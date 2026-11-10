import AppKit
import MetalKit

/// The snow on one display: its overlay window, simulation and renderer, the windows tracked on it and its light.
final class ScreenSnow {
  let displayID: CGDirectDisplayID
  let window: OverlayWindow
  let dock: DockOverlay
  let backgroundFog: DockOverlay
  private var panelFrames: [CGRect] = []
  var simulation: SnowSimulation { renderer.simulation }
  private let view: MTKView
  private var frameClock: NativeFrameClock?
  private var renderingPaused: Bool {
    get { frameClock?.isPaused ?? view.isPaused }
    set { if let frameClock { frameClock.isPaused = newValue } else { view.isPaused = newValue } }
  }
  private var exiting = false
  private let renderer: Renderer
  private let reflection: ScreenReflection
  private var placementTimer: Timer?
  private var coveredGeometryCheck: CFTimeInterval = -1
  private var automaticallyBehind = false
  private var presentationTransition = false
  private let occlusionMask = WindowOcclusionMask()
  private var topWindowIDs = Set<CGWindowID>()
  private var effect = WeatherEffect.snow
  private var appliedScene: WeatherScene?
  private var appliedIntensity: Snowfall?
  private let tracker = WindowTracker()
  private var geometryRevision: UInt64 = .max
  private let light = SceneLight()
  private(set) var screen: NSScreen
  /// Awake and showing; at rest with nothing to draw, the view may still be paused.
  private var active = true
  /// An app in full screen on this display: the snow fades out of its way and waits until it goes.
  private(set) var covered = false
  /// A full-screen app's Space is the current one here, though Mission Control may still show over it.
  private var fullScreenCurrent = false
  /// The snow stays over full-screen apps instead of fading out of their way.
  var overFullScreen = false {
    didSet {
      guard overFullScreen != oldValue else { return }
      following = false
      arriving = false
      goneFullScreenAt = -10
      fullScreenSpaces = nil
      updatePlacement()
      checkCovered()
      activityChanged()
    }
  }
  /// Mission Control shows over a full-screen app's Space, picked in it or opened from it: the snow stays until
  /// the app fills the screen.
  private var exposed = false
  private var exposedSeenAt: CFTimeInterval = 0
  /// Mission Control can drop out of the window list for a moment as it moves to a full-screen app's Space: the
  /// app covers the snow only once Mission Control has stayed away a little while.
  private var coverAfter: CFTimeInterval = 0
  /// Swiped away from the full-screen app, its Space still current while the desktop slides back in.
  private var leaving = false
  /// An app here going full screen, its Space about to slide in.
  private var arriving = false
  /// The full-screen apps' Spaces on this display at the last look.
  private var fullScreenSpaces: Set<UInt64>?
  private var spacesSeenAt: CFTimeInterval = 0
  /// When an app here last went full screen: its Space is added as the move starts, and is current only once it's in.
  private var goneFullScreenAt: CFTimeInterval = -10
  /// How much of the screen a full-screen app's Space covers as it slides, as seen without the windows tracked.
  private var untrackedShare: CGFloat = 0
  private var shareSeenAt: CFTimeInterval = 0
  /// Hidden by the window server, as while an app goes full screen.
  private var occluded = false
  /// What the overlays were last faded to; nil while they follow a slide.
  private var alphaTarget: CGFloat? = 1
  /// Following a slide between a desktop and a full-screen app: how much of the snow shows, and how much it's
  /// heading for.
  private var following = false
  private var slideAlpha: CGFloat = 1
  private var slideGoal: CGFloat = 1
  private var slideFrameAt: CFTimeInterval = 0
  /// Looks for the desktop sliding back in while a full-screen app hides the snow.
  private let snowOnWindows: () -> Bool
  private var asleep = false
  /// Asks for the snow to be woken or put to rest again.
  var activityChanged: () -> Void = {}
  /// Faded all the way out for a full-screen app: the snow keeps falling until then.
  private var gone = false
  private var fadeEndsAt: CFTimeInterval = 0
  /// Hidden for a full-screen app: nothing to draw.
  var givesWay: Bool { covered && !leaving && gone }
  /// Fading in or out: still drawn, though the window server may already count the overlay as hidden, as while a
  /// full-screen app picked in Mission Control zooms in.
  var fading: Bool { CACurrentMediaTime() < fadeEndsAt }
  /// The quickest the snow comes in and goes, in seconds from none to all of it.
  private static let fadeIn: CGFloat = 0.35
  private static let fadeOut: CGFloat = 0.15
  /// Picked in Mission Control or switched to, a full-screen app zooms in from where it was: the snow goes with it.
  private static let giveWay: CGFloat = 0.4
  var autumn: Bool {
    get { simulation.autumn }
    set { simulation.autumn = newValue }
  }

