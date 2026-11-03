#!/bin/zsh
# Double-click to install the local build for this user. Does not need administrator access.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -d Atmos.app ]]; then
    source_app="$PWD/Atmos.app"
else
    ./build.sh
    source_app="$PWD/build/Atmos.app"
fi
codesign --verify --deep --strict "$source_app"
# Stop an earlier Atmos build even if it used a different bundle identifier.
if pgrep -x Atmos >/dev/null; then
    pids=("${(@f)$(pgrep -x Atmos)}")
    kill -TERM "${pids[@]}"
    for attempt in {1..30}; do
        if ! pgrep -x Atmos >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x Atmos >/dev/null; then
        echo "Quit Atmos from its menu bar icon, then run this installer again."
        exit 1
    fi
fi
destination="$HOME/Applications"
mkdir -p "$destination"
staged_app=$(mktemp -d "$destination/.atmos-install.XXXXXX")
trap 'rm -rf "$staged_app"' EXIT
ditto "$source_app" "$staged_app/Atmos.app"
codesign --verify --deep --strict "$staged_app/Atmos.app"
# Keep the old app until the new copy has passed verification.
if [[ -d "$destination/Atmos.app" ]]; then
    mv "$destination/Atmos.app" "$staged_app/Previous Atmos.app"
fi
if ! mv "$staged_app/Atmos.app" "$destination/Atmos.app"; then
    if [[ -d "$staged_app/Previous Atmos.app" ]]; then
        mv "$staged_app/Previous Atmos.app" "$destination/Atmos.app"
    fi
    exit 1
fi
open "$destination/Atmos.app"
echo "Installed to $destination/Atmos.app. Look for Atmos in your menu bar."
