import MetalKit
import QuartzCore

struct Uniforms {
  var viewSize: SIMD2<Float>
  var scale: Float
  var time: Float
  var columnWidth: Float
  var columnCount: Int32 = 0
  var pileTop: Float = 0
  var occluderCount: Int32 = 0
  var origin: SIMD2<Float> = .zero
  var pileBottom: Float = 0
  /// One while leaves fall instead of snow.
  var autumn: Float = 0
  var light = SIMD4<Float>(1, 1, 1, 1)
  var shadowTint = SIMD4<Float>(0, 0, 0, 0)
  var rim = SIMD4<Float>(0, 0, 0, 0)
  /// How far everything is jolted: x and y. For a pile, z is how far along its window its snow has drifted.
  var shake = SIMD4<Float>(0, 0, 0, 0)
}

enum RendererError: Error {
  case unavailable
}

/// A live scene and its outgoing predecessors overlap until their actual particles and piles decay.
final class EffectScene {
  let effect: WeatherEffect
  let snow: SnowSceneRenderer
  let weather: WeatherRenderer
  private(set) var retiring = false
  var hasContent: Bool {
    snow.simulation.hasSnow || snow.simulation.spriteCount > 0 || weather.simulation.hasContent
  }
  var isEmpty: Bool { snow.simulation.isEmpty && weather.simulation.isEmpty }

  init(
    effect: WeatherEffect, device: MTLDevice, queue: MTLCommandQueue, format: MTLPixelFormat,
    simulation: SnowSimulation, reusing previous: EffectScene? = nil
  ) throws {
    self.effect = effect
    snow = try SnowSceneRenderer(
      device: device, queue: queue, format: format, simulation: simulation, reusing: previous?.snow)
    weather = try WeatherRenderer(
      device: device, format: format, size: SIMD2(simulation.width, simulation.height),
      reusing: previous?.weather)
    simulation.botanicalStyle = effect.botanicalStyle
    simulation.autumn = effect.botanicalStyle > 0
    weather.setEffect(effect)
  }
  func retire() {
    retiring = true
    snow.simulation.retire()
    weather.simulation.retire()
  }
  func resume() {
    retiring = false
    snow.simulation.resume()
    weather.simulation.resume()
  }
}

final class Renderer: NSObject, MTKViewDelegate {
  var cursorLocation: () -> SIMD2<Float> = { SIMD2(-10_000, -10_000) }
  var windowSurfaces: (CFTimeInterval) -> WindowUpdate? = { _ in nil }
  var sceneLight:
    (CFTimeInterval) -> (
      light: SIMD3<Float>, shadowTint: SIMD4<Float>, rim: SIMD4<Float>
    ) = { _ in (SIMD3(repeating: 1), .zero, .zero) }
  var prepareReflection: (MTLCommandBuffer) -> Void = { _ in }
  var nativeFrameRate = 60
  var budget = PowerBudget.full
  private let activity = FrameActivity()
  private let airflow = WindField()
  private var coverFrames: [SIMD4<Float>] = []
  private var reflectionMotion: ReflectionMotion?
  private var reflectionMotionUnavailable = false
  var captureFrameRate: Int {
    reflectionMotionUnavailable || activity.isActive(now: CACurrentMediaTime())
      ? nativeFrameRate : budget == .saver ? 20 : 30
  }
  func desktopMoved(now: CFTimeInterval) { activity.wake(now: now) }
  var rest: () -> Void = {}
  var dockOverlay: DockOverlay?
  var accumulatesOnWindows = true
  var simulation: SnowSimulation { current.snow.simulation }
  var weather: WeatherSimulation { current.weather.simulation }
  var effect: WeatherEffect { current.effect }
  var hasContent: Bool { current.hasContent || retiring.contains { $0.hasContent } }
  var hasWater: Bool {
    scenes.contains {
      $0.weather.simulation.effect.hasWater && $0.weather.simulation.ownsWater
        && $0.weather.simulation.water.contains { $0.top > 0.15 && !$0.isOccluded }
    }
  }
  var contentTop: Float = .greatestFiniteMagnitude {
    didSet { for scene in scenes { scene.weather.contentTop = contentTop } }
  }
  var reflectionFrame: ScreenReflection.Frame? {
    didSet {
      if reflectionFrame !== oldValue {
        for scene in scenes {
          scene.weather.reflectionRect = reflectionFrame?.uvRect ?? SIMD4(0, 0, 1, 1)
        }
      }
    }
  }
  var reflection: MTLTexture? {
    didSet {
      if reflection !== oldValue { for scene in scenes { scene.weather.reflection = reflection } }
    }
  }
  private(set) var current: EffectScene
  private(set) var retiring: [EffectScene] = []
  private var scenes: [EffectScene] = []
  private(set) var overlays: [EffectScene] = []
  private var intensity = Snowfall.steady
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let format: MTLPixelFormat
  private let semaphore = DispatchSemaphore(value: 2)
  private var lastTime: CFTimeInterval = 0
  private var lastWindows: WindowUpdate?
  private var dockDrawn = false
  private var ambient: (light: SIMD3<Float>, shadowTint: SIMD4<Float>, rim: SIMD4<Float>) = (
    SIMD3(repeating: 1), .zero, .zero
  )
  private var pointer = SIMD2<Float>(-10_000, -10_000)
  private let epoch = CACurrentMediaTime()

