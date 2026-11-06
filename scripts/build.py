#!/usr/bin/env python3
"""Build a local, ad-hoc-signed macOS .app; no package installation required."""
import pathlib
import argparse
import json
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "dist" / "AimDrop.app"
CONTENTS = APP / "Contents"
RESOURCES = CONTENTS / "Resources"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=APP)
    parser.add_argument("--bundled-python", type=pathlib.Path, help="Relocatable Python runtime to include in the app")
    args = parser.parse_args()
    app = args.output.resolve()
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
    subprocess.run([str(renderer), str(ROOT / "docs/aimdrop-icon.svg"), str(artwork)], check=True)
    subprocess.run(["iconutil", "-c", "icns", str(artwork / "AimDrop.iconset"),
                    "-o", str(RESOURCES / "AimDrop.icns")], check=True)
    shutil.copy2(artwork / "AimDropStatus.pdf", RESOURCES / "AimDropStatus.pdf")
    shutil.copy2(artwork / "AimDrop.png", RESOURCES / "AimDrop.png")
    shutil.copy2(artwork / "AimDropAvatar.png", RESOURCES / "AimDropAvatar.png")
    subprocess.run([sys.executable, str(ROOT / "scripts/build-native.py"),
                    str(CONTENTS / "MacOS/AimDropReceiver")], check=True)
    subprocess.run([
        "xcrun", "swiftc", "-O", "-framework", "Cocoa", "-framework", "UserNotifications",
        "-framework", "QuickLookThumbnailing", "-framework", "UniformTypeIdentifiers", "-framework", "ImageIO",
        "-framework", "ServiceManagement",
        "-module-cache-path", str(cache),
        *map(str, sorted((ROOT / "Sources").glob("*.swift"))),
        "-o", str(CONTENTS / "MacOS" / "AimDrop"),
    ], check=True)
    # Previous development launches may have created bytecode inside the bundle.
    receiver_resources = RESOURCES / "receiver"
    if receiver_resources.exists():
        shutil.rmtree(receiver_resources)
    shutil.copytree(ROOT / "receiver", receiver_resources,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    catalogs = RESOURCES / "Localizations"
    if catalogs.exists():
        shutil.rmtree(catalogs)
    shutil.copytree(ROOT / "Resources/Localizations", catalogs)
    purpose = "AimDrop receives the files you choose to share with AirDrop from your Apple devices."
    for catalog in catalogs.glob("*.json"):
        translated = json.loads(catalog.read_text(encoding="utf-8"))
        localized = RESOURCES / (catalog.stem + ".lproj")
        localized.mkdir(exist_ok=True)
        (localized / "InfoPlist.strings").write_text(
            '"NSLocalNetworkUsageDescription" = ' + json.dumps(translated.get(purpose, purpose), ensure_ascii=False) + ';\n',
            encoding="utf-8")
    bundled_python = RESOURCES / "python"
    if bundled_python.exists():
        shutil.rmtree(bundled_python)
    if args.bundled_python:
        runtime = args.bundled_python.resolve()
        if not (runtime / "bin/python3").is_file():
            parser.error("--bundled-python must contain bin/python3")
        shutil.copytree(runtime, bundled_python, symlinks=True,
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
            "CFBundleName": "AimDrop",
            "CFBundleDisplayName": "AimDrop",
            # Preserve notification permissions and user preferences across the rename.
            "CFBundleIdentifier": "pl.airfrajer.prototype",
            "CFBundleExecutable": "AimDrop",
            "CFBundleIconFile": "AimDrop.icns",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.8.2",
            "CFBundleVersion": "22",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": ["en", "pl", "de", "fr", "es", "it", "pt", "nl", "sv", "cs", "uk", "ja", "ko", "zh-Hans", "zh-Hant"],
            "LSMinimumSystemVersion": "26.0",
            "LSUIElement": True,
            "NSHighResolutionCapable": True,
            "NSLocalNetworkUsageDescription": "AimDrop receives the files you choose to share with AirDrop from your Apple devices.",
            "NSBonjourServices": ["_appSvcPrePair._tcp", "_applicationServicePairing._tcp", "_asquic._udp"],
            "AFPythonExecutable": "python/bin/python3" if args.bundled_python else str(pathlib.Path(sys.executable).resolve()),
        }, stream)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
