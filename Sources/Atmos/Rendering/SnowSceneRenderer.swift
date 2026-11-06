import MetalKit

/// Each overlapping season keeps its own simulation and frame storage; Metal pipelines are shared.
final class SnowSceneRenderer {
  let simulation: SnowSimulation
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let spritePipeline: MTLRenderPipelineState
  private let pilePipeline: MTLRenderPipelineState
  private let framesInFlight = 2
  private var spriteBuffers: [MTLBuffer] = []
  private var heightBuffers: [MTLBuffer] = []
  private var spriteCapacity = 0
  private var heightCapacity = 0
  private var slot = 0
  private var frameIndex = 0
  private var groundPiles: [PileLayer] = []
  private var frameUniforms = Uniforms(viewSize: .zero, scale: 1, time: 0, columnWidth: 1)
  var groundTop: Float {
    max(simulation.surfaceDrift.groundTop, groundPiles.map { $0.origin.y + $0.top + 2 }.max() ?? 0)
  }

  init(
    device: MTLDevice, queue: MTLCommandQueue, format: MTLPixelFormat, simulation: SnowSimulation,
    reusing: SnowSceneRenderer? = nil
  ) throws {
    self.device = device
    self.queue = queue
    self.simulation = simulation
    if let previous = reusing {
      spritePipeline = previous.spritePipeline
      pilePipeline = previous.pilePipeline
    } else {
      let library = try device.makeLibrary(source: shaderSource, options: nil)

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

      spritePipeline = try pipeline("spriteVertex", "spriteFragment")
      pilePipeline = try pipeline("pileVertex", "pileFragment")
    }
  }

  func encode(
    with encoder: MTLRenderCommandEncoder,
    ambient: (light: SIMD3<Float>, shadowTint: SIMD4<Float>, rim: SIMD4<Float>),
    scale: Float, time: Float, includeGround: Bool = true
  ) {
    reserve(sprites: simulation.spriteCount, columns: simulation.columnCount)
    guard spriteBuffers.count == framesInFlight, heightBuffers.count == framesInFlight else {
      return
    }

    let index = slot % framesInFlight
    slot += 1
    let spriteBuffer = spriteBuffers[index]
    let heightBuffer = heightBuffers[index]
    let sprites = simulation.writeSprites(
      into: spriteBuffer.contents().bindMemory(to: Sprite.self, capacity: spriteCapacity),
      capacity: spriteCapacity
    )
    let piles = simulation.writeLayers(
      into: heightBuffer.contents().bindMemory(to: Float.self, capacity: heightCapacity),
      capacity: heightCapacity
    )

    var uniforms = Uniforms(
      viewSize: SIMD2(simulation.width, simulation.height),
      scale: scale,
      time: time,
      columnWidth: simulation.columnWidth,
      light: SIMD4(ambient.light, 1),
      shadowTint: ambient.shadowTint,
      rim: ambient.rim,
      shake: .zero
    )
    uniforms.autumn = simulation.autumn ? simulation.botanicalStyle : 0
    frameUniforms = uniforms
    groundPiles = piles.filter(\.isDock)
    frameIndex = index
    let uniformsLength = MemoryLayout<Uniforms>.stride

    drawPiles(piles.filter { !$0.isDock }, with: encoder, uniforms: uniforms, heights: heightBuffer)
    let start = includeGround ? 0 : simulation.surfaceDrift.groundCount
    if sprites > start {
      encoder.setRenderPipelineState(spritePipeline)
      encoder.setVertexBuffer(spriteBuffer, offset: 0, index: 0)
      encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 1)
      encoder.setFragmentBytes(&uniforms, length: uniformsLength, index: 1)
      encoder.drawPrimitives(type: .point, vertexStart: start, vertexCount: sprites - start)
    }

  }

  func encodeGround(with encoder: MTLRenderCommandEncoder, height: Float, scale: Float) {
    guard heightBuffers.count == 2, spriteBuffers.count == 2 else { return }
    var u = frameUniforms
    u.viewSize.y = height
    u.scale = scale
    drawPiles(groundPiles, with: encoder, uniforms: u, heights: heightBuffers[frameIndex])
    if simulation.surfaceDrift.groundCount > 0 {
      encoder.setRenderPipelineState(spritePipeline)
      encoder.setVertexBuffer(spriteBuffers[frameIndex], offset: 0, index: 0)
      encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.drawPrimitives(
        type: .point, vertexStart: 0, vertexCount: simulation.surfaceDrift.groundCount)
    }
  }

  func releaseBuffers() {
    spriteBuffers.removeAll()
    heightBuffers.removeAll()
    groundPiles.removeAll()
    spriteCapacity = 0
    heightCapacity = 0
  }

  private func drawPiles(
    _ piles: [PileLayer], with encoder: MTLRenderCommandEncoder, uniforms: Uniforms,
    heights: MTLBuffer
  ) {
    guard !piles.isEmpty else { return }
    var uniforms = uniforms
    let uniformsLength = MemoryLayout<Uniforms>.stride
    encoder.setRenderPipelineState(pilePipeline)
    for pile in piles {
      uniforms.columnCount = Int32(pile.count)
      uniforms.pileTop = pile.top + 2
      uniforms.pileBottom = pile.bottom
      uniforms.origin = pile.origin
      uniforms.shake.z = pile.drift
      uniforms.occluderCount = Int32(pile.occluders.count)
      var occluders = pile.occluders.isEmpty ? [SIMD4<Float>(repeating: 0)] : pile.occluders
      encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 0)
      encoder.setFragmentBuffer(heights, offset: pile.offset * MemoryLayout<Float>.stride, index: 0)
      encoder.setFragmentBytes(&uniforms, length: uniformsLength, index: 1)
      encoder.setFragmentBytes(
        &occluders, length: occluders.count * MemoryLayout<SIMD4<Float>>.stride, index: 2)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
  }

  private func reserve(sprites: Int, columns: Int) {
    if sprites > spriteCapacity || spriteBuffers.isEmpty {
      spriteCapacity = max(1024, sprites * 3 / 2)
      spriteBuffers = makeBuffers(length: spriteCapacity * MemoryLayout<Sprite>.stride)
    }
    if columns > heightCapacity || heightBuffers.isEmpty {
      heightCapacity = max(256, columns)
      heightBuffers = makeBuffers(length: heightCapacity * MemoryLayout<Float>.stride)
    }
  }

  private func makeBuffers(length: Int) -> [MTLBuffer] {
    (0..<framesInFlight).compactMap { _ in
      device.makeBuffer(length: length, options: [.storageModeShared, .cpuCacheModeWriteCombined])
    }
  }
}
