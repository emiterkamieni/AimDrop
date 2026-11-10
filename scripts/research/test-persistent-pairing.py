"""PIN enrollment, process restart, authenticated encrypted resolve and real h3.

Only generated fixture keys are used. Each peer gets a separate private store.
"""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from receiver.http import ReceiverServer
from receiver.inbox import Inbox
from receiver.main import identity
from receiver.sessions import Sessions

BINARY = str(ROOT / '.build/airfolder-pairing-prototype')


class Server:
    def __init__(self, env, args=('--loopback',)):
        self.buffer = b''
        self.lines = []
        self.process = subprocess.Popen([BINARY, *args], cwd=ROOT, env=env,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.ports = {}
        try:
            while True:
                line = self.line(30)
                if '_server_ready port=' in line:
                    mode, port = line.split('_server_ready port=')
                    self.ports[mode] = port
                if line.startswith('pairing_prototype_ready'):
                    break
        except BaseException:
            self.stop()
            raise

    def line(self, timeout=15):
        deadline = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.process.stdout], [], [], remaining)[0], 'Server timeout'
            data = os.read(self.process.stdout.fileno(), 65536)
            assert data, 'Server exited: ' + ' / '.join(self.lines[-5:])
            self.buffer += data
        raw, self.buffer = self.buffer.split(b'\n', 1)
        line = raw.decode()
        self.lines.append(line)
        return line

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        out, _ = self.process.communicate(timeout=5)
        self.lines.extend((self.buffer + out).decode().splitlines())
        self.buffer = b''


def run(args, env, expected=0):
    result = subprocess.run([BINARY, *args], cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=35)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr[-1500:])
    return result.stdout


def main():
    with tempfile.TemporaryDirectory(prefix='pairing-restart-', dir=ROOT / '.build') as temp:
        root = Path(temp)
        (root / 'backend').mkdir(mode=0o700)
        _, context = identity(root / 'backend')
        inbox = Inbox(root / 'Incoming')
        sessions = Sessions(lambda *a, **kw: None, prepare_destination=inbox.prepare, abandon_destination=inbox.abandon)
        backend = ReceiverServer(('::', 0), context, sessions, lambda *a, **kw: None, 'PairVerify fixture', inbox=inbox)
        worker = threading.Thread(target=backend.serve_forever, daemon=True)
        worker.start()
        common = {**os.environ, 'AIRFOLDER_PROBE_BACKEND_PORT': str(backend.server_port)}
        server_env = {**common, 'AIRFOLDER_PAIRING_STATE_DIR': str(root / 'server'), 'AIRFOLDER_PAIRING_TEST_FILES': '1'}
        client_env = {**common, 'AIRFOLDER_PAIRING_STATE_DIR': str(root / 'client')}
        second_env = {**common, 'AIRFOLDER_PAIRING_STATE_DIR': str(root / 'second')}
        server = None
        try:
            print(run(['--peer-enrollment-check'], common).strip())
            print(run(['--pair-verify-check'], common).strip())
            server = Server(server_env)
            for env in (client_env, second_env):
                extra = ['--large-peer-image'] if env is client_env else []
                client = subprocess.Popen([BINARY, '--client', server.ports['prepair'], server.ports['pairing'], *extra], cwd=ROOT,
                                          env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    while True:
                        line = server.line()
                        if line.startswith('test_pin='):
                            pin = line.split('=')[1]
                            break
                    stdout, stderr = client.communicate(pin + '\n', timeout=20)
                    assert client.returncode == 0, (stdout, stderr)
                    assert 'temporary_identity_exchange=mutual' in stdout
                finally:
                    if client.poll() is None:
                        client.kill(); client.wait()
            for directory in ('server', 'client', 'second'):
                path = root / directory / 'identity.json'
                assert path.stat().st_mode & 0o777 == 0o600
                assert path.parent.stat().st_mode & 0o777 == 0o700
                assert len(json.loads(path.read_text())['peers']) == (2 if directory == 'server' else 1)
            before = (root / 'server/identity.json').read_bytes()
            # A second process cannot race the active identity writer.
            assert 'already in use' in run(['--pairing-store-check'], server_env, expected=1)
            server.stop()
            assert any(line.startswith('test_pin=') for line in server.lines)
            server = Server(server_env)
            assert (root / 'server/identity.json').read_bytes() == before
            for mode in ('normal', 'replay', 'isolation', 'no-stream', 'wrong-key', 'legacy', 'normal'):
                output = run(['--reconnect', server.ports['prepair'], mode], client_env)
                print(output.strip())
                marker = {'wrong-key': 'reconnect_wrong-key=rejected', 'no-stream': 'resolve_without_stream=rejected'}.get(mode, 'restart_pair_verify_http3=ok')
                assert marker in output
            assert 'restart_pair_verify_http3=ok' in run(['--reconnect', server.ports['prepair'], 'normal'], second_env)
            server.stop()
            assert not any('test_pin=' in line or 'prepair_exchange=ready' in line for line in server.lines), 'Reconnect fell back to PIN'
            assert (root / 'server/identity.json').read_bytes() == before, 'Reconnect changed identity or extended enrollment'
            # Expired enrollment cannot authenticate after another restart.
            state = json.loads(before)
            for peer in state['peers']:
                peer['enrolledAt'] -= 32 * 86400
                peer['expiresAt'] -= 32 * 86400
            (root / 'server/identity.json').write_text(json.dumps(state))
            server = Server(server_env)
            assert 'reconnect_expired=rejected' in run(['--reconnect', server.ports['prepair'], 'expired'], client_env)
            server.stop()
            # Never silently replace damaged or insecure existing state.
            path = root / 'server/identity.json'
            path.write_bytes(b'{broken')
            assert 'corrupt' in run(['--pairing-store-check'], server_env, expected=1)
            assert path.read_bytes() == b'{broken'
            path.write_bytes(before)
            path.chmod(0o644)
            assert 'permissions' in run(['--pairing-store-check'], server_env, expected=1)
            path.chmod(0o600)
            target = root / 'original-state.json'
            path.rename(target)
            path.symlink_to(target)
            run(['--pairing-store-check'], server_env, expected=1)
            assert target.read_bytes() == before
            path.unlink()
            old = json.loads(before)
            old['version'] = 1
            old.pop('presentedName')
            path.write_text(json.dumps(old)); path.chmod(0o600)
            run(['--pairing-store-check'], server_env)
            migrated_bytes = path.read_bytes()
            migrated = json.loads(migrated_bytes)
            assert migrated['version'] == 4 and migrated['presentedName'] == 'AimDrop Logo Test'
            assert migrated['signingSeed'] != old['signingSeed'] and not migrated['peers']
            assert migrated['serverID'] != old['serverID'] and migrated['irk'] != old['irk']
            run(['--pairing-store-check'], server_env)
            assert path.read_bytes() == migrated_bytes, 'Migration repeated on restart'
            print('PASS: durable mutual enrollment; process restart without PIN; real encrypted resolve + h3; UUID and legacy sessions; replay, isolation, wrong-key, expiry, store lock/corruption/permissions/symlink rejection')
        finally:
            if server:
                server.stop()
            sessions.close()
            backend.shutdown()
            backend.close_connections()
            backend.server_close()
            worker.join(timeout=3)


if __name__ == '__main__':
    main()
