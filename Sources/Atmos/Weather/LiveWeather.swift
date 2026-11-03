import AppKit
import CoreLocation

/// Location and weather are requested only while Live Weather is selected and the session is awake.
/// Coordinates stay in memory; only rounded coordinates are sent to Open-Meteo over HTTPS.
final class LiveWeather: NSObject, CLLocationManagerDelegate {
  private(set) var enabled = false
  private(set) var snapshot: WeatherSnapshot?
  private(set) var status = "Live Weather is off"
  private(set) var updatedAt: Date?
  private(set) var locationName = "Waiting for location"
  private(set) var locationDetail = ""
  private(set) var provider =
    AppleWeather.isAvailable ? "Apple Weather" : "Open-Meteo · Apple Weather fallback"
  private(set) var providerURL = URL(string: "https://open-meteo.com/")!
  private(set) var attributionMark: NSImage?
  private let geocoder = CLGeocoder()
  private var appleRetryAt = Date.distantPast
  var changed: () -> Void = {}

  private var manager: CLLocationManager?
  private var coordinate: CLLocation?
  private var timer: Timer?
  private var locationTimeout: Timer?
  private var expiryTimer: Timer?
  private var task: Task<Void, Never>?
  private var generation = 0
  private var failures = 0
  private var suspended = false
  private var lastRequest = Date.distantPast
  private var locating = false
  var locationAuthorization: CLAuthorizationStatus {
    (manager ?? CLLocationManager()).authorizationStatus
  }
  var isLocating: Bool { locating }
  var isSuspended: Bool { suspended }
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  var current: WeatherSnapshot? {
    guard enabled, let snapshot, snapshot.isUsable() else { return nil }
    return snapshot
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != self.enabled else { return }
    self.enabled = enabled
    cancel()
    if enabled {
      if manager == nil {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 5_000
        self.manager = manager
        manager.delegate = self
      }
      refresh(force: true)
    } else {
      coordinate = nil
      locationName = "Location access is off"
      locationDetail = ""
      snapshot = nil
      updatedAt = nil
      status = "Live Weather is off"
      changed()
    }
  }

  func setSource(_ source: WeatherSource) {
    Preferences.weatherSource = source
    cancel()
    snapshot = nil
    updatedAt = nil
    appleRetryAt = .distantPast
    provider = source == .openMeteo ? "Open-Meteo" : "Apple Weather"
    if enabled { refresh(force: true) }
    changed()
  }

  func setSuspended(_ suspended: Bool) {
    guard self.suspended != suspended else { return }
    self.suspended = suspended
    if suspended {
      cancel()
    } else if enabled {
      scheduleExpiry()
      refresh(force: true)
    }
  }

