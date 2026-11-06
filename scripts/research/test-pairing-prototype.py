"""Exercise pre-pair exchange, dynamic PAKE challenge, and both identity directions."""
import os
from pathlib import Path
import select
import subprocess
import time

os.chdir(Path(__file__).resolve().parents[2])
binary = '.build/airfolder-pairing-prototype'
server = subprocess.Popen([binary, '--loopback'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
lines = []
buffer = b''

def server_line(timeout=10):
    global buffer
    deadline = time.monotonic() + timeout
    while b'\n' not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([server.stdout], [], [], remaining)[0]:
            raise RuntimeError('Timed out waiting for prototype')
        chunk = os.read(server.stdout.fileno(), 4096)
        if not chunk:
            raise RuntimeError('Prototype exited: ' + server.stderr.read().decode())
        buffer += chunk
    raw, buffer = buffer.split(b'\n', 1)
    line = raw.decode()
    lines.append(line)
    if not line.startswith('test_pin='):
        print(line)
    return line

try:
    ports = {}
    while True:
        line = server_line()
        if '_server_ready port=' in line:
            mode, port = line.split('_server_ready port=')
            ports[mode] = port
        if line.startswith('pairing_prototype_ready'):
            break
    for extra in [[], ['--wrong-pin']]:
        client = subprocess.Popen([binary, '--client', ports['prepair'], ports['pairing'], *extra], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            while True:
                line = server_line()
                if line.startswith('test_pin='):
                    pin = line.split('=')[1]
                    break
            stdout, stderr = client.communicate(pin + '\n', timeout=15)
            print(stdout.strip())
            if client.returncode:
                print(stderr)
                raise RuntimeError(f'Client failed: {client.returncode}')
        finally:
            if client.poll() is None:
                client.kill()
                client.wait()
    server.terminate()
    stdout, stderr = server.communicate(timeout=3)
    lines.extend((buffer + stdout).decode().splitlines())
    assert sum(line.startswith('authenticated_identity_sent') for line in lines) == 1
    assert sum(line.startswith('authenticated_peer_identities_received') for line in lines) == 1
    print('two_stage_native_pairing_probe=ok')
finally:
    if server.poll() is None:
        server.kill()
        server.wait()
