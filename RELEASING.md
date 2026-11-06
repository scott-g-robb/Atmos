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
./release.sh 0.14.0 "Release notes"
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

## Dynamic weather checks

For the 0.14 series, verify three independent manual selections (Weather, Seasonal
Drift, Wildlife), deselection by clicking again, and persistence across relaunch.
Check all six drift styles on light and dark desktops, including moving window ledges,
floating material, drying water, and cursor lifts. Check four bird variants and ensure
butterflies rotate with flight and disappear beneath application windows.
For 0.14.0, check variable 2–5 bird groups, occasional companion flocks, quiet gaps,
and a perched bird taking off when its window is shaken. Sweep through a whole
dandelion head to release its seeds and check fast maple autorotation and motion blur.
Let rain overfill a window ledge: shallow films should stay pinned, while excess
water spills at the edges. Compare upward, downward and horizontal window movements;
droplets must retain momentum and the selected reflection source. Regression tests
check retained plus spilled water mass and distinguish gentle drags from shakes.
In Live Weather, confirm cloud cover is continuous, drizzle remains light under
near-overcast skies, wind responds to reported compass direction, and material/wildlife spells
have lulls. Compare northern and southern seasonal dates in regression tests.

`ATMOS_BENCHMARK_DIR=/tmp/atmos-performance ./test.sh` enables isolated weather and
three-layer profiling. It records simulation (including shared airflow), render CPU
encoding and GPU time separately. It does not measure screen capture or establish a
whole-app CPU percentage. Capture has its own adaptive cadence and runtime metrics.

Check fullscreen entry/exit, Split View, Mission Control and multiple displays on
both physical Intel and Apple silicon hardware. A geometry fallback supplements
private Space information; universal compilation alone does not verify Intel desktop
behavior. Rendering and capture must stop after the fullscreen fade and resume on exit.

For new installs, verify Live Weather starts on and all three manual layers are empty.
Preserve existing users' explicit choices. Test a long sleep/lock, temporary network loss,
and Automatic → Apple → Automatic: Apple data must be preferred each time, with a
labelled fallback and bounded retries. A failed branding-image download must not discard
Apple data. Verify neighbourhood labels when the geocoder supplies them. Seasonal
Halloween code and the Screen Facing control have been removed.

Keep the cursor submerged and stationary: its solid boundary excludes fluid, while
water above it flows over through the free-liquid solver. Conserve displaced volume
and refill when the cursor leaves. Check fast cursor strokes
and floating material carried by the same liquid impulse. Let puddles rise under settled
leaves. Check long heavy rain on a narrow window for a thin film, overflow originating
at the rounded top edge, and cohesive liquid sheets during shakes. Maple autorotation
must project a horizontal orbit around the stem, never a flat screen-plane pinwheel.

Check diagonal window throws for both velocity components, cohesive blobs and thin
ligaments during fast cursor strokes, and sharp foam bubbles fading within a second.
All six floating drift styles must share splash momentum. Maple rotor inclination
and lean must vary between individual seeds. The only 0.14 release artifact set is
0.14.0 (build 52); discard superseded 0.14.1–0.14.3 packages.

For build 50, check flotation on the landing frame and after water rises beneath
existing litter; submerged aggregate litter must not cover the water. Confirm maple
seeds decay with global thaw disabled. Check Wind Speed below Intensity: 0–100 km/h,
saved manual value, automatic/disabled while Live Weather is enabled, and restoration
on returning to manual. Check both rain and lightning splashes and sustained storm
ripples. Dense-liquid profiling includes a CPU neighbourhood-cache comparison; GPU
surface comparisons can use ATMOS_REFERENCE_SHADER pointing to an earlier Metal
source file. Capture is excluded and must be measured separately.

For build 51, compare calm vertical rain with windy rain: upward splashes should
inherit the incoming horizontal velocity, with only subtle radial spread. Verify
thin window puddles still splash when the desktop puddle receives many impacts.
Lightning should end at the actual wet surface and produce a broad crown followed
by a short pressure-fed jet, conserving water volume. Floating material uses the
earlier low sitting height. Check soft, asymmetric liquid silhouettes and connected
ligaments in motion; enlarged shader previews must not change application sample size.

`ATMOS_BENCHMARK_DIR=/tmp/atmos-performance ATMOS_SWEEP_NATIVE=1 ./test.sh`
also measures rapid full-puddle cursor sweeps at the host display's backing resolution,
separating simulation, CPU encoding and GPU time. It warms rendering before measuring,
keeps the full liquid population and excludes capture. Compare the combined measured
work with the display's frame budget; this isolated test does not prove whole-app frame
delivery or performance on other hardware. Dense-cell searches have bounded sampling,
liquid buffers are preallocated, and fast cursor movement reuses its reflection image.

For build 52, edit both sliders, enable Live Weather, choose a manual scene, then
edit both again. Repeat without relying on a menu-needs-update callback; saved manual
values must return immediately. Window puddles retain 5.85 points of depth (about 30%
more), with the existing conservative overflow. Check whole dandelion heads on light
and dark desktops: seed stalks and tufts rotate around a sphere, the stem foreshortens,
and near/rear overlap changes with tumbling. Individual released seeds keep their model.

Liquid contour neighbours are now built on the GPU without CPU readback. A parity test
compares the field against Rust through dense cells, hash collisions and motion;
equal-distance candidates have stable ordering. The Rust fallback remains available.
For an isolated comparison, add `ATMOS_CPU_LIQUID_FIELD=1` to the rapid-sweep profiling
command and set `ATMOS_SWEEP_LABEL=cpu`; omit it and label the second run `gpu`.
`ATMOS_SWEEP_FRAMES` can extend the measurement beyond its default 48 frames.
Memory allocation and splash-queue shifts are removed from the merging/draining paths;
interaction and neighbourhood rejection avoid work outside their physical reach.
