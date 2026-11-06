"""Bounded, incremental decoding of AirDrop dvzip and ODC cpio containers.

Only complete regular files/directories are published. Each transfer has its
own staging directory on the chosen volume; process cwd is never changed.
"""
import ctypes
import errno
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import sys
import time
import uuid
import zlib
from .localization import message

MAX_BLOCK = 4 * 1024 * 1024
MAX_MEMBERS = 10000


def quarantine_file(fd):
    if sys.platform != "darwin":
        return
    value = ("0081;%x;AimDrop;%s" % (int(time.time()), str(uuid.uuid4()).upper())).encode("ascii")
    call = ctypes.CDLL(None, use_errno=True).fsetxattr
    call.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                     ctypes.c_uint32, ctypes.c_int]
    call.restype = ctypes.c_int
    # Best effort on external volumes which may not support extended attributes.
    call(fd, b"com.apple.quarantine", value, len(value), 0, 0)


class ArchiveError(ValueError):
    pass


def safe_name(name, strip_wrapper=True):
    if "\x00" in name or "\\" in name:
        raise ArchiveError(message("Invalid file name in the transfer.", "Nieprawidłowa nazwa pliku w przesyłce."))
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise ArchiveError(message("The file path is outside the receive folder.", "Ścieżka pliku wychodzi poza folder odbioru."))
    parts = tuple(part for part in path.parts if part != ".")
    if strip_wrapper and parts and parts[0].startswith("NSIRD_AirDrop_"):
        parts = parts[1:]
    return parts


def rename_exclusive(source_fd, source, target_fd, target):
    """Atomic no-replace rename, including directories, on the supported Mac."""
    if sys.platform == "darwin":
        lib = ctypes.CDLL(None, use_errno=True)
        call = lib.renameatx_np
        call.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        call.restype = ctypes.c_int
        if call(source_fd, os.fsencode(source), target_fd, os.fsencode(target), 0x4) != 0:  # RENAME_EXCL
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(target))
    else:
        # The live app is macOS-only; this branch supports file-only CI fixtures.
        if stat.S_ISDIR(os.stat(source, dir_fd=source_fd, follow_symlinks=False).st_mode):
            raise OSError(message("Saving folders requires macOS.", "Zapisywanie folderów wymaga systemu macOS."))
        os.link(source, target, src_dir_fd=source_fd, dst_dir_fd=target_fd, follow_symlinks=False)
        os.unlink(source, dir_fd=source_fd)


