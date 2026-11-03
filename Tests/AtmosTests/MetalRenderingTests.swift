import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest

@testable import Atmos

final class MetalRenderingTests: XCTestCase {
  func testAllWeatherPipelinesRenderVisiblePixels() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    for effect in WeatherEffect.allCases where !effect.usesSnowSimulation {
      let renderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(960, 600))
      renderer.setEffect(effect)
      let surface = WindowSurface(
        id: 42, frame: CGRect(x: 130, y: 120, width: 560, height: 280),
        blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
      renderer.simulation.updateWindows([surface])
      renderer.simulation.wind = 36
      for _ in 0..<900 { renderer.simulation.step(dt: 1.0 / 60, cursor: SIMD2(-100, -100)) }
      let target = try texture(device, width: 960, height: 600)
      try render(renderer, target: target, queue: queue)
      let pixels = bytes(target)
      let visible = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
      XCTAssertGreaterThan(visible, 15, "\(effect.title) should be visible")
      for (name, level) in [("dark", 0.025), ("light", 0.96)] {
        try render(
          renderer, target: target, queue: queue,
          background: MTLClearColorMake(level, level, level, 1))
        let result = bytes(target)
        let background = Int((level * 255).rounded())
        var contrasted = 0
        for i in stride(from: 0, to: result.count, by: 4) {
          let difference = max(
            abs(Int(result[i]) - background), abs(Int(result[i + 1]) - background),
            abs(Int(result[i + 2]) - background))
          if difference >= 8 { contrasted += 1 }
        }
        XCTAssertGreaterThan(
          contrasted, effect == .fireflies ? 100 : 200,
          "\(effect.title) must remain visible on a \(name) wallpaper")
        if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
          try export(
            result, width: 960, height: 600, path: "\(output)/\(effect.rawValue)-\(name).png")
        }
      }
    }
  }

  func testBackgroundCloudWispsHideBehindWindowsWhileForegroundWispsRemainVisible() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    var selected: WeatherRenderer?
    for seed in UInt64(1)...100 {
      let candidate = try WeatherRenderer(
        device: device, format: .rgba8Unorm, size: SIMD2(960, 600), seed: seed)
      candidate.setEffect(.clouds)
      candidate.simulation.accumulates = false
      candidate.simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
      let lower = candidate.simulation.particles.filter {
        $0.motion.w == 2 && $0.rect.y > 100 && $0.rect.y < 400
      }
      if lower.contains(where: { $0.life.z == 1 }) && lower.contains(where: { $0.life.z == 0 }) {
        selected = candidate
        break
      }
    }
    let renderer = try XCTUnwrap(selected)
    for _ in 0..<120 { renderer.simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000)) }
    let target = try texture(device, width: 960, height: 600)
    try render(renderer, target: target, queue: queue)
    let full = bytes(target)
    renderer.windowOccluders = [SIMD4(0, 0, 960, 600)]
    try render(renderer, target: target, queue: queue)
    let clipped = bytes(target)
    var fullAlpha = 0
    var clippedAlpha = 0
    for y in 100..<400 {
      for x in 0..<960 {
        let i = ((600 - y - 1) * 960 + x) * 4 + 3
        fullAlpha += Int(full[i])
        clippedAlpha += Int(clipped[i])
      }
    }
    XCTAssertGreaterThan(
      fullAlpha, clippedAlpha + 100, "Background wisps disappear beneath application content")
    XCTAssertGreaterThan(clippedAlpha, 100, "Occasional foreground wisps remain visible")
  }

  func testOptimizedWeatherMatchesOriginalImages() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    for effect in WeatherEffect.allCases where !effect.usesSnowSimulation {
      let optimized = try WeatherRenderer(
        device: device, format: .rgba8Unorm, size: SIMD2(960, 600), seed: 8173)
      let reference = try WeatherRenderer(
        device: device, format: .rgba8Unorm, size: SIMD2(960, 600),
        shaderSource: referenceWeatherShaderSource, seed: 8173)
      for renderer in [optimized, reference] {
        renderer.setEffect(effect)
        renderer.simulation.intensity = .heavy
        renderer.simulation.wind = 36
        renderer.simulation.updateWindows([
          WindowSurface(
            id: 42, frame: CGRect(x: 130, y: 120, width: 560, height: 280), blockers: [],
            cornerRadius: 18, cornerExponent: 2.5, isDock: false)
        ])
        for _ in 0..<300 { renderer.simulation.step(dt: 1 / 30, cursor: SIMD2(-1000, -1000)) }
      }
      for level in [0.025, 0.96] {
        let a = try texture(device, width: 960, height: 600)
        let b = try texture(device, width: 960, height: 600)
        try render(
          optimized, target: a, queue: queue, background: MTLClearColorMake(level, level, level, 1))
        try render(
          reference, target: b, queue: queue, background: MTLClearColorMake(level, level, level, 1))
        let differences = zip(bytes(a), bytes(b)).map { abs(Int($0) - Int($1)) }
        XCTAssertLessThanOrEqual(
          differences.max() ?? 0, 1, "\(effect.title): shader optimization must preserve the image")
      }
    }
  }

  func testGPUResidentSmokePreservesTheRenderedScenes() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    for effect in [WeatherEffect.mist, .clouds, .storm, .lightning] {
      let cpu = try WeatherRenderer(
        device: device, format: .rgba8Unorm, size: SIMD2(960, 600), seed: 77181)
      let gpu = try WeatherRenderer(
        device: device, format: .rgba8Unorm, size: SIMD2(960, 600), seed: 77181)
      for renderer in [cpu, gpu] {
        renderer.setEffect(effect)
        renderer.simulation.intensity = .heavy
        renderer.simulation.wind = 28
        renderer.simulation.updateWindows([
          WindowSurface(
            id: 41, frame: CGRect(x: 180, y: 120, width: 580, height: 260), blockers: [],
            cornerRadius: 18, cornerExponent: 2.5, isDock: false)
        ])
      }
      for frame in 0..<240 {
        let time = Float(frame) / 30
        let point = SIMD2<Float>(720 + cos(time) * 100, 130 + sin(time * 1.7) * 70)
        cpu.simulation.step(dt: 1 / 30, cursor: point)
        gpu.simulation.step(dt: 1 / 30, cursor: point)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        gpu.prepare(light: SIMD3(repeating: 1), command: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
      }
      for background in [0.025, 0.96] {
        let a = try texture(device, width: 960, height: 600)
        let b = try texture(device, width: 960, height: 600)
        try render(
          cpu, target: a, queue: queue,
          background: MTLClearColorMake(background, background, background, 1))
        try render(
          gpu, target: b, queue: queue,
          background: MTLClearColorMake(background, background, background, 1))
        let error = zip(bytes(a), bytes(b)).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(
          error, 1, "\(effect.title): GPU simulation must preserve the existing appearance")
      }
    }
  }

  func testPuddlesReflectTheSuppliedScreenTexture() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let renderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(320, 200))
    for surface in renderer.simulation.water {
      for x in stride(from: Float(0), through: 320, by: 4) { surface.hit(x: x, amount: 15) }
      for _ in 0..<60 { surface.step(dt: 1.0 / 60, evaporates: false, clearing: false) }
    }
    renderer.simulation.intensity = .off
    renderer.simulation.step(dt: 0.05, cursor: SIMD2(-100, -100))
    let scene = try texture(device, width: 2, height: 2)
    let red: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255]
    red.withUnsafeBytes {
      scene.replace(
        region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 8)
    }
    renderer.reflection = scene
    let target = try texture(device, width: 320, height: 200)
    // Let the scene's entrance fade finish without adding rain.
    for _ in 0..<40 { renderer.simulation.step(dt: 1.0 / 60, cursor: SIMD2(-100, -100)) }
    try render(renderer, target: target, queue: queue)
    let pixels = bytes(target)
    let i = ((200 - 3) * 320 + 160) * 4
    XCTAssertGreaterThan(pixels[i + 3], 10)
    XCTAssertGreaterThan(
      Int(pixels[i]), Int(pixels[i + 2]) + 15, "A red captured scene must produce a red reflection")
  }

  func testDesktopReflectionKeepsHorizontalRegistration() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let renderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(320, 200))
    renderer.simulation.intensity = .off
    renderer.simulation.evaporates = false
    let pool = renderer.simulation.water[0]
    for x in stride(from: Float(0), through: 320, by: 4) { pool.hit(x: x, amount: 18) }
    for _ in 0..<120 { renderer.simulation.step(dt: 1 / 60, cursor: SIMD2(-1000, -1000)) }
    let scene = try texture(device, width: 320, height: 200)
    var source = [UInt8](repeating: 255, count: 320 * 200 * 4)
    // Asymmetric screen columns reveal horizontal flips, offsets and excessive wave distortion.
    for y in 0..<200 {
      for x in 0..<320 {
        let i = (y * 320 + x) * 4
        source[i] = x < 106 ? 255 : 0
        source[i + 1] = x >= 106 && x < 213 ? 255 : 0
        source[i + 2] = x >= 213 ? 255 : 0
      }
    }
    source.withUnsafeBytes {
      scene.replace(
        region: MTLRegionMake2D(0, 0, 320, 200), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 1280)
    }
    renderer.reflection = scene
    let target = try texture(device, width: 320, height: 200)
    try render(renderer, target: target, queue: queue)
    let result = bytes(target)
    for (x, channel) in [(50, 0), (160, 1), (270, 2)] {
      let i = ((200 - 3) * 320 + x) * 4
      XCTAssertGreaterThan(result[i + 3], 50)
      XCTAssertGreaterThan(Int(result[i + channel]), Int(result[i + (channel + 1) % 3]) + 30)
    }
    // A window dragged across the reflection changes the same x positions in the next frame.
    for y in 0..<200 {
      for x in 130..<190 {
        let i = (y * 320 + x) * 4
        source[i] = 255
        source[i + 1] = 0
        source[i + 2] = 0
      }
    }
    source.withUnsafeBytes {
      scene.replace(
        region: MTLRegionMake2D(0, 0, 320, 200), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 1280)
    }
    try render(renderer, target: target, queue: queue)
    let moved = bytes(target)
    let center = ((200 - 3) * 320 + 160) * 4
    XCTAssertGreaterThan(Int(moved[center]), Int(moved[center + 1]) + 30)
    // The top of a desktop image must appear deeper in the mirrored water band.
    for y in 0..<200 {
      for x in 0..<320 {
        let i = (y * 320 + x) * 4
        source[i] = y < 100 ? 255 : 0
        source[i + 1] = 0
        source[i + 2] = y >= 100 ? 255 : 0
      }
    }
    source.withUnsafeBytes {
      scene.replace(
        region: MTLRegionMake2D(0, 0, 320, 200), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 1280)
    }
    try render(renderer, target: target, queue: queue)
    let vertical = bytes(target)
    let deep = ((200 - 3) * 320 + 160) * 4
    let shallow = ((200 - Int(pool.depth(at: 160) - 2)) * 320 + 160) * 4
    XCTAssertGreaterThan(Int(vertical[deep]), Int(vertical[deep + 2]) + 30)
    XCTAssertGreaterThan(Int(vertical[shallow + 2]), Int(vertical[shallow]) + 30)
  }

  func testVolumetricEffectsNeverDrawInsideTheMenuBar() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    for effect in [WeatherEffect.mist, .clouds, .storm, .lightning] {
      let renderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(640, 400))
      renderer.setEffect(effect)
      renderer.contentTop = 368
      for _ in 0..<300 { renderer.simulation.step(dt: 1 / 30, cursor: SIMD2(-1000, -1000)) }
      let target = try texture(device, width: 640, height: 400)
      try render(renderer, target: target, queue: queue)
      let result = bytes(target)
      XCTAssertTrue(
        stride(from: 3, to: 640 * 32 * 4, by: 4).allSatisfy { result[$0] == 0 }, effect.title)
      XCTAssertTrue(
        stride(from: 640 * 32 * 4 + 3, to: result.count, by: 4).contains { result[$0] > 10 },
        effect.title)
    }
  }

  func testPaddedCaptureDoesNotShiftTheReflectionToTheRight() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let renderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(320, 200))
    renderer.simulation.intensity = .off
    renderer.simulation.evaporates = false
    for x in stride(from: Float(0), through: 320, by: 4) {
      renderer.simulation.water[0].hit(x: x, amount: 18)
    }
    for _ in 0..<90 { renderer.simulation.step(dt: 1 / 60, cursor: SIMD2(-1000, -1000)) }
    let scene = try texture(device, width: 512, height: 256)
    var pixels = [UInt8](repeating: 255, count: 512 * 256 * 4)
    for y in 0..<256 {
      for x in 0..<512 {
        let i = (y * 512 + x) * 4
        let inside = x >= 96 && x < 416 && y >= 28 && y < 228
        pixels[i] = inside && x < 256 ? 255 : 0
        pixels[i + 1] = inside ? 0 : 255
        pixels[i + 2] = inside && x >= 256 ? 255 : 0
      }
    }
    pixels.withUnsafeBytes {
      scene.replace(
        region: MTLRegionMake2D(0, 0, 512, 256), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 2048)
    }
    renderer.reflection = scene
    renderer.reflectionRect = ReflectionGeometry.uvRect(
      contentPixels: CGRect(x: 96, y: 28, width: 320, height: 200),
      textureSize: CGSize(width: 512, height: 256))
    let target = try texture(device, width: 320, height: 200)
    try render(renderer, target: target, queue: queue)
    let result = bytes(target)
    let left = ((200 - 3) * 320 + 80) * 4
    let right = ((200 - 3) * 320 + 240) * 4
    XCTAssertGreaterThan(Int(result[left]), Int(result[left + 1]) + 30)
    XCTAssertGreaterThan(Int(result[right + 2]), Int(result[right + 1]) + 30)
  }

  func testConsecutiveFramesRefreshWaterReflections() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let renderer = try Renderer(
      device: device, pixelFormat: .rgba8Unorm,
      simulation: SnowSimulation(width: 640, height: 400, snowfall: .off))
    renderer.setEffect(.storm, calm: false)
    renderer.setIntensity(.steady)
    for _ in 0..<180 { renderer.weather.step(dt: 1 / 30, cursor: SIMD2(-1000, -1000)) }
    for x in stride(from: Float(0), through: 640, by: 4) {
      renderer.weather.water[0].hit(x: x, amount: 18)
    }
    renderer.weather.step(dt: 1 / 60, cursor: SIMD2(-1000, -1000))
    let scene = try texture(device, width: 2, height: 2)
    renderer.reflection = scene
    let target = try texture(device, width: 640, height: 400)
    var times: [Double] = []
    for blue in [false, true] {
      let color: [UInt8] = Array(
        repeating: blue
          ? [UInt8](arrayLiteral: 0, 0, 255, 255) : [UInt8](arrayLiteral: 255, 0, 0, 255), count: 4
      ).flatMap { $0 }
      color.withUnsafeBytes {
        scene.replace(
          region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: $0.baseAddress!,
          bytesPerRow: 8)
      }
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      let command = try XCTUnwrap(queue.makeCommandBuffer())
      renderer.encode(into: command, pass: pass, scale: 1, time: 6)
      command.commit()
      command.waitUntilCompleted()
      XCTAssertNil(command.error)
      times.append(max(0, command.gpuEndTime - command.gpuStartTime) * 1000)
      let result = bytes(target)
      let i = ((400 - 3) * 640 + 320) * 4
      if blue {
        XCTAssertGreaterThan(Int(result[i + 2]), Int(result[i]) + 30)
      } else {
        XCTAssertGreaterThan(Int(result[i]), Int(result[i + 2]) + 30)
      }
    }
    if let output = ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] {
      let data: [String: Any] = [
        "device": device.name, "resolution": "640x400", "first_frame_gpu_ms": times[0],
        "reflection_refresh_gpu_ms": times[1], "capture_cost_included": false,
      ]
      try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output).appendingPathComponent("reflection-frames.json"))
    }
  }

  func testWaterBandsPreserveGlobalPixelsAndReflectionCoordinates() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let renderer = try WeatherRenderer(
      device: device, format: .rgba8Unorm, size: SIMD2(640, 400), seed: 771)
    renderer.simulation.intensity = .off
    renderer.simulation.evaporates = false
    renderer.simulation.updateWindows([
      WindowSurface(
        id: 41, frame: CGRect(x: 113.25, y: 83.75, width: 320.5, height: 190.5), blockers: [],
        cornerRadius: 18, cornerExponent: 2.5, isDock: false)
    ])
    let pool = renderer.simulation.water[1]
    for x in stride(from: pool.origin.x, through: pool.origin.x + pool.width, by: 4) {
      pool.hit(x: x, amount: 4, impulse: 0)
    }
    for _ in 0..<90 { renderer.simulation.step(dt: 1 / 60, cursor: SIMD2(-1000, -1000)) }
    let capture = try texture(device, width: 640, height: 400)
    var source = [UInt8](repeating: 255, count: 640 * 400 * 4)
    for y in 0..<400 {
      for x in 0..<640 {
        let i = (y * 640 + x) * 4
        source[i] = UInt8(x % 256)
        source[i + 1] = UInt8(y % 256)
        source[i + 2] = UInt8((x + y) % 256)
      }
    }
    source.withUnsafeBytes {
      capture.replace(
        region: MTLRegionMake2D(0, 0, 640, 400), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 640 * 4)
    }
    renderer.reflection = capture
    let rect = CGRect(
      x: floor(Double(pool.origin.x)), y: floor(Double(pool.origin.y)),
      width: ceil(Double(pool.origin.x + pool.width)) - floor(Double(pool.origin.x)), height: 16)
    let full = try texture(device, width: 640, height: 400)
    let band = try texture(device, width: Int(rect.width), height: Int(rect.height))
    for (target, viewport) in [(full, Optional<CGRect>.none), (band, Optional(rect))] {
      renderer.prepare(light: SIMD3(repeating: 1))
      let command = try XCTUnwrap(queue.makeCommandBuffer())
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
      renderer.encodeWater(with: encoder, includeGround: false, viewport: viewport)
      encoder.endEncoding()
      command.commit()
      command.waitUntilCompleted()
      XCTAssertNil(command.error)
    }
    let a = bytes(full)
    let b = bytes(band)
    var maximumDifference = 0
    for row in 0..<Int(rect.height) {
      for x in 0..<Int(rect.width) {
        let i = ((400 - Int(rect.maxY) + row) * 640 + Int(rect.minX) + x) * 4
        let j = (row * Int(rect.width) + x) * 4
        for k in 0..<4 {
          maximumDifference = max(maximumDifference, abs(Int(a[i + k]) - Int(b[j + k])))
        }
      }
    }
    XCTAssertLessThanOrEqual(
      maximumDifference, 1,
      "A narrow native-rate layer must sample the same world positions as the full-screen renderer")
  }

  func testDockWaterRendersInTheDockPassInsteadOfCoveringIcons() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let renderer = try WeatherRenderer(
      device: device, format: .rgba8Unorm, size: SIMD2(640, 400), seed: 8171)
    renderer.simulation.intensity = .off
    renderer.simulation.evaporates = false
    renderer.simulation.updateWindows([
      WindowSurface(
        id: 16, frame: CGRect(x: 100, y: 8, width: 440, height: 60), blockers: [], cornerRadius: 25,
        cornerExponent: 2.5, isDock: true)
    ])
    let pool = try XCTUnwrap(renderer.simulation.water.first { $0.isDock })
    for x in stride(from: pool.origin.x, through: pool.origin.x + pool.width, by: 4) {
      pool.hit(x: x, amount: 4, impulse: 0)
    }
    for _ in 0..<90 { renderer.simulation.step(dt: 1 / 60, cursor: SIMD2(-1000, -1000)) }
    renderer.prepare(light: SIMD3(repeating: 1))
    let main = try texture(device, width: 640, height: 400)
    let dock = try texture(device, width: 1280, height: 192)
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    for (target, isDock) in [(main, false), (dock, true)] {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
      let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
      if isDock {
        renderer.encodeGround(with: encoder, height: 96)
      } else {
        renderer.encodeWater(with: encoder, includeGround: false)
      }
      encoder.endEncoding()
    }
    command.commit()
    command.waitUntilCompleted()
    XCTAssertNil(command.error)
    let mainPixels = bytes(main)
    XCTAssertTrue(stride(from: 3, to: mainPixels.count, by: 4).allSatisfy { mainPixels[$0] == 0 })
    let pixels = bytes(dock)
    let i = ((192 - Int((pool.origin.y + 2) * 2)) * 1280 + 640) * 4
    XCTAssertGreaterThan(pixels[i + 3], 50)
  }

  func testOriginalSnowAndLeafMetalPipelinesStillCompile() throws {
    let device = try metalDevice()
    let simulation = SnowSimulation(width: 640, height: 400, snowfall: .steady)
    _ = try Renderer(device: device, pixelFormat: .bgra8Unorm, simulation: simulation)
    XCTAssertEqual(MemoryLayout<WeatherParticle>.stride, 64)
    XCTAssertEqual(MemoryLayout<WeatherUniforms>.stride, 160)
    XCTAssertEqual(MemoryLayout<WaterRipple>.stride, 16)
  }

  func testProfileWeatherFrameCostsWhenRequested() throws {
    guard let output = ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] else {
      throw XCTSkip("Set ATMOS_BENCHMARK_DIR for local profiling")
    }
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let target = try texture(device, width: 1920, height: 1080)
    var report: [[String: Any]] = []
    for effect in WeatherEffect.allCases where !effect.usesSnowSimulation {
      let renderer = try WeatherRenderer(
        device: device, format: .rgba8Unorm, size: SIMD2(1920, 1080))
      renderer.setEffect(effect)
      let sim = renderer.simulation
      for _ in 0..<450 { sim.step(dt: 1.0 / 30, cursor: SIMD2(-100, -100)) }
      let started = CFAbsoluteTimeGetCurrent()
      for _ in 0..<1200 { sim.step(dt: 1.0 / 30, cursor: SIMD2(-100, -100)) }
      let simulationMS = (CFAbsoluteTimeGetCurrent() - started) * 1000 / 1200
      var gpu: [Double] = []
      for _ in 0..<40 { gpu.append(try render(renderer, target: target, queue: queue)) }
      let gpuMS = gpu.reduce(0, +) / Double(gpu.count)
      report.append([
        "effect": effect.rawValue, "particles": sim.particleCount,
        "simulation_ms_per_frame": simulationMS, "gpu_ms_per_frame": gpuMS,
        "render_resolution": "1920x1080", "device": device.name,
      ])
    }
    let url = URL(fileURLWithPath: output).appendingPathComponent("weather-performance.json")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
  }

  func testCompareOriginalAndOptimizedShaderCostsWhenRequested() throws {
    guard let output = ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] else {
      throw XCTSkip("Opt-in GPU comparison")
    }
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let target = try texture(device, width: 1512, height: 982)
    var report = [[String: Any]]()
    for effect in WeatherEffect.allCases where !effect.usesSnowSimulation {
      var costs = [String: Double]()
      for (name, source) in [
        ("original", referenceWeatherShaderSource), ("optimized", weatherShaderSource),
      ] {
        let renderer = try WeatherRenderer(
          device: device, format: .rgba8Unorm, size: SIMD2(1512, 982), shaderSource: source,
          seed: 19271)
        renderer.setEffect(effect)
        renderer.simulation.intensity = .heavy
        for _ in 0..<600 { renderer.simulation.step(dt: 1 / 30, cursor: SIMD2(-1000, -1000)) }
        for _ in 0..<30 { try render(renderer, target: target, queue: queue) }
        var measured = [Double]()
        for _ in 0..<200 { measured.append(try render(renderer, target: target, queue: queue)) }
        costs[name] = measured.reduce(0, +) / Double(measured.count)
      }
      report.append(["effect": effect.rawValue, "gpu_ms": costs])
    }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: output).appendingPathComponent("shader-comparison.json"))
  }

  private func texture(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
  }

  private func metalDevice() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("Metal is unavailable on this machine")
    }
    return device
  }

  @discardableResult
  private func render(
    _ renderer: WeatherRenderer, target: MTLTexture, queue: MTLCommandQueue,
    background: MTLClearColor = MTLClearColorMake(0, 0, 0, 0)
  ) throws -> Double {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = background
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
    renderer.encode(with: encoder, light: SIMD3(repeating: 1))
    encoder.endEncoding()
    if target.storageMode == .managed {
      let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
      blit.synchronize(resource: target)
      blit.endEncoding()
    }
    command.commit()
    command.waitUntilCompleted()
    XCTAssertNil(command.error)
    return max(0, command.gpuEndTime - command.gpuStartTime) * 1000
  }

  private func bytes(_ texture: MTLTexture) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
      &result, bytesPerRow: texture.width * 4,
      from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return result
  }

  private func export(_ pixels: [UInt8], width: Int, height: Int, path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}
