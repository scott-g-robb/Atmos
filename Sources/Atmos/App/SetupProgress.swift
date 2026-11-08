import Foundation

struct SetupProgress {
  enum Page { case welcome, permissions, customisation, menuBar, complete }
  enum Completion { case skipped, menuBar }
  private(set) var page: Page = .welcome
  private(set) var completion: Completion?
  var isPaused: Bool { completion == nil }
  mutating func next() {
    if page == .welcome { page = .permissions }
    else if page == .permissions { page = .customisation }
    else if page == .customisation { page = .menuBar }
  }
  mutating func back() {
    if page == .permissions { page = .welcome }
    else if page == .customisation { page = .permissions }
  }
  mutating func skip() { page = .complete; completion = .skipped }
  mutating func openedMenu() {
    if page == .menuBar { page = .complete; completion = .menuBar }
  }
  static func liveWeather(after completion: Completion, previous: Bool, locationGranted: Bool) -> Bool {
    completion == .skipped ? previous : locationGranted
  }

  static var release: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return "\(info["CFBundleShortVersionString"] as? String ?? "development").\(info["CFBundleVersion"] as? String ?? "0")"
  }
  /// File identities change when Finder or an installer replaces this copy,
  /// even when the downloaded app has the same version/build as before.
  static func installationID(at app: URL = Bundle.main.bundleURL) -> String {
    let root = app.resolvingSymlinksInPath()
    let paths = [root, root.appendingPathComponent("Contents/MacOS/Atmos")]
    return paths.map { url in
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let volume = attributes[.systemNumber] as? NSNumber,
        let file = attributes[.systemFileNumber] as? NSNumber else { return url.path }
      return "\(volume):\(file)"
    }.joined(separator: "/")
  }
  static func needsPresentation(in defaults: UserDefaults = .standard, release: String = release,
    installation: String = installationID()) -> Bool {
    defaults.string(forKey: "completedSetupRelease") != release
      || defaults.string(forKey: "completedSetupInstallation") != installation
  }
  static func complete(in defaults: UserDefaults = .standard, release: String = release,
    installation: String = installationID()) {
    defaults.set(release, forKey: "completedSetupRelease")
    defaults.set(installation, forKey: "completedSetupInstallation")
  }
  static func recordAutomaticRelaunch(release: String, path: String, in defaults: UserDefaults = .standard) {
    defaults.set(["release": release, "path": path, "time": Date().timeIntervalSince1970], forKey: "automaticUpdateRelaunch")
    defaults.synchronize()
  }
  static func consumeAutomaticRelaunch(in defaults: UserDefaults = .standard, release: String = release,
    path: String = Bundle.main.bundleURL.resolvingSymlinksInPath().path,
    arguments: [String] = CommandLine.arguments, now: Date = Date(),
    installation: String = installationID()) -> Bool {
    guard let receipt = defaults.dictionary(forKey: "automaticUpdateRelaunch") else { return false }
    defaults.removeObject(forKey: "automaticUpdateRelaunch")
    let age = now.timeIntervalSince1970 - (receipt["time"] as? Double ?? 0)
    guard defaults.bool(forKey: "automaticUpdates"), arguments.contains("--atmos-auto-update"),
      receipt["release"] as? String == release, receipt["path"] as? String == path, age >= 0, age < 600 else { return false }
    complete(in: defaults, release: release, installation: installation)
    return true
  }
}
