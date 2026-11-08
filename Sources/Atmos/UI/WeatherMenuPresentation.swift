import Foundation

struct WeatherMenuLayer: Equatable, Identifiable {
  let effect: WeatherEffect
  let title: String
  var id: WeatherEffect { effect }
}

extension WeatherScene {
  /// Describe the scene used by rendering, including secondary atmospheric layers.
  /// Keep measurements on the details page, and collapse layers sharing one renderer.
  var menuLayers: [WeatherMenuLayer] {
    var layers: [WeatherMenuLayer] = []
    func add(_ effect: WeatherEffect, title: String? = nil) {
      guard effect != .none, !layers.contains(where: { $0.effect == effect }) else { return }
      layers.append(WeatherMenuLayer(effect: effect, title: title ?? effect.title))
    }
    let fogTitle = fogIsVisibilityDriven && fog < 0.3 ? "Haze" : fog > 0 ? "Fog" : "Mist"
    add(primary, title: primary == .clouds ? "Clouds" : primary == .mist ? fogTitle : nil)
    if (dynamics?.cloudCover ?? manualCloudCover ?? clouds) > 0 { add(.clouds, title: "Clouds") }
    if sunlight > 0.05 { add(.sunlight) }
    if fog > 0 { add(.mist, title: fogTitle) }
    if let stacked { add(stacked) }
    if let wildlife { add(wildlife) }
    return layers
  }
}

struct WeatherMenuMeasurement: Identifiable {
  let title: String
  let symbol: String
  let value: String
  var detail: String? = nil
  var id: String { title }
}

extension WeatherSnapshot {
  /// One complete set of reported scene inputs. Missing optional observations stay
  /// unknown here, rather than displaying the simulation's inferred defaults as data.
  var menuMeasurements: [WeatherMenuMeasurement] {
    let units = Preferences.weatherUnits
    let direction = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((windDirection / 45).rounded()) % 8]
    return [
      .init(title: "Temperature", symbol: "thermometer.medium", value: units.temperature(temperature)),
      .init(title: "Feels like", symbol: "person", value: apparentTemperature.map(units.temperature) ?? "—"),
      .init(title: "Wind", symbol: "wind", value: units.wind(windSpeed),
        detail: "From \(direction) · \(Int(windDirection.rounded()))°"),
      .init(title: "Gusts", symbol: "wind", value: windGust.map(units.wind) ?? "—"),
      .init(title: "Cloud cover", symbol: "cloud.fill", value: cloudCover.map { "\(Int($0.rounded()))%" } ?? "—"),
      .init(title: "Rainfall", symbol: "drop.fill", value: units.rainfall(precipitationRate)),
      .init(title: "Humidity", symbol: "humidity", value: humidity.map { "\(Int($0.rounded()))%" } ?? "—"),
      .init(title: "Visibility", symbol: "eye", value: units.visibility(visibility) ?? "—"),
    ]
  }
}
