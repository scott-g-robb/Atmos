import CWeatherCore
import XCTest
import simd

@testable import Atmos

final class EffectPolishTests: XCTestCase {
  private let away = SIMD2<Float>(-1000, -1000)
  private func sprites(_ simulation: SnowSimulation) -> [Sprite] {
    let buffer = UnsafeMutablePointer<Sprite>.allocate(capacity: 20000)
    defer { buffer.deallocate() }
    let count = simulation.writeSprites(into: buffer, capacity: 20000)
    return Array(UnsafeBufferPointer(start: buffer, count: count))
  }

  func testFlocksVaryBetweenTwoAndFiveWithOccasionalSecondGroupsAndQuietGaps() {
    var sizes = Set<Int>(), singles = 0, doubles = 0
    for seed in UInt64(1)...40 {
      let flock = BirdFlock(seed: seed)
      for _ in 0..<900 {
        flock.step(dt: 1 / 30, size: SIMD2(1200, 800), surfaces: [], wind: 0,
          airflow: nil, cursor: away, active: true, reducedMotion: false)
        XCTAssertLessThanOrEqual(flock.particles.count, 10)
      }
      sizes.formUnion(flock.groupSizes)
      if flock.groupSizes.count == 1 { singles += 1 }
      if flock.groupSizes.count == 2 { doubles += 1 }
      XCTAssertTrue((1...2).contains(flock.groupSizes.count), "No repeated arrivals in the first quiet interval")
    }
    XCTAssertEqual(sizes, Set(2...5))
    XCTAssertGreaterThan(singles, doubles * 2)
    XCTAssertGreaterThan(doubles, 0)
  }

