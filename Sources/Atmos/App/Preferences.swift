import AppKit

enum Snowfall: Int, CaseIterable {
  case off, light, steady, heavy, variable

  var title: String {
    switch self {
    case .off: "Off"
    case .light: "Light"
    case .steady: "Medium"
    case .heavy: "Heavy"
    case .variable: "Variable"
    }
  }

  var flakesPerMegapoint: Float {
    switch self {
    case .off: 0
    case .light: 150
    case .steady: 380
    case .heavy: 800
    case .variable: 380
    }
  }
}

enum Preferences {
  private static let defaults = UserDefaults.standard
  private static let snowfallKey = "snowfall"
  private static let behindWindowsKey = "behindWindows"
  private static let showOverFullScreenKey = "showOverFullScreen"
  private static let meltSnowKey = "meltSnow"
  private static let accumulateKey = "accumulate"
  private static let snowOnWindowsKey = "snowOnWindows"
  private static let welcomedKey = "welcomed"
  private static let showInScreenshotsKey = "showInScreenshots"
  private static let autumnKey = "autumn"

  static func registerDefaults(in store: UserDefaults = .standard) {
    let defaults = store
    let existing = [
      "weatherEffect", "liveWeather", welcomedKey, snowfallKey, autumnKey, "atmosLayeredScenes1",
    ]
    .contains { defaults.object(forKey: $0) != nil }
    if !defaults.bool(forKey: "atmosMigratedPreferences3") {
      let domain = Bundle.main.bundleIdentifier ?? "dev.grobb.Atmos"
      var stored = defaults.persistentDomain(forName: domain) ?? [:]
      // Preserve preferences from earlier Atmos builds and the original snow app.
      for legacy in ["com.mbezruchko.Atmos", "com.mbezruchko.Snowhush"] {
        guard let old = defaults.persistentDomain(forName: legacy) else { continue }
        for (key, value) in old where stored[key] == nil {
          defaults.set(value, forKey: key)
          stored[key] = value
        }
      }
      defaults.set(true, forKey: "atmosMigratedPreferences3")
    }
    if !defaults.bool(forKey: "atmosLayeredScenes1") {
      let legacy =
        defaults.string(forKey: "weatherEffect").flatMap(WeatherEffect.init(rawValue:))
        ?? (defaults.bool(forKey: autumnKey) ? .leaves : .snow)
      if legacy.isStacked {
        defaults.set(
          legacy.rawValue,
          forKey: WeatherEffect.seasonal.contains(legacy) ? "seasonalDrift" : "wildlifeEffect")
        defaults.set(WeatherEffect.none.rawValue, forKey: "weatherEffect")
      }
      defaults.set(true, forKey: "atmosLayeredScenes1")
    }
    if !existing {
      // Persist initial scene choices so later launches do not interpret migration flags as a manual selection.
      defaults.set(false, forKey: "liveWeather")
      defaults.set(WeatherEffect.none.rawValue, forKey: "weatherEffect")
    }
    let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    defaults.register(defaults: [
      snowfallKey: (calm ? Snowfall.light : .steady).rawValue,
      behindWindowsKey: false,
      showOverFullScreenKey: false,
      meltSnowKey: true,
      accumulateKey: true,
      snowOnWindowsKey: true,
      showInScreenshotsKey: false,
      autumnKey: false,
      "weatherEffect": (existing ? WeatherEffect.snow : .none).rawValue,
      "liveWeather": false,
    ])
  }

  static var snowfall: Snowfall {
    get { Snowfall(rawValue: defaults.integer(forKey: snowfallKey)) ?? .steady }
    set { defaults.set(newValue.rawValue, forKey: snowfallKey) }
  }

  static var manualWindSpeed: Double {
    get {max(0,min(100,defaults.double(forKey:"manualWindSpeed")))}
    set {defaults.set(max(0,min(100,newValue)),forKey:"manualWindSpeed")}
  }
  static var manualCloudCoverage: Double {
    get { max(0, min(100, defaults.double(forKey: "manualCloudCoverage"))) }
    set { defaults.set(max(0, min(100, newValue)), forKey: "manualCloudCoverage") }
  }

  static var snowOnWindows: Bool {
    get { defaults.bool(forKey: snowOnWindowsKey) }
    set { defaults.set(newValue, forKey: snowOnWindowsKey) }
  }

  static var accumulate: Bool {
    get { defaults.bool(forKey: accumulateKey) }
    set { defaults.set(newValue, forKey: accumulateKey) }
  }

  static var meltSnow: Bool {
    get { defaults.bool(forKey: meltSnowKey) }
    set { defaults.set(newValue, forKey: meltSnowKey) }
  }

