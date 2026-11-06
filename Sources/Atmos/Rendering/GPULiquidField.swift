import Metal

/// Reconstruct liquid neighbours directly into the render buffer. No CPU readback
/// or transfer of the neighbour field is needed; physics still owns its particles.
final class GPULiquidField {
  final class Pipelines {
    let clear: MTLComputePipelineState
    let build: MTLComputePipelineState
    let resolve: MTLComputePipelineState
    init(device: MTLDevice, library: MTLLibrary) throws {
      func make(_ name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else { throw RendererError.unavailable }
        return try device.makeComputePipelineState(function: function)
      }
      clear = try make("liquidClear")
      build = try make("liquidBuild")
      resolve = try make("liquidResolve")
    }
  }
  private let pipelines: Pipelines
  private let heads: MTLBuffer
  private let links: MTLBuffer
  init(device: MTLDevice, pipelines: Pipelines) throws {
    self.pipelines = pipelines
    guard let heads = device.makeBuffer(length: 8192 * 4, options: .storageModePrivate),
      let links = device.makeBuffer(length: 16384 * 4, options: .storageModePrivate)
    else { throw RendererError.unavailable }
    self.heads = heads; self.links = links
  }
  func encode(particles: MTLBuffer, count: Int, output: MTLBuffer, command: MTLCommandBuffer) -> Bool {
    guard count > 0, count <= 8192, particles.length >= count * 64,
      output.length >= count * 8 * 16,
      let encoder = command.makeComputeCommandEncoder() else { return false }
    var count = UInt32(count)
    encoder.label = "Liquid contour neighbours"
    encoder.setBuffer(particles, offset: 0, index: 0)
    encoder.setBuffer(heads, offset: 0, index: 1)
    encoder.setBuffer(links, offset: 0, index: 2)
    encoder.setBuffer(output, offset: 0, index: 3)
    encoder.setBytes(&count, length: 4, index: 4)
    for (pipeline, threads) in [(pipelines.clear, 8192), (pipelines.build, Int(count)), (pipelines.resolve, Int(count))] {
      encoder.setComputePipelineState(pipeline)
      encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
      encoder.memoryBarrier(scope: .buffers)
    }
    encoder.endEncoding()
    return true
  }
}

let liquidFieldShaderSource = """
  struct LiquidSample { float4 rect, motion, color, life; };
  static uint liquidHash(int2 cell) {
      return (uint(cell.x)*73856093u ^ uint(cell.y)*19349663u)&4095u;
  }
  kernel void liquidClear(device atomic_int *heads [[buffer(1)]], uint id [[thread_position_in_grid]]) {
      atomic_store_explicit(heads+id,-1,memory_order_relaxed);
  }
  kernel void liquidBuild(const device LiquidSample *p [[buffer(0)]],device atomic_int *heads [[buffer(1)]],
      device int *links [[buffer(2)]],constant uint &count [[buffer(4)]],uint id [[thread_position_in_grid]]) {
      if(id>=count || p[id].motion.w!=9.0)return;
      int2 cell=int2(p[id].rect.xy/4.0);
      links[id]=atomic_exchange_explicit(heads+liquidHash(cell),int(id),memory_order_relaxed);
      int2 small=int2(p[id].rect.xy/1.5);
      links[8192+id]=atomic_exchange_explicit(heads+4096+liquidHash(small),int(id),memory_order_relaxed);
  }
  kernel void liquidResolve(const device LiquidSample *p [[buffer(0)]],device atomic_int *heads [[buffer(1)]],
      const device int *links [[buffer(2)]],device float4 *field [[buffer(3)]],constant uint &count [[buffer(4)]],
      uint id [[thread_position_in_grid]]) {
      if(id>=count || p[id].motion.w!=9.0)return;
      int2 cell=int2(p[id].rect.xy/1.5);
      int first=atomic_load_explicit(heads+4096+liquidHash(cell),memory_order_relaxed);
      // One owner resolves each occupied cell, including dense sheets. Hash
      // collisions have separate owners; no cell or particle is dropped.
      for(int node=first;node>=0;node=links[8192+node]) {
          if(uint(node)<id && all(int2(p[node].rect.xy/1.5)==cell))return;
      }
      float2 centre=(float2(cell)+0.5)*1.5;
      int2 large=int2(centre/4.0);
      float distances[9];int indices[9];float4 nearest[9];
      for(uint k=0;k<9;k++){distances[k]=36.0;indices[k]=-1;nearest[k]=float4(0);}
      uint worst=0;
      for(int yy=large.y-1;yy<=large.y+1;yy++)for(int xx=large.x-1;xx<=large.x+1;xx++) {
          int node=atomic_load_explicit(heads+liquidHash(int2(xx,yy)),memory_order_relaxed);
          while(node>=0) {
              int j=node;node=links[node];
              if(any(int2(p[j].rect.xy/4.0)!=int2(xx,yy)))continue;
              float2 delta=p[j].rect.xy-centre;float distance=dot(delta,delta);
              if(distance<distances[worst] || (distance==distances[worst] && j>indices[worst] && distance<36.0)) {
                  distances[worst]=distance;indices[worst]=j;
                  nearest[worst]=float4(p[j].rect.xy,p[j].rect.z*0.5,1);
                  worst=0;
                  for(uint k=1;k<9;k++)if(distances[k]>distances[worst] || (distances[k]==distances[worst] && indices[k]<indices[worst]))worst=k;
              }
          }
      }
      for(uint n=1;n<9;n++) {
          uint k=n;
          while(k>0 && (distances[k]<distances[k-1] || (distances[k]==distances[k-1] && indices[k]>indices[k-1]))) {
              float d=distances[k];distances[k]=distances[k-1];distances[k-1]=d;
              int index=indices[k];indices[k]=indices[k-1];indices[k-1]=index;
              float4 value=nearest[k];nearest[k]=nearest[k-1];nearest[k-1]=value;k--;
          }
      }
      for(int node=first;node>=0;node=links[8192+node]) {
          if(any(int2(p[node].rect.xy/1.5)!=cell))continue;
          uint out=0;
          for(uint k=0;k<9 && out<8;k++) {
              float4 candidate=nearest[k];
              if(candidate.w>0.5 && all(abs(candidate.xy-p[node].rect.xy)<0.0001))continue;
              field[uint(node)*8+out++]=candidate;
          }
          while(out<8)field[uint(node)*8+out++]=float4(0);
      }
  }
  """
