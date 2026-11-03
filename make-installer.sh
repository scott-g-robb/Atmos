#!/bin/zsh
# Builds a universal, locally signed app and a drag-to-install disk image. No publishing or notarization.
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then ./build.sh; fi
mkdir -p dist
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Atmos.app/Contents/Info.plist)
image="dist/Atmos-$version.dmg"
tools=.build/dmg-tools
if [[ ! -x "$tools/bin/dmgbuild" ]]; then
    python3 -m venv "$tools"
    "$tools/bin/python" -m pip install --quiet -r scripts/dmg-requirements.txt
fi
swift scripts/make-dmg-background.swift build/dmg-artwork
tiffutil -cathidpicheck build/dmg-artwork/background.png build/dmg-artwork/background@2x.png \
    -out build/dmg-artwork/background.tiff >/dev/null
rm -f "$image"
"$tools/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D app="$PWD/build/Atmos.app" -D background="$PWD/build/dmg-artwork/background.tiff" \
    "Atmos $version" "$image"
hdiutil verify "$image"
shasum -a 256 "$image" > "$image.sha256"
rm -f dist/Atmos.dmg
ln -s "$(basename "$image")" dist/Atmos.dmg
shasum -a 256 dist/Atmos.dmg > dist/Atmos.dmg.sha256
echo "Installer ready: $PWD/$image"
