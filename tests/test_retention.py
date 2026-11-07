import fcntl
import json
import os
import plistlib
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

from receiver.inbox import Inbox
from receiver.retention import DAY_NS, InboxMaintenance
from tests.fixtures import archive, dvzip, request
from tests.test_buffered_flow import Worker


class RetentionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="aimdrop-retention-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.now = 1_800_000_000_000_000_000
        self.inbox = Inbox(self.root / "Incoming", clock=lambda: self.now)
        self.trash = self.root / "Trash"
        self.trash.mkdir()
        self.events = []
        self.stopped = threading.Event()
        self.maintenance = InboxMaintenance(self.inbox, self.move, self.emit, self.stopped)

    def emit(self, kind, **fields):
        self.events.append(dict(event=kind, **fields))

    def move(self, source, fd):
        self.assertGreaterEqual(fd, 0)
        os.rename(source, self.trash / source.name)

    def ready(self):
        ident = str(uuid.uuid4())
        payload = Path(self.inbox.prepare(ident))
        (payload / "example.txt").write_bytes(b"keep every byte")
        return self.inbox.record(ident, [payload / "example.txt"], 1)

    def perform_next(self):
        self.maintenance._perform(*self.maintenance.requests.get_nowait())

    def test_days_apply_only_to_future_receipts_even_while_automatic_deletion_is_off(self):
        old = self.ready()
        self.now += DAY_NS
        self.inbox.configure_retention(3, False)
        new = self.ready()
        self.assertEqual(old["expires_at_ns"], old["received_at_ns"] + 7 * DAY_NS)
        self.assertEqual(new["expires_at_ns"], new["received_at_ns"] + 3 * DAY_NS)
        self.now += 10 * DAY_NS
        self.maintenance.sweep()
        self.assertTrue(self.maintenance.requests.empty())
        restored = Inbox(self.inbox.root, days=30, automatic_trash=False, clock=lambda: self.now)
        self.assertEqual({r["id"]: r for r in restored.list_ready()}, {r["id"]: r for r in (old, new)})
        self.inbox.configure_retention(30, True)
        self.maintenance.sweep()
        self.perform_next()
        self.perform_next()
        self.assertEqual(self.inbox.list_ready(), [])
        self.assertEqual(len(list(self.trash.iterdir())), 2)

    def test_legacy_receipts_get_one_grace_period_and_keep_original_receive_time(self):
        ident = str(uuid.uuid4())
        legacy_root = self.root / "Legacy"
        job = legacy_root / ident
        (job / "payload").mkdir(parents=True)
        (job / "payload/file.txt").write_text("old")
        original = self.now - 100 * DAY_NS
        (job / "ready.json").write_text(json.dumps(dict(count=1, files=["file.txt"], received_at_ns=original)))
        first = Inbox(legacy_root, clock=lambda: self.now).list_ready()[0]
        self.assertEqual(first["received_at_ns"], original)
        self.assertEqual(first["expires_at_ns"], self.now + 7 * DAY_NS)
        self.now += 3 * DAY_NS
        second = Inbox(legacy_root, days=20, clock=lambda: self.now).list_ready()[0]
        self.assertEqual(first, second)

    def test_trash_failure_retains_original_receipt_and_contents(self):
        receipt = self.ready()
        def fail(source, fd):
            raise PermissionError("denied")
        with self.assertRaises(PermissionError):
            self.inbox.trash(receipt["id"], fail)
        self.assertEqual(self.inbox.list_ready(), [receipt])
        self.assertEqual(Path(receipt["paths"][0]).read_bytes(), b"keep every byte")
        self.assertFalse((self.inbox.root / receipt["id"] / "trash.json").exists())

    def test_lost_helper_reply_after_move_does_not_resurrect_receipt(self):
        receipt = self.ready()
        def lost_reply(source, fd):
            self.move(source, fd)
            raise OSError("reply lost")
        self.inbox.trash(receipt["id"], lost_reply)
        self.assertEqual(Inbox(self.inbox.root).list_ready(), [])
        self.assertEqual(next(self.trash.iterdir()).joinpath("example.txt").read_bytes(), b"keep every byte")

    def test_failed_retirement_after_move_is_reconciled_with_terminal_event(self):
        receipt = self.ready()
        self.assertTrue(self.maintenance.trash(receipt["id"]))
        with patch.object(self.inbox, "_retire", side_effect=OSError("metadata unavailable")):
            self.perform_next()
        self.assertTrue(any(e["event"] == "error" for e in self.events))
        self.maintenance.sweep()
        self.assertTrue(any(e["event"] == "trashed" and e["id"] == receipt["id"] for e in self.events))
        self.assertEqual(self.inbox.list_ready(), [])
        self.assertEqual(next(self.trash.iterdir()).joinpath("example.txt").read_bytes(), b"keep every byte")

    def test_missing_payload_is_not_reported_as_successful_trash(self):
        receipt = self.ready()
        job = self.inbox.root / receipt["id"]
        os.rename(job / "payload", self.root / "moved-externally")
        with self.assertRaises(FileNotFoundError):
            self.inbox.trash(receipt["id"], self.move)
        self.assertTrue((job / "ready.json").exists())
        self.assertFalse((job / "retired.json").exists())
        self.assertFalse((job / "trash.json").exists())

    def stage_interruption(self):
        receipt = self.ready()
        job = self.inbox.root / receipt["id"]
        source = job / ("AimDrop interrupted " + receipt["id"])
        (job / "trash.json").write_text(json.dumps(dict(folder=source.name)))
        os.rename(job / "payload", source)
        return receipt, job, source

    def test_restart_recovers_unfinished_trash_and_recognizes_completed_move(self):
        receipt, job, source = self.stage_interruption()
        self.assertEqual(Inbox(self.inbox.root).list_ready(), [receipt])
        self.assertTrue((job / "payload/example.txt").exists())
        receipt2, job2, source2 = self.stage_interruption()
        os.rename(source2, self.trash / source2.name)
        recovered = Inbox(self.inbox.root)
        self.assertEqual(recovered.list_ready(), [receipt])
        recovered.cleanup_retired()
        self.assertFalse(job2.exists())

    def test_recovery_waits_for_inherited_operation_lock(self):
        receipt, job, source = self.stage_interruption()
        fd = os.open(job / ".operation.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            recovered = Inbox(self.inbox.root)
            self.assertEqual(recovered.list_ready(), [])
            self.assertTrue(source.exists())
        finally:
            os.close(fd)
        recovered.recover_operations()
        self.assertEqual(recovered.list_ready(), [receipt])

    def test_expiry_skips_picker_and_save_reservations_until_released(self):
        receipt = self.ready()
        ident = receipt["id"]
        request = str(uuid.uuid4())
        token = self.inbox.reserve(ident, "hold", request)
        self.assertEqual(token, request)
        self.now = receipt["expires_at_ns"]
        self.maintenance.sweep()
        self.assertTrue(self.maintenance.requests.empty())
        self.assertIsNone(self.inbox.reserve(ident, "save", "wrong-token"))
        self.assertEqual(self.inbox.reserve(ident, "save", token), token)
        self.maintenance.sweep()
        self.assertTrue(self.maintenance.requests.empty())
        self.inbox.release(ident, "wrong-token")
        self.assertFalse(self.maintenance.trash(ident))
        self.inbox.release(ident, token)
        self.maintenance.sweep()
        self.perform_next()
        self.assertEqual(self.inbox.list_ready(), [])

    def test_disabling_automatic_deletion_cancels_already_queued_expiry(self):
        receipt = self.ready()
        self.now = receipt["expires_at_ns"]
        self.maintenance.sweep()
        self.inbox.configure_retention(7, False)
        self.perform_next()
        self.assertEqual(self.inbox.list_ready(), [receipt])
        self.assertTrue(any(e["event"] == "trash_canceled" for e in self.events))
        self.assertIsNotNone(self.inbox.reserve(receipt["id"], "hold"))

    def test_bulk_trash_reserves_snapshot_and_skips_busy_or_missing_transfers(self):
        first, second, busy = self.ready(), self.ready(), self.ready()
        token = self.inbox.reserve(busy["id"], "save")
        missing = str(uuid.uuid4())
        result = self.maintenance.trash_many([first["id"], busy["id"], second["id"], first["id"], missing])
        self.assertEqual(result, dict(started=[first["id"], second["id"]], skipped=[busy["id"], missing]))
        arriving = self.ready()
        self.perform_next(); self.perform_next()
        self.inbox.release(busy["id"], token)
        self.assertEqual({x["id"] for x in self.inbox.list_ready()}, {busy["id"], arriving["id"]})
        self.assertEqual(len(list(self.trash.iterdir())), 2)

    def test_invalid_bulk_command_does_not_start_any_deletion(self):
        receipt = self.ready()
        for ids in ([receipt["id"], "invalid"], [], [receipt["id"]] * 513, None):
            with self.subTest(ids_count=len(ids) if isinstance(ids, list) else None):
                with self.assertRaises(ValueError):
                    self.maintenance.trash_many(ids)
                self.assertTrue(self.maintenance.requests.empty())
                self.assertEqual(self.inbox.list_ready(), [receipt])

    def test_partial_metadata_is_not_expired_or_rewritten(self):
        receipt = self.ready()
        marker = self.inbox.root / receipt["id"] / "ready.json"
        value = json.loads(marker.read_text())
        value.pop("expires_at_ns")
        marker.write_text(json.dumps(value))
        self.now += 30 * DAY_NS
        self.maintenance.sweep()
        self.assertTrue(self.maintenance.requests.empty())
        self.assertTrue(Path(receipt["paths"][0]).exists())
        self.assertEqual(json.loads(marker.read_text()), value)

    def test_failed_cleanup_of_saved_payload_is_retried_without_reoffering(self):
        receipt = self.ready()
        destination = self.root / "Saved"
        destination.mkdir()
        with patch("receiver.inbox.shutil.rmtree", side_effect=PermissionError("busy")):
            self.inbox.save(receipt["id"], str(destination))
        job = self.inbox.root / receipt["id"]
        self.assertTrue((job / "retired.json").exists())
        self.assertTrue((job / "payload/example.txt").exists())
        self.assertEqual(self.inbox.list_ready(), [])
        restored = Inbox(self.inbox.root)
        restored.cleanup_retired()
        self.assertFalse(job.exists())
        self.assertEqual((destination / "example.txt").read_bytes(), b"keep every byte")


class InboxCommandTests(unittest.TestCase):
    def test_live_policy_holds_independent_save_trash_and_restart(self):
        with tempfile.TemporaryDirectory(prefix="aimdrop-inbox-ipc-") as temporary:
            root = Path(temporary).resolve()
            state = root / "State"
            inbox = Inbox(state / "Incoming")
            identities = [str(uuid.uuid4()) for _ in range(2)]
            for ident in identities:
                payload = Path(inbox.prepare(ident))
                (payload / "file.txt").write_text(ident)
                inbox.record(ident, [payload / "file.txt"], 1)
            destination, trash = root / "Saved", root / "Trash"
            destination.mkdir(); trash.mkdir()
            setup = ("import os\nimport receiver.trash\n"
                     "receiver.trash.MacTrash.__call__ = lambda self, source, fd: os.rename(source, %r + '/' + source.name)"
                     % str(trash))
            with (root / "worker.log").open("w") as log:
                worker = Worker(state, log, setup=setup)
                try:
                    initial = worker.event("pending")
                    self.assertTrue(initial["initial"])
                    self.assertEqual({x["id"] for x in initial["transfers"]}, set(identities))
                    policy = str(uuid.uuid4())
                    worker.command(dict(command="set_retention", request_id=policy, days=1, enabled=False))
                    self.assertEqual(worker.event("retention_result")["request_id"], policy)
                    hold = str(uuid.uuid4())
                    worker.command(dict(command="hold_transfer", id=identities[0], request_id=hold))
                    held = worker.event("hold_result")
                    self.assertTrue(held["ok"])
                    self.assertEqual(held["token"], hold)
                    deletion = str(uuid.uuid4())
                    worker.command(dict(command="trash_many", ids=identities, request_id=deletion))
                    replies = {}
                    while not {"trash_many_result", "trashed", "pending"}.issubset(replies):
                        event = worker.events.get(timeout=10)
                        self.assertIsNotNone(event)
                        self.assertNotEqual(event["event"], "error", event)
                        replies[event["event"]] = event
                    self.assertEqual(replies["trash_many_result"]["request_id"], deletion)
                    self.assertEqual(replies["trash_many_result"]["started"], [identities[1]])
                    self.assertEqual(replies["trash_many_result"]["skipped"], [identities[0]])
                    self.assertEqual(replies["trashed"]["id"], identities[1])
                    self.assertEqual([x["id"] for x in replies["pending"]["transfers"]], [identities[0]])
                    worker.command(dict(command="save", id=identities[0], token=hold, directory=str(destination)))
                    self.assertEqual(worker.event("complete")["id"], identities[0])
                    self.assertEqual(worker.event("pending")["transfers"], [])
                    transfer = str(uuid.uuid4())
                    self.assertEqual(worker.post("/Ask", plistlib.dumps(request(transfer)))[0], 200)
                    payload = dvzip(archive([("NSIRD_AirDrop_fixture/test.txt", b"new receipt")]))
                    self.assertEqual(worker.post("/Upload", payload, {"TransferID": transfer, "Content-Type": "application/x-dvzip"})[0], 200)
                    downloaded = worker.event("downloaded")
                    self.assertEqual(downloaded["retention_days"], 1)
                finally:
                    worker.close()
                restored = Worker(state, log, setup=setup)
                try:
                    pending = restored.event("pending")["transfers"]
                    self.assertEqual(len(pending), 1)
                    self.assertEqual(pending[0]["id"], downloaded["id"])
                    self.assertEqual(pending[0]["expires_at_ns"], downloaded["expires_at_ns"])
                    self.assertEqual((destination / "file.txt").read_text(), identities[0])
                    self.assertEqual(next(trash.iterdir()).joinpath("file.txt").read_text(), identities[1])
                finally:
                    restored.close()
