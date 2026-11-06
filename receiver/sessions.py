"""Single-use consent bound to the scoped peer address and AirDrop TransferID."""
import base64
from dataclasses import dataclass, field
from pathlib import Path
import logging
import threading
import time
import uuid

from .archive import ReceiveDirectory
from .layout import selections
from .localization import message


class Refused(Exception):
    pass


def transfer_id(value):
    if isinstance(value, dict):
        value = value.get("id")
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError) as error:
        raise Refused(message("A valid transfer identifier is missing.", "Brak poprawnego identyfikatora przesyłki.")) from error


def peer_key(address):
    # IPv6 link-local addresses are only unique within an interface scope.
    return address[0], address[3] if len(address) > 3 else 0


def display_text(value, maximum=240):
    text = str(value)
    return "".join(char for char in text if char.isprintable())[:maximum]


@dataclass
class Offer:
    transfer: str
    peer: tuple
    sender: str
    files: tuple
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    decision: threading.Event = field(default_factory=threading.Event)
    directory: str = ""
    state: str = "waiting"
    deadline: float = 0
    canceled: threading.Event = field(default_factory=threading.Event)
    storage: object = None
    selection: tuple = ()
    folders: tuple = ()
    preview: str = None


class Sessions:
    def __init__(self, emit, chooser_timeout=120, upload_timeout=90,
                 prepare_destination=None, abandon_destination=None):
        self.emit = emit
        self.chooser_timeout = chooser_timeout
        self.upload_timeout = upload_timeout
        self.lock = threading.RLock()
        self.current = None
        self.paused = False
        self.stopped = False
        self.recent = {}
        self.prepare_destination = prepare_destination
        self.abandon_destination = abandon_destination

    def offer(self, request, address):
        ident = transfer_id(request.get("TransferID"))
        files = request.get("Files")
        if not isinstance(files, list) or not files or len(files) > 10000:
            raise Refused(message("Only file transfers are supported, not links or other items.", "Obsługiwane jest przesyłanie plików, nie linków ani innych rzeczy."))
        if any(not isinstance(item, dict) or not isinstance(item.get("FileName"), str) for item in files):
            raise Refused(message("Invalid file list.", "Nieprawidłowa lista plików."))
        names = tuple(display_text(item["FileName"]) for item in files)
        try:
            selected = selections(files)
        except ValueError as error:
            raise Refused(str(error)) from error
        key = peer_key(address)
        with self.lock:
            self.expire()
            if self.paused or self.stopped:
                raise Refused(message("Receiving is paused.", "Odbieranie jest wstrzymane."))
            if (ident, key) in self.recent:
                raise Refused(message("This transfer has already finished or been declined.", "Ta przesyłka została już zakończona lub odrzucona."))
            if self.current:
                existing = self.current
                if (existing.transfer == ident and existing.peer == key
                        and existing.selection == selected and existing.state in ("waiting", "accepted")):
                    return existing
                raise Refused(message("Another transfer is already being handled.", "Inna przesyłka jest już obsługiwana."))
            offer = Offer(ident, key, display_text(request.get("SenderComputerName", "iPhone")), names,
                          selection=selected,
                          folders=tuple(display_text(item.name) for item in selected if item.is_directory))
            icon = request.get("FileIcon")
            if isinstance(icon, bytes) and len(icon) <= 512 * 1024:
                offer.preview = base64.b64encode(icon).decode("ascii")
            offer.deadline = time.monotonic() + self.chooser_timeout
            self.current = offer
        if self.prepare_destination is None:
            self.emit("offer", id=offer.id, sender=offer.sender, files=list(offer.files))
        else:
            self.emit("incoming", id=offer.id, sender=offer.sender, files=list(offer.files),
                      folders=list(offer.folders),
                      **({"preview": offer.preview} if offer.preview is not None else {}))
            try:
                destination = self.prepare_destination(offer.id)
                accepted = self.decide(offer.id, True, destination)
                if not accepted:
                    raise Refused(message("Cannot prepare the receive buffer.", "Nie można przygotować bufora odbioru."))
            except Exception as error:
                with self.lock:
                    canceled = offer.canceled.is_set()
                    if self.current is offer:
                        self._close(offer, "buffer_unavailable")
                    elif self.abandon_destination:
                        self.abandon_destination(offer.id)
                if not canceled:
                    self.emit("error", id=offer.id, message=str(message("Cannot prepare the receive buffer: %s", "Nie można przygotować bufora odbioru: %s", error)))
                raise Refused(message("The receive buffer is unavailable.", "Bufor odbioru jest niedostępny.")) from error
        return offer

    def wait(self, offer):
        offer.decision.wait(max(0, offer.deadline - time.monotonic()))
        with self.lock:
            if offer.state == "waiting":
                self._close(offer, "timeout")
            if (offer.state not in ("accepted", "receiving", "finished")
                    or (offer.state != "finished" and self.current is not offer)):
                raise Refused(message("The transfer was not accepted.", "Przesyłka nie została zaakceptowana."))
            return offer

    def decide(self, ident, accepted, directory=None):
        with self.lock:
            offer = self.current
            if not offer or offer.id != ident or offer.state != "waiting":
                return False
            if time.monotonic() >= offer.deadline or not accepted:
                self._close(offer, "declined")
                return False
            try:
                if not isinstance(directory, str) or not Path(directory).is_absolute():
                    raise ValueError(message("Choose an absolute folder path.", "Wybierz pełną ścieżkę folderu."))
                destination = Path(directory).resolve(strict=True)
                if not destination.is_dir():
                    raise ValueError(message("The selected location is not a folder.", "Wybrane miejsce nie jest folderem."))
                offer.storage = ReceiveDirectory(destination)
            except (OSError, ValueError, RuntimeError) as error:
                self._close(offer, "invalid_destination")
                self.emit("error", message=str(message("Cannot use the selected folder: %s", "Nie można użyć wybranego folderu: %s", error)))
                return False
            offer.directory = str(destination)
            offer.state = "accepted"
            offer.deadline = time.monotonic() + self.upload_timeout
            offer.decision.set()
            log_message = "Receive buffer prepared" if self.prepare_destination else "Destination selected"
            logging.getLogger(__name__).info("%s; transfer accepted, awaiting payload", log_message)
            self.emit("accepted", id=offer.id)
            return True

    def claim(self, ident, address):
        ident = transfer_id(ident)
        with self.lock:
            self.expire()
            offer = self.current
            if (self.paused or self.stopped or not offer or offer.state != "accepted"
                    or offer.transfer != ident or offer.peer != peer_key(address)):
                raise Refused(message("The transfer has no valid receive consent.", "Transfer nie ma ważnej zgody na odbiór."))
            offer.state = "receiving"
            return offer

    def finish(self, offer):
        with self.lock:
            if self.current is offer:
                offer.state = "finished"
                self.recent[(offer.transfer, offer.peer)] = time.monotonic() + 300
                self.current = None

    def cancel(self, ident):
        with self.lock:
            offer = self.current
            if not offer or offer.id != ident:
                return False
            self._close(offer, "canceled")
            self.emit("canceled", id=offer.id, phase="receiving")
            return True

    def _close(self, offer, reason):
        receiving = offer.state == "receiving"
        offer.state = "closed"
        offer.canceled.set()
        offer.decision.set()
        if self.current is offer:
            self.current = None
        self.recent[(offer.transfer, offer.peer)] = time.monotonic() + 300
        if offer.storage and not receiving:
            offer.storage.close()
        if not receiving and self.abandon_destination:
            self.abandon_destination(offer.id)
        self.emit("offer_closed", id=offer.id, reason=reason)

    def expire(self):
        with self.lock:
            now = time.monotonic()
            self.recent = {key: deadline for key, deadline in self.recent.items() if deadline > now}
            offer = self.current
            if offer and offer.state in ("waiting", "accepted") and time.monotonic() >= offer.deadline:
                self._close(offer, "timeout")

    def pause(self, paused):
        with self.lock:
            self.paused = paused
            if paused and self.current and self.current.state != "receiving":
                self._close(self.current, "paused")
        self.emit("paused", paused=paused)

    def close(self):
        with self.lock:
            self.stopped = True
            if self.current:
                self._close(self.current, "shutdown")
