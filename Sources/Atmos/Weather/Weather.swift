import Foundation

enum WeatherEffect: String, CaseIterable, Codable {
  case snow, leaves, rain, drizzle, storm, lightning, sleet, hail, mist, clouds, sunlight, fireflies

  var title: String {
    switch self {
    case .snow: "Snow"
    case .leaves: "Autumn Leaves"
    case .rain: "Rain"
    case .drizzle: "Drizzle"
    case .storm: "Storm"
    case .lightning: "Lightning"
    case .sleet: "Sleet"
    case .hail: "Hail"
    case .mist: "Mist"
    case .clouds: "Cloud Wisps"
    case .sunlight: "Sunbeams"
    case .fireflies: "Fireflies"
    }
  }

  var symbol: String {
    switch self {
    case .snow: "snowflake"
    case .leaves: "leaf"
    case .rain, .drizzle: "cloud.rain"
    case .storm: "cloud.heavyrain"
    case .lightning: "cloud.bolt.rain"
    case .sleet: "cloud.sleet"
    case .hail: "cloud.hail"
    case .mist: "cloud.fog"
    case .clouds: "cloud"
    case .sunlight: "sun.max"
    case .fireflies: "sparkles"
    }
  }

  var usesSnowSimulation: Bool { self == .snow || self == .leaves }
  var hasWater: Bool { [.rain, .drizzle, .storm, .lightning, .sleet].contains(self) }
  var hasBanks: Bool { self == .mist || self == .clouds }
  var canAccumulate: Bool { usesSnowSimulation || hasWater || hasBanks }
}

struct WeatherSnapshot: Decodable, Equatable {
  let time: TimeInterval
  let weatherCode: Int
  let temperature: Double
  let windSpeed: Double
  let windDirection: Double
  let precipitation: Double
  let isDay: Int
  var humidity: Double? = nil
  var cloudCover: Double? = nil
  var apparentTemperature: Double? = nil
  var reportedCondition: String? = nil
  var preferredEffect: WeatherEffect? = nil
  var precipitationUnit = "mm"

  enum CodingKeys: String, CodingKey {
    case time
    case weatherCode = "weather_code"
    case temperature = "temperature_2m"
    case windSpeed = "wind_speed_10m"
    case windDirection = "wind_direction_10m"
    case precipitation
    case isDay = "is_day"
    case humidity = "relative_humidity_2m"
    case cloudCover = "cloud_cover"
    case apparentTemperature = "apparent_temperature"
  }

  var effect: WeatherEffect {
    if let preferredEffect { return preferredEffect }
    // Precipitation takes precedence over wind: a windy snowstorm should still snow.
    switch weatherCode {
    case 71, 73, 75, 77, 85, 86: return .snow
    case 56, 57, 66, 67: return .sleet
    case 51, 53, 55: return .drizzle
    case 61, 63, 65, 80, 81, 82: return .rain
    case 95: return .lightning
    case 96, 99: return .hail
    case 45, 48: return .mist
    default: break
    }
    if windSpeed >= 25 { return .leaves }
    if weatherCode == 3 { return .clouds }
    return isDay == 1 ? .sunlight : .fireflies
  }

  var intensity: Snowfall {
    switch weatherCode {
    case 55, 57, 65, 67, 75, 82, 86, 95, 96, 99: return .heavy
    case 51, 56, 61, 71, 77, 80, 85: return .light
    case 53, 63, 66, 73, 81, 45, 48, 3: return .steady
    default: return windSpeed >= 45 ? .heavy : windSpeed >= 20 ? .steady : .light
    }
  }

  var condition: String {
    if let reportedCondition { return reportedCondition }
    switch weatherCode {
    case 0: return isDay == 1 ? "Clear sky" : "Clear night"
    case 1: return "Mainly clear"
    case 2: return "Partly cloudy"
    case 3: return "Overcast"
    case 45: return "Fog"
    case 48: return "Freezing fog"
    case 51: return "Light drizzle"
    case 53: return "Drizzle"
    case 55: return "Dense drizzle"
    case 56, 57: return "Freezing drizzle"
    case 61: return "Light rain"
    case 63: return "Rain"
    case 65: return "Heavy rain"
    case 66, 67: return "Freezing rain"
    case 71: return "Light snow"
    case 73: return "Snow"
    case 75: return "Heavy snow"
    case 77: return "Snow grains"
    case 80: return "Light rain showers"
    case 81: return "Rain showers"
    case 82: return "Heavy rain showers"
    case 85, 86: return "Snow showers"
    case 95: return "Thunderstorm"
    case 96, 99: return "Thunderstorm with hail"
    default: return "Unknown conditions"
    }
  }

