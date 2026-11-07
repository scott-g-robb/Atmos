import AppKit
import CoreLocation
import XCTest
@testable import Atmos

private final class LocationCounts {
  private let lock=NSLock()
  private var count=0
  var requests:Int {lock.lock();defer{lock.unlock()};return count}
  func requested(){lock.lock();count+=1;lock.unlock()}
}

/// Models a location framework callback bound to the manager's default run loop.
private final class DefaultModeLocations: WeatherLocationClient {
  weak var delegate: CLLocationManagerDelegate?
  let authorizationStatus:CLAuthorizationStatus
  private let sender=CLLocationManager()
  private let counts:LocationCounts
  private let delay:Double
  private var timer:Timer?
  init(counts:LocationCounts,delay:Double=0.02,authorization:CLAuthorizationStatus = .authorizedAlways) {
    self.counts=counts;self.delay=delay;authorizationStatus=authorization
  }
  func requestWhenInUseAuthorization(){XCTFail("Tests must not request actual permissions")}
  func requestLocation(){
    counts.requested()
    timer=Timer.scheduledTimer(withTimeInterval:delay,repeats:false){[weak self] _ in
      guard let self else{return}
      delegate?.locationManager?(sender,didUpdateLocations:[CLLocation(
        coordinate:CLLocationCoordinate2D(latitude:0,longitude:0),altitude:0,
        horizontalAccuracy:5,verticalAccuracy:5,timestamp:Date())])
      timer=nil
    }
  }
  func stopUpdatingLocation(){timer?.invalidate();timer=nil}
}

