from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import queue
import tempfile
import threading
import unittest
from unittest import mock
import uuid

from receiver.inbox import Inbox
from receiver.main import SaveJobs


class SaveJobTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="airfrajer-save-jobs-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.inbox = Inbox(self.root / "Incoming")
        self.destination = self.root / "chosen"
        self.destination.mkdir()
        self.events = queue.Queue()
        self.observed = []
        self.stopped = threading.Event()
        self.jobs = SaveJobs(self.inbox, self.emit, self.stopped)
        self.addCleanup(self.jobs.close)

    def emit(self, event, **fields):
        item = dict(event=event, **fields)
        self.observed.append(item)
        self.events.put(item)

    def event(self, kind):
        while True:
            event = self.events.get(timeout=5)
            if event["event"] == "error":
                self.fail(event["message"])
            if event["event"] == kind:
                return event

    def ready(self, content=b"data" * (512 * 1024)):
        ident = str(uuid.uuid4())
        payload = Path(self.inbox.prepare(ident))
        path = payload / "file.bin"
        path.write_bytes(content)
        info = self.inbox.record(ident, [path], 1)
        return ident, path, info

    def paused_copy(self, ident):
        copying = threading.Event()
        release = threading.Event()
        self.addCleanup(release.set)
        def emit(event, **fields):
            self.emit(event, **fields)
            if (event == "save_progress" and fields["id"] == ident and fields["bytes"]
                    and not copying.is_set()):
                copying.set()
                if not release.wait(timeout=5):
                    raise RuntimeError("test timed out")
        self.jobs.emit = emit
        self.assertTrue(self.jobs.start(ident, str(self.destination)))
        self.assertTrue(copying.wait(timeout=3))
        return release

    def test_cancel_cleans_private_copy_retains_ready_originals_and_allows_retry(self):
        ident, path, info = self.ready()
        original = path.read_bytes()
        release = self.paused_copy(ident)
        self.assertTrue(any(entry.name.startswith(".airfrajer-") for entry in self.destination.iterdir()))
        self.assertFalse(self.jobs.start(ident, str(self.destination)))
        self.assertFalse(self.jobs.cancel(str(uuid.uuid4())))
        self.assertTrue(self.jobs.cancel(ident))
        release.set()
        self.assertEqual(self.event("save_canceled"), dict(event="save_canceled", id=ident))
        self.assertEqual(self.event("pending")["transfers"], [info])
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(list(self.destination.iterdir()), [])
        self.assertFalse(self.jobs.cancel(ident))
        self.assertTrue(self.jobs.start(ident, str(self.destination)))
        self.assertEqual(self.event("complete")["id"], ident)
        self.assertEqual((self.destination / "file.bin").read_bytes(), original)
        self.assertFalse(path.exists())
        self.assertFalse(any(event["event"] == "error" for event in self.observed))

    def test_cancel_does_not_affect_other_concurrent_save(self):
        first, path, info = self.ready()
        second, second_path, _ = self.ready(b"other job")
        release = self.paused_copy(first)
        self.assertTrue(self.jobs.start(second, str(self.destination)))
        self.assertTrue(self.jobs.cancel(first))
        self.assertEqual(self.event("complete")["id"], second)
        release.set()
        self.assertEqual(self.event("save_canceled")["id"], first)
        self.assertEqual(self.event("pending")["transfers"], [info])
        self.assertTrue(path.exists())
        self.assertFalse(second_path.exists())
        self.assertEqual((self.destination / "file.bin").read_bytes(), b"other job")
        self.assertEqual(list(self.destination.iterdir()), [self.destination / "file.bin"])

    def test_shutdown_cancels_copy_and_joins_without_error_or_lost_buffer(self):
        ident, path, info = self.ready()
        release = self.paused_copy(ident)
        with ThreadPoolExecutor(max_workers=1) as pool:
            closed = pool.submit(self.jobs.close)
            self.assertTrue(self.stopped.wait(timeout=2))
            release.set()
            closed.result(timeout=3)
        self.assertEqual(self.jobs.jobs, {})
        self.assertEqual(self.inbox.list_ready(), [info])
        self.assertTrue(path.exists())
        self.assertEqual(list(self.destination.iterdir()), [])
        self.assertFalse(any(event["event"] in ("complete", "error") for event in self.observed))
        self.assertFalse(self.jobs.start(ident, str(self.destination)))

    def test_cancel_after_publication_commit_reports_completion(self):
        ident, path, _ = self.ready(b"committed")
        from receiver.archive import ReceiveDirectory
        publish = ReceiveDirectory.publish
        def commit_then_cancel(directory):
            result = publish(directory)
            self.assertTrue(self.jobs.cancel(ident))
            return result
        with mock.patch.object(ReceiveDirectory, "publish", commit_then_cancel):
            self.jobs.start(ident, str(self.destination))
            self.assertEqual(self.event("complete")["id"], ident)
            self.event("pending")
        self.assertFalse(path.exists())
        self.assertEqual((self.destination / "file.bin").read_bytes(), b"committed")
        self.assertFalse(any(event["event"] in ("save_canceled", "error") for event in self.observed))
