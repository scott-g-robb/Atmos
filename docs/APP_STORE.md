# Mac App Store distribution

Aeolian 0.14.4 (76) has been uploaded to App Store Connect and attached to the
macOS version. Apple validated the listing and marked it **Ready for Review**.
The final Submit for Review action remains pending the public privacy page.
The original build 75 was rejected for inherited quarantine
metadata on bundled resources; the build now removes that metadata from its own
newly assembled resources before signing, and audits the complete Store app.

The public app name is Aeolian. The registered bundle identifier remains
`dev.grobb.Atmos`, preserving WeatherKit authorization and existing settings.
The GitHub repository is `scott-g-robb/Aeolian`.

The listing uses English (UK), Weather and Entertainment categories, a 4+ age
rating, free pricing and all 175 available territories, including future
territories. There are no purchases, accounts, adverts or subscriptions. The
description, keywords, screenshots, support link and review contact are saved.
Release is manual after review approval.

The privacy disclosure identifies coarse location and other diagnostic data used
for app functionality, with no tracking or link to identity. This accounts for
the weather providers' server logs. Desktop screenshots stay in local memory.
The privacy policy is prepared in `site/index.html`; the maintainer must publish
it at `https://grobb.dev/projects/Aeolian#privacy` before submitting for review.
The URL returned 404 during verification on 10 November 2026.

The copyright field names Scott Graeme Robb. Required third-party licence notices
remain in LICENSE and NOTICE.md. The maintainer confirmed the intro audio was
supplied under Pixabay's free licence. Keep those notices with every distribution.

## Build and upload

The App Store configuration is separate from the Developer ID download. It enables
App Sandbox, outgoing network access, optional location and WeatherKit. Private
window-server integration, translocation handling and the direct GitHub installer
are excluded from the Store binary. Store updates are managed by the App Store.
Public window geometry polling remains available. Dock accumulation that relies
on private Dock geometry is unavailable in this configuration.

Store certificates and profiles belong in Keychain and Xcode's local profile
directory. Temporary private keys are removed after importing; no signing material
belongs in the repository or source archive.

```sh
APP_STORE_PROFILE=/absolute/path/to/store.provisionprofile ./scripts/build-app-store.sh
xcodebuild -exportArchive \
  -archivePath build/appstore/Aeolian.xcarchive \
  -exportPath build/appstore/upload \
  -exportOptionsPlist build/appstore/ExportOptions.plist \
  -allowProvisioningUpdates
```

Upload uses the signed-in Xcode account. The script validates that the macOS
distribution profile authorizes WeatherKit and the selected signing certificate,
then checks both architectures, sandbox entitlements, resource quarantine metadata
and excluded direct-release APIs before producing the signed installer package.

The exact Store-signed application is intended to launch through TestFlight or the
App Store, rather than directly from an archive. A local copy of the same Store
code, re-signed with Developer ID while retaining App Sandbox, successfully
requested native WeatherKit without personal credentials. Complete TestFlight
installation and permission checks before final submission; Apple's processing
success is not App Review approval.

## Rebrand migration

The new updater accepts both Aeolian and legacy Atmos releases from this publisher.
Older Atmos updaters restrict asset URLs to the former repository path, so the first
Aeolian release may require one manual installation from the new GitHub repository.
After that, updates use the Aeolian release feed. Saved presets and preferences keep
their stable identifiers through the rename.
