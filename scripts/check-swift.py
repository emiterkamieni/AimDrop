#!/usr/bin/env python3
"""Run native checks in isolated app bundles with the actual product resources."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sparkle

ROOT = Path(__file__).resolve().parents[1]
CHECKS = ["LocalizationChecks", "DiscoveryStatusChecks", "PairingWindowChecks", "UpdateChecks", "NotificationChecks", "WindowPlacementChecks", "AvatarChecks", "SettingsChecks", "LoginItemChecks",
          "PendingTransfersChecks", "PendingFilePreviewChecks", "RetentionSettingsChecks", "SettingsLanguageChecks", "ProgressModel", "ProgressResponsiveness", "ProgressPreview"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=ROOT / "dist/AimDrop.app")
    parser.add_argument("--only", nargs="+", choices=CHECKS)
    args = parser.parse_args()
    resources = args.app.resolve() / "Contents/Resources"
    product_info = plistlib.loads((resources.parent / "Info.plist").read_bytes())
    if not (resources / "AimDropAvatar.png").is_file():
        parser.error("Build the current app first, or pass --app with the staged app path")
    sources = [str(path) for path in sorted((ROOT / "Sources").glob("*.swift")) if path.name != "main.swift"]
    environment = dict(os.environ)
    for name in args.only or CHECKS:
        app = ROOT / ".build/checks" / (name + ".app")
        contents = app / "Contents"
        binary = contents / "MacOS" / name
        binary.parent.mkdir(parents=True, exist_ok=True)
        framework_dir = sparkle.embed(contents)
        destination = contents / "Resources"
        destination.mkdir(exist_ok=True)
        for resource in ("AimDrop.png", "AimDropAvatar.png", "AimDrop.icns", "AimDropStatus.pdf"):
            shutil.copy2(resources / resource, destination / resource)
        if (destination / "Localizations").exists():
            shutil.rmtree(destination / "Localizations")
        shutil.copytree(resources / "Localizations", destination / "Localizations")
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleName": "AimDrop Checks", "CFBundleIdentifier": "pl.aimdrop.checks." + name.lower(),
            "CFBundleExecutable": name, "CFBundlePackageType": "APPL", "CFBundleIconFile": "AimDrop.icns",
            "CFBundleShortVersionString": product_info["CFBundleShortVersionString"],
            "CFBundleVersion": product_info["CFBundleVersion"], "LSUIElement": True,
            **{key: value for key, value in product_info.items() if key.startswith("SU")},
        }))
        subprocess.run(["xcrun", "swiftc", "-D", "AIRFOLDER_CHECKS", "-parse-as-library",
                        "-framework", "Cocoa", "-framework", "UserNotifications", "-framework", "QuickLookThumbnailing",
                        "-framework", "UniformTypeIdentifiers", "-framework", "ImageIO", "-framework", "ServiceManagement",
                        "-F", str(framework_dir), "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                        "-module-cache-path", str(ROOT / ".build/module-cache"), *sources,
                        str(ROOT / "tests" / (name + ".swift")), "-o", str(binary)], check=True, cwd=ROOT)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        arguments = []
        if name == "AvatarChecks": arguments = [str(ROOT / ".build/avatar-fixtures"), str(resources / "AimDropAvatar.png")]
        elif name == "SettingsChecks": arguments = [str(ROOT / ".build/settings-current.png")]
        elif name == "SettingsLanguageChecks": arguments = [str(ROOT / ".build/previews")]
        elif name == "ProgressPreview": arguments = [str(ROOT / ".build/progress-current.png")]
        subprocess.run([str(binary), *arguments], check=True, cwd=ROOT, env=environment, timeout=60)
    print("PASS: native checks")


if __name__ == "__main__":
    main()