class ReceiveDirectory:
    def __init__(self, destination):
        self.destination = Path(destination).resolve(strict=True)
        if not self.destination.is_dir():
            raise ArchiveError(message("The selected location is not a folder.", "Wybrane miejsce nie jest folderem."))
        self.destination_fd = os.open(self.destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.stage_name = ".airfrajer-" + uuid.uuid4().hex
        self.stage_fd = None
        self.root = self.destination / self.stage_name
        try:
            os.mkdir(self.stage_name, 0o700, dir_fd=self.destination_fd)
            self.stage_fd = os.open(self.stage_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                    dir_fd=self.destination_fd)
            space = os.fstatvfs(self.stage_fd)
            self.limit = max(0, space.f_bavail * space.f_frsize - 16 * 1024 * 1024)
        except Exception:
            self.close()
            raise
        self.written = 0
        self.published = []

    def assert_present(self):
        current = os.stat(self.destination, follow_symlinks=False)
        pinned = os.fstat(self.destination_fd)
        if (current.st_dev, current.st_ino) != (pinned.st_dev, pinned.st_ino):
            raise ArchiveError(message("The selected folder was moved or the disk was disconnected.", "Wybrany folder został przeniesiony lub dysk został odłączony."))

    def open_directory(self, parts):
        fd = os.dup(self.stage_fd)
        try:
            for part in parts:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
            return fd
        except Exception:
            os.close(fd)
            raise

    def open_file(self, parts):
        fd = self.open_directory(parts[:-1])
        try:
            result = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=fd)
            return os.fdopen(result, "wb")
        finally:
            os.close(fd)

    @staticmethod
    def _empty(fd):
        for name in os.listdir(fd):
            mode = os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode
            if stat.S_ISDIR(mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    ReceiveDirectory._empty(child)
                finally:
                    os.close(child)
                os.rmdir(name, dir_fd=fd)
            else:
                os.unlink(name, dir_fd=fd)

    def close(self):
        if self.destination_fd is None:
            return
        try:
            if self.stage_fd is not None:
                self._empty(self.stage_fd)
            os.rmdir(self.stage_name, dir_fd=self.destination_fd)
        except OSError:
            pass  # disconnected volumes may retain this transfer's hidden staging dir
        finally:
            if self.stage_fd is not None:
                os.close(self.stage_fd)
                self.stage_fd = None
            os.close(self.destination_fd)
            self.destination_fd = None

    def publish(self):
        # Publish top-level items without merging with existing directories.
        try:
            self.assert_present()
            for source in sorted(os.listdir(self.stage_fd)):
                if source.startswith("._"):
                    continue
                is_file = stat.S_ISREG(os.stat(source, dir_fd=self.stage_fd, follow_symlinks=False).st_mode)
                for index in range(10000):
                    suffix = Path(source).suffix if is_file else ""
                    stem = source[:-len(suffix)] if suffix else source
                    name = source if index == 0 else "%s (%s)%s" % (stem, index, suffix)
                    target = self.destination / name
                    try:
                        rename_exclusive(self.stage_fd, source, self.destination_fd, name)
                        self.published.append(target)
                        break
                    except OSError as error:
                        if error.errno not in (errno.EEXIST, errno.ENOTEMPTY):
                            raise
                else:
                    raise ArchiveError(message("Too many files have the same name.", "Zbyt wiele plików o tej samej nazwie."))
            return self.published
        except Exception:
            # Already-published items are kept and reported by the caller, never deleted.
            raise


class ODCParser:
    def __init__(self, directory, layout=None):
        self.directory = directory
        self.layout = layout
        self.pending = bytearray()
        self.phase = "header"
        self.remaining = 0
        self.name_length = 0
        self.mode = 0
        self.links = 0
        self.file = None
        self.done = False
        self.count = 0
        self.completed_count = 0
        self.members = 0
        self.paths = set()

    def close(self):
        if self.file is not None:
            handle = self.file
            self.file = None
            handle.close()

    def feed(self, data):
        if self.done:
            if any(data):
                raise ArchiveError(message("Unexpected data after the end of the archive.", "Dane po zakończeniu archiwum."))
            return
        self.pending.extend(data)
        while not self.done:
            if self.phase == "header":
                if len(self.pending) < 76:
                    break
                header = bytes(self.pending[:76])
                del self.pending[:76]
                if header[:6] != b"070707":
                    raise ArchiveError(message("Unsupported AirDrop archive format (expected ODC cpio).", "Nieobsługiwany format archiwum AirDrop (oczekiwano ODC cpio)."))
                if any(byte not in b"01234567" for byte in header[6:]):
                    raise ArchiveError(message("Invalid archive header.", "Nieprawidłowy nagłówek archiwum."))
                self.mode = int(header[18:24], 8)
                self.links = int(header[36:42], 8)
                self.name_length = int(header[59:65], 8)
                self.remaining = int(header[65:76], 8)
                if not 1 <= self.name_length <= 4096:
                    raise ArchiveError(message("Invalid file name length.", "Nieprawidłowa długość nazwy pliku."))
                if self.remaining > self.directory.limit - self.directory.written:
                    raise ArchiveError(message("There is not enough space in the selected folder.", "Za mało miejsca w wybranym folderze."))
                self.phase = "name"
            elif self.phase == "name":
                if len(self.pending) < self.name_length:
                    break
                raw = bytes(self.pending[:self.name_length])
                del self.pending[:self.name_length]
                if raw[-1:] != b"\0" or b"\0" in raw[:-1]:
                    raise ArchiveError(message("Invalid name in the archive.", "Nieprawidłowa nazwa w archiwum."))
                try:
                    name = raw[:-1].decode("utf-8")
                except UnicodeError as error:
                    raise ArchiveError(message("The file name is not valid UTF-8.", "Nazwa pliku nie jest poprawnym UTF-8.")) from error
                if name == "TRAILER!!!":
                    if self.remaining:
                        raise ArchiveError(message("Invalid archive ending.", "Nieprawidłowe zakończenie archiwum."))
                    self.done = True
                    if any(self.pending):
                        raise ArchiveError(message("Unexpected data after the end of the archive.", "Dane po zakończeniu archiwum."))
                    self.pending.clear()
                    break
                self._begin_member(name)
                self.phase = "data"
            else:
                length = min(len(self.pending), self.remaining)
                if length:
                    if self.file is not None:
                        self.file.write(self.pending[:length])
                    del self.pending[:length]
                    self.remaining -= length
                    self.directory.written += length
                if self.remaining:
                    break
                if self.file is not None:
                    self.file.flush()
                    os.fsync(self.file.fileno())
                    self.file.close()
                    self.file = None
                    self.completed_count += 1
                self.phase = "header"

    def _begin_member(self, name):
        self.members += 1
        if self.members > MAX_MEMBERS:
            raise ArchiveError(message("The transfer contains too many items.", "Przesyłka zawiera zbyt wiele elementów."))
        parts = safe_name(name, strip_wrapper=self.layout is None)
        kind = stat.S_IFMT(self.mode)
        if kind not in (stat.S_IFREG, stat.S_IFDIR):
            raise ArchiveError(message("Only regular files and folders can be received; this item has a different type.", "Odbierać można zwykłe pliki i foldery; ten element ma inny typ."))
        if kind == stat.S_IFREG and self.links > 1:
            raise ArchiveError(message("Hard links are not supported.", "Dowiązania twarde nie są obsługiwane."))
        if kind == stat.S_IFDIR and self.remaining:
            raise ArchiveError(message("Invalid folder entry.", "Nieprawidłowy wpis folderu."))
        if not parts:
            if kind != stat.S_IFDIR:
                raise ArchiveError(message("The file name is missing.", "Brak nazwy pliku."))
            return
        # AppleDouble metadata is not file content; do not expose it as a second photo.
        if any(part.startswith("._") for part in parts):
            return
        # Reject a repeated source record, but allow separate selected sources
        # whose filenames happen to collide after removing iOS transport paths.
        if kind == stat.S_IFREG:
            source = "/".join(parts)
            if source in self.paths:
                raise ArchiveError(message("Duplicate source file in the same transfer.", "Powtórzony plik źródłowy w tej samej przesyłce."))
            self.paths.add(source)
        if self.layout is not None:
            parts = self.layout.destination(parts, kind == stat.S_IFDIR)
            if parts is None:
                return
        if kind == stat.S_IFDIR:
            os.close(self.directory.open_directory(parts))
            return
        self.file = self.directory.open_file(parts)
        quarantine_file(self.file.fileno())
        self.count += 1


class ContainerDecoder:
    def __init__(self, parser, content_type):
        self.parser = parser
        self.dvzip = content_type == "application/x-dvzip"
        self.pending = bytearray()
        self.block = None
        self.stored = False
        self.gzip = None
        self.detected = False
        self.terminated = False
        self.decoded_bytes = 0

    @property
    def done(self):
        if self.dvzip:
            return self.parser.done and not self.pending and self.block is None
        return self.parser.done and (self.gzip is None or self.gzip.eof)

    def feed(self, data):
        if self.dvzip:
            self._dvzip(data)
        else:
            self._cpio(data)

    def _decoded(self, data):
        # Count the entire decoded cpio stream, including headers and padding.
        self.decoded_bytes += len(data)
        self.parser.feed(data)

    def _dvzip(self, data):
        self.pending.extend(data)
        while True:
            if self.terminated:
                if self.pending:
                    raise ArchiveError(message("Unexpected data after the end of the AirDrop container.", "Dane po zakończeniu kontenera AirDrop."))
                return
            if self.block is None:
                if len(self.pending) < 4:
                    return
                value = struct.unpack(">I", self.pending[:4])[0]
                del self.pending[:4]
                self.stored = bool(value & 0x80000000)
                self.block = value & 0x7fffffff
                if self.block == 0:
                    if not self.parser.done:
                        raise ArchiveError(message("The container ended before the complete archive was received.", "Kontener zakończył się przed pełnym archiwum."))
                    self.terminated = True
                    self.block = None
                    continue
                if self.block > MAX_BLOCK:
                    raise ArchiveError(message("The data block in the AirDrop container is too large.", "Zbyt duży blok danych w kontenerze AirDrop."))
            if len(self.pending) < self.block:
                return
            payload = bytes(self.pending[:self.block])
            del self.pending[:self.block]
            self.block = None
            if self.stored:
                self._decoded(payload)
            else:
                decoder = zlib.decompressobj()
                decoded = decoder.decompress(payload, MAX_BLOCK + 1)
                if len(decoded) > MAX_BLOCK or decoder.unconsumed_tail or not decoder.eof or decoder.unused_data:
                    raise ArchiveError(message("Invalid compressed AirDrop block.", "Nieprawidłowy skompresowany blok AirDrop."))
                self._decoded(decoded)

    def _cpio(self, data):
        if not self.detected:
            self.pending.extend(data)
            if len(self.pending) < 2:
                return
            data = bytes(self.pending)
            self.pending.clear()
            self.gzip = zlib.decompressobj(16 + zlib.MAX_WBITS) if data[:2] == b"\x1f\x8b" else None
            self.detected = True
        if self.gzip is None:
            self._decoded(data)
        else:
            while data:
                decoded = self.gzip.decompress(data, MAX_BLOCK)
                self._decoded(decoded)
                data = self.gzip.unconsumed_tail
                if self.gzip.unused_data:
                    raise ArchiveError(message("Unexpected data after the end of the compressed archive.", "Dane po zakończeniu skompresowanego archiwum."))

    def finish(self):
        if not self.done or (self.dvzip and (self.pending or self.block is not None)):
            raise ArchiveError(message("The transfer was interrupted before the complete archive was received.", "Transfer został przerwany przed odebraniem całego archiwum."))
        if self.parser.count == 0:
            raise ArchiveError(message("The transfer contains no supported files.", "Przesyłka nie zawiera obsługiwanych plików."))
