import MetalKit
import CWeatherCore

struct WeatherUniforms {
  var viewSize: SIMD2<Float>
  var time: Float
  var opacity: Float
  var light: SIMD4<Float>
  var surface = SIMD4<Float>.zero
  var details = SIMD4<Float>.zero
  var cursor = SIMD4<Float>(-10_000, -10_000, 0, 0)
  var screen = SIMD4<Float>.zero
  var atmosphere = SIMD4<Float>.zero
  var pointer = SIMD4<Float>.zero
  var reflectionRect = SIMD4<Float>(0, 0, 1, 1)
  var viewport = SIMD4<Float>.zero
  var climate = SIMD4<Float>.zero
}

final class WeatherRenderer {
  let simulation: WeatherSimulation
  private let device: MTLDevice
  private let particles: MTLRenderPipelineState
  private let water: MTLRenderPipelineState
  private let fallback: MTLTexture
  private var smokeFrames: [MTLBuffer] = []
  private var gpuSmoke: GPUSmoke?
  private var smokePipelines: GPUSmoke.Pipelines?
  private var gpuSmokeUnavailable = false
  private var pointerTexture: MTLTexture?
  private var pointerInfo = SIMD4<Float>.zero
  private var pointerPixels: Data?
  private var pointerAt: Double = -1
  private var frames: [MTLBuffer] = []
  private var heightFrames: [MTLBuffer] = []
  private var liquidFrames: [MTLBuffer] = []
  private var liquidNeighbourCache:MTLBuffer?
  private let liquidPipelines: GPULiquidField.Pipelines?
  private var gpuLiquidField: GPULiquidField?
  var usesGPULiquidField = true
  private var capacity = 0
  private var heightCapacity = 0
  private var slot = 0
  private var frameIndex = 0
  private var atmosphereIndex = 0
  private var pools: [(surface: WaterSurface, offset: Int)] = []
  private var uniforms = WeatherUniforms(
    viewSize: .zero, time: 0, opacity: 1, light: SIMD4(repeating: 1))
  var contentTop: Float = .greatestFiniteMagnitude
  var reflectionRect = SIMD4<Float>(0, 0, 1, 1)
  var reflection: MTLTexture?
  var windowOccluders: [SIMD4<Float>] = []
  private var startedAt: Double = 0

