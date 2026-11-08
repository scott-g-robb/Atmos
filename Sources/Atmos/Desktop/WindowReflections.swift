import AppKit
import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit

/// A window image is independent of its screen position. Repositioning cached
/// images on the GPU keeps reflected drags smooth without recording every frame.
struct ReflectionWindow: Equatable {
  let id: CGWindowID
  /// Display-local points, with a top-left origin, in front-to-back order.
  let frame: CGRect
  let alpha: Float
  var ownerPID: pid_t? = nil
  var occludesOthers = true
}

final class WindowReflections {
  typealias SnapshotProvider = (CGWindowID, CGSize) async throws -> CVPixelBuffer?
  private let device: MTLDevice
  private let snapshotProvider: SnapshotProvider?
  private let displayID: CGDirectDisplayID?
  private let pipeline: MTLRenderPipelineState
  private let transitionPipeline: MTLRenderPipelineState
  private var encodingTransition = false
  private final class Image {
    let texture: MTLTexture
    let size: CGSize
    let at: CFTimeInterval
    let buffer: CVPixelBuffer
    let uvRect: SIMD4<Float>
    init(texture: MTLTexture, size: CGSize, at: CFTimeInterval, buffer: CVPixelBuffer, uvRect: SIMD4<Float>) {
      self.texture = texture
      self.size = size
      self.at = at
      self.buffer = buffer
      self.uvRect = uvRect
    }
  }
  private var images: [CGWindowID: Image] = [:]
  private var previousImages: [CGWindowID: (image: Image, at: Double)] = [:]
  private var previousDesktop: (image: Image, at: Double)?
  private var dirty = Set<CGWindowID>()
  private var requestedAt: [CGWindowID: Double] = [:]
  private var clock: Double = 0
  private var includeDesktop = true
  private var separateWater = false
  private var windowTarget: MTLTexture?
  private var renderedWaterBackground: MTLTexture?
  private var selectionInput: [ReflectionWindow] = []
  private var selectionRegions: [CGRect]? = nil
  private var selected: [ReflectionWindow] = []
  private var retainedIDs = Set<CGWindowID>()
  var refreshInterval: Double = 10
  var minimumEventInterval: Double = 0.2
  private(set) var captureCount = 0
  private(set) var compositeCount = 0
  private(set) var compositedAt: Double?
  var isCapturing: Bool { pending }
  var waterTexture: MTLTexture? { windowTarget ?? target }
  var captureFailed: ((Error) -> Void)?
  /// Content hints are separate from geometry: a drag never captures pixels.
  func invalidateContents(_ ids: Set<CGWindowID>) { dirty.formUnion(ids); nextCaptureAt = 0 }
  static func visibleWindows(_ windows: [ReflectionWindow], size: CGSize, regions: [CGRect]?) -> [ReflectionWindow] {
    let screen = CGRect(origin: .zero, size: size)
    var blockers: [CGRect] = [], result: [ReflectionWindow] = []
    for window in windows.prefix(64) {
      guard window.frame.minX.isFinite, window.frame.minY.isFinite,
        window.frame.width.isFinite, window.frame.height.isFinite,
        window.frame.width > 1, window.frame.height > 1 else { continue }
      let clipped = window.frame.intersection(screen)
      guard window.id != 0, window.alpha > 0.01, !clipped.isNull,
        window.frame.width.isFinite, window.frame.height.isFinite, window.frame.width > 1, window.frame.height > 1 else { continue }
      let relevant = regions == nil || regions!.contains { $0.intersects(clipped) }
      if relevant && hasVisibleArea(clipped, above: blockers) { result.append(window) }
      if window.alpha >= 0.99 && window.occludesOthers { blockers.append(clipped) }
    }
    return Array(result.prefix(32))
  }
  private static func hasVisibleArea(_ frame: CGRect, above blockers: [CGRect]) -> Bool {
    var pieces = [frame]
    for blocker in blockers {
      var next: [CGRect] = []
      for piece in pieces {
        let cut = piece.intersection(blocker)
        if cut.isNull { next.append(piece); continue }
        if cut.minX > piece.minX { next.append(CGRect(x:piece.minX,y:piece.minY,width:cut.minX-piece.minX,height:piece.height)) }
        if cut.maxX < piece.maxX { next.append(CGRect(x:cut.maxX,y:piece.minY,width:piece.maxX-cut.maxX,height:piece.height)) }
        if cut.minY > piece.minY { next.append(CGRect(x:cut.minX,y:piece.minY,width:cut.width,height:cut.minY-piece.minY)) }
        if cut.maxY < piece.maxY { next.append(CGRect(x:cut.minX,y:cut.maxY,width:cut.width,height:piece.maxY-cut.maxY)) }
      }
      if next.isEmpty { return false }
      if next.count > 64 { return true } // bounded conservative fallback
      pieces = next
    }
    return true
  }
  private var windows: [ReflectionWindow] = []
  private var rendered: [ReflectionWindow] = []
  private var size = CGSize.zero
  private var revision: UInt64 = 0
  private var renderedRevision: UInt64 = .max
  private var background: MTLTexture?
  private var desktop: Image?
  private var backgroundRetryAt: CFTimeInterval = 0
  private var renderedBackground: MTLTexture?
  private var target: MTLTexture?
  private var pending = false
  private var generation: UInt64 = 0
  private var nextCaptureAt: CFTimeInterval = 0
  private var failedCaptures = 0
  private(set) var captureTask: Task<Void, Never>?
  private var shareable: SCShareableContent?
  private var shareableAt: CFTimeInterval = -10
  private var missing: [CGWindowID: CFTimeInterval] = [:]
  private(set) var unavailable = false
  var maximumWidth: CGFloat = 1280
  var texture: MTLTexture? { target }

