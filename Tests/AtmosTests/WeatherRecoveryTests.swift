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
      if calls == 1 { throw URLError(.notConnectedToInternet) }
      return appleReading()
    }
    let first = try await WeatherRequest.fetch(
      source: .automatic, appleAvailable: true,
      apple: { try apple() }, openMeteo: { self.snapshot(code: 3) })
    XCTAssertEqual(first.snapshot.effect, .clouds)
    let next = try await WeatherRequest.fetch(
      source: .automatic, appleAvailable: true,
      apple: { try apple() }, openMeteo: { self.snapshot(code: 3) })
    XCTAssertEqual(next.snapshot.effect, .drizzle)
    XCTAssertEqual(calls, 2)
  }
  func testExplicitProvidersNeverSilentlySwitch() async throws {
    var appleCalls = 0
    var fallbackCalls = 0
    do {
      _ = try await WeatherRequest.fetch(
        source: .apple, appleAvailable: true,
        apple: {
          appleCalls += 1
          throw URLError(.timedOut)
        },
        openMeteo: {
          fallbackCalls += 1
          return self.snapshot(code: 3)
        })
      XCTFail("Explicit Apple must report an Apple failure")
    } catch { XCTAssertEqual(fallbackCalls, 0) }
    _ = try await WeatherRequest.fetch(
      source: .openMeteo, appleAvailable: true,
      apple: {
        appleCalls += 1
        return self.appleReading()
      },
      openMeteo: {
        fallbackCalls += 1
        return self.snapshot(code: 3)
      })
    XCTAssertEqual(appleCalls, 1)
    XCTAssertEqual(fallbackCalls, 1)
  }
  func testWakeRecoveryRetriesQuicklyAndAppleFallbackHasNoHourLongHold() {
    let now = Date(timeIntervalSince1970: 1000)
    var recovery = WeatherRecovery()
    recovery.resume(at: now)
    XCTAssertEqual(recovery.failureDelay(1, at: now), 5)
    XCTAssertEqual(recovery.failureDelay(2, at: now.addingTimeInterval(5)), 10)
    XCTAssertEqual(recovery.failureDelay(3, at: now.addingTimeInterval(15)), 20)
    XCTAssertFalse(recovery.isRecovering(at: now.addingTimeInterval(121)))
    XCTAssertEqual(WeatherRecovery.appleRetryDelay(1), 30)
    XCTAssertLessThanOrEqual(WeatherRecovery.appleRetryDelay(100), 300)
  }
  func testNewInstallStartsLiveWithNoManualLayersWhileSavedChoicesSurvive() {
    let name = "Atmos.InstallDefaultsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "atmosMigratedPreferences3")
    Preferences.registerDefaults(in: defaults)
    XCTAssertTrue(defaults.bool(forKey: "liveWeather"))
    XCTAssertEqual(defaults.string(forKey: "weatherEffect"), WeatherEffect.none.rawValue)
    XCTAssertEqual(defaults.persistentDomain(forName: name)?["liveWeather"] as? Bool, true)
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
