import AppKit
import Metal
import XCTest
@testable import Atmos

final class Glow57Tests:XCTestCase {
  private let size=SIMD2<Float>(960,600)
  private let windows:[SIMD4<Float>]=[SIMD4(150,220,430,560),SIMD4(530,240,810,560)]
  private func target(_ device:MTLDevice,width:Int=960,height:Int=600) throws -> MTLTexture {
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false)
    descriptor.usage=[.shaderRead,.renderTarget]
    return try XCTUnwrap(device.makeTexture(descriptor:descriptor))
  }
  private func desktop(_ device:MTLDevice) throws -> MTLTexture {
    let texture=try target(device)
    var data=[UInt8](repeating:0,count:960*600*4)
    for y in 0..<600 {for x in 0..<960 {
      var c:SIMD3<UInt8>=SIMD3(12,18,26)
      if x>=150 && x<430 && y>=220 && y<560 {
        c=SIMD3(27,30,34)
        if x<157 || y>552 {c=SIMD3(35,100,205)}
        if x>=423 {c=SIMD3(205,74,30)}
      }
      if x>=530 && x<810 && y>=240 && y<560 {c=SIMD3(30,34,38)}
      if x>=220 && x<650 && y>=10 && y<82 {c=SIMD3(32,36,40)}
      for (left,colour):(Int,SIMD3<UInt8>) in [(290,SIMD3(220,55,40)),(380,SIMD3(45,210,65)),(470,SIMD3(45,95,220))] {
        if x>=left && x<left+48 && y>=26 && y<74 {c=colour}
      }
      let i=((599-y)*960+x)*4
      data[i]=c.x;data[i+1]=c.y;data[i+2]=c.z;data[i+3]=255
    }}
    texture.replace(region:MTLRegionMake2D(0,0,960,600),mipmapLevel:0,withBytes:&data,bytesPerRow:960*4)
    return texture
  }
  private func bytes(_ texture:MTLTexture)->[UInt8] {
    var result=[UInt8](repeating:0,count:texture.width*texture.height*4)
    texture.getBytes(&result,bytesPerRow:texture.width*4,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)
    return result
  }
  private func pass(_ texture:MTLTexture)->MTLRenderPassDescriptor {
    let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture
    pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
    return pass
  }
  func testDarkChromeUpperWindowEdgesAndDockIconsAllEmitTheirOwnColours() throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("Metal unavailable")}
    let bloom=try FogBloom(device:device,format:.rgba8Unorm),source=try desktop(device),output=try target(device)
    let command=try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    let scene=try XCTUnwrap(bloom.scenePass(for:output))
    scene.colorAttachments[0].clearColor=MTLClearColorMake(0.20,0.21,0.22,0.35)
    try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:scene)).endEncoding()
    bloom.prepare(desktop:source,rect:SIMD4(0,0,1,1),size:size,windows:windows,command:command)
    let light=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass(output)))
    bloom.encode(with:light,size:size,amount:0.72,windows:windows,contents:.light);light.endEncoding()
    command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
    let data=bytes(output)
    func pixel(_ x:Int,_ y:Int)->[UInt8] {let i=((599-y)*960+x)*4;return Array(data[i..<i+4])}
    for (x,y) in [(140,420),(440,420),(280,568),(520,420),(670,568)] {
      XCTAssertGreaterThan(pixel(x,y)[3],12,"Clearly visible halo at \(x),\(y), including dark and high window edges")
    }
    XCTAssertGreaterThan(Int(pixel(140,420)[2]),Int(pixel(140,420)[0])*2)
    XCTAssertGreaterThan(Int(pixel(440,420)[0]),Int(pixel(440,420)[2])*2)
    XCTAssertGreaterThan(Int(pixel(280,568)[2]),Int(pixel(280,568)[0])*2)
    XCTAssertEqual(pixel(280,400)[3],0,"Window content remains untouched")
    let red=pixel(314,88),green=pixel(404,88),blue=pixel(494,88)
    for c in [red,green,blue] {XCTAssertGreaterThan(c[3],8,"Dock light must escape above its shelf")}
    XCTAssertGreaterThan(red[0],red[1]);XCTAssertGreaterThan(green[1],green[0]);XCTAssertGreaterThan(blue[2],blue[0])
    if let directory=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
      try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
      let backdrop=bytes(source);var preview=data
      for i in stride(from:0,to:preview.count,by:4) {
        for c in 0..<3 {preview[i+c]=UInt8(min(255,Float(data[i+c])+Float(backdrop[i+c])*(1-Float(data[i+3])/255)))}
        preview[i+3]=255
      }
      let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:960,pixelsHigh:600,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:3840,bitsPerPixel:32)!
      rep.bitmapData!.update(from:preview,count:preview.count)
      try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:directory).appendingPathComponent("window-and-dock-glow.png"))
    }
  }
  func testMissingCapturedWindowDoesNotLeaveAGhostAtStaleGeometry() throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("Metal unavailable")}
    let bloom=try FogBloom(device:device,format:.rgba8Unorm),source=try target(device),output=try target(device)
    var pixels=[UInt8](repeating:32,count:960*600*4)
    for i in stride(from:3,to:pixels.count,by:4){pixels[i]=255}
    source.replace(region:MTLRegionMake2D(0,0,960,600),mipmapLevel:0,withBytes:&pixels,bytesPerRow:3840)
    let command=try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    let scene=try XCTUnwrap(bloom.scenePass(for:output))
    try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:scene)).endEncoding()
    bloom.prepare(desktop:source,rect:SIMD4(0,0,1,1),size:size,windows:windows,command:command)
    let light=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass(output)))
    bloom.encode(with:light,size:size,amount:1,windows:windows,contents:.light);light.endEncoding()
    command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
    XCTAssertEqual(bytes(output).reduce(0){$0+Int($1)},0,"A vanished captured edge must stop emitting immediately, even before window geometry updates")
  }
  func testSeparateLightAndScenePassesMatchCombinedCompositing() throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("Metal unavailable")}
    let bloom=try FogBloom(device:device,format:.rgba8Unorm),source=try desktop(device)
    let combined=try target(device),sceneOutput=try target(device),lightOutput=try target(device)
    let command=try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    let scene=try XCTUnwrap(bloom.scenePass(for:combined))
    scene.colorAttachments[0].clearColor=MTLClearColorMake(0.1,0.12,0.15,0.25)
    try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:scene)).endEncoding()
    bloom.prepare(desktop:source,rect:SIMD4(0,0,1,1),size:size,windows:windows,command:command)
    for (texture,contents) in [(combined,FogBloom.Contents.combined),(sceneOutput,.scene),(lightOutput,.light)] {
      let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass(texture)))
      bloom.encode(with:encoder,size:size,amount:0.72,windows:windows,contents:contents);encoder.endEncoding()
    }
    command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
    let c=bytes(combined),s=bytes(sceneOutput),l=bytes(lightOutput)
    var maximum=0
    for i in stride(from:0,to:c.count,by:4) {for channel in 0..<4 {
      let expected=min(255,Float(l[i+channel])+Float(s[i+channel])*(1-Float(l[i+3])/255))
      maximum=max(maximum,abs(Int(c[i+channel])-Int(expected.rounded())))
    }}
    XCTAssertLessThanOrEqual(maximum,1,"The dedicated layer must preserve the same glow and scene")
  }
  func testSetupStaysPausedUntilTheFinalClickAndSkipPreservesExistingLiveChoice() {
    var setup=SetupProgress()
    XCTAssertTrue(setup.isPaused);XCTAssertNil(setup.completion)
    setup.openedMenu();XCTAssertTrue(setup.isPaused)
    setup.next();XCTAssertTrue(setup.isPaused)
    setup.next();XCTAssertTrue(setup.isPaused,"The arrow is still part of setup")
    setup.openedMenu();XCTAssertFalse(setup.isPaused);XCTAssertEqual(setup.completion,.menuBar)
    for previous in [false,true] {for granted in [false,true] {
      XCTAssertEqual(SetupProgress.liveWeather(after:.skipped,previous:previous,locationGranted:granted),previous)
      XCTAssertEqual(SetupProgress.liveWeather(after:.menuBar,previous:previous,locationGranted:granted),granted)
    }}
  }
  func testAutomaticRelaunchBypassesSetupOnlyForTheMatchingInstalledBuildAndOnce() {
    let name="Atmos.auto.test.\(UUID())"
    let defaults=UserDefaults(suiteName:name)!
    defer {defaults.removePersistentDomain(forName:name)}
    defaults.set(true,forKey:"automaticUpdates")
    SetupProgress.recordAutomaticRelaunch(release:"0.14.2.58",path:"/Applications/Atmos.app",in:defaults)
    XCTAssertFalse(SetupProgress.consumeAutomaticRelaunch(in:defaults,release:"0.14.2.58",path:"/Applications/Atmos.app",arguments:[]))
    SetupProgress.recordAutomaticRelaunch(release:"0.14.2.58",path:"/Applications/Atmos.app",in:defaults)
    XCTAssertTrue(SetupProgress.consumeAutomaticRelaunch(in:defaults,release:"0.14.2.58",path:"/Applications/Atmos.app",arguments:["--atmos-auto-update"]))
    XCTAssertFalse(SetupProgress.needsPresentation(in:defaults,release:"0.14.2.58"))
    XCTAssertFalse(SetupProgress.consumeAutomaticRelaunch(in:defaults,release:"0.14.2.58",path:"/Applications/Atmos.app",arguments:["--atmos-auto-update"]))
    SetupProgress.recordAutomaticRelaunch(release:"0.14.3.59",path:"/Applications/Atmos.app",in:defaults)
    XCTAssertFalse(SetupProgress.consumeAutomaticRelaunch(in:defaults,release:"0.14.2.58",path:"/Applications/Atmos.app",arguments:["--atmos-auto-update"]))
  }
}
