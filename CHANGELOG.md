# Atmos changes

## 0.14.1 · build 65

- My atmosphere opens saved presets for immediate switching, with Edit/Delete under
  each arrow. With no presets it opens the editor directly.
- New atmospheres start empty, at 4 km/h wind, Medium intensity and 0% cloud coverage.
  Advanced is a peer tab beside Weather, Drift and Wildlife. Save stays bottom-right.
- Cloud coverage is editable and saved per preset. Weather choices suggest coverage;
  upgrading older presets preserves their prior weather-appropriate clouds.
- Precipitation enters at the screen top within the existing cloud coverage field,
  reaching high windows. Leaves and seasonal drift retain their original spawning.
- Loading-to-weather UI changes animate within a fixed dropdown frame.
- Visibility from native Apple Weather, personal WeatherKit and Open-Meteo drives
  continuous light haze through dense fog, alongside observed clouds/precipitation.
  Warnings strengthen the same fog layer. Nature accents are restrained in haze and
  dense fog, and Local weather details show visibility with explicit distance units.

## Earlier 0.14.1 changes (through build 64)

- Named atmosphere presets save all three layers, intensity and wind. Default names
  advance through atmos1, atmos2 and so on, and remain editable. Preset icons prefer
  weather, then seasonal drift, then wildlife. Empty presets cannot be saved.
- Apple Weather attribution is bounded and appears once per view; command images
  cannot overflow their rows. Weather details restart at the top when opened.
- Butterflies use a portable vector icon, including the menu-bar icon. Live Weather
  has a native loading indicator while acquiring its first reading.
- Screen Recording can be explicitly rechecked through ScreenCaptureKit when the
  legacy preflight result is stale. Permission state is shared with rendering;
  there is a restart action for macOS grants that need relaunch. Running capture
  is preserved during rechecking and Stop Sharing still requires an explicit resume.
- Native Xcode target enables WeatherKit with an all-device Developer ID distribution
  profile. Apple Weather works without users supplying personal credentials.
- A compact custom dropdown replaces the standard menu presentation, sharing the
  welcome/update surface. It has an integrated icon pointer, visual layer tiles,
  a live weather overview, focused settings pages and a separate update footer.
  Controls call the existing commands; selecting an active layer removes it.
- Permissions → Next prepares location/weather immediately when Location is allowed.
  Effects stay paused through the guide; the first icon click activates prepared
  weather or preserves an in-flight request without restarting it.
- Location callbacks arrive while the menu stays open, rather than waiting for its
  tracking loop to close. The first weather card updates as soon as data arrives.
- Apple is retried once before labelled Open-Meteo fallback, including when Apple
  is selected explicitly. Every new check tries Apple first; bounded provider
  deadlines allow fallback even when an SDK ignores cancellation.

- Fixed post-setup weather recovery: temporary Apple unavailability now enters the
  automatic retry loop. Location/request watchdogs run while menus track; failed
  attempts release pending work before retrying. Duplicate authorization and late
  callbacks cannot bypass the delay or overwrite recovered data.
- The weather card and live menu state update immediately when a retry succeeds,
  without reopening the menu or pressing Refresh. Retry timing/count is visible.
- Welcome tracks the installed copy as well as version/build. Manual replacements
  present setup again; only a valid, one-use automatic relaunch bypasses it.
- Both download/DMG and automatic installers wait for all previous copies to exit
  before replacing the app. Silent updates reopen in the background.
- Window bloom caches edge colours on the GPU and follows native-rate geometry.
  A soft contact halo closes the shadow gap; delayed captures cannot stencil old
  window positions into the glow.
- The compact dropdown keeps manual sliders out of Live Weather; Surfaces stays in
  Settings. All customisation remains available.
- Permission transitions stay centred without lateral sliding. Clouds and other
  effects return gently after setup; atmospheric entrances use eased timing.
- Flocks vary which birds land, how many stop, their spaced perches, resting times,
  flight direction in light wind and species mix.
- Removed the foreground wallpaper-difference glow mask that mottled Dock icons
  and widgets. All mist and bloom now stay behind real desktop objects, preserving
  their natural colours with subtle halos. One full-screen lighting layer is removed.
- Dense fog and window bloom now use native window occlusion, following the real
  shape during Genie minimization instead of leaving a rectangular fog cutout.
- Widget and Dock/icon halos use a clean wallpaper reference to distinguish their
  colours from wallpaper detail.
- Welcome and update panels stay above all effects. Entrance scaling stays centred,
  and Check for Updates has its own menu section below Settings.
- Failed Live Weather/location requests retry after 1, 2, 3, 5, 15 and then 30
  seconds, turning Live Weather off after 15 failed attempts without selecting temporary weather.
- Setup pauses effects and capture, preparing weather only after Permissions → Next
  with Location granted. New installs stay manual
  and empty; Skip preserves existing choices. The final icon click enables Live
  Weather only with Location access.
- Welcome unfolds from the Atmos icon with staggered content and a gentle settle.
- Check for Updates offers verified GitHub download, installation and relaunch in a
  matching Atmos panel. Optional Automatic Updates checks every two hours silently;
  automatic relaunches skip setup and never show update or administrator dialogs.
- Fog warning severity controls the transparency of broad fog areas, with smooth
  changes between severities. The original soft cloud appearance is preserved.
- Colour-aware fog bloom spreads light from windows, widgets, icons and Atmos
  effects. Dense fog and bloom respect window content. Fog Bloom has an independent
  capture control and shares the desktop stream with live water reflections.
- A rounded welcome and permissions flow appears on first launch and after updates.
  A menu-bar guide finishes when Atmos's icon is opened. Setup can be skipped or
  reopened in Settings, and respects light/dark appearance and Reduce Motion.
- Apple Weather warnings appear with their issuing agency and details link. Active
  warnings affect scenes without replacing observed measurements. Open-Meteo shares
  the weather rendering; its forecast API does not supply official warnings.
- Live cloud coverage controls occupied horizontal width. Rain originates beneath
  those clouds, and rain rate affects cloud depth and darkness. Clearing and forming
  clouds uses smooth transitions.

## 0.14.0 · since 0.13.2

- Live Weather continuously drives effects using wind, precipitation, cloud cover,
  humidity and feels-like temperature. Automatic tries Apple first with a labelled
  Open-Meteo fallback. Weather resumes and retries after sleep, locking and network
  interruption, with more specific location labels.
- Independent Weather, Seasonal Drift and Wildlife layers replace single-scene
  selection. Click a selected layer to turn it off.  Wind and intensity sliders return
  to manual control when Live Weather is switched off.
- Cherry blossoms, rose petals, dandelions, maple seeds and cottonwood fluff join
  autumn leaves. Whole dandelions burst into seeds; maple seeds autorotate in varied
  horizontal planes. Birds, butterflies and fireflies arrive in seasonal spells.
- Birds vary in appearance, arrive in groups of 2–5 and fly off shaken windows.
  Butterflies rotate in flight and stay behind windows. Halloween Snow was removed.
- Water reacts to cursor collisions, rain, window acceleration and lightning.
  Fine liquid parcels form smooth, deforming blobs and strings, with brief white
  foam. Seasonal material floats, rides waves and joins splashes. Window puddles
  overflow and retain lateral momentum during fast drags.
- Rust physics and GPU smoke/liquid reconstruction reduce simulation and rendering
  work. Visible effects retain native display refresh, including 120 Hz. Capture
  adapts independently; performance depends on hardware and scene.
- Screen Recording, Location Services, Open at Login and reflection controls are
  available in Settings. Installers support Apple silicon and Intel on macOS 14+.
