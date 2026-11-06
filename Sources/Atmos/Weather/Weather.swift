import Foundation

enum WeatherEffect: String, CaseIterable, Codable {
  case none, snow, leaves, rain, drizzle, storm, lightning, sleet, hail, mist, clouds, sunlight,
    fireflies
  case cherryBlossoms, dandelionSeeds, rosePetals, mapleSeeds, cottonwood, butterflies, birds

  var title: String {
    switch self {
    case .none: "Off"
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
    case .cherryBlossoms: "Cherry Blossoms"
    case .dandelionSeeds: "Dandelions"
    case .rosePetals: "Rose Petals"
    case .mapleSeeds: "Maple Seeds"
    case .cottonwood: "Cottonwood Fluff"
    case .butterflies: "Butterflies"
    case .birds: "Birds"
    }
  }

  var symbol: String {
    switch self {
    case .none: "circle"
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
    case .cherryBlossoms, .rosePetals: "camera.macro"
    case .dandelionSeeds, .cottonwood: "wind"
    case .mapleSeeds: "leaf"
    case .butterflies: "butterfly"
    case .birds: "bird"
    }
  }

  static let seasonal: [Self] = [
    .leaves, .cherryBlossoms, .dandelionSeeds, .rosePetals, .mapleSeeds, .cottonwood,
  ]
  static let wildlife: [Self] = [.butterflies, .fireflies, .birds]
  var isStacked: Bool { Self.seasonal.contains(self) || Self.wildlife.contains(self) }
  var usesSnowSimulation: Bool { self == .snow || Self.seasonal.contains(self) }
  /// Shared leaf renderer style; zero is snow, one preserves the original autumn artwork.
  var botanicalStyle: Float {
    switch self {
    case .leaves: 1
    case .cherryBlossoms: 2
    case .dandelionSeeds: 3
    case .rosePetals: 4
    case .mapleSeeds: 5
    case .cottonwood: 6
    default: 0
    }
  }
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
  var interval: Double? = nil
  var windGust: Double? = nil
  /// Rounded, in-memory coordinate for seasonal timing; never persisted.
  var latitude: Double? = nil
  var precipitationRate: Double {
    precipitationUnit == "mm/h" ? precipitation : precipitation * 3600 / (interval ?? 900)
  }

  enum CodingKeys: String, CodingKey {
    case time, interval
    case windGust = "wind_gusts_10m"
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
    if let preferredEffect, !preferredEffect.isStacked { return preferredEffect }
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
    if weatherCode == 3 { return .clouds }
    return isDay == 1 ? .sunlight : .none
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
    let intervalValid = interval.map { $0.isFinite && (60...3600).contains($0) } ?? true
    let gustValid = windGust.map { $0.isFinite && (0...500).contains($0) } ?? true
    return humidityValid && cloudsValid && feelsValid && intervalValid && gustValid && age >= -900
      && age <= 7200
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
          "weather_code,temperature_2m,apparent_temperature,relative_humidity_2m,cloud_cover,wind_speed_10m,wind_gusts_10m,wind_direction_10m,precipitation,is_day"
      ),
      .init(name: "wind_speed_unit", value: "kmh"), .init(name: "timeformat", value: "unixtime"),
      .init(name: "forecast_days", value: "1"),
    ]
    return components.url
  }
}

/// Weather remains the base layer; seasonal material and wildlife have independent lifetimes.
struct WeatherScene: Equatable {
  var primary: WeatherEffect
  var clouds: Float = 0
  var sunlight: Float = 0
  var fireflies: Float = 0  // Legacy secondary-layer compatibility.
  var strength: Float = 1
  var dynamics: WeatherDynamics?
  var stacked: WeatherEffect?
  var wildlife: WeatherEffect?
  var overlayStrength: Float = 1

  init(primary: WeatherEffect, stacked: WeatherEffect? = nil, wildlife: WeatherEffect? = nil) {
    self.primary = primary
    self.stacked = stacked
    self.wildlife = wildlife
  }
  init(weather: WeatherSnapshot, date: Date = Date()) {
    primary = weather.effect
    let dynamics = WeatherDynamics(weather: weather)
    self.dynamics = dynamics
    clouds = dynamics.cloudCover
    sunlight =
      weather.isDay == 1 && ![WeatherEffect.storm, .lightning, .mist].contains(primary)
      ? pow(1 - clouds, 2) : 0
    strength = dynamics.precipitationStrength
    let overlays = SeasonalWeather.overlays(weather: weather, date: date)
    stacked = overlays.material
    wildlife = overlays.wildlife
    overlayStrength = overlays.strength
  }
  var summary: String {
    var names = primary == .none ? (dynamics != nil ? ["Clear night"] : []) : [primary.title]
    if let dynamics, dynamics.cloudCover > 0, primary != .clouds {
      names.append("Clouds \(Int((dynamics.cloudCover * 100).rounded()))%")
    } else if clouds > 0.05 && primary != .clouds {
      names.append("Clouds")
    }
    if sunlight > 0.05 && primary != .sunlight { names.append("Sunbeams") }
    if let stacked { names.append(stacked.title) }
    if let wildlife { names.append(wildlife.title) }
    return names.isEmpty ? "All layers off" : names.joined(separator: " + ")
  }
}

extension WeatherScene {
  mutating func toggleManual(_ effect: WeatherEffect) {
    if WeatherEffect.seasonal.contains(effect) {
      stacked = stacked == effect ? nil : effect
    } else if WeatherEffect.wildlife.contains(effect) {
      wildlife = wildlife == effect ? nil : effect
    } else {
      primary = primary == effect ? .none : effect
    }
  }
}
