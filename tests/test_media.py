import json
from pathlib import Path
import tempfile
import unittest

from receiver.media import LEGACY_CAPABILITIES, load_capabilities


class MediaCapabilityTests(unittest.TestCase):
    def test_native_codec_tables_survive_without_claiming_photos_asset_support(self):
        native = {
            "Version": 3,
            "Codecs": {"hvc1": {"Profiles": {"VTSupportedProfiles": [1, 2, 3, 4]}}},
            "ContainerFormats": {"public.heif-standard": {"HeifSubtypes": ["public.heic", "public.heif"]}},
            "Vendor": {"com.apple": {"LivePhotoFormatVersion": "1"}},
            "SupportsAdjustmentBaseResources": True,
        }
        with tempfile.TemporaryDirectory(prefix="airfrajer-media-") as name:
            path = Path(name) / "media.json"
            path.write_text(json.dumps(native))
            media = json.loads(load_capabilities(path))
        self.assertEqual(media, {key: native[key] for key in ("Version", "Codecs", "ContainerFormats")})

    def test_unavailable_or_invalid_profile_falls_back_without_breaking_receiver(self):
        with tempfile.TemporaryDirectory(prefix="airfrajer-media-") as name:
            path = Path(name) / "media.json"
            self.assertEqual(load_capabilities(path), LEGACY_CAPABILITIES)
            for value in (b"broken", b"[]", b'{"Version":true}', b'{"Version":0}',
                          b'{"Version":3,"Codecs":[]}', b"x" * 65537):
                with self.subTest(value=value[:60]):
                    path.write_bytes(value)
                    self.assertEqual(load_capabilities(path), LEGACY_CAPABILITIES)