  init(device: MTLDevice, pixelFormat: MTLPixelFormat, simulation: SnowSimulation) throws {
    guard let queue = device.makeCommandQueue() else { throw RendererError.unavailable }
    self.device = device
    self.queue = queue
    format = pixelFormat
    current = try EffectScene(
      effect: .snow, device: device, queue: queue, format: pixelFormat, simulation: simulation)
    scenes = [current]
    super.init()
  }

  func setEffect(_ effect: WeatherEffect, calm: Bool) {
    guard effect != current.effect else { return }
    let previous = current
    let next: EffectScene
    if let index = retiring.firstIndex(where: { $0.effect == effect }) {
      next = retiring.remove(at: index)
      next.resume()
    } else {
      let old = simulation
      let snow = SnowSimulation(
        width: old.width, height: old.height,
        snowfall: effect.usesSnowSimulation ? old.snowfall : .off)
      snow.autumn = effect == .leaves
      snow.accumulates = old.accumulates
      snow.thaws = old.thaws
      snow.weatherWind = old.weatherWind
      snow.density = old.density
      snow.walls = old.walls
      snow.windowFrames = old.windowFrames
      snow.snowfallHeld = old.snowfallHeld
      snow.snowfallReleased = old.snowfallReleased
      snow.stirred = old.stirred
      do {
        next = try EffectScene(
          effect: effect, device: device, queue: queue, format: format, simulation: snow,
          reusing: previous)
      } catch {
        NSLog("Atmos: scene setup failed: \(error)")
        return
      }
      next.weather.simulation.accumulates = weather.accumulates
      next.weather.simulation.evaporates = weather.evaporates
      next.weather.simulation.wind = weather.wind
      next.weather.simulation.density = weather.density
      next.weather.simulation.intensity = weather.intensity
      next.weather.simulation.reducedMotion = calm
    }
    if effect.hasWater,
      let donor = ([previous] + retiring).first(where: {
        $0.weather.simulation.ownsWater && $0.effect.hasWater
          && !$0.weather.simulation.water.isEmpty
      }), donor !== next
    {
      next.weather.simulation.adoptWater(from: donor.weather.simulation)
    }
    if previous.hasContent {
      previous.retire()
      retiring.append(previous)
    }
    current = next
    activity.wake(now: CACurrentMediaTime())
    scenes = retiring + [current] + overlays
    let waterScenes = scenes.filter { $0.effect.hasWater }
    if let owner = waterScenes.first(where: { $0.weather.simulation.ownsWater })
      ?? waterScenes.first
    {
      owner.weather.simulation.retainWaterOwnership()
      for other in waterScenes where other !== owner {
        other.weather.simulation.followWater(of: owner.weather.simulation)
      }
    }
    next.weather.contentTop = contentTop
    next.weather.reflection = reflection
    next.weather.reflectionRect = reflectionFrame?.uvRect ?? SIMD4(0, 0, 1, 1)
    if let lastWindows { updateWindows(lastWindows, onWindows: accumulatesOnWindows) }
    resetClock()
  }

