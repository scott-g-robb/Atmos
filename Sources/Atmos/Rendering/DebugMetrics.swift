#if DEBUG
  import Foundation
  import Darwin

  /// Opt-in developer diagnostics, absent from release builds. SIGUSR1 takes a snapshot; there is no timer.
  enum DebugMetrics {
    static let enabled = ProcessInfo.processInfo.environment["ATMOS_METRICS"] == "1"
    static var frames: UInt64 = 0
    static var effectFrames: UInt64 = 0
    static var gpuSmokeSteps: UInt64 = 0
    static var effectSize = ""
    static var windowPolls: UInt64 = 0
    static var windowEvents: UInt64 = 0
    static var queryReasons = [String: UInt64]()
    static var trackerState = ""
    static var captured: UInt64 = 0
    static var captureIdle: UInt64 = 0
    static var captureTextureHits: UInt64 = 0
    static var captureTextureCreates: UInt64 = 0
    static var pointerUploads: UInt64 = 0
    static var captureGeometry = ""
    static var pacing = ""
    private static var source: DispatchSourceSignal?
    static var cpu = [String: UInt64]()
    private static let gpuLock = NSLock()
    private static var gpuNS: UInt64 = 0
    private static var gpuFrames: UInt64 = 0
    static func recordGPU(seconds: Double) {
      guard enabled, seconds.isFinite, seconds >= 0 else { return }
      gpuLock.lock()
      gpuNS += UInt64(seconds * 1e9)
      gpuFrames += 1
      gpuLock.unlock()
    }
    static func begin() -> UInt64 { enabled ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0 }
    @discardableResult static func end(_ phase: String, since start: UInt64) -> UInt64 {
      guard enabled else { return 0 }
      let now = begin()
      cpu[phase, default: 0] += now - start
      return now
    }
    static func start() {
      guard enabled else { return }
      signal(SIGUSR1, SIG_IGN)
      let listener = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
      listener.setEventHandler {
        gpuLock.lock()
        let gpu = gpuNS
        let submitted = gpuFrames
        gpuLock.unlock()
        let text =
          "ATMOS_METRICS frames=\(frames) polls=\(windowPolls) events=\(windowEvents) effect_frames=\(effectFrames) capture=\(captured) idle=\(captureIdle) reasons=\(queryReasons) tracker=\(trackerState) cpu_ns=\(cpu) notifications=\(WindowChanges.shared.available) gpu_ns=\(gpu) submissions=\(submitted) capture_hits=\(captureTextureHits) capture_creates=\(captureTextureCreates) cursor_uploads=\(pointerUploads) geometry=\(captureGeometry) fx_size=\(effectSize) gpu_smoke_steps=\(gpuSmokeSteps)\n"
        FileHandle.standardError.write(Data((text + "PACING \(pacing)\n").utf8))
      }
      listener.resume()
      source = listener
    }
  }
#endif
