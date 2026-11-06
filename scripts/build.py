#!/usr/bin/env python3
"""Build a local, ad-hoc-signed macOS .app; no package installation required."""
import pathlib
import argparse
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "dist" / "AirFolder.app"
CONTENTS = APP / "Contents"
RESOURCES = CONTENTS / "Resources"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=APP)
    app = parser.parse_args().output.resolve()
    CONTENTS = app / "Contents"
    RESOURCES = CONTENTS / "Resources"
    (CONTENTS / "MacOS").mkdir(parents=True, exist_ok=True)
    RESOURCES.mkdir(exist_ok=True)
    cache = ROOT / ".build" / "module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    artwork = ROOT / ".build" / "artwork"
    renderer = ROOT / ".build" / "render-artwork"
    subprocess.run(["xcrun", "swiftc", "-O", "-framework", "Cocoa", "-module-cache-path", str(cache),
                    str(ROOT / "scripts/artwork.swift"), "-o", str(renderer)], check=True)
    subprocess.run([str(renderer), str(ROOT / "docs/airfolder_znak.svg"), str(artwork)], check=True)
    subprocess.run(["iconutil", "-c", "icns", str(artwork / "AirFolder.iconset"),
                    "-o", str(RESOURCES / "AirFolder.icns")], check=True)
    shutil.copy2(artwork / "AirFolderStatus.pdf", RESOURCES / "AirFolderStatus.pdf")
    shutil.copy2(artwork / "AirFolder.png", RESOURCES / "AirFolder.png")
    subprocess.run([sys.executable, str(ROOT / "scripts/build-native.py"),
                    str(CONTENTS / "MacOS/AirFolderReceiver")], check=True)
    subprocess.run([
        "xcrun", "swiftc", "-O", "-framework", "Cocoa", "-framework", "UserNotifications",
        "-framework", "QuickLookThumbnailing", "-framework", "UniformTypeIdentifiers", "-framework", "ImageIO",
        "-module-cache-path", str(cache),
        *map(str, sorted((ROOT / "Sources").glob("*.swift"))),
        "-o", str(CONTENTS / "MacOS" / "AirFolder"),
    ], check=True)
    # Previous development launches may have created bytecode inside the bundle.
    receiver_resources = RESOURCES / "receiver"
    if receiver_resources.exists():
        shutil.rmtree(receiver_resources)
    shutil.copytree(ROOT / "receiver", receiver_resources,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    # Query the build Mac rather than claiming the codec levels of an old
    # example device. The generated JSON contains only media support tables.
    helper = ROOT / ".build" / "media-capabilities"
    media = b'{"Version":1}'
    try:
        subprocess.run(["xcrun", "clang", "-framework", "Foundation",
                        str(ROOT / "scripts/media-capabilities.m"), "-o", str(helper)], check=True)
        media = subprocess.run([str(helper)], check=True, stdout=subprocess.PIPE, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        print("Native media capabilities unavailable; using legacy profile")
    (RESOURCES / "media-capabilities.json").write_bytes(media)
    for name in ("LICENSE", "THIRD_PARTY.md"):
        shutil.copy2(ROOT / name, RESOURCES / name)
    with (CONTENTS / "Info.plist").open("wb") as stream:
        plistlib.dump({
            "CFBundleName": "AirFolder",
            "CFBundleDisplayName": "AirFolder",
            # Preserve notification permissions and user preferences across the rename.
            "CFBundleIdentifier": "pl.airfrajer.prototype",
            "CFBundleExecutable": "AirFolder",
            "CFBundleIconFile": "AirFolder.icns",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.6.3",
            "CFBundleVersion": "16",
            "LSMinimumSystemVersion": "26.0",
            "LSUIElement": True,
            "NSHighResolutionCapable": True,
            "NSLocalNetworkUsageDescription": "AirFolder odbiera wybrane przez Ciebie pliki AirDrop z iPhone’a.",
            "NSBonjourServices": ["_appSvcPrePair._tcp", "_applicationServicePairing._tcp", "_asquic._udp"],
            "AFPythonExecutable": str(pathlib.Path(sys.executable).resolve()),
        }, stream)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
