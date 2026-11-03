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
}

final class WindowReflections {
  typealias SnapshotProvider = (CGWindowID, CGSize) async throws -> CVPixelBuffer?
  private let device: MTLDevice
  private let snapshotProvider: SnapshotProvider?
  private let displayID: CGDirectDisplayID?
  private let pipeline: MTLRenderPipelineState
  private final class Image {
    let texture: MTLTexture
    let size: CGSize
    let at: CFTimeInterval
    let buffer: CVPixelBuffer
    init(texture: MTLTexture, size: CGSize, at: CFTimeInterval, buffer: CVPixelBuffer) {
      self.texture = texture
      self.size = size
      self.at = at
      self.buffer = buffer
    }
  }
  private var images: [CGWindowID: Image] = [:]
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
  }

  func update(
    windows: [ReflectionWindow], size: CGSize, wallpaper: MTLTexture?, now: CFTimeInterval
  ) {
    guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
      stop()
      return
    }
    self.windows = Array(windows.prefix(32))
    self.size = size
    background = wallpaper
    let visible = Set(self.windows.map(\.id))
    images = images.filter { visible.contains($0.key) }
    missing = missing.filter { visible.contains($0.key) }
    let width = max(2, Int(min(size.width, maximumWidth)))
    let height = max(
      2,
      min(Int(size.height * CGFloat(width) / max(1, size.width)), max(512, Int(size.height * 0.5))))
    // Bound image storage to roughly 16 MiB even with many large windows.
    let pixels = self.windows.reduce(CGFloat(0)) {
      $0 + min(CGFloat(width), $1.frame.width * CGFloat(width) / size.width)
        * min(CGFloat(height), $1.frame.height * CGFloat(height) / size.height)
    }
    let cacheScale = min(1, sqrt(4_194_304 / max(1, pixels)))
    if target?.width != width || target?.height != height {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .private
      target = device.makeTexture(descriptor: descriptor)
      renderedRevision = .max
    }
    guard !pending, now >= nextCaptureAt else { return }
    // One fresh snapshot per visible window each second, bounded to four
    // captures per scheduling pass. New and resized windows go first.
    let wanted = self.windows.filter { window in
      if let at = missing[window.id], now - at < 5 { return false }
      guard let image = images[window.id] else { return true }
      return image.size != window.frame.size || now - image.at >= 1
    }.sorted { (images[$0.id]?.at ?? -1) < (images[$1.id]?.at ?? -1) }.prefix(4)
    let needsBackground =
      snapshotProvider == nil && now >= backgroundRetryAt
      && (desktop == nil || now - (desktop?.at ?? 0) >= 10 || desktop?.size != size)
    guard !wanted.isEmpty || needsBackground else {
      nextCaptureAt = now + 0.1
      return
    }
    let requests = Array(wanted)
    let token = generation
    pending = true
    nextCaptureAt = now + 0.1
    captureTask = Task { @MainActor [weak self] in
      guard let self else { return }
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
            }
            let config = configuration(width: width, height: height, source: size)
            let sample = try await SCScreenshotManager.captureSampleBuffer(
              contentFilter: SCContentFilter(display: display, excludingWindows: excluded),
              configuration: config)
            guard generation == token, !Task.isCancelled else { return }
            if let buffer = CMSampleBufferGetImageBuffer(sample),
              let image = image(from: buffer, size: size)
            {
              desktop = image
              captured += 1
            } else {
              backgroundRetryAt = now + 10
            }
          } catch { backgroundRetryAt = now + 10 }
        }
        for request in requests {
          do {
            let config = configuration(
              width: max(
                2, min(width, Int(request.frame.width * CGFloat(width) / size.width * cacheScale))),
              height: max(
                2,
                min(height, Int(request.frame.height * CGFloat(height) / size.height * cacheScale))),
              source: request.frame.size)
            let buffer: CVPixelBuffer?
            if let snapshotProvider {
              buffer = try await snapshotProvider(
                request.id, CGSize(width: config.width, height: config.height))
            } else {
              guard let window = shareable?.windows.first(where: { $0.windowID == request.id })
              else {
                missing[request.id] = now
                continue
              }
              let sample = try await SCScreenshotManager.captureSampleBuffer(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config)
              buffer = CMSampleBufferGetImageBuffer(sample)
            }
            guard generation == token, !Task.isCancelled else { return }
            guard let buffer, let image = image(from: buffer, size: request.frame.size) else {
              missing[request.id] = now
              continue
            }
            images[request.id] = image
            captured += 1
          } catch {
            guard generation == token, !Task.isCancelled else { return }
            missing[request.id] = now
          }
        }
        if captured > 0 {
          revision &+= 1
          failedCaptures = 0
        } else {
          failedCaptures += 1
        }
      } catch { failedCaptures += 1 }
      if generation == token {
        unavailable = failedCaptures >= 3
        pending = false
        captureTask = nil
      }
    }
  }

  /// Encoded on the same command queue as water, so texture updates never race
  /// a reflection reader. A still desktop needs no compositing draw at all.
  func encode(into command: MTLCommandBuffer) {
    let background = desktop?.texture ?? self.background
    guard let target, size.width > 0, size.height > 0,
      rendered != windows || renderedRevision != revision || renderedBackground !== background
    else { return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.12, 0.16, 0.22, 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
    encoder.setRenderPipelineState(pipeline)
    if let background {
      draw(background, frame: CGRect(origin: .zero, size: size), alpha: 1, encoder: encoder)
    }
    for window in windows.reversed() {
      guard let image = images[window.id] else { continue }
      draw(image.texture, frame: window.frame, alpha: window.alpha, encoder: encoder)
    }
    encoder.endEncoding()
    let held = Array(images.values) + [desktop].compactMap { $0 }
    command.addCompletedHandler { _ in withExtendedLifetime(held) {} }
    rendered = windows
    renderedRevision = revision
    renderedBackground = background
  }

  private func draw(
    _ texture: MTLTexture, frame: CGRect, alpha: Float, encoder: MTLRenderCommandEncoder
  ) {
    var rect = SIMD4<Float>(
      Float(frame.minX / size.width), Float(frame.minY / size.height),
      Float(frame.width / size.width), Float(frame.height / size.height))
    var opacity = alpha
    encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
    encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
    encoder.setFragmentTexture(texture, index: 0)
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
    images.removeAll()
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

  private func image(from buffer: CVPixelBuffer, size: CGSize) -> Image? {
    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: CVPixelBufferGetWidth(buffer),
      height: CVPixelBufferGetHeight(buffer), mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    else { return nil }
    return Image(texture: texture, size: size, at: CACurrentMediaTime(), buffer: buffer)
  }

  private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct SnapshotOut { float4 position [[position]]; float2 uv; };
    vertex SnapshotOut snapshotVertex(uint id [[vertex_id]],constant float4 &rect [[buffer(0)]]) {
        float2 uv=float2(id&1,id>>1);float2 point=rect.xy+uv*rect.zw;
        SnapshotOut out;out.position=float4(point.x*2-1,1-point.y*2,0,1);out.uv=uv;return out;
    }
    fragment float4 snapshotFragment(SnapshotOut in [[stage_in]],texture2d<float> image [[texture(0)]],constant float &alpha [[buffer(0)]]) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        return image.sample(s,in.uv)*alpha;
    }
    """
}
