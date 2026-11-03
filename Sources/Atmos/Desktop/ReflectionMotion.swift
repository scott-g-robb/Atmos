import Metal
import simd

/// Compare a small grid on the GPU, without copying desktop images to the CPU.
/// Persistent video/animation wakes full-rate reflections; excluded Atmos pixels
/// and idle capture callbacks cannot keep an otherwise still desktop awake.
final class ReflectionMotion {
  private let pipeline: MTLComputePipelineState
  private let samples: MTLBuffer
  private let counts: [MTLBuffer]
  private var slot = 0
  private var primed: UInt32 = 0
  private var nextAt: Double = 0
  init(device: MTLDevice) throws {
    let library = try device.makeLibrary(source: Self.source, options: nil)
    guard let function = library.makeFunction(name: "reflectionMotion"),
      let samples = device.makeBuffer(
        length: 32 * 18 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
      let a = device.makeBuffer(length: 4, options: .storageModeShared),
      let b = device.makeBuffer(length: 4, options: .storageModeShared)
    else { throw RendererError.unavailable }
    pipeline = try device.makeComputePipelineState(function: function)
    self.samples = samples
    counts = [a, b]
  }
  /// The parent's two-frame semaphore protects the two result slots. Read the
  /// result in its completion handler, before releasing that semaphore.
  func encode(texture: MTLTexture, into command: MTLCommandBuffer, now: Double) -> MTLBuffer? {
    guard now + 0.0005 >= nextAt, let encoder = command.makeComputeCommandEncoder() else {
      return nil
    }
    nextAt = now + 1 / 30
    let result = counts[slot % 2]
    slot += 1
    result.contents().storeBytes(of: UInt32(0), as: UInt32.self)
    var ready = primed
    primed = 1
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBuffer(samples, offset: 0, index: 0)
    encoder.setBuffer(result, offset: 0, index: 1)
    encoder.setBytes(&ready, length: 4, index: 2)
    encoder.dispatchThreads(
      MTLSize(width: 32, height: 18, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
    encoder.endEncoding()
    return result
  }
  private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void reflectionMotion(texture2d<float> frame [[texture(0)]],device float4 *previous [[buffer(0)]],
        device atomic_uint *changed [[buffer(1)]],constant uint &primed [[buffer(2)]],uint2 p [[thread_position_in_grid]]) {
        if(p.x>=32 || p.y>=18)return;
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        uint i=p.y*32+p.x;float4 value=frame.sample(s,(float2(p)+0.5)/float2(32,18));
        float3 delta=abs(value.rgb-previous[i].rgb);previous[i]=value;
        if(primed && max(delta.r,max(delta.g,delta.b))>0.012)atomic_fetch_add_explicit(changed,1,memory_order_relaxed);
    }
    """
}
