import AppKit

@main
enum AtmosApp {
  static func main() {
    let app = NSApplication.shared
    if CommandLine.arguments.contains("--profile-visible-fog") || CommandLine.arguments.contains("--profile-visible-storm") {
      app.setActivationPolicy(.prohibited)
      Task { @MainActor in
        await CaptureDiagnostics.visibleFog(storm: CommandLine.arguments.contains("--profile-visible-storm"))
        exit(0)
      }
      app.run(); return
    }
    if CommandLine.arguments.contains("--profile-desktop-capture") {
      app.setActivationPolicy(.prohibited)
      Task { @MainActor in await CaptureDiagnostics.run(); exit(0) }
      app.run(); return
    }
    if CommandLine.arguments.contains("--verify-native-weatherkit") {
      app.setActivationPolicy(.prohibited)
      Task { @MainActor in
        do {
          try await AppleWeather.verifyNativeAccess()
          print("Native WeatherKit verified without personal credentials")
          exit(0)
        } catch {
          let failure = error as NSError
          print("Native WeatherKit verification failed: \(failure.domain) (\(failure.code))")
          exit(1)
        }
      }
      app.run()
      return
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }
}
