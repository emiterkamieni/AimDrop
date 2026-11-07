"""Use the bundled Foundation helper; never substitute permanent deletion."""
import json
from pathlib import Path
import subprocess

from .localization import message


class MacTrash:
    def __init__(self, executable):
        self.executable = Path(executable) if executable else None

    def __call__(self, source, lock_fd):
        try:
            if self.executable is None:
                raise OSError("Missing trash helper")
            result = subprocess.run([str(self.executable), str(source), str(lock_fd)],
                                    pass_fds=(lock_fd,), capture_output=True, text=True, timeout=60)
            value = json.loads(result.stdout)
            if result.returncode != 0 or value.get("ok") is not True:
                raise OSError("Trash helper failed")
            return value["path"]
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            raise OSError(message("Could not move the transfer to Trash. The files remain in the inbox.",
                                  "Nie udało się przenieść transferu do Kosza. Pliki pozostają w buforze.")) from error
