import Foundation
import simd

/// Shared coarse flow field, refreshed at 12 Hz independently of native-rate particles.
/// Windows shelter their lee and split flow at the edges; bilinear sampling avoids cell steps.
final class WindField {
  let spacing: Float = 48
  private(set) var columns = 0
  private(set) var rows = 0
  private(set) var cells: [SIMD4<Float>] = []
  private var updatedAt: Double = -100
  private(set) var base: Float = 0

  func update(
    size: SIMD2<Float>, windows: [SIMD4<Float>], wind: Float, turbulence: Float, time: Double
  ) {
    let columns = max(2, min(128, Int(ceil(size.x / spacing)) + 1))
    let rows = max(2, min(96, Int(ceil(size.y / spacing)) + 1))
    if self.columns != columns || self.rows != rows {
      self.columns = columns
      self.rows = rows
      cells = Array(repeating: .zero, count: columns * rows)
      updatedAt = -100
    }
    guard time - updatedAt >= 1 / 12 || time < updatedAt else { return }
    updatedAt = time
    base = wind
    let t = Float(time)
    let direction: Float = wind < 0 ? -1 : 1
    let energy = max(abs(wind) * 0.12, turbulence)
    for y in 0..<rows {
      for x in 0..<columns {
        let point = SIMD2(Float(x) * spacing, Float(y) * spacing)
        // Gust fronts travel downwind, with slower, larger structures above the desktop.
        let front = sin(point.x * 0.006 - direction * t * 0.9 + sin(point.y * 0.004 + t * 0.17))
        var velocity = SIMD2(
          wind + energy * front,
          energy * 0.35 * sin(point.x * 0.011 + t * 0.7) * cos(point.y * 0.009 - t * 0.3))
        var exposure: Float = 1
        for b in windows.prefix(48) {
          let downwind = direction > 0 ? point.x - b.z : b.x - point.x
          let vertical = max(b.y - point.y, point.y - b.w, 0)
          if downwind >= 0 && downwind < 320 && vertical < 48 {
            let shelter = (1 - downwind / 320) * (1 - vertical / 48)
            exposure = min(exposure, 1 - shelter * 0.82)
            let edge = min(abs(point.y - b.y), abs(point.y - b.w))
            let curl = exp(-edge / 45) * exp(-downwind / 160)
            velocity.y += direction * energy * 2 * sin(downwind * 0.035 - t * 1.7) * curl
          }
          if point.x >= b.x && point.x <= b.z && point.y >= b.y && point.y <= b.w {
            exposure = min(exposure, 0.28)
          }
        }
        cells[y * columns + x] = SIMD4(velocity.x * exposure, velocity.y * exposure, exposure, 0)
      }
    }
  }

  func sample(_ point: SIMD2<Float>) -> SIMD2<Float> {
    guard !cells.isEmpty else { return SIMD2(base, 0) }
    let p = simd_clamp(
      point / spacing, .zero, SIMD2(Float(columns - 1) - 0.001, Float(rows - 1) - 0.001))
    let x = Int(p.x)
    let y = Int(p.y)
    let f = p - SIMD2(Float(x), Float(y))
    let a = simd_mix(cells[y * columns + x], cells[y * columns + x + 1], SIMD4(repeating: f.x))
    let b = simd_mix(
      cells[(y + 1) * columns + x], cells[(y + 1) * columns + x + 1], SIMD4(repeating: f.x))
    let value = simd_mix(a, b, SIMD4(repeating: f.y))
    return SIMD2(value.x, value.y)
  }
}
