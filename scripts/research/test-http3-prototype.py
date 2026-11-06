"""Exercise native HTTP3 against an isolated, real AimDrop backend and inbox."""
import hashlib
import os
from pathlib import Path
import plistlib
import queue
import subprocess
import sys
import tempfile
import threading
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from receiver.http import ReceiverServer
from receiver.inbox import Inbox
from receiver.main import identity
from receiver.sessions import Sessions
from tests.fixtures import archive, dvzip, request


def check(canceled=False, chunked=False):
    with tempfile.TemporaryDirectory(prefix="airfolder-http3-", dir=ROOT / ".build") as temp:
        root = Path(temp)
        inbox = Inbox(root / "Incoming")
        events = queue.Queue()
        observed = []
        canceled_once = threading.Event()
        def emit(event, **fields):
            events.put(dict(event=event, **fields))
            if event in ("receiving", "progress"):
                spooled = sum(path.stat().st_size for path in (root / "spool").glob("*.body"))
                observed.append((event, spooled, fields.get("bytes", 0)))
            if canceled and event == "progress" and not canceled_once.is_set():
                canceled_once.set()
                assert server.cancel_transfer(fields["id"])
        _, context = identity(root)
        sessions = Sessions(emit, prepare_destination=inbox.prepare, abandon_destination=inbox.abandon)
        server = ReceiverServer(("::", 0), context, sessions, emit, "Isolated HTTP3 backend", inbox=inbox)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        original = os.urandom(8 * 1024 * 1024 + 17)
        (root / "ask.plist").write_bytes(plistlib.dumps(request(str(uuid.uuid4()), "http3-probe.bin"), fmt=plistlib.FMT_BINARY))
        payload = dvzip(archive([("NSIRD_AirDrop_test/http3-probe.bin", original)]))
        (root / "upload.body").write_bytes(payload)
        try:
            mode = "--native-cancel-check" if canceled else "--native-transfer-check"
            result = subprocess.run([str(ROOT / ".build/airfolder-pairing-prototype"), mode, str(root)],
                cwd=ROOT, env={**os.environ, "AIRFOLDER_PROBE_BACKEND_PORT": str(server.server_port),
                               "AIRFOLDER_PROBE_SPOOL_DIR": str(root / "spool"),
                               "AIRFOLDER_PROBE_CLIENT_NO_LENGTH": "1" if chunked else "0"},
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=65)
            print(result.stdout, end="")
            assert result.returncode == 0, result.returncode
            assert "framing=" + ("chunked" if chunked else "content-length") in result.stdout
            for marker in ("native_http3_client_ready alpn=h3", "native_http3_discover_check=ok", "native_http3_ask_check=ok", "native_http3_continue_received",
                           "native_http3_streaming_backend_ready"):
                assert marker in result.stdout, marker
            downloaded = [event for event in list(events.queue) if event["event"] == "downloaded"]
            assert any(event == "receiving" and size < len(payload) for event, size, _ in observed), "Panel only starts after source EOF"
            assert any(event == "progress" and 0 < size < len(payload) and count > 0 for event, size, count in observed), "No progress while source is incomplete"
            if canceled:
                assert "native_http3_cancel_check=ok" in result.stdout
                assert "native_http3_upload_source_complete" not in result.stdout, "Cancellation did not stop source reading"
                assert not downloaded and not Inbox(inbox.root).list_ready(), "Canceled payload was published"
                with server.connection_condition:
                    assert server.connection_condition.wait_for(lambda: not server.uploads, timeout=5)
                assert not list(inbox.root.iterdir()), "Incomplete inbox job not removed"
                print("PASS: cancellation during first progress stops HTTP3 before source EOF, no ready job, incomplete inbox cleaned")
                return
            assert "native_http3_upload_check=ok" in result.stdout and "native_http3_replay_check=rejected" in result.stdout
            assert len(downloaded) == 1, downloaded
            paths = [Path(path) for path in downloaded[0]["paths"]]
            assert len(paths) == 1 and paths[0].name == "http3-probe.bin", paths
            assert hashlib.sha256(paths[0].read_bytes()).digest() == hashlib.sha256(original).digest()
            assert len(Inbox(inbox.root).list_ready()) == 1, "Not durable across reopen"
            # Successful spool removed; the replay is rejected after its first
            # block, before another 100 Continue or the rest of its body is read.
            spools = list((root / "spool").glob("*.body"))
            assert len(spools) == 1 and payload.startswith(spools[0].read_bytes()) and spools[0].stat().st_size < len(payload)
            assert result.stdout.count("native_http3_continue_received") == 1
            print("PASS: strict h3 ALPN, streaming progress before source EOF, 8 MiB SHA-256, durable inbox, early replay rejection, spool retention")
        finally:
            sessions.close()
            server.shutdown()
            server.close_connections()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    check()
    check(chunked=True)
    check(canceled=True, chunked=True)
