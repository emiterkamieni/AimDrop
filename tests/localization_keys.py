"""Catalog extractor: python3 -B tests/localization_keys.py [en|pl] [--write].

Outputs a flat JSON object ready for Resources/Localizations/<code>.json.
Regular keys are English source strings. Preserve printf placeholders exactly:
Swift %@ is a string, %ld is an integer; Python %s is a string/number. Never
convert %s to %@, or vice versa. Swift can reorder arguments with %2$@ etc.;
Python messages retain their original placeholder order.

Plural keys: @files, @photos, @videos, @folders, @progress.files followed by
.one/.few/.many/.other. Item forms take ONE %ld (count); progress forms take
TWO %ld (completed, total), and the TOTAL chooses the category. Catalogs should
provide all four forms (duplicate the appropriate other form where unused).
pl/uk use one/few/many, cs one/few/other; ja/ko/zh-Hans/zh-Hant use only other.
fr/pt use one for 0/1; other supported languages use one for 1, other otherwise.
Missing categories fall back to .other, then the built-in English/Polish text.

This scans Swift and Python user-facing strings. --write regenerates only the
English and Polish source catalogs; translated catalogs are edited separately.
"""
import ast
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SWIFT_PAIR = re.compile(r'(?:L10n\.(?:text|format)|setReceiverStatus)\(\s*("(?:[^"\\]|\\.)*")\s*,\s*("(?:[^"\\]|\\.)*")')
PLURALS = {
    "files": (("%ld file", "%ld files", "%ld files", "%ld files"), ("%ld plik", "%ld pliki", "%ld plików", "%ld plików")),
    "photos": (("%ld photo", "%ld photos", "%ld photos", "%ld photos"), ("%ld zdjęcie", "%ld zdjęcia", "%ld zdjęć", "%ld zdjęć")),
    "videos": (("%ld video", "%ld videos", "%ld videos", "%ld videos"), ("%ld wideo",) * 4),
    "folders": (("%ld folder", "%ld folders", "%ld folders", "%ld folders"), ("%ld folder", "%ld foldery", "%ld folderów", "%ld folderów")),
    "progress.files": (("%ld of %ld file", "%ld of %ld files", "%ld of %ld files", "%ld of %ld files"),
                       ("%ld z %ld pliku", "%ld z %ld plików", "%ld z %ld plików", "%ld z %ld plików")),
}


def catalogs():
    english, polish = {}, {}

    def add(en, pl):
        english[en] = en
        if en in polish and polish[en] != pl:
            raise ValueError("Conflicting Polish translations for " + repr(en))
        polish[en] = pl

    add("AimDrop receives the files you choose to share with AirDrop from your iPhone.",
        "AimDrop odbiera wybrane przez Ciebie pliki AirDrop z iPhone’a.")

    for path in sorted((ROOT / "Sources").glob("*.swift")):
        for match in SWIFT_PAIR.finditer(path.read_text()):
            add(*(json.loads(value) for value in match.groups()))
    for path in sorted((ROOT / "receiver").glob("*.py")):
        for node in ast.walk(ast.parse(path.read_text())):
            values = None
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ("text", "message"):
                values = node.args[:2]
            elif path.name == "localization.py" and isinstance(node, ast.Tuple) and len(node.elts) == 2:
                values = node.elts
            if values and len(values) == 2 and all(isinstance(value, ast.Constant) and isinstance(value.value, str) for value in values):
                add(*(value.value for value in values))
    for name, forms in PLURALS.items():
        for table, translations in zip((english, polish), forms):
            table.update(("@" + name + "." + category, value)
                         for category, value in zip(("one", "few", "many", "other"), translations))
    return {"en": english, "pl": polish}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("language", choices=("en", "pl"), nargs="?", default="en")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    value = json.dumps(catalogs()[args.language], ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.write:
        target = ROOT / "Resources/Localizations" / (args.language + ".json")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value, encoding="utf-8")
        print("Generated " + str(target.relative_to(ROOT)))
    else:
        print(value, end="")