  static var welcomed: Bool {
    get { defaults.bool(forKey: welcomedKey) }
    set { defaults.set(newValue, forKey: welcomedKey) }
  }

  static var fogBloom: Bool {
    get { defaults.object(forKey: "fogBloom") == nil || defaults.bool(forKey: "fogBloom") }
    set { defaults.set(newValue, forKey: "fogBloom") }
  }
  static var automaticUpdates: Bool {
    get { defaults.bool(forKey: "automaticUpdates") }
    set { defaults.set(newValue, forKey: "automaticUpdates") }
  }

  static var behindWindows: Bool {
    get { defaults.bool(forKey: behindWindowsKey) }
    set { defaults.set(newValue, forKey: behindWindowsKey) }
  }

  static var showOverFullScreen: Bool {
    get { defaults.bool(forKey: showOverFullScreenKey) }
    set { defaults.set(newValue, forKey: showOverFullScreenKey) }
  }

  static var showInScreenshots: Bool {
    get { defaults.bool(forKey: showInScreenshotsKey) }
    set { defaults.set(newValue, forKey: showInScreenshotsKey) }
  }

  static var autumn: Bool {
    get { defaults.bool(forKey: autumnKey) }
    set { defaults.set(newValue, forKey: autumnKey) }
  }

  static var effect: WeatherEffect {
    get {
      defaults.string(forKey: "weatherEffect").flatMap(WeatherEffect.init(rawValue:))
        ?? (autumn ? .leaves : .snow)
    }
    set {
      defaults.set(newValue.rawValue, forKey: "weatherEffect")
      autumn = newValue == .leaves
    }
  }

  static var liveWeather: Bool {
    get { defaults.bool(forKey: "liveWeather") }
    set { defaults.set(newValue, forKey: "liveWeather") }
  }

  static var reflectionConsentVersion: Int {
    get { defaults.integer(forKey: "reflectionConsentVersion") }
    set { defaults.set(newValue, forKey: "reflectionConsentVersion") }
  }

  static var screenReflections: Bool {
    get { defaults.bool(forKey: "screenReflections") }
    set { defaults.set(newValue, forKey: "screenReflections") }
  }

  static var liveReflections: Bool {
    get {
      defaults.object(forKey: "liveReflections") == nil || defaults.bool(forKey: "liveReflections")
    }
    set { defaults.set(newValue, forKey: "liveReflections") }
  }
}

enum WeatherSource: String, CaseIterable {
  case automatic, apple, openMeteo
  var title: String {
    switch self {
    case .automatic: "Automatic · Apple First"
    case .apple: "Apple Weather"
    case .openMeteo: "Open-Meteo"
    }
  }
}
extension Preferences {
  static var weatherSource: WeatherSource {
    get {
      UserDefaults.standard.string(forKey: "weatherSource").flatMap(WeatherSource.init(rawValue:))
        ?? .automatic
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "weatherSource") }
  }
}

extension Preferences {
  static var reflectionConsentIdentity: String {
    get { UserDefaults.standard.string(forKey: "reflectionConsentIdentity") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "reflectionConsentIdentity") }
  }
}

extension Preferences {
  static var seasonalDrift: WeatherEffect? {
    get {
      defaults.string(forKey: "seasonalDrift").flatMap(WeatherEffect.init(rawValue:)).flatMap {
        WeatherEffect.seasonal.contains($0) ? $0 : nil
      }
    }
    set { defaults.set(newValue?.rawValue, forKey: "seasonalDrift") }
  }
  static var wildlifeEffect: WeatherEffect? {
    get {
      defaults.string(forKey: "wildlifeEffect").flatMap(WeatherEffect.init(rawValue:)).flatMap {
        WeatherEffect.wildlife.contains($0) ? $0 : nil
      }
    }
    set { defaults.set(newValue?.rawValue, forKey: "wildlifeEffect") }
  }
  static var manualScene: WeatherScene {
    get {
      var scene = WeatherScene(primary: effect, stacked: seasonalDrift, wildlife: wildlifeEffect)
      let cover = defaults.object(forKey: "manualCloudCoverage") == nil ? effect.defaultCloudCoverage : manualCloudCoverage
      scene.manualCloudCover = Float(cover / 100); scene.clouds = Float(cover / 100)
      return scene
    }
    set {
      effect = newValue.primary
      seasonalDrift = newValue.stacked
      wildlifeEffect = newValue.wildlife
      manualCloudCoverage = newValue.manualCloudCover.map { (Double($0) * 100).rounded() } ?? newValue.primary.defaultCloudCoverage
    }
  }
}
