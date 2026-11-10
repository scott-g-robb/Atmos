import CWeatherCore
import Metal
import XCTest
@testable import Aeolian

final class GPULiquidFieldTests: XCTestCase {
  func testGPUFieldMatchesRustAcrossDenseCellsHashCollisionsAndMotion() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable") }
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let library = try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + liquidFieldShaderSource, options: nil)
    let pipelines = try GPULiquidField.Pipelines(device: device, library: library)
    let gpu = try GPULiquidField(device: device, pipelines: pipelines)
    for count in [320, 8192] {
      var particles = (0..<count).map { i in WeatherParticle(
        rect: SIMD4(Float((i * 17) % 89) * 0.25 - 7, Float((i * 31) % 71) * 0.25 - 5, 0.75 + Float(i % 5) * 0.25, 1),
        motion: SIMD4(0, 0, 0, i % 11 == 0 ? 0 : 9), color: .zero, life: SIMD4(0, 10, 0.08, 0)) }
      let input = try XCTUnwrap(device.makeBuffer(length: count * MemoryLayout<WeatherParticle>.stride, options: .storageModeShared))
      let output = try XCTUnwrap(device.makeBuffer(length: count * 8 * 16, options: .storageModeShared))
      var reference = [SIMD4<Float>](repeating: .zero, count: count * 8)
      var scratch = [SIMD4<Float>](repeating: .zero, count: 4096 * 9)
      for frame in 0..<3 {
        if frame > 0 {
          for i in particles.indices { particles[i].rect.x += Float(i % 3 - 1) * 0.25; particles[i].rect.y += 0.25 }
        }
        particles.withUnsafeBytes { input.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        particles.withUnsafeBufferPointer { p in reference.withUnsafeMutableBufferPointer { r in scratch.withUnsafeMutableBufferPointer { s in
          sh_liquid_field(p.baseAddress, count, r.baseAddress, s.baseAddress)
        }}}
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(gpu.encode(particles: input, count: count, output: output, command: command))
        command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
        let field = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: count * 8)
        var maximumError: Float = 0
        for i in particles.indices where particles[i].motion.w == 9 {
          for k in 0..<8 { for axis in 0..<4 { maximumError = max(maximumError, abs(field[i * 8 + k][axis] - reference[i * 8 + k][axis])) } }
        }
        XCTAssertLessThanOrEqual(maximumError, 0.0001, "GPU neighbours must preserve the Rust field, including stable ties")
      }
    }
  }
}
