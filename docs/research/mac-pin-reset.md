# macOS PIN dialog reset after successful authentication

## Confirmed cause

The reported Mac-to-Mac attempt passed the PIN handshake. The receiving app
logged `pake_credential_lookup=hit` and `authenticated_identity_sent`, but no
successful peer enrollment. Sender-side system diagnostics then showed:

1. the receiver's temporary identity was accepted;
2. macOS sent its own temporary identities with `shareTemporaryIdentities`;
3. AimDrop returned `rapportd.ProbeError`, code 4 (`invalidArgument`);
4. macOS reported PIN pairing failure and reset its PIN entry dialog.

An isolated, authenticated query to the native pairing actor on the sending
Mac returned two temporary identities. Only their shape was inspected: each
had a 36-byte identifier, 16-byte IRK, 32-byte public key, finite date, and a
**551,006-byte contact image**. No image or key contents were printed or saved.
Passing these identities to an in-memory `PairingStore` reproduced code 4.

The rejected field was the image size. `PairingStore.enroll` had incorrectly
applied `ReceiverAvatar.maximumPNGBytes` (524,288 bytes) to incoming native
contact images. That limit belongs to AimDrop's own outgoing 256×256 avatar.
The receiver's reported outgoing image was only 98,752 bytes. macOS generates
the sender's contact metadata independently of AimDrop's avatar editor.

## Flow and relevant sources

- `scripts/research/airfolder-pairing-prototype.swift:192` — pre-pairing obtains
  PAKE identifiers and displays the PIN.
- `scripts/research/airfolder-pairing-prototype.swift:197` — authenticated
  `pairAndReceiveTemporaryIdentities` returns AimDrop's receiver identity.
- `scripts/research/airfolder-pairing-prototype.swift:203` — authenticated
  `shareTemporaryIdentities` enrolls the sender before closing the PIN panel.
- `scripts/research/pairing-store.swift:114` — validates a batch, constructs
  credential-only peer records, and commits the complete updated store.
- `Sources/ReceiverAvatar.swift:54` — outgoing avatar rendering, PNG validation
  and the 512 KiB limit. This is separate from native sender metadata.

`NWActorSystem` transports the Codable identities over authenticated PAKE/TLS.
The native macOS sender supplies contact metadata alongside credentials.
AimDrop persists identifiers, public keys, IRKs and dates; it does not render
or persist the sender's image. Resizing an unused image after receiving it is
unnecessary. Removing its unrelated size check leaves credential validation,
batch bounds, atomic updates and the persistent store's byte limit in place.

## Regression verification

- A generated 551,006-byte image fixture reproduced the same failure against
  the previous bundled receiver, after successful PIN authentication.
- `--peer-enrollment-check` covers native-sized and 2 MiB synthetic image
  metadata, bounded credential-only state, and atomic rejection of malformed
  identifiers, keys, IRKs, dates and batches.
- `test-persistent-pairing.py` enrolls a peer with the larger image and checks
  restart, PairVerify, encrypted endpoint resolution and native HTTP3.
- `native-smoke.py` sends that fixture through the actual bundled worker and
  helper, then checks a remembered connection without another PIN.

All of these checks passed. After the fix, the same in-memory native identity
shape check accepted both system-provided identities with 551,006-byte images.
The final 0.8.6/build 26 app also passed 134 Python tests, `PairingWindowChecks`,
`UpdateChecks`, the full bundled native smoke test, portable-runtime/signature
verification, and byte-for-byte comparison of the app and its ZIP executables.

Automatic regressions use synthetic metadata and generated keys. The final
physical two-Mac retry is a separate acceptance step. Native integration
checks run sequentially because they exercise shared macOS services.
