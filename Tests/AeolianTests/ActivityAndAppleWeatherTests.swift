import CryptoKit
import WeatherKit
import XCTest

@testable import Aeolian

final class ActivityAndAppleWeatherTests: XCTestCase {
  func testFullScreenDisablesDisplayFramesAndPolling() {
    for visible in [true, false] {
      let covered = DisplayActivity(awake: true, fullScreen: true, visible: visible, fading: false)
      XCTAssertFalse(covered.renders)
      XCTAssertFalse(covered.pollsWindows)
    }
    let transitioning = DisplayActivity(awake: true, fullScreen: true, visible: true, fading: true)
    XCTAssertTrue(transitioning.renders)
    XCTAssertFalse(transitioning.pollsWindows)
    let restored = DisplayActivity(awake: true, fullScreen: false, visible: true, fading: false)
    XCTAssertTrue(restored.renders)
    XCTAssertTrue(restored.pollsWindows)
    let locked = DisplayActivity(awake: false, fullScreen: false, visible: true, fading: true)
    XCTAssertFalse(locked.renders)
    XCTAssertFalse(locked.pollsWindows)
  }

  func testEveryAppleWeatherConditionHasAValidMapping() {
    for condition in WeatherCondition.allCases {
      let mapping = AppleWeather.mapping(condition)
      XCTAssertTrue(WeatherSnapshot.knownCodes.contains(mapping.code), condition.rawValue)
    }
    XCTAssertEqual(AppleWeather.mapping(.wintryMix).effect, .sleet)
    XCTAssertEqual(AppleWeather.mapping(.blizzard).effect, .snow)
    XCTAssertNil(AppleWeather.mapping(.breezy).effect)
    XCTAssertEqual(AppleWeather.mapping(.foggy).effect, .mist)
    XCTAssertEqual(AppleWeather.mapping(.hurricane).effect, .storm)
  }

  func testReportedConditionsAreSeparateFromDecorativeEffects() {
    let reading = WeatherSnapshot(
      time: Date().timeIntervalSince1970, weatherCode: 2, temperature: 12,
      windSpeed: 8, windDirection: 180, precipitation: 0, isDay: 1)
    XCTAssertEqual(reading.condition, "Partly cloudy")
    XCTAssertEqual(reading.effect, .sunlight)
    var invalid = reading
    invalid.humidity = 1e100
    XCTAssertFalse(invalid.isUsable())
  }
  func testPersonalWeatherKitTokenUsesRequiredClaimsAndValidES256Signature() throws {
    let key = P256.Signing.PrivateKey()
    let credentials = WeatherKitCredentials(
      teamID: "TESTTEAM00", keyID: "TESTKEY000", serviceID: "test.atmos",
      privateKeyPEM: key.pemRepresentation)
    let token = try credentials.token(at: Date(timeIntervalSince1970: 10000))
    let parts = token.split(separator: ".").map(String.init)
    XCTAssertEqual(parts.count, 3)
    func decode(_ value: String) throws -> Data {
      let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
      return try XCTUnwrap(
        Data(base64Encoded: padded + String(repeating: "=", count: (4 - padded.count % 4) % 4)))
    }
    let claims = try XCTUnwrap(
      JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])
    XCTAssertEqual(Set(claims.keys), ["iss", "iat", "exp", "sub"])
    XCTAssertEqual(claims["sub"] as? String, "test.atmos")
    XCTAssertEqual(claims["exp"] as? Int, 10600)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
    XCTAssertTrue(
      key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
  }

  func testAppleRESTResponseUsesMetricUnitsAndBuildsLayeredNightScene() throws {
    let data = Data(
      """
      {"currentWeather":{"asOf":"2026-11-03T06:43:02Z","conditionCode":"MostlyClear","daylight":false,"cloudCover":0.3,"humidity":0.8,"temperature":8,"temperatureApparent":6,"windSpeed":12.36,"windDirection":230,"precipitationIntensity":0,"metadata":{"attributionURL":"https://developer.apple.com/weatherkit/data-source-attribution/"}}}
      """.utf8)
    let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-03T06:45:00Z"))
    let reading = try AppleWeatherREST.decode(data, at: date)
    XCTAssertEqual(reading.snapshot.windSpeed, 12.36)
    XCTAssertEqual(reading.snapshot.cloudCover, 30)
    XCTAssertEqual(reading.snapshot.humidity, 80)
    let scene = WeatherScene(weather: reading.snapshot)
    XCTAssertEqual(scene.primary, .none)
    XCTAssertGreaterThan(scene.clouds, 0)
    XCTAssertEqual(reading.attribution.legalPageURL.host, "developer.apple.com")
    XCTAssertThrowsError(try AppleWeatherREST.decode(data, at: date.addingTimeInterval(8000)))
  }

  @MainActor func testAutomaticIntensityDisablesTheNativeSliderAndRestoresManualControl() {
    let slider = SnowfallSlider()
    slider.snowfall = .heavy
    slider.automatic = true
    let control = slider.subviews.compactMap { $0 as? NSSlider }.first
    let caption = slider.subviews.compactMap { $0 as? NSTextField }.first
    XCTAssertFalse(control?.isEnabled ?? true)
    XCTAssertEqual(caption?.stringValue, "Auto · Heavy")
    slider.awaitingWeather = true
    XCTAssertEqual(caption?.stringValue, "Auto · Waiting for weather")
    slider.automatic = false
    XCTAssertTrue(control?.isEnabled ?? false)
    XCTAssertEqual(caption?.stringValue, "Heavy")
  }

  func testLiveIntensityFollowsReportedWeatherInsteadOfManualPreference() {
    func reading(_ code: Int) -> WeatherSnapshot {
      .init(
        time: Date().timeIntervalSince1970, weatherCode: code, temperature: 8, windSpeed: 5,
        windDirection: 0, precipitation: 0, isDay: 1)
    }
    XCTAssertEqual(reading(61).intensity, .light)
    XCTAssertEqual(reading(63).intensity, .steady)
    XCTAssertEqual(reading(65).intensity, .heavy)
    XCTAssertEqual(reading(71).intensity, .light)
    XCTAssertEqual(reading(75).intensity, .heavy)
    XCTAssertEqual(reading(95).intensity, .heavy)
  }

}
