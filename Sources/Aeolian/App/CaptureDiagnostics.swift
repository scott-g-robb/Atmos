import AppKit
import Darwin
import Metal

/// Explicit, opt-in profiling only. No images, window names or coordinates are
/// written to disk. Uses the production capture path with existing permission.
enum CaptureDiagnostics {
  /// Explicit desktop test of the shipping display link, geometry and fog path.
  /// No preferences, location or updater state are changed by this diagnostic.
  @MainActor static func visibleFog(storm: Bool = false) async {
    guard let screen = NSScreen.main, let device = MTLCreateSystemDefaultDevice(),
      let overlay = ScreenSnow(screen: screen, device: device, snowOnWindows: { true }) else { return }
    var scene = WeatherScene(primary: storm ? .lightning : .mist,
      stacked: storm ? .leaves : nil, wildlife: storm ? .birds : nil)
    scene.fog = storm ? 0 : 0.72; scene.manualCloudCover = storm ? 1 : 0.58; scene.clouds = storm ? 1 : 0.58
    overlay.setScene(scene); overlay.setFogBloom(true); overlay.setActive(true, asleep:false)
    if storm {
      overlay.setIntensity(.heavy); overlay.setAccumulation(true)
      overlay.setEvaporation(true); overlay.setReflections(true)
    }
    overlay.resumeAfterSetup()
    try? await Task.sleep(nanoseconds: storm ? 8_000_000_000 : 3_000_000_000)
    let start = CACurrentMediaTime(), cpu = cpuTime(), initial = overlay.frameCounts
    let timings = overlay.profileTimings
    let duration = min(60, max(12, Double(ProcessInfo.processInfo.environment["ATMOS_PROFILE_SECONDS"] ?? "20") ?? 20))
    try? await Task.sleep(nanoseconds: UInt64(duration * 1e9))
    let elapsed = CACurrentMediaTime() - start, counts = overlay.frameCounts
    emit(["duration_seconds":elapsed, "process_cpu_percent":(cpuTime()-cpu)/elapsed*100,
      "delivered_frames":counts.delivered-initial.delivered,"presented_frames":counts.presented-initial.presented,
      "frames_per_second":Double(counts.presented-initial.presented)/elapsed,
      "geometry_queries":counts.geometryQueries-initial.geometryQueries,
      "simulation_ms_per_frame":(overlay.profileTimings.simulation-timings.simulation)/Double(max(1,counts.presented-initial.presented))*1000,
      "input_ms_per_frame":(overlay.profileTimings.input-timings.input)/Double(max(1,counts.presented-initial.presented))*1000,
      "encode_ms_per_frame":(overlay.profileTimings.encode-timings.encode)/Double(max(1,counts.presented-initial.presented))*1000,
      "weather_particles":overlay.profileTimings.particles,
      "maximum_water_depth_points":overlay.profileWaterDepth,
      "native_refresh_hz":screen.maximumFramesPerSecond,"reflection_status":overlay.reflectionStatus,
      "scene":storm ? "heavy lightning + autumn leaves + birds; water reflections" : "fog 0.72; cloud cover 58%; native desktop geometry and screenshot bloom",
      "scope":"production visible overlays, simulation, rendering and capture; WindowServer CPU excluded"])
    overlay.close()
  }
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
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
  }
}
