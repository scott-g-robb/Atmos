import AppKit
import SwiftUI
import XCTest
@testable import Aeolian

final class QuickSwitch65Tests: XCTestCase {
  private let away = SIMD2<Float>(-1000, -1000)
  func testPrecipitationSourcesUseTheScreenTopAtAllCloudDepths() throws {
    for load: Float in [0, 0.3, 1] {
      var sky = CloudSky()
      for _ in 0..<600 { sky.step(size: SIMD2(960, 572), cover: 0.5, rainLoad: load, wind: 0, dt: 0.05, active: true, clearing: false) }
      for index in 0..<100 {
        let source = try XCTUnwrap(sky.rainSource(Float(index)/100))
        XCTAssertTrue(sky.contains(x: source.x))
        XCTAssertEqual(source.y, 575)
        XCTAssertGreaterThan(source.y, try XCTUnwrap(sky.bottom(at: source.x)))
      }
    }
  }
  func testPrecipitationHitsWindowsInsideTheCloudLayer() throws {
    let top: Float = 550
    let window = WindowSurface(id: 65, frame: CGRect(x: 0, y: 100, width: 960, height: 450), blockers: [], cornerRadius: 12, cornerExponent: 2.5, isDock: false)
    for effect in [WeatherEffect.rain, .drizzle, .storm, .sleet, .hail] {
      let sim = WeatherSimulation(size: SIMD2(960, 600), seed: 65)
      sim.setEffect(effect); sim.skyCeiling = 572; sim.intensity = .heavy
      sim.updateWindows([window])
      var highBounce = false
      for _ in 0..<720 {
        sim.step(dt: 1/120, cursor: away)
        if effect == .hail {
          highBounce = highBounce || sim.particles.contains { $0.motion.w == 1 && $0.rect.y >= top && $0.motion.y > 0 }
        }
      }
      XCTAssertLessThan(try XCTUnwrap(sim.sky.bottom(at: 480)), top)
      if effect == .hail { XCTAssertTrue(highBounce, "Hail must bounce off high ledges") }
      else { XCTAssertGreaterThan(try XCTUnwrap(sim.water.first { $0.id == 65 }).volume, 0.1, effect.title) }
    }
  }
  @MainActor private func savePreferences() -> () -> Void {
    let defaults = UserDefaults.standard
    let keys = ["liveWeather", "weatherEffect", "seasonalDrift", "wildlifeEffect", "manualWindSpeed", "manualCloudCoverage", "snowfall", "autumn", "atmospherePresets1", "atmosphereDraftName", "atmosphereNameSequence", "selectedAtmosphereID"]
    let values = keys.map { defaults.object(forKey: $0) }
    for key in keys { defaults.removeObject(forKey: key) }
    Preferences.liveWeather = false; Preferences.manualScene = WeatherScene(primary: .none)
    return { for (key, value) in zip(keys, values) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
  }
  @MainActor private func settle(_ seconds: Double = 0.08) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
  @MainActor func testRootPresetSwitchingArrowEditDeleteAndEmptyFallback() throws {
    _ = NSApplication.shared
    let restore = savePreferences(); defer { restore() }
    let first = AtmospherePreset(name: "atmos1", weather: .rain, drift: .leaves, wildlife: .birds, intensity: 2, wind: 12)
    let second = AtmospherePreset(name: "atmos2", weather: .none, drift: .cherryBlossoms, wildlife: .butterflies, intensity: 1, wind: 7)
    AtmosphereLibrary.shared.save(first); AtmosphereLibrary.shared.save(second)
    let app = AppDelegate(), item = app.makeStatusItem()
    let controller = try XCTUnwrap(app.installCustomMenu())
    defer { controller.close(); app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); NSStatusBar.system.removeStatusItem(item) }
    controller.show(from: try XCTUnwrap(item.button)); settle()
    let model = controller.model
    XCTAssertEqual(model.navigation.page, "", "Existing presets open directly in My atmosphere")
    model.switchPreset(first)
    XCTAssertEqual(Preferences.manualScene, first.scene)
    XCTAssertEqual(model.navigation.page, "", "Switching stays on the quick list")
    model.togglePresetOptions(second.id)
    XCTAssertEqual(model.navigation.expandedPreset, second.id)
    model.editPreset(second)
    XCTAssertEqual(model.navigation.page, "manual")
    XCTAssertNil(model.navigation.expandedPreset)
    XCTAssertEqual(Preferences.manualScene, second.scene)
    model.savePreset(name: "Spring evening")
    XCTAssertEqual(model.navigation.page, "")
    XCTAssertEqual(AtmosphereLibrary.shared.presets.first { $0.id == second.id }?.name, "Spring evening")
    model.removePreset(first.id)
    XCTAssertEqual(AtmosphereLibrary.shared.presets.map(\.id), [second.id])
    model.createPresetForEditing()
    XCTAssertEqual(model.navigation.page, "manual")
    XCTAssertEqual(Preferences.manualScene.primary, .none)
    XCTAssertNil(Preferences.manualScene.stacked); XCTAssertNil(Preferences.manualScene.wildlife)
    XCTAssertEqual(Preferences.manualWindSpeed, 4); XCTAssertEqual(Preferences.snowfall, .steady)
    XCTAssertEqual(Preferences.manualCloudCoverage, 0)
    XCTAssertFalse(model.canSave)
    model.removePreset(second.id)
    XCTAssertTrue(AtmosphereLibrary.shared.presets.isEmpty)
    XCTAssertEqual(model.navigation.page, "", "No presets shows the creation form directly in My atmosphere")
  }

