import AppKit
import CoreMedia
import CoreVideo
import ImageIO
import Metal
import ScreenCaptureKit

/// One-off screenshots only. Cached pixels are composited with live geometry on
/// the rendering command queue; no SCStream or continuous recording session exists.
final class ScreenReflection {
  final class Frame {
    let texture: MTLTexture
    let uvRect: SIMD4<Float>
    let capturedAt: Double
    private let pixelBuffer: CVPixelBuffer
    init(texture: MTLTexture, pixelBuffer: CVPixelBuffer, uvRect: SIMD4<Float>, capturedAt: Double = CACurrentMediaTime()) {
      self.texture=texture;self.pixelBuffer=pixelBuffer;self.uvRect=uvRect;self.capturedAt=capturedAt
    }
  }
  private let device: MTLDevice
  private let displayID: CGDirectDisplayID
  private var generation = 0
  private var retryAfter: Double = 0
  private var permissionAt: Double = -100
  private var permission = false
  private var windowSnapshots: WindowReflections?
  private var currentWindows: [ReflectionWindow] = []
  private var screenFrame = CGRect.zero
  private var mouseMonitor: Any?
  private var workspaceObserver: NSObjectProtocol?
  private var wallpaper: MTLTexture?
  private var cleanWallpaper: Frame?
  private var cleanWallpaperTask: Task<Void, Never>?
  private var cleanWallpaperAt: Double = -100
  private var wallpaperURL: URL?
  private var wallpaperAt: Double = -100
  private(set) var bloomTexture: MTLTexture?
  private(set) var bloomRect = SIMD4<Float>(0,0,1,1)
  private(set) var waterRect = SIMD4<Float>(0,0,1,1)
  private(set) var stoppedByUser = false
  private(set) var status = "Wallpaper reflections"
  var wallpaperTexture: MTLTexture? { cleanWallpaper?.texture ?? wallpaper }
  var maximumWidth: CGFloat = 1280 { didSet { if oldValue != maximumWidth { invalidate() } } }
  var refreshInterval: Double = 10
  var powerBudget = PowerBudget.full
  var captureCount: Int { windowSnapshots?.captureCount ?? 0 }
  var compositedAt: Double? { windowSnapshots?.compositedAt }
  var isCapturing: Bool { windowSnapshots?.isCapturing == true || cleanWallpaperTask != nil }
  var enabled = false { didSet { if enabled { stoppedByUser = false } } }
  /// Retained preference: desktop imagery versus window-only water snapshots.
  var live = false { didSet { if oldValue != live { invalidate() } } }
  var fogBloomEnabled = false { didSet { if fogBloomEnabled && !oldValue { stoppedByUser = false } } }
  init(device: MTLDevice, displayID: CGDirectDisplayID) { self.device=device;self.displayID=displayID }
  deinit { removeMonitors(); cleanWallpaperTask?.cancel() }

  func update(screen: NSScreen, now: Double, active: Bool, windows: [ReflectionWindow] = [],
    water: Bool = true, fog: Bool = false, regions: [CGRect]? = nil) -> MTLTexture? {
    guard active else { stop(); return nil }
    screenFrame=screen.frame; currentWindows=windows
    bloomTexture=nil
    if now-wallpaperAt >= 60 { wallpaperAt=now;updateWallpaper(screen) }
    if now-permissionAt > 2 { permissionAt=now;permission=ScreenshotAccess.shared.isGranted }
    let demand=DesktopCaptureDemand(water:water,fog:fog,reflectionsEnabled:enabled,
      liveReflections:live,bloomEnabled:fogBloomEnabled)
    guard (demand.live || demand.snapshots),permission,!stoppedByUser,now>=retryAfter else {
      windowSnapshots?.stop();removeMonitors()
      status=stoppedByUser ? "Screenshots stopped" : (demand.live || demand.snapshots) && !permission
        ? "Wallpaper · Screenshot access needed":"Wallpaper reflections"
      return wallpaper
    }
    if windowSnapshots == nil {
      windowSnapshots=try? WindowReflections(device:device,displayID:displayID)
      windowSnapshots?.captureFailed={ [weak self] error in
        ScreenshotAccess.shared.invalidateIfDenied(error)
        let e=error as NSError
        if e.domain == SCStreamErrorDomain && [SCStreamError.userDeclined.rawValue,SCStreamError.userStopped.rawValue].contains(e.code) {
          self?.captureStopped(with:error)
        }
      }
    }
    guard let snapshots=windowSnapshots else { return wallpaper }
    installMonitors()
    snapshots.maximumWidth=maximumWidth
    snapshots.refreshInterval=max(1,refreshInterval)*(powerBudget == .saver ? 3:powerBudget == .battery ? 2:1)
    snapshots.minimumEventInterval=powerBudget == .saver ? 1:powerBudget == .battery ? 0.5:0.2
    if demand.bloom { refreshCleanWallpaper(screen:screen,now:now) }
    snapshots.update(windows:windows,size:screen.frame.size,wallpaper:wallpaperTexture,now:now,
      regions:demand.bloom ? nil:regions,includeDesktop:demand.live,
      separateWater:demand.bloom && water && enabled && !live)
    if demand.bloom { bloomTexture=snapshots.texture }
    status=demand.bloom ? "Fog bloom · Cached screenshots":"Reflections · Cached window screenshots"
    return water && enabled ? snapshots.waterTexture ?? wallpaper:wallpaper
  }

