import AppKit
import Metal
import XCTest
@testable import Aeolian

final class Polish60Tests: XCTestCase {
  func testManualReplacementOfTheSameBuildPresentsWelcomeAgain() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("Aeolian-install-\(UUID())")
    let app=directory.appendingPathComponent("Aeolian.app")
    let executable=app.appendingPathComponent("Contents/MacOS/Aeolian")
    try FileManager.default.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:directory)}
    let domain="Aeolian.install.test.\(UUID())"
    let store=UserDefaults(suiteName:domain)!
    defer {store.removePersistentDomain(forName:domain)}
    try Data("same release".utf8).write(to:executable)
    let first=SetupProgress.installationID(at:app)
    SetupProgress.complete(in:store,release:"0.14.1.60",installation:first)
    XCTAssertFalse(SetupProgress.needsPresentation(in:store,release:"0.14.1.60",installation:first))
    XCTAssertEqual(first,SetupProgress.installationID(at:app),"An ordinary relaunch is the same installation")
    try Data("same release".utf8).write(to:executable,options:.atomic)
    let replacement=SetupProgress.installationID(at:app)
    XCTAssertNotEqual(first,replacement)
    XCTAssertTrue(SetupProgress.needsPresentation(in:store,release:"0.14.1.60",installation:replacement))
    store.set(true,forKey:"automaticUpdates")
    SetupProgress.recordAutomaticRelaunch(release:"0.14.1.60",path:app.path,in:store)
    XCTAssertTrue(SetupProgress.consumeAutomaticRelaunch(in:store,release:"0.14.1.60",path:app.path,
      arguments:["--atmos-auto-update"],installation:replacement))
    XCTAssertFalse(SetupProgress.needsPresentation(in:store,release:"0.14.1.60",installation:replacement))
    try Data("same release".utf8).write(to:executable,options:.atomic)
    XCTAssertTrue(SetupProgress.needsPresentation(in:store,release:"0.14.1.60",installation:SetupProgress.installationID(at:app)),
      "An earlier automatic update must not suppress a later manual installation")
    store.removePersistentDomain(forName:domain)
  }

  @MainActor func testMainMenuStaysCompactAndManualControlsStayAvailable() throws {
    _=NSApplication.shared
    let old=Preferences.liveWeather
    defer {Preferences.liveWeather=old}
    Preferences.liveWeather=true
    let app=AppDelegate(),item=app.makeStatusItem()
    defer {NSStatusBar.system.removeStatusItem(item)}
    let menu=try XCTUnwrap(item.menu)
    app.menuWillOpen(menu)
    XCTAssertLessThanOrEqual(menu.items.filter{ !$0.isSeparatorItem }.count,6)
    XCTAssertTrue(menu.items.allSatisfy{$0.view==nil})
    let manual=try XCTUnwrap(menu.items.first{$0.title=="Manual Effects"}?.submenu)
    let controls=manual.items.filter{$0.view is WindSlider || $0.view is SnowfallSlider}
    XCTAssertEqual(controls.count,2)
    XCTAssertTrue(controls.allSatisfy(\.isHidden),"Live Weather does not need manual sliders")
    Preferences.liveWeather=false;app.menuWillOpen(menu)
    XCTAssertTrue(controls.allSatisfy{!$0.isHidden})
    let settings=try XCTUnwrap(menu.items.first{$0.title=="Settings"}?.submenu)
    XCTAssertNotNil(settings.items.first{$0.title=="Surfaces"}?.submenu)
    let settingsIndex=try XCTUnwrap(menu.items.firstIndex{$0.title=="Settings"})
    XCTAssertTrue(menu.items[settingsIndex+1].isSeparatorItem)
    XCTAssertEqual(menu.items[settingsIndex+2].title,"Check for Updates…")
  }

  @MainActor func testPermissionTransitionKeepsTextAndWindowCentred() throws {
    let controller=WelcomeController()
    controller.permissions={SetupPermission.Kind.allCases.map {
      SetupPermission(kind:$0,title:"Permission",detail:"A short explanation.",symbol:"checkmark",action:"Allow",granted:false)
    }}
    controller.show()
    func wait(_ seconds:Double){RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
    wait(0.8)
    let window=try XCTUnwrap(NSApp.windows.first{$0.identifier==AeolianPanelPresentation.identifier && $0.isVisible})
    let centre=CGPoint(x:window.frame.midX,y:window.frame.midY)
    let page=try XCTUnwrap(window.contentView as? SetupPageView)
    page.next.performClick(nil)
    func labels(_ view:NSView)->[NSTextField] {
      view.subviews.flatMap{($0 as? NSTextField).map{[$0]} ?? labels($0)}
    }
    for _ in 0..<5 {
      wait(0.04)
      let content=try XCTUnwrap(window.contentView)
      for title in labels(content) where title.stringValue=="Make yourself at home." || title.stringValue=="Thank you for downloading" {
        let frame=content.convert(title.bounds,from:title)
        XCTAssertEqual(frame.midX,content.bounds.midX,accuracy:0.75,"Text must not slide sideways during resizing")
      }
      XCTAssertEqual(window.frame.midX,centre.x,accuracy:0.75)
      XCTAssertEqual(window.frame.midY,centre.y,accuracy:0.75)
    }
    wait(0.1)
    let permissions=try XCTUnwrap(window.contentView as? SetupPageView)
    permissions.previous.performClick(nil);wait(0.3)
    try XCTUnwrap(window.contentView as? SetupPageView).previous.performClick(nil);wait(0.3)
  }

  func testAtmosphericEntranceIsGradualAndEased() {
    XCTAssertEqual(WeatherRenderer.entranceOpacity(age:0,atmospheric:true),0)
    XCTAssertLessThan(WeatherRenderer.entranceOpacity(age:0.1,atmospheric:true),0.03)
    XCTAssertEqual(WeatherRenderer.entranceOpacity(age:0.7,atmospheric:true),0.5,accuracy:0.001)
    XCTAssertEqual(WeatherRenderer.entranceOpacity(age:1.4,atmospheric:true),1)
    XCTAssertLessThan(WeatherRenderer.entranceOpacity(age:0.05,atmospheric:false),0.02)
  }

  func testManualDiskImageInstallerWaitsForEveryOldProcessAndRelaunchesManually() async throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("Aeolian-manual-\(UUID())")
    let source=directory.appendingPathComponent("Source.app"),destination=directory.appendingPathComponent("Current.app")
    let executable=source.appendingPathComponent("Contents/MacOS/Fixture"),receipt=directory.appendingPathComponent("opened")
    try FileManager.default.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:directory)}
    let code=directory.appendingPathComponent("fixture.c")
    let escaped=receipt.path.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
    try "#include <stdio.h>\nint main(int argc,char**argv){FILE*f=fopen(\"\(escaped)\",\"w\");if(f){fputs(\"manual\",f);for(int i=1;i<argc;i++)fputs(argv[i],f);fclose(f);}return 0;}".write(to:code,atomically:true,encoding:.utf8)
    _=try await UpdateFiles.run("/usr/bin/clang",[code.path,"-o",executable.path])
    let info:[String:Any]=["CFBundleIdentifier":"dev.atmos.ManualFixture","CFBundleExecutable":"Fixture",
      "CFBundlePackageType":"APPL","CFBundleShortVersionString":"2.0.0","CFBundleVersion":"2","LSBackgroundOnly":true]
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:source.appendingPathComponent("Contents/Info.plist"))
    _=try await UpdateFiles.run("/usr/bin/codesign",["--force","--sign","-",source.path])
    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
    let marker=destination.appendingPathComponent("old-app")
    try Data("old".utf8).write(to:marker)
    let first=Process(),second=Process()
    for process in [first,second] {process.executableURL=URL(fileURLWithPath:"/bin/sleep");process.arguments=["30"];process.terminationHandler={_ in};try process.run()}
    defer {for process in [first,second] where process.isRunning {process.terminate()}}
    let pids="\(first.processIdentifier) \(second.processIdentifier)"
    let install=Task {
      try await UpdateFiles.run("/bin/sh",["-c",AppMover.installScript,"fixture",source.path,destination.path,"",pids,UUID().uuidString])
    }
    try await Task.sleep(nanoseconds:100_000_000)
    XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
    first.terminate()
    try await Task.sleep(nanoseconds:150_000_000)
    XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path),"One remaining process must prevent replacement")
    second.terminate()
    _=try await install.value
    let deadline=Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath:receipt.path),Date()<deadline {try await Task.sleep(nanoseconds:50_000_000)}
    XCTAssertEqual(try String(contentsOf:receipt),"manual","A downloaded DMG must not acquire the automatic-update bypass flag")
    XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
  }

  func testFlocksVaryTheirLandingCountAndKeepPerchesSpaced() {
    let window=WindowSurface(id:1,frame:CGRect(x:200,y:100,width:650,height:250),
      blockers:[],cornerRadius:18,cornerExponent:2.5,isDock:false)
    var peaks=Set<Int>()
    for seed in UInt64(1)...32 {
      let flock=BirdFlock(seed:seed)
      var peak=0
      for _ in 0..<1200 {
        flock.step(dt:1/60,size:SIMD2(1100,700),surfaces:[window],wind:0,
          airflow:nil,cursor:SIMD2(-1000,-1000),active:true,reducedMotion:false)
        peak=max(peak,flock.perchedCount)
        let perched=flock.particles.filter{$0.life.w==1}
        for i in perched.indices {for j in perched.indices where j>i {
          XCTAssertGreaterThanOrEqual(abs(perched[i].rect.x-perched[j].rect.x),37.9)
        }}
      }
      peaks.insert(peak)
    }
    XCTAssertTrue(peaks.contains(0),"Some flocks should pass by without landing")
    XCTAssertTrue(peaks.contains(1))
    XCTAssertTrue(peaks.contains{$0>=2},"Several birds must sometimes land together")
  }

  func testWindowGlowTracksGeometryDespiteDelayedCaptureWithoutLeavingATrail() throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("Metal unavailable")}
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:960,height:600,mipmapped:false)
    descriptor.usage=[.shaderRead,.renderTarget]
    let source=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    let wallpaper=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    let output=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    var pixels=[UInt8](repeating:0,count:960*600*4)
    for i in stride(from:0,to:pixels.count,by:4){pixels[i]=12;pixels[i+1]=18;pixels[i+2]=26;pixels[i+3]=255}
    wallpaper.replace(region:MTLRegionMake2D(0,0,960,600),mipmapLevel:0,withBytes:&pixels,bytesPerRow:3840)
    for y in 180..<500 {for x in 180..<460 {
      let i=((599-y)*960+x)*4;pixels[i]=35;pixels[i+1]=100;pixels[i+2]=220
    }}
    source.replace(region:MTLRegionMake2D(0,0,960,600),mipmapLevel:0,withBytes:&pixels,bytesPerRow:3840)
    let bloom=try FogBloom(device:device,format:.rgba8Unorm),queue=try XCTUnwrap(device.makeCommandQueue())
    func render(_ frame:SIMD4<Float>,time:Double,capture:Double) throws -> [UInt8] {
      let command=try XCTUnwrap(queue.makeCommandBuffer())
      let scene=try XCTUnwrap(bloom.scenePass(for:output))
      try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:scene)).endEncoding()
      bloom.prepare(desktop:source,rect:SIMD4(0,0,1,1),size:SIMD2(960,600),windows:[frame],command:command,
        wallpaper:wallpaper,windowIDs:[41],capturedAt:capture,now:time)
      let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
      pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
      let encoder=try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
      bloom.encode(with:encoder,size:SIMD2(960,600),amount:0.72,windows:[],contents:.light)
      encoder.endEncoding();command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
      var result=[UInt8](repeating:0,count:pixels.count)
      output.getBytes(&result,bytesPerRow:3840,from:MTLRegionMake2D(0,0,960,600),mipmapLevel:0)
      return result
    }
    for i in 0..<25 {_=try render(SIMD4(180,180,460,500),time:100+Double(i)/60,capture:100+Double(i)/60)}
    var alphas=[Int](),last=[UInt8]()
    for i in 1...20 {
      let left=180+i*12
      let result=try render(SIMD4(Float(left),180,Float(left+280),500),time:102+Double(i)/120,capture:101)
      let edge=((599-340)*960+left-2)*4
      alphas.append(Int(result[edge+3]))
      XCTAssertGreaterThan(result[edge+2],result[edge],"Glow retains the window's own blue")
      for distance in 1...12 {
        XCTAssertGreaterThan(result[((599-340)*960+left-distance)*4+3],12,"No sharp unlit gap beside the moving edge")
      }
      last=result
    }
    XCTAssertGreaterThan(alphas.min()!,20)
    XCTAssertLessThanOrEqual(alphas.max()!-alphas.min()!,3,"Capture latency must not make a dragged halo flicker")
    XCTAssertLessThanOrEqual(last[((599-340)*960+178)*4+3],1,"A stale captured window must not glow at its old location")
  }
}
