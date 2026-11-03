import CWeatherCore
import CoreGraphics
import Foundation
import simd

// The C ABI is also the Metal vertex layout; Rust steps this storage in place.
typealias WeatherParticle = SHParticle

struct WaterRipple {
  var point: SIMD2<Float>
  var age: Float
  var strength: Float
}

final class WaterSurface {
  let id: CGWindowID
  let isDock: Bool
  var belowDock: Bool { id == 0 || isDock }
  var origin: SIMD2<Float>
  var width: Float
  let limit: Float
  var blockers: [SIMD4<Float>]
  private(set) var depths: [Float]
  private var waves: [Float]
  private var speeds: [Float]
  private var scratch: [Float]
  private let bed: [Float]
  private var horizontal: [Float]
  private var fluxScratch: [Float]
  private(set) var supportVelocity = SIMD2<Float>.zero
  private var lastMotionAt: Double = -1
  private(set) var outflow = SHWaterOutflow()
  private(set) var detached: Float = 0
  private(set) var detachedAt = SIMD2<Float>.zero
  private(set) var detachedVelocity = SIMD2<Float>.zero
  private(set) var heights: [Float]
  private(set) var top: Float = 0
  var isOccluded: Bool {
    blockers.contains {
      $0.x <= origin.x && $0.z >= origin.x + width && $0.y <= origin.y && $0.w >= origin.y + top + 2
    }
  }
  static let spacing: Float = 4

  init(
    id: CGWindowID, origin: SIMD2<Float>, width: Float, blockers: [SIMD4<Float>] = [],
    isDock: Bool = false
  ) {
    self.id = id
    self.isDock = isDock
    self.origin = origin
    self.width = max(width, 1)
    self.blockers = blockers
    limit = id == 0 ? 24 : 5
    let count = max(3, Int(ceil(max(width, 1) / Self.spacing)) + 1)
    depths = Array(repeating: 0, count: count)
    waves = depths
    speeds = depths
    scratch = depths
    heights = depths
    horizontal = depths
    fluxScratch = depths
    bed = (0..<count).map { i in
      let x = Float(i) * Self.spacing
      return max(0.08, 0.32 + 0.28 * sin(x * 0.021 + Float(id % 17)) + 0.22 * sin(x * 0.057 + 1.7))
    }
  }

  /// Changes of support velocity accelerate the water in the opposite direction.
  func move(to point: SIMD2<Float>, interval: Float, now: Double, physical: Bool) {
    let shift = point - origin
    guard physical, simd_length(shift) < 700 else {
      origin = point
      supportVelocity = .zero
      for i in horizontal.indices { horizontal[i] = 0 }
      return
    }
    let velocity = simd_clamp(shift / max(interval, 1 / 120), SIMD2(-1200, -900), SIMD2(1200, 900))
    impart(velocity)
    if velocity.y < -200 && volume > 0.1 {
      detachedAt = origin + SIMD2(width / 2, top + 2)
      detachedVelocity = SIMD2(0, 0)
      detached += extract(
        x: origin.x + width / 2, radius: width, fraction: min(0.75, -velocity.y / 1500))
    }
    origin = point
    lastMotionAt = now
  }

  func settleMotion(now: Double) {
    if now - lastMotionAt > 0.04 && supportVelocity != .zero { impart(.zero) }
  }

  private func impart(_ velocity: SIMD2<Float>) {
    let delta = velocity - supportVelocity
    if delta.y < -200 && supportVelocity.y > 180 && volume > 0.1 {
      detachedAt = origin + SIMD2(width / 2, top + 2)
      let worldX =
        supportVelocity.x + zip(horizontal, depths).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        / max(0.001, volume)
      detachedVelocity = SIMD2(max(-650, min(650, worldX)), min(650, supportVelocity.y * 0.8))
      detached += extract(
        x: origin.x + width / 2, radius: width, fraction: min(0.65, -delta.y / 1600))
    }
    for i in horizontal.indices { horizontal[i] = max(-1200, min(1200, horizontal[i] - delta.x)) }
    supportVelocity = velocity
  }

  func consumeOutflow(left: Bool) {
    if left {
      outflow.left = 0
      outflow.left_momentum = 0
    } else {
      outflow.right = 0
      outflow.right_momentum = 0
    }
  }
  func consumeDetached() { detached = 0 }

  private var cachedVolume: Float? = 0
  var volume: Float {
    if let cachedVolume { return cachedVolume }
    let result = depths.reduce(0, +)
    cachedVolume = result
    return result
  }

  func accepts(x: Float) -> Bool {
    guard x >= origin.x, x <= origin.x + width else { return false }
    return !blockers.contains {
      x >= $0.x && x <= $0.z && origin.y >= $0.y - 1 && origin.y <= $0.w + 1
    }
  }

  func hit(x: Float, amount: Float, impulse: Float = 1) {
    cachedVolume = nil
    let index = min(depths.count - 2, max(1, Int((x - origin.x) / width * Float(depths.count - 1))))
    for j in max(0, index - 2)...min(depths.count - 1, index + 2) {
      let weight: Float = j == index ? 0.4 : abs(j - index) == 1 ? 0.22 : 0.08
      depths[j] = min(limit, depths[j] + amount * weight)
      speeds[j] = max(-8, min(8, speeds[j] + impulse * weight))
    }
  }