  init(
    device: MTLDevice, displayID: CGDirectDisplayID? = nil,
    snapshotProvider: SnapshotProvider? = nil
  ) throws {
    self.device = device
    self.displayID = displayID
    self.snapshotProvider = snapshotProvider
    let library = try device.makeLibrary(source: Self.shaders, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "snapshotVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "snapshotFragment")
    let color = descriptor.colorAttachments[0]!
    color.pixelFormat = .rgba8Unorm
    color.isBlendingEnabled = true
    color.sourceRGBBlendFactor = .one
    color.sourceAlphaBlendFactor = .one
    color.destinationRGBBlendFactor = .oneMinusSourceAlpha
    color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    descriptor.fragmentFunction = library.makeFunction(name: "snapshotBlend")
    transitionPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
  }

  func update(
    windows: [ReflectionWindow], size: CGSize, wallpaper: MTLTexture?, now: CFTimeInterval,
    regions: [CGRect]? = nil, includeDesktop: Bool = true, separateWater: Bool = false
  ) {
    guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
      stop()
      return
    }
    clock = now
    if selectionInput != windows || selectionRegions != regions || self.size != size {
      selectionInput = windows; selectionRegions = regions
      selected = Self.visibleWindows(windows, size: size, regions: regions)
      let visible = Set(selected.map(\.id))
      if retainedIDs != visible {
        retainedIDs = visible
        images = images.filter { visible.contains($0.key) }
        previousImages = previousImages.filter { visible.contains($0.key) }
        dirty.formIntersection(visible)
        requestedAt = requestedAt.filter { visible.contains($0.key) }
        missing = missing.filter { visible.contains($0.key) }
      }
    }
    self.windows = selected
    if self.includeDesktop != includeDesktop || self.separateWater != separateWater { renderedRevision = .max }
    self.includeDesktop = includeDesktop; self.separateWater = separateWater
    if !includeDesktop { desktop = nil; previousDesktop = nil }
    if !separateWater { windowTarget = nil; renderedWaterBackground = nil }
    self.size = size
    background = wallpaper
    let width = max(2, Int(min(size.width, maximumWidth)))
    let height = max(
      2,
      min(Int(size.height * CGFloat(width) / max(1, size.width)), max(512, Int(size.height * 0.5))))
    // Bound image storage to roughly 16 MiB even with many large windows.
    if target?.width != width || target?.height != height {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .private
      target = device.makeTexture(descriptor: descriptor)
      renderedRevision = .max
    }
    if separateWater && (windowTarget?.width != width || windowTarget?.height != height) {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
      d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
      windowTarget = device.makeTexture(descriptor: d)
    }
    guard !pending, now >= nextCaptureAt else { return }
    // Ten seconds normally. New/resized/dirty windows go first, with coalescing
    // to bound resize storms and allow each 150 ms crossfade to finish.
    let wanted = self.windows.filter { window in
      if let at = missing[window.id], now - at < 5 { return false }
      guard let image = images[window.id] else { return true }
      guard now - (requestedAt[window.id] ?? -.infinity) >= minimumEventInterval else { return false }
      return image.size != window.frame.size || dirty.contains(window.id) || now - image.at >= refreshInterval
    }.sorted {
      func priority(_ w: ReflectionWindow) -> Int {
        guard let image=images[w.id] else { return 0 }
        return image.size != w.frame.size || dirty.contains(w.id) ? 1:2
      }
      let a=priority($0),b=priority($1)
      return a == b ? (images[$0.id]?.at ?? -1) < (images[$1.id]?.at ?? -1) : a < b
    }.prefix(4)
    let needsBackground =
      includeDesktop && snapshotProvider == nil && now >= backgroundRetryAt
      && (desktop == nil || now - (desktop?.at ?? 0) >= refreshInterval || desktop?.size != size)
    guard !wanted.isEmpty || needsBackground else {
      nextCaptureAt = now + 0.05
      return
    }
    let pixels = self.windows.reduce(CGFloat(0)) {
      $0 + min(CGFloat(width), $1.frame.width * CGFloat(width) / size.width)
        * min(CGFloat(height), $1.frame.height * CGFloat(height) / size.height)
    }
    let cacheScale = min(1, sqrt(4_194_304 / max(1, pixels)))
    let requests = Array(wanted)
    for request in requests { requestedAt[request.id] = now; dirty.remove(request.id) }
    let token = generation
    pending = true
    nextCaptureAt = now + 0.05
    captureTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { if generation == token { pending = false; captureTask = nil } }
      do {
        if snapshotProvider == nil
          && (shareable == nil || now - shareableAt >= 30
            || requests.contains(where: { request in
              !(self.shareable?.windows.contains { $0.windowID == request.id } ?? false)
                || self.images[request.id].map { $0.size != request.frame.size } == true
            }))
        {
          let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
          guard generation == token, !Task.isCancelled else { return }
          shareable = content
          shareableAt = now
        }
        var captured = 0
        if needsBackground, let content = shareable,
          let display = content.displays.first(where: {
            self.displayID == nil || $0.displayID == self.displayID
          })
        {
          do {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let excluded = content.windows.filter {
              $0.windowLayer >= 0 || $0.owningApplication?.processID == ownPID
                || $0.owningApplication?.bundleIdentifier == "dev.grobb.Atmos"
            }
            let config = configuration(width: width, height: height, source: size)
            let sample = try await SCScreenshotManager.captureSampleBuffer(
              contentFilter: SCContentFilter(display: display, excludingWindows: excluded),
              configuration: config)
            guard generation == token, !Task.isCancelled else { return }
            if let buffer = CMSampleBufferGetImageBuffer(sample),
              let image = image(from: buffer, size: size, at: now, uvRect: ReflectionGeometry.uvRect(sample: sample))
            {
              if let desktop { previousDesktop = (desktop, clock) }
              desktop = image
              captured += 1; captureCount += 1
            } else {
              backgroundRetryAt = now + 10
            }
          } catch { backgroundRetryAt = now + 10; captureFailed?(error) }
        }
        for request in requests {
          do {
            let config = configuration(
              width: max(
                2, Int(min(CGFloat(width), request.frame.width * CGFloat(width) / size.width * cacheScale))),
              height: max(
                2,
                Int(min(CGFloat(height), request.frame.height * CGFloat(height) / size.height * cacheScale))),
              source: request.frame.size)
            let buffer: CVPixelBuffer?
            var uvRect = SIMD4<Float>(0,0,1,1)
            if let snapshotProvider {
              buffer = try await snapshotProvider(
                request.id, CGSize(width: config.width, height: config.height))
            } else {
              guard let window = shareable?.windows.first(where: { $0.windowID == request.id }),
                window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier,
                window.owningApplication?.bundleIdentifier != "dev.grobb.Atmos"
              else {
                missing[request.id] = now
                continue
              }
              // A desktop-independent filter already crops to its window. A
              // display-space source rectangle can add transparent gutters or
              // crop a differently scaled backing store on Retina displays.
              config.sourceRect = .zero
              let sample = try await SCScreenshotManager.captureSampleBuffer(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config)
              buffer = CMSampleBufferGetImageBuffer(sample)
              uvRect = ReflectionGeometry.uvRect(sample: sample)
            }
            guard generation == token, !Task.isCancelled else { return }
            guard let buffer, let image = image(from: buffer, size: request.frame.size, at: now, uvRect: uvRect) else {
              missing[request.id] = now
              continue
            }
            guard self.windows.contains(where: { $0.id == request.id }) else { continue }
            if let old = images[request.id] { previousImages[request.id] = (old, clock) }
            images[request.id] = image
            captured += 1; captureCount += 1
          } catch {
            guard generation == token, !Task.isCancelled else { return }
            missing[request.id] = now
            captureFailed?(error)
          }
        }
        if captured > 0 {
          revision &+= 1
          failedCaptures = 0
        } else {
          failedCaptures += 1
        }
      } catch { failedCaptures += 1; captureFailed?(error) }
      if generation == token {
        unavailable = false
        if failedCaptures >= 3 { nextCaptureAt = clock + min(30, Double(failedCaptures) * 2) }
        pending = false
        captureTask = nil
      }
    }
  }

  /// Encoded on the same command queue as water, so texture updates never race
  /// a reflection reader. A still desktop needs no compositing draw at all.
  func encode(into command: MTLCommandBuffer, now: Double? = nil) {
    let now = now ?? clock
    let expired = previousImages.contains { now - $0.value.at >= 0.15 }
      || previousDesktop.map { now - $0.at >= 0.15 } == true
    previousImages = previousImages.filter { now - $0.value.at < 0.15 }
    if let previousDesktop, now - previousDesktop.at >= 0.15 { self.previousDesktop = nil }
    let fading = !previousImages.isEmpty || previousDesktop != nil
    let background = desktop?.texture ?? self.background
    guard let target, size.width > 0, size.height > 0,
      rendered != windows || renderedRevision != revision || renderedBackground !== background
        || renderedWaterBackground !== self.background || fading || expired
    else { return }
    for output in [target, separateWater ? windowTarget : nil].compactMap({ $0 }) {
      let waterOnly = output === windowTarget
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = output
      pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0.12, 0.16, 0.22, 1)
      guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { continue }
      encoder.setRenderPipelineState(pipeline)
      encodingTransition = false
      if let base = waterOnly ? self.background : background {
        let previous = waterOnly ? nil : previousDesktop
        draw(base, previous: previous?.image.texture,
          uvRect: waterOnly ? SIMD4(0,0,1,1) : desktop?.uvRect ?? SIMD4(0,0,1,1),
          previousRect: previous?.image.uvRect ?? SIMD4(0,0,1,1),
          blend: previous.map { Float(min(1, max(0, (now-$0.at)/0.15))) } ?? 1,
          frame: CGRect(origin: .zero, size: size), alpha: 1, encoder: encoder)
      }
      for window in windows.reversed() {
        guard let image = images[window.id] else { continue }
        let previous = previousImages[window.id]
        draw(image.texture, previous: previous?.image.texture,
          uvRect: image.uvRect, previousRect: previous?.image.uvRect ?? image.uvRect,
          blend: previous.map { Float(min(1, max(0, (now-$0.at)/0.15))) } ?? 1,
          frame: window.frame, alpha: window.alpha, encoder: encoder)
      }
      encoder.endEncoding()
    }
    let held = Array(images.values) + previousImages.values.map(\.image)
      + [desktop, previousDesktop?.image].compactMap { $0 }
    command.addCompletedHandler { _ in withExtendedLifetime(held) {} }
    rendered = windows; renderedRevision = revision
    renderedBackground = background; renderedWaterBackground = self.background
    compositeCount += 1; compositedAt = now
  }

  private func draw(
    _ texture: MTLTexture, previous: MTLTexture? = nil,
    uvRect: SIMD4<Float> = SIMD4(0,0,1,1), previousRect: SIMD4<Float> = SIMD4(0,0,1,1), blend: Float = 1,
    frame: CGRect, alpha: Float, encoder: MTLRenderCommandEncoder
  ) {
    var rect = SIMD4<Float>(
      Float(frame.minX / size.width), Float(frame.minY / size.height),
      Float(frame.width / size.width), Float(frame.height / size.height))
    var opacity = SIMD2(alpha, blend)
    let transition = previous != nil && blend < 1
    if transition != encodingTransition {
      encoder.setRenderPipelineState(transition ? transitionPipeline : pipeline)
      encodingTransition = transition
    }
    encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
    encoder.setFragmentBytes(&opacity, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    let sampling = [uvRect, previousRect]
    sampling.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: 32, index: 1) }
    encoder.setFragmentTexture(texture, index: 0)
    encoder.setFragmentTexture(previous ?? texture, index: 1)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
  }

  func stop() {
    generation &+= 1
    pending = false
    nextCaptureAt = 0
    captureTask?.cancel()
    captureTask = nil
    shareable = nil
    shareableAt = -10
    images.removeAll(); previousImages.removeAll(); previousDesktop = nil
    dirty.removeAll(); requestedAt.removeAll(); selectionInput.removeAll(); selected.removeAll()
    retainedIDs.removeAll()
    selectionRegions = nil; windowTarget = nil; renderedWaterBackground = nil; compositedAt = nil
    windows.removeAll()
    rendered.removeAll()
    missing.removeAll()
    target = nil
    background = nil
    renderedBackground = nil
    desktop = nil
    backgroundRetryAt = 0
    renderedRevision = .max
    unavailable = false
    failedCaptures = 0
  }

  private func configuration(width: Int, height: Int, source: CGSize) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.width = width
    config.height = height
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    config.capturesAudio = false
    config.ignoreShadowsSingleWindow = true
    config.shouldBeOpaque = false
    config.sourceRect = CGRect(origin: .zero, size: source)
    config.destinationRect = CGRect(x: 0, y: 0, width: width, height: height)
    config.preservesAspectRatio = false
    config.scalesToFit = true
    config.colorSpaceName = CGColorSpace.sRGB
    return config
  }

  private func image(from buffer: CVPixelBuffer, size: CGSize, at: Double,
    uvRect: SIMD4<Float> = SIMD4(0,0,1,1)) -> Image? {
    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: CVPixelBufferGetWidth(buffer),
      height: CVPixelBufferGetHeight(buffer), mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    else { return nil }
    return Image(texture: texture, size: size, at: at, buffer: buffer, uvRect: uvRect)
  }

  private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct SnapshotOut { float4 position [[position]]; float2 uv; };
    vertex SnapshotOut snapshotVertex(uint id [[vertex_id]],constant float4 &rect [[buffer(0)]]) {
        float2 uv=float2(id&1,id>>1);float2 point=rect.xy+uv*rect.zw;
        SnapshotOut out;out.position=float4(point.x*2-1,1-point.y*2,0,1);out.uv=uv;return out;
    }
    fragment float4 snapshotFragment(SnapshotOut in [[stage_in]],texture2d<float> image [[texture(0)]],constant float2 &opacity [[buffer(0)]],constant float4 *sampling [[buffer(1)]]) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        return image.sample(s,sampling[0].xy+in.uv*sampling[0].zw)*opacity.x;
    }
    fragment float4 snapshotBlend(SnapshotOut in [[stage_in]],texture2d<float> image [[texture(0)]],texture2d<float> previous [[texture(1)]],constant float2 &opacity [[buffer(0)]],constant float4 *sampling [[buffer(1)]]) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        return mix(previous.sample(s,sampling[1].xy+in.uv*sampling[1].zw),image.sample(s,sampling[0].xy+in.uv*sampling[0].zw),opacity.y)*opacity.x;
    }
    """
}
