#!/usr/bin/env python3
"""Check the real 120-second PIN lifecycle using bundled workers and isolated state."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("aimdrop_native_smoke", ROOT / "scripts/native-smoke.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/AimDrop.app")
    args = parser.parse_args()
    prototype = ROOT / ".build/airfolder-pairing-prototype"
    with tempfile.TemporaryDirectory(prefix="pin-expiry-", dir=ROOT / ".build") as folder:
        root = Path(folder)
        name = "AimDrop PIN Expiry Check"
        worker = smoke.Worker(args.app.resolve() / "Contents", root, name)
        clients = []
        try:
            native = worker.event("ready")["native"]

            def begin():
                env = {**os.environ, "AIRFOLDER_PAIRING_STATE_DIR": str(root / ("client-" + str(len(clients)))),
                       "AIRFOLDER_EXPECTED_NAME": name}
                client = subprocess.Popen([prototype, "--client", str(native["prepair_port"]), str(native["pairing_port"])],
                                          cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, text=True)
                clients.append(client)
                return client, worker.event("pairing_pin")

            def finish(client, event, accepted):
                output, _ = client.communicate(event["code"] + "\n", timeout=20)
                if accepted:
                    assert client.returncode == 0 and "temporary_identity_exchange=mutual" in output, "Valid PIN rejected"
                    worker.event("pairing_closed")
                else:
                    assert client.returncode == 1 and "pairing_client_error=" in output, "Expired PIN was not rejected by authentication"

            initial, first = begin()
            assert 110 < first["expires_at"] - time.time() <= 120
            finish(initial, first, accepted=True)
            print("Checking the original 120-second deadline (about two minutes)…", flush=True)
            time.sleep(max(0, first["expires_at"] - time.time() - 8))
            retry, repeated = begin()
            assert repeated["code"] == first["code"], "Retry changed a still-valid PIN"
            assert repeated["expires_at"] == first["expires_at"], "Retry extended the original deadline"
            # The protocol probe has a 12-second watchdog. Open the attempt
            # crossing expiry late enough to exercise authentication, not that watchdog.
            delayed, expiring = begin()
            assert expiring["code"] == first["code"] and expiring["expires_at"] == first["expires_at"]
            finish(retry, repeated, accepted=True)
            state = root / "state/Pairing/identity.json"
            paired = state.read_bytes()
            print("PASS: a late retry reuses the PIN and original deadline; authentication succeeds before expiry", flush=True)

            time.sleep(max(0, first["expires_at"] - time.time() + 0.2))
            finish(delayed, expiring, accepted=False)
            assert "pake_credential_lookup=miss" in worker.log_path.read_text(), "Failure was not credential expiry"
            assert state.read_bytes() == paired, "An expired attempt modified persistent pairing"

            fresh, replacement = begin()
            assert replacement["code"] != first["code"], "Expired PIN reused by a new registration"
            assert 110 < replacement["expires_at"] - time.time() <= 120
            finish(fresh, replacement, accepted=True)
            log = worker.log_path.read_text()
            assert all(event["code"] not in log for event in (first, replacement)), "PIN leaked to diagnostics"
            print("PASS: expired credential rejected; a new request generates a different PIN valid for 120 seconds")
        finally:
            for client in clients:
                if client.poll() is None:
                    client.kill()
                client.communicate()
            worker.close()


if __name__ == "__main__":
    main()
