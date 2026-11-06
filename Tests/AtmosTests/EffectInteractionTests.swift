import MetalKit
import XCTest
import simd

@testable import Atmos

final class EffectInteractionTests: XCTestCase {
  private let away = SIMD2<Float>(-1000, -1000)
  private func pool(id: UInt32 = 41, origin: SIMD2<Float> = SIMD2(100, 200)) -> WaterSurface {
    let pool = WaterSurface(id: id, origin: origin, width: 500)
    for x in stride(from: origin.x, through: origin.x + 500, by: 4) {
      pool.hit(x: x, amount: 2.5, impulse: 0)
    }
    for _ in 0..<60 { pool.step(dt: 1 / 120, evaporates: false, clearing: false) }
    return pool
  }

  func testLeavesFloatAtTheActualWaterlineAndFollowCurrentsAndMovingSupports() {
    let water = pool()
    let drift = SurfaceDrift()
    let volume = water.volume
    XCTAssertTrue(
      drift.catchMaterial(
        x: 300, from: 240, to: 200, velocity: SIMD2(40, -50),
        size: 14, seed: 0.24, area: 1, turn: 17, water: [water]))
    let initial = drift.positions[0]
    for _ in 0..<120 {
      water.step(dt: 1 / 120, evaporates: false, clearing: false)
      XCTAssertTrue(
        drift.step(
          dt: 1 / 120, water: [water], wind: 70, cursor: nil,
          cursorVelocity: .zero, retiring: false, clearing: false
        ).isEmpty)
    }
    XCTAssertEqual(drift.count, 1)
    XCTAssertGreaterThan(drift.positions[0].x, initial.x)
    XCTAssertEqual(
      drift.positions[0].y, water.origin.y + water.depth(at: drift.positions[0].x) + 14 * 0.055,
      accuracy: 0.02)
    let beforeMove = drift.positions[0]
    water.move(to: water.origin + SIMD2(120, 40), interval: 1 / 60, now: 1, physical: false)
    _ = drift.step(
      dt: 1 / 120, water: [water], wind: 0, cursor: nil, cursorVelocity: .zero, retiring: false,
      clearing: false)
    XCTAssertEqual(drift.positions[0].x - beforeMove.x, 120, accuracy: 0.1)
    XCTAssertEqual(drift.positions[0].y - beforeMove.y, 40, accuracy: 0.1)
    XCTAssertEqual(water.volume, volume, accuracy: 0.01)
  }

  func testDryingOrMissingWaterReleasesMaterialAndCursorCanLiftIt() {
    for reason in ["dry", "closed", "cursor"] {
      let water = pool()
      let drift = SurfaceDrift()
      XCTAssertTrue(
        drift.catchMaterial(
          x: 300, from: 240, to: 200, velocity: SIMD2(0, -40),
          size: 12, seed: 0.4, area: 2, turn: 0, water: [water]))
      if reason == "dry" {
        _ = water.extract(x: 350, radius: 1000, fraction: 1)
        water.step(dt: 1 / 120, evaporates: false, clearing: false)
      }
      let position = drift.positions[0]
      let released = drift.step(
        dt: 1 / 120, water: reason == "closed" ? [] : [water], wind: 0,
        cursor: reason == "cursor" ? position : nil, cursorVelocity: SIMD2(200, 120),
        retiring: false, clearing: false)
      XCTAssertEqual(drift.count, 0, reason)
      XCTAssertEqual(released.count, 1, reason)
      XCTAssertEqual(released[0].area, 2)
      if reason == "cursor" { XCTAssertGreaterThan(released[0].velocity.y, 50) }
    }
  }

  func testOccludedPuddlesAndUpwardCrossingsDoNotCatchLeaves() {
    let water = pool()
    water.blockers = [SIMD4(200, 190, 400, 300)]
    let drift = SurfaceDrift()
    XCTAssertFalse(
      drift.catchMaterial(
        x: 300, from: 240, to: 200, velocity: SIMD2(0, -40),
        size: 12, seed: 0.4, area: 1, turn: 0, water: [water]))
    water.blockers = []
    XCTAssertFalse(
      drift.catchMaterial(
        x: 300, from: 200, to: 240, velocity: SIMD2(0, 40),
        size: 12, seed: 0.4, area: 1, turn: 0, water: [water]))
  }

  func testRainAndLeavesSharePuddlesThroughRetirementAndStopCaptureWhenDry() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let renderer = try Renderer(
      device: device, pixelFormat: .rgba8Unorm,
      simulation: SnowSimulation(width: 800, height: 300, snowfall: .steady))
    renderer.setScene(WeatherScene(primary: .rain, stacked: .leaves), calm: false)
    renderer.setIntensity(.steady)
    renderer.weather.evaporates = false
    for x in stride(from: Float(0), through: 800, by: 4) {
      renderer.weather.water[0].hit(x: x, amount: 14, impulse: 0)
    }
    for frame in 0..<3600 { renderer.step(dt: 1 / 120, cursor: away, now: Double(frame) / 120) }
    let leaves = try XCTUnwrap(renderer.overlays.first { $0.effect == .leaves })
    XCTAssertGreaterThan(leaves.snow.simulation.surfaceDrift.count, 0)
    XCTAssertTrue(renderer.hasWater)
    renderer.setScene(WeatherScene(primary: .none, stacked: .leaves), calm: false)
    for frame in 3600..<5160 { renderer.step(dt: 1 / 120, cursor: away, now: Double(frame) / 120) }
    XCTAssertFalse(renderer.hasWater)
    XCTAssertEqual(leaves.snow.simulation.surfaceDrift.count, 0)
  }

  func testFlockHasDifferentBirdsAndButterfliesTurnWithTheirFlight() {
    let flock = BirdFlock(seed: 42)
    for _ in 0..<120 {
      flock.step(
        dt: 1 / 120, size: SIMD2(1000, 700), surfaces: [], wind: 0,
        airflow: nil, cursor: away, active: true, reducedMotion: false)
    }
    XCTAssertTrue((2...5).contains(flock.particles.count))
    XCTAssertGreaterThanOrEqual(Set(flock.particles.map { Int(abs($0.life.z)) }).count, 2)
    let butterflies = WeatherSimulation(size: SIMD2(960, 600), seed: 27)
    butterflies.setEffect(.butterflies)
    for _ in 0..<1200 { butterflies.step(dt: 1 / 120, cursor: away) }
    let airborne = butterflies.particles.filter { $0.motion.w == 13 }
    XCTAssertFalse(airborne.isEmpty)
    XCTAssertTrue(airborne.contains { abs($0.life.w) > 0.25 })
    XCTAssertLessThanOrEqual(airborne.count, 12)
    XCTAssertTrue(airborne.allSatisfy { $0.life.w.isFinite && abs($0.life.w) <= .pi })
  }
}
