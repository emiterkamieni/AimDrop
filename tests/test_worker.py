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
import unittest
from unittest import mock
import uuid

from tests.fixtures import archive, request
from tests.test_buffered_flow import Worker

ROOT = Path(__file__).resolve().parents[1]


class WorkerLifecycleTests(unittest.TestCase):
    def test_ready_and_tls_discover_do_not_require_reverse_dns(self):
        setup = '''
import socket
def unavailable_resolver(*args, **kwargs):
    raise AssertionError("worker startup attempted hostname resolution")
socket.getfqdn = unavailable_resolver
socket.gethostbyaddr = unavailable_resolver
'''
        with tempfile.TemporaryDirectory(prefix="airfrajer-worker-dns-") as name:
            root = Path(name)
            with (root / "worker.log").open("w") as log:
                worker = Worker(root / "state", log, setup=setup)
                try:
                    worker.event("pending")
                    status, data = worker.post("/Discover", plistlib.dumps({}))
                    self.assertEqual(status, 200)
                    self.assertEqual(plistlib.loads(data)["ReceiverComputerName"], "AimDrop")
                finally:
                    worker.close()
                self.assertEqual(worker.process.returncode, 0)

    def test_startup_failure_reports_phase_and_reaps_child(self):
        setup = '''
from receiver import main
def failed_model_probe():
    raise RuntimeError("controlled hardware model failure")
main.hardware_model = failed_model_probe
'''
        spawned = []
        popen = subprocess.Popen
        def spawn(*args, **kwargs):
            process = popen(*args, **kwargs)
            spawned.append(process)
            return process

        with tempfile.TemporaryDirectory(prefix="airfrajer-worker-failure-") as name:
            root = Path(name)
            with (root / "worker.log").open("w") as log, \
                    mock.patch("tests.test_buffered_flow.subprocess.Popen", side_effect=spawn):
                with self.assertRaises(AssertionError) as error:
                    Worker(root / "state", log, setup=setup)
            detail = str(error.exception)
            self.assertIn("Worker exited waiting for ready", detail)
            self.assertIn("Receiver startup: hardware model", detail)
            self.assertIn("controlled hardware model failure", detail)
            self.assertNotIn("Receiver startup: HTTPS listener", detail)
            self.assertEqual(len(spawned), 1)
            self.assertIsNotNone(spawned[0].returncode)
            self.assertTrue(spawned[0].stdin.closed)
            self.assertTrue(spawned[0].stdout.closed)

    def test_ui_eof_during_upload_cleans_partial_files(self):
        with tempfile.TemporaryDirectory(prefix="airfrajer-worker-") as name:
            root = Path(name)
            chosen = root / "chosen"
            chosen.mkdir()
            with (root / "worker.log").open("w+") as log:
                process = subprocess.Popen([
                    sys.executable, "-I", "-B", "-u", str(ROOT / "receiver/main.py"),
                    "--state-dir", str(root / "state"), "--no-advertise", "--manual-consent",
                ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
                events = queue.Queue()
                def read():
                    for line in process.stdout:
                        events.put(json.loads(line))
                thread = threading.Thread(target=read, daemon=True)
                thread.start()
                def event(kind):
                    while True:
                        try:
                            message = events.get(timeout=10)
                        except queue.Empty:
                            log.seek(0)
                            self.fail("Timed out waiting for %s:\n%s" % (kind, log.read()))
                        if message["event"] == kind:
                            return message
                secure = None
                ask = None
                try:
                    ready = event("ready")
                    ident = str(uuid.uuid4())
                    ask = http.client.HTTPSConnection("::1", ready["port"], timeout=5,
                                                     context=ssl._create_unverified_context())
                    ask.request("POST", "/Ask", plistlib.dumps(request(ident, "partial.bin")))
                    offer = event("offer")
                    process.stdin.write(json.dumps({"command": "decision", "id": offer["id"],
                                                     "accept": True, "directory": str(chosen)}) + "\n")
                    process.stdin.flush()
                    response = ask.getresponse()
                    self.assertEqual(response.status, 200)
                    response.read()
                    ask.close()
                    data = archive([("partial.bin", b"x" * 250000)])
                    raw = socket.create_connection(("::1", ready["port"]), timeout=5)
                    secure = ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost")
                    headers = ("POST /Upload HTTP/1.1\r\nContent-Type: application/x-cpio\r\n"
                               "TransferID: %s\r\nContent-Length: %d\r\n\r\n" % (ident, len(data))).encode()
                    secure.sendall(headers + data[:100000])
                    progress = event("progress")
                    self.assertEqual(progress["files_received"], 0)
                    self.assertEqual(progress["total_files"], 1)
                    self.assertEqual(progress["total_bytes"], len(data))
                    process.stdin.close()  # UI crash/exit, while the phone's upload socket stays open
                    self.assertEqual(process.wait(timeout=10), 0)
                    self.assertEqual(list(chosen.iterdir()), [])
                finally:
                    if secure:
                        secure.close()
                    if ask:
                        ask.close()
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    if not process.stdin.closed:
                        process.stdin.close()
                    thread.join(timeout=2)
                    process.stdout.close()
