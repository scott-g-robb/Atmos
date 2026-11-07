import Metal
import QuartzCore

/// Fog-only scattering. All images stay on the GPU; broad blur runs at low
/// resolution while the original scene and the final composite stay native size.
final class FogBloom {
  private let device: MTLDevice
  private let windowColours: MTLComputePipelineState
  private let edgeCache: MTLBuffer
  private struct TrackedEdge {
    var slot: Int
    var frame: SIMD4<Float>
    var changed: Double
    var source: SIMD4<Float>
    var captured: Double = -.infinity
  }
  private var tracked: [UInt32: TrackedEdge] = [:]
  private var departed: [(frame: SIMD4<Float>, at: Double)] = []
  private let extract: MTLComputePipelineState
  private let blur: MTLComputePipelineState
  private let composite: MTLRenderPipelineState
  private(set) var scene: MTLTexture?
  private var field: MTLTexture?
  private var scratch: MTLTexture?

  init(device: MTLDevice, format: MTLPixelFormat) throws {
    self.device = device
    let library = try device.makeLibrary(source: fogBloomShaderSource, options: nil)
    windowColours = try device.makeComputePipelineState(function: library.makeFunction(name: "fogWindowColours")!)
    guard let cache = device.makeBuffer(length: 128*4*16, options: .storageModePrivate) else { throw RendererError.unavailable }
    edgeCache = cache
    extract = try device.makeComputePipelineState(function: library.makeFunction(name: "fogExtract")!)
    blur = try device.makeComputePipelineState(function: library.makeFunction(name: "fogBlur")!)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "fogBloomVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "fogBloomFragment")
    let color = descriptor.colorAttachments[0]!
    color.pixelFormat = format
    color.isBlendingEnabled = true
    color.sourceRGBBlendFactor = .one
    color.sourceAlphaBlendFactor = .one
    color.destinationRGBBlendFactor = .oneMinusSourceAlpha
    color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    composite = try device.makeRenderPipelineState(descriptor: descriptor)
  }

