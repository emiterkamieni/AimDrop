<p align="center">
  <img src="docs/images/app-icon.png" width="96" alt="AimDrop icon">
</p>

# AimDrop

**Receive AirDrop files on your Mac. Choose where they go.**

AimDrop lives in the macOS menu bar and appears as a receiver in your iPhone's
standard **Share → AirDrop** sheet. Files arrive in a persistent inbox before you
choose a destination, so dismissing the folder picker never discards a transfer.

**[Download for Apple Silicon](https://github.com/emiterkamieni/AimDrop/releases/latest)**
 · [Releases](https://github.com/emiterkamieni/AimDrop/releases)
 · [Report an issue](https://github.com/emiterkamieni/AimDrop/issues)

## Features

- **Choose a folder after receiving**, or automatically save new transfers to a selected folder.
- **A durable inbox.** Unsaved files survive closing the picker and restarting the app.
- **Live progress:** a blue progress bar, received bytes, file counts, and cancellation.
- **Save Files…** reopens the destination picker for the latest unsaved transfer.
- **Your receiver identity:** choose a name and an avatar, with circular cropping and zoom.
- **Remembered PIN pairing** with a fresh PIN when you change the receiver name or avatar.
- **Launch at login**, managed through macOS login items.
- **15 languages**, selected automatically from your system preferences or manually in Settings.
- **GitHub update checks** every 24 hours, a manual check, and a download notification for a newer release.

<img src="docs/images/settings.png" width="600" alt="AimDrop settings with a circular avatar, save destination, language and update controls">

## Requirements

- An **Apple Silicon Mac running macOS 26 or later**.
- An iPhone with AirDrop. Device interoperability has been tested with **iOS 26.6.1 and macOS 26.5.2**.
- Local-network access enabled for AimDrop.

Release ZIPs include their own Python runtime. Python, Homebrew and developer
tools are needed only when building from source.

## Install

1. Download the latest `AimDrop-…-macos-arm64.zip` from [Releases](https://github.com/emiterkamieni/AimDrop/releases/latest).
2. Extract it and move **AimDrop.app** to **Applications**.
3. Open AimDrop and allow local-network access and notifications.
4. If desired, enable **Launch at login** in Settings and click **Save**.

Current releases are ad-hoc signed. If macOS blocks the first launch, use
**System Settings → Privacy & Security → Open Anyway** for AimDrop.
See [distribution details](docs/distribution.md) for checksums, signing and release builds.

## Receive your first transfer

1. On your iPhone, select files and open **Share → AirDrop → AimDrop**.
2. Enter the PIN shown on your Mac when pairing for the first time.
3. Follow the transfer in the progress panel.
4. Choose a destination and click **Save here**.

If you cancel the folder picker, the files stay in AimDrop's inbox. Use
**Save Files…** from the menu for the latest unsaved batch, or the received-files
notification. After saving, the completion panel offers **Show in Finder** and **Open**.

Changing the receiver name or avatar requires a new PIN. After pairing,
**close and reopen AirDrop on your iPhone** to refresh the displayed name and image.
Ordinary application restarts preserve pairing.

## Languages

AimDrop supports English, Polish, German, French, Spanish, Italian, Portuguese,
Dutch, Swedish, Czech, Ukrainian, Japanese, Korean, Simplified Chinese, and
Traditional Chinese.

**System default** follows the first supported language in your macOS preferences,
with English as the fallback. A manual choice in Settings takes effect after **Save**.
Receiver names and file names are preserved exactly as entered or received.

## Updates

AimDrop checks the latest stable release in this repository every 24 hours,
including across application restarts. Select **Check for Updates…** in the menu
or Settings to check immediately. A newer version produces a notification with
a **Download** button that opens its GitHub download.

Outbound firewalls such as LuLu must allow AimDrop to reach `api.github.com`
for update checks.

Transfers stay local. Update checks contact GitHub; files are never uploaded to
GitHub or relayed through a cloud service.

## Build from source

Use an Apple Silicon Mac with macOS 26, Xcode Command Line Tools, and Python 3.9+.
Quit an existing AimDrop instance before running a development build.

```sh
git clone https://github.com/emiterkamieni/AimDrop.git
cd AimDrop
python3 scripts/build.py --output .build/development/AimDrop.app
open .build/development/AimDrop.app
```

Create a portable release with the pinned, bundled Python runtime:

```sh
python3 scripts/package.py
```

The packager verifies the runtime download, includes its licenses, signs the
bundle, and checks the extracted archive from a different location.
See [the release guide](docs/distribution.md).

### Checks

```sh
python3 -B -m unittest discover -s tests
python3 scripts/check-swift.py --app .build/development/AimDrop.app
python3 scripts/smoke.py --app .build/development/AimDrop.app

# Native PIN / PairVerify / HTTP3 integration with isolated test state
python3 scripts/research/build-pairing-prototypes.py
python3 scripts/native-smoke.py --app .build/development/AimDrop.app
```

The Swift UI checks need a logged-in macOS desktop session.

## Project layout

| Directory | Purpose |
| --- | --- |
| `Sources/` | AppKit interface, settings, localization, notifications, and updates |
| `NativeReceiver/` | Headless native AirDrop transport entry point |
| `receiver/` | Python worker, persistent inbox, archive handling, and saving |
| `Resources/Localizations/` | Complete language catalogs shared by the app and worker |
| `scripts/` | Build, packaging, artwork generation, and integration tools |
| `scripts/research/` | Shared native protocol implementation and interoperability probes |
| `tests/` | Model, UI, localization, update, and receiver checks |
| `docs/` | Artwork, architecture, translation and distribution documentation |
| `docs/research/` | Historical implementation and device-test notes |

Build products and caches are ignored by Git. Application data is stored in
`~/Library/Application Support/AirFrajer/`; that historical directory and bundle
identifier are retained to preserve existing inboxes and pairing state.

## License

[GPL-3.0-only](LICENSE). Research sources, artwork attribution and bundled-runtime
notices are documented in [THIRD_PARTY.md](THIRD_PARTY.md).
