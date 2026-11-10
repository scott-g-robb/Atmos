import AppKit
import XCTest
@testable import Aeolian

private final class Update142Protocol: URLProtocol {
  static var status = 200
  static var data = Data()
  static var requests = 0
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.requests += 1
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.data); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class UpdateAndUnits142Tests: XCTestCase {
  private func service(version: String = "0.14.3", status: Int = 200) throws -> GitHubUpdates {
    Update142Protocol.status = status; Update142Protocol.requests = 0
    Update142Protocol.data = try JSONSerialization.data(withJSONObject: ["name": "Aeolian \(version)", "draft": false, "prerelease": false,
      "assets": [["name": "Aeolian-\(version).dmg", "size": 100, "browser_download_url": "https://github.com/scott-g-robb/Aeolian/releases/download/v\(version)/Aeolian-\(version).dmg"]]])
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Update142Protocol.self]
    return GitHubUpdates(session: URLSession(configuration: config))
  }
  @MainActor private func waitForCheck(_ updater: AppUpdater, seconds: Double = 3) async {
    let end = Date().addingTimeInterval(seconds)
    while updater.lastCheckedAt == nil && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
  }
  @MainActor func testPeriodicDiscoveryRunsWithAutomaticInstallationOffAndPersistsTheBadge() async throws {
    _ = NSApplication.shared
    let domain = "Aeolian.update142.\(UUID())", defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    var installs = 0
    let updater = AppUpdater(service: try service(), defaults: defaults, currentVersion: AppVersion("0.14.2"), automaticInstaller: { _ in installs += 1 }, canInstallAutomatically: { true })
    defer { updater.stop() }
    let visible = Set(NSApp.windows.filter(\.isVisible))
    updater.setAutomaticActivity(enabled: false, active: true)
    await waitForCheck(updater) // Exercise the real startup timer, not a direct check.
    XCTAssertEqual(Update142Protocol.requests, 1)
    XCTAssertEqual(installs, 0); XCTAssertTrue(updater.updateAvailable)
    XCTAssertEqual(updater.checkStatus, "Update available"); XCTAssertNotNil(updater.lastCheckedAt)
    XCTAssertTrue(Set(NSApp.windows.filter(\.isVisible)).isSubset(of: visible), "Discovery never opens update UI")
    let reopened = AppUpdater(defaults: defaults, currentVersion: AppVersion("0.14.2"))
    XCTAssertTrue(reopened.updateAvailable); XCTAssertEqual(reopened.lastCheckedAt, updater.lastCheckedAt)
    let upgraded = AppUpdater(defaults: defaults, currentVersion: AppVersion("0.14.3"))
    XCTAssertFalse(upgraded.updateAvailable); XCTAssertEqual(upgraded.checkStatus, "Up-To-Date")
    let app = AppDelegate(weather: LiveWeather(), updater: reopened), item = app.makeStatusItem()
    defer { app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); NSStatusBar.system.removeStatusItem(item) }
    try await Task.sleep(nanoseconds: 50_000_000)
    let button = try XCTUnwrap(item.button)
    XCTAssertTrue(button.image?.isTemplate == true, "The icon must retain native menu-bar colouring")
    XCTAssertEqual(item.length, NSStatusBar.system.thickness + 12)
    let badge = try XCTUnwrap(button.subviews.first { $0 is UpdateBadgeView })
    XCTAssertFalse(badge.isHidden)
    XCTAssertLessThanOrEqual(badge.frame.maxX, button.bounds.maxX)
  }
  @MainActor func testOnlyOptedInChecksInstallAndInactiveChecksDoNotRun() async throws {
    let domain = "Aeolian.update142.\(UUID())", defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    var installs = 0
    let updater = AppUpdater(service: try service(), defaults: defaults, currentVersion: AppVersion("0.14.2"), automaticInstaller: { _ in installs += 1 }, canInstallAutomatically: { true })
    defer { updater.stop() }
    updater.setAutomaticActivity(enabled: true, active: false)
    updater.checkAutomatically()
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(Update142Protocol.requests, 0)
    updater.setAutomaticActivity(enabled: true, active: true)
    updater.checkAutomatically(); await waitForCheck(updater)
    XCTAssertEqual(Update142Protocol.requests, 1); XCTAssertEqual(installs, 1)
  }
  @MainActor func testReadOnlyInstallationStillDiscoversUpdatesWithoutInstalling() async throws {
    let domain = "Aeolian.update142.\(UUID())", defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    var installs = 0
    let updater = AppUpdater(service: try service(), defaults: defaults, currentVersion: AppVersion("0.14.2"), automaticInstaller: { _ in installs += 1 }, canInstallAutomatically: { false })
    defer { updater.stop() }
    updater.setAutomaticActivity(enabled: true, active: true)
    updater.checkAutomatically(); await waitForCheck(updater)
    XCTAssertEqual(Update142Protocol.requests, 1); XCTAssertTrue(updater.updateAvailable)
    XCTAssertEqual(installs, 0)
  }
  @MainActor func testFailedDiscoveryIsNotReportedAsUpToDate() async throws {
    let domain = "Aeolian.update142.\(UUID())", defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let updater = AppUpdater(service: try service(status: 503), defaults: defaults, currentVersion: AppVersion("0.14.2"))
    defer { updater.stop() }
    updater.setAutomaticActivity(enabled: false, active: true)
    updater.checkAutomatically(); await waitForCheck(updater)
    XCTAssertEqual(updater.checkStatus, "Couldn't check"); XCTAssertNotNil(updater.lastCheckedAt)
    XCTAssertFalse(updater.updateAvailable)
  }
  func testDisplayUnitsConvertAllMeasurementsAndKeepFineRainVisible() {
    XCTAssertEqual(WeatherUnits.metric.temperature(0), "0°C")
    XCTAssertEqual(WeatherUnits.imperial.temperature(0), "32°F")
    XCTAssertEqual(WeatherUnits.imperial.wind(16.09344), "10 mph")
    XCTAssertEqual(WeatherUnits.metric.wind(16.09344), "16 km/h")
    XCTAssertEqual(WeatherUnits.imperial.rainfall(25.4), "1.000 in/h")
    XCTAssertEqual(WeatherUnits.imperial.rainfall(0.2), "0.008 in/h")
    XCTAssertEqual(WeatherUnits.imperial.visibility(1609.344), "1.0 mi")
    XCTAssertEqual(WeatherUnits.imperial.visibility(30.48), "100 ft")
    XCTAssertNil(WeatherUnits.imperial.visibility(.nan))
  }
  @MainActor func testUnitsDefaultToCelsiusAndSwitchWithoutChangingTheSceneOrPreset() throws {
    _ = NSApplication.shared
    let old = UserDefaults.standard.object(forKey: "weatherUnits")
    defer { if let old { UserDefaults.standard.set(old, forKey: "weatherUnits") } else { UserDefaults.standard.removeObject(forKey: "weatherUnits") } }
    UserDefaults.standard.removeObject(forKey: "weatherUnits")
    XCTAssertEqual(Preferences.weatherUnits, .metric)
    let scene = Preferences.manualScene, wind = Preferences.manualWindSpeed
    let app = AppDelegate(), item = app.makeStatusItem()
    defer { app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); NSStatusBar.system.removeStatusItem(item) }
    let controller = try XCTUnwrap(app.installCustomMenu())
    let units = try XCTUnwrap(controller.model.settings?.items.first { $0.title == "Units" }?.submenu)
    controller.model.invoke(try XCTUnwrap(units.items.first { $0.representedObject as? String == "imperial" }))
    XCTAssertEqual(Preferences.weatherUnits, .imperial)
    XCTAssertEqual(Preferences.manualScene, scene); XCTAssertEqual(Preferences.manualWindSpeed, wind)
    let w = WeatherSnapshot(time: Date().timeIntervalSince1970, weatherCode: 0, temperature: 0,
      windSpeed: 16.09344, windDirection: 0, precipitation: 0, isDay: 1)
    XCTAssertEqual(w.menuMeasurements.first { $0.title == "Temperature" }?.value, "32°F")
    XCTAssertEqual(w.menuMeasurements.first { $0.title == "Wind" }?.value, "10 mph")
    let badge = UpdateBadgeView(frame: CGRect(x: 0, y: 0, width: 5, height: 5))
    XCTAssertNil(badge.hitTest(CGPoint(x: 2, y: 2)), "The notification must not steal menu clicks")
  }
}
