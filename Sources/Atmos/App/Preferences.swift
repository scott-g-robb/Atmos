import AppKit

enum Snowfall: Int, CaseIterable {
  case off, light, steady, heavy, variable

  var title: String {
    switch self {
    case .off: "Off"
    case .light: "Light"
    case .steady: "Steady"
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
  private static let halloweenKey = "halloweenOn"
  private static let halloweenSkippedKey = "halloweenSkipped"
  private static let autumnKey = "autumn"

  static func registerDefaults() {
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
    let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    defaults.register(defaults: [
      snowfallKey: (calm ? Snowfall.light : .steady).rawValue,
      behindWindowsKey: false,
      showOverFullScreenKey: false,
      meltSnowKey: true,
      accumulateKey: true,
      snowOnWindowsKey: true,
      showInScreenshotsKey: false,
      halloweenKey: false,
      halloweenSkippedKey: 0,
      autumnKey: false,
    ])
  }

  static var snowfall: Snowfall {
    get { Snowfall(rawValue: defaults.integer(forKey: snowfallKey)) ?? .steady }
    set { defaults.set(newValue.rawValue, forKey: snowfallKey) }
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

  /// Halloween turned on from the menu, for every day.
  static var halloween: Bool {
    get { defaults.bool(forKey: halloweenKey) }
    set { defaults.set(newValue, forKey: halloweenKey) }
  }

  /// The year whose Halloween was turned off from the menu, zero for none.
  static var halloweenSkipped: Int {
    get { defaults.integer(forKey: halloweenSkippedKey) }
    set { defaults.set(newValue, forKey: halloweenSkippedKey) }
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
