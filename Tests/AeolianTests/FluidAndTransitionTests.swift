import MetalKit
import XCTest
import simd

@testable import Aeolian

final class FluidAndTransitionTests: XCTestCase {
  func testRainToSunKeepsCaptureDemandOnlyUntilTheLastPuddleDries() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let renderer = try Renderer(
      device: device, pixelFormat: .rgba8Unorm,
      simulation: SnowSimulation(width: 640, height: 400, snowfall: .off))
    renderer.setEffect(.rain, calm: false)
    renderer.setIntensity(.steady)
    for x in stride(from: Float(0), through: 640, by: 4) {
      renderer.weather.water[0].hit(x: x, amount: 12)
    }
    renderer.weather.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
    XCTAssertTrue(renderer.hasWater)
    renderer.setEffect(.sunlight, calm: false)
    renderer.setIntensity(.steady)
    for _ in 0..<120 {
      for scene in renderer.retiring + [renderer.current] {
        scene.weather.simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
      }
    }
    XCTAssertTrue(
      renderer.hasWater, "Remaining puddles still need their reflection while sunbeams arrive")
    for _ in 0..<1200 {
      for scene in renderer.retiring + [renderer.current] {
        scene.weather.simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
      }
    }
    XCTAssertFalse(
      renderer.hasWater, "Dry water must stop requesting desktop capture while sunlight continues")
  }

  private let away = SIMD2<Float>(-1000, -1000)
  private func window(
    x: CGFloat = 200, y: CGFloat = 80, width: CGFloat = 400, height: CGFloat = 220
  ) -> WindowSurface {
    .init(
      id: 41, frame: CGRect(x: x, y: y, width: width, height: height), blockers: [],
      cornerRadius: 18, cornerExponent: 2.5, isDock: false)
  }
  private func filledSimulation() -> WeatherSimulation {
    let sim = WeatherSimulation(size: SIMD2(1200, 900), seed: 71)
    sim.intensity = .off
    sim.evaporates = false
    sim.updateWindows([window()])
    let pool = sim.water[1]
    for x in stride(from: pool.origin.x, through: pool.origin.x + pool.width, by: 4) {
      pool.hit(x: x, amount: 2.5, impulse: 0)
    }
    for _ in 0..<60 { sim.step(dt: 1 / 60, cursor: away) }
    return sim
  }
  func testDockCollectsRainAndSpillsIntoGroundWhenItHides() {
    let sim = WeatherSimulation(size: SIMD2(1200, 900), seed: 8151)
    sim.setEffect(.rain)
    sim.intensity = .heavy
    let dock = WindowSurface(
      id: 16, frame: CGRect(x: 240, y: 8, width: 720, height: 66), blockers: [], cornerRadius: 26,
      cornerExponent: 2.5, isDock: true)
    sim.updateWindows([dock])
    for _ in 0..<900 { sim.step(dt: 1 / 60, cursor: away) }
    let pool = sim.water.first { $0.id == 16 }
    XCTAssertNotNil(pool)
    XCTAssertTrue(pool?.belowDock ?? false)
    XCTAssertGreaterThan(pool?.volume ?? 0, 1)
    XCTAssertGreaterThan(sim.groundTop, 74)
    sim.intensity = .off
    sim.updateWindows([])
    XCTAssertFalse(sim.water.contains { $0.id == 16 })
    XCTAssertTrue(
      sim.particles.contains { $0.motion.w == 9 && $0.rect.y > 74 },
      "The hiding Dock releases its actual water as droplets")
    let before = sim.water[0].volume
    for _ in 0..<180 { sim.step(dt: 1 / 60, cursor: away) }
    XCTAssertGreaterThan(sim.water[0].volume, before)
  }

  func testSurfaceTensionKeepsRestingWindowWaterFromDraining() {
    let sim = filledSimulation()
    let pool = sim.water[1]
    let original = pool.volume
    for _ in 0..<600 { sim.step(dt: 1 / 60, cursor: away) }
    XCTAssertGreaterThan(pool.volume, original * 0.97)
    XCTAssertLessThan(pool.outflow.left + pool.outflow.right, 0.05)
    XCTAssertFalse(sim.particles.contains { $0.motion.w == 9 })
  }
  func testFastHorizontalDragShedsWaterFromTheTrailingEdgeAndConservesMass() {
    let sim = filledSimulation()
    let original = sim.water[1].volume
    var sawTrailingDrop = false
    for i in 1...10 {
      sim.updateWindows([window(x: 200 + CGFloat(i) * 30)], interval: 1 / 60)
      sim.step(dt: 1 / 60, cursor: away)
      let left = sim.water[1].origin.x
      sawTrailingDrop =
        sawTrailingDrop || sim.particles.contains { $0.motion.w == 9 && $0.rect.x < left }
    }
    XCTAssertTrue(sawTrailingDrop)
    XCTAssertLessThan(sim.water[1].volume, original * 0.8)
    let flying = sim.particles.filter { $0.motion.w == 9 }.reduce(Float(0)) { $0 + $1.life.z }
    let pending = sim.water.reduce(Float(0)) {
      $0 + $1.outflow.left + $1.outflow.right + $1.detached
    }
    XCTAssertEqual(
      sim.water.reduce(0) { $0 + $1.volume } + flying + pending, original, accuracy: 0.2)
    for _ in 0..<240 { sim.step(dt: 1 / 60, cursor: away) }
    XCTAssertGreaterThan(sim.water[0].volume, 1)
  }
  func testFastUpwardDragCarriesWaterBeyondTheStoppedWindow() {
    let sim = filledSimulation()
    // A smaller window leaves room to see a complete upward throw and return.
    for i in 1...5 {
      sim.updateWindows([window(y: 80 + CGFloat(i) * 45)], interval: 1 / 60)
      sim.step(dt: 1 / 60, cursor: away)
    }
    let top = sim.water[1].origin.y
    var height: Float = 0
    var upward: Float = 0
    var sawImpactSpray = false
    for _ in 0..<210 {
      sim.step(dt: 1 / 60, cursor: away)
      for p in sim.particles where p.motion.w == 9 {
        height = max(height, p.rect.y - top)
        upward = max(upward, p.motion.y)
      }
      sawImpactSpray = sawImpactSpray || sim.ripples.contains { $0.strength > 0.5 }
    }
    XCTAssertGreaterThan(upward, 250)
    XCTAssertGreaterThan(height, 35)
    XCTAssertTrue(sawImpactSpray, "Detached liquid returns momentum to the water field")
    XCTAssertTrue(sim.water.allSatisfy { $0.heights.allSatisfy { $0.isFinite && $0 >= 0 } })
  }
  func testWeatherRetirementKeepsParticlesAndAgesThemThreeTimesFaster() {
    let sim = WeatherSimulation(size: SIMD2(1000, 800), seed: 34)
    sim.setEffect(.mist)
    for _ in 0..<120 { sim.step(dt: 1 / 30, cursor: away) }
    let before = Dictionary(uniqueKeysWithValues: sim.particles.map { ($0.motion.z, $0.life.x) })
    let count = sim.particleCount
    sim.retire()
    XCTAssertEqual(sim.particleCount, count, "Switching must not clear the outgoing particles")
    sim.step(dt: 1 / 30, cursor: away)
    XCTAssertEqual(sim.retirementRate, 3)
    for p in sim.particles {
      if let age = before[p.motion.z] { XCTAssertEqual(p.life.x - age, 0.1, accuracy: 0.0001) }
    }
    for _ in 0..<900 { sim.step(dt: 1 / 30, cursor: away) }
    XCTAssertTrue(sim.isEmpty)
  }

  func testRetiringDeepWaterDriesInSecondsAndKeepsItsPhysics() {
    let sim = filledSimulation()
    for pool in sim.water {
      for x in stride(from: pool.origin.x, through: pool.origin.x + pool.width, by: 4) {
        pool.hit(x: x, amount: 60, impulse: 0)
      }
    }
    sim.step(dt: 1 / 60, cursor: away)
    let ground = sim.water[0]
    let window = sim.water[1]
    let volume = ground.volume + window.volume
    sim.retire()
    sim.step(dt: 1 / 60, cursor: away)
    XCTAssertGreaterThan(
      ground.volume + window.volume, volume * 0.97,
      "Switching does not clear or fade the pools at once")
    sim.step(dt: 1 / 60, cursor: SIMD2(window.origin.x + 100, window.origin.y + 2))
    sim.step(dt: 1 / 60, cursor: SIMD2(window.origin.x + 112, window.origin.y + 2))
    XCTAssertTrue(sim.interactive, "Outgoing water must remain interactive as its depth decreases")
    for _ in 0..<180 { sim.step(dt: 1 / 60, cursor: away) }
    XCTAssertGreaterThan(ground.volume, 1)
    XCTAssertLessThan(ground.volume + window.volume, volume * 0.8)
    for _ in 0..<420 { sim.step(dt: 1 / 60, cursor: away) }
    XCTAssertTrue(sim.water.allSatisfy { $0.volume < 0.001 && $0.top == 0 })
    XCTAssertTrue(
      sim.isEmpty, "Retired water must release the outgoing scene and its capture demand")
  }

  func testReturningToRainStopsRetirementDryingWithoutResettingPuddles() {
    let sim = filledSimulation()
    let pool = sim.water[1]
    sim.retire()
    for _ in 0..<120 { sim.step(dt: 1 / 60, cursor: away) }
    let remaining = pool.volume
    XCTAssertGreaterThan(remaining, 1)
    sim.resume()
    sim.intensity = .off
    for _ in 0..<120 { sim.step(dt: 1 / 60, cursor: away) }
    XCTAssertEqual(pool.volume, remaining, accuracy: 0.01)
    XCTAssertTrue(sim.water[1] === pool)
  }
  func testSnowToRainOverlapsWithoutClearingDriftsOrWaitingToEmitRain() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let snow = SnowSimulation(width: 1000, height: 800, snowfall: .heavy)
    let renderer = try Renderer(device: device, pixelFormat: .rgba8Unorm, simulation: snow)
    renderer.updateWindows(
      .init(
        surfaces: [window()], interval: 0.1, parked: [], elsewhere: [], sliding: false,
        slideVelocity: 0), onWindows: true)
    for _ in 0..<2400 { _ = snow.step(dt: 1 / 60, cursor: away) }
    let count = snow.spriteCount
    let pile = snow.pileTop
    XCTAssertGreaterThan(count, 20)
    renderer.setEffect(.rain, calm: false)
    renderer.setIntensity(.steady)
    XCTAssertTrue(renderer.retiring.contains { $0.snow.simulation === snow })
    XCTAssertEqual(snow.spriteCount, count)
    XCTAssertEqual(snow.pileTop, pile)
    renderer.weather.step(dt: 1 / 30, cursor: away)
    XCTAssertGreaterThan(renderer.weather.particleCount, 0)
    for _ in 0..<60 { _ = snow.step(dt: 1 / 60, cursor: away) }
    XCTAssertGreaterThan(snow.spriteCount, 0)
    XCTAssertEqual(snow.retirementRate, 3)
    for _ in 0..<1800 { _ = snow.step(dt: 1 / 60, cursor: away) }
    XCTAssertLessThan(snow.pileTop, pile)
  }
  func testRapidSceneSwitchesReuseOutgoingScenesAndStayBounded() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let renderer = try Renderer(
      device: device, pixelFormat: .rgba8Unorm,
      simulation: SnowSimulation(width: 640, height: 480, snowfall: .steady))
    for _ in 0..<3 {
      for effect in WeatherEffect.allCases {
        renderer.setEffect(effect, calm: false)
        renderer.setIntensity(.steady)
        renderer.weather.step(dt: 1 / 30, cursor: away)
        _ = renderer.simulation.step(dt: 1 / 30, cursor: away)
        XCTAssertEqual(Set(renderer.retiring.map(\.effect)).count, renderer.retiring.count)
        XCTAssertLessThan(renderer.retiring.count, WeatherEffect.allCases.count)
        let liquidOwners = (renderer.retiring + [renderer.current]).filter {
          $0.effect.hasWater && $0.weather.simulation.ownsWater
        }
        XCTAssertLessThanOrEqual(liquidOwners.count, 1)
      }
    }
  }
  func testPrecipitationTransitionsKeepOneSharedPuddleInsteadOfStackingOrResettingIt() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let renderer = try Renderer(
      device: device, pixelFormat: .rgba8Unorm,
      simulation: SnowSimulation(width: 800, height: 600, snowfall: .off))
    renderer.setEffect(.rain, calm: false)
    renderer.setIntensity(.off)
    let rain = renderer.weather
    rain.evaporates = false
    for x in stride(from: Float(0), through: 800, by: 4) {
      rain.water[0].hit(x: x, amount: 10, impulse: 0)
    }
    rain.step(dt: 1 / 30, cursor: away)
    let pool = rain.water[0]
    let volume = pool.volume
    renderer.setEffect(.storm, calm: false)
    renderer.setIntensity(.off)
    XCTAssertTrue(renderer.weather.water[0] === pool)
    XCTAssertFalse(rain.ownsWater)
    XCTAssertTrue(renderer.weather.ownsWater)
    for _ in 0..<60 {
      rain.step(dt: 1 / 60, cursor: away)
      renderer.weather.step(dt: 1 / 60, cursor: away)
    }
    XCTAssertEqual(pool.volume, volume, accuracy: 0.01)
    let windowUpdate = WindowUpdate(
      surfaces: [window(width: 420)], interval: 1 / 60, parked: [], elsewhere: [], sliding: false,
      slideVelocity: 0)
    renderer.updateWindows(windowUpdate, onWindows: true)
    rain.step(dt: 1 / 60, cursor: away)
    XCTAssertEqual(rain.water.count, renderer.weather.water.count)
    XCTAssertTrue(
      rain.water.last === renderer.weather.water.last,
      "Outgoing emitters must follow replacement surfaces after a resize")
    renderer.setEffect(.drizzle, calm: false)
    renderer.setIntensity(.off)
    XCTAssertTrue(renderer.weather.water[0] === pool)
    XCTAssertEqual(pool.volume, volume, accuracy: 0.01)
  }

  func testPaddedCaptureCoordinatesPreserveHorizontalRegistration() {
    let rect = ReflectionGeometry.uvRect(
      contentPixels: CGRect(x: 96, y: 20, width: 1088, height: 680),
      textureSize: CGSize(width: 1280, height: 720))
    XCTAssertEqual(rect.x, 0.075, accuracy: 0.00001)
    XCTAssertEqual(rect.z, 0.85, accuracy: 0.00001)
    XCTAssertEqual(
      ReflectionGeometry.uvRect(
        contentPixels: CGRect(x: 96, y: 0, width: 1280, height: 720),
        textureSize: CGSize(width: 1280, height: 720)), SIMD4(0, 0, 1, 1),
      "Invalid out-of-surface metadata must not introduce an offset")
  }
}
