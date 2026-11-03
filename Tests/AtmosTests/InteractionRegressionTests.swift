import XCTest
import simd

@testable import Atmos

final class InteractionRegressionTests: XCTestCase {
  func testCloudWispDepthIsMostlyBehindWindowsAndPersistsThroughMovement() {
    var background = 0
    var total = 0
    for seed in UInt64(1)...120 {
      let sim = WeatherSimulation(size: SIMD2(1512, 982), seed: seed)
      sim.setEffect(.clouds)
      sim.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
      let choices = Dictionary(
        uniqueKeysWithValues: sim.particles.filter { $0.motion.w == 2 }.map {
          ($0.motion.z, $0.life.z)
        })
      background += choices.values.filter { $0 == 1 }.count
      total += choices.count
      for _ in 0..<10 { sim.step(dt: 1 / 120, cursor: SIMD2(500, 300)) }
      for p in sim.particles where p.motion.w == 2 {
        if let original = choices[p.motion.z] {
          XCTAssertEqual(p.life.z, original, "Dragging never reshuffles cloud depth")
        }
      }
    }
    let fraction = Float(background) / Float(total)
    XCTAssertGreaterThan(fraction, 0.75)
    XCTAssertLessThan(fraction, 0.9)
    let mist = WeatherSimulation(size: SIMD2(1512, 982), seed: 7)
    mist.setEffect(.mist)
    mist.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
    XCTAssertTrue(
      mist.particles.filter { $0.motion.w == 2 }.allSatisfy { $0.life.z == 0 },
      "Mist keeps its existing interaction and depth")
  }

  private func window(
    _ id: UInt32 = 40, x: CGFloat = 100, y: CGFloat = 100, width: CGFloat = 500,
    height: CGFloat = 300, dock: Bool = false
  ) -> WindowSurface {
    WindowSurface(
      id: id, frame: CGRect(x: x, y: y, width: width, height: height), blockers: [],
      cornerRadius: 18, cornerExponent: 2.5, isDock: dock)
  }

  func testMinimizeAndAnimatedRestoreNeverLaunchLeaves() {
    let sim = SnowSimulation(width: 1000, height: 800, snowfall: .heavy)
    sim.autumn = true
    sim.thaws = false
    sim.updateWindows([window()], interval: 0.1)
    let pointer = SIMD2<Float>(-1000, -1000)
    for _ in 0..<2400 { _ = sim.step(dt: 1 / 60, cursor: pointer) }
    let sprites = UnsafeMutablePointer<Sprite>.allocate(capacity: 20000)
    defer { sprites.deallocate() }
    XCTAssertGreaterThan(sim.writeSprites(into: sprites, capacity: 20000), 0)
    for _ in 0..<4 {
      sim.updateWindows([], interval: 0.1, parked: [40])
      for _ in 0..<30 { _ = sim.step(dt: 1 / 60, cursor: pointer) }
      for frame in 0..<35 {
        let t = CGFloat(frame + 1) / 35
        sim.updateWindows(
          [window(x: 380 - t * 280, y: 20 + t * 80, width: 80 + t * 420, height: 20 + t * 280)],
          interval: 1 / 60)
        _ = sim.step(dt: 1 / 60, cursor: pointer)
        let count = sim.writeSprites(into: sprites, capacity: 20000)
        for i in 0..<count {
          XCTAssertTrue(sprites[i].position.x.isFinite && sprites[i].position.y.isFinite)
          XCTAssertLessThan(
            simd_length(sprites[i].velocity), 950,
            "Restoration is a presentation transform, not a launch impulse")
        }
      }
      for _ in 0..<90 { _ = sim.step(dt: 1 / 60, cursor: pointer) }
    }
  }

