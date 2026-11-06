from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from email.message import Message
import http.client
import io
from pathlib import Path
import plistlib
import queue
import socket
import ssl
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

from receiver.http import Body, HTTPError, ReceiverServer, decoded_size_hint
from receiver.archive import ODCParser
from receiver.inbox import Inbox
from receiver.main import identity
from receiver.sessions import Sessions
from tests.fixtures import archive, dvzip, request


class BodyTests(unittest.TestCase):
    def test_chunk_extensions_and_trailers(self):
        headers = Message()
        headers["Transfer-Encoding"] = "chunked"
        body = Body(io.BytesIO(b"3;ext=yes\r\nabc\r\n2\r\nde\r\n0\r\nX-End: yes\r\n\r\n"), headers, 10)
        self.assertEqual(body.read() + body.read(), b"abcde")
        self.assertEqual(body.read(), b"")

    def test_ambiguous_length_refused(self):
        headers = Message()
        headers["Transfer-Encoding"] = "chunked"
        headers["Content-Length"] = "5"
        with self.assertRaises(HTTPError):
            Body(io.BytesIO(), headers, 10)

    def test_truncated_chunk_not_eof(self):
        headers = Message()
        headers["Transfer-Encoding"] = "chunked"
        body = Body(io.BytesIO(b"5\r\nabc"), headers, 10)
        with self.assertRaises(HTTPError):
            body.read()

    def test_total_bytes_is_single_positive_ascii_signed63_hint_for_chunked_only(self):
        cases = [((), None), (("1",), 1), ((" 00042\t",), 42),
                 ((str((1 << 63) - 1),), (1 << 63) - 1),
                 ((str(1 << 63),), None), (("9" * 5000,), None),
                 (("0",), None), (("-1",), None), (("+1",), None), (("",), None),
                 (("1.5",), None), (("1e6",), None), (("１２３",), None),
                 (("\v123",), None),
                 (("123,123",), None), (("123", "123"), None)]
        for values, expected in cases:
            with self.subTest(values=tuple(value[:40] for value in values)):
                headers = Message()
                for value in values:
                    headers["TotalBytes"] = value
                self.assertEqual(decoded_size_hint(headers, True), expected)
                self.assertIsNone(decoded_size_hint(headers, False))


class ReceiverIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.state = tempfile.TemporaryDirectory(prefix="airfrajer-tls-")
        _, cls.context = identity(Path(cls.state.name))

    @classmethod
    def tearDownClass(cls):
        cls.state.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="airfrajer-dest-")
        self.addCleanup(self.temp.cleanup)
        self.events = queue.Queue()
        self.sessions = Sessions(lambda event, **fields: self.events.put(dict(event=event, **fields)))
        self.server = ReceiverServer(("::1", 0), self.context, self.sessions,
                                     lambda event, **fields: self.events.put(dict(event=event, **fields)), "Test", model="Mac13,1")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.pool = ThreadPoolExecutor(max_workers=2)
        self.addCleanup(self.stop)

    def stop(self):
        self.sessions.close()
        self.server.shutdown()
        self.server.close_connections()
        self.server.server_close()
        self.pool.shutdown(wait=True)

    def connection(self):
        return http.client.HTTPSConnection("::1", self.server.server_port, timeout=5,
                                          context=ssl._create_unverified_context())

    def post(self, path, payload, headers=None):
        conn = self.connection()
        try:
            conn.request("POST", path, payload, headers=headers or {})
            response = conn.getresponse()
            return response.status, response.read()
        finally:
            conn.close()

    def event(self, kind):
        while True:
            item = self.events.get(timeout=5)
            if item["event"] == kind:
                return item

    def grant(self, ident):
        pending = self.pool.submit(self.post, "/Ask", plistlib.dumps(request(ident)))
        offer = self.event("offer")
        self.sessions.decide(offer["id"], True, self.temp.name)
        status, response = pending.result(timeout=5)
        self.assertEqual(status, 200)
        self.assertEqual(plistlib.loads(response)["ReceiverModelName"], "Mac13,1")

    def post_chunks(self, ident, chunks, totals=()):
        raw = socket.create_connection(("::1", self.server.server_port), timeout=5)
        with ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost") as secure:
            headers = ("POST /Upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n"
                       "Content-Type: application/x-cpio\r\nTransferID: %s\r\n" % ident)
            headers += "".join("TotalBytes: %s\r\n" % total for total in totals)
            secure.sendall((headers + "\r\n").encode())
            for chunk in chunks:
                secure.sendall(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
            response = http.client.HTTPResponse(secure)
            response.begin()
            response.read()
            return response.status

    def use_inbox(self):
        inbox = Inbox(Path(self.temp.name) / "Incoming")
        self.server.inbox = inbox
        self.sessions.prepare_destination = inbox.prepare
        self.sessions.abandon_destination = inbox.abandon
        return inbox

    def test_ask_waits_while_other_connections_continue(self):
        ident = str(uuid.uuid4())
        pending = self.pool.submit(self.post, "/Ask", plistlib.dumps(request(ident)))
        offer = self.event("offer")
        with self.assertRaises(FutureTimeout):
            pending.result(timeout=0.15)
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])
        status, data = self.post("/Discover", plistlib.dumps({}))
        self.assertEqual(status, 200)
        self.assertEqual(plistlib.loads(data)["ReceiverComputerName"], "Test")
        self.sessions.decide(offer["id"], False)
        self.assertEqual(pending.result(timeout=5)[0], 403)

    def test_discover_preserves_native_media_json_as_binary_plist_data(self):
        capabilities = b'{"Version":3,"Codecs":{"hvc1":{"Profiles":{"VTSupportedProfiles":[1,2]}}}}'
        self.server.media_capabilities = capabilities
        status, data = self.post("/Discover", plistlib.dumps({}))
        self.assertEqual(status, 200)
        value = plistlib.loads(data)["ReceiverMediaCapabilities"]
        self.assertEqual(plistlib.loads(data)["ReceiverModelName"], "Mac13,1")
        self.assertIsInstance(value, bytes)
        self.assertEqual(value, capabilities)

    def test_upload_without_consent_never_gets_100_continue(self):
        raw = socket.create_connection(("::1", self.server.server_port), timeout=5)
        secure = ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost")
        with secure:
            secure.sendall(("POST /Upload HTTP/1.1\r\nContent-Type: application/x-dvzip\r\n"
                            "TransferID: %s\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n" % uuid.uuid4()).encode())
            answer = secure.recv(4096)
            self.assertIn(b"403", answer.split(b"\r\n", 1)[0])
            self.assertNotIn(b"100 Continue", answer)
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])

    def test_complete_upload_on_new_connection_and_replay_refused(self):
        ident = str(uuid.uuid4())
        self.grant(ident)
        payload = dvzip(archive([("NSIRD_AirDrop_test/test.txt", b"expected contents")]))
        headers = {"TransferID": ident, "Content-Type": "application/x-dvzip"}
        self.assertEqual(self.post("/Upload", payload, headers)[0], 200)
        self.assertEqual((Path(self.temp.name) / "test.txt").read_bytes(), b"expected contents")
        completion = self.event("complete")
        self.assertEqual(completion["paths"], [str(Path(self.temp.name) / "test.txt")])
        self.assertEqual(self.post("/Upload", payload, headers)[0], 403)

    def test_truncated_payload_not_reported_as_success(self):
        ident = str(uuid.uuid4())
        self.grant(ident)
        payload = dvzip(archive([("test.txt", b"expected contents")]))[:-3]
        status, _ = self.post("/Upload", payload, {"TransferID": ident, "Content-Type": "application/x-dvzip"})
        self.assertEqual(status, 500)
        self.assertFalse((Path(self.temp.name) / "test.txt").exists())

    def test_chunked_metadata_without_host_header(self):
        body = plistlib.dumps({}, fmt=plistlib.FMT_BINARY)
        wire = b"POST /Discover HTTP/1.1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        wire += ("%x\r\n" % len(body)).encode() + body + b"\r\n0\r\n\r\n"
        raw = socket.create_connection(("::1", self.server.server_port), timeout=5)
        with ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost") as secure:
            secure.sendall(wire)
            response = http.client.HTTPResponse(secure)
            response.begin()
            self.assertEqual(response.status, 200)
            self.assertEqual(plistlib.loads(response.read())["ReceiverComputerName"], "Test")

    def test_completed_archive_can_finish_without_http_zero_chunk(self):
        ident = str(uuid.uuid4())
        self.grant(ident)
        payload = dvzip(archive([("test.txt", b"contents")]))
        raw = socket.create_connection(("::1", self.server.server_port), timeout=5)
        with ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost") as secure:
            headers = ("POST /Upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n"
                       "Content-Type: application/x-dvzip\r\nTransferID: %s\r\n\r\n" % ident).encode()
            secure.sendall(headers + ("%x\r\n" % len(payload)).encode() + payload + b"\r\n")
            response = http.client.HTTPResponse(secure)
            response.begin()
            self.assertEqual(response.status, 200)
            response.read()
        self.assertEqual((Path(self.temp.name) / "test.txt").read_bytes(), b"contents")

    def test_dvzip_end_marker_split_across_http_chunks(self):
        ident = str(uuid.uuid4())
        self.grant(ident)
        payload = dvzip(archive([("test.txt", b"contents")]))
        chunks = [payload + b"\x00\x00", b"\x00\x00"]
        raw = socket.create_connection(("::1", self.server.server_port), timeout=5)
        with ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost") as secure:
            headers = ("POST /Upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n"
                       "Content-Type: application/x-dvzip\r\nTransferID: %s\r\n\r\n" % ident).encode()
            secure.sendall(headers)
            for chunk in chunks:
                secure.sendall(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
            response = http.client.HTTPResponse(secure)
            response.begin()
            self.assertEqual(response.status, 200)
            response.read()

    def test_write_and_flush_failure_release_session(self):
        ident = str(uuid.uuid4())
        self.grant(ident)
        failing = mock.Mock()
        failing.close.side_effect = OSError(28, "No space left on device")
        def fail_write(parser, data):
            parser.file = failing
            raise OSError(28, "No space left on device")
        payload = dvzip(archive([("test.txt", b"contents")]))
        with mock.patch.object(ODCParser, "feed", fail_write):
            status, _ = self.post("/Upload", payload, {"TransferID": ident, "Content-Type": "application/x-dvzip"})
        self.assertEqual(status, 500)
        self.grant(str(uuid.uuid4()))

    def test_ios_batch_layout_through_real_http_receiver(self):
        ident = str(uuid.uuid4())
        metadata = request(ident, "a.jpg")
        metadata["Files"] = [{"FileName": "a.jpg", "FileIsDirectory": False},
                             {"FileName": "b.jpg", "FileIsDirectory": False}]
        pending = self.pool.submit(self.post, "/Ask", plistlib.dumps(metadata))
        offer = self.event("offer")
        self.sessions.decide(offer["id"], True, self.temp.name)
        self.assertEqual(pending.result(timeout=5)[0], 200)
        from tests.test_layout import with_directories, PLUGIN, PHOTOS
        payload = dvzip(with_directories([
            (PLUGIN + "NSIRD_AirDrop_example/a.jpg", b"first image"),
            (PHOTOS + "PHMediaFormatConversionRequest-example/b.jpg", b"second image"),
        ]))
        self.assertEqual(self.post("/Upload", payload,
                                  {"TransferID": ident, "Content-Type": "application/x-dvzip"})[0], 200)
        self.assertEqual((Path(self.temp.name) / "a.jpg").read_bytes(), b"first image")
        self.assertEqual((Path(self.temp.name) / "b.jpg").read_bytes(), b"second image")
        self.assertFalse((Path(self.temp.name) / "Containers").exists())
        self.assertFalse((Path(self.temp.name) / "Media").exists())

    def test_completion_points_at_new_file_after_name_collision(self):
        existing = Path(self.temp.name) / "test.txt"
        existing.write_bytes(b"original")
        ident = str(uuid.uuid4())
        self.grant(ident)
        payload = dvzip(archive([("test.txt", b"new content")]))
        self.assertEqual(self.post("/Upload", payload,
                                  {"TransferID": ident, "Content-Type": "application/x-dvzip"})[0], 200)
        completion = self.event("complete")
        self.assertEqual(completion["paths"], [str(existing.with_name("test (1).txt"))])
        self.assertEqual(existing.read_bytes(), b"original")

    def test_chunked_hints_are_reported_but_never_validate_actual_size(self):
        data = archive([("test.txt", b"contents")])
        for totals, expected in [(("1",), 1), (("999999",), 999999),
                                 (("123", "123"), None), (("private-invalid-header",), None),
                                 ((str(1 << 63),), None), ((), None)]:
            with self.subTest(totals=totals):
                ident = str(uuid.uuid4())
                self.grant(ident)
                with self.assertLogs("receiver.http", level="INFO") as logs:
                    self.assertEqual(self.post_chunks(ident, [data], totals), 200)
                    for event in (self.event("receiving"), self.event("progress")):
                        self.assertEqual(event["total_decoded_bytes"], expected)
                        self.assertIsNone(event["total_bytes"])
                    self.event("complete")
                    with self.server.connection_condition:
                        self.assertTrue(self.server.connection_condition.wait_for(
                            lambda: not self.server.uploads, timeout=2))
                self.assertNotIn("private-invalid-header", "\n".join(logs.output))
                numeric = "declared=%d actual=%d" % (expected, len(data)) if expected else "actual=%d" % len(data)
                self.assertTrue(any("Decoded totals: " + numeric in line for line in logs.output))

    def test_receiving_and_progress_keep_wire_and_decoded_totals_distinct(self):
        ident = str(uuid.uuid4())
        self.grant(ident)
        data = archive([("test.txt", b"compressible" * 5000)])
        wire = dvzip(data)
        self.assertEqual(self.post("/Upload", wire, {"TransferID": ident, "TotalBytes": "1",
                                                    "Content-Type": "application/x-dvzip"})[0], 200)
        receiving = self.event("receiving")
        progress = self.event("progress")
        for event in (receiving, progress):
            self.assertIsNone(event["total_decoded_bytes"])
            self.assertEqual(event["total_bytes"], len(wire))
            self.assertEqual(event["total_files"], 1)
        self.assertEqual(receiving["decoded_bytes"], 0)
        self.assertEqual(progress["bytes"], len(wire))
        self.assertEqual(progress["decoded_bytes"], len(data))
        self.assertEqual(progress["files_received"], 1)

    def test_progress_is_immediate_then_100ms_and_final(self):
        ident = str(uuid.uuid4())
        self.grant(ident)
        data = archive([("test.txt", b"x" * 10000)])
        clock = SimpleNamespace(monotonic=mock.Mock(side_effect=[1, 1.05, 1.11, 1.15]))
        with mock.patch("receiver.http.time", clock):
            self.assertEqual(self.post_chunks(ident, [data[:100], data[100:200], data[200:300], data[300:]],
                                              totals=("99999",)), 200)
        receiving = self.event("receiving")
        progress = [self.event("progress") for _ in range(3)]
        self.assertEqual([event["bytes"] for event in progress], [100, 300, len(data)])
        for event in (receiving, *progress):
            self.assertIsNone(event["total_bytes"])
            self.assertEqual(event["total_decoded_bytes"], 99999)
            self.assertEqual(event["decoded_bytes"], event["bytes"])
        self.assertEqual(self.event("complete")["count"], 1)

    def test_cancel_interrupts_only_upload_socket_and_cleans_incomplete_inbox(self):
        inbox = self.use_inbox()
        ident = str(uuid.uuid4())
        self.assertEqual(self.post("/Ask", plistlib.dumps(request(ident)))[0], 200)
        incoming = self.event("incoming")
        data = archive([("test.txt", b"x" * 250000)])
        raw = socket.create_connection(("::1", self.server.server_port), timeout=5)
        with ssl._create_unverified_context().wrap_socket(raw, server_hostname="localhost") as secure:
            headers = ("POST /Upload HTTP/1.1\r\nContent-Type: application/x-cpio\r\n"
                       "TransferID: %s\r\nContent-Length: %d\r\n\r\n" % (ident, len(data))).encode()
            secure.sendall(headers + data[:100000])
            self.assertEqual(self.event("progress")["files_received"], 0)
            other = self.connection()
            try:
                other.request("POST", "/Discover", plistlib.dumps({}))
                response = other.getresponse()
                self.assertEqual(response.status, 200)
                response.read()
                self.assertFalse(self.server.cancel_transfer(str(uuid.uuid4())))
                self.assertTrue(self.server.cancel_transfer(incoming["id"]))
                secure.settimeout(2)
                self.assertEqual(secure.recv(4096), b"")
                with self.server.connection_condition:
                    self.assertTrue(self.server.connection_condition.wait_for(
                        lambda: not self.server.uploads, timeout=2))
                other.request("POST", "/Discover", plistlib.dumps({}))
                response = other.getresponse()
                self.assertEqual(response.status, 200)
                response.read()
            finally:
                other.close()
        self.assertEqual(self.event("canceled"), dict(event="canceled", id=incoming["id"], phase="receiving"))
        self.assertEqual(list(inbox.root.iterdir()), [])
        self.assertEqual(inbox.list_ready(), [])
        self.assertFalse(any(event["event"] == "error" for event in list(self.events.queue)))
        self.assertEqual(self.post("/Ask", plistlib.dumps(request(str(uuid.uuid4()))))[0], 200)
        next_offer = self.event("incoming")
        self.assertFalse(self.server.cancel_transfer(incoming["id"]))
        self.assertEqual(self.sessions.current.id, next_offer["id"])

    def test_cancel_racing_ready_commit_keeps_completed_inbox_job(self):
        inbox = self.use_inbox()
        ident = str(uuid.uuid4())
        self.assertEqual(self.post("/Ask", plistlib.dumps(request(ident)))[0], 200)
        incoming = self.event("incoming")
        committed = threading.Event()
        release = threading.Event()
        record = inbox.record
        def pause_after_ready(*args):
            result = record(*args)
            committed.set()
            if not release.wait(timeout=5):
                raise RuntimeError("test timed out")
            return result
        with mock.patch.object(inbox, "record", side_effect=pause_after_ready):
            upload = self.pool.submit(self.post, "/Upload", archive([("test.txt", b"keep")]),
                                      {"TransferID": ident, "Content-Type": "application/x-cpio"})
            try:
                self.assertTrue(committed.wait(timeout=3))
                cancel = self.pool.submit(self.server.cancel_transfer, incoming["id"])
                with self.assertRaises(FutureTimeout):
                    cancel.result(timeout=0.1)
            finally:
                release.set()
            self.assertEqual(upload.result(timeout=3)[0], 200)
            self.assertFalse(cancel.result(timeout=3))
        downloaded = self.event("downloaded")
        self.assertEqual(inbox.list_ready()[0]["id"], incoming["id"])
        self.assertEqual(Path(downloaded["paths"][0]).read_bytes(), b"keep")
        self.assertFalse(self.server.cancel_transfer(incoming["id"]))
