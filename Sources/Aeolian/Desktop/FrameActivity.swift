import Foundation
import simd

/// Rendering may rest between frames, while input is still sampled at display
/// speed. A short hold prevents the rate oscillating during a drag or sweep.
final class FrameActivity {
  private var cursor: SIMD2<Float>?
  private var activeUntil: CFTimeInterval = -1
  private var changes: [CFTimeInterval] = []
  private(set) var lastReason = "none"

  func observeCursor(_ point: SIMD2<Float>, size: SIMD2<Float>, now: CFTimeInterval) {
    defer { cursor = point }
    guard point.x.isFinite, point.y.isFinite, let previous = cursor else { return }
    func inside(_ p: SIMD2<Float>) -> Bool {
      p.x >= -16 && p.y >= -16 && p.x <= size.x + 16 && p.y <= size.y + 16
    }
    if (inside(point) || inside(previous)) && simd_distance_squared(point, previous) > 0.01 {
      wake(now: now, reason: "cursor")
    }
  }
  func wake(now: CFTimeInterval, reason: String = "window") {
    activeUntil = max(activeUntil, now + 0.4)
    lastReason = reason
  }
  func observeDesktopChange(samples: UInt32, now: CFTimeInterval) {
    // Tiny animated indicators and updating text do not need a whole display
    // running at 120 Hz. Sustained motion across a meaningful area does.
    guard samples >= 24 else { return }
    changes.removeAll { now - $0 > 0.12 }
    changes.append(now)
    if changes.count >= 3 {
      wake(now: now, reason: "desktop")
      changes.removeFirst(changes.count - 2)
    }
  }
  func isActive(now: CFTimeInterval) -> Bool { now < activeUntil }
  func resetCursor() { cursor = nil }
}
