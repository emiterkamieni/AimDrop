import http.client
import json
from pathlib import Path
import plistlib
import socket
import ssl
import subprocess
import sys
import tempfile
import unittest
import uuid

from receiver.configuration import normalized_receiver_name
from tests.fixtures import archive, request
from tests.test_buffered_flow import ROOT, Worker


class ReceiverNameValidationTests(unittest.TestCase):
    def test_unicode_nfc_and_only_ascii_edge_spaces_are_normalized(self):
        cases = [
            ("  Z\u0307o\u0301łw — 👩\u200d💻  ", "Żółw — 👩\u200d💻"),
            ("  Zażółć  gęślą jaźń  ", "Zażółć  gęślą jaźń"),
            (" \u00a0\u2003Odbiornik\u2003\u00a0 ", "\u00a0\u2003Odbiornik\u2003\u00a0"),
            ("\u00a0", "\u00a0"),
            ("👨\u200d👩\u200d👧\u200d👦", "👨\u200d👩\u200d👧\u200d👦"),
        ]
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertEqual(normalized_receiver_name(value), expected)

    def test_limit_is_utf8_bytes_after_normalization(self):
        for value in ("a", "a" * 128, "ą" * 64, "😀" * 32):
            with self.subTest(value=value):
                self.assertEqual(normalized_receiver_name(value), value)
        self.assertEqual(normalized_receiver_name("e\u0301" * 64), "é" * 64)
        self.assertEqual(normalized_receiver_name("  " + "a" * 128 + "  "), "a" * 128)
        for value in ("", "   ", "a" * 129, "ą" * 65, "😀" * 33):
            with self.subTest(value=value), self.assertRaises(ValueError) as error:
                normalized_receiver_name(value)
            self.assertEqual(str(error.exception),
                             "Nazwa odbiornika musi mieć od 1 do 128 bajtów UTF-8.")

    def test_non_strings_have_fixed_error(self):
        for value in (None, True, 12, 1.5, [], {}, b"Private name"):
            with self.subTest(value=value), self.assertRaises(ValueError) as error:
                normalized_receiver_name(value)
            self.assertEqual(str(error.exception), "Nazwa odbiornika musi być tekstem.")

    def test_all_disallowed_unicode_codepoints_are_rejected_without_echo(self):
        ranges = (range(0x20), range(0x7F, 0xA0), range(0x2028, 0x202F),
                  range(0x2066, 0x206A), range(0xD800, 0xE000))
        for codes in ranges:
            for code in codes:
                with self.subTest(code=hex(code)), self.assertRaises(ValueError) as error:
                    normalized_receiver_name("Private name" + chr(code) + "suffix")
                self.assertEqual(str(error.exception),
                                 "Nazwa odbiornika zawiera niedozwolone znaki.")
        for value in ("\tName", "Name\n", " Name\r "):
            with self.subTest(value=value), self.assertRaises(ValueError):
                normalized_receiver_name(value)


class ReceiverSettingsWorkerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="airfrajer-settings-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.log = (self.root / "worker.log").open("w")
        self.addCleanup(self.log.close)

    def start_worker(self, setup=None):
        worker = Worker(self.root / "state", self.log, setup=setup)
        self.addCleanup(worker.close)
        worker.event("pending")
        return worker

    def rename(self, worker, name, request_id=None):
        request_id = request_id or str(uuid.uuid4())
        worker.command(dict(command="set_name", request_id=request_id, name=name))
        result = worker.event("name_result")
        self.assertEqual(result["request_id"], request_id)
        result.pop("emitted_at")
        return result

    def discover(self, worker):
        status, body = worker.post("/Discover", plistlib.dumps({}))
        self.assertEqual(status, 200)
        return plistlib.loads(body)

    def test_startup_name_is_canonical_in_ready_and_discover(self):
        name = "  Z\u0307o\u0301łw 👩\u200d💻  "
        worker = self.start_worker(setup="sys.argv += ['--name', %r]" % name)
        ready = next(event for event in worker.observed if event["event"] == "ready")
        self.assertEqual(ready["name"], "Żółw 👩\u200d💻")
        self.assertEqual(self.discover(worker)["ReceiverComputerName"], ready["name"])
        self.assertNotIn("Żółw", (self.root / "worker.log").read_text())

    def test_startup_name_can_begin_with_hyphen_using_joined_option(self):
        worker = self.start_worker(setup="sys.argv += ['--name=-Studio']")
        self.assertEqual(self.discover(worker)["ReceiverComputerName"], "-Studio")

    def test_invalid_startup_names_fail_before_state_creation_without_echo(self):
        for index, name in enumerate(("Private\nname", "Private\u2028name", "Private\u202ename",
                                      "Private" + "x" * 128, "   ")):
            with self.subTest(index=index):
                state = self.root / ("invalid-%d" % index)
                result = subprocess.run([
                    sys.executable, "-I", "-B", "-u", str(ROOT / "receiver/main.py"),
                    "--state-dir", str(state), "--no-advertise", "--name", name,
                ], input="", capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                failure = json.loads(result.stdout)
                self.assertEqual(failure["event"], "error")
                self.assertIs(failure["fatal"], True)
                self.assertIn("Nazwa odbiornika", failure["message"])
                self.assertNotIn("Private", result.stdout + result.stderr)
                self.assertFalse(state.exists())

    def test_rename_updates_discover_and_ask_preserving_identity_and_capabilities(self):
        worker = self.start_worker()
        before = self.discover(worker)
        state = self.root / "state"
        identity = {name: (state / name).read_bytes()
                    for name in ("identity.json", "certificate.pem", "private-key.pem")}
        request_id = str(uuid.uuid4()).upper()  # Swift's UUID.uuidString is uppercase.
        result = self.rename(worker, "  Z\u0307o\u0301łw 👩\u200d💻  ", request_id)
        self.assertEqual(result, dict(event="name_result", request_id=request_id,
                                      ok=True, name="Żółw 👩\u200d💻"))
        self.assertEqual(self.discover(worker), dict(before, ReceiverComputerName=result["name"]))
        ident = str(uuid.uuid4())
        status, body = worker.post("/Ask", plistlib.dumps(request(ident)))
        self.assertEqual(status, 200)
        self.assertEqual(plistlib.loads(body), {
            "ReceiverComputerName": result["name"], "ReceiverModelName": before["ReceiverModelName"],
        })
        # A subsequent rename also reaches an Ask retry with the original consent.
        renamed = self.rename(worker, "Następny odbiornik")
        self.assertIs(renamed["ok"], True)
        status, body = worker.post("/Ask", plistlib.dumps(request(ident)))
        self.assertEqual(status, 200)
        self.assertEqual(plistlib.loads(body)["ReceiverComputerName"], renamed["name"])
        for name, contents in identity.items():
            self.assertEqual((state / name).read_bytes(), contents)
        self.assertEqual(len([event for event in worker.observed if event["event"] == "ready"]), 1)
        self.assertIsNone(worker.process.poll())
        logs = (self.root / "worker.log").read_text()
        self.assertNotIn("Żółw", logs)
        self.assertNotIn("Następny odbiornik", logs)

    def test_rejected_names_and_malformed_commands_keep_current_name_and_worker_alive(self):
        worker = self.start_worker()
        current = self.rename(worker, "Prywatny odbiornik")
        invalid = (None, 123, True, [], {}, "", " ", "x" * 129,
                   "Private\nname", "Private\u0085name", "Private\u2029name",
                   "Private\u2067name", "Private\ud800name", "Private\udfffname")
        for index, name in enumerate(invalid):
            with self.subTest(index=index):
                result = self.rename(worker, name)
                self.assertIs(result["ok"], False)
                self.assertEqual(result["name"], current["name"])
                self.assertIn("Nazwa odbiornika", result["message"])
                self.assertNotIn("Private", result["message"])
        # Missing name must be rejected through the same correlated contract.
        ident = str(uuid.uuid4())
        worker.command(dict(command="set_name", request_id=ident))
        missing = worker.event("name_result")
        self.assertEqual(missing["request_id"], ident)
        self.assertIs(missing["ok"], False)
        self.assertEqual(missing["name"], current["name"])
        results_before = sum(event["event"] == "name_result" for event in worker.observed)
        for bad_id in (None, True, 12, [], {}, "", "not-a-uuid", uuid.uuid4().hex,
                       "{" + str(uuid.uuid4()) + "}", str(uuid.uuid4()) + "\n"):
            worker.command(dict(command="set_name", request_id=bad_id, name="Must not apply"))
        worker.command(dict(command="set_name", name="Must not apply"))
        for malformed in (None, [], "text", True, 42):
            worker.command(malformed)
        worker.process.stdin.write("{broken JSON\n" + "[" * 2000 + "]" * 2000 + "\n")
        worker.process.stdin.flush()
        worker.command(dict(command="defer"))
        worker.event("pending")  # Command-reader barrier; no sleeps or queue timeouts.
        self.assertEqual(sum(event["event"] == "name_result" for event in worker.observed), results_before)
        self.assertEqual(self.discover(worker)["ReceiverComputerName"], current["name"])
        self.assertIs(self.rename(worker, "Działa dalej")["ok"], True)
        self.assertIsNone(worker.process.poll())
        logs = (self.root / "worker.log").read_text()
        self.assertNotIn("Private", logs)
        self.assertNotIn(current["name"], logs)
        self.assertFalse(any(event["event"] == "error" for event in worker.observed))

    def test_rename_during_paused_tls_upload_finishes_same_socket_with_identical_bytes(self):
        worker = self.start_worker()
        ident = str(uuid.uuid4())
        self.assertEqual(worker.post("/Ask", plistlib.dumps(request(ident)))[0], 200)
        incoming = worker.event("incoming")
        contents = bytes(range(256)) * 1024
        data = archive([("test.txt", contents)])
        first_block = 64 * 1024
        raw = socket.create_connection(("::1", worker.port), timeout=5)
        with ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost") as secure:
            headers = ("POST /Upload HTTP/1.1\r\nContent-Type: application/x-cpio\r\n"
                       "TransferID: %s\r\nContent-Length: %d\r\n\r\n" % (ident, len(data))).encode()
            secure.sendall(headers + data[:first_block])
            progress = worker.event("progress")
            self.assertEqual(progress["bytes"], first_block)
            self.assertEqual(progress["files_received"], 0)
            renamed = self.rename(worker, "Nowa nazwa 📥")
            self.assertIs(renamed["ok"], True)
            self.assertEqual(self.discover(worker)["ReceiverComputerName"], renamed["name"])
            self.assertFalse(any(event["event"] == "downloaded" for event in worker.observed))
            # The sender only releases the remaining payload after the rename ack.
            secure.sendall(data[first_block:])
            response = http.client.HTTPResponse(secure)
            response.begin()
            self.assertEqual(response.status, 200)
            response.read()
        downloaded = worker.event("downloaded")
        self.assertEqual(downloaded["id"], incoming["id"])
        self.assertEqual(Path(downloaded["paths"][0]).read_bytes(), contents)
        self.assertFalse(any(event["event"] in ("error", "canceled") for event in worker.observed))
        status, body = worker.post("/Ask", plistlib.dumps(request(str(uuid.uuid4()))))
        self.assertEqual(status, 200)
        self.assertEqual(plistlib.loads(body)["ReceiverComputerName"], renamed["name"])

    def test_rename_is_acknowledged_while_save_copy_is_blocked(self):
        release = self.root / "release-copy"
        setup = '''
from pathlib import Path
import time
from receiver.inbox import Inbox
save = Inbox.save
def paused_save(self, ident, destination, progress):
    def report(fields):
        progress(fields)
        if fields["bytes"]:
            deadline = time.monotonic() + 10
            while not Path(%r).exists():
                if time.monotonic() > deadline:
                    raise RuntimeError("test copy barrier timed out")
                time.sleep(0.01)
    return save(self, ident, destination, report)
Inbox.save = paused_save
''' % str(release)
        worker = self.start_worker(setup=setup)
        self.addCleanup(release.touch)
        destination = self.root / "chosen"
        destination.mkdir()
        ident = str(uuid.uuid4())
        self.assertEqual(worker.post("/Ask", plistlib.dumps(request(ident)))[0], 200)
        contents = bytes(range(256)) * 8192
        self.assertEqual(worker.post("/Upload", archive([("test.txt", contents)]),
                                     {"TransferID": ident, "Content-Type": "application/x-cpio"})[0], 200)
        downloaded = worker.event("downloaded")
        worker.command(dict(command="save", id=downloaded["id"], directory=str(destination)))
        while worker.event("save_progress")["bytes"] == 0:
            pass
        try:
            renamed = self.rename(worker, "Podczas zapisu")
            self.assertIs(renamed["ok"], True)
            self.assertEqual(self.discover(worker)["ReceiverComputerName"], renamed["name"])
            self.assertFalse(any(event["event"] == "complete" for event in worker.observed))
            self.assertEqual(Path(downloaded["paths"][0]).read_bytes(), contents)
        finally:
            release.touch()
        self.assertEqual(worker.event("complete")["id"], downloaded["id"])
        self.assertEqual((destination / "test.txt").read_bytes(), contents)
        self.assertEqual(worker.event("pending")["transfers"], [])
