import AppKit
import ScreenCaptureKit

/// Preflight is a hint. A successful, explicitly requested ScreenCaptureKit check
/// is authoritative for this process; it does not start a capture stream.
final class ScreenshotAccess {
  static let shared = ScreenshotAccess()
  enum State: Equatable { case unknown, checking, granted, authorizationNeeded }
  private(set) var state: State = .unknown
  private var verifiedByKit = false
  private var task: Task<Void, Never>?
  private let preflight: () -> Bool
  private let probe: () async throws -> Void
  var changed: () -> Void = {}
  var returningFromSettings = false
  var isGranted: Bool { state != .authorizationNeeded && (preflight() || verifiedByKit) }
  init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
    probe: @escaping () async throws -> Void = {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
      guard !content.displays.isEmpty else { throw URLError(.resourceUnavailable) }
    }) {
    self.preflight = preflight; self.probe = probe
  }
  /// Only call after Allow, Recheck, or a return from explicitly opened Settings.
  func recheck() {
    guard task == nil else { return }
    state = .checking; changed()
    let probe = self.probe
    task = Task { @MainActor [weak self] in
      let success: Bool
      var explicitlyDenied = false
      do { try await WeatherAttempt.run(timeout: 8, operation: probe); success = true }
      catch {
        success = false
        let error = error as NSError
        explicitlyDenied = error.domain == SCStreamErrorDomain && error.code == SCStreamError.userDeclined.rawValue
      }
      guard let self, !Task.isCancelled else { return }
      verifiedByKit = success
      state = success || (!explicitlyDenied && preflight()) ? .granted : .authorizationNeeded
      task = nil; changed()
    }
  }
  func invalidateIfDenied(_ error: Error) {
    let error = error as NSError
    guard error.domain == SCStreamErrorDomain, error.code == SCStreamError.userDeclined.rawValue else { return }
    verifiedByKit = false; state = .authorizationNeeded; changed()
  }
  deinit { task?.cancel() }
}
