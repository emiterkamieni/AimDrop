#!/usr/bin/env python3
"""Run the isolated AimDrop AWDL Test receiver with a durable research inbox."""
import argparse
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from receiver.http import ReceiverServer
from receiver.inbox import Inbox
from receiver.main import identity
from receiver.sessions import Sessions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--duration', type=int, default=1200)
    parser.add_argument('--state-root', type=Path, default=ROOT / '.build/self-discovery/live')
    args = parser.parse_args()
    if not 15 <= args.duration <= 3600:
        parser.error('Duration must be between 15 and 3600 seconds')
    root = args.state_root.resolve()
    if (ROOT / '.build').resolve() not in root.parents:
        parser.error('Research state must be inside .build')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / 'receiver.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        backend_root = root / 'backend'
        backend_root.mkdir(exist_ok=True, mode=0o700)
        _, context = identity(backend_root)
        inbox = Inbox(root / 'Incoming')
        def event(kind, **fields):
            if kind in ('receiving', 'downloaded', 'error', 'canceled'):
                print(f'research_event={kind} files={len(fields.get("paths", []))}', flush=True)
        sessions = Sessions(event, prepare_destination=inbox.prepare, abandon_destination=inbox.abandon)
        backend = ReceiverServer(('::1', 0), context, sessions, event, 'AimDrop AWDL Test', inbox=inbox)
        thread = threading.Thread(target=backend.serve_forever, daemon=True)
        thread.start()
        process = None
        try:
            process = subprocess.Popen([str(ROOT / '.build/airfolder-pairing-prototype'), '--advertise', '--remote-only'],
                cwd=ROOT, env={**os.environ, 'AIRFOLDER_PAIRING_STATE_DIR': str(root / 'Pairing'),
                              'AIRFOLDER_PROBE_BACKEND_PORT': str(backend.server_port),
                              'AIRFOLDER_PROBE_DURATION_SECONDS': str(args.duration)},
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            def stop(signum, frame):
                if process.poll() is None:
                    process.terminate()
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            with (root / 'receiver.log').open('a', buffering=1) as log:
                for line in process.stdout:
                    log.write(line)
                    print(line, end='', flush=True)
            result = process.wait(timeout=5)
            print('research_receiver_stopped', result, 'ready_transfers', len(inbox.list_ready()), flush=True)
            return result
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
            sessions.close()
            backend.shutdown(); backend.close_connections(); backend.server_close()
            thread.join(timeout=3)


if __name__ == '__main__':
    sys.exit(main())