  init(
    device: MTLDevice, format: MTLPixelFormat, size: SIMD2<Float>, reusing: WeatherRenderer? = nil,
    shaderSource: String = weatherShaderSource, seed: UInt64 = UInt64.random(in: 1...UInt64.max)
  ) throws {
    self.device = device
    simulation = WeatherSimulation(size: size, seed: seed)
    if let reusing {
      windowOccluders = reusing.windowOccluders
      particles = reusing.particles
      water = reusing.water
      fallback = reusing.fallback
      smokePipelines = reusing.smokePipelines
      liquidPipelines = reusing.liquidPipelines
      return
    }
    let library = try device.makeLibrary(source: shaderSource + "\n" + liquidFieldShaderSource, options: nil)
    liquidPipelines = try? GPULiquidField.Pipelines(device: device, library: library)
    func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: vertex)
      descriptor.fragmentFunction = library.makeFunction(name: fragment)
      let attachment = descriptor.colorAttachments[0]!
      attachment.pixelFormat = format
      attachment.isBlendingEnabled = true
      attachment.sourceRGBBlendFactor = .one
      attachment.sourceAlphaBlendFactor = .one
      attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      return try device.makeRenderPipelineState(descriptor: descriptor)
    }
    particles = try pipeline("weatherVertex", "weatherFragment")
    water = try pipeline("waterVertex", "waterFragment")
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 2, height: 64, mipmapped: false)
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw RendererError.unavailable
    }
    var pixels: [UInt8] = []
    for y in 0..<64 {
      let t = Float(y) / 63
      for _ in 0..<2 {
        pixels += [UInt8(55 + 80 * t), UInt8(77 + 83 * t), UInt8(105 + 85 * t), 255]
      }
    }
    texture.replace(
      region: MTLRegionMake2D(0, 0, 2, 64), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 8)
    fallback = texture

  }

  func setEffect(_ effect: WeatherEffect) {
    simulation.setEffect(effect)
    startedAt = simulation.elapsed
  }

  /// One upload for both overlays. All buffers are reused and protected by the parent renderer's semaphore.
  func encode(
    with encoder: MTLRenderCommandEncoder, light: SIMD3<Float>, includeGround: Bool = true
  ) {
    prepare(light: light)
    encodeWater(with: encoder, includeGround: includeGround)
    encodeAtmosphere(with: encoder, includeGround: includeGround)
  }

  func prepare(light: SIMD3<Float>, atmosphere: Bool = true, command: MTLCommandBuffer? = nil) {
    if let smoke = simulation.smoke, let command, !gpuSmokeUnavailable {
      if gpuSmoke?.source !== smoke {
        do {
          let next = try GPUSmoke(device: device, source: smoke, reusing: smokePipelines)
          gpuSmoke = next
          smokePipelines = next.pipelines
        } catch {
          gpuSmokeUnavailable = true
          NSLog("Atmos: GPU smoke unavailable: \(error)")
        }
      }
      gpuSmoke?.encode(into: command)
    } else if simulation.smoke == nil {
      gpuSmoke = nil
    }
    var bytes = 0
    pools.removeAll(keepingCapacity: true)
    if simulation.effect.hasWater && simulation.ownsWater {
      for pool in simulation.water where pool.top > 0.025 && !pool.isOccluded {
        pools.append((pool, bytes))
        bytes = (bytes + pool.heights.count * 4 + 255) & ~255
      }
    }
    let count = simulation.particleCount + simulation.decorations.count
    guard reserve(sprites: count, heightBytes: bytes) else { return }
    frameIndex = slot % 2
    slot += 1
    let buffer = frames[frameIndex]
    let uploadAtmosphere =
      atmosphere || simulation.decorations.contains { $0.motion.w == 7 && $0.life.z == 0 }
    if uploadAtmosphere {
      atmosphereIndex = frameIndex
      if simulation.particleCount > 0 {
        simulation.particles.withUnsafeBufferPointer { source in
          buffer.contents().copyMemory(
            from: source.baseAddress!,
            byteCount: source.count * MemoryLayout<WeatherParticle>.stride)
        }
      }
      if !simulation.decorations.isEmpty {
        simulation.decorations.withUnsafeBufferPointer { source in
          buffer.contents().advanced(
            by: simulation.particleCount * MemoryLayout<WeatherParticle>.stride
          )
          .copyMemory(
            from: source.baseAddress!,
            byteCount: source.count * MemoryLayout<WeatherParticle>.stride)
        }
      }
    }
    if simulation.effect.hasWater && simulation.particles.contains(where: { $0.motion.w == 9 }) {
      let gpuEncoded = usesGPULiquidField && uploadAtmosphere && command.map {
        gpuLiquidField?.encode(particles: buffer, count: simulation.particleCount,
          output: liquidFrames[frameIndex], command: $0) ?? false
      } == true
      if !gpuEncoded {
        if liquidNeighbourCache == nil {
          liquidNeighbourCache = device.makeBuffer(length: 4096*9*16, options: .storageModeShared)
        }
        simulation.particles.withUnsafeBufferPointer { source in
          sh_liquid_field(source.baseAddress,source.count,
            liquidFrames[frameIndex].contents().bindMemory(to:SIMD4<Float>.self,capacity:capacity*8),
            liquidNeighbourCache?.contents().bindMemory(to:SIMD4<Float>.self,capacity:4096*9))
        }
      }
    }
    for (pool, offset) in pools {
      pool.heights.withUnsafeBufferPointer { source in
        heightFrames[frameIndex].contents().advanced(by: offset).copyMemory(
          from: source.baseAddress!, byteCount: source.count * 4)
      }
    }
    uniforms = WeatherUniforms(
      viewSize: simulation.size, time: simulation.time,
      opacity: Float(min(1, max(0, (simulation.elapsed - startedAt) / 0.6))), light: SIMD4(light, 1)
    )
    uniforms.cursor = simulation.interaction
    uniforms.screen = SIMD4(
      simulation.size.x, simulation.size.y, min(contentTop, simulation.size.y), 0)
    if let smoke = simulation.smoke {
      let length = smoke.cells.count * MemoryLayout<SIMD4<Float>>.stride
      if gpuSmoke?.source !== smoke, smokeFrames.first?.length != length {
        smokeFrames = (0..<2).compactMap { _ in
          device.makeBuffer(length: length, options: .storageModeShared)
        }
      }
      if gpuSmoke?.source === smoke {
        uniforms.atmosphere = SIMD4(
          Float(smoke.columns), Float(smoke.rows), smoke.spacing, simulation.flash)
      } else if smokeFrames.count == 2 && uploadAtmosphere {
        smoke.cells.withUnsafeBytes {
          smokeFrames[frameIndex].contents().copyMemory(from: $0.baseAddress!, byteCount: length)
        }
        uniforms.atmosphere = SIMD4(
          Float(smoke.columns), Float(smoke.rows), smoke.spacing, simulation.flash)
      }
    }
    uniforms.reflectionRect = reflectionRect
    if simulation.effect.hasWater && !pools.isEmpty {
      updatePointer()
      uniforms.pointer = pointerInfo
    }

  }

  func encodeWater(
    with encoder: MTLRenderCommandEncoder, includeGround: Bool, viewport: CGRect? = nil
  ) {
    guard frames.count == 2 else { return }
    var u = uniforms
    if let viewport {
      u.viewSize = SIMD2(Float(viewport.width), Float(viewport.height))
      u.viewport = SIMD4(Float(viewport.minX), Float(viewport.minY), 0, 0)
    }
    for (pool, offset) in pools where includeGround || !pool.belowDock {
      drawPool(pool, offset: offset, encoder: encoder, uniforms: u)
    }
  }

  func encodeAtmosphere(with encoder: MTLRenderCommandEncoder, includeGround: Bool) {
    guard frames.count == 2 else { return }
    bindSmoke(encoder)
    // Beams and banks sit behind the particles. Window banks carry their foreground occlusion masks.
    drawDecorations(encoder: encoder, uniforms: uniforms, ground: includeGround ? nil : false)
    drawSprites(encoder: encoder, uniforms: uniforms, start: 0, count: simulation.particleCount)
  }

  private func bindSmoke(_ encoder: MTLRenderCommandEncoder) {
    if windowOccluders.isEmpty {
      var empty = SIMD4<Float>.zero
      encoder.setFragmentBytes(&empty, length: 16, index: 5)
    } else {
      windowOccluders.withUnsafeBytes {
        encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 5)
      }
    }
    if let gpuSmoke {
      encoder.setFragmentBuffer(gpuSmoke.cells, offset: 0, index: 4)
    } else if smokeFrames.count == 2 {
      encoder.setFragmentBuffer(smokeFrames[atmosphereIndex], offset: 0, index: 4)
    } else {
      var dummy = SIMD4<Float>(0, 0, 1, 0)
      encoder.setFragmentBytes(&dummy, length: 16, index: 4)
    }
  }

  func encodeGround(with encoder: MTLRenderCommandEncoder, height: Float) {
    guard frames.count == 2 else { return }
    var u = uniforms
    u.viewSize.y = height
    bindSmoke(encoder)
    for (pool, offset) in pools where pool.belowDock {
      drawPool(pool, offset: offset, encoder: encoder, uniforms: u)
    }
    drawDecorations(encoder: encoder, uniforms: u, ground: true)
  }

  private func drawPool(
    _ pool: WaterSurface, offset: Int, encoder: MTLRenderCommandEncoder, uniforms: WeatherUniforms
  ) {
    var u = uniforms
    u.surface = SIMD4(pool.origin.x, pool.origin.y, pool.width, pool.top + 2)
    u.climate = SIMD4(pool.foam,pool.foamCenter,pool.foamRadius,0)
    let relevant = simulation.ripples.filter { abs($0.point.y - pool.origin.y) < 4 }
    u.details = SIMD4(
      Float(pool.heights.count), Float(relevant.count), Float(min(128, pool.blockers.count)),
      reflection == nil ? 0 : 1)
    var rippleData = relevant.isEmpty ? [WaterRipple(point: .zero, age: 10, strength: 0)] : relevant
    var blockers = pool.blockers.isEmpty ? [SIMD4<Float>.zero] : Array(pool.blockers.prefix(128))
    encoder.setRenderPipelineState(water)
    encoder.setVertexBytes(&u, length: MemoryLayout<WeatherUniforms>.stride, index: 1)
    encoder.setFragmentBytes(&u, length: MemoryLayout<WeatherUniforms>.stride, index: 1)
    encoder.setFragmentBuffer(heightFrames[frameIndex], offset: offset, index: 0)
    encoder.setFragmentBytes(
      &rippleData, length: rippleData.count * MemoryLayout<WaterRipple>.stride, index: 2)
    encoder.setFragmentBytes(
      &blockers, length: blockers.count * MemoryLayout<SIMD4<Float>>.stride, index: 3)
    encoder.setFragmentTexture(reflection ?? fallback, index: 0)
    encoder.setFragmentTexture(pointerTexture ?? fallback, index: 1)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
  }

  private func drawDecorations(
    encoder: MTLRenderCommandEncoder, uniforms: WeatherUniforms, ground: Bool?
  ) {
    for (i, sprite) in simulation.decorations.enumerated() {
      let isGround = sprite.motion.w == 7 && sprite.life.z == 0
      if let ground, ground != isGround { continue }
      var u = uniforms
      var blockers = [SIMD4<Float>.zero]
      if sprite.motion.w == 7,
        let bank = simulation.banks.first(where: { Float($0.id) == sprite.life.z })
      {
        u.details.z = Float(min(128, bank.blockers.count))
        if !bank.blockers.isEmpty { blockers = Array(bank.blockers.prefix(128)) }
      } else {
        u.details.z = 0
      }
      encoder.setFragmentBytes(
        &blockers, length: blockers.count * MemoryLayout<SIMD4<Float>>.stride, index: 3)
      drawSprites(
        encoder: encoder, uniforms: u, start: simulation.particleCount + i, count: 1,
        clearBlockers: false)
    }
  }

  private func drawSprites(
    encoder: MTLRenderCommandEncoder, uniforms: WeatherUniforms, start: Int, count: Int,
    clearBlockers: Bool = true
  ) {
    guard count > 0 else { return }
    var u = uniforms
    u.screen.w = Float(windowOccluders.count)
    if let dynamics = simulation.dynamics {
      u.climate = SIMD4(dynamics.cloudCover, dynamics.haze, simulation.wind, 1)
    }
    encoder.setFragmentTexture(reflection ?? fallback, index: 0)
    encoder.setRenderPipelineState(particles)
    encoder.setVertexBuffer(frames[atmosphereIndex], offset: 0, index: 0)
    encoder.setFragmentBuffer(liquidFrames[atmosphereIndex],offset:0,index:6)
    encoder.setVertexBytes(&u, length: MemoryLayout<WeatherUniforms>.stride, index: 1)
    encoder.setFragmentBytes(&u, length: MemoryLayout<WeatherUniforms>.stride, index: 1)
    if clearBlockers {
      var dummy = SIMD4<Float>.zero
      encoder.setFragmentBytes(&dummy, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
    }
    encoder.drawPrimitives(
      type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count,
      baseInstance: start)
  }

  func releaseBuffers() {
    smokeFrames.removeAll()
    pointerTexture = nil
    pointerPixels = nil
    frames.removeAll()
    heightFrames.removeAll()
    liquidFrames.removeAll()
    liquidNeighbourCache=nil
    gpuLiquidField=nil
    pools.removeAll()
    capacity = 0
    heightCapacity = 0
  }

  private func updatePointer() {
    // System cursor/image queries can block the render thread. Reuse the cached
    // reflection while interacting; refresh its appearance when movement settles.
    guard pointerTexture == nil || simulation.interaction.z<0.15 else {return}
    guard simulation.elapsed - pointerAt > 0.2 else { return }
    pointerAt = simulation.elapsed
    let cursor = NSCursor.currentSystem ?? .arrow
    var rect = CGRect(origin: .zero, size: cursor.image.size)
    guard let image = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
      return
    }
    let info = SIMD4(
      Float(cursor.image.size.width), Float(cursor.image.size.height), Float(cursor.hotSpot.x),
      Float(cursor.hotSpot.y))
    guard let pixels = image.dataProvider?.data as Data?,
      pointerTexture == nil || pixels != pointerPixels || info != pointerInfo
    else { return }
    pointerPixels = pixels
    #if DEBUG
      if DebugMetrics.enabled { DebugMetrics.pointerUploads += 1 }
    #endif
    pointerTexture = try? MTKTextureLoader(device: device).newTexture(
      cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
    pointerInfo = SIMD4(
      Float(cursor.image.size.width), Float(cursor.image.size.height), Float(cursor.hotSpot.x),
      Float(cursor.hotSpot.y))
  }

  private func reserve(sprites: Int, heightBytes: Int) -> Bool {
    if simulation.effect.hasWater && gpuLiquidField == nil, let liquidPipelines {
      gpuLiquidField = try? GPULiquidField(device: device, pipelines: liquidPipelines)
    }
    if frames.isEmpty || sprites > capacity {
      capacity = max(simulation.effect.hasWater ? 8320 : 256, sprites * 3 / 2)
      liquidFrames = (0..<2).compactMap { _ in
        guard let buffer=device.makeBuffer(length:capacity*8*16,options:.storageModeShared) else {return nil}
        buffer.contents().initializeMemory(as:UInt8.self,repeating:0,count:buffer.length)
        return buffer
      }
      frames = (0..<2).compactMap { _ in
        device.makeBuffer(
          length: capacity * MemoryLayout<WeatherParticle>.stride, options: .storageModeShared)
      }
    }
    if heightFrames.isEmpty || heightBytes > heightCapacity {
      heightCapacity = max(1024, heightBytes * 3 / 2)
      heightFrames = (0..<2).compactMap { _ in
        device.makeBuffer(length: heightCapacity, options: .storageModeShared)
      }
    }
    return frames.count == 2 && heightFrames.count == 2 && liquidFrames.count == 2
  }
}
