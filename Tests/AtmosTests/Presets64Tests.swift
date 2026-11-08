import AppKit
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import Atmos

final class Presets64Tests: XCTestCase {
  private func fixture(_ body: (UserDefaults, AtmosphereLibrary) throws -> Void) rethrows {
    let domain="Atmos.presets.\(UUID())"
    // Use an isolated persistent domain, never the user's Atmos preferences.
    let store=UserDefaults(suiteName:domain)!
    defer{store.removePersistentDomain(forName:domain)}
    try body(store,AtmosphereLibrary(defaults:store))
  }
  private func preset(_ name:String="atmos1", weather:WeatherEffect = .rain,
    drift:WeatherEffect? = .leaves, wildlife:WeatherEffect? = .birds) -> AtmospherePreset {
    AtmospherePreset(name:name,weather:weather,drift:drift,wildlife:wildlife,intensity:Snowfall.heavy.rawValue,wind:37)
  }
  func testNamesSaveRenameReloadAndDeletePreserveIndependentSnapshots() throws {
    try fixture { defaults, library in
      XCTAssertEqual(library.name,"atmos1")
      var first=preset();library.save(first)
      library.newDraft();XCTAssertEqual(library.name,"atmos2")
      let second=preset(library.name,weather:.snow,drift:nil,wildlife:.butterflies)
      library.save(second)
      first.name="Rainy afternoon";library.save(first)
      XCTAssertEqual(library.presets.count,2)
      XCTAssertEqual(library.presets.first{$0.id==second.id},second)
      let reloaded=AtmosphereLibrary(defaults:defaults)
      XCTAssertEqual(reloaded.presets.first{$0.id==first.id}?.name,"Rainy afternoon")
      XCTAssertEqual(reloaded.presets.first{$0.id==first.id}?.wind,37)
      reloaded.remove(first.id);XCTAssertNil(reloaded.selectedID)
      reloaded.newDraft();XCTAssertEqual(reloaded.name,"atmos3")
      XCTAssertEqual(reloaded.presets.map(\.id),[second.id])
    }
  }
  func testOlderPresetsRetainTheirCloudCoverageWhenUpgrading() throws {
    try fixture { defaults, library in
      var old: [[String: Any]] = []
      for effect in [WeatherEffect.rain, .clouds, .none] {
        var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset(weather: effect))) as! [String: Any]
        record.removeValue(forKey: "cloudCoverage"); old.append(record)
      }
      defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "atmospherePresets1")
      XCTAssertEqual(library.presets.map(\.cloudCoverage), [100, 65, 0])
      var customized = library.presets[0]; customized.cloudCoverage = 32; library.save(customized)
      XCTAssertEqual(library.presets.first?.cloudCoverage, 32)
    }
  }
  func testEmptyPresetsCannotBeSavedAndIconUsesWeatherThenDriftThenWildlife() {
    fixture { _, library in
      let empty=preset(weather:.none,drift:nil,wildlife:nil)
      XCTAssertFalse(empty.isValid);library.save(empty);XCTAssertTrue(library.presets.isEmpty)
      XCTAssertEqual(preset().icon,.rain)
      XCTAssertEqual(preset(weather:.none).icon,.leaves)
      XCTAssertEqual(preset(weather:.none,drift:nil,wildlife:.butterflies).icon,.butterflies)
      var invalid=preset();invalid.wind = .infinity;library.save(invalid)
      XCTAssertTrue(library.presets.isEmpty)
    }
  }
  func testFirstRenamedAtmosphereStillAdvancesTheDefaultNumber() {
    fixture { _, library in
      library.save(preset("Quiet evening"));library.newDraft()
      XCTAssertEqual(library.name,"atmos2")
    }
  }
  @MainActor func testApplyingPresetRestoresLayersIntensityWindAndDisablesLive() throws {
    _=NSApplication.shared
    let keys=["weatherEffect","seasonalDrift","wildlifeEffect","snowfall","manualWindSpeed","manualCloudCoverage","liveWeather","autumn","atmosphereDraftName","selectedAtmosphereID","atmosphereNameSequence"]
    let defaults=UserDefaults.standard,old=keys.map{defaults.object(forKey:$0)}
    defer{for (key,value) in zip(keys,old){if let value{defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}}}
    let app=AppDelegate(),item=app.makeStatusItem()
    defer{NSStatusBar.system.removeStatusItem(item);app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))}
    Preferences.liveWeather=true
    let saved=preset("My rainy day",wildlife:.butterflies)
    app.activatePreset(saved)
    XCTAssertFalse(Preferences.liveWeather)
    XCTAssertEqual(Preferences.manualScene,saved.scene)
    XCTAssertEqual(Preferences.snowfall,.heavy);XCTAssertEqual(Preferences.manualWindSpeed,37)
    XCTAssertEqual(AtmosphereLibrary.shared.name,saved.name)
    XCTAssertEqual(AtmosphereLibrary.shared.selectedID,saved.id)
    let model=AtmosMenuModel(menu:try XCTUnwrap(item.menu))
    XCTAssertTrue(model.canSave)
    Preferences.manualScene=WeatherScene(primary:.none)
    XCTAssertFalse(model.canSave)
  }
  @MainActor func testKitPermissionProofRecoversAStalePreflightWithoutStartingCapture() async throws {
    var calls=0
    let access=ScreenshotAccess(preflight:{false},probe:{calls+=1})
    XCTAssertFalse(access.isGranted);XCTAssertEqual(calls,0)
    access.recheck();access.recheck()
    for _ in 0..<100 {
      if access.state != .checking {break}
      try await Task.sleep(nanoseconds:1_000_000)
    }
    XCTAssertTrue(access.isGranted);XCTAssertEqual(access.state,.granted);XCTAssertEqual(calls,1)
    access.invalidateIfDenied(NSError(domain:SCStreamErrorDomain,code:SCStreamError.userDeclined.rawValue))
    XCTAssertFalse(access.isGranted);XCTAssertEqual(access.state,.authorizationNeeded)
  }
  @MainActor func testPermissionProbeFailureDoesNotClaimAccess() async throws {
    let access=ScreenshotAccess(preflight:{false},probe:{throw URLError(.noPermissionsToReadFile)})
    access.recheck()
    for _ in 0..<100 {
      if access.state != .checking {break}
      try await Task.sleep(nanoseconds:1_000_000)
    }
    XCTAssertFalse(access.isGranted);XCTAssertEqual(access.state,.authorizationNeeded)
  }
  @MainActor func testButterflyArtworkExistsWithoutAnSFSymbol() throws {
    let image=try XCTUnwrap(EffectArtwork.image(for:.butterflies))
    XCTAssertTrue(image.isTemplate)
    let bitmap=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation)))
    var filled=0
    for x in 0..<bitmap.pixelsWide {for y in 0..<bitmap.pixelsHigh {
      if (bitmap.colorAt(x:x,y:y)?.alphaComponent ?? 0)>0.5 {filled+=1}
    }}
    XCTAssertGreaterThan(filled,100)
    XCTAssertEqual(EffectArtwork.statusImage(for:.butterflies)?.size,NSSize(width:18,height:18))
  }
}
