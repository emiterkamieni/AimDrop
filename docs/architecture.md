# Architecture

AimDrop is a native AppKit menu-bar application. It starts a supervised Python
worker, which owns the persistent inbox and starts the headless Swift receiver.

```text
AppKit UI ── JSON over pipes ── Python worker ── JSON over pipes ── native receiver
                                   ▲                                  │
                                   └──── loopback HTTPS ◀──── HTTP3 ────┘
```

The native receiver handles PIN enrollment, remembered peer identities,
PairVerify and AirDrop's encrypted endpoint negotiation. Shared implementation
files live in `scripts/research/` and are compiled into `AimDropReceiver` with
module name `rapportd`, which is part of the wire contract. The research folder
therefore contains production sources as well as standalone protocol probes.

The Python worker validates and unpacks transfers into the app-owned inbox.
Only complete receipts are offered for saving. Saving copies files to a staging
directory on the destination volume, then publishes each item without overwriting
an existing name. Canceling or a failed save retains the ready inbox batch.

AppKit owns the file pickers and all windows on the main thread. Pipe readers,
image decoding and network work run independently. The latest-received index
keeps the menu's Save Files action tied to the newest transfer after a restart.

## Presentation and language

`AimDrop.icns` is the macOS application icon. `AimDropAvatar.png` is a separate,
flat circular contact image, generated from the same SVG without the icon tile.
Both sides canonicalize avatars with the same image code before fingerprinting.

`AppPreferences.language` defaults to the system selection when reading older
preferences. `L10n` selects a catalog and broadcasts changes to existing views.
The worker accepts a live `set_language` command; changing UI language does not
modify the receiver's name, image or pairing identity.

## Updates

`UpdateChecker` reads the repository's latest stable GitHub release. The cadence
and last notified version are persisted. Manual and automatic requests coalesce;
only newer stable semantic versions produce an update result. Download URLs are
restricted to release URLs in this repository. The notification center remains
shared with transfer reminders so both sets of actions work together.

The new-version notification preference defaults to enabled for existing and new
installations. It only controls automatic update notifications; manual checks and
the 24-hour scheduler remain active. Disabling it clears update notifications
without removing transfer reminders, and invalidates late delivery acknowledgements.

## Stable storage

The bundle identifier, historical Application Support directory, preference key
and avatar fingerprint namespace remain stable across product renames. A real
receiver-profile change rotates the complete pairing identity once; unchanged
profiles survive restarts. Historical implementation and device-test details are
under `docs/research/`.