  func depth(at x: Float) -> Float {
    let i = min(depths.count - 1, max(0, Int((x - origin.x) / Self.spacing)))
    return heights[i]
  }

  /// Extract real volume for ballistic droplets. Never invent splash water.
  func extract(x: Float, radius: Float, fraction: Float) -> Float {
    cachedVolume = nil
    var amount: Float = 0
    for i in depths.indices where abs(origin.x + Float(i) * Self.spacing - x) <= radius {
      let taken = depths[i] * min(1, max(0, fraction))
      depths[i] -= taken
      amount += taken
    }
    return amount
  }

  func sweep(x: Float, velocity: Float, dt: Float) {
    cachedVolume = nil
    let i = min(depths.count - 2, max(1, Int((x - origin.x) / width * Float(depths.count - 1))))
    let direction = velocity < 0 ? -1 : 1
    for j in max(1, i - 2)...min(depths.count - 2, i + 2) {
      let amount = min(depths[j] * 0.3, abs(velocity) * dt * 0.035)
      depths[j] -= amount
      let destination = min(depths.count - 1, max(0, j + direction * 3))
      depths[destination] = min(limit, depths[destination] + amount)
      speeds[j] = max(-8, min(8, speeds[j] + abs(velocity) * dt * 0.04))
    }
  }

  func step(
    dt: Float, evaporates: Bool, clearing: Bool, decay: Float = 1, driesWithin: Float? = nil
  ) {
    guard volume > 0.0001 || top > 0.001 else { return }
    cachedVolume = nil
    let count = depths.count
    if id != 0 {
      let spill = depths.withUnsafeMutableBufferPointer { d in
        horizontal.withUnsafeMutableBufferPointer { v in
          scratch.withUnsafeMutableBufferPointer { mass in
            fluxScratch.withUnsafeMutableBufferPointer { momentum in
              sh_transport_water(
                d.baseAddress, v.baseAddress, mass.baseAddress, momentum.baseAddress, count,
                Self.spacing, dt)
            }
          }
        }
      }
      outflow.left += spill.left
      outflow.right += spill.right
      outflow.left_momentum += spill.left_momentum + spill.left * supportVelocity.x
      outflow.right_momentum += spill.right_momentum + spill.right * supportVelocity.x
    }
    var evaporation: Float = (clearing ? 7 : evaporates ? 0.022 : 0) * decay
    if let remaining = driesWithin {
      // Retiring rain needs a visible end, even with evaporation disabled in
      // preferences. Remove depth, rather than fading the whole water layer:
      // waves, surface tension and any late splashes keep their normal physics.
      evaporation = max(evaporation, (depths.max() ?? 0) / max(0.25, remaining))
    }
    top = depths.withUnsafeMutableBufferPointer { d in
      waves.withUnsafeMutableBufferPointer { w in
        speeds.withUnsafeMutableBufferPointer { v in
          scratch.withUnsafeMutableBufferPointer { spare in
            heights.withUnsafeMutableBufferPointer { h in
              bed.withUnsafeBufferPointer { b in
                sh_step_water(
                  d.baseAddress, w.baseAddress, v.baseAddress, spare.baseAddress,
                  h.baseAddress, b.baseAddress, count, dt, evaporation)
              }
            }
          }
        }
      }
    }
  }

}

final class MistBank {
  let id: CGWindowID
  var origin: SIMD2<Float>
  var width: Float
  var amount: Float = 0
  var blockers: [SIMD4<Float>]
  init(surface: WaterSurface) {
    id = surface.id
    origin = surface.origin
    width = surface.width
    blockers = surface.blockers
  }
}

/// Rust handles the per-particle integration, collisions and water solver without frame allocations.
final class WeatherSimulation {
  private static let capacity = 4096
  private var storage: [WeatherParticle] = []
  private(set) var particleCount = 0
  var particles: ArraySlice<WeatherParticle> { storage.prefix(particleCount) }
  private var impactStorage = [SHImpact](repeating: SHImpact(), count: 96)
  private var coreSurfaces: [SHSurface] = []
  private var coreBlockers: [SIMD4<Float>] = []
  private(set) var water: [WaterSurface] = []
  private(set) var ownsWater = true
  private weak var waterOwner: WeatherSimulation?
  private(set) var banks: [MistBank] = []
  private(set) var decorations: [WeatherParticle] = []
  private(set) var ripples: [WaterRipple] = []
  private(set) var elapsed: Double = 0
  private(set) var interaction = SIMD4<Float>(-10_000, -10_000, 0, 0)
  private(set) var interactive = false
  var time: Float { Float(elapsed.truncatingRemainder(dividingBy: 1000)) }
  private(set) var effect: WeatherEffect = .rain
  private(set) var smoke: SmokeSimulation?
  var scene = WeatherScene(primary: .rain)
  private var secondaryEmitted: Float = 0
  private var waterThrowBudget = 64
  private var nextStrike: Double = 4
  private var bolts: [WeatherParticle] = []
  private(set) var lastStrikeTarget: SIMD2<Float>?
  private(set) var flash: Float = 0
  private var windowSeenAt: [CGWindowID: Double] = [:]
  var size: SIMD2<Float>
  var intensity = Snowfall.steady
  var accumulates = true
  var evaporates = true
  var wind: Float = 0
  var density: Float = 1
  var reducedMotion = false
  private var emitted: Float = 0
  private var previousCursor: SIMD2<Float>?
  private var clearingUntil: Double = -1
  private var primed = false
  private(set) var retiring = false
  private(set) var retirementRate: Float = 1
  private var retirementAt: Double = 0
  static let waterDryingDuration: Float = 8
  private var retirementIntensity: Snowfall = .steady
  private var smokeSources: [SIMD4<Float>] = []

