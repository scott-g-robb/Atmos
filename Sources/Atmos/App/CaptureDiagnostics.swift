import AppKit
import Darwin
import Metal

/// Explicit, opt-in profiling only. No images, window names or coordinates are
/// written to disk. Uses the production capture path with existing permission.
enum CaptureDiagnostics {
  @MainActor static func run() async {
    var result: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString]
    guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main,
      let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
    else {
      result["status"] = "Capture profiling unavailable: existing screenshot permission required"
      emit(result); return
    }
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    let capture = ScreenReflection(device: device, displayID: id)
    capture.enabled = true; capture.live = true; capture.fogBloomEnabled = true
    let tracker = WindowTracker()
    tracker.screen = CGDisplayBounds(id); tracker.primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    tracker.menuBarHeight = screen.frame.maxY-screen.visibleFrame.maxY; tracker.usesSnapshotReflections = true
    let duration = min(60, max(12, Double(ProcessInfo.processInfo.environment["ATMOS_PROFILE_SECONDS"] ?? "12") ?? 12))
    let start = CACurrentMediaTime(), cpu = cpuTime()
    var frames = 0, maxWindows = 0, gpu = 0.0, encode = 0.0
    var copy: MTLTexture?
    while CACurrentMediaTime()-start < duration {
      let now = CACurrentMediaTime()
      _ = tracker.poll(now: now, eager: NSEvent.pressedMouseButtons != 0, frameInterval: 1/120)
      maxWindows = max(maxWindows, tracker.reflectionWindows.count)
      let texture = capture.update(screen: screen, now: now, active: true, windows: tracker.reflectionWindows, water: true, fog: true)
      let encoding = CACurrentMediaTime()
      if let command = queue.makeCommandBuffer() {
        capture.prepare(into: command)
        if let texture {
          if copy?.width != texture.width || copy?.height != texture.height || copy?.pixelFormat != texture.pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
            d.storageMode = .private; copy = device.makeTexture(descriptor: d)
          }
          if let copy, let blit = command.makeBlitCommandEncoder() { blit.copy(from: texture, to: copy); blit.endEncoding() }
        }
        encode += CACurrentMediaTime()-encoding
        command.commit(); command.waitUntilCompleted()
        gpu += max(0, command.gpuEndTime-command.gpuStartTime)
      }
      frames += 1
      let delay = start+Double(frames)/120-CACurrentMediaTime()
      if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay*1e9)) }
    }
    let elapsed = CACurrentMediaTime()-start
    result.merge(["status": capture.status, "duration_seconds": elapsed, "capture_frames": capture.captureCount,
      "render_ticks": frames, "maximum_windows": maxWindows, "process_cpu_percent": (cpuTime()-cpu)/elapsed*100,
      "gpu_ms_per_tick": gpu/Double(frames)*1000, "encode_ms_per_tick": encode/Double(frames)*1000,
      "gpu_allocated_bytes": device.currentAllocatedSize, "measurement": "production capture + geometry + Metal composite/copy; water simulation and WindowServer CPU excluded"]) { _, b in b }
    capture.stop(); emit(result)
  }
  private static func cpuTime() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
  }
  private static func emit(_ result: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
  }
}