  func scenePass(for target: MTLTexture) -> MTLRenderPassDescriptor? {
    if scene?.width != target.width || scene?.height != target.height {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat,
        width: target.width, height: target.height, mipmapped: false)
      descriptor.storageMode = .private
      descriptor.usage = [.renderTarget, .shaderRead]
      scene = device.makeTexture(descriptor: descriptor)
      let width = min(640, max(2, target.width / 4))
      let height = max(2, Int((Double(width) * Double(target.height) / Double(target.width)).rounded()))
      let low = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false)
      low.storageMode = .private
      low.usage = [.shaderRead, .shaderWrite]
      field = device.makeTexture(descriptor: low)
      scratch = device.makeTexture(descriptor: low)
    }
    guard let scene, field != nil, scratch != nil else { return nil }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = scene
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    return pass
  }

  func prepare(desktop: MTLTexture, rect: SIMD4<Float>, size: SIMD2<Float>,
    windows: [SIMD4<Float>], command: MTLCommandBuffer, wallpaper: MTLTexture? = nil,
    windowIDs: [UInt32] = [], capturedAt: Double? = nil, now: Double = CACurrentMediaTime()) {
    guard let scene, let field, let scratch else { return }
    var rect = rect
    var geometry = SIMD4(size.x, size.y, Float(min(128, windows.count)), wallpaper == nil ? 0 : 1)
    let frames = Array(windows.prefix(128))
    var identities = Set<UInt32>()
    let ids = frames.indices.map { i -> UInt32 in
      let raw = i < windowIDs.count ? windowIDs[i] : UInt32(i+1)
      let id = raw != 0 && !identities.contains(raw) ? raw : UInt32.max-UInt32(i)
      identities.insert(id); return id
    }
    let visible = Set(ids)
    let capture = capturedAt ?? now
    for (id,edge) in tracked where !visible.contains(id) { departed.append((edge.frame,now)) }
    departed.removeAll { capture >= $0.at }
    if departed.count > 128 { departed.removeFirst(departed.count-128) }
    tracked = tracked.filter { visible.contains($0.key) }
    var exclusions = departed.map(\.frame)
    var used = Set(tracked.values.map(\.slot))
    var parameters = [SIMD4<Float>]()
    for (i,id) in ids.enumerated() {
      let fresh = tracked[id] == nil
      let slot = tracked[id]?.slot ?? (0..<128).first { !used.contains($0) }!
      used.insert(slot)
      var edge = tracked[id] ?? TrackedEdge(slot:slot,frame:frames[i],changed:now,source:frames[i])
      if edge.frame != frames[i] { edge.frame = frames[i]; edge.changed = now }
      // Colours stay attached to window identity throughout a drag. Refresh only
      // after capture has caught up to a stationary window, never from old pixels.
      let ready = capture >= edge.changed && (fresh || now-edge.changed >= 0.10)
      let update = ready && capture != edge.captured
      parameters.append(SIMD4(Float(slot),update ? 1:0,fresh ? 1:0,0))
      if update { edge.captured = capture; edge.source = frames[i] }
      let f = frames[i], old = edge.source
      exclusions.append(SIMD4(min(f.x,old.x),min(f.y,old.y),max(f.z,old.z),max(f.w,old.w)))
      tracked[id] = edge
    }
    if !frames.isEmpty, let encoder = command.makeComputeCommandEncoder() {
      encoder.setComputePipelineState(windowColours)
      encoder.setTexture(desktop,index:0)
      frames.withUnsafeBufferPointer { encoder.setBytes($0.baseAddress!,length:frames.count*16,index:0) }
      parameters.withUnsafeBufferPointer { encoder.setBytes($0.baseAddress!,length:parameters.count*16,index:1) }
      encoder.setBytes(&geometry,length:16,index:2)
      encoder.setBytes(&rect,length:16,index:3)
      encoder.setBuffer(edgeCache,offset:0,index:4)
      encoder.dispatchThreads(MTLSize(width:frames.count*4,height:1,depth:1),
        threadsPerThreadgroup:MTLSize(width:min(32,windowColours.maxTotalThreadsPerThreadgroup),height:1,depth:1))
      encoder.endEncoding()
    }
    if let encoder = command.makeComputeCommandEncoder() {
      encoder.setComputePipelineState(extract)
      encoder.setBuffer(edgeCache,offset:0,index:3)
      var count = UInt32(exclusions.count)
      encoder.setBytes(&count,length:4,index:6)
      if exclusions.isEmpty {
        var empty = SIMD4<Float>.zero;encoder.setBytes(&empty,length:16,index:5)
      } else { exclusions.withUnsafeBufferPointer {encoder.setBytes($0.baseAddress!,length:exclusions.count*16,index:5)} }
      if parameters.isEmpty {
        var empty = SIMD4<Float>.zero;encoder.setBytes(&empty,length:16,index:4)
      } else { parameters.withUnsafeBufferPointer {encoder.setBytes($0.baseAddress!,length:parameters.count*16,index:4)} }

      encoder.setTexture(desktop, index: 0)
      encoder.setTexture(scene, index: 1)
      encoder.setTexture(field, index: 2)
      encoder.setTexture(wallpaper ?? desktop, index: 3)
      encoder.setBytes(&rect, length: 16, index: 0)
      encoder.setBytes(&geometry, length: 16, index: 1)
      if windows.isEmpty {
        var empty = SIMD4<Float>.zero
        encoder.setBytes(&empty, length: 16, index: 2)
      } else {
        windows.withUnsafeBufferPointer {
          encoder.setBytes($0.baseAddress!, length: min(128, $0.count) * 16, index: 2)
        }
      }
      dispatch(encoder, pipeline: extract, texture: field)
      encoder.endEncoding()
    }
    for horizontal in [true, false] {
      guard let encoder = command.makeComputeCommandEncoder() else { return }
      var axis = horizontal ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1)
      encoder.setComputePipelineState(blur)
      encoder.setTexture(horizontal ? field : scratch, index: 0)
      encoder.setTexture(horizontal ? scratch : field, index: 1)
      encoder.setBytes(&axis, length: 8, index: 0)
      dispatch(encoder, pipeline: blur, texture: field)
      encoder.endEncoding()
    }
  }

  enum Contents: Float { case combined = 0, scene = 1, light = 2 }
  func encode(with encoder: MTLRenderCommandEncoder, size: SIMD2<Float>, amount: Float,
    windows: [SIMD4<Float>], contents: Contents = .combined) {
    guard let scene, let field else { return }
    var info = SIMD4(size.x, size.y, amount, Float(min(128, windows.count)))
    encoder.setRenderPipelineState(composite)
    encoder.setFragmentTexture(scene, index: 0)
    encoder.setFragmentTexture(field, index: 1)
    encoder.setFragmentBytes(&info, length: 16, index: 0)
    var mode = contents.rawValue
    encoder.setFragmentBytes(&mode, length: 4, index: 2)
    if windows.isEmpty {
      var empty = SIMD4<Float>.zero
      encoder.setFragmentBytes(&empty, length: 16, index: 1)
    } else {
      windows.withUnsafeBufferPointer {
        encoder.setFragmentBytes($0.baseAddress!, length: min(128, $0.count) * 16, index: 1)
      }
    }
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
  }

  func reset() { scene = nil; field = nil; scratch = nil; tracked.removeAll(keepingCapacity:true); departed.removeAll(keepingCapacity:true) }

  private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
    texture: MTLTexture) {
    let width = pipeline.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: width,
        height: min(8, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1))
  }
}