  func retire() {
    guard !retiring else { return }
    retiring = true
    retirementRate = 3
    retirementAt = elapsed
    retirementIntensity = intensity
    intensity = .off
  }
  func resume() {
    retiring = false
    retirementRate = 1
    intensity = retirementIntensity
  }

  private var surfaces: [WindowSurface] = []
  private var onWindows = true
  private var rng: UInt64

  init(size: SIMD2<Float>, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
    self.size = size
    rng = seed == 0 ? 1 : seed
    decorations.reserveCapacity(32)
    ripples.reserveCapacity(48)
    rebuildSurfaces()
  }

  var isEmpty: Bool {
    decorations.isEmpty && particleCount == 0 && (!ownsWater || !water.contains { $0.top > 0.01 })
      && !banks.contains { $0.amount > 0.01 } && intensity == .off
  }
  var hasContent: Bool {
    !decorations.isEmpty || particleCount > 0 || (ownsWater && water.contains { $0.volume > 0.01 })
      || banks.contains { $0.amount > 0.01 }
  }
  var groundTop: Float {
    if effect.hasWater {
      return ownsWater
        ? water.lazy.filter { $0.belowDock && $0.top > 0.025 && !$0.isOccluded }.map {
          $0.origin.y + $0.top
        }.max() ?? 0 : 0
    }
    return decorations.filter { $0.motion.w == 7 && $0.life.z == 0 }.map {
      $0.rect.y + $0.rect.w * 0.5
    }.max() ?? 0
  }

  /// One physical water field survives changes between precipitation modes. Outgoing
  /// drops can still land in it, while only its current owner steps and draws the fluid.
  func adoptWater(from outgoing: WeatherSimulation) {
    guard outgoing !== self, outgoing.ownsWater, outgoing.effect.hasWater else { return }
    water = outgoing.water
    ownsWater = true
    waterOwner = nil
    outgoing.ownsWater = false
    outgoing.waterOwner = self
    windowSeenAt = Dictionary(
      uniqueKeysWithValues: water.filter { $0.id != 0 }.map { ($0.id, elapsed - 1) })
    refreshCollisions()
  }

  func followWater(of owner: WeatherSimulation) {
    guard owner !== self else { return }
    water = owner.water
    ownsWater = false
    waterOwner = owner
    refreshCollisions()
  }
  func retainWaterOwnership() {
    ownsWater = true
    waterOwner = nil
  }

  func setEffect(_ effect: WeatherEffect) {
    guard effect != self.effect else { return }
    self.effect = effect
    scene = WeatherScene(primary: effect)
    smoke = nil
    bolts.removeAll()
    nextStrike = elapsed + 4
    secondaryEmitted = 0
    particleCount = 0
    if effect.usesSnowSimulation { storage.removeAll() }
    ripples.removeAll(keepingCapacity: true)
    emitted = 0
    primed = false
    clearingUntil = -1
    resetCursor()
    rebuildSurfaces()
  }

  func resize(_ size: SIMD2<Float>) {
    guard self.size != size else { return }
    self.size = size
    particleCount = 0
    primed = false
    smoke = nil
    rebuildSurfaces()
  }

