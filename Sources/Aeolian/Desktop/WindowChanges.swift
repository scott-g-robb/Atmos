import AppKit

/// A quick restore can finish before the minimise grace period expires.
/// Once an outgoing window has actually left the census, its return is immediate.
struct WindowDepartureState {
  private var seenAway = Set<CGWindowID>()
  mutating func restored(departing: Set<CGWindowID>, visible: Set<CGWindowID>) -> Set<CGWindowID> {
    seenAway.formUnion(departing.subtracting(visible))
    let restored = seenAway.intersection(visible).intersection(departing)
    seenAway.formIntersection(departing.subtracting(restored))
    return restored
  }
}

/// WindowServer notifications invalidate geometry; the idle census still discovers
/// new windows. Sharing one subscription avoids repeated IPC on every display tick.
#if APP_STORE
final class WindowChanges {
  static let shared = WindowChanges()
  static let notification = Notification.Name("AeolianWindowGeometryDidChange")
  let revision: UInt64 = 0
  let available = false
  func observe(_ ids: Set<CGWindowID>) {}
}
#else
final class WindowChanges {
  static let shared = WindowChanges()
  static let notification = Notification.Name("AeolianWindowGeometryDidChange")
  private(set) var revision: UInt64 = 0
  private(set) var available = false
  private let lock = NSLock()
  private var windows = Set<CGWindowID>()
  private var deliveryPending = false
  private typealias Notify =
    @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt, UnsafeMutableRawPointer?) -> Void
  private typealias Register = @convention(c) (Notify, UInt32, UnsafeMutableRawPointer?) -> Int32
  private typealias Request = @convention(c) (Int32, UnsafePointer<CGWindowID>?, Int32) -> Int32
  private let request = SkyLight.function("SLSRequestNotificationsForWindows", as: Request.self)
  private static let callback: Notify = { event, data, length, context in
    guard let context else { return }
    let owner = Unmanaged<WindowChanges>.fromOpaque(context).takeUnretainedValue()
    if event < 1000 {
      guard let data, length >= MemoryLayout<CGWindowID>.size else { return }
      let id = data.load(as: CGWindowID.self)
      owner.lock.lock()
      let tracked = owner.windows.contains(id)
      owner.lock.unlock()
      guard tracked else { return }
    }
    owner.lock.lock()
    guard !owner.deliveryPending else { owner.lock.unlock(); return }
    owner.deliveryPending = true
    owner.lock.unlock()
    DispatchQueue.main.async {
      owner.lock.lock(); owner.deliveryPending = false; owner.lock.unlock()
      owner.revision &+= 1
      NotificationCenter.default.post(name: WindowChanges.notification, object: nil)
      #if DEBUG
        if DebugMetrics.enabled { DebugMetrics.windowEvents += 1 }
      #endif
    }
  }
  private init() {
    guard request != nil, SkyLight.connection != nil,
      let register = SkyLight.function("SLSRegisterNotifyProc", as: Register.self)
    else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    // Register every supported event. One unsupported optional notification must
    // not short-circuit the remaining registrations and force permanent polling.
    let results = [UInt32](arrayLiteral: 804, 806, 807, 808, 815, 816, 1327, 1328, 1401, 1404)
      .map { register(Self.callback, $0, context) == 0 }
    available = results.prefix(6).contains(true)
  }
  /// The shared on-screen census includes all displays, with Atmos's windows excluded.
  func observe(_ ids: Set<CGWindowID>) {
    lock.lock()
    let changed = ids != windows
    if changed { windows = ids }
    lock.unlock()
    guard changed, available, let request, let connection = SkyLight.connection else { return }
    let list = Array(ids)
    if list.withUnsafeBufferPointer({ request(connection, $0.baseAddress, Int32($0.count)) }) != 0 {
      available = false
    }
  }
}

#endif