let fogBloomShaderSource = """
  #include <metal_stdlib>
  using namespace metal;
  constexpr sampler fogSample(coord::normalized, address::clamp_to_edge, filter::linear);
  // Signed rounded-window distance and its outward normal, in desktop points.
  static float3 fogWindowEdge(float2 world,float4 w) {
    float2 halfSize=(w.zw-w.xy)*0.5,p=world-(w.xy+w.zw)*0.5;
    float radius=min(18.0,min(halfSize.x,halfSize.y));
    float2 q=abs(p)-halfSize+radius,corner=max(q,0.0);
    float lengthCorner=length(corner);
    float d=lengthCorner+min(max(q.x,q.y),0.0)-radius;
    float2 n=lengthCorner>0.001 ? corner/lengthCorner : q.x>q.y ? float2(1,0) : float2(0,1);
    n*=select(float2(-1),float2(1),p>=0);
    return float3(d,n);
  }
  static float3 fogEmitter(float3 colour,float coverage,float floorEnergy) {
    float peak=max(colour.r,max(colour.g,colour.b));
    float3 hue=colour/max(0.025,peak);
    float energy=coverage*(floorEnergy+(1-floorEnergy)*sqrt(peak));
    return hue*hue*energy;
  }
  kernel void fogWindowColours(texture2d<float,access::sample> desktop [[texture(0)]],
    constant float4 *windows [[buffer(0)]],constant float4 *parameters [[buffer(1)]],
    constant float4 &geometry [[buffer(2)]],constant float4 &rect [[buffer(3)]],
    device float4 *cache [[buffer(4)]],uint gid [[thread_position_in_grid]]) {
    uint i=gid/4,side=gid%4;if(i>=uint(geometry.z))return;
    float4 p=parameters[i],w=windows[i];uint slot=uint(p.x)*4+side;
    float4 old=p.z>0.5 ? float4(0):cache[slot];
    if(p.y>0.5) {
      float3 sum=0;float weight=0;
      for(int j=0;j<7;j++) {
        float t=(float(j)+1)/8.0;
        float2 at=side<2 ? float2(side==0 ? w.x+3:w.z-3,mix(w.y,w.w,t))
          : float2(mix(w.x,w.z,t),side==2 ? w.y+3:w.w-3);
        bool covered=false;
        for(uint k=0;k<i;k++)if(all(at>windows[k].xy)&&all(at<windows[k].zw)){covered=true;break;}
        if(covered || any(at<0) || any(at>geometry.xy))continue;
        float2 normal=side<2 ? float2(side==0 ? -1:1,0):float2(0,side==2 ? -1:1);
        float2 uv=float2(at.x,geometry.y-at.y)/geometry.xy;
        float2 outside=at+normal*10.0;
        float2 other=float2(outside.x,geometry.y-outside.y)/geometry.xy;
        float3 colour=desktop.sample(fogSample,rect.xy+uv*rect.zw).rgb;
        float3 backdrop=desktop.sample(fogSample,rect.xy+other*rect.zw).rgb;
        float boundary=smoothstep(0.012,0.10,length(colour-backdrop));
        sum+=colour*boundary;weight+=boundary;
      }
      float3 target=weight>0.01 ? fogEmitter(sum/weight,min(1.0,weight/2.0),0.32):float3(0);
      old=float4(mix(old.rgb,target,old.a>0.5 ? 0.25:0.5),1);
    }
    cache[slot]=old;
  }
  kernel void fogExtract(texture2d<float,access::sample> desktop [[texture(0)]],
    texture2d<float,access::sample> atmosphere [[texture(1)]],
    texture2d<half,access::write> output [[texture(2)]],texture2d<float,access::sample> wallpaper [[texture(3)]],constant float4 &rect [[buffer(0)]],
    constant float4 &geometry [[buffer(1)]],constant float4 *windows [[buffer(2)]],
    device const float4 *cache [[buffer(3)]],constant float4 *parameters [[buffer(4)]],
    constant float4 *excluded [[buffer(5)]],constant uint &exclusionCount [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width() || gid.y>=output.get_height())return;
    float2 uv=(float2(gid)+0.5)/float2(output.get_width(),output.get_height());
    float2 world=float2(uv.x,1-uv.y)*geometry.xy;
    float2 sourceUV=rect.xy+uv*rect.zw;
    float3 c=desktop.sample(fogSample,sourceUV).rgb;
    float3 emission=0;
    float objectEnergy=0;
    bool windowPixel=false;
    // A cached colour follows current geometry at presentation rate, regardless
    // of capture latency. The soft outer band bridges the native window shadow.
    for(int i=0;i<int(geometry.z);i++) {
      float4 w=windows[i];
      if(any(world<w.xy-28.0) || any(world>w.zw+28.0))continue;
      float3 edge=fogWindowEdge(world,w);
      if(edge.x>28.0)continue;
      int side=abs(edge.y)>abs(edge.z) ? (edge.y<0 ? 0:1):(edge.z<0 ? 2:3);
      float3 colour=cache[int(parameters[i].x)*4+side].rgb;
      float band=edge.x<0 ? 1-smoothstep(10.0,22.0,-edge.x):exp(-edge.x/11.0)*0.85;
      emission+=colour*band;
      if(edge.x<=0){windowPixel=true;break;}
    }
    bool capturedWindow=false;
    for(uint i=0;i<exclusionCount;i++)if(all(world>excluded[i].xy-3.0)&&all(world<excluded[i].zw+3.0)){capturedWindow=true;break;}
    if(!windowPixel && !capturedWindow) {
      // Local contrast finds Dock/desktop icon silhouettes without Accessibility
      // access or a CPU readback. No flat desktop-brightness threshold is used.
      float2 step=rect.zw*4.0/geometry.xy;
      float3 left=desktop.sample(fogSample,sourceUV-float2(step.x,0)).rgb;
      float3 right=desktop.sample(fogSample,sourceUV+float2(step.x,0)).rgb;
      float3 above=desktop.sample(fogSample,sourceUV-float2(0,step.y)).rgb;
      float3 below=desktop.sample(fogSample,sourceUV+float2(0,step.y)).rgb;
      float contrast=max(max(length(c-left),length(c-right)),max(length(c-above),length(c-below)));
      if(geometry.w>0.5) {
        float3 backdrop=wallpaper.sample(fogSample,uv).rgb;
        float object=smoothstep(0.045,0.22,length(c-backdrop));
        emission+=fogEmitter(c,object*0.95,0.28);
        objectEnergy=object*0.95;
      } else {
        objectEnergy=smoothstep(0.025,0.25,contrast)*0.70;
        emission+=fogEmitter(c,objectEnergy,0.16);
      }
    }
    // The existing effect colours can scatter too, but fog itself is a medium,
    // not an emitter. Its nearly neutral, broad haze contributes no extra light.
    float4 a=atmosphere.sample(fogSample,uv);
    float chroma=max(a.r,max(a.g,a.b))-min(a.r,min(a.g,a.b));
    emission+=a.rgb*a.rgb*smoothstep(0.05,0.25,chroma)*0.5;
    output.write(half4(float4(emission,objectEnergy)),gid);
  }
  kernel void fogBlur(texture2d<float,access::sample> source [[texture(0)]],
    texture2d<half,access::write> output [[texture(1)]],constant float2 &axis [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width() || gid.y>=output.get_height())return;
    float2 dimensions=float2(output.get_width(),output.get_height());
    float2 uv=(float2(gid)+0.5)/dimensions,step=axis/dimensions;
    // An exact 17-tap Gaussian in nine bilinear reads. Contiguous taps avoid
    // the hard bands produced by simply stretching a small blur kernel.
    float4 c=source.sample(fogSample,uv)*0.10315262;
    c+=(source.sample(fogSample,uv+step*1.47657965)+source.sample(fogSample,uv-step*1.47657965))*0.19101081;
    c+=(source.sample(fogSample,uv+step*3.44552954)+source.sample(fogSample,uv-step*3.44552954))*0.14042891;
    c+=(source.sample(fogSample,uv+step*5.41489885)+source.sample(fogSample,uv-step*5.41489885))*0.08071546;
    c+=(source.sample(fogSample,uv+step*7.38491214)+source.sample(fogSample,uv-step*7.38491214))*0.03626851;
    output.write(half4(c),gid);
  }
  struct FogBloomOut {float4 position [[position]];float2 uv;};
  vertex FogBloomOut fogBloomVertex(uint id [[vertex_id]]) {
    float2 p=float2((id<<1)&2,id&2);
    FogBloomOut out;out.position=float4(p*2-1,0,1);out.uv=float2(p.x,1-p.y);return out;
  }
  fragment float4 fogBloomFragment(FogBloomOut in [[stage_in]],
    texture2d<float> scene [[texture(0)]],texture2d<float> glow [[texture(1)]],
    constant float4 &info [[buffer(0)]],constant float4 *windows [[buffer(1)]],
    constant float &mode [[buffer(2)]]) {
    float4 original=mode>1.5 ? float4(0) : scene.sample(fogSample,in.uv);
    if(mode>0.5 && mode<1.5)return original;
    float2 world=float2(in.uv.x,1-in.uv.y)*info.xy;
    for(int i=0;i<int(info.w);i++) {
      float4 w=windows[i];
      if(any(world<w.xy) || any(world>w.zw))continue;
      if(fogWindowEdge(world,w).x<-0.5)return original;
    }
    // Fog is strongest near the desktop, but window tops are also light sources.
    float height=info.y*(0.62+info.z*0.20);
    float fog=mix(0.60,1.0,1-smoothstep(height*0.25,height,world.y));
    float4 field=glow.sample(fogSample,in.uv);
    float3 light=sqrt(max(float3(0),field.rgb));
    float energy=max(light.r,max(light.g,light.b));
    // Object halos are deliberately subtle. Both colour and object energy
    // are already blurred: never apply an inverse, per-pixel wallpaper mask
    // over Dock icons or widgets. WindowServer places the real objects in front.
    float objectShare=saturate(field.a/max(0.001,max(field.r,max(field.g,field.b))));
    float alpha=min(mix(0.48,0.12,objectShare),energy*mix(0.85,0.28,objectShare)*info.z*fog);
    float3 colour=light/max(0.001,energy);
    float4 bloom=float4(colour*alpha,alpha);
    return bloom+original*(1-bloom.a);
  }
  """
