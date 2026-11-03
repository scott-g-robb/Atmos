import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import ImageIO
import Metal
import ScreenCaptureKit

/// IOSurface-backed frames: no CGImage creation, CPU readback or per-frame texture upload.
final class ScreenReflection: NSObject, SCStreamOutput, SCStreamDelegate {
  final class Frame {
    let texture: MTLTexture
    let uvRect: SIMD4<Float>
    private let pixelBuffer: CVPixelBuffer
    init(texture: MTLTexture, pixelBuffer: CVPixelBuffer, uvRect: SIMD4<Float>) {
      self.uvRect = uvRect
      self.texture = texture
      self.pixelBuffer = pixelBuffer
    }
  }
  private let device: MTLDevice
  private let displayID: CGDirectDisplayID
  private struct SurfaceTexture {
    let id: IOSurfaceID
    let texture: MTLTexture
  }
  // Retain GPU views, never pooled CVPixelBuffers, between frames. A Frame retains
  // its pixel buffer only until the last GPU reader finishes.
  private var surfaceTextures: [SurfaceTexture] = []
  private let queue = DispatchQueue(label: "Atmos.reflections", qos: .utility)
  private let lock = NSLock()
  private var latest: Frame?
  private var acceptedStream: ObjectIdentifier?
  private var stream: SCStream?
  private var configuration: SCStreamConfiguration?
  private var paceTask: Task<Void, Never>?
  private var appliedFrameRate = 0
  private var nativeFrameRate = 60
  private var paceRetryAt: CFTimeInterval = 0
  var preferredFrameRate = 30 {
    didSet { if preferredFrameRate != oldValue { updatePace() } }
  }
  private var task: Task<Void, Never>?
  private var generation = 0
  private var retryAfter: CFTimeInterval = 0
  private var permissionAt: CFTimeInterval = -100
  private var permission = false
  private(set) var displayedFrame: Frame?
  var maximumWidth: CGFloat = 1280 { didSet { if maximumWidth != oldValue { invalidate() } } }
  private var wallpaper: MTLTexture?
  private var wallpaperURL: URL?
  private var wallpaperAt: CFTimeInterval = -100
  private var windowSnapshots: WindowReflections?
  private var snapshotMode = false
  var isCapturing: Bool { snapshotMode || (stream != nil && task == nil) }
  private(set) var stoppedByUser = false
  private(set) var status = "Wallpaper reflections"
  var enabled = false { didSet { if enabled { stoppedByUser = false } } }
  var live = false { didSet { if live != oldValue { invalidate() } } }

  init(device: MTLDevice, displayID: CGDirectDisplayID) {
    self.device = device
    self.displayID = displayID
    super.init()
  }

  var frame: Frame? {
    lock.lock()
    defer { lock.unlock() }
    return latest
  }

  func update(screen: NSScreen, now: CFTimeInterval, active: Bool, windows: [ReflectionWindow] = [])
    -> MTLTexture?
  {
    guard active else {
      stop()
      return nil
    }
    nativeFrameRate = max(1, screen.maximumFramesPerSecond)
    displayedFrame = nil
    if now - wallpaperAt >= 60 {
      wallpaperAt = now
      updateWallpaper(screen)
    }
    if now - permissionAt > 2 {
      permissionAt = now
      permission = CGPreflightScreenCaptureAccess()
    }
    if stoppedByUser {
      stopCapture()
      windowSnapshots?.stop()
      snapshotMode = false
      status = "Wallpaper · Desktop capture stopped"
      return wallpaper
    }
    guard enabled && permission else {
      stopCapture()
      windowSnapshots?.stop()
      snapshotMode = false
      status = enabled ? "Wallpaper · Screen Recording permission needed" : "Wallpaper reflections"
      return wallpaper
    }
    if !live {
      if windowSnapshots == nil {
        windowSnapshots = try? WindowReflections(device: device, displayID: displayID)
      }
      if let snapshots = windowSnapshots, !snapshots.unavailable {
        stopCapture()
        snapshotMode = true
        snapshots.maximumWidth = maximumWidth
        snapshots.update(windows: windows, size: screen.frame.size, wallpaper: wallpaper, now: now)
        status = "Window snapshots · Cached reflections"
        return snapshots.texture ?? wallpaper
      }
    }
    snapshotMode = false
    if stream == nil && task == nil && now >= retryAfter { start(screen: screen) }
    updatePace()
    if let frame {
      displayedFrame = frame
      status =
        live
        ? "Desktop reflections · Screen Recording active"
        : "Live desktop · Snapshot capture unavailable"
      return frame.texture
    }
    if now >= retryAfter { status = "Starting desktop reflections…" }
    return wallpaper
  }

