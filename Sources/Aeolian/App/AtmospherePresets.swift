import Foundation

struct AtmospherePreset: Codable, Equatable, Identifiable {
  var id = UUID()
  var name: String
  var weather: WeatherEffect
  var drift: WeatherEffect?
  var wildlife: WeatherEffect?
  var intensity: Int
  var wind: Double
  var cloudCoverage: Double = 0

  var scene: WeatherScene {
    var scene = WeatherScene(primary: weather, stacked: drift, wildlife: wildlife)
    scene.manualCloudCover = Float(cloudCoverage / 100); scene.clouds = Float(cloudCoverage / 100)
    return scene
  }
  var icon: WeatherEffect { weather != .none ? weather : drift ?? wildlife ?? .none }
  var isValid: Bool {
    icon != .none && !weather.isStacked && (drift == nil || WeatherEffect.seasonal.contains(drift!))
      && (wildlife == nil || WeatherEffect.wildlife.contains(wildlife!))
      && Snowfall(rawValue: intensity) != nil && wind.isFinite && (0...100).contains(wind)
      && cloudCoverage.isFinite && (0...100).contains(cloudCoverage)
  }
  static func current(name: String, id: UUID? = nil) -> Self {
    Self(id: id ?? UUID(), name: name, weather: Preferences.manualScene.primary,
      drift: Preferences.manualScene.stacked, wildlife: Preferences.manualScene.wildlife,
      intensity: Preferences.snowfall.rawValue, wind: Preferences.manualWindSpeed,
      cloudCoverage: (Double(Preferences.manualScene.manualCloudCover ?? 0) * 100).rounded())
  }
}

/// Small versioned snapshots, independent of live weather and global permissions.
final class AtmosphereLibrary {
  static let shared = AtmosphereLibrary()
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  var hasDraft: Bool { defaults.object(forKey: "atmosphereDraftName") != nil }
  var name: String {
    get { defaults.string(forKey: "atmosphereDraftName") ?? nextName }
    set {
      let name = Self.cleanName(newValue)
      defaults.set(name, forKey: "atmosphereDraftName")
      if name.hasPrefix("atmos"), let number = Int(name.dropFirst(5)), number > 0 {
        defaults.set(max(number, defaults.integer(forKey: "atmosphereNameSequence")), forKey: "atmosphereNameSequence")
      }
    }
  }
  var selectedID: UUID? {
    get { defaults.string(forKey: "selectedAtmosphereID").flatMap(UUID.init(uuidString:)) }
    set { defaults.set(newValue?.uuidString, forKey: "selectedAtmosphereID") }
  }
  var presets: [AtmospherePreset] {
    guard let data = defaults.data(forKey: "atmospherePresets1"),
      let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    var seen = Set<UUID>()
    return records.prefix(200).compactMap { record in
      var record = record
      if record["cloudCoverage"] == nil {
        record["cloudCoverage"] = (record["weather"] as? String).flatMap(WeatherEffect.init(rawValue:))?.defaultCloudCoverage ?? 0
      }
      guard let data = try? JSONSerialization.data(withJSONObject: record),
        var preset = try? JSONDecoder().decode(AtmospherePreset.self, from: data),
        preset.isValid, seen.insert(preset.id).inserted else { return nil }
      preset.name = Self.cleanName(preset.name)
      return preset
    }
  }
  func save(_ preset: AtmospherePreset) {
    guard preset.isValid else { return }
    var preset = preset; preset.name = Self.cleanName(preset.name)
    var items = presets
    if defaults.integer(forKey: "atmosphereNameSequence") == 0 {
      defaults.set(1, forKey: "atmosphereNameSequence")
    }
    if let index = items.firstIndex(where: { $0.id == preset.id }) { items[index] = preset }
    else { items.insert(preset, at: 0) }
    persist(Array(items.prefix(200)))
    selectedID = preset.id; name = preset.name
  }
  func remove(_ id: UUID) {
    persist(presets.filter { $0.id != id })
    if selectedID == id { selectedID = nil }
  }
  private var nextName: String { "atmos\(max(0, defaults.integer(forKey: "atmosphereNameSequence"))+1)" }
  func newDraft() { selectedID = nil; name = nextName }
  private func persist(_ items: [AtmospherePreset]) {
    if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: "atmospherePresets1") }
  }
  private static func cleanName(_ name: String) -> String {
    let name = String(name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(48))
    return name.isEmpty ? "Untitled atmosphere" : name
  }
}
