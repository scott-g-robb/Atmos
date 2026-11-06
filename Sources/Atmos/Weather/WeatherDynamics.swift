import Foundation

/// Measurements are normalized once. Values below are display mappings, not claims about
/// physical screen scale or measured drop terminal velocity (neither provider supplies that).
struct WeatherDynamics: Equatable {
  var cloudCover: Float
  var precipitationRate: Float
  var precipitationStrength: Float
  var fallSpeed: Float
  var humidity: Float
  var temperature: Float
  var feelsLike: Float
  var wind: Float
  var gust: Float
  var turbulence: Float
  var haze: Float
  var evaporation: Float

  init(weather: WeatherSnapshot) {
    cloudCover =
      Float(
        weather.cloudCover
          ?? (weather.weatherCode == 3
            ? 100 : weather.weatherCode == 2 ? 45 : weather.precipitation > 0 ? 75 : 0)) / 100
    precipitationRate = Float(weather.precipitationRate)
    // A reported trace still has a few drops; no light/steady/heavy quantization.
    precipitationStrength =
      weather.effect.hasWater || weather.effect == .snow || weather.effect == .hail
      ? min(3.8, 0.06 + pow(precipitationRate / 2.5, 0.72)) : 1
    let drizzle = weather.effect == .drizzle
    fallSpeed =
      drizzle
      ? 160 + 250 * (1 - exp(-precipitationRate * 1.8))
      : 390 + 650 * (1 - exp(-precipitationRate / 4))
    humidity = Float(weather.humidity ?? 55) / 100
    temperature = Float(weather.temperature)
    feelsLike = Float(weather.apparentTemperature ?? weather.temperature)
    wind = Float(
      -sin(weather.windDirection * .pi / 180) * min(weather.windSpeed, 100) * 2.4)
    let direction = Float(-sin(weather.windDirection * .pi / 180))
    gust =
      direction
      * Float(min(120, max(weather.windSpeed, weather.windGust ?? weather.windSpeed * 1.25))) * 2.4
    turbulence = Float(min(100, weather.windSpeed)) * 0.22
    haze = max(0, (humidity - 0.78) / 0.22) * max(0, 1 - abs(temperature - feelsLike) / 20)
    evaporation = max(0.15, min(3, (1 - humidity) * 2 + max(0, feelsLike) / 35))
  }

  func wind(at time: Double) -> Float {
    let pulse = pow(Float(0.5 + 0.5 * sin(time * 0.31 + sin(time * 0.073))), 4)
    return wind + (gust - wind) * pulse + sin(Float(time) * 0.77) * turbulence
  }

  func approach(_ target: Self, dt: Float) -> Self {
    var result = self
    let t = 1 - exp(-dt / 3)
    result.cloudCover += (target.cloudCover - cloudCover) * t
    result.precipitationRate += (target.precipitationRate - precipitationRate) * t
    result.precipitationStrength += (target.precipitationStrength - precipitationStrength) * t
    result.fallSpeed += (target.fallSpeed - fallSpeed) * t
    result.humidity += (target.humidity - humidity) * t
    result.temperature += (target.temperature - temperature) * t
    result.feelsLike += (target.feelsLike - feelsLike) * t
    result.wind += (target.wind - wind) * t
    result.gust += (target.gust - gust) * t
    result.turbulence += (target.turbulence - turbulence) * t
    result.haze += (target.haze - haze) * t
    result.evaporation += (target.evaporation - evaporation) * t
    return result
  }
}

/// Seasonal, weather-gated spells with real lulls. Stable time buckets avoid re-rolling
/// on provider refreshes. Hemisphere shifts by six months; nothing uses saved location.
enum SeasonalWeather {
  struct Overlays {
    var material: WeatherEffect?
    var wildlife: WeatherEffect?
    var strength: Float = 1
  }
  static func overlays(weather: WeatherSnapshot, date: Date) -> Overlays {
    let calendar = Calendar(identifier: .gregorian)
    let month = calendar.component(.month, from: date)
    let seasonalMonth = (month - 1 + ((weather.latitude ?? 45) < 0 ? 6 : 0)) % 12 + 1
    let rate = weather.precipitationRate
    let wind = weather.windSpeed
    let warmth = weather.apparentTemperature ?? weather.temperature
    let storm = [.storm, .lightning, .hail, .snow, .sleet].contains(weather.effect)
    guard !storm else { return Overlays() }
    var materials: [WeatherEffect] = []
    if wind >= 5 && wind <= 65 {
      if [9, 10, 11, 12].contains(seasonalMonth), rate < 4 { materials.append(.leaves) }
      if [3, 4, 5].contains(seasonalMonth), warmth > 6, rate < 1.2 {
        materials.append(.cherryBlossoms)
      }
      if [4, 5, 6, 7, 8].contains(seasonalMonth), warmth > 10, rate < 0.3 {
        materials.append(.dandelionSeeds)
      }
      if [5, 6, 7, 8, 9].contains(seasonalMonth), warmth > 13, rate < 0.8 {
        materials.append(.rosePetals)
      }
      if [9, 10, 11].contains(seasonalMonth), rate < 2 { materials.append(.mapleSeeds) }
      if [5, 6, 7].contains(seasonalMonth), warmth > 14, rate < 0.2 {
        materials.append(.cottonwood)
      }
    }
    // 3-minute cycles: roughly 90–120 seconds of material followed by a quiet spell.
    let seconds = date.timeIntervalSince1970
    let cycle = Int(floor(seconds / 180))
    let phase = seconds - Double(cycle) * 180
    var result = Overlays()
    if !materials.isEmpty && phase > 18 && phase < 125 {
      result.material = materials[abs(cycle) % materials.count]
      result.strength = Float(min(1.4, 0.35 + wind / 35))
    }
    // Wildlife uses an independent clock, so it need not coincide with drifting material.
    let wildlifePhase = seconds.truncatingRemainder(dividingBy: 240)
    if rate < 0.2 && wind < 22 && weather.effect != .mist && wildlifePhase > 35
      && wildlifePhase < 155
    {
      if weather.isDay == 0 && warmth >= 15 && [5, 6, 7, 8, 9].contains(seasonalMonth) {
        result.wildlife = .fireflies
      } else if weather.isDay == 1 && warmth > 5 {
        result.wildlife =
          warmth > 16 && [4, 5, 6, 7, 8, 9].contains(seasonalMonth) && cycle % 2 == 0
          ? .butterflies : .birds
      }
    }
    return result
  }
}
