# In-app update verification — 2026-11-07

The implementation uses Sparkle 2.10.1 with an ad-hoc host app, the original
signed Sparkle framework/helpers, and separate Ed25519 archive/feed signatures.
No Developer ID certificate or notarization was used for these experiments.

## Observed results on macOS 26 / Apple Silicon

- A full portable application was replaced and relaunched at the exact running
  path under `dist/update-experiment`. A second copy was left unchanged.
- The final successful experiment updated build `1794086056` to `1794086057`,
  including differently compiled and signed native receiver executables.
- The real `prepare_update` → worker/native drain → `shutdown_complete` → clean
  process exit barrier ran before Sparkle was allowed to install.
- A ready inbox receipt and its bytes survived. Native pairing identity bytes
  remained unchanged. The receiver reached ready after relaunch.
- Login registration was explicitly enabled before updating. `SMAppService`
  status was `1` (enabled) both before and after. The test registration was
  disabled on cleanup. Disabled/unregistered status was also preserved in the
  preceding experiment.
- Flipping one byte in the signed ZIP caused rejection before installation.
  Sparkle reported outer error 4005 with underlying validation error 3002.
  The running app, identity and second copy remained unchanged. AimDrop now
  identifies this nested validation error in its localized message.
- The focused native HTTP3 integration passed receipt-byte checks before drain,
  after canceling drain, and during an already-accepted transfer. It confirmed
  the sender's response, the final clean-shutdown acknowledgement and unchanged
  pairing identity.
- Swift checks exercised install consent, resumed installation, cancellation
  while extracting/waiting, stale callbacks, shutdown recheck refusal, settings
  registration failure, an actual open folder picker and 15-language layout.

The private-API research client's separate fresh-QUIC-connection-per-request
fixture also produced intermittent handshake timeouts before `/Ask` during
diagnostics. Old/rebuilt helper variants and the final focused three-transfer
run were compared; the final focused run passed. This fixture is not a substitute
for an iPhone test. Actual launch after logout/login and real-device permissions
across the update have not been verified in this session.

Two drain details found during verification are covered by the implementation:
unclaimed pre-opened HTTP3 streams must not hold the barrier forever, and a
terminal connection failure must release the response's reservation even when
it races the response-send callback. Accepted data and pending successful
response sends remain protected until completion.

The experiment account/key and bundle identifier are separate from production.
Test-only automatic consent, alternate storage, loopback networking and old-code
markers are compile-time fixtures and are absent from normal builds.

## Publishing follow-up

The 0.8.4 release uses build 24 and the same production public key as the local
0.8.3 build 23. It is built with `--archive-only`, preserving the running 0.8.3
bundle for an actual in-app upgrade from the public feed.

Renaming the sensitive signing-key item's label with `SecItemUpdate` was followed
by `errSecInvalidItemRef` (-25304) on private-key reads. Restoring the upstream
label `Private key for signing Sparkle updates` restored successful signing with
the original key. Both production and test labels were restored, and the rename
utility was removed. End users do not encounter this publisher-only dialog.
Release preparation now verifies the archive and feed using only the bundled
public key, without the redundant private-key read previously used to obtain it.
