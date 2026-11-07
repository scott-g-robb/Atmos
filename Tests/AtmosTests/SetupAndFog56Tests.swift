import AppKit
import Metal
import XCTest
@testable import Atmos

final class SetupAndFog56Tests: XCTestCase {
  private var appIcon: NSImage {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return NSImage(contentsOf:root.appendingPathComponent("Resources/AppIcon.icon/Assets/Weather.png"))!
  }
  func testSetupRunsOncePerInstalledBuildAndOnlyCompletesAtTheRightStep() {
    let name = "Atmos.setup.test.\(UUID())"
    let store = UserDefaults(suiteName: name)!
    defer { store.removePersistentDomain(forName: name) }
    XCTAssertTrue(SetupProgress.needsPresentation(in: store, release: "0.14.1.56"))
    SetupProgress.complete(in: store, release: "0.14.1.55")
    XCTAssertTrue(SetupProgress.needsPresentation(in: store, release: "0.14.1.56"))
    SetupProgress.complete(in: store, release: "0.14.1.56")
    XCTAssertFalse(SetupProgress.needsPresentation(in: store, release: "0.14.1.56"))
    var progress = SetupProgress()
    progress.openedMenu(); XCTAssertEqual(progress.page, .welcome)
    progress.next(); XCTAssertEqual(progress.page, .permissions)
    progress.back(); XCTAssertEqual(progress.page, .welcome)
    progress.next(); progress.next(); XCTAssertEqual(progress.page, .menuBar)
    progress.back(); XCTAssertEqual(progress.page, .menuBar)
    progress.openedMenu(); XCTAssertEqual(progress.page, .complete)
    var skipped = SetupProgress(); skipped.skip(); XCTAssertEqual(skipped.page, .complete)
  }

  func testFogSeverityControlsOpticalDepthAndOnlyActiveFogWarningsContribute() {
    let now = Date()
    var reading = WeatherSnapshot(time: now.timeIntervalSince1970, weatherCode: 3,
      temperature: 8, windSpeed: 3, windDirection: 270, precipitation: 0, isDay: 0)
    reading.humidity = 100 // Humidity must not flatten all severities to the same opacity.
    func alert(_ severity: LocalWeatherAlert.Severity, start: Double = -30, text: String = "Fog warning") -> LocalWeatherAlert {
      LocalWeatherAlert(id: severity.rawValue, summary: text, source: "Test agency",
        detailsURL: URL(string: "https://example.com/fog")!, severity: severity,
        effective: now.addingTimeInterval(start), expires: now.addingTimeInterval(3600))
    }
    var previous: Float = 0
    for severity in [LocalWeatherAlert.Severity.minor, .moderate, .severe, .extreme] {
      reading.alerts = [alert(severity), alert(.extreme, start: 60), alert(.extreme, text: "Rain warning")]
      let scene = WeatherScene(weather: reading, date: now)
      XCTAssertEqual(scene.fog, severity.fogDensity)
      let sim = WeatherSimulation(size: SIMD2(960, 600), seed: 6)
      sim.setEffect(.mist); sim.scene = scene
      for _ in 0..<1800 { sim.step(dt: 1/120, cursor: SIMD2(-1000,-1000)) }
      XCTAssertEqual(sim.fogAmount, severity.fogDensity, accuracy: 0.002)
      XCTAssertGreaterThan(sim.fogAmount, previous)
      previous = sim.fogAmount
      let before = sim.fogAmount
      sim.scene.fog = LocalWeatherAlert.Severity.minor.fogDensity
      sim.step(dt: 1/120, cursor: SIMD2(-1000,-1000))
      XCTAssertGreaterThan(sim.fogAmount, before * 0.99, "Warning changes must blend, not pop")
    }
    reading.alerts = [alert(.minor), alert(.severe)]
    XCTAssertEqual(WeatherScene(weather: reading, date: now).fog, LocalWeatherAlert.Severity.severe.fogDensity)
  }

