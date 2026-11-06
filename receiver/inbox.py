"""Durable, app-managed downloads awaiting a user-selected destination."""
import json
import logging
import os
from pathlib import Path
import shutil
import stat
import threading
import time
import uuid

from .archive import ReceiveDirectory, quarantine_file


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _sync(directory):
    fd = os.open(directory, DIRECTORY_FLAGS)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _walk(fd, names, prefix=()):
    """Yield entries while their parent descriptors remain open; never follow links."""
    for name in names:
        entry = os.stat(name, dir_fd=fd, follow_symlinks=False)
        parts = prefix + (name,)
        if not (stat.S_ISREG(entry.st_mode) or stat.S_ISDIR(entry.st_mode)):
            raise ValueError("Bufor zawiera dowiązanie lub nieobsługiwany typ pliku.")
        yield fd, parts, entry
        if stat.S_ISDIR(entry.st_mode):
            child = os.open(name, DIRECTORY_FLAGS, dir_fd=fd)
            try:
                yield from _walk(child, sorted(os.listdir(child)), parts)
            finally:
                os.close(child)


class Inbox:
    def __init__(self, root: Path):
        root = Path(root)
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.root = root.resolve(strict=True)
        self._guard = threading.Lock()
        self._locks = {}
        self._latest_lock = threading.Lock()
        self._latest = None
        self._latest_invalid = False
        try:
            fd = os.open(self.root / ".latest-received.json", os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "r", encoding="utf-8") as source:
                value = json.load(source)
            value["id"] = str(uuid.UUID(value["id"]))
            if type(value["received_at_ns"]) is not int or value["received_at_ns"] <= 0:
                raise ValueError("Invalid receipt time")
            self._latest = value
        except FileNotFoundError:
            pass
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            # Unknown history must not expose an older job as the last transfer.
            self._latest_invalid = True

    def _job(self, ident):
        ident = str(uuid.UUID(ident))
        job = self.root / ident
        if job.is_symlink():
            raise ValueError("Folder bufora nie może być dowiązaniem.")
        with self._guard:
            lock = self._locks.setdefault(ident, threading.RLock())
        return job, lock

    @staticmethod
    def _info(job, count, files):
        if type(count) is not int or count < 0 or not isinstance(files, list) or not files:
            raise ValueError("Nieprawidłowe metadane bufora.")
        if any(not isinstance(name, str) or name in ("", ".", "..")
               or Path(name).name != name or "\0" in name for name in files):
            raise ValueError("Nieprawidłowa nazwa w buforze.")
        if len(set(files)) != len(files):
            raise ValueError("Powtórzona ścieżka w metadanych bufora.")
        return dict(id=job.name, count=count, files=files,
                    paths=[str(job / "payload" / name) for name in files])

    def _read(self, job):
        fd = os.open(job / "ready.json", os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r", encoding="utf-8") as source:
            data = json.load(source)
        return self._info(job, data["count"], data["files"])

    def prepare(self, id: str) -> str:
        job, lock = self._job(id)
        with lock:
            job.mkdir(mode=0o700)  # Existing jobs, particularly ready ones, are never reset.
            (job / "payload").mkdir(mode=0o700)
            _sync(job)
            _sync(self.root)
            return str(job / "payload")

    def record(self, id: str, paths, count: int) -> dict:
        job, lock = self._job(id)
        with lock:
            if os.path.lexists(job / "ready.json"):
                raise FileExistsError("Przesyłka jest już gotowa do zapisania.")
            paths = [Path(os.path.abspath(path)) for path in paths]
            if any(path.parent != job / "payload" for path in paths):
                raise ValueError("Ścieżka wychodzi poza bufor przesyłki.")
            info = self._info(job, count, [path.name for path in paths])
            fd = os.open(job / "payload", DIRECTORY_FLAGS)
            try:
                for _ in _walk(fd, info["files"]):
                    pass
                os.fsync(fd)
            finally:
                os.close(fd)
            with self._latest_lock:
                received = max(time.time_ns(), (self._latest or {}).get("received_at_ns", 0) + 1)
                temporary = job / "ready.tmp"
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as target:
                    json.dump(dict(count=count, files=info["files"], received_at_ns=received), target, ensure_ascii=True)
                    target.flush()
                    os.fsync(target.fileno())
                os.replace(temporary, job / "ready.json")
                _sync(job)
                self._latest = dict(id=info["id"], received_at_ns=received)
                self._latest_invalid = False
                self._persist_latest()
            return info

    def _persist_latest(self):
        # Keep the last ID even after its ready marker is retired by save().
        # Otherwise saving the newest job would resurrect an older menu target.
        try:
            temporary = self.root / ".latest-received.tmp"
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as target:
                json.dump(self._latest, target)
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary, self.root / ".latest-received.json")
            _sync(self.root)
        except OSError:
            # The payload is already durable. Its receipt timestamp permits
            # recovery if the small menu-history write was interrupted.
            logging.getLogger("airfrajer").warning("Could not persist latest received transfer")

    def latest_received_id(self):
        with self._latest_lock:
            if self._latest_invalid:
                return None
            newest = self._latest
            for path in self.root.iterdir():
                try:
                    job, _ = self._job(path.name)
                    fd = os.open(job / "ready.json", os.O_RDONLY | os.O_NOFOLLOW)
                    with os.fdopen(fd, "r", encoding="utf-8") as source:
                        legacy_time = os.fstat(source.fileno()).st_mtime_ns
                        data = json.load(source)
                    self._info(job, data["count"], data["files"])
                    received = data.get("received_at_ns", legacy_time)
                    if type(received) is not int or received <= 0:
                        continue
                    if newest is None or received > newest["received_at_ns"]:
                        newest = dict(id=job.name, received_at_ns=received)
                except (OSError, ValueError, TypeError, KeyError):
                    continue
            if newest != self._latest:
                self._latest = newest
                self._persist_latest()
            return self._latest["id"] if self._latest else None

    def list_ready(self) -> list:
        ready = []
        for path in sorted(self.root.iterdir()):
            try:
                job, lock = self._job(path.name)
                # A final copy can be long-running. Listing must not block the
                # UI command reader (including pause/defer/shutdown) behind it.
                if not lock.acquire(blocking=False):
                    continue
                try:
                    ready.append(self._read(job))
                finally:
                    lock.release()
            except (OSError, ValueError, TypeError, KeyError):
                continue  # Incomplete jobs and damaged metadata are kept, not exposed or deleted.
        return ready

    def abandon(self, id: str):
        job, lock = self._job(id)
        with lock:
            if job.exists() and not os.path.lexists(job / "ready.json"):
                shutil.rmtree(job)

    def save(self, id: str, destination: str, progress=None) -> dict:
        job, lock = self._job(id)
        with lock:
            info = self._read(job)
            destination = Path(destination).resolve(strict=True)
            # samefile also catches alternate casing on case-insensitive Mac volumes.
            if any(parent.samefile(self.root) for parent in (destination, *destination.parents)):
                raise ValueError("Nie można zapisywać plików wewnątrz bufora odbioru.")
            directory = ReceiveDirectory(destination)
            try:
                fd = os.open(job / "payload", DIRECTORY_FLAGS)
                try:
                    sizes = [entry.st_size for _, _, entry in _walk(fd, info["files"])
                             if stat.S_ISREG(entry.st_mode)]
                    status = dict(bytes=0, total_bytes=sum(sizes), files_received=0, total_files=len(sizes))
                    if status["total_bytes"] > directory.limit:
                        raise OSError("Za mało miejsca w wybranym folderze.")

                    def report():
                        if progress is not None:
                            progress(dict(status))

                    report()
                    for parent, parts, entry in _walk(fd, info["files"]):
                        if stat.S_ISDIR(entry.st_mode):
                            os.close(directory.open_directory(parts))
                            continue
                        source_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                            dir_fd=parent)
                        with os.fdopen(source_fd, "rb") as source:
                            actual = os.fstat(source.fileno())
                            if (not stat.S_ISREG(actual.st_mode)
                                    or (actual.st_dev, actual.st_ino, actual.st_size)
                                    != (entry.st_dev, entry.st_ino, entry.st_size)):
                                raise ValueError("Plik w buforze został zmieniony.")
                            with directory.open_file(parts) as target:
                                quarantine_file(target.fileno())
                                while True:
                                    chunk = source.read(1024 * 1024)
                                    if not chunk:
                                        break
                                    target.write(chunk)
                                    status["bytes"] += len(chunk)
                                    report()
                                target.flush()
                                os.fsync(target.fileno())
                        status["files_received"] += 1
                        report()
                finally:
                    os.close(fd)
                report()  # Last cooperative cancellation check before publishing any item.
                paths = directory.publish()
                os.fsync(directory.destination_fd)
                result = dict(id=info["id"], count=info["count"], directory=str(destination),
                              paths=[str(path) for path in paths])
                # Publication is the commit point. Retire the ready marker before cleanup
                # so an interrupted cleanup cannot offer an already-saved job again.
                (job / "ready.json").unlink()
            except Exception as error:
                if directory.published:
                    raise RuntimeError("%s; już zapisane pliki: %s" %
                                       (error, ", ".join(str(path) for path in directory.published))) from error
                raise
            finally:
                directory.close()
            shutil.rmtree(job, ignore_errors=True)
            return result
