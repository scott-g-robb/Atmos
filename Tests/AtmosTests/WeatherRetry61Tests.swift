import AppKit
import CoreLocation
import XCTest
@testable import Atmos

private final class RetryLocation: WeatherLocationClient {
  var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
  weak var delegate: CLLocationManagerDelegate?
  private let sender = CLLocationManager()
  var requests = 0
  var stopped = 0
  var onRequest: () -> Void = {}
  func requestWhenInUseAuthorization() { XCTFail("Retry tests must never request system permissions") }
  func requestLocation() { requests += 1; onRequest() }
  func stopUpdatingLocation() { stopped += 1 }
  func succeed() {
    delegate?.locationManager?(sender,didUpdateLocations:[CLLocation(
      coordinate:CLLocationCoordinate2D(latitude:0,longitude:0),altitude:0,
      horizontalAccuracy:5,verticalAccuracy:5,timestamp:Date())])
  }
  func fail() {
    delegate?.locationManager?(sender,didFailWithError:NSError(
      domain:kCLErrorDomain,code:CLError.Code.locationUnknown.rawValue))
  }
  func repeatAuthorization() { delegate?.locationManagerDidChangeAuthorization?(sender) }
}

final class WeatherRetry61Tests: XCTestCase {
  private func reading(code:Int=51) -> WeatherRequest.Reading {
    .openMeteo(WeatherSnapshot(time:Date().timeIntervalSince1970,weatherCode:code,
      temperature:12,windSpeed:10,windDirection:270,precipitation:0.2,isDay:1))
  }
  private func savePreferences() -> () -> Void {
    let defaults=UserDefaults.standard
    let keys=["weatherSource","liveWeather"]
    let saved=keys.map{defaults.object(forKey:$0)}
    Preferences.weatherSource = .openMeteo
    return {for (key,value) in zip(keys,saved) {
      if let value {defaults.set(value,forKey:key)} else {defaults.removeObject(forKey:key)}
    }}
  }
  @MainActor private func waitForReading(_ weather:LiveWeather) async throws {
    for _ in 0..<200 {
      if weather.current != nil {return}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    XCTFail("Automatic recovery never produced weather: \(weather.status)")
  }

  @MainActor func testFirstPostSetupLocationFailureRetriesAfterOneRealSecondWithoutRefresh() async throws {
    let restore=savePreferences();defer{restore()}
    let location=RetryLocation()
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{false},
      requestWeather:{_,_,_ in self.reading()},observesNetwork:false,resolvesNames:false)
    defer{weather.stop()}
    var times=[Date]()
    location.onRequest={
      times.append(Date())
      if location.requests==1 {location.fail()} else {location.succeed()}
    }
    weather.setSuspended(true)
    weather.setEnabled(true)
    XCTAssertEqual(location.requests,0,"Setup must stay paused")
    weather.setSuspended(false)
    XCTAssertTrue(weather.status.contains("Retrying in 1s"))
    try await waitForReading(weather)
    XCTAssertEqual(location.requests,2)
    let gap=try XCTUnwrap(times.last).timeIntervalSince(try XCTUnwrap(times.first))
    XCTAssertGreaterThanOrEqual(gap,0.9)
    XCTAssertLessThan(gap,1.8)
    XCTAssertEqual(weather.current?.effect,.drizzle)
  }