  func testDiagonalPointerStrokeDoesNotTouchUnrelatedPuddleAtBottomRight() {
    let sim = WeatherSimulation(size: SIMD2(1400, 900), seed: 1)
    sim.intensity = .off
    sim.evaporates = false
    let ground = sim.water[0]
    for x in stride(from: Float(0), through: 1400, by: 4) { ground.hit(x: x, amount: 12) }
    ground.step(dt: 1 / 30, evaporates: false, clearing: false)
    sim.step(dt: 1 / 30, cursor: SIMD2(850, 300))
    sim.step(dt: 1 / 30, cursor: SIMD2(1350, 200))
    XCTAssertFalse(sim.interactive)
    XCTAssertTrue(sim.ripples.isEmpty)
    XCTAssertFalse(sim.particles.contains { $0.motion.w == 9 })
    sim.step(dt: 1 / 30, cursor: SIMD2(1350, 8))
    XCTAssertTrue(sim.interactive)
    XCTAssertTrue(sim.ripples.allSatisfy { $0.point.x > 1300 })
  }

  func testFastSweepThrowsRealWaterAndItLandsOnTheGround() {
    let sim = WeatherSimulation(size: SIMD2(1000, 800), seed: 7)
    sim.intensity = .off
    sim.evaporates = false
    sim.updateWindows([window()])
    let pool = sim.water[1]
    for x in stride(from: pool.origin.x, through: pool.origin.x + pool.width, by: 4) {
      pool.hit(x: x, amount: 3)
    }
    pool.step(dt: 1 / 30, evaporates: false, clearing: false)
    let original = pool.volume
    sim.step(dt: 1 / 30, cursor: SIMD2(430, 410))
    sim.step(dt: 1 / 30, cursor: SIMD2(650, 410))
    let thrown = sim.particles.filter { $0.motion.w == 9 }
    XCTAssertFalse(thrown.isEmpty)
    XCTAssertGreaterThan(thrown.map { $0.motion.y }.max() ?? 0, 200)
    XCTAssertLessThan(pool.volume, original)
    XCTAssertEqual(pool.volume + thrown.reduce(0) { $0 + $1.life.z }, original, accuracy: 0.1)
    for _ in 0..<180 { sim.step(dt: 1 / 30, cursor: SIMD2(-1000, -1000)) }
    XCTAssertGreaterThan(
      sim.water[0].volume, 1, "Water thrown beyond the edge must reach and splash on the floor")
    XCTAssertTrue(sim.particles.filter { $0.motion.w == 9 }.allSatisfy { $0.life.x < 14 })
  }

