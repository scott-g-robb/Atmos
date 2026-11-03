import CoreLocation
import Foundation
import Security
import WeatherKit

/// Uses the same Apple Weather service as the Weather app through its supported public API.
/// An ad-hoc signed build deliberately does not claim to have WeatherKit authorization.
enum AppleWeather {
  static let isConfigured: Bool = {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode
    else { return false }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let info = information as? [String: Any],
      let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    else { return false }
    return entitlements["com.apple.developer.weatherkit"] as? Bool == true
  }()

  static var isAvailable: Bool { isConfigured || WeatherKitCredentials.exists }
  struct Attribution {
    let combinedMarkDarkURL: URL
    let legalPageURL: URL
  }
  struct Reading {
    let snapshot: WeatherSnapshot
    let attribution: Attribution
  }

  static func fetch(at location: CLLocation) async throws -> Reading {
    if isConfigured {
      do { return try await fetchNative(at: location) } catch {
        guard !Task.isCancelled, WeatherKitCredentials.exists else { throw error }
      }
    }
    return try await AppleWeatherREST.fetch(at: location)
  }

  private static func fetchNative(at location: CLLocation) async throws -> Reading {
    let current = try await WeatherService.shared.weather(for: location, including: .current)
    let attribution = try await WeatherService.shared.attribution
    let mapping = mapping(current.condition)
    var snapshot = WeatherSnapshot(
      time: current.date.timeIntervalSince1970, weatherCode: mapping.code,
      temperature: current.temperature.converted(to: .celsius).value,
      windSpeed: current.wind.speed.converted(to: .kilometersPerHour).value,
      windDirection: current.wind.direction.converted(to: .degrees).value,
      precipitation: current.precipitationIntensity.converted(to: .metersPerSecond).value
        * 3_600_000,
      isDay: current.isDaylight ? 1 : 0)
    snapshot.humidity = current.humidity * 100
    snapshot.cloudCover = current.cloudCover * 100
    snapshot.apparentTemperature = current.apparentTemperature.converted(to: .celsius).value
    snapshot.reportedCondition = current.condition.accessibilityDescription
    snapshot.preferredEffect = mapping.effect
    snapshot.precipitationUnit = "mm/h"
    guard snapshot.isUsable() else { throw URLError(.cannotParseResponse) }
    return Reading(
      snapshot: snapshot,
      attribution: Attribution(
        combinedMarkDarkURL: attribution.combinedMarkDarkURL, legalPageURL: attribution.legalPageURL
      ))
  }

  static func mapping(_ condition: WeatherCondition) -> (code: Int, effect: WeatherEffect?) {
    switch condition {
    case .blizzard, .blowingSnow, .heavySnow: return (75, .snow)
    case .blowingDust, .breezy, .windy: return (0, .leaves)
    case .clear, .hot, .frigid: return (0, nil)
    case .cloudy, .mostlyCloudy: return (3, .clouds)
    case .partlyCloudy: return (2, nil)
    case .mostlyClear: return (1, nil)
    case .drizzle: return (53, .drizzle)
    case .flurries, .sunFlurries: return (71, .snow)
    case .foggy, .haze, .smoky: return (45, .mist)
    case .freezingDrizzle: return (56, .sleet)
    case .freezingRain, .sleet, .wintryMix: return (66, .sleet)
    case .hail: return (96, .hail)
    case .heavyRain: return (65, .rain)
    case .rain, .sunShowers: return (63, .rain)
    case .snow: return (73, .snow)
    case .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .thunderstorms:
      return (95, .lightning)
    case .hurricane, .tropicalStorm: return (65, .storm)
    @unknown default: return (3, .clouds)
    }
  }
}
