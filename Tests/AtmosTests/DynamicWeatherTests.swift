import XCTest
import simd

@testable import Atmos

final class DynamicWeatherTests: XCTestCase {
  private func reading(code: Int = 51, rate: Double = 0.2, day: Int = 1) -> WeatherSnapshot {
    var result = WeatherSnapshot(
      time: Date().timeIntervalSince1970, weatherCode: code,
      temperature: 20, windSpeed: 16, windDirection: 270, precipitation: rate, isDay: day)
    result.precipitationUnit = "mm/h"
    result.cloudCover = 99
    result.humidity = 85
    result.apparentTemperature = 18
    return result
  }

  func testManualLayersToggleIndependentlyIncludingWeatherOff() {
    var scene = WeatherScene(primary: .rain, stacked: .cherryBlossoms, wildlife: .birds)
    scene.toggleManual(.rain)
    XCTAssertEqual(scene.primary, .none)
    XCTAssertEqual(scene.stacked, .cherryBlossoms)
    XCTAssertEqual(scene.wildlife, .birds)
    scene.toggleManual(.cherryBlossoms)
    XCTAssertNil(scene.stacked)
    XCTAssertEqual(scene.wildlife, .birds)
    scene.toggleManual(.birds)
    XCTAssertNil(scene.wildlife)
    scene.toggleManual(.snow)
    scene.toggleManual(.mapleSeeds)
    scene.toggleManual(.butterflies)
    XCTAssertEqual(scene.primary, .snow)
    XCTAssertEqual(scene.stacked, .mapleSeeds)
    XCTAssertEqual(scene.wildlife, .butterflies)
    XCTAssertEqual(WeatherEffect.seasonal.count, 6)
  }

  func testProviderRatesNormalizeAndRejectInvalidIntervalsAndGusts() throws {
    var meteo = reading(rate: 0.3)
    meteo.precipitationUnit = "mm"
    meteo.interval = 900
    XCTAssertEqual(meteo.precipitationRate, 1.2, accuracy: 0.001)
    meteo.interval = 1800
    XCTAssertEqual(meteo.precipitationRate, 0.6, accuracy: 0.001)
    meteo.interval = 0
    XCTAssertFalse(meteo.isUsable())
    meteo.interval = 900
    meteo.windGust = .nan
    XCTAssertFalse(meteo.isUsable())
    let data = Data(
      """
      {"current":{"time":\(Int(Date().timeIntervalSince1970)),"interval":900,"weather_code":51,
      "temperature_2m":12,"wind_speed_10m":10,"wind_gusts_10m":25,"wind_direction_10m":90,
      "precipitation":0.3,"is_day":1}}
      """.utf8)
    let decoded = try JSONDecoder().decode(WeatherAPI.Response.self, from: data).current
    XCTAssertEqual(decoded.precipitationRate, 1.2, accuracy: 0.001)
    XCTAssertEqual(decoded.windGust, 25)
  }

