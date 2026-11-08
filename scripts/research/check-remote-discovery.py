"""Verify unadvertised actors still support PIN, restart, PairVerify and HTTP3."""
import importlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

checks = importlib.import_module('test-persistent-pairing')


def main():
    with tempfile.TemporaryDirectory(prefix='remote-discovery-', dir=checks.ROOT / '.build') as directory:
        root = Path(directory)
        (root / 'backend').mkdir(mode=0o700)
        _, context = checks.identity(root / 'backend')
        inbox = checks.Inbox(root / 'Incoming')
        events = lambda *args, **kwargs: None
        sessions = checks.Sessions(events, prepare_destination=inbox.prepare, abandon_destination=inbox.abandon)
        backend = checks.ReceiverServer(('::1', 0), context, sessions, events, 'AimDrop AWDL Test', inbox=inbox)
        thread = threading.Thread(target=backend.serve_forever, daemon=True)
        thread.start()
        common = {**os.environ, 'AIRFOLDER_PROBE_BACKEND_PORT': str(backend.server_port),
                  'AIRFOLDER_EXPECTED_NAME': 'AimDrop AWDL Test'}
        server_env = {**common, 'AIRFOLDER_PAIRING_STATE_DIR': str(root / 'server'), 'AIRFOLDER_PAIRING_TEST_FILES': '1'}
        client_env = {**common, 'AIRFOLDER_PAIRING_STATE_DIR': str(root / 'client')}
        server = client = None
        try:
            server = checks.Server(server_env, ('--loopback', '--remote-only'))
            client = subprocess.Popen([checks.BINARY, '--client', server.ports['prepair'], server.ports['pairing']],
                cwd=checks.ROOT, env=client_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True)
            while True:
                line = server.line()
                if line.startswith('test_pin='):
                    pin = line.split('=', 1)[1]
                    break
            output, errors = client.communicate(pin + '\n', timeout=25)
            assert client.returncode == 0, (output, errors)
            assert 'temporary_identity_exchange=mutual' in output
            before = (root / 'server/identity.json').read_bytes()
            assert len(json.loads(before)['peers']) == 1
            server.stop()
            server = checks.Server(server_env, ('--loopback', '--remote-only'))
            assert (root / 'server/identity.json').read_bytes() == before
            output = checks.run(['--reconnect', server.ports['prepair'], 'normal'], client_env)
            assert 'restart_pair_verify_http3=ok' in output
            server.stop()
            assert not any('test_pin=' in line for line in server.lines)
            assert (root / 'server/identity.json').read_bytes() == before
            print('PASS: actors without Bonjour registration support mutual PIN enrollment and restart → PairVerify → HTTP3 without re-pairing')
        finally:
            if client is not None and client.poll() is None:
                client.kill(); client.communicate(timeout=5)
            if server is not None and server.process.poll() is None:
                server.stop()
            sessions.close()
            backend.shutdown(); backend.close_connections(); backend.server_close()
            thread.join(timeout=3)


if __name__ == '__main__':
    main()
