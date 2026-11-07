import AppKit
import Metal
import XCTest
@testable import Atmos

final class Visibility65Tests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_794_002_400)
  private func reading(_ metres: Double?) -> WeatherSnapshot {
    var w = WeatherSnapshot(time: now.timeIntervalSince1970, weatherCode: 2,
      temperature: 12, windSpeed: 8, windDirection: 270, precipitation: 0, isDay: 1)
    w.cloudCover = 52; w.visibility = metres
    return w
  }
  func testVisibilityMappingIsContinuousAndDoesNotConfuseMilesWithMetres() {
    let levels = [16_000.0, 8_046.72, 5_000, 1_000, 100, 0].map { reading($0).visibilityFogDensity }
    XCTAssertEqual(levels[0], 0)
    XCTAssertGreaterThan(levels[1], 0.05); XCTAssertLessThan(levels[1], 0.15)
    for (clearer, denser) in zip(levels, levels.dropFirst()) { XCTAssertGreaterThan(denser, clearer) }
    XCTAssertLessThanOrEqual(levels.last!, 0.9)
    for unknown in [nil, -1.0, .infinity, .nan] {
      XCTAssertEqual(reading(unknown).visibilityFogDensity, 0)
      XCTAssertNil(reading(unknown).visibilityDescription)
    }
    XCTAssertEqual(reading(8_046.72).visibilityDescription, "8.0 km")
    XCTAssertEqual(reading(500).visibilityDescription, "500 m")
  }
  func testBothJSONProvidersCarryVisibilityInMetresWithoutRequiringIt() throws {
    let current: [String: Any] = ["time": now.timeIntervalSince1970, "weather_code": 2,
      "temperature_2m": 12, "wind_speed_10m": 8, "wind_direction_10m": 270,
      "precipitation": 0, "is_day": 1, "visibility": 8_000]
    let response = HTTPURLResponse(url: WeatherAPI.url(latitude: 51, longitude: 0)!,
      statusCode: 200, httpVersion: nil, headerFields: nil)!
    let open = try WeatherAPI.decode(JSONSerialization.data(withJSONObject: ["current": current]), response: response, at: now)
    XCTAssertEqual(open.visibility, 8_000)
    let requested = URLComponents(url: response.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "current" }?.value
    XCTAssertTrue(requested?.split(separator: ",").contains("visibility") == true)
    let apple: [String: Any] = ["asOf": ISO8601DateFormatter().string(from: now),
      "conditionCode": "PartlyCloudy", "daylight": true, "cloudCover": 0.52,
      "humidity": 0.8, "temperature": 12, "temperatureApparent": 12, "windSpeed": 8,
      "visibility": 8_000, "metadata": ["attributionURL": "https://developer.apple.com/weatherkit/data-source-attribution/"]]
    let rest = try AppleWeatherREST.decode(JSONSerialization.data(withJSONObject: ["currentWeather": apple]), at: now).snapshot
    XCTAssertEqual(rest.visibility, open.visibility)
    XCTAssertEqual(rest.visibilityFogDensity, open.visibilityFogDensity)
    var missing = apple; missing.removeValue(forKey: "visibility")
    XCTAssertNil(try AppleWeatherREST.decode(JSONSerialization.data(withJSONObject: ["currentWeather": missing]), at: now).snapshot.visibility)
  }
  func testLightHazeKeepsTheObservedWeatherAndDoesNotPileOnNatureAccents() {
    let w = reading(8_046.72)
    for offset in stride(from: 0, to: 7200, by: 15) {
      let date = now.addingTimeInterval(Double(offset))
      let scene = WeatherScene(weather: w, date: date)
      XCTAssertEqual(scene.primary, w.effect)
      XCTAssertEqual(scene.clouds, 0.52, accuracy: 0.001)
      XCTAssertGreaterThan(scene.fog, 0); XCTAssertLessThan(scene.fog, 0.15)
      XCTAssertGreaterThan(scene.sunlight, 0)
      XCTAssertTrue(scene.summary.contains("Haze"))
      XCTAssertFalse(scene.stacked != nil && scene.wildlife != nil)
    }
    let dense = WeatherScene(weather: reading(100), date: now)
    XCTAssertNil(dense.wildlife); XCTAssertNil(dense.stacked)
    XCTAssertEqual(dense.sunlight, 0)
    XCTAssertEqual(WeatherScene(weather: reading(nil), date: now).fog, 0)
  }
  func testVisibilityAndAlertsUseOneSmoothFogLayerWithTheStrongerDensity() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    var w = reading(8_000); w.preferredEffect = .rain
    let alert = LocalWeatherAlert(id: "fog", summary: "Yellow warning for fog", source: "Met Office",
      detailsURL: URL(string: "https://weather-data.apple.com/alertDetails/fog")!, severity: .moderate,
      effective: now.addingTimeInterval(-3600), expires: now.addingTimeInterval(3600))
    w.alerts = [alert]
    let scene = WeatherScene(weather: w, date: now)
    XCTAssertEqual(scene.fog, alert.severity.fogDensity)
    XCTAssertFalse(scene.fogIsVisibilityDriven)
    let renderer = try Renderer(device: device, pixelFormat: .rgba8Unorm,
      simulation: SnowSimulation(width: 960, height: 600, snowfall: .steady))
    renderer.setScene(scene, calm: false)
    XCTAssertEqual(renderer.overlays.filter { $0.effect == .mist }.count, 1)
    let fog = try XCTUnwrap(renderer.overlays.first { $0.effect == .mist }?.weather.simulation)
    fog.step(dt: 1/120, cursor: SIMD2(-1000, -1000))
    XCTAssertGreaterThan(fog.fogAmount, 0); XCTAssertLessThan(fog.fogAmount, scene.fog * 0.01)
    for _ in 0..<1200 { fog.step(dt: 1/120, cursor: SIMD2(-1000, -1000)) }
    XCTAssertEqual(fog.fogAmount, scene.fog, accuracy: 0.005)
    w.visibility = 100
    XCTAssertGreaterThan(WeatherScene(weather: w, date: now).fog, scene.fog)
  }
}
