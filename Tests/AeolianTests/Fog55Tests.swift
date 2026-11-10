import XCTest
import simd
@testable import Aeolian

final class Fog55Tests: XCTestCase {
  private let away = SIMD2<Float>(-1000, -1000)
  func testMistKeepsNearlyAllVolumesBehindWindowsAndCapsForegroundAtOneFaintVolume() {
    let sim = WeatherSimulation(size: SIMD2(1200, 800), seed: 6)
    sim.setEffect(.mist); sim.intensity = .heavy
    for frame in 0..<1800 {
      sim.step(dt: 1/60, cursor: away)
      let volumes = sim.particles.filter { $0.motion.w == 2 }
      let foreground = volumes.filter { $0.life.z < 0.5 }
      XCTAssertLessThanOrEqual(foreground.count, 1)
      XCTAssertTrue(foreground.allSatisfy { $0.color.w <= 0.13 })
      if frame == 1799 {
        XCTAssertGreaterThan(volumes.count, 8)
        XCTAssertGreaterThan(Double(volumes.filter { $0.life.z > 0.5 }.count) / Double(volumes.count), 0.9)
        XCTAssertTrue(volumes.allSatisfy { $0.rect.z >= 340 && $0.rect.w > 100 })
      }
    }
    XCTAssertGreaterThan(sim.fogAmount, 0.95)
    XCTAssertEqual(sim.decorations.filter { $0.motion.w == 15 }.count, 1)
  }
  func testContinuousFogDissolvesAndReformsSmoothlyWhenCleared() {
    let sim = WeatherSimulation(size: SIMD2(960, 600), seed: 6)
    sim.setEffect(.mist)
    for _ in 0..<1200 { sim.step(dt: 1/120, cursor: away) }
    let full = sim.fogAmount
    sim.clear(); sim.step(dt: 1/120, cursor: away)
    XCTAssertLessThan(sim.fogAmount, full)
    XCTAssertGreaterThan(sim.fogAmount, full * 0.95)
    for _ in 0..<479 { sim.step(dt: 1/120, cursor: away) }
    XCTAssertLessThan(sim.fogAmount, 0.01)
    sim.step(dt: 1/120, cursor: away)
    XCTAssertLessThan(sim.fogAmount, 0.02)
    for _ in 0..<960 { sim.step(dt: 1/120, cursor: away) }
    XCTAssertGreaterThan(sim.fogAmount, full * 0.98)
  }
  func testFogWarningGetsDenseMistWithoutDuplicatingTheSkyOrSummary() {
    let now = Date()
    var weather = WeatherSnapshot(time: now.timeIntervalSince1970, weatherCode: 3,
      temperature: 10, windSpeed: 3, windDirection: 270, precipitation: 0, isDay: 0)
    weather.humidity = 60; weather.cloudCover = 58
    weather.alerts = [LocalWeatherAlert(id: "fog", summary: "Yellow warning for fog", source: "Met Office",
      detailsURL: URL(string: "https://weather-data.apple.com/alertDetails/fog")!, severity: .moderate,
      effective: now.addingTimeInterval(-3600), expires: now.addingTimeInterval(3600))]
    let scene = WeatherScene(weather: weather, date: now)
    XCTAssertEqual(scene.primary, .mist); XCTAssertEqual(scene.fog, LocalWeatherAlert.Severity.moderate.fogDensity)
    XCTAssertFalse(scene.summary.contains("Mist + Clouds 58% + Fog"))
    let sim = WeatherSimulation(size: SIMD2(960, 600), seed: 6)
    sim.setEffect(.mist); sim.scene = scene
    for _ in 0..<1200 { sim.step(dt: 1/120, cursor: away) }
    XCTAssertGreaterThan(sim.fogAmount, scene.fog - 0.01)
    XCTAssertEqual(sim.decorations.filter { $0.motion.w == 15 }.count, 1)
  }
}
