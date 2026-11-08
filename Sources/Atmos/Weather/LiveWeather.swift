import AppKit
import CoreLocation
import Network

/// The system manager in production; replaceable without requesting real location
/// or contacting providers in retry/lifecycle tests.
protocol WeatherLocationClient: AnyObject {
  var authorizationStatus: CLAuthorizationStatus { get }
  var delegate: CLLocationManagerDelegate? { get set }
  func requestWhenInUseAuthorization()
  func requestLocation()
  func stopUpdatingLocation()
}
extension CLLocationManager: WeatherLocationClient {}

/// Location and weather are requested only while Live Weather is selected and the session is awake.
/// Coordinates stay in memory; only rounded coordinates are sent to Open-Meteo over HTTPS.
final class LiveWeather: NSObject, CLLocationManagerDelegate {
  private(set) var enabled = false
  private(set) var snapshot: WeatherSnapshot?
  private(set) var status = "Live Weather is off"
  private(set) var updatedAt: Date?
  private(set) var locationName = "Waiting for location"
  private(set) var locationDetail = ""
  private(set) var provider = "Apple Weather"
  private(set) var providerURL = URL(string: "https://open-meteo.com/")!
  private(set) var attributionMark: NSImage?
  private let geocoder = CLGeocoder()
  private var recovery = WeatherRecovery()
  private var appleFailures = 0
  private var networkMonitor: NWPathMonitor?
  private var attributionTask: Task<Void, Never>?
  var changed: () -> Void = {}
  var failureLimitReached: () -> Void = {}
  /// Setup presents the reason before asking macOS. A skipped setup leaves the
  /// request available through Live Weather or Refresh Weather.
  var requestsLocationAuthorization = true

  typealias Request = (WeatherSource, CLLocationCoordinate2D, String?) async throws -> WeatherRequest.Reading
  struct Timing {
    var locationTimeout: TimeInterval = 25
    var requestTimeout: TimeInterval = 25
    var retryInterval: (TimeInterval) -> TimeInterval = { $0 }
    var refreshInterval: TimeInterval = 900
  }
  private let makeLocation: () -> WeatherLocationClient
  private let appleAvailable: () -> Bool
  private let requestWeather: Request?
  private let observesNetwork: Bool
  private let resolvesNames: Bool
  private let timing: Timing
  private var manager: WeatherLocationClient?
  private var knownAuthorization: CLAuthorizationStatus?
  private var requestTimeout: Timer?
  private var coordinate: CLLocation?
  private var timer: Timer?
  private var locationTimeout: Timer?
  private var expiryTimer: Timer?
  private var alertTimer: Timer?
  private var countryCode: String?
  private var task: Task<Void, Never>?
  private var generation = 0
  private var suspended = false
  private var lastRequest = Date.distantPast
  private var locating = false
  private var fetchAfterLocation = false
  var locationAuthorization: CLAuthorizationStatus {
    ensureLocationManager().authorizationStatus
  }
  var isLocating: Bool { locating }
  var isRefreshing: Bool { locating || task != nil }
  var isSuspended: Bool { suspended }
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  init(makeLocation: @escaping () -> WeatherLocationClient = {
    WeatherLocationManager()
  }, appleAvailable: @escaping () -> Bool = { AppleWeather.isAvailable },
    requestWeather: Request? = nil, observesNetwork: Bool = true,
    resolvesNames: Bool = true, timing: Timing = Timing()) {
    self.makeLocation = makeLocation
    self.appleAvailable = appleAvailable
    self.requestWeather = requestWeather
    self.observesNetwork = observesNetwork
    self.resolvesNames = resolvesNames
    self.timing = timing
    super.init()
    provider = appleAvailable() ? "Apple Weather" : "Open-Meteo · Apple Weather fallback"
  }

  var current: WeatherSnapshot? {
    guard enabled, let snapshot, snapshot.isUsable() else { return nil }
    return snapshot
  }

  /// Setup's explicit permission action is independent of provider availability.
  func requestLocationAccess() {
    requestsLocationAuthorization = true
    let manager = ensureLocationManager()
    guard manager.authorizationStatus == .notDetermined else { return }
    NSApp.activate(ignoringOtherApps: true)
    manager.requestWhenInUseAuthorization()
  }