  func setScene(_ description: WeatherScene, calm: Bool) {
    setEffect(description.primary, calm: calm)
    weather.scene = description
    let wanted = [description.stacked, description.wildlife].compactMap { $0 }
    for outgoing in overlays where !wanted.contains(outgoing.effect) {
      if outgoing.hasContent {
        outgoing.retire()
        retiring.append(outgoing)
      }
    }
    overlays.removeAll { !wanted.contains($0.effect) }
    for effect in wanted where !overlays.contains(where: { $0.effect == effect }) {
      let next: EffectScene
      if let index = retiring.firstIndex(where: { $0.effect == effect }) {
        next = retiring.remove(at: index)
        next.resume()
      } else {
        let snow = SnowSimulation(
          width: simulation.width, height: simulation.height, snowfall: .off)
        snow.accumulates = simulation.accumulates
        snow.thaws = simulation.thaws
        snow.density = simulation.density
        snow.walls = simulation.walls
        snow.windowFrames = simulation.windowFrames
        do {
          next = try EffectScene(
            effect: effect, device: device, queue: queue, format: format, simulation: snow,
            reusing: current)
        } catch {
          NSLog("Atmos: overlay setup failed: \(error)")
          continue
        }
      }
      overlays.append(next)
    }
    scenes = retiring + [current] + overlays
    for overlay in overlays {
      var layer = WeatherScene(primary: overlay.effect)
      layer.dynamics = description.dynamics
      layer.strength = description.overlayStrength
      overlay.weather.simulation.scene = layer
      overlay.weather.simulation.density = weather.density
      overlay.weather.simulation.reducedMotion = calm
      overlay.weather.contentTop = contentTop
    }
    setIntensity(intensity)
    if let lastWindows { updateWindows(lastWindows, onWindows: accumulatesOnWindows) }
  }

  func configureLayers(_ change: (SnowSimulation, WeatherSimulation) -> Void) {
    for scene in scenes { change(scene.snow.simulation, scene.weather.simulation) }
  }

