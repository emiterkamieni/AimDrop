import plistlib
from pathlib import Path
import tempfile
import threading
import time
import unittest
import uuid

from receiver.inbox import Inbox
from receiver.main import SaveJobs
from receiver.retention import InboxMaintenance
from receiver.sessions import Refused, Sessions
from tests.fixtures import archive, dvzip, request
from tests.test_buffered_flow import Worker


class UpdateDrainTests(unittest.TestCase):
    def test_accepted_upload_survives_drain_and_new_offer_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Sessions(lambda *a, **kw: None, prepare_destination=lambda _: directory)
            peer = ("::1", 1234)
            transfer = str(uuid.uuid4())
            offer = session.offer(request(transfer), peer)
            session.drain(True)
            self.assertIs(session.offer(request(transfer), peer), offer)
            with self.assertRaises(Refused):
                session.offer(request(str(uuid.uuid4())), peer)
            self.assertIs(session.claim(transfer, peer), offer)
            self.assertFalse(offer.canceled.is_set())
            offer.storage.close()
            session.finish(offer)
            session.drain(False)
            self.assertIsNotNone(session.offer(request(str(uuid.uuid4())), peer))
            session.close()

    def test_picker_continuation_is_allowed_but_new_reservations_are_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = Inbox(Path(directory))
            ident = str(uuid.uuid4())
            payload = Path(inbox.prepare(ident))
            (payload / "file").write_bytes(b"preserved")
            inbox.record(ident, [payload / "file"], 1)
            token = inbox.reserve(ident, "hold", str(uuid.uuid4()))
            inbox.drain(True)
            self.assertIsNone(inbox.reserve(ident, "save"))
            self.assertIsNone(inbox.reserve(ident, "trash", "wrong"))
            self.assertTrue(inbox.has_reservations())
            self.assertEqual(inbox.reserve(ident, "save", token), token)
            inbox.release(ident, token)
            self.assertFalse(inbox.has_reservations())
            self.assertIsNone(inbox.reserve(ident, "hold"))
            inbox.drain(False)
            self.assertIsNotNone(inbox.reserve(ident, "hold"))

    def test_save_remains_busy_until_final_acknowledgement(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = Inbox(Path(directory) / "Incoming")
            ident = str(uuid.uuid4())
            payload = Path(inbox.prepare(ident))
            (payload / "file").write_bytes(b"saved")
            inbox.record(ident, [payload / "file"], 1)
            destination = Path(directory) / "Saved"
            destination.mkdir()
            entered, release = threading.Event(), threading.Event()
            def emit(event, **fields):
                if event == "complete":
                    entered.set()
                    release.wait(5)
            saves = SaveJobs(inbox, emit, threading.Event())
            try:
                self.assertTrue(saves.start(ident, str(destination)))
                self.assertTrue(entered.wait(5))
                self.assertFalse(inbox.has_reservations())
                self.assertTrue(saves.is_busy())
            finally:
                release.set()
                saves.close()
            self.assertFalse(saves.is_busy())
            self.assertEqual((destination / "file").read_bytes(), b"saved")

    def test_queued_trash_finishes_during_drain_but_expiry_cannot_start_more(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = Inbox(Path(directory) / "Incoming", clock=lambda: 1_800_000_000_000_000_000)
            ids = []
            for _ in range(2):
                ident = str(uuid.uuid4())
                payload = Path(inbox.prepare(ident))
                (payload / "file").write_bytes(b"retained")
                inbox.record(ident, [payload / "file"], 1)
                ids.append(ident)
            trash = Path(directory) / "Trash"
            maintenance = InboxMaintenance(inbox, lambda source, fd: source.rename(trash), lambda *a, **kw: None, threading.Event())
            self.assertTrue(maintenance.trash(ids[0]))
            inbox.drain(True); maintenance.drain(True)
            inbox.clock = lambda: 1_900_000_000_000_000_000
            maintenance.sweep()
            self.assertFalse(maintenance.trash(ids[1]))
            maintenance._perform(*maintenance.requests.get_nowait())
            self.assertEqual((trash / "file").read_bytes(), b"retained")
            self.assertEqual([r["id"] for r in inbox.list_ready()], [ids[1]])

    def test_actual_worker_drain_waits_for_accepted_transfer_and_preserves_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (root / "worker.log").open("w+") as log:
                worker = Worker(root / "state", log)
                try:
                    ident = str(uuid.uuid4())
                    self.assertEqual(worker.post("/Ask", plistlib.dumps(request(ident)))[0], 200)
                    correlation = str(uuid.uuid4())
                    worker.command(dict(command="prepare_update", request_id=correlation))
                    self.assertFalse(worker.event("update_status")["idle"])
                    status, _ = worker.post("/Ask", plistlib.dumps(request(str(uuid.uuid4()))))
                    self.assertNotEqual(status, 200)
                    body = dvzip(archive([("test.txt", b"survives update")]))
                    status, _ = worker.post("/Upload", body, {"Content-Type": "application/x-dvzip", "TransferID": ident})
                    self.assertEqual(status, 200)
                    receipt = worker.event("downloaded")
                    deadline = time.monotonic() + 5
                    while not worker.event("update_status")["idle"]:
                        self.assertLess(time.monotonic(), deadline)
                    worker.command(dict(command="shutdown_when_idle", request_id=correlation))
                    self.assertEqual(worker.event("shutdown_complete")["request_id"], correlation)
                    self.assertEqual(worker.process.wait(timeout=5), 0)
                    restored = Inbox(root / "state/Incoming")
                    self.assertEqual(restored.list_ready()[0]["id"], receipt["id"])
                    self.assertEqual(Path(restored.list_ready()[0]["paths"][0]).read_bytes(), b"survives update")
                finally:
                    worker.close()

    def test_worker_canceled_drain_resumes_receiving(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (root / "worker.log").open("w+") as log:
                worker = Worker(root / "state", log)
                try:
                    request_id = str(uuid.uuid4())
                    worker.command(dict(command="prepare_update", request_id=request_id))
                    self.assertTrue(worker.event("update_status")["idle"])
                    worker.command(dict(command="cancel_update", request_id=request_id))
                    worker.event("update_canceled")
                    status, _ = worker.post("/Ask", plistlib.dumps(request(str(uuid.uuid4()))))
                    self.assertEqual(status, 200)
                finally:
                    worker.close()
