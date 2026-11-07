import XCTest

@testable import Atmos

final class WeatherRecoveryTests: XCTestCase {
  private func snapshot(code: Int) -> WeatherSnapshot {
    WeatherSnapshot(
      time: Date().timeIntervalSince1970, weatherCode: code, temperature: 12,
      windSpeed: 10, windDirection: 270, precipitation: 0.2, isDay: 1)
  }
  private func appleReading() -> AppleWeather.Reading {
    AppleWeather.Reading(
      snapshot: snapshot(code: 51),
      attribution: AppleWeather.Attribution(
        combinedMarkDarkURL: URL(string: "https://weatherkit.apple.com/unavailable-image.png")!,
        legalPageURL: URL(
          string: "https://developer.apple.com/weatherkit/data-source-attribution/")!))
  }
  func testAutomaticAndManualAppleUseTheSameReadingWithoutDependingOnTheLogo() async throws {
    var fallbackCalls = 0
    for source in [WeatherSource.automatic, .apple] {
      let reading = try await WeatherRequest.fetch(
        source: source, appleAvailable: true,
        apple: { self.appleReading() },
        openMeteo: {
          fallbackCalls += 1
          return self.snapshot(code: 3)
        })
      XCTAssertEqual(reading.snapshot.effect, .drizzle)
      guard case .apple = reading else {
        XCTFail("A valid Apple reading must be kept")
        continue
      }
    }
    XCTAssertEqual(fallbackCalls, 0)
  }
  func testAutomaticRetriesAppleOnTheNextRequestAfterOneFailure() async throws {
    var calls = 0
    func apple() throws -> AppleWeather.Reading {
      calls += 1
      if calls <= 2 { throw URLError(.notConnectedToInternet) }
      return appleReading()
    }
    let first = try await WeatherRequest.fetch(
      source: .automatic, appleAvailable: true, retryDelay: 0,
      apple: { try apple() }, openMeteo: { self.snapshot(code: 3) })
    XCTAssertEqual(first.snapshot.effect, .clouds)
    let next = try await WeatherRequest.fetch(
      source: .automatic, appleAvailable: true, retryDelay: 0,
      apple: { try apple() }, openMeteo: { self.snapshot(code: 3) })
    XCTAssertEqual(next.snapshot.effect, .drizzle)
    XCTAssertEqual(calls, 3)
  }
  func testAppleRetriesBeforeLabelledFallbackAndExplicitOpenMeteoDoesNotCallApple() async throws {
    var appleCalls = 0, fallbackCalls = 0
    let reading = try await WeatherRequest.fetch(
      source: .apple, appleAvailable: true, retryDelay: 0,
      apple: { appleCalls += 1;throw URLError(.timedOut) },
      openMeteo: { fallbackCalls += 1;return self.snapshot(code:3) })
    guard case .openMeteo = reading else { return XCTFail("Failed Apple retries must reach fallback") }
    XCTAssertEqual(appleCalls,2);XCTAssertEqual(fallbackCalls,1)
    _ = try await WeatherRequest.fetch(
      source: .openMeteo, appleAvailable: true,
      apple: { appleCalls += 1;return self.appleReading() },
      openMeteo: { fallbackCalls += 1;return self.snapshot(code:3) })
    XCTAssertEqual(appleCalls,2);XCTAssertEqual(fallbackCalls,2)
  }
  func testWakeRecoveryRetriesQuicklyAndAppleFallbackHasNoHourLongHold() {
    let now = Date(timeIntervalSince1970: 1000)
    var recovery = WeatherRecovery()
    recovery.resume(at: now)
    XCTAssertEqual(recovery.nextFailureDelay(), 1)
    XCTAssertEqual(recovery.nextFailureDelay(), 2)
    XCTAssertEqual(recovery.nextFailureDelay(), 3)
    XCTAssertFalse(recovery.isRecovering(at: now.addingTimeInterval(121)))
    XCTAssertEqual(WeatherRecovery.appleRetryDelay(1), 30)
    XCTAssertLessThanOrEqual(WeatherRecovery.appleRetryDelay(100), 300)
  }
  func testLocationAndWeatherFailuresRetryWithTheExactScheduleThenStop() {
    var recovery = WeatherRecovery()
    let delays = (0..<14).compactMap { _ in recovery.nextFailureDelay() }
    XCTAssertEqual(delays, [1, 2, 3, 5, 15] + Array(repeating: 30, count: 9))
    XCTAssertEqual(recovery.failedAttempts, 14)
    XCTAssertFalse(recovery.exhausted, "The fifteenth request must still be allowed to run")
    XCTAssertNil(recovery.nextFailureDelay())
    XCTAssertTrue(recovery.exhausted)
    for _ in 0..<20 { XCTAssertNil(recovery.nextFailureDelay()) }
    XCTAssertEqual(recovery.failedAttempts, 15)
  }
  func testSuccessManualRefreshAndWakeStartANewRetryBudget() {
    var recovery = WeatherRecovery()
    for _ in 0..<16 { _ = recovery.nextFailureDelay() }
    XCTAssertTrue(recovery.exhausted)
    recovery.resetRetries()
    XCTAssertFalse(recovery.exhausted)
    XCTAssertEqual(recovery.nextFailureDelay(), 1)
    for _ in 0..<15 { _ = recovery.nextFailureDelay() }
    XCTAssertTrue(recovery.exhausted)
    recovery.resume()
    XCTAssertFalse(recovery.exhausted)
    XCTAssertEqual(recovery.failedAttempts, 0)
    XCTAssertEqual(recovery.nextFailureDelay(), 1)
  }
  func testNewInstallStartsManualWithNoLayersWhileSavedChoicesSurvive() {
    let name = "Atmos.InstallDefaultsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "atmosMigratedPreferences3")
    Preferences.registerDefaults(in: defaults)
    XCTAssertFalse(defaults.bool(forKey: "liveWeather"))
    XCTAssertEqual(defaults.string(forKey: "weatherEffect"), WeatherEffect.none.rawValue)
    XCTAssertEqual(defaults.persistentDomain(forName: name)?["liveWeather"] as? Bool, false)
    XCTAssertEqual(defaults.persistentDomain(forName: name)?["weatherEffect"] as? String, "none")
    XCTAssertNil(defaults.string(forKey: "seasonalDrift"))
    XCTAssertNil(defaults.string(forKey: "wildlifeEffect"))
    defaults.set(false, forKey: "liveWeather")
    defaults.set("rain", forKey: "weatherEffect")
    defaults.set("cherryBlossoms", forKey: "seasonalDrift")
    defaults.set("birds", forKey: "wildlifeEffect")
    Preferences.registerDefaults(in: defaults)
    XCTAssertFalse(defaults.bool(forKey: "liveWeather"))
    XCTAssertEqual(defaults.string(forKey: "weatherEffect"), "rain")
    XCTAssertEqual(defaults.string(forKey: "seasonalDrift"), "cherryBlossoms")
    XCTAssertEqual(defaults.string(forKey: "wildlifeEffect"), "birds")
  }
  func testLocationPrefersDistrictAndAvoidsRepeatedPlaceNames() {
    XCTAssertEqual(
      LocationPresentation.name(
        district: "Hounslow", city: "London", region: "England", country: "United Kingdom"),
      "Hounslow, London, United Kingdom")
    XCTAssertEqual(
      LocationPresentation.name(
        district: "Hounslow", city: "Hounslow", region: "England", country: "United Kingdom"),
      "Hounslow, United Kingdom")
    XCTAssertEqual(
      LocationPresentation.name(
        district: nil, city: "London", region: "England", country: "United Kingdom"),
      "London, England, United Kingdom")
  }
}
