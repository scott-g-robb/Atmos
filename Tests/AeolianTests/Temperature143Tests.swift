import AppKit
import CoreLocation
import XCTest
@testable import Aeolian

final class Temperature143Tests: XCTestCase {
  @MainActor func testWelcomeEntranceSharesItsStartAndSettlesWithoutOvershootOrBlockingNavigation() throws {
    let page = SetupPageView(frame:CGRect(x:0,y:0,width:520,height:530),page:.welcome,permissions:[],icon:nil)
    let start = CACurrentMediaTime()+0.12
    page.prepareEntrance(calm:false,startTime:start)
    let layer = try XCTUnwrap(page.layer)
    let settle = try XCTUnwrap(layer.animation(forKey:"settlingAtmosphere") as? CAKeyframeAnimation)
    XCTAssertEqual(settle.duration,3.4)
    XCTAssertEqual(settle.beginTime,layer.convertTime(start,from:nil),accuracy:0.001)
    let scales = try XCTUnwrap(settle.values as? [NSValue]).map {$0.caTransform3DValue.m11}
    XCTAssertEqual(scales,[0.985,1])
    XCTAssertTrue(page.next.isEnabled)
    XCTAssertNotNil(layer.mask)
    page.finishEntrance()
    XCTAssertNil(layer.mask);XCTAssertNil(layer.animation(forKey:"settlingAtmosphere"))
    XCTAssertNil(page.next.layer?.animation(forKey:"settlingContent"))
  }
  private func reading() -> WeatherSnapshot {
    var w = WeatherSnapshot(time: Date().timeIntervalSince1970, weatherCode: 1,
      temperature: 10, windSpeed: 4, windDirection: 270, precipitation: 0, isDay: 1)
    w.apparentTemperature = 9; w.reportedCondition = "Mostly Clear"
    w.setDailyTemperatures(high: 14, low: 6)
    return w
  }
  func testMenuStylesUseCurrentInCompactAndFeelsLikeWithConditionInFull() {
    let w = reading()
    XCTAssertEqual(MenuBarStyle.simple.text(for: w, units: .metric), "")
    XCTAssertEqual(MenuBarStyle.compact.text(for: w, units: .metric), "10°C")
    XCTAssertEqual(MenuBarStyle.full.text(for: w, units: .metric),
      "Feels like 9°C, Mostly Clear")
    XCTAssertEqual(MenuBarStyle.compact.text(for: w, units: .imperial), "50°F")
    XCTAssertEqual(MenuBarStyle.full.text(for: nil, units: .metric), "")
    var missing = w; missing.apparentTemperature = nil
    missing.setDailyTemperatures(high: .infinity, low: .nan)
    XCTAssertEqual(MenuBarStyle.compact.text(for: missing, units: .metric), "10°C")
    XCTAssertEqual(MenuBarStyle.full.text(for: missing, units: .metric), "Feels like —, Mostly Clear")
    missing.setDailyTemperatures(high: 2, low: 12)
    XCTAssertNil(missing.highTemperature); XCTAssertNil(missing.lowTemperature)
  }
  func testOpenMeteoIncludesLocalDayHighAndLowWithoutRequiringForecastAvailability() throws {
    let now = Date(), url = try XCTUnwrap(WeatherAPI.url(latitude: 51.5, longitude: -0.1))
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    XCTAssertEqual(query.first { $0.name == "timezone" }?.value, "auto")
    XCTAssertEqual(query.first { $0.name == "daily" }?.value, "temperature_2m_max,temperature_2m_min")
    let current: [String:Any] = ["time":now.timeIntervalSince1970,"weather_code":1,
      "temperature_2m":10,"apparent_temperature":9,"wind_speed_10m":4,
      "wind_direction_10m":270,"precipitation":0,"is_day":1]
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    for forecast in [true,false] {
      var payload: [String:Any] = ["current":current]
      if forecast {payload["daily"]=["temperature_2m_max":[14],"temperature_2m_min":[6]]}
      let w = try WeatherAPI.decode(JSONSerialization.data(withJSONObject: payload), response: response, at: now)
      XCTAssertEqual(w.highTemperature, forecast ? 14 : nil)
      XCTAssertEqual(w.lowTemperature, forecast ? 6 : nil)
      XCTAssertEqual(w.apparentTemperature, 9)
    }
  }
  func testPersonalAppleForecastUsesTheSameCelsiusDailyFields() throws {
    let now = Date()
    let current: [String:Any] = ["asOf":ISO8601DateFormatter().string(from:now),
      "conditionCode":"MostlyClear","daylight":true,"cloudCover":0.2,"humidity":0.8,
      "temperature":10,"temperatureApparent":9,"windSpeed":4,
      "metadata":["attributionURL":"https://developer.apple.com/weatherkit/data-source-attribution/"]]
    let payload: [String:Any] = ["currentWeather":current,
      "forecastDaily":["days":[["temperatureMax":14,"temperatureMin":6]]]]
    let w = try AppleWeatherREST.decode(JSONSerialization.data(withJSONObject: payload), at:now).snapshot
    XCTAssertEqual(w.highTemperature,14);XCTAssertEqual(w.lowTemperature,6)
  }
  @MainActor func testMenuStyleSettingsPersistAndSimpleIsTheDefault() throws {
    _ = NSApplication.shared
    let store = UserDefaults.standard, previous = store.object(forKey:"menuBarStyle")
    defer {if let previous {store.set(previous,forKey:"menuBarStyle")} else {store.removeObject(forKey:"menuBarStyle")}}
    store.removeObject(forKey:"menuBarStyle")
    XCTAssertEqual(Preferences.menuBarStyle,.simple)
    let app = AppDelegate(), item = app.makeStatusItem()
    defer {NSStatusBar.system.removeStatusItem(item);app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))}
    let menu = try XCTUnwrap(item.menu)
    let settings = try XCTUnwrap(menu.items.first{$0.title=="Settings"}?.submenu)
    let styles = try XCTUnwrap(settings.items.first{$0.title=="Menu Bar Style"}?.submenu)
    XCTAssertEqual(styles.items.map(\.title),["Simple","Compact","Full"])
    for option in styles.items {
      XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(option.action),to:option.target,from:option))
      XCTAssertEqual(Preferences.menuBarStyle.rawValue,option.representedObject as? String)
      XCTAssertEqual(option.state,.on)
    }
  }
}