final class WeatherSetup62Tests:XCTestCase {
  private func savePreferences()->()->Void {
    let store=UserDefaults.standard
    let keys=["weatherSource","liveWeather","completedSetupRelease","completedSetupInstallation",
      "welcomed","automaticUpdates","screenReflections","fogBloom"]
    let values=keys.map{store.object(forKey:$0)}
    Preferences.weatherSource = .automatic;Preferences.liveWeather=false
    Preferences.automaticUpdates=false;Preferences.screenReflections=false;Preferences.fogBloom=false
    return {for(key,value) in zip(keys,values) {
      if let value {store.set(value,forKey:key)}else{store.removeObject(forKey:key)}
    }}
  }
  private static func reading(_:WeatherSource,_:CLLocationCoordinate2D,_:String?) async throws -> WeatherRequest.Reading {
    .openMeteo(snapshot())
  }
  private static func snapshot()->WeatherSnapshot {
    WeatherSnapshot(time:Date().timeIntervalSince1970,weatherCode:51,temperature:12,
      windSpeed:10,windDirection:270,precipitation:0.2,isDay:1)
  }
  private static func apple()->AppleWeather.Reading {
    AppleWeather.Reading(snapshot:snapshot(),attribution:AppleWeather.Attribution(
      combinedMarkDarkURL:URL(fileURLWithPath:"/no-attribution-image"),
      legalPageURL:URL(string:"https://developer.apple.com/weatherkit/data-source-attribution/")!))
  }
  @MainActor private func trackMenu(for duration:Double,until ready:()->Bool = {false}) {
    CFRunLoopAddCommonMode(CFRunLoopGetMain(),CFRunLoopMode(rawValue:RunLoop.Mode.eventTracking.rawValue as CFString))
    let end=Date().addingTimeInterval(duration)
    while Date()<end && !ready(){_=RunLoop.main.run(mode:.eventTracking,before:end)}
  }
  @MainActor private func settle(_ duration:Double){RunLoop.main.run(until:Date().addingTimeInterval(duration))}
  @MainActor private func page() throws -> SetupPageView {
    try XCTUnwrap(NSApp.windows.first{$0.isVisible && $0.contentView is SetupPageView}?.contentView as? SetupPageView)
  }
  @MainActor private func showSetup(_ app:AppDelegate,menu:NSMenu) throws {
    let settings=try XCTUnwrap(menu.items.first{$0.title=="Settings"}?.submenu)
    let show=try XCTUnwrap(settings.items.first{$0.title=="Show Setup…"})
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(show.action),to:app,from:show))
    settle(0.05)
    try page().next.performClick(nil);settle(0.3)
  }

  @MainActor func testLocationDefaultModeStallIsBridgedWhileMenuRemainsOpen() throws {
    let restore=savePreferences();defer{restore()}
    _=NSApplication.shared
    let directCounts=LocationCounts()
    let direct=LiveWeather(makeLocation:{DefaultModeLocations(counts:directCounts)},
      appleAvailable:{false},requestWeather:Self.reading,observesNetwork:false,resolvesNames:false)
    direct.setEnabled(true)
    trackMenu(for:0.08)
    XCTAssertNil(direct.current,"A manager on the tracking main run loop reproduces the stuck finding state")
    direct.stop()
    let bridgedCounts=LocationCounts()
    let bridged=LiveWeather(makeLocation:{
      WeatherLocationManager(initialAuthorization:.authorizedAlways,makeManager:{DefaultModeLocations(counts:bridgedCounts)})
    },appleAvailable:{false},requestWeather:Self.reading,observesNetwork:false,resolvesNames:false)
    defer{bridged.stop()}
    bridged.setEnabled(true)
    trackMenu(for:0.5,until:{bridged.current != nil})
    XCTAssertNotNil(bridged.current,"The worker must deliver location and weather before the menu closes")
    XCTAssertEqual(bridgedCounts.requests,1)
  }

  @MainActor func testPermissionsNextPreparesWeatherAndIconActivatesWithoutASecondRequest() throws {
    let restore=savePreferences();defer{restore()}
    _=NSApplication.shared
    let counts=LocationCounts()
    let weather=LiveWeather(makeLocation:{
      WeatherLocationManager(initialAuthorization:.authorizedAlways,makeManager:{DefaultModeLocations(counts:counts)})
    },appleAvailable:{false},requestWeather:Self.reading,observesNetwork:false,resolvesNames:false)
    let app=AppDelegate(weather:weather),item=app.makeStatusItem()
    defer{app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification));NSStatusBar.system.removeStatusItem(item)}
    let menu=try XCTUnwrap(item.menu)
    try showSetup(app,menu:menu)
    XCTAssertEqual(counts.requests,0)
    try page().next.performClick(nil)
    settle(0.45)
    XCTAssertNotNil(weather.current,"Leaving Permissions must prepare the first reading during the guide")
    XCTAssertFalse(Preferences.liveWeather,"The visible live scene stays paused until the icon is opened")
    let prepared=weather.updatedAt
    app.menuWillOpen(menu)
    XCTAssertTrue(Preferences.liveWeather)
    XCTAssertFalse(weather.isSuspended)
    XCTAssertEqual(weather.updatedAt,prepared)
    XCTAssertEqual(counts.requests,1,"Activating prepared data must not restart location")
    withExtendedLifetime(app){}
  }

  @MainActor func testEarlyIconClickPreservesTheInFlightPreparationWhileMenuTracks() throws {
    let restore=savePreferences();defer{restore()}
    _=NSApplication.shared
    let counts=LocationCounts()
    let weather=LiveWeather(makeLocation:{
      WeatherLocationManager(initialAuthorization:.authorizedAlways,makeManager:{DefaultModeLocations(counts:counts,delay:0.2)})
    },appleAvailable:{false},requestWeather:Self.reading,observesNetwork:false,resolvesNames:false)
    let app=AppDelegate(weather:weather),item=app.makeStatusItem()
    defer{app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification));NSStatusBar.system.removeStatusItem(item)}
    let menu=try XCTUnwrap(item.menu)
    try showSetup(app,menu:menu)
    try page().next.performClick(nil)
    XCTAssertTrue(weather.isLocating)
    app.menuWillOpen(menu)
    trackMenu(for:0.7,until:{weather.current != nil})
    XCTAssertNotNil(weather.current,"An immediate icon click must not postpone the callback until menu close")
    XCTAssertEqual(counts.requests,1)
    withExtendedLifetime(app){}
  }

  @MainActor func testPermissionsNextWithoutLocationDoesNotPrepareOrEnableLiveWeather() throws {
    let restore=savePreferences();defer{restore()}
    _=NSApplication.shared
    let counts=LocationCounts()
    let weather=LiveWeather(makeLocation:{
      WeatherLocationManager(initialAuthorization:.denied,makeManager:{DefaultModeLocations(counts:counts,authorization:.denied)})
    },appleAvailable:{false},requestWeather:Self.reading,observesNetwork:false,resolvesNames:false)
    let app=AppDelegate(weather:weather),item=app.makeStatusItem()
    defer{app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification));NSStatusBar.system.removeStatusItem(item)}
    let menu=try XCTUnwrap(item.menu)
    try showSetup(app,menu:menu)
    try page().next.performClick(nil);settle(0.4)
    XCTAssertFalse(weather.enabled);XCTAssertEqual(counts.requests,0)
    app.menuWillOpen(menu)
    XCTAssertFalse(Preferences.liveWeather);XCTAssertEqual(counts.requests,0)
    withExtendedLifetime(app){}
  }

  func testAppleRetryThenFallbackAndTheNextAutomaticCycleStartsWithApple() async throws {
    var appleCalls=0,meteoCalls=0
    let fallback=try await WeatherRequest.fetch(source:.automatic,appleAvailable:true,retryDelay:0.01,
      apple:{appleCalls+=1;throw URLError(.badServerResponse)},
      openMeteo:{meteoCalls+=1;return Self.snapshot()})
    guard case .openMeteo = fallback else{return XCTFail("Two failed Apple attempts must use fallback")}
    XCTAssertEqual(appleCalls,2);XCTAssertEqual(meteoCalls,1)
    let next=try await WeatherRequest.fetch(source:.automatic,appleAvailable:true,retryDelay:0,
      apple:{appleCalls+=1;return Self.apple()},openMeteo:{meteoCalls+=1;return Self.snapshot()})
    guard case .apple = next else{return XCTFail("Fallback must not pin the next refresh to Open-Meteo")}
    XCTAssertEqual(appleCalls,3);XCTAssertEqual(meteoCalls,1)
  }

  func testHungAppleAttemptsReachFallbackEvenIfTheSDKIgnoresCancellation() async throws {
    let pending=PendingApple()
    defer{pending.cancel()}
    let began=Date()
    let result=try await WeatherRequest.fetch(source:.apple,appleAvailable:true,retryDelay:0.01,attemptTimeout:0.02,
      apple:{try await withCheckedThrowingContinuation{pending.add($0)}},openMeteo:{Self.snapshot()})
    guard case .openMeteo = result else{return XCTFail("A hung Apple operation must not prevent fallback")}
    XCTAssertEqual(pending.count,2)
    XCTAssertLessThan(Date().timeIntervalSince(began),0.4)
  }

  func testCancellingAHungAppleRequestDoesNotStartFallback() async throws {
    let pending=PendingApple(),fallback=LocationCounts()
    defer{pending.cancel()}
    let request=Task {
      try await WeatherRequest.fetch(source:.automatic,appleAvailable:true,retryDelay:0.01,attemptTimeout:10,
        apple:{try await withCheckedThrowingContinuation{pending.add($0)}},
        openMeteo:{fallback.requested();return Self.snapshot()})
    }
    for _ in 0..<100 {
      if pending.count>0 {break}
      try await Task.sleep(nanoseconds:1_000_000)
    }
    XCTAssertEqual(pending.count,1)
    request.cancel()
    do {_=try await request.value;XCTFail("Cancellation must end the provider chain")}
    catch is CancellationError {}
    catch {XCTFail("Expected cancellation, received \(error)")}
    XCTAssertEqual(fallback.requests,0)
  }
}

private final class PendingApple {
  private let lock=NSLock()
  private var continuations=[CheckedContinuation<AppleWeather.Reading,Error>]()
  var count:Int {lock.lock();defer{lock.unlock()};return continuations.count}
  func add(_ continuation:CheckedContinuation<AppleWeather.Reading,Error>){lock.lock();continuations.append(continuation);lock.unlock()}
  func cancel(){
    lock.lock();let pending=continuations;continuations.removeAll();lock.unlock()
    for continuation in pending {continuation.resume(throwing:CancellationError())}
  }
}