  func testSmokeCarriesMomentumAndDensityAfterCursorLeaves() throws {
    let smoke = SmokeSimulation(size: SIMD2(600, 400))
    let sources = [SIMD4<Float>(300, 160, 250, 70)]
    for i in 0..<150 {
      smoke.step(
        dt: 1 / 30, time: Float(i) / 30, wind: 0, cursor: SIMD4(-1000, -1000, 0, 0),
        previous: SIMD2(-1000, -1000), sources: sources)
    }
    let before = smoke.cells
    smoke.step(
      dt: 1 / 30, time: 5, wind: 0, cursor: SIMD4(380, 160, 1200, 0), previous: SIMD2(200, 160),
      sources: sources)
    let disturbed = smoke.cells
    XCTAssertGreaterThan(disturbed.map { abs($0.x) + abs($0.y) }.max() ?? 0, 30)
    for i in 0..<15 {
      smoke.step(
        dt: 1 / 30, time: 5 + Float(i) / 30, wind: 0, cursor: SIMD4(-1000, -1000, 0, 0),
        previous: SIMD2(-1000, -1000), sources: sources)
    }
    XCTAssertTrue(
      zip(before, smoke.cells).contains { abs($0.z - $1.z) > 0.03 },
      "Smoke density must be transported, not a temporary opacity hole")
    XCTAssertTrue(
      smoke.cells.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z >= 0 && $0.z <= 1 })
  }

  func testLightningTargetsSurfacesAndRespectsReduceMotion() throws {
    let sim = WeatherSimulation(size: SIMD2(1000, 800), seed: 42)
    sim.setEffect(.lightning)
    sim.updateWindows([window(), window(99, x: 250, y: 5, width: 450, height: 60, dock: true)])
    var targets = Set<Float>()
    for _ in 0..<3600 {
      sim.step(dt: 1 / 30, cursor: SIMD2(-1000, -1000))
      if let target = sim.lastStrikeTarget { targets.insert(target.y) }
      XCTAssertLessThan(sim.decorations.filter { $0.motion.w == 11 }.count, 100)
    }
    XCTAssertGreaterThan(targets.count, 1)
    XCTAssertTrue(targets.isSubset(of: [0, 65, 400]))
    XCTAssertTrue(sim.decorations.contains { $0.motion.w == 12 && $0.life.w == 1 })
    sim.setEffect(.rain)
    sim.setEffect(.lightning)
    sim.reducedMotion = true
    for _ in 0..<900 { sim.step(dt: 1 / 30, cursor: SIMD2(-1000, -1000)) }
    XCTAssertFalse(sim.decorations.contains { $0.motion.w == 11 })
    XCTAssertEqual(sim.flash, 0)
  }

  func testLightningSkipsFullyOccludedWindowEdges() {
    let sim = WeatherSimulation(size: SIMD2(1000, 800), seed: 13)
    sim.setEffect(.lightning)
    let covered = WindowSurface(
      id: 8, frame: CGRect(x: 100, y: 100, width: 500, height: 300),
      blockers: [CGRect(x: 90, y: 390, width: 520, height: 410)], cornerRadius: 18,
      cornerExponent: 2.5, isDock: false)
    sim.updateWindows([covered])
    for _ in 0..<1200 {
      sim.step(dt: 1 / 30, cursor: SIMD2(-1000, -1000))
      if let target = sim.lastStrikeTarget { XCTAssertEqual(target.y, 0) }
    }
    XCTAssertNotNil(sim.lastStrikeTarget)
  }

  func testLiveScenesMixDayNightAndPrecipitationWithoutWeatherContradictions() {
    var reading = WeatherSnapshot(
      time: Date().timeIntervalSince1970, weatherCode: 2, temperature: 12, windSpeed: 8,
      windDirection: 180, precipitation: 0, isDay: 0)
    reading.cloudCover = 35
    var scene = WeatherScene(weather: reading)
    XCTAssertEqual(scene.primary, .fireflies)
    XCTAssertGreaterThan(scene.clouds, 0)
    reading = WeatherSnapshot(
      time: Date().timeIntervalSince1970, weatherCode: 2, temperature: 12, windSpeed: 8,
      windDirection: 180, precipitation: 0, isDay: 1)
    reading.cloudCover = 35
    scene = WeatherScene(weather: reading)
    XCTAssertEqual(scene.primary, .sunlight)
    XCTAssertGreaterThan(scene.clouds, 0)
    reading = WeatherSnapshot(
      time: Date().timeIntervalSince1970, weatherCode: 61, temperature: 12, windSpeed: 8,
      windDirection: 180, precipitation: 0.2, isDay: 1)
    reading.cloudCover = 35
    scene = WeatherScene(weather: reading)
    XCTAssertEqual(scene.primary, .rain)
    XCTAssertGreaterThan(scene.sunlight, 0)
    XCTAssertGreaterThan(scene.clouds, 0)
    reading = WeatherSnapshot(
      time: Date().timeIntervalSince1970, weatherCode: 95, temperature: 12, windSpeed: 8,
      windDirection: 180, precipitation: 2, isDay: 1)
    scene = WeatherScene(weather: reading)
    XCTAssertEqual(scene.primary, .lightning)
    XCTAssertEqual(scene.sunlight, 0)
    XCTAssertEqual(scene.fireflies, 0)
    let sim = WeatherSimulation(size: SIMD2(1000, 800), seed: 9)
    sim.setEffect(.snow)
    sim.scene = WeatherScene(weather: reading)
    sim.scene.primary = .snow
    sim.scene.clouds = 0.4
    for _ in 0..<120 { sim.step(dt: 1 / 30, cursor: SIMD2(-1000, -1000)) }
    XCTAssertFalse(
      sim.particles.contains { $0.motion.w == 0 }, "A snow scene must not accidentally prefill rain"
    )
    XCTAssertTrue(sim.decorations.contains { $0.motion.w == 12 })
  }
}