  /// Meteorological direction is where wind comes FROM. Display wind is bounded, in points/second.
  var horizontalWind: Float {
    Float(-sin(windDirection * .pi / 180) * min(windSpeed, 100) * 2.4)
  }

  func isUsable(at date: Date = Date()) -> Bool {
    let age = date.timeIntervalSince1970 - time
    let humidityValid = humidity.map { $0.isFinite && (0...100).contains($0) } ?? true
    let cloudsValid = cloudCover.map { $0.isFinite && (0...100).contains($0) } ?? true
    let feelsValid = apparentTemperature.map { $0.isFinite && (-120...80).contains($0) } ?? true
    return humidityValid && cloudsValid && feelsValid && age >= -900 && age <= 7200
      && temperature.isFinite && (-120...80).contains(temperature) && windSpeed.isFinite
      && windSpeed >= 0 && windSpeed <= 500 && windDirection.isFinite
      && (0...360).contains(windDirection)
      && precipitation.isFinite && (0...1000).contains(precipitation) && (isDay == 0 || isDay == 1)
      && Self.knownCodes.contains(weatherCode)
  }

  static let knownCodes: Set<Int> = [
    0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86,
    95, 96, 99,
  ]
}

enum WeatherAPI {
  struct Response: Decodable { let current: WeatherSnapshot }

  static func decode(_ data: Data, response: URLResponse, at date: Date = Date()) throws
    -> WeatherSnapshot
  {
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      data.count < 65_536
    else {
      throw URLError(.badServerResponse)
    }
    let weather = try JSONDecoder().decode(Response.self, from: data).current
    guard weather.isUsable(at: date) else { throw URLError(.cannotParseResponse) }
    return weather
  }

  static func url(latitude: Double, longitude: Double) -> URL? {
    guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
      (-180...180).contains(longitude)
    else { return nil }
    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    // About a kilometre is enough for weather; avoid sending the precise device coordinate.
    components.queryItems = [
      .init(
        name: "latitude",
        value: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), latitude)),
      .init(
        name: "longitude",
        value: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), longitude)),
      .init(
        name: "current",
        value:
          "weather_code,temperature_2m,apparent_temperature,relative_humidity_2m,cloud_cover,wind_speed_10m,wind_direction_10m,precipitation,is_day"
      ),
      .init(name: "wind_speed_unit", value: "kmh"), .init(name: "timeformat", value: "unixtime"),
      .init(name: "forecast_days", value: "1"),
    ]
    return components.url
  }
}

/// One coherent scene. Secondary layers share the same renderer, flow grid and frame budget.
struct WeatherScene: Equatable {
  var primary: WeatherEffect
  var clouds: Float = 0
  var sunlight: Float = 0
  var fireflies: Float = 0
  var strength: Float = 1

  init(primary: WeatherEffect) { self.primary = primary }
  init(weather: WeatherSnapshot) {
    primary = weather.effect
    let cover =
      Float(
        weather.cloudCover
          ?? (weather.weatherCode == 2
            ? 45 : weather.weatherCode == 3 ? 95 : weather.precipitation > 0 ? 75 : 0)) / 100
    clouds =
      primary == .clouds || primary == .mist || primary == .storm || primary == .lightning
      ? 0 : min(0.8, max(0, (cover - 0.08) * 0.85))
    // Daylight through broken rain clouds, or a few fireflies beneath a lightly clouded night.
    sunlight =
      weather.isDay == 1 && cover < 0.8 && primary != .sunlight && primary != .clouds
        && primary != .mist && primary != .storm && primary != .lightning ? (1 - cover) * 0.45 : 0
    fireflies =
      weather.isDay == 0 && cover < 0.7 && !primary.hasWater && primary != .fireflies
        && primary != .mist ? (1 - cover) * 0.3 : 0
    strength = 1
  }
  var summary: String {
    var names = [primary.title]
    if clouds > 0.05 { names.append("Light Clouds") }
    if sunlight > 0.05 { names.append("Sunbeams") }
    if fireflies > 0.05 { names.append("Fireflies") }
    return names.joined(separator: " + ")
  }
}
