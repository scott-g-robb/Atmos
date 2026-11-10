import CWeatherCore
import simd

/// Small, reusable flow grid; density and momentum travel with the mouse and keep swirling after it leaves.
final class SmokeSimulation {
  let columns: Int
  let rows: Int
  let spacing: Float
  private(set) var cells: [SIMD4<Float>]
  private var spare: [SIMD4<Float>]
  private var pressure: [Float]
  private var gpuDriven = false
  private(set) var pendingSteps: [SmokeStep] = []
  func useGPU() { gpuDriven = true }
  func consumeGPUSteps() { pendingSteps.removeAll(keepingCapacity: true) }

  init(size: SIMD2<Float>) {
    spacing = max(18, max(size.x / 90, size.y / 60))
    columns = max(3, Int(ceil(size.x / spacing)) + 1)
    rows = max(3, Int(ceil(size.y / spacing)) + 1)
    cells = Array(repeating: .zero, count: columns * rows)
    spare = cells
    pressure = Array(repeating: 0, count: cells.count)
  }

  func step(
    dt: Float, time: Float, wind: Float, cursor: SIMD4<Float>, previous: SIMD2<Float>,
    sources: [SIMD4<Float>]
  ) {
    if gpuDriven {
      pendingSteps.append(
        SmokeStep(
          shape: SIMD4(Float(columns), Float(rows), spacing, dt),
          motion: SIMD4(time, wind, cursor.x, cursor.y),
          input: SIMD4(cursor.z, cursor.w, previous.x, previous.y),
          counts: SIMD4(Float(sources.count), 0, 0, 0), sources: sources))
      return
    }
    var cursor = cursor
    var previous = previous
    cells.withUnsafeMutableBufferPointer { c in
      spare.withUnsafeMutableBufferPointer { s in
        pressure.withUnsafeMutableBufferPointer { p in
          sources.withUnsafeBufferPointer { sources in
            sh_step_smoke(
              c.baseAddress, s.baseAddress, p.baseAddress, columns, rows, spacing,
              dt, time, wind, &cursor, &previous, sources.baseAddress, sources.count)
          }
        }
      }
    }
  }
}
