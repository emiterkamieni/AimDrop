"""AirDrop's small HTTPS surface, with explicit consent before reading Upload."""
import logging
import plistlib
import socket
from socketserver import TCPServer
import ssl
import threading
import time
import uuid
from time import perf_counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .archive import ArchiveError, ContainerDecoder, ODCParser
from .configuration import normalized_receiver_name
from .layout import SelectionLayout
from .localization import error_message, message, text
from .media import LEGACY_CAPABILITIES
from .sessions import Refused

LOG = logging.getLogger(__name__)
MAX_METADATA = 8 * 1024 * 1024
READ_SIZE = 64 * 1024


class HTTPError(ValueError):
    pass


def exact(stream, length):
    data = bytearray()
    while len(data) < length:
        part = stream.read(length - len(data))
        if not part:
            raise HTTPError(message("The connection was interrupted while receiving data.", "Połączenie przerwano w środku danych."))
        data.extend(part)
    return bytes(data)


def decoded_size_hint(headers, chunked):
    """TotalBytes is an optional sender estimate, never a framing/size check."""
    values = headers.get_all("TotalBytes", []) if chunked else []
    if len(values) != 1:
        return None
    value = values[0].strip(" \t")
    if not value or any(char not in "0123456789" for char in value):
        return None
    value = value.lstrip("0")
    if not value or len(value) > 19:
        return None
    number = int(value)
    return number if number <= (1 << 63) - 1 else None


class Body:
    def __init__(self, stream, headers, limit):
        self.stream = stream
        self.limit = limit
        self.total = 0
        self.remaining = 0
        self.finished = False
        encodings = headers.get_all("Transfer-Encoding", [])
        lengths = headers.get_all("Content-Length", [])
        if len(encodings) > 1 or len(lengths) > 1 or (encodings and lengths):
            raise HTTPError(message("Ambiguous request size.", "Niejednoznaczny rozmiar żądania."))
        self.chunked = bool(encodings)
        if self.chunked:
            if encodings[0].strip().lower() != "chunked":
                raise HTTPError(message("Unsupported transfer encoding.", "Nieobsługiwany sposób przesyłania danych."))
        else:
            if not lengths or not lengths[0].strip().isdigit():
                raise HTTPError(message("A valid request size is missing.", "Brak poprawnego rozmiaru żądania."))
            self.remaining = int(lengths[0])
            if self.remaining > limit:
                raise HTTPError(message("The transfer exceeds the available space limit.", "Przesyłka przekracza dostępny limit miejsca."))

    def read(self):
        if self.finished:
            return b""
        if self.chunked and self.remaining == 0:
            line = self.stream.readline(1025)
            if not line.endswith(b"\r\n") or len(line) > 1024:
                raise HTTPError(message("Invalid data chunk header.", "Nieprawidłowy nagłówek fragmentu danych."))
            number = line[:-2].split(b";", 1)[0]
            if not number or any(char not in b"0123456789abcdefABCDEF" for char in number):
                raise HTTPError(message("Invalid data chunk size.", "Nieprawidłowy rozmiar fragmentu danych."))
            self.remaining = int(number, 16)
            if self.remaining > self.limit - self.total:
                raise HTTPError(message("The transfer exceeds the available space limit.", "Przesyłka przekracza dostępny limit miejsca."))
            if self.remaining == 0:
                trailer_bytes = 0
                while True:
                    trailer = self.stream.readline(8193)
                    trailer_bytes += len(trailer)
                    if not trailer.endswith(b"\r\n") or trailer_bytes > 8192:
                        raise HTTPError(message("Invalid request ending.", "Nieprawidłowe zakończenie żądania."))
                    if trailer == b"\r\n":
                        break
                self.finished = True
                return b""
        if not self.remaining:
            self.finished = True
            return b""
        data = exact(self.stream, min(READ_SIZE, self.remaining))
        self.remaining -= len(data)
        self.total += len(data)
        if self.chunked and self.remaining == 0:
            if exact(self.stream, 2) != b"\r\n":
                raise HTTPError(message("Invalid data chunk separator.", "Nieprawidłowy separator fragmentu danych."))
        return data


class ReceiverServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 16

    def __init__(self, address, context, sessions, emit, name, darwin=False, inbox=None, media_capabilities=LEGACY_CAPABILITIES, model="Mac"):
        self.context = context
        self.sessions = sessions
        self.emit = emit
        self._name_lock = threading.Lock()
        self.receiver_name = name
        self.receiver_model = model
        self.media_capabilities = media_capabilities
        self.inbox = inbox
        self.slots = threading.BoundedSemaphore(16)
        self.connections = set()
        self.uploads = {}
        self.connection_condition = threading.Condition()
        self.closing = False
        super().__init__(address, Handler, bind_and_activate=False)
        try:
            if darwin:
                self.socket.setsockopt(socket.SOL_SOCKET, 0x1104, 1)  # SO_RECV_ANYIF
            LOG.info("HTTPS listener: binding")
            self.server_bind()
            self.server_activate()
            LOG.info("HTTPS listener: active on port %d", self.server_port)
        except Exception:
            self.server_close()
            raise

    def server_bind(self):
        # HTTPServer.server_bind calls getfqdn -> gethostbyaddr, which can block
        # startup on the system resolver even for ::1. AirDrop uses receiver_name
        # in its protocol; the HTTP server only needs the bound address and port.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    @property
    def receiver_name(self):
        with self._name_lock:
            return self._receiver_name

    @receiver_name.setter
    def receiver_name(self, value):
        name = normalized_receiver_name(value)
        with self._name_lock:
            self._receiver_name = name

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        with self.connection_condition:
            if self.closing:
                self.slots.release()
                self.shutdown_request(request)
                return
            self.connections.add(request)
        try:
            super().process_request(request, address)
        except Exception:
            with self.connection_condition:
                self.connections.discard(request)
                self.connection_condition.notify_all()
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        secure = request
        connection_id = uuid.uuid4().hex[:8]
        started = perf_counter()
        LOG.info("Connection %s: TLS starting", connection_id)
        try:
            # Handshake in a worker, so an idle TLS peer cannot block all accepts.
            request.settimeout(10)
            secure = self.context.wrap_socket(request, server_side=True, do_handshake_on_connect=False)
            secure.airfrajer_connection_id = connection_id
            with self.connection_condition:
                self.connections.discard(request)
                self.connections.add(secure)
                if self.closing:
                    return
            secure.do_handshake()
            LOG.info("Connection %s: TLS ready ms=%.1f", connection_id, (perf_counter() - started) * 1000)
            secure.settimeout(30)
            self.finish_request(secure, address)
        except (OSError, ssl.SSLError):
            LOG.info("Connection %s: closed during TLS/HTTP handling", connection_id)
        except Exception:
            LOG.exception("Unexpected request error")
        finally:
            self.shutdown_request(secure)
            with self.connection_condition:
                self.connections.discard(secure)
                self.connections.discard(request)
                self.connection_condition.notify_all()
            self.slots.release()

    def close_connections(self):
        with self.connection_condition:
            self.closing = True
            connections = list(self.connections)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        with self.connection_condition:
            if not self.connection_condition.wait_for(lambda: not self.connections, timeout=8):
                LOG.warning("Some request threads did not finish cleanup within the shutdown deadline")

    def has_uploads(self):
        with self.connection_condition:
            return bool(self.uploads)

    def claim_upload(self, ident, address, connection):
        # Registration and cancellation share the session lock: no uninterruptible
        # gap between claiming the offer and entering a blocking socket read.
        with self.sessions.lock:
            offer = self.sessions.claim(ident, address)
            with self.connection_condition:
                self.uploads[offer.id] = connection
            return offer

    def cancel_transfer(self, ident):
        with self.sessions.lock:
            offer = self.sessions.current
            if not offer or offer.id != ident:
                return False
            offer.canceled.set()
            with self.connection_condition:
                connection = self.uploads.get(ident)
            if connection is not None:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            return self.sessions.cancel(ident)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "AimDrop/0.8.2"
    sys_version = ""
    timeout = 30

    def handle_expect_100(self):
        # BaseHTTPRequestHandler otherwise acknowledges before checking consent.
        return True

    def reply(self, status, payload=None, close=False):
        data = plistlib.dumps(payload, fmt=plistlib.FMT_BINARY) if payload is not None else b""
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        if data:
            self.send_header("Content-Type", "application/x-apple-binary-plist")
        if close:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if data:
            self.wfile.write(data)
        self.wfile.flush()

    def continue_if_requested(self):
        expect = self.headers.get("Expect", "").lower()
        if expect:
            if expect != "100-continue":
                raise HTTPError(message("Unsupported Expect header.", "Nieobsługiwany nagłówek Expect."))
            self.send_response_only(100)
            self.end_headers()
            self.wfile.flush()

    def metadata(self):
        started = perf_counter()
        body = Body(self.rfile, self.headers, MAX_METADATA)
        self.continue_if_requested()
        data = bytearray()
        while True:
            chunk = body.read()
            if not chunk:
                break
            data.extend(chunk)
        body_finished = perf_counter()
        try:
            result = plistlib.loads(data)
        except Exception as error:
            raise HTTPError(message("Invalid AirDrop metadata.", "Nieprawidłowe metadane AirDrop.")) from error
        if not isinstance(result, dict):
            raise HTTPError(message("Invalid AirDrop metadata.", "Nieprawidłowe metadane AirDrop."))
        LOG.info("Metadata %s: bytes=%d read_ms=%.1f parse_ms=%.1f", self.path, len(data),
                 (body_finished - started) * 1000, (perf_counter() - body_finished) * 1000)
        return result

    def do_HEAD(self):
        self.reply(200)

    def log_message(self, format, *args):
        LOG.info(format, *args)

    def do_GET(self):
        self.reply(200)

    def do_POST(self):
        # Only structural information is logged; no Apple IDs, tokens or request bodies.
        started = perf_counter()
        LOG.info("AirDrop %s connection=%s", self.path, self.connection.airfrajer_connection_id)
        try:
            if self.path == "/Discover":
                self.metadata()
                self.reply(200, {
                    "ReceiverComputerName": self.server.receiver_name,
                    "ReceiverModelName": self.server.receiver_model,
                    "ReceiverMediaCapabilities": self.server.media_capabilities,
                })
            elif self.path == "/Ask":
                offer = self.server.sessions.offer(self.metadata(), self.client_address)
                self.server.sessions.wait(offer)
                try:
                    self.reply(200, {
                        "ReceiverComputerName": self.server.receiver_name,
                        "ReceiverModelName": self.server.receiver_model,
                    })
                except OSError:
                    # The client may retry Ask on a second connection before Upload.
                    LOG.info("Ask response connection closed; consent expires automatically")
                    self.close_connection = True
            elif self.path == "/Upload":
                self.upload()
            else:
                self.reply(404, close=True)
        except Refused as error:
            LOG.info("Request declined: %s", error)
            self.reply(403, close=True)
        except (HTTPError, ArchiveError, ValueError) as error:
            LOG.warning("Request rejected: %s", error)
            self.reply(400, close=True)
        except (OSError, TimeoutError):
            LOG.info("Peer disconnected or timed out")
            self.close_connection = True
        finally:
            LOG.info("Request finished %s ms=%.1f", self.path, (perf_counter() - started) * 1000)

    def upload(self):
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].lower()
        if content_type not in ("application/x-dvzip", "application/x-cpio"):
            self.reply(415, close=True)
            return
        ids = self.headers.get_all("TransferID", [])
        if len(ids) != 1:
            raise Refused(message("Invalid transfer identifier.", "Nieprawidłowy identyfikator transferu."))
        offer = self.server.claim_upload(ids[0], self.client_address, self.connection)
        directory = None
        parser = None
        decoder = None
        total_decoded_bytes = None
        success = False
        try:
            directory = offer.storage
            directory.assert_present()
            body = Body(self.rfile, self.headers, directory.limit)
            total_bytes = body.remaining if not body.chunked else None
            total_decoded_bytes = decoded_size_hint(self.headers, body.chunked)
            total_files = len(offer.selection) if all(not item.is_directory for item in offer.selection) else None
            parser = ODCParser(directory, layout=SelectionLayout(offer.selection))
            decoder = ContainerDecoder(parser, content_type)
            with self.server.sessions.lock:
                if offer.canceled.is_set():
                    raise ArchiveError(message("Receiving canceled.", "Odbieranie anulowano."))
                self.continue_if_requested()
                LOG.info("Upload ready (%s)", content_type)
                self.server.emit("receiving", id=offer.id, bytes=0, total_bytes=total_bytes,
                                 decoded_bytes=0, total_decoded_bytes=total_decoded_bytes,
                                 total_files=total_files, files_received=0)
            last_progress = None
            while not decoder.done or body.remaining:
                if offer.canceled.is_set():
                    raise ArchiveError(message("Receiving canceled.", "Odbieranie anulowano."))
                chunk = body.read()
                if not chunk:
                    break
                if last_progress is None:
                    LOG.info("First payload block: %s bytes", len(chunk))
                decoder.feed(chunk)
                now = time.monotonic()
                if last_progress is None or now - last_progress >= 0.1 or (decoder.done and not body.remaining):
                    with self.server.sessions.lock:
                        if offer.canceled.is_set():
                            raise ArchiveError(message("Receiving canceled.", "Odbieranie anulowano."))
                        self.server.emit("progress", id=offer.id, bytes=body.total,
                                         total_bytes=total_bytes, total_files=total_files,
                                         decoded_bytes=decoder.decoded_bytes,
                                         total_decoded_bytes=total_decoded_bytes,
                                         files_received=parser.completed_count)
                        last_progress = now
            # iOS can wait for our response before its final HTTP zero-chunk.
            # A structurally complete cpio trailer, not a substring, proves completion.
            decoder.finish()
            # Completion is the commit point. A late cancel must not turn a
            # durable ready job into a canceled/failed transfer.
            with self.server.sessions.lock:
                if offer.canceled.is_set():
                    raise ArchiveError(message("Receiving canceled.", "Odbieranie anulowano."))
                directory.publish()
                paths = [str(path) for path in directory.published]
                if self.server.inbox:
                    receipt = self.server.inbox.record(offer.id, paths, parser.count)
                else:
                    receipt = dict(id=offer.id, count=parser.count, directory=offer.directory, paths=paths)
                success = True
                self.server.sessions.finish(offer)
            LOG.info("Transfer complete: %s file(s), %s wire bytes", parser.count, body.total)
            try:
                self.reply(200, close=True)
            except OSError:
                LOG.info("Complete files retained; sender disconnected before acknowledgment")
                self.close_connection = True
            self.server.emit("downloaded" if self.server.inbox else "complete", **receipt)
        except Exception as error:
            if offer.canceled.is_set() and not success:
                LOG.info("Upload canceled")
                self.close_connection = True
            else:
                LOG.warning("Upload failed (%s): %s", type(error).__name__, error)
                if not success:
                    detail = error_message(error)
                    if directory and directory.published:
                        detail += " " + text("Some files have been saved in the selected folder.", "Część plików została zapisana w wybranym folderze.")
                    self.server.emit("error", id=offer.id, message=str(message("Could not receive the transfer. %s", "Nie udało się odebrać przesyłki. %s", detail)))
                try:
                    self.reply(500, close=True)
                except OSError:
                    self.close_connection = True
        finally:
            if decoder is not None:
                if total_decoded_bytes is not None:
                    LOG.info("Decoded totals: declared=%d actual=%d", total_decoded_bytes, decoder.decoded_bytes)
                else:
                    LOG.info("Decoded totals: actual=%d", decoder.decoded_bytes)
            try:
                if parser:
                    parser.close()
            except OSError:
                LOG.warning("Could not flush an incomplete file during cleanup")
            finally:
                try:
                    if directory:
                        directory.close()
                finally:
                    try:
                        self.server.sessions.finish(offer)
                        if self.server.inbox and not success:
                            self.server.inbox.abandon(offer.id)
                    finally:
                        with self.server.connection_condition:
                            self.server.uploads.pop(offer.id, None)
                            self.server.connection_condition.notify_all()
