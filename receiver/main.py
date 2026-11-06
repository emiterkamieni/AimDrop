#!/usr/bin/env python3
"""Native app worker. stdout/stdin are a line-delimited JSON control channel."""
import argparse
import fcntl
import json
import logging
import os
from pathlib import Path
import signal
import ssl
import subprocess
import sys
import threading
import time
import uuid

# Works with Python -I: import only the receiver shipped in this app bundle.
sys.dont_write_bytecode = True  # the signed .app Resources must remain immutable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from receiver.bonjour import Advertisement
from receiver.configuration import normalized_receiver_name
from receiver.http import ReceiverServer
from receiver.inbox import Inbox
from receiver.media import load_capabilities
from receiver.localization import configure, error_message, language_code, message
from receiver.native import NativeReceiver
from receiver.sessions import Sessions

LOG = logging.getLogger("airfrajer")


class SaveCanceled(Exception):
    pass


class SaveJobs:
    """Per-job cooperative cancellation; Inbox owns staging and ready originals."""
    def __init__(self, inbox, emit, stopped):
        self.inbox = inbox
        self.emit = emit
        self.stopped = stopped
        self.lock = threading.Lock()
        self.jobs = {}
        self.tasks = set()

    def start(self, ident, destination):
        ident = str(uuid.UUID(ident))
        with self.lock:
            if self.stopped.is_set() or ident in self.jobs:
                return False
            canceled = threading.Event()
            task = threading.Thread(target=self._save, args=(ident, destination, canceled),
                                    name="save-received", daemon=True)
            self.jobs[ident] = (canceled, task)
            self.tasks.add(task)
            try:
                task.start()
            except Exception:
                self.jobs.pop(ident)
                self.tasks.discard(task)
                raise
        return True

    def cancel(self, ident):
        ident = str(uuid.UUID(ident))
        with self.lock:
            job = self.jobs.get(ident)
            if job is None:
                return False
            job[0].set()
            return True

    def _save(self, ident, destination, canceled):
        event = None
        fields = {}
        try:
            def check():
                if canceled.is_set() or self.stopped.is_set():
                    raise SaveCanceled()

            def progress(fields):
                check()
                self.emit("save_progress", id=ident, phase="saving", **fields)

            check()
            self.emit("saving", id=ident, phase="saving")
            fields = self.inbox.save(ident, destination, progress)
            event = "complete"
        except SaveCanceled:
            event, fields = "save_canceled", dict(id=ident)
        except Exception as error:
            LOG.warning("Could not save buffered transfer (%s)", type(error).__name__)
            event, fields = "error", dict(id=ident, phase="saving", message=error_message(error))
        finally:
            # Remove the old token before acknowledging, so an immediate retry
            # cannot inherit cancellation or be mistaken for a duplicate save.
            with self.lock:
                self.jobs.pop(ident)
        try:
            if not self.stopped.is_set():
                self.emit(event, **fields)
                self.emit("pending", transfers=self.inbox.list_ready())
        finally:
            with self.lock:
                self.tasks.discard(threading.current_thread())

    def close(self):
        with self.lock:
            self.stopped.set()
            tasks = list(self.tasks)
            for canceled, _ in self.jobs.values():
                canceled.set()
        for task in tasks:
            task.join(timeout=8)


