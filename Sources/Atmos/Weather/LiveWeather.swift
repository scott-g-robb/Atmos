import AppKit
import CoreLocation
import Network

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
  private var recovery = WeatherRecovery()
  private var appleFailures = 0
  private var networkMonitor: NWPathMonitor?
  private var attributionTask: Task<Void, Never>?
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
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 1_000
        self.manager = manager
        manager.delegate = self
      }
      recovery.resume()
      startNetworkMonitor()
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
    appleFailures = 0
    startNetworkMonitor()
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
      recovery.resume()
      appleFailures = 0
      failures = 0
      lastRequest = .distantPast
      startNetworkMonitor()
      scheduleExpiry()
      refresh(force: true)
    }
  }

  func refresh(force: Bool = false) {
    guard enabled, !suspended else { return }
    if force, task != nil, Date().timeIntervalSince(lastRequest) > 5 { cancelRequest() }
    guard task == nil, !locating else { return }
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
      if let coordinate, abs(coordinate.timestamp.timeIntervalSinceNow) < 600 {

        if locationName.hasPrefix("Approximate location:") { resolveName(coordinate) }
        fetch(coordinate.coordinate)
      } else {
        // The last in-memory approximate position can bridge location-service wakeup.
        // A fresh location is still requested, and a move cancels any old-position request.
        if recovery.isRecovering(), let coordinate,
          abs(coordinate.timestamp.timeIntervalSinceNow) < 86400
        {
          fetch(coordinate.coordinate)
        }
        locating = true
        status = "Finding your local weather…"
        changed()
        manager.requestLocation()
        locationTimeout = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) {
          [weak self] _ in
          guard let self, locating else { return }
          manager.stopUpdatingLocation()
          locating = false
          if task == nil {
            failed(
              current == nil
                ? "Location unavailable — retrying shortly"
                : "Location unavailable — keeping recent weather")
          }
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
    startNetworkMonitor()
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
    let moved = coordinate.map { location.distance(from: $0) > 2000 } ?? true
    if moved && task != nil { cancelRequest() }
    coordinate = location
    locationDetail = String(
      format: "Approximate location: %.3f°, %.3f°", location.coordinate.latitude,
      location.coordinate.longitude)
    locationName = locationDetail
    resolveName(location)
    if moved || current == nil || (updatedAt.map { Date().timeIntervalSince($0) > 60 } ?? true) {
      fetch(location.coordinate)
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard enabled, !suspended, locating else { return }
    locationTimeout?.invalidate()
    locating = false
    if task == nil {
      failed(
        current == nil
          ? "Location unavailable — retrying shortly"
          : "Location unavailable — keeping recent weather")
    }
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
        let source = Preferences.weatherSource
        let reading = try await WeatherRequest.fetch(
          source: source, appleAvailable: AppleWeather.isAvailable,
          apple: {
            let rounded = CLLocation(
              latitude: (coordinate.latitude * 100).rounded() / 100,
              longitude: (coordinate.longitude * 100).rounded() / 100)
            return try await AppleWeather.fetch(at: rounded)
          },
          openMeteo: {
            let (data, response) = try await self.session.data(from: url)
            return try WeatherAPI.decode(data, response: response)
          })
        guard enabled, !suspended, generation == token, !Task.isCancelled else { return }
        var weather = reading.snapshot
        var refreshAfter: TimeInterval = 900
        switch reading {
        case .apple(let apple):
          appleFailures = 0
          provider = "Apple Weather"
          providerURL = apple.attribution.legalPageURL
          loadAttributionMark(apple.attribution, generation: token)
        case .openMeteo:
          provider = source == .openMeteo ? "Open-Meteo" : "Open-Meteo · Apple Weather fallback"
          providerURL = URL(string: "https://open-meteo.com/")!
          if source == .automatic && (AppleWeather.isAvailable || recovery.isRecovering()) {
            appleFailures += 1
            refreshAfter = WeatherRecovery.appleRetryDelay(appleFailures)
          }
        }
        weather.latitude = (coordinate.latitude * 100).rounded() / 100
        task = nil
        snapshot = weather
        updatedAt = Date()
        failures = 0
        status =
          "\(weather.condition) · \(Int(weather.temperature.rounded()))°C · \(Int(weather.windSpeed.rounded())) km/h"
        changed()
        scheduleExpiry()
        schedule(after: refreshAfter)
      } catch {
        guard generation == token, enabled, !suspended, !Task.isCancelled else { return }
        task = nil
        failed(
          "Weather unavailable — \(current == nil ? "using your manual mode" : "keeping recent weather")"
        )
      }
    }
  }

  private func loadAttributionMark(_ attribution: AppleWeather.Attribution, generation token: Int) {
    guard attributionMark == nil, attributionTask == nil else { return }
    attributionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { if generation == token { attributionTask = nil } }
      do {
        let (data, response) = try await session.data(from: attribution.combinedMarkDarkURL)
        guard enabled, !suspended, generation == token, !Task.isCancelled,
          (response as? HTTPURLResponse)?.statusCode == 200, data.count < 262144,
          let mark = NSImage(data: data), mark.size.height > 0
        else { return }
        let ratio = mark.size.width / mark.size.height
        mark.size = NSSize(width: 16 * ratio, height: 16)
        mark.isTemplate = true
        attributionMark = mark
        changed()
      } catch { /* Keep the successful Apple reading and the visible textual attribution. */  }
    }
  }

  private func startNetworkMonitor() {
    guard enabled, !suspended, networkMonitor == nil else { return }
    let monitor = NWPathMonitor()
    networkMonitor = monitor
    var reachable = false
    monitor.pathUpdateHandler = { [weak self, weak monitor] path in
      let recovered = path.status == .satisfied && !reachable
      reachable = path.status == .satisfied
      guard recovered else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak monitor] in
        guard let self, let monitor, enabled, !suspended, networkMonitor === monitor else { return }
        // Wi-Fi and WeatherKit often become ready after the display wakes.
        refresh(force: true)
      }
    }
    monitor.start(queue: DispatchQueue(label: "Atmos.WeatherNetwork"))
  }

  private func resolveName(_ location: CLLocation) {
    let token = generation
    let rounded = CLLocation(
      latitude: (location.coordinate.latitude * 1000).rounded() / 1000,
      longitude: (location.coordinate.longitude * 1000).rounded() / 1000)
    geocoder.cancelGeocode()
    geocoder.reverseGeocodeLocation(rounded) { [weak self] places, _ in
      guard let self, enabled, !suspended, generation == token, let place = places?.first else {
        return
      }
      if let name = LocationPresentation.name(
        district: place.subLocality,
        city: place.locality ?? place.subAdministrativeArea, region: place.administrativeArea,
        country: place.country)
      {
        locationName = name
        changed()
      }
    }
  }

  private func failed(_ message: String) {
    failures += 1
    status = message
    changed()
    schedule(after: recovery.failureDelay(failures))
  }

  private func schedule(after interval: TimeInterval) {
    timer?.invalidate()
    guard enabled, !suspended else { return }
    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      self?.refresh(force: true)
    }
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
      status = "Updating weather after a long pause…"
      changed()
      refresh(force: true)
    }
    RunLoop.main.add(timer, forMode: .common)
    expiryTimer = timer
  }

  private func cancelRequest() {
    generation += 1
    task?.cancel()
    task = nil
    attributionTask?.cancel()
    attributionTask = nil
  }

  private func cancel() {
    cancelRequest()
    networkMonitor?.cancel()
    networkMonitor = nil
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
