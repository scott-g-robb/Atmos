import XCTest

@testable import Atmos

final class WeatherTests: XCTestCase {
  private func snapshot(code: Int, wind: Double = 0, day: Int = 1, age: Double = 0)
    -> WeatherSnapshot
  {
    WeatherSnapshot(
      time: Date().timeIntervalSince1970 - age, weatherCode: code, temperature: 12,
      windSpeed: wind, windDirection: 270, precipitation: 1, isDay: day)
  }

  func testEveryWMOConditionHasAnAppropriateEffect() {
    let groups: [(WeatherEffect, [Int])] = [
      (.snow, [71, 73, 75, 77, 85, 86]), (.drizzle, [51, 53, 55]),
      (.rain, [61, 63, 65, 80, 81, 82]),
      (.sleet, [56, 57, 66, 67]), (.lightning, [95]), (.hail, [96, 99]), (.mist, [45, 48]),
      (.clouds, [3]), (.sunlight, [0, 1, 2]),
    ]
    for (effect, codes) in groups {
      for code in codes {
        XCTAssertEqual(snapshot(code: code).effect, effect, "WMO \(code)")
        XCTAssertTrue(snapshot(code: code).isUsable())
      }
    }
    XCTAssertEqual(Set(groups.flatMap(\.1)), WeatherSnapshot.knownCodes)
    XCTAssertEqual(snapshot(code: 0, wind: 25).effect, .leaves)
    XCTAssertEqual(snapshot(code: 3, wind: 50).effect, .leaves)
    XCTAssertEqual(snapshot(code: 75, wind: 80).effect, .snow)
    XCTAssertEqual(snapshot(code: 65, wind: 80).effect, .rain)
    XCTAssertEqual(snapshot(code: 0, day: 0).effect, .fireflies)
    XCTAssertFalse(snapshot(code: 123).isUsable())
  }

  func testStaleFutureAndInvalidWeatherIsRejected() {
    XCTAssertTrue(snapshot(code: 0, age: 7000).isUsable())
    XCTAssertFalse(snapshot(code: 0, age: 7201).isUsable())
    XCTAssertFalse(snapshot(code: 0, age: -901).isUsable())
    XCTAssertFalse(snapshot(code: 0, wind: .infinity).isUsable())
    XCTAssertFalse(snapshot(code: 0, wind: -1).isUsable())
    XCTAssertFalse(snapshot(code: 0, day: 4).isUsable())
    XCTAssertEqual(snapshot(code: 0, wind: 30).horizontalWind, 72, accuracy: 0.001)
  }

  func testAPIRequestRoundsCoordinatesAndDecodesRealResponseShape() throws {
    let url = try XCTUnwrap(WeatherAPI.url(latitude: 51.507351, longitude: -0.127758))
    let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(query.first { $0.name == "latitude" }?.value, "51.51")
    XCTAssertEqual(query.first { $0.name == "longitude" }?.value, "-0.13")
    XCTAssertEqual(url.scheme, "https")
    XCTAssertNil(WeatherAPI.url(latitude: .nan, longitude: 0))
    XCTAssertNil(WeatherAPI.url(latitude: 91, longitude: 0))
    let data = Data(
      """
      {"latitude":51.5,"current":{"time":\(Int(Date().timeIntervalSince1970)),"weather_code":63,
      "temperature_2m":9.2,"wind_speed_10m":28.4,"wind_direction_10m":270,"precipitation":1.2,"is_day":1}}
      """.utf8)
    let result = try JSONDecoder().decode(WeatherAPI.Response.self, from: data)
    XCTAssertEqual(result.current.effect, .rain)
    XCTAssertTrue(result.current.isUsable())
    XCTAssertThrowsError(
      try JSONDecoder().decode(WeatherAPI.Response.self, from: Data("{\"current\":null}".utf8)))
  }

  func testHTTPFailuresOversizedAndStaleResponsesAreRejected() throws {
    let url = try XCTUnwrap(WeatherAPI.url(latitude: 0, longitude: 0))
    let ok = try XCTUnwrap(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    let limited = try XCTUnwrap(
      HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil))
    let data = Data(
      """
      {"current":{"time":100000,"weather_code":63,"temperature_2m":9,"wind_speed_10m":20,
      "wind_direction_10m":180,"precipitation":1,"is_day":1}}
      """.utf8)
    let now = Date(timeIntervalSince1970: 100100)
    XCTAssertEqual(try WeatherAPI.decode(data, response: ok, at: now).effect, .rain)
    XCTAssertThrowsError(try WeatherAPI.decode(data, response: limited, at: now))
    XCTAssertThrowsError(
      try WeatherAPI.decode(data, response: ok, at: now.addingTimeInterval(8000)))
    XCTAssertThrowsError(
      try WeatherAPI.decode(Data(repeating: 32, count: 65536), response: ok, at: now))
    XCTAssertThrowsError(
      try WeatherAPI.decode(Data("<html>service unavailable</html>".utf8), response: ok, at: now))
    let extreme = Data(
      String(decoding: data, as: UTF8.self).replacingOccurrences(
        of: "\"temperature_2m\":9", with: "\"temperature_2m\":1e100"
      ).utf8)
    XCTAssertThrowsError(try WeatherAPI.decode(extreme, response: ok, at: now))
  }
}