  @MainActor func testUnavailableAppleAtStartupEntersTheSameAutomaticRetryLoop() async throws {
    let restore=savePreferences();defer{restore()}
    Preferences.weatherSource = .apple
    let location=RetryLocation()
    var available=false,calls=0
    let timing=LiveWeather.Timing()
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{available},
      requestWeather:{source,_,_ in
        try await WeatherRequest.fetch(source:source,appleAvailable:available,retryDelay:0.02,
          apple:{
            calls+=1
            return AppleWeather.Reading(snapshot:self.reading().snapshot,
              attribution:AppleWeather.Attribution(combinedMarkDarkURL:URL(fileURLWithPath:"/no-attribution-image"),
                legalPageURL:URL(string:"https://developer.apple.com/weatherkit/data-source-attribution/")!))
          },openMeteo:{self.reading().snapshot})
      },observesNetwork:false,resolvesNames:false,timing:timing)
    defer{weather.stop()}
    location.onRequest={location.succeed()}
    weather.setEnabled(true)
    XCTAssertEqual(calls,0)
    XCTAssertNil(weather.current,"The first unavailable-Apple pass is still preparing")
    available=true
    try await waitForReading(weather)
    XCTAssertEqual(calls,1)
    XCTAssertEqual(weather.provider,"Apple Weather")
  }

  @MainActor func testFirstPostSetupWeatherFailureRetriesAfterOneRealSecondUsingTheValidLocation() async throws {
    let restore=savePreferences();defer{restore()}
    let location=RetryLocation()
    var requests=[Date]()
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{false},
      requestWeather:{_,_,_ in
        requests.append(Date())
        if requests.count==1 {throw URLError(.badServerResponse)}
        return self.reading()
      },observesNetwork:false,resolvesNames:false)
    defer{weather.stop()}
    location.onRequest={location.succeed()}
    weather.setSuspended(true);weather.setEnabled(true)
    weather.setSuspended(false)
    try await waitForReading(weather)
    XCTAssertEqual(requests.count,2)
    XCTAssertEqual(location.requests,1,"A valid location should be reused for a failed weather fetch")
    let gap=try XCTUnwrap(requests.last).timeIntervalSince(try XCTUnwrap(requests.first))
    XCTAssertGreaterThanOrEqual(gap,0.9)
    XCTAssertLessThan(gap,1.8)
    XCTAssertEqual(weather.current?.effect,.drizzle)
  }

  @MainActor func testActualFailedRequestsFollowAllFourteenDelaysThenSwitchOffAtFifteen() async throws {
    let restore=savePreferences();defer{restore()}
    let location=RetryLocation()
    var delays=[TimeInterval](),calls=0,stops=0
    let timing=LiveWeather.Timing(retryInterval:{delays.append($0);return 0.005})
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{false},
      requestWeather:{_,_,_ in calls+=1;throw URLError(.notConnectedToInternet)},
      observesNetwork:false,resolvesNames:false,timing:timing)
    defer{weather.stop()}
    location.onRequest={location.succeed()}
    weather.failureLimitReached={stops+=1}
    weather.setEnabled(true)
    for _ in 0..<200 {
      if !weather.enabled {break}
      try await Task.sleep(nanoseconds:5_000_000)
    }
    XCTAssertFalse(weather.enabled)
    XCTAssertEqual(calls,15)
    XCTAssertEqual(stops,1)
    XCTAssertEqual(delays,[1,2,3,5,15]+Array(repeating:30,count:9))
    weather.refresh(force:true,automatic:true)
    location.succeed()
    try await Task.sleep(nanoseconds:30_000_000)
    XCTAssertEqual(calls,15,"Late callbacks and automatic refreshes must not revive an exhausted session")
    XCTAssertNil(weather.current)
  }

  @MainActor func testDuplicateAuthorizationAndAutomaticCallbacksCannotStealTheRetry() async throws {
    let restore=savePreferences();defer{restore()}
    let location=RetryLocation()
    var delays=[TimeInterval]()
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{false},
      requestWeather:{_,_,_ in self.reading()},observesNetwork:false,resolvesNames:false,
      timing:LiveWeather.Timing(retryInterval:{delays.append($0);return 0.02}))
    defer{weather.stop()}
    location.onRequest={if location.requests<3 {location.fail()} else {location.succeed()}}
    weather.setEnabled(true)
    for _ in 0..<3 {location.repeatAuthorization();weather.refresh(force:true,automatic:true)}
    location.succeed() // A cancelled request's late result must not steal the pending retry.
    XCTAssertEqual(location.requests,1)
    try await waitForReading(weather)
    XCTAssertEqual(location.requests,3)
    XCTAssertEqual(delays,[1,2])
  }

  @MainActor func testLocationTimeoutAndRetryRunWhileTheMenuIsTracking() async throws {
    let restore=savePreferences();defer{restore()}
    _=NSApplication.shared
    let location=RetryLocation()
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{false},
      requestWeather:{_,_,_ in self.reading()},observesNetwork:false,resolvesNames:false,
      timing:LiveWeather.Timing(locationTimeout:0.02,requestTimeout:2,retryInterval:{_ in 0.005}))
    defer{weather.stop()}
    location.onRequest={if location.requests>1 {location.succeed()}}
    weather.setEnabled(true)
    func trackMenu() {
      CFRunLoopAddCommonMode(CFRunLoopGetMain(),CFRunLoopMode(rawValue:RunLoop.Mode.eventTracking.rawValue as CFString))
      let end=Date().addingTimeInterval(0.12)
      while Date()<end {_=RunLoop.main.run(mode:.eventTracking,before:end)}
    }
    trackMenu()
    XCTAssertEqual(location.requests,2,"An open menu must not stall the location watchdog or retry")
    try await waitForReading(weather)
  }

  @MainActor func testWeatherCompletesBeforeTheInitialTrackingLoopReturns() throws {
    let restore=savePreferences();defer{restore()}
    _=NSApplication.shared
    let location=RetryLocation()
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{false},
      requestWeather:Self.trackingReading,observesNetwork:false,resolvesNames:false)
    defer{weather.stop()}
    location.onRequest={location.succeed()}
    weather.setSuspended(true);weather.setEnabled(true)
    weather.setSuspended(false)
    CFRunLoopAddCommonMode(CFRunLoopGetMain(),CFRunLoopMode(rawValue:RunLoop.Mode.eventTracking.rawValue as CFString))
    let end=Date().addingTimeInterval(0.25)
    while Date()<end && weather.current == nil {
      _=RunLoop.main.run(mode:.eventTracking,before:end)
    }
    XCTAssertNotNil(weather.current,"Weather must finish while the first menu remains open, not only after it closes")
  }

  private static func trackingReading(_:WeatherSource,_:CLLocationCoordinate2D,_:String?) async throws -> WeatherRequest.Reading {
    .openMeteo(WeatherSnapshot(time:Date().timeIntervalSince1970,weatherCode:51,
      temperature:12,windSpeed:10,windDirection:270,precipitation:0.2,isDay:1))
  }

  @MainActor func testStalledProviderIsRetriedAndItsLateResultCannotOverwriteRecovery() async throws {
    let restore=savePreferences();defer{restore()}
    let location=RetryLocation()
    var calls=0
    var stalled:CheckedContinuation<WeatherRequest.Reading,Error>?
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{false},
      requestWeather:{_,_,_ in
        calls+=1
        if calls==1 {return try await withCheckedThrowingContinuation {stalled=$0}}
        return self.reading()
      },observesNetwork:false,resolvesNames:false,
      timing:LiveWeather.Timing(requestTimeout:0.02,retryInterval:{_ in 0.005}))
    defer{stalled?.resume(throwing:CancellationError());weather.stop()}
    location.onRequest={location.succeed()}
    weather.setEnabled(true)
    try await waitForReading(weather)
    XCTAssertEqual(calls,2)
    XCTAssertEqual(weather.current?.effect,.drizzle)
    stalled?.resume(returning:reading(code:65));stalled=nil
    try await Task.sleep(nanoseconds:40_000_000)
    XCTAssertEqual(weather.current?.effect,.drizzle)
    XCTAssertEqual(calls,2)
  }

  @MainActor func testRecoveredWeatherUpdatesTheAlreadyOpenCardWithoutReopeningOrRefresh() async throws {
    let restore=savePreferences();defer{restore()}
    _=NSApplication.shared
    Preferences.liveWeather=true
    let location=RetryLocation()
    var calls=0
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{false},
      requestWeather:{_,_,_ in
        calls+=1
        if calls==1 {throw URLError(.notConnectedToInternet)}
        return self.reading()
      },observesNetwork:false,resolvesNames:false,
      timing:LiveWeather.Timing(retryInterval:{_ in 0.03}))
    let app=AppDelegate(weather:weather),item=app.makeStatusItem()
    defer{weather.stop();NSStatusBar.system.removeStatusItem(item)}
    let menu=try XCTUnwrap(item.menu)
    let details=try XCTUnwrap(menu.items.first{$0.title.hasPrefix("Local Weather")}?.submenu)
    let card=try XCTUnwrap(details.items.compactMap{$0.view as? WeatherMenuCard}.first)
    location.onRequest={location.succeed()}
    weather.setEnabled(true)
    app.menuNeedsUpdate(details)
    try await waitForReading(weather)
    func labels(_ view:NSView)->[String] {
      view.subviews.flatMap{($0 as? NSTextField).map{[$0.stringValue]} ?? labels($0)}
    }
    XCTAssertTrue(labels(card).contains(reading().snapshot.condition),"The visible weather card must update when the retry succeeds: \(labels(card))")
    XCTAssertFalse(labels(card).contains{$0.hasPrefix("Weather unavailable") || $0.contains("Retrying in")})
    XCTAssertEqual(calls,2)
    withExtendedLifetime(app) {}
  }

  @MainActor func testSuspendingCancelsPendingRetryAndResumeRecoversAutomatically() async throws {
    let restore=savePreferences();defer{restore()}
    let location=RetryLocation()
    let weather=LiveWeather(makeLocation:{location},appleAvailable:{false},
      requestWeather:{_,_,_ in self.reading()},observesNetwork:false,resolvesNames:false,
      timing:LiveWeather.Timing(retryInterval:{_ in 0.01}))
    defer{weather.stop()}
    location.onRequest={location.fail()}
    weather.setEnabled(true)
    weather.setSuspended(true)
    try await Task.sleep(nanoseconds:40_000_000)
    XCTAssertEqual(location.requests,1)
    location.onRequest={location.succeed()}
    weather.setSuspended(false)
    try await waitForReading(weather)
    XCTAssertEqual(location.requests,2)
  }
}
