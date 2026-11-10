import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import Aeolian

/// Staged screenshots use the shipping menu and Metal effects, with example data
/// and no personal desktop contents. Exported at Apple's 1440 × 900 Mac size.
final class AppStoreMediaTests: XCTestCase {
  @MainActor func testExportNativeStoreScreenshots() throws {
    guard let output=ProcessInfo.processInfo.environment["AEOLIAN_APP_STORE_MEDIA"] else {
      throw XCTSkip("Enable AEOLIAN_APP_STORE_MEDIA to export the product screenshots")
    }
    _=NSApplication.shared
    let defaults=UserDefaults.standard
    let keys=["liveWeather","weatherEffect","seasonalDrift","wildlifeEffect","manualCloudCoverage","weatherUnits","temperatureUnits","windUnits","rainfallUnits","visibilityUnits"]
    let saved=keys.map{defaults.object(forKey:$0)}
    defer {for (key,value) in zip(keys,saved) {if let value {defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}}}
    let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let app=AppDelegate(),item=app.makeStatusItem()
    defer {NSStatusBar.system.removeStatusItem(item);app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))}
    app.menuNeedsUpdate(try XCTUnwrap(item.menu))
    let suite="Aeolian.StoreMedia.\(UUID())",store=UserDefaults(suiteName:suite)!
    defer {store.removePersistentDomain(forName:suite)}
    let library=AtmosphereLibrary(defaults:store)
    library.save(AtmospherePreset(name:"Rainy afternoon",weather:.rain,drift:.leaves,wildlife:.birds,intensity:2,wind:12))
    library.save(AtmospherePreset(name:"Spring breeze",weather:.none,drift:.cherryBlossoms,wildlife:.butterflies,intensity:1,wind:5))
    let model=AeolianMenuModel(menu:try XCTUnwrap(item.menu),library:library)
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    model.appArtwork=NSImage(contentsOf:root.appendingPathComponent("Resources/AppIcon.icon/Assets/Weather.png"))
    model.storeUpdates=true;model.updateItem?.title="App Store Updates…"
    model.place="Edinburgh";model.reading=WeatherSnapshot(time:Date().timeIntervalSince1970,weatherCode:51,temperature:12,windSpeed:14,windDirection:270,precipitation:0.2,isDay:1)
    model.reading?.cloudCover=68;model.reading?.apparentTemperature=11
    model.reading?.highTemperature=15;model.reading?.lowTemperature=7
    model.activeScene=model.reading.map{WeatherScene(weather:$0)}
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
    for (name,page,live,title,subtitle,effect) in [
      ("01-live-weather","",true,"A little atmosphere\non your desktop.","Your local sky. Beautifully alive.",WeatherEffect.rain),
      ("02-your-atmospheres","",false,"Make room\nfor a little wonder.","Weather, seasonal drift and wildlife. Your way.",WeatherEffect.snow),
      ("03-personalise","settings",false,"Quietly at home\non your Mac.","Native controls. A desktop that feels yours.",WeatherEffect.mist)] {
      Preferences.liveWeather=live;Preferences.weatherUnits = .metric
      let view=NSHostingView(rootView:AeolianMenuView(model:model,page:page,category:0).frame(width:320,height:520))
      view.frame=CGRect(x:0,y:0,width:320,height:520)
      let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=view;window.orderFront(nil)
      RunLoop.main.run(until:Date().addingTimeInterval(0.3));view.layoutSubtreeIfNeeded()
      let menu=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:menu)
      let weather=try WeatherRenderer(device:device,format:.rgba8Unorm,size:SIMD2(1440,900),seed:74)
      weather.setEffect(effect);weather.simulation.intensity = .steady
      weather.simulation.accumulates=false;weather.simulation.wind = -18
      for _ in 0..<480 {weather.simulation.step(dt:1/60,cursor:SIMD2(-1000,-1000))}
      let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1440,height:900,mipmapped:false)
      descriptor.usage=[.renderTarget,.shaderRead];descriptor.storageMode=device.hasUnifiedMemory ? .shared:.managed
      let texture=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
      let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture
      pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
      let command=try XCTUnwrap(queue.makeCommandBuffer()),encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
      weather.encode(with:encoder,light:SIMD3(repeating:0.75));encoder.endEncoding()
      if !device.hasUnifiedMemory {let blit=try XCTUnwrap(command.makeBlitCommandEncoder());blit.synchronize(resource:texture);blit.endEncoding()}
      command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
      let weatherPixels=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1440,pixelsHigh:900,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:1440*4,bitsPerPixel:32))
      texture.getBytes(weatherPixels.bitmapData!,bytesPerRow:1440*4,from:MTLRegionMake2D(0,0,1440,900),mipmapLevel:0)
      let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1440,pixelsHigh:900,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:1440*4,bitsPerPixel:32))
      let graphics=try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
      NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
      let bounds=CGRect(x:0,y:0,width:1440,height:900)
      NSGradient(colors:[NSColor(srgbRed:0.035,green:0.075,blue:0.13,alpha:1),NSColor(srgbRed:0.15,green:0.25,blue:0.32,alpha:1)])!.draw(in:bounds,angle:35)
      NSImage(cgImage:try XCTUnwrap(weatherPixels.cgImage),size:bounds.size).draw(in:bounds)
      let style=NSMutableParagraphStyle();style.lineSpacing=3
      (title as NSString).draw(in:CGRect(x:82,y:340,width:850,height:220),withAttributes:[.font:NSFont.systemFont(ofSize:68,weight:.medium),.foregroundColor:NSColor.white,.paragraphStyle:style])
      (subtitle as NSString).draw(at:CGPoint(x:86,y:297),withAttributes:[.font:NSFont.systemFont(ofSize:23,weight:.regular),.foregroundColor:NSColor.white.withAlphaComponent(0.78)])
      ("Aeolian" as NSString).draw(at:CGPoint(x:86,y:741),withAttributes:[.font:NSFont.systemFont(ofSize:30,weight:.semibold),.foregroundColor:NSColor.white])
      ("Free for macOS 14+ · Apple silicon & Intel" as NSString).draw(at:CGPoint(x:86,y:97),withAttributes:[.font:NSFont.systemFont(ofSize:16),.foregroundColor:NSColor.white.withAlphaComponent(0.65)])
      NSImage(cgImage:try XCTUnwrap(menu.cgImage),size:CGSize(width:320,height:520)).draw(in:CGRect(x:1016,y:126,width:352,height:572))
      if live {("Example weather shown" as NSString).draw(at:CGPoint(x:1016,y:93),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white.withAlphaComponent(0.6)])}
      NSGraphicsContext.restoreGraphicsState()
      let opaque=try XCTUnwrap(CGContext(data:nil,width:1440,height:900,bitsPerComponent:8,bytesPerRow:1440*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
      opaque.draw(try XCTUnwrap(bitmap.cgImage),in:bounds)
      let flattened=NSBitmapImageRep(cgImage:try XCTUnwrap(opaque.makeImage()))
      XCTAssertFalse(flattened.hasAlpha)
      XCTAssertGreaterThan(flattened.bitmapData![100*flattened.bytesPerRow+100*4],0)
      try XCTUnwrap(flattened.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(name+".png"))
      window.orderOut(nil);window.contentView=nil;window.close()
    }
  }
}
