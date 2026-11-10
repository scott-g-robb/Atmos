import AppKit
import CoreLocation
import Metal
import XCTest
@testable import Aeolian

final class LiveSky141Tests: XCTestCase {
  private let away = SIMD2<Float>(-1000, -1000)
  private let now = Date(timeIntervalSince1970: 1794002400) // 6 Nov 2026, 22:00 UTC
  private func reading(cover: Double = 58, rate: Double = 0, code: Int = 3) -> WeatherSnapshot {
    var w = WeatherSnapshot(time: now.timeIntervalSince1970, weatherCode: code, temperature: 10,
      windSpeed: 0, windDirection: 0, precipitation: rate, isDay: 0)
    w.cloudCover = cover; w.precipitationUnit = "mm/h"; w.reportedCondition = "Mostly cloudy"
    return w
  }
  private func warning(_ effect: String = "Yellow warning for fog", severity: LocalWeatherAlert.Severity = .moderate,
    start: TimeInterval = -3600, end: TimeInterval = 3600) -> LocalWeatherAlert {
    LocalWeatherAlert(id: effect, summary: effect, source: "Met Office",
      detailsURL: URL(string: "https://weather-data.apple.com/alertDetails/test")!, severity: severity,
      effective: now.addingTimeInterval(-7200), expires: now.addingTimeInterval(end),
      onset: now.addingTimeInterval(start))
  }
  func testHorizontalCoverageMatchesReportedFractionAtAllWindsAndLoads() {
    for cover: Float in [0, 0.01, 0.32, 0.58, 0.99, 1] {
      for wind: Float in [-240, 0, 240] {
        var sky = CloudSky()
        for _ in 0..<600 { sky.step(size: SIMD2(1920, 1080), cover: cover, rainLoad: 0.8, wind: wind, dt: 0.05, active: true, clearing: false) }
        XCTAssertEqual(sky.occupiedWidth, 1920 * cover, accuracy: 0.04)
        let samples = (0..<1920).filter { sky.contains(x: Float($0) + 0.5) }.count
        XCTAssertEqual(Float(samples) / 1920, cover, accuracy: 0.004)
        for i in 0..<100 where cover > 0 {
          let source = sky.rainSource(Float(i) / 100)
          XCTAssertNotNil(source)
          if let source { XCTAssertTrue(sky.contains(x: source.x)) }
        }
      }
    }
  }
  func testRainLoadContinuouslyDeepensAndDarkensTheSameCoveredWidth() {
    var previousDepth: Float = 0, previousShade: Float = -1
    for rate in [0.0, 0.2, 1, 5, 20] {
      let sim = WeatherSimulation(size: SIMD2(960, 1000), seed: 4)
      sim.setEffect(.rain); sim.scene = WeatherScene(weather: reading(rate: rate, code: 63), date: now)
      for _ in 0..<600 { sim.step(dt: 1 / 60, cursor: away) }
      let depth = sim.sky.bands.map(\.depth).max() ?? 0
      XCTAssertGreaterThan(depth, previousDepth)
      XCTAssertGreaterThan(sim.sky.darkness, previousShade)
      XCTAssertEqual(sim.sky.occupiedWidth / 960, 0.58, accuracy: 0.002)
      previousDepth = depth; previousShade = sim.sky.darkness
    }
  }
  func testRainEntersAboveCloudsAndNeverSpawnsInTheGapsInCalmWeather() {
    let sim = WeatherSimulation(size: SIMD2(960, 600), seed: 4)
    sim.skyCeiling = 572
    sim.setEffect(.rain); sim.scene = WeatherScene(weather: reading(cover: 50, rate: 2, code: 63), date: now)
    for _ in 0..<1200 { sim.step(dt: 1 / 120, cursor: away) }
    let rain = sim.particles.filter { $0.motion.w == 0 }
    XCTAssertEqual(sim.sky.ceiling, 572)
    XCTAssertGreaterThan(rain.count, 10)
    for drop in rain {
      XCTAssertTrue(sim.sky.contains(x: drop.rect.x))
      XCTAssertLessThanOrEqual(drop.rect.y, sim.sky.ceiling + 4)
    }
    XCTAssertTrue(rain.contains { $0.rect.y > (sim.sky.bottom(at: $0.rect.x) ?? 0) + 20 })
  }
  func testClearDissipatesAndReformsCloudsWithoutASingleFrameJump() {
    let sim = WeatherSimulation(size: SIMD2(960, 600), seed: 4)
    sim.setEffect(.clouds)
    for _ in 0..<1200 { sim.step(dt: 1 / 120, cursor: away) }
    let full = sim.sky.occupiedWidth
    sim.clear(); sim.step(dt: 1 / 120, cursor: away)
    XCTAssertGreaterThan(sim.sky.occupiedWidth, full * 0.95)
    XCTAssertTrue(sim.decorations.contains { $0.motion.w == 12 })
    for _ in 0..<479 { sim.step(dt: 1 / 120, cursor: away) }
    XCTAssertLessThan(sim.sky.occupiedWidth, full * 0.01)
    sim.step(dt: 1 / 120, cursor: away)
    XCTAssertLessThan(sim.sky.occupiedWidth, full * 0.02)
    for _ in 0..<960 { sim.step(dt: 1 / 120, cursor: away) }
    XCTAssertGreaterThan(sim.sky.occupiedWidth, full * 0.98)
  }
  func testActiveFogWarningTakesPriorityAndHonoursOnsetAndExpiry() {
    var w = reading(); w.alerts = [warning()]; w.alertsAvailable = true
    XCTAssertEqual(WeatherScene(weather: w, date: now).primary, .mist)
    XCTAssertEqual(w.condition, "Mostly cloudy")
    XCTAssertEqual(WeatherScene(weather: w, date: now).clouds, 0.58, accuracy: 0.001)
    XCTAssertEqual(WeatherScene(weather: w, date: now.addingTimeInterval(-3601)).primary, .clouds)
    XCTAssertEqual(WeatherScene(weather: w, date: now.addingTimeInterval(3600)).primary, .clouds)
    XCTAssertEqual(w.nextAlertBoundary(after: now), now.addingTimeInterval(3600))
    w.alerts.append(warning("Severe thunderstorm warning", severity: .severe))
    XCTAssertEqual(WeatherScene(weather: w, date: now).primary, .lightning)
    XCTAssertGreaterThan(WeatherScene(weather: w, date: now).fog, 0)
    var ended = warning(); ended.eventEnd = now.addingTimeInterval(-1)
    XCTAssertTrue(ended.isVisible(at: now), "The original warning remains visible until its official expiry")
    XCTAssertFalse(ended.isActive(at: now), "An ended event must stop driving the scene")
  }
  func testFogWarningMixesWithObservedRainAndOnlyOneLayerOwnsTheSky() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    var w = reading(rate: 2, code: 63); w.alerts = [warning()]
    let scene = WeatherScene(weather: w, date: now)
    XCTAssertEqual(scene.primary, .rain); XCTAssertGreaterThan(scene.fog, 0)
    let renderer = try Renderer(device: device, pixelFormat: .rgba8Unorm,
      simulation: SnowSimulation(width: 960, height: 600, snowfall: .steady))
    renderer.setScene(scene, calm: false)
    let fog = try XCTUnwrap(renderer.overlays.first { $0.effect == .mist })
    XCTAssertFalse(fog.weather.simulation.scene.includesSky)
    XCTAssertTrue(renderer.weather.scene.includesSky)
  }
  func testAlertRequestsRequireTheLocationsCountryAndKeepRoundedCoordinates() throws {
    let location = CLLocation(latitude: 51.47229, longitude: -0.36651)
    let url = AppleWeatherREST.requestURL(at: location, countryCode: "gb")
    let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(query.first { $0.name == "country" }?.value, "GB")
    XCTAssertEqual(query.first { $0.name == "dataSets" }?.value, "currentWeather,forecastDaily,weatherAlerts")
    XCTAssertTrue(url.path.hasSuffix("/51.47/-0.37"))
    for country in [nil, "G-B", "England"] {
      let url = AppleWeatherREST.requestURL(at: location, countryCode: country)
      XCTAssertFalse(url.absoluteString.contains("weatherAlerts"))
    }
  }
  func testRESTWarningTimesSourceAndDetailsSurviveWithoutDiscardingCurrentWeather() throws {
    let formatter = ISO8601DateFormatter()
    let current: [String: Any] = ["asOf": formatter.string(from: now), "conditionCode": "MostlyCloudy",
      "daylight": false, "cloudCover": 0.58, "humidity": 0.9, "temperature": 10,
      "temperatureApparent": 8, "windSpeed": 4, "windDirection": 270, "precipitationIntensity": 0,
      "metadata": ["attributionURL": "https://developer.apple.com/weatherkit/data-source-attribution/"]]
    let raw: [String: Any] = ["id": "fog", "description": "Yellow warning for fog", "source": "Met Office", "severity": "moderate",
      "effectiveTime": formatter.string(from: now.addingTimeInterval(-7200)),
      "eventOnsetTime": formatter.string(from: now.addingTimeInterval(-3600)),
      "expireTime": formatter.string(from: now.addingTimeInterval(3600))]
    let payload: [String: Any] = ["currentWeather": current,
      "weatherAlerts": ["detailsUrl": "https://weather-data.apple.com/alertDetails/test", "alerts": [raw]]]
    let result = try AppleWeatherREST.decode(JSONSerialization.data(withJSONObject: payload), at: now).snapshot
    XCTAssertTrue(result.alertsAvailable); XCTAssertEqual(result.alerts.count, 1)
    XCTAssertEqual(result.activeAlerts(at: now).first?.summary, "Yellow warning for fog")
    XCTAssertEqual(result.alerts.first?.source, "Met Office")
    XCTAssertEqual(WeatherScene(weather: result, date: now).primary, .mist)
    let unsupported = try AppleWeatherREST.decode(JSONSerialization.data(withJSONObject: ["currentWeather": current]), at: now).snapshot
    XCTAssertFalse(unsupported.alertsAvailable); XCTAssertEqual(unsupported.effect, .clouds)
  }
  func testWarningCardContainsTheCompleteLinkedAgencyText() {
    let card = WeatherMenuCard()
    var w = reading(); w.alertsAvailable = true
    w.alerts = [warning(start: -3600, end: 7200)]
    // Move the fixture to the real clock, since menu presentation uses now.
    let shift = Date().timeIntervalSince(now)
    w.alerts[0].effective.addTimeInterval(shift); w.alerts[0].expires.addTimeInterval(shift)
    w.alerts[0].onset?.addTimeInterval(shift)
    card.update(reading: w, place: "Hounslow", detail: "", status: "", live: true)
    func labels(_ view: NSView) -> [NSTextField] {
      view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels($0) }
    }
    let fields = labels(card)
    let alert = fields.first { $0.stringValue == "Yellow warning for fog\nMet Office" }
    XCTAssertNotNil(alert)
    XCTAssertEqual(alert?.attributedStringValue.attribute(.link, at: 0, effectiveRange: nil) as? URL, w.alerts[0].detailsURL)
    XCTAssertEqual(alert?.maximumNumberOfLines, 0)
    if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"],
      let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds) {
      card.cacheDisplay(in: card.bounds, to: bitmap)
      if let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: output).appendingPathComponent("warning-card.png"))
      }
    }
  }
}
