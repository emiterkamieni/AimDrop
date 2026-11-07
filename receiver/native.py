"""Own the bundled native transport; preserve the worker's existing IPC contract."""
import json
import logging
import subprocess
import threading
import time
import uuid
from .localization import message, text

LOG = logging.getLogger("airfrajer")


class NativeReceiver:
    def __init__(self, executable, artwork, state_dir, name, port, emit, stopped, loopback=False, avatar=None, avatar_digest=None):
        self.emit = emit
        self.stopped = stopped
        self.lock = threading.Lock()
        self.closing = False
        self.ready = threading.Event()
        self.ready_fields = None
        self.pending = {}
        self.quiesce_request = None
        self.quiesced = False
        arguments = [
            str(executable), "--name=" + name, "--backend-port=" + str(port),
            "--state-dir=" + str(state_dir.resolve()), "--artwork=" + str(artwork.resolve()),
            "--loopback=" + str(loopback).lower(),
        ]
        if avatar is not None:
            arguments.append("--avatar=" + str(avatar.resolve()))
        if avatar_digest is not None:
            arguments.append("--avatar-digest=" + avatar_digest)
        self.process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.reader = threading.Thread(target=self._read, name="native-events", daemon=True)
        self.reader.start()

    def _read(self):
        try:
            while True:
                line = self.process.stdout.readline(65537)
                if not line:
                    break
                if len(line) > 65536:
                    raise ValueError("oversized native event")
                value = json.loads(line)
                event = value.get("event")
                if event == "ready":
                    self.ready_fields = value
                    self.ready.set()
                elif event in ("name_result", "profile_result"):
                    with self.lock:
                        if value.get("ok") is True and self.ready_fields:
                            for key in ("prepair_port", "pairing_port"):
                                if isinstance(value.get(key), int) and 0 < value[key] <= 65535:
                                    self.ready_fields[key] = value[key]
                            for key in ("name", "avatar_digest"):
                                if isinstance(value.get(key), str):
                                    self.ready_fields[key] = value[key]
                        pending = self.pending.get(value.get("request_id"))
                        if pending:
                            pending[1].update(value)
                            pending[0].set()
                elif event == "pin":
                    code = value.get("code")
                    if isinstance(code, str) and len(code) == 6 and code.isascii() and code.isdigit():
                        self.emit("pairing_pin", code=code)
                elif event == "quiesced":
                    with self.lock:
                        if value.get("request_id") == self.quiesce_request:
                            self.quiesced = True
                elif event == "pin_closed":
                    self.emit("pairing_closed")
                elif event == "error":
                    break
        except (OSError, ValueError, TypeError, AttributeError):
            LOG.warning("Invalid native receiver control channel")
        finally:
            self.ready.set()
            with self.lock:
                for done, _ in self.pending.values():
                    done.set()
            if not self.closing and not self.stopped.is_set():
                self.emit("error", fatal=True, message=text("The native AirDrop receiver stopped. Restart AimDrop.", "Natywny odbiornik AirDrop zatrzymał się. Uruchom AimDrop ponownie."))
                self.stopped.set()

    def wait_ready(self):
        deadline = time.monotonic() + 35
        while not self.ready.wait(0.1):
            if self.stopped.is_set():
                return None
            if time.monotonic() >= deadline:
                raise RuntimeError(message("The AirDrop receiver took too long to start.", "Upłynął czas uruchamiania odbiornika AirDrop."))
        if not self.ready_fields:
            raise RuntimeError(message("Cannot start the native AirDrop receiver.", "Nie można uruchomić natywnego odbiornika AirDrop."))
        if self.stopped.is_set():
            return None
        return self.ready_fields

    def _send(self, command):
        # Serialize complete messages, never log a control payload (PIN events
        # travel in the other direction and go only to the AppKit panel).
        with self.lock:
            if self.closing or self.process.poll() is not None:
                raise RuntimeError(message("The AirDrop receiver is unavailable.", "Odbiornik AirDrop jest niedostępny."))
            self.process.stdin.write(json.dumps(command) + "\n")
            self.process.stdin.flush()

    def rename(self, name):
        return self._update(dict(command="set_name", name=name))["pairing_reset"]

    def update_profile(self, name, path, digest):
        return self._update(dict(command="set_profile", name=name, avatar_path=path, avatar_digest=digest))

    def _update(self, command):
        request = str(uuid.uuid4())
        done, result = threading.Event(), {}
        with self.lock:
            self.pending[request] = (done, result)
        try:
            self._send(dict(command, request_id=request))
            if (not done.wait(10) or result.get("ok") is not True or result.get("name") != command["name"]
                    or (command["command"] == "set_profile" and result.get("avatar_digest") != command["avatar_digest"])):
                raise RuntimeError(message("The receiver did not confirm the name and avatar settings.", "Odbiornik nie potwierdził ustawień nazwy i awatara."))
            return dict(pairing_reset=result.get("pairing_reset") is True, avatar_digest=result["avatar_digest"])
        finally:
            with self.lock:
                self.pending.pop(request, None)

    def quiesce(self, request):
        with self.lock:
            if self.quiesce_request == request:
                return self.quiesced
            self.quiesce_request, self.quiesced = request, False
        self._send(dict(command="quiesce", request_id=request))
        return False

    def resume(self):
        with self.lock:
            self.quiesce_request, self.quiesced = None, False
        self._send(dict(command="resume"))

    def close(self, graceful=False):
        if graceful:
            self._send(dict(command="shutdown"))
            self.closing = True
            # The helper exits only after its dispatch queue has stopped. EOF
            # is intentionally deferred: its crash fallback exits immediately.
            self.process.wait()
            self.process.stdin.close()
            self.reader.join()
            self.process.stdout.close()
            return
        self.closing = True
        # EOF also stops the helper if it is still awaiting startup. Each child
        # has its own pipe, so killing the worker cannot leave it advertising.
        try:
            self.process.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        self.reader.join(timeout=2)
        self.process.stdout.close()
