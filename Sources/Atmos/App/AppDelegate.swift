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
  private var halloween = false
  private var statusItem: NSStatusItem!
  private let snowfallSlider = SnowfallSlider()
  private var accumulateItem: NSMenuItem!
  private var meltItem: NSMenuItem!
  private var snowOnWindowsItem: NSMenuItem!
  private var clearItem: NSMenuItem!
  private var halloweenItem: NSMenuItem!
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
  private var halloweenTimer: Timer?
  private let weather = LiveWeather()
  private var scene: WeatherScene {
    weather.current.map(WeatherScene.init(weather:)) ?? WeatherScene(primary: Preferences.effect)
  }
  private var effect: WeatherEffect { scene.primary }
  private var effectiveIntensity: Snowfall {
    Preferences.liveWeather ? weather.current?.intensity ?? .light : snowfall
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
    snowfallHeld = !Preferences.welcomed
    syncScreens()
    guard !screens.isEmpty else {
      NSApp.terminate(nil)
      return
    }

    statusItem = makeStatusItem()
    weather.changed = { [weak self] in self?.applyWeather() }
    weather.setEnabled(Preferences.liveWeather)
    updateStatusIcon()
    refreshHalloween()
    updateActivity()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      self?.prepareReflectionsIfNeeded()
    }
    observeSystem()
    // A newly ordered overlay may report occluded until the first run-loop
    // commit. Recheck after installing observers so a missed initial event
    // cannot leave a visible scene paused at launch.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.updateActivity() }
    if snowfallHeld {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showWelcome() }
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
        snow.halloween = halloween
        snow.setScene(scene)
        snow.setIntensity(effectiveIntensity)
        snow.setWind(weather.current?.horizontalWind ?? 0)
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

  private func showWelcome() {
    let welcome = WelcomeController()
    welcome.scatter = { [weak self] pieces in
      guard let self, let first = pieces.first else { return }
      let point = CGPoint(x: CGFloat(first.position.x), y: CGFloat(first.position.y))
      guard let snow = screens.first(where: { $0.window.frame.contains(point) }) ?? screens.first
      else { return }
      let origin = SIMD2(Float(snow.window.frame.minX), Float(snow.window.frame.minY))
      snow.simulation.scatter(
        pieces.map { piece in
          var local = piece
          local.position -= origin
          return local
        })
    }
    welcome.skipped = { [weak self] in self?.releaseSnowfall() }
    welcome.finished = { [weak self] in
      Preferences.welcomed = true
      self?.welcome = nil
    }
    self.welcome = welcome
    welcome.show()
  }

  // MARK: - Menu

  private func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = Self.icon(halloween: false)

    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false

    liveItem = add("Live Weather", #selector(chooseLiveWeather), to: menu)
    liveItem.image = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
    liveItem.toolTip =
      "Blend effects to match current local conditions. Choose a scene to return to manual control."
    let modes = NSMenu()
    modes.autoenablesItems = false
    for (title, effects) in [
      ("Precipitation", [WeatherEffect.snow, .rain, .drizzle, .storm, .lightning, .sleet, .hail]),
      ("Atmosphere", [.mist, .clouds, .sunlight]), ("Nature", [.leaves, .fireflies]),
    ] {
      if !modes.items.isEmpty { modes.addItem(.separator()) }
      modes.addItem(.sectionHeader(title: title))
      for effect in effects {
        let option = add(effect.title, #selector(chooseMode), to: modes)
        option.representedObject = effect.rawValue
        option.image = NSImage(systemSymbolName: effect.symbol, accessibilityDescription: nil)
        effectItems[effect] = option
      }
    }
    modes.addItem(.separator())
    halloweenItem = add("Halloween Snow", #selector(toggleHalloween), to: modes)
    halloweenItem.image = NSImage(systemSymbolName: "moon.stars", accessibilityDescription: nil)
    sceneItem = menu.addItem(withTitle: "Scene", action: nil, keyEquivalent: "")
    sceneItem.submenu = modes
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
    menu.addItem(.separator())
    intensityHeader = .sectionHeader(title: "Intensity")
    menu.addItem(intensityHeader)
    snowfallSlider.changed = { [unowned self] in select($0) }
    let sliderItem = NSMenuItem()
    sliderItem.view = snowfallSlider
    menu.addItem(sliderItem)
    menu.addItem(.separator())
    let surfaces = NSMenu()
    surfaces.autoenablesItems = false
    accumulateItem = add("Accumulate", #selector(toggleAccumulate), to: surfaces)
    meltItem = add("Melt Snow", #selector(toggleMeltSnow), to: surfaces)
    snowOnWindowsItem = add("Snow on Windows", #selector(toggleSnowOnWindows), to: surfaces)
    surfaceItem = menu.addItem(withTitle: "Surfaces", action: nil, keyEquivalent: "")
    surfaceItem.submenu = surfaces
    clearItem = add("Clear Scene", #selector(clearSnow), to: menu)
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
    settings.addItem(withTitle: "Permissions & Activity", action: nil, keyEquivalent: "").submenu =
      permissions
    screenReflectionsToggle = add(
      "Screen Reflections", #selector(toggleScreenReflections), to: settings)
    screenReflectionsToggle.toolTip =
      "Use captured desktop content in water. Turn off to stop capture and reflect only the wallpaper."
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
    menu.addItem(withTitle: "Settings", action: nil, keyEquivalent: "").submenu = settings
    menu.addItem(.separator())
    let website = add("Explore grobb.dev ↗", #selector(openWebsite), to: menu)
    website.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
    menu.addItem(
      withTitle: "Quit Atmos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    item.menu = menu
    return item
  }

  @discardableResult
  private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    snowfallSlider.automatic = Preferences.liveWeather
    snowfallSlider.awaitingWeather = Preferences.liveWeather && weather.current == nil
    snowfallSlider.snowfall = effectiveIntensity
    intensityHeader.title = Preferences.liveWeather ? "Intensity · Automatic" : "Intensity"
    accumulateItem.state = accumulates ? .on : .off
    let effect = self.effect
    let autumn = effect == .leaves
    let water = effect.hasWater
    liveItem.state = Preferences.liveWeather ? .on : .off
    liveItem.title = Preferences.liveWeather ? "Live Weather: On" : "Live Weather: Off"
    for (mode, item) in effectItems {
      item.state = !Preferences.liveWeather && mode == effect ? .on : .off
    }
    sceneItem.title =
      Preferences.liveWeather ? "Choose a Manual Scene…" : "Manual Scene · \(effect.title)"
    weatherDetailsItem.title = Preferences.liveWeather ? "Local Weather · Live" : "Local Weather"
    weatherCard.update(weather: weather)
    weatherRefreshItem.isEnabled = Preferences.liveWeather
    weatherProviderItem.title = "\(weather.provider) ↗"
    weatherProviderItem.image = weather.provider == "Apple Weather" ? weather.attributionMark : nil
    weatherProviderItem.toolTip =
      Preferences.weatherSource == .automatic
      ? "Automatic prefers Apple Weather, with Open-Meteo as a fallback."
      : "Weather data attribution"
    for (source, item) in sourceItems {
      item.state = Preferences.weatherSource == source ? .on : .off
    }
    meltItem.title =
      effect.hasBanks
      ? (effect == .clouds ? "Dissipate Clouds" : "Dissipate Mist")
      : water ? "Evaporate Puddles" : autumn ? "Wither Leaves" : "Melt Snow"
    snowOnWindowsItem.title =
      effect.hasBanks
      ? (effect == .clouds ? "Clouds on Windows" : "Mist on Windows")
      : water
        ? "Rain on Windows"
        : autumn ? "Leaves on Windows" : effect == .hail ? "Hail on Windows" : "Snow on Windows"
    clearItem.title = "Clear Scene"
    surfaceItem.isHidden = !effect.canAccumulate && effect != .hail
    screenReflectionsToggle.state = Preferences.screenReflections ? .on : .off
    refreshPermissions()
    accumulateItem.title =
      effect.hasBanks
      ? (effect == .clouds ? "Form Cloud Banks" : "Form Mist Banks")
      : water ? "Form Puddles" : "Accumulate"
    accumulateItem.isEnabled = effect.canAccumulate
    accumulateItem.isHidden = !effect.canAccumulate
    meltItem.isHidden = !effect.canAccumulate
    snowOnWindowsItem.isHidden = !effect.canAccumulate && effect != .hail
    reflectionsItem.isHidden = false
    reflectionStatusItem.isHidden = false
    reflectionPermissionItem.isHidden = CGPreflightScreenCaptureAccess()
    reflectionStatusItem.title =
      screens.first(where: { $0.isCapturingReflections })?.reflectionStatus ?? screens.first?
      .reflectionStatus ?? "Wallpaper reflections"
    meltItem.state = thaws ? .on : .off
    meltItem.isEnabled = accumulates && effect.canAccumulate
    snowOnWindowsItem.state = snowOnWindows ? .on : .off
    snowOnWindowsItem.isEnabled = effect.canAccumulate || effect == .hail
    clearItem.isEnabled = screens.contains(where: { $0.hasContent })
    halloweenItem.state = Halloween.isWanted && effect == .snow ? .on : .off
    halloweenItem.isEnabled = true
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
  }

  private func select(_ snowfall: Snowfall) {
    guard !Preferences.liveWeather else { return }
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
    guard let raw = sender.representedObject as? String, let effect = WeatherEffect(rawValue: raw)
    else { return }
    Preferences.effect = effect
    Preferences.liveWeather = false
    weather.setEnabled(false)
    applyWeather()
  }

  @objc private func chooseLiveWeather() {
    Preferences.liveWeather.toggle()
    weather.setEnabled(Preferences.liveWeather)
    applyWeather()
  }

  private func applyWeather() {
    for snow in screens {
      snow.setScene(scene)
      snow.setIntensity(effectiveIntensity)
      snow.setWind(weather.current?.horizontalWind ?? 0)
    }
    updateStatusIcon()
    refreshHalloween()
    prepareReflectionsIfNeeded()
    statusItem?.button?.image =
      halloween
      ? Halloween.icon
      : NSImage(
        systemSymbolName: effect.symbol, accessibilityDescription: "Atmos — \(effect.title)")
    statusItem?.button?.toolTip =
      Preferences.liveWeather
      ? "Atmos · Live Weather On · \(weather.status)" : "Atmos · Manual · \(effect.title)"
  }

  @objc private func chooseWeatherSource(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let source = WeatherSource(rawValue: raw)
    else { return }
    weather.setSource(source)
  }

  @objc private func refreshWeather() { weather.refresh() }

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
    let granted = CGPreflightScreenCaptureAccess()
    permissionRequestItem.isHidden = granted
    let active = screens.contains { $0.isCapturingReflections }
    let stopped = screens.contains { $0.reflectionsStoppedByUser }
    let screen = PermissionPresentation.screen(
      granted: granted, enabled: Preferences.screenReflections, active: active, stopped: stopped)
    let location = PermissionPresentation.location(
      status: weather.locationAuthorization, enabled: weather.enabled, locating: weather.isLocating,
      paused: weather.isSuspended)
    let login = SMAppService.mainApp.status
    updatePermission(screenPermissionItem, title: "Screen Recording", state: screen)
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
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
  }

  @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

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
    guard statusItem != nil, effect.hasWater, screens.contains(where: { !$0.covered }),
      Preferences.reflectionConsentVersion < 2
    else { return }
    Preferences.reflectionConsentVersion = 2
    Preferences.screenReflections = true
    screens.forEach { $0.setReflections(true) }
    DispatchQueue.main.async { [weak self] in
      guard let self, effect.hasWater, !CGPreflightScreenCaptureAccess() else { return }
      NSApp.activate(ignoringOtherApps: true)
      _ = CGRequestScreenCaptureAccess()
      screens.forEach { $0.setReflections(Preferences.screenReflections) }
    }
  }

  @objc private func allowReflections() {
    recordReflectionChoice(true)
    NSApp.activate(ignoringOtherApps: true)
    if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess(),
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      NSWorkspace.shared.open(url)
    }
    screens.forEach { $0.setReflections(true) }
  }

  @objc private func selectWallpaperReflections() {
    recordReflectionChoice(false)
    screens.forEach { $0.setReflections(false) }
  }

  @objc private func selectSnapshotReflections() {
    Preferences.liveReflections = false
    recordReflectionChoice(true)
    if !CGPreflightScreenCaptureAccess() { allowReflections() }
    screens.forEach { $0.setReflections(true) }
  }

  @objc private func selectLiveReflections() {
    Preferences.liveReflections = true
    recordReflectionChoice(true)
    if !CGPreflightScreenCaptureAccess() { allowReflections() }
    screens.forEach { $0.setReflections(true) }
  }

  @objc private func toggleHalloween() {
    if effect != .snow {
      Preferences.effect = .snow
      Preferences.liveWeather = false
      weather.setEnabled(false)
      if !Halloween.isWanted { Halloween.toggle() }
      applyWeather()
    } else {
      Halloween.toggle()
      refreshHalloween()
    }
  }

  private func updateStatusIcon() {
    statusItem.button?.appearsDisabled = effectiveIntensity == .off
  }

  private static func icon(halloween: Bool) -> NSImage? {
    halloween
      ? Halloween.icon
      : NSImage(systemSymbolName: Preferences.effect.symbol, accessibilityDescription: "Atmos")
  }

  private func refreshHalloween() {
    guard (Halloween.isWanted && effect == .snow) != halloween else { return }
    halloween.toggle()
    statusItem.button?.image =
      halloween
      ? Halloween.icon : NSImage(systemSymbolName: effect.symbol, accessibilityDescription: "Atmos")
    for snow in screens { snow.halloween = halloween }
  }

  // MARK: - System

  private func observeSystem() {
    power.changed = { [unowned self] in screens.forEach { $0.apply(power.budget) } }
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()

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
    let awake = !screensAsleep && !screenLocked && !sessionInactive
    let visible = screens.contains { !$0.givesWay }
    weather.setSuspended(!awake || !visible)
    if awake && visible && statusItem != nil {
      prepareReflectionsIfNeeded()
      if halloweenTimer == nil {
        refreshHalloween()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
          self?.refreshHalloween()
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        halloweenTimer = timer
      }
    } else {
      halloweenTimer?.invalidate()
      halloweenTimer = nil
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
    halloweenTimer?.invalidate()
    screens.forEach { $0.close() }
  }
}
