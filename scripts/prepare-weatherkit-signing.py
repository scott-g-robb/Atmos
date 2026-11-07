#!/usr/bin/env python3
"""Validate public signing metadata without reading or exporting private keys."""
from pathlib import Path
import datetime,plistlib,subprocess,sys
profile=Path(sys.argv[1]).expanduser().resolve()
bundle=sys.argv[2]
identity=sys.argv[3]
document=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(profile)]))
e=document['Entitlements']
def require(condition,message):
 if not condition:raise SystemExit(message)
require(any(p in ('OSX','macOS') for p in document.get('Platform',[])),'WeatherKit needs a macOS profile.')
require(document['ExpirationDate']>datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),'The WeatherKit profile has expired.')
require(e.get('com.apple.application-identifier')==document['TeamIdentifier'][0]+'.'+bundle,'WeatherKit profile bundle identifier mismatch.')
require(e.get('com.apple.developer.weatherkit') is True,'The profile does not authorize native WeatherKit.')
if identity.startswith('Developer ID Application:'):
 require(document.get('ProvisionsAllDevices') is True and not e.get('get-task-allow',False),'Public WeatherKit builds need an all-device Developer ID distribution profile.')
pem=subprocess.check_output(['security','find-certificate','-c',identity,'-p'])
certificate=subprocess.check_output(['/usr/bin/openssl','x509','-outform','DER'],input=pem)
require(certificate in document['DeveloperCertificates'],'The signing certificate is not authorized by the WeatherKit profile.')
folder=Path.home()/'Library/Developer/Xcode/UserData/Provisioning Profiles'
folder.mkdir(parents=True,exist_ok=True)
(folder/(document['UUID']+'.provisionprofile')).write_bytes(profile.read_bytes())
Path('build/weatherkit-profile.plist').write_bytes(plistlib.dumps(document))
print('Validated native macOS WeatherKit authorization and matching signing certificate.')
