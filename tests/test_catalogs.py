import json
from pathlib import Path
import re
import unittest

from receiver.localization import LANGUAGES
from tests.localization_keys import catalogs


ROOT = Path(__file__).resolve().parents[1] / "Resources" / "Localizations"
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?(?:hh|ll|h|l|z|t|j)?[@diuoxXfFeEgGcs%]")


class CatalogTests(unittest.TestCase):
    def test_source_catalogs_match_user_facing_code(self):
        for language, expected in catalogs().items():
            with self.subTest(language=language):
                self.assertEqual(json.loads((ROOT / (language + ".json")).read_text()), expected)

    def test_every_language_is_complete_and_preserves_format_arguments(self):
        source = catalogs()["en"]
        for language in LANGUAGES:
            with self.subTest(language=language):
                translated = json.loads((ROOT / (language + ".json")).read_text())
                self.assertEqual(set(translated), set(source))
                for key, original in source.items():
                    with self.subTest(key=key):
                        value = translated[key]
                        self.assertIsInstance(value, str)
                        self.assertTrue(value.strip())
                        self.assertEqual(PLACEHOLDER.findall(value), PLACEHOLDER.findall(original))
                        self.assertEqual(value.count("\n"), original.count("\n"))


if __name__ == "__main__":
    unittest.main()
