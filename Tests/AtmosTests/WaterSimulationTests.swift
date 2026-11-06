import XCTest
import simd

@testable import Atmos

final class WaterSimulationTests: XCTestCase {
  func testWaterConservesVolumeAndEvaporates() {
    let surface = WaterSurface(id: 0, origin: .zero, width: 800)
    for _ in 0..<40 { surface.hit(x: 400, amount: 1) }
    let volume = surface.volume
    for _ in 0..<600 { surface.step(dt: 1.0 / 60, evaporates: false, clearing: false) }
    XCTAssertEqual(surface.volume, volume, accuracy: 0.01)
    XCTAssertGreaterThan(surface.top, 0)
    for _ in 0..<180 { surface.step(dt: 1.0 / 60, evaporates: true, clearing: true) }
    XCTAssertLessThan(surface.volume, 0.01)
    XCTAssertTrue(surface.heights.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 26 })
  }

  func testSweepMovesWaterAndBlockersExcludeCoveredWindowEdges() {
    let surface = WaterSurface(
      id: 10, origin: SIMD2(100, 200), width: 400, blockers: [SIMD4(200, 190, 300, 400)])
    XCTAssertTrue(surface.accepts(x: 150))
    XCTAssertFalse(surface.accepts(x: 250))
    XCTAssertFalse(surface.accepts(x: 50))
    surface.hit(x: 150, amount: 3)
    let before = surface.depths
    let volume = surface.volume
    surface.sweep(x: 150, velocity: 600, dt: 1.0 / 60)
    XCTAssertNotEqual(surface.depths, before)
    XCTAssertEqual(surface.volume, volume, accuracy: 0.001)
  }

  func testRainCreatesWindowPuddlesAndStaysBounded() {
    let simulation = WeatherSimulation(size: SIMD2(1000, 800), seed: 42)
    let window = WindowSurface(
      id: 42, frame: CGRect(x: 100, y: 200, width: 700, height: 300), blockers: [],
      cornerRadius: 18, cornerExponent: 2.5, isDock: false)
    simulation.updateWindows([window])
    for _ in 0..<1800 { simulation.step(dt: 1.0 / 60, cursor: SIMD2(-100, -100)) }
    XCTAssertGreaterThan(simulation.water.first { $0.id == 42 }?.volume ?? 0, 10)
    XCTAssertGreaterThan(simulation.water.first { $0.id == 0 }?.volume ?? 0, 10)
    XCTAssertLessThan(simulation.particles.count, 3000)
    XCTAssertLessThanOrEqual(simulation.ripples.count, 80)
    simulation.updateWindows([])
    XCTAssertEqual(simulation.water.count, 1)
    simulation.intensity = .off
    simulation.clear()
    for _ in 0..<1200 { simulation.step(dt: 1.0 / 60, cursor: .zero) }
    XCTAssertTrue(simulation.isEmpty)
  }

  func testEveryEffectSurvivesLongFramesResizesAndModeChanges() {
    let simulation = WeatherSimulation(size: SIMD2(800, 600), seed: 8)
    for effect in WeatherEffect.allCases where !effect.usesSnowSimulation && effect != .none {
      simulation.setEffect(effect)
      for i in 0..<400 {
        simulation.step(dt: i % 7 == 0 ? 0.2 : 1.0 / 60, cursor: SIMD2(Float(i % 800), 10))
      }
      XCTAssertTrue(simulation.hasContent, effect.title)
      XCTAssertTrue(
        simulation.particles.allSatisfy { p in
          [p.rect.x, p.rect.y, p.rect.z, p.rect.w, p.motion.x, p.motion.y].allSatisfy(\.isFinite)
        }, effect.title)
      simulation.resize(SIMD2(640, 480))
    }
    simulation.setEffect(.fireflies)
    XCTAssertTrue(simulation.water.allSatisfy { $0.volume == 0 })
    simulation.intensity = .off
    for _ in 0..<2000 { simulation.step(dt: 1.0 / 60, cursor: .zero) }
    XCTAssertTrue(simulation.isEmpty)
  }

  func testOffAndNoAccumulationAreRespected() {
    let simulation = WeatherSimulation(size: SIMD2(800, 600), seed: 7)
    simulation.intensity = .off
    for _ in 0..<60 { simulation.step(dt: 1.0 / 60, cursor: .zero) }
    XCTAssertTrue(simulation.isEmpty)
    simulation.intensity = .heavy
    simulation.accumulates = false
    for _ in 0..<900 { simulation.step(dt: 1.0 / 60, cursor: .zero) }
    XCTAssertTrue(simulation.water.allSatisfy { $0.volume == 0 })
    XCTAssertFalse(simulation.particles.isEmpty)
  }

  func testWindowSettingSurvivesModeChangesWithoutRectangularDockCutouts() {
    let simulation = WeatherSimulation(size: SIMD2(800, 600), seed: 23)
    let window = WindowSurface(
      id: 11, frame: CGRect(x: 100, y: 200, width: 400, height: 200),
      blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
    let dock = WindowSurface(
      id: 12, frame: CGRect(x: 200, y: 8, width: 400, height: 60),
      blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: true)
    simulation.updateWindows([window, dock], onWindows: false)
    XCTAssertEqual(simulation.water.count, 1)
    XCTAssertTrue(simulation.water[0].blockers.isEmpty)
    simulation.setEffect(.storm)
    XCTAssertEqual(simulation.water.count, 1)
    XCTAssertTrue(simulation.water[0].blockers.isEmpty)
    simulation.updateWindows([window, dock])
    simulation.setEffect(.drizzle)
    XCTAssertEqual(simulation.water.count, 3)
    XCTAssertTrue(simulation.water.contains { $0.isDock && $0.belowDock })
    XCTAssertTrue(simulation.water[0].blockers.isEmpty)
  }
  func testCursorSweepsPuddlesAtTheBottomEdgeAndFromAbove() {
    let simulation = WeatherSimulation(size: SIMD2(800, 600), seed: 77)
    simulation.intensity = .off
    let ground = simulation.water[0]
    for x in stride(from: Float(0), through: 800, by: 4) { ground.hit(x: x, amount: 8) }
    ground.step(dt: 1.0 / 30, evaporates: false, clearing: false)
    simulation.step(dt: 1.0 / 30, cursor: SIMD2(250, 0))
    let before = ground.depths
    simulation.step(dt: 1.0 / 30, cursor: SIMD2(300, 0))
    XCTAssertNotEqual(ground.depths, before)
    XCTAssertTrue(simulation.interactive)
    XCTAssertTrue(simulation.ripples.contains { abs($0.point.x - 304) < 1 && $0.strength >= 1 })
    simulation.step(dt: 1.0 / 30, cursor: SIMD2(300, 55))
    simulation.step(dt: 1.0 / 30, cursor: SIMD2(300, 8))
    XCTAssertTrue(simulation.interactive, "Vertical strokes should disturb the water too")
    XCTAssertTrue(
      simulation.particles.contains { $0.motion.w == 9 }, "A fast collision releases actual liquid")
  }

  func testMistBuildsOnWindowsAndClearsWithoutDriftingAway() {
    let simulation = WeatherSimulation(size: SIMD2(800, 600), seed: 24)
    simulation.setEffect(.mist)
    let window = WindowSurface(
      id: 14, frame: CGRect(x: 80, y: 100, width: 500, height: 250),
      blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
    simulation.updateWindows([window])
    for _ in 0..<360 { simulation.step(dt: 1.0 / 30, cursor: SIMD2(-100, -100)) }
    XCTAssertGreaterThan(simulation.banks.first { $0.id == 14 }?.amount ?? 0, 0.5)
    XCTAssertTrue(simulation.decorations.contains { $0.motion.w == 7 && $0.rect.y > 350 })
    XCTAssertTrue(
      simulation.particles.filter { $0.motion.w == 2 }.allSatisfy {
        $0.rect.x > -200 && $0.rect.x < 1000
      })
    simulation.clear()
    simulation.intensity = .off
    for _ in 0..<900 { simulation.step(dt: 1.0 / 30, cursor: .zero) }
    XCTAssertTrue(simulation.isEmpty)
  }

  func testFirefliesHaveMultipleSwarmsCurvedTrailsAndBoundedStorage() {
    let simulation = WeatherSimulation(size: SIMD2(1920, 1080), seed: 64)
    simulation.setEffect(.fireflies)
    simulation.intensity = .heavy
    for _ in 0..<1800 { simulation.step(dt: 1.0 / 30, cursor: SIMD2(-100, -100)) }
    let flies = simulation.particles.filter { $0.motion.w == 4 }
    XCTAssertGreaterThan(Set(flies.map { $0.life.z }).count, 2)
    XCTAssertLessThanOrEqual(flies.count, 96)
    XCTAssertGreaterThan(simulation.particles.filter { $0.motion.w == 6 }.count, flies.count * 3)
    XCTAssertLessThan(simulation.particleCount, 4096)
    XCTAssertTrue(
      flies.allSatisfy {
        $0.rect.x >= -25 && $0.rect.x <= 1945 && $0.rect.y >= -25 && $0.rect.y <= 1105
      })
  }

}