  private func start(screen: NSScreen) {
    let token = generation
    let size = screen.frame.size
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        // The overlays live in a separate visible Space. An on-screen-only
        // census may omit their owning application, defeating exclusion.
        let content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: false)
        guard generation == token, enabled, !Task.isCancelled else { return }
        guard let display = content.displays.first(where: { $0.displayID == self.displayID }) else {
          throw RendererError.unavailable
        }
        let own = content.applications.filter {
          $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        #if DEBUG
          if DebugMetrics.enabled {
            let windows = Set(NSApp.windows.compactMap { CGWindowID(exactly: $0.windowNumber) })
            let matched = content.windows.filter { windows.contains($0.windowID) }.count
            FileHandle.standardError.write(
              Data(
                "CAPTURE_FILTER apps=\(own.count) windows=\(matched) own_windows=\(windows.count)\n"
                  .utf8))
          }
        #endif
        let filter = SCContentFilter(
          display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = min(1, maximumWidth / max(1, size.width))
        configuration.width = max(2, Int(size.width * scale))
        // Water compresses hundreds of desktop points into a few screen pixels.
        // Keep horizontal detail while avoiding vertical capture samples that the
        // shallow reflection band cannot resolve, even at Retina backing scale.
        configuration.height = max(
          2, min(Int(size.height * scale), max(512, Int(ceil(size.height * 0.5)))))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Zero follows the display clock (including ProMotion), without a quantised
        // 1/120 interval intermittently rejecting hardware frames just below that duration.
        configuration.minimumFrameInterval = interval(for: preferredFrameRate)
        configuration.queueDepth = 2
        configuration.showsCursor = false
        // Make source points -> destination pixels explicit. Automatic fitting may insert
        // padding, whose origin must not become a horizontal reflection offset.
        configuration.sourceRect = CGRect(origin: .zero, size: size)
        configuration.destinationRect = CGRect(
          x: 0, y: 0, width: configuration.width, height: configuration.height)
        configuration.preservesAspectRatio = false
        configuration.scalesToFit = true
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        guard generation == token, !Task.isCancelled else {
          try? capture.removeStreamOutput(self, type: .screen)
          return
        }
        stream = capture
        self.configuration = configuration
        appliedFrameRate = preferredFrameRate
        accept(capture)
        try await capture.startCapture()
        guard generation == token, !Task.isCancelled else {
          try? await capture.stopCapture()
          return
        }
        task = nil
        updatePace()
      } catch {
        guard generation == token else { return }
        stopCapture()
        retryAfter = CACurrentMediaTime() + 20
        status = "Wallpaper · Desktop capture unavailable"
      }
    }
  }

  private func accept(_ stream: SCStream) {
    lock.lock()
    acceptedStream = ObjectIdentifier(stream)
    lock.unlock()
  }

  private func interval(for rate: Int) -> CMTime {
    rate >= nativeFrameRate ? .zero : CMTime(value: 1, timescale: Int32(max(1, rate)))
  }

  /// Coalesce changes on the running stream; never restart capture merely to
  /// change cadence, or allow an old async update to revive a stopped stream.
  private func updatePace() {
    guard task == nil, paceTask == nil, let stream, let configuration,
      appliedFrameRate != preferredFrameRate, CACurrentMediaTime() >= paceRetryAt
    else { return }
    let token = generation
    let rate = preferredFrameRate
    configuration.minimumFrameInterval = interval(for: rate)
    paceTask = Task { @MainActor [weak self, weak stream] in
      guard let self, let stream else { return }
      do {
        try await stream.updateConfiguration(configuration)
        guard generation == token, !Task.isCancelled else { return }
        appliedFrameRate = rate
        paceTask = nil
        updatePace()
      } catch {
        guard generation == token else { return }
        paceTask = nil
        paceRetryAt = CACurrentMediaTime() + 2
      }
    }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen, sampleBuffer.isValid,
      let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }
    lock.lock()
    let accepted = acceptedStream == ObjectIdentifier(stream)
    lock.unlock()
    guard accepted else { return }
    let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
    let metadata: NSDictionary? = array.flatMap {
      CFArrayGetCount($0) > 0
        ? unsafeBitCast(CFArrayGetValueAtIndex($0, 0), to: NSDictionary.self) : nil
    }
    if let raw = metadata?[SCStreamFrameInfo.status.rawValue] as? Int,
      SCFrameStatus(rawValue: raw) != .complete
    {
      #if DEBUG
        if DebugMetrics.enabled { DispatchQueue.main.async { DebugMetrics.captureIdle += 1 } }
      #endif
      return
    }
    #if DEBUG
      if DebugMetrics.enabled { DispatchQueue.main.async { DebugMetrics.captured += 1 } }
    #endif
    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
    let id = IOSurfaceGetID(surface)
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let texture: MTLTexture
    if let cached = surfaceTextures.first(where: {
      $0.id == id && $0.texture.width == width && $0.texture.height == height
    }) {
      texture = cached.texture
      #if DEBUG
        if DebugMetrics.enabled {
          DispatchQueue.main.async { DebugMetrics.captureTextureHits += 1 }
        }
      #endif
    } else {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      descriptor.storageMode = .shared
      descriptor.usage = .shaderRead
      guard let created = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
      else { return }
      texture = created
      if surfaceTextures.count >= 6 { surfaceTextures.removeFirst() }
      surfaceTextures.append(SurfaceTexture(id: id, texture: created))
      #if DEBUG
        if DebugMetrics.enabled {
          DispatchQueue.main.async { DebugMetrics.captureTextureCreates += 1 }
        }
      #endif
    }
    var rect = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
    if let dict = metadata?[SCStreamFrameInfo.contentRect.rawValue] as? NSDictionary,
      let points = CGRect(dictionaryRepresentation: dict)
    {
      let scale = (metadata?[SCStreamFrameInfo.scaleFactor.rawValue] as? CGFloat) ?? 1
      rect = CGRect(
        x: points.minX * scale, y: points.minY * scale, width: points.width * scale,
        height: points.height * scale)
    }
    let uv = ReflectionGeometry.uvRect(
      contentPixels: rect, textureSize: CGSize(width: texture.width, height: texture.height))
    #if DEBUG
      if DebugMetrics.enabled {
        DispatchQueue.main.async {
          DebugMetrics.captureGeometry = "\(texture.width)x\(texture.height) uv:\(uv)"
        }
      }
    #endif
    let frame = Frame(texture: texture, pixelBuffer: buffer, uvRect: uv)
    lock.lock()
    if acceptedStream == ObjectIdentifier(stream) { latest = frame }
    lock.unlock()
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    DispatchQueue.main.async { [weak self, weak stream] in
      guard let self, let stream, self.stream === stream else { return }
      captureStopped(with: error)
    }
  }

  func captureStopped(with error: Error) {
    let error = error as NSError
    stoppedByUser =
      error.domain == SCStreamErrorDomain && error.code == SCStreamError.userStopped.rawValue
    stopCapture()
    windowSnapshots?.stop()
    snapshotMode = false
    retryAfter = CACurrentMediaTime() + 20
    status = "Wallpaper · Desktop capture stopped"
  }

  private func stopCapture(preservingImage: Bool = false) {
    guard task != nil || stream != nil || frame != nil else { return }
    generation += 1
    task?.cancel()
    task = nil
    paceTask?.cancel()
    paceTask = nil
    configuration = nil
    appliedFrameRate = 0
    paceRetryAt = 0
    lock.lock()
    acceptedStream = nil
    if !preservingImage { latest = nil }
    lock.unlock()
    if let capture = stream {
      stream = nil
      try? capture.removeStreamOutput(self, type: .screen)
      Task { try? await capture.stopCapture() }
    }
    queue.async { [weak self] in self?.surfaceTextures.removeAll() }
  }

  func stop() {
    stopCapture()
    windowSnapshots?.stop()
    snapshotMode = false
    displayedFrame = nil
    wallpaper = nil
    wallpaperURL = nil
    wallpaperAt = -100
    status = "Reflections paused"
  }
  func invalidate() {
    stopCapture(preservingImage: true)
    windowSnapshots?.stop()
    snapshotMode = false
    permissionAt = -100
    retryAfter = 0
  }

  func prepare(into command: MTLCommandBuffer) {
    if snapshotMode { windowSnapshots?.encode(into: command) }
  }

  private func updateWallpaper(_ screen: NSScreen) {
    guard let url = NSWorkspace.shared.desktopImageURL(for: screen), url != wallpaperURL else {
      return
    }
    wallpaperURL = url
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 768,
        ] as CFDictionary)
    else { return }
    let width = 640
    let height = max(2, Int(640 * screen.frame.height / max(1, screen.frame.width)))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    let scale = max(
      CGFloat(width) / CGFloat(thumbnail.width), CGFloat(height) / CGFloat(thumbnail.height))
    let w = CGFloat(thumbnail.width) * scale
    let h = CGFloat(thumbnail.height) * scale
    context.draw(
      thumbnail,
      in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
    // This upload happens once per wallpaper change; live frames use the zero-copy cache above.
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    guard let data = context.data, let texture = device.makeTexture(descriptor: descriptor) else {
      return
    }
    texture.replace(
      region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data,
      bytesPerRow: width * 4)
    wallpaper = texture
  }
}
