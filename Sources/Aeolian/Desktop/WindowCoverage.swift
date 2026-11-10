import Foundation

/// Computes the union, so overlapping windows never count the same screen pixels twice.
enum WindowCoverage {
  static func fraction(of screen: CGRect, windows: [CGRect]) -> CGFloat {
    guard screen.width > 0, screen.height > 0 else { return 0 }
    let clipped = windows.map { $0.intersection(screen) }.filter { !$0.isNull && !$0.isEmpty }
    let edges = Set(clipped.flatMap { [$0.minX, $0.maxX] }).sorted()
    guard edges.count > 1 else { return 0 }
    var area: CGFloat = 0
    for i in 1..<edges.count {
      let left = edges[i - 1]
      let right = edges[i]
      let intervals = clipped.filter { $0.minX < right && $0.maxX > left }.sorted {
        $0.minY < $1.minY
      }
      var end = screen.minY
      var covered: CGFloat = 0
      for rect in intervals where rect.maxY > end {
        covered += rect.maxY - max(end, rect.minY)
        end = rect.maxY
      }
      area += (right - left) * covered
    }
    return min(1, area / (screen.width * screen.height))
  }

  /// Only extensive coverage changes the whole overlay's level.
  static func shouldYield(
    screen: CGRect, windows: [CGRect], alreadyBehind: Bool = false
  ) -> Bool {
    let substantial = windows.filter { $0.width >= 80 && $0.height >= 40 && $0.intersects(screen) }
    let coverage = fraction(of: screen, windows: substantial)
    return coverage >= (alreadyBehind ? 0.68 : 0.70)
  }

  /// Top-edge windows occlude their own footprints, without lowering the whole scene.
  static func windowsAtTop(
    screen: CGRect, top: CGFloat, windows: [UInt32: CGRect], previous: Set<UInt32>
  ) -> [UInt32: CGRect] {
    windows.filter { id, frame in
      let tolerance: CGFloat = previous.contains(id) ? 5 : 1
      return frame.width >= 80 && frame.height >= 40 && frame.intersects(screen)
        && frame.maxY >= top - tolerance && frame.minY < top
    }
  }
}
