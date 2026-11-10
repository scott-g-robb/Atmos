#!/bin/zsh
# Developer ID signing, notarization and manual release publishing. The app updater consumes these GitHub release assets.
set -euo pipefail
cd "$(dirname "$0")"
version=${1:?usage: ./release.sh <version> [notes]}
notes=${2:-"Aeolian $version"}
repository=${RELEASE_REPOSITORY:-scott-g-robb/Aeolian}
[[ "$repository" != "mbezruchko/"* ]] || { echo "Set RELEASE_REPOSITORY to your own Aeolian repository." >&2; exit 1; }
profile=${NOTARY_PROFILE:-atmos}
export IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}
[[ "$IDENTITY" == "Developer ID Application:"* ]] || { echo "A Developer ID Application identity is required for public releases." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash changes first." >&2; exit 1; }
current=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ "$current" != "$version" ]]; then
    number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $((number+1))" Resources/Info.plist
    python3 - "$version" <<'PYVERSION'
import sys
from pathlib import Path
for name in ('weather-core/Cargo.toml', 'weather-core/Cargo.lock'):
    path = Path(name)
    import re
    path.write_text(re.sub(r'(?m)^version = "[^"]+"', f'version = "{sys.argv[1]}"', path.read_text(), count=1))
PYVERSION
    git add Resources/Info.plist weather-core/Cargo.toml weather-core/Cargo.lock
    git commit -m "chore: release v$version"
fi
./test.sh
./build.sh
NOTARY_PROFILE="$profile" ./scripts/notarize-release.sh
git push -q origin HEAD
gh release create "v$version" dist/Aeolian.dmg dist/Aeolian.dmg.sha256 \
    --repo "$repository" --target "$(git rev-parse HEAD)" --title "Aeolian $version" --notes "$notes"
