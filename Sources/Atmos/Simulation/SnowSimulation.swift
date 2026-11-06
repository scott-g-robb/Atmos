import CoreGraphics
import Foundation
import simd

struct Sprite {
  var position: SIMD2<Float>
  /// Smears fast snow into a short streak, as a camera would.
  var velocity = SIMD2<Float>(repeating: 0)
  var size: Float
  var alpha: Float
  var soft: Float
  /// How much of `tint` shows instead of snow white.
  var tintAmount: Float = 0
  var tintRed: Float = 1
  var tintGreen: Float = 1
  var tintBlue: Float = 1
  /// Gives a lump of snow its ragged outline and tumble; zero for a round flake.
  var lump: Float = 0
  /// A leaf instead of a snowflake: its seed, which picks its shape and colour; zero for snow.
  var leaf: Float = 0
  /// Which way a leaf points.
  var turn: Float = 0
  /// How much of a leaf's face shows, and which side: one is its front face on, below zero its back.
  var flip: Float = 1
  /// How fast a leaf turns and tumbles, a second: it blurs over the exposure, as it moves.
  var turnSpeed: Float = 0
  var flipSpeed: Float = 0
}

/// A bit of something that crumbles into snow, such as a window: it keeps its colour for a moment while it falls.
struct ScatterPiece {
  var position: SIMD2<Float>
  var velocity: SIMD2<Float>
  var color: SIMD3<Float>
}

struct PileLayer {
  var offset: Int
  var count: Int
  var origin: SIMD2<Float>
  var top: Float
  var bottom: Float
  var occluders: [SIMD4<Float>]
  var isDock: Bool
  var drift: Float
}

private struct Flake {
  var retirementLife: Float = .greatestFiniteMagnitude
  var position: SIMD2<Float>
  var velocity: SIMD2<Float>
  var fallSpeed: Float
  var size: Float
  var depth: Float
  var alpha: Float
  var soft: Float
  var phase: Float
  var swayRate: Float
  var swayAmount: Float
  var settles: Bool
  /// Scales the snow it leaves where it lands.
  var mass: Float = 1
  var tint = SIMD3<Float>(repeating: 1)
  var tintAmount: Float = 0
  /// The direction of the gust that caught the flake and carries it off the screen; zero until then.
  var blown: Float = 0
  var leaf: Float = 0
}

private struct Grain {
  var position: SIMD2<Float>
  var velocity: SIMD2<Float>
  var area: Float
  var size: Float
  /// A lump holds together in flight and bursts into powder where it lands; zero for loose snow.
  var lump: Float = 0
  /// Powder carried off by a gust: it rides the wind off the screen instead of settling.
  var blown = false
  /// For a leaf, picks its shape and colour.
  var seed = Float.random(in: 0.001...1)
  /// Only the bulk under fallen leaves, with no leaf of its own: unseen, it falls and adds to the heap it lands on.
  var bulk = false
}

/// A leaf come to rest on a heap or a window: it lies flat on top, riding along with what it lies on, until others
/// cover it. Its bulk is in the heap under it, so leaves pile up on one another.
private struct LyingLeaf {
  let layer: SnowLayer
  /// From the layer's base along it, and up from the base to where the leaf rests and to the top of its own bulk.
  var x: Float
  var rest: Float
  var top: Float
  let size: Float
  let seed: Float
  let tilt: Float
  /// Half a turn when it came down pointing the other way.
  let around: Float
  /// How it was turned and tumbled in the air, and how far along the surface it slides, while it settles.
  let fromTurn: Float
  let fromFlip: Float
  let slide: Float
  let settling: Float
  var settled: Float = 0
  let life: Float
  var age: Float = 0
  var fade: Float = 1
}

/// Powder thrown up by a lump bursting: it billows, slows in the air and fades without settling.
private struct Mote {
  var position: SIMD2<Float>
  var velocity: SIMD2<Float>
  var size: Float
  var alpha: Float
  var age: Float = 0
  var life: Float
}

private struct RandomSource {
  private var state = UInt64.random(in: 1...UInt64.max)

  mutating func next() -> Float {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Float(state >> 40) / Float(1 << 24)
  }

  mutating func range(_ lower: Float, _ upper: Float) -> Float {
    lower + (upper - lower) * next()
  }
}

final class SnowSimulation {
  let columnWidth: Float = 2
  private(set) var width: Float
  private(set) var height: Float
  /// How briskly the scene changes, which sets how often it is drawn.
  enum Pace {
    /// Only snowfall and slow drifts: a low frame rate is indistinguishable.
    case calm
    /// Loose snow in flight.
    case lively
    /// The cursor or a window is pushing snow around: drawn as often as the display allows.
    case interactive
  }

  private(set) var pace = Pace.calm

  var snowfall: Snowfall {
    didSet {
      if snowfall == .variable && oldValue != .variable { nextShift = clock }
      if snowfall != .variable {
        strength = 1
        strengthTarget = 1
      }
      updateTarget()
      stirred()
    }
  }
  /// Called when the screen may get snow again after it has come to rest.
  var stirred: () -> Void = {}
  /// Scales the snowfall; flakes come and go through the usual cycle, so a change shows gradually.
  var density: Float = 1 {
    didSet { updateTarget() }
  }
  private(set) var retiring = false
  private(set) var retirementRate: Float = 1
  func retire() {
    retiring = true
    retirementRate = 3
    snowfall = .off
    dormant.removeAll()
    parking.removeAll()
    for i in flakes.indices {
      // Continue falling at the same speed. Individual remaining lifetimes are shortened,
      // rather than fading the whole old screen in unison.
      flakes[i].retirementLife = max(
        1, max(0, flakes[i].position.y) / max(12, flakes[i].fallSpeed) / retirementRate)
    }
  }
  func resume() {
    retiring = false
    retirementRate = 1
    for i in flakes.indices { flakes[i].retirementLife = .greatestFiniteMagnitude }
  }
  var thaws = false
  /// Live Weather's bounded wind, in points per second; zero for manually selected modes.
  let surfaceDrift = SurfaceDrift()
  var waterSurfaces: [WaterSurface] = []
  var airflow: WindField?
  var weatherWind: Float = 0
  var weatherStrength: Float = 1 {
    didSet { if abs(oldValue - weatherStrength) > 0.001 { updateTarget() } }
  }
  var meltScale: Float = 1
  var botanicalStyle: Float = 1 {
    didSet { updateTarget() }
  }
  private var cursorFrom: SIMD2<Float>?
  private(set) var dandelionBursts = 0
  var accumulates = true
  /// Screen edges with no display past them: a window slid past one leaves its snow heaped against the edge.
  var walls: (left: Bool, right: Bool) = (false, false)
  /// Keeps the snowfall from starting until a scattered window's snow first reaches the bottom of the screen.
  var snowfallHeld = false {
    didSet { updateTarget() }
  }
  /// Called when the held snowfall starts by itself, so the other displays can start theirs.
  var snowfallReleased: () -> Void = {}

  private let groundDepth: Float = 40
  private let ledgeDepth: Float = 14
  private let thawDepth: Float = 8
  private let ledgeThawDepth: Float = 4
  private let thawRate: Float = 0.02
  private let thawTime: Float = 30
  private let thawBalance: Float = 184
  private let thawExponent: Float = 0.74
  private let deposition: Float = 1.1
  private let repose: Float = 0.8
  private let rounding: Float = 0.15
  private let cursorRadius: Float = 10
  private let cursorOffset = SIMD2<Float>(4, -8)
  private let gravity: Float = 2500
  private let grainDrag: Float = 0.8
  private let maxGrains = 12000
  private let phaseWrap: Float = 20 * .pi
  private let ledgeInset: Float = 0
  private let grip: Float = 3
  private let slip: Float = 2
  private let breakLift: Float = 10
  /// Snow sticks to a window: it only lets go when pulled away harder than this, on top of its weight.
  private let adhesion: Float = 3500
  private let shaking: Float = 4
  /// Leaves hold together far less than snow: a heap of them flies apart as soon as it lifts off its window at
  /// all, and a shake that would only stir snow throws them off.
  private let leafBreakLift: Float = 2
  private let leafShaking: Float = 0.8
  /// Leaves hardly stick to a window and slide over it easily: shaken, the window moves out from under them.
  private let leafAdhesion: Float = 500
  private let leafGrip: Float = 0.8
  private let leafSlip: Float = 0.5

  private let jumpSpeed: Float = 6000
  private let trackTime: Float = 0.06
  private let maxMotes = 1500
  private let gustSweep: Float = 0.6
  private let gustLength: Float = 2.2
  private let gustWind: Float = 1000
  /// The snowfall is caught this long after the drifts, so it trails behind their powder.
  private let gustLag: Float = 0.3
  /// Snow a wall scrapes up packs down to this share of its fresh bulk.
  private let packing: Float = 0.6
  /// A sliding Space drags the air along: the wind it stirs up is this share of its speed, up to `slideWindMax`,
  /// and dies down over `slideCalm` seconds once the Space stops.
  private let slideDrag: Float = 0.025
  private let slideWindMax: Float = 160
  private let slideCalm: Float = 0.35
  /// Leaves fall this much sparser than snow, each one being so much bigger.
  private let leafShare: Float = 0.07
  /// The share of a heap one fallen leaf makes up.
  private let leafArea: Float = 24
  /// How much of a heap's visible bulk each leaf coming off it stands for: a heap is packed with overlapping
  /// leaves, so as many fly off as it looked to hold.
  private let leafShown: Float = 30
  /// Leaves lie loosely, with air between them: the bulk a landing leaf adds to its heap, per point of its length.
  private var leafBulk: Float {botanicalStyle == 5 ? 1.6 : 5.5}
  private let maxLying = 1500
  /// The top of a heap is the lying leaves themselves: the pile shader draws the mass under them only this far down.
  private let leafCover: Float = 2.5
  private var lying: [LyingLeaf] = []

  private let ground: SnowLayer
  private var ledges: [CGWindowID: SnowLayer] = [:]
  private var ledgeList: [SnowLayer] = []
  private var layers: [SnowLayer]
  private var heldLayers: [SnowLayer] = []
  private var flakes: [Flake] = []
  private var grains: [Grain] = []
  private var motes: [Mote] = []
  private var targetFlakes = 0
  private var random = RandomSource()
  private var clock: Double = 0
  private var cursor: SIMD2<Float>?
  private var cursorVelocity = SIMD2<Float>(repeating: 0)
  private var heightsChanged = false
  private var windowsChanged = false
  private var lastWindowMotion: Double = -10
  private var lastCursorPush: Double = -10
  /// Snow on windows that left the screen for another Space, kept until the window shows up again.
  private var dormant: [CGWindowID: SnowLayer] = [:]
  /// Windows that went off screen without a word yet on why; a Space switch keeps their snow, anything else drops it.
  private var parking: [(id: CGWindowID, ledge: SnowLayer, since: Double)] = []
  private var spaceChangedAt: Double = -10
  private var scatteredUntil: Double = -10
  private var strength: Float = 1
  private var strengthTarget: Float = 1
  private var nextShift: Double = 0
  /// A gust clearing the snow: its front sweeps across from the windward side, lifting the drifts behind it.
  private var gust: (start: Double, direction: Float, calm: Bool)?
  private var slideWind: Float = 0
  /// What `spareLeaves` found since the step began, less the leaves shown since.
  private var leafBudget: Float?
  /// Leaves fall instead of snow and heap up where it would.
  var autumn = false {
    didSet {
      guard autumn != oldValue else { return }
      lying.removeAll()
      updateTarget()
      flakes = flakes.prefix(targetFlakes).map { makeFlake(y: $0.position.y) }
      restyled = true
      stirred()
    }
  }
  private var restyled = false
  /// The mode waiting for the gust to clear the screen, so one kind never turns into the other in sight.
  private var nextAutumn: Bool?
  private var switchedAt: Double = 0
  /// The app windows on the screen, left, bottom, right, top: used for display geometry.
  var windowFrames: [SIMD4<Float>] = []

