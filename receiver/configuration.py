"""Shared validation for receiver settings at startup and over IPC."""
import unicodedata
from .localization import message


def normalized_receiver_name(value):
    if not isinstance(value, str):
        raise ValueError(message("The receiver name must be text.", "Nazwa odbiornika musi być tekstem."))
    for char in value:
        code = ord(char)
        if (code <= 0x1F or 0x7F <= code <= 0x9F
                or 0x2028 <= code <= 0x202E or 0x2066 <= code <= 0x2069
                or 0xD800 <= code <= 0xDFFF):
            raise ValueError(message("The receiver name contains disallowed characters.", "Nazwa odbiornika zawiera niedozwolone znaki."))
    name = unicodedata.normalize("NFC", value.strip(" "))
    if not 1 <= len(name.encode("utf-8")) <= 128:
        raise ValueError(message("The receiver name must contain 1 to 128 UTF-8 bytes.", "Nazwa odbiornika musi mieć od 1 do 128 bajtów UTF-8."))
    return name
