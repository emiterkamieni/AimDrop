"""Process-local language selection and shared, English-source-key JSON catalogs.

Catalogs are flat {source: translation} objects. Swift printf placeholders (%@,
%ld) and Python placeholders (%s) must retain their types/counts in translations.
Missing entries fall back to the paired Polish text for pl, otherwise English.
"""
from dataclasses import dataclass
import errno
import json
from pathlib import Path
import threading

LANGUAGES = ("en", "pl", "de", "fr", "es", "it", "pt", "nl", "sv", "cs", "uk", "ja", "ko", "zh-Hans", "zh-Hant")
_lock = threading.RLock()
_language = "en"
_catalogs = {}


def configure(language):
    global _language
    if not isinstance(language, str) or language not in LANGUAGES:
        raise ValueError(message("Unsupported application language.", "Nieobsługiwany język aplikacji."))
    with _lock:
        _language = language


def language_code():
    with _lock:
        return _language


def _catalog_directories():
    root = Path(__file__).resolve().parent.parent
    # The worker lives in Contents/Resources/receiver in a signed app bundle.
    if root.name == "Resources" and root.parent.name == "Contents":
        return (root / "Localizations",)
    return (root / "Resources" / "Localizations", root / "Localizations")


def _catalog(language):
    with _lock:
        if language not in _catalogs:
            table = {}
            for directory in _catalog_directories():
                try:
                    value = json.loads((directory / (language + ".json")).read_text(encoding="utf-8"))
                    if isinstance(value, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in value.items()):
                        table = value
                        break
                except (OSError, ValueError):
                    pass
            _catalogs[language] = table
        return _catalogs[language]


def text(english, polish):
    language = language_code()
    return _catalog(language).get(english, polish if language == "pl" else english)


@dataclass(frozen=True)
class Message:
    english: str
    polish: str
    arguments: tuple = ()

    def __str__(self):
        template = text(self.english, self.polish)
        if not self.arguments:
            return template
        arguments = tuple(error_message(arg) if isinstance(arg, BaseException) else arg for arg in self.arguments)
        return template % arguments


def message(english, polish, *arguments):
    # Keep authored errors lazy: even an exception created before a live switch
    # is rendered in the current language when the worker emits it to the UI.
    return Message(english, polish, arguments)


def error_message(error):
    if len(error.args) == 1 and isinstance(error.args[0], Message):
        return str(error.args[0])
    if isinstance(error, OSError):
        descriptions = {
            errno.EACCES: ("Permission to access the file or folder was denied.", "Brak uprawnień do pliku lub folderu."),
            errno.EPERM: ("Permission to access the file or folder was denied.", "Brak uprawnień do pliku lub folderu."),
            errno.ENOENT: ("The file or folder no longer exists.", "Plik lub folder już nie istnieje."),
            errno.ENOSPC: ("There is not enough space on the disk.", "Na dysku jest za mało miejsca."),
            errno.EROFS: ("The selected disk is read-only.", "Wybrany dysk jest tylko do odczytu."),
            errno.EIO: ("The disk could not read or write the data.", "Nie można odczytać lub zapisać danych na dysku."),
            errno.ENOTDIR: ("The selected location is not a folder.", "Wybrane miejsce nie jest folderem."),
            errno.EEXIST: ("A file or folder already exists at this location.", "W tym miejscu istnieje już plik lub folder."),
            errno.ELOOP: ("The path contains an unsupported symbolic link.", "Ścieżka zawiera nieobsługiwane dowiązanie symboliczne."),
            errno.ENAMETOOLONG: ("The file or folder name is too long.", "Nazwa pliku lub folderu jest za długa."),
            errno.ETIMEDOUT: ("The connection timed out.", "Upłynął czas oczekiwania na połączenie."),
            errno.ECONNRESET: ("The connection was interrupted.", "Połączenie zostało przerwane."),
            errno.EPIPE: ("The connection was interrupted.", "Połączenie zostało przerwane."),
        }
        if isinstance(error, TimeoutError):
            result = text("The connection timed out.", "Upłynął czas oczekiwania na połączenie.")
        else:
            result = text(*descriptions.get(error.errno, (
                "The file, disk or connection is unavailable.", "Plik, dysk lub połączenie jest niedostępne.")))
        if error.filename:
            result += " " + str(error.filename)
        return result
    return text("An unexpected error occurred. See the AimDrop log for details.", "Wystąpił nieoczekiwany błąd. Szczegóły znajdziesz w dzienniku AimDrop.")
