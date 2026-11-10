import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest

@testable import Aeolian

final class MetalRenderingTests: XCTestCase {
  func testAllWeatherPipelinesRenderVisiblePixels() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    for effect in WeatherEffect.allCases where !effect.usesSnowSimulation && effect != .none {
      let renderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(960, 600))
      renderer.setEffect(effect)
      let surface = WindowSurface(
        id: 42, frame: CGRect(x: 130, y: 120, width: 560, height: 280),
        blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
      renderer.simulation.updateWindows([surface])
      renderer.simulation.wind = 36
      // A flock can intentionally pass without landing. Sample its entrance,
      // rather than the later natural lull, when checking bird artwork visibility.
      for _ in 0..<(effect == .birds ? 180 : 900) { renderer.simulation.step(dt: 1.0 / 60, cursor: SIMD2(-100, -100)) }
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
          contrasted, effect == .fireflies || effect == .birds ? 100 : 200,
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

  func testFogIsBroaderThanWispsAndStaysBehindWindowContent() throws {
    let device = try metalDevice(), queue = try XCTUnwrap(device.makeCommandQueue())
    let target = try texture(device, width: 960, height: 600)
    var fields = [WeatherEffect: [UInt8]]()
    for effect in [WeatherEffect.clouds, .mist] {
      let renderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(960, 600), seed: 6)
      renderer.setEffect(effect); renderer.simulation.scene.includesSky = false
      for _ in 0..<1200 { renderer.simulation.step(dt: 1/120, cursor: SIMD2(-1000, -1000)) }
      try render(renderer, target: target, queue: queue)
      fields[effect] = bytes(target)
      if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
        for (name, level) in [("dark",0.025),("light",0.96)] {
          try render(renderer,target:target,queue:queue,background:MTLClearColorMake(level,level,level,1))
          try export(bytes(target),width:960,height:600,path:"\(output)/fog-compare-\(effect.rawValue)-\(name).png")
        }
      }
      if effect == .mist {
        renderer.windowOccluders = [SIMD4(180,150,780,500)]
        try render(renderer,target:target,queue:queue)
        let masked = bytes(target)
        var maximum: UInt8 = 0
        for y in 175..<475 { for x in 205..<755 {maximum=max(maximum,masked[((600-y-1)*960+x)*4+3])} }
        XCTAssertLessThanOrEqual(maximum,34,"Only the single faint foreground volume may pass over window content")
        if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
          try render(renderer,target:target,queue:queue,background:MTLClearColorMake(0.025,0.025,0.025,1))
          try export(bytes(target),width:960,height:600,path:"\(output)/fog-window-safe.png")
        }
      }
    }
    let fog = try XCTUnwrap(fields[.mist]), wisps = try XCTUnwrap(fields[.clouds])
    let fogArea = stride(from:3,to:fog.count,by:4).filter {fog[$0]>16}.count
    let wispArea = stride(from:3,to:wisps.count,by:4).filter {wisps[$0]>16}.count
    XCTAssertGreaterThan(fogArea,wispArea*2,"Fog should be a continuous, more notable atmosphere than separate cloud wisps")
    let row = 600-150-1
    XCTAssertGreaterThan((0..<960).filter {fog[(row*960+$0)*4+3]>16}.count,850)
  }

  func testFogOpacityFollowsSeverityAcrossBothBanksAndBroadHaze() throws {
    let device=try metalDevice(),queue=try XCTUnwrap(device.makeCommandQueue())
    let target=try texture(device,width:960,height:600)
    var previous=0
    for severity in [LocalWeatherAlert.Severity.minor,.moderate,.severe,.extreme] {
      let renderer=try WeatherRenderer(device:device,format:.rgba8Unorm,size:SIMD2(960,600),seed:6)
      renderer.setEffect(.mist);renderer.simulation.scene.includesSky=false
      renderer.simulation.scene.fog=severity.fogDensity
      for _ in 0..<1800 {renderer.simulation.step(dt:1/120,cursor:SIMD2(-1000,-1000))}
      try render(renderer,target:target,queue:queue)
      let pixels=bytes(target)
      let coverage=stride(from:3,to:pixels.count,by:4).reduce(0){$0+Int(pixels[$1])}
      XCTAssertGreaterThan(coverage,previous)
      previous=coverage
    }
  }

  func testBackgroundMistHidesBehindWindowsWhileFaintForegroundRemains() throws {
    let device = try metalDevice(), queue = try XCTUnwrap(device.makeCommandQueue())
    var selected: WeatherRenderer?
    for seed in UInt64(1)...150 {
      let candidate = try WeatherRenderer(device:device,format:.rgba8Unorm,size:SIMD2(960,600),seed:seed)
      candidate.setEffect(.mist)
      candidate.simulation.step(dt:1/120,cursor:SIMD2(-1000,-1000))
      if candidate.simulation.particles.contains(where:{$0.motion.w==2 && $0.life.z<0.5}) {selected=candidate;break}
    }
    let renderer = try XCTUnwrap(selected)
    for _ in 0..<240 {renderer.simulation.step(dt:1/120,cursor:SIMD2(-1000,-1000))}
    let target = try texture(device,width:960,height:600)
    try render(renderer,target:target,queue:queue)
    let full = bytes(target), total = stride(from:3,to:full.count,by:4).reduce(0){$0+Int(full[$1])}
    renderer.windowOccluders=[SIMD4(-100,-100,1060,700)]
    try render(renderer,target:target,queue:queue)
    let clipped=bytes(target),remaining=stride(from:3,to:clipped.count,by:4).reduce(0){$0+Int(clipped[$1])}
    XCTAssertGreaterThan(remaining,100,"Occasional foreground mist stays visible")
    XCTAssertLessThan(Double(remaining),Double(total)*0.10,"The dense fog layers must stay behind windows")
  }

  func testOptimizedWeatherMatchesOriginalImages() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    for effect in WeatherEffect.allCases
    where [.hail, .clouds, .sunlight, .fireflies].contains(effect) {
      let optimized = try WeatherRenderer(
        device: device, format: .rgba8Unorm, size: SIMD2(960, 600), seed: 8173)
      let reference = try WeatherRenderer(
        device: device, format: .rgba8Unorm, size: SIMD2(960, 600),
        shaderSource: referenceWeatherShaderSource, seed: 8173)
      for renderer in [optimized, reference] {
        renderer.setEffect(effect)
        // Isolate the unchanged wisps, banks and particles. The original canopy
        // has its own strict comparison; mist is intentionally refined separately.
        renderer.simulation.scene.includesSky = false
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

  func testDetachedDropletsUseTheSameDesktopReflectionSource() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let renderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(320, 300))
    let sim = renderer.simulation
    sim.intensity = .off
    sim.evaporates = false
    sim.updateWindows([
      WindowSurface(id: 41, frame: CGRect(x: 50, y: 100, width: 220, height: 100),
        blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
    ])
    for x in stride(from: Float(50), through: 270, by: 4) {
      sim.water[1].hit(x: x, amount: 3, impulse: 0)
    }
    for _ in 0..<120 { sim.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000)) }
    sim.updateWindows([])
    XCTAssertTrue(sim.particles.contains { $0.motion.w == 9 })
    let scene = try texture(device, width: 2, height: 2)
    renderer.reflection = scene
    let target = try texture(device, width: 320, height: 300)
    var results: [[UInt8]] = []
    for color: [UInt8] in [[255, 0, 0, 255], [0, 0, 255, 255]] {
      let pixels = Array(repeating: color, count: 4).flatMap { $0 }
      pixels.withUnsafeBytes {
        scene.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
          withBytes: $0.baseAddress!, bytesPerRow: 8)
      }
      try render(renderer, target: target, queue: queue)
      if let output=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
        try export(bytes(target),width:320,height:300,path:"\(output)/liquid-contour-\(color[0]).png")
      }
      let snapshot=bytes(target)
      try render(renderer,target:target,queue:queue)
      XCTAssertEqual(bytes(target),snapshot,"Unchanged water must render identically across buffer slots")
      results.append(snapshot)
    }
    var red = 0, blue = 0, visible = 0
    for i in stride(from: 0, to: results[0].count, by: 4) where results[0][i + 3] > 30 {
      red += Int(results[0][i]) - Int(results[0][i + 2])
      blue += Int(results[1][i + 2]) - Int(results[1][i])
      visible += 1
    }
    XCTAssertGreaterThan(visible, 100)
    XCTAssertGreaterThan(red, visible * 30)
    XCTAssertGreaterThan(blue, visible * 30)
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

  func testSixBotanicalStylesRenderWithLeafMotionBlurOnLightAndDark() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let library = try device.makeLibrary(source: shaderSource, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "spriteVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "spriteFragment")
    let attachment = descriptor.colorAttachments[0]!
    attachment.pixelFormat = .rgba8Unorm
    attachment.isBlendingEnabled = true
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    for effect in WeatherEffect.seasonal {
      for level in [0.025, 0.96] {
        let target = try texture(device, width: 960, height: 600)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(level, level, level, 1)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var sprites: [Sprite] = []
        for i in 0..<12 {
          let position = SIMD2<Float>(100 + Float(i % 4) * 250, 110 + Float(i / 4) * 185)
          let seed: Float = 0.031 + Float(i) * 0.081
          let sprite = Sprite(
            position: position,
            velocity: SIMD2(Float(i % 3) * 100, -60), size: 100, alpha: 1, soft: 0,
            leaf: seed + (effect == .dandelionSeeds && i < 6 ? 2 : 0),
            turn: Float(i) * 0.7, flip: i % 2 == 0 ? 0.8 : -0.7,
            turnSpeed: effect == .mapleSeeds ? 45 : 1.2, flipSpeed: 0.7)
          sprites.append(sprite)
        }
        var uniforms = Uniforms(viewSize: SIMD2(960, 600), scale: 1, time: 0, columnWidth: 2)
        uniforms.autumn = effect.botanicalStyle
        let buffer = try XCTUnwrap(
          device.makeBuffer(bytes: &sprites, length: sprites.count * MemoryLayout<Sprite>.stride))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: sprites.count)
        encoder.endEncoding()
        try synchronizeIfNeeded([target], into: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        let pixels = bytes(target)
        let background = Int((level * 255).rounded())
        var visible = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
          if max(
            abs(Int(pixels[i]) - background), abs(Int(pixels[i + 1]) - background),
            abs(Int(pixels[i + 2]) - background)) > 10
          {
            visible += 1
          }
        }
        XCTAssertGreaterThan(visible, 500, effect.title)
        XCTAssertLessThan(
          visible, 60000,
          "Artwork must have a transparent silhouette, including thin seed filaments")
        if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
          try export(
            pixels, width: 960, height: 600,
            path: "\(output)/botanical-\(effect.rawValue)-\(level < 0.5 ? "dark" : "light").png")
        }
      }
    }
  }

  func testThreeLayersKeepIndependentParticlesAndRetireWithoutRestartingWeather() throws {
    let device = try metalDevice()
    let simulation = SnowSimulation(width: 960, height: 600, snowfall: .steady)
    let renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm, simulation: simulation)
    renderer.setScene(
      WeatherScene(primary: .rain, stacked: .cherryBlossoms, wildlife: .birds), calm: false)
    renderer.setIntensity(.steady)
    let rain = renderer.current
    let petals = try XCTUnwrap(renderer.overlays.first { $0.effect == .cherryBlossoms })
    let birds = try XCTUnwrap(renderer.overlays.first { $0.effect == .birds })
    for _ in 0..<1200 {
      rain.weather.simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
      _ = petals.snow.simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
      birds.weather.simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000))
    }
    XCTAssertGreaterThan(rain.weather.simulation.particleCount, 0)
    XCTAssertGreaterThan(petals.snow.simulation.spriteCount, 0)
    XCTAssertTrue(birds.weather.simulation.hasContent)
    renderer.setScene(
      WeatherScene(primary: .rain, stacked: .mapleSeeds, wildlife: .birds), calm: false)
    XCTAssertTrue(renderer.current === rain)
    XCTAssertTrue(renderer.overlays.contains { $0 === birds })
    XCTAssertTrue(renderer.retiring.contains { $0 === petals })
    renderer.setScene(WeatherScene(primary: .none, wildlife: .birds), calm: false)
    XCTAssertTrue(renderer.overlays.contains { $0 === birds })
    XCTAssertTrue(renderer.retiring.contains { $0 === rain })
  }

  func testSnowOnlyLiveSceneStillAdvancesItsWeatherClockAndSmoothsMeasurements() throws {
    let device = try metalDevice()
    let renderer = try Renderer(
      device: device, pixelFormat: .rgba8Unorm,
      simulation: SnowSimulation(width: 640, height: 400, snowfall: .steady))
    var reading = WeatherSnapshot(
      time: Date().timeIntervalSince1970, weatherCode: 73,
      temperature: -1, windSpeed: 10, windDirection: 270, precipitation: 0.1, isDay: 0)
    reading.precipitationUnit = "mm/h"
    reading.cloudCover = 0
    renderer.setScene(WeatherScene(weather: reading), calm: false)
    for frame in 0..<120 {
      renderer.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000), now: Double(frame) / 120)
    }
    XCTAssertGreaterThan(renderer.weather.elapsed, 0.9)
    let initial = try XCTUnwrap(renderer.weather.dynamics).precipitationStrength
    reading = WeatherSnapshot(
      time: reading.time, weatherCode: 73, temperature: -1,
      windSpeed: 10, windDirection: 270, precipitation: 1, isDay: 0)
    reading.precipitationUnit = "mm/h"
    reading.cloudCover = 0
    renderer.setScene(WeatherScene(weather: reading), calm: false)
    renderer.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000), now: 1)
    let current = try XCTUnwrap(renderer.weather.dynamics).precipitationStrength
    XCTAssertGreaterThan(current, initial)
    XCTAssertLessThan(current, WeatherDynamics(weather: reading).precipitationStrength)
  }

  func testFloatingLeavesUseTheWaterGroundPassWithoutDrawingOverTheDock() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let simulation = SnowSimulation(width: 640, height: 400, snowfall: .off)
    simulation.autumn = true
    let pool = WaterSurface(id: 0, origin: .zero, width: 640)
    for x in stride(from: Float(0), through: 640, by: 4) { pool.hit(x: x, amount: 12, impulse: 0) }
    pool.step(dt: 1 / 120, evaporates: false, clearing: false)
    XCTAssertTrue(
      simulation.surfaceDrift.catchMaterial(
        x: 320, from: 40, to: 0,
        velocity: SIMD2(0, -40), size: 24, seed: 0.35, area: 1, turn: 0, water: [pool]))
    _ = simulation.surfaceDrift.step(
      dt: 1 / 120, water: [pool], wind: 0, cursor: nil,
      cursorVelocity: .zero, retiring: false, clearing: false)
    let renderer = try SnowSceneRenderer(
      device: device, queue: queue, format: .rgba8Unorm, simulation: simulation)
    let main = try texture(device, width: 640, height: 400)
    let ground = try texture(device, width: 640, height: 128)
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    func pass(_ target: MTLTexture) -> MTLRenderPassDescriptor {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      return pass
    }
    let foreground = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass(main)))
    renderer.encode(
      with: foreground, ambient: (SIMD3(repeating: 1), .zero, .zero), scale: 1, time: 0,
      includeGround: false)
    foreground.endEncoding()
    let behindDock = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass(ground)))
    renderer.encodeGround(with: behindDock, height: 128, scale: 1)
    behindDock.endEncoding()
    try synchronizeIfNeeded([main, ground], into: command)
    command.commit()
    command.waitUntilCompleted()
    XCTAssertNil(command.error)
    let mainPixels = bytes(main)
    let groundPixels = bytes(ground)
    XCTAssertTrue(stride(from: 3, to: mainPixels.count, by: 4).allSatisfy { mainPixels[$0] == 0 })
    XCTAssertGreaterThan(
      stride(from: 3, to: groundPixels.count, by: 4).filter { groundPixels[$0] > 10 }.count, 20)
  }

  func testButterfliesAlwaysRenderBehindApplicationWindows() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let renderer = try WeatherRenderer(
      device: device, format: .rgba8Unorm, size: SIMD2(960, 600), seed: 42)
    renderer.setEffect(.butterflies)
    for _ in 0..<240 { renderer.simulation.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000)) }
    let target = try texture(device, width: 960, height: 600)
    try render(renderer, target: target, queue: queue)
    let uncovered = bytes(target)
    XCTAssertGreaterThan(
      stride(from: 3, to: uncovered.count, by: 4).reduce(0) { $0 + Int(uncovered[$1]) }, 0)
    renderer.windowOccluders = [SIMD4(-50, -50, 1010, 650)]
    try render(renderer, target: target, queue: queue)
    let covered = bytes(target)
    XCTAssertTrue(stride(from: 3, to: covered.count, by: 4).allSatisfy { covered[$0] == 0 })
  }

  func testBirdVariantsRenderCurvedWingsAndDistinctPlumage() throws {
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let library = try device.makeLibrary(source: weatherShaderSource, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "weatherVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "weatherFragment")
    let attachment = descriptor.colorAttachments[0]!
    attachment.pixelFormat = .rgba8Unorm
    attachment.isBlendingEnabled = true
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    var models: [WeatherParticle] = []
    for species in 0..<4 {
      for pose in 0..<3 {
        models.append(
          WeatherParticle(
            rect: SIMD4(125 + Float(species) * 235, 120 + Float(pose) * 180, 180, 170),
            motion: SIMD4(80, 0, 0.12 + Float(pose) * 0.21, 14), color: SIMD4(0.3, 0.3, 0.3, 1),
            life: SIMD4(2, 10000, Float(species + 1), pose == 2 ? 1 : 0)))
      }
    }
    let buffer = try XCTUnwrap(
      device.makeBuffer(bytes: &models, length: models.count * MemoryLayout<WeatherParticle>.stride)
    )
    for level in [0.025, 0.96] {
      let target = try texture(device, width: 960, height: 600)
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(level, level, level, 1)
      let command = try XCTUnwrap(queue.makeCommandBuffer())
      let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
      var u = WeatherUniforms(
        viewSize: SIMD2(960, 600), time: 1.1, opacity: 1, light: SIMD4(repeating: 1))
      u.screen = SIMD4(960, 600, 600, 0)
      var dummy = SIMD4<Float>.zero
      encoder.setRenderPipelineState(pipeline)
      encoder.setVertexBuffer(buffer, offset: 0, index: 0)
      encoder.setVertexBytes(&u, length: MemoryLayout<WeatherUniforms>.stride, index: 1)
      encoder.setFragmentBytes(&u, length: MemoryLayout<WeatherUniforms>.stride, index: 1)
      for index in [3, 4, 5] { encoder.setFragmentBytes(&dummy, length: 16, index: index) }
      encoder.drawPrimitives(
        type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: models.count)
      encoder.endEncoding()
      try synchronizeIfNeeded([target], into: command)
      command.commit()
      command.waitUntilCompleted()
      XCTAssertNil(command.error)
      let pixels = bytes(target)
      var tiles: [Data] = []
      for column in 0..<4 {
        var tile: [UInt8] = []
        for row in 35..<205 {
          let start = (row * 960 + 35 + column * 235) * 4
          tile.append(contentsOf: pixels[start..<(start + 180 * 4)])
        }
        tiles.append(Data(tile))
      }
      XCTAssertEqual(Set(tiles).count, 4, "Each bird variant must have distinct visible artwork")
      if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
        try export(
          pixels, width: 960, height: 600,
          path: "\(output)/bird-variants-\(level < 0.5 ? "dark" : "light").png")
      }
    }
  }

  func testOriginalSnowAndLeafMetalPipelinesStillCompile() throws {
    let device = try metalDevice()
    let simulation = SnowSimulation(width: 640, height: 400, snowfall: .steady)
    _ = try Renderer(device: device, pixelFormat: .bgra8Unorm, simulation: simulation)
    XCTAssertEqual(MemoryLayout<WeatherParticle>.stride, 64)
    XCTAssertEqual(MemoryLayout<WeatherUniforms>.stride, 176)
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
    for effect in WeatherEffect.allCases where !effect.usesSnowSimulation && effect != .none {
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

  func testProfileThreeLiveLayersWhenRequested() throws {
    guard let output = ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] else {
      throw XCTSkip("Set ATMOS_BENCHMARK_DIR for isolated live-layer profiling")
    }
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let target = try texture(device, width: 1920, height: 1080)
    var report = [[String: Any]]()
    for (index, material) in WeatherEffect.seasonal.enumerated() {
      let renderer = try Renderer(
        device: device, pixelFormat: .rgba8Unorm,
        simulation: SnowSimulation(width: 1920, height: 1080, snowfall: .steady))
      var reading = WeatherSnapshot(
        time: Date().timeIntervalSince1970, weatherCode: 51,
        temperature: 18, windSpeed: 25, windDirection: 270, precipitation: 0.2, isDay: 1)
      reading.precipitationUnit = "mm/h"
      reading.cloudCover = 99
      reading.humidity = 85
      reading.windGust = 38
      var scene = WeatherScene(weather: reading)
      scene.stacked = material
      scene.wildlife = index % 2 == 0 ? .birds : .butterflies
      renderer.setScene(scene, calm: false)
      renderer.setIntensity(.steady)
      let frames: [SIMD4<Float>] = [SIMD4(200, 200, 800, 700), SIMD4(1000, 100, 1700, 600)]
      renderer.setCoverFrames(frames)
      let surfaces = frames.enumerated().map { i, b in
        WindowSurface(
          id: UInt32(i + 10),
          frame: CGRect(
            x: CGFloat(b.x), y: CGFloat(b.y), width: CGFloat(b.z - b.x), height: CGFloat(b.w - b.y)),
          blockers: [], cornerRadius: 18, cornerExponent: 2.5, isDock: false)
      }
      renderer.updateWindows(
        WindowUpdate(
          surfaces: surfaces, interval: 0.1, parked: [], elsewhere: [], sliding: false,
          slideVelocity: 0), onWindows: true)
      for frame in 0..<1800 {
        renderer.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000), now: Double(frame) / 120)
      }
      let start = CACurrentMediaTime()
      for frame in 1800..<2400 {
        renderer.step(dt: 1 / 120, cursor: SIMD2(-1000, -1000), now: Double(frame) / 120)
      }
      let simulationMS = (CACurrentMediaTime() - start) / 600 * 1000
      var gpuMS = 0.0
      var renderCPU = 0.0
      for frame in 0..<120 {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let start = CACurrentMediaTime()
        renderer.encode(into: command, pass: pass, scale: 1, time: Float(frame) / 120)
        command.commit()
        renderCPU += (CACurrentMediaTime() - start) * 1000
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        gpuMS += max(0, command.gpuEndTime - command.gpuStartTime) * 1000
      }
      report.append([
        "material": material.rawValue, "wildlife": scene.wildlife!.rawValue,
        "simulation_including_airflow_ms": simulationMS, "render_encode_cpu_ms": renderCPU / 120,
        "render_gpu_ms": gpuMS / 120, "device": device.name,
        "capture":
          "excluded; capture remains adaptive and is measured separately by runtime metrics",
      ])
      if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
        try export(
          bytes(target), width: 1920, height: 1080, path: "\(output)/live-\(material.rawValue).png")
      }
    }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: output).appendingPathComponent("dynamic-performance.json"))
  }

  func testCompareOriginalAndOptimizedShaderCostsWhenRequested() throws {
    guard let output = ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] else {
      throw XCTSkip("Opt-in GPU comparison")
    }
    let device = try metalDevice()
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let target = try texture(device, width: 1512, height: 982)
    var report = [[String: Any]]()
    for effect in WeatherEffect.allCases where !effect.usesSnowSimulation && effect != .none {
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

  private func synchronizeIfNeeded(_ textures: [MTLTexture], into command: MTLCommandBuffer) throws
  {
    let managed = textures.filter { $0.storageMode == .managed }
    guard !managed.isEmpty else { return }
    let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
    for texture in managed { blit.synchronize(resource: texture) }
    blit.endEncoding()
  }

  func testMapleMaterialRendersAboveItsSharedWaterline() throws {
    let device=try metalDevice(),queue=try XCTUnwrap(device.makeCommandQueue())
    let renderer=try Renderer(device:device,pixelFormat:.rgba8Unorm,
      simulation:SnowSimulation(width:800,height:300,snowfall:.steady))
    renderer.setScene(WeatherScene(primary:.rain,stacked:.mapleSeeds),calm:false)
    renderer.setIntensity(.steady);renderer.weather.intensity = .off;renderer.weather.evaporates=false
    for x in stride(from:Float(0),through:800,by:4) {renderer.weather.water[0].hit(x:x,amount:14,impulse:0)}
    for frame in 0..<1800 {renderer.step(dt:1/60,cursor:SIMD2(-1000,-1000),now:Double(frame)/60)}
    let maple=try XCTUnwrap(renderer.overlays.first {$0.effect == .mapleSeeds})
    XCTAssertGreaterThan(maple.snow.simulation.surfaceDrift.count,0)
    let target=try texture(device,width:800,height:300)
    let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
    pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0.04,0.05,0.055,1)
    let command=try XCTUnwrap(queue.makeCommandBuffer())
    renderer.encode(into:command,pass:pass,scale:1,time:30)
    try synchronizeIfNeeded([target],into:command);command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
    if let output=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
      try export(bytes(target),width:800,height:300,path:"\(output)/maples-floating.png")
    }
  }

  func testProfileDenseLiquidAndComparePreviousSurfaceWhenRequested() throws {
    guard let output=ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] else {throw XCTSkip("Set ATMOS_BENCHMARK_DIR for dense liquid profiling")}
    let device=try metalDevice(),queue=try XCTUnwrap(device.makeCommandQueue())
    let target=try texture(device,width:1920,height:1080)
    var report=[[String:Any]]()
    var sources=[("current",weatherShaderSource)]
    if let path=ProcessInfo.processInfo.environment["ATMOS_REFERENCE_SHADER"] {sources.append(("build49",try String(contentsOfFile:path)))}
    for (name,source) in sources {
      let renderer=try WeatherRenderer(device:device,format:.rgba8Unorm,size:SIMD2(1920,1080),shaderSource:source,seed:42)
      let sim=renderer.simulation;sim.intensity = .off;sim.evaporates=false
      func window(_ y:CGFloat)->WindowSurface {WindowSurface(id:41,frame:CGRect(x:100,y:y,width:1400,height:200),blockers:[],cornerRadius:18,cornerExponent:2.5,isDock:false)}
      sim.updateWindows([window(100)])
      for _ in 0..<120 {sim.step(dt:1/120,cursor:SIMD2(-1000,-1000))}
      let pool=sim.water[1]
      for x in stride(from:pool.origin.x,through:pool.origin.x+pool.width,by:4) {pool.hit(x:x,amount:4,impulse:0)}
      var simulationMS=0.0
      for frame in 1...14 {
        if frame<=6 {sim.updateWindows([window(100+CGFloat(frame)*12)],interval:1/120)}
        let start=CACurrentMediaTime();sim.step(dt:1/120,cursor:SIMD2(-1000,-1000));simulationMS+=(CACurrentMediaTime()-start)*1000
      }
      var gpu=0.0,cpu=0.0
      for _ in 0..<30 {
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        let command=try XCTUnwrap(queue.makeCommandBuffer())
        let start=CACurrentMediaTime()
        let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
        renderer.encode(with:encoder,light:SIMD3(repeating:1));encoder.endEncoding();command.commit()
        cpu+=(CACurrentMediaTime()-start)*1000
        command.waitUntilCompleted();XCTAssertNil(command.error)
        gpu+=max(0,command.gpuEndTime-command.gpuStartTime)*1000
      }
      report.append(["surface":name,"particles":sim.particleCount,"simulation_ms":simulationMS/14,
        "render_encode_cpu_ms":cpu/30,"gpu_ms":gpu/30,"device":device.name,"capture":"excluded"])
    }
    try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output).appendingPathComponent("dense-liquid-performance.json"))
  }

  func testLightningSplashRendersAVisibleCrown() throws {
    let device=try metalDevice(),queue=try XCTUnwrap(device.makeCommandQueue())
    let renderer=try WeatherRenderer(device:device,format:.rgba8Unorm,size:SIMD2(960,640),seed:42)
    let sim=renderer.simulation;sim.intensity = .off;sim.evaporates=false
    for x in stride(from:Float(0),through:960,by:4) {sim.water[0].hit(x:x,amount:14,impulse:0)}
    for _ in 0..<60 {sim.step(dt:1/120,cursor:SIMD2(-1000,-1000))}
    sim.lightningSplash(surface:sim.water[0],x:480)
    let target=try texture(device,width:960,height:640)
    for frame in 0..<25 {
      sim.step(dt:1/120,cursor:SIMD2(-1000,-1000))
      if [0,8,16,24].contains(frame) {
        try render(renderer,target:target,queue:queue,background:MTLClearColorMake(0.04,0.05,0.06,1))
        if let output=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
          try export(bytes(target),width:960,height:640,path:"\(output)/lightning-crown-\(frame).png")
        }
      }
    }
    XCTAssertTrue(sim.particles.contains {$0.motion.w==9 && $0.rect.y>80})
  }

  func testProfileRapidPuddleSweepsWhenRequested() throws {
    guard let output=ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] else {throw XCTSkip("Set ATMOS_BENCHMARK_DIR for cursor stress profiling")}
    let device=try metalDevice(),queue=try XCTUnwrap(device.makeCommandQueue())
    let native=ProcessInfo.processInfo.environment["ATMOS_SWEEP_NATIVE"]=="1"
    let screen=NSScreen.main
    let pointSize:SIMD2<Float>=native ? SIMD2(Float(screen?.frame.width ?? 1920),Float(screen?.frame.height ?? 1080)):SIMD2(1920,1080)
    let scale=native ? Float(screen?.backingScaleFactor ?? 1):1
    let renderer=try WeatherRenderer(device:device,format:.rgba8Unorm,size:pointSize,seed:42)
    renderer.usesGPULiquidField = ProcessInfo.processInfo.environment["ATMOS_CPU_LIQUID_FIELD"] != "1"
    let sim=renderer.simulation;sim.intensity = .off;sim.evaporates=false
    for x in stride(from:Float(0),through:pointSize.x,by:4) {sim.water[0].hit(x:x,amount:18,impulse:0)}
    for _ in 0..<60 {sim.step(dt:1/120,cursor:SIMD2(-1000,-1000))}
    let target=try texture(device,width:Int(pointSize.x*scale),height:Int(pointSize.y*scale))
    // The running app has already rendered while its puddle fills. Exclude the
    // one-time pipeline/resource startup from the interaction stress measurement.
    for _ in 0..<3 {_=try render(renderer,target:target,queue:queue)}
    var simulation=[Double](),encoding=[Double](),gpu=[Double](),counts=[Int]()
    let measuredFrames = max(48, Int(ProcessInfo.processInfo.environment["ATMOS_SWEEP_FRAMES"] ?? "48") ?? 48)
    for frame in 0..<measuredFrames {
      let point=SIMD2<Float>(native ? pointSize.x*(0.5+0.4*sin(Float(frame)*0.55)) : 800+650*sin(Float(frame)*0.55),8)
      let start=CACurrentMediaTime();sim.step(dt:1/120,cursor:point);simulation.append((CACurrentMediaTime()-start)*1000)
      counts.append(sim.particleCount)
      let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
      pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
      let command=try XCTUnwrap(queue.makeCommandBuffer()),encodeStart=CACurrentMediaTime()
      renderer.prepare(light: SIMD3(repeating: 1), command: command)
      let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
      renderer.encodeWater(with:encoder,includeGround:true);renderer.encodeAtmosphere(with:encoder,includeGround:true);encoder.endEncoding();command.commit()
      encoding.append((CACurrentMediaTime()-encodeStart)*1000)
      command.waitUntilCompleted();XCTAssertNil(command.error)
      gpu.append(max(0,command.gpuEndTime-command.gpuStartTime)*1000)
    }
    func values(_ list:[Double])->[String:Double] {let s=list.sorted();return ["median":s[s.count/2],"p95":s[Int(Double(s.count-1)*0.95)],"maximum":s.last!]}
    let report:[String:Any]=["device":device.name,"resolution":"\(target.width)x\(target.height)","simulation_ms":values(simulation),
      "render_encode_cpu_ms":values(encoding),"gpu_ms":values(gpu),"maximum_particles":counts.max() ?? 0,"capture":"excluded",
      "measured_frames":measuredFrames,"liquid_field":renderer.usesGPULiquidField ? "GPU with Rust fallback":"Rust",
      "combined_liquid_frame_ms":values(simulation.indices.map {simulation[$0]+encoding[$0]+gpu[$0]})]
    let label=ProcessInfo.processInfo.environment["ATMOS_SWEEP_LABEL"] ?? "current"
    try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output).appendingPathComponent("puddle-sweep-\(label).json"))
  }

  func testOrganicLiquidSilhouettesHaveVisibleSoftLobes() throws {
    let device=try metalDevice(),queue=try XCTUnwrap(device.makeCommandQueue())
    let library=try device.makeLibrary(source:weatherShaderSource,options:nil)
    let descriptor=MTLRenderPipelineDescriptor()
    descriptor.vertexFunction=library.makeFunction(name:"weatherVertex")
    descriptor.fragmentFunction=library.makeFunction(name:"weatherFragment")
    let attachment=descriptor.colorAttachments[0]!
    attachment.pixelFormat = .rgba8Unorm;attachment.isBlendingEnabled=true
    attachment.sourceRGBBlendFactor = .one;attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha;attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    let pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
    var particles=[WeatherParticle](),field=[SIMD4<Float>]()
    for i in 0..<6 {
      let centre=SIMD2<Float>(150+Float(i%3)*300,150+Float(i/3)*300)
      particles.append(WeatherParticle(rect:SIMD4(centre.x,centre.y,35,35),motion:SIMD4(20,90,0.03+Float(i)*0.13,9),color:SIMD4(0,0,0,1),life:SIMD4(2,10000,1,0)))
      for _ in 0..<8 {field.append(SIMD4(centre.x,centre.y,17.5,1))}
    }
    let particleBuffer=try XCTUnwrap(device.makeBuffer(bytes:&particles,length:particles.count*MemoryLayout<WeatherParticle>.stride))
    let fieldBuffer=try XCTUnwrap(device.makeBuffer(bytes:&field,length:field.count*16))
    let scene=try texture(device,width:2,height:2)
    let scenePixels:[UInt8]=[45,80,110,255,45,80,110,255,105,145,180,255,105,145,180,255]
    scenePixels.withUnsafeBytes {scene.replace(region:MTLRegionMake2D(0,0,2,2),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:8)}
    let target=try texture(device,width:900,height:600)
    let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
    pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0.04,0.05,0.06,1)
    let command=try XCTUnwrap(queue.makeCommandBuffer()),encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
    var uniforms=WeatherUniforms(viewSize:SIMD2(900,600),time:0.75,opacity:1,light:SIMD4(repeating:1))
    uniforms.screen=SIMD4(900,600,600,0)
    encoder.setRenderPipelineState(pipeline);encoder.setVertexBuffer(particleBuffer,offset:0,index:0)
    encoder.setVertexBytes(&uniforms,length:MemoryLayout<WeatherUniforms>.stride,index:1)
    encoder.setFragmentBytes(&uniforms,length:MemoryLayout<WeatherUniforms>.stride,index:1)
    var dummy=SIMD4<Float>.zero
    for index in [3,4,5] {encoder.setFragmentBytes(&dummy,length:16,index:index)}
    encoder.setFragmentBuffer(fieldBuffer,offset:0,index:6);encoder.setFragmentTexture(scene,index:0)
    encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4,instanceCount:6);encoder.endEncoding()
    try synchronizeIfNeeded([target],into:command);command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
    let pixels=bytes(target)
    for i in 0..<6 {
      let cx=150+Int(i%3)*300,cy=150+Int(i/3)*300
      var radii=[Int]()
      for ray in 0..<32 {
        let angle=Double(ray)/32*2*Double.pi
        var last=0
        for r in 1..<90 {
          let x=cx+Int((cos(angle)*Double(r)).rounded()),y=cy+Int((sin(angle)*Double(r)).rounded())
          let j=((600-1-y)*900+x)*4
          if max(abs(Int(pixels[j])-10),abs(Int(pixels[j+1])-13),abs(Int(pixels[j+2])-15))>10 {last=r}
        }
        radii.append(last)
      }
      XCTAssertGreaterThan((radii.max() ?? 0)-(radii.min() ?? 0),6,"The outline should visibly deform rather than remain circular")
    }
    if let output=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {try export(pixels,width:900,height:600,path:"\(output)/organic-liquid-shapes.png")}
  }

  func testRestoredCloudVolumeMatchesTheOriginalAppearance() throws {
    let device = try metalDevice(), queue = try XCTUnwrap(device.makeCommandQueue())
    let start = try XCTUnwrap(weatherShaderSource.range(of: "    if(in.kind==2.0 || in.kind==7.0 || in.kind==12.0) {"))
    let end = try XCTUnwrap(weatherShaderSource.range(of: "    if(in.kind==13.0) {", range: start.upperBound..<weatherShaderSource.endIndex))
    // Compare the original volume/lighting at the same wind-advected coordinates.
    // 0.14.4 deliberately changes motion, not cloud density, shading or artwork.
    let referenceVolume = originalCloudVolumeFragment
      .replacingOccurrences(of: "-u.time*(0.018+u.climate.z*0.0005)",
        with: "(cloud ? -u.details.w*(0.011/0.0018) : -u.time*(0.018+u.climate.z*0.0005))")
      .replacingOccurrences(of: "in.world.x*0.009-u.time*0.012", with: "in.world.x*0.009-u.details.w*5.0")
    let referenceSource = weatherShaderSource.replacingCharacters(in: start.lowerBound..<end.lowerBound, with: referenceVolume)
    for effect in [WeatherEffect.clouds, .lightning] {
      let restored = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(960, 600), seed: 77181)
      let original = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(960, 600), shaderSource: referenceSource, seed: 77181)
      for renderer in [restored, original] {
        renderer.setEffect(effect)
        for _ in 0..<600 { renderer.simulation.step(dt: 1/30, cursor: SIMD2(-1000, -1000)) }
        let cloud = try XCTUnwrap(renderer.simulation.decorations.first { $0.motion.w == 12 })
        let cover: Float = effect == .clouds ? 0.65 : 1
        let height = min(Float(600)*0.35, effect == .clouds ? 90+cover*130 : 220)*(0.65+0.35*cover)
        XCTAssertEqual(cloud.rect, SIMD4(480,600-height*0.35,1056,height*1.5), "Preserve the original broad canopy geometry")
      }
      for level in [0.025, 0.96] {
        let a = try texture(device, width: 960, height: 600), b = try texture(device, width: 960, height: 600)
        try render(restored, target: a, queue: queue, background: MTLClearColorMake(level,level,level,1))
        try render(original, target: b, queue: queue, background: MTLClearColorMake(level,level,level,1))
        let error = zip(bytes(a),bytes(b)).map { abs(Int($0)-Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(error,1,"Restore the original soft volume, lighting and colour")
        if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
          let name = "\(effect.rawValue)-\(level<0.5 ? "dark":"light")"
          try export(bytes(a),width:960,height:600,path:"\(output)/restored-\(name).png")
          try export(bytes(b),width:960,height:600,path:"\(output)/original-\(name).png")
        }
      }
    }
  }

  func testLiveCloudCoverageFillsTheReportedWidthAndRendersVisibleClouds() throws {
    let device = try metalDevice(), queue = try XCTUnwrap(device.makeCommandQueue())
    // Probe the very same coverage function used by the volume, before its
    // naturally translucent light extinction and feathered edge are applied.
    let maskSource = weatherShaderSource.replacingOccurrences(of: "float envelope;",
      with: "          if(cloud)return float4(1.0)*step(0.5,cloudCoverage(in.world.x,u));\n          float envelope;")
    XCTAssertNotEqual(maskSource, weatherShaderSource)
    for cover in [32.0, 58, 99] {
      let renderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(960, 600), seed: 42)
      let maskRenderer = try WeatherRenderer(device: device, format: .rgba8Unorm, size: SIMD2(960, 600), shaderSource: maskSource, seed: 42)
      var reading = WeatherSnapshot(time: Date().timeIntervalSince1970, weatherCode: 1,
        temperature: 12, windSpeed: 0, windDirection: 0, precipitation: 0, isDay: 0)
      reading.cloudCover = cover; reading.precipitationUnit = "mm/h"
      for item in [renderer,maskRenderer] {
        item.setEffect(.none); item.contentTop = 572
        item.simulation.scene = WeatherScene(weather: reading)
        for _ in 0..<1200 { item.simulation.step(dt: 1/120, cursor: SIMD2(-1000, -1000)) }
      }
      let target = try texture(device, width: 960, height: 600)
      let row = 600 - Int(renderer.contentTop) + 1
      try render(maskRenderer, target: target, queue: queue)
      let mask = bytes(target)
      let occupied = (0..<960).filter { mask[(row*960+$0)*4+3]>128 }.count
      XCTAssertEqual(Double(occupied)/960,cover/100,accuracy:0.008,"The original volume's coverage field must fill the reported width")
      let agreement = (0..<960).filter {
        (mask[(row*960+$0)*4+3]>128) == renderer.simulation.sky.contains(x:Float($0)+0.5)
      }.count
      XCTAssertGreaterThan(Double(agreement)/960,0.99,"Rain and rendered clouds must share the same field")
      try render(renderer, target: target, queue: queue)
      let pixels = bytes(target)
      let visible = (0..<960).filter { pixels[(row*960+$0)*4+3]>16 }.count
      XCTAssertGreaterThan(Double(visible)/960,cover/100*0.65,"Partial cloud cover must remain visible with the original soft rendering")
      if let output = ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
        try render(renderer, target: target, queue: queue, background: MTLClearColorMake(0.025, 0.025, 0.025, 1))
        try export(bytes(target), width: 960, height: 600, path: "\(output)/sky-\(Int(cover)).png")
      }
    }
  }

  func testLiveHazeCannotMakeFiftyPercentSkyCloudsInvisible() throws {
    let device=try metalDevice(),queue=try XCTUnwrap(device.makeCommandQueue())
    let renderer=try WeatherRenderer(device:device,format:.rgba8Unorm,size:SIMD2(960,600),seed:42)
    var reading=WeatherSnapshot(time:Date().timeIntervalSince1970,weatherCode:2,
      temperature:6,windSpeed:2,windDirection:108,precipitation:0,isDay:0)
    reading.cloudCover=50;reading.visibility=12_400;reading.humidity=92
    var scene=WeatherScene(weather:reading)
    scene.primary = .mist // A regional warning selects the haze renderer.
    renderer.setEffect(.mist);renderer.contentTop=572;renderer.simulation.scene=scene
    for _ in 0..<1200 {renderer.simulation.step(dt:1/120,cursor:SIMD2(-1000,-1000))}
    XCTAssertLessThan(renderer.simulation.fogAmount,0.1)
    let target=try texture(device,width:960,height:600)
    try render(renderer,target:target,queue:queue)
    let pixels=bytes(target),row=600-Int(renderer.contentTop)+1
    let visible=(0..<960).filter{pixels[(row*960+$0)*4+3]>16}.count
    XCTAssertGreaterThan(Double(visible)/960,0.25,"Visibility may soften low haze, but must not dim the overhead cloud field")
    if let output=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
      try render(renderer,target:target,queue:queue,background:MTLClearColorMake(0.025,0.025,0.025,1))
      try export(bytes(target),width:960,height:600,path:"\(output)/clouds-with-light-haze.png")
    }
  }

  func testProfileFogAndWispsAtNativeResolutionWhenRequested() throws {
    guard let output=ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] else {throw XCTSkip("Set ATMOS_BENCHMARK_DIR for native fog profiling")}
    let device=try metalDevice(),queue=try XCTUnwrap(device.makeCommandQueue()),screen=NSScreen.main
    let size=SIMD2<Float>(Float(screen?.frame.width ?? 1512),Float(screen?.frame.height ?? 982))
    let scale=Float(screen?.backingScaleFactor ?? 2)
    let target=try texture(device,width:Int(size.x*scale),height:Int(size.y*scale))
    var reports=[[String:Any]]()
    for effect in [WeatherEffect.clouds,.mist] {
      let renderer=try WeatherRenderer(device:device,format:.rgba8Unorm,size:size,seed:6)
      renderer.setEffect(effect);renderer.simulation.scene.includesSky=false;renderer.simulation.intensity = .heavy
      renderer.windowOccluders=[SIMD4(size.x*0.1,size.y*0.25,size.x*0.45,size.y*0.8),SIMD4(size.x*0.6,size.y*0.2,size.x*0.9,size.y*0.7)]
      for _ in 0..<1200 {renderer.simulation.step(dt:1/120,cursor:SIMD2(-1000,-1000))}
      var simulation=[Double](),encoding=[Double](),gpu=[Double]()
      for frame in 0..<63 {
        let start=CACurrentMediaTime()
        renderer.simulation.step(dt:1/120,cursor:SIMD2(size.x*0.5+sin(Float(frame)*0.15)*100,size.y*0.3))
        let sim=(CACurrentMediaTime()-start)*1000
        let command=try XCTUnwrap(queue.makeCommandBuffer()),encoded=CACurrentMediaTime()
        renderer.prepare(light:SIMD3(repeating:1),command:command)
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
        renderer.encodeWater(with:encoder,includeGround:true);renderer.encodeAtmosphere(with:encoder,includeGround:true)
        encoder.endEncoding();command.commit();let cpu=(CACurrentMediaTime()-encoded)*1000
        command.waitUntilCompleted();XCTAssertNil(command.error)
        if frame>=3 {simulation.append(sim);encoding.append(cpu);gpu.append(max(0,command.gpuEndTime-command.gpuStartTime)*1000)}
      }
      func values(_ list:[Double])->[String:Double] {let s=list.sorted();return ["median":s[s.count/2],"p95":s[Int(Double(s.count-1)*0.95)],"maximum":s.last!]}
      reports.append(["effect":effect.rawValue,"device":device.name,"resolution":"\(target.width)x\(target.height)",
        "simulation_ms":values(simulation),"render_encode_cpu_ms":values(encoding),"gpu_ms":values(gpu),
        "combined_frame_ms":values(simulation.indices.map{simulation[$0]+encoding[$0]+gpu[$0]}),"capture":"excluded"])
    }
    try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output).appendingPathComponent("fog-native-performance.json"))
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
