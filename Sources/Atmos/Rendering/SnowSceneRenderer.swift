import MetalKit

/// Each overlapping season keeps its own simulation and frame storage; Metal pipelines are shared.
final class SnowSceneRenderer {
  let simulation: SnowSimulation
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let spritePipeline: MTLRenderPipelineState
  private let pilePipeline: MTLRenderPipelineState
  private let signPipeline: MTLRenderPipelineState
  private let pumpkinPipeline: MTLRenderPipelineState
  private var pumpkinPictures: (shell: MTLTexture, face: MTLTexture)?
  private var signPictures: [Int: (texture: MTLTexture, size: SIMD2<Float>)] = [:]
  private let framesInFlight = 2
  private var spriteBuffers: [MTLBuffer] = []
  private var heightBuffers: [MTLBuffer] = []
  private var spriteCapacity = 0
  private var heightCapacity = 0
  private var slot = 0
  private var frameIndex = 0
  private var groundPiles: [PileLayer] = []
  private var frameUniforms = Uniforms(viewSize: .zero, scale: 1, time: 0, columnWidth: 1)
  var groundTop: Float { groundPiles.map { $0.origin.y + $0.top + 2 }.max() ?? 0 }

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
      signPipeline = previous.signPipeline
      pumpkinPipeline = previous.pumpkinPipeline
      pumpkinPictures = previous.pumpkinPictures
      signPictures = previous.signPictures
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
      signPipeline = try pipeline("signVertex", "signFragment")
      pumpkinPipeline = try pipeline("pumpkinVertex", "pumpkinFragment")
    }
  }

  func encode(
    with encoder: MTLRenderCommandEncoder,
    ambient: (light: SIMD3<Float>, shadowTint: SIMD4<Float>, rim: SIMD4<Float>, lantern: Float),
    lanternAt: SIMD2<Float>, scale: Float, time: Float
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
      lantern: SIMD4(lowHalf: lanternAt, highHalf: SIMD2(130, ambient.lantern)),
      shake: SIMD4(lowHalf: simulation.shake, highHalf: .zero)
    )
    uniforms.autumn = simulation.autumn ? 1 : 0
    let pumpkins = simulation.pumpkins
    let candles = pumpkins.prefix(3).map { pumpkin in
      let height = pumpkin.width * HalloweenPumpkin.aspect
      let flame =
        pumpkin.anchor + (HalloweenPumpkin.candle - SIMD2(0.5, 0)) * SIMD2(pumpkin.width, height)
      return SIMD4(
        lowHalf: flame, highHalf: SIMD2(pumpkin.width * 1.6, 0.4 + 0.6 * ambient.lantern))
    }
    if candles.count > 0 { uniforms.pumpkins.0 = candles[0] }
    if candles.count > 1 { uniforms.pumpkins.1 = candles[1] }
    if candles.count > 2 { uniforms.pumpkins.2 = candles[2] }
    frameUniforms = uniforms
    groundPiles = piles.filter(\.isDock)
    frameIndex = index
    let uniformsLength = MemoryLayout<Uniforms>.stride

    drawPumpkins(pumpkins, with: encoder, uniforms: uniforms)
    drawPiles(piles.filter { !$0.isDock }, with: encoder, uniforms: uniforms, heights: heightBuffer)
    drawSigns(simulation.signs, with: encoder, uniforms: uniforms)
    if sprites > 0 {
      encoder.setRenderPipelineState(spritePipeline)
      encoder.setVertexBuffer(spriteBuffer, offset: 0, index: 0)
      encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 1)
      encoder.setFragmentBytes(&uniforms, length: uniformsLength, index: 1)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: sprites)
    }

  }

  func encodeGround(with encoder: MTLRenderCommandEncoder, height: Float, scale: Float) {
    guard !groundPiles.isEmpty, heightBuffers.count == 2 else { return }
    var u = frameUniforms
    u.viewSize.y = height
    u.scale = scale
    drawPiles(groundPiles, with: encoder, uniforms: u, heights: heightBuffers[frameIndex])
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

  private func drawSigns(
    _ signs: [SignSprite], with encoder: MTLRenderCommandEncoder, uniforms: Uniforms
  ) {
    guard !signs.isEmpty else { return }
    var uniforms = uniforms
    encoder.setRenderPipelineState(signPipeline)
    for sign in signs {
      guard let picture = signPicture(sign.caption) else { continue }
      var shape = SignUniforms(
        anchor: sign.anchor, size: picture.size, angle: sign.angle, ground: sign.ground)
      encoder.setVertexBytes(&shape, length: MemoryLayout<SignUniforms>.stride, index: 0)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.setFragmentBytes(&shape, length: MemoryLayout<SignUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.setFragmentTexture(picture.texture, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
  }

  /// The pumpkins go down before the snow, so the drift they sit in covers their bottoms.
  private func drawPumpkins(
    _ pumpkins: [PumpkinSprite], with encoder: MTLRenderCommandEncoder, uniforms: Uniforms
  ) {
    guard !pumpkins.isEmpty, let pictures = pumpkinPictures ?? makePumpkinPictures() else { return }
    var uniforms = uniforms
    encoder.setRenderPipelineState(pumpkinPipeline)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentTexture(pictures.shell, index: 0)
    encoder.setFragmentTexture(pictures.face, index: 1)
    for pumpkin in pumpkins {
      var shape = PumpkinUniforms(anchor: pumpkin.anchor, width: pumpkin.width, seed: pumpkin.seed)
      encoder.setVertexBytes(&shape, length: MemoryLayout<PumpkinUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&shape, length: MemoryLayout<PumpkinUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
  }

  /// Drawn large and mipmapped: the pumpkins are shown at a fraction of that, and smaller ones would shimmer.
  private func makePumpkinPictures() -> (shell: MTLTexture, face: MTLTexture)? {
    func texture(_ part: HalloweenPumpkin.Part) -> MTLTexture? {
      guard let context = HalloweenPumpkin.draw(part, scale: 2), let data = context.data else {
        return nil
      }
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: context.width, height: context.height, mipmapped: true)
      descriptor.usage = .shaderRead
      guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
      texture.replace(
        region: MTLRegionMake2D(0, 0, context.width, context.height), mipmapLevel: 0,
        withBytes: data, bytesPerRow: context.bytesPerRow)
      return texture
    }
    guard let shell = texture(.shell), let face = texture(.face),
      let commandBuffer = queue.makeCommandBuffer(),
      let blit = commandBuffer.makeBlitCommandEncoder()
    else { return nil }
    blit.generateMipmaps(for: shell)
    blit.generateMipmaps(for: face)
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    pumpkinPictures = (shell, face)
    return pumpkinPictures
  }

  private func signPicture(_ caption: Int) -> (texture: MTLTexture, size: SIMD2<Float>)? {
    if let picture = signPictures[caption] { return picture }
    guard let context = HalloweenSign.draw(HalloweenSign.captions[caption]), let data = context.data
    else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: context.width, height: context.height, mipmapped: false)
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    texture.replace(
      region: MTLRegionMake2D(0, 0, context.width, context.height), mipmapLevel: 0, withBytes: data,
      bytesPerRow: context.bytesPerRow)
    let picture = (
      texture: texture,
      size: SIMD2(Float(context.width), Float(context.height)) / Float(HalloweenSign.scale)
    )
    signPictures[caption] = picture
    return picture
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