  func testPerchedBirdFollowsSlowWindowMovementAndEscapesAShake() {
    let flock = BirdFlock(seed: 42)
    var window = WindowSurface(id: 41, frame: CGRect(x: 200, y: 100, width: 500, height: 250),
      blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
    for _ in 0..<1800 {
      flock.step(dt: 1 / 120, size: SIMD2(1000, 700), surfaces: [window], wind: 0,
        airflow: nil, cursor: away, active: true, reducedMotion: false)
      if flock.perchedCount > 0 { break }
    }
    XCTAssertGreaterThan(flock.perchedCount, 0)
    for _ in 0..<60 {
      window = WindowSurface(id: window.id, frame: window.frame.offsetBy(dx: 0.25, dy: 0),
        blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
      flock.step(dt: 1 / 120, size: SIMD2(1000, 700), surfaces: [window], wind: 0,
        airflow: nil, cursor: away, active: true, reducedMotion: false)
    }
    XCTAssertGreaterThan(flock.perchedCount, 0, "A slow drag carries resting birds")
    window = WindowSurface(id: window.id, frame: window.frame.offsetBy(dx: -65, dy: 0),
      blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
    flock.step(dt: 1 / 120, size: SIMD2(1000, 700), surfaces: [window], wind: 0,
      airflow: nil, cursor: away, active: true, reducedMotion: false)
    XCTAssertEqual(flock.perchedCount, 0)
    XCTAssertTrue(flock.particles.contains { $0.motion.y > 20 })
  }

  func testWholeDandelionPopsOnlyOnACursorStrokeIntoAirborneSeedsAndPoof() throws {
    let sim = SnowSimulation(width: 1000, height: 700, snowfall: .steady)
    sim.botanicalStyle = 3
    sim.autumn = true
    var visibleHead:Sprite?
    for frame in 0..<7200 {
      _=sim.step(dt:1/120,cursor:away)
      if frame % 120 == 0 {
        visibleHead=sprites(sim).first {$0.leaf>2 && $0.position.y>40 && $0.position.y<660 && $0.position.x>100 && $0.position.x<900}
        if visibleHead != nil {break}
      }
    }
    let head = try XCTUnwrap(visibleHead)
    XCTAssertEqual(sim.dandelionBursts, 0)
    let point = head.position - SIMD2(4, -8)
    _ = sim.step(dt: 1 / 120, cursor: point - SIMD2(90, 0))
    _ = sim.step(dt: 1 / 120, cursor: point + SIMD2(90, 0))
    let result = sprites(sim)
    XCTAssertGreaterThan(sim.dandelionBursts, 0)
    XCTAssertGreaterThanOrEqual(result.filter { $0.leaf > 0 && $0.leaf < 1 }.count, 10)
    XCTAssertTrue(result.contains { $0.leaf == 0 && $0.soft > 0 })
    XCTAssertTrue(result.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    let bursts = sim.dandelionBursts
    for _ in 0..<60 { _ = sim.step(dt: 1 / 120, cursor: point + SIMD2(90, 0)) }
    XCTAssertEqual(sim.dandelionBursts, bursts, "A stationary pointer must not repeatedly burst heads")
  }

  func testMapleSeedsAutorotateWithoutSpeedingUpTheirFall() throws {
    let sim = SnowSimulation(width: 1000, height: 700, snowfall: .steady)
    sim.botanicalStyle = 5
    sim.autumn = true
    for _ in 0..<120 { _ = sim.step(dt: 1 / 120, cursor: away) }
    let seed = try XCTUnwrap(sprites(sim).first { $0.leaf > 0 })
    XCTAssertGreaterThan(seed.turnSpeed, 32)
    XCTAssertLessThan(seed.turnSpeed, 61)
    XCTAssertLessThan(abs(seed.velocity.y), 150)
    XCTAssertTrue((0.12...0.58).contains(seed.flip))
    _ = sim.step(dt: 1 / 120, cursor: away)
    let next = try XCTUnwrap(sprites(sim).first { $0.leaf == seed.leaf })
    let angularTravel = abs(atan2(sin(next.turn - seed.turn), cos(next.turn - seed.turn)))
    XCTAssertGreaterThan(angularTravel, 0.25)
  }

  func testOverfilledMeniscusSpillsAndConservesIncomingRain() {
    let pool = WaterSurface(id: 41, origin: SIMD2(200, 300), width: 400)
    for x in stride(from: Float(200), through: 600, by: 4) { pool.hit(x: x, amount: 2.5, impulse: 0) }
    for _ in 0..<120 { pool.step(dt: 1 / 120, evaporates: false, clearing: false) }
    XCTAssertLessThan(pool.outflow.left + pool.outflow.right, 0.01)
    let before = pool.volume
    // Uniform persistent rain raises the head beyond the capillary retention depth.
    for x in stride(from: Float(208), through: 592, by: 4) { pool.hit(x: x, amount: 5, impulse: 0) }
    let added = Float(97 * 5)
    XCTAssertEqual(pool.volume, before + added, accuracy: 0.02, "Rain must not be clipped at the old five-point limit")
    pool.sweep(x: 220, velocity: 700, dt: 1 / 120)
    for _ in 0..<1200 { pool.step(dt: 1 / 120, evaporates: false, clearing: false) }
    XCTAssertLessThanOrEqual(pool.top, pool.limit + 2.5)
    XCTAssertTrue(pool.depths.allSatisfy { $0 <= pool.limit + 0.01 })
    XCTAssertGreaterThan(pool.outflow.left + pool.outflow.right, 5)
    XCTAssertEqual(pool.volume + pool.detached + pool.outflow.left + pool.outflow.right, before + added, accuracy: 0.15)
  }

  func testWaterSeparationUsesExistingMomentumRatherThanAnUpwardPreset() {
    func pool() -> WaterSurface {
      let water = WaterSurface(id: 41, origin: SIMD2(100, 200), width: 300)
      for x in stride(from: Float(100), through: 400, by: 4) { water.hit(x: x, amount: 4, impulse: 0) }
      water.step(dt: 1 / 120, evaporates: false, clearing: false)
      return water
    }
    let down = pool(), original = down.volume
    down.move(to: SIMD2(100, 180), interval: 1 / 60, now: 1, physical: true)
    XCTAssertGreaterThan(down.detached, 1)
    XCTAssertTrue(down.releases.allSatisfy { abs($0.velocity.y) < 1 }, "Dropping the support leaves initially stationary water behind")
    XCTAssertEqual(down.volume + down.detached, original, accuracy: 0.01)
    let up = pool()
    up.move(to: SIMD2(100, 210), interval: 1 / 60, now: 1, physical: true)
    XCTAssertEqual(up.detached, 0)
    up.settleMotion(now: 1.05)
    XCTAssertGreaterThan(up.detached, 1)
    XCTAssertTrue(up.releases.allSatisfy { $0.velocity.y > 590 }, "Stopping an upward support releases the water with that upward momentum")
  }
  func testSolidCursorDisplacesVolumeWhileHeldAndWaterRefillsAfterExit() {
    let pool=WaterSurface(id:0,origin:.zero,width:400)
    for x in stride(from:Float(0),through:400,by:4) {pool.hit(x:x,amount:8,impulse:0)}
    for _ in 0..<60 {pool.step(dt:1/120,evaporates:false,clearing:false)}
    let mass=pool.volume
    for _ in 0..<120 {
      pool.step(dt:1/120,evaporates:false,clearing:false)
      XCTAssertTrue(pool.collide(cursor:SIMD2(200,4),previous:SIMD2(200,4),velocity:.zero,dt:1/120))
      XCTAssertEqual(pool.depths[50],0,accuracy:0.001)
    }
    XCTAssertEqual(pool.volume+pool.detached,mass,accuracy:0.05)
    for _ in 0..<120 {pool.step(dt:1/120,evaporates:false,clearing:false)}
    XCTAssertGreaterThan(pool.depths[50],1)
  }

  func testFreeLiquidHasPressureAndASolidCursorWithoutLosingMass() {
    var drops=(0..<3).map { i in
      WeatherParticle(rect:SIMD4(100+Float(i),100,4,4),motion:SIMD4(100,0,Float(i)*0.2,9),
        color:SIMD4(100,100,2,0.9),life:SIMD4(0,14,2,0))
    }
    drops.withUnsafeMutableBufferPointer { p in sh_couple_liquid(p.baseAddress,3,1/120,100,100,0,0) }
    XCTAssertEqual(drops.reduce(Float(0)) {$0+$1.life.z},6)
    XCTAssertTrue(drops.allSatisfy {simd_distance(SIMD2($0.rect.x,$0.rect.y),SIMD2(100,100))>=12.9})
    XCTAssertGreaterThan(simd_distance(SIMD2(drops[0].rect.x,drops[0].rect.y),SIMD2(drops[2].rect.x,drops[2].rect.y)),1)
  }

  func testRisingPuddleLiftsPreviouslySettledLeaves() {
    let sim=SnowSimulation(width:800,height:300,snowfall:.heavy)
    sim.autumn=true
    for _ in 0..<3600 {_=sim.step(dt:1/60,cursor:away)}
    let pool=WaterSurface(id:0,origin:.zero,width:800)
    for x in stride(from:Float(0),through:800,by:4) {pool.hit(x:x,amount:18,impulse:0)}
    for _ in 0..<60 {pool.step(dt:1/120,evaporates:false,clearing:false)}
    sim.waterSurfaces=[pool]
    _=sim.step(dt:1/120,cursor:away)
    XCTAssertGreaterThan(sim.surfaceDrift.count,0)
  }

  func testWaterCollisionTransfersSplashMomentumToFloatingMaterial() {
    let pool=WaterSurface(id:0,origin:.zero,width:400)
    for x in stride(from:Float(0),through:400,by:4) {pool.hit(x:x,amount:8,impulse:0)}
    for _ in 0..<60 {pool.step(dt:1/120,evaporates:false,clearing:false)}
    let drift=SurfaceDrift(),line=pool.depth(at:200)
    XCTAssertTrue(drift.catchMaterial(x:200,from:line+2,to:line-1,velocity:.zero,
      size:12,seed:0.4,area:1,turn:0,water:[pool]))
    _=pool.collide(cursor:SIMD2(194,line-3),previous:SIMD2(184,line-3),
      velocity:SIMD2(1200,300),dt:1/120)
    let released=drift.step(dt:1/120,water:[pool],wind:0,cursor:nil,cursorVelocity:.zero,retiring:false,clearing:false)
    XCTAssertEqual(released.count,1)
    XCTAssertGreaterThan(released.first?.velocity.y ?? 0,45)
  }

  func testSubmergedColliderTransfersOverlyingWaterToFreeLiquid() {
    let pool=WaterSurface(id:0,origin:.zero,width:400)
    for x in stride(from:Float(0),through:400,by:4) {pool.hit(x:x,amount:20,impulse:0)}
    for _ in 0..<60 {pool.step(dt:1/120,evaporates:false,clearing:false)}
    let mass=pool.volume
    XCTAssertTrue(pool.collide(cursor:SIMD2(200,6),previous:SIMD2(200,6),velocity:.zero,dt:1/120))
    XCTAssertTrue(pool.releases.contains {$0.point.y>17 && $0.amount>0})
    XCTAssertEqual(pool.volume+pool.detached,mass,accuracy:0.05)
  }

  func testDiagonalWindowMotionPreservesBothMomentumComponents() {
    let pool=WaterSurface(id:41,origin:SIMD2(100,100),width:400)
    for x in stride(from:Float(100),through:500,by:4) {pool.hit(x:x,amount:2.5,impulse:0)}
    for i in 1...6 {
      pool.move(to:SIMD2(100+Float(i)*12,100+Float(i)*15),interval:1/60,now:Double(i)/60,physical:true)
      pool.step(dt:1/60,evaporates:false,clearing:false)
    }
    pool.settleMotion(now:0.16)
    XCTAssertGreaterThan(pool.detached,1)
    let mass=pool.detached
    let momentum=pool.releases.reduce(SIMD2<Float>.zero) {$0+$1.velocity*$1.amount}/mass
    XCTAssertGreaterThan(momentum.x,150)
    XCTAssertGreaterThan(momentum.y,500)
  }

  func testFoamIsCollisionDrivenAndFadesQuickly() {
    let pool=WaterSurface(id:0,origin:.zero,width:400)
    for x in stride(from:Float(0),through:400,by:4) {pool.hit(x:x,amount:8,impulse:0)}
    pool.step(dt:1/120,evaporates:false,clearing:false)
    _=pool.collide(cursor:SIMD2(194,4),previous:SIMD2(184,4),velocity:SIMD2(1200,300),dt:1/120)
    XCTAssertGreaterThan(pool.foam,0.1)
    XCTAssertEqual(pool.foamRadius,35)
    for _ in 0..<120 {pool.step(dt:1/120,evaporates:false,clearing:false)}
    XCTAssertLessThan(pool.foam,0.01)
  }

  func testAllSeasonalFloatingMaterialsShareLiquidSplashMomentum() {
    for (index,_) in WeatherEffect.seasonal.enumerated() {
      let pool=WaterSurface(id:0,origin:.zero,width:400)
      for x in stride(from:Float(0),through:400,by:4) {pool.hit(x:x,amount:8,impulse:0)}
      pool.step(dt:1/120,evaporates:false,clearing:false)
      let drift=SurfaceDrift(),line=pool.depth(at:200),seed=Float(index)*0.1+0.1
      XCTAssertTrue(drift.catchMaterial(x:200,from:line+2,to:line-1,velocity:.zero,
        size:12,seed:seed,area:1,turn:0,water:[pool]))
      _=pool.collide(cursor:SIMD2(194,line-3),previous:SIMD2(184,line-3),velocity:SIMD2(1200,300),dt:1/120)
      let lifted=drift.step(dt:1/120,water:[pool],wind:0,cursor:nil,cursorVelocity:.zero,retiring:false,clearing:false)
      XCTAssertEqual(lifted.first?.seed,seed)
      XCTAssertGreaterThan(lifted.first?.velocity.y ?? 0,45)
    }
  }

  func testDownwardPointerImpactCreatesDenseUpwardLiquidAndConservesVolume() {
    let sim=WeatherSimulation(size:SIMD2(600,400),seed:42)
    sim.intensity = .off;sim.evaporates=false
    let pool=sim.water[0]
    for x in stride(from:Float(0),through:600,by:4) {pool.hit(x:x,amount:10,impulse:0)}
    for _ in 0..<60 {sim.step(dt:1/120,cursor:away)}
    let mass=pool.volume
    sim.step(dt:1/120,cursor:SIMD2(300,45))
    sim.step(dt:1/120,cursor:SIMD2(300,6))
    let liquid=sim.particles.filter {$0.motion.w==9}
    XCTAssertGreaterThan(liquid.count,30)
    XCTAssertGreaterThan(liquid.map {$0.motion.y}.max() ?? 0,120)
    XCTAssertTrue(liquid.allSatisfy {$0.rect.z<=1.8})
    let pending=pool.detached+pool.outflow.left+pool.outflow.right
    XCTAssertEqual(pool.volume+pending+liquid.reduce(Float(0)) {$0+$1.life.z},mass,accuracy:0.1)
  }

  func testLargeWindowReleaseIsVisibleImmediatelyWithoutADeferredQueue() {
    let sim=WeatherSimulation(size:SIMD2(1600,1000),seed:42)
    sim.intensity = .off;sim.evaporates=false
    func window(_ y:CGFloat)->WindowSurface {
      WindowSurface(id:41,frame:CGRect(x:100,y:y,width:1200,height:200),blockers:[],cornerRadius:18,cornerExponent:2.5,isDock:false)
    }
    sim.updateWindows([window(100)])
    for _ in 0..<120 {sim.step(dt:1/120,cursor:away)}
    let pool=sim.water[1]
    for x in stride(from:pool.origin.x,through:pool.origin.x+pool.width,by:4) {pool.hit(x:x,amount:4,impulse:0)}
    for i in 1...6 {sim.updateWindows([window(100+CGFloat(i)*12)],interval:1/120);sim.step(dt:1/120,cursor:away)}
    for _ in 0..<8 {sim.step(dt:1/120,cursor:away)}
    XCTAssertTrue(pool.releases.isEmpty,"The latest motion must not wait behind a seconds-long particle queue")
    XCTAssertGreaterThan(sim.particles.filter {$0.motion.w==9}.count,2000)
  }

  func testSlowPointerHoverCannotCreateFoam() {
    let pool=WaterSurface(id:0,origin:.zero,width:400)
    for x in stride(from:Float(0),through:400,by:4) {pool.hit(x:x,amount:8,impulse:0)}
    pool.step(dt:1/120,evaporates:false,clearing:false)
    for i in 0..<120 {
      let x=180+Float(i)*0.5
      _=pool.collide(cursor:SIMD2(x,12),previous:SIMD2(x-0.5,12),velocity:SIMD2(60,0),dt:1/120)
      pool.step(dt:1/120,evaporates:false,clearing:false)
    }
    XCTAssertEqual(pool.foam,0)
  }

}
