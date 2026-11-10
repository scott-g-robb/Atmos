import MetalKit
import QuartzCore

/// Core Animation supplies an available drawable at the display's own cadence.
/// The UI thread never waits in MTKView.currentDrawable for a display refresh.
final class NativeFrameClock: NSObject, CAMetalDisplayLinkDelegate {
  private let link: CAMetalDisplayLink
  private weak var view: MTKView?
  private weak var renderer: Renderer?
  private var invalidated = false
  private var paused = false
  private var clearPending = false
  private(set) var deliveredFrames = 0
  private(set) var presentedFrames = 0
  private(set) var clearedFrames = 0
  var isPaused: Bool {
    get { invalidated || paused }
    set {
      guard !invalidated, paused != newValue else { return }
      paused = newValue
      clearPending = newValue
      // Consume one supplied drawable for a transparent frame before stopping.
      // Calling nextDrawable manually is invalid even while this link is paused.
      link.isPaused = false
    }
  }
  init?(view: MTKView, renderer: Renderer) {
    guard let layer = view.layer as? CAMetalLayer else { return nil }
    self.view = view; self.renderer = renderer
    link = CAMetalDisplayLink(metalLayer: layer)
    super.init()
    view.isPaused = true
    link.delegate = self
    link.preferredFrameLatency = 1
    updateRate()
    link.add(to: .main, forMode: .common)
  }
  func updateRate() {
    guard !invalidated, let renderer else { return }
    let rate = Float(renderer.presentationFrameRate)
    if link.preferredFrameRateRange.preferred != rate {
      link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }
  }
  func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    guard !invalidated, let view, let renderer else { return }
    if paused {
      if clearPending {
        renderer.clearForPause(in: view, drawable: update.drawable)
        clearedFrames += 1
      }
      clearPending = false; link.isPaused = true
      return
    }
    updateRate()
    // A wake/resize can retire a prefetched drawable from the old dimensions.
    // Wait for the next correctly sized surface rather than stretching one pixel.
    guard update.drawable.texture.width == Int(view.drawableSize.width),
      update.drawable.texture.height == Int(view.drawableSize.height) else { return }
    deliveredFrames += 1
    let presented = renderer.draw(in: view, providedDrawable: update.drawable)
    if presented { presentedFrames += 1 }
    if paused && !presented {
      if clearPending {
        renderer.clearForPause(in: view, drawable: update.drawable)
        clearedFrames += 1
      }
      clearPending = false; link.isPaused = true
    }
  }
  func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    link.isPaused = true; link.delegate = nil
    link.invalidate()
  }
  deinit { if !invalidated { link.invalidate() } }
}
