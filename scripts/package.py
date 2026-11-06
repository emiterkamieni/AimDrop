#!/usr/bin/env python3
"""Build a portable, ad-hoc-signed Apple Silicon release using only the stdlib."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build" / "python-runtime"
RELEASE = "20261026"
PYTHON_VERSION = "3.13.18"
ASSET = f"cpython-{PYTHON_VERSION}+{RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
ASSET_SIZE = 25265774
ASSET_SHA256 = "8392b6ea51d94391befb2c31ebe75463f045d0b69dfcf5e1bb3234e1f5fa3405"
UPSTREAM = "https://github.com/astral-sh/python-build-standalone"
ASSET_URL = f"{UPSTREAM}/releases/download/{RELEASE}/{ASSET.replace('+', '%2B')}"
# Release tag resolved through GitHub's API. License files are pinned separately
# because install_only archives omit the full distribution's licenses/ directory.
SOURCE_COMMIT = "fa506e0858ac9f2cc5b289c137b888a2aa24d1ee"
SOURCE_HASHES = {
    "LICENSE": "1f256ecad192880510e84ad60474eab7589218784b9a50bc7ceee34c2b91f1d5",
    "LICENSE.bdb.txt": "3bdff06e69991c94664f2ef5c5f8096f60b7dbec071756ea6cc26b445e06ec5b",
    "LICENSE.bzip2.txt": "1f38bbc7caacafd65169276d759c0d88c991b753b643ce35d0e45ea1971dd441",
    "LICENSE.cpython.txt": "86e61415828a8b5b06ec8d024e6f086ce155a8b85fd0c419c0ba4dc004e74fdd",
    "LICENSE.expat.txt": "122f2c27000472a201d337b9b31f7eb2b52d091b02857061a8880371612d9534",
    "LICENSE.libX11.txt": "2daec087a88e7c9b8082557cdeebad5bbb8155a4137472f0b22e269cd99d0c1e",
    "LICENSE.libXau.txt": "56abe29bb1d9806a9e04fa9f80fed2c0f18027594df3f098148d814aef6bddfa",
    "LICENSE.libedit.txt": "29cea33c32bbc9785142386377915612a2fa786482c46843383384aded2e09b1",
    "LICENSE.libffi.txt": "deaf3a42effb551a5b140fa9afefed183a27f1341c6d1bf430d106a5e6931fc0",
    "LICENSE.liblzma.txt": "9a4062de0a2c388a98cf35a35d348b62fa97c838a71c3c28ee1a2d7d0a565b02",
    "LICENSE.libuuid.txt": "122ee1f7e258f2c3c0e538a75c037684f420454bf3850ddc74ce750bbf5fe86b",
    "LICENSE.libxcb.txt": "c5ffbfeaa501071ceeb97b7de2c0d703fdaa35de01c0fb6cbac1c28453a3e9fd",
    "LICENSE.mpdecimal.txt": "669512af7219f58be03a398766d7c9da11a3b3df9d3f05cb74c5ceca25c8da3b",
    "LICENSE.ncurses.txt": "87a4c4442337b8968ef956031c406b74f9cb7149b7ba87311bdaba534816201c",
    "LICENSE.openssl-3.txt": "7d5450cb2d142651b8afa315b5f238efc805dad827d91ba367d8516bc9d49e7a",
    "LICENSE.sqlite.txt": "38bef3d28b24f145ea293bd3b6eb4b20396982abc8303128fb493986ea5bc719",
    "LICENSE.tcl.txt": "c0a69a2bfd757361ec7e6143973b103c90409316b49e9c88db26ad6388e79f16",
    "LICENSE.tix.txt": "3ac5cdd0bef6c43ce34c6a7ced452081d9e5a0bf94082b9f9147d23ec9e214f5",
    "LICENSE.zlib-ng.txt": "6c9f0d975b41afaa34d22f55bb8986ce69e5cb7ad327cb2b28820cd425edf5ee",
    "LICENSE.zlib.txt": "818922b2620f12801a12bf78e399644a30990e66824abd8ca8ec24d451d6f92c",
    "LICENSE.zstd.txt": "7055266497633c9025b777c78eb7235af13922117480ed5c674677adc381c9d8",
    "pythonbuild/downloads.json": "8b0e472c66797dcd58dfa461171c7f416602503924091e5e4629e776221b8a27",
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, path, digest, limit):
    """Reuse only verified cache entries; bound downloads before writing them."""
    if path.is_file() and not path.is_symlink() and path.stat().st_size <= limit:
        if sha256(path) == digest:
            return path
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "AimDrop-release-packager"})
            with urllib.request.urlopen(request, timeout=60) as response:
                if not response.url.startswith("https://"):
                    raise ValueError("Refusing an insecure download redirect")
                total = 0
                for block in iter(lambda: response.read(1024 * 1024), b""):
                    total += len(block)
                    if total > limit:
                        raise ValueError(f"Download exceeds size limit: {path.name}")
                    stream.write(block)
            stream.flush()
            if sha256(temporary) != digest:
                raise ValueError(f"SHA-256 mismatch: {path.name}")
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    return path


def extract_runtime(archive, destination):
    """Validate the whole manifest, then write files before creating any links."""
    if sha256(archive) != ASSET_SHA256 or archive.stat().st_size != ASSET_SIZE:
        raise ValueError("Runtime archive does not match the pinned release")
    with tarfile.open(archive, "r:gz") as bundle:
        members, names, folded, total = [], {}, set(), 0
        for member in bundle:
            path = PurePosixPath(member.name)
            if (not path.parts or path.parts[0] != "python" or path.is_absolute()
                    or ".." in path.parts or "\\" in member.name
                    or any(ord(c) < 32 for c in member.name)
                    or str(path) != member.name.rstrip("/")):
                raise ValueError("Unsafe runtime archive path")
            if not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError("Unsupported runtime archive entry (including hard links)")
            key = str(path)
            if key.casefold() in folded:
                raise ValueError("Duplicate runtime archive path")
            folded.add(key.casefold())
            names[key] = member
            members.append(member)
            total += member.size
            if member.size < 0 or member.size > 128 * 1024**2 or total > 256 * 1024**2 or len(members) > 10000:
                raise ValueError("Runtime archive exceeds extraction limits")
        for member in members:
            path = PurePosixPath(member.name)
            for parent in path.parents:
                if str(parent) in names and not names[str(parent)].isdir():
                    raise ValueError("Runtime archive traverses a non-directory")
            if member.issym():
                target = posixpath.normpath(posixpath.join(str(path.parent), member.linkname))
                if (posixpath.isabs(member.linkname) or "\\" in member.linkname
                        or target not in names or not names[target].isfile()):
                    raise ValueError("Runtime symlink must name an archived regular file")
        # Do not let tarfile apply ownership, setuid bits, extended attributes, or
        # symlink traversal. This also works with build-host Python 3.9.
        for member in members:
            target = destination / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                target.mkdir(exist_ok=True)
            elif member.isfile():
                with bundle.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
        for member in members:
            if member.issym():
                (destination / member.name).symlink_to(member.linkname)


def prepare_runtime():
    archive = download(ASSET_URL, CACHE / "downloads" / ASSET, ASSET_SHA256, ASSET_SIZE)
    licenses = []
    for name, digest in SOURCE_HASHES.items():
        url = f"https://raw.githubusercontent.com/astral-sh/python-build-standalone/{SOURCE_COMMIT}/{name}"
        licenses.append(download(url, CACHE / "downloads/licenses" / Path(name).name, digest, 1024**2))
    runtime = CACHE / f"cpython-{PYTHON_VERSION}+{RELEASE}" / "python"
    with tempfile.TemporaryDirectory(prefix="extract-", dir=CACHE) as folder:
        extracted = Path(folder)
        extract_runtime(archive, extracted)
        notices = extracted / "python/licenses"
        notices.mkdir()
        for source in licenses:
            shutil.copyfile(source, notices / source.name)
        (notices / "runtime.json").write_text(json.dumps({
            "project": UPSTREAM, "release": RELEASE, "python_version": PYTHON_VERSION,
            "asset": ASSET, "url": ASSET_URL, "sha256": ASSET_SHA256,
            "source_commit": SOURCE_COMMIT, "source_sha256": SOURCE_HASHES,
            "note": "Upstream license collection includes other platforms. See downloads.json for dependency source URLs.",
        }, indent=2) + "\n", encoding="utf-8")
        runtime.parent.mkdir(parents=True, exist_ok=True)
        if runtime.exists():
            shutil.rmtree(runtime)
        (extracted / "python").rename(runtime)
    return runtime


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def inside(path, root):
    return path.resolve().is_relative_to(root.resolve())


def native_files(root):
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            if os.path.isabs(os.readlink(path)) or not inside(path, root) or not path.exists():
                raise ValueError(f"Non-portable bundle symlink: {path.relative_to(root)}")
        elif path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
                                      b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
                    result.append(path)
    return result


def verify_native(root, executable_dir):
    """Reject developer-local dylibs/rpaths, including optional Python modules."""
    binaries = native_files(root)
    if not binaries:
        raise ValueError("No Mach-O executables found")
    for path in binaries:
        arches = run("/usr/bin/lipo", "-archs", path, capture_output=True, text=True).stdout.split()
        if arches != ["arm64"]:
            raise ValueError(f"Expected arm64: {path.relative_to(root)}")
        loads = run("/usr/bin/otool", "-l", path, capture_output=True, text=True).stdout
        rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", loads)
        python = root / "Contents/Resources/python"
        binary_executable_dir = python / "bin" if inside(path, python) else executable_dir

        def expand(value):
            if value.startswith("@loader_path/"):
                return path.parent / value[len("@loader_path/"):]
            if value.startswith("@executable_path/"):
                return binary_executable_dir / value[len("@executable_path/"):]
            raise ValueError(f"Non-portable load path in {path.relative_to(root)}")

        for rpath in rpaths:
            if not inside(expand(rpath), root):
                raise ValueError("Runtime search path leaves the bundle")
        # LC_ID_DYLIB names the library itself; unlike LC_LOAD_* it is not a
        # dependency (some upstream Tcl libraries use a bare filename here).
        libraries = re.findall(r"cmd LC_(?:LOAD|LOAD_WEAK|REEXPORT|LOAD_UPWARD|LAZY_LOAD)_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset", loads)
        for library in libraries:
            if library.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if library.startswith("@rpath/"):
                candidates = [expand(rpath) / library[len("@rpath/"):] for rpath in rpaths]
            else:
                candidates = [expand(library)]
            if not any(inside(candidate, root) and candidate.is_file() for candidate in candidates):
                raise ValueError(f"Unresolved bundled dylib in {path.relative_to(root)}: {library}")
    return binaries


def verify_runtime(runtime):
    executable = runtime / "bin/python3"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("Bundled python/bin/python3 is not executable")
    for name, digest in SOURCE_HASHES.items():
        if sha256(runtime / "licenses" / Path(name).name) != digest:
            raise ValueError("Missing or modified runtime license/source notice")
    verify_native(runtime, runtime / "bin")
    code = r'''
import bz2, ctypes, decimal, fcntl, hashlib, http.server, json, lzma
import pathlib, platform, plistlib, select, socket, sqlite3, ssl, sys, tarfile, threading, uuid, zlib
root = pathlib.Path(sys.argv[1]).resolve()
assert sys.version.split()[0] == sys.argv[2]
assert platform.machine() == "arm64"
assert pathlib.Path(sys.prefix).resolve() == root
assert pathlib.Path(sys.base_prefix).resolve() == root
assert all(pathlib.Path(p).resolve().is_relative_to(root) for p in sys.path)
assert pathlib.Path(ssl.__file__).resolve().is_relative_to(root)
assert ssl.OPENSSL_VERSION_INFO >= (3, 0)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
assert context.get_ciphers() and ssl.HAS_TLSv1_3
ctypes.CDLL("/usr/lib/libSystem.B.dylib")
for module in (bz2, lzma, zlib):
    assert module.decompress(module.compress(b"AimDrop")) == b"AimDrop"
assert sqlite3.connect(":memory:").execute("select 1").fetchone() == (1,)
print("Runtime OK: Python " + platform.python_version() + "; " + ssl.OPENSSL_VERSION)
'''
    with tempfile.TemporaryDirectory(prefix="isolated-home-", dir=CACHE) as home:
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "TMPDIR": home, "LC_ALL": "C"}
        run(executable, "-I", "-B", "-S", "-c", code, runtime, PYTHON_VERSION,
            env=environment, cwd=home, timeout=30)
        receiver = runtime.parent / "receiver/main.py"
        if receiver.is_file():
            run(executable, "-I", "-B", receiver, "--help", env=environment,
                cwd=home, timeout=30, stdout=subprocess.DEVNULL)


def verify_app(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("AFPythonExecutable") != "python/bin/python3":
        raise ValueError("Build must set AFPythonExecutable to python/bin/python3")
    if info.get("CFBundleExecutable") != "AimDrop":
        raise ValueError("Build must set CFBundleExecutable to AimDrop")
    version = info.get("CFBundleShortVersionString", "")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError("Invalid release version in Info.plist")
    for name in ("AimDrop", "AimDropReceiver"):
        executable = app / "Contents/MacOS" / name
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError(f"Missing app executable: {name}")
    for name in ("receiver/main.py", "LICENSE", "THIRD_PARTY.md"):
        if not (app / "Contents/Resources" / name).is_file():
            raise ValueError(f"Missing app resource: {name}")
    runtime = app / "Contents/Resources/python"
    verify_runtime(runtime)
    # Runtime executable_path is its own bin/, not the GUI's Contents/MacOS/.
    for path in verify_native(app, app / "Contents/MacOS"):
        run("/usr/bin/codesign", "--verify", "--strict", path, capture_output=True)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    return version


def package(runtime, expected_version):
    with tempfile.TemporaryDirectory(prefix="package-", dir=ROOT / ".build") as folder:
        stage = Path(folder)
        app = stage / "AimDrop.app"
        run(sys.executable, ROOT / "scripts/build.py", "--output", app, "--bundled-python", runtime)
        # Only a fresh build enters this archive; no installed app or user state
        # is copied. Strip Finder/resource metadata before the final signatures.
        run("/usr/bin/xattr", "-cr", app)
        for path in app.rglob("*"):
            if path.is_file() and (path.name == ".DS_Store" or path.name.startswith("._")):
                path.unlink()
        for binary in native_files(app):
            run("/usr/bin/codesign", "--force", "--sign", "-", binary, capture_output=True)
        run("/usr/bin/codesign", "--force", "--sign", "-", app)
        version = verify_app(app)
        if expected_version and version != expected_version:
            raise ValueError(f"Built version {version} differs from --version {expected_version}")
        name = f"AimDrop-{version}-macos-arm64.zip"
        archive = stage / name
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", app, archive)
        with zipfile.ZipFile(archive) as zipped:
            if zipped.testzip() is not None:
                raise ValueError("Release ZIP failed its integrity check")
            if any(not name.startswith("AimDrop.app/") for name in zipped.namelist()):
                raise ValueError("Unexpected file outside AimDrop.app in release ZIP")
        relocated = stage / "relocated app with spaces"
        run("/usr/bin/ditto", "-x", "-k", "--noextattr", "--noqtn", archive, relocated)
        # Remove the original so relocation cannot accidentally fall back to it.
        shutil.rmtree(app)
        verify_app(relocated / "AimDrop.app")
        dist = ROOT / "dist"
        dist.mkdir(exist_ok=True)
        output = dist / name
        archive.replace(output)
        manifest = stage / "SHA256SUMS"
        manifest.write_text(f"{sha256(output)}  {name}\n", encoding="ascii")
        manifest.replace(dist / "SHA256SUMS")
        print(output)
        print(dist / "SHA256SUMS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="require this app version (does not modify the build version)")
    parser.add_argument("--prepare-runtime", action="store_true", help="download and verify Python without building the app")
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        parser.error("Run natively on an Apple Silicon Mac")
    runtime = prepare_runtime()
    if args.prepare_runtime:
        with tempfile.TemporaryDirectory(prefix="relocation check ", dir=CACHE) as folder:
            moved = Path(folder) / "moved python"
            shutil.copytree(runtime, moved, symlinks=True)
            verify_runtime(moved)
        print(runtime)
    else:
        package(runtime, args.version)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        sys.exit(f"Packaging failed: {error}")
