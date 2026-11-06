from pathlib import Path, PurePosixPath
import tempfile
import unittest

from receiver.archive import ArchiveError, ContainerDecoder, ODCParser, ReceiveDirectory
from receiver.layout import SelectionLayout, selections
from tests.fixtures import dvzip, member


PLUGIN = "Containers/Data/PluginKitPlugin/00000000-0000-0000-0000-000000000001/tmp/"
PHOTOS = "Media/PhotoData/OutgoingTemp/"


def with_directories(entries):
    directories = set()
    for name, _ in entries:
        directories.update(str(parent) for parent in PurePosixPath(name).parents if str(parent) != ".")
    data = b"".join(member(name, mode=0o040755) for name in sorted(directories))
    data += b"".join(member(name, content) for name, content in entries)
    return data + member("TRAILER!!!", mode=0)


class SelectionLayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="airfrajer-layout-")
        self.addCleanup(self.temp.cleanup)
        self.destination = Path(self.temp.name)

    def receive(self, entries, selected):
        directory = ReceiveDirectory(self.destination)
        parser = ODCParser(directory, layout=SelectionLayout(selections(selected)))
        try:
            decoder = ContainerDecoder(parser, "application/x-dvzip")
            encoded = dvzip(with_directories(entries))
            for offset in range(0, len(encoded), 19):
                decoder.feed(encoded[offset:offset + 19])
            decoder.finish()
            directory.publish()
            return parser.count
        finally:
            try:
                parser.close()
            finally:
                directory.close()

    def test_ios_photos_batch_produces_ten_files_and_no_transport_directories(self):
        entries = []
        selected = []
        for index in range(10):
            name = "IMG_%04d.jpg" % index
            parent = PLUGIN + "NSIRD_AirDrop_%s/" % index if index < 4 else PHOTOS + "PHMediaFormatConversionRequest-%s/" % index
            entries.append((parent + name, ("photo %s" % index).encode()))
            selected.append({"FileName": name, "FileBomPath": "/private/var/mobile/" + parent + name,
                             "FileIsDirectory": False})
        self.assertEqual(self.receive(entries, selected), 10)
        self.assertEqual(sorted(path.name for path in self.destination.iterdir()),
                         ["IMG_%04d.jpg" % index for index in range(10)])
        for index in range(10):
            self.assertEqual((self.destination / ("IMG_%04d.jpg" % index)).read_bytes(),
                             ("photo %s" % index).encode())

    def test_distinct_photos_with_same_basename_are_both_preserved(self):
        entries = [("NSIRD_AirDrop_one/photo.jpg", b"first"),
                   ("NSIRD_AirDrop_two/photo.jpg", b"second")]
        self.receive(entries, [{"FileName": "photo.jpg"}, {"FileName": "photo.jpg"}])
        self.assertEqual((self.destination / "photo.jpg").read_bytes(), b"first")
        self.assertEqual((self.destination / "photo (1).jpg").read_bytes(), b"second")

    def test_case_collisions_preserve_both_files(self):
        self.receive([("a/Photo.JPG", b"one"), ("b/photo.jpg", b"two")],
                     [{"FileName": "Photo.JPG"}, {"FileName": "photo.jpg"}])
        self.assertEqual((self.destination / "Photo.JPG").read_bytes(), b"one")
        self.assertEqual((self.destination / "photo (1).jpg").read_bytes(), b"two")

    def test_real_selected_folder_keeps_its_hierarchy(self):
        source = "Containers/Data/Application/example/Documents/Album"
        self.receive([(source + "/day1/a.jpg", b"one"), (source + "/day2/b.jpg", b"two")],
                     [{"FileName": "Album", "FileBomPath": "/private/var/mobile/" + source,
                       "FileIsDirectory": True}])
        self.assertEqual([path.name for path in self.destination.iterdir()], ["Album"])
        self.assertEqual((self.destination / "Album/day1/a.jpg").read_bytes(), b"one")
        self.assertEqual((self.destination / "Album/day2/b.jpg").read_bytes(), b"two")

    def test_mixed_folder_and_loose_photo(self):
        self.receive([("Album/inside.txt", b"inside"),
                      (PHOTOS + "PHMediaFormatConversionRequest-example/photo.jpg", b"image")],
                     [{"FileName": "Album", "FileBomPath": "./Album", "FileIsDirectory": True},
                      {"FileName": "photo.jpg", "FileIsDirectory": False}])
        self.assertEqual(sorted(path.name for path in self.destination.iterdir()), ["Album", "photo.jpg"])
        self.assertEqual((self.destination / "Album/inside.txt").read_bytes(), b"inside")

    def test_converted_photo_keeps_payload_extension(self):
        self.receive([(PHOTOS + "PHMediaFormatConversionRequest-example/photo.jpg", b"jpeg")],
                     [{"FileName": "photo.HEIC"}])
        self.assertEqual([path.name for path in self.destination.iterdir()], ["photo.jpg"])

    def test_real_folder_named_like_transport_wrapper_is_preserved(self):
        self.receive([("NSIRD_AirDrop_user_folder/keep.txt", b"keep")],
                     [{"FileName": "NSIRD_AirDrop_user_folder", "FileIsDirectory": True}])
        self.assertEqual((self.destination / "NSIRD_AirDrop_user_folder/keep.txt").read_bytes(), b"keep")

    def test_source_traversal_is_rejected_before_flattening(self):
        with self.assertRaises(ArchiveError):
            self.receive([("../escape.txt", b"bad")], [{"FileName": "escape.txt"}])
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_identical_bytes_in_two_selected_files_are_not_discarded(self):
        self.receive([("a/first.txt", b"same"), ("b/second.txt", b"same")],
                     [{"FileName": "first.txt"}, {"FileName": "second.txt"}])
        self.assertEqual(sorted(path.name for path in self.destination.iterdir()), ["first.txt", "second.txt"])
