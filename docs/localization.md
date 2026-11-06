# Localization

Catalogs are UTF-8 JSON objects in `Resources/Localizations/`. The Swift app and
Python worker use the same English source keys. All supported catalogs contain
the complete key set, including error messages, accessibility text and notifications.

English and Polish are also provided at their source call sites. Regenerate their
catalogs after changing interface copy:

```sh
python3 -B tests/localization_keys.py en --write
python3 -B tests/localization_keys.py pl --write
```

Translate added keys in every other catalog. Keep `AimDrop`, `AirDrop`, `GitHub`
and `macOS` as product names. Use concise native interface terminology.

## Formatting

Preserve printf placeholders exactly, including type and order:

- `%@`: Swift string
- `%ld` / `%d`: Swift integer
- `%s`: Python string or number

Keep newlines and meaningful leading/trailing spaces. The catalog tests check
coverage, nonempty values and format signatures to prevent runtime formatting errors.

Plural entries use `@files`, `@folders`, `@photos`, `@videos` or `@progress.files`,
followed by `.one`, `.few`, `.many`, `.other`. Include every form, repeating a
suitable form where the language does not use that category. Progress has two
`%ld` arguments: completed count, then total; the total selects the plural category.

`Sources/Localization.swift` defines the supported languages, native picker names,
system-language resolution, Chinese scripts and plural rules. `receiver/localization.py`
contains the corresponding worker language codes. After adding a language, update
these lists and `CFBundleLocalizations` in `scripts/build.py`.

```sh
python3 -B -m unittest tests.test_catalogs tests.test_localization
```

`SettingsLanguageChecks.swift` also renders the complete settings window in every
language. Inspect `.build/previews/` when changing translated control labels.
