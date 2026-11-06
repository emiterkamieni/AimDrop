#!/bin/zsh
ROOT="${0:A:h}"
if [[ ! -d "$ROOT/dist/AimDrop.app" ]]; then
  python3 "$ROOT/scripts/build.py" || exit $?
fi
exec /usr/bin/open "$ROOT/dist/AimDrop.app"
