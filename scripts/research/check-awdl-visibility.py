"""Compare actual unregistered pairing listeners with raw AWDL loopback on/off."""
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def check(loopback):
    with tempfile.TemporaryDirectory(prefix='awdl-visibility-', dir=ROOT / '.build') as directory:
        root = Path(directory)
        output = []
        lines = queue.Queue()
        process = subprocess.Popen([sys.executable, '-B', '-u', str(ROOT / 'scripts/research/remote-discovery-live.py'),
                                    '--duration', '20', '--state-root', str(root)],
            cwd=ROOT, env={**os.environ, 'AIRFOLDER_PROBE_HIDE_PANEL': '1',
                          'AIRFOLDER_PROBE_SYNTHETIC_ADVERTISEMENT': '1',
                          'AIRFOLDER_PROBE_ADVERTISEMENT_LOOPBACK': '1' if loopback else '0'},
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        def collect():
            for line in process.stdout:
                output.append(line)
                lines.put(line)
            lines.put(None)
        reader = threading.Thread(target=collect, daemon=True)
        reader.start()
        try:
            ready = sent = False
            ports = []
            deadline = time.monotonic() + 30
            while not (ready and sent):
                line = lines.get(timeout=max(0.01, deadline - time.monotonic()))
                if line is None:
                    raise RuntimeError('Receiver exited before readiness: ' + ''.join(output[-10:]))
                if '_server_ready port=' in line:
                    ports.append(int(line.split('port=')[1]))
                ready |= line.startswith('pairing_prototype_ready scope=external-awdl')
                sent |= line.startswith('awdl_external_announcement_sent')
                if time.monotonic() > deadline:
                    raise TimeoutError('Receiver startup timeout')
            assert len(ports) == 2
            for port in ports:
                with socket.create_connection(('::1', port), timeout=2):
                    pass
            server_id = json.loads((root / 'Pairing/identity.json').read_bytes())['serverID']
            observer = subprocess.run([str(ROOT / '.build/self-discovery/observer'), 'AimDrop-' + server_id],
                                      capture_output=True, text=True, timeout=18)
            expected = 2 if loopback else 0
            assert observer.returncode == 0, observer.stderr
            assert f'summary observed={expected}\n' in observer.stdout, observer.stdout
            assert 'observer_failed=' not in observer.stdout
            assert process.wait(timeout=15) == 0, ''.join(output[-10:])
            reader.join(timeout=2)
            assert not any('announcement_failed' in line for line in output), ''.join(output[-10:])
            print(f'PASS: raw AWDL loopback={int(loopback)}, locally discovered pairing types={expected}, both listeners reachable')
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
            reader.join(timeout=2)


if __name__ == '__main__':
    check(True)
    check(False)