  @MainActor func testAdvancedCloudCoverageOverridesAndPersistsWithThePreset() throws {
    _ = NSApplication.shared
    let restore = savePreferences(); defer { restore() }
    let app = AppDelegate(), item = app.makeStatusItem()
    let controller = try XCTUnwrap(app.installCustomMenu())
    defer { controller.close(); app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); NSStatusBar.system.removeStatusItem(item) }
    controller.show(from: try XCTUnwrap(item.button)); settle()
    let model = controller.model
    XCTAssertEqual(Preferences.manualWindSpeed, 4)
    XCTAssertEqual(Preferences.snowfall, .steady)
    XCTAssertEqual(Preferences.manualCloudCoverage, 0)
    model.invoke(try XCTUnwrap(model.effect(.rain)))
    XCTAssertEqual(Preferences.manualCloudCoverage, 100)
    model.cloudCoverageChanged(32)
    model.savePreset(name: "Broken clouds")
    let preset = try XCTUnwrap(model.library.presets.first)
    XCTAssertEqual(preset.cloudCoverage, 32)
    model.createPresetForEditing()
    XCTAssertEqual(Preferences.manualCloudCoverage, 0)
    model.switchPreset(preset)
    XCTAssertEqual(Preferences.manualCloudCoverage, 32)
    let sim = WeatherSimulation(size: SIMD2(960, 600), seed: 65)
    sim.setEffect(.rain); sim.scene = preset.scene
    for _ in 0..<600 { sim.step(dt: 1/60, cursor: away) }
    XCTAssertEqual(sim.sky.occupiedWidth/960, 0.32, accuracy: 0.002)
  }
  @MainActor func testWeatherArrivalAnimatesInsideAFixedDropdownFrame() throws {
    _ = NSApplication.shared
    let restore = savePreferences(); defer { restore() }
    Preferences.liveWeather = true
    let app = AppDelegate(), item = app.makeStatusItem()
    let model = AeolianMenuModel(menu: try XCTUnwrap(item.menu))
    let view = NSHostingView(rootView: AeolianMenuView(model: model).frame(width: 320, height: 520))
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 320, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view; window.orderFront(nil); settle(0.2)
    defer { window.orderOut(nil); window.contentView = nil; NSStatusBar.system.removeStatusItem(item) }
    let frame = window.frame
    func bitmap() throws -> Data {
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    model.objectWillChange.send()
    model.reading = WeatherSnapshot(time: Date().timeIntervalSince1970, weatherCode: 63, temperature: 8, windSpeed: 12, windDirection: 270, precipitation: 1, isDay: 1)
    model.place = "Hounslow"
    settle(0.07); let early = try bitmap()
    settle(0.55); let final = try bitmap()
    XCTAssertEqual(window.frame, frame)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      XCTAssertNotEqual(early, final, "The loading-to-reading transition must have intermediate frames")
    }
    if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
      try early.write(to: URL(fileURLWithPath: output).appendingPathComponent("weather-arrival-early.png"))
      try final.write(to: URL(fileURLWithPath: output).appendingPathComponent("weather-arrival-final.png"))
    }
  }
}