  func refresh(force: Bool = false) {
    guard enabled, !suspended, task == nil, !locating else { return }
    guard force || Date().timeIntervalSince(lastRequest) >= 60 else { return }
    timer?.invalidate()
    if Preferences.weatherSource == .apple && !AppleWeather.isAvailable {
      snapshot = nil
      status = "Apple Weather is unavailable on this Mac"
      provider = "Apple Weather · Unavailable"
      changed()
      return
    }
    guard let manager else { return }
    switch manager.authorizationStatus {
    case .notDetermined:
      status = "Allow location access to follow your weather"
      changed()
      NSApp.activate(ignoringOtherApps: true)
      manager.requestWhenInUseAuthorization()
    case .authorized, .authorizedAlways:
      if let coordinate, abs(coordinate.timestamp.timeIntervalSinceNow) < 3600 {
        if locationName.hasPrefix("Approximate location:") { resolveName(coordinate) }
        fetch(coordinate.coordinate)
      } else {
        locating = true
        status = "Finding your local weather…"
        changed()
        manager.requestLocation()
        locationTimeout = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) {
          [weak self] _ in
          guard let self, locating else { return }
          manager.stopUpdatingLocation()
          locating = false
          failed("Location unavailable — retrying shortly")
        }
      }
    case .denied, .restricted:
      coordinate = nil
      locationName = "Location access is off"
      locationDetail = ""
      snapshot = nil
      updatedAt = nil
      status = "Location access is off — using your manual mode"
      changed()
      schedule(after: 900)
    @unknown default:
      failed("Location unavailable — using your manual mode")
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard enabled, !suspended else { return }
    // A revoked grant cancels even an already-running request and drops its coordinates.
    if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
      cancel()
    }
    refresh(force: true)
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard enabled, !suspended,
      manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways
    else { return }
    locationTimeout?.invalidate()
    locating = false
    guard let location = locations.last, location.horizontalAccuracy >= 0,
      abs(location.timestamp.timeIntervalSinceNow) < 600,
      CLLocationCoordinate2DIsValid(location.coordinate)
    else {
      failed("Location unavailable — retrying shortly")
      return
    }
    coordinate = location
    locationDetail = String(
      format: "Approximate location: %.2f°, %.2f°", location.coordinate.latitude,
      location.coordinate.longitude)
    locationName = locationDetail
    resolveName(location)
    fetch(location.coordinate)
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard enabled, !suspended, locating else { return }
    locationTimeout?.invalidate()
    locating = false
    failed("Location unavailable — retrying shortly")
  }

  private func fetch(_ coordinate: CLLocationCoordinate2D) {
    guard task == nil, enabled, !suspended, let manager,
      manager.authorizationStatus == .authorized
        || manager.authorizationStatus == .authorizedAlways,
      let url = WeatherAPI.url(latitude: coordinate.latitude, longitude: coordinate.longitude)
    else { return }
    lastRequest = Date()
    let token = generation
    status = current == nil ? "Checking local weather…" : "Updating local weather…"
    changed()
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        var weather: WeatherSnapshot?
        if Preferences.weatherSource != .openMeteo && AppleWeather.isAvailable
          && (Preferences.weatherSource == .apple || Date() >= appleRetryAt)
        {
          do {
            let rounded = CLLocation(
              latitude: (coordinate.latitude * 100).rounded() / 100,
              longitude: (coordinate.longitude * 100).rounded() / 100)
            let reading = try await AppleWeather.fetch(at: rounded)
            guard enabled, !suspended, generation == token, !Task.isCancelled else { return }
            if attributionMark == nil {
              let (markData, _) = try await session.data(
                from: reading.attribution.combinedMarkDarkURL)
              guard enabled, !suspended, generation == token, !Task.isCancelled else { return }
              guard let mark = NSImage(data: markData) else {
                throw URLError(.cannotDecodeContentData)
              }
              let ratio = mark.size.width / max(1, mark.size.height)
              mark.size = NSSize(width: 16 * ratio, height: 16)
              mark.isTemplate = true
              attributionMark = mark
            }
            provider = "Apple Weather"
            providerURL = reading.attribution.legalPageURL
            weather = reading.snapshot
          } catch {
            guard generation == token, enabled, !suspended, !Task.isCancelled else { return }
            if Preferences.weatherSource == .apple { throw error }
            appleRetryAt = Date().addingTimeInterval(3600)
          }
        }
        if weather == nil {
          let (data, response) = try await session.data(from: url)
          guard enabled, !suspended, generation == token, !Task.isCancelled else { return }
          weather = try WeatherAPI.decode(data, response: response)
          provider =
            Preferences.weatherSource == .openMeteo
            ? "Open-Meteo" : "Open-Meteo · Apple Weather fallback"
          providerURL = URL(string: "https://open-meteo.com/")!
        }
        guard let weather else { throw URLError(.cannotParseResponse) }
        task = nil
        snapshot = weather
        updatedAt = Date()
        failures = 0
        status =
          "\(weather.condition) · \(Int(weather.temperature.rounded()))°C · \(Int(weather.windSpeed.rounded())) km/h"
        changed()
        scheduleExpiry()
        schedule(after: 900)
      } catch {
        guard generation == token, enabled, !suspended, !Task.isCancelled else { return }
        task = nil
        failed(
          "Weather unavailable — \(current == nil ? "using your manual mode" : "keeping recent weather")"
        )
      }
    }
  }

  private func resolveName(_ location: CLLocation) {
    let token = generation
    let rounded = CLLocation(
      latitude: (location.coordinate.latitude * 100).rounded() / 100,
      longitude: (location.coordinate.longitude * 100).rounded() / 100)
    geocoder.cancelGeocode()
    geocoder.reverseGeocodeLocation(rounded) { [weak self] places, _ in
      guard let self, enabled, !suspended, generation == token, let place = places?.first else {
        return
      }
      let components = [
        place.locality ?? place.subAdministrativeArea, place.administrativeArea, place.country,
      ].compactMap { $0 }
      var unique: [String] = []
      for component in components where !unique.contains(component) { unique.append(component) }
      if !unique.isEmpty {
        locationName = unique.joined(separator: ", ")
        changed()
      }
    }
  }

  private func failed(_ message: String) {
    failures += 1
    status = message
    changed()
    schedule(after: failures == 1 ? 60 : failures == 2 ? 300 : 900)
  }

  private func schedule(after interval: TimeInterval) {
    timer?.invalidate()
    guard enabled, !suspended else { return }
    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.refresh() }
    timer.tolerance = min(30, interval * 0.1)
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func scheduleExpiry() {
    expiryTimer?.invalidate()
    guard let snapshot else { return }
    let interval = max(1, snapshot.time + 7201 - Date().timeIntervalSince1970)
    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      guard let self, enabled, !suspended, current == nil else { return }
      self.snapshot = nil
      status = "Weather is out of date — using your manual mode"
      changed()
    }
    RunLoop.main.add(timer, forMode: .common)
    expiryTimer = timer
  }

  private func cancel() {
    generation += 1
    task?.cancel()
    task = nil
    timer?.invalidate()
    locationTimeout?.invalidate()
    expiryTimer?.invalidate()
    manager?.stopUpdatingLocation()
    geocoder.cancelGeocode()
    locating = false
  }

  func stop() {
    cancel()
    session.invalidateAndCancel()
  }
}
