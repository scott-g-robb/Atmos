import Metal
import simd

struct SmokeStep {
  var shape: SIMD4<Float>
  var motion: SIMD4<Float>
  var input: SIMD4<Float>
  var counts: SIMD4<Float>
  var sources: [SIMD4<Float>]
}
private struct SmokeGPUUniforms {
  var shape: SIMD4<Float>
  var motion: SIMD4<Float>
  var input: SIMD4<Float>
  var counts: SIMD4<Float>
}

/// Persistent GPU state. Only the small source/input description crosses from the
/// CPU each update; advection, pressure projection and density stay on the GPU.
final class GPUSmoke {
  final class Pipelines {
    let advect: MTLComputePipelineState
    let divergence: MTLComputePipelineState
    let jacobi: MTLComputePipelineState
    let project: MTLComputePipelineState
    init(device: MTLDevice) throws {
      let options = MTLCompileOptions()
      options.fastMathEnabled = false
      let library = try device.makeLibrary(source: smokeShaderSource, options: options)
      func make(_ name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
          throw RendererError.unavailable
        }
        return try device.makeComputePipelineState(function: function)
      }
      advect = try make("smokeAdvect")
      divergence = try make("smokeDivergence")
      jacobi = try make("smokeJacobi")
      project = try make("smokeProject")
    }
  }
  let source: SmokeSimulation
  let cells: MTLBuffer
  let pipelines: Pipelines
  private let device: MTLDevice
  private let spare: MTLBuffer
  private let pressure: MTLBuffer
  private var inputs: [MTLBuffer] = []
  private var inputCapacity = 0
  private var slot = 0

  init(device: MTLDevice, source: SmokeSimulation, reusing pipelines: Pipelines? = nil) throws {
    self.device = device
    self.source = source
    self.pipelines = try pipelines ?? Pipelines(device: device)
    let length = source.cells.count * MemoryLayout<SIMD4<Float>>.stride
    guard
      let cells = source.cells.withUnsafeBytes({
        device.makeBuffer(bytes: $0.baseAddress!, length: length, options: .storageModeShared)
      }),
      let spare = device.makeBuffer(length: length, options: .storageModePrivate),
      let pressure = device.makeBuffer(
        length: source.cells.count * 12, options: .storageModePrivate)
    else { throw RendererError.unavailable }
    self.cells = cells
    self.spare = spare
    self.pressure = pressure
    source.useGPU()
  }

  func encode(into command: MTLCommandBuffer) {
    guard !source.pendingSteps.isEmpty else { return }
    let steps = source.pendingSteps
    let length = steps.reduce(0) { $0 + ((256 + max(16, $1.sources.count * 16) + 255) & ~255) }
    if inputs.isEmpty || length > inputCapacity {
      inputCapacity = max(1024, length * 3 / 2)
      inputs = (0..<2).compactMap { _ in
        device.makeBuffer(length: inputCapacity, options: .storageModeShared)
      }
    }
    guard inputs.count == 2, let encoder = command.makeComputeCommandEncoder() else { return }
    let input = inputs[slot % 2]
    slot += 1
    encoder.setBuffer(cells, offset: 0, index: 2)
    encoder.setBuffer(spare, offset: 0, index: 3)
    encoder.setBuffer(pressure, offset: 0, index: 4)
    let grid = MTLSize(width: source.columns, height: source.rows, depth: 1)
    let group = MTLSize(width: 16, height: 8, depth: 1)
    var offset = 0
    for step in steps {
      var uniforms = SmokeGPUUniforms(
        shape: step.shape, motion: step.motion, input: step.input, counts: step.counts)
      withUnsafeBytes(of: &uniforms) {
        input.contents().advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
      }
      step.sources.withUnsafeBytes {
        if !$0.isEmpty {
          input.contents().advanced(by: offset + 256).copyMemory(
            from: $0.baseAddress!, byteCount: $0.count)
        }
      }
      encoder.setBuffer(input, offset: offset, index: 0)
      encoder.setBuffer(input, offset: offset + 256, index: 1)
      encoder.setComputePipelineState(pipelines.advect)
      encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
      encoder.memoryBarrier(scope: .buffers)
      encoder.setComputePipelineState(pipelines.divergence)
      encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
      encoder.memoryBarrier(scope: .buffers)
      encoder.setComputePipelineState(pipelines.jacobi)
      for pass in UInt32(0)..<8 {
        var iteration = pass
        encoder.setBytes(&iteration, length: 4, index: 5)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
        encoder.memoryBarrier(scope: .buffers)
      }
      encoder.setComputePipelineState(pipelines.project)
      encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
      encoder.memoryBarrier(scope: .buffers)
      offset += (256 + max(16, step.sources.count * 16) + 255) & ~255
    }
    encoder.endEncoding()
    #if DEBUG
      if DebugMetrics.enabled { DebugMetrics.gpuSmokeSteps += UInt64(steps.count) }
    #endif
    source.consumeGPUSteps()
  }
}
