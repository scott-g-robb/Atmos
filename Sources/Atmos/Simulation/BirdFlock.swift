import CoreGraphics
import Foundation
import simd

/// Small flocks with approach, landing, perched and takeoff phases. Perches follow
/// their actual windows; disappearing or occluded support immediately releases the bird.
final class BirdFlock {
  private struct Bird {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var species: Int
    var seed: Float
    var facing: Float = 1
    var age: Float = 0
    var phase: Float = 0
    var perch: CGWindowID?
    var perchX: Float = 0.5
    var rest: Float = 0
    var restLimit: Float = 10
    var leaving = false
    var lastSupport: SIMD2<Float>?
    var supportVelocity = SIMD2<Float>.zero
    var supportSeenAt: Float = 0
  }
  private var randomState: UInt64
  init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { randomState = max(1, seed) }
  private func random() -> Float {
    randomState ^= randomState >> 12
    randomState ^= randomState << 25
    randomState ^= randomState >> 27
    return Float((randomState &* 2_685_821_657_736_338_717) >> 40) / Float(1 << 24)
  }
  private var birds: [Bird] = []
  private var nextFlock: Float = 0.8
  private var companionAt: Float?
  private(set) var groupSizes: [Int] = []
  private var elapsed: Float = 0
  private(set) var particles: [WeatherParticle] = []
  var perchedCount: Int { birds.filter { $0.phase == 1 }.count }
  func reset() {
    birds.removeAll()
    particles.removeAll()
    nextFlock = 0.8
    companionAt = nil
    groupSizes.removeAll()
    elapsed = 0
  }

