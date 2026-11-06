"""Build the bundled, headless receiver from the same transport as native tests."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/research"
output = Path(sys.argv[1]).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable, str(SOURCE / "build-network-research-module.py")], cwd=ROOT, check=True)
objects = []
for name in ("pake-bridge", "pair-verify-bridge"):
    obj = ROOT / ".build" / (name + "-helper.o")
    subprocess.run(["xcrun", "clang", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                    "-c", str(SOURCE / (name + ".m")), "-o", str(obj)], check=True)
    objects.append(str(obj))
subprocess.run([
    "xcrun", "swiftc", "-O", "-parse-as-library", "-D", "AIRFOLDER_HELPER", "-module-name", "rapportd",
    "-target", "arm64-apple-macos14.0", "-I", str(ROOT / ".build/research-modules"),
    "-module-cache-path", str(ROOT / ".build/research-module-cache"),
    "-import-objc-header", str(SOURCE / "pake-bridge.h"), str(ROOT / "NativeReceiver/helper.swift"),
    str(ROOT / "Sources/ReceiverAvatar.swift"),
    *[str(SOURCE / (name + ".swift")) for name in
      ("airfolder-pairing-prototype", "native-file-service", "streaming-upload", "pair-verify", "pairing-store")],
    *objects, "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup", "-o", str(output),
], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(output)], check=True)
