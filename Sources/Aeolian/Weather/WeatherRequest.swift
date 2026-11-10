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
    source: WeatherSource, appleAvailable: Bool, retryDelay: TimeInterval = 1,
    attemptTimeout: TimeInterval = 6,
    apple: @escaping () async throws -> AppleWeather.Reading,
    openMeteo: @escaping () async throws -> WeatherSnapshot
  ) async throws -> Reading {
    if source != .openMeteo {
      // Every cycle starts with Apple, including a cycle after fallback. Retry
      // Apple once before fetching Open-Meteo, never mark fallback as Apple data.
      for attempt in 0..<2 {
        do {
          try Task.checkCancellation()
          guard appleAvailable || attempt > 0 else { throw URLError(.userAuthenticationRequired) }
          return .apple(try await WeatherAttempt.run(timeout:attemptTimeout,operation:apple))
        } catch {
          try Task.checkCancellation()
          if attempt == 0 {
            try await Task.sleep(nanoseconds: UInt64(max(0,retryDelay)*1_000_000_000))
          }
        }
      }
    }
    try Task.checkCancellation()
    return .openMeteo(try await WeatherAttempt.run(timeout:attemptTimeout,operation:openMeteo))
  }
}

struct WeatherRecovery {
  private(set) var until = Date.distantPast
  private(set) var failedAttempts = 0
  private(set) var exhausted = false
  mutating func resume(at now: Date = Date()) {
    until = now.addingTimeInterval(120)
    resetRetries()
  }
  func isRecovering(at now: Date = Date()) -> Bool { now < until }
  mutating func resetRetries() { failedAttempts = 0; exhausted = false }
  /// Fifteen total failed attempts, including the first request. Automatic
  /// refresh triggers cannot reset this budget or bypass a pending retry.
  mutating func nextFailureDelay() -> TimeInterval? {
    guard !exhausted else { return nil }
    failedAttempts += 1
    guard failedAttempts < 15 else { exhausted = true; return nil }
    return [1.0, 2, 3, 5, 15, 30][min(5, failedAttempts - 1)]
  }
  static func appleRetryDelay(_ failures: Int) -> TimeInterval {
    min(300, 30 * pow(2, Double(min(4, max(0, failures - 1)))))
  }
}
