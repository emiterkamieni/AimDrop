"""Use Apple's mDNSResponder so service announcements also reach AWDL."""
import ctypes
import logging
import select
import socket
import threading
from .localization import message

LOG = logging.getLogger(__name__)
INCLUDE_P2P_AND_AWDL = 0x00120000


class Advertisement:
    def __init__(self, instance, port, on_error):
        # Darwin exports DNS-SD through libSystem; Linux's libdns_sd name is
        # not present in the dyld shared cache on current macOS.
        self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.ref = ctypes.c_void_p()
        self.stopped = threading.Event()
        self.on_error = on_error
        callback_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_uint32,
                                        ctypes.c_int32, ctypes.c_char_p,
                                        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p)
        self.callback = callback_type(self._registered)
        self.lib.DNSServiceRegister.argtypes = [
            ctypes.POINTER(ctypes.c_void_p), ctypes.c_uint32, ctypes.c_uint32,
            ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
            ctypes.c_uint16, ctypes.c_uint16, ctypes.c_void_p, callback_type, ctypes.c_void_p,
        ]
        self.lib.DNSServiceRegister.restype = ctypes.c_int32
        self.lib.DNSServiceRefSockFD.argtypes = [ctypes.c_void_p]
        self.lib.DNSServiceRefSockFD.restype = ctypes.c_int
        self.lib.DNSServiceProcessResult.argtypes = [ctypes.c_void_p]
        self.lib.DNSServiceProcessResult.restype = ctypes.c_int32
        self.lib.DNSServiceRefDeallocate.argtypes = [ctypes.c_void_p]
        self.lib.DNSServiceRefDeallocate.restype = None
        txt = b"\x09flags=136"
        self.txt = ctypes.create_string_buffer(txt)
        error = self.lib.DNSServiceRegister(
            ctypes.byref(self.ref), INCLUDE_P2P_AND_AWDL, 0, instance.encode("ascii"),
            b"_airdrop._tcp", b"local.", None, socket.htons(port), len(txt),
            self.txt, self.callback, None,
        )
        if error:
            raise RuntimeError(message("Bonjour registration failed (%s).", "Nie udało się zarejestrować odbiornika Bonjour (%s).", error))
        self.thread = threading.Thread(target=self._process, name="bonjour", daemon=True)
        self.thread.start()

    def _registered(self, ref, flags, error, name, service, domain, context):
        if error:
            self.on_error(str(message("Bonjour error %s. Check AimDrop's local network access in System Settings.", "Bonjour: błąd %s. Sprawdź dostęp AimDrop do sieci lokalnej w Ustawieniach systemowych.", error)))
        else:
            LOG.info("Bonjour registered on peer-to-peer/AWDL interfaces")

    def _process(self):
        fd = self.lib.DNSServiceRefSockFD(self.ref)
        try:
            while not self.stopped.is_set():
                ready, _, _ = select.select([fd], [], [], 0.5)
                if ready:
                    error = self.lib.DNSServiceProcessResult(self.ref)
                    if error:
                        self.on_error(str(message("The Bonjour receiver advertisement was lost (%s).", "Utracono ogłaszanie odbiornika Bonjour (%s).", error)))
                        break
        except (OSError, ValueError):
            if not self.stopped.is_set():
                LOG.exception("Bonjour event processing failed")
        finally:
            self.lib.DNSServiceRefDeallocate(self.ref)

    def close(self):
        self.stopped.set()
        self.thread.join(timeout=2)
