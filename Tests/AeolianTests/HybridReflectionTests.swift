import AppKit
import CoreVideo
import Darwin
import Metal
import XCTest
@testable import Aeolian

final class HybridReflectionTests: XCTestCase {
  private func solid(_ colour: SIMD3<UInt8>, size: CGSize) throws -> CVPixelBuffer {
    var output: CVPixelBuffer?
    CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
    let buffer = try XCTUnwrap(output)
    CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<Int(size.height) { for x in 0..<Int(size.width) {
      let i=y*CVPixelBufferGetBytesPerRow(buffer)+x*4
      bytes[i]=colour.z;bytes[i+1]=colour.y;bytes[i+2]=colour.x;bytes[i+3]=255
    }}
    return buffer
  }
  private func pixel(_ cache: WindowReflections, device: MTLDevice, at time: Double) throws -> [UInt8] {
    let command=try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    cache.encode(into:command,now:time)
    let texture=try XCTUnwrap(cache.texture), row=(texture.width*4+255) & ~255
    let buffer=try XCTUnwrap(device.makeBuffer(length:row*texture.height,options:.storageModeShared))
    let blit=try XCTUnwrap(command.makeBlitCommandEncoder())
    blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(),sourceSize:.init(width:texture.width,height:texture.height,depth:1),
      to:buffer,destinationOffset:0,destinationBytesPerRow:row,destinationBytesPerImage:row*texture.height)
    blit.endEncoding();command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
    return Array(UnsafeBufferPointer(start:buffer.contents().advanced(by:row*10+40).assumingMemoryBound(to:UInt8.self),count:4))
  }
  @MainActor func testTenSecondCadenceAndExplicitContentRefreshCrossfadeOnGPU() async throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    var captures=0, blue=false
    let cache=try WindowReflections(device:device) { [self] _,size in
      captures+=1;return try solid(blue ? SIMD3(0,0,255):SIMD3(255,0,0),size:size)
    }
    let windows=[ReflectionWindow(id:1,frame:CGRect(x:0,y:0,width:80,height:80),alpha:1)]
    let size=CGSize(width:128,height:128)
    cache.update(windows:windows,size:size,wallpaper:nil,now:10);await cache.captureTask?.value
    XCTAssertEqual(try pixel(cache,device:device,at:10).prefix(3),[255,0,0])
    cache.update(windows:windows,size:size,wallpaper:nil,now:19.9);await cache.captureTask?.value
    XCTAssertEqual(captures,1,"The rendering clock does not refresh screenshot pixels")
    blue=true;cache.invalidateContents([1])
    cache.update(windows:windows,size:size,wallpaper:nil,now:20);await cache.captureTask?.value
    XCTAssertEqual(captures,2)
    XCTAssertEqual(try pixel(cache,device:device,at:20).prefix(3),[255,0,0])
    let middle=try pixel(cache,device:device,at:20.075)
    XCTAssertEqual(Int(middle[0]),128,accuracy:2);XCTAssertEqual(Int(middle[2]),128,accuracy:2)
    XCTAssertEqual(try pixel(cache,device:device,at:20.16).prefix(3),[0,0,255])
    let count=cache.compositeCount
    _=try pixel(cache,device:device,at:21)
    XCTAssertEqual(cache.compositeCount,count,"A static cache skips even its compositing pass")
  }
  func testOnlyVisibleRelevantWindowsAreSelectedWithTransparentOccludersRespected() {
    let front=ReflectionWindow(id:1,frame:CGRect(x:0,y:0,width:100,height:100),alpha:1)
    let hidden=ReflectionWindow(id:2,frame:CGRect(x:10,y:10,width:30,height:30),alpha:1)
    let outside=ReflectionWindow(id:3,frame:CGRect(x:300,y:300,width:30,height:30),alpha:1)
    let other=ReflectionWindow(id:4,frame:CGRect(x:120,y:0,width:50,height:50),alpha:1)
    let size=CGSize(width:200,height:200)
    XCTAssertEqual(WindowReflections.visibleWindows([front,hidden,outside,other],size:size,regions:nil).map(\.id),[1,4])
    XCTAssertEqual(WindowReflections.visibleWindows([front,hidden,other],size:size,regions:[other.frame]).map(\.id),[4])
    let glass=ReflectionWindow(id:1,frame:front.frame,alpha:0.5)
    XCTAssertEqual(WindowReflections.visibleWindows([glass,hidden],size:size,regions:nil).count,2)
  }
  @MainActor func testFailedScreenshotsRetainGoodPixelsAndBackOff() async throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    var calls=0, fail=false
    let cache=try WindowReflections(device:device) { [self] _,size in
      calls+=1;if fail {throw URLError(.resourceUnavailable)}
      return try solid(SIMD3(255,0,0),size:size)
    }
    let windows=[ReflectionWindow(id:1,frame:CGRect(x:0,y:0,width:80,height:80),alpha:1)]
    let size=CGSize(width:128,height:128)
    cache.update(windows:windows,size:size,wallpaper:nil,now:10);await cache.captureTask?.value
    fail=true
    cache.update(windows:windows,size:size,wallpaper:nil,now:21);await cache.captureTask?.value
    XCTAssertEqual(calls,2);XCTAssertEqual(try pixel(cache,device:device,at:21).prefix(3),[255,0,0])
    for i in 0..<120 {cache.update(windows:windows,size:size,wallpaper:nil,now:21+Double(i)/120)}
    XCTAssertEqual(calls,2)
    cache.stop();XCTAssertNil(cache.texture)
  }
  func testSaverPresentationCanReducePowerWithoutCappingNormalNativeRefresh() throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer=try Renderer(device:device,pixelFormat:.rgba8Unorm,simulation:SnowSimulation(width:200,height:200,snowfall:.steady))
    renderer.nativeFrameRate=120;renderer.budget = .full;XCTAssertEqual(renderer.presentationFrameRate,120)
    renderer.budget = .saver;XCTAssertEqual(renderer.presentationFrameRate,60)
  }
  @MainActor func testProfileScreenshotCacheWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["ATMOS_CAPTURE_BENCHMARK_DIR"] else {
      throw XCTSkip("Set ATMOS_CAPTURE_BENCHMARK_DIR for isolated screenshot-cache profiling")
    }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), queue = try XCTUnwrap(device.makeCommandQueue())
    var captures = 0
    let cache = try WindowReflections(device: device) { _, size in
      captures += 1
      var buffer: CVPixelBuffer?
      CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
      return buffer
    }
    defer { cache.stop() }
    func cpu() -> Double {
      var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
      return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
    }
    let start = CACurrentMediaTime(), initialCPU = cpu()
    var gpu = 0.0, encoding = 0.0
    for tick in 0..<1440 {
      let now = CACurrentMediaTime()
      let windows = (0..<8).map { i in ReflectionWindow(id: UInt32(i+1),
        frame: CGRect(x: 20+(i%4)*230+Int(sin((now-start)*1.7)*12), y: 30+(i/4)*260, width: 180, height: 160), alpha: 1) }
      cache.update(windows: windows, size: CGSize(width: 960, height: 600), wallpaper: nil, now: now)
      let command = try XCTUnwrap(queue.makeCommandBuffer()), began = CACurrentMediaTime()
      cache.encode(into: command)
      encoding += CACurrentMediaTime()-began
      command.commit(); command.waitUntilCompleted()
      gpu += max(0, command.gpuEndTime-command.gpuStartTime)
      let delay = start+Double(tick+1)/120-CACurrentMediaTime()
      if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay*1e9)) }
    }
    let elapsed = CACurrentMediaTime()-start
    let report: [String: Any] = ["duration_seconds": elapsed, "captures": captures, "windows": 8,
      "ticks": 1440, "process_cpu_percent": (cpu()-initialCPU)/elapsed*100,
      "gpu_ms_per_tick": gpu/1440*1000, "encode_ms_per_tick": encoding/1440*1000,
      "allocated_gpu_bytes": device.currentAllocatedSize,
      "scope": "120 Hz geometry/compositing and cache scheduler; synthetic IOSurface screenshots; capture service and WindowServer excluded"]
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: output).appendingPathComponent("snapshot-cache.json"))
  }
}
