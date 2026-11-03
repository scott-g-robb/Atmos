# Building & releasing Atmos

## Local installer

```sh
./test.sh
./make-installer.sh
```

This produces a universal `build/Atmos.app`, a verified
`dist/Atmos-<version>.dmg` and its SHA-256 checksum. `dist/Atmos.dmg` is a convenient
alias. App bundles include the license and attribution. The installer shows only the app and Applications shortcut on a Retina-ready background.
`install.command` remains available in the source for installation into `~/Applications`.

Installer packaging installs the pinned Python dependencies in `scripts/dmg-requirements.txt`
into an isolated `.build/dmg-tools` environment on first use.

The default build is ad-hoc signed. `IDENTITY` selects an installed signing
certificate; a previously selected local identity is remembered in ignored
`build/signing-identity.txt`. Development signing is suitable for local tests;
public distribution should use Developer ID and notarization.

## Apple Weather

Apple Weather uses [WeatherKit](https://developer.apple.com/weatherkit/). Register
`dev.grobb.Atmos` (or your chosen bundle identifier) with the WeatherKit capability
and create a matching **macOS** provisioning profile:

```sh
IDENTITY="Developer ID Application: Your Name (TEAMID)" \
BUNDLE_IDENTIFIER="dev.grobb.Atmos" \
WEATHERKIT_PROFILE="/absolute/path/to/WeatherKit.provisionprofile" \
./make-installer.sh
```

The build validates and embeds the profile and adds its WeatherKit entitlements.
Verify a live request with the enabled account before publishing. Automatic mode
clearly falls back to Open-Meteo when Apple Weather is unavailable; selecting Apple
Weather explicitly reports an error instead of silently changing providers.

For a personal WeatherKit service key, store credentials only in the login Keychain:

```sh
mkdir -p build
swiftc Sources/Atmos/Weather/WeatherKitCredentials.swift \
  scripts/configure-apple-weather.swift -o build/configure-apple-weather
build/configure-apple-weather /path/to/AuthKey.p8 KEY_ID TEAM_ID SERVICE_ID \
  /absolute/path/to/Atmos.app
```

The utility validates the key and grants the app's signing identity access. Keep
that identity stable across updates. Never distribute the private key. Public
builds need native WeatherKit authorization or a separately operated token service.
Changing a bundle identifier may require granting Location and Screen Recording
permissions again and reconfiguring personal Keychain access. Existing preferences
from earlier Atmos builds are migrated automatically.

## Publish a release

Prerequisites: a clean Git checkout with your own `origin`, an authenticated
[GitHub CLI](https://cli.github.com/), a **Developer ID Application** certificate,
and a `notarytool` Keychain profile. The default profile name is `atmos`.

```sh
xcrun notarytool store-credentials atmos
./release.sh 0.13.2 "Release notes"
```

The script tests and builds both architectures, notarizes and staples the app,
creates and notarizes the disk image, updates its checksum, pushes the commit and
publishes a GitHub release with `Atmos.dmg` and `Atmos.dmg.sha256`. It uses the
repository `scott-g-robb/Atmos`; `RELEASE_REPOSITORY=owner/Atmos` overrides it.
`NOTARY_PROFILE` selects another Keychain profile. It never publishes to the
original Snowhush repository.

Before uploading, test installation and permissions on a Mac that has not run a
development build. Check the installed menu, all scenes, multi-display placement,
full-screen suspension and reflection sources. GitHub CI verifies tests and produces
an installer artifact; an unsigned CI artifact is not a notarized public release.

Upload source files through Git, and attach installers through GitHub Releases.
Do not commit `.build/`, `build/`, `dist/`, credentials, profiles or signing keys.
The source archive in `dist/` excludes those generated and private files.

`site/` is a static page with no build step. Its canonical URL is
`https://grobb.dev/projects/atmos`; publish its contents at that route. Asset URLs are
relative so the page also works under a project subdirectory.

The page downloads `Atmos.dmg` from the latest `scott-g-robb/Atmos` GitHub release.
Create that repository and publish the first release before deploying the page.

## App icon

`Resources/AppIcon.icon` is the canonical native icon. The build compiles it with
Xcode for modern macOS appearances and exports every legacy icon size from the same
artwork using `scripts/build-icons.swift`. Keep `CFBundleIconName` set to `AppIcon`
so macOS uses the native asset instead of wrapping a legacy bitmap in another tile.
