#!/bin/zsh
# Build a separate sandboxed Store candidate; never replaces the direct-download app.
set -euo pipefail
cd "$(dirname "$0")/.."
profile=${APP_STORE_PROFILE:-}
if [[ -z "$profile" && -f build/appstore-profile-path.txt ]]; then
    profile="$(< build/appstore-profile-path.txt)"
fi
[[ -n "$profile" && -f "$profile" ]] || { echo 'Set APP_STORE_PROFILE to the macOS App Store WeatherKit profile.' >&2; exit 1; }
identity=${APP_STORE_IDENTITY:-Apple Distribution: SCOTT GRAEME ROBB (8QDD68TVRK)}
installer=${APP_STORE_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer: SCOTT GRAEME ROBB (8QDD68TVRK)}
mkdir -p build/appstore dist
python3 - "$profile" "$identity" <<'PY'
import datetime, plistlib, subprocess, sys
from pathlib import Path
profile=Path(sys.argv[1]).expanduser().resolve()
p=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(profile)]))
e=p['Entitlements']
assert any(x in ('OSX','macOS') for x in p['Platform']), 'A macOS profile is required'
assert not p.get('ProvisionsAllDevices') and not p.get('ProvisionedDevices'), 'Use a Mac App Store distribution profile'
assert p['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Profile expired'
assert e.get('com.apple.application-identifier') == '8QDD68TVRK.dev.grobb.Atmos'
assert e.get('com.apple.developer.weatherkit') is True, 'WeatherKit is required'
assert not e.get('get-task-allow') and not e.get('com.apple.security.get-task-allow')
pem=subprocess.check_output(['security','find-certificate','-c',sys.argv[2],'-p'])
cert=subprocess.check_output(['/usr/bin/openssl','x509','-outform','DER'],input=pem)
assert cert in p['DeveloperCertificates'], 'Profile does not authorize this signing identity'
destination=Path.home()/'Library/Developer/Xcode/UserData/Provisioning Profiles'
destination.mkdir(parents=True,exist_ok=True)
(destination/(p['UUID']+'.provisionprofile')).write_bytes(profile.read_bytes())
ent=plistlib.loads(Path('Resources/AppStore.entitlements').read_bytes())
for key in ('com.apple.application-identifier','com.apple.developer.team-identifier','com.apple.developer.weatherkit'):
    ent[key]=e[key]
Path('build/appstore/release.entitlements').write_bytes(plistlib.dumps(ent))
Path('build/appstore/profile-name.txt').write_text(p['Name'])
options={'method':'app-store-connect','destination':'upload','signingStyle':'manual',
    'teamID':p['TeamIdentifier'][0],'signingCertificate':'Apple Distribution',
    'installerSigningCertificate':'3rd Party Mac Developer Installer: SCOTT GRAEME ROBB (8QDD68TVRK)',
    'provisioningProfiles':{'dev.grobb.Atmos':p['Name']},
    'uploadSymbols':False,'manageAppVersionAndBuildNumber':False}
Path('build/appstore/ExportOptions.plist').write_bytes(plistlib.dumps(options))
print('Validated App Store distribution profile and WeatherKit authorization.')
PY
python3 scripts/generate-xcode-project.py
profile_name="$(< build/appstore/profile-name.txt)"
archive="$PWD/build/appstore/Aeolian.xcarchive"
xcodebuild -quiet -project Aeolian.xcodeproj -scheme Aeolian -configuration AppStore \
    -derivedDataPath .build/appstore -archivePath "$archive" \
    -destination 'generic/platform=macOS' 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=8QDD68TVRK CODE_SIGN_IDENTITY="$identity" \
    CODE_SIGN_ENTITLEMENTS=build/appstore/release.entitlements \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO 'OTHER_CODE_SIGN_FLAGS=--timestamp' \
    PROVISIONING_PROFILE_SPECIFIER="$profile_name" SKIP_INSTALL=NO archive
app="$archive/Products/Applications/Aeolian.app"
python3 - "$app" <<'PY'
import plistlib, subprocess, sys
from pathlib import Path
app=Path(sys.argv[1]);binary=app/'Contents/MacOS/Aeolian'
subprocess.run(['codesign','--verify','--deep','--strict','--all-architectures',str(app)],check=True)
ent=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(app)],stderr=subprocess.DEVNULL))
for key in ('com.apple.security.app-sandbox','com.apple.security.network.client','com.apple.security.personal-information.location','com.apple.developer.weatherkit'):
    assert ent.get(key) is True, key
assert not ent.get('com.apple.security.get-task-allow')
assert set(subprocess.check_output(['lipo','-archs',str(binary)]).decode().split()) == {'arm64','x86_64'}
# App Store processing rejects download quarantine attributes on bundled resources.
attributes=subprocess.check_output(['/usr/bin/xattr','-lr',str(app)])
assert b'com.apple.quarantine:' not in attributes, 'A bundled resource still has a quarantine attribute'
data=binary.read_bytes()
for forbidden in (b'SLSCopyManagedDisplaySpaces', b'SLSRegisterConnectionNotifyProc', b'SLSGetDockRect', b'SLSSetWindowWorkspace', b'SecTranslocateCreateOriginalPathForURL', b'api.github.com/repos/scott-g-robb/Aeolian/releases'):
    assert forbidden not in data, 'Store build contains a direct-release-only API'
assert (app/'Contents/Resources/PrivacyInfo.xcprivacy').is_file()
print('Audited sandbox, both architectures, WeatherKit, privacy manifest and excluded direct-release APIs.')
PY
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
package="$PWD/dist/Aeolian-$version-AppStore.pkg"
productbuild --component "$app" /Applications --sign "$installer" "$package"
pkgutil --check-signature "$package"
echo "App Store upload candidate: $package"
