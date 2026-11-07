import AppKit
import Metal
import QuartzCore
import XCTest
@testable import Atmos

final class NativeAtmosphere58Tests: XCTestCase {
  private func texture(_ device: MTLDevice) throws -> MTLTexture {
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:960,height:600,mipmapped:false)
    descriptor.usage=[.shaderRead,.renderTarget]
    return try XCTUnwrap(device.makeTexture(descriptor:descriptor))
  }
  private func pass(_ target: MTLTexture) -> MTLRenderPassDescriptor {
    let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
    pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
    return pass
  }
  private func bytes(_ texture: MTLTexture) -> [UInt8] {
    var output=[UInt8](repeating:0,count:960*600*4)
    texture.getBytes(&output,bytesPerRow:3840,from:MTLRegionMake2D(0,0,960,600),mipmapLevel:0)
    return output
  }
  func testBackgroundAtmosphereHasNoRectangleCutoutsDuringWindowAnimations() throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("Metal unavailable")}
    let queue=try XCTUnwrap(device.makeCommandQueue()),target=try texture(device)
    for effect in [WeatherEffect.mist,.clouds] {
      let renderer=try WeatherRenderer(device:device,format:.rgba8Unorm,size:SIMD2(960,600),seed:6)
      renderer.setEffect(effect)
      for _ in 0..<1200 {renderer.simulation.step(dt:1/120,cursor:SIMD2(-1000,-1000))}
      var reference:[UInt8]?
      for windows:[SIMD4<Float>] in [[],[SIMD4(180,150,780,500)],[SIMD4(400,40,700,180)]] {
        renderer.windowOccluders=windows
        renderer.prepare(light:SIMD3(repeating:1))
        let command=try XCTUnwrap(queue.makeCommandBuffer())
        let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass(target)))
        renderer.encodeAtmosphere(with:encoder,includeGround:true,placement:.nativeBackground)
        encoder.endEncoding();command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
        let pixels=bytes(target)
        if let reference {XCTAssertEqual(pixels,reference,"Native background cannot retain, move or snap a rectangular hole")}
        else {reference=pixels;XCTAssertGreaterThan(pixels.reduce(0){$0+Int($1)},100_000)}
      }
    }
  }
  func testCentredTransformsKeepTheVisualCentrePinnedForAppKitAndDefaultAnchors() {
    let bounds=CGRect(x:0,y:0,width:520,height:630)
    for anchor in [CGPoint.zero,CGPoint(x:0.5,y:0.5),CGPoint(x:0.25,y:0.8)] {
      for scale:CGFloat in [0.96,0.965,1,1.005,1.006] {
        let relativeCentre=CGPoint(x:bounds.width*(0.5-anchor.x),y:bounds.height*(0.5-anchor.y))
        let transform=AtmosPanelPresentation.centeredScale(scale,bounds:bounds,anchor:anchor)
        let actual=relativeCentre.applying(CATransform3DGetAffineTransform(transform))
        XCTAssertEqual(actual.x,relativeCentre.x,accuracy:0.00001)
        XCTAssertEqual(actual.y,relativeCentre.y,accuracy:0.00001)
      }
    }
  }
  @MainActor func testPanelsAreAboveEffectsAndProtectedFromTheirOwnOverlays() throws {
    let panel=UpdatePanel();defer{panel.close()}
    panel.show(title:"Atmos is up to date.",detail:"You're using Atmos 0.14.1.",primary:"Done")
    let window=try XCTUnwrap(NSApp.windows.first{$0.title=="Atmos Updates" && $0.isVisible})
    XCTAssertGreaterThan(window.level.rawValue,Int(CGWindowLevelForKey(.mainMenuWindow)))
    XCTAssertTrue(AtmosPanelPresentation.visibleFrames.contains(window.frame))
    let mask=WindowOcclusionMask.visiblePath(in:CGRect(x:0,y:0,width:4000,height:4000),excluding:[window.frame])
    XCTAssertFalse(mask.contains(CGPoint(x:window.frame.midX,y:window.frame.midY)))
  }
  func testDetailedWallpaperIsNotALightSourceButWidgetsAndIconsAre() throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("Metal unavailable")}
    let queue=try XCTUnwrap(device.makeCommandQueue()),source=try texture(device),wallpaper=try texture(device),target=try texture(device)
    let bloom=try FogBloom(device:device,format:.rgba8Unorm)
    var pixels=[UInt8](repeating:255,count:960*600*4)
    for y in 0..<600 {for x in 0..<960 {
      let i=(y*960+x)*4,light=((x/7+y/11)%2)==0
      // Some background pixels exactly match the widget colour. An inverse
      // wallpaper mask would punch their high-frequency pattern into the object.
      pixels[i]=light ? 35:15;pixels[i+1]=light ? 65:45;pixels[i+2]=light ? 150:30
    }}
    wallpaper.replace(region:MTLRegionMake2D(0,0,960,600),mipmapLevel:0,withBytes:&pixels,bytesPerRow:3840)
    var fields=[[UInt8]]()
    for objects in [false,true] {
      if objects {for y in 50..<210 {for x in 100..<350 {
        let i=(y*960+x)*4;pixels[i]=35;pixels[i+1]=65;pixels[i+2]=150
      }}}
      source.replace(region:MTLRegionMake2D(0,0,960,600),mipmapLevel:0,withBytes:&pixels,bytesPerRow:3840)
      let command=try XCTUnwrap(queue.makeCommandBuffer())
      let scene=try XCTUnwrap(bloom.scenePass(for:target))
      try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:scene)).endEncoding()
      bloom.prepare(desktop:source,rect:SIMD4(0,0,1,1),size:SIMD2(960,600),windows:[],command:command,wallpaper:wallpaper)
      let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass(target)))
      bloom.encode(with:encoder,size:SIMD2(960,600),amount:1,windows:[],contents:.light)
      encoder.endEncoding();command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
      fields.append(bytes(target))
    }
    XCTAssertEqual(fields[0].reduce(0){$0+Int($1)},0,"Wallpaper detail must not create a broad luminous wash")
    let edge=(130*960+90)*4
    XCTAssertGreaterThan(fields[1][edge+3],12,"A visible halo must extend outside the widget")
    XCTAssertGreaterThan(fields[1][edge+2],fields[1][edge],"Halo follows the blue widget, not the green wallpaper")
    let centre=(130*960+220)*4
    XCTAssertGreaterThan(fields[1][centre+3],0,"Background light must not contain an inverse silhouette mask")
    XCTAssertLessThanOrEqual(fields[1][centre+3],31,"Widget and icon halos stay subtle, at most 12% opacity")
    var largestStep = 0
    for y in 80..<180 { for x in 130..<320 {
      let i=(y*960+x)*4+3
      largestStep=max(largestStep,abs(Int(fields[1][i])-Int(fields[1][i+4])))
    }}
    XCTAssertLessThanOrEqual(largestStep,2,"Wallpaper detail cannot become a mottled/inverted stencil over desktop objects")
  }
  func testMistAndGlowNeverDrawOverNativeDesktopObjects() throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("Metal unavailable")}
    let renderer=try Renderer(device:device,pixelFormat:.rgba8Unorm,
      simulation:SnowSimulation(width:960,height:600,snowfall:.heavy))
    renderer.setScene(WeatherScene(primary:.mist),calm:false)
    renderer.setIntensity(.heavy)
    for i in 0..<1200 {renderer.step(dt:1/120,cursor:SIMD2(-1000,-1000),now:Double(i)/120)}
    let queue=try XCTUnwrap(device.makeCommandQueue())
    let foreground=try texture(device),background=try texture(device),desktop=try texture(device)
    var pixels=[UInt8](repeating:160,count:960*600*4)
    for i in stride(from:3,to:pixels.count,by:4) {pixels[i]=255}
    desktop.replace(region:MTLRegionMake2D(0,0,960,600),mipmapLevel:0,withBytes:&pixels,bytesPerRow:3840)
    for glow in [false,true] {
      renderer.fogBloomTexture=glow ? desktop:nil
      let command=try XCTUnwrap(queue.makeCommandBuffer())
      renderer.encode(into:command,pass:pass(foreground),scale:1,time:10,backgroundPass:pass(background))
      command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
      XCTAssertTrue(bytes(foreground).allSatisfy{$0==0},"Neither fog wisps nor bloom may filter Dock, widget or icon pixels")
      XCTAssertGreaterThan(bytes(background).reduce(0){$0+Int($1)},100_000,"The beautiful mist must remain visible behind the objects")
    }
    XCTAssertLessThan(OverlayWindow.desktopLevel.rawValue,Int(CGWindowLevelForKey(.desktopIconWindow)))
    XCTAssertLessThan(OverlayWindow.desktopLevel.rawValue,Int(CGWindowLevelForKey(.dockWindow)))
  }

}