  func testVisibleCaptureConsumersShareLiveCaptureWithoutOverridingTheWaterSource() {
    for water in [false,true] { for fog in [false,true] {
      for reflections in [false,true] { for live in [false,true] { for bloom in [false,true] {
        let demand = DesktopCaptureDemand(water: water, fog: fog,
          reflectionsEnabled: reflections, liveReflections: live, bloomEnabled: bloom)
        XCTAssertEqual(demand.live, (water && reflections && live) || (fog && bloom))
        XCTAssertEqual(demand.snapshots, water && reflections && !live)
        XCTAssertEqual(demand.bloom, fog && bloom)
      } } }
    } }
  }

  @MainActor func testSetupScreensHaveWorkingPermissionButtonsAndUnclippedLayouts() throws {
    let permissions = [
      SetupPermission(kind:.location,title:"Location",detail:"Follow the weather where you are, automatically.",symbol:"location",action:"Allow",granted:false),
      SetupPermission(kind:.screen,title:"Screen Recording",detail:"Desktop reflections and colour-matched fog bloom. Images stay on this Mac; no audio.",symbol:"rectangle.on.rectangle",action:"Allow",granted:false),
      SetupPermission(kind:.login,title:"Open at Login · Optional",detail:"A little atmosphere, ready whenever you sign in.",symbol:"arrow.right.circle",action:"Enable",granted:false),
      SetupPermission(kind:.automaticUpdates,title:"Automatic Updates · Optional",detail:"Quietly check, install and reopen Atmos in the background. No update windows.",symbol:"arrow.triangle.2.circlepath",action:"Enable",granted:false),
    ]
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      for page in [SetupProgress.Page.welcome,.permissions] {
        let view=SetupPageView(frame:CGRect(x:0,y:0,width:520,height:page == .permissions ? 630:530),page:page,permissions:permissions,icon:appIcon)
        view.appearance=NSAppearance(named:appearance)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.next.title,"Next")
        XCTAssertEqual(view.previous.title,page == .welcome ? "Skip setup" : "Back")
        if page == .welcome {
          func labels(_ view:NSView)->[NSTextField] {view.subviews.flatMap { ($0 as? NSTextField).map{[$0]} ?? labels($0) }}
          for label in labels(view) {
            let width=label.stringValue.size(withAttributes:[.font:label.font!]).width
            XCTAssertGreaterThanOrEqual(label.bounds.width+1,width,"Welcome copy must stay on one line")
          }
        }
        for (_,button) in view.permissionButtons {
          XCTAssertTrue(button.isEnabled)
          let frame=view.convert(button.bounds,from:button)
          XCTAssertTrue(view.bounds.insetBy(dx:10,dy:10).contains(frame),"Unclipped permission button: \(frame)")
          XCTAssertGreaterThan(frame.minY,view.next.frame.maxY+12)
        }
        if page == .permissions {
          var granted=permissions
          granted[0]=SetupPermission(kind:.location,title:"Location",detail:"",symbol:"location",action:"Allow",granted:true)
          view.update(granted)
          XCTAssertFalse(view.permissionButtons[0].1.isEnabled)
          XCTAssertEqual(view.permissionButtons[0].1.title,"Allowed")
        }
        if let path=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
          try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
          let rep=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
          view.cacheDisplay(in:view.bounds,to:rep)
          try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("setup-\(page)-\(appearance.rawValue).png"))
        }
      }
    }
  }

  func testBloomSpreadsTheSourceColourBeyondItsEdgesAndProtectsWindowContents() throws {
    guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let queue=try XCTUnwrap(device.makeCommandQueue())
    let bloom=try FogBloom(device:device,format:.rgba8Unorm)
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:960,height:600,mipmapped:false)
    descriptor.usage=[.shaderRead,.renderTarget]
    let source=try XCTUnwrap(device.makeTexture(descriptor:descriptor)),target=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    var pixels=[UInt8](repeating:0,count:960*600*4)
    let windows:[SIMD4<Float>]=[SIMD4(240,80,450,350),SIMD4(600,80,810,350)]
    for y in 0..<600 { for x in 0..<960 {
      let i=((599-y)*960+x)*4
      pixels[i+3]=255
      if x>=240 && x<450 && y>=80 && y<350 { pixels[i]=255;pixels[i+1]=80;pixels[i+2]=65 }
      if x>=600 && x<810 && y>=80 && y<350 { pixels[i]=65;pixels[i+1]=255;pixels[i+2]=80 }
    } }
    source.replace(region:MTLRegionMake2D(0,0,960,600),mipmapLevel:0,withBytes:&pixels,bytesPerRow:960*4)
    var fields=[[UInt8]]()
    for amount:Float in [0,0.45,1] {
      let command=try XCTUnwrap(queue.makeCommandBuffer())
      let scene=try XCTUnwrap(bloom.scenePass(for:target))
      try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:scene)).endEncoding()
      bloom.prepare(desktop:source,rect:SIMD4(0,0,1,1),size:SIMD2(960,600),windows:windows,command:command)
      let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
      pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
      let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
      bloom.encode(with:encoder,size:SIMD2(960,600),amount:amount,windows:windows);encoder.endEncoding()
      command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
      var data=[UInt8](repeating:0,count:960*600*4)
      target.getBytes(&data,bytesPerRow:960*4,from:MTLRegionMake2D(0,0,960,600),mipmapLevel:0)
      fields.append(data)
      if let output=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"],amount==1 {
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        var preview=data
        for i in stride(from:0,to:data.count,by:4) {
          let remaining=1-Float(data[i+3])/255
          for channel in 0..<3 {
            preview[i+channel]=UInt8(min(255,Float(data[i+channel])+Float(pixels[i+channel])*remaining))
          }
          preview[i+3]=255
        }
        let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:960,pixelsHigh:600,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:960*4,bitsPerPixel:32)!
        rep.bitmapData!.update(from:preview,count:preview.count)
        try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output).appendingPathComponent("fog-coloured-bloom.png"))
      }
    }
    let red=((599-200)*960+230)*4,green=((599-200)*960+590)*4,inside=((599-200)*960+300)*4
    XCTAssertEqual(fields[0].reduce(0){$0+Int($1)},0)
    XCTAssertGreaterThan(fields[2][red],fields[2][red+1]*2)
    XCTAssertGreaterThan(fields[2][green+1],fields[2][green]*2)
    XCTAssertGreaterThan(fields[2][red+3],fields[1][red+3])
    XCTAssertGreaterThan(fields[1][red+3],0)
    XCTAssertEqual(fields[2][inside+3],0,"Windows retain their sharp, unobscured content")
  }

  @MainActor func testSetupButtonsDriveTheGuideAndTheMenuCompletesItExactlyOnce() throws {
    let controller=WelcomeController()
    controller.appIcon=appIcon
    var completed=0,requests=0
    controller.finished={_ in completed+=1}
    controller.permissions={[
      SetupPermission(kind:.screen,title:"Screen Recording",detail:"Desktop reflections and fog bloom.",symbol:"rectangle.on.rectangle",action:"Allow",granted:false)
    ]}
    controller.requestPermission={_ in requests+=1}
    controller.menuAnchor={CGRect(x:700,y:950,width:24,height:24)}
    controller.show()
    func wait(_ seconds:Double) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
    func page() throws -> SetupPageView {
      try XCTUnwrap(NSApp.windows.compactMap{$0.contentView as? SetupPageView}.first)
    }
    wait(0.4)
    controller.menuOpened();XCTAssertEqual(completed,0)
    try page().next.performClick(nil);wait(0.35)
    XCTAssertEqual(controller.progress.page,.permissions)
    try page().permissionButtons[0].1.performClick(nil)
    XCTAssertEqual(requests,1,"Permission requests must come from the user's button")
    try page().previous.performClick(nil);wait(0.35)
    XCTAssertEqual(controller.progress.page,.welcome)
    try page().next.performClick(nil);wait(0.35)
    try page().next.performClick(nil);wait(0.45)
    XCTAssertEqual(controller.progress.page,.menuBar)
    let guide=try XCTUnwrap(NSApp.windows.first{$0.contentView is MenuBarGuideView && $0.isVisible})
    XCTAssertTrue(guide.ignoresMouseEvents)
    XCTAssertGreaterThan(guide.level.rawValue,NSWindow.Level.statusBar.rawValue)
    XCTAssertEqual(completed,0)
    controller.menuOpened();wait(0.3)
    XCTAssertFalse(guide.isVisible);XCTAssertEqual(completed,1)
    controller.menuOpened();wait(0.1);XCTAssertEqual(completed,1)
  }

  @MainActor func testProfileFogBloomAtNativeResolutionWhenRequested() throws {
    guard let output=ProcessInfo.processInfo.environment["ATMOS_BENCHMARK_DIR"] else {throw XCTSkip("Set ATMOS_BENCHMARK_DIR for fog bloom profiling")}
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("Metal unavailable")}
    let screen=NSScreen.main,scale=Float(screen?.backingScaleFactor ?? 2)
    let size=SIMD2<Float>(Float(screen?.frame.width ?? 1512),Float(screen?.frame.height ?? 982))
    let queue=try XCTUnwrap(device.makeCommandQueue())
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,
      width:Int(size.x*scale),height:Int(size.y*scale),mipmapped:false)
    descriptor.usage=[.shaderRead,.renderTarget]
    let target=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    let backgroundTarget=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    let inputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1280,height:512,mipmapped:false)
    inputDescriptor.usage = .shaderRead
    let desktop=try XCTUnwrap(device.makeTexture(descriptor:inputDescriptor))
    var samples=[UInt8](repeating:220,count:1280*512*4)
    for i in stride(from:3,to:samples.count,by:4){samples[i]=255}
    desktop.replace(region:MTLRegionMake2D(0,0,1280,512),mipmapLevel:0,withBytes:&samples,bytesPerRow:1280*4)
    let renderer=try Renderer(device:device,pixelFormat:.rgba8Unorm,
      simulation:SnowSimulation(width:size.x,height:size.y,snowfall:.heavy))
    renderer.setScene(WeatherScene(primary:.mist,stacked:.leaves,wildlife:.birds),calm:false)
    renderer.setIntensity(.heavy);renderer.contentTop=size.y-28
    renderer.setCoverFrames([SIMD4(size.x*0.1,size.y*0.25,size.x*0.45,size.y*0.8),SIMD4(size.x*0.6,size.y*0.2,size.x*0.9,size.y*0.7)])
    for i in 0..<1200{renderer.step(dt:1/120,cursor:SIMD2(-1000,-1000),now:Double(i)/120)}
    var reports=[[String:Any]]()
    for enabled in [false,true] {
      renderer.fogBloomTexture=enabled ? desktop : nil
      var simulation=[Double](),cpu=[Double](),gpu=[Double]()
      for i in 0..<63 {
        let start=CACurrentMediaTime()
        renderer.step(dt:1/120,cursor:SIMD2(size.x*0.5,size.y*0.3),now:10+Double(i)/120)
        let sim=(CACurrentMediaTime()-start)*1000
        let command=try XCTUnwrap(queue.makeCommandBuffer()),encoded=CACurrentMediaTime()
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        let background=MTLRenderPassDescriptor();background.colorAttachments[0].texture=backgroundTarget
        background.colorAttachments[0].loadAction = .clear;background.colorAttachments[0].storeAction = .store
        background.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        renderer.encode(into:command,pass:pass,scale:scale,time:Float(10+Double(i)/120),backgroundPass:background)
        command.commit();let cost=(CACurrentMediaTime()-encoded)*1000
        command.waitUntilCompleted();XCTAssertNil(command.error)
        if i>=3 {simulation.append(sim);cpu.append(cost);gpu.append(max(0,command.gpuEndTime-command.gpuStartTime)*1000)}
      }
      func stats(_ list:[Double])->[String:Double] {let sorted=list.sorted();return["median":sorted[sorted.count/2],"p95":sorted[Int(Double(sorted.count-1)*0.95)],"maximum":sorted.last!]}
      reports.append(["bloom":enabled,"device":device.name,"resolution":"\(target.width)x\(target.height)",
        "simulation_ms":stats(simulation),"encode_cpu_ms":stats(cpu),"gpu_ms":stats(gpu),
        "combined_ms":stats(simulation.indices.map{simulation[$0]+cpu[$0]+gpu[$0]}),
        "capture":"excluded; static 1280x512 input","scene":"heavy mist, leaves and birds; native background fog and subtle lighting"])
    }
    try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output).appendingPathComponent("fog-bloom-performance.json"))
  }
}
