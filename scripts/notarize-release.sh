#!/bin/zsh
# Prepare a trusted, stapled local release; never commits, pushes or publishes.
set -euo pipefail
cd "$(dirname "$0")/.."
profile=${NOTARY_PROFILE:-atmos}
app="$PWD/build/Aeolian.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
identity=$(codesign -dv --verbose=2 "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p')
[[ -n "$identity" ]] || { echo 'Developer ID Application signing is required.' >&2; exit 1; }
codesign --verify --deep --strict --all-architectures "$app"
python3 scripts/verify-distribution-signing.py "$app"
# Fail before replacing release files if the account is not configured.
xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null
evidence="$PWD/build/verification/notary-$version-$number"
mkdir -p "$evidence" dist
archive="$evidence/Aeolian.zip"
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait --output-format json > "$evidence/app-submission.json"
python3 - "$evidence/app-submission.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('App notarization was not accepted. See '+sys.argv[1])
print('App notarization accepted.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
SKIP_BUILD=1 ./make-installer.sh
image="$PWD/dist/Aeolian-$version.dmg"
codesign --force --timestamp --sign "$identity" "$image"
xcrun notarytool submit "$image" --keychain-profile "$profile" --wait --output-format json > "$evidence/dmg-submission.json"
python3 - "$evidence/dmg-submission.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Installer notarization was not accepted. See '+sys.argv[1])
print('Installer notarization accepted.')
PY
xcrun stapler staple "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
shasum -a 256 "dist/Aeolian-$version.dmg" > "dist/Aeolian-$version.dmg.sha256"
shasum -a 256 dist/Aeolian.dmg > dist/Aeolian.dmg.sha256
echo "Notarized installer ready: $image"