  func setIntensity(_ intensity: Snowfall) {
    self.intensity = intensity
    simulation.snowfall =
      effect.usesSnowSimulation
      ? (weather.scene.dynamics != nil && intensity != .off ? .steady : intensity) : .off
    weather.intensity = intensity
    for overlay in overlays {
      overlay.snow.simulation.snowfall =
        overlay.effect.usesSnowSimulation
        ? (weather.scene.dynamics != nil && intensity != .off ? .steady : intensity) : .off
      overlay.weather.simulation.intensity = overlay.effect.usesSnowSimulation ? .off : intensity
    }
  }
  func updateWindows(_ update: WindowUpdate, onWindows: Bool) {
    lastWindows = update
    accumulatesOnWindows = onWindows
    for scene in scenes {
      scene.snow.simulation.updateWindows(
        onWindows ? update.surfaces : [], interval: update.interval, parked: update.parked,
        elsewhere: update.elsewhere, sliding: update.sliding)
      scene.weather.simulation.updateWindows(
        update.surfaces, onWindows: onWindows, interval: update.interval, sliding: update.sliding,
        elsewhere: update.elsewhere)
      if update.slideVelocity != 0 {
        scene.snow.simulation.spaceSlid(velocity: update.slideVelocity)
      }
    }
  }
  func setCoverFrames(_ frames: [SIMD4<Float>]) {
    coverFrames = frames
    for scene in scenes {
      scene.snow.simulation.windowFrames = frames
      scene.weather.windowOccluders = Array(frames.prefix(128))
    }
  }
  func resize(_ size: SIMD2<Float>) {
    for scene in scenes {
      scene.snow.simulation.resize(width: size.x, height: size.y)
      scene.weather.simulation.resize(size)
    }
  }
  func clear(direction: Float, calm: Bool) {
    for scene in scenes {
      if scene.effect.usesSnowSimulation || scene.snow.simulation.hasSnow
        || scene.snow.simulation.spriteCount > 0
      {
        scene.snow.simulation.blowAway(direction: direction, calm: calm)
      }
      scene.weather.simulation.clear()
    }
  }
  func spaceChanged() { for scene in scenes { scene.snow.simulation.spaceChanged() } }
  func resetClock() {
    lastTime = 0
    activity.resetCursor()
    for scene in scenes { scene.weather.simulation.resetCursor() }
  }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  static func fitDrawable(of view: MTKView) { resize(view, to: view.bounds.size) }
  private static func resize(_ view: MTKView, to size: CGSize) {
    view.drawableSize = size
    (view.layer as? CAMetalLayer)?.drawableSize = size
  }
  func releaseFrames(of view: MTKView) {
    guard view.drawableSize != CGSize(width: 1, height: 1) else { return }
    Self.resize(view, to: CGSize(width: 1, height: 1))
    for scene in scenes {
      scene.weather.releaseBuffers()
      scene.snow.releaseBuffers()
    }
    clear(view)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak view] in
      guard let self, let view, view.drawableSize == CGSize(width: 1, height: 1) else { return }
      clear(view)
    }
  }
  private func clear(_ view: MTKView) {
    guard let command = queue.makeCommandBuffer() else { return }
    if let drawable = (view.layer as? CAMetalLayer)?.nextDrawable() {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = drawable.texture
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
      command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
      command.present(drawable)
    }
    clearDock(into: command)
    command.commit()
  }
  private func clearDock(into command: MTLCommandBuffer) {
    guard let frame = dockOverlay?.emptyFrame(),
      let encoder = command.makeRenderCommandEncoder(descriptor: frame.pass)
    else { return }
    encoder.endEncoding()
    command.present(frame.drawable)
    dockDrawn = false
  }

  func draw(in view: MTKView) {
    #if DEBUG
      if DebugMetrics.enabled { DebugMetrics.frames += 1 }
    #endif
    #if DEBUG
      var measured = DebugMetrics.begin()
    #endif
    let now = CACurrentMediaTime()
    if let update = windowSurfaces(now) { updateWindows(update, onWindows: accumulatesOnWindows) }
    #if DEBUG
      measured = DebugMetrics.end("windows", since: measured)
    #endif
    pointer = cursorLocation()
    activity.observeCursor(pointer, size: SIMD2(simulation.width, simulation.height), now: now)
    ambient = sceneLight(now)
    #if DEBUG
      measured = DebugMetrics.end("capture_input", since: measured)
    #endif
    // Presentation and every visible simulation follow this display. Desktop
    // capture can rest independently without freezing the weather itself.
    if view.preferredFramesPerSecond != nativeFrameRate {
      view.preferredFramesPerSecond = nativeFrameRate
    }
    #if DEBUG
      if DebugMetrics.enabled {
        DebugMetrics.pacing =
          "active:\(activity.isActive(now: now)) reason:\(activity.lastReason) capture:\(captureFrameRate) present:\(nativeFrameRate) sensor_failed:\(reflectionMotionUnavailable)"
      }
    #endif
    let dt = lastTime > 0 ? Float(min(now - lastTime, 0.05)) : 1 / Float(nativeFrameRate)
    lastTime = now
    step(dt: dt, cursor: pointer, now: now)
    if current.isEmpty && retiring.isEmpty && overlays.allSatisfy(\.isEmpty) {
      rest()
      return
    }
    #if DEBUG
      measured = DebugMetrics.end("simulation", since: measured)
    #endif
    semaphore.wait()
    guard let command = queue.makeCommandBuffer() else {
      semaphore.signal()
      return
    }
    guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
      semaphore.signal()
      return
    }
    if reflectionMotion == nil, !reflectionMotionUnavailable, reflectionFrame != nil {
      do { reflectionMotion = try ReflectionMotion(device: device) } catch {
        reflectionMotionUnavailable = true
      }
    }
    let motionResult = reflectionFrame.flatMap {
      reflectionMotion?.encode(texture: $0.texture, into: command, now: now)
    }
    prepareReflection(command)
    encode(
      into: command, pass: pass, scale: Float(view.drawableSize.width / max(1, view.bounds.width)),
      time: Float((now - epoch).truncatingRemainder(dividingBy: 1000)))
    command.present(drawable)
    let reflected = reflectionFrame
    command.addCompletedHandler { [semaphore, reflected, weak self] finished in
      #if DEBUG
        DebugMetrics.recordGPU(seconds: finished.gpuEndTime - finished.gpuStartTime)
      #endif
      let changed = motionResult?.contents().load(as: UInt32.self) ?? 0
      if changed >= 24 {
        DispatchQueue.main.async { [weak self] in
          self?.activity.observeDesktopChange(samples: changed, now: now)
        }
      }
      _ = withExtendedLifetime(reflected) { semaphore.signal() }
    }
    command.commit()
    #if DEBUG
      _ = DebugMetrics.end("encode_submit", since: measured)
    #endif
  }

  /// Shared native-rate step, also used for isolated simulation and rendering measurements.
  func step(dt: Float, cursor: SIMD2<Float>, now: Double) {
    let climate = weather.dynamics ?? weather.scene.dynamics
    let fieldWind=climate?.wind(at:weather.elapsed) ?? weather.wind
    let hasAirflow=climate != nil || abs(fieldWind)>0.01
    if hasAirflow {
      airflow.update(size:weather.size,windows:coverFrames,wind:fieldWind,
        turbulence:climate?.turbulence ?? abs(fieldWind)*0.12,time:now)
    }
    // Step water first, then let every drifting layer collide with the same live or drying puddles.
    for scene in scenes {
      scene.weather.simulation.airflow = hasAirflow ? airflow : nil
      scene.weather.simulation.step(dt: dt, cursor: cursor)
    }
    let pools = scenes.filter { $0.effect.hasWater && $0.weather.simulation.ownsWater }
      .flatMap { $0.weather.simulation.water }
    for scene in scenes {
      scene.snow.simulation.waterSurfaces = pools
      scene.snow.simulation.airflow = hasAirflow ? airflow : nil
      scene.weather.simulation.airflow = hasAirflow ? airflow : nil
      let snow = scene.snow.simulation
      let weather = scene.weather.simulation
      if let dynamics = weather.dynamics ?? weather.scene.dynamics {
        snow.weatherWind = dynamics.wind(at: weather.elapsed)
        snow.weatherStrength =
          scene.effect == .snow ? dynamics.precipitationStrength : weather.scene.strength
        snow.meltScale = scene.effect == .snow ? max(0.15, min(3, (dynamics.feelsLike + 3) / 8)) : 1
      } else {
        snow.weatherStrength = 1
        snow.meltScale = 1
      }
      if scene.effect.usesSnowSimulation || scene.snow.simulation.spriteCount > 0
        || scene.snow.simulation.hasSnow
      {
        _ = scene.snow.simulation.step(dt: dt, cursor: cursor)
      }
    }
    let outgoingCount = retiring.count
    retiring.removeAll { $0.isEmpty }
    if outgoingCount != retiring.count { scenes = retiring + [current] + overlays }
  }

  /// One shared pass draws water and atmosphere at the display's native rate.
  func encode(
    into command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, scale: Float, time: Float
  ) {
    let layers = scenes
    for scene in layers { scene.weather.prepare(light: ambient.light, command: command) }
    #if DEBUG
      if DebugMetrics.enabled { DebugMetrics.effectFrames += 1 }
    #endif
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
    if let target = pass.colorAttachments[0].texture {
      clip(encoder, width: target.width, height: target.height)
    }
    for scene in layers {
      scene.weather.encodeWater(with: encoder, includeGround: dockOverlay == nil)
    }
    drawAtmosphere(layers, with: encoder, scale: scale, time: time)
    encoder.endEncoding()
    encodeDock(layers, into: command)
  }
  private func encodeDock(_ layers: [EffectScene], into command: MTLCommandBuffer) {
    if let dockOverlay {
      dockOverlay.setDetailedRendering(layers.contains { $0.weather.simulation.effect.hasWater })
      let top = layers.map { max($0.weather.simulation.groundTop, $0.snow.groundTop) }.max() ?? 0
      if top > 0.02, let frame = dockOverlay.nextFrame(reaching: CGFloat(top + 3)),
        let ground = command.makeRenderCommandEncoder(descriptor: frame.pass)
      {
        for scene in layers {
          scene.weather.encodeGround(with: ground, height: Float(dockOverlay.height))
          scene.snow.encodeGround(
            with: ground, height: Float(dockOverlay.height),
            scale: Float(frame.drawable.texture.width) / max(1, simulation.width))
        }
        ground.endEncoding()
        command.present(frame.drawable)
        dockDrawn = true
      } else if dockDrawn {
        clearDock(into: command)
      }
    }
  }
  private func drawAtmosphere(
    _ layers: [EffectScene], with encoder: MTLRenderCommandEncoder, scale: Float, time: Float
  ) {
    for scene in layers {
      scene.weather.encodeAtmosphere(with: encoder, includeGround: dockOverlay == nil)
      if scene.effect.usesSnowSimulation || scene.snow.simulation.hasSnow
        || scene.snow.simulation.spriteCount > 0
      {
        scene.snow.encode(
          with: encoder, ambient: ambient, scale: scale, time: time,
          includeGround: dockOverlay == nil)
      }
    }
  }
  private func clip(_ encoder: MTLRenderCommandEncoder, width: Int, height: Int) {
    let top = min(simulation.height, max(0, contentTop))
    let inset = min(
      height - 1,
      max(0, Int(ceil((simulation.height - top) / max(1, simulation.height) * Float(height)))))
    encoder.setScissorRect(MTLScissorRect(x: 0, y: inset, width: width, height: height - inset))
  }
}
