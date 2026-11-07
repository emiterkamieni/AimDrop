#!/usr/bin/env python3
"""Actual two-version Sparkle replacement/relaunch of a full, isolated AimDrop."""
import functools
import argparse
import http.server
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import threading
import time
import sparkle
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from receiver.inbox import Inbox
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("aimdrop_package", ROOT / "scripts/package.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tamper", choices=("archive", "feed"), help="Require signature failure without replacing the app")
    parser.add_argument("--login", choices=("on", "off"), default="off", help="Login-item setting applied before the update")
    args = parser.parse_args()
    root = ROOT / "dist/update-experiment"
    root.mkdir(parents=True, exist_ok=True)
    # Each run has separate state and monotonically increasing versions, so
    # Sparkle's own caches cannot make a repeated experiment a false positive.
    first = str(int(time.time()))
    second = str(int(first) + 1)
    state = root / ("state-" + first)
    state.mkdir()
    inbox = Inbox(state / "Incoming")
    transfer = str(uuid.uuid4())
    payload = Path(inbox.prepare(transfer))
    (payload / "retained.txt").write_text("Retained across the Sparkle update")
    inbox.record(transfer, [payload / "retained.txt"], 1)
    feed = root / ("feed-" + first)
    feed.mkdir()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(feed)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    tools = sparkle.prepare() / "bin"
    public = subprocess.check_output([tools / "generate_keys", "--account", "AimDrop-UpdateExperiment", "-p"], text=True).strip()
    config = dict(version="0.8.3", build=second, public_key=public, feed=base + "appcast.xml", state=str(state), install="no", login=args.login)
    config_path = state / "config.json"
    config_path.write_text(json.dumps(config))
    app = root / "AimDrop.app"
    runtime = package.CACHE / f"cpython-{package.PYTHON_VERSION}+{package.RELEASE}" / "python"
    subprocess.run([sys.executable, "-B", ROOT / "scripts/build.py", "--output", app, "--bundled-python", runtime,
                    "--update-experiment", config_path], check=True)
    for binary in package.native_files(app):
        if not package.inside(binary, app / "Contents/Frameworks/Sparkle.framework"):
            package.run("/usr/bin/codesign", "--force", "--sign", "-", binary, capture_output=True)
    package.run("/usr/bin/codesign", "--force", "--sign", "-", app)
    package.verify_app(app)
    archive = feed / f"AimDrop-{second}.zip"
    new_helper_digest = package.sha256(app / "Contents/MacOS/AimDropReceiver")
    package.run("/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", app, archive)
    package.run(tools / "generate_appcast", "--account", "AimDrop-UpdateExperiment", "--maximum-deltas", "0", "--download-url-prefix", base, feed)
    if args.tamper == "archive":
        with archive.open("r+b") as stream:
            stream.seek(archive.stat().st_size // 2)
            byte = stream.read(1)
            stream.seek(-1, 1)
            stream.write(bytes([byte[0] ^ 1]))
    elif args.tamper == "feed":
        appcast = feed / "appcast.xml"
        text = appcast.read_text()
        appcast.write_text(text.replace("<title>", "<title>Changed ", 1))
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleVersion"] = first
    info["AimDropUpdateExperiment"].update(build=first, install="yes")
    info_path.write_bytes(plistlib.dumps(info))
    package.run(sys.executable, "-B", ROOT / "scripts/build-native.py", app / "Contents/MacOS/AimDropReceiver", "--experiment-old")
    old_helper_digest = package.sha256(app / "Contents/MacOS/AimDropReceiver")
    assert old_helper_digest != new_helper_digest
    package.run("/usr/bin/codesign", "--force", "--sign", "-", app)
    other = root / "Untouched.app"
    if other.exists():
        shutil.rmtree(other)
    shutil.copytree(app, other, symlinks=True)
    original = package.sha256(other / "Contents/Info.plist")
    package.run("/usr/bin/open", "-n", app)
    deadline = time.monotonic() + 45
    while not (state / ("ready-" + first)).exists():
        if time.monotonic() > deadline:
            raise RuntimeError("Initial app did not start its receiver")
        time.sleep(0.25)
    identity = (state / "Pairing/identity.json").read_bytes()
    (state / "install").touch()
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if args.tamper and "Updater error domain=" in (state / "receiver.log").read_text():
            current = plistlib.loads(info_path.read_bytes())
            assert current["CFBundleVersion"] == first
            assert not (state / ("ready-" + second)).exists()
            assert package.sha256(other / "Contents/Info.plist") == original
            assert (state / "Pairing/identity.json").read_bytes() == identity
            # A malformed signature must not be confused with a download error.
            errors = [line for line in (state / "receiver.log").read_text().splitlines() if "Updater error domain=" in line]
            assert any("SUSparkleErrorDomain:" + str(code) in errors[-1] for code in (1002, 3001, 3002)), errors[-1]
            package.run("/usr/bin/osascript", "-e", 'tell application id "pl.aimdrop.update-experiment" to quit')
            server.shutdown()
            print("PASS: tampered", args.tamper, "rejected; running bundle, identity and second copy unchanged")
            print("Evidence:", state)
            return
        if (state / ("ready-" + second)).exists():
            break
        time.sleep(0.25)
    else:
        raise RuntimeError("Updated app did not report receiver-ready; inspect " + str(state / "receiver.log"))
    current = plistlib.loads(info_path.read_bytes())
    assert current["CFBundleVersion"] == second
    assert package.sha256(app / "Contents/MacOS/AimDropReceiver") == new_helper_digest
    assert package.sha256(other / "Contents/Info.plist") == original
    before = (state / ("ready-" + first)).read_text()
    after = (state / ("ready-" + second)).read_text()
    assert before.split("login=")[1].split()[0] == after.split("login=")[1].split()[0]
    if args.login == "on":
        assert before.split("login=")[1].split()[0] in ("1", "2"), "Login registration was not enabled or awaiting OS approval"
    assert f"path={app}" in after
    assert (state / "Pairing/identity.json").read_bytes() == identity
    assert (payload / "retained.txt").read_text() == "Retained across the Sparkle update"
    assert Inbox(state / "Incoming").list_ready()[0]["id"] == transfer
    package.verify_app(app)
    print("PASS: signed ad-hoc update, real drain/clean shutdown, exact-path replacement, relaunch, native receiver ready, login setting preserved (" + args.login + "), identity/backlog preservation, second copy unchanged")
    print("Evidence:", state)
    server.shutdown()
    (state / "cleanup").touch()


if __name__ == "__main__":
    main()