def identity(directory):
    path = directory / "identity.json"
    if path.exists():
        value = json.loads(path.read_text())
        instance = value["instance"]
        if len(instance) != 12 or any(char not in "0123456789abcdef" for char in instance):
            raise ValueError(message("Invalid receiver identity.", "Niepoprawna tożsamość odbiornika."))
    else:
        instance = uuid.uuid4().hex[:12]
        path.write_text(json.dumps({"instance": instance}))
        path.chmod(0o600)
    cert = directory / "certificate.pem"
    key = directory / "private-key.pem"
    if not cert.exists() or not key.exists():
        subprocess.run([
            "/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(cert), "-days", "365", "-sha256",
            "-subj", "/CN=AimDrop",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        key.chmod(0o600)
        cert.chmod(0o600)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(str(cert), str(key))
    return instance, context


def hardware_model():
    if sys.platform == "darwin":
        try:
            model = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True, timeout=2).strip()
            if model and len(model) <= 64 and all(char.isascii() and (char.isalnum() or char == ",") for char in model):
                return model
        except (OSError, subprocess.SubprocessError):
            pass
    return "Mac"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default="AimDrop")
    parser.add_argument("--language", default=os.environ.get("AIMDROP_LANGUAGE", "en"))
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--no-advertise", action="store_true", help="Loopback-only integration testing")
    parser.add_argument("--manual-consent", action="store_true", help="Manual-consent protocol fixture mode")
    parser.add_argument("--native-helper", type=Path)
    parser.add_argument("--native-artwork", type=Path)
    parser.add_argument("--native-avatar", type=Path)
    parser.add_argument("--avatar-digest")
    parser.add_argument("--native-loopback", action="store_true", help="Isolated native lifecycle checks")
    args = parser.parse_args()
    configure(args.language)
    # Validate here rather than argparse's type hook, which echoes invalid values.
    args.name = normalized_receiver_name(args.name)
    if args.native_helper and not args.native_artwork:
        raise ValueError(message("AirDrop receiver artwork is missing.", "Brak grafiki odbiornika AirDrop."))
    os.umask(0o077)
    logging.Formatter.converter = time.gmtime
    logging.basicConfig(level=logging.INFO, format="%(asctime)s.%(msecs)03dZ %(levelname)s %(message)s",
                        datefmt="%Y-%m-%dT%H:%M:%S", stream=sys.stderr)
    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_file = (args.state_dir / "receiver.lock").open("a+")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError(message("Another AimDrop receiver is already running.", "Inny odbiornik AimDrop jest już uruchomiony."))
    output_lock = threading.Lock()
    stopped = threading.Event()

    def emit(event, **fields):
        try:
            with output_lock:
                if event in ("pending", "downloaded") and inbox:
                    fields["latest_received_id"] = inbox.latest_received_id()
                emitted = time.time()
                if event in ("incoming", "accepted", "receiving", "downloaded", "saving", "complete"):
                    LOG.info("IPC emit event=%s transfer=%s", event, fields.get("id", "none"))
                print(json.dumps(dict(event=event, emitted_at=emitted, **fields), ensure_ascii=True), flush=True)
        except (BrokenPipeError, OSError):
            stopped.set()

    inbox = None if args.manual_consent else Inbox(args.state_dir / "Incoming")
    sessions = Sessions(emit, prepare_destination=inbox.prepare if inbox else None,
                        abandon_destination=inbox.abandon if inbox else None)
    LOG.info("Receiver startup: TLS identity")
    instance, context = identity(args.state_dir)
    media_capabilities = load_capabilities(Path(__file__).resolve().parent.parent / "media-capabilities.json")
    LOG.info("Receiver startup: hardware model")
    model = hardware_model()
    LOG.info("Receiver startup: HTTPS listener")
    server = ReceiverServer(("::1" if args.no_advertise or args.native_helper else "::", args.port),
                            context, sessions, emit, args.name, darwin=sys.platform == "darwin", inbox=inbox,
                            media_capabilities=media_capabilities, model=model)
    server_thread = threading.Thread(target=server.serve_forever, name="https", daemon=True)
    server_thread.start()
    advert = None
    native = None

    def stop(signum=None, frame=None):
        stopped.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    saves = SaveJobs(inbox, emit, stopped) if inbox else None

    def commands():
        try:
            for line in sys.stdin:
                if len(line) > 65536:
                    continue
                try:
                    command = json.loads(line)
                    action = command.get("command")
                    if action == "decision":
                        sessions.decide(command.get("id"), command.get("accept") is True, command.get("directory"))
                    elif action == "pause":
                        sessions.pause(command.get("paused") is True)
                    elif action == "cancel_transfer":
                        server.cancel_transfer(command.get("id"))
                    elif action == "save" and inbox:
                        saves.start(command.get("id"), command.get("directory"))
                    elif action == "cancel_save" and inbox:
                        saves.cancel(command.get("id"))
                    elif action == "defer" and inbox:
                        emit("pending", transfers=inbox.list_ready())
                    elif action == "set_language":
                        # Presentation only: no profile update, listener restart or
                        # native command, so active transfers and pairing survive.
                        request_id = command.get("request_id")
                        if (not isinstance(request_id, str) or len(request_id) != 36
                                or str(uuid.UUID(request_id)) != request_id.lower()):
                            raise ValueError(message("Invalid request identifier.", "Nieprawidłowy identyfikator żądania."))
                        try:
                            configure(command.get("language"))
                        except ValueError as error:
                            emit("language_result", request_id=request_id, ok=False,
                                 language=language_code(), message=error_message(error))
                        else:
                            emit("language_result", request_id=request_id, ok=True, language=language_code())
                    elif action in ("set_name", "set_profile"):
                        result_event = "profile_result" if action == "set_profile" else "name_result"
                        request_id = command.get("request_id")
                        if (not isinstance(request_id, str) or len(request_id) != 36
                                or str(uuid.UUID(request_id)) != request_id.lower()):
                            raise ValueError(message("Invalid request identifier.", "Nieprawidłowy identyfikator żądania."))
                        try:
                            name = normalized_receiver_name(command.get("name"))
                            pairing_reset = False
                            profile = {}
                            if action == "set_profile":
                                path, digest = command.get("avatar_path"), command.get("avatar_digest")
                                if (not native or "avatar_path" not in command or
                                        (path is not None and (not isinstance(path, str) or not Path(path).is_absolute())) or
                                        not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest)):
                                    raise ValueError(message("Invalid avatar settings.", "Nieprawidłowe ustawienia awatara."))
                                profile = native.update_profile(name, path, digest)
                                pairing_reset = profile["pairing_reset"]
                            elif native:
                                pairing_reset = native.rename(name)
                            server.receiver_name = name
                        except (ValueError, RuntimeError, OSError) as error:
                            emit(result_event, request_id=request_id, ok=False,
                                  message=error_message(error), name=server.receiver_name)
                        else:
                            emit(result_event, request_id=request_id, ok=True,
                                  name=server.receiver_name, **(dict(pairing_reset=pairing_reset) if native else {}),
                                  **(dict(avatar_digest=profile["avatar_digest"]) if action == "set_profile" else {}),
                                  **(dict(native=native.ready_fields) if native and args.native_loopback else {}))
                    elif action == "shutdown":
                        break
                except (ValueError, TypeError, AttributeError, RecursionError):
                    LOG.warning("Invalid UI command")
        finally:
            stopped.set()

    try:
        if args.native_helper:
            native = NativeReceiver(args.native_helper, args.native_artwork, args.state_dir / "Pairing",
                                    args.name, server.server_port, emit, stopped, loopback=args.native_loopback,
                                    avatar=args.native_avatar, avatar_digest=args.avatar_digest)
        threading.Thread(target=commands, name="ui-commands", daemon=True).start()
        if native:
            if not native.wait_ready():
                return
        elif not args.no_advertise:
            advert = Advertisement(instance, server.server_port,
                                   lambda message: emit("error", message=message))
        LOG.info("Receiver listening on port %s; %s", server.server_port, ssl.OPENSSL_VERSION)
        LOG.info("Receiver model: %s", server.receiver_model)
        native_check = dict(native={**native.ready_fields, "pid": native.process.pid}) if native and args.native_loopback else {}
        emit("ready", name=server.receiver_name, port=server.server_port, **native_check,
             **(dict(avatar_digest=native.ready_fields["avatar_digest"]) if native else {}))
        if inbox:
            emit("pending", transfers=inbox.list_ready())
        while not stopped.wait(0.5):
            sessions.expire()
    finally:
        stopped.set()
        if native:
            native.close()
        sessions.close()
        if advert:
            advert.close()
        server.shutdown()
        server.close_connections()
        server.server_close()
        if saves:
            saves.close()
        lock_file.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        LOG.exception("Receiver could not start")
        print(json.dumps({"event": "error", "message": error_message(error), "fatal": True}), flush=True)
        sys.exit(1)
