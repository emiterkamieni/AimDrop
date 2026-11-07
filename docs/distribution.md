# Portable macOS releases

The release asset is `AimDrop-<version>-macos-arm64.zip`. It contains one
`AimDrop.app`, including its native receiver and a private Python runtime.
End users do not need Python, Conda, Homebrew, Xcode, or pip packages.
The app requires an **Apple Silicon Mac running macOS 26 or later**.

## Install a downloaded release

1. Download the versioned ZIP and `SHA256SUMS` from the same GitHub release.
   In their download directory, verify the ZIP:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

2. Extract the ZIP in Finder and move `AimDrop.app` to `/Applications`.
3. Open the app. These builds are **ad-hoc signed**, not Developer ID signed
   or notarized. Gatekeeper can block a browser-downloaded copy. After the
   blocked launch, use **System Settings → Privacy & Security → Open Anyway**
   for AimDrop, authenticate if requested, and confirm **Open**. The option
   can be unavailable on a managed Mac. Do not disable Gatekeeper globally.
4. Allow local-network access and notifications when macOS asks. AimDrop runs
   in the menu bar. Configure launch at login after moving it to its final
   location.

The checksum detects a damaged or mismatched download; it is not an Apple
notarization ticket. Successful `codesign --verify` checks bundle integrity,
not Gatekeeper approval or publisher identity.

## Build a release

Build natively on Apple Silicon, with:

- macOS 26 or later;
- Xcode Command Line Tools (or Xcode selected with `xcode-select`), providing
  `xcrun`, Swift, Clang, and the macOS SDK needed by the native build;
- Python 3.9 or later to run the build scripts;
- the standard macOS tools `codesign`, `ditto`, `xattr`, `lipo`, and `otool`;
- HTTPS access to GitHub release assets and `raw.githubusercontent.com` on the
  first run. Verified downloads are cached for later offline builds.

From the repository root:

```sh
# Optional: download and test the runtime without compiling the app.
python3 scripts/package.py --prepare-runtime

# Build, sign, verify, and archive the app. Use its current source version.
python3 scripts/package.py --version 0.8.4
```

`--version` is an assertion against `CFBundleShortVersionString`; it does not
change the version. Omit it to use the built app's version automatically.
Outputs are:

```text
dist/AimDrop.app
dist/AimDrop-0.8.4-macos-arm64.zip
dist/SHA256SUMS
```

`SHA256SUMS` describes the ZIP from this invocation. Packaging uses a fresh,
temporary staging directory under `.build/`; it does not package an installed
app or copy user preferences, received files, pairing records, certificates,
or keys. The downloaded runtime is freshly extracted from its verified archive
on each invocation, so additions made to a previously prepared runtime do not
enter the release. Build and download caches stay under ignored `.build/`.

The packager signs AimDrop's bundled Mach-O executables/libraries ad hoc, then
signs the enclosing app. Sparkle retains its upstream nested signatures and
universal arm64/x86_64 binaries; all AimDrop/Python binaries remain arm64-only.
The packager checks architecture, symlink containment, dynamic
library load paths, the relative Python setting, runtime imports, SSL contexts,
and code signatures. It uses `ditto` to preserve executable modes and symlinks
without Finder metadata, then extracts the ZIP into a different directory with
spaces in its name, removes the original staged app, and repeats runtime and
signature checks. Runtime checks use isolated Python, a temporary home, and a
system-only PATH. They also run the bundled receiver's `--help` import path.
These checks do not replace an app-launch and real-device transfer test.

Quit the running `dist/AimDrop.app` before packaging; the packager refuses to
overwrite it while running. The verified portable bundle is delivered there,
alongside the ZIP, rather than at a development staging path.
For a release intended to update the running copy, use `--archive-only`. The
fresh staged build is verified and archived normally, while `dist/AimDrop.app`
stays at its current version until the user installs the published update.

## Sparkle updates

`scripts/sparkle.py` pins the official Sparkle 2.10.1 distribution with SHA-256
`1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27`.
The framework is embedded in `Contents/Frameworks`; its executable permissions,
symlinks, licenses and nested helper signatures are retained. Load-path checks
use each helper's executable location. Bundled tools remain in the build cache.

Production update keys were generated in the login Keychain under the
`AimDrop-Releases` account. Only the public key is in `scripts/build.py` and the
app's `SUPublicEDKey`. Keep a protected backup of the signing key outside this
repository. Ad-hoc signing does not provide a Developer ID fallback if this key
is lost. Use the separate `AimDrop-UpdateExperiment` account for test builds.

Increment both the displayed release version and the monotonic build number in
`scripts/build.py`. To build and sign a release:

```sh
python3 -B scripts/prepare-update.py --version 0.8.4 --notes docs/releases/0.8.4.md
# Optional: --notes release-notes.md --previous-appcast previous-appcast.xml
# After packaging separately: add --existing-build
# To keep the current dist/AimDrop.app running: add --archive-only
```

Allow Sparkle's `generate_appcast` tool to access the appropriate key in the
system Keychain dialog. It signs the final archive and feed; editing either
afterward requires signing again. This uses full ZIP updates, without deltas.
Before emitting the feed and checksums, `prepare-update.py` independently checks
both Ed25519 signatures with `verify-update.swift` and the archive's public key.
Verification uses CryptoKit and does not access the Keychain.
This dialog is shown only to the release publisher, never to end users checking
or installing an update. Keep Sparkle's original Keychain item label
`Private key for signing Sparkle updates`; distinguish keys by account
(`AimDrop-Releases` versus `AimDrop-UpdateExperiment`). Changing this sensitive
item's label caused macOS to return `errSecInvalidItemRef` during signing;
restoring the original label restored access without replacing the key.
macOS controls the dialog wording and displays `generate_appcast` as the requester.
The output is `dist/appcast.xml` and an updated `dist/SHA256SUMS` alongside the
app and ZIP. Existing feed entries retain their version-specific download URLs.

