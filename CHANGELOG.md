# Aeolian changes

## 0.14.4 — Aeolian, a continuous sky

- Atmos is now Aeolian. App, installer, menus, project and repository names are
  updated while the bundle identifier, saved settings and WeatherKit access remain stable.
- Dismissing a context menu no longer moves foreground cloud wisps behind all
  windows. Temporary menus no longer collect particles like window ledges.

- Weather refreshes preserve the existing composition. Coverage and rainfall
  interpolate in place; changing precipitation inherits the already formed sky.
- Clouds follow accumulated wind motion consistently: north/west travel left,
  south/east right. Gusts change speed without reversing the prevailing direction.
- Seasonal drift and wildlife use distinct weather scenarios. Unchanged conditions
  retain the same layers across checks, with natural pauses in their emitters.
- Background atmosphere remains active when a foreground overlay is covered;
  menus do not fade all rendering layers away. Rest detection includes stacked effects.
- Public release signing removes debug entitlements, requires secure timestamps
  on both architectures, and verifies Apple's notarization and stapled tickets for
  the app and installer. Updates check Gatekeeper before closing the running app.

## 0.14.3 — Local conditions, smoother desktop motion

- The weather card includes feels-like temperature and the day's high/low. Choose
  Simple, Compact or Full menu-bar weather in Settings; all temperatures follow
  the selected units and Simple preserves the icon-only default.
- Quick customisation follows permissions: choose appearance, an accent colour,
  measurement units (including mixed combinations) and menu-bar style. Settings
  groups personalisation, desktop effects, privacy and app options clearly.
- Clouds retain their own opacity when combined with haze or fog; local visibility
  controls the low atmosphere without fading the sky. The mist veil applies its
  optical density once. Compact shows current temperature; Full shows feels-like
  temperature and condition beside the icon.
- The welcome forms gently with the intro audio's swell, using a shared scheduled
  start, slower text reveals and a steady settle without overshoot.
- Welcome startup, empty scenes and pause/wake clear through the native display
  clock, preventing an invisible running process before the menu icon appears.
- Weather warnings appear on the main Live weather page. Its icon and the menu-bar
  icon describe the actual scene, including fog and partly cloudy conditions.
- Local visibility controls fog under regional warnings: clear visibility means no
  fog, while the official warning remains prominent. Scheduled weather checks renew
  location every 15 minutes and keep the last successful scene until new data arrives.
- Open skies receive a lighter upper fog veil for a balanced desktop. Window glow
  follows the geometry used to composite screenshots, clearing obsolete footprints
  during minimisation and restoration.
- Reflections retain desktop scale, with screenshot content bounds cropped correctly
  and updated textures crossfading without changes in registration.
- Display-linked frame delivery keeps UI input independent of drawable waits. Static
  fog reuses its glow field, and redundant full-screen passes and window-system
  queries are removed while native refresh, appearance and interaction are retained.
- Liquid neighbour traversal reuses exact cell coordinates and skips already
  processed pairs, retaining identical particle physics. GPU contention skips
  work for frames that cannot be submitted instead of wasting simulation work.
- Quitting for a manual or automatic update fades the atmosphere out; relaunch fades
  it back in. Automatic updates remain silent and do not show setup.

## 0.14.2 — A clearer, lighter atmosphere

- See the combined atmosphere at a glance: the Live weather overview shows its
  weather, cloud, haze/fog, seasonal drift and wildlife layers together, without
  scrolling.
- All reported weather measurements now live on one details page, including wind
  direction, gusts and visibility, with clear labels for unavailable readings.
- Metric is the default; a Settings units choice converts all weather displays to
  Imperial without changing physics or saved atmospheres.
- Update checks always run periodically. The menu shows when Atmos last checked and
  whether it is current; an orange menu-bar dot marks available updates. Automatic
  Updates controls silent installation, independently of checking.
- Water reflections and fog bloom now use cached screenshots instead of continuous
  recording. Live geometry keeps movement smooth, 150 ms texture crossfades hide
  refreshes, and content updates are separated from display rendering. Low Power
  Mode lowers screenshot cadence/resolution and limits presentation to 60 Hz.
- Wind shelter, snow and botanical flight, pile transport, cursor collisions,
  buoyancy, wildlife motion and water splash calculations now share allocation-free
  Rust kernels. Window-top mouse splashes use half their previous impulse.
- The welcome entrance plays the supplied introduction audio once; ordinary launches
  without a welcome screen and silent background updates remain quiet.

## 0.14.1 — Your atmosphere, live skies and a native menu

- A compact custom menu brings visual controls, named atmosphere presets and quick
  switching. Weather, Drift, Wildlife and Advanced share one editor with a fixed
  Save button; presets include intensity, wind and cloud coverage.
- Native WeatherKit brings Apple Weather to everyone without personal keys, with a
  clearly labelled Open-Meteo fallback and reliable startup/wake recovery.
- Cloud coverage shapes the sky's occupied width; rainfall drives cloud depth and
  darkness. Precipitation enters from the screen top within cloud-covered areas.
  Visibility adds nuanced haze, and active weather warnings can strengthen scenes.
- Fog gains rolling banks and colour-aware bloom around windows, widgets and icons,
  with native occlusion that follows window animations and preserves desktop content.
- A refined welcome and permissions flow prepares weather before setup completes.
  GitHub updates support verified manual installation and optional silent updates.
- Atmospheres transition gently, bird flocks vary their visits, and permission and
  capture controls keep background activity tied to visible effects.

## 0.14.0 — A dynamic desktop atmosphere

- Live measurements continuously shape weather, with shared wind and shelter.
  Independent Weather, Seasonal Drift and Wildlife layers can mix and be deselected.
- Cherry blossoms, rose petals, dandelions, maple seeds and cottonwood join autumn
  leaves. Whole dandelions burst into seeds; birds, butterflies and fireflies visit
  in seasonal spells. Birds leave shaken windows; Halloween Snow was removed.
- Water responds to the cursor, rainfall, lightning and moving windows. Smooth blobs,
  strings, brief foam, floating material and overflowing puddles bring richer motion.
- Rust physics and GPU simulation reduce work while visible effects retain native
  refresh, including 120 Hz. Adaptive capture remains independent of rendering.

## 0.13.2 — A native macOS icon

- Canonical Icon Composer artwork and native assets give Atmos the correct macOS
  app icon, with legacy ICNS support for Apple silicon and Intel on macOS 14+.
