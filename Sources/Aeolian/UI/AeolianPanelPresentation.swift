import AppKit
import QuartzCore

/// Common ordering and animation geometry for Atmos's own panels.
enum AeolianPanelPresentation {
  static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
  static let identifier = NSUserInterfaceItemIdentifier("Aeolian.Panel")
  static var visibleFrames: [CGRect] {
    NSApp.windows.compactMap {
      $0.identifier == identifier && $0.isVisible && $0.alphaValue > 0.001 ? $0.frame : nil
    }
  }
  /// AppKit owns layer anchors. Compensate in the transform instead of changing
  /// the anchor/position beneath AppKit during a resize or layout pass.
  static func centeredScale(_ scale: CGFloat, bounds: CGRect, anchor: CGPoint) -> CATransform3D {
    let dx = bounds.width * (0.5 - anchor.x), dy = bounds.height * (0.5 - anchor.y)
    var transform = CATransform3DMakeTranslation(dx, dy, 0)
    transform = CATransform3DScale(transform, scale, scale, 1)
    return CATransform3DTranslate(transform, -dx, -dy, 0)
  }
  static func settle(layer: CALayer, scales: [CGFloat], keyTimes: [NSNumber], duration: Double) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: "transform")
    animation.values = scales.map { NSValue(caTransform3D: centeredScale($0, bounds: layer.bounds, anchor: layer.anchorPoint)) }
    animation.keyTimes = keyTimes; animation.duration = duration
    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(0, scales.count - 1))
    return animation
  }
}
