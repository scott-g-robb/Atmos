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
  private var liquidImpulse: [SIMD2<Float>]
  private var sustainedPressure=false
  private(set) var foam: Float = 0
  private(set) var foamCenter: Float = 0
  private(set) var foamRadius: Float = 40
  private(set) var supportVelocity = SIMD2<Float>.zero
  private var lastMotionAt: Double = -1
  private(set) var outflow = SHWaterOutflow()
  struct Release {
    var amount: Float
    var point: SIMD2<Float>
    var velocity: SIMD2<Float>
    var continuous=false
  }
  private var releaseStorage: [Release] = []
  private var releaseHead = 0
  var releases: ArraySlice<Release> { releaseStorage[releaseHead...] }
  var detached: Float { releases.reduce(0) { $0 + $1.amount } }
  var meanWorldVelocity: SIMD2<Float> {
    let relative = zip(horizontal, depths).reduce(Float(0)) { $0 + $1.0 * $1.1 } / max(0.001, volume)
    return supportVelocity + SIMD2(relative, 0)
  }
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
    limit = id == 0 ? 24 : 5.85
    let count = max(3, Int(ceil(max(width, 1) / Self.spacing)) + 1)
    depths = Array(repeating: 0, count: count)
    waves = depths
    speeds = depths
    scratch = depths
    heights = depths
    horizontal = depths
    fluxScratch = depths
    liquidImpulse = Array(repeating: .zero, count: count)
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
    impart(velocity, interval: interval)
    origin = point
    lastMotionAt = now
  }

  func settleMotion(now: Double) {
    if now - lastMotionAt > 0.04 && supportVelocity != .zero { impart(.zero, interval: Float(now - lastMotionAt)) }
  }

  private func impart(_ velocity: SIMD2<Float>, interval: Float) {
    let dt = max(1 / 120, min(0.1, interval))
    let delta = velocity - supportVelocity
    let acceleration = delta / dt
    if simd_length(delta)>350 && volume>0.1 {foam = max(foam,min(1,(simd_length(delta)-300)/600))}
    foamCenter=origin.x+width*0.5;foamRadius=width
    // Loss of contact follows the normal force. Water leaves with its existing world
    // momentum; slowing an upward window and accelerating it downward use the same rule.
    let separating = max(0, -acceleration.y - 950)
    if separating > 0 && volume > 0.001 {
      cachedVolume = nil
      // Detach the local fluid column, never a fixed number of evenly spaced drops.
      // Neighbour pressure/cohesion subsequently keeps this fluid in sheets and ligaments.
      for j in depths.indices {
        let adhesion = 180 / max(0.3, depths[j])
        let fraction = 1 - exp(-max(0, separating - adhesion) / 950 * dt * 8)
        let mass = depths[j] * fraction
        guard mass > 0.0001 else { continue }
        let x = Float(j) / Float(depths.count - 1) * width
        let height = max(0, depths[j] - bed[j] + waves[j])
        let velocity = supportVelocity + SIMD2(horizontal[j], speeds[j])
        depths[j] -= mass
        liquidImpulse[j] = velocity
        appendRelease(Release(amount: mass, point: origin + SIMD2(x, height * 0.5), velocity: velocity))
      }
    }
    for i in horizontal.indices { horizontal[i] = max(-1200, min(1200, horizontal[i] - delta.x)) }
    supportVelocity = velocity
  }

  private func appendRelease(_ release: Release) {
    // Compact only after a full queue's worth has been consumed, so a busy
    // producer cannot turn alternating single pops/appends into quadratic work.
    if releaseHead >= 2048 {
      releaseStorage.removeFirst(releaseHead)
      releaseHead = 0
    }
    if releases.count < 2048 { releaseStorage.append(release) }
    else {
      let i = releaseStorage.count - 1, total = releaseStorage[i].amount + release.amount
      releaseStorage[i].point = (releaseStorage[i].point * releaseStorage[i].amount + release.point * release.amount) / total
      releaseStorage[i].velocity = (releaseStorage[i].velocity * releaseStorage[i].amount + release.velocity * release.amount) / total
      releaseStorage[i].amount = total
    }
  }
  func consumeRelease() {
    guard releaseHead < releaseStorage.count else { return }
    releaseHead += 1
    if releaseHead == releaseStorage.count {
      releaseStorage.removeAll(keepingCapacity: true)
      releaseHead = 0
    }
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
      depths[j] = id == 0 ? min(limit, depths[j] + amount * weight) : depths[j] + amount * weight
      speeds[j] = max(-8, min(8, speeds[j] + impulse * weight))
    }
  }

  /// Match the rendered cubic waterline so floating material never snaps between columns.
  func depth(at x: Float) -> Float {
    let column = max(
      0, min(Float(heights.count - 1) - 0.0001, (x - origin.x) / width * Float(heights.count - 1)))
    let i = Int(column)
    let t = column - Float(i)
    let a = heights[max(0, i - 1)]
    let b = heights[i]
    let c = heights[i + 1]
    let d = heights[min(heights.count - 1, i + 2)]
    let t2 = t * t
    let t3 = t * t * t
    let value =
      0.5
      * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
    var result = max(max(0, min(b, c) - 0.2), min(max(b, c) + 0.2, value))
    if origin.y > 0.5 {
      let edge = min(x - origin.x, origin.x + width - x)
      let t = max(0, min(1, edge / 10))
      result *= t * t * (3 - 2 * t)
    }
    return result
  }

  /// Surface flow for buoyant material; support inertia and local slopes both contribute.
  func current(at x: Float) -> Float {
    let i = min(depths.count - 2, max(1, Int((x - origin.x) / Self.spacing)))
    let slope = (heights[i + 1] - heights[i - 1]) / (2 * Self.spacing)
    return max(-65, min(65, horizontal[i] * 0.12 - slope * 18))
  }

  /// Extract real volume for ballistic droplets. Never invent splash water.
  func extract(x: Float, radius: Float, fraction: Float) -> Float {
    cachedVolume = nil
    var amount: Float = 0
    guard let columns = columns(near: x, radius: radius) else { return 0 }
    let fraction = min(1, max(0, fraction))
    for i in columns where abs(origin.x + Float(i)/Float(depths.count-1)*width - x) <= radius {
      let taken = depths[i] * fraction
      depths[i] -= taken
      amount += taken
    }
    return amount
  }

  /// A solid circular collider excludes real fluid volume. The displaced volume
  /// goes around its boundary; only collision momentum can lift it into free liquid.
  @discardableResult
  func collide(cursor: SIMD2<Float>, previous: SIMD2<Float>, velocity: SIMD2<Float>, dt: Float) -> Bool {
    guard volume > 0.0001 else { return false }
    let stroke = cursor - previous
    let distance = simd_length(stroke)
    let steps = min(100, max(1, Int(ceil(distance / 5))))
    var touched = false
    for step in 1...steps {
      let centre = previous + stroke * (Float(step) / Float(steps))
      let lower=max(0,Int(floor((centre.x-11-origin.x)/width*Float(depths.count-1))))
      let upper=min(depths.count-1,Int(ceil((centre.x+11-origin.x)/width*Float(depths.count-1))))
      guard lower<=upper else {continue}
      for i in lower...upper {
        let x = origin.x + Float(i) / Float(depths.count - 1) * width
        let dx = x - centre.x, radius: Float = 11
        guard abs(dx) < radius, accepts(x: x), depths[i] > 0.001 else { continue }
        let half = sqrt(max(0, radius * radius - dx * dx))
        let bottom = max(0, centre.y - half - origin.y)
        guard centre.y + half > origin.y, depths[i] > bottom else { continue }
        touched = true; cachedVolume = nil
        let cap = max(bottom,centre.y + half - origin.y)
        let above = max(0,depths[i]-cap)
        if above > 0.001 {
          // A height field cannot represent an overhang. Transfer just this upper
          // layer to the free-liquid solver so it can flow OVER a submerged collider.
          appendRelease(Release(amount:above,point:SIMD2(x,origin.y+cap+above*0.5),
            velocity:supportVelocity+SIMD2(horizontal[i],speeds[i])))
        }
        let amount = max(0,min(depths[i],cap)-bottom)
        let point = SIMD2(x, origin.y + max(bottom, depths[i]))
        var normal = point - centre
        normal /= max(0.001, simd_length(normal))
        let closing = max(0, simd_dot(velocity, normal))
        var impulse = normal * closing
        // A downward impact compresses water against the supporting ledge. The
        // displaced volume exits upward around the cursor rather than losing all
        // entry energy because the top-surface normal faces against the stroke.
        let down = max(0,-velocity.y)
        let confinement = min(1,amount/max(1,half))
        let rebound = down * sqrt(confinement) * 0.65
        impulse.y = max(impulse.y,rebound)
        impulse.x += (dx < 0 ? -1 : 1) * rebound * 0.25
        if simd_length(velocity)>350 && centre.y<point.y && amount>0.15 && max(closing,rebound)>180 {foam = max(foam,min(1,(max(closing,rebound)-150)/450));foamCenter=x;foamRadius=35}
        depths[i] = bottom
        // Available kinetic energy versus the gravitational binding head.
        if impulse.y > sqrt(2 * 950 * max(0.5, depths[i] + amount)) {
          appendRelease(Release(amount: amount, point: centre + normal * radius,
            velocity: supportVelocity + SIMD2(horizontal[i], speeds[i]) + impulse))
        } else {
          let side: Float = dx == 0 ? (velocity.x < 0 ? -1 : 1) : (dx < 0 ? -1 : 1)
          let destinationX = centre.x + side * (radius + Self.spacing)
          let j = max(0, min(depths.count - 1, Int(((destinationX-origin.x)/width*Float(depths.count-1)).rounded())))
          depths[j] += amount
          horizontal[j] += impulse.x * amount / max(0.01, depths[j])
          speeds[j] += impulse.y * amount / max(0.01, depths[j])
        }
        for k in max(0,i-3)...min(depths.count-1,i+3) {
          liquidImpulse[k] += impulse * (1-Float(abs(k-i))/4) / Float(steps)
        }
      }
    }
    return touched
  }

  func kick(x:Float,radius:Float,velocity:SIMD2<Float>,sustained:Bool=false) {
    if sustained {sustainedPressure=true}
    if simd_length(velocity)>350 {foam=max(foam,min(1,simd_length(velocity)/700));foamCenter=x;foamRadius=radius}
    guard let columns = columns(near: x, radius: max(1, radius)) else { return }
    for i in columns {
      let px=origin.x+Float(i)/Float(depths.count-1)*width
      let weight=max(0,1-abs(px-x)/max(1,radius))
      liquidImpulse[i]+=velocity*weight
    }
  }

  private func columns(near x: Float, radius: Float) -> ClosedRange<Int>? {
    let scale = Float(depths.count - 1) / width
    let lower = max(0, Int(floor((x - radius - origin.x) * scale)))
    let upper = min(depths.count - 1, Int(ceil((x + radius - origin.x) * scale)))
    return lower <= upper ? lower...upper : nil
  }

  func velocity(at x: Float) -> SIMD2<Float> {
    let i = max(0,min(depths.count-1,Int((x-origin.x)/width*Float(depths.count-1))))
    return supportVelocity + SIMD2(horizontal[i],speeds[i]) + liquidImpulse[i]
  }

  func sweep(x: Float, velocity: Float, dt: Float) {
    _ = collide(cursor: SIMD2(x,origin.y+1), previous: SIMD2(x-velocity*dt,origin.y+1),
      velocity: SIMD2(velocity,0), dt: dt)
  }

  func releaseAll() {
    cachedVolume = nil
    for i in depths.indices where depths[i] > 0.0001 {
      let x=origin.x+Float(i)/Float(depths.count-1)*width
      appendRelease(Release(amount: depths[i], point: SIMD2(x,origin.y+max(0,depths[i]-bed[i])*0.5),
        velocity: velocity(at:x)))
      depths[i]=0
    }
  }

  func step(
    dt: Float, evaporates: Bool, clearing: Bool, decay: Float = 1, driesWithin: Float? = nil
  ) {
    guard volume > 0.0001 || top > 0.001 else { return }
    cachedVolume = nil
    let count = depths.count
    foam *= exp(-dt * 6)
    let pressureDecay = exp(-dt * 9)
    var strongestPressure:Float=0
    for i in liquidImpulse.indices {
      liquidImpulse[i] *= pressureDecay
      strongestPressure=max(strongestPressure,liquidImpulse[i].y)
      let up=liquidImpulse[i].y,head=depths[i]
      if sustainedPressure && head>0.03 && up>max(120,sqrt(2*950*head)) {
        // A pressure impulse persists in the fluid field and feeds a continuous
        // jet until its energy dissipates, instead of one isolated row of beads.
        let energy=max(0,1-2*950*head/(up*up))
        let fraction=min(0.2,energy*dt*6),mass=head*fraction
        if mass>0.001 {
          let x=origin.x+Float(i)/Float(depths.count-1)*width
          appendRelease(Release(amount:mass,point:SIMD2(x,origin.y+max(0,head-bed[i])),
            velocity:supportVelocity+SIMD2(horizontal[i],speeds[i])+liquidImpulse[i],continuous:true))
          depths[i]-=mass
          liquidImpulse[i] *= sqrt(max(0,1-fraction))
        }
      }
    }
    if strongestPressure<120 {sustainedPressure=false}
    if id != 0 {
      let spill = depths.withUnsafeMutableBufferPointer { d in
        horizontal.withUnsafeMutableBufferPointer { v in
          scratch.withUnsafeMutableBufferPointer { mass in
            fluxScratch.withUnsafeMutableBufferPointer { momentum in
              sh_transport_water(
                d.baseAddress, v.baseAddress, mass.baseAddress, momentum.baseAddress, count,
                Self.spacing, dt, limit)
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
  private static let capacity = 8192
  private var storage: [WeatherParticle] = []
  private(set) var particleCount = 0
  var particles: ArraySlice<WeatherParticle> { storage.prefix(particleCount) }
  private var impactStorage = [SHImpact](repeating: SHImpact(), count: 8192)
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
  private(set) var dynamics: WeatherDynamics?
  var airflow: WindField?
  private let birds = BirdFlock()
  func updateDynamics(dt: Float) {
    if let target = scene.dynamics {
      dynamics = dynamics?.approach(target, dt: dt) ?? target
      wind = dynamics!.wind(at: elapsed)
    } else {
      dynamics = nil
    }
  }
  private var secondaryEmitted: Float = 0
  private var impactSplashBudget = 24
  private var puddleSplashSamples: [CGWindowID:Int] = [:]
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
  var manualWind = false
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
    decorations.isEmpty && particleCount == 0 && (!ownsWater || !water.contains {
      $0.top > 0.01 || $0.detached > 0.001 || $0.outflow.left + $0.outflow.right > 0.02
    })
      && !banks.contains { $0.amount > 0.01 }
      && (intensity == .off || (effect == .none && scene.clouds == 0 && scene.sunlight == 0))
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
    birds.reset()
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
      let inset = Float(surface.cornerRadius)
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
          oldSurface.releaseAll()
          while let release = oldSurface.releases.first, particleCount < Self.capacity - 32 {
            appendLiquid(release)
            oldSurface.consumeRelease()
          }
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
    impactSplashBudget = reducedMotion ? 8 : max(24,min(144,water.count*12))
    puddleSplashSamples.removeAll(keepingCapacity:true)
    elapsed += Double(dt)
    if retiring { for i in 0..<particleCount { storage[i].life.x += dt * (retirementRate - 1) } }
    let clearing = elapsed < clearingUntil
    updateDynamics(dt: dt)
    let displayIntensity = retiring ? retirementIntensity : intensity
    let presetMultiplier: Float =
      switch displayIntensity {
      case .off: 0
      case .light: 0.5
      case .steady: 1
      case .heavy: 1.65
      case .variable: 0.7 + 0.6 * Float(0.5 + 0.5 * sin(elapsed * 0.035))
      }
    let multiplier: Float =
      scene.dynamics != nil
      ? (displayIntensity == .off
        ? 0
        : (effect.hasWater || effect == .snow || effect == .hail
          ? dynamics?.precipitationStrength ?? 1 : 1))
      : presetMultiplier
    let layerStrength: Float = scene.dynamics != nil && !effect.isStacked ? 1 : scene.strength
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
      case .butterflies: 0.18
      default: 0
      }
    if !retiring, !primed, multiplier > 0, rate > 0 {
      primed = true
      let prefill: Float = effect.hasWater || effect == .hail ? 0.65 : effect == .fireflies ? 6 : 8
      let count = min(
        240,
        max(
          effect == .fireflies ? 8 : 4,
          Int(rate * area * multiplier * density * layerStrength * prefill)))
      for _ in 0..<count { append(makeParticle(initial: true)) }
    }
    if !retiring && !clearing {
      emitted += rate * area * multiplier * density * layerStrength * slow * dt
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
      effect: dynamics != nil || manualWind ? 1 : effect == .storm || effect == .lightning ? 2 : 0,
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
    if let airflow, !airflow.cells.isEmpty {
      storage.withUnsafeMutableBufferPointer { particles in
        airflow.cells.withUnsafeBufferPointer { cells in
          sh_apply_airflow(
            particles.baseAddress, particleCount, cells.baseAddress, airflow.columns, airflow.rows,
            airflow.spacing, wind, dt)
        }
      }
    }
    for i in 0..<result.impact_count {
      let hit = impactStorage[i]
      guard Int(hit.surface_index) < water.count else { continue }
      let surface = water[Int(hit.surface_index)]
      if effect.hasWater && accumulates && !clearing {
        surface.hit(x: hit.x, amount: hit.amount, impulse: hit.impulse)
        addRipple(
          at: SIMD2(hit.x, surface.origin.y), strength: min(1.7,0.35+abs(hit.impulse)*0.16))
        if hit.kind==0 || hit.kind==9 {impactSplash(surface:surface,x:hit.x,velocity:SIMD2(hit.vx,hit.vy),amount:hit.amount)}
      }
    }
    if effect.hasWater && ownsWater {
      for surface in water {
        if surface.collide(cursor: cursor, previous: simd_distance(previous,cursor) < 400 ? previous : cursor,
          velocity: velocity, dt: dt) {
          interactive = true
          if speed > 8 { addRipple(at: SIMD2(cursor.x,surface.origin.y), strength: min(3,speed/250)) }
        }
        surface.settleMotion(now: elapsed)
        let drying = retiring ? Self.waterDryingDuration - Float(elapsed - retirementAt) : nil
        surface.step(dt: dt, evaporates: retiring || evaporates || !accumulates,
          clearing: clearing || !accumulates, decay: retirementRate * (dynamics?.evaporation ?? 1),
          driesWithin: drying)
        // Spend the available samples across this frame's releases, rather than
        // letting an early column fill the pool and delaying the rest for seconds.
        var pending=water.reduce(0) {$0+$1.releases.count}
        if pending>0 && pending>Self.capacity-particleCount-64 {coalesceLiquid()}
        while let release=surface.releases.first, particleCount<Self.capacity-32 {
          let share=max(1,(Self.capacity-particleCount-32)/max(1,pending))
          appendLiquid(release,maximum:share);surface.consumeRelease();pending-=1
        }
        for left in [true,false] {
          let amount=left ? surface.outflow.left:surface.outflow.right
          if amount>0.0001,particleCount<Self.capacity-32 {
            let momentum=left ? surface.outflow.left_momentum:surface.outflow.right_momentum
            let x=surface.origin.x+(left ? 0:surface.width)
            appendLiquid(WaterSurface.Release(amount:amount,point:SIMD2(x,surface.origin.y+surface.depth(at:x)),
              velocity:SIMD2(momentum/amount,surface.supportVelocity.y)))
            surface.consumeOutflow(left:left)
          }
        }
      }
    }
    storage.withUnsafeMutableBufferPointer { p in
      sh_couple_liquid(p.baseAddress, particleCount, dt, cursor.x,cursor.y,velocity.x,velocity.y)
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
    if effect == .birds {
      birds.step(
        dt: dt, size: size, surfaces: surfaces, wind: wind, airflow: airflow,
        cursor: SIMD2(interaction.x, interaction.y),
        active: !retiring && !clearing && multiplier > 0, reducedMotion: reducedMotion)
      decorations.append(contentsOf: birds.particles)
    }
    if effect == .mist || effect == .clouds {
      for bank in banks {
        let target: Float =
          !retiring && !clearing && accumulates && multiplier > 0
          ? min(1.2, 0.8 * multiplier)
            * (dynamics.map { effect == .mist ? 0.5 + $0.haze * 0.7 : $0.cloudCover } ?? 1) : 0
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
    if (effect == .sunlight || scene.sunlight > 0) && multiplier > 0 && !clearing
      && (dynamics == nil || scene.sunlight > 0.001)
    {
      for i in 0..<2 {
        let x = size.x * (0.14 + Float(i) * 0.16) + sin(time * 0.035 + Float(i)) * 12
        decorations.append(
          WeatherParticle(
            rect: SIMD4(
              x, size.y * 0.63, (75 + Float(i) * 22) * min(1.5, multiplier), size.y * 0.88),
            motion: SIMD4(0.32, -1, Float(i) * 0.31, 8),
            color: SIMD4(
              1, 0.84, 0.42,
              0.16 * (dynamics != nil ? scene.sunlight : effect == .sunlight ? 1 : scene.sunlight)),
            life: SIMD4(2, 10000, 0, 0)))
      }
    }
  }

  private func stormDecorations(dt: Float, multiplier: Float, clearing: Bool) {
    let storm = effect == .storm || effect == .lightning
    let cover: Float =
      dynamics != nil
      ? (scene.clouds > 0 || storm || effect == .clouds ? dynamics!.cloudCover : 0)
      : storm ? 1 : effect == .clouds ? 0.65 : scene.clouds
    if cover > 0 && multiplier > 0 && !clearing {
      let height = min(size.y * 0.35, storm ? 220 : 90 + cover * 130) * (0.65 + 0.35 * cover)
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
      let struckPool=water.first {abs($0.origin.y-target.y)<4 && $0.accepts(x:target.x)}
      if let pool=struckPool {target.y=pool.origin.y+pool.depth(at:target.x)}
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
      if let pool=struckPool {
        addRipple(at:SIMD2(target.x,pool.origin.y),strength:2)
        pool.hit(x:target.x,amount:0,impulse:8)
        lightningSplash(surface:pool,x:target.x)
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
    case .butterflies:
      let diameter = range(17, 28)
      return WeatherParticle(
        rect: SIMD4(
          range(20, size.x - 20), range(size.y * 0.2, size.y * 0.85), diameter, diameter * 0.85),
        motion: SIMD4(range(-30, 30), range(-12, 12), unit(), 13),
        color: unit() < 0.5 ? SIMD4(1, 0.58, 0.17, 0.96) : SIMD4(0.55, 0.72, 1, 0.96),
        life: SIMD4(initial ? 1 : 0, range(18, 30), 0, 0))
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
    let speed: Float
    if let dynamics {
      speed = dynamics.fallSpeed * range(0.82, 1.16)
    } else {
      speed = range(
        drizzle ? 290 : 650, (effect == .storm || effect == .lightning) ? 1200 : drizzle ? 470 : 930
      )
    }
    return WeatherParticle(
      rect: SIMD4(
        point.x, point.y,
        splash ? range(2.2, 3.2) : range(drizzle ? 2.2 : 2.7, drizzle ? 2.8 : 3.8),
        splash ? range(3, 6) : speed * (drizzle ? 0.024 : 0.029)),
      motion: SIMD4(
        splash ? range(-110, 110) : wind + ((manualWind || dynamics != nil) ? 0 : (effect == .storm || effect == .lightning ? 80 : 12)),
        splash ? range(50, 160) : -speed, unit(), splash ? 5 : 0),
      color: SIMD4(0.74, 0.86, 0.97, splash ? 0.7 : range(0.65, 0.88)),
      life: SIMD4(0, splash ? range(0.35, 0.7) : 16, 0, 0))
  }

  /// Merge nearby old samples only under pressure, preserving mass and momentum.
  private func coalesceLiquid() {
    particleCount = storage.withUnsafeMutableBufferPointer { particles in
      sh_coalesce_liquid(particles.baseAddress, particleCount)
    }
  }

  private func appendLiquid(_ release: WaterSurface.Release, maximum: Int = 128) {
    guard release.amount > 0.0001, particleCount < Self.capacity else { return }
    // Pixel-scale fluid parcels represent the same conserved volume. Dense small
    // samples reconstruct thin ligaments instead of rendering one large glass ball.
    let count=min(maximum,max(1,Int(ceil(release.amount/0.08))),Self.capacity-particleCount)
    let mass=release.amount/Float(count)
    let diameter=max(0.75,min(1.8,sqrt(mass)*2.3))
    let phase=unit()*2*Float.pi
    for k in 0..<count {
      let angle=phase+Float(k)*2.3999632
      let radius=sqrt((Float(k)+0.5)/Float(count))*max(0.6,sqrt(Float(count))*0.42)
      let point=release.point+SIMD2(cos(angle),sin(angle))*radius
      append(WeatherParticle(rect:SIMD4(point.x,point.y,diameter,diameter),
        motion:SIMD4(release.velocity.x,release.velocity.y,release.continuous ? -max(0.001,phase/(2*Float.pi)) : phase/(2*Float.pi),9),
        color:SIMD4(point.x,point.y,diameter*0.5,0.9),
        life:SIMD4(0,14,mass,0)))
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
    if let i=ripples.indices.first(where: {ripples[$0].age<0.1 && simd_distance(ripples[$0].point,point)<24}) {
      let old=ripples[i].strength,total=old+strength
      ripples[i].point=(ripples[i].point*old+point*strength)/max(0.001,total)
      ripples[i].strength=min(1.7,sqrt(old*old+strength*strength))
      return // Preserve age: repeated rain cannot restart a white point every frame.
    }
    if ripples.count==32 {
      guard let i=ripples.indices.min(by:{ripples[$0].strength*exp(-ripples[$0].age*4)<ripples[$1].strength*exp(-ripples[$1].age*4)}),ripples[i].age>0.2 else {return}
      ripples.remove(at:i)
    }
    ripples.append(WaterRipple(point:point,age:0,strength:min(1.7,strength)))
  }

  /// Transfer a bounded amount of existing water into an impact crown. Energy sets
  /// launch velocity; no extra water is invented, and large lightning hits scale up.
  func impactSplash(surface:WaterSurface,x:Float,velocity:SIMD2<Float>,amount:Float) {
    let speed=abs(velocity.y),remaining=puddleSplashSamples[surface.id] ?? (reducedMotion ? 4:12)
    guard speed>250,surface.depth(at:x)>0.12,remaining>=2,impactSplashBudget>=2,particleCount<Self.capacity-64 else {return}
    let samples=min(6,remaining/2,impactSplashBudget/2)
    let radius=min(14,max(4,speed*0.007))
    let volume=surface.extract(x:x,radius:radius,fraction:min(surface.id==0 ? 0.08:0.14,amount*speed/18000))
    guard volume>0.0001 else {return}
    puddleSplashSamples[surface.id]=remaining-samples*2;impactSplashBudget-=samples*2
    let rise=min(500,speed*0.23),waterVelocity=surface.velocity(at:x)
    surface.kick(x:x,radius:radius,velocity:SIMD2(0,rise*0.3*min(1,amount/4)))
    // Mostly vertical rain creates mostly vertical ejecta. The incoming drop carries
    // wind momentum; the impact's radial spread is only a small crown component.
    let carriedX=velocity.x*0.8+waterVelocity.x*0.2
    for side:Float in [-1,1] {
      appendLiquid(WaterSurface.Release(amount:volume*0.5,
        point:SIMD2(x+side*radius*0.25,surface.origin.y+surface.depth(at:x)+0.6),
        velocity:SIMD2(carriedX+side*rise*0.08,waterVelocity.y*0.2+rise)),maximum:samples)
    }
  }

  func lightningSplash(surface:WaterSurface,x:Float) {
    guard surface.volume>0.1 else {return}
    if Self.capacity-particleCount<512 {coalesceLiquid()}
    let budget=min(512,Self.capacity-particleCount-32)
    guard budget>0 else {return}
    let depth=surface.depth(at:x),radius=min(70,max(20,16+depth*3))
    let columns=surface.depths.indices.filter {
      let px=surface.origin.x+Float($0)/Float(surface.depths.count-1)*surface.width
      return abs(px-x)<radius && surface.accepts(x:px) && surface.depth(at:px)>0.12
    }
    guard !columns.isEmpty else {return}
    let rise=sqrt(2*950*min(size.y*0.45,180+depth*20))
    let samples=max(1,budget/columns.count)
    for column in columns {
      let px=surface.origin.x+Float(column)/Float(surface.depths.count-1)*surface.width
      let r=(px-x)/radius,weight=max(0,1-r*r)
      let line=surface.origin.y+surface.depth(at:px)
      let mass=surface.extract(x:px,radius:surface.width/Float(surface.depths.count-1)*0.45,fraction:0.55*weight)
      let v=surface.velocity(at:px)
      let first=particleCount
      appendLiquid(WaterSurface.Release(amount:mass,point:SIMD2(px,line+0.8),
        velocity:v+SIMD2(r*rise*0.32,rise*sqrt(max(0.12,weight)))),maximum:samples)
      let extent=max(0.6,sqrt(Float(particleCount-first))*0.42)
      for i in first..<particleCount {
        // Sample the actual removed layer, rather than collapsing its full depth
        // into a row of identical droplets. Pressure varies continuously over the
        // layer and across the impact, allowing curtains and ligaments to stretch.
        let z=max(0,min(1,0.5+(storage[i].rect.y-(line+0.8))/(2*extent)))
        storage[i].rect.y=line-mass+z*mass
        let localR=(storage[i].rect.x-x)/radius
        storage[i].motion.x=v.x+localR*rise*0.20
        storage[i].motion.y=v.y+rise*sqrt(max(0.12,1-localR*localR))*sqrt(0.35+0.65*z)
        storage[i].life.w=0.7*weight
      }
    }
    surface.kick(x:x,radius:radius,velocity:SIMD2(0,rise*0.9),sustained:true)
  }

  private func unit() -> Float {
    rng ^= rng >> 12
    rng ^= rng << 25
    rng ^= rng >> 27
    return Float((rng &* 2_685_821_657_736_338_717) >> 40) / Float(1 << 24)
  }
  private func range(_ low: Float, _ high: Float) -> Float { low + (high - low) * unit() }
}
