"""Pinned Sparkle distribution, shared by builds, checks and release signing."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "2.10.1"
DIGEST = "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
CACHE = ROOT / ".build" / "sparkle"


def prepare():
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / f"Sparkle-{VERSION}.tar.xz"
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        try:
            with urllib.request.urlopen(f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/{archive.name}", timeout=60) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != DIGEST:
                raise ValueError("Sparkle archive checksum mismatch")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != DIGEST:
        raise ValueError("Sparkle archive checksum mismatch")
    distribution = CACHE / VERSION
    if not (distribution / "Sparkle.framework").exists():
        distribution.mkdir(exist_ok=True)
        subprocess.run(["/usr/bin/tar", "-xf", str(archive), "-C", str(distribution)], check=True)
    return distribution


def embed(contents):
    distribution = prepare()
    source = distribution / "Sparkle.framework"
    destination = contents / "Frameworks" / source.name
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    shutil.copy2(distribution / "LICENSE", resources / "Sparkle-LICENSE")
    # Retain the upstream signatures of the framework and its nested helpers.
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
    return destination.parent


if __name__ == "__main__":
    print(prepare())