  private func installMonitors() {
    if workspaceObserver == nil {
      workspaceObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,
        object:nil,queue:.main) { [weak self] note in
        guard let self,let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let ids=Set(currentWindows.filter { $0.ownerPID == app.processIdentifier }.prefix(2).map(\.id))
        windowSnapshots?.invalidateContents(ids)
      }
    }
    if mouseMonitor == nil {
      mouseMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.scrollWheel,.leftMouseUp]) { [weak self] _ in
        guard let self else { return }
        let cursor=NSEvent.mouseLocation
        let point=CGPoint(x:cursor.x-screenFrame.minX,y:screenFrame.maxY-cursor.y)
        // Window drags/title-bar clicks do not imply new content. Never inspect
        // keystrokes or request Accessibility/Input Monitoring permission.
        if let window=currentWindows.first(where: { $0.frame.contains(point) }), point.y>window.frame.minY+38 {
          windowSnapshots?.invalidateContents([window.id])
        }
      }
    }
  }
  private func removeMonitors() {
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor);self.mouseMonitor=nil }
    if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver);self.workspaceObserver=nil }
  }
  func captureStopped(with error: Error) {
    ScreenshotAccess.shared.invalidateIfDenied(error)
    let e=error as NSError
    stoppedByUser=e.domain == SCStreamErrorDomain && e.code == SCStreamError.userStopped.rawValue
    windowSnapshots?.stop();removeMonitors();bloomTexture=nil
    retryAfter=CACurrentMediaTime()+20
    status="Wallpaper · Screenshots unavailable"
  }
  func prepare(into command: MTLCommandBuffer) { windowSnapshots?.encode(into:command) }
  func stop() {
    generation+=1;cleanWallpaperTask?.cancel();cleanWallpaperTask=nil;cleanWallpaper=nil;cleanWallpaperAt = -100
    windowSnapshots?.stop();removeMonitors();currentWindows.removeAll();bloomTexture=nil
    wallpaper=nil;wallpaperURL=nil;wallpaperAt = -100;status="Screenshots paused"
  }
  func invalidate() {
    generation+=1;cleanWallpaperTask?.cancel();cleanWallpaperTask=nil;cleanWallpaper=nil;cleanWallpaperAt = -100
    windowSnapshots?.stop();permissionAt = -100;retryAfter=0
  }

  private func refreshCleanWallpaper(screen: NSScreen, now: CFTimeInterval) {
    guard cleanWallpaperTask == nil, now-cleanWallpaperAt >= 60 else { return }
    cleanWallpaperAt = now
    let token = generation, size = screen.frame.size
    cleanWallpaperTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { if generation == token { cleanWallpaperTask = nil } }
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard generation == token, !Task.isCancelled,
          let display = content.displays.first(where: { $0.displayID == self.displayID }) else { return }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let excluded = content.windows.filter {
          $0.windowLayer >= iconLevel || $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            || $0.owningApplication?.bundleIdentifier == "dev.grobb.Atmos"
        }
        let config = SCStreamConfiguration()
        config.width = 640; config.height = max(2, Int(640*size.height/max(1,size.width)))
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.capturesAudio = false; config.showsCursor = false
        config.sourceRect = CGRect(origin: .zero, size: size)
        config.destinationRect = CGRect(x: 0, y: 0, width: config.width, height: config.height)
        config.preservesAspectRatio = false; config.scalesToFit = true; config.colorSpaceName = CGColorSpace.sRGB
        let sample = try await SCScreenshotManager.captureSampleBuffer(
          contentFilter: SCContentFilter(display: display, excludingWindows: excluded), configuration: config)
        guard generation == token, !Task.isCancelled,
          let buffer = CMSampleBufferGetImageBuffer(sample),
          let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
          width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        if let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) {
          cleanWallpaper = Frame(texture: texture, pixelBuffer: buffer, uvRect: SIMD4(0,0,1,1))
        }
      } catch { /* Keep the last valid wallpaper; no retry loop or permission prompt. */ }
    }
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
    // This upload happens once per wallpaper change; window screenshots use IOSurface-backed textures.
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
