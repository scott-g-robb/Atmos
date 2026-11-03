import CoreLocation
import XCTest

@testable import Atmos

final class PermissionPresentationTests: XCTestCase {
  func testScreenGrantIsDistinctFromCurrentCaptureAndUserStop() {
    let denied = PermissionPresentation.screen(
      granted: false, enabled: true, active: false, stopped: false)
    XCTAssertFalse(denied.granted)
    XCTAssertEqual(denied.status, "Not granted")
    let disabled = PermissionPresentation.screen(
      granted: true, enabled: false, active: false, stopped: false)
    XCTAssertEqual(disabled.status, "Granted")
    XCTAssertTrue(disabled.detail.contains("No desktop capture"))
    let active = PermissionPresentation.screen(
      granted: true, enabled: true, active: true, stopped: false)
    XCTAssertTrue(active.status.contains("In use"))
    let stopped = PermissionPresentation.screen(
      granted: true, enabled: true, active: false, stopped: true)
    XCTAssertTrue(stopped.detail.contains("Stopped in macOS"))
    XCTAssertFalse(stopped.status.contains("In use"))
  }

  func testLocationDistinguishesMissingPermissionActiveAccessAndCachedWeather() {
    let fresh = PermissionPresentation.location(
      status: .notDetermined, enabled: false, locating: false, paused: false)
    XCTAssertEqual(fresh.status, "Not requested")
    XCTAssertTrue(fresh.detail.contains("Enable Live Weather"))
    XCTAssertFalse(
      PermissionPresentation.location(
        status: .denied, enabled: true, locating: false, paused: false
      ).granted)
    let cached = PermissionPresentation.location(
      status: .authorizedAlways, enabled: true, locating: false, paused: false)
    XCTAssertEqual(cached.status, "Granted")
    XCTAssertTrue(cached.detail.contains("Idle"))
    XCTAssertTrue(
      PermissionPresentation.location(
        status: .authorized, enabled: true, locating: true, paused: false
      ).status.contains("In use"))
  }
}
