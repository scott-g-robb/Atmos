import CoreLocation
import Foundation
import WeatherKit

/// Personal-key access for this Mac. Distributed builds use the native entitlement or Open-Meteo.
enum AppleWeatherREST {
  private struct Response: Decodable { let currentWeather: Current }
  private struct Current: Decodable {
    struct Metadata: Decodable { let attributionURL: URL }
    let asOf: String
    let conditionCode: String
    let daylight: Bool
    let cloudCover: Double
    let humidity: Double
    let temperature: Double
    let temperatureApparent: Double
    let windSpeed: Double
    let windGust: Double?
    let windDirection: Double?
    let precipitationIntensity: Double?
    let metadata: Metadata
  }
  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 30
    config.urlCache = nil
    return URLSession(configuration: config)
  }()

  static func decode(_ data: Data, at date: Date = Date()) throws -> AppleWeather.Reading {
    guard data.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
    let current = try JSONDecoder().decode(Response.self, from: data).currentWeather
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var observation = formatter.date(from: current.asOf)
    if observation == nil {
      formatter.formatOptions = [.withInternetDateTime]
      observation = formatter.date(from: current.asOf)
    }
    guard let observation else { throw URLError(.cannotParseResponse) }
    let condition = WeatherCondition.allCases.first {
      $0.rawValue.lowercased() == current.conditionCode.lowercased()
    }
    let mapping = condition.map(AppleWeather.mapping) ?? (code: 3, effect: WeatherEffect.clouds)
    var snapshot = WeatherSnapshot(
      time: observation.timeIntervalSince1970, weatherCode: mapping.code,
      temperature: current.temperature,
      windSpeed: current.windSpeed, windDirection: current.windDirection ?? 0,
      precipitation: current.precipitationIntensity ?? 0, isDay: current.daylight ? 1 : 0)
    snapshot.windGust = current.windGust
    snapshot.humidity = current.humidity * 100
    snapshot.cloudCover = current.cloudCover * 100
    snapshot.apparentTemperature = current.temperatureApparent
    snapshot.preferredEffect = mapping.effect
    snapshot.reportedCondition = condition?.accessibilityDescription ?? "Cloudy"
    snapshot.precipitationUnit = "mm/h"
    guard snapshot.isUsable(at: date), current.metadata.attributionURL.scheme == "https",
      current.metadata.attributionURL.host == "developer.apple.com"
    else { throw URLError(.cannotParseResponse) }
    return AppleWeather.Reading(
      snapshot: snapshot,
      attribution: AppleWeather.Attribution(
        combinedMarkDarkURL: URL(
          string:
            "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_wht_en_2X_090122.png")!,
        legalPageURL: current.metadata.attributionURL))
  }

  static func fetch(at location: CLLocation) async throws -> AppleWeather.Reading {
    guard let credentials = WeatherKitCredentials.load() else {
      throw URLError(.userAuthenticationRequired)
    }
    let latitude = String(
      format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.latitude)
    let longitude = String(
      format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.longitude)
    let url = URL(
      string:
        "https://weatherkit.apple.com/api/v1/weather/en/\(latitude)/\(longitude)?dataSets=currentWeather"
    )!
    var request = URLRequest(url: url)
    request.setValue("Bearer \(try credentials.token())", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw URLError(.userAuthenticationRequired)
    }
    return try decode(data)
  }
}
