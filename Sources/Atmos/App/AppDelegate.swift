import AppKit
import CoreLocation
import MetalKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var device: MTLDevice!
  private var screens: [ScreenSnow] = []
  private var snowfall = Snowfall.steady
  private var accumulates = true
  private var thaws = true
  private var snowOnWindows = true
  private var behindWindows = false
  private var snowfallHeld = false
  private var statusItem: NSStatusItem!
  private let snowfallSlider = SnowfallSlider()
  private let windSlider = WindSlider()
  private var windHeader: NSMenuItem!
  private var manualControlItems: [NSMenuItem] = []
  private var effectiveWind: Float { setupPending ? 0 : Preferences.liveWeather ? weather.current?.horizontalWind ?? 0 : Float(Preferences.manualWindSpeed)*2.4 }
  private var accumulateItem: NSMenuItem!
  private var meltItem: NSMenuItem!
  private var snowOnWindowsItem: NSMenuItem!
  private var clearItem: NSMenuItem!
  private var effectItems: [WeatherEffect: NSMenuItem] = [:]
  private var liveItem: NSMenuItem!
  private let weatherCard = WeatherMenuCard()
  private var sourceItems: [WeatherSource: NSMenuItem] = [:]
  private var sceneItem: NSMenuItem!
  private var intensityHeader: NSMenuItem!
  private var surfaceItem: NSMenuItem!
  private var waterReflectionMenuItem: NSMenuItem!
  private var weatherProviderItem: NSMenuItem!
  private var reflectionStatusItem: NSMenuItem!
  private var reflectionPermissionItem: NSMenuItem!
  private var weatherDetailsItem: NSMenuItem!
  private var weatherRefreshItem: NSMenuItem!
  private var reflectionsItem: NSMenuItem!
  private var snapshotReflectionsItem: NSMenuItem!
  private var liveReflectionsItem: NSMenuItem!
  private var behindWindowsItem: NSMenuItem!
  private var fullScreenItem: NSMenuItem!
  private var screenshotsItem: NSMenuItem!
  private var loginItem: NSMenuItem!
  private var screenReflectionsToggle: NSMenuItem!
  private var fogBloomItem: NSMenuItem!
  private var fogPermissionItem: NSMenuItem!
  private let updater = AppUpdater()
  private var updateItem: NSMenuItem!
  private var automaticUpdateItem: NSMenuItem!
  private var setupPending = false
  private var setupWeatherPreparing = false
  private var statusMenu: NSMenu?
  private var customMenu: AtmosMenuController?
  private var screenPermissionItem: NSMenuItem!
  private var locationPermissionItem: NSMenuItem!
  private var loginPermissionItem: NSMenuItem!
  private var permissionRequestItem: NSMenuItem!
  private var observers: [NSObjectProtocol] = []
  private var screensAsleep = false
  private var screenLocked = false
  private var sessionInactive = false
  private var welcome: WelcomeController?
  private let power = PowerMonitor()
  private var liveSceneTimer: Timer?
  private let weather: LiveWeather

  override convenience init() { self.init(weather: LiveWeather()) }
  init(weather: LiveWeather) {
    self.weather = weather
    super.init()
    weather.changed = { [weak self] in self?.applyWeather() }
    weather.failureLimitReached = { Preferences.liveWeather = false }
    ScreenRecordingAccess.shared.changed = { [weak self] in
      guard let self else { return }
      if ScreenRecordingAccess.shared.isGranted { screens.forEach { $0.refreshCapturePermission() } }
      if statusItem != nil { refreshCustomMenu() }
    }
  }
  private var scene: WeatherScene {
    if setupPending { return WeatherScene(primary: .none) }
    if Preferences.liveWeather {
      return weather.current.map { WeatherScene(weather: $0) } ?? WeatherScene(primary: .none)
    }
    return Preferences.manualScene
  }
  private var effect: WeatherEffect { scene.primary }
  private var statusEffect: WeatherEffect {
    effect == .none ? scene.stacked ?? scene.wildlife ?? .none : effect
  }
  private var effectiveIntensity: Snowfall {
    setupPending ? .off : Preferences.liveWeather ? weather.current?.intensity ?? .light : snowfall
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if AppMover.moveIfNeeded() {
      NSApp.terminate(nil)
      return
    }
    #if DEBUG
      DebugMetrics.start()
    #endif
    Preferences.registerDefaults()
    _ = SetupProgress.consumeAutomaticRelaunch()
    guard let device = MTLCreateSystemDefaultDevice() else {
      NSApp.terminate(nil)
      return
    }
    self.device = device
    snowfall = Preferences.snowfall
    accumulates = Preferences.accumulate
    thaws = Preferences.meltSnow
    snowOnWindows = Preferences.snowOnWindows
    behindWindows = Preferences.behindWindows
    setupPending = SetupProgress.needsPresentation()
    snowfallHeld = false
    syncScreens()
    guard !screens.isEmpty else {
      NSApp.terminate(nil)
      return
    }

    makeStatusItem()
    installCustomMenu()
    weather.requestsLocationAuthorization = weather.locationAuthorization != .notDetermined
    weather.setEnabled(!setupPending && Preferences.liveWeather)
    updateStatusIcon()
    updateActivity()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      self?.prepareReflectionsIfNeeded()
    }
    observeSystem()
    // A newly ordered overlay may report occluded until the first run-loop
    // commit. Recheck after installing observers so a missed initial event
    // cannot leave a visible scene paused at launch.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.updateActivity() }
    if setupPending {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showWelcome() }
    }
  }

  // MARK: - Displays

  /// One overlay per display: new displays get snow, removed ones lose theirs, the rest follow resolution changes.
  private func syncScreens() {
    let current = NSScreen.screens
    let ids = Set(current.compactMap(\.displayID))
    for gone in screens where !ids.contains(gone.displayID) { gone.close() }
    screens.removeAll { !ids.contains($0.displayID) }

    for screen in current {
      if let existing = screens.first(where: { $0.displayID == screen.displayID }) {
        existing.fit(to: screen)
      } else if let snow = ScreenSnow(
        screen: screen, device: device, snowOnWindows: { [unowned self] in snowOnWindows })
      {
        snow.simulation.snowfallHeld = snowfallHeld
        snow.simulation.snowfallReleased = { [weak self] in self?.releaseSnowfall() }
        snow.setScene(scene)
        snow.setIntensity(effectiveIntensity)
        snow.setWind(effectiveWind,automatic:Preferences.liveWeather)
        snow.activityChanged = { [weak self] in self?.updateActivity() }
        snow.apply(power.budget)
        screens.append(snow)
      }
    }
    updateActivity()
  }

  private func releaseSnowfall() {
    snowfallHeld = false
    for snow in screens { snow.simulation.snowfallHeld = false }
  }

  @objc private func showWelcome() {
    guard welcome == nil else { return }
    setupPending = true
    setupWeatherPreparing = false
    updateActivity()
    applyWeather()
    let welcome = WelcomeController()
    welcome.permissions = { [weak self] in self?.setupPermissions() ?? [] }
    welcome.requestPermission = { [weak self] kind in self?.requestSetupPermission(kind) }
    welcome.menuAnchor = { [weak self] in
      guard let button = self?.statusItem.button, let window = button.window else { return nil }
      return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    welcome.prepareWeather = { [weak self] in self?.prepareSetupWeather() }
    welcome.finished = { [weak self] completion in self?.finishSetup(completion) }
    self.welcome = welcome
    welcome.show()
  }

  func prepareSetupWeather() {
    guard setupPending else { return }
    let authorization = weather.locationAuthorization
    guard authorization == .authorized || authorization == .authorizedAlways else { return }
    setupWeatherPreparing = true
    updateActivity()
    weather.setEnabled(true)
  }

  func finishSetup(_ completion: SetupProgress.Completion) {
    SetupProgress.complete()
    Preferences.welcomed = true
    let authorization = weather.locationAuthorization
    Preferences.liveWeather = SetupProgress.liveWeather(after: completion, previous: Preferences.liveWeather,
      locationGranted: authorization == .authorized || authorization == .authorizedAlways)
    screens.forEach { $0.resumeAfterSetup() }
    setupPending = false
    setupWeatherPreparing = false
    welcome = nil
    // A prepared or in-flight request is preserved. The menu click activates
    // its data; it must not cancel it and start location lookup again.
    weather.setEnabled(Preferences.liveWeather)
    applyWeather()
    releaseSnowfall()
    updateActivity()
  }

  private func setupPermissions() -> [SetupPermission] {
    let location = weather.locationAuthorization
    let login = SMAppService.mainApp.status
    return [
      SetupPermission(kind: .location, title: "Location", detail: "Follow the weather where you are, automatically.",
        symbol: "location", action: location == .notDetermined ? "Allow" : "Settings…",
        granted: location == .authorized || location == .authorizedAlways),
      SetupPermission(kind: .screen, title: "Screen Recording",
        detail: "Desktop reflections and colour-matched fog bloom. Images stay on this Mac; no audio.",
        symbol: "rectangle.on.rectangle", action: "Allow", granted: ScreenRecordingAccess.shared.isGranted),
      SetupPermission(kind: .login, title: "Open at Login · Optional",
        detail: "A little atmosphere, ready whenever you sign in.", symbol: "arrow.right.circle",
        action: login == .requiresApproval ? "Settings…" : "Enable", granted: login == .enabled),
      SetupPermission(kind: .automaticUpdates, title: "Automatic Updates · Optional",
        detail: "Quietly check, install and reopen Atmos in the background. No update windows.",
        symbol: "arrow.triangle.2.circlepath", action: "Enable", granted: Preferences.automaticUpdates),
    ]
  }

  private func requestSetupPermission(_ kind: SetupPermission.Kind) {
    switch kind {
    case .location:
      if weather.locationAuthorization == .notDetermined {
        weather.requestLocationAccess()
      } else { openLocationSettings() }
    case .screen:
      if !ScreenRecordingAccess.shared.isGranted && !CGRequestScreenCaptureAccess() { openScreenRecordingSettings() }
      else { ScreenRecordingAccess.shared.recheck() }
      screens.forEach { $0.setReflections(Preferences.screenReflections); $0.setFogBloom(Preferences.fogBloom) }
    case .login:
      if SMAppService.mainApp.status == .requiresApproval { openLoginSettings() }
      else {
        do { try SMAppService.mainApp.register() }
        catch { openLoginSettings() }
      }
    case .automaticUpdates:
      Preferences.automaticUpdates = true
      updateActivity()
    }
  }

  // MARK: - Menu

  @discardableResult
  func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem = item
    item.button?.image = EffectArtwork.statusImage(for: statusEffect)
    item.button?.setAccessibilityLabel("Atmos")

    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false

    liveItem = add("Live Weather", #selector(chooseLiveWeather), to: menu)
    liveItem.image = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
    liveItem.toolTip =
      "Blend effects to match current local conditions. Choose a scene to return to manual control."
    let modes = NSMenu()
    modes.autoenablesItems = false
    modes.delegate = self
    for (title, effects) in [
      (
        "Weather",
        [
          WeatherEffect.snow, .rain, .drizzle, .storm, .lightning, .sleet, .hail, .mist, .clouds,
          .sunlight,
        ]
      ),
      ("Seasonal Drift", WeatherEffect.seasonal), ("Wildlife", WeatherEffect.wildlife),
    ] {
      if !modes.items.isEmpty { modes.addItem(.separator()) }
      modes.addItem(.sectionHeader(title: title))
      for effect in effects {
        let option = add(effect.title, #selector(chooseMode), to: modes)
        option.representedObject = effect.rawValue
        option.image = EffectArtwork.image(for: effect)
        effectItems[effect] = option
      }
    }
    sceneItem = menu.addItem(withTitle: "Manual Effects", action: nil, keyEquivalent: "")
    sceneItem.submenu = modes
    sceneItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
    let details = NSMenu()
    details.autoenablesItems = false
    details.delegate = self
    let summary = NSMenuItem()
    summary.view = weatherCard
    details.addItem(summary)
    details.addItem(.separator())
    weatherRefreshItem = add("Refresh Weather", #selector(refreshWeather), to: details)
    weatherRefreshItem.image = NSImage(
      systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
    let sources = NSMenu()
    sources.autoenablesItems = false
    for source in WeatherSource.allCases {
      let option = add(source.title, #selector(chooseWeatherSource), to: sources)
      option.representedObject = source.rawValue
      sourceItems[source] = option
    }
    details.addItem(withTitle: "Weather Source", action: nil, keyEquivalent: "").submenu = sources
    add("Location Settings…", #selector(openLocationSettings), to: details)
    details.addItem(.separator())
    weatherProviderItem = add(
      "Weather Data & Attribution…", #selector(openWeatherProvider), to: details)
    weatherDetailsItem = menu.addItem(withTitle: "Local Weather", action: nil, keyEquivalent: "")
    weatherDetailsItem.image = NSImage(systemSymbolName: "cloud.sun", accessibilityDescription: nil)
    weatherDetailsItem.submenu = details
    modes.addItem(.separator())
    intensityHeader = .sectionHeader(title: "Intensity")
    modes.addItem(intensityHeader)
    manualControlItems.append(intensityHeader)
    snowfallSlider.changed = { [unowned self] in select($0) }
    let sliderItem = NSMenuItem()
    sliderItem.view = snowfallSlider
    modes.addItem(sliderItem)
    manualControlItems.append(sliderItem)
    windHeader = .sectionHeader(title:"Wind Speed")
    modes.addItem(windHeader)
    manualControlItems.append(windHeader)
    windSlider.changed = { [unowned self] speed in
      guard !setupPending && !Preferences.liveWeather else {return}
      Preferences.manualWindSpeed=speed
      screens.forEach {$0.setWind(effectiveWind,automatic:Preferences.liveWeather)}
    }
    let windItem=NSMenuItem();windItem.view=windSlider;modes.addItem(windItem)
    manualControlItems.append(windItem)
    modes.addItem(.separator())
    let surfaces = NSMenu()
    surfaces.autoenablesItems = false
    accumulateItem = add("Accumulate", #selector(toggleAccumulate), to: surfaces)
    meltItem = add("Melt Snow", #selector(toggleMeltSnow), to: surfaces)
    snowOnWindowsItem = add("Snow on Windows", #selector(toggleSnowOnWindows), to: surfaces)
    surfaceItem = NSMenuItem(title: "Surfaces", action: nil, keyEquivalent: "")
    surfaceItem.submenu = surfaces
    clearItem = add("Clear Scene", #selector(clearSnow), to: modes)
    clearItem.image = NSImage(systemSymbolName: "wind", accessibilityDescription: nil)
    let reflections = NSMenu()
    reflections.autoenablesItems = false
    reflectionsItem = add("Wallpaper Only", #selector(selectWallpaperReflections), to: reflections)
    reflectionsItem.toolTip = "Reflect the wallpaper without capturing other applications."
    snapshotReflectionsItem = add(
      "Window Snapshots", #selector(selectSnapshotReflections), to: reflections)
    snapshotReflectionsItem.toolTip =
      "Cached window images follow window movement smoothly. Content refreshes once a second; no continuous screen recording."
    liveReflectionsItem = add("Live Desktop", #selector(selectLiveReflections), to: reflections)
    liveReflectionsItem.toolTip =
      "Reflect videos and all desktop animation at the display refresh rate. Uses more energy."
    reflections.addItem(.separator())
    reflectionPermissionItem = add(
      "Allow Screen Recording…", #selector(allowReflections), to: reflections)
    reflectionStatusItem = reflections.addItem(
      withTitle: "Wallpaper reflections", action: nil, keyEquivalent: "")
    reflectionStatusItem.isEnabled = false
    let settings = NSMenu()
    settings.autoenablesItems = false
    settings.delegate = self
    settings.addItem(surfaceItem)
    settings.addItem(.separator())
    let permissions = NSMenu()
    permissions.autoenablesItems = false
    permissions.delegate = self
    screenPermissionItem = add(
      "Screen Recording", #selector(openScreenRecordingSettings), to: permissions)
    locationPermissionItem = add(
      "Location Services", #selector(openLocationSettings), to: permissions)
    loginPermissionItem = add("Open at Login", #selector(openLoginSettings), to: permissions)
    permissions.addItem(.separator())
    permissionRequestItem = add(
      "Allow Screen Recording…", #selector(allowReflections), to: permissions)
    add("Recheck Screen Recording", #selector(recheckScreenRecording), to: permissions)
    add("Restart Atmos…", #selector(restartAtmos), to: permissions)
    settings.addItem(withTitle: "Permissions & Activity", action: nil, keyEquivalent: "").submenu =
      permissions
    screenReflectionsToggle = add(
      "Screen Reflections", #selector(toggleScreenReflections), to: settings)
    screenReflectionsToggle.toolTip =
      "Use captured desktop content in water. Fog Bloom has its own capture control."
    fogBloomItem = add("Fog Bloom", #selector(toggleFogBloom), to: settings)
    fogBloomItem.toolTip = "Scatter the colours of windows, desktop icons and effects through visible fog. Uses Screen Recording."
    fogPermissionItem = add("Allow Fog Bloom…", #selector(allowFogBloom), to: settings)
    waterReflectionMenuItem = settings.addItem(
      withTitle: "Water Reflection Source", action: nil, keyEquivalent: "")
    waterReflectionMenuItem.submenu = reflections
    reflections.delegate = self
    settings.addItem(.separator())
    behindWindowsItem = add("Always Behind Windows", #selector(toggleBehindWindows), to: settings)
    behindWindowsItem.toolTip =
      "Top-edge windows cover their own particles. At 70% screen coverage, all effects move behind windows."
    fullScreenItem = add("Show over Full Screen", #selector(toggleFullScreen), to: settings)
    screenshotsItem = add("Include in Screenshots", #selector(toggleScreenshots), to: settings)
    settings.addItem(.separator())
    loginItem = add("Open at Login", #selector(toggleOpenAtLogin), to: settings)
    automaticUpdateItem = add("Automatic Updates", #selector(toggleAutomaticUpdates), to: settings)
    add("Show Setup…", #selector(showWelcome), to: settings)
    menu.addItem(withTitle: "Settings", action: nil, keyEquivalent: "").submenu = settings
    menu.addItem(.separator())
    updateItem = add("Check for Updates…", #selector(checkForUpdates), to: menu)
    updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
    updater.changed = { [weak self] in
      self?.updateItem.title = self?.updater.menuTitle ?? "Check for Updates…"
      self?.refreshCustomMenu()
    }
    menu.addItem(.separator())
    let website = add("Explore grobb.dev ↗", #selector(openWebsite), to: settings)
    website.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
    menu.addItem(
      withTitle: "Quit Atmos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    item.menu = menu
    statusMenu = menu
    return item
  }

  @discardableResult
  func installCustomMenu() -> AtmosMenuController? {
    guard let menu = statusMenu else { return nil }
    let controller = AtmosMenuController(menu: menu)
    customMenu = controller
    statusItem.menu = nil
    statusItem.button?.target = self
    statusItem.button?.action = #selector(toggleCustomMenu)
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    controller.model.invoke = { [weak self] item in
      guard let self, item.isEnabled, let action = item.action else { return }
      let keepsOpen = ["chooseLiveWeather", "chooseMode:", "chooseWeatherSource:", "refreshWeather",
        "toggleAccumulate", "toggleMeltSnow", "toggleSnowOnWindows", "clearSnow", "toggleFogBloom",
        "toggleScreenReflections", "toggleBehindWindows", "toggleFullScreen", "toggleScreenshots",
        "toggleOpenAtLogin", "toggleAutomaticUpdates", "selectWallpaperReflections",
        "selectSnapshotReflections", "selectLiveReflections"].contains(NSStringFromSelector(action))
      let permissionAction = ["toggleFogBloom", "toggleScreenReflections", "selectSnapshotReflections", "selectLiveReflections"].contains(NSStringFromSelector(action)) && !ScreenRecordingAccess.shared.isGranted
      let locationAction = NSStringFromSelector(action) == "chooseLiveWeather" && !Preferences.liveWeather && weather.locationAuthorization == .notDetermined
      if !keepsOpen || permissionAction || locationAction { self.customMenu?.close() }
      NSApp.sendAction(action, to: item.target, from: item)
      self.refreshCustomMenu()
    }
    controller.model.intensityChanged = { [weak self] in self?.select($0); self?.refreshCustomMenu() }
    controller.model.selectPreset = { [weak self] preset in self?.activatePreset(preset) }
    controller.model.beginNewPreset = { [weak self] in self?.beginNewAtmosphere() }
    controller.model.cloudCoverageChanged = { [weak self] cover in
      guard let self, !setupPending, !Preferences.liveWeather else { return }
      Preferences.manualCloudCoverage = cover
      applyWeather()
    }
    controller.model.windChanged = { [weak self] speed in
      guard let self, !setupPending, !Preferences.liveWeather else { return }
      Preferences.manualWindSpeed = speed
      screens.forEach { $0.setWind(self.effectiveWind, automatic: false) }
      refreshCustomMenu()
    }
    return controller
  }

  func activatePreset(_ preset: AtmospherePreset) {
    guard !setupPending, preset.isValid else { return }
    Preferences.liveWeather = false
    Preferences.manualScene = preset.scene
    snowfall = Snowfall(rawValue: preset.intensity) ?? .steady
    Preferences.snowfall = snowfall
    Preferences.manualWindSpeed = preset.wind
    AtmosphereLibrary.shared.selectedID = preset.id
    AtmosphereLibrary.shared.name = preset.name
    weather.setEnabled(false)
    applyWeather()
  }
  func beginNewAtmosphere() {
    guard !setupPending else { return }
    Preferences.liveWeather = false
    Preferences.manualScene = WeatherScene(primary: .none)
    Preferences.manualWindSpeed = 4
    snowfall = .steady; Preferences.snowfall = .steady
    weather.setEnabled(false)
    applyWeather()
  }

  @objc private func toggleCustomMenu() {
    guard let customMenu, let menu = statusMenu, let button = statusItem.button else { return }
    if customMenu.isShown { customMenu.close(); return }
    if Date().timeIntervalSince(customMenu.lastClosed) < 0.18 { return }
    let captureAccess = ScreenRecordingAccess.shared
    if captureAccess.returningFromSettings {
      captureAccess.returningFromSettings = false
      captureAccess.recheck()
    }
    welcome?.menuOpened()
    menuNeedsUpdate(menu)
    customMenu.model.refresh(weather: weather)
    customMenu.show(from: button)
  }

  private func refreshCustomMenu() {
    guard let customMenu, customMenu.isShown, let menu = statusMenu else { return }
    menuNeedsUpdate(menu)
    customMenu.model.refresh(weather: weather)
  }

  @discardableResult
  private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func updateWeatherControls() {
    snowfallSlider.automatic = setupPending || Preferences.liveWeather
    snowfallSlider.awaitingWeather = !setupPending && Preferences.liveWeather && weather.current == nil
    snowfallSlider.snowfall = effectiveIntensity
    intensityHeader.title = setupPending ? "Paused for Setup" : Preferences.liveWeather ? "Intensity · Automatic" : "Intensity"
    windSlider.automatic=setupPending || Preferences.liveWeather
    windSlider.awaitingWeather = !setupPending && Preferences.liveWeather && weather.current == nil
    windSlider.speed = setupPending ? 0 : Preferences.liveWeather ? weather.current?.windSpeed ?? 0 : Preferences.manualWindSpeed
    for item in manualControlItems { item.isHidden = Preferences.liveWeather || setupPending }
    windHeader.title = setupPending ? "Wind Speed · Paused" : Preferences.liveWeather ? "Wind Speed · Automatic":"Wind Speed"
  }

  private func updateLiveWeatherMenu() {
    let scene = self.scene, effect = scene.primary
    liveItem.state = !setupPending && Preferences.liveWeather ? .on : .off
    liveItem.isEnabled = !setupPending
    sceneItem.isEnabled = !setupPending
    liveItem.title = setupPending ? "Live Weather · Paused for Setup" : Preferences.liveWeather ? "Live Weather: On" : "Live Weather: Off"
    for (mode, item) in effectItems {
      item.state =
        !Preferences.liveWeather
          && (mode == effect || mode == scene.stacked || mode == scene.wildlife) ? .on : .off
    }
    sceneItem.title =
      setupPending ? "Manual Effects · Paused for Setup" : "Manual Effects"
    weatherDetailsItem.title = Preferences.liveWeather ? "Local Weather · Live" : "Local Weather"
    weatherCard.update(weather: weather)
    weatherRefreshItem.isEnabled = !setupPending && Preferences.liveWeather
    weatherProviderItem.title = "\(weather.provider) ↗"
    weatherProviderItem.image = weather.provider == "Apple Weather" ? weather.attributionMark : nil
    weatherProviderItem.toolTip =
      Preferences.weatherSource == .automatic
      ? "Automatic prefers Apple Weather, with Open-Meteo as a fallback."
      : "Weather data attribution"
    for (source, item) in sourceItems {
      item.state = Preferences.weatherSource == source ? .on : .off
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    if menu === statusItem.menu { welcome?.menuOpened(); menuNeedsUpdate(menu) }
    updateWeatherControls()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    updateItem.isEnabled = !setupPending
    updateWeatherControls()
    accumulateItem.state = accumulates ? .on : .off
    let effect = self.effect
    let autumn = scene.stacked != nil
    let accumulating = effect.canAccumulate || autumn
    let water = effect.hasWater
    updateLiveWeatherMenu()
    meltItem.title =
      effect.hasBanks
      ? (effect == .clouds ? "Dissipate Clouds" : "Dissipate Mist")
      : water ? "Evaporate Puddles" : autumn ? "Fade Seasonal Drift" : "Melt Snow"
    snowOnWindowsItem.title =
      effect.hasBanks
      ? (effect == .clouds ? "Clouds on Windows" : "Mist on Windows")
      : water
        ? "Rain on Windows"
        : autumn ? "Drift on Windows" : effect == .hail ? "Hail on Windows" : "Snow on Windows"
    clearItem.title = "Clear Scene"
    surfaceItem.isHidden = !accumulating && effect != .hail
    screenReflectionsToggle.state = Preferences.screenReflections ? .on : .off
    fogBloomItem.state = Preferences.fogBloom ? .on : .off
    fogPermissionItem.isHidden = !Preferences.fogBloom || ScreenRecordingAccess.shared.isGranted
    refreshPermissions()
    accumulateItem.title =
      effect.hasBanks
      ? (effect == .clouds ? "Form Cloud Banks" : "Form Mist Banks")
      : water ? "Form Puddles" : "Accumulate"
    accumulateItem.isEnabled = accumulating
    accumulateItem.isHidden = !accumulating
    meltItem.isHidden = !accumulating
    snowOnWindowsItem.isHidden = !accumulating && effect != .hail
    reflectionsItem.isHidden = false
    reflectionStatusItem.isHidden = false
    reflectionPermissionItem.isHidden = ScreenRecordingAccess.shared.isGranted
    reflectionStatusItem.title =
      screens.first(where: { $0.isCapturingReflections })?.reflectionStatus ?? screens.first?
      .reflectionStatus ?? "Wallpaper reflections"
    meltItem.state = thaws ? .on : .off
    meltItem.isEnabled = accumulates && accumulating
    snowOnWindowsItem.state = snowOnWindows ? .on : .off
    snowOnWindowsItem.isEnabled = accumulating || effect == .hail
    clearItem.isEnabled = !setupPending && screens.contains(where: { $0.hasContent })
    surfaceItem.isEnabled = !setupPending
    reflectionsItem.state = Preferences.screenReflections ? .off : .on
    reflectionsItem.isEnabled = true
    snapshotReflectionsItem.state =
      Preferences.screenReflections && !Preferences.liveReflections ? .on : .off
    liveReflectionsItem.state =
      Preferences.screenReflections && Preferences.liveReflections ? .on : .off
    behindWindowsItem.state = behindWindows ? .on : .off
    fullScreenItem.state = Preferences.showOverFullScreen ? .on : .off
    fullScreenItem.isEnabled = !behindWindows
    screenshotsItem.state = Preferences.showInScreenshots ? .on : .off
    loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    automaticUpdateItem.state = Preferences.automaticUpdates ? .on : .off
  }

  private func select(_ snowfall: Snowfall) {
    guard !setupPending && !Preferences.liveWeather else { return }
    self.snowfall = snowfall
    Preferences.snowfall = snowfall
    for snow in screens { snow.setIntensity(snowfall) }
    updateStatusIcon()
  }

  @objc private func toggleAccumulate() {
    accumulates.toggle()
    Preferences.accumulate = accumulates
    for snow in screens { snow.setAccumulation(accumulates) }
  }

  @objc private func toggleMeltSnow() {
    thaws.toggle()
    Preferences.meltSnow = thaws
    for snow in screens { snow.setEvaporation(thaws) }
  }

  @objc private func toggleSnowOnWindows() {
    snowOnWindows.toggle()
    Preferences.snowOnWindows = snowOnWindows
    if !snowOnWindows { screens.forEach { $0.dropWindowSnow() } }
  }

  @objc private func clearSnow() {
    let direction = screens.first?.simulation.breezeDirection ?? -1
    let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for snow in screens { snow.clear(direction: direction, calm: calm) }
  }

  @objc private func toggleBehindWindows() {
    behindWindows.toggle()
    Preferences.behindWindows = behindWindows
    for snow in screens { snow.setBehindWindows(behindWindows) }
  }

  @objc private func toggleFullScreen() {
    Preferences.showOverFullScreen.toggle()
    for snow in screens { snow.overFullScreen = Preferences.showOverFullScreen }
  }

  @objc private func toggleScreenshots() {
    Preferences.showInScreenshots.toggle()
    for snow in screens {
      snow.window.showsInScreenshots = Preferences.showInScreenshots
      snow.dock.window.showsInScreenshots = Preferences.showInScreenshots
      snow.backgroundFog.window.showsInScreenshots = Preferences.showInScreenshots
    }
  }

  @objc private func toggleOpenAtLogin() {
    let service = SMAppService.mainApp
    do {
      if service.status == .enabled {
        try service.unregister()
      } else {
        try service.register()
      }
    } catch {
      NSLog("Atmos: login item change failed: \(error)")
    }
  }

  @objc private func chooseMode(_ sender: NSMenuItem) {
    guard !setupPending else { return }
    guard let raw = sender.representedObject as? String, let effect = WeatherEffect(rawValue: raw)
    else { return }
    var selection = Preferences.manualScene
    selection.toggleManual(effect)
    if !effect.isStacked {
      let cover = selection.primary == .none ? 0 : effect.defaultCloudCoverage
      selection.manualCloudCover = Float(cover / 100); selection.clouds = Float(cover / 100)
    }
    Preferences.manualScene = selection
    Preferences.liveWeather = false
    weather.setEnabled(false)
    applyWeather()
  }

  @objc private func chooseLiveWeather() {
    guard !setupPending else { return }
    weather.requestsLocationAuthorization = true
    Preferences.liveWeather.toggle()
    weather.setEnabled(Preferences.liveWeather)
    applyWeather()
  }

  private func applyWeather() {
    // A custom menu view can survive multiple tracking sessions. Restore its
    // controls immediately, even when AppKit does not request a menu update.
    if statusItem != nil { updateWeatherControls(); updateLiveWeatherMenu() }
    refreshCustomMenu()
    let scene = self.scene
    for snow in screens {
      snow.setScene(scene)
      snow.setIntensity(effectiveIntensity)
      snow.setWind(effectiveWind,automatic:Preferences.liveWeather)
    }
    updateStatusIcon()
    prepareReflectionsIfNeeded()
    statusItem?.button?.image = EffectArtwork.statusImage(for: statusEffect)
    statusItem?.button?.setAccessibilityLabel("Atmos — \(scene.summary)")
    statusItem?.button?.toolTip =
      Preferences.liveWeather
      ? "Atmos · Live Weather On · \(weather.status)" : "Atmos · Manual · \(scene.summary)"
  }

  @objc private func chooseWeatherSource(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let source = WeatherSource(rawValue: raw)
    else { return }
    weather.setSource(source)
  }

  @objc private func refreshWeather() {
    weather.requestsLocationAuthorization = true
    weather.refresh(force: true)
  }

  @objc private func checkForUpdates() { updater.check() }
  @objc private func toggleAutomaticUpdates() {
    Preferences.automaticUpdates.toggle()
    updateActivity()
  }

  @objc private func openLocationSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
    {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func openWeatherProvider() {
    NSWorkspace.shared.open(weather.providerURL)
  }

  @objc private func openWebsite() {
    NSWorkspace.shared.open(URL(string: "https://grobb.dev/projects/atmos")!)
  }

  private func refreshPermissions() {
    let granted = ScreenRecordingAccess.shared.isGranted
    permissionRequestItem.isHidden = granted
    let active = screens.contains { $0.isCapturingReflections }
    let stopped = screens.contains { $0.reflectionsStoppedByUser }
    let screen = PermissionPresentation.screen(
      granted: granted, enabled: Preferences.screenReflections || Preferences.fogBloom, active: active, stopped: stopped)
    let location = PermissionPresentation.location(
      status: weather.locationAuthorization, enabled: weather.enabled, locating: weather.isLocating,
      paused: weather.isSuspended)
    let login = SMAppService.mainApp.status
    if ScreenRecordingAccess.shared.state == .checking {
      screenPermissionItem.title = "Screen Recording · Checking…"
    } else { updatePermission(screenPermissionItem, title: "Screen Recording", state: screen) }
    updatePermission(locationPermissionItem, title: "Location Services", state: location)
    updatePermission(
      loginPermissionItem, title: "Open at Login",
      state: PermissionPresentation(
        status: login == .enabled
          ? "Enabled" : login == .requiresApproval ? "Approval needed" : "Off",
        detail: "Manage background login access in System Settings.", granted: login == .enabled))
  }

  private func updatePermission(_ item: NSMenuItem, title: String, state: PermissionPresentation) {
    item.title = "\(title) · \(state.status)"
    item.image = NSImage(
      systemSymbolName: state.granted ? "checkmark.circle" : "exclamationmark.circle",
      accessibilityDescription: nil)
    if #available(macOS 14.4, *) { item.subtitle = state.detail }
    item.toolTip = state.detail
  }

  @objc private func openScreenRecordingSettings() {
    ScreenRecordingAccess.shared.returningFromSettings = true
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
  }

  @objc private func recheckScreenRecording() { ScreenRecordingAccess.shared.recheck() }

  @objc private func restartAtmos() {
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = ["-c", "attempt=0; while /bin/kill -0 \"$1\" 2>/dev/null; do attempt=$((attempt+1)); [ \"$attempt\" -lt 300 ] || exit 1; /bin/sleep 0.1; done; /usr/bin/open -n \"$2\"", "atmos-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
    helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
    do { try helper.run(); NSApp.terminate(nil) }
    catch { NSSound.beep() }
  }

  @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

  @objc private func toggleFogBloom() {
    Preferences.fogBloom.toggle()
    if Preferences.fogBloom && !ScreenRecordingAccess.shared.isGranted {
      requestSetupPermission(.screen)
    }
    screens.forEach { $0.setFogBloom(Preferences.fogBloom) }
  }
  @objc private func allowFogBloom() {
    requestSetupPermission(.screen)
    screens.forEach { $0.setFogBloom(Preferences.fogBloom) }
  }

  @objc private func toggleScreenReflections() {
    if Preferences.screenReflections {
      selectWallpaperReflections()
    } else if Preferences.liveReflections {
      selectLiveReflections()
    } else {
      selectSnapshotReflections()
    }
  }

  private func recordReflectionChoice(_ enabled: Bool) {
    Preferences.reflectionConsentVersion = 2
    Preferences.reflectionConsentIdentity = Bundle.main.bundleIdentifier ?? "dev.grobb.Atmos"
    Preferences.screenReflections = enabled
  }

  private func prepareReflectionsIfNeeded() {
    // Screen Recording grants belong to the bundle identity, rather than migrated preferences.
    let identity = Bundle.main.bundleIdentifier ?? "dev.grobb.Atmos"
    if Preferences.reflectionConsentIdentity != identity {
      Preferences.reflectionConsentVersion = 0
      Preferences.reflectionConsentIdentity = identity
    }
    guard !setupPending, ScreenRecordingAccess.shared.isGranted,
      statusItem != nil, effect.hasWater, screens.contains(where: { !$0.covered }),
      Preferences.reflectionConsentVersion < 2
    else { return }
    Preferences.reflectionConsentVersion = 2
    Preferences.screenReflections = true
    screens.forEach { $0.setReflections(true) }

  }

  @objc private func allowReflections() {
    recordReflectionChoice(true)
    NSApp.activate(ignoringOtherApps: true)
    if !ScreenRecordingAccess.shared.isGranted && !CGRequestScreenCaptureAccess(),
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      ScreenRecordingAccess.shared.returningFromSettings = true
      NSWorkspace.shared.open(url)
    } else { ScreenRecordingAccess.shared.recheck() }
    screens.forEach { $0.setReflections(true) }
  }

  @objc private func selectWallpaperReflections() {
    recordReflectionChoice(false)
    screens.forEach { $0.setReflections(false) }
  }

  @objc private func selectSnapshotReflections() {
    Preferences.liveReflections = false
    recordReflectionChoice(true)
    if !ScreenRecordingAccess.shared.isGranted { allowReflections() }
    screens.forEach { $0.setReflections(true) }
  }

  @objc private func selectLiveReflections() {
    Preferences.liveReflections = true
    recordReflectionChoice(true)
    if !ScreenRecordingAccess.shared.isGranted { allowReflections() }
    screens.forEach { $0.setReflections(true) }
  }

  private func updateStatusIcon() {
    statusItem.button?.appearsDisabled = effectiveIntensity == .off
  }

  // MARK: - System

  private func observeSystem() {
    power.changed = { [unowned self] in screens.forEach { $0.apply(power.budget) } }
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()
    observe(.default, NSApplication.didBecomeActiveNotification) { _ in
      let access = ScreenRecordingAccess.shared
      if access.returningFromSettings { access.returningFromSettings = false; access.recheck() }
    }

    observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
    observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
    observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
    observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) {
      $0.sessionInactive = false
    }
    observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
    observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) {
      $0.screenLocked = false
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: WindowChanges.notification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.screens.forEach { $0.windowGeometryChanged() }
      })
    observe(.default, NSWindow.didChangeOcclusionStateNotification) { _ in }
    observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.syncScreens() }
    observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) {
      $0.screens.forEach { $0.spaceChanged() }
    }
    observe(workspace, NSWorkspace.didActivateApplicationNotification) {
      $0.screens.forEach { $0.watchWindows() }
    }
    observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
      $0.screens.forEach { $0.accessibilityChanged() }
    }
  }

  private func observe(
    _ center: NotificationCenter,
    _ name: Notification.Name,
    object: AnyObject? = nil,
    _ change: @escaping (AppDelegate) -> Void
  ) {
    observers.append(
      center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        guard let self else { return }
        change(self)
        self.updateActivity()
      })
  }

  private func updateActivity() {
    let awake = !setupPending && !screensAsleep && !screenLocked && !sessionInactive
    let visible = screens.contains { !$0.givesWay }
    updater.setAutomaticActivity(enabled: Preferences.automaticUpdates, active: awake)
    let preparing = setupPending && setupWeatherPreparing && !screensAsleep && !screenLocked && !sessionInactive
    // Fullscreen pauses effects, not the weather card or an explicitly started
    // setup fetch. Location/networking stop for lock, sleep and earlier setup pages.
    weather.setSuspended(!(awake || preparing))
    if awake && visible && statusItem != nil {
      prepareReflectionsIfNeeded()
      if liveSceneTimer == nil {
        let timer = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
          guard let self else { return }
          if weather.current != nil { applyWeather() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        liveSceneTimer = timer
      }
    } else {
      liveSceneTimer?.invalidate()
      liveSceneTimer = nil
    }
    for snow in screens {
      snow.occlusionChanged()
      let plan = DisplayActivity(
        awake: awake, fullScreen: snow.covered,
        visible: snow.window.occlusionState.contains(.visible), fading: snow.fading)
      snow.setActive(plan.renders, asleep: !awake)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    weather.stop()
    liveSceneTimer?.invalidate()
    screens.forEach { $0.close() }
  }
}
