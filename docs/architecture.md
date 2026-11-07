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
image decoding and network work run independently. The Unsaved transfers menu
contains every ready batch, ordered by receipt time. Its actions use stable IDs;
terminal events prevent late snapshots from restoring saved or trashed entries.
Busy transfers may be absent from `list_ready()`, so snapshots merge rather than
implicitly deleting active rows. The historical latest-received index remains
readable for compatibility but no longer restricts the menu.

## Inbox retention and Trash

Each receipt stores its receive time, retention start, number of days and absolute
deadline. Changing the default period affects only future receipts. A global
switch pauses automatic cleanup without changing stored deadlines. Legacy
receipts receive a one-time grace period anchored by `.retention-migration.json`.
Incomplete or invalid records are preserved rather than treated as expired.

The worker owns mutations and reserves batches before dispatching save/Trash
jobs. A correlated hold protects destination selection and deletion confirmation;
promotion to a save/Trash reservation is atomic. Cleanup runs on a background
queue every minute and can be woken by the UI after system wake or policy changes.

`NativeInbox/trash.swift` builds `AimDropTrash`, a Foundation-only helper using
the macOS Trash API. A worker journal remains outside the payload directory.
An inherited filesystem lock protects recovery even if the worker exits while
the helper is still moving files. Recovery restores an uncommitted payload or
retires a completed move. Failed Trash operations never fall back to deletion.
Saved/trashed retirement markers survive failed cleanup and are removed only
after the remaining payload has been cleaned. Transfer reminders are reconciled
with the initial ready list after restart.

Bulk deletion snapshots eligible UI IDs before its confirmation. Commands are
bounded to 512 IDs and validated in full before reservations are attempted;
already busy or missing batches are skipped without interrupting active saves.
Normal per-transfer terminal events remain authoritative, including when they
arrive before the bulk acknowledgement.

Hover previews use a delayed, nonactivating panel alongside the file submenu.
ImageIO downsamples images, TXT reads at most 8 KiB, and document/video thumbnails
use Quick Look. Generation tokens and cancellation prevent late results from
reopening a closed preview or replacing a newer file. Menu closure, save/Trash
activity and transfer removal dismiss the panel; previews do not extend retention.

## Presentation and language

App-owned action buttons share `ActionButtonStyle`: a 28-point flexible push
button, 13-point medium text and a 96-point minimum width. The settings window,
inbox menu, avatar crop sheet and completion card use the same metrics.

On the first launch of a new installation, `LoginItemManager` requests launch at
login once. Existing preferences or an existing Application Support directory
identify an upgrade; its OS-managed login choice is preserved. A durable default
marker prevents later launches from reversing an opt-out. Registration errors
are shown in settings and can be retried explicitly there.

`AimDrop.icns` is the macOS application icon. `AimDropAvatar.png` is a separate,
flat circular contact image, generated from the same SVG without the icon tile.
Both sides canonicalize avatars with the same image code before fingerprinting.

`AppPreferences.language` defaults to the system selection when reading older
preferences. `L10n` selects a catalog and broadcasts changes to existing views.
The worker accepts a live `set_language` command; changing UI language does not
modify the receiver's name, image or pairing identity.

## Updates

`UpdateChecker` retains the persistent 24-hour cadence and notification delivery
deduplication (including migration of the previous preference keys). Its probe
calls `SparkleUpdateController`, the single update engine. Sparkle 2.10.1 reads
the signed GitHub Releases appcast, compares increasing `CFBundleVersion` values,
verifies Ed25519 signatures before extraction, and replaces the running bundle.
Sparkle's independent scheduler and automatic downloading are disabled.

`SparkleUpdateController` implements `SPUUserDriver` and `SPUUpdaterDelegate`.
`UpdateWindowController` provides the localized 28-point-button interface.
Only an explicit Update and Restart click grants install consent. A resumed
installation must pass the same restart barrier. Cancellation while extracting
is remembered; at the ready callback it replies `.skip`, not `.dismiss`, which
could otherwise leave an installation pending until quit. No signing secrets
are shipped in the app. The production Keychain account is `AimDrop-Releases`.

`UpdateRestartCoordinator` coordinates two barriers. UI pickers and their saves
must finish and Settings must be resolved, including login registration and
correlated profile/language/retention acknowledgements. The worker's
`prepare_update` closes new admission without canceling accepted offers;
`Inbox` allows only pre-existing hold tokens to continue into saves/Trash.
Periodic retention sweeps stop while queued operations finish. The worker waits
for session, upload, reservation, save-thread and maintenance completion. It then
quiesces the native HTTP3 listener, closes unclaimed idle streams, and waits for
response-send callbacks before reporting idle. `shutdown_when_idle` rechecks the barrier, waits for the helper
to exit, and emits `shutdown_complete`. Both that correlated event and a clean
worker process exit are required before Sparkle receives `.install`.
`applicationShouldTerminate` gates every update-related quit path. Canceling the
preparation sends `cancel_update` and restores admission without changing user
pause state or persisted settings.

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
