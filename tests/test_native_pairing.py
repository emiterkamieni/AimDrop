import io
import json
from pathlib import Path
import threading
import unittest
from unittest import mock

from receiver.native import NativeReceiver


class NativePairingEventsTests(unittest.TestCase):
    def relay(self, events):
        observed = []
        process = mock.Mock()
        process.stdout = io.StringIO("".join(json.dumps(event) + "\n" for event in events))
        stopped = threading.Event()
        stopped.set()  # The fixture's EOF is an intentional stop.
        with mock.patch("receiver.native.subprocess.Popen", return_value=process):
            receiver = NativeReceiver(Path("helper"), Path("artwork"), Path("state"), "Test", 1234,
                                      lambda kind, **fields: observed.append(dict(event=kind, **fields)), stopped)
            receiver.reader.join(timeout=2)
            self.assertFalse(receiver.reader.is_alive())
        return observed

    def test_repeated_pin_preserves_original_deadline_across_worker_ipc(self):
        expires_at = 1_800_000_000.125
        events = [dict(event="pin", code="012345", expires_at=expires_at)] * 2
        events.append(dict(event="pin_closed"))
        with mock.patch("receiver.native.time.time", return_value=expires_at - 5):
            observed = self.relay(events)
        self.assertEqual(observed, [dict(event="pairing_pin", code="012345", expires_at=expires_at)] * 2
                         + [dict(event="pairing_closed")])

    def test_pin_without_a_usable_deadline_is_not_forwarded(self):
        events = [dict(event="pin", code="123456")]
        for deadline in (None, "1800000000", True, float("nan"), float("inf")):
            events.append(dict(event="pin", code="123456", expires_at=deadline))
        self.assertEqual(self.relay(events), [])
