import Metal
import XCTest
import simd

@testable import Atmos

final class GPUSmokeTests: XCTestCase {
  func testSmokeAdvancesOnEveryProMotionFrame() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw XCTSkip("Metal unavailable")
    }
    for effect in [WeatherEffect.mist, .clouds, .storm, .lightning] {
      let renderer = try WeatherRenderer(
        device: device, format: .rgba8Unorm, size: SIMD2(640, 400), seed: 2718)
      renderer.setEffect(effect)
      renderer.simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
      let smoke = try XCTUnwrap(renderer.simulation.smoke)
      let gpu = try GPUSmoke(device: device, source: smoke)
      var previousDensity: Float = -1
      for frame in 0..<120 {
        renderer.simulation.step(dt: 1 / 120, cursor: SIMD2(Float(frame) + 300, 180))
        XCTAssertEqual(
          smoke.pendingSteps.count, 1, "A 120 Hz display must not reuse a 30 Hz flow update")
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        gpu.encode(into: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        let cells = gpu.cells.contents().bindMemory(
          to: SIMD4<Float>.self, capacity: smoke.cells.count)
        let density = (0..<smoke.cells.count).reduce(Float(0)) { $0 + cells[$1].z }
        XCTAssertGreaterThan(
          density, previousDensity,
          "\(effect.title) must advance between consecutive display frames")
        previousDensity = density
      }
    }
  }

  func testGPUAdvectionAndPressureMatchTheRustSolver() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let reference = SmokeSimulation(size: SIMD2(1512, 982))
    let simulation = SmokeSimulation(size: SIMD2(1512, 982))
    let gpu = try GPUSmoke(device: device, source: simulation)
    let sources: [SIMD4<Float>] = [
      SIMD4(760, 880, 740, 160), SIMD4(480, 520, 260, 24), SIMD4(1210, 180, 240, 60),
    ]
    var previous = SIMD2<Float>(1420, 160)
    for i in 0..<240 {
      let time = Float(i) / 30
      let point = SIMD2<Float>(1180 + cos(time * 1.3) * 240, 200 + sin(time * 1.7) * 160)
      let velocity = (point - previous) * 30
      let cursor = SIMD4(point.x, point.y, velocity.x, velocity.y)
      for solver in [reference, simulation] {
        solver.step(
          dt: 1 / 30, time: time, wind: 35, cursor: cursor, previous: previous, sources: sources)
      }
      previous = point
      // Exercise batched updates as well as single-frame updates.
      if i % 3 == 2 {
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        gpu.encode(into: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
      }
    }
    XCTAssertTrue(simulation.pendingSteps.isEmpty)
    let actual = gpu.cells.contents().bindMemory(
      to: SIMD4<Float>.self, capacity: reference.cells.count)
    var velocityError: Float = 0
    var densityError: Float = 0
    var pressureError: Float = 0
    for i in reference.cells.indices {
      let difference = simd_abs(actual[i] - reference.cells[i])
      XCTAssertTrue(
        actual[i].x.isFinite && actual[i].y.isFinite && actual[i].z.isFinite && actual[i].w.isFinite
      )
      velocityError = max(velocityError, difference.x, difference.y)
      densityError = max(densityError, difference.z)
      pressureError = max(pressureError, difference.w)
    }
    XCTAssertLessThan(velocityError, 0.025)
    XCTAssertLessThan(densityError, 0.0001)
    XCTAssertLessThan(pressureError, 0.05)
  }
}