  func step(
    dt: Float, size: SIMD2<Float>, surfaces: [WindowSurface], wind: Float,
    airflow: WindField?, cursor: SIMD2<Float>, active: Bool, reducedMotion: Bool
  ) {
    elapsed += dt
    let companion = companionAt.map { elapsed >= $0 } ?? false
    if active && (elapsed >= nextFlock || companion) && birds.count <= 5 {
      if companion { companionAt = nil }
      else {
        nextFlock = elapsed + 48 + random() * 54
        if !reducedMotion && random() < 0.18 { companionAt = elapsed + 3 + random() * 5 }
      }
      let direction: Float = abs(wind) > 25 && random()<0.8 ? (wind<0 ? -1:1) : (random()<0.5 ? -1:1)
      let candidates = surfaces.filter {
        !$0.isDock && $0.frame.width > 120 && $0.frame.maxY < CGFloat(size.y - 70)
      }
      let firstSpecies = Int(random() * 4)
      let count = min(10 - birds.count, reducedMotion ? 2 : 2 + Int(random() * 4))
      groupSizes.append(count)
      if groupSizes.count > 32 { groupSizes.removeFirst() }
      let altitude = size.y * (0.42 + random() * 0.34)
      let landings = reducedMotion ? min(1,count) : random()<0.18 ? 0 : 1+Int(random()*Float(count))
      // Shuffle the landing subset rather than always choosing the flock leader.
      var order = Array(0..<count)
      for i in order.indices.reversed() { order.swapAt(i,Int(random()*Float(i+1))) }
      let stopping = Set(order.prefix(landings))
      for i in 0..<count {
        let seed = random()
        let species = i == 0 ? firstSpecies : i == count-1
          ? (firstSpecies+1+Int(random()*3))%4 : random()<0.72 ? firstSpecies : Int(random()*4)
        var perch: CGWindowID?
        var perchX: Float = 0.5
        if stopping.contains(i), !candidates.isEmpty {
          for _ in 0..<12 {
            let support = candidates[Int(random()*Float(candidates.count))]
            let fraction = 0.12+random()*0.76
            let x = Float(support.frame.minX)+Float(support.frame.width)*fraction
            let y = Float(support.frame.maxY)+5
            let blocked = support.blockers.contains { $0.insetBy(dx:-12,dy:-14).contains(CGPoint(x:CGFloat(x),y:CGFloat(y))) }
            let occupied = birds.contains { $0.perch == support.id && abs($0.perchX-fraction)*Float(support.frame.width)<38 }
            if !blocked && !occupied { perch=support.id;perchX=fraction;break }
          }
        }
        birds.append(
          Bird(
            position: SIMD2(
              direction > 0 ? -40 - Float(i) * 38 : size.x + 40 + Float(i) * 38,
              altitude + Float(i) * (10 + seed * 14)), velocity: SIMD2(direction * (95 + seed * 20), 0),
            species: species, seed: seed,
            perch: perch, perchX: perchX, restLimit: 5+random()*13))
      }
    }
    particles.removeAll(keepingCapacity: true)
    for i in birds.indices {
      var bird = birds[i]
      bird.age += dt
      if abs(bird.velocity.x) > 2 { bird.facing = bird.velocity.x < 0 ? -1 : 1 }
      let support = bird.perch.flatMap { id in surfaces.first { $0.id == id } }
      var target: SIMD2<Float>?
      if let support {
        let x = Float(support.frame.minX) + Float(support.frame.width) * bird.perchX
        let y = Float(support.frame.maxY) + 5
        let blocked = support.blockers.contains {
          $0.insetBy(dx: -8, dy: -12).contains(CGPoint(x: CGFloat(x), y: CGFloat(y)))
        }
        if !blocked { target = SIMD2(x, y) }
      }
      var startled = false
      if let target {
        if let previous = bird.lastSupport, simd_distance(previous, target) > 0.2 {
          // Window geometry arrives less often than display frames. Cap a long
          // stationary interval so the first shake is not averaged over the whole rest.
          let interval = max(dt, min(0.12, elapsed - bird.supportSeenAt))
          let velocity = simd_clamp((target - previous) / interval, SIMD2(-1200,-900), SIMD2(1200,900))
          let acceleration = simd_length(velocity - bird.supportVelocity) / interval
          startled = bird.phase == 1 && (simd_length(velocity) > 340
            || (acceleration > 3200 && simd_length(velocity - bird.supportVelocity) > 120))
          bird.supportVelocity = velocity; bird.supportSeenAt = elapsed
        }
        if bird.lastSupport == nil { bird.supportSeenAt = elapsed }
        bird.lastSupport = target
      }
      if startled {
        bird.velocity = bird.supportVelocity * 0.35 + SIMD2(bird.facing * 80, 70)
        target = nil
      }
      if !active || startled || (bird.perch != nil && target == nil)
        || simd_distance(cursor, bird.position) < 50 || bird.rest > bird.restLimit
      {
        bird.leaving = true
        bird.perch = nil
        bird.phase = 0
      }
      if bird.phase == 1, let target {
        bird.position = target
        bird.velocity = .zero
        bird.rest += dt
      } else {
        let local = airflow?.sample(bird.position) ?? SIMD2(wind, 0)
        var desired = SIMD2(
          (bird.velocity.x < 0 ? -1 : 1) * 105 + local.x * 0.15,
          sin(elapsed * 1.7 + bird.seed * 31) * 9 + local.y * 0.12)
        if let target, !bird.leaving {
          let delta = target - bird.position
          let distance = simd_length(delta)
          desired = delta / max(1, distance) * min(125, max(14, distance * 1.8))
          if distance < 8 {
            bird.phase = 1
            bird.position = target
            bird.velocity = .zero
          }
        } else if bird.leaving {
          desired.y = 55
        }
        bird.velocity += (desired - bird.velocity) * min(1, dt * 3)
        if bird.phase != 1 { bird.position += bird.velocity * dt }
      }
      particles.append(
        WeatherParticle(
          rect: SIMD4(
            bird.position.x, bird.position.y, bird.species == 3 ? 33 : 28 + bird.seed * 2,
            bird.species == 3 ? 25 : 27),
          motion: SIMD4(bird.velocity.x, bird.velocity.y, bird.seed, 14),
          color: SIMD4(0.24, 0.28, 0.33, min(1, bird.age * 2)),
          life: SIMD4(2, 10000, bird.facing * Float(bird.species + 1), bird.phase)))
      birds[i] = bird
    }
    birds.removeAll {
      $0.age > 48 || $0.position.x < -200 || $0.position.x > size.x + 200
        || $0.position.y > size.y + 80
    }
  }
}
