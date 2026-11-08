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