  func setEffect(_ effect: WeatherEffect) {
    appliedScene = nil
    self.effect = effect
    renderer.setEffect(effect, calm: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    startPlacementWatcher()
    wake()
  }

  func setScene(_ scene: WeatherScene) {
    guard scene != appliedScene else { return }
    appliedScene = scene
    effect = scene.primary
    renderer.setScene(scene, calm: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    startPlacementWatcher()
    wake()
  }

  func setIntensity(_ intensity: Snowfall) {
    guard intensity != appliedIntensity else { return }
    appliedIntensity = intensity
    renderer.setIntensity(intensity)
    startPlacementWatcher()
    wake()
  }

  func setAccumulation(_ on: Bool) {
    renderer.configureLayers {
      $0.accumulates = on
      $1.accumulates = on
    }
    wake()
  }

  func setEvaporation(_ on: Bool) {
    renderer.configureLayers {
      $0.thaws = on
      $1.evaporates = on
    }
    wake()
  }

  func setWind(_ wind: Float, automatic:Bool=false) {
    renderer.configureLayers {
      $0.weatherWind = wind
      $1.wind = wind
      $1.manualWind = !automatic
    }
  }

  func accessibilityChanged() {
    renderer.configureLayers { _, weather in
      weather.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
  }

  func setBehindWindows(_ behind: Bool) {
    window.behindWindows = behind
    dock.window.behindWindows = behind
    updatePlacement()
  }

  func setReflections(_ enabled: Bool) {
    reflection.enabled = enabled
    reflection.live = Preferences.liveReflections
    tracker.usesSnapshotReflections = enabled || reflection.fogBloomEnabled
    if !enabled && !renderer.hasFog {
      reflection.stop()
      renderer.reflection = nil
    }
  }

  func setFogBloom(_ enabled: Bool) {
    reflection.fogBloomEnabled = enabled
    tracker.usesSnapshotReflections = reflection.enabled || enabled
    if !enabled {
      renderer.fogBloomTexture = nil
      if !renderer.hasWater { reflection.stop() }
    }
    wake()
  }

  var reflectionStatus: String {
    if effect.hasWater && !renderer.weather.water.contains(where: { $0.top > 0.15 }) {
      return "Reflections start when puddles form"
    }
    return reflection.status
  }

  var isCapturingReflections: Bool { reflection.isCapturing }
  var frameCounts: (delivered: Int, presented: Int, geometryQueries: Int) {
    (frameClock?.deliveredFrames ?? 0, frameClock?.presentedFrames ?? 0, tracker.queryCount)
  }
  var profileTimings: (input: Double, simulation: Double, encode: Double, particles: Int) {
    (renderer.profileInput, renderer.profileSimulation, renderer.profileEncode, renderer.weather.particleCount)
  }
  var profileWaterDepth: Float { renderer.weather.water.map(\.top).max() ?? 0 }
  func refreshCapturePermission() {
    guard !reflection.isCapturing else { return }
    reflection.invalidate(); wake()
  }
  var reflectionsStoppedByUser: Bool { reflection.stoppedByUser }

  var hasContent: Bool {
    renderer.hasContent
  }

  /// Native background fog and the Dock strip can remain visible when the
  /// foreground layer is covered. A context menu must not stop all three.
  var hasVisibleLayer: Bool {
    [window, dock.window, backgroundFog.window].contains { $0.occlusionState.contains(.visible) }
  }

  func clear(direction: Float, calm: Bool) {
    renderer.clear(direction: direction, calm: calm)
    wake()
  }

  init?(screen: NSScreen, device: MTLDevice, snowOnWindows: @escaping () -> Bool) {
    guard let displayID = screen.displayID else { return nil }
    let simulation = SnowSimulation(
      width: Float(screen.frame.width),
      height: Float(screen.frame.height),
      snowfall: Preferences.snowfall
    )
    simulation.thaws = Preferences.meltSnow
    simulation.accumulates = Preferences.accumulate
    let renderer: Renderer
    do {
      renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm, simulation: simulation)
    } catch {
      NSLog("Aeolian: Metal setup failed: \(error)")
      return nil
    }
    self.snowOnWindows = snowOnWindows
    self.displayID = displayID
    self.screen = screen
    self.renderer = renderer
    reflection = ScreenReflection(device: device, displayID: displayID)
    reflection.enabled = Preferences.screenReflections
    reflection.live = Preferences.liveReflections
    reflection.fogBloomEnabled = Preferences.fogBloom
    renderer.weather.intensity = Preferences.snowfall
    renderer.weather.accumulates = Preferences.accumulate
    renderer.weather.evaporates = Preferences.meltSnow
    renderer.configureLayers { _, weather in
      weather.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    window = OverlayWindow(screen: screen)
    window.behindWindows = Preferences.behindWindows
    window.showsInScreenshots = Preferences.showInScreenshots
    overFullScreen = Preferences.showOverFullScreen
    dock = DockOverlay(screen: screen, device: device)
    dock.window.behindWindows = Preferences.behindWindows
    dock.window.showsInScreenshots = Preferences.showInScreenshots
    renderer.dockOverlay = dock
    backgroundFog = DockOverlay(screen: screen, device: device,
      level: OverlayWindow.desktopLevel, fixedSpace: false)
    backgroundFog.window.showsInScreenshots = Preferences.showInScreenshots
    renderer.backgroundFogOverlay = backgroundFog
    view = Self.makeView(device: device, size: screen.frame.size)
    tracker.usesSnapshotReflections = reflection.enabled || reflection.fogBloomEnabled

    renderer.cursorLocation = { [unowned window] in
      let mouse = NSEvent.mouseLocation
      return SIMD2(Float(mouse.x - window.frame.minX), Float(mouse.y - window.frame.minY))
    }
    renderer.windowSurfaces = { [unowned self] now in
      // Behind the windows the snow still settles on them: what lies on a window's top edge is above it, in
      // plain view.
      let onWindows = snowOnWindows()
      let panels = AeolianPanelPresentation.visibleFrames.map { $0.offsetBy(dx: -self.screen.frame.minX, dy: -self.screen.frame.minY) }
      if panels != panelFrames { panelFrames = panels; updatePlacement() }
      let update = tracker.poll(now: now, eager: NSEvent.pressedMouseButtons != 0,
        frameInterval: (renderer.hasFog || renderer.hasWater) ? 1/Double(renderer.presentationFrameRate) : 1.0/62)
      let geometryChanged = geometryRevision != tracker.geometryRevision
      let transitioning = tracker.hasPresentationTransition(now: now)
      if geometryChanged || presentationTransition != transitioning {
        presentationTransition = transitioning
        updatePlacement()
        geometryRevision = tracker.geometryRevision
        renderer.desktopMoved(now: now)
      }
      renderer.accumulatesOnWindows = onWindows
      watchForFullScreen(now: now, tracked: true)
      if geometryChanged {
        renderer.setCoverFrames(
          tracker.covers.map {
            SIMD4(Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY))
          }, ids: tracker.coverIDs)
      }
      return update
    }
    renderer.sceneLight = { [unowned self] now in
      light.update(screen: self.screen, now: now)
      renderer.reflection = reflection.update(
        screen: self.screen, now: now,
        active: (renderer.hasWater || renderer.hasFog) && active && !asleep && !covered,
        windows: tracker.reflectionWindows, water: renderer.hasWater, fog: renderer.hasFog, regions: renderer.reflectionRegions(now:now))
      renderer.reflectionRect = reflection.waterRect
      renderer.fogCaptureTime = reflection.compositedAt ?? now
      renderer.fogBloomTexture = reflection.bloomTexture
      renderer.fogWallpaperTexture = reflection.wallpaperTexture
      renderer.fogBloomRect = reflection.bloomRect
      return (light.light, light.shadowTint, light.rim)
    }
    renderer.prepareReflection = { [unowned self] command in
      reflection.prepare(into: command)
      return reflection.compositedAt
    }
    renderer.rest = { [unowned self] in
      // An empty scene has no next draw callback to notice its last puddle dried.
      // End capture here as well, before pausing the display link.
      reflection.stop()
      renderer.reflection = nil
      renderer.fogBloomTexture = nil
      renderingPaused = true
      renderer.releaseFrames(of: view)
      if self.simulation.snowfall == .off && !hasContent {
        placementTimer?.invalidate()
        placementTimer = nil
      }
    }
    self.simulation.stirred = { [unowned self] in wake() }
    renderer.nativeFrameRate = max(1, screen.maximumFramesPerSecond)
    view.preferredFramesPerSecond = renderer.nativeFrameRate
    measure()
    view.delegate = renderer
    window.contentView = view
    frameClock = NativeFrameClock(view: view, renderer: renderer)
    window.orderFrontRegardless()
    checkCovered()
    startPlacementWatcher()
  }

  private func startPlacementWatcher() {
    guard simulation.snowfall != .off || hasContent else { return }
    guard placementTimer == nil,
      DisplayActivity(awake: !asleep, fullScreen: covered, visible: false, fading: false)
        .pollsWindows
    else { return }
    let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
      guard let self, !asleep, !covered, renderingPaused else { return }
      // Drawing can stop before the full-screen Space finishes its transition.
      checkCovered()
      if covered {
        placementTimer?.invalidate()
        placementTimer = nil
        activityChanged()
        return
      }
      if simulation.snowfall == .off && !hasContent { return }
      if let update = tracker.poll(now: CACurrentMediaTime(), eager: false) {
        renderer.updateWindows(update, onWindows: snowOnWindows())
      }
      updatePlacement()
    }
    timer.tolerance = 0.06
    RunLoop.main.add(timer, forMode: .common)
    placementTimer = timer
  }

  func fit(to screen: NSScreen) {
    self.screen = screen
    window.setFrame(screen.frame, display: true)
    dock.fit(to: screen)
    backgroundFog.fit(to: screen)
    Renderer.fitDrawable(of: view)
    renderer.resize(SIMD2(Float(screen.frame.width), Float(screen.frame.height)))
    reflection.invalidate()
    light.invalidate()
    renderer.nativeFrameRate = max(1, screen.maximumFramesPerSecond)
    view.preferredFramesPerSecond = renderer.nativeFrameRate
    frameClock?.updateRate()
    measure()
    checkCovered()
  }

  func apply(_ budget: PowerBudget) {
    renderer.budget = budget
    reflection.powerBudget = budget
    view.preferredFramesPerSecond = renderer.presentationFrameRate
    frameClock?.updateRate()
    renderer.configureLayers {
      $0.density = budget == .saver ? 0.75 : 1
      $1.density = budget == .saver ? 0.65 : 1
    }
    reflection.maximumWidth = budget == .full ? 1280 : budget == .battery ? 1024 : 768
  }

  /// `asleep` with the screens off, locked or switched away from: nothing is seen, so the frames are given back.
  func setActive(_ active: Bool, asleep: Bool) {
    self.asleep = asleep
    self.active = active
    if asleep || covered {
      placementTimer?.invalidate()
      placementTimer = nil
    } else {
      startPlacementWatcher()
    }
    if !active {
      reflection.stop()
      renderer.reflection = nil
      renderer.fogBloomTexture = nil
    }
    if !active { renderer.releaseFrames(of: view) }
    guard renderingPaused == active else { return }
    if active { Renderer.fitDrawable(of: view) }
    renderingPaused = !active
    if active { renderer.resetClock() }
  }

  /// Setup has released all frames. Reintroduce the whole composition gently,
  /// including a previously formed cloud scene resumed from retirement.
  func resumeAfterSetup() {
    guard !covered else { return }
    let duration: Double = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 1.4
    following = false
    alphaTarget = 1
    fadeEndsAt = CACurrentMediaTime()+duration
    for overlay in [window,dock.window,backgroundFog.window] { overlay.alphaValue = 0 }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
      for overlay in [window,dock.window,backgroundFog.window] { overlay.animator().alphaValue = 1 }
    }
  }