  func updateWindows(
    _ surfaces: [WindowSurface], onWindows: Bool = true, interval: Float = 0.1,
    sliding: Bool = false, elsewhere: Set<CGWindowID> = []
  ) {
    self.surfaces = surfaces
    self.onWindows = onWindows
    guard ownsWater else {
      synchroniseWater()
      refreshCollisions()
      return
    }
    let old = Dictionary(uniqueKeysWithValues: water.map { ($0.id, $0) })
    var next = [old[0] ?? WaterSurface(id: 0, origin: .zero, width: size.x)]
    // Ground water is drawn below the actual Dock, with no rectangular cutout.
    next[0].blockers = []
    for surface in surfaces where onWindows {
      let inset = Float(surface.cornerRadius * 0.5)
      let width = Float(surface.frame.width) - inset * 2
      guard width > 16 else { continue }
      let origin = SIMD2(Float(surface.frame.minX) + inset, Float(surface.frame.maxY))
      let blockers = surface.blockers.map {
        SIMD4(Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY))
      }
      if let existing = old[surface.id], abs(existing.width - width) < 8 {
        let physical = !sliding && elapsed - (windowSeenAt[surface.id] ?? elapsed) > 0.7
        existing.move(to: origin, interval: interval, now: elapsed, physical: physical)
        existing.width = width
        existing.blockers = blockers
        next.append(existing)
      } else {
        windowSeenAt[surface.id] = elapsed
        let replacement = WaterSurface(
          id: surface.id, origin: origin, width: width, blockers: blockers, isDock: surface.isDock)
        // A live resize preserves the water already held by the supporting edge.
        if let existing = old[surface.id] {
          for (i, amount) in existing.depths.enumerated() where amount > 0 {
            replacement.hit(
              x: origin.x + width * Float(i) / Float(existing.depths.count - 1), amount: amount,
              impulse: 0)
          }
        }
        next.append(replacement)
      }
    }
    if effect.hasWater {
      let kept = Set(next.map(\.id))
      for oldSurface in water
      where oldSurface.id != 0 && !kept.contains(oldSurface.id) && oldSurface.volume > 1 {
        if !sliding && !elsewhere.contains(oldSurface.id) {
          let amount = oldSurface.extract(
            x: oldSurface.origin.x + oldSurface.width / 2, radius: oldSurface.width, fraction: 1)
          throwWater(
            amount: amount,
            at: oldSurface.origin + SIMD2(oldSurface.width * 0.5, oldSurface.top + 2),
            velocity: SIMD2(0, -30), count: 18, spread: oldSurface.width)
        }
        windowSeenAt[oldSurface.id] = nil
      }
    }
    water = next
    refreshCollisions()
    let oldBanks = Dictionary(uniqueKeysWithValues: banks.map { ($0.id, $0) })
    banks = water.filter { !$0.isDock }.map { surface in
      let bank = oldBanks[surface.id] ?? MistBank(surface: surface)
      bank.origin = surface.origin
      bank.width = surface.width
      bank.blockers = surface.blockers
      return bank
    }
  }

  private func synchroniseWater() {
    var owner = waterOwner
    for _ in WeatherEffect.allCases {
      guard let candidate = owner else { return }
      if candidate.ownsWater {
        water = candidate.water
        return
      }
      owner = candidate.waterOwner
    }
  }

  private func refreshCollisions() {
    coreSurfaces.removeAll(keepingCapacity: true)
    coreBlockers.removeAll(keepingCapacity: true)
    for surface in water {
      coreSurfaces.append(
        SHSurface(
          x: surface.origin.x, y: surface.origin.y, width: surface.width, height: surface.top,
          blocker_start: UInt32(coreBlockers.count), blocker_count: UInt32(surface.blockers.count)))
      coreBlockers.append(contentsOf: surface.blockers)
    }
  }

  func clear() {
    clearingUntil = elapsed + 4
    for i in 0..<particleCount {
      storage[i].life.y = min(storage[i].life.y, storage[i].life.x + 0.65)
    }
  }

  func resetCursor() {
    previousCursor = nil
    interaction.z = 0
    interactive = false
  }

  func step(dt rawDT: Float, cursor: SIMD2<Float>) {
    guard rawDT.isFinite, rawDT > 0, size.x > 0, size.y > 0 else { return }
    // Match the original snow/leaf contact point, in local macOS points at every display scale.
    let cursor = cursor + SIMD2<Float>(4, -8)
    let dt = min(rawDT, 0.05)
    waterThrowBudget = 64
    elapsed += Double(dt)
    if retiring { for i in 0..<particleCount { storage[i].life.x += dt * (retirementRate - 1) } }
    let clearing = elapsed < clearingUntil
    let displayIntensity = retiring ? retirementIntensity : intensity
    let multiplier: Float =
      switch displayIntensity {
      case .off: 0
      case .light: 0.5
      case .steady: 1
      case .heavy: 1.65
      case .variable: 0.7 + 0.6 * Float(0.5 + 0.5 * sin(elapsed * 0.035))
      }
    let area = min(8, size.x * size.y / 1_000_000)
    let slow: Float = reducedMotion ? 0.55 : 1
    let rate: Float =
      switch effect {
      case .rain: 100
      case .drizzle: 55
      case .storm, .lightning: 170
      case .sleet: 95
      case .hail: 70
      case .mist: 0.32
      case .clouds: 0.20
      case .sunlight: 6
      case .fireflies: 0.65
      default: 0
      }
    if !retiring, !primed, multiplier > 0, rate > 0 {
      primed = true
      let prefill: Float = effect.hasWater || effect == .hail ? 0.65 : effect == .fireflies ? 6 : 8
      let count = min(
        240,
        max(
          effect == .fireflies ? 8 : 4,
          Int(rate * area * multiplier * density * scene.strength * prefill)))
      for _ in 0..<count { append(makeParticle(initial: true)) }
    }
    if !retiring && !clearing {
      emitted += rate * area * multiplier * density * scene.strength * slow * dt
      let count = min(40, Int(emitted))
      emitted -= Float(count)
      for _ in 0..<count where particleCount < Self.capacity - 128 {
        append(makeParticle(initial: false))
      }
    }
    var velocity = SIMD2<Float>.zero
    if let previousCursor, simd_distance(previousCursor, cursor) < max(size.x, size.y) * 0.8 {
      velocity = (cursor - previousCursor) / dt
      let speed = simd_length(velocity)
      if speed > 2400 { velocity *= 2400 / speed }
    }
    let previous = previousCursor ?? cursor
    previousCursor = cursor
    let speed = simd_length(velocity)
    let strength = min(1, speed / 350)
    interaction = SIMD4(
      cursor.x, cursor.y,
      interaction.z + (strength - interaction.z) * min(1, dt * (strength > interaction.z ? 14 : 3)),
      0)
    interactive = false
    for i in coreSurfaces.indices {
      coreSurfaces[i].x = water[i].origin.x
      coreSurfaces[i].y = water[i].origin.y
      coreSurfaces[i].width = water[i].width
      coreSurfaces[i].height = water[i].top
    }
    var params = SHStep(
      dt: dt, time: time, width: size.x, height: size.y, wind: wind,
      cursor_x: cursor.x, cursor_y: cursor.y, cursor_vx: velocity.x, cursor_vy: velocity.y,
      motion_scale: slow, previous_x: previous.x, previous_y: previous.y,
      effect: effect == .storm || effect == .lightning ? 2 : 0,
      surface_count: UInt32(coreSurfaces.count), blocker_count: UInt32(coreBlockers.count))
    if !ownsWater {
      synchroniseWater()
      refreshCollisions()
    }
    let count = particleCount
    let result = storage.withUnsafeMutableBufferPointer { particles in
      coreSurfaces.withUnsafeBufferPointer { surfaces in
        coreBlockers.withUnsafeBufferPointer { blockers in
          impactStorage.withUnsafeMutableBufferPointer { impacts in
            sh_step_particles(
              particles.baseAddress, count, particles.count, &params,
              surfaces.baseAddress, blockers.baseAddress, impacts.baseAddress, impacts.count)
          }
        }
      }
    }
    particleCount = result.count
    for i in 0..<result.impact_count {
      let hit = impactStorage[i]
      guard Int(hit.surface_index) < water.count else { continue }
      let surface = water[Int(hit.surface_index)]
      if effect.hasWater && accumulates && !clearing {
        surface.hit(x: hit.x, amount: hit.amount, impulse: hit.impulse)
        addRipple(at: SIMD2(hit.x, surface.origin.y), strength: 0.8)
      }
      if hit.kind != 5, i < 16 {
        splash(
          at: SIMD2(hit.x, hit.y),
          count: reducedMotion ? 1 : hit.kind == 9 ? min(24, 6 + Int(hit.amount * 2)) : 3,
          ice: hit.kind == 1, energy: hit.kind == 9 ? min(3, hit.impulse / 2) : 1)
      }
    }
    if effect.hasWater && ownsWater {
      for surface in water {
        let distance = simd_distance(previous, cursor)
        let steps = min(160, max(1, Int(ceil(distance / 7))))
        var contact: SIMD2<Float>?
        if surface.top > 0.1 && speed > 8 {
          for j in 0...steps {
            let point = previous + (cursor - previous) * (Float(j) / Float(steps))
            guard surface.accepts(x: point.x), point.y >= surface.origin.y - 12,
              point.y <= surface.origin.y + surface.depth(at: point.x) + 12
            else { continue }
            let horizontal =
              abs(velocity.x) > 15
              ? velocity.x : (point.x < size.x / 2 ? -1 : 1) * max(80, abs(velocity.y) * 0.6)
            surface.sweep(x: point.x, velocity: horizontal, dt: dt / Float(steps + 1))
            surface.hit(x: point.x, amount: 0, impulse: min(7, speed * 0.014) / Float(steps + 1))
            contact = point
            interactive = true
            if speed > 480 && waterThrowBudget > 0 && particleCount < Self.capacity - 64 {
              let amount = surface.extract(
                x: point.x, radius: 9, fraction: min(0.7, (speed - 350) / 1800))
              let launch = SIMD2(
                velocity.x * 0.48, max(100, min(650, abs(velocity.y) * 0.4 + speed * 0.18)))
              throwWater(
                amount: amount,
                at: SIMD2(point.x, surface.origin.y + surface.depth(at: point.x) + 3),
                velocity: launch, count: reducedMotion ? 2 : 5)
            }
          }
        }
        if let point = contact {
          addRipple(at: SIMD2(point.x, surface.origin.y), strength: min(3, speed / 250 + 0.5))
          if speed > 300 {
            splash(
              at: SIMD2(point.x, surface.origin.y + surface.depth(at: point.x)),
              count: reducedMotion ? 2 : min(20, Int(speed / 100)), ice: false,
              energy: min(3, speed / 500))
          }
        }
        surface.settleMotion(now: elapsed)
        let drying = retiring ? Self.waterDryingDuration - Float(elapsed - retirementAt) : nil
        surface.step(
          dt: dt, evaporates: retiring || evaporates || !accumulates,
          clearing: clearing || !accumulates, decay: retirementRate, driesWithin: drying)
        for left in [true, false] {
          let amount = left ? surface.outflow.left : surface.outflow.right
          let momentum = left ? surface.outflow.left_momentum : surface.outflow.right_momentum
          if amount > 0.02, waterThrowBudget > 0, particleCount < Self.capacity - 32 {
            let edge = surface.origin.x + (left ? -5 : surface.width + 5)
            let point = SIMD2(edge, surface.origin.y + surface.top + 1)
            throwWater(
              amount: amount, at: point,
              velocity: SIMD2(
                max(-650, min(650, momentum / amount)),
                min(650, max(0, surface.supportVelocity.y * 0.8))),
              count: min(10, max(2, Int(amount * 2))), spread: 3)
            surface.consumeOutflow(left: left)
          }
        }
        if surface.detached > 0.02, waterThrowBudget > 0, particleCount < Self.capacity - 32 {
          throwWater(
            amount: surface.detached, at: surface.detachedAt, velocity: surface.detachedVelocity,
            count: 18, spread: surface.width)
          surface.consumeDetached()
        }
      }
    }
    for i in ripples.indices { ripples[i].age += dt }
    ripples.removeAll { $0.age > 1.5 }
    // Light secondary layers are emitted in the same bounded particle storage.
    if !retiring && !clearing {
      secondaryEmitted +=
        (scene.fireflies * 0.65 + scene.sunlight * 4) * area * multiplier * density * dt
    }
    if secondaryEmitted >= 1 && !clearing && !retiring {
      secondaryEmitted -= 1
      let secondary: WeatherEffect = scene.fireflies > 0 ? .fireflies : .sunlight
      append(makeParticle(initial: false, mode: secondary))
    }
    updateDecorations(dt: dt, multiplier: multiplier, clearing: clearing)
    if retiring {
      // Large shafts and overhead clouds dissipate as volumes; falling particles keep their
      // own staggered ages. Banks already dissipate through their density state.
      let volumeLife = max(0, 1 - Float(elapsed - retirementAt) * retirementRate / 12)
      for i in decorations.indices where decorations[i].motion.w != 7 {
        decorations[i].color.w *= volumeLife
      }
      decorations.removeAll { $0.color.w < 0.001 }
    }
    let smoky =
      (!retiring
        && (effect.hasBanks || effect == .storm || effect == .lightning || scene.clouds > 0))
      || decorations.contains { $0.motion.w == 7 || $0.motion.w == 12 }
      || particles.contains { $0.motion.w == 2 }
    if smoky && multiplier > 0 {
      if smoke == nil { smoke = SmokeSimulation(size: size) }
      smokeSources.removeAll(keepingCapacity: true)
      for p in decorations where p.motion.w == 7 || p.motion.w == 12 {
        smokeSources.append(SIMD4(p.rect.x, p.rect.y, p.rect.z * 0.5, max(22, p.rect.w * 0.5)))
      }
      for p in particles where p.motion.w == 2 {
        smokeSources.append(SIMD4(p.rect.x, p.rect.y, p.rect.z * 0.5, p.rect.w * 0.5))
      }
      smoke?.step(
        dt: dt, time: time, wind: wind, cursor: SIMD4(cursor.x, cursor.y, velocity.x, velocity.y),
        previous: previous, sources: smokeSources)
    } else {
      smoke = nil
    }

  }

  private func updateDecorations(dt: Float, multiplier: Float, clearing: Bool) {
    decorations.removeAll(keepingCapacity: true)
    stormDecorations(dt: dt, multiplier: multiplier, clearing: clearing)
    if effect == .mist || effect == .clouds {
      for bank in banks {
        let target: Float =
          !retiring && !clearing && accumulates && multiplier > 0 ? min(1.2, 0.8 * multiplier) : 0
        bank.amount +=
          (target - bank.amount)
          * min(
            1,
            dt * retirementRate
              * (clearing || !accumulates ? 2 : target < bank.amount ? 0.18 : 0.38))
        guard bank.amount > 0.01 else { continue }
        let height: Float = (effect == .mist ? 23 : 36) * bank.amount
        decorations.append(
          WeatherParticle(
            rect: SIMD4(
              bank.origin.x + bank.width * 0.5, bank.origin.y + height * 0.5, bank.width, height),
            motion: SIMD4(0, 0, Float(bank.id % 97) * 0.013, 7),
            color: SIMD4(0.88, 0.91, 0.97, (effect == .mist ? 0.50 : 0.43) * bank.amount),
            life: SIMD4(2, 10000, Float(bank.id), effect == .mist ? 0 : 1)))
      }
    }
    if (effect == .sunlight || scene.sunlight > 0) && multiplier > 0 && !clearing {
      for i in 0..<2 {
        let x = size.x * (0.14 + Float(i) * 0.16) + sin(time * 0.035 + Float(i)) * 12
        decorations.append(
          WeatherParticle(
            rect: SIMD4(
              x, size.y * 0.63, (75 + Float(i) * 22) * min(1.5, multiplier), size.y * 0.88),
            motion: SIMD4(0.32, -1, Float(i) * 0.31, 8),
            color: SIMD4(1, 0.84, 0.42, 0.16 * (effect == .sunlight ? 1 : scene.sunlight)),
            life: SIMD4(2, 10000, 0, 0)))
      }
    }
  }

  private func stormDecorations(dt: Float, multiplier: Float, clearing: Bool) {
    let storm = effect == .storm || effect == .lightning
    let cover: Float = storm ? 1 : effect == .clouds ? 0.65 : scene.clouds
    if cover > 0 && multiplier > 0 && !clearing {
      let height = min(size.y * 0.25, storm ? 180 : 100) * (0.65 + 0.35 * cover)
      decorations.append(
        WeatherParticle(
          rect: SIMD4(size.x * 0.5, size.y - height * 0.35, size.x * 1.1, height * 1.5),
          motion: SIMD4(0, 0, 0.37, 12),
          color: storm ? SIMD4(0.20, 0.23, 0.28, 0.94) : SIMD4(0.78, 0.83, 0.90, 0.62 * cover),
          life: SIMD4(2, 10000, 0, storm ? 1 : 0)))
    }
    for i in bolts.indices { bolts[i].life.x += dt * retirementRate }
    bolts.removeAll { $0.life.x > $0.life.y }
    flash = max(0, flash - dt * 5)
    if effect == .lightning && multiplier > 0 && !retiring && !clearing && !reducedMotion
      && elapsed >= nextStrike
    {
      nextStrike = elapsed + Double(range(7, 17))
      let candidates = surfaces.filter {
        $0.frame.maxY < CGFloat(size.y - 80) && $0.frame.width > 50
      }
      var target = SIMD2(range(30, max(31, size.x - 30)), Float(0))
      if !candidates.isEmpty && unit() < 0.72 {
        for _ in 0..<min(24, candidates.count * 4) {
          let surface = candidates[min(candidates.count - 1, Int(unit() * Float(candidates.count)))]
          let x = range(Float(surface.frame.minX + 20), Float(surface.frame.maxX - 20))
          let point = CGPoint(x: CGFloat(x), y: surface.frame.maxY)
          guard !surface.blockers.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) })
          else { continue }
          target = SIMD2(x, Float(surface.frame.maxY))
          break
        }
      }
      lastStrikeTarget = target
      let start = SIMD2(
        min(size.x - 15, max(15, target.x + range(-180, 180))), size.y - range(35, 65))
      let segments = max(8, Int(simd_distance(start, target) / 24))
      var previous = start
      for i in 1...segments {
        var end = start + (target - start) * (Float(i) / Float(segments))
        if i != segments { end.x += range(-22, 22) }
        addBolt(from: previous, to: end, width: range(5, 8), alpha: 1)
        if i > 2 && i < segments - 2 && unit() < 0.22 {
          let branch = end + SIMD2(range(-65, 65), -range(15, 60))
          addBolt(from: end, to: branch, width: 3, alpha: 0.55)
        }
        previous = end
      }
      flash = 0.6
      if let pool = water.first(where: {
        abs($0.origin.y - target.y) < 4 && $0.accepts(x: target.x)
      }) {
        addRipple(at: SIMD2(target.x, pool.origin.y), strength: 2)
      }
    }
    decorations.append(contentsOf: bolts)
  }

  private func addBolt(from a: SIMD2<Float>, to b: SIMD2<Float>, width: Float, alpha: Float) {
    let delta = b - a
    bolts.append(
      WeatherParticle(
        rect: SIMD4((a.x + b.x) / 2, (a.y + b.y) / 2, width, simd_length(delta) + 2),
        motion: SIMD4(delta.x, delta.y, unit(), 11), color: SIMD4(0.79, 0.86, 1, alpha),
        life: SIMD4(0, 0.3, 0, 0)))
  }

  private func rebuildSurfaces() {
    water = [WaterSurface(id: 0, origin: .zero, width: size.x)]
    banks.removeAll(keepingCapacity: true)
    updateWindows(surfaces, onWindows: onWindows)
  }

  private func makeParticle(initial: Bool, mode: WeatherEffect? = nil) -> WeatherParticle {
    let effect = mode ?? self.effect
    let point = SIMD2(range(-20, size.x + 20), initial ? range(0, size.y) : size.y + range(5, 45))
    switch effect {
    case .rain, .drizzle, .storm, .lightning: return drop(at: point, splash: false)
    case .sleet, .hail:
      if effect == .sleet && unit() < 0.6 { return drop(at: point, splash: false) }
      let diameter = range(effect == .hail ? 3.5 : 2.8, effect == .hail ? 6.5 : 4.2)
      return WeatherParticle(
        rect: SIMD4(point.x, point.y, diameter, diameter),
        motion: SIMD4(wind * 0.5, -range(350, 650), unit(), 1),
        color: SIMD4(0.8, 0.92, 1, 0.9), life: SIMD4(0, 12, 0, 0))
    case .mist, .clouds:
      let mist = effect == .mist
      let width = range(mist ? 220 : 200, mist ? 440 : 350)
      // A stable depth choice keeps most cloud wisps behind application content.
      let background: Float = !mist && unit() < 0.82 ? 1 : 0
      return WeatherParticle(
        rect: SIMD4(range(0, size.x), range(0, size.y), width, width * range(0.23, 0.39)),
        motion: SIMD4(range(-5, 8), range(-1, 1), unit(), 2),
        color: SIMD4(0.86, 0.9, 0.97, mist ? 0.55 : 0.58),
        life: SIMD4(initial ? range(1, 7) : 0, range(20, 34), background, mist ? 0 : 1))
    case .sunlight, .fireflies:
      let firefly = effect == .fireflies
      let diameter = range(firefly ? 13 : 6, firefly ? 21 : 10)
      let groups = min(7, max(3, Int(size.x * size.y / 600_000) + 2))
      let group = Float(Int(unit() * Float(groups)))
      return WeatherParticle(
        rect: SIMD4(
          range(25, max(26, size.x - 25)), range(35, max(36, size.y - 35)), diameter, diameter),
        motion: SIMD4(range(-18, 18), range(-12, 12), unit(), firefly ? 4 : 3),
        color: firefly ? SIMD4(1, 0.92, 0.38, 0.95) : SIMD4(1, 0.84, 0.38, 0.82),
        life: SIMD4(
          initial ? range(0.6, 3) : 0, range(firefly ? 18 : 12, firefly ? 32 : 24), group, 0))
    default: return drop(at: point, splash: false)
    }
  }

  private func drop(at point: SIMD2<Float>, splash: Bool) -> WeatherParticle {
    let drizzle = effect == .drizzle
    let speed = range(
      drizzle ? 290 : 650, (effect == .storm || effect == .lightning) ? 1200 : drizzle ? 470 : 930)
    return WeatherParticle(
      rect: SIMD4(
        point.x, point.y,
        splash ? range(2.2, 3.2) : range(drizzle ? 2.2 : 2.7, drizzle ? 2.8 : 3.8),
        splash ? range(3, 6) : speed * (drizzle ? 0.024 : 0.029)),
      motion: SIMD4(
        splash ? range(-110, 110) : wind + (effect == .storm || effect == .lightning ? 80 : 12),
        splash ? range(50, 160) : -speed, unit(), splash ? 5 : 0),
      color: SIMD4(0.74, 0.86, 0.97, splash ? 0.7 : range(0.65, 0.88)),
      life: SIMD4(0, splash ? range(0.35, 0.7) : 16, 0, 0))
  }

  private func splash(at point: SIMD2<Float>, count: Int, ice: Bool, energy: Float = 1) {
    for _ in 0..<count where particleCount < Self.capacity - 128 {
      var p = drop(at: point + SIMD2(0, 2), splash: true)
      p.motion.x *= energy
      p.motion.y *= energy
      p.life.y = max(p.life.y, p.motion.y / 475 + 0.15)
      if ice { p.color = SIMD4(0.88, 0.95, 1, 0.7) }
      append(p)
    }
  }

  private func throwWater(
    amount: Float, at point: SIMD2<Float>, velocity: SIMD2<Float>, count: Int, spread: Float = 12
  ) {
    guard amount > 0.02 else { return }
    let count = min(count, max(1, Int(amount * 2)), Self.capacity - particleCount, waterThrowBudget)
    guard count > 0 else { return }
    waterThrowBudget -= count
    for i in 0..<count {
      let mass = amount / Float(count)
      let diameter = min(11, max(3, sqrt(mass) * 3))
      let x = point.x + (Float(i) / Float(max(1, count - 1)) - 0.5) * spread
      append(
        WeatherParticle(
          rect: SIMD4(x, point.y, diameter, diameter * 1.3),
          motion: SIMD4(velocity.x + range(-65, 65), velocity.y + range(0, 95), unit(), 9),
          color: SIMD4(0.70, 0.85, 0.97, 0.9), life: SIMD4(0, 14, mass, 0)))
    }
  }

  private func append(_ particle: WeatherParticle) {
    guard particleCount < Self.capacity else { return }
    if storage.isEmpty {
      storage = [WeatherParticle](repeating: WeatherParticle(), count: Self.capacity)
    }
    storage[particleCount] = particle
    particleCount += 1
  }

  private func addRipple(at point: SIMD2<Float>, strength: Float) {
    if ripples.count == 32 { ripples.removeFirst() }
    // Coalesce impacts at the same spot rather than making the shader loop over redundant rings.
    if let last = ripples.last, last.age < 0.08, simd_distance(last.point, point) < 12 { return }
    ripples.append(WaterRipple(point: point, age: 0, strength: strength))
  }

  private func unit() -> Float {
    rng ^= rng >> 12
    rng ^= rng << 25
    rng ^= rng >> 27
    return Float((rng &* 2_685_821_657_736_338_717) >> 40) / Float(1 << 24)
  }
  private func range(_ low: Float, _ high: Float) -> Float { low + (high - low) * unit() }
}