  @discardableResult private func ensureLocationManager() -> WeatherLocationClient {
    if let manager { return manager }
    let manager = makeLocation()
    self.manager = manager
    knownAuthorization = manager.authorizationStatus
    manager.delegate = self
    return manager
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != self.enabled else { return }
    self.enabled = enabled
    cancel()
    if enabled {
      ensureLocationManager()
      recovery.resume()
      startNetworkMonitor()
      refresh(force: true, automatic: true)
    } else {
      coordinate = nil
      countryCode = nil
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
    recovery.resetRetries()
    snapshot = nil
    updatedAt = nil
    appleFailures = 0
    startNetworkMonitor()
    provider = source == .openMeteo ? "Open-Meteo" : "Apple Weather"
    if enabled { refresh(force: true, automatic: true) }
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
      lastRequest = .distantPast
      startNetworkMonitor()
      scheduleExpiry()
      refresh(force: true, automatic: true)
    }
  }

  func refresh(force: Bool = false, automatic: Bool = false, renewLocation: Bool = false) {
    guard enabled, !suspended, !automatic || !recovery.exhausted else { return }
    if automatic, recovery.failedAttempts > 0, timer?.isValid == true { return }
    if !automatic {
      recovery.resetRetries()
      timer?.invalidate()
      timer = nil
      if force { cancelRequest(); cancelLocationRequest() }
    }
    if force, task != nil, Date().timeIntervalSince(lastRequest) > 5 { cancelRequest() }
    guard task == nil, !locating else { return }
    guard force || Date().timeIntervalSince(lastRequest) >= 60 else { return }
    timer?.invalidate()
    let manager = ensureLocationManager()
    switch manager.authorizationStatus {
    case .notDetermined:
      status = "Allow location access to follow your weather"
      changed()
      guard requestsLocationAuthorization else { return }
      NSApp.activate(ignoringOtherApps: true)
      manager.requestWhenInUseAuthorization()
    case .authorized, .authorizedAlways:
      if !renewLocation, let coordinate, abs(coordinate.timestamp.timeIntervalSinceNow) < 600 {

        if locationName.hasPrefix("Approximate location:") { resolveName(coordinate) }
        fetch(coordinate.coordinate)
      } else {
        // The last in-memory approximate position can bridge location-service wakeup.
        // A fresh location is still requested, and a move cancels any old-position request.
        if !renewLocation, recovery.isRecovering(), let coordinate,
          abs(coordinate.timestamp.timeIntervalSinceNow) < 86400
        {
          fetch(coordinate.coordinate)
        }
        locating = true
        fetchAfterLocation = renewLocation
        status = current == nil ? "Finding your local weather…" : "Updating your location and weather…"
        let token = generation
        let timeout = Timer(timeInterval: timing.locationTimeout, repeats: false) { [weak self] _ in
          guard let self, enabled, !suspended, generation == token, locating else { return }
          cancelLocationRequest()
          if task == nil {
            failed(current == nil ? "Location unavailable" : "Location unavailable — keeping recent weather")
          }
        }
        locationTimeout = timeout
        RunLoop.main.add(timeout, forMode: .common)
        manager.requestLocation()
        changed()
      }
    case .denied, .restricted:
      coordinate = nil
      locationName = "Location access is off"
      locationDetail = ""
      snapshot = nil
      updatedAt = nil
      status = "Location access is off — allow Location in Settings"
      changed()
      schedule(after: 900)
    @unknown default:
      failed("Location unavailable")
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let authorization = locationAuthorization
    let changedGrant = knownAuthorization != authorization
    knownAuthorization = authorization
    guard enabled, !suspended, changedGrant else { return }
    // Duplicate initial callbacks must not clear a pending retry or its budget.
    cancel()
    recovery.resetRetries()
    startNetworkMonitor()
    refresh(force: true, automatic: true)
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard enabled, !suspended, locating, !recovery.exhausted,
      locationAuthorization == .authorized || locationAuthorization == .authorizedAlways
    else { return }
    locationTimeout?.invalidate()
    locationTimeout = nil
    locating = false
    let renewWeather = fetchAfterLocation
    fetchAfterLocation = false
    guard let location = locations.last, location.horizontalAccuracy >= 0,
      abs(location.timestamp.timeIntervalSinceNow) < 600,
      CLLocationCoordinate2DIsValid(location.coordinate)
    else {
      failed("Location unavailable")
      return
    }
    let moved = coordinate.map { location.distance(from: $0) > 2000 } ?? true
    if moved && task != nil { cancelRequest() }
    if moved { countryCode = nil }
    coordinate = location
    locationDetail = String(
      format: "Approximate location: %.3f°, %.3f°", location.coordinate.latitude,
      location.coordinate.longitude)
    if current == nil { locationName = locationDetail }
    resolveName(location)
    if renewWeather || moved || current == nil || (updatedAt.map { Date().timeIntervalSince($0) > 60 } ?? true) {
      fetch(location.coordinate)
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard enabled, !suspended, locating else { return }
    locationTimeout?.invalidate()
    locationTimeout = nil
    locating = false
    if task == nil {
      failed(
        current == nil
          ? "Location unavailable"
          : "Location unavailable — keeping recent weather")
    }
  }

  private func fetch(_ coordinate: CLLocationCoordinate2D) {
    guard task == nil, enabled, !suspended,
      locationAuthorization == .authorized
        || locationAuthorization == .authorizedAlways,
      let url = WeatherAPI.url(latitude: coordinate.latitude, longitude: coordinate.longitude)
    else { return }
    lastRequest = Date()
    let token = generation
    status = current == nil ? "Checking local weather…" : "Updating local weather…"
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let source = Preferences.weatherSource
        let reading: WeatherRequest.Reading
        if let requestWeather {
          reading = try await requestWeather(source, coordinate, countryCode)
        } else {
          reading = try await WeatherRequest.fetch(
            source: source, appleAvailable: appleAvailable(),
            retryDelay: timing.retryInterval(1),
            apple: {
              let rounded = CLLocation(
                latitude: (coordinate.latitude * 100).rounded() / 100,
                longitude: (coordinate.longitude * 100).rounded() / 100)
              return try await AppleWeather.fetch(at: rounded, countryCode: self.countryCode)
            },
            openMeteo: {
              let (data, response) = try await self.session.data(from: url)
              return try WeatherAPI.decode(data, response: response)
            })
        }
        guard enabled, !suspended, generation == token, !Task.isCancelled else { return }
        var weather = reading.snapshot
        var refreshAfter = timing.refreshInterval
        switch reading {
        case .apple(let apple):
          appleFailures = 0
          refreshAfter = timing.refreshInterval
          if let expiry = weather.alerts.map(\.expires).min() {
            refreshAfter = min(refreshAfter, max(30, expiry.timeIntervalSinceNow - 30))
          }
          provider = "Apple Weather"
          providerURL = apple.attribution.legalPageURL
          loadAttributionMark(apple.attribution, generation: token)
        case .openMeteo:
          provider = source == .openMeteo ? "Open-Meteo" : "Open-Meteo · Apple Weather fallback"
          providerURL = URL(string: "https://open-meteo.com/")!
          if source == .automatic && (appleAvailable() || recovery.isRecovering()) {
            appleFailures += 1
            refreshAfter = WeatherRecovery.appleRetryDelay(appleFailures)
          }
        }
        weather.latitude = (coordinate.latitude * 100).rounded() / 100
        requestTimeout?.invalidate(); requestTimeout = nil
        task = nil
        snapshot = weather
        updatedAt = Date()
        recovery.resetRetries()
        status =
          "\(weather.condition) · \(Preferences.displayUnits.temperature(weather.temperature)) · \(Preferences.displayUnits.wind(weather.windSpeed))"
        changed()
        scheduleExpiry()
        scheduleAlertBoundary()
        schedule(after: refreshAfter)
      } catch {
        guard generation == token, enabled, !suspended, !Task.isCancelled else { return }
        task = nil
        failed(current == nil ? "Weather unavailable" : "Weather unavailable — keeping recent weather")
      }
    }
    let timeout = Timer(timeInterval: timing.requestTimeout, repeats: false) { [weak self] _ in
      guard let self, enabled, !suspended, generation == token, task != nil else { return }
      failed("Weather request timed out")
    }
    requestTimeout = timeout
    RunLoop.main.add(timeout, forMode: .common)
    changed()
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
    guard observesNetwork, enabled, !suspended, networkMonitor == nil else { return }
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
        // A pending retry owns its cadence; reconnecting cannot reset its limit.
        guard recovery.failedAttempts == 0, !recovery.exhausted else { return }
        refresh(force: true, automatic: true)
      }
    }
    monitor.start(queue: DispatchQueue(label: "Atmos.WeatherNetwork"))
  }

  private func resolveName(_ location: CLLocation) {
    guard resolvesNames else { return }
    let token = generation
    let rounded = CLLocation(
      latitude: (location.coordinate.latitude * 1000).rounded() / 1000,
      longitude: (location.coordinate.longitude * 1000).rounded() / 1000)
    geocoder.cancelGeocode()
    geocoder.reverseGeocodeLocation(rounded) { [weak self] places, _ in
      guard let self, enabled, !suspended, generation == token, let place = places?.first else {
        return
      }
      countryCode = place.isoCountryCode
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
    timer?.invalidate()
    timer = nil
    // A failed attempt must release all of its work before the next timer fires;
    // a leftover location request must not block the scheduled automatic retry.
    cancelRequest()
    cancelLocationRequest()
    if let delay = recovery.nextFailureDelay() {
      status = "\(message) · Retrying in \(Int(delay))s (attempt \(recovery.failedAttempts+1) of 15)"
      schedule(after: delay, retry: true)
    } else {
      // Stop the complete live session, including expiry/network callbacks.
      // The app persists the off state; no placeholder weather is selected.
      enabled = false
      cancel()
      coordinate = nil
      countryCode = nil
      snapshot = nil
      updatedAt = nil
      locationName = "Location access is off"
      locationDetail = ""
      status = "Live Weather turned off after 15 failed attempts"
      failureLimitReached()
    }
    changed()
  }

  private func schedule(after interval: TimeInterval, retry: Bool = false) {
    timer?.invalidate()
    guard enabled, !suspended else { return }
    let delay = retry ? timing.retryInterval(interval) : interval
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      guard let self else { return }
      self.timer?.invalidate()
      self.timer = nil
      refresh(force: true, automatic: true, renewLocation: !retry)
    }
    timer.tolerance = min(1, delay * 0.05)
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
      if recovery.failedAttempts == 0 {
        status = "Updating weather after a long pause…"
        changed()
      }
      refresh(force: true, automatic: true)
    }
    RunLoop.main.add(timer, forMode: .common)
    expiryTimer = timer
  }

  private func scheduleAlertBoundary() {
    alertTimer?.invalidate()
    guard enabled, !suspended, let boundary = snapshot?.nextAlertBoundary(after: Date()) else { return }
    let timer = Timer(timeInterval: max(0.1, boundary.timeIntervalSinceNow + 0.05), repeats: false) { [weak self] _ in
      guard let self, enabled, !suspended else { return }
      changed()
      scheduleAlertBoundary()
      refresh(force: true, automatic: true)
    }
    RunLoop.main.add(timer, forMode: .common)
    alertTimer = timer
  }

  private func cancelLocationRequest() {
    locationTimeout?.invalidate()
    locationTimeout = nil
    if locating { manager?.stopUpdatingLocation() }
    locating = false
    fetchAfterLocation = false
  }

  private func cancelRequest() {
    generation += 1
    requestTimeout?.invalidate()
    requestTimeout = nil
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
    timer = nil
    cancelLocationRequest()
    expiryTimer?.invalidate()
    alertTimer?.invalidate()
    geocoder.cancelGeocode()
  }

  func stop() {
    cancel()
    session.invalidateAndCancel()
  }
}
