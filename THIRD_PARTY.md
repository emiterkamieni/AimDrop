# Protocol research and attribution

AirFolder is an independent experimental receiver, not an Apple product.

The AirDrop wire format and macOS socket configuration were informed by:

- **OpenDrop**, Milan Stute and Alexander Heinrich, GPL-3.0:
  https://github.com/seemoo-lab/opendrop
- **jedbillyb/opendrop**, branch `airdrop-mt7921`, reviewed at
  `787f694b617d48fa31587771a76bb659e8787a56`, GPL-3.0:
  https://github.com/jedbillyb/opendrop
- **airdrop-mt7921**, jedbillyb and contributors (including Alban Peralta):
  https://github.com/jedbillyb/airdrop-mt7921/blob/main/patches/README.md
- Apple's DNS-SD declarations and Darwin socket declarations:
  https://github.com/apple-oss-distributions/mDNSResponder
  https://github.com/apple-oss-distributions/xnu
- OpenDrop's recorded media capability schema and legacy-format comment:
  https://github.com/seemoo-lab/opendrop/blob/6960a97ab8f39b978feb4fc578d1b8735bf28c09/opendrop/server.py#L173-L215
- Reverse-generated PhotosFormats declarations (API names, not bundled framework code):
  https://github.com/nst/iOS-Runtime-Headers/blob/f53e3d01aceb4aab6ec2c37338d2df992d917536/PrivateFrameworks/PhotosFormats.framework/PFMediaCapabilities.h
- Apple's description of HEIF/HEVC conversion when sharing:
  https://support.apple.com/en-us/116944
- Independent AirDrop protocol description, including ReceiverModelName and receiver icons:
  https://github.com/t4t5/owly/blob/main/docs/SPEC.md#63-post-discover
- Reverse-engineered Apple BLE message layouts (AirDrop 0x05 and Proximity Pairing 0x07):
  https://github.com/furiousMAC/continuity/blob/master/messages/airdrop.md
  https://github.com/furiousMAC/continuity/blob/master/messages/proximity_pairing.md

In particular, the iOS 26 work documents chunked metadata requests, dvzip blocks,
TransferID correlation and the upload end-of-stream handshake. AirFolder has its
own consent coordinator, streaming archive reader and native AppKit interface.
It does not include upstream's automatic acceptance or partial-file salvage.

AirFolder's source is released under GPL-3.0-only. The full license is in LICENSE.
Runtime dependencies are Python's standard library and system macOS frameworks.
The local build records the Python executable used to build it in Info.plist;
Python itself is not bundled or redistributed by this prototype.

The local build optionally queries the installed PhotosFormats framework for
media capabilities. Only its Version, Codecs and ContainerFormats tables are
included in the app. On the development Mac, Apple's own capability parser
reported HEVC and HEIF support for this filtered payload identically to the
full native payload; its legacy profile reported neither. This is not proof
that a particular iPhone transfer skips all preparation or conversion.

The AirFolder mark in docs/airfolder_znak.svg was supplied by the user. The icon
renderer preserves its geometry and adds the app's blue/turquoise background.
