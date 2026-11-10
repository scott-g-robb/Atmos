import AppKit
import Metal
import MetalKit
import XCTest
@testable import Aeolian

final class Refinement143Tests: XCTestCase {
  @MainActor func testSetupPauseNeverAcquiresADrawableFromALinkedLayer() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), device: device)
    let renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm,
      simulation: SnowSimulation(width: 320, height: 200, snowfall: .off))
    let clock = try XCTUnwrap(NativeFrameClock(view: view, renderer: renderer))
    defer { clock.invalidate() }
    // The ordinary welcome launch pauses immediately after attaching the clock.
    // The former releaseFrames called nextDrawable and raised an ObjC exception.
    clock.isPaused = true
    renderer.releaseFrames(of: view)
    renderer.releaseFrames(of: view)
    XCTAssertTrue(clock.isPaused)
  }
  @MainActor func testNativeClockClearsThenPausesAndCanWakeRepeatedly() async throws {
    guard ProcessInfo.processInfo.environment["ATMOS_TEST_NATIVE_LIFECYCLE"] == "1" else {
      throw XCTSkip("Set ATMOS_TEST_NATIVE_LIFECYCLE=1 for visible display-clock lifecycle testing")
    }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 240, height: 160), device: device)
    view.autoResizeDrawable = false
    view.clearColor = MTLClearColorMake(0,0,0,0)
    view.layer?.isOpaque = false
    Renderer.fitDrawable(of: view)
    let renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm,
      simulation: SnowSimulation(width: 240, height: 160, snowfall: .off))
    renderer.setEffect(.rain, calm: false)
    let clock = try XCTUnwrap(NativeFrameClock(view: view, renderer: renderer))
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 240, height: 160),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false; window.backgroundColor = .clear
    window.hasShadow = false; window.ignoresMouseEvents = true
    window.contentView = view; window.orderFrontRegardless()
    defer { clock.invalidate(); window.close() }
    func waitFor(_ condition: () -> Bool) async throws {
      let limit = CACurrentMediaTime() + 3
      while !condition() && CACurrentMediaTime() < limit { try await Task.sleep(nanoseconds: 10_000_000) }
      XCTAssertTrue(condition(), "Native clock did not complete its pause/wake transition")
    }
    for _ in 0..<3 {
      let cleared = clock.clearedFrames
      clock.isPaused = true; renderer.releaseFrames(of: view)
      try await waitFor { clock.clearedFrames > cleared }
      XCTAssertEqual(view.drawableSize, CGSize(width: 1, height: 1))
      let presented = clock.presentedFrames
      Renderer.fitDrawable(of: view); clock.isPaused = false; renderer.resetClock()
      try await waitFor { clock.presentedFrames > presented }
      XCTAssertEqual(view.drawableSize, view.bounds.size)
    }
  }
  @MainActor func testBusyGPUDoesNotRunUnpresentablePhysicsOrDesktopCapture() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), device: device)
    let renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm,
      simulation: SnowSimulation(width: 320, height: 200, snowfall: .heavy),
      inFlight: DispatchSemaphore(value: 0))
    var queried = false
    renderer.windowSurfaces = { _ in queried = true; return nil }
    let elapsed = renderer.weather.elapsed
    XCTAssertFalse(renderer.draw(in: view, providedDrawable: nil))
    XCTAssertFalse(queried)
    XCTAssertEqual(renderer.weather.elapsed, elapsed)
  }
  func testRapidRestoreClearsDepartureAsSoonAsTheWindowReturns() {
    var state=WindowDepartureState()
    XCTAssertTrue(state.restored(departing:[7],visible:[7,8]).isEmpty)
    XCTAssertTrue(state.restored(departing:[7],visible:[8]).isEmpty)
    XCTAssertEqual(state.restored(departing:[7],visible:[7,8]),[7])
    XCTAssertTrue(state.restored(departing:[],visible:[7,8]).isEmpty)
    XCTAssertTrue(state.restored(departing:[7],visible:[7,8]).isEmpty,"An old departure cannot hide a newly minimising window")
  }
  func testWindowMetadataCachesOnlyBrieflyAndInvalidatesWithoutCachingPositions() {
    var cache=WindowMetadataCache<Set<UInt64>>(),calls=0
    func fetch()->Set<UInt64>? {calls+=1;return [UInt64(calls)]}
    XCTAssertEqual(cache.value(for:1,now:1,fetch:fetch),[1])
    for tick in 1..<9 {XCTAssertEqual(cache.value(for:1,now:1+Double(tick)/120,fetch:fetch),[1])}
    XCTAssertEqual(calls,1)
    XCTAssertEqual(cache.value(for:1,now:1.09,fetch:fetch),[2])
    cache.invalidate();XCTAssertEqual(cache.value(for:1,now:1.1,fetch:fetch),[3])
  }
  func testFastWindowMaskExactlyMatchesBooleanSubtraction() {
    let bounds=CGRect(x:0,y:0,width:960,height:600)
    let frames=[CGRect(x:30,y:220,width:350,height:340),CGRect(x:500,y:200,width:390,height:360)]
    var reference=CGPath(rect:bounds,transform:nil)
    for f in frames {reference=reference.subtracting(CGPath(roundedRect:f,cornerWidth:18,cornerHeight:18,transform:nil))}
    let fast=WindowOcclusionMask.visiblePath(in:bounds,excluding:frames)
    for y in stride(from:0.5,to:600,by:3) {for x in stride(from:0.5,to:960,by:3) {
      XCTAssertEqual(fast.contains(CGPoint(x:x,y:y)),reference.contains(CGPoint(x:x,y:y)))
    }}
  }
  func testProfileMovingWindowMaskWhenRequested() throws {
    guard let output=ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] else {
      throw XCTSkip("Set ATMOS_BENCHMARK_DIR for window-geometry profiling")
    }
    let bounds=CGRect(x:0,y:0,width:960,height:600),iterations=1200
    var timings=[Double](),checksum:CGFloat=0
    for fast in [false,true] {
      let start=CACurrentMediaTime()
      for i in 0..<iterations {
        let frame=CGRect(x:80+sin(Double(i)*0.01)*40,y:200,width:400,height:360)
        let path=fast ? WindowOcclusionMask.visiblePath(in:bounds,excluding:[frame])
          : CGPath(rect:bounds,transform:nil).subtracting(CGPath(roundedRect:frame,cornerWidth:18,cornerHeight:18,transform:nil))
        checksum+=path.boundingBox.width
      }
      timings.append((CACurrentMediaTime()-start)/Double(iterations)*1000)
    }
    XCTAssertGreaterThan(checksum,0)
    try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:["previous_ms_per_update":timings[0],"new_ms_per_update":timings[1],
      "iterations":iterations,"scope":"one moving window compositor mask; identical path geometry"],options:[.prettyPrinted,.sortedKeys])
      .write(to:URL(fileURLWithPath:output).appendingPathComponent("geometry-mask.json"))
  }
  @MainActor func testNativeDisplayLinkCanBeStoppedTwiceAndReleased() throws {
    try autoreleasepool {
      let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
      let view=MTKView(frame:CGRect(x:0,y:0,width:320,height:200),device:device)
      let renderer=try Renderer(device:device,pixelFormat:.bgra8Unorm,
        simulation:SnowSimulation(width:320,height:200,snowfall:.off))
      var clock:NativeFrameClock?=try XCTUnwrap(NativeFrameClock(view:view,renderer:renderer))
      clock?.invalidate();clock?.invalidate()
      XCTAssertTrue(clock?.isPaused == true)
      clock=nil
    }
  }
  private let now = Date()
  private func reading(visibility: Double?) -> WeatherSnapshot {
    var w = WeatherSnapshot(time: now.timeIntervalSince1970, weatherCode: 2,
      temperature: 10, windSpeed: 4, windDirection: 270, precipitation: 0, isDay: 1)
    w.cloudCover = 58; w.visibility = visibility; w.humidity = 98
    w.alerts = [LocalWeatherAlert(id: "fog", summary: "Yellow warning for fog", source: "Met Office",
      detailsURL: URL(string: "https://weather-data.apple.com/alertDetails/test")!, severity: .moderate,
      effective: now.addingTimeInterval(-3600), expires: now.addingTimeInterval(3600))]
    return w
  }
  func testClearLocalVisibilityRemovesFogWithoutHidingTheRegionalWarning() {
    let w = reading(visibility: 25_000), scene = WeatherScene(weather: w, date: now)
    XCTAssertEqual(scene.fog, 0)
    XCTAssertNotEqual(scene.primary, .mist)
    XCTAssertFalse(scene.menuLayers.contains { $0.effect == .mist })
    XCTAssertEqual(scene.dynamics?.haze, 0, "High humidity cannot override clear measured visibility")
    let model = AeolianMenuModel(menu: NSMenu()); model.reading = w; model.activeScene = scene
    XCTAssertEqual(model.overviewAlerts.map(\.summary), ["Yellow warning for fog"])
    XCTAssertEqual(model.presentationSymbol, "cloud.sun", "Partly cloudy must not use a bare sun")
  }
  func testFogIconMatchesTheActualSceneAndDensityFollowsLocalVisibility() {
    let clear = WeatherScene(weather: reading(visibility: 25_000), date: now)
    let hazy = WeatherScene(weather: reading(visibility: 8_000), date: now)
    let foggy = WeatherScene(weather: reading(visibility: 500), date: now)
    XCTAssertEqual(clear.fog, 0); XCTAssertGreaterThan(hazy.fog, 0); XCTAssertLessThan(hazy.fog, 0.15)
    XCTAssertGreaterThan(foggy.fog, hazy.fog)
    let model = AeolianMenuModel(menu: NSMenu()); model.reading = reading(visibility: 500); model.activeScene = foggy
    XCTAssertEqual(model.presentationEffect, .mist); XCTAssertEqual(model.presentationSymbol, "cloud.fog")
    XCTAssertEqual(WeatherScene(weather: reading(visibility: nil), date: now).fog, 0.72, accuracy: 0.001)
  }
  func testOpenSkyFogExtendsHigherWithoutInventingClouds() {
    func height(cover: Float) -> Float {
      let sim = WeatherSimulation(size: SIMD2(960,600), seed: 8)
      sim.setEffect(.mist); sim.scene = WeatherScene(primary: .mist); sim.scene.fog = 0.72
      sim.scene.manualCloudCover = cover
      for _ in 0..<600 { sim.step(dt: 1/60, cursor: SIMD2(-1000,-1000)) }
      return sim.decorations.first { $0.motion.w == 15 }?.rect.w ?? 0
    }
    XCTAssertGreaterThan(height(cover: 0), 600)
    XCTAssertGreaterThan(height(cover: 0), height(cover: 1) + 150)
  }
  func testStaticNativeFogReusesItsLightFieldButGeometryAndPixelsInvalidateIt() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), queue = try XCTUnwrap(device.makeCommandQueue())
    func texture() throws -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,width:320,height:200,mipmapped:false)
      d.usage = [.shaderRead,.renderTarget]; return try XCTUnwrap(device.makeTexture(descriptor:d))
    }
    let bloom = try FogBloom(device:device,format:.rgba8Unorm), source = try texture(), output = try texture()
    var pixels = [UInt8](repeating: 0,count:320*200*4)
    source.replace(region:MTLRegionMake2D(0,0,320,200),mipmapLevel:0,withBytes:&pixels,bytesPerRow:1280)
    func prepare(x:Float,capture:Double) throws {
      _ = bloom.scenePass(for:output,includesScene:false)
      let command = try XCTUnwrap(queue.makeCommandBuffer())
      bloom.prepare(desktop:source,rect:SIMD4(0,0,1,1),size:SIMD2(320,200),windows:[SIMD4(x,40,x+100,160)],
        command:command,windowIDs:[1],capturedAt:capture,now:100,geometrySynchronized:true)
      command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
    }
    try prepare(x:20,capture:100);let updates=bloom.fieldUpdates
    for _ in 0..<120 {try prepare(x:20,capture:100)}
    XCTAssertEqual(bloom.fieldUpdates,updates)
    try prepare(x:30,capture:100);XCTAssertEqual(bloom.fieldUpdates,updates+1)
    try prepare(x:30,capture:101);XCTAssertEqual(bloom.fieldUpdates,updates+2)
    XCTAssertEqual(bloom.scene?.width,1,"No full-screen intermediate is needed for a purely native background")
  }
}
