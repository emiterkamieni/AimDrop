"""Durable, app-managed downloads awaiting a user-selected destination."""
import fcntl
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
from .localization import message
from .retention import DAY_NS, retention_days


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _sync(directory):
    fd = os.open(directory, DIRECTORY_FLAGS)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_json(path, value):
    temporary = path.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as target:
        json.dump(value, target, ensure_ascii=True)
        target.flush()
        os.fsync(target.fileno())
    os.replace(temporary, path)
    _sync(path.parent)


def _read_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r", encoding="utf-8") as source:
        return json.load(source), os.fstat(source.fileno()).st_mtime_ns


def _walk(fd, names, prefix=()):
    """Yield entries while their parent descriptors remain open; never follow links."""
    for name in names:
        entry = os.stat(name, dir_fd=fd, follow_symlinks=False)
        parts = prefix + (name,)
        if not (stat.S_ISREG(entry.st_mode) or stat.S_ISDIR(entry.st_mode)):
            raise ValueError(message("The buffer contains a symbolic link or an unsupported file type.", "Bufor zawiera dowiązanie lub nieobsługiwany typ pliku."))
        yield fd, parts, entry
        if stat.S_ISDIR(entry.st_mode):
            child = os.open(name, DIRECTORY_FLAGS, dir_fd=fd)
            try:
                yield from _walk(child, sorted(os.listdir(child)), parts)
            finally:
                os.close(child)


