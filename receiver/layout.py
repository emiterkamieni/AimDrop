"""Map archive source paths to the items selected in AirDrop's Ask manifest.

iOS Photos can send paths rooted at Containers/…/tmp or Media/PhotoData/….
Those are sender-side transport paths, not user-selected folder hierarchies.
Regular selected files land at the destination root; selected folders retain
their own contents, using FileBomPath to locate the actual folder root.
"""
from dataclasses import dataclass
from pathlib import PurePosixPath
import unicodedata
from .localization import message


def name_key(name):
    return unicodedata.normalize("NFC", name).casefold()


@dataclass(frozen=True)
class SelectedItem:
    name: str
    source: tuple
    is_directory: bool


def selections(files):
    result = []
    for item in files:
        name = item["FileName"]
        if not name or name in (".", "..") or any(char in name for char in ("/", "\\", "\x00")):
            raise ValueError(message("Invalid name of the selected item.", "Nieprawidłowa nazwa wybranego elementu."))
        source = item.get("FileBomPath", "")
        if not isinstance(source, str) or "\x00" in source or "\\" in source:
            raise ValueError(message("Invalid transfer source path.", "Nieprawidłowa ścieżka źródłowa przesyłki."))
        parts = tuple(part for part in PurePosixPath(source).parts if part not in ("/", "."))
        if ".." in parts:
            raise ValueError(message("Invalid transfer source path.", "Nieprawidłowa ścieżka źródłowa przesyłki."))
        directory = item.get("FileIsDirectory", item.get("FileType") in ("public.folder", "public.directory"))
        if not isinstance(directory, (bool, int)) or directory not in (False, True):
            raise ValueError(message("Invalid type of the selected item.", "Nieprawidłowy typ wybranego elementu."))
        result.append(SelectedItem(name, parts, bool(directory)))
    return tuple(result)


class SelectionLayout:
    def __init__(self, selected):
        self.used_names = set()
        self.files = any(not item.is_directory for item in selected)
        self.folders = [(item, self._allocate(item.name)) for item in selected if item.is_directory]

    def _allocate(self, name):
        suffix = PurePosixPath(name).suffix
        stem = name[:-len(suffix)] if suffix else name
        for index in range(10000):
            candidate = name if not index else "%s (%s)%s" % (stem, index, suffix)
            key = name_key(candidate)
            if key not in self.used_names:
                self.used_names.add(key)
                return candidate
        raise ValueError(message("Too many items have the same name.", "Zbyt wiele elementów o tej samej nazwie."))

    @staticmethod
    def _folder_match(parts, item):
        # cpio paths can omit the common prefix of absolute sender-side paths.
        source = item.source
        for length in range(min(len(parts), len(source)), 0, -1):
            if parts[:length] == source[-length:]:
                return length, length
        # Older peers can omit FileBomPath. Only unambiguous folder roots qualify.
        positions = [index for index, part in enumerate(parts) if part == item.name]
        if len(positions) == 1:
            return 0, positions[0] + 1
        return None

    def destination(self, parts, is_directory):
        matches = []
        for item, output in self.folders:
            match = self._folder_match(parts, item)
            if match is not None:
                score, consumed = match
                matches.append((score, consumed, output))
        if matches:
            best = max(match[0] for match in matches)
            matches = [match for match in matches if match[0] == best]
            if len(matches) != 1:
                raise ValueError(message("The file cannot be matched unambiguously to the selected folder.", "Nie można jednoznacznie przypisać pliku do wybranego folderu."))
            _, consumed, output = matches[0]
            if not is_directory and len(parts) == consumed:
                raise ValueError(message("An item announced as a folder is a file.", "Element zapowiedziany jako folder jest plikiem."))
            return (output,) + parts[consumed:]
        if is_directory:
            return None  # transport ancestors are not output directories
        if not self.files:
            raise ValueError(message("The file is outside the folders selected for sending.", "Plik znajduje się poza folderami wybranymi do wysłania."))
        # Keep the actual payload extension: Photos may convert HEIC to JPEG.
        # Distinct sources with the same basename remain distinct output files.
        return (self._allocate(parts[-1]),)
