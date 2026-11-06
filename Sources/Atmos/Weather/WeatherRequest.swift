import Foundation

/// Provider order is identical for manual Apple and Automatic. A failed logo request
/// is deliberately outside this operation: branding must never replace good weather.
enum WeatherRequest {
  enum Reading {
    case apple(AppleWeather.Reading)
    case openMeteo(WeatherSnapshot)
    var snapshot: WeatherSnapshot {
      switch self {
      case .apple(let reading): reading.snapshot
      case .openMeteo(let snapshot): snapshot
      }
    }
  }
  static func fetch(
    source: WeatherSource, appleAvailable: Bool,
    apple: () async throws -> AppleWeather.Reading,
    openMeteo: () async throws -> WeatherSnapshot
  ) async throws -> Reading {
    if source != .openMeteo && appleAvailable {
      do { return .apple(try await apple()) } catch {
        if source == .apple || Task.isCancelled { throw error }
      }
    } else if source == .apple {
      throw URLError(.userAuthenticationRequired)
    }
    try Task.checkCancellation()
    return .openMeteo(try await openMeteo())
  }
}

struct WeatherRecovery {
  private(set) var until = Date.distantPast
  mutating func resume(at now: Date = Date()) { until = now.addingTimeInterval(120) }
  func isRecovering(at now: Date = Date()) -> Bool { now < until }
  func failureDelay(_ count: Int, at now: Date = Date()) -> TimeInterval {
    if isRecovering(at: now) { return [5.0, 10, 20, 30][min(3, max(0, count - 1))] }
    return count == 1 ? 30 : count == 2 ? 60 : count == 3 ? 300 : 900
  }
  static func appleRetryDelay(_ failures: Int) -> TimeInterval {
    min(300, 30 * pow(2, Double(min(4, max(0, failures - 1)))))
  }
}
