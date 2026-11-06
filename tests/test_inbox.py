from concurrent.futures import ThreadPoolExecutor
import errno
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

from receiver.archive import rename_exclusive
from receiver.inbox import Inbox


class InboxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="airfrajer-inbox-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.inbox = Inbox(self.root / "inbox")
        self.destination = self.root / "saved"
        self.destination.mkdir()
        self.ident = str(uuid.uuid4())

    def ready(self, contents=None):
        contents = contents if contents is not None else {"photo.jpg": b"photo bytes"}
        payload = Path(self.inbox.prepare(self.ident))
        for name, data in contents.items():
            path = payload / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if data is None:
                path.mkdir()
            else:
                path.write_bytes(data)
        paths = sorted(payload.iterdir())
        count = sum(data is not None for data in contents.values())
        info = self.inbox.record(self.ident, paths, count)
        return payload, info

    def test_ready_download_restores_after_restart_and_remains_saveable(self):
        payload, info = self.ready()
        incomplete = str(uuid.uuid4())
        self.inbox.prepare(incomplete)
        restored = Inbox(self.inbox.root)
        self.assertEqual(restored.list_ready(), [info])
        self.assertEqual(info, dict(id=self.ident, count=1, files=["photo.jpg"],
                                   paths=[str(payload / "photo.jpg")]))
        result = restored.save(self.ident, str(self.destination))
        self.assertEqual(result["paths"], [str(self.destination / "photo.jpg")])
        self.assertEqual((self.destination / "photo.jpg").read_bytes(), b"photo bytes")
        self.assertFalse(payload.parent.exists())
        self.assertEqual(Inbox(self.inbox.root).list_ready(), [])

    def test_copy_preserves_bytes_nested_and_empty_directories_and_progress(self):
        binary = bytes(range(256)) * 5000
        contents = {"Album/subfolder/photo.bin": binary, "Album/empty-dir": None,
                    "empty.txt": b"", "same-bytes.bin": binary}
        payload, info = self.ready(contents)
        events = []
        result = self.inbox.save(self.ident, str(self.destination), events.append)
        for name, data in contents.items():
            if data is None:
                self.assertTrue((self.destination / name).is_dir())
            else:
                self.assertEqual((self.destination / name).read_bytes(), data)
        self.assertEqual(result, dict(id=self.ident, count=3, directory=str(self.destination),
                                     paths=[str(self.destination / name) for name in info["files"]]))
        self.assertEqual(events[0], dict(bytes=0, total_bytes=len(binary) * 2,
                                         files_received=0, total_files=3))
        self.assertEqual(events[-1], dict(bytes=len(binary) * 2, total_bytes=len(binary) * 2,
                                          files_received=3, total_files=3))
        self.assertEqual([event["bytes"] for event in events], sorted(event["bytes"] for event in events))
        self.assertFalse(payload.parent.exists())

    def test_collisions_keep_existing_files_and_directories_and_return_final_names(self):
        self.ready({"photo.jpg": b"new photo", "Album/nested.txt": b"new nested"})
        (self.destination / "photo.jpg").write_bytes(b"original")
        (self.destination / "photo (1).jpg").write_bytes(b"previous copy")
        (self.destination / "Album").mkdir()
        (self.destination / "Album/keep.txt").write_bytes(b"keep")
        result = self.inbox.save(self.ident, str(self.destination))
        self.assertEqual((self.destination / "photo.jpg").read_bytes(), b"original")
        self.assertEqual((self.destination / "photo (1).jpg").read_bytes(), b"previous copy")
        self.assertEqual((self.destination / "photo (2).jpg").read_bytes(), b"new photo")
        self.assertEqual((self.destination / "Album/keep.txt").read_bytes(), b"keep")
        self.assertFalse((self.destination / "Album/nested.txt").exists())
        self.assertEqual((self.destination / "Album (1)/nested.txt").read_bytes(), b"new nested")
        self.assertEqual(result["paths"], [str(self.destination / "Album (1)"),
                                           str(self.destination / "photo (2).jpg")])

    def test_invalid_destination_retains_ready_buffer_for_later_save(self):
        payload, info = self.ready()
        not_directory = self.root / "file.txt"
        not_directory.write_bytes(b"existing")
        for destination in (self.root / "missing", not_directory):
            with self.subTest(destination=destination), self.assertRaises((OSError, ValueError)):
                self.inbox.save(self.ident, str(destination))
            self.assertEqual(Inbox(self.inbox.root).list_ready(), [info])
            self.assertEqual((payload / "photo.jpg").read_bytes(), b"photo bytes")
        self.inbox.save(self.ident, str(self.destination))

    def test_abandon_deletes_incomplete_jobs_but_never_ready_downloads(self):
        payload, info = self.ready()
        restored = Inbox(self.inbox.root)
        restored.abandon(self.ident)
        self.assertEqual(restored.list_ready(), [info])
        self.assertTrue((payload / "photo.jpg").is_file())
        incomplete = str(uuid.uuid4())
        unfinished = Path(restored.prepare(incomplete))
        (unfinished / "partial").write_bytes(b"unfinished")
        restored.abandon(incomplete)
        self.assertFalse(unfinished.parent.exists())
        restored.abandon(incomplete)
        with self.assertRaises(FileExistsError):
            restored.prepare(self.ident)
        self.assertEqual(restored.list_ready(), [info])

    def test_self_destination_and_symlink_alias_are_rejected(self):
        payload, info = self.ready()
        alias = self.root / "alias"
        alias.symlink_to(payload, target_is_directory=True)
        for destination in (self.inbox.root, payload.parent, payload, alias):
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                self.inbox.save(self.ident, str(destination))
        self.assertEqual(self.inbox.list_ready(), [info])
        self.assertEqual((payload / "photo.jpg").read_bytes(), b"photo bytes")

    def test_save_rejects_cached_file_and_directory_symlinks(self):
        payload, info = self.ready({"Album/photo.jpg": b"photo bytes"})
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret").write_bytes(b"outside data")
        link = payload / "Album/link"
        for target in (outside / "secret", outside):
            link.symlink_to(target)
            with self.subTest(target=target), self.assertRaises(ValueError):
                self.inbox.save(self.ident, str(self.destination))
            link.unlink()
            self.assertEqual(list(self.destination.iterdir()), [])
            self.assertEqual(self.inbox.list_ready(), [info])

    def test_self_destination_with_alternate_case_is_rejected_on_mac_volumes(self):
        payload, info = self.ready()
        alias = self.inbox.root.with_name(self.inbox.root.name.upper())
        if not alias.exists():
            self.skipTest("Case-sensitive volume")
        with self.assertRaises(ValueError):
            self.inbox.save(self.ident, str(alias / self.ident / "payload"))
        self.assertEqual(self.inbox.list_ready(), [info])
        self.assertEqual((payload / "photo.jpg").read_bytes(), b"photo bytes")

    def test_copy_failure_cleans_staging_and_retains_ready_download(self):
        payload, info = self.ready()

        def interrupted(event):
            if event["bytes"]:
                raise OSError("copy interrupted")

        with self.assertRaisesRegex(OSError, "copy interrupted"):
            self.inbox.save(self.ident, str(self.destination), interrupted)
        self.assertEqual(list(self.destination.iterdir()), [])
        self.assertEqual(Inbox(self.inbox.root).list_ready(), [info])
        self.assertEqual((payload / "photo.jpg").read_bytes(), b"photo bytes")

    def test_partial_publication_reports_written_paths_and_keeps_entire_buffer(self):
        payload, info = self.ready({"a.txt": b"first", "b.txt": b"second"})

        def fail_second(source_fd, source, target_fd, target):
            if source == "b.txt":
                raise OSError(errno.EIO, "publication failed")
            return rename_exclusive(source_fd, source, target_fd, target)

        with patch("receiver.archive.rename_exclusive", side_effect=fail_second):
            with self.assertRaises(RuntimeError) as caught:
                self.inbox.save(self.ident, str(self.destination))
        self.assertIn(str(self.destination / "a.txt"), str(caught.exception))
        self.assertEqual(list(self.destination.iterdir()), [self.destination / "a.txt"])
        self.assertEqual((payload / "a.txt").read_bytes(), b"first")
        self.assertEqual((payload / "b.txt").read_bytes(), b"second")
        self.assertEqual(Inbox(self.inbox.root).list_ready(), [info])
        result = self.inbox.save(self.ident, str(self.destination))
        self.assertEqual(result["paths"], [str(self.destination / "a (1).txt"),
                                           str(self.destination / "b.txt")])
        self.assertEqual((self.destination / "a.txt").read_bytes(), b"first")

    def test_shutdown_callback_before_publication_keeps_ready_originals(self):
        payload, info = self.ready()
        completed = []

        def shutdown(event):
            if event["files_received"] == event["total_files"]:
                completed.append(event)
                if len(completed) == 2:
                    raise RuntimeError("shutting down")

        with self.assertRaisesRegex(RuntimeError, "shutting down"):
            self.inbox.save(self.ident, str(self.destination), shutdown)
        self.assertEqual(list(self.destination.iterdir()), [])
        self.assertEqual(Inbox(self.inbox.root).list_ready(), [info])
        self.assertEqual((payload / "photo.jpg").read_bytes(), b"photo bytes")

    def test_concurrent_saves_publish_a_job_only_once(self):
        self.ready()
        barrier = threading.Barrier(2)

        def save():
            barrier.wait(timeout=5)
            try:
                return self.inbox.save(self.ident, str(self.destination))
            except FileNotFoundError:
                return None

        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(save) for _ in range(2)]
            results = [future.result(timeout=5) for future in futures]
        self.assertEqual(sum(result is not None for result in results), 1)
        self.assertEqual(list(self.destination.iterdir()), [self.destination / "photo.jpg"])

    def test_atomic_metadata_failure_does_not_expose_incomplete_record(self):
        payload = Path(self.inbox.prepare(self.ident))
        path = payload / "photo.jpg"
        path.write_bytes(b"photo")
        with patch("receiver.inbox.os.replace", side_effect=OSError("metadata interrupted")):
            with self.assertRaises(OSError):
                self.inbox.record(self.ident, [path], 1)
        self.assertEqual(Inbox(self.inbox.root).list_ready(), [])
        info = self.inbox.record(self.ident, [str(path)], 1)
        self.assertEqual(Inbox(self.inbox.root).list_ready(), [info])

    def test_identifiers_and_record_paths_cannot_escape_inbox(self):
        with self.assertRaises(ValueError):
            self.inbox.prepare("../escape")
        payload = Path(self.inbox.prepare(self.ident))
        outside = self.root / "outside.txt"
        outside.write_bytes(b"outside")
        with self.assertRaises(ValueError):
            self.inbox.record(self.ident, [outside], 1)
        (payload / "link").symlink_to(outside)
        with self.assertRaises(ValueError):
            self.inbox.record(self.ident, [payload / "link"], 1)
        self.assertEqual(self.inbox.list_ready(), [])
        self.assertEqual(outside.read_bytes(), b"outside")

    def test_pending_list_does_not_wait_for_long_running_copy(self):
        self.ready()
        started = threading.Event()
        release = threading.Event()
        def progress(event):
            if event["bytes"] == 0:
                started.set()
                if not release.wait(timeout=5):
                    raise RuntimeError("test timed out")
        with ThreadPoolExecutor(max_workers=2) as pool:
            saving = pool.submit(self.inbox.save, self.ident, str(self.destination), progress)
            self.assertTrue(started.wait(timeout=3))
            try:
                listing = pool.submit(self.inbox.list_ready)
                self.assertEqual(listing.result(timeout=1), [])
            finally:
                release.set()
            self.assertEqual(saving.result(timeout=5)["count"], 1)

    def test_latest_received_survives_save_and_never_falls_back_to_older_ready_job(self):
        self.ready()
        older = self.ident
        self.ident = str(uuid.uuid4())
        _, newest = self.ready({"new.txt": b"new"})
        self.assertEqual(self.inbox.latest_received_id(), newest["id"])
        restored = Inbox(self.inbox.root)
        self.assertEqual(restored.latest_received_id(), newest["id"])
        restored.save(newest["id"], str(self.destination))
        again = Inbox(self.inbox.root)
        self.assertEqual([job["id"] for job in again.list_ready()], [older])
        self.assertEqual(again.latest_received_id(), newest["id"], "Do not offer older unsaved files after saving the latest transfer")

    def test_latest_index_recovers_from_receipt_after_interrupted_index_write(self):
        self.ready()
        self.ident = str(uuid.uuid4())
        replace = os.replace
        def fail_latest(source, target):
            if Path(target).name == ".latest-received.json":
                raise OSError("index interrupted")
            return replace(source, target)
        with patch("receiver.inbox.os.replace", side_effect=fail_latest):
            _, latest = self.ready({"latest.txt": b"latest"})
        restored = Inbox(self.inbox.root)
        self.assertEqual(restored.latest_received_id(), latest["id"])
        self.assertEqual(len(restored.list_ready()), 2)

    def test_legacy_receipts_use_receive_time_not_uuid_order(self):
        self.ident = "ffffffff-ffff-4fff-bfff-ffffffffffff"
        self.ready()
        old = self.inbox.root / self.ident / "ready.json"
        self.ident = "00000000-0000-4000-8000-000000000000"
        self.ready({"new.txt": b"new"})
        new = self.inbox.root / self.ident / "ready.json"
        for receipt, stamp in ((old, 1_000_000_000), (new, 2_000_000_000)):
            data = json.loads(receipt.read_text())
            data.pop("received_at_ns")
            receipt.write_text(json.dumps(data))
            os.utime(receipt, ns=(stamp, stamp))
        (self.inbox.root / ".latest-received.json").unlink()
        self.assertEqual(Inbox(self.inbox.root).latest_received_id(), self.ident)
