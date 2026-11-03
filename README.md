<p align="center">
  <img src="site/assets/icon-512.png" width="112" height="112" alt="Atmos icon">
</p>
<h1 align="center">Atmos</h1>
<p align="center">A little atmosphere on your desktop.</p>
<p align="center">
  <a href="https://grobb.dev/projects/atmos">Download for Mac</a> ·
  <a href="https://github.com/scott-g-robb/Atmos/releases">GitHub Releases</a> ·
  <a href="#try-it">See it in motion</a> ·
  <a href="#build">Build from source</a>
</p>
<p align="center">macOS 14+ · Apple silicon &amp; Intel · Free for noncommercial use</p>

![Snow, rain, storm clouds, mist, fireflies and autumn leaves rendered by Atmos](docs/assets/scenes.png)

Atmos lives in your menu bar and brings interactive weather to your Mac. Snow settles
on windows. Rain gathers in reflective puddles. Clouds curl around your cursor.
Choose a scene, or let Live Weather follow the sky outside. Most Cloud Wisps pass behind windows, with occasional foreground billows.

## Try it

![Rain, mist and fireflies in motion](docs/assets/interaction.gif)

*Rendered with the app's Metal renderer against sample windows. The preview is 30 fps;
the app targets your display's native refresh rate, including 120 Hz ProMotion.*

- **Sweep and scatter.** Push through snow and leaves, stir mist, or flick water into splashes.
- **Move your windows.** Drifts follow their ledges. Fast drags send snow, leaves and water falling to the surfaces below.
- **Watch the weather change.** New effects arrive immediately while the old scene naturally melts, dries or dissipates.
- **Keep working.** Controls remain accessible. A window at the top edge covers the weather within its own outline; 70% screen coverage moves the scene behind windows.

| Precipitation | Atmosphere | Nature |
| --- | --- | --- |
| Snow · Rain · Drizzle | Mist · Cloud Wisps | Autumn Leaves |
| Storm · Lightning · Sleet · Hail | Sunbeams | Fireflies |

**Live Weather** combines effects to match local conditions, including lighter cloud
cover, sunbeams or nighttime fireflies. Its menu card shows the location, condition,
temperature, observation time and active provider. Intensity adjusts automatically.

## Install

1. Download the Mac installer from [grobb.dev](https://grobb.dev/projects/atmos) or [GitHub Releases](https://github.com/scott-g-robb/Atmos/releases).
2. Open the `.dmg` and drag **Atmos** into **Applications**.
3. Open Atmos and use its icon in the menu bar.

The installer contains just Atmos and the Applications shortcut, with a drag-to-install
arrow. Quit an older copy before replacing it. To uninstall, quit Atmos and move it
to the Trash.

The included development installer is signed but **not notarized**. If macOS blocks
it, use **System Settings → Privacy & Security → Open Anyway**. See
[RELEASING.md](RELEASING.md) for Developer ID signing and notarization.

## Make it yours

Choose a manual scene or switch **Live Weather** on. Use the intensity slider for
manual scenes; live intensity is automatic. **Surfaces** controls accumulation,
evaporation and window interaction. **Settings** includes placement, screenshot
visibility, full-screen behaviour and Open at Login.

**Settings → Permissions & Activity** shows granted access and current use for
Screen Recording, Location Services and Open at Login, with links to macOS settings.
**Settings → Screen Reflections** stops or enables desktop capture without revoking
the macOS permission. **Settings → Water Reflection Source** offers:

| Source | What appears in the water |
| --- | --- |
| **Live Desktop** | Live windows, video and the cursor; capture adapts to desktop activity |
| **Window Snapshots** | Cached window images that follow window movement; content refreshes about once a second |
| **Wallpaper Only** | Wallpaper reflections without capturing other apps |

Water remains interactive with every source. Leaving a rain scene dries its puddles
in roughly eight seconds. Switching between water scenes preserves existing water.

## Privacy & weather sources

- **Location Services** is requested when you enable Live Weather. Coordinates are rounded before requests; location and weather readings remain in memory.
- **Screen Recording** is needed for desktop and window reflections. Images stay on your Mac, are never saved or uploaded, and contain no audio. macOS **Stop Sharing** is respected.
- **Automatic · Apple First** prefers Apple's WeatherKit service and clearly labels the Open-Meteo fallback. You can also select either provider manually.

Apple Weather needs a WeatherKit-enabled signed build or personal credentials stored
in Keychain. A source build works with Open-Meteo without an API key. Atmos uses the
supported Apple weather service; it does not read the Weather app's private files.
See [weather setup](RELEASING.md#apple-weather).

## Built for macOS

Swift and AppKit handle the menu, displays and system integration. Metal renders the
effects and simulates cloud flow; an allocation-free Rust core handles particles and
water. Buffers and pipelines are reused, and desktop capture adapts independently
of animation. Visible animations target each display's native rate; macOS may lower
the physical refresh rate for power or thermal reasons.

By default, animation and capture pause while the display is asleep, locked or covered
by a full-screen app. Reduce Motion is respected. Energy use varies with the scene,
resolution, display rate and reflection source; no fixed CPU/GPU percentage is promised.

## Build

Requires Xcode, its command-line tools, and [Rust](https://rustup.rs/).

```sh
./test.sh             # Rust, Swift and Metal regression tests
./build.sh            # Universal build/Atmos.app
./make-installer.sh   # Verified dist/Atmos-<version>.dmg
./install.command     # Build, install into ~/Applications and launch
```

Builds are ad-hoc signed unless a signing identity is configured. Rust is linked
statically; users need no toolchain or runtime dependencies. Metal tests skip when
no compatible GPU is available.

```
Sources/Atmos/
  App/          Lifecycle, preferences and power management
  Desktop/      Displays, window tracking and reflections
  Rendering/    Metal renderers, shaders and GPU cloud flow
  Simulation/   Weather, water, snow and seasonal physics
  UI/           Native menu controls and welcome window
  Weather/      Location, providers and WeatherKit credentials
Sources/CWeatherCore/  C interface and ABI checks
weather-core/          Rust simulation core
Tests/                 Interaction, physics and rendering regressions
site/                  Static project page and interactive snow demo
```

See [RELEASING.md](RELEASING.md) for public releases and signing. Build products,
profiling output and local signing material are excluded from source control.

## Credits & license

Atmos grew from [Snowhush](https://github.com/mbezruchko/Snowhush) by Mykhailo Bezruchko.
The original copyright notice and [PolyForm Noncommercial 1.0.0 license](LICENSE) are
retained; see [NOTICE.md](NOTICE.md). This is source-available software for
noncommercial use.

Weather data: Apple Weather, with attribution in the app, and
[Open-Meteo](https://open-meteo.com/) under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
