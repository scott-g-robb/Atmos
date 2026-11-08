#!/bin/zsh
# Universal macOS build. No persistent helpers or third-party runtime frameworks.
set -euo pipefail
cd "$(dirname "$0")"
# Keep a configured local signing identity stable across rebuilds (including Keychain access).
if [[ -z "${IDENTITY:-}" && -f build/signing-identity.txt ]]; then
    IDENTITY="$(< build/signing-identity.txt)"
fi
WEATHERKIT_PROFILE=${WEATHERKIT_PROFILE:-}
if [[ -z "$WEATHERKIT_PROFILE" && -f build/weatherkit-profile-path.txt ]]; then
    WEATHERKIT_PROFILE="$(< build/weatherkit-profile-path.txt)"
fi
if [[ -n "$WEATHERKIT_PROFILE" && "${BUILD_WITH_XCODE:-1}" == 1 ]]; then
    mkdir -p build
    [[ -n "${IDENTITY:-}" ]] || { echo "Native WeatherKit requires a signing identity." >&2; exit 1; }
    python3 scripts/prepare-weatherkit-signing.py "$WEATHERKIT_PROFILE" "${BUNDLE_IDENTIFIER:-dev.grobb.Atmos}" "$IDENTITY"
    python3 scripts/generate-xcode-project.py
    team=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' build/weatherkit-profile.plist)
    profile_name=$(/usr/libexec/PlistBuddy -c 'Print :Name' build/weatherkit-profile.plist)
    xcodebuild -quiet -project Atmos.xcodeproj -scheme Atmos -configuration Release \
        -derivedDataPath .build/xcode -destination 'generic/platform=macOS' \
        'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$team" \
        PROVISIONING_PROFILE_SPECIFIER="$profile_name" \
        PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-dev.grobb.Atmos}" build
    rm -rf build/Atmos.app
    ditto .build/xcode/Build/Products/Release/Atmos.app build/Atmos.app
    codesign --verify --deep --strict build/Atmos.app
    lipo build/Atmos.app/Contents/MacOS/Atmos -verify_arch arm64
    lipo build/Atmos.app/Contents/MacOS/Atmos -verify_arch x86_64
    print -r -- "$IDENTITY" > build/signing-identity.txt
    print "Built build/Atmos.app with Xcode and native WeatherKit"
    exit 0
fi
./scripts/build-weather-core.sh
# Keep the universal release separate from host-architecture test products.
flags=(--scratch-path .build/universal -c release --arch arm64 --arch x86_64)
swift build "${flags[@]}"
products="$(swift build "${flags[@]}" --show-bin-path)"
app=build/Atmos.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
vtool -set-build-version macos "$minimum" "$(xcrun --sdk macosx --show-sdk-version)" -replace \
    -output "$app/Contents/MacOS/Atmos" "$products/Atmos"
lipo "$app/Contents/MacOS/Atmos" -verify_arch arm64
lipo "$app/Contents/MacOS/Atmos" -verify_arch x86_64
cp Resources/Info.plist "$app/Contents/"
# Native icon assets prevent macOS from nesting a legacy bitmap inside a second tile.
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" \
    --platform macosx --minimum-deployment-target "$minimum" --app-icon AppIcon \
    --output-partial-info-plist build/icon-info.plist --output-format human-readable-text
swift scripts/build-icons.swift Resources/AppIcon.icon/Assets/Weather.png build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp NOTICE.md "$app/Contents/Resources/NOTICE.md"
cp Resources/IntroAudio.mp3 "$app/Contents/Resources/IntroAudio.mp3"
if [[ -n "${BUNDLE_IDENTIFIER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$app/Contents/Info.plist"
fi
entitlements=Resources/Atmos.entitlements
if [[ -n "${WEATHERKIT_PROFILE:-}" ]]; then
    [[ -n "${IDENTITY:-}" ]] || { echo "WeatherKit needs an Apple signing identity." >&2; exit 1; }
    cp "$WEATHERKIT_PROFILE" "$app/Contents/embedded.provisionprofile"
    entitlements=build/WeatherKit.entitlements
    security cms -D -i "$WEATHERKIT_PROFILE" > build/weatherkit-profile.plist
    python3 - <<'PY'
import plistlib
from pathlib import Path
document=plistlib.loads(Path('build/weatherkit-profile.plist').read_bytes())
if not any(p in ('OSX','macOS') for p in document.get('Platform', [])):
    raise SystemExit('WeatherKit requires a macOS provisioning profile, not an iOS profile.')
profile=document['Entitlements']
app=plistlib.loads(Path('build/Atmos.app/Contents/Info.plist').read_bytes())['CFBundleIdentifier']
identifier=profile.get('com.apple.application-identifier','')
if not identifier.endswith('.'+app):
    raise SystemExit('The WeatherKit profile must match the app bundle identifier. Set BUNDLE_IDENTIFIER to the registered App ID.')
if not profile.get('com.apple.developer.weatherkit'):
    raise SystemExit('The provisioning profile does not enable WeatherKit.')
base=plistlib.loads(Path('Resources/Atmos.entitlements').read_bytes())
for key in ('com.apple.application-identifier','com.apple.developer.team-identifier','com.apple.developer.weatherkit'):
    if key in profile: base[key]=profile[key]
Path('build/WeatherKit.entitlements').write_bytes(plistlib.dumps(base))
PY
fi
if [[ -n "${IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" --entitlements "$entitlements" "$app"
else
    codesign --force --sign - --entitlements "$entitlements" "$app"
fi
codesign --verify --deep --strict "$app"
if [[ -n "${IDENTITY:-}" ]]; then print -r -- "$IDENTITY" > build/signing-identity.txt; fi
echo "Built $app"
