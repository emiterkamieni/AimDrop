#!/usr/bin/env python3
"""Build a release and sign its ZIP/feed using the AimDrop Keychain account."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
import sparkle

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "AimDrop-Releases"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--notes", type=Path, help="Optional release notes in Markdown")
    parser.add_argument("--previous-appcast", type=Path, help="Retain existing version-specific entries")
    parser.add_argument("--existing-build", action="store_true", help="Sign the already verified dist release")
    parser.add_argument("--archive-only", action="store_true", help="publish an archive while preserving the currently running dist app")
    args = parser.parse_args()
    if not args.existing_build:
        subprocess.run([sys.executable, "-B", ROOT / "scripts/package.py", "--version", args.version,
                        *(["--archive-only"] if args.archive_only else [])], check=True)
    dist = ROOT / "dist"
    name = f"AimDrop-{args.version}-macos-arm64.zip"
    archive = dist / name
    with zipfile.ZipFile(archive) as zipped:
        info = plistlib.loads(zipped.read("AimDrop.app/Contents/Info.plist"))
    if (info["CFBundleShortVersionString"] != args.version or "AimDropUpdateExperiment" in info
            or info.get("CFBundleIdentifier") != "pl.airfrajer.prototype"):
        parser.error("The release version or build configuration does not match")
    if not args.archive_only and info != plistlib.loads((dist / "AimDrop.app/Contents/Info.plist").read_bytes()):
        parser.error("The ZIP does not contain the current dist/AimDrop.app build")
    tools = sparkle.prepare() / "bin"
    verifier = ROOT / ".build/verify-update"
    subprocess.run(["xcrun", "swiftc", "-O", "-target", "arm64-apple-macos14.0", "-framework", "CryptoKit",
                    "-module-cache-path", ROOT / ".build/module-cache", ROOT / "scripts/verify-update.swift", "-o", verifier], check=True)
    # Reuse the exact final archive. No bundle or ZIP mutations after signing.
    with tempfile.TemporaryDirectory(prefix="appcast-", dir=ROOT / ".build") as folder:
        stage = Path(folder)
        shutil.copy2(archive, stage / name)
        if args.previous_appcast:
            shutil.copy2(args.previous_appcast, stage / "appcast.xml")
        if args.notes:
            shutil.copy2(args.notes, stage / (Path(name).stem + ".md"))
        release = f"https://github.com/emiterkamieni/AimDrop/releases/tag/v{args.version}"
        subprocess.run([tools / "generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0", "--embed-release-notes",
                        "--download-url-prefix", f"https://github.com/emiterkamieni/AimDrop/releases/download/v{args.version}/",
                        "--full-release-notes-url", release, "--link", release, stage], check=True)
        subprocess.run([verifier, archive, stage / "appcast.xml", info["SUPublicEDKey"]], check=True)
        shutil.copy2(stage / "appcast.xml", dist / "appcast.xml")
    manifest = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in (archive, dist / "appcast.xml"))
    (dist / "SHA256SUMS").write_text(manifest, encoding="ascii")
    print("Signed release:", archive)
    print("Signed feed:", dist / "appcast.xml")
    print("Upload ZIP, appcast.xml and SHA256SUMS to a draft GitHub release, then publish it together.")


if __name__ == "__main__":
    main()