  private func wake() {
    guard active, renderingPaused else { return }
    Renderer.fitDrawable(of: view)
    renderingPaused = false
    renderer.resetClock()
  }

  func beginExit(duration: Double) {
    exiting = true; following = false; alphaTarget = 0
    fadeEndsAt = CACurrentMediaTime() + duration
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      for overlay in [window, dock.window, backgroundFog.window] { overlay.animator().alphaValue = 0 }
    }
  }

  func dropWindowSnow() {
    renderer.updateWindows(
      WindowUpdate(
        surfaces: [], interval: 0.1, parked: [], elsewhere: [], sliding: false, slideVelocity: 0),
      onWindows: false)
    renderer.setCoverFrames([])
    tracker.reset()
  }

  private func updatePlacement() {
    let local = CGRect(origin: .zero, size: screen.frame.size)
    let top = screen.visibleFrame.maxY - screen.frame.minY
    let allowsFullScreen = overFullScreen && tracker.fullScreenInView
    let behind =
      !allowsFullScreen
      && (tracker.hasPresentationTransition(now: CACurrentMediaTime()) || WindowCoverage.shouldYield(
        screen: local, windows: tracker.applicationFrames, alreadyBehind: automaticallyBehind))
    let topWindows =
      allowsFullScreen
      ? [:]
      : WindowCoverage.windowsAtTop(
        screen: local, top: top, windows: tracker.applicationWindows, previous: topWindowIDs)
    topWindowIDs = Set(topWindows.keys)
    let occluders =
      (behind || window.behindWindows ? [] : topWindows.sorted { $0.key < $1.key }.map(\.value)) + panelFrames
    if let layer = view.layer {
      occlusionMask.apply(to: layer, bounds: local, excluding: occluders)
    }
    dock.setOccludingWindows(occluders)
    guard behind != automaticallyBehind else { return }
    automaticallyBehind = behind
    window.automaticallyBehindWindows = behind
    dock.window.automaticallyBehindWindows = behind
    activityChanged()
  }

  /// Going full screen, an app adds its Space as the move starts, though it is the current one only once the app is
  /// in. Swiped between a desktop and a full-screen app, the snow follows the desktop: as much of it shows as the
  /// square of the desktop's share of the screen, so it is faint while the app fills most of it.
  private func watchForFullScreen(now: CFTimeInterval, tracked: Bool) {
    guard !overFullScreen else { return }
    if covered {
      // Still drawn while fading out under the app: the lookout watches for the desktop until it comes back.
      guard leaving else { return }
      if now - shareSeenAt >= 1.0 / 30 {
        shareSeenAt = now
        guard let shown = tracker.desktopShare(now: now), shown > 0 else {
          setLeaving(false)
          return
        }
        slideGoal = shown * shown
      }
      follow(now: now)
      return
    }
    if now - spacesSeenAt >= 0.1 {
      spacesSeenAt = now
      if let spaces = Spaces.fullScreen(on: displayID)?.spaces {
        if let known = fullScreenSpaces, !spaces.isSubset(of: known) { goneFullScreenAt = now }
        fullScreenSpaces = spaces
      }
    }
    if now - exposedSeenAt >= 0.15 {
      exposedSeenAt = now
      let previouslyCovered = covered
      checkCovered()
      if covered != previouslyCovered { activityChanged() }
      if covered { return }
    }
    let canSlide = !(fullScreenSpaces ?? []).isEmpty
    // Untracked, the window list is read only while there is a full-screen app here to swipe to.
    if !tracked && canSlide && now - shareSeenAt >= (untrackedShare > 0 ? 1.0 / 30 : 0.1) {
      shareSeenAt = now
      untrackedShare = tracker.readFullScreenShare(now: now)
    }
    let share = !canSlide ? 0 : tracked ? tracker.fullScreenShare : untrackedShare
    let entering = now - goneFullScreenAt < 1
    if entering != arriving {
      arriving = entering
      if arriving { following = false }
      fade()
    }
    guard !arriving, share > 0 || following else { return }
    if !following { startFollowing(now: now) }
    slideGoal = (1 - share) * (1 - share)
    follow(now: now)
    if share == 0 && slideAlpha >= 0.999 {
      following = false
      fade()
    }
  }

  /// The overlays sit in a Space of their own that shows over every other, full-screen apps' too.
  private func checkCovered() {
    let now = CACurrentMediaTime()
    let was = covered
    let wasFullScreen = fullScreenCurrent
    fullScreenCurrent =
      !overFullScreen
      && ((Spaces.fullScreen(on: displayID)?.showing ?? false)
        || tracker.geometryShowsFullScreen(now: now))
    if fullScreenCurrent && !wasFullScreen && !was { coverAfter = now + 0.2 }
    exposed = fullScreenCurrent && (now < coverAfter || tracker.missionControlShows(now: now))
    covered = fullScreenCurrent && !exposed
    if covered != was {
      fullScreenSpaces = nil
      leaving = false
      if covered {
        placementTimer?.invalidate()
        placementTimer = nil
      }
    }
    if covered && !was { following = false }
    if was && !covered {
      arriving = false
      goneFullScreenAt = -10
    }
    fade()
  }

  private func setLeaving(_ next: Bool) {
    guard next != leaving else { return }
    leaving = next
    if leaving {
      startFollowing(now: CACurrentMediaTime())
      shareSeenAt = 0
    } else {
      following = false
    }
    fade()
    activityChanged()
  }

  private func startFollowing(now: CFTimeInterval) {
    following = true
    slideAlpha = window.alphaValue
    slideFrameAt = now
    fade()
  }

  private func follow(now: CFTimeInterval) {
    guard following else { return }
    let dt = CGFloat(min(now - slideFrameAt, 0.05))
    slideFrameAt = now
    // Caught late in a quick swipe, the desktop is nearly in: the snow still comes in at its own pace.
    let step = (slideGoal - slideAlpha) * min(1, dt / 0.08)
    slideAlpha += min(max(step, -dt / Self.fadeOut), dt / Self.fadeIn)
    guard !occluded, abs(window.alphaValue - slideAlpha) > 0.002 else { return }
    window.alphaValue = slideAlpha
    dock.window.alphaValue = slideAlpha
    backgroundFog.window.alphaValue = slideAlpha
  }

  // Full-screen wakeup is driven by Space, application and occlusion notifications. No polling timer
  // or display link remains running while a full-screen app completely covers this display.

  /// Gone full screen, the window server hides the overlays for the move and shows them again once the app is in:
  /// they vanish while hidden, so they come back already gone.
  private func fade() {
    guard !exiting else { return }
    if following && !occluded {
      alphaTarget = nil
      return
    }
    let out = covered || arriving || occluded
    let target: CGFloat = out ? 0 : 1
    if target != alphaTarget {
      alphaTarget = target
      gone = false
      let duration = occluded ? 0 : covered && !arriving ? Self.giveWay : out ? Self.fadeOut : 0.25
      fadeEndsAt = CACurrentMediaTime() + duration
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        window.animator().alphaValue = target
        dock.window.animator().alphaValue = target
        backgroundFog.window.animator().alphaValue = target
      }
    }
    finishFade()
  }

  /// An animation may be lost, as on an overlay just put on screen: once the fade's time is up its end is set
  /// outright, and under a full-screen app the snow is put to rest.
  private func finishFade() {
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(0, fadeEndsAt - CACurrentMediaTime()) + 0.02
    ) { [weak self] in
      guard let self, !following, let target = alphaTarget, CACurrentMediaTime() >= fadeEndsAt
      else { return }
      if window.alphaValue != target || dock.window.alphaValue != target || backgroundFog.window.alphaValue != target {
        window.alphaValue = target
        dock.window.alphaValue = target
        backgroundFog.window.alphaValue = target
      }
      guard covered, !leaving, !gone, target == 0 else { return }
      gone = true
      activityChanged()
    }
  }

  func occlusionChanged() {
    let hidden =
      !hasVisibleLayer
      && (covered || arriving)
    guard hidden != occluded else { return }
    occluded = hidden
    if hidden {
      fade()
    } else {
      checkCovered()
      if covered && !leaving, let shown = tracker.desktopShare(now: CACurrentMediaTime()), shown > 0
      {
        setLeaving(true)
      }
    }
  }

  func spaceChanged() {
    Spaces.invalidate()
    checkCovered()
    renderer.spaceChanged()
    light.invalidate()
    reflection.invalidate()
    watchWindows()
    window.holdInPlace()
    dock.window.holdInPlace()
  }

  func windowGeometryChanged() {
    guard covered, !asleep else { return }
    let now = CACurrentMediaTime()
    guard now - coveredGeometryCheck > 0.15 else { return }
    coveredGeometryCheck = now
    checkCovered()
    activityChanged()
  }

  func watchWindows() {
    checkCovered()
    tracker.watchClosely(now: CACurrentMediaTime())
    for delay in [0.25, 0.75, 1.4] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, !asleep else { return }
        checkCovered()
        activityChanged()
      }
    }
  }

  func close() {
    placementTimer?.invalidate()
    reflection.stop()
    active = false
    renderingPaused = true
    frameClock?.invalidate()
    view.delegate = nil
    window.orderOut(nil)
    dock.close()
    backgroundFog.close()
  }

  /// Window bounds come in global coordinates with the origin at the top left of the primary display.
  private func measure() {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let frame = screen.frame
    tracker.screen = CGRect(
      x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    tracker.primaryHeight = primaryHeight
    tracker.menuBarHeight = frame.maxY - screen.visibleFrame.maxY
    let menuInset = max(
      tracker.menuBarHeight, screen.safeAreaInsets.top, NSStatusBar.system.thickness)
    renderer.contentTop = Float(frame.height - menuInset)
    tracker.reset()
    let others = NSScreen.screens.map(\.frame).filter {
      $0 != frame && $0.maxY > frame.minY && $0.minY < frame.maxY
    }
    simulation.walls = (
      left: !others.contains { abs($0.maxX - frame.minX) < 1 },
      right: !others.contains { abs($0.minX - frame.maxX) < 1 }
    )
  }

  private static func makeView(device: MTLDevice, size: CGSize) -> MTKView {
    let view = MTKView(frame: CGRect(origin: .zero, size: size), device: device)
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColorMake(0, 0, 0, 0)
    view.framebufferOnly = true
    (view.layer as? CAMetalLayer)?.maximumDrawableCount = 3
    view.preferredFramesPerSecond = 30
    view.autoresizingMask = [.width, .height]
    view.autoResizeDrawable = false
    Renderer.fitDrawable(of: view)
    return view
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}
