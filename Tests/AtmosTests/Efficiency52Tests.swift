import AppKit
import CWeatherCore
import XCTest
@testable import Atmos

final class Efficiency52Tests: XCTestCase {
  func testManualSceneImmediatelyUnlocksBothControlsAndPreservesEdits() throws {
    _ = NSApplication.shared
    let defaults = UserDefaults.standard
    let keys = ["liveWeather", "manualWindSpeed", "snowfall", "weatherEffect", "seasonalDrift", "wildlifeEffect", "autumn", "reflectionConsentIdentity", "reflectionConsentVersion"]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
      }
    }
    Preferences.liveWeather = false
    Preferences.manualScene = WeatherScene(primary: .none)
    Preferences.manualWindSpeed = 42
    Preferences.reflectionConsentIdentity = Bundle.main.bundleIdentifier ?? "dev.grobb.Atmos"
    let app = AppDelegate(), item = app.makeStatusItem()
    defer { NSStatusBar.system.removeStatusItem(item) }
    let menu = try XCTUnwrap(item.menu)
    let manual = try XCTUnwrap(menu.items.first { $0.title == "Scene" || $0.title == "Manual Effects" }?.submenu)
    let wind = try XCTUnwrap(manual.items.compactMap { $0.view as? WindSlider }.first)
    let intensity = try XCTUnwrap(manual.items.compactMap { $0.view as? SnowfallSlider }.first)
    let windControl = try XCTUnwrap(wind.subviews.compactMap { $0 as? NSSlider }.first)
    let intensityControl = try XCTUnwrap(intensity.subviews.compactMap { $0 as? NSSlider }.first)
    app.menuWillOpen(menu)
    intensityControl.integerValue = Snowfall.heavy.rawValue
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(intensityControl.action), to: intensityControl.target, from: intensityControl))
    windControl.doubleValue = 63
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(windControl.action), to: windControl.target, from: windControl))
    for _ in 0..<3 {
      // Exercise automatic presentation without starting Location Services.
      Preferences.liveWeather = true
      app.menuWillOpen(menu)
      XCTAssertFalse(windControl.isEnabled)
      XCTAssertFalse(intensityControl.isEnabled)
      let option = try XCTUnwrap(menu.items.compactMap(\.submenu).flatMap(\.items).first { ($0.representedObject as? String) == WeatherEffect.rain.rawValue })
      XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(option.action), to: option.target, from: option))
      // No menu-needs-update callback: the selection itself must unlock them.
      XCTAssertFalse(Preferences.liveWeather)
      XCTAssertTrue(windControl.isEnabled)
      XCTAssertTrue(intensityControl.isEnabled)
      XCTAssertEqual(windControl.doubleValue, 63)
      XCTAssertEqual(intensityControl.integerValue, Snowfall.heavy.rawValue)
    }
    windControl.doubleValue = 27
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(windControl.action), to: windControl.target, from: windControl))
    intensityControl.integerValue = Snowfall.light.rawValue
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(intensityControl.action), to: intensityControl.target, from: intensityControl))
    XCTAssertEqual(Preferences.manualWindSpeed, 27)
    XCTAssertEqual(Preferences.snowfall, .light)
  }

  func testRustMergingMatchesPreviousMassMomentumOrderAndArea() {
    var input = [WeatherParticle]()
    for i in 0..<1400 {
      let liquid = i % 7 != 0
      input.append(WeatherParticle(rect: SIMD4(Float((i * 17) % 180) - 90 + 0.2, Float((i * 31) % 120) - 60 + 0.3, 1.1, 1.1),
        motion: SIMD4(Float(i % 100) - 50, Float(i % 83), 0.2, liquid ? 9 : 0),
        color: SIMD4(0.2, 0.3, 0.4, 0.9), life: SIMD4(1, 100, 0.08 + Float(i % 6) * 0.01, Float(i % 9) / 10)))
    }
    var expected = [WeatherParticle](), cells = [SIMD2<Int32>: Int]()
    for p in input {
      let key = SIMD2<Int32>(Int32(floor(p.rect.x / 4)), Int32(floor(p.rect.y / 4)))
      if p.motion.w == 9, let j = cells[key] {
        let mass = expected[j].life.z + p.life.z, t = p.life.z / max(0.001, mass)
        expected[j].rect.x += (p.rect.x - expected[j].rect.x) * t
        expected[j].rect.y += (p.rect.y - expected[j].rect.y) * t
        expected[j].motion.x += (p.motion.x - expected[j].motion.x) * t
        expected[j].motion.y += (p.motion.y - expected[j].motion.y) * t
        expected[j].life.z = mass; expected[j].life.w = max(expected[j].life.w, p.life.w)
        expected[j].rect.z = min(3.6, sqrt(mass) * 2.3); expected[j].rect.w = expected[j].rect.z
      } else {
        if p.motion.w == 9 { cells[key] = expected.count }
        expected.append(p)
      }
    }
    let count = input.withUnsafeMutableBufferPointer { sh_coalesce_liquid($0.baseAddress, $0.count) }
    XCTAssertEqual(count, expected.count)
    for (actual, reference) in zip(input.prefix(count), expected) {
      for (a, b) in [(actual.rect, reference.rect), (actual.motion, reference.motion), (actual.life, reference.life), (actual.color, reference.color)] {
        for axis in 0..<4 { XCTAssertEqual(a[axis], b[axis], accuracy: 0.00001) }
      }
    }
  }

  func testReleaseQueueRetainsOrderAndMassAcrossPartialDrainsAndRefills() {
    let pool = WaterSurface(id: 41, origin: .zero, width: 12000)
    for x in stride(from: Float(0), through: 12000, by: 4) { pool.hit(x: x, amount: 2, impulse: 0) }
    let original = pool.volume
    pool.releaseAll()
    XCTAssertEqual(pool.detached, original, accuracy: 0.1)
    let expected = Array(pool.releases.dropFirst(300))
    for _ in 0..<300 { pool.consumeRelease() }
    for x in stride(from: Float(0), through: 12000, by: 4) { pool.hit(x: x, amount: 1, impulse: 0) }
    let refill = pool.volume
    let retained = pool.detached
    pool.releaseAll()
    XCTAssertEqual(pool.detached, retained + refill, accuracy: 0.1)
    for (a, b) in zip(pool.releases.dropLast(), expected.dropLast()) {
      XCTAssertEqual(a.point, b.point); XCTAssertEqual(a.velocity, b.velocity); XCTAssertEqual(a.amount, b.amount)
    }
    // Keep the queue busy through several compactions instead of always draining
    // it completely. This is the long-running heavy-rain/window-motion case.
    for _ in 0..<9 {
      let next = Array(pool.releases.dropFirst(300))
      for _ in 0..<300 { pool.consumeRelease() }
      let retained = pool.detached
      for x in stride(from: Float(0), through: 1600, by: 4) { pool.hit(x: x, amount: 4, impulse: 0) }
      let added = pool.volume
      pool.releaseAll()
      XCTAssertEqual(pool.detached, retained + added, accuracy: 0.1)
      for (a, b) in zip(pool.releases.prefix(next.count), next) {
        XCTAssertEqual(a.point, b.point); XCTAssertEqual(a.amount, b.amount)
      }
    }
    while !pool.releases.isEmpty { pool.consumeRelease() }
    XCTAssertEqual(pool.detached, 0)
    pool.hit(x: 6000, amount: 2, impulse: 0); pool.releaseAll()
    XCTAssertGreaterThan(pool.releases.count, 0)
  }
}
