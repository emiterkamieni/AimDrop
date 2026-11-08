"""Isolated loopback backend owned by the research .app through its stdin pipe."""
import json
from pathlib import Path
import sys
import threading

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from receiver.http import ReceiverServer
from receiver.inbox import Inbox
from receiver.main import identity
from receiver.sessions import Sessions


def main():
    if len(sys.argv) != 2:
        raise ValueError('Expected research state directory')
    root = Path(sys.argv[1]).resolve()
    if (ROOT / '.build').resolve() not in root.parents:
        raise ValueError('Research state must be inside .build')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    backend_root = root / 'backend'
    backend_root.mkdir(exist_ok=True, mode=0o700)
    _, context = identity(backend_root)
    inbox = Inbox(root / 'Incoming')
    def event(kind, **fields):
        if kind in ('receiving', 'downloaded', 'error', 'canceled'):
            try:
                print(json.dumps({'event': kind, 'files': len(fields.get('paths', []))}), flush=True)
            except BrokenPipeError:
                pass  # The owning app exited; the inbox still completes cleanup.
    sessions = Sessions(event, prepare_destination=inbox.prepare, abandon_destination=inbox.abandon)
    backend = ReceiverServer(('::1', 0), context, sessions, event, 'AimDrop AWDL Test', inbox=inbox)
    worker = threading.Thread(target=backend.serve_forever, daemon=True)
    worker.start()
    print(json.dumps({'backend_port': backend.server_port}), flush=True)
    try:
        # Closing the app also closes this pipe, including abrupt parent death.
        sys.stdin.buffer.read()
    finally:
        sessions.close()
        backend.shutdown(); backend.close_connections(); backend.server_close()
        worker.join(timeout=3)
        print(json.dumps({'event': 'stopped', 'ready_transfers': len(inbox.list_ready())}), file=sys.stderr, flush=True)


if __name__ == '__main__':
    main()
