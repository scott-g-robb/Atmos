import Foundation

/// The original agency text and link are kept intact. Visual interpretation is
/// separate from observed conditions, and never invents a measured rain/wind value.
struct LocalWeatherAlert: Equatable {
  enum Severity: String {
    case unknown, minor, moderate, severe, extreme
    var rank: Int { [.unknown, .minor, .moderate, .severe, .extreme].firstIndex(of: self)! }
    /// Artistic optical depth, not a claimed visibility measurement.
    var fogDensity: Float {
      switch self {
      case .unknown: 0.65
      case .minor: 0.45
      case .moderate: 0.72
      case .severe: 0.90
      case .extreme: 1
      }
    }
  }
  var id: String
  var summary: String
  var source: String
  var detailsURL: URL
  var severity: Severity
  var effective: Date
  var expires: Date
  var onset: Date?
  var eventEnd: Date?
  var starts: Date { max(effective, onset ?? effective) }
  var ends: Date { min(expires, eventEnd ?? expires) }
  func isActive(at date: Date) -> Bool { date >= starts && date < ends }
  func isVisible(at date: Date) -> Bool { date < expires && expires > effective }
  var visualEffect: WeatherEffect? {
    let words = Set(summary.lowercased().components(separatedBy: CharacterSet.letters.inverted))
    if !words.isDisjoint(with: ["fog", "brouillard", "nebel", "niebla", "niwl"]) { return .mist }
    if !words.isDisjoint(with: ["thunderstorm", "thunderstorms", "thunder", "lightning"]) { return .lightning }
    if !words.isDisjoint(with: ["blizzard", "snow", "snowfall"]) { return .snow }
    if !words.isDisjoint(with: ["sleet", "ice", "freezing"]) { return .sleet }
    if !words.isDisjoint(with: ["rain", "rainfall"]) { return .rain }
    return nil
  }
  var hasValidLink: Bool {
    detailsURL.scheme?.lowercased() == "https" && detailsURL.host != nil
      && !summary.isEmpty && !source.isEmpty
  }
}

extension WeatherSnapshot {
  func activeAlerts(at date: Date = Date()) -> [LocalWeatherAlert] {
    visibleAlerts(at: date).filter { $0.isActive(at: date) }
  }
  func visibleAlerts(at date: Date = Date()) -> [LocalWeatherAlert] {
    alerts.filter { $0.hasValidLink && $0.isVisible(at: date) }.sorted {
      if $0.isActive(at: date) != $1.isActive(at: date) { return $0.isActive(at: date) }
      if $0.severity != $1.severity { return $0.severity.rank > $1.severity.rank }
      return $0.starts < $1.starts
    }
  }
  func nextAlertBoundary(after date: Date) -> Date? {
    alerts.flatMap { [$0.starts, $0.ends, $0.expires] }.filter { $0 > date }.min()
  }
}
