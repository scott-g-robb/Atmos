import CoreLocation
import Foundation

/// Core Location owns a default-mode run loop. A tracking status menu must not
/// hold its delegate callbacks until the user closes the menu.
final class WeatherLocationManager: NSObject, WeatherLocationClient {
  weak var delegate: CLLocationManagerDelegate?
  private let worker: Worker
  var authorizationStatus: CLAuthorizationStatus { worker.authorizationStatus }

  init(initialAuthorization: CLAuthorizationStatus? = nil,
    makeManager: @escaping () -> WeatherLocationClient = {
      let manager = CLLocationManager()
      manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
      manager.distanceFilter = 1_000
      return manager
    }) {
    worker = Worker(authorization: initialAuthorization ?? CLLocationManager().authorizationStatus,
      makeManager: makeManager)
    super.init()
    worker.deliver = { [weak self] event in
      RunLoop.main.perform(inModes: [.common]) { [weak self] in
        guard let self, let delegate else { return }
        switch event {
        case .authorization(let manager): delegate.locationManagerDidChangeAuthorization?(manager)
        case .locations(let manager, let locations): delegate.locationManager?(manager,didUpdateLocations:locations)
        case .failure(let manager, let error): delegate.locationManager?(manager,didFailWithError:error)
        }
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    worker.start()
  }

  deinit { worker.shutdown() }
  func requestWhenInUseAuthorization() { worker.execute { $0.requestWhenInUseAuthorization() } }
  func requestLocation() { worker.execute { $0.requestLocation() } }
  func stopUpdatingLocation() { worker.execute { $0.stopUpdatingLocation() } }

  private enum Event {
    case authorization(CLLocationManager)
    case locations(CLLocationManager, [CLLocation])
    case failure(CLLocationManager, Error)
  }

  private final class Worker: NSObject, CLLocationManagerDelegate {
    private let lock = NSLock()
    private let makeManager: () -> WeatherLocationClient
    private var authorization: CLAuthorizationStatus
    private var loop: CFRunLoop?
    private var pending: [(WeatherLocationClient) -> Void] = []
    private var stopped = false
    private var thread: Thread?
    // Only accessed on the worker's run loop.
    private var manager: WeatherLocationClient?
    var deliver: (Event) -> Void = { _ in }

    init(authorization: CLAuthorizationStatus, makeManager: @escaping () -> WeatherLocationClient) {
      self.authorization = authorization
      self.makeManager = makeManager
      super.init()
    }
    var authorizationStatus: CLAuthorizationStatus {
      lock.lock();defer{lock.unlock()}
      return authorization
    }
    func start() {
      let thread = Thread { [self] in run() }
      thread.name = "Atmos.Location"
      thread.qualityOfService = .utility
      self.thread = thread
      thread.start()
    }
    private func run() {
      autoreleasepool {
        let port = NSMachPort()
        RunLoop.current.add(port,forMode:.default)
        let manager = makeManager()
        self.manager = manager
        manager.delegate = self
        let loop = CFRunLoopGetCurrent()!
        lock.lock()
        authorization = manager.authorizationStatus
        self.loop = loop
        let commands = pending
        pending.removeAll()
        let shouldRun = !stopped
        lock.unlock()
        if shouldRun {
          for command in commands { command(manager) }
          CFRunLoopRun()
        }
        manager.stopUpdatingLocation()
        manager.delegate = nil
        self.manager = nil
        port.invalidate()
        lock.lock();self.loop = nil;lock.unlock()
      }
      thread = nil
    }
    func execute(_ command: @escaping (WeatherLocationClient) -> Void) {
      lock.lock()
      guard !stopped else { lock.unlock();return }
      guard let loop else { pending.append(command);lock.unlock();return }
      lock.unlock()
      CFRunLoopPerformBlock(loop,RunLoop.Mode.default.rawValue as CFString) { [weak self] in
        guard let self, let manager else { return }
        command(manager)
      }
      CFRunLoopWakeUp(loop)
    }
    func shutdown() {
      lock.lock()
      stopped = true
      pending.removeAll()
      let loop = self.loop
      lock.unlock()
      if let loop {
        CFRunLoopPerformBlock(loop,RunLoop.Mode.default.rawValue as CFString) { CFRunLoopStop(loop) }
        CFRunLoopWakeUp(loop)
      }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
      lock.lock();authorization = manager.authorizationStatus;lock.unlock()
      deliver(.authorization(manager))
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
      deliver(.locations(manager,locations))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
      deliver(.failure(manager,error))
    }
  }
}