  init(width: Float, height: Float, snowfall: Snowfall) {
    self.width = width
    self.height = height
    self.snowfall = snowfall
    var seed = RandomSource()
    ground = SnowLayer(
      origin: .zero,
      columns: Self.columnCount(for: width, columnWidth: columnWidth),
      columnWidth: columnWidth,
      depth: groundDepth,
      opensAtEdges: false,
      phases: (seed.range(0, 2 * .pi), seed.range(0, 2 * .pi))
    )
    layers = [ground]
    updateTarget()
  }

  var pileTop: Float { ground.top }
  var hasSnow: Bool { surfaceDrift.count > 0 || !lying.isEmpty || layers.contains { $0.top > 0.5 } }
  /// Nothing falls, lies or waits for its window, and nothing will until the snow is stirred.
  var isEmpty: Bool {
    snowfall == .off && surfaceDrift.count == 0 && flakes.isEmpty && grains.isEmpty && motes.isEmpty
      && gust == nil && dormant.isEmpty
      && parking.isEmpty && lying.isEmpty && nextAutumn == nil
      && !layers.contains { $0.top > 0 }
  }
  var spriteCount: Int {
    surfaceDrift.sprites.count + lying.count + flakes.count + grains.count + motes.count
  }
  /// Floats the renderer needs per frame: each layer's surface and bed.
  var columnCount: Int { layers.reduce(0) { $0 + 2 * $1.count } }

  func resize(width: Float, height: Float) {
    guard width != self.width || height != self.height else { return }
    ground.resize(columns: Self.columnCount(for: width, columnWidth: columnWidth))
    self.width = width
    self.height = height
    updateTarget()
  }

  /// Returns whether anything visible changed.
  func step(dt: Float, cursor point: SIMD2<Float>) -> Bool {
    clock += Double(dt)
    let wasMoving =
      !flakes.isEmpty || !grains.isEmpty || !motes.isEmpty

    heightsChanged = false
    leafBudget = nil

    vary(dt: dt)
    slideWind = abs(slideWind) < 1 ? 0 : slideWind * exp(-dt / slideCalm)
    expireParking()
    for ledge in ledgeList { carry(ledge, dt: dt) }
    trackCursor(point, dt: dt)
    for ledge in ledgeList where !ledge.carried { confine(ledge) }
    blow(dt: dt)
    skim(dt: dt)
    surfaceDrift.botanicalStyle=botanicalStyle
    surfaceDrift.lifetime=botanicalStyle == 5 ? 20 : 90
    let released = surfaceDrift.step(
      dt: dt, water: waterSurfaces, wind: weatherWind, cursor: cursor,
      cursorVelocity: cursorVelocity, retiring: retiring, clearing: gust != nil,
      cursorFrom: cursorFrom)
    for item in released where grains.count < maxGrains {
      if botanicalStyle == 3 && item.seed > 2 && touchesDandelion(item.position, size: item.size) {
        popDandelion(at: item.position, velocity: item.velocity, size: item.size, area: item.area)
        continue
      }
      grains.append(
        Grain(
          position: item.position, velocity: item.velocity, area: item.area,
          size: item.size, seed: item.seed))
    }
    advanceFlakes(dt: dt)
    advanceGrains(dt: dt)
    advanceMotes(dt: dt)
    settle(dt: dt)
    tendLeaves(dt: dt)
    if let next = nextAutumn, gust == nil, grains.isEmpty || clock - switchedAt > 6 {
      nextAutumn = nil
      autumn = next
    }
    spawnFlakes()

    for layer in layers {
      layer.refreshTop()
      layer.previousBaseY = layer.base.y
    }
    // Only a cursor that actually displaces snow needs the full rate; one passing near it or resting in it changes nothing.
    let pushed =
      clock - lastWindowMotion < 0.6 || clock - lastCursorPush < 0.3 || gust != nil

    // The steady trickle off window corners is a few tiny grains at a time; they read fine at the calm rate.
    let flying = grains.count > 24 || clock < scatteredUntil || abs(slideWind) > 20
    if pushed {
      pace = .interactive
    } else if flying {
      pace = .lively
    } else {
      pace = .calm
    }
    let changed =
      wasMoving || !flakes.isEmpty || !grains.isEmpty || !motes.isEmpty
      || heightsChanged || windowsChanged
      || restyled
    restyled = false
    windowsChanged = false
    return changed
  }

  func writeSprites(into buffer: UnsafeMutablePointer<Sprite>, capacity: Int) -> Int {
    var count = 0
    for sprite in surfaceDrift.sprites where count < capacity {
      buffer[count] = sprite
      count += 1
    }
    let shown = Set(layers.map(ObjectIdentifier.init))
    for leaf in lying where count < capacity && shown.contains(ObjectIdentifier(leaf.layer)) {
      let layer = leaf.layer
      let ease = 1 - pow(1 - leaf.settled, 3)
      let x = layer.heapX + leaf.x - leaf.slide * (1 - ease)
      guard let i = layer.index(at: x), layer.visible[i] else { continue }
      let target = restingTurn(of: leaf, on: layer, at: i)
      // Sliding over to where it comes to rest, it skims the ground until it rides up onto the leaves there.
      let rest = leaf.settled < 1 ? min(layer.surface(i) - layer.base.y, leaf.rest) : leaf.rest
      // The heap's mass shows `leafCover` below its surface: the leaf lies on what shows, or on the bare window.
      let sink = min(leafCover, max(0, rest - layer.bed[i]))
      buffer[count] = Sprite(
        position: SIMD2(x, layer.base.y + rest + leaf.size * 0.2 - sink),
        size: leaf.size,
        alpha: leaf.fade,
        soft: 0,
        leaf: leaf.seed,
        turn: leaf.fromTurn + (target - leaf.fromTurn) * ease,
        flip: leaf.fromFlip + ((leaf.fromFlip < 0 ? -0.7 : 0.7) - leaf.fromFlip) * ease
      )
      count += 1
    }
    for flake in flakes where count < capacity {
      buffer[count] = Sprite(
        position: flake.position,
        velocity: flake.leaf != 0 ? motion(of: flake) : flake.velocity,
        size: flake.size,
        alpha: flake.alpha,
        soft: flake.soft,
        tintAmount: flake.tintAmount,
        tintRed: flake.tint.x,
        tintGreen: flake.tint.y,
        tintBlue: flake.tint.z,
        leaf: flake.leaf,
        turn: turn(of: flake),
        flip: tumble(flake.leaf),
        turnSpeed: flake.leaf != 0
          ? cos(flake.phase) * 0.6 * flake.swayRate
            + (botanicalStyle == 5 ? 36 + flake.leaf * 22 : flake.leaf - 0.5) : 0,
        flipSpeed: flake.leaf != 0 ? tumbleSpeed(flake.leaf) : 0
      )
      count += 1
    }
    for grain in grains where count < capacity && !grain.bulk {
      if autumn {
        buffer[count] = Sprite(
          position: grain.position,
          velocity: grain.velocity,
          size: grain.size >= 5.5 ? grain.size : 6 + grain.seed * 4.5,
          alpha: 0.95,
          soft: 0,
          leaf: grain.seed,
          turn: turn(of: grain),
          flip: tumble(grain.seed),
          turnSpeed: botanicalStyle == 5 ? 36 + grain.seed * 22 : (grain.seed - 0.5) * 9,
          flipSpeed: tumbleSpeed(grain.seed)
        )
      } else {
        buffer[count] = Sprite(
          position: grain.position,
          velocity: grain.velocity,
          size: grain.size,
          alpha: grain.lump > 0 ? 0.97 : grain.blown ? 0.8 : 0.95,
          soft: grain.lump > 0 ? 0.2 : 0.3,
          lump: grain.lump
        )
      }
      count += 1
    }
    for mote in motes where count < capacity && (!autumn || botanicalStyle == 3) {
      let t = mote.age / mote.life
      let fade = min(1, mote.age / 0.06) * pow(1 - t, 1.5)
      buffer[count] = Sprite(
        position: mote.position, size: mote.size * (1 + t), alpha: mote.alpha * fade, soft: 1)
      count += 1
    }
    return count
  }

  func writeLayers(into buffer: UnsafeMutablePointer<Float>, capacity: Int) -> [PileLayer] {
    var result: [PileLayer] = []
    var offset = 0
    for layer in layers where layer.top > 0.05 && offset + 2 * layer.count <= capacity {
      layer.writeSmoothed(into: buffer + offset)
      // Opaque botanical litter must not be drawn over the water covering it.
      // Raise the rendered bed to the same interpolated waterline used by floats.
      if autumn,let pool=waterSurfaces.first(where:{($0.id==0 && layer === ground) || ledges[$0.id] === layer}) {
        for i in 0..<layer.count {
          let x=layer.centerX(i),depth=pool.depth(at:x)
          if depth>0.3 && pool.accepts(x:x) {
            let bed=max(buffer[offset+layer.count+i],pool.origin.y+depth-layer.base.y)
            buffer[offset+layer.count+i]=bed
            buffer[offset+i]=max(buffer[offset+i],bed)
          }
        }
      }
      result.append(
        PileLayer(
          offset: offset,
          count: layer.count,
          origin: layer.base,
          top: layer.top,
          bottom: -layer.bedDepth,
          occluders: layer.occluders,
          isDock: layer.isDock,
          drift: layer.drift
        ))
      offset += 2 * layer.count
    }
    return result
  }

  // MARK: - Windows

  func spaceChanged() {
    spaceChangedAt = clock
    for entry in parking { dormant[entry.id] = entry.ledge }
    parking.removeAll()
  }

  /// A Space slid past at `velocity` points a second, negative to the left: the air it drags along blows the
  /// falling snow that way for a moment.
  func spaceSlid(velocity: Float) {
    let wind = min(max(velocity * slideDrag, -slideWindMax), slideWindMax)
    if abs(wind) > abs(slideWind) { slideWind = wind }
  }

  func updateWindows(
    _ surfaces: [WindowSurface], interval: Float, parked: Set<CGWindowID> = [],
    elsewhere: Set<CGWindowID> = [], sliding: Bool = false
  ) {
    leafBudget = nil
    var seen = Set<CGWindowID>()
    for surface in surfaces {
      let left = Float(surface.frame.minX) + ledgeInset
      let top = Float(surface.frame.maxY)
      let right = Float(surface.frame.maxX) - ledgeInset
      let columns = Int((Float(surface.frame.width) - 2 * ledgeInset) / columnWidth)
      guard columns >= 8 else { continue }
      seen.insert(surface.id)

      let ledge: SnowLayer
      if let existing = ledges[surface.id] {
        ledge = existing
        if sliding && columns == ledge.count {
          pan(ledge, left: left, top: top, interval: interval)
        } else {
          move(ledge, left: left, right: right, top: top, columns: columns, interval: interval)
        }
      } else if let returning = dormant.removeValue(forKey: surface.id) ?? unpark(surface.id) {
        ledge = returning
        restore(returning, left: left, top: top, columns: columns)
        ledges[surface.id] = returning
      } else {
        ledge = SnowLayer(
          origin: SIMD2(left, top),
          columns: columns,
          columnWidth: columnWidth,
          depth: ledgeDepth,
          opensAtEdges: true,
          phases: (random.range(0, 2 * .pi), random.range(0, 2 * .pi))
        )
        ledge.motionGraceUntil = clock + 0.65
        ledges[surface.id] = ledge
      }
      ledge.right = right
      ledge.shapeCorners(
        radius: Float(surface.cornerRadius), exponent: Float(surface.cornerExponent))
      let blockers = surface.blockers.map {
        SIMD4<Float>(Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY))
      }
      ledge.occluders = Array(blockers.prefix(16))
      ledge.isDock = surface.isDock
      ledge.updateVisibility(screenWidth: width, blockers: blockers)
    }