Attach the ZIP, appcast and checksums to the matching **draft** GitHub release,
then publish all assets together. The app's stable feed URL is
`https://github.com/emiterkamieni/AimDrop/releases/latest/download/appcast.xml`.
The archive URLs point to specific release tags, not mutable latest ZIPs.
Version 0.8.4 (build 24) is the first public updater-bearing release. Public
0.8.2 and earlier clients must install it manually once. The local 0.8.3 build
(build 23) can install 0.8.4 through its existing updater using the same public key.

Run `python3 -B scripts/check-update-experiment.py` for an actual two-version
update using an isolated full bundle under `dist/update-experiment`, a local
signed feed, test-only bundle identity/storage and native loopback transport.
It verifies exact-path replacement, relaunch, the real clean-shutdown barrier,
login status and inbox/identity persistence. Use `--login on` to test enabled
registration, or `--tamper archive` / `--tamper feed` to verify rejection.
The two test versions contain differently compiled/signed native helpers too.
`scripts/check-native-update.py --app dist/AimDrop.app` exercises native paired
HTTP3 transfers before, after canceling, and during the drain barrier (using the
research client built by `scripts/research/build-pairing-prototypes.py`).
This does not validate actual
login-session launch or iPhone permissions; those require an interactive device
check. Experiment builds are rejected by the production signing script.

The script produces local files only. A release maintainer should test the
extracted app, then attach its ZIP and matching `SHA256SUMS` to the release
for the corresponding source revision. Keep the corresponding AimDrop source
available under GPL-3.0-only.

## Pinned Python runtime

Source: [astral-sh/python-build-standalone, release 20261026](https://github.com/astral-sh/python-build-standalone/releases/tag/20261026).

| Field | Value |
| --- | --- |
| CPython | 3.13.18, standard GIL-enabled build |
| Target | `aarch64-apple-darwin` |
| Archive | `cpython-3.13.18+20261026-aarch64-apple-darwin-install_only_stripped.tar.gz` |
| Compressed size | 25,265,774 bytes |
| SHA-256 | `8392b6ea51d94391befb2c31ebe75463f045d0b69dfcf5e1bb3234e1f5fa3405` |
| Upstream source commit | `fa506e0858ac9f2cc5b289c137b888a2aa24d1ee` |
| Prepared runtime root | `.build/python-runtime/cpython-3.13.18+20261026/python` |
| Bundled runtime root | `AimDrop.app/Contents/Resources/python` |

The pinned digest was checked against both the GitHub release API's asset
`digest` and the release's upstream `SHA256SUMS` before adoption. Every download
and cached archive is checked against that digest before extraction. Downloads,
file counts, individual extracted files, and total extracted size are bounded.
The extractor rejects traversal, case-colliding/duplicate names, special files,
hard links, and symlinks that do not point to an archived regular file. It
creates links only after writing regular files and does not restore upstream
ownership or special permission bits.

To update Python, review a stable 3.12/3.13 upstream asset and its published
digest using the GitHub API. Update the release, Python version, archive size,
SHA-256, source commit, and source-file hashes in `scripts/package.py` together.
Run `--prepare-runtime`, then package and test the resulting app. Do not replace
the pin with a mutable `latest` URL or a developer's Python installation.

## Runtime licenses and sources

The archive's original CPython license remains at
`Contents/Resources/python/lib/python3.13/LICENSE.txt`; included pip and vendored
package notices remain in their upstream locations. CPython is distributed
under the Python Software Foundation license and its included historical and
third-party notices; bundled dependencies retain their own licenses, including
OpenSSL's Apache-2.0 license.

The packager also includes `Contents/Resources/python/licenses/` containing:

- the upstream `LICENSE` and complete `LICENSE.*.txt` collection from the pinned
  source commit, including Python, OpenSSL, compression libraries, libffi,
  SQLite, and Tcl/Tk notices;
- upstream `downloads.json`, with dependency source URLs, versions, and hashes;
- `runtime.json`, recording the runtime provenance and the pinned notice hashes.

The complete upstream notice collection covers more platforms/components than
this macOS runtime. It is included intact because the install-only archive
omits the full distribution's `licenses/` directory. License/source files are
downloaded from the pinned upstream commit and individually SHA-256 verified.
AimDrop's own `LICENSE` and `THIRD_PARTY.md` remain in `Contents/Resources/`.

## Build integration contract

The packager calls:

```sh
python3 scripts/build.py --output <staged-app>/AimDrop.app \
  --bundled-python <prepared-runtime-root>
```

The build must copy the **contents of that runtime root**, including its
`licenses/` directory and symlinks, into `Contents/Resources/python`, set
`AFPythonExecutable` to the relative string `python/bin/python3`, and include
both `Contents/MacOS/AimDrop` and `Contents/MacOS/AimDropReceiver`. The GUI must
resolve that setting relative to its own Resources directory, independently
of the working directory, before launching the receiver in isolated Python
mode without writing bytecode into the signed bundle. A development build may
use an external interpreter; the release packager rejects such a setting.

The packager performs final inside-out ad-hoc signing after the build has
finished writing resources. Any later change to the app requires re-signing
and regenerating the ZIP and checksum.
