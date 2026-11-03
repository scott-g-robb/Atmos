import AppKit
import QuartzCore

/// The snow lying on the Dock, drawn in a strip along the bottom of the screen just below the Dock's level:
/// the main overlay sits above the Dock, where the snow would cover icons that grow under the pointer.
/// The strip shares the main overlay's coordinates, with its origin at the bottom left of the screen.
final class DockOverlay {
  let window: OverlayWindow
  private let layer = CAMetalLayer()
  private var screenFrame: CGRect
  private var scale: CGFloat = 1
  private let occlusionMask = WindowOcclusionMask()
  private var occludingWindows: [CGRect] = []

  func setOccludingWindows(_ frames: [CGRect]) {
    occludingWindows = frames
    updateOcclusion()
  }

  private func updateOcclusion() {
    occlusionMask.apply(
      to: layer,
      bounds: CGRect(x: 0, y: 0, width: screenFrame.width, height: height),
      excluding: occludingWindows)
  }

  func setDetailedRendering(_ detailed: Bool) {
    let next: CGFloat = detailed ? 2 : 1
    guard next != scale else { return }
    scale = next
    place()
  }
  /// The strip's height; it grows to fit the snow and shrinks back as the snow goes.
  private(set) var height: CGFloat = 1

  init(screen: NSScreen, device: MTLDevice) {
    screenFrame = screen.frame
    window = OverlayWindow(screen: screen, level: OverlayWindow.belowDockLevel)
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.isOpaque = false
    layer.framebufferOnly = false
    layer.maximumDrawableCount = 2
    // While the strip resizes, a frame of the other size stays pinned to the shared origin instead of stretching.
    layer.contentsGravity = .resize
    layer.needsDisplayOnBoundsChange = false
    let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
    view.layer = layer
    view.wantsLayer = true
    view.autoresizingMask = [.width, .height]
    window.contentView = view
    place()
    window.orderFrontRegardless()
  }

  func fit(to screen: NSScreen) {
    screenFrame = screen.frame
    place()
  }

  /// The next frame to draw into, cleared, with the strip resized first to reach `top`.
  func nextFrame(reaching top: CGFloat) -> (
    drawable: CAMetalDrawable, pass: MTLRenderPassDescriptor
  )? {
    // Steps of 64 points keep a growing drift from resizing the window every frame.
    let needed = min(
      screenFrame.height,
      scale > 1
        ? (max(top, 1) / 8).rounded(.up) * 8 + 4
        : (max(top, 1) / 64).rounded(.up) * 64 + 32)
    if needed > height || needed < height - (scale > 1 ? 16 : 128) {
      height = needed
      place()
    }
    return frame()
  }

  /// A cleared frame with no snow to show, the strip shrunk to a line so its larger frames go back.
  func emptyFrame() -> (drawable: CAMetalDrawable, pass: MTLRenderPassDescriptor)? {
    if height != 1 {
      height = 1
      place()
    }
    return frame()
  }

  private func frame() -> (drawable: CAMetalDrawable, pass: MTLRenderPassDescriptor)? {
    guard let drawable = layer.nextDrawable() else { return nil }
    let pass = MTLRenderPassDescriptor()
    let attachment = pass.colorAttachments[0]!
    attachment.texture = drawable.texture
    attachment.loadAction = .clear
    attachment.storeAction = .store
    attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
    return (drawable, pass)
  }

  func close() {
    window.orderOut(nil)
  }

  private func place() {
    window.setFrame(
      CGRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: height),
      display: false)
    // Keep point geometry and texture pixels paired, including non-Retina displays.
    layer.contentsScale = scale
    layer.drawableSize = CGSize(width: screenFrame.width * scale, height: height * scale)
    updateOcclusion()
  }
}
