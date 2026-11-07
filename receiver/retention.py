"""Receipt-local deadlines and a background inbox maintenance queue."""
import logging
import queue
import threading
import time
import uuid

from .localization import error_message, message

DAY_NS = 86400 * 1_000_000_000
MAX_DAYS = 36500  # Keep nanosecond dates within the signed 64-bit IPC range.


def retention_days(value):
    if type(value) is not int or not 1 <= value <= MAX_DAYS:
        raise ValueError(message("Enter a whole number of days between 1 and 36500.",
                                 "Podaj całkowitą liczbę dni od 1 do 36500."))
    return value


class InboxMaintenance:
    def __init__(self, inbox, trash, emit, stopped, interval=60):
        self.inbox, self.trash_item, self.emit, self.stopped = inbox, trash, emit, stopped
        self.interval = interval
        self.requests = queue.Queue()
        self.lock = threading.RLock()
        self.draining = False
        self.working = False
        self.thread = threading.Thread(target=self._run, name="inbox-maintenance", daemon=True)

    def start(self):
        self.thread.start()

    def wake(self):
        self.requests.put(None)

    def trash(self, ident, token=None, automatic=False):
        operation = self.inbox.reserve(ident, "trash", token)
        if operation is None:
            return False
        self.emit("trashing", id=ident)
        self.requests.put((ident, operation, automatic))
        return True

    def trash_many(self, identifiers):
        if not isinstance(identifiers, list) or not 1 <= len(identifiers) <= 512:
            raise ValueError("Invalid transfer batch")
        # Validate the entire command before starting any filesystem operation.
        identifiers = list(dict.fromkeys(str(uuid.UUID(value)) for value in identifiers))
        started, skipped = [], []
        for ident in identifiers:
            (started if self.trash(ident) else skipped).append(ident)
        return dict(started=started, skipped=skipped)

    def sweep(self):
        with self.lock:
            if self.draining:
                return
            self._sweep()

    def drain(self, enabled):
        with self.lock:
            self.draining = enabled
        self.wake()

    def is_busy(self):
        with self.lock:
            return self.working

    def _sweep(self):
        recovered = self.inbox.recover_operations()
        self.inbox.cleanup_retired()
        if recovered:
            for ident, outcome in recovered:
                if outcome == "trashed":
                    self.emit("trashed", id=ident)
            self.emit("pending", transfers=self.inbox.list_ready())
        if self.inbox.automatic_trash:
            now = self.inbox.clock()
            for receipt in self.inbox.list_ready():
                if receipt["expires_at_ns"] <= now:
                    self.trash(receipt["id"], automatic=True)

    def _perform(self, ident, token, automatic):
        with self.lock:
            self.working = True
        try:
            self._perform_reserved(ident, token, automatic)
        finally:
            with self.lock:
                self.working = False

    def _perform_reserved(self, ident, token, automatic):
        try:
            # A queued automatic request may have been overtaken by disabling it.
            if self.stopped.is_set() or (automatic and not self.inbox.automatic_trash):
                self.emit("trash_canceled", id=ident)
                return
            self.inbox.trash(ident, self.trash_item)
            self.emit("trashed", id=ident)
        except Exception as error:
            logging.getLogger("airfrajer").warning("Could not trash transfer (%s)", type(error).__name__)
            self.emit("error", id=ident, phase="trashing", automatic=automatic, message=error_message(error))
        finally:
            self.inbox.release(ident, token)
            if not self.stopped.is_set():
                self.emit("pending", transfers=self.inbox.list_ready())

    def _run(self):
        deadline = 0
        while not self.stopped.is_set():
            if time.monotonic() >= deadline:
                try:
                    self.sweep()
                except (OSError, ValueError):
                    logging.getLogger("airfrajer").warning("Could not inspect inbox maintenance state")
                deadline = time.monotonic() + self.interval
            try:
                request = self.requests.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                continue
            if request is None:
                deadline = 0
            else:
                self._perform(*request)

    def close(self):
        self.wake()
        if self.thread.ident is not None:
            self.thread.join(timeout=65)
