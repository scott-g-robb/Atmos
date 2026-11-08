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

The repository includes a native **Atmos.xcodeproj** target and shared scheme with
WeatherKit enabled. `build.sh` uses this Xcode target when a profile is supplied;
without one it retains the key-free Swift package/Open-Meteo source build.
On this Mac, ignored `build/weatherkit-profile-path.txt` and
`build/signing-identity.txt` remember the selected profile and certificate. Regenerate
source references with `python3 scripts/generate-xcode-project.py` after adding files.
Profile preparation validates platform, expiry, App ID, native WeatherKit permission,
all-device distribution and the signing certificate. Private signing keys stay in
Keychain; no private WeatherKit service key is embedded or required by users.

Run `build/Atmos.app/Contents/MacOS/Atmos --verify-native-weatherkit` on the signed
bundle before packaging. This checks the real native API at a fixed public test
location, forbids the personal-key fallback, and prints only success or an error
code. Build 63 passed this check. Public release notarization remains a separate
step; no GitHub publishing occurs during local builds.

The build validates and embeds the profile and adds its WeatherKit entitlements.
Verify a live request with the enabled account before publishing. Automatic and
explicit Apple modes retry Apple once after one second, then use a clearly labelled
Open-Meteo fallback. Every new check starts with Apple again. Selecting Open-Meteo
requests only that provider.

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
./release.sh 0.14.2 "Release notes"
```

The script tests and builds both architectures, notarizes and staples the app,
creates and notarizes the disk image, updates its checksum, pushes the commit and
publishes a GitHub release with `Atmos.dmg` and `Atmos.dmg.sha256`. It uses the
repository `scott-g-robb/Atmos`; `RELEASE_REPOSITORY=owner/Atmos` overrides it.
`NOTARY_PROFILE` selects another Keychain profile. It never publishes to the
original Snowhush repository.

Before uploading, test installation and permissions on a Mac that has not run a
development build. Check the installed menu, all scenes, multi-display placement,
full-screen suspension and reflection sources. Run the local test and packaging
commands above; an unsigned build artifact is not a notarized public release.

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
and lean must vary between individual seeds. The current release is 0.14.2 (build 68).
Keep the previous stable 0.14.0 artifacts; discard superseded experimental packages.

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

## 0.14.1 weather checks

Apple requests current conditions and alerts. REST requests include the location's ISO
country code, obtained through geocoding; the machine's locale is not a location proxy.
Unavailable or malformed alert data must not discard a valid current reading or cause
an automatic switch away from Apple. Warnings remain in memory, with credentials in
Keychain. Follow [Apple's alert attribution requirements](https://developer.apple.com/weatherkit/):
preserve the complete original summary, the full agency name and an embedded details link.

REST onset/end/expiry timestamps gate visual effects, including transitions between
refreshes. Native WeatherKit exposes metadata validity dates rather than the REST
event-onset/end fields; it uses that provider validity window and refreshes before expiry.
Check active, future, expired and overlapping warnings, including fog mixed with rain.
The observed condition stays separate from the warning's visual influence. Unknown
hazards remain visible as warnings without inventing a measured rain or wind value.
Open-Meteo's documented forecast API has no warning dataset: label availability honestly
and keep its cloud/rain behaviour identical for the same measurements.

Compare 32%, 58%, 99% and full cloud cover. Occupied width below the menu-bar clipping
edge should match the
reported coverage in the shared coverage field. Preserve the original soft volumetric
appearance as the field moves with the wind. In calm rain, drops must originate beneath the cloud
geometry; wind may carry falling rain into a gap. Increasing rain rates should deepen
and darken the same coverage continuously. Clear Scene should dissolve existing clouds,
then build cloud volume and width gradually after the clearing interval. Secondary fog,
material and wildlife layers must not duplicate the sky.

Build 54 restores the original 0.14.0 cloud shader's volume sampling, light extinction,
colour and soft underside. Manual cloud and lightning canopies retain their original
geometry, with a pixel comparison against the original fragment on light and dark
backgrounds (maximum channel difference: 1). Live coverage calibrates that original
continuous noise field to the requested width; it does not replace the cloud artwork.
A GPU probe checks the actual coverage function against the CPU rain layout, separately
from the volume's naturally translucent edges. Manual scenes avoid the calibration work.

Build 55 gives mist a continuous background scattering layer, wider rolling banks,
and a diffuse optical-depth treatment distinct from the cloud volume. The cloud
renderer's original-appearance comparison must keep passing. Mist uses the same rounded
window masking as background cloud wisps; its veil and ledge banks always stay behind
windows. Roughly 95% of mist births choose the background, with at most one faint
foreground volume (alpha at most 0.13). Pointer interaction must preserve that choice.

Compare mist and cloud wisps on dark and light desktops with overlapping windows.
Mist should cover substantially more desktop area and lower background contrast while
application text stays clear. Check manual intensity, warning-driven fog, clear/reform
transitions and scene retirement. `ATMOS_BENCHMARK_DIR=/tmp/atmos-performance ./test.sh`
also records native-resolution fog simulation, CPU encoding and GPU work separately.
The fog model integrates diffuse optical depth directly rather than adding cloud ray
samples; measurements still exclude capture and do not establish other hardware's frame rate.

## Build 56: fog bloom and setup

The strongest currently active fog warning sets the broad haze's optical depth:
minor 0.45, moderate 0.72, severe 0.90, extreme 1.00; unknown severity uses 0.65.
These are visual weights, not claimed visibility measurements. Humidity must not
override the severity distinction. Increases, decreases and expiry blend smoothly.

Fog bloom includes windows, desktop icons, wallpaper and Atmos effects. A single
ScreenCaptureKit stream serves fog and live water, excludes Atmos itself, and has
no audio. Snapshot/Wallpaper water retains its selected source when fog needs live
capture. Fog Bloom and Screen Reflections are independent controls. Test each
combination, drying/retiring scenes, permission denial/revocation, Stop Sharing,
fullscreen, locking and sleeping. Capture stops after the final visible consumer.
Bloom uses a reused native-resolution scene target and a GPU-only, low-resolution
linear-light separable blur. Native presentation stays unchanged. Record capture,
simulation, CPU encoding and GPU work separately; the synthetic bloom benchmark
excludes actual capture and must not be reported as whole-app performance.

Onboarding appears once per app version/build, including upgrades from 0.13.2.
Check the exact welcome copy, Back/Next/Skip, light/dark appearance, Reduce Motion,
all permission states and returning from System Settings. No permission is needed
to continue. Open at Login is optional. The guide must track the actual status icon,
stay above other windows, allow clicks through to the icon, and fade only when the
root Atmos menu opens. Setup completion is persisted only after Skip or that click;
quitting mid-setup presents it again. Show Setup can replay it without changing
weather preferences. System permission prompts must stay in front of setup itself.


## Builds 57–62: updates, pause and native fog occlusion

Check welcome, four permission/preference rows, Back/Next/Skip and the menu-bar
arrow. Effects and capture remain paused until Skip or completion. Weather/location
alone prepare after Permissions → Next when Location is granted.
A fresh install starts empty/manual. Skip preserves existing selections; completing
setup enables Live Weather only when Location is granted. The icon-led unfolding
entrance respects Reduce Motion. Automatic Updates is opt-in, not a macOS grant.

Dense fog, cloud wisps and window-edge bloom render in a normal desktop-level window,
outside the fixed overlay Space. WindowServer clips these layers to real window
shapes during Genie minimization; CPU rectangles do not cut holes in this background.
As of build 59, all mist wisps and bloom stay in this background. The foreground
lighting window and inverse wallpaper stencil are removed. Dock/widget/icon halos
are limited to 12% opacity and never filter the objects themselves. A GPU-backed
wallpaper-only snapshot, refreshed at most once a minute while fog already has capture
permission, separates objects from wallpaper detail. It adds no continuous stream.
Test minimization for regular and maximized windows, yellow-button and Command-M,
plus widgets and Dock icons on detailed wallpaper. Include wallpaper patches that
match an object's colour: they must not punch an inverted pattern into that object.
The mist-only foreground target must be transparent with bloom both on and off.
Welcome, guide and update panels
must stay above effects; they also have explicit overlay exclusions. Animation
transforms compensate for AppKit's layer anchor to keep scaling centred. Check for
Updates has a separate menu section below Settings. Test all reflection-source
combinations, Stop Sharing, locking, sleeping and fullscreen suspension.

The manual updater uses GitHub’s latest full release, parsing `Atmos X.X.X` from
its name; tags can differ. Publish an Atmos DMG with the API SHA-256 digest or a
matching `.sha256` asset. Keep the bundle identifier and Apple signing team stable.
Unsigned/ad-hoc or foreign-publisher replacements are rejected. A certificate can
rotate within the same Apple team. Developer ID signing/notarization remains the
public release workflow. No publishing occurs when building locally.

Automatic checks run about every two hours while awake, enabled and outside setup.
They display no update UI, never request administrator access, and pass a one-use,
version/build/path-bound receipt plus a relaunch flag to suppress welcome. A normal
or manual relaunch cannot reuse that receipt. Manual updates retain their prompt
and welcome. Test downloads, cancellation, digest mismatch, publisher checks,
rollback, post-exit replacement and relaunch using isolated signed fixtures. The
live API/download test uses `ATMOS_TEST_GITHUB=1`; it validates the published DMG
without installing it over the running app. Administrator authorization still needs
an interactive check on a standard-user Mac.

Live location/weather failures share a bounded retry budget: 1, 2, 3, 5, 15 seconds,
then 30 seconds until 15 total attempts have failed. Live Weather then turns off,
its preference is persisted, and no temporary scene is selected. While awaiting a
first usable reading, show no live effects. Existing manual selections are preserved.
Automatic network, expiry and alert
callbacks must not reset that budget or bypass a pending delay. Success, explicit
Refresh Weather, provider/permission changes or resuming a live session resets it.
Disabling Live Weather, sleeping, locking and entering setup cancel pending work. Verify
exhaustion leaves no scheduled refresh and Live Weather is unchecked in the menu.

Build 60 checks: reinstall an identical release manually and verify welcome returns;
ordinary relaunches of that same installation must not repeat it. A valid one-use
automatic receipt completes setup for only the new installation identity. Install
helpers wait for every old PID before replacing any file in the installed bundle,
and automatic open uses background activation. Test both helper paths using signed,
isolated fixtures; never replace the real app during updater tests.

Window bloom retains four GPU edge colours per tracked window. Geometry follows the
native display rate while fog is active; colours refresh only after capture catches
up to stationary bounds. Captured old/swept window regions are excluded from desktop
object lighting, preventing trails. Check contact at the window shadow, fast diagonal
drags, resizing, overlapping windows, minimizing and closing, with adaptive capture.
Record capture, simulation, CPU encoding and GPU work separately.

Check Next/Back throughout the welcome resize: both text and window centres stay
fixed, and the two pages crossfade without lateral translation. Skip resumes all
overlays with a 1.4-second eased introduction (shortened with Reduce Motion).
The main menu has six primary items; manual sliders are in Manual Effects and hidden
while Live Weather is enabled. Surfaces and the website link are in Settings.
Test bird groups across many seeds: zero, one and multiple landings, spaced perches,
varied dwell times, occasional companion groups and takeoff after a window shake.

Build 61: exercise the LiveWeather coordinator with injected location/provider
failures, not just its backoff calculation. After a paused setup, fail the first
location request and first weather request separately: both must retry automatically
after one real second. Temporary explicit-Apple unavailability must schedule recovery.
Location and provider watchdogs use common run-loop modes so an open menu cannot
stall them; provider requests time out after 25 seconds. A failed attempt releases
pending work, while duplicate authorization callbacks cannot reset its retry budget.

Hold the weather card open across failure/success: it must display the new reading
without another menu update or manual refresh. Verify the exact 14 retry delays
for 15 failed attempts, then Live Weather off, no placeholder scene and no automatic
revival. Test pause/resume, late location callbacks and a non-cooperating cancelled
provider result. Retry tests use synthetic coordinates, fake providers and no system
permission requests, geocoding or network monitor. Full suite still includes the
separate optional public GitHub download/signature check.

Build 62: Permissions → Next starts location/weather immediately if Location is
granted, with effects and capture still paused through the guide. The final menu
click activates prepared data or keeps the existing request alive. Check both a
completed fetch and an immediate click while location is still arriving. No Location
grant means no preparation and no automatic Live Weather activation.

The production location adapter owns an idle worker run loop and forwards callbacks
in the main run loop's common modes, so a tracking menu cannot stall the first fix.
The regression suite reproduces default-mode starvation, then exercises the actual
adapter and AppDelegate/WelcomeController handoff with synthetic location readings.
Apple gets two attempts, one second apart, before labelled Open-Meteo fallback in
both Automatic and explicit Apple modes. Each provider attempt has a six-second
deadline; the coordinator retains its 25-second overall watchdog. A non-cooperating
SDK must neither block fallback nor restart it after cancellation. Every refresh
starts with Apple again unless Open-Meteo was explicitly selected. Fullscreen pauses
rendering without interrupting weather acquisition; lock/sleep still pause both.


## Build 63: native WeatherKit and custom dropdown

Verify the Developer ID signature, embedded macOS profile and WeatherKit entitlement
on both architectures. The profile must authorize all devices, not a development
UDID list. Native verification must succeed without personal credentials. Include
Atmos.xcodeproj and its shared scheme in the source archive; exclude xcuserdata,
profiles, certificates and private keys.

Check the 320-point-wide, at-most-520-point-high dropdown on light/dark desktops and
small/secondary displays. The triangle shares the panel's continuous outline and
points toward the status icon. All pages scroll within the same stable footprint.
Test outside-click dismissal, Escape, keyboard focus, repeated icon clicks, and
closing the menu before opening setup, update or permission panels. The weather
card opens full weather details/provider selection. Selected weather/drift/wildlife
tiles toggle independently; manual sliders stay editable after leaving Live Weather.
No menu timers or continuous animations should run while closed.


## Build 64: presets and permission recovery

Test default atmos1/atmos2 numbering, renaming, saving, updating, deleting and reload.
Snapshots include weather, drift, wildlife, intensity and wind; applying one leaves
Live Weather and restores the whole snapshot. The icon priority is weather → drift
→ wildlife. Neither Save nor Return can save three empty selections. Global capture
and privacy preferences are not part of presets. Storage stays in UserDefaults.

Use an oversized attribution fixture: the Apple mark must remain bounded, with no
duplicate provider row. Check loading → reading, butterfly-only scenes, full preset
lists, returning to the top of a newly opened page and disabled Save appearance.
The menu footprint and pointer remain unchanged.

ScreenRecordingAccess centralizes preflight and explicit ScreenCaptureKit proof.
A Recheck or return from deliberately opened Screen Recording settings can recover a
stale false preflight; no background permission probing occurs. Successful checks do
not start streams or reset an active capture. User-declined errors invalidate cached
SDK proof; Stop Sharing remains distinct. macOS signing changes may require a fresh
grant/relaunch; test those on a fresh installed copy. Restart waits for the current
process to exit, and ordinary restarts do not bypass unfinished setup.


## Build 65: quick presets, Advanced and visibility

My atmosphere must open the saved list, not the editor, when any presets exist.
Selecting a row changes the atmosphere without leaving the list. Each arrow reveals
Edit/Delete; Edit opens that preset, Save returns to the list, and deleting the last
preset opens an empty draft. New drafts use 4 km/h wind, Medium intensity and 0%
cloud coverage. Name remains editable. Save is fixed bottom-right outside scrolling.
Advanced is the fourth peer tab beside Weather, Drift and Wildlife; its intensity,
wind and coverage values persist in snapshots. Earlier snapshots without coverage
migrate to the original weather defaults (rain/snow 100%, clouds 65%, otherwise 0%).

Ongoing rain/drizzle/storm/lightning/sleet/hail sources use the screen's top edge in
cloud-covered columns. Test windows whose top lies inside the cloud band. Seasonal
material, including leaves and other drifting drops, keeps its previous spawning.
Loading-to-reading animates inside a fixed-size dropdown with reduced-motion support.

Native WeatherKit converts visibility to metres; the personal REST path and
Open-Meteo already report metres. Open-Meteo requests visibility in current variables.
Missing/invalid visibility contributes no fog. A bounded logarithmic artistic mapping
adds subtle haze at about 8 km (5 miles), thickening towards 100 m. Do not interpret
an Apple Weather display abbreviation as metres without its unit. Visibility and
active alert density use their maximum, never two separate fog overlays. Retain
observed cloud cover/precipitation, soften sunlight, and reduce nature accents as
visibility worsens. Local weather details show km or m. Test unknown/zero/extreme
visibility, alert priority, one fog overlay, gradual arrival and legacy preset reload.
Provider references: [WeatherKit visibility](https://developer.apple.com/documentation/weatherkit/currentweather/visibility)
and [Open-Meteo current variables](https://open-meteo.com/en/docs).


## 0.14.2: weather overview

The Live weather root shows the local condition and the combined effects under On
your desktop. It does not show a partial measurement selection. Layers use the same
scene description passed to rendering, including warning-driven fog and seasonal
accents; shared atmospheric layers appear once. Changes ease within the fixed menu
frame, using existing weather/scene refresh events rather than a new timer. The
root Live weather page has no scroll view: conditions, combined effects and source
fit above the fixed update footer. The redundant Compose shortcut is removed; My
atmosphere remains the direct entry to presets and creation.

Local weather groups every reported input together: temperature, feels-like, wind
with its source direction, gusts, cloud cover, rainfall, humidity and visibility.
Optional missing readings show a dash/Not reported, never an inferred measurement.
Check light/dark layouts, a full combination of layers, no layers, loading-to-reading,
all eight measurement cards with missing values, and scrolling to warnings/actions.
CHANGELOG.md records release milestones, without per-build development history.


0.14.2 update and units checks: periodic discovery runs about every two hours while
awake with Automatic Updates both on and off. The toggle controls silent install,
not discovery. No automatic check opens a panel. Read-only install locations still
check and show availability. Successful/failed checks store their completion time;
failed checks never claim up-to-date. Cached release versions clear the badge when
the installed version catches up. The orange dot is separate from the template
weather icon and cannot intercept clicks. The update footer includes the check time
and result, and the five-layer Live weather overview must still fit without scrolling.

Units defaults to Metric (°C, km/h, mm/h, m/km). Imperial converts temperature to °F,
wind/gusts to mph, rain to in/h and visibility to ft/mi. Check both weather pages,
manual wind and accessibility captions. Inferred/saved values and simulation inputs
remain Celsius, km/h, millimetres and metres. Light rain keeps three decimal places
in inches so drizzle is not rounded to zero. Settings changes apply without refetching
weather or changing selected layers. Profiles/previews include both units and an
available-update footer.


## Hybrid screenshot capture (0.14.2)

Water and fog share WindowReflections; there is no SCStream creation or streaming
fallback in production. SCScreenshotManager.captureSampleBuffer is available on
macOS 14. IOSurface-backed pixel buffers become Metal textures without CPU image
readback. Per-window images normally refresh every 10 seconds, with new/resize,
app activation and mouse/scroll content hints prioritised and coalesced. A 150 ms
GPU crossfade applies only to updated images. Still geometry skips compositing.
Geometry and display rendering remain independent; Low Power Mode uses up to
60 Hz presentation and 30-second screenshots (battery: 20 seconds).

Desktop Screenshots includes the desktop base; Window Snapshots uses clean wallpaper
for water, including when fog simultaneously needs desktop imagery. Native window
occlusion and the original water/fog shaders remain in place. Relevant water source
regions and opaque window coverage exclude unnecessary windows. Minimized/closed/
off-screen windows are removed; source changes, display changes and pause cancel
pending work by generation and release buffers. Failures back off and retain valid
images, never fall back to streaming. Permission denial releases cached app images.

The UI requests Screenshot Access, but macOS uses the shared screen-capture TCC
permission under Screen & System Audio Recording. No separate screenshot permission
exists on the supported macOS 14 API. Do not promise the absence of OS indicators
or alter system privacy controls. Verify on macOS 14 as well as current macOS.

CaptureDiagnostics (--profile-desktop-capture) records timing/counts only, never
images, names or coordinates. Direct-shell attempts reported no capture permission;
launching signed diagnostic copies through LaunchServices picked up the existing
grant. Both real capture runs completed. See docs/PERFORMANCE.md: screen-source
updates decreased, but the real diagnostic did not establish a CPU/GPU reduction.
The isolated 12-second eight-window cache benchmark uses synthetic IOSurfaces at
120 geometry/composite ticks per second. Baseline and after JSON are in
build/verification/hybrid-before and hybrid-after. Do not label these whole-app
CPU measurements or include WindowServer/capture service costs in their scope.
References: https://developer.apple.com/videos/play/wwdc2023/10136/
and https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager


## Rust kernels and welcome audio (0.14.2)

The CPU migration keeps Swift-owned buffers and C-defined layouts, checked in C
and Rust for both architectures. The Xcode generator compiles WeatherCore.c too,
so the SIMD ABI shim and static layout assertions match the SwiftPM test target.
Wind, snow/botanical flight, pile transport/cursor carving, support inertia,
resting-leaf interaction, buoyancy, bird motion and water interaction/emission
kernels live in weather-core/src. Metal smoke/liquid/rendering work stays on the GPU.
AppKit geometry, scene policy, emission scheduling and visual assembly stay in Swift.

Window-top mouse impulse is 50% of desktop/Dock impulse. Verify slow/submerged and
fast strokes, sideways window momentum, floating maple seeds and storm/lightning
water, with volume conserved. The supplied IntroAudio.mp3 is copied by both build
paths; verify its hash against the canonical resource in the signed app and DMG.
It plays once when the welcome opens, fading out if setup finishes early; ordinary
launches without welcome and silent auto updates do not play it.

The current verification set has 242 Swift and 13 Rust tests, including optional
profiles/renders and the live GitHub release download check. See docs/PERFORMANCE.md
for measured before/after scope and limitations. The separate capture diagnostic
requires an existing macOS screenshot grant; launch the signed app through macOS
so permission attribution matches normal use. Never bypass TCC or promise
indicator suppression. Physical Intel/macOS 14 and multi-display checks remain
necessary; a universal build alone is not device validation.
