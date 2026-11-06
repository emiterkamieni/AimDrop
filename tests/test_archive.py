import gzip
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
import zlib

from receiver.archive import ArchiveError, ContainerDecoder, ODCParser, ReceiveDirectory
from tests.fixtures import archive, dvzip, member


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="airfrajer-test-")
        self.addCleanup(self.temp.cleanup)
        self.destination = Path(self.temp.name)
        self.directory = ReceiveDirectory(self.destination)
        self.addCleanup(self.directory.close)
        self.parser = ODCParser(self.directory)
        self.addCleanup(self.parser.close)

    def decode(self, data, content_type="application/x-dvzip", stride=7):
        decoder = ContainerDecoder(self.parser, content_type)
        for offset in range(0, len(data), stride):
            decoder.feed(data[offset:offset + stride])
        decoder.finish()
        return decoder

    def test_compressed_dvzip_preserves_bytes_and_flattens_ios_wrapper(self):
        original = os.urandom(300000)
        wire = dvzip(archive([("NSIRD_AirDrop_fixture/zdjęcie.bin", original), ("empty.txt", b"")]))
        self.decode(wire, stride=32749)
        self.directory.publish()
        saved = (self.destination / "zdjęcie.bin").read_bytes()
        self.assertEqual(hashlib.sha256(saved).digest(), hashlib.sha256(original).digest())
        self.assertEqual((self.destination / "empty.txt").read_bytes(), b"")

    def test_stored_dvzip_one_byte_at_a_time(self):
        self.decode(dvzip(archive([("a.txt", b"hello")]), stored=True), stride=1)
        self.directory.publish()
        self.assertEqual((self.destination / "a.txt").read_bytes(), b"hello")

    def test_raw_cpio_and_nested_directory(self):
        self.decode(archive([("folder/a.txt", b"data")]), "application/x-cpio")
        self.directory.publish()
        self.assertEqual((self.destination / "folder/a.txt").read_bytes(), b"data")

    def test_gzip_cpio(self):
        self.decode(gzip.compress(archive([("a.txt", b"hello")])), "application/x-cpio", stride=1)
        self.directory.publish()
        self.assertEqual((self.destination / "a.txt").read_bytes(), b"hello")

    def test_decoded_metrics_include_headers_sidecars_and_padding_in_all_containers(self):
        data = archive([("a.txt", b"hello" * 60000), ("._a.txt", b"metadata")]) + b"\0" * 512
        for content_type, wire in (("application/x-cpio", data),
                                   ("application/x-cpio", gzip.compress(data)),
                                   ("application/x-dvzip", dvzip(data)),
                                   ("application/x-dvzip", dvzip(data, stored=True))):
            with self.subTest(content_type=content_type, wire_bytes=len(wire)):
                directory = ReceiveDirectory(self.destination)
                parser = ODCParser(directory)
                decoder = ContainerDecoder(parser, content_type)
                try:
                    previous = 0
                    for offset in range(0, len(wire), 1021):
                        decoder.feed(wire[offset:offset + 1021])
                        self.assertGreaterEqual(decoder.decoded_bytes, previous)
                        self.assertLessEqual(decoder.decoded_bytes, len(data))
                        previous = decoder.decoded_bytes
                    decoder.finish()
                    self.assertEqual(decoder.decoded_bytes, len(data))
                    self.assertGreater(decoder.decoded_bytes, directory.written)
                    self.assertEqual(parser.completed_count, 1)
                finally:
                    parser.close()
                    directory.close()

    def test_gzip_metrics_count_every_bounded_decompression_pass(self):
        data = archive([("large.bin", b"x" * (5 * 1024 * 1024))])
        wire = gzip.compress(data)
        decoder = self.decode(wire, "application/x-cpio", stride=len(wire))
        self.assertEqual(decoder.decoded_bytes, len(data))

    def test_gzip_checksum_is_required(self):
        compressed = gzip.compress(archive([("a.txt", b"hello")]))
        with self.assertRaises(ArchiveError):
            self.decode(compressed[:-4], "application/x-cpio")
        self.assertFalse((self.destination / "a.txt").exists())

    def test_existing_file_not_overwritten(self):
        (self.destination / "a.txt").write_bytes(b"original")
        self.decode(dvzip(archive([("a.txt", b"new")])))
        self.directory.publish()
        self.assertEqual((self.destination / "a.txt").read_bytes(), b"original")
        self.assertEqual((self.destination / "a (1).txt").read_bytes(), b"new")

    def test_existing_directory_not_merged(self):
        (self.destination / "folder").mkdir()
        (self.destination / "folder/keep.txt").write_bytes(b"original")
        self.decode(dvzip(archive([("folder/a.txt", b"new")])))
        self.directory.publish()
        self.assertEqual((self.destination / "folder (1)/a.txt").read_bytes(), b"new")
        self.assertFalse((self.destination / "folder/a.txt").exists())

    def test_false_trailer_in_file_does_not_complete_truncated_transfer(self):
        data = archive([("a.txt", b"TRAILER!!!" + b"x" * 200)])
        with self.assertRaises(ArchiveError):
            self.decode(dvzip(data[:130]))
        self.assertFalse((self.destination / "a.txt").exists())

    def test_reject_traversal_absolute_and_symlink(self):
        for name in ("../escape.txt", "/absolute.txt", "NSIRD_AirDrop_x/../../escape.txt"):
            with self.subTest(name=name), self.assertRaises(ArchiveError):
                self.parser.feed(member(name, b"bad"))
            self.parser.close()
            self.parser = ODCParser(self.directory)
        with self.assertRaises(ArchiveError):
            self.parser.feed(member("link", b"/tmp", mode=0o120777))

    def test_reject_duplicate_member(self):
        with self.assertRaises(ArchiveError):
            self.decode(dvzip(archive([("a.txt", b"first"), ("a.txt", b"second")])))

    def test_reject_hardlink(self):
        with self.assertRaises(ArchiveError):
            self.parser.feed(member("a.txt", b"", links=2))

    def test_no_publish_when_destination_path_is_replaced(self):
        self.decode(dvzip(archive([("a.txt", b"data")])))
        moved = self.destination.with_name(self.destination.name + "-moved")
        self.destination.rename(moved)
        self.destination.mkdir()
        self.addCleanup(lambda: moved.rmdir())
        with self.assertRaises(ArchiveError):
            self.directory.publish()
        self.assertEqual(list(self.destination.iterdir()), [])
        self.directory.close()

    def test_partial_compression_block_not_accepted(self):
        wire = dvzip(archive([("a.txt", b"hello")]))
        with self.assertRaises(ArchiveError):
            self.decode(wire[:-2])

    def test_compression_bomb_is_bounded(self):
        import struct
        payload = zlib.compress(b"a" * (5 * 1024 * 1024))
        with self.assertRaises(ArchiveError):
            self.decode(struct.pack(">I", len(payload)) + payload)

    def test_appledouble_sidecar_not_published_as_file(self):
        self.decode(dvzip(archive([("._photo.jpg", b"metadata"), ("photo.jpg", b"image")])) )
        self.directory.publish()
        self.assertEqual(self.parser.count, 1)
        self.assertFalse((self.destination / "._photo.jpg").exists())
