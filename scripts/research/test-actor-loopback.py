"""Two real processes, loopback TLS-SPAKE2+, correct and incorrect PIN."""
import os
from pathlib import Path
import selectors
import subprocess

os.chdir(Path(__file__).resolve().parents[2])
binary = '.build/actor-loopback-probe'
server = subprocess.Popen([binary, '--server'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    selector = selectors.DefaultSelector()
    selector.register(server.stdout, selectors.EVENT_READ)
    if not selector.select(10):
        raise RuntimeError('Server readiness timeout')
    line = server.stdout.readline().strip()
    print(line)
    if not line.startswith('loopback_server_ready port='):
        raise RuntimeError('Server did not become ready')
    port = line.split('=')[1]
    for extra in [[], ['--wrong-pin']]:
        result = subprocess.run([binary, '--client', port, *extra], capture_output=True, text=True, timeout=15)
        print(result.stdout.strip())
        if result.returncode:
            print(result.stderr)
            raise RuntimeError(f'Client failed: {result.returncode}')
    server.terminate()
    stdout, stderr = server.communicate(timeout=3)
    print(stdout.strip())
    if stdout.count('remote_identity_request=received') != 1:
        raise RuntimeError('Unexpected count of authenticated identity requests')
    print('cross_process_spake_probe=ok')
finally:
    if server.poll() is None:
        server.kill()
        server.wait()
