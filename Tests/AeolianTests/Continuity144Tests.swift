import AppKit
import MetalKit
import XCTest
@testable import Aeolian

final class Continuity144Tests: XCTestCase {
  private let away = SIMD2<Float>(-1000, -1000)
  private func reading(direction: Double = 270, cover: Double = 50, code: Int = 3) -> WeatherSnapshot {
    var result = WeatherSnapshot(time: 1_793_707_200, weatherCode: code, temperature: 12,
      windSpeed: 14, windDirection: direction, precipitation: code == 61 ? 0.5 : 0, isDay: 1)
    result.cloudCover = cover; result.visibility = 20_000
    result.windGust = 25; result.precipitationUnit = "mm/h"
    return result
  }

  func testSameObservationDoesNotRerollDriftOrWildlifeAsWallClockAdvances() {
    let snapshot = reading()
    let observed = Date(timeIntervalSince1970: snapshot.time)
    let original = WeatherScene(weather: snapshot, date: observed)
    for seconds in stride(from: 0, to: 900, by: 12) {
      XCTAssertEqual(WeatherScene(weather: snapshot, date: observed.addingTimeInterval(Double(seconds))), original)
    }
    // Fresh provider timestamps preserve the same accent when conditions are unchanged.
    var materials = Set<WeatherEffect>(), quiet = 0
    for period in 0..<48 {
      var next = snapshot
      next = WeatherSnapshot(time: snapshot.time + Double(period * 900), weatherCode: 3,
        temperature: 12, windSpeed: 14, windDirection: 270, precipitation: 0, isDay: 1)
      let scene = WeatherScene(weather: next)
      if let material = scene.stacked { materials.insert(material) } else { quiet += 1 }
    }
    XCTAssertEqual(materials, [.mapleSeeds])
    XCTAssertEqual(quiet, 0, "Identical conditions keep the same scenario across new observations")
  }

  func testPrevailingWindKeepsItsDirectionThroughEveryGust() {
    for (degrees, sign): (Double, Float) in [(0,-1), (30,-1), (90,1), (180,1), (270,-1), (330,-1), (360,-1)] {
      let snapshot = reading(direction: degrees)
      let climate = WeatherDynamics(weather: snapshot)
      XCTAssertEqual(snapshot.horizontalWind, sign * 14 * 2.4, accuracy: 0.001)
      for second in stride(from: 0.0, through: 1800, by: 0.5) {
        XCTAssertGreaterThan(climate.wind(at: second) * sign, 0)
      }
      var sky = CloudSky(), phase: Float = 0
      for frame in 0..<1200 {
        sky.step(size: SIMD2(960,600), cover: 0.5, rainLoad: 0,
          wind: climate.wind(at: Double(frame)/120), dt: 1/120, active: true, clearing: false)
        XCTAssertGreaterThan((sky.maskPhase-phase)*sign, 0)
        phase = sky.maskPhase
      }
    }
  }

  @MainActor func testRefreshMorphsAnExistingSkyInsteadOfRestartingIt() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm,
      simulation: SnowSimulation(width: 960, height: 600, snowfall: .steady))
    let original = WeatherScene(weather: reading())
    renderer.setScene(original, calm: false)
    for frame in 0..<1200 { renderer.step(dt: 1/120, cursor: away, now: Double(frame)/120) }
    let owner = renderer.current
    let phase = renderer.weather.sky.maskPhase, age = renderer.weather.elapsed
    let formation = renderer.weather.sky.formation
    for _ in 0..<10 { renderer.setScene(original, calm: false) }
    XCTAssertTrue(renderer.current === owner)
    XCTAssertEqual(renderer.weather.elapsed, age)
    XCTAssertEqual(renderer.weather.sky.maskPhase, phase)
    XCTAssertEqual(renderer.weather.sky.formation, formation)
    renderer.setScene(WeatherScene(weather: reading(cover: 60)), calm: false)
    XCTAssertTrue(renderer.current === owner)
    renderer.step(dt: 1/120, cursor: away, now: 10)
    XCTAssertGreaterThan(renderer.weather.sky.cover, 0.5)
    XCTAssertLessThan(renderer.weather.sky.cover, 0.501)
    XCTAssertGreaterThan(renderer.weather.sky.formation, 0.99)
    for frame in 0..<1800 { renderer.step(dt: 1/120, cursor: away, now: 10+Double(frame)/120) }
    XCTAssertEqual(renderer.weather.sky.cover, 0.6, accuracy: 0.002)
  }

  @MainActor func testPrecipitationChangeInheritsTheAlreadyFormedSky() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm,
      simulation: SnowSimulation(width: 960, height: 600, snowfall: .steady))
    renderer.setScene(WeatherScene(weather: reading()), calm: false)
    for frame in 0..<1200 { renderer.step(dt: 1/120, cursor: away, now: Double(frame)/120) }
    let previous = renderer.weather
    let sky = previous.sky
    let rain = reading(cover: 60, code: 61)
    renderer.setScene(WeatherScene(weather: rain), calm: false)
    XCTAssertFalse(renderer.weather === previous)
    XCTAssertEqual(renderer.weather.sky.formation, sky.formation)
    XCTAssertEqual(renderer.weather.sky.maskPhase, sky.maskPhase)
    XCTAssertEqual(renderer.weather.sky.cover, sky.cover)
    XCTAssertEqual(previous.sky.formation, 0)
    XCTAssertFalse(previous.scene.includesSky)
    XCTAssertFalse(previous.decorations.contains { $0.motion.w == 12 })
    renderer.step(dt: 1/120, cursor: away, now: 10)
    XCTAssertGreaterThan(renderer.weather.sky.formation, 0.99)
    XCTAssertLessThan(renderer.weather.sky.cover, 0.501)
    XCTAssertNotNil(renderer.weather.sky.rainSource(0.5))
  }

  @MainActor func testContextMenuTrackingDoesNotStopTheNativeFrameClock() throws {
    guard ProcessInfo.processInfo.environment["ATMOS_TEST_NATIVE_LIFECYCLE"] == "1" else {
      throw XCTSkip("Enable native lifecycle checks for menu-tracking rendering")
    }
    _ = NSApplication.shared
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let view = MTKView(frame: CGRect(x:0,y:0,width:240,height:160), device:device)
    Renderer.fitDrawable(of:view)
    let renderer = try Renderer(device:device,pixelFormat:.bgra8Unorm,
      simulation:SnowSimulation(width:240,height:160,snowfall:.steady))
    renderer.setScene(WeatherScene(primary:.clouds),calm:false)
    let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=view;window.orderFrontRegardless()
    let clock = try XCTUnwrap(NativeFrameClock(view:view,renderer:renderer))
    defer {clock.invalidate();window.close()}
    func run(_ mode:RunLoop.Mode) {
      let end=Date().addingTimeInterval(0.3)
      while Date()<end {RunLoop.main.run(mode:mode,before:end)}
    }
    run(.default)
    let before=clock.presentedFrames
    run(.eventTracking)
    XCTAssertGreaterThan(clock.presentedFrames,before)
    let tracked=clock.presentedFrames
    run(.default)
    XCTAssertGreaterThan(clock.presentedFrames,tracked)
    XCTAssertGreaterThan(renderer.weather.sky.formation,0)
  }
}
