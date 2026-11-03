import QuartzCore

/// A cached compositor mask leaves only selected windows in front of every effect.
/// Geometry changes update the path; animation adds no extra Metal pass or CPU readback.
final class WindowOcclusionMask {
  private let shape = CAShapeLayer()
  private var lastBounds = CGRect.null
  private var lastWindows: [CGRect] = []

  static func visiblePath(in bounds: CGRect, excluding windows: [CGRect]) -> CGPath {
    var path = CGPath(rect: bounds, transform: nil)
    for frame in windows where frame.intersects(bounds) {
      let radius = min(18, frame.width / 2, frame.height / 2)
      let hole = CGPath(
        roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
      // Boolean subtraction keeps overlapping windows opaque instead of reopening a hole.
      path = path.subtracting(hole)
    }
    return path
  }

  func apply(to layer: CALayer, bounds: CGRect, excluding windows: [CGRect]) {
    guard bounds != lastBounds || windows != lastWindows else { return }
    lastBounds = bounds
    lastWindows = windows
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if windows.isEmpty {
      layer.mask = nil
    } else {
      shape.frame = bounds
      shape.fillColor = CGColor(gray: 1, alpha: 1)
      shape.path = Self.visiblePath(in: bounds, excluding: windows)
      layer.mask = shape
    }
    CATransaction.commit()
  }
}
