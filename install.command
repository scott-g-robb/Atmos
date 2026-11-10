#!/bin/zsh
# Double-click to install the local build for this user. Does not need administrator access.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -d Aeolian.app ]]; then
    source_app="$PWD/Aeolian.app"
else
    ./build.sh
    source_app="$PWD/build/Aeolian.app"
fi
codesign --verify --deep --strict "$source_app"
# Stop an earlier Aeolian build even if it used a different bundle identifier.
if pgrep -x Aeolian >/dev/null; then
    pids=("${(@f)$(pgrep -x Aeolian)}")
    kill -TERM "${pids[@]}"
    for attempt in {1..30}; do
        if ! pgrep -x Aeolian >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x Aeolian >/dev/null; then
        echo "Quit Aeolian from its menu bar icon, then run this installer again."
        exit 1
    fi
fi
destination="$HOME/Applications"
mkdir -p "$destination"
staged_app=$(mktemp -d "$destination/.atmos-install.XXXXXX")
trap 'rm -rf "$staged_app"' EXIT
ditto "$source_app" "$staged_app/Aeolian.app"
codesign --verify --deep --strict "$staged_app/Aeolian.app"
# Keep the old app until the new copy has passed verification.
if [[ -d "$destination/Aeolian.app" ]]; then
    mv "$destination/Aeolian.app" "$staged_app/Previous Aeolian.app"
fi
if ! mv "$staged_app/Aeolian.app" "$destination/Aeolian.app"; then
    if [[ -d "$staged_app/Previous Aeolian.app" ]]; then
        mv "$staged_app/Previous Aeolian.app" "$destination/Aeolian.app"
    fi
    exit 1
fi
open "$destination/Aeolian.app"
echo "Installed to $destination/Aeolian.app. Look for Aeolian in your menu bar."
