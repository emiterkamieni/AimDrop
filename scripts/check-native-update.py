#!/usr/bin/env python3
"""Focused native HTTP3 receive / cancel-drain / restart-barrier integration."""
import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tests.fixtures import archive, dvzip, request

spec = importlib.util.spec_from_file_location("aimdrop_native_smoke", ROOT / "scripts/native-smoke.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/AimDrop.app")
    parser.add_argument("--baseline-only", action="store_true", help="Check transport without any updater commands")
    args = parser.parse_args()
    prototype = ROOT / ".build/airfolder-pairing-prototype"
    with tempfile.TemporaryDirectory(prefix="native-update-", dir=ROOT / ".build") as folder:
        root = Path(folder)
        worker = smoke.Worker(args.app.resolve() / "Contents", root, "AimDrop Update Check")
        env = {**os.environ, "AIRFOLDER_PAIRING_STATE_DIR": str(root / "client"), "AIRFOLDER_EXPECTED_NAME": "AimDrop Update Check"}
        try:
            ready = worker.event("ready")
            native = ready["native"]
            client = subprocess.Popen([prototype, "--client", str(native["prepair_port"]), str(native["pairing_port"])],
                                      env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                pin = worker.event("pairing_pin")["code"]
                stdout, stderr = client.communicate(pin + "\n", timeout=30)
                assert client.returncode == 0, "Enrollment failed"
            finally:
                if client.poll() is None:
                    client.kill(); client.communicate()
            worker.event("pairing_closed")
            identity = (root / "state/Pairing/identity.json").read_bytes()

            def idle(correlation):
                deadline = time.monotonic() + 15
                while True:
                    status = worker.event("update_status")
                    if status["request_id"] == correlation and status["idle"]:
                        return
                    assert time.monotonic() < deadline, worker.log_path.read_text()[-3000:]

            def transfer(drain=False):
                data = os.urandom(2 * 1024 * 1024 + 17)
                (root / "ask.plist").write_bytes(plistlib.dumps(request(str(uuid.uuid4()), "bundled.bin")))
                (root / "upload.body").write_bytes(dvzip(archive([("NSIRD_AirDrop_update/bundled.bin", data)])))
                process = subprocess.Popen([prototype, "--reconnect", str(native["prepair_port"]), "normal"],
                                           env={**env, "AIRFOLDER_RECONNECT_TRANSFER_DIR": str(root)}, text=True,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                output = []
                reader = threading.Thread(target=lambda: output.extend(process.communicate()), daemon=True)
                reader.start()
                correlation = str(uuid.uuid4())
                try:
                    if drain:
                        worker.event("accepted")
                        worker.send(dict(command="prepare_update", request_id=correlation))
                    reader.join(timeout=40)
                    assert not reader.is_alive(), "Client response timed out"
                    assert process.returncode == 0, "\n".join(output)[-1500:]
                    assert "bundled_pair_verify_transfer=ok" in output[0]
                    receipt = worker.event("downloaded")
                    assert Path(receipt["paths"][0]).read_bytes() == data
                    if drain:
                        idle(correlation)
                    return correlation
                except Exception as error:
                    raise AssertionError(str(error) + "\nCLIENT:\n" + "\n".join(output)[-1500:] + "\nWORKER:\n" + worker.log_path.read_text()[-3000:]) from error
                finally:
                    if process.poll() is None:
                        process.kill(); process.wait()
                    reader.join(timeout=2)

            transfer()
            print("PASS: baseline native paired transfer", flush=True)
            if args.baseline_only:
                return
            cancel = str(uuid.uuid4())
            worker.send(dict(command="prepare_update", request_id=cancel))
            idle(cancel)
            worker.send(dict(command="cancel_update", request_id=cancel))
            worker.event("update_canceled")
            transfer()
            print("PASS: receiving resumes after canceled drain", flush=True)
            correlation = transfer(drain=True)
            worker.send(dict(command="shutdown_when_idle", request_id=correlation))
            assert worker.event("shutdown_complete")["request_id"] == correlation
            assert worker.process.wait(timeout=8) == 0
            assert (root / "state/Pairing/identity.json").read_bytes() == identity
            print("PASS: accepted native HTTP3 transfer completes during drain; sender response, clean shutdown and pairing identity preserved")
        finally:
            worker.close()


if __name__ == "__main__":
    main()
