"""Exercise the actual bundled helper/worker together, with isolated app storage."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tests.fixtures import archive, dvzip, request


def gone(pid):
    for _ in range(60):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    raise AssertionError('Orphan native helper: ' + str(pid))


class Worker:
    def __init__(self, bundle, root, name, avatar=None):
        self.events = queue.Queue()
        self.log_path = root / ('worker-' + uuid.uuid4().hex + '.log')
        self.log = self.log_path.open('w')
        config = plistlib.loads((bundle / 'Info.plist').read_bytes())
        arguments = [
            config['AFPythonExecutable'], '-I', '-B', '-u', str(bundle / 'Resources/receiver/main.py'),
            '--state-dir', str(root / 'state'), '--name=' + name,
            '--native-helper', str(bundle / 'MacOS/AirFolderReceiver'),
            '--native-artwork', str(bundle / 'Resources/AirFolder.png'), '--native-loopback',
        ]
        if avatar is not None:
            arguments += ['--native-avatar', str(avatar)]
        self.process = subprocess.Popen(arguments, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True)
        def read():
            for line in self.process.stdout:
                self.events.put(json.loads(line))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.native_pid = None

    def event(self, kind, allow_error=False):
        while True:
            try:
                value = self.events.get(timeout=40)
            except queue.Empty:
                raise AssertionError('Worker timeout: ' + self.log_path.read_text()[-1500:])
            if value['event'] == 'error' and not allow_error:
                raise AssertionError(value)
            if value['event'] == kind:
                if kind == 'ready':
                    self.native_pid = value['native']['pid']
                return value

    def send(self, command):
        self.process.stdin.write(json.dumps(command) + '\n')
        self.process.stdin.flush()

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait()
            raise
        self.reader.join(timeout=2)
        self.process.stdout.close()
        self.log.close()
        if self.native_pid:
            gone(self.native_pid)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/AirFolder.app')
    bundle = parser.parse_args().app.resolve() / 'Contents'
    prototype = ROOT / '.build/airfolder-pairing-prototype'
    with tempfile.TemporaryDirectory(prefix='bundled-native-', dir=ROOT / '.build') as temp:
        root = Path(temp)
        fixture = root / 'avatar-fixtures'
        avatar_checks = root / 'avatar-checks'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(ROOT / 'Sources/ReceiverAvatar.swift'),
                        str(ROOT / 'tests/AvatarChecks.swift'), '-o', str(avatar_checks)], check=True)
        subprocess.run([str(avatar_checks), str(fixture), str(bundle / 'Resources/AirFolder.png')], cwd=ROOT, check=True)
        name = 'AirFolder — kontrola paczki'
        client_env = {**os.environ, 'AIRFOLDER_PAIRING_STATE_DIR': str(root / 'client'), 'AIRFOLDER_EXPECTED_NAME': name}
        worker = Worker(bundle, root, name)
        def reconnect(ready, transfer=False):
            env = dict(client_env)
            if transfer:
                env['AIRFOLDER_RECONNECT_TRANSFER_DIR'] = str(root)
            result = subprocess.run([str(prototype), '--reconnect', str(ready['native']['prepair_port']), 'normal'],
                                    cwd=ROOT, env=env, text=True, capture_output=True, timeout=35)
            assert result.returncode == 0, (result.stdout, result.stderr[-1000:], worker.log_path.read_text()[-5000:])
            assert 'restart_pair_verify_http3=ok' in result.stdout
            if transfer:
                assert 'bundled_pair_verify_transfer=ok' in result.stdout
        try:
            ready = worker.event('ready')
            def enroll():
                client = subprocess.Popen([str(prototype), '--client', str(ready['native']['prepair_port']), str(ready['native']['pairing_port'])],
                                          cwd=ROOT, env=client_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    pin = worker.event('pairing_pin')['code']
                    stdout, stderr = client.communicate(pin + '\n', timeout=20)
                    assert client.returncode == 0, (stdout, stderr)
                    worker.event('pairing_closed')
                    assert pin not in worker.log_path.read_text(), 'PIN leaked to app diagnostics'
                    return pin
                finally:
                    if client.poll() is None:
                        client.kill(); client.wait()
            first_pin = enroll()
            state_path = root / 'state/Pairing/identity.json'
            # The real installed v3 state has no avatar field. Upgrading with
            # the default logo must preserve every identity/peer field.
            v4 = json.loads(state_path.read_bytes())
            default_digest = v4['presentedAvatarDigest']
            worker.close()
            v3 = dict(v4, version=3); v3.pop('presentedAvatarDigest')
            state_path.write_text(json.dumps(v3))
            worker = Worker(bundle, root, name)
            ready = worker.event('ready')
            migrated = json.loads(state_path.read_bytes())
            assert migrated == dict(v3, version=4, presentedAvatarDigest=default_digest), 'Default upgrade reset existing pairing'
            reconnect(ready)
            assert 'prepair_exchange=ready' not in worker.log_path.read_text()
            before_rename = json.loads(state_path.read_bytes())
            # Name changes reach both the native identity and the Python backend.
            name = 'AirFolder — nowa nazwa'
            client_env['AIRFOLDER_EXPECTED_NAME'] = name
            request_id = str(uuid.uuid4())
            worker.send(dict(command='set_name', request_id=request_id, name=name))
            result = worker.event('name_result')
            assert result['ok'] and result['name'] == name and result['request_id'] == request_id and result['pairing_reset']
            old_ports = dict(ready['native'])
            ready['native'].update(result['native'])
            assert ready['native']['prepair_port'] != old_ports['prepair_port']
            after_rename = json.loads(state_path.read_bytes())
            assert after_rename['presentedName'] == name
            for field in ('serverID', 'deviceID', 'irk'):
                assert after_rename[field] != before_rename[field], 'Old discovery identity retained'
            assert after_rename['signingSeed'] != before_rename['signingSeed']
            assert not after_rename['peers'], 'Old PIN enrollment still trusted after rename'
            old_client = subprocess.run([str(prototype), '--reconnect', str(ready['native']['prepair_port']), 'normal'],
                                        cwd=ROOT, env=client_env, text=True, capture_output=True, timeout=30)
            assert old_client.returncode != 0 and 'reconnect_check_error=' in old_client.stdout, 'Old pairing still works after rename'
            assert worker.process.poll() is None, 'Rejection must not stop the receiver'
            enroll()
            same_name_state = state_path.read_bytes()
            worker.send(dict(command='set_name', request_id=str(uuid.uuid4()), name=name))
            assert worker.event('name_result')['pairing_reset'] is False
            assert state_path.read_bytes() == same_name_state, 'Equal-name save reset pairing'
            digests = json.loads((fixture / 'digests.json').read_text())
            assert digests['default_digest'] == default_digest
            avatar = root / 'avatar.png'; avatar.write_bytes((fixture / 'avatar.png').read_bytes())
            alternate = root / 'same-image.png'; alternate.write_bytes((fixture / 'same-image.png').read_bytes())
            invalid = root / 'invalid.png'; invalid.write_bytes(b'not an image')
            def profile(path, digest, expected=True):
                worker.send(dict(command='set_profile', request_id=str(uuid.uuid4()), name=name,
                                 avatar_path=str(path) if path else None, avatar_digest=digest))
                result = worker.event('profile_result')
                assert result['ok'] is expected, result
                if expected:
                    assert result['avatar_digest'] == digest
                    ready['native'].update(result['native'])
                return result
            before_bad = state_path.read_bytes()
            profile(invalid, digests['avatar_digest'], expected=False)
            assert state_path.read_bytes() == before_bad, 'Invalid artwork modified pairing'
            # Combined name/avatar edit goes through a single profile operation.
            name = 'AirFolder — profil z awatarem'; client_env['AIRFOLDER_EXPECTED_NAME'] = name
            assert profile(avatar, digests['avatar_digest'])['pairing_reset']
            changed = state_path.read_bytes()
            assert profile(avatar, digests['avatar_digest'])['pairing_reset'] is False
            assert state_path.read_bytes() == changed
            old_client = subprocess.run([str(prototype), '--reconnect', str(ready['native']['prepair_port']), 'normal'],
                                        cwd=ROOT, env=client_env, text=True, capture_output=True, timeout=30)
            assert old_client.returncode != 0, 'Avatar change accepted old pairing'
            client_env['AIRFOLDER_EXPECTED_AVATAR'] = str(avatar)
            enroll()  # also compares exact donated PNG bytes
            enrolled = state_path.read_bytes()
            assert profile(alternate, digests['avatar_digest'])['pairing_reset'] is False
            assert state_path.read_bytes() == enrolled, 'Same pixels at another path reset pairing'
            worker.close()
            worker = Worker(bundle, root, name, avatar=alternate)
            ready = worker.event('ready')
            reconnect(ready)
            assert state_path.read_bytes() == enrolled, 'Custom avatar restart reset pairing'
            worker.close()
            worker = Worker(bundle, root, name, avatar=fixture / 'truncated.png')
            startup = worker.events.get(timeout=40)
            assert startup['event'] == 'error', 'Truncated PNG was accepted at startup'
            worker.close()
            assert state_path.read_bytes() == enrolled, 'Invalid startup avatar reset paired keys'
            worker = Worker(bundle, root, name, avatar=alternate)
            ready = worker.event('ready')
            reconnect(ready)
            worker.close()
            worker = Worker(bundle, root, name, avatar=fixture / 'short-scanlines.png')
            assert worker.events.get(timeout=40)['event'] == 'error', 'CRC-valid partial PNG was accepted'
            worker.close()
            assert state_path.read_bytes() == enrolled
            worker = Worker(bundle, root, name, avatar=alternate)
            ready = worker.event('ready')
            assert profile(None, default_digest)['pairing_reset'], 'Restore logo did not require new pairing'
            client_env.pop('AIRFOLDER_EXPECTED_AVATAR')
            enroll()
            original = os.urandom(2 * 1024 * 1024 + 17)
            (root / 'ask.plist').write_bytes(plistlib.dumps(request(str(uuid.uuid4()), 'bundled.bin'), fmt=plistlib.FMT_BINARY))
            (root / 'upload.body').write_bytes(dvzip(archive([('NSIRD_AirDrop_bundle/bundled.bin', original)])))
            reconnect(ready, transfer=True)
            downloaded = worker.event('downloaded')
            assert len(downloaded['paths']) == 1
            buffered = Path(downloaded['paths'][0])
            assert hashlib.sha256(buffered.read_bytes()).digest() == hashlib.sha256(original).digest()
            identity = (root / 'state/Pairing/identity.json').read_bytes()
            worker.send(dict(command='shutdown'))
            worker.close()
            worker = Worker(bundle, root, name)
            ready = worker.event('ready')
            pending = worker.event('pending')['transfers']
            assert len(pending) == 1 and pending[0]['id'] == downloaded['id']
            reconnect(ready)
            assert (root / 'state/Pairing/identity.json').read_bytes() == identity
            assert 'prepair_exchange=ready' not in worker.log_path.read_text(), 'Unexpected new PIN flow'
            destination = root / 'saved'; destination.mkdir()
            worker.send(dict(command='save', id=downloaded['id'], directory=str(destination)))
            complete = worker.event('complete')
            assert complete['paths'] == [str(destination / 'bundled.bin')]
            assert (destination / 'bundled.bin').read_bytes() == original
            worker.close()  # UI EOF
            worker = Worker(bundle, root, name)
            ready = worker.event('ready')
            worker.process.kill()  # hard worker death must close the child's pipe
            worker.close()
            worker = Worker(bundle, root, name)
            ready = worker.event('ready')
            os.kill(worker.native_pid, signal.SIGKILL)
            assert worker.event('error', allow_error=True)['fatal'] is True
            worker.close()
            worker = Worker(bundle, root, name)
            worker.close()  # UI EOF during native startup
            print('PASS: bundled profile IPC, v3 migration without re-pairing, name/avatar reset + exact PNG donation, metadata/path equality, custom-avatar restart, invalid PNG rejection without key changes, logo restore, PairVerify + h3/SHA-256, durable backlog, child lifecycle')
        finally:
            worker.close()


if __name__ == '__main__':
    main()
