import CoreGraphics

/// Public geometry fallback when a macOS version cannot report managed Spaces.
/// True full screen reaches all four display edges; a maximized desktop window
/// below the menu bar does not. The union also handles Split View.
enum FullScreenDetection {
  static func coversDisplay(_ screen: CGRect, windows: [CGRect]) -> Bool {
    guard screen.width > 0, screen.height > 0 else { return false }
    let clipped = windows.filter { $0.width > 80 && $0.height > 80 }.map { $0.intersection(screen) }
      .filter { !$0.isNull && !$0.isEmpty }
    guard WindowCoverage.fraction(of: screen, windows: clipped) >= 0.995 else { return false }
    let top = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 4)
    let bottom = CGRect(x: screen.minX, y: screen.maxY - 4, width: screen.width, height: 4)
    return WindowCoverage.fraction(of: top, windows: clipped) > 0.98
      && WindowCoverage.fraction(of: bottom, windows: clipped) > 0.98
  }
}
