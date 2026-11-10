import CWeatherCore
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
    cells.withUnsafeMutableBufferPointer { cells in
      windows.withUnsafeBufferPointer { windows in
        sh_build_wind(cells.baseAddress,columns,rows,spacing,windows.baseAddress,windows.count,wind,turbulence,Float(time))
      }
    }
  }

  func sample(_ point: SIMD2<Float>) -> SIMD2<Float> {
    cells.withUnsafeBufferPointer { cells in
      sh_sample_wind(cells.baseAddress,columns,rows,spacing,base,point.x,point.y)
    }
  }
}
