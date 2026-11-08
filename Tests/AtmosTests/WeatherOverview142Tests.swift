import AppKit
import XCTest
@testable import Atmos

final class WeatherOverview142Tests: XCTestCase {
  private func reading() -> WeatherSnapshot {
    var w = WeatherSnapshot(time: Date().timeIntervalSince1970, weatherCode: 2,
      temperature: 7, windSpeed: 8, windDirection: 270, precipitation: 0.2, isDay: 1)
    w.cloudCover = 58; w.apparentTemperature = 6; w.humidity = 86
    w.windGust = 16; w.visibility = 8_000; w.precipitationUnit = "mm/h"
    return w
  }
  func testOverviewUsesTheActualCombinedSceneRatherThanTheConditionAlone() {
    let model = AtmosMenuModel(menu: NSMenu())
    model.reading = reading() // The report itself is partly cloudy.
    var scene = WeatherScene(primary: .rain, stacked: .mapleSeeds, wildlife: .birds)
    scene.dynamics = WeatherDynamics(weather: reading())
    scene.fog = 0.72 // An active fog/rain warning can augment the report.
    model.activeScene = scene
    XCTAssertEqual(model.activeLayers.map(\.effect), [.rain, .clouds, .mist, .mapleSeeds, .birds])
    XCTAssertEqual(model.activeLayers.map(\.title), ["Rain", "Clouds", "Fog", "Maple Seeds", "Birds"])
    scene.fog = 0.12; scene.fogIsVisibilityDriven = true
    model.activeScene = scene
    XCTAssertEqual(model.activeLayers.first { $0.effect == .mist }?.title, "Haze")
  }
  func testAtmosphericLayersAreNotDuplicatedAndClearScenesDoNotInventEffects() {
    var fog = WeatherScene(primary: .mist)
    fog.fog = 0.72; fog.clouds = 0.58
    XCTAssertEqual(fog.menuLayers.map(\.effect), [.mist, .clouds])
    var clouds = WeatherScene(primary: .clouds)
    clouds.clouds = 1
    XCTAssertEqual(clouds.menuLayers.map(\.effect), [.clouds])
    XCTAssertTrue(WeatherScene(primary: .none).menuLayers.isEmpty)
    var sun = WeatherScene(primary: .sunlight)
    sun.sunlight = 1
    XCTAssertEqual(sun.menuLayers.map(\.effect), [.sunlight])
  }
  func testDetailsKeepAllMeasurementsTogetherWithoutInventingOptionalReadings() throws {
    let previous = UserDefaults.standard.object(forKey: "weatherUnits")
    defer { if let previous { UserDefaults.standard.set(previous, forKey: "weatherUnits") } else { UserDefaults.standard.removeObject(forKey: "weatherUnits") } }
    Preferences.weatherUnits = .metric
    var w = reading()
    let measurements = Dictionary(uniqueKeysWithValues: w.menuMeasurements.map { ($0.title, $0) })
    XCTAssertEqual(Set(measurements.keys), ["Temperature", "Feels like", "Wind", "Gusts", "Cloud cover", "Rainfall", "Humidity", "Visibility"])
    XCTAssertEqual(measurements["Temperature"]?.value, "7°C")
    XCTAssertEqual(measurements["Wind"]?.detail, "From W · 270°")
    XCTAssertEqual(measurements["Gusts"]?.value, "16 km/h")
    XCTAssertEqual(measurements["Rainfall"]?.value, "0.2 mm/h")
    XCTAssertEqual(measurements["Visibility"]?.value, "8.0 km")
    w.cloudCover = nil; w.apparentTemperature = nil; w.humidity = nil
    w.windGust = nil; w.visibility = nil
    let missing = w.menuMeasurements.filter { ["Cloud cover", "Feels like", "Humidity", "Gusts", "Visibility"].contains($0.title) }
    XCTAssertEqual(missing.count, 5)
    XCTAssertTrue(missing.allSatisfy { $0.value == "—" })
    let north = WeatherSnapshot(time: w.time, weatherCode: w.weatherCode,
      temperature: w.temperature, windSpeed: w.windSpeed, windDirection: 360,
      precipitation: w.precipitation, isDay: w.isDay)
    XCTAssertEqual(north.menuMeasurements.first { $0.title == "Wind" }?.detail, "From N · 360°")
  }
}
