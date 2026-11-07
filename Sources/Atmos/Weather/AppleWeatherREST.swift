import CoreLocation
import Foundation
import WeatherKit

/// Personal-key access for this Mac. Distributed builds use the native entitlement or Open-Meteo.
enum AppleWeatherREST {
  private struct Response: Decodable { let currentWeather: Current }
  private struct AlertResponse: Decodable { let weatherAlerts: AlertCollection? }
  private struct AlertCollection: Decodable {
    let detailsUrl: URL?
    let alerts: [Alert]
  }
  private struct Alert: Decodable {
    let id: String?
    let description: String
    let source: String
    let detailsUrl: URL?
    let severity: String
    let effectiveTime: String
    let expireTime: String
    let eventOnsetTime: String?
    let eventEndTime: String?
  }
  private struct Current: Decodable {
    struct Metadata: Decodable { let attributionURL: URL }
    let asOf: String
    let conditionCode: String
    let daylight: Bool
    let cloudCover: Double
    let visibility: Double?
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
    guard data.count < 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
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
    snapshot.visibility = current.visibility
    snapshot.humidity = current.humidity * 100
    snapshot.cloudCover = current.cloudCover * 100
    snapshot.apparentTemperature = current.temperatureApparent
    snapshot.preferredEffect = mapping.effect
    snapshot.reportedCondition = condition?.accessibilityDescription ?? "Cloudy"
    snapshot.precipitationUnit = "mm/h"
    // Missing/unsupported alerts never become a false 'no warnings' claim.
    if let collection = try? JSONDecoder().decode(AlertResponse.self, from: data).weatherAlerts {
      snapshot.alertsAvailable = true
      snapshot.alerts = collection.alerts.prefix(128).compactMap { alert in
        func parse(_ text: String?) -> Date? {
          guard let text else { return nil }
          formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
          if let date = formatter.date(from: text) { return date }
          formatter.formatOptions = [.withInternetDateTime]
          return formatter.date(from: text)
        }
        guard let effective = parse(alert.effectiveTime), let expires = parse(alert.expireTime),
          let url = alert.detailsUrl ?? collection.detailsUrl else { return nil }
        let warning = LocalWeatherAlert(id: alert.id ?? url.absoluteString,
          summary: alert.description, source: alert.source, detailsURL: url,
          severity: .init(rawValue: alert.severity) ?? .unknown, effective: effective,
          expires: expires, onset: parse(alert.eventOnsetTime), eventEnd: parse(alert.eventEndTime))
        return warning.hasValidLink ? warning : nil
      }
    }
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

  static func requestURL(at location: CLLocation, countryCode: String?) -> URL {
    let latitude = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.latitude)
    let longitude = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), location.coordinate.longitude)
    let candidate = countryCode?.uppercased()
    let country = candidate.flatMap { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isLetter } ? $0 : nil }
    var url = URLComponents(string: "https://weatherkit.apple.com/api/v1/weather/en/\(latitude)/\(longitude)")!
    url.queryItems = [URLQueryItem(name: "dataSets", value: country?.count == 2 ? "currentWeather,weatherAlerts" : "currentWeather")]
    if let country, country.count == 2 { url.queryItems!.append(URLQueryItem(name: "country", value: country)) }
    return url.url!
  }

  static func fetch(at location: CLLocation, countryCode: String? = nil) async throws -> AppleWeather.Reading {
    guard let credentials = WeatherKitCredentials.load() else {
      throw URLError(.userAuthenticationRequired)
    }
    var country = countryCode
    if country == nil {
      country = try? await CLGeocoder().reverseGeocodeLocation(location).first?.isoCountryCode
    }
    try Task.checkCancellation()
    let token = try credentials.token()
    func request(_ country: String?) async throws -> AppleWeather.Reading {
      var request = URLRequest(url: requestURL(at: location, countryCode: country))
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let (data, response) = try await session.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
      return try decode(data)
    }
    do { return try await request(country) }
    catch {
      try Task.checkCancellation()
      guard country != nil else { throw error }
      // Unsupported warning regions still receive the Apple observation.
      return try await request(nil)
    }
  }
}