  func testNinetyNinePercentCloudWithDrizzleKeepsBothMeasurements() {
    let scene = WeatherScene(weather: reading())
    XCTAssertEqual(scene.primary, .drizzle)
    XCTAssertEqual(scene.clouds, 0.99, accuracy: 0.0001)
    XCTAssertEqual(scene.dynamics?.cloudCover ?? 0, 0.99, accuracy: 0.0001)
    let a = WeatherDynamics(weather: reading(rate: 0.21))
    let b = WeatherDynamics(weather: reading(rate: 0.31))
    XCTAssertGreaterThan(b.precipitationStrength, a.precipitationStrength)
    XCTAssertGreaterThan(b.fallSpeed, a.fallSpeed)
    let simulation = WeatherSimulation(size: SIMD2(1000, 800), seed: 12)
    simulation.setEffect(.drizzle)
    simulation.scene = scene
    for _ in 0..<300 { simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000)) }
    XCTAssertTrue(simulation.decorations.contains { $0.motion.w == 12 })
    XCTAssertTrue(simulation.particles.contains { $0.motion.w == 0 })
    simulation.scene = WeatherScene(weather: reading(rate: 1))
    let initial = simulation.dynamics!.precipitationStrength
    simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
    XCTAssertGreaterThan(simulation.dynamics!.precipitationStrength, initial)
    XCTAssertLessThan(
      simulation.dynamics!.precipitationStrength, simulation.scene.dynamics!.precipitationStrength)
  }

  func testAllSeasonalMaterialAndWildlifeHaveSpellsAndLullsInBothHemispheres() throws {
    let calendar = Calendar(identifier: .gregorian)
    for latitude in [51.0, -34.0] {
      var observed = Set<WeatherEffect>()
      var wildlife = Set<WeatherEffect>()
      var lulls = 0
      for month in 1...12 {
        let start = try XCTUnwrap(
          calendar.date(from: DateComponents(year: 2026, month: month, day: 15)))
        for seconds in stride(from: 0, to: 7200, by: 15) {
          for day in [0, 1] {
            var weather = reading(code: 1, rate: 0, day: day)
            weather.latitude = latitude
            let overlay = SeasonalWeather.overlays(
              weather: weather, date: start.addingTimeInterval(Double(seconds)))
            if let material = overlay.material { observed.insert(material) } else { lulls += 1 }
            if let animal = overlay.wildlife { wildlife.insert(animal) }
          }
        }
      }
      XCTAssertEqual(observed, Set(WeatherEffect.seasonal))
      XCTAssertEqual(wildlife, Set(WeatherEffect.wildlife))
      XCTAssertGreaterThan(lulls, 100)
    }
    let storm = SeasonalWeather.overlays(weather: reading(code: 95, rate: 10), date: Date())
    XCTAssertNil(storm.material)
    XCTAssertNil(storm.wildlife)
    let cold = WeatherSnapshot(
      time: Date().timeIntervalSince1970, weatherCode: 0,
      temperature: -4, windSpeed: 10, windDirection: 90, precipitation: 0, isDay: 0)
    XCTAssertNil(SeasonalWeather.overlays(weather: cold, date: Date()).wildlife)
  }

  func testCompassDirectionReversesWindAndWindowsShelterTheirLee() {
    let weather = reading()
    let north = WeatherDynamics(weather: weather)
    var easterly = weather
    easterly = WeatherSnapshot(
      time: weather.time, weatherCode: 51, temperature: 20, windSpeed: weather.windSpeed,
      windDirection: 90, precipitation: 0.2, isDay: 1)
    let south = WeatherDynamics(weather: easterly)
    XCTAssertGreaterThan(north.wind, 0)
    XCTAssertEqual(north.wind, -south.wind, accuracy: 0.001)
    let field = WindField()
    field.update(
      size: SIMD2(1000, 700), windows: [SIMD4(200, 100, 400, 500)], wind: 100, turbulence: 10,
      time: 1)
    XCTAssertLessThan(field.sample(SIMD2(450, 300)).x, field.sample(SIMD2(150, 300)).x * 0.7)
    let before = field.sample(SIMD2(450, 500))
    field.update(
      size: SIMD2(1000, 700), windows: [SIMD4(200, 100, 400, 500)], wind: 100, turbulence: 10,
      time: 2)
    XCTAssertNotEqual(before, field.sample(SIMD2(450, 500)))
    XCTAssertTrue(field.cells.allSatisfy { $0.x.isFinite && $0.y.isFinite })
  }

  func testPuddleRecoversFromSweepWithoutLosingWater() {
    let water = WaterSurface(id: 0, origin: .zero, width: 800)
    for x in stride(from: Float(0), through: 800, by: 4) { water.hit(x: x, amount: 8, impulse: 0) }
    for _ in 0..<60 { water.step(dt: 1 / 120, evaporates: false, clearing: false) }
    let volume = water.volume
    let initial = water.depths[100]
    for _ in 0..<6 { water.sweep(x: 400, velocity: 1500, dt: 1 / 120) }
    let disturbed = abs(water.depths[100] - initial)
    XCTAssertGreaterThan(disturbed, 0.2)
    for _ in 0..<120 { water.step(dt: 1 / 120, evaporates: false, clearing: false) }
    XCTAssertLessThan(abs(water.depths[100] - initial), disturbed * 0.35)
    XCTAssertEqual(water.volume + water.detached, volume, accuracy: 0.02)
  }

  func testBirdsLandOnWindowsAndTakeOffWhenSupportDisappears() {
    let flock = BirdFlock(seed:42)
    let window = WindowSurface(
      id: 1, frame: CGRect(x: 200, y: 100, width: 500, height: 250),
      blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
    var landed = false
    for _ in 0..<2400 {
      flock.step(
        dt: 1 / 120, size: SIMD2(1000, 700), surfaces: [window], wind: 10,
        airflow: nil, cursor: SIMD2(-1000, -1000), active: true, reducedMotion: false)
      landed = landed || flock.perchedCount > 0
    }
    XCTAssertTrue(landed)
    for _ in 0..<60 {
      flock.step(
        dt: 1 / 120, size: SIMD2(1000, 700), surfaces: [], wind: 10,
        airflow: nil, cursor: SIMD2(-1000, -1000), active: false, reducedMotion: false)
    }
    XCTAssertEqual(flock.perchedCount, 0)
    XCTAssertLessThanOrEqual(flock.particles.count, 10)
  }

  func testFullscreenGeometryFallbackHandlesIntelLayoutsSplitViewAndExternalScreens() {
    for screen in [
      CGRect(x: 0, y: 0, width: 1440, height: 900),
      CGRect(x: -1920, y: 200, width: 1920, height: 1080),
    ] {
      XCTAssertTrue(FullScreenDetection.coversDisplay(screen, windows: [screen]))
      XCTAssertFalse(
        FullScreenDetection.coversDisplay(
          screen,
          windows: [
            CGRect(
              x: screen.minX, y: screen.minY + 24, width: screen.width, height: screen.height - 80)
          ]))
      let left = CGRect(
        x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
      let right = CGRect(
        x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
      XCTAssertTrue(FullScreenDetection.coversDisplay(screen, windows: [left, right]))
      XCTAssertFalse(FullScreenDetection.coversDisplay(screen, windows: [left]))
    }
  }
}