class Inbox:
    def __init__(self, root: Path, days=7, automatic_trash=True, clock=None):
        root = Path(root)
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.root = root.resolve(strict=True)
        self._guard = threading.Lock()
        self._locks = {}
        self._reservations = {}
        self._draining = False
        self.clock = clock or time.time_ns
        self.days = retention_days(days)
        self.automatic_trash = automatic_trash
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
        migration = self.root / ".retention-migration.json"
        try:
            self._migration, _ = _read_json(migration)
            self._validate_retention(self._migration)
        except FileNotFoundError:
            start = self.clock()
            self._migration = dict(retention_started_at_ns=start, retention_days=self.days,
                                   expires_at_ns=start + self.days * DAY_NS)
            _write_json(migration, self._migration)
        self.recover_operations()
        # Materialize the grace period once, before publishing the initial list.
        self.list_ready()

    def configure_retention(self, days, enabled):
        days = retention_days(days)
        if type(enabled) is not bool:
            raise ValueError("Invalid retention switch")
        with self._guard:
            self.days, self.automatic_trash = days, enabled

    @staticmethod
    def _validate_retention(data):
        days = retention_days(data["retention_days"])
        start, end = data["retention_started_at_ns"], data["expires_at_ns"]
        if type(start) is not int or type(end) is not int or start <= 0 or end != start + days * DAY_NS:
            raise ValueError("Invalid receipt deadline")

    def reserve(self, ident, kind, token=None):
        job, _ = self._job(ident)
        ident = job.name
        with self._guard:
            old = self._reservations.get(ident)
            if self._draining and not (old == ("hold", token) and kind in ("save", "trash")):
                return None
            if old is not None and not (old == ("hold", token) and kind in ("save", "trash")):
                return None
            if (not (job / "ready.json").is_file() or os.path.lexists(job / "retired.json")
                    or os.path.lexists(job / "trash.json")):
                return None
            value = token if (old or kind == "hold") and token else str(uuid.uuid4())
            self._reservations[ident] = (kind, value)
            return value

    def release(self, ident, token):
        ident = str(uuid.UUID(ident))
        with self._guard:
            old = self._reservations.get(ident)
            if old is not None and old[1] == token:
                self._reservations.pop(ident)

    def drain(self, enabled):
        with self._guard:
            self._draining = enabled

    def has_reservations(self):
        with self._guard:
            return bool(self._reservations)

    def _job(self, ident):
        ident = str(uuid.UUID(ident))
        job = self.root / ident
        if job.is_symlink():
            raise ValueError(message("The buffer folder cannot be a symbolic link.", "Folder bufora nie może być dowiązaniem."))
        with self._guard:
            lock = self._locks.setdefault(ident, threading.RLock())
        return job, lock

    @staticmethod
    def _info(job, count, files):
        if type(count) is not int or count < 0 or not isinstance(files, list) or not files:
            raise ValueError(message("Invalid buffer metadata.", "Nieprawidłowe metadane bufora."))
        if any(not isinstance(name, str) or name in ("", ".", "..")
               or Path(name).name != name or "\0" in name for name in files):
            raise ValueError(message("Invalid name in the buffer.", "Nieprawidłowa nazwa w buforze."))
        if len(set(files)) != len(files):
            raise ValueError(message("Duplicate path in the buffer metadata.", "Powtórzona ścieżka w metadanych bufora."))
        return dict(id=job.name, count=count, files=files,
                    paths=[str(job / "payload" / name) for name in files])

    def _read(self, job):
        if os.path.lexists(job / "retired.json") or os.path.lexists(job / "trash.json"):
            raise FileNotFoundError("Transfer is no longer ready")
        data, legacy_time = _read_json(job / "ready.json")
        info = self._info(job, data["count"], data["files"])
        received = data.get("received_at_ns", legacy_time)
        if type(received) is not int or received <= 0:
            raise ValueError("Invalid receipt time")
        if not any(key in data for key in self._migration):
            data.update(self._migration)
            data["received_at_ns"] = received
            _write_json(job / "ready.json", data)
        self._validate_retention(data)
        return dict(info, received_at_ns=received, **{key: data[key] for key in self._migration})

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
                raise FileExistsError(message("The transfer is already ready to save.", "Przesyłka jest już gotowa do zapisania."))
            paths = [Path(os.path.abspath(path)) for path in paths]
            if any(path.parent != job / "payload" for path in paths):
                raise ValueError(message("The path is outside the transfer buffer.", "Ścieżka wychodzi poza bufor przesyłki."))
            info = self._info(job, count, [path.name for path in paths])
            fd = os.open(job / "payload", DIRECTORY_FLAGS)
            try:
                for _ in _walk(fd, info["files"]):
                    pass
                os.fsync(fd)
            finally:
                os.close(fd)
            with self._latest_lock:
                received = max(self.clock(), (self._latest or {}).get("received_at_ns", 0) + 1)
                with self._guard:
                    days = self.days
                temporary = job / "ready.tmp"
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as target:
                    json.dump(dict(count=count, files=info["files"], received_at_ns=received,
                                   retention_started_at_ns=received, retention_days=days,
                                   expires_at_ns=received + days * DAY_NS), target, ensure_ascii=True)
                    target.flush()
                    os.fsync(target.fileno())
                os.replace(temporary, job / "ready.json")
                _sync(job)
                self._latest = dict(id=info["id"], received_at_ns=received)
                self._latest_invalid = False
                self._persist_latest()
            return self._read(job)

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

    def _retire(self, job, reason):
        try:
            _write_json(job / "retired.json", dict(reason=reason))
        except OSError:
            # A directory sync may fail after the atomic marker publication.
            # The destination has already been committed; do not reoffer it.
            try:
                marker, _ = _read_json(job / "retired.json")
            except (OSError, ValueError):
                raise
            if marker != dict(reason=reason):
                raise
        try:
            (job / "ready.json").unlink()
            _sync(job)
        except OSError:
            pass  # The durable retired marker already prevents another save.

    @staticmethod
    def _cleanup_retired_job(job):
        try:
            # Keep the retirement proof until the last payload byte is removed.
            for child in job.iterdir():
                if child.name == "retired.json":
                    continue
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()
            (job / "retired.json").unlink()
            job.rmdir()
        except OSError:
            pass

    def cleanup_retired(self):
        for path in self.root.iterdir():
            try:
                job, lock = self._job(path.name)
                if not lock.acquire(blocking=False):
                    continue
                try:
                    data, _ = _read_json(job / "retired.json")
                    if data == {"reason": "saved"} or data == {"reason": "trashed"}:
                        self._cleanup_retired_job(job)
                finally:
                    lock.release()
            except (OSError, ValueError, TypeError, KeyError):
                continue

    def recover_operations(self):
        recovered = []
        for path in self.root.iterdir():
            try:
                job, lock = self._job(path.name)
                if not lock.acquire(blocking=False):
                    continue
                try:
                    if not (job / "trash.json").exists() or (job / "retired.json").exists():
                        continue
                    fd = os.open(job / ".operation.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        data, _ = _read_json(job / "trash.json")
                        name = data["folder"]
                        if not isinstance(name, str) or not name.startswith("AimDrop ") or Path(name).name != name:
                            continue
                        source, payload = job / name, job / "payload"
                        outcome = "restored"
                        if source.is_symlink() or payload.is_symlink():
                            continue
                        if source.is_dir() and not payload.exists():
                            os.rename(source, payload)
                        elif source.exists():
                            continue
                        elif not payload.exists():
                            self._retire(job, "trashed")
                            outcome = "trashed"
                        (job / "trash.json").unlink()
                        _sync(job)
                        recovered.append((job.name, outcome))
                    finally:
                        os.close(fd)
                finally:
                    lock.release()
            except (OSError, ValueError, TypeError, KeyError):
                continue
        return recovered

    def trash(self, ident, move_to_trash):
        job, lock = self._job(ident)
        with lock:
            info = self._read(job)
            # Move the entire payload as one directory, keeping receipt/journal
            # outside it so a lost acknowledgement can be recovered after restart.
            stamp = time.strftime("%Y-%m-%d %H-%M-%S", time.localtime(info["received_at_ns"] / 1e9))
            name = "AimDrop " + stamp + " " + job.name
            source = job / name
            fd = os.open(job / ".operation.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                _write_json(job / "trash.json", dict(folder=name))
                staged = False
                try:
                    os.rename(job / "payload", source)
                    staged = True
                    _sync(job)
                    move_to_trash(source, fd)
                    if source.exists():
                        raise OSError("Trash helper did not move the transfer")
                except Exception:
                    if not staged:
                        (job / "trash.json").unlink()
                        _sync(job)
                        raise
                    if source.exists():
                        os.rename(source, job / "payload")
                        (job / "trash.json").unlink()
                        _sync(job)
                        raise
                    if (job / "payload").exists():
                        (job / "trash.json").unlink()
                        _sync(job)
                        raise
                    # The OS completed the move, but the helper's reply was lost.
                self._retire(job, "trashed")
            finally:
                os.close(fd)
            self._cleanup_retired_job(job)

    def save(self, id: str, destination: str, progress=None) -> dict:
        job, lock = self._job(id)
        with lock:
            info = self._read(job)
            destination = Path(destination).resolve(strict=True)
            # samefile also catches alternate casing on case-insensitive Mac volumes.
            if any(parent.samefile(self.root) for parent in (destination, *destination.parents)):
                raise ValueError(message("Files cannot be saved inside the receive buffer.", "Nie można zapisywać plików wewnątrz bufora odbioru."))
            directory = ReceiveDirectory(destination)
            try:
                fd = os.open(job / "payload", DIRECTORY_FLAGS)
                try:
                    sizes = [entry.st_size for _, _, entry in _walk(fd, info["files"])
                             if stat.S_ISREG(entry.st_mode)]
                    status = dict(bytes=0, total_bytes=sum(sizes), files_received=0, total_files=len(sizes))
                    if status["total_bytes"] > directory.limit:
                        raise OSError(message("There is not enough space in the selected folder.", "Za mało miejsca w wybranym folderze."))

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
                                raise ValueError(message("A file in the buffer has been changed.", "Plik w buforze został zmieniony."))
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
                self._retire(job, "saved")
            except Exception as error:
                if directory.published:
                    raise RuntimeError(message("%s; files already saved: %s", "%s; już zapisane pliki: %s",
                                               error, ", ".join(str(path) for path in directory.published))) from error
                raise
            finally:
                directory.close()
            self._cleanup_retired_job(job)
            return result
