#!/usr/bin/env python3
"""Exercise the actual bundled worker over IPC and TLS, without radio discovery."""
import hashlib
import argparse
import http.client
import json
from pathlib import Path
import plistlib
import queue
import ssl
import subprocess
import sys
import tempfile
import threading
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tests.fixtures import archive, dvzip, request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=ROOT / "dist/AimDrop.app")
    bundle = parser.parse_args().app.resolve() / "Contents"
    config = plistlib.loads((bundle / "Info.plist").read_bytes())
    python = Path(config["AFPythonExecutable"])
    if not python.is_absolute():
        python = bundle / "Resources" / python
    with tempfile.TemporaryDirectory(prefix="airfrajer-smoke-") as temp:
        temp = Path(temp)
        destination = temp / "chosen"
        destination.mkdir()
        with (temp / "worker.log").open("w+") as log:
            process = subprocess.Popen([
                str(python), "-I", "-B", "-u",
                str(bundle / "Resources/receiver/main.py"), "--state-dir", str(temp / "state"),
                "--no-advertise", "--name", "AimDrop IPC test",
            ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            events = queue.Queue()
            def read_events():
                for line in process.stdout:
                    events.put(json.loads(line))
            reader = threading.Thread(target=read_events, daemon=True)
            reader.start()

            def event(kind):
                while True:
                    try:
                        item = events.get(timeout=15)
                    except queue.Empty:
                        log.seek(0)
                        raise RuntimeError("Worker timeout: " + log.read())
                    if item["event"] == "error":
                        raise RuntimeError(item["message"])
                    if item["event"] == kind:
                        return item

            def command(message):
                process.stdin.write(json.dumps(message) + "\n")
                process.stdin.flush()

            try:
                ready = event("ready")
                discover = http.client.HTTPSConnection("::1", ready["port"], timeout=10,
                                                       context=ssl._create_unverified_context())
                discover.request("POST", "/Discover", plistlib.dumps({}))
                response = discover.getresponse()
                assert response.status == 200, "Discover failed"
                discovery = plistlib.loads(response.read())
                assert discovery["ReceiverComputerName"] == "AimDrop IPC test"
                assert discovery["ReceiverModelName"] != "OpenDrop"
                capabilities = discovery["ReceiverMediaCapabilities"]
                assert isinstance(capabilities, bytes), "Media capabilities must be a plist data value"
                assert json.loads(capabilities) == json.loads((bundle / "Resources/media-capabilities.json").read_bytes())
                discover.close()
                rename_id = str(uuid.uuid4())
                receiver_name = "AimDrop — kontrola IPC"
                command({"command": "set_name", "request_id": rename_id, "name": receiver_name})
                renamed = event("name_result")
                assert renamed["request_id"] == rename_id and renamed["ok"] and renamed["name"] == receiver_name
                ident = str(uuid.uuid4())
                ask = http.client.HTTPSConnection("::1", ready["port"], timeout=10,
                                                  context=ssl._create_unverified_context())
                ask.request("POST", "/Ask", plistlib.dumps(request(ident, "probe.bin")))
                response = ask.getresponse()
                assert response.status == 200, "Ask not accepted"
                assert plistlib.loads(response.read())["ReceiverComputerName"] == receiver_name, "Live name not applied to Ask"
                ask.close()
                original = bytes(range(256)) * 8192
                payload = dvzip(archive([("NSIRD_AirDrop_smoke/probe.bin", original)]))
                upload = http.client.HTTPSConnection("::1", ready["port"], timeout=15,
                                                     context=ssl._create_unverified_context())
                upload.request("POST", "/Upload", payload,
                               {"Content-Type": "application/x-dvzip", "TransferID": ident})
                response = upload.getresponse()
                assert response.status == 200, "Upload failed"
                response.read()
                upload.close()
                downloaded = event("downloaded")
                assert list(destination.iterdir()) == [], "File saved before choosing a destination"
                assert all(Path(path).exists() for path in downloaded["paths"]), "Buffered files missing"
                command({"command": "save", "id": downloaded["id"], "directory": str(destination)})
                saved_event = event("complete")
                assert saved_event["paths"] == [str(destination / "probe.bin")], "Wrong notification target"
                saved = (destination / "probe.bin").read_bytes()
                assert hashlib.sha256(saved).digest() == hashlib.sha256(original).digest(), "Content mismatch"
                command({"command": "shutdown"})
                assert process.wait(timeout=5) == 0, "Worker shutdown failed"
                assert sorted(item.name for item in destination.iterdir()) == ["probe.bin"], "Staging leak"
                print("PASS: native media discovery, live rename, buffered TLS receive, destination chosen after upload, SHA-256 (2 MiB), notification paths, cleanup, shutdown")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                process.stdin.close()
                reader.join(timeout=2)
                process.stdout.close()


if __name__ == "__main__":
    main()
