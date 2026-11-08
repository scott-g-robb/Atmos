import CWeatherCore
import CoreGraphics
import Foundation
import simd

/// Small flocks with approach, landing, perched and takeoff phases. Perches follow
/// their actual windows; disappearing or occluded support immediately releases the bird.
final class BirdFlock {
  private typealias Bird = SHBird
  private var targets: [SHBirdTarget] = []
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
    targets.removeAll(keepingCapacity:true)
    for bird in birds {
      var target=SHBirdTarget()
      if let id=bird.perch,let support=surfaces.first(where:{$0.id==id}) {
        let x=Float(support.frame.minX)+Float(support.frame.width)*bird.perchX
        let y=Float(support.frame.maxY)+5
        if !support.blockers.contains(where:{$0.insetBy(dx:-8,dy:-12).contains(CGPoint(x:CGFloat(x),y:CGFloat(y)))}) {
          target.point=SIMD2(x,y);target.available=1
        }
      }
      targets.append(target)
    }
    if particles.count != birds.count {particles=Array(repeating:WeatherParticle(),count:birds.count)}
    let cells=airflow?.cells ?? [],columns=airflow?.columns ?? 0,rows=airflow?.rows ?? 0
    let spacing=airflow?.spacing ?? 48,base=airflow?.base ?? wind
    let count=birds.withUnsafeMutableBufferPointer { birds in
      targets.withUnsafeBufferPointer { targets in
        particles.withUnsafeMutableBufferPointer { particles in
          cells.withUnsafeBufferPointer { cells in
            sh_step_birds(birds.baseAddress,birds.count,targets.baseAddress,particles.baseAddress,dt,elapsed,
              size.x,size.y,wind,active ? 1:0,cursor.x,cursor.y,cells.baseAddress,columns,rows,spacing,base)
          }
        }
      }
    }
    if count<birds.count {birds.removeLast(birds.count-count);particles.removeLast(particles.count-count)}
  }
}
