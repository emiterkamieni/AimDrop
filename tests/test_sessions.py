from pathlib import Path
import base64
import tempfile
import threading
import time
import unittest
import uuid
from unittest import mock

from receiver.sessions import Refused, Sessions
from receiver.inbox import Inbox
from tests.fixtures import request

PEER = ("fe80::1", 1000, 0, 20)


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.sessions = Sessions(lambda event, **fields: self.events.append((event, fields)))
        self.temp = tempfile.TemporaryDirectory(prefix="airfrajer-test-")
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.sessions.close)
        self.ident = str(uuid.uuid4())

    def accepted(self):
        offer = self.sessions.offer(request(self.ident), PEER)
        self.sessions.decide(offer.id, True, self.temp.name)
        self.sessions.wait(offer)
        return offer

    def test_upload_before_choice_is_refused_without_files(self):
        self.sessions.offer(request(self.ident), PEER)
        with self.assertRaises(Refused):
            self.sessions.claim(self.ident, PEER)
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])

    def test_consent_bound_to_peer_scope_and_id_not_source_port(self):
        offer = self.accepted()
        for ident, peer in [(str(uuid.uuid4()), PEER), (self.ident, ("fe80::2", 1000, 0, 20)),
                            (self.ident, ("fe80::1", 1000, 0, 21))]:
            with self.assertRaises(Refused):
                self.sessions.claim(ident, peer)
        self.assertIs(self.sessions.claim(self.ident, (PEER[0], 9999, 0, 20)), offer)
        offer.storage.close()

    def test_decline_and_late_accept_do_not_grant_access(self):
        offer = self.sessions.offer(request(self.ident), PEER)
        self.sessions.decide(offer.id, False)
        self.sessions.decide(offer.id, True, self.temp.name)
        with self.assertRaises(Refused):
            self.sessions.claim(self.ident, PEER)
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])

    def test_expiration_cleans_reserved_destination(self):
        offer = self.accepted()
        offer.deadline = time.monotonic() - 1
        self.sessions.expire()
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])
        with self.assertRaises(Refused):
            self.sessions.claim(self.ident, PEER)

    def test_identical_ask_reuses_panel_changed_manifest_is_refused(self):
        offer = self.sessions.offer(request(self.ident), PEER)
        self.assertIs(self.sessions.offer(request(self.ident), PEER), offer)
        self.assertEqual(len(self.events), 1)
        with self.assertRaises(Refused):
            self.sessions.offer(request(self.ident, "other.txt"), PEER)

    def test_concurrent_upload_claim_is_single_use(self):
        offer = self.accepted()
        barrier = threading.Barrier(3)
        results = []
        def claim():
            barrier.wait()
            try:
                self.sessions.claim(self.ident, PEER)
                results.append(True)
            except Refused:
                results.append(False)
        threads = [threading.Thread(target=claim) for _ in range(2)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join()
        self.assertEqual(sorted(results), [False, True])
        offer.storage.close()
        self.sessions.finish(offer)
        with self.assertRaises(Refused):
            self.sessions.offer(request(self.ident), PEER)

    def test_invalid_destination_refused_before_acknowledgment(self):
        offer = self.sessions.offer(request(self.ident), PEER)
        self.sessions.decide(offer.id, True, self.temp.name + "/missing")
        with self.assertRaises(Refused):
            self.sessions.wait(offer)
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])

    def test_repeated_ask_cannot_change_folder_semantics(self):
        original = request(self.ident, "Album")
        original["Files"][0].update(FileIsDirectory=True, FileBomPath="./Album")
        self.sessions.offer(original, PEER)
        changed = request(self.ident, "Album")
        changed["Files"][0].update(FileIsDirectory=False, FileBomPath="./Album")
        with self.assertRaises(Refused):
            self.sessions.offer(changed, PEER)

    def test_automatic_acceptance_survives_upload_starting_during_ask_retry(self):
        self.sessions.prepare_destination = lambda ident: self.temp.name
        original = self.sessions.decide
        def accept_then_start_upload(*args):
            accepted = original(*args)
            self.sessions.claim(self.ident, PEER)
            return accepted
        with mock.patch.object(self.sessions, "decide", side_effect=accept_then_start_upload):
            offer = self.sessions.offer(request(self.ident), PEER)
        self.assertEqual(offer.state, "receiving")
        self.assertFalse(offer.canceled.is_set())
        self.assertIs(self.sessions.wait(offer), offer)
        offer.storage.close()
        self.sessions.finish(offer)

    def test_incoming_has_display_folder_names_and_bounded_byte_preview(self):
        self.sessions.prepare_destination = lambda ident: self.temp.name
        metadata = request(self.ident)
        metadata["Files"].extend([
            {"FileName": "Al\nb um", "FileIsDirectory": True},
            {"FileName": "Other", "FileType": "public.folder"},
        ])
        metadata["FileIcon"] = b"image bytes\x00"
        offer = self.sessions.offer(metadata, PEER)
        incoming = self.events[0][1]
        self.assertEqual(self.events[0][0], "incoming")
        self.assertEqual(incoming["files"], ["test.txt", "Alb um", "Other"])
        self.assertEqual(incoming["folders"], ["Alb um", "Other"])
        self.assertEqual(base64.b64decode(incoming["preview"]), metadata["FileIcon"])
        self.assertEqual(offer.preview, incoming["preview"])

    def test_preview_accepts_only_bytes_up_to_512_kib(self):
        self.sessions.prepare_destination = lambda ident: self.temp.name
        for icon, accepted in ((b"x" * (512 * 1024), True), (b"", True),
                               (b"x" * (512 * 1024 + 1), False),
                               ("base64-looking-text", False), (bytearray(b"image"), False),
                               ({"image": b"data"}, False), (None, False)):
            with self.subTest(type=type(icon).__name__, accepted=accepted):
                metadata = request(str(uuid.uuid4()))
                metadata["FileIcon"] = icon
                offer = self.sessions.offer(metadata, PEER)
                incoming = next(fields for event, fields in self.events if event == "incoming")
                self.assertEqual(incoming["folders"], [])
                self.assertEqual("preview" in incoming, accepted)
                if accepted:
                    self.assertEqual(base64.b64decode(incoming["preview"]), icon)
                self.sessions.cancel(offer.id)
                self.events.clear()

    def test_cancel_during_incoming_before_buffer_preparation_cleans_without_error(self):
        inbox = Inbox(Path(self.temp.name) / "Incoming")
        self.sessions.prepare_destination = inbox.prepare
        self.sessions.abandon_destination = inbox.abandon
        def emit(event, **fields):
            self.events.append((event, fields))
            if event == "incoming":
                self.sessions.cancel(fields["id"])
        self.sessions.emit = emit
        with self.assertRaises(Refused):
            self.sessions.offer(request(self.ident), PEER)
        self.assertIsNone(self.sessions.current)
        self.assertEqual(list(inbox.root.iterdir()), [])
        self.assertEqual([event for event, _ in self.events], ["incoming", "offer_closed", "canceled"])

    def test_cancel_only_matches_current_offer_and_is_idempotent(self):
        offer = self.accepted()
        self.assertFalse(self.sessions.cancel(str(uuid.uuid4())))
        self.assertIs(self.sessions.current, offer)
        self.assertTrue(self.sessions.cancel(offer.id))
        self.assertTrue(offer.canceled.is_set())
        self.assertFalse(self.sessions.cancel(offer.id))
        self.assertEqual(self.events[-1], ("canceled", dict(id=offer.id, phase="receiving")))
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])
