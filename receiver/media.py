"""AirDrop media capabilities captured from the build host's PhotosFormats.

The app is a local build. Do not replace this with invented codec levels or
asset-bundle flags: this describes the actual Mac, not an accept-all switch.
"""
import json
import logging

LOG = logging.getLogger(__name__)
LEGACY_CAPABILITIES = b'{"Version":1}'


def load_capabilities(path):
    try:
        data = path.read_bytes()
        if len(data) > 65536:
            raise ValueError("Oversized capabilities")
        value = json.loads(data)
        if not isinstance(value, dict) or type(value.get("Version")) is not int or value["Version"] < 1:
            raise ValueError("Invalid capabilities")
        media = {"Version": value["Version"]}
        for key in ("Codecs", "ContainerFormats"):
            if key in value:
                if not isinstance(value[key], dict):
                    raise ValueError("Invalid media formats")
                media[key] = value[key]
        encoded = json.dumps(media, separators=(",", ":")).encode("utf-8")
        LOG.info("Media capabilities: version=%d HEVC=%s HEIF=%s", media["Version"],
                 "hvc1" in media.get("Codecs", {}), "public.heif-standard" in media.get("ContainerFormats", {}))
        return encoded
    except (OSError, ValueError):
        LOG.info("Native media capabilities unavailable; using legacy profile")
        return LEGACY_CAPABILITIES
