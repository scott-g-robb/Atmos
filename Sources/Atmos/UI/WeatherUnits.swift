import Foundation

/// Display conversions only. Provider observations, presets and simulation remain
/// in Celsius, km/h, millimetres and metres regardless of this preference.
enum WeatherUnits: String, CaseIterable {
  case metric, imperial
  var title: String { self == .metric ? "Metric (°C, km/h)" : "Imperial (°F, mph)" }
  func temperature(_ celsius: Double) -> String {
    let value = self == .metric ? celsius : celsius * 9 / 5 + 32
    return "\(Int(value.rounded()))°\(self == .metric ? "C" : "F")"
  }
  func wind(_ kilometresPerHour: Double) -> String {
    let value = self == .metric ? kilometresPerHour : kilometresPerHour / 1.609344
    return "\(Int(value.rounded())) \(self == .metric ? "km/h" : "mph")"
  }
  func rainfall(_ millimetresPerHour: Double) -> String {
    self == .metric ? String(format: "%.1f mm/h", millimetresPerHour)
      : String(format: "%.3f in/h", millimetresPerHour / 25.4)
  }
  func visibility(_ metres: Double?) -> String? {
    guard let metres, metres.isFinite, metres >= 0 else { return nil }
    if self == .metric {
      return metres < 1_000 ? "\(Int(metres.rounded())) m" : String(format: "%.1f km", metres / 1_000)
    }
    let miles = metres / 1_609.344
    return miles < 0.1 ? "\(Int((metres / 0.3048).rounded())) ft" : String(format: "%.1f mi", miles)
  }
}

enum MenuBarStyle: String, CaseIterable {
  case simple, compact, full
  var title: String { rawValue.capitalized }
  func text(for reading: WeatherSnapshot?, units: WeatherUnits) -> String {
    text(for: reading, units: WeatherDisplayUnits(preset: units))
  }
  func text(for reading: WeatherSnapshot?, units: WeatherDisplayUnits) -> String {
    guard self != .simple, let reading else { return "" }
    func temperature(_ value: Double?) -> String {
      guard let value, value.isFinite else { return "—" }
      return units.temperature(value)
    }
    let condition = reading.condition.localizedCapitalized
    if self == .compact { return temperature(reading.temperature) }
    return "Feels like \(temperature(reading.apparentTemperature)), \(condition)"
  }
}

struct WeatherDisplayUnits: Equatable {
  var temperatureUnits: WeatherUnits
  var windUnits: WeatherUnits
  var rainfallUnits: WeatherUnits
  var visibilityUnits: WeatherUnits
  init(preset: WeatherUnits) {
    temperatureUnits=preset;windUnits=preset;rainfallUnits=preset;visibilityUnits=preset
  }
  func temperature(_ value: Double) -> String { temperatureUnits.temperature(value) }
  func wind(_ value: Double) -> String { windUnits.wind(value) }
  func rainfall(_ value: Double) -> String { rainfallUnits.rainfall(value) }
  func visibility(_ value: Double?) -> String? { visibilityUnits.visibility(value) }
}
