import http.client
import json
from pathlib import Path
import plistlib
import queue
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

from tests.fixtures import archive, dvzip, request

ROOT = Path(__file__).resolve().parents[1]


class Worker:
    def __init__(self, state, log, setup=None):
        self.observed = []
        self.events = queue.Queue()
        entry = [str(ROOT / "receiver/main.py")]
        if setup:
            entry = ["-c", "import sys\nsys.path.insert(0, %r)\n%s\nfrom receiver.main import main\nmain()"
                     % (str(ROOT), setup)]
        self.process = subprocess.Popen([
            sys.executable, "-I", "-B", "-u", *entry,
            "--state-dir", str(state), "--no-advertise",
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        def read():
            for line in self.process.stdout:
                event = json.loads(line)
                self.observed.append(event)
                self.events.put(event)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.port = self.event("ready")["port"]

    def event(self, kind):
        while True:
            event = self.events.get(timeout=10)
            if event["event"] == "error":
                raise AssertionError(event["message"])
            if event["event"] == kind:
                return event

    def command(self, command):
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def post(self, path, body, headers=None):
        connection = http.client.HTTPSConnection("::1", self.port, timeout=5,
                                                context=ssl._create_unverified_context())
        try:
            connection.request("POST", path, body, headers or {})
            response = connection.getresponse()
            data = response.read()
            return response.status, data
        finally:
            connection.close()

    def close(self):
        if self.process.poll() is None:
            self.command({"command": "shutdown"})
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdin.close()
        self.reader.join(timeout=2)
        self.process.stdout.close()


class BufferedFlowTests(unittest.TestCase):
    def test_cancel_transfer_command_interrupts_blocked_socket_without_error(self):
        with tempfile.TemporaryDirectory(prefix="airfrajer-cancel-flow-") as name:
            root = Path(name).resolve()
            with (root / "worker.log").open("w") as log:
                worker = Worker(root / "state", log)
                try:
                    worker.event("pending")
                    ident = str(uuid.uuid4())
                    self.assertEqual(worker.post("/Ask", plistlib.dumps(request(ident)))[0], 200)
                    incoming = worker.event("incoming")
                    data = archive([("test.txt", b"x" * 250000)])
                    raw = socket.create_connection(("::1", worker.port), timeout=5)
                    with ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost") as secure:
                        headers = ("POST /Upload HTTP/1.1\r\nContent-Type: application/x-cpio\r\n"
                                   "TransferID: %s\r\nContent-Length: %d\r\n\r\n" % (ident, len(data))).encode()
                        secure.sendall(headers + data[:100000])
                        worker.event("progress")
                        worker.command({"command": "cancel_transfer", "id": incoming["id"]})
                        canceled = worker.event("canceled")
                        canceled.pop("emitted_at")
                        self.assertEqual(canceled,
                                         dict(event="canceled", id=incoming["id"], phase="receiving"))
                        secure.settimeout(2)
                        self.assertEqual(secure.recv(4096), b"")
                    job = root / "state/Incoming" / incoming["id"]
                    deadline = time.monotonic() + 2
                    while job.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertFalse(job.exists())
                    self.assertEqual(worker.post("/Discover", plistlib.dumps({}))[0], 200)
                    worker.command({"command": "defer"})
                    self.assertEqual(worker.event("pending")["transfers"], [])
                    self.assertFalse(any(event["event"] == "error" for event in worker.observed))
                finally:
                    worker.close()

    def test_cancel_save_command_retains_buffer_and_removes_private_copy(self):
        with tempfile.TemporaryDirectory(prefix="airfrajer-save-flow-") as name:
            root = Path(name).resolve()
            destination = root / "chosen"
            destination.mkdir()
            release = root / "release-copy"
            # A test-only callback barrier makes command delivery deterministic,
            # independent of disk speed; the worker still uses real Inbox.save.
            setup = '''
from pathlib import Path
import time
from receiver.inbox import Inbox
save = Inbox.save
def paused_save(self, ident, destination, progress):
    def report(fields):
        progress(fields)
        if fields["bytes"]:
            deadline = time.monotonic() + 5
            while not Path(%r).exists():
                if time.monotonic() > deadline:
                    raise RuntimeError("test copy barrier timed out")
                time.sleep(0.01)
    return save(self, ident, destination, report)
Inbox.save = paused_save
''' % str(release)
            with (root / "worker.log").open("w") as log:
                worker = Worker(root / "state", log, setup=setup)
                try:
                    worker.event("pending")
                    ident = str(uuid.uuid4())
                    self.assertEqual(worker.post("/Ask", plistlib.dumps(request(ident)))[0], 200)
                    data = b"x" * (2 * 1024 * 1024)
                    self.assertEqual(worker.post("/Upload", dvzip(archive([("test.txt", data)])),
                                                 {"TransferID": ident, "Content-Type": "application/x-dvzip"})[0], 200)
                    downloaded = worker.event("downloaded")
                    worker.command({"command": "save", "id": downloaded["id"], "directory": str(destination)})
                    while worker.event("save_progress")["bytes"] == 0:
                        pass
                    worker.command({"command": "cancel_save", "id": downloaded["id"]})
                    worker.command({"command": "defer"})
                    worker.event("pending")  # Command reader has processed cancel_save.
                    release.touch()
                    canceled = worker.event("save_canceled")
                    canceled.pop("emitted_at")
                    self.assertEqual(canceled, dict(event="save_canceled", id=downloaded["id"]))
                    self.assertEqual(worker.event("pending")["transfers"][0]["id"], downloaded["id"])
                    self.assertEqual(Path(downloaded["paths"][0]).read_bytes(), data)
                    self.assertEqual(list(destination.iterdir()), [])
                    self.assertFalse(any(event["event"] == "error" for event in worker.observed))
                finally:
                    release.touch()
                    worker.close()

    def test_receive_then_defer_restart_and_choose_final_destination(self):
        with tempfile.TemporaryDirectory(prefix="airfrajer-flow-") as name:
            root = Path(name).resolve()
            destination = root / "chosen"
            destination.mkdir()
            (destination / "test.txt").write_bytes(b"existing file")
            state = root / "state"
            with (root / "worker.log").open("w") as log:
                worker = Worker(state, log)
                try:
                    worker.event("pending")
                    ident = str(uuid.uuid4())
                    self.assertEqual(worker.post("/Ask", plistlib.dumps(request(ident)))[0], 200)
                    incoming = worker.event("incoming")
                    payload = dvzip(archive([("NSIRD_AirDrop_test/test.txt", b"received content")]))
                    self.assertEqual(worker.post("/Upload", payload,
                                                 {"TransferID": ident, "Content-Type": "application/x-dvzip"})[0], 200)
                    downloaded = worker.event("downloaded")
                    self.assertEqual(downloaded["id"], incoming["id"])
                    self.assertEqual(list(destination.iterdir()), [destination / "test.txt"])
                    self.assertEqual(Path(downloaded["paths"][0]).read_bytes(), b"received content")
                    self.assertNotIn("offer", [event["event"] for event in worker.observed])
                    self.assertNotIn("complete", [event["event"] for event in worker.observed])
                    self.assertIn("progress", [event["event"] for event in worker.observed])
                    worker.command({"command": "defer", "id": downloaded["id"]})
                    self.assertEqual(worker.event("pending")["transfers"][0]["id"], downloaded["id"])
                finally:
                    worker.close()

                restored = Worker(state, log)
                try:
                    pending = restored.event("pending")["transfers"]
                    self.assertEqual(pending, [
                        {key: value for key, value in downloaded.items() if key not in ("event", "emitted_at", "latest_received_id")}
                    ])
                    restored.command({"command": "save", "id": downloaded["id"], "directory": str(destination)})
                    complete = restored.event("complete")
                    self.assertEqual(complete["paths"], [str(destination / "test (1).txt")])
                    self.assertEqual((destination / "test (1).txt").read_bytes(), b"received content")
                    self.assertEqual((destination / "test.txt").read_bytes(), b"existing file")
                    self.assertEqual(restored.event("pending")["transfers"], [])
                    self.assertFalse(Path(downloaded["paths"][0]).exists())
                    self.assertTrue(any(event["event"] == "save_progress" and event["bytes"] > 0
                                        for event in restored.observed))
                finally:
                    restored.close()