    for id in ledges.keys where !seen.contains(id) {
      guard let ledge = ledges.removeValue(forKey: id) else { continue }
      if elsewhere.contains(id) {
        dormant[id] = ledge
      } else if !parked.contains(id) {
        shed(ledge, share: 1, velocity: ledge.trackVelocity + ledge.offsetVelocity)
      } else if clock - spaceChangedAt < 0.6 {
        dormant[id] = ledge
      } else {
        parking.append((id, ledge, clock))
      }
    }
    if dormant.count > 200, let stale = dormant.keys.first { dormant[stale] = nil }
    ledgeList = Array(ledges.values)
    layers = [ground] + ledgeList
  }

  private func unpark(_ id: CGWindowID) -> SnowLayer? {
    guard let index = parking.firstIndex(where: { $0.id == id }) else { return nil }
    return parking.remove(at: index).ledge
  }

  /// Puts snow that waited off screen back on its window, wherever the window is now, without treating the jump as motion.
  private func restore(_ ledge: SnowLayer, left: Float, top: Float, columns: Int) {
    ledge.resize(columns: columns)
    ledge.origin = SIMD2(left, top)
    ledge.track = ledge.origin
    ledge.trackVelocity = .zero
    ledge.offset = .zero
    ledge.offsetVelocity = .zero
    ledge.previousBaseY = top
    ledge.movedAt = -1
    ledge.carried = true
    ledge.agitation = 0
    ledge.swingPeak = 0
    ledge.previousSwingPeak = 0
    ledge.swingDirection = .zero
    ledge.motionGraceUntil = clock + 0.65
  }

  /// Off-screen windows that no Space switch accounts for were minimized or hidden: their snow falls.
  private func expireParking() {
    while let first = parking.first, clock - first.since > 0.25 {
      parking.removeFirst()
      shed(first.ledge, share: 1, velocity: .zero)
    }
  }

  /// Carries snow along with a window that the whole Space is sliding past: nothing pushes the snow, so it doesn't react.
  private func pan(_ ledge: SnowLayer, left: Float, top: Float, interval: Float) {
    let shift = SIMD2(left, top) - ledge.origin
    guard shift != .zero else { return }
    ledge.carried = true
    ledge.origin += shift
    ledge.track += shift
    ledge.previousBaseY = ledge.base.y
    if clock - ledge.trimmedAt > 1 {
      ledge.trimmedAt = clock
      // Thrown along the slide, but not at its full speed: the snow would fly across the screen.
      let velocity = shift / max(interval, 1.0 / 120)
      trimEnds(of: ledge, velocity: SIMD2(min(max(velocity.x, -600), 600), 0))
    }
    if ledge.top > 0.05 {
      lastWindowMotion = clock
      windowsChanged = true
    }
  }

  /// A switch between Spaces shakes the snow off a window's ends: stopping short of the edges, the snow doesn't
  /// show the frame or two it trails the window by.
  private func trimEnds(of ledge: SnowLayer, velocity: SIMD2<Float>) {
    // A twentieth of the window from each end, but no more than 40 points off a wide one.
    let ends = min(
      max(1, Int((min(ledge.width * 0.05, 40) / columnWidth).rounded())), ledge.count / 2)
    var area = (left: Float(0), right: Float(0))
    for i in 0..<ends {
      area.left += ledge.heights[i] * columnWidth
      area.right += ledge.heights[ledge.count - 1 - i] * columnWidth
      ledge.set(i, 0)
      ledge.set(ledge.count - 1 - i, 0)
    }
    guard area.left + area.right > 0.05 else { return }
    heightsChanged = true
    release(
      area.left, at: edgePoint(of: ledge, left: true), velocity: velocity + SIMD2(-30, -15),
      spread: SIMD2(1, 2), scatter: 0.25)
    release(
      area.right, at: edgePoint(of: ledge, left: false), velocity: velocity + SIMD2(30, -15),
      spread: SIMD2(1, 2), scatter: 0.25)
  }

  private func move(
    _ ledge: SnowLayer, left: Float, right: Float, top: Float, columns: Int, interval: Float
  ) {
    let oldLeft = ledge.origin.x
    // The window's own edges, not the snow's: rounded down to whole columns, the snow's right end would twitch
    // as the left edge is dragged, and shake the snow about.
    let oldRight = ledge.right > 0 ? ledge.right : oldLeft + ledge.width
    // A resize keeps the edge that didn't move fixed; a plain move shifts both edges alike.
    let shift = abs(left - oldLeft) <= abs(right - oldRight) ? left - oldLeft : right - oldRight
    let displacement = SIMD2(shift, top - ledge.origin.y)
    let resized = columns != ledge.count || abs(left - oldLeft - shift) > 0.5
    guard displacement != .zero || resized else { return }
    // The WindowServer reports intermediate Genie/restore bounds. These are presentation
    // transforms, not impulses. Rebase through the whole animation, including newly seen edges.
    let presentationResize =
      abs(Float(columns - ledge.count)) * columnWidth > max(40, ledge.width * 0.12)
    if clock < ledge.motionGraceUntil || presentationResize {
      let until = presentationResize ? clock + 0.65 : ledge.motionGraceUntil
      restore(ledge, left: left, top: top, columns: columns)
      ledge.motionGraceUntil = until
      return
    }
    ledge.carried = false

    let elapsed = max(interval, 1.0 / 120)
    // Only a motion that began unobserved, between slow polls, has to be picked up mid-flight.
    let wasResting = clock - ledge.movedAt > 0.3 && interval > 0.05
    ledge.movedAt = clock
    if ledge.top > 0.05 {
      lastWindowMotion = clock
      windowsChanged = true
    }

    if simd_length(displacement) / elapsed > jumpSpeed {
      // The window vanished from under the snow and reappeared elsewhere: nothing carried the snow along.
      shed(ledge, share: 1, velocity: .zero, asLeaves: true)
      ledge.offset = .zero
      ledge.offsetVelocity = .zero
      ledge.trackVelocity = .zero
    }

    if resized {
      // The snow stays put as the window's edge moves under it: it shifts along the window by whole columns,
      // as many as the drift it has built up comes to, so that rounding never adds up and walks it off.
      let along = oldLeft + shift - left
      let before = (ledge.drift / columnWidth).rounded()
      ledge.drift += along
      let by = Int((ledge.drift / columnWidth).rounded() - before)
      var fresh = [Float](repeating: 0, count: columns)
      for i in 0..<ledge.count where ledge.heights[i] > 0 {
        let j = i + by
        if j >= 0 && j < columns {
          fresh[j] += ledge.heights[i]
        } else {
          let h = ledge.heights[i]
          release(
            h * columnWidth,
            at: SIMD2(ledge.centerX(i), ledge.floor(i)),
            velocity: ledge.trackVelocity,
            spread: SIMD2(columnWidth / 2, h),
            leaves: max(h - leafCover, 0) / h
          )
        }
      }
      ledge.replace(heights: fresh)
    }
    ledge.origin = SIMD2(left, top)
    // Resized, the window doesn't move under its snow: the edge dragged is no jolt to it.
    ledge.track.x += left - oldLeft - shift
    if simd_length(displacement) / elapsed > jumpSpeed {
      ledge.track = ledge.origin
    } else if wasResting {
      // Join the motion at its current pace, with the lag a steady follow would have, instead of as a jolt.
      ledge.trackVelocity = displacement / elapsed
      ledge.track = ledge.origin - ledge.trackVelocity * trackTime
    }
  }

  /// Moves a ledge's snow as a body riding on its window: it feels gravity plus the inertia of the
  /// window's acceleration, sticks by friction, slides when that's exceeded, and flies free when the
  /// window drops away faster than gravity or stops short after rising.
  private func carry(_ ledge: SnowLayer, dt: Float) {
    guard clock >= ledge.motionGraceUntil else { return }
    let previousVelocity = ledge.trackVelocity
    smoothDamp(&ledge.track, &ledge.trackVelocity, toward: ledge.origin, time: trackTime, dt: dt)
    let acceleration = (ledge.trackVelocity - previousVelocity) / dt
    // Agitation is vibration: two consecutive back-and-forth swings, not a single start or stop.
    ledge.agitation *= exp(-dt / 0.3)
    let magnitude = simd_length(acceleration)
    if magnitude > 1, simd_dot(acceleration, ledge.swingDirection) < 0 {
      ledge.agitation = max(
        ledge.agitation, min(ledge.previousSwingPeak, ledge.swingPeak) / gravity)
      ledge.previousSwingPeak = ledge.swingPeak
      ledge.swingPeak = magnitude
      ledge.swingDirection = acceleration / magnitude
    } else {
      ledge.swingPeak = max(ledge.swingPeak, magnitude)
      if magnitude > 1 && ledge.swingDirection == .zero {
        ledge.swingDirection = acceleration / magnitude
      }
    }

    guard ledge.top > 0.05 else {
      ledge.offset = .zero
      ledge.offsetVelocity = .zero
      return
    }

    var lift = ledge.offset.y
    var liftVelocity = ledge.offsetVelocity.y
    let (stick, hold, rub) = autumn ? (leafAdhesion, leafGrip, leafSlip) : (adhesion, grip, slip)
    let fall = -gravity - acceleration.y
    if lift > 0 || fall > stick {
      liftVelocity += fall * dt
      lift += liftVelocity * dt
      if lift <= 0 {
        lift = 0
        liftVelocity = 0
      }
    }

    let pressure = lift > 0 ? 0 : max(0, gravity + stick + acceleration.y)
    let drive = -acceleration.x
    var slideVelocity = ledge.offsetVelocity.x
    if !(slideVelocity == 0 && abs(drive) <= hold * pressure) {
      let direction: Float =
        slideVelocity != 0 ? (slideVelocity > 0 ? 1 : -1) : (drive > 0 ? 1 : -1)
      let next = slideVelocity + (drive - direction * rub * pressure) * dt
      slideVelocity = pressure > 0 && next * direction <= 0 ? 0 : next
    }

    var slide = ledge.offset.x + slideVelocity * dt
    let carried = ledge.trackVelocity + SIMD2(slideVelocity, liftVelocity)
    while abs(slide) >= columnWidth {
      let direction = slide > 0 ? 1 : -1
      let dropped = ledge.slideColumn(toward: direction)
      slide -= Float(direction) * columnWidth
      ledge.drift += Float(direction) * columnWidth
      if dropped.height > 0.01 {
        let x = dropped.x + Float(direction) * columnWidth
        release(
          dropped.height * columnWidth,
          at: SIMD2(x, dropped.y),
          velocity: carried,
          spread: SIMD2(columnWidth / 2, dropped.height),
          leaves: max(dropped.height - leafCover, 0) / dropped.height
        )
      }
    }

    let moved = lift != ledge.offset.y || slide != ledge.offset.x
    ledge.offset = SIMD2(slide, lift)
    ledge.offsetVelocity = SIMD2(slideVelocity, liftVelocity)
    if moved { heightsChanged = true }

    let shakes = autumn ? leafShaking : shaking
    if lift > (autumn ? leafBreakLift : breakLift) {
      shed(ledge, share: 1, velocity: carried, asLeaves: true)
      ledge.offset = .zero
      ledge.offsetVelocity = .zero
    } else if ledge.agitation > shakes {
      // A granular bed shaken well past gravity throws grains off its surface.
      let rate =
        autumn ? leafShakeRate(ledge.agitation) : min(0.8, 0.06 * (ledge.agitation - shakes))
      let picks = Int(Float(ledge.count) * rate * dt * 2 + random.next())
      for _ in 0..<picks {
        let i = Int(random.next() * Float(ledge.count))
        let h = ledge.heights[min(i, ledge.count - 1)]
        guard h > 0.2 else { continue }
        let column = min(i, ledge.count - 1)
        ledge.set(column, h * 0.5)
        release(
          h * 0.5 * columnWidth,
          at: SIMD2(ledge.centerX(column), ledge.floor(column) + h * 0.5),
          velocity: carried + SIMD2(random.range(-80, 80), random.range(50, 200)),
          spread: SIMD2(columnWidth / 2, h * 0.5),
          scatter: 0.25,
          leaves: min(h * 0.5, max(h - leafCover, 0)) / (h * 0.5)
        )
      }
      if picks > 0 { heightsChanged = true }
    }
  }

  /// How fast a shaken heap of leaves comes apart: the share of its columns, and of the leaves lying on it, thrown
  /// off in half a second.
  private func leafShakeRate(_ agitation: Float) -> Float {
    min(0.8, 0.3 * max(agitation - leafShaking, 0))
  }

  /// The part of a window slid past a wall carries no snow: the wall scrapes it off, and it heaps up against the
  /// wall, which holds up the heap's face as the cursor holds up the snow it touches.
  private func confine(_ ledge: SnowLayer) {
    let count = ledge.count
    let first =
      walls.left ? min(max(0, Int((-ledge.base.x / columnWidth - 0.5).rounded(.up))), count) : 0
    let last =
      walls.right
      ? max(min(count - 1, Int(((width - ledge.base.x) / columnWidth - 0.5).rounded(.down))), -1)
      : count - 1
    guard first > 0 || last < count - 1 else { return }
    guard first <= last else {
      // Nothing of the window is left this side of the wall: its snow falls down the wall.
      let x: Float = first > 0 ? 1 : width - 1
      for i in 0..<count where ledge.heights[i] > 0.05 {
        let h = ledge.heights[i]
        ledge.set(i, 0)
        release(h * columnWidth, at: SIMD2(x, ledge.floor(i)), velocity: .zero, spread: SIMD2(1, h))
      }
      heightsChanged = true
      return
    }
    if !heldLayers.contains(where: { $0 === ledge }) { heldLayers.append(ledge) }
    scrape(ledge, 0..<first, onto: first, inward: 1)
    scrape(ledge, (last + 1)..<count, onto: last, inward: -1)
  }

  /// Heaps the snow on `columns`, past a wall, onto column `edge` just inside it, packing down what wasn't packed
  /// already. Scraped off fast, some of it crumbles off the heap and tumbles back over the window.
  private func scrape(_ ledge: SnowLayer, _ columns: Range<Int>, onto edge: Int, inward: Float) {
    var area: Float = 0
    for i in columns {
      let packed = min(ledge.packed[i], ledge.heights[i])
      area += (packed + (ledge.heights[i] - packed) * packing) * columnWidth
      ledge.set(i, 0)
      ledge.hold(i)
    }
    guard area > 0.01 else { return }
    heightsChanged = true
    let speed = max(0, -inward * (ledge.trackVelocity.x + ledge.offsetVelocity.x))
    let crumbled = area * 0.4 * smoothstep(200, 1200, speed)
    if crumbled > 0.5 {
      release(
        crumbled,
        at: SIMD2(ledge.centerX(edge), ledge.surface(edge)),
        velocity: SIMD2(inward * speed * 0.25, 60 + speed * 0.12),
        spread: SIMD2(columnWidth, 2),
        scatter: 0.6
      )
    }
    ledge.heap(area - crumbled, against: edge, inward: Int(inward), slope: repose * columnWidth)
  }

  /// Turns part of a ledge's snow into falling snow where it lies: a few columns at a time hold together
  /// as a lump, the rest pours off as powder. A heap of leaves thrown off `asLeaves` shows as the leaves it is
  /// made of; one left by a window closing or hiding goes unseen, leaving only the leaves lying on it to fall.
  private func shed(
    _ ledge: SnowLayer, share: Float, velocity: SIMD2<Float>, asLeaves: Bool = false
  ) {
    var shown: Float = 0
    if autumn && asLeaves {
      // The leaves lying on top go along with the rest, and count among the leaves the heap shows.
      var lyingHere: Float = 0
      for k in lying.indices.reversed() where lying[k].layer === ledge {
        fly(k, velocity: velocity + SIMD2(random.range(-40, 40), random.range(10, 60)))
        lyingHere += 1
      }
      let area = ledge.heights.reduce(0) { $0 + max($1, 0) } * share * columnWidth
      let seen = ledge.heights.reduce(0) { $0 + max($1 - leafCover, 0) } * share * columnWidth
      shown = area > 0 ? max(0, seen / leafShown - lyingHere) * leafShown / area : 0
    }
    var start = 0
    while start < ledge.count {
      let end = min(ledge.count, start + Int(random.range(2, 7)))
      var area: Float = 0
      var lowest = Float.greatestFiniteMagnitude
      var highest = -Float.greatestFiniteMagnitude
      for i in start..<end where ledge.heights[i] > 0.05 {
        let h = ledge.heights[i]
        area += h * share * columnWidth
        lowest = min(lowest, ledge.floor(i) + h * (1 - share))
        highest = max(highest, ledge.floor(i) + h)
      }
      let cohesion = area > 14 && !autumn ? random.range(0.4, 0.7) : 0
      for i in start..<end where ledge.heights[i] > 0.05 {
        let h = ledge.heights[i]
        let amount = h * share
        ledge.set(i, h - amount)
        release(
          amount * columnWidth * (1 - cohesion),
          at: SIMD2(ledge.centerX(i), ledge.floor(i) + h - amount),
          velocity: velocity,
          spread: SIMD2(columnWidth / 2, amount),
          scatter: 0.25,
          leaves: shown
        )
      }
      if cohesion > 0 {
        let left = ledge.centerX(start)
        let right = ledge.centerX(end - 1)
        throwLump(
          area * cohesion, at: SIMD2((left + right) / 2, (lowest + highest) / 2), velocity: velocity
        )
      }
      start = end
    }
    heightsChanged = true
  }

  private func throwLump(_ area: Float, at position: SIMD2<Float>, velocity: SIMD2<Float>) {
    if autumn {
      release(area, at: position, velocity: velocity, spread: SIMD2(4, 2), scatter: 0.5)
      return
    }
    let pieces = Int(area / 90) + 1
    for _ in 0..<pieces where grains.count < maxGrains {
      let share = area / Float(pieces)
      grains.append(
        Grain(
          position: position + SIMD2(random.range(-2, 2), random.range(-1, 1)),
          // Lumps break away a moment before the powder around them, so a falling sheet comes apart.
          velocity: velocity * (1 + random.range(-0.2, 0.2))
            + SIMD2(random.range(-25, 25), random.range(-80, 0)),
          area: share,
          size: min(11, share.squareRoot() * 1.05),
          lump: random.range(0.05, 1)
        ))
    }
  }

  /// A lump hitting the snow: most of it packs in where it lands, a few crumbs hop off and a puff of powder rises.
  private func burst(_ lump: Grain, into layer: SnowLayer) {
    let impact = max(0, -lump.velocity.y)
    let force = min(max(impact / 900, 0.35), 1.3)
    let crumbs = lump.area * 0.18
    for spot: Float in [-0.3, 0, 0.3] {
      let x = lump.position.x + spot * lump.size
      let missed = layer.deposit((lump.area - crumbs) / 3, at: x, wide: true)
      dropPast(layer, missed, near: x, velocity: lump.velocity.x * 0.3)
    }
    let surface = layer.index(at: lump.position.x).map { layer.surface($0) } ?? lump.position.y
    release(
      crumbs,
      at: SIMD2(lump.position.x, surface + 1),
      velocity: SIMD2(lump.velocity.x * 0.3, impact * random.range(0.08, 0.16)),
      spread: SIMD2(lump.size * 0.4, 1),
      scatter: 0.6
    )

    let count = min(maxMotes - motes.count, Int(2 + lump.size * 0.6 * force))
    guard count > 0 else { return }
    for _ in 0..<count {
      let angle = random.range(0.15, .pi - 0.15)
      let speed = random.range(25, 110) * force
      motes.append(
        Mote(
          position: SIMD2(
            lump.position.x + random.range(-0.5, 0.5) * lump.size,
            surface + random.range(0, lump.size * 0.4)),
          velocity: SIMD2(
            cos(angle) * speed * 1.4 + lump.velocity.x * 0.2, sin(angle) * speed * 0.6),
          size: random.range(0.3, 0.6) * lump.size + 1,
          alpha: random.range(0.1, 0.22),
          life: random.range(0.45, 0.9)
        ))
    }
  }

  /// `scatter` varies each clump's speed by that fraction, so a thrown sheet of snow breaks up instead of flying as one band.
  /// Of a heap of leaves, `leaves` of what comes off shows as the leaves it is made of.
  private func release(
    _ area: Float, at position: SIMD2<Float>, velocity: SIMD2<Float>,
    spread: SIMD2<Float> = SIMD2(1, 1), scatter: Float = 0, leaves: Float = 0
  ) {
    guard area > 0.02 else { return }
    if autumn && leaves > 0 {
      let count = min(
        Int(area * leaves / leafShown + random.next()), maxGrains - grains.count, Int(spareLeaves())
      )
      if count > 0 {
        leafBudget = spareLeaves() - Float(count)
        // The leaves carry the bulk along, so the heap makes up again just where and when they land.
        for _ in 0..<count {
          grains.append(
            Grain(
              position: position
                + SIMD2(random.range(-spread.x, spread.x), random.range(0, spread.y)),
              velocity: velocity * (1 + random.range(-scatter, scatter))
                + SIMD2(random.range(-40, 40), random.range(10, 60)),
              area: area / Float(count),
              size: leafLength(depth: random.range(0.3, 1)),
              seed: random.range(0.001, 1)
            ))
        }
        return
      }
    }
    let room = maxGrains - grains.count
    guard room > 0 else {
      ground.deposit(area, at: position.x, wide: true)
      return
    }
    if autumn {
      // The bulk goes unseen and makes up a heap again wherever it lands; whatever leaves show come off above.
      let count = min(room, Int(area / leafArea) + 1, 4)
      let share = area / Float(count)
      for _ in 0..<count {
        grains.append(
          Grain(
            position: position
              + SIMD2(random.range(-spread.x, spread.x), random.range(0, spread.y)),
            velocity: velocity * (1 + random.range(-scatter, scatter))
              + SIMD2(random.range(-30, 30), random.range(0, 40)),
            area: share,
            size: 2,
            bulk: true
          ))
      }
      return
    }
    let count = min(room, max(1, min(6, Int(area / 3))))
    let share = area / Float(count)
    for _ in 0..<count {
      grains.append(
        Grain(
          position: position + SIMD2(random.range(-spread.x, spread.x), random.range(0, spread.y)),
          velocity: velocity * (1 + random.range(-scatter, scatter))
            + SIMD2(
              random.range(-12, 12) - 40 * scatter * random.range(-1, 1), random.range(-10, 8)),
          area: share,
          size: min(5, max(1.1, share.squareRoot() * 1.05))
        ))
    }
  }

  /// How many more leaves the heaps can show coming off them: as many as all the bulk lying about is worth, less
  /// the leaves already shown, lying or in the air. Leaves flown off a heap leave their bulk in it, so without
  /// this a heap thrown about again and again would show more and more of them.
  private func spareLeaves() -> Float {
    if let leafBudget { return leafBudget }
    var bulk = grains.reduce(Float(0)) { $0 + $1.area }
    for layer in layers { bulk += layer.heights.reduce(0) { $0 + max($1, 0) } * layer.columnWidth }
    let shown = lying.count + grains.reduce(0) { $0 + ($1.bulk ? 0 : 1) }
    let spare = bulk / leafShown - Float(shown)
    leafBudget = spare
    return spare
  }

  /// How high the snow lying just past one end of a window's ledge comes up that end, from below or beside it: a heap
  /// grown up to a window's end props up the snow on it, so the window stops pouring onto the heap.
  private func outside(of ledge: SnowLayer, left: Bool) -> Float {
    let end = left ? 0 : ledge.count - 1
    let floor = ledge.floor(end)
    let x =
      left
      ? ledge.base.x - ledge.columnWidth * 0.5
      : ledge.base.x + ledge.width + ledge.columnWidth * 0.5
    var highest = -Float.greatestFiniteMagnitude
    for layer in layers where layer !== ledge {
      guard let i = layer.index(at: x), layer.floor(i) <= floor else { continue }
      highest = max(highest, layer.surface(i))
    }
    return max(highest - floor, 0)
  }

  /// Snow that lands past the end of a ledge drops off that end instead.
  private func dropPast(_ layer: SnowLayer, _ area: Float, near x: Float, velocity: Float) {
    guard layer.opensAtEdges, area > 0.05 else { return }
    let leftSide = x < layer.base.x + layer.width / 2
    release(
      area, at: edgePoint(of: layer, left: leftSide), velocity: SIMD2(velocity, -10),
      spread: SIMD2(0.25, 1))
  }

  /// Where snow leaves an open layer: just past its end, at the height the snow reaches on the end column,
  /// which on a rounded corner lies well down the curve.
  private func edgePoint(of layer: SnowLayer, left: Bool) -> SIMD2<Float> {
    let end = left ? 0 : layer.count - 1
    let x = left ? layer.base.x - 0.75 : layer.base.x + layer.width + 0.75
    return SIMD2(x, layer.surface(end))
  }

  // MARK: - Cursor

  private func trackCursor(_ point: SIMD2<Float>, dt: Float) {
    for layer in heldLayers { layer.releaseSupport() }
    heldLayers.removeAll(keepingCapacity: true)

    let center = point + cursorOffset
    guard let previous = cursor else {
      cursor = center
      return
    }
    cursorFrom = previous
    cursor = center

    let delta = center - previous
    var velocity = delta / max(dt, 1.0 / 240)
    let speed = simd_length(velocity)
    if speed > 3000 { velocity *= 3000 / speed }
    cursorVelocity += (velocity - cursorVelocity) * 0.5

    let low = min(center.y, previous.y) - cursorRadius
    let high = max(center.y, previous.y) + cursorRadius
    let left = min(center.x, previous.x) - cursorRadius
    let right = max(center.x, previous.x) + cursorRadius
    let touched = layers.filter { layer in
      low <= layer.base.y + layer.top + 1 && high >= layer.base.y - layer.bedDepth
        && right >= layer.base.x && left <= layer.base.x + layer.width
        && (layer === ground || layer.top > 0.01)
    }
    guard !touched.isEmpty else { return }

    let distance = simd_length(delta)
    if distance > 400 {
      for layer in touched { carve(layer, at: center, velocity: .zero, travel: 0, final: true) }
      return
    }
    let steps = Int(distance / (cursorRadius * 0.5)) + 1
    for step in 1...steps {
      let position = previous + delta * (Float(step) / Float(steps))
      for layer in touched {
        carve(
          layer, at: position, velocity: velocity, travel: distance / Float(steps),
          final: step == steps)
      }
    }
  }

  private func carve(
    _ layer: SnowLayer, at center: SIMD2<Float>, velocity: SIMD2<Float>, travel: Float, final: Bool
  ) {
    let radius = cursorRadius
    let lower = max(0, Int(((center.x - radius - layer.base.x) / columnWidth).rounded(.down)))
    let upper = min(
      layer.count - 1, Int(((center.x + radius - layer.base.x) / columnWidth).rounded(.down)))
    guard lower <= upper else { return }

    let local = center.y - layer.base.y
    let sprayShare =
      autumn
      ? smoothstep(60, 500, simd_length(velocity)) : smoothstep(60, 420, simd_length(velocity))
    var pushedLeft: Float = 0
    var pushedRight: Float = 0

    for i in lower...upper where layer.visible[i] {
      let x = layer.centerX(i)
      let dx = x - center.x
      let reach = radius * radius - dx * dx
      guard reach > 0 else { continue }
      let half = reach.squareRoot()
      // Heights here are measured up from the bed under this column.
      let bedLevel = layer.bed[i]
      let bottom = max(0, local - half - bedLevel)
      let top = local + half - bedLevel
      guard top > bottom else { continue }
      let h = layer.heights[i]
      let buried = h > top
      if final && !buried && h >= bottom - 1 {
        if !heldLayers.contains(where: { $0 === layer }) { heldLayers.append(layer) }
        layer.hold(i)
      }
      guard h > bottom + 0.01 else { continue }

      // A buried cursor only displaces the snow it sweeps through; the rest rests on top of it.
      let removed = buried ? (top - bottom) * min(1, travel / (2 * radius)) : h - bottom
      guard removed > 0.001 else { continue }
      layer.set(i, h - removed)
      lastCursorPush = clock
      heightsChanged = true

      var area = removed * columnWidth
      if autumn {
        // The lying leaves on top fly off by themselves; only the mass under them is swept out.
        let hidden = max(0, leafCover - (buried ? h - top : 0))
        area = max(0, removed - hidden) * columnWidth
      }
      let surface = layer.floor(i) + (buried ? h - removed : h)
      let sprayed =
        sprayShare > 0
        ? emit(area * sprayShare, from: SIMD2(x, surface), center: center, velocity: velocity) : 0
      let side = abs(velocity.x) > 40 ? velocity.x : dx
      if side < 0 { pushedLeft += area - sprayed } else { pushedRight += area - sprayed }
    }

    for (area, x) in [
      (pushedLeft, center.x - radius - columnWidth * 3),
      (pushedRight, center.x + radius + columnWidth * 3),
    ] where area > 0 {
      let missed = layer.deposit(area, at: x, wide: true)
      dropPast(layer, missed, near: x, velocity: velocity.x * 0.5)
    }
  }

  private func emit(
    _ area: Float, from origin: SIMD2<Float>, center: SIMD2<Float>, velocity: SIMD2<Float>
  ) -> Float {
    guard area > 0.6, grains.count < maxGrains else { return 0 }
    let count = min(4, Int(area / 1.6) + 1)
    let share = area / Float(count)
    let speed = simd_length(velocity)
    let offset = origin - center
    let length = simd_length(offset)
    let outward = length > 0.001 ? offset / length : SIMD2<Float>(0, 1)

    if autumn {
      // Leaves swept out of a heap skim along the way the cursor goes, a whole leaf at a time.
      let leaves = min(3, Int(area / leafArea + random.next()))
      guard leaves > 0 else { return 0 }
      for _ in 0..<leaves {
        grains.append(
          Grain(
            position: origin + SIMD2(random.range(-2, 2), random.range(0, 3)),
            velocity: swept(by: velocity + outward * (speed * random.range(0.05, 0.15))),
            area: area / Float(leaves),
            size: leafLength(depth: pow(random.next(), 1.2))
          ))
      }
      return area
    }

    for _ in 0..<count {
      var v = velocity * random.range(0.55, 1.25) + outward * (speed * random.range(0.05, 0.25))
      v.y += speed * random.range(0.02, 0.2)
      v += SIMD2(random.range(-30, 30), random.range(-20, 40))
      grains.append(
        Grain(
          position: origin + SIMD2(random.range(-1, 1), random.range(0, 2)),
          velocity: v,
          area: share,
          size: min(4.2, max(1.1, share.squareRoot() * 1.05))
        ))
    }
    return area
  }

  // MARK: - Particles

  /// The highest visible snow surface crossed while falling from `from` to `to` at `x`, allowing for the surface moving meanwhile.
  private func landing(x: Float, from: Float, to: Float) -> (layer: SnowLayer, index: Int)? {
    var hit: (layer: SnowLayer, index: Int)?
    var highest = -Float.greatestFiniteMagnitude
    for ledge in ledgeList {
      guard let i = ledge.index(at: x), ledge.visible[i] else { continue }
      let surface = ledge.surface(i)
      // Entering the snow from above the window's edge counts, even if the surface rose this frame.
      if from >= ledge.previousBaseY + ledge.bed[i] && to <= surface && surface > highest {
        hit = (ledge, i)
        highest = surface
      }
    }
    if let hit { return hit }
    let i = ground.clampedIndex(at: x)
    return to <= ground.surface(i) ? (ground, i) : nil
  }

  private func advanceFlakes(dt: Float) {
    let wind = breeze() + slideWind
    // A Space's wind is short: the flakes take it up faster than the slow breeze, or it would be gone first.
    let follow = min(1, dt * (1.2 + abs(slideWind) * 0.03))
    let settle = min(1, dt * 1.6)
    let wake = cursorWake()

    var i = flakes.count - 1
    while i >= 0 {
      var flake = flakes[i]
      if retiring {
        flake.retirementLife -= dt
        if flake.retirementLife <= 0 {
          removeFlake(i)
          i -= 1
          continue
        }
        if flake.retirementLife < 1 { flake.alpha = min(flake.alpha, flake.retirementLife) }
      }
      if flake.blown != 0 {
        // The nearer the flake, the faster the gust seems to carry it.
        flake.velocity.x +=
          (flake.blown * gustWind * (1.3 + 1.3 * flake.depth) - flake.velocity.x) * min(1, dt * 2.5)
      } else {
        let local = airflow?.sample(flake.position) ?? SIMD2(weatherWind, 0)
        let localWind = wind - weatherWind + local.x
        let response: Float =
          botanicalStyle == 3 || botanicalStyle == 6 ? 1.6 : botanicalStyle == 5 ? 0.8 : 1
        flake.velocity.x +=
          (localWind * (0.35 + 0.65 * flake.depth) - flake.velocity.x) * min(1, follow * response)
        flake.velocity.y += local.y * dt * response

      }
      flake.velocity.y += (-flake.fallSpeed - flake.velocity.y) * settle

      if botanicalStyle == 3 && flake.leaf > 2 && touchesDandelion(flake.position, size: flake.size) {
        popDandelion(at: flake.position, velocity: flake.velocity, size: flake.size, area: flake.size * leafBulk)
        recycle(i); i -= 1; continue
      }
      if let wake { stir(&flake.velocity, at: flake.position, in: wake, dt: dt) }

      // Harmonic ratios 2.3 and 1.3 stay continuous across the 20π wrap.
      flake.phase += flake.swayRate * dt
      if flake.phase > phaseWrap { flake.phase -= phaseWrap }
      if flake.tintAmount > 0 { flake.tintAmount = max(0, flake.tintAmount - dt * 1.3) }
      let previousY = flake.position.y
      flake.position += motion(of: flake) * dt

      if flake.blown != 0 && (flake.position.x < -30 || flake.position.x > width + 30) {
        removeFlake(i)
        i -= 1
        continue
      }
      if flake.position.x < -30 {
        flake.position.x += width + 60
      } else if flake.position.x > width + 30 {
        flake.position.x -= width + 60
      }

      if flake.settles && flake.blown == 0 {
        if flake.leaf > 0
          && surfaceDrift.catchMaterial(
            x: flake.position.x, from: previousY,
            to: flake.position.y, velocity: flake.velocity, size: flake.size, seed: flake.leaf,
            area: flake.size * leafBulk, turn: turn(of: flake), water: waterSurfaces)
        {
          recycle(i)
          i -= 1
          continue
        }
        if flake.leaf == 0,
          let pool = waterSurfaces.first(where: {
            let top = $0.origin.y + $0.depth(at: flake.position.x)
            return $0.accepts(x: flake.position.x) && $0.depth(at: flake.position.x) > 0.3
              && previousY >= top && flake.position.y <= top
          })
        {
          pool.hit(
            x: flake.position.x, amount: min(0.12, flake.size * flake.size * 0.004), impulse: 0.15)
          recycle(i)
          i -= 1
          continue
        }
      }
      if flake.settles && accumulates && flake.blown == 0 {
        if let hit = landing(x: flake.position.x, from: previousY, to: flake.position.y) {
          if snowfallHeld && flake.mass < 1 && hit.layer === ground {
            snowfallHeld = false
            snowfallReleased()
          }
          if flake.leaf > 0 {
            let bulk = hit.layer.fill(hit.index) > 0 ? flake.size * leafBulk : 0
            lay(
              size: flake.size, seed: flake.leaf, area: bulk, at: flake.position.x, on: hit.layer,
              turn: turn(of: flake), flip: tumble(flake.leaf), drift: flake.velocity.x)
          } else {
            hit.layer.deposit(
              flake.size * flake.size * deposition * flake.mass * hit.layer.fill(hit.index),
              at: flake.position.x, wide: true)
          }
          heightsChanged = true
          recycle(i)
          i -= 1
          continue
        }
      } else if flake.position.y < -flake.size * 2 {
        recycle(i)
        i -= 1
        continue
      }

      flakes[i] = flake
      i -= 1
    }
  }

  /// The air a moving cursor drags along, which carries off what falls through it; nil while it is still.
  private func cursorWake() -> (center: SIMD2<Float>, velocity: SIMD2<Float>)? {
    guard let cursor else { return nil }
    let speed = simd_length(cursorVelocity)
    guard speed > 20 else { return nil }
    return (cursor, speed > 500 ? cursorVelocity * (500 / speed) : cursorVelocity)
  }

  private func stir(
    _ velocity: inout SIMD2<Float>, at position: SIMD2<Float>,
    in wake: (center: SIMD2<Float>, velocity: SIMD2<Float>), dt: Float
  ) {
    let radius: Float = 80
    let distanceSquared = simd_length_squared(position - wake.center)
    guard distanceSquared < radius * radius else { return }
    let falloff = 1 - distanceSquared.squareRoot() / radius
    velocity += (wake.velocity - velocity) * min(1, falloff * falloff * 4 * dt)
  }

  private func advanceGrains(dt: Float) {
    guard !grains.isEmpty else { return }
    let wake = cursorWake()
    let damping = exp(-grainDrag * dt)
    let airDrag = exp(-3.2 * dt)
    let wind = breeze() + slideWind
    let time = Float(clock.truncatingRemainder(dividingBy: 1000))
    var i = grains.count - 1
    while i >= 0 {
      var grain = grains[i]
      if botanicalStyle == 3 && grain.seed > 2 && touchesDandelion(grain.position, size: grain.size) {
        popDandelion(at: grain.position, velocity: grain.velocity, size: grain.size, area: grain.area)
        removeGrain(i); i -= 1; continue
      }

      let previousY = grain.position.y
      if grain.blown {
        // Light powder: the wind keeps it moving toward the edge it was blown to, and it barely sinks.
        let speed = grain.velocity.x < 0 ? -gustWind * 1.6 : gustWind * 1.6
        grain.velocity.x += (speed - grain.velocity.x) * min(1, dt * 2)
        grain.velocity.y -= gravity * 0.08 * dt
      } else if autumn {
        // A leaf catches the air: flung up, it soon loses its speed and flutters down, swinging from side to side.
        let phase = time * (1.2 + grain.seed) + grain.seed * 40
        let fall = (35 + 30 * grain.seed) * (0.3 + 1.1 * abs(cos(phase)))
        let local = airflow?.sample(grain.position) ?? SIMD2(weatherWind, 0)
        let carried = wind - weatherWind + local.x
        grain.velocity.x = (grain.velocity.x - carried) * airDrag + carried
        grain.velocity.y += local.y * dt
        grain.velocity.y = (grain.velocity.y + fall) * airDrag - fall
        // Leaves falling off a window or swept out of a heap ride the cursor's wake as the falling ones do.
        if let wake, !grain.bulk { stir(&grain.velocity, at: grain.position, in: wake, dt: dt) }
        // As wide as a falling leaf's swing: tossed up, it glides off to one side and back as it comes down.
        grain.position.x += cos(phase) * 60 * dt
      } else {
        grain.velocity.y -= gravity * dt
        grain.velocity *= damping
      }
      grain.position += grain.velocity * dt

      if autumn && !grain.bulk && !grain.blown
        && surfaceDrift.catchMaterial(
          x: grain.position.x,
          from: previousY, to: grain.position.y, velocity: grain.velocity, size: grain.size,
          seed: grain.seed, area: grain.area, turn: turn(of: grain), water: waterSurfaces)
      {
        removeGrain(i)
        i -= 1
        continue
      }
      if grain.position.x < -10 || grain.position.x > width + 10 || grain.position.y < -10 {
        removeGrain(i)
      } else if !grain.blown, grain.velocity.y <= 0,
        let hit = landing(x: grain.position.x, from: previousY, to: grain.position.y)
      {
        if grain.lump > 0 {
          burst(grain, into: hit.layer)
          heightsChanged = true
          removeGrain(i)
          i -= 1
          continue
        }
        if autumn && !grain.bulk && hit.layer.agitation > leafShaking {
          // A shaken window lets no leaf settle: it hops off again the way the window goes, and so works
          // its way off the edges.
          grain.position.y = hit.layer.surface(hit.index) + 1
          let window = hit.layer.trackVelocity
          grain.velocity = SIMD2(
            window.x * random.range(0.6, 1) + random.range(-120, 120),
            random.range(80, 180) + max(window.y, 0) * random.range(0.6, 1))
          grains[i] = grain
          i -= 1
          continue
        }
        if autumn && !grain.bulk {
          lay(
            size: grain.size >= 5.5 ? grain.size : 6 + grain.seed * 4.5, seed: grain.seed,
            area: grain.area, at: grain.position.x,
            on: hit.layer, turn: turn(of: grain), flip: tumble(grain.seed), drift: grain.velocity.x)
          removeGrain(i)
          i -= 1
          continue
        }
        let missed = hit.layer.deposit(grain.area, at: grain.position.x, wide: true)
        dropPast(hit.layer, missed, near: grain.position.x, velocity: grain.velocity.x * 0.5)
        heightsChanged = true
        removeGrain(i)
      } else {
        grains[i] = grain
      }
      i -= 1
    }
  }

  private func advanceMotes(dt: Float) {
    guard !motes.isEmpty else { return }
    let damping = exp(-3.2 * dt)
    let drift = windSpeed() * 0.4
    var i = motes.count - 1
    while i >= 0 {
      var mote = motes[i]
      mote.age += dt
      if mote.age >= mote.life {
        motes.swapAt(i, motes.count - 1)
        motes.removeLast()
      } else {
        mote.velocity.y -= 35 * dt
        mote.velocity *= damping
        mote.position += (mote.velocity + SIMD2(drift, 0)) * dt
        motes[i] = mote
      }
      i -= 1
    }
  }

  /// Turns the pieces into snowflakes that drift down and fade to white; together they leave a small drift.
  func scatter(_ pieces: [ScatterPiece]) {
    stirred()
    scatteredUntil = clock + 8
    for piece in pieces {
      let depth = pow(random.next(), 0.7)
      flakes.append(
        Flake(
          position: piece.position,
          velocity: piece.velocity,
          fallSpeed: 70 + depth * 170 + random.range(0, 40),
          size: 1.8 + depth * 2.6,
          depth: depth,
          alpha: 0.5 + depth * 0.45,
          soft: 0.7 - depth * 0.4,
          phase: random.range(0, phaseWrap),
          swayRate: random.range(0.6, 1.8),
          swayAmount: random.range(8, 24),
          settles: true,
          mass: 0.06,
          tint: piece.color,
          tintAmount: 1
        ))
    }
  }

  private func removeGrain(_ i: Int) {
    grains.swapAt(i, grains.count - 1)
    grains.removeLast()
  }

  private func recycle(_ i: Int) {
    if flakes.count <= targetFlakes && !holding {
      flakes[i] = makeFlake(y: height + random.range(4, 40))
    } else {
      removeFlake(i)
    }
  }

  private func removeFlake(_ i: Int) {
    flakes.swapAt(i, flakes.count - 1)
    flakes.removeLast()
  }

  /// No new snow falls until the gust has carried off the last flake, then the snowfall starts again from the top.
  private func spawnFlakes() {
    guard flakes.count < targetFlakes, !holding else { return }
    for _ in flakes.count..<targetFlakes {
      flakes.append(makeFlake(y: height + random.range(0, height * 0.8)))
    }
  }

  private func makeFlake(y: Float) -> Flake {
    if autumn { return makeLeaf(y: y) }
    let near = random.next() < 0.02
    let depth = near ? 1 : pow(random.next(), 1.6)
    let fallSpeed = near ? random.range(75, 100) : 16 + depth * 50 + random.range(0, 10)
    return Flake(
      position: SIMD2(random.range(-30, width + 30), y),
      velocity: SIMD2(windSpeed() * (0.35 + 0.65 * depth), -fallSpeed),
      fallSpeed: fallSpeed,
      size: near ? random.range(8, 13) : 1.4 + depth * 4.4 + random.range(0, 1),
      depth: depth,
      alpha: near ? 0.28 : 0.4 + depth * 0.5,
      soft: near ? 0.95 : 0.75 - depth * 0.45,
      phase: random.range(0, phaseWrap),
      swayRate: random.range(0.5, 1.4),
      swayAmount: near ? random.range(10, 20) : random.range(4, 9) + depth * 10,
      settles: !near
    )
  }

  private func makeLeaf(y: Float) -> Flake {
    let depth = pow(random.next(), 1.2)
    let delicate = botanicalStyle == 3 || botanicalStyle == 6
    let fallSpeed =
      (24 + depth * 36 + random.range(0, 12))
      * (delicate ? 0.42 : botanicalStyle == 5 ? 1.3 : botanicalStyle == 2 ? 0.75 : 1)
    return Flake(
      position: SIMD2(random.range(-30, width + 30), y),
      velocity: SIMD2(windSpeed() * (0.35 + 0.65 * depth), -fallSpeed),
      fallSpeed: fallSpeed,
      size: leafLength(depth: depth)
        * (botanicalStyle == 2
          ? 0.64 : botanicalStyle == 3 ? 2.7 : botanicalStyle == 4 ? 0.82 : botanicalStyle == 6 ? 0.65 : 1),
      depth: depth,
      alpha: 0.88 + depth * 0.12,
      soft: 0,
      phase: random.range(0, phaseWrap),
      swayRate: botanicalStyle == 5 ? random.range(3.5, 5.5) : random.range(1.1, 2.0),
      swayAmount: random.range(26, 46) + depth * 20,
      settles: true,
      leaf: random.range(0.001, 1) + (botanicalStyle == 3 ? 2 : 0)
    )
  }

  private func touchesDandelion(_ point: SIMD2<Float>, size: Float) -> Bool {
    guard simd_length(cursorVelocity) > 70, let cursor, let from = cursorFrom else { return false }
    let segment = cursor - from
    if simd_length_squared(segment) > 160_000 {
      return simd_distance(point, cursor) < size * 0.44 + 4
    }
    let t = max(0, min(1, simd_dot(point - from, segment) / max(0.001, simd_length_squared(segment))))
    return simd_distance(point, from + segment * t) < size * 0.44 + 4
  }

  private func popDandelion(at point: SIMD2<Float>, velocity: SIMD2<Float>, size: Float, area: Float) {
    dandelionBursts += 1
    let count = min(18, max(10, Int(size * 0.4)), maxGrains - grains.count)
    guard count > 0 else { return }
    for k in 0..<count {
      let angle = Float(k) / Float(count) * 2 * .pi + random.range(-0.16, 0.16)
      let radial = SIMD2(cos(angle), sin(angle))
      grains.append(Grain(position: point + radial * random.range(1, size * 0.22),
        velocity: velocity * 0.25 + cursorVelocity * 0.20 + radial * random.range(65, 155),
        area: area / Float(count), size: random.range(8, 13), seed: random.range(0.001, 1)))
    }
    for _ in 0..<4 where motes.count < maxMotes {
      motes.append(Mote(position: point + SIMD2(random.range(-4,4),random.range(-4,4)),
        velocity: cursorVelocity * 0.08 + SIMD2(random.range(-35,35),random.range(-15,35)),
        size: random.range(16,30), alpha: random.range(0.07,0.13), life: random.range(0.3,0.55)))
    }
    stirred()
  }

  private func windSpeed() -> Float {
    breeze() + gustSpeed() + slideWind
  }

  private func breeze() -> Float {
    let t = clock
    let breeze = Float(10 * sin(t * 0.07) + 6 * sin(t * 0.19 + 1.7) + 3 * sin(t * 0.43 + 4.1))
    return breeze * (0.6 + 0.4 * strength) + weatherWind
  }

  private func gustSpeed() -> Float {
    guard let gust, !gust.calm else { return 0 }
    let age = Float(clock - gust.start)
    return gust.direction * gustWind * smoothstep(0, 0.12, age)
      * (1 - smoothstep(0.9, gustLength, age))
  }

  /// Wanders between light lulls, steady snow and heavy flurries.
  private func vary(dt: Float) {
    // In case none of the scattered snow makes it to the bottom, say because it all came to rest on windows.
    if snowfallHeld && scatteredUntil > 0 && clock > scatteredUntil {
      snowfallHeld = false
      snowfallReleased()
    }
    if snowfall != .variable {
      strengthTarget = 1
    } else if clock >= nextShift {
      let roll = random.next()
      strengthTarget =
        roll < 0.25
        ? random.range(0.25, 0.5)
        : roll < 0.75
          ? random.range(0.7, 1.3)
          : random.range(1.5, 2.1)
      nextShift = clock + Double(random.range(60, 240))
    }
    guard abs(strengthTarget - strength) > 0.001 else { return }
    strength += (strengthTarget - strength) * (1 - exp(-dt / 25))
    updateTarget()
  }

  // MARK: - Gust

  /// The way the breeze blows now: 1 to the right, -1 to the left.
  var breezeDirection: Float { breeze() < 0 ? -1 : 1 }

  /// Clears all the snow: a gust in `direction` lifts it off the ground and the windows and blows it off the screen,
  /// or, `calm`, it melts away where it lies.
  func blowAway(direction: Float, calm: Bool) {
    gust = (clock, direction < 0 ? -1 : 1, calm)
    // Snow kept for windows on other Spaces goes too, out of sight.
    dormant.removeAll()
    for entry in parking {
      for i in 0..<entry.ledge.count { entry.ledge.set(i, 0) }
    }
  }

  /// Clears the screen first and lets the other kind fall only after, from the top.
  func switchMode(autumn: Bool, direction: Float, calm: Bool) {
    guard autumn != self.autumn else {
      nextAutumn = nil
      return
    }
    guard nextAutumn == nil else { return }
    nextAutumn = autumn
    switchedAt = clock
    blowAway(direction: direction, calm: calm)
    stirred()
  }

  /// Weather effects have their own simulation. Discard the outgoing season while it is out of sight.
  func resetForWeather() {
    flakes.removeAll(keepingCapacity: true)
    grains.removeAll(keepingCapacity: true)
    motes.removeAll(keepingCapacity: true)
    surfaceDrift.removeAll()
    lying.removeAll(keepingCapacity: true)
    dormant.removeAll()
    parking.removeAll()
    heldLayers.removeAll()
    gust = nil
    nextAutumn = nil
    for layer in layers {
      for i in 0..<layer.count { layer.set(i, 0) }
      layer.refreshTop()
    }
    restyled = true
    stirred()
  }

  private var holding: Bool { nextAutumn != nil || gust.map { !$0.calm } ?? false }

  private func blow(dt: Float) {
    guard let gust else { return }
    let age = Float(clock - gust.start)
    guard age < gustLength || flakes.contains(where: { $0.blown != 0 }) else {
      self.gust = nil
      return
    }
    let margin: Float = 40
    let front = gustFront(age: age, direction: gust.direction, margin: margin)
    // Whatever the front has long passed is gone by now, however deep it was.
    let finish = age > gustSweep + (gust.calm ? 0.6 : 0.8)
    if !gust.calm {
      let trailing = gustFront(age: age - gustLag, direction: gust.direction, margin: margin)
      for i in flakes.indices where flakes[i].blown == 0 {
        // Each flake is caught a little further behind, so the snowfall doesn't go as one straight line.
        let stagger = flakes[i].phase / phaseWrap * 240
        if finish || (trailing - flakes[i].position.x) * gust.direction > stagger {
          flakes[i].blown = gust.direction
        }
      }
      // Whatever else is in the air, like the snow off a window just closed, goes along with the snowfall.
      for i in grains.indices
      where !grains[i].blown
        && (finish || (trailing - grains[i].position.x) * gust.direction > 0)
      {
        grains[i].blown = true
        grains[i].area = 0
        grains[i].velocity =
          autumn
          ? SIMD2(gust.direction * random.range(500, 1100), random.range(60, 260))
          : SIMD2(gust.direction * random.range(800, 1600), random.range(60, 300))
      }
    }
    for k in lying.indices.reversed() {
      let leaf = lying[k]
      guard finish || gust.calm || (front - leaf.layer.heapX - leaf.x) * gust.direction > 0 else {
        continue
      }
      if gust.calm {
        lying.remove(at: k)
      } else {
        fly(
          k, velocity: SIMD2(gust.direction * random.range(500, 1100), random.range(60, 260)),
          blown: true)
      }
    }
    for layer in layers {
      var dust: Float = 0
      for i in 0..<layer.count {
        let height = layer.heights[i]
        guard height > 0 else { continue }
        let x = layer.centerX(i)
        guard gust.calm || (front - x) * gust.direction > 0 else { continue }
        let surface = layer.surface(i)
        let loss =
          finish ? height : min(height, (gust.calm ? height * 2.5 + 6 : height * 8 + 50) * dt)
        layer.set(i, height - loss)
        heightsChanged = true
        guard !gust.calm, layer.visible[i] else { continue }
        dust += loss * layer.columnWidth
        while dust >= 3.5 {
          lift(at: SIMD2(x, surface), direction: gust.direction)
          dust -= 3.5
        }
      }
    }
  }

  /// The wind of a sliding Space skims the drifts, most off the crests that stand above the snow around them:
  /// a little powder flies a short way downwind and settles again.
  private func skim(dt: Float) {
    let share = abs(slideWind) / slideWindMax
    guard share > 0.1 else { return }
    if autumn {
      // It lifts some of the leaves lying on top, never the mass under them.
      let shown = Set(layers.map(ObjectIdentifier.init))
      for k in lying.indices.reversed() where random.next() < share * dt {
        let leaf = lying[k]
        guard shown.contains(ObjectIdentifier(leaf.layer)),
          let i = leaf.layer.index(at: leaf.layer.heapX + leaf.x),
          leaf.layer.visible[i], leaf.layer.surface(i) - leaf.layer.base.y < leaf.top + 2
        else { continue }
        fly(k, velocity: SIMD2(slideWind * random.range(1.5, 3), random.range(30, 120)))
      }
      return
    }
    for layer in layers {
      let count = layer.count
      var dust: Float = 0
      for i in 0..<count where layer.visible[i] {
        let height = layer.heights[i]
        guard height > 1.5 else { continue }
        let around = (layer.heights[max(i - 12, 0)] + layer.heights[min(i + 12, count - 1)]) / 2
        let loss = min(height * 0.2, (0.2 + max(0, height - around) * 1.5) * share * dt)
        layer.set(i, height - loss)
        heightsChanged = true
        dust += loss * layer.columnWidth
        while dust >= 1.5 {
          puff(at: SIMD2(layer.centerX(i), layer.surface(i)), area: 1.5)
          dust -= 1.5
        }
      }
    }
  }

  /// A pinch of powder off a crest, thrown downwind by a sliding Space's wind; it lands again where it falls.
  private func puff(at position: SIMD2<Float>, area: Float) {
    guard grains.count < maxGrains else { return }
    grains.append(
      Grain(
        position: position + SIMD2(random.range(-1, 1), random.range(-2, 0)),
        velocity: SIMD2(slideWind * random.range(1.5, 3), random.range(60, 260)),
        area: area,
        size: random.range(1.1, 2.4)
      ))
    guard random.next() < 0.3, motes.count < maxMotes else { return }
    motes.append(
      Mote(
        position: position,
        velocity: SIMD2(slideWind * random.range(0.8, 2), random.range(20, 90)),
        size: random.range(6, 13),
        alpha: random.range(0.06, 0.12),
        life: random.range(0.5, 1)
      ))
  }

  /// Where the gust's front is `age` seconds in, coming in from `margin` past the windward edge.
  /// It hits at full speed and eases off as it crosses.
  private func gustFront(age: Float, direction: Float, margin: Float) -> Float {
    let t = min(max(age / gustSweep, 0), 1)
    let travel = (width + 2 * margin) * (1 - (1 - t) * (1 - t))
    return direction > 0 ? -margin + travel : width + margin - travel
  }

  private func lift(at position: SIMD2<Float>, direction: Float) {
    // Of a heap of leaves only the lying ones fly off; the bulk under them just goes.
    guard grains.count < maxGrains, !autumn else { return }
    grains.append(
      Grain(
        position: position + SIMD2(random.range(-1, 1), random.range(-3, 0)),
        velocity: SIMD2(direction * random.range(800, 1800), random.range(60, 420)),
        area: 0,
        size: random.range(1.1, 2.6),
        blown: true
      ))
    guard random.next() < 0.35, motes.count < maxMotes else { return }
    motes.append(
      Mote(
        position: position,
        velocity: SIMD2(direction * random.range(200, 600), random.range(20, 120)),
        size: random.range(6, 14),
        alpha: random.range(0.06, 0.14),
        life: random.range(0.6, 1.3)
      ))
  }

  // MARK: - Piles

  private func spin(_ rate: Float) -> Float {
    Float((clock * Double(rate)).truncatingRemainder(dividingBy: 2 * .pi))
  }

  /// How a leaf in the air tumbles about its length.
  private func tumble(_ seed: Float) -> Float {
    if botanicalStyle == 5 { return 0.18 + seed * 0.28 + cos(spin(1.2) + seed * 50) * 0.055 }
    return cos(spin(0.5 + seed * 1.1) + seed * 50)
  }

  /// How a flake actually moves: carried along, swaying from side to side, and for a leaf, swinging like a
  /// pendulum, dropping fastest through the middle of each swing.
  private func motion(of flake: Flake) -> SIMD2<Float> {
    let sway = (cos(flake.phase) + 0.3 * cos(flake.phase * 2.3)) * flake.swayAmount
    let flutter =
      flake.leaf > 0 ? 0.3 + 1.1 * abs(cos(flake.phase)) : 1 + 0.12 * sin(flake.phase * 1.3)
    return SIMD2(flake.velocity.x + sway, flake.velocity.y * flutter)
  }

  private func tumbleSpeed(_ seed: Float) -> Float {
    if botanicalStyle == 5 { return -sin(spin(1.2) + seed * 50) * 0.066 }
    return -sin(spin(0.5 + seed * 1.1) + seed * 50) * (0.5 + seed * 1.1)
  }

  private func turn(of flake: Flake) -> Float {
    flake.leaf * 40 + sin(flake.phase) * 0.6
      + spin(botanicalStyle == 5 ? 36 + flake.leaf * 22 : flake.leaf - 0.5)
  }

  private func turn(of grain: Grain) -> Float {
    grain.seed * 40 + spin(botanicalStyle == 5 ? 36 + grain.seed * 22 : (grain.seed - 0.5) * 9)
  }

  /// A lying leaf follows the slope under it.
  private func restingTurn(of leaf: LyingLeaf, on layer: SnowLayer, at i: Int) -> Float {
    let left = max(i - 2, 0)
    let right = min(i + 2, layer.count - 1)
    let slope =
      (layer.surface(right) - layer.surface(left))
      / (Float(max(right - left, 1)) * layer.columnWidth)
    return atan(slope) + leaf.tilt + leaf.around
  }

  /// A leaf comes down, slides a little the way it was going and settles flat on whatever lies there, adding its
  /// bulk to the heap under it so the next one lands on top.
  private func lay(
    size: Float, seed: Float, area: Float, at x: Float, on layer: SnowLayer, turn: Float,
    flip: Float, drift: Float
  ) {
    let slide = max(-8, min(8, drift * 0.06))
    let spot = x + slide
    let i = layer.clampedIndex(at: spot)
    let rest = layer.surface(i) - layer.base.y
    let steps = max(1, Int(size / 5))
    for step in 0..<steps where area > 0 {
      let along = (Float(step) + 0.5) / Float(steps) - 0.5
      let missed = layer.deposit(area / Float(steps), at: spot + along * size * 0.8, wide: true)
      dropPast(layer, missed, near: spot, velocity: 0)
    }
    let tilt = random.range(-0.2, 0.2)
    let left = max(i - 2, 0)
    let right = min(i + 2, layer.count - 1)
    let flat =
      atan(
        (layer.surface(right) - layer.surface(left))
          / (Float(max(right - left, 1)) * layer.columnWidth)) + tilt
    let toward = wrapped(flat - turn)
    let around: Float = abs(toward) <= .pi / 2 ? 0 : .pi
    let target = flat + around
    lying.append(
      LyingLeaf(
        layer: layer,
        x: spot - layer.heapX,
        rest: rest,
        top: layer.surface(i) - layer.base.y,
        size: size,
        seed: seed,
        tilt: tilt,
        around: around,
        fromTurn: target - wrapped(target - turn),
        fromFlip: flip,
        slide: slide,
        settling: 0.45 + abs(slide) / 90,
        life: botanicalStyle == 5 ? random.range(14, 28) : random.range(90, 180)
      ))
    if lying.count > maxLying { lying.removeFirst() }
    heightsChanged = true
  }

  private func leafLength(depth: Float) -> Float {
    7 + depth * 7 + random.range(0, 2.5)
  }

  private func wrapped(_ angle: Float) -> Float {
    var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
    if a > .pi { a -= 2 * .pi } else if a < -.pi { a += 2 * .pi }
    return a
  }

  /// A leaf the cursor sweeps along: it goes the cursor's way a little slower, barely lifting, and the air soon
  /// slows it down, so it lands a short way off.
  private func swept(by velocity: SIMD2<Float>) -> SIMD2<Float> {
    var v = velocity * random.range(0.5, 0.9)
    let speed = simd_length(v)
    if speed > 450 { v *= 450 / speed }
    return v + SIMD2(random.range(-20, 20), random.range(10, 35) + speed * random.range(0.03, 0.1))
  }

  /// A lying leaf taken up into the air; its bulk stays in the heap, whatever takes the heap takes it.
  private func fly(_ k: Int, velocity: SIMD2<Float>, blown: Bool = false) {
    let speed = simd_length(velocity)
    let velocity = !blown && speed > 900 ? velocity * (900 / speed) : velocity
    let leaf = lying.remove(at: k)
    heightsChanged = true
    guard grains.count < maxGrains else { return }
    grains.append(
      Grain(
        position: SIMD2(leaf.layer.heapX + leaf.x, leaf.layer.base.y + leaf.rest + 1),
        velocity: velocity,
        area: 0,
        size: leaf.size,
        blown: blown,
        seed: leaf.seed
      ))
  }

  /// Lying leaves fly up when the cursor kicks them or the heap under them comes off, sink with it as it settles,
  /// sink out of sight deep under the leaves that land on them, and wither away while the snow melts.
  private func tendLeaves(dt: Float) {
    guard !lying.isEmpty else { return }
    let shown = Set(layers.map(ObjectIdentifier.init))
    let kept = Set(
      dormant.values.map(ObjectIdentifier.init) + parking.map { ObjectIdentifier($0.ledge) })
    let speed = simd_length(cursorVelocity)
    for k in lying.indices.reversed() {
      var leaf = lying[k]
      let leafPoint = SIMD2(leaf.layer.heapX + leaf.x, leaf.layer.base.y + leaf.rest)
      if botanicalStyle == 3 && leaf.seed > 2 && touchesDandelion(leafPoint, size: leaf.size) {
        popDandelion(at: leafPoint, velocity: .zero, size: leaf.size, area: 0)
        lying.remove(at: k); continue
      }
      let layer = leaf.layer
      guard shown.contains(ObjectIdentifier(layer)) else {
        if !kept.contains(ObjectIdentifier(layer)) { fly(k, velocity: .zero) }
        continue
      }
      let x = layer.heapX + leaf.x
      guard let i = layer.index(at: x) else {
        fly(k, velocity: SIMD2(layer.trackVelocity.x, 0))
        continue
      }
      // Material already resting on a dry ledge becomes buoyant as rain reaches it.
      if let pool=waterSurfaces.first(where: {
        (($0.id==0 && layer === ground) || ledges[$0.id] === layer) && $0.accepts(x:x) && $0.depth(at:x)>0.3
          && $0.origin.y+$0.depth(at:x)>=leafPoint.y-leaf.size*0.2
      }) {
        let line=pool.origin.y+pool.depth(at:x)
        if surfaceDrift.catchMaterial(x:x,from:line+1,to:line-1,velocity:.zero,
          size:leaf.size,seed:leaf.seed,area:0,turn:leaf.fromTurn,water:[pool]) {
          lying.remove(at:k);continue
        }
      }
      let surface = layer.surface(i) - layer.base.y
      let point = SIMD2(x, layer.base.y + leaf.rest)
      if let cursor, speed > 8, simd_length(point - cursor) < cursorRadius + leaf.size * 0.4 {
        fly(k, velocity: swept(by: cursorVelocity))
        lastCursorPush = clock
        continue
      }
      // Shaken, the leaves on top go as often as the columns of the heap under them do.
      if random.next() < leafShakeRate(layer.agitation) * 2 * dt {
        fly(
          k,
          velocity: layer.trackVelocity + layer.offsetVelocity
            + SIMD2(random.range(-80, 80), random.range(20, 80)))
        continue
      }
      if surface < leaf.rest - 3 {
        // It goes the way the heap under it went, not the window.
        let carried = layer.trackVelocity + layer.offsetVelocity
        let tossed =
          layer.agitation > leafShaking
          ? SIMD2(random.range(-40, 40), random.range(20, 80)) : SIMD2(random.range(-15, 15), 0)
        fly(k, velocity: carried + tossed)
        continue
      }
      // Deep in a heap a leaf is hidden by the ones above it and the mass drawn under them.
      let buried = surface > leaf.top + 10
      if surface < leaf.top {
        let sink = min(leaf.top - surface, 20 * dt)
        leaf.top -= sink
        leaf.rest -= sink
        heightsChanged = true
      }
      if leaf.settled < 1 {
        leaf.settled = min(1, leaf.settled + dt / leaf.settling)
        heightsChanged = true
      }
      if buried {
        leaf.fade -= dt * 2
        heightsChanged = true
      } else if thaws || retiring || botanicalStyle == 5 {
        leaf.age += dt * retirementRate
        if leaf.age > leaf.life {
          leaf.fade -= dt * retirementRate / 4
          heightsChanged = true
        }
      }
      if leaf.fade <= 0 {
        lying.remove(at: k)
      } else {
        lying[k] = leaf
      }
    }
  }

  private func settle(dt: Float) {
    // Melting nearly keeps pace with the snowfall, so heavier snowfall builds drifts only a little higher, and the
    // far sparser leaves wither as slowly.
    let falling = snowfall.flakesPerMegapoint * strength * density * (autumn ? leafShare : 1)
    let meltPace = falling > 0 ? pow(falling / thawBalance, thawExponent) : 1
    for ledge in ledgeList {
      ledge.outside = (outside(of: ledge, left: true), outside(of: ledge, left: false))
    }
    for layer in layers {
      if !accumulates || thaws || retiring || botanicalStyle == 5 {
        // Withered leaves leave nothing behind.
        let floor =
          retiring || !accumulates || autumn ? 0 : (layer === ground ? thawDepth : ledgeThawDepth)
        if layer.thaw(
          dt: dt * meltPace * retirementRate * meltScale, down: floor, rate: thawRate,
          settle: botanicalStyle == 5 ? 14 : thawTime)
        {
          heightsChanged = true
        }
      }
      // Shaken harder than gravity, a granular pile fluidizes and slumps to a flatter slope.
      // Leaves catch on one another and heap up steeper than snow.
      let steepest = autumn ? repose * 1.8 : repose
      if layer.relax(
        repose: layer.agitation > shaking ? steepest * 0.35 : steepest, rounding: rounding)
      {
        heightsChanged = true
      }
      if layer.spill.left > 1.5 {
        release(
          layer.spill.left, at: edgePoint(of: layer, left: true),
          velocity: layer.trackVelocity + SIMD2(-6, -15), spread: SIMD2(0.25, 1))
        layer.spill.left = 0
      }
      if layer.spill.right > 1.5 {
        release(
          layer.spill.right, at: edgePoint(of: layer, left: false),
          velocity: layer.trackVelocity + SIMD2(6, -15), spread: SIMD2(0.25, 1))
        layer.spill.right = 0
      }
    }
  }

  private func updateTarget() {
    let share: Float = autumn ? leafShare * (botanicalStyle == 3 ? 0.22 : botanicalStyle == 5 ? 0.6 : 1) : 1
    targetFlakes =
      snowfallHeld
      ? 0
      : Int(
        snowfall.flakesPerMegapoint * share * strength * density * weatherStrength * width * height
          / 1_000_000)
  }

  private static func columnCount(for width: Float, columnWidth: Float) -> Int {
    Int((width / columnWidth).rounded(.up)) + 1
  }
}

/// Critically damped follow of `target` (the SmoothDamp approximation), stable at any time step.
private func smoothDamp(
  _ current: inout SIMD2<Float>, _ velocity: inout SIMD2<Float>, toward target: SIMD2<Float>,
  time: Float, dt: Float
) {
  let omega = 2 / time
  let x = omega * dt
  let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
  let change = current - target
  let temp = (velocity + omega * change) * dt
  velocity = (velocity - omega * temp) * decay
  current = target + (change + temp) * decay
}

private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
  let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
  return t * t * (3 - 2 * t)
}
