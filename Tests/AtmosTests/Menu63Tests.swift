import AppKit
import SwiftUI
import CoreLocation
import XCTest
@testable import Atmos

final class Menu63Tests: XCTestCase {
  @MainActor private func saved() -> () -> Void {
    let store=UserDefaults.standard
    let keys=["liveWeather","weatherEffect","seasonalDrift","wildlifeEffect","manualWindSpeed","manualCloudCoverage","snowfall","autumn","weatherUnits"]
    let values=keys.map{store.object(forKey:$0)}
    Preferences.liveWeather=false; Preferences.manualScene=WeatherScene(primary:.none)
    return {for (key,value) in zip(keys,values) {if let value {store.set(value,forKey:key)}else{store.removeObject(forKey:key)}}}
  }
  @MainActor func testCustomMenuUsesExistingCommandsAndIndependentDeselection() throws {
    _=NSApplication.shared
    let restore=saved();defer{restore()}
    let app=AppDelegate(),item=app.makeStatusItem()
    defer{NSStatusBar.system.removeStatusItem(item)}
    let menu=try XCTUnwrap(item.menu)
    let controller=try XCTUnwrap(app.installCustomMenu())
    XCTAssertNil(item.menu)
    XCTAssertNotNil(item.button?.action)
    controller.show(from:try XCTUnwrap(item.button))
    RunLoop.main.run(until:Date().addingTimeInterval(0.2))
    XCTAssertTrue(controller.isShown)
    let panel=try XCTUnwrap(NSApp.windows.first{$0.identifier==AtmosPanelPresentation.identifier && $0.isVisible})
    XCTAssertEqual(panel.frame.width,320)
    XCTAssertLessThanOrEqual(panel.frame.height,520)
    XCTAssertLessThan(panel.frame.width,panel.frame.height)
    defer{controller.close();app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))}
    for effect in [WeatherEffect.rain,.leaves,.birds] {
      let command=try XCTUnwrap(controller.model.effect(effect))
      controller.model.invoke(command)
      XCTAssertEqual(command.state,.on)
    }
    XCTAssertEqual(Preferences.manualScene.primary,.rain)
    XCTAssertEqual(Preferences.manualScene.stacked,.leaves)
    XCTAssertEqual(Preferences.manualScene.wildlife,.birds)
    controller.model.invoke(try XCTUnwrap(controller.model.effect(.leaves)))
    XCTAssertNil(Preferences.manualScene.stacked)
    XCTAssertEqual(Preferences.manualScene.primary,.rain)
    XCTAssertEqual(Preferences.manualScene.wildlife,.birds)
    controller.model.intensityChanged(.heavy)
    controller.model.windChanged(37)
    XCTAssertEqual(Preferences.snowfall,.heavy)
    XCTAssertEqual(Preferences.manualWindSpeed,37)
    XCTAssertNotNil(controller.model.settings?.items.first{$0.title=="Permissions & Activity"}?.submenu)
    XCTAssertTrue(menu.items.contains{$0.title=="Check for Updates…"})
    XCTAssertTrue(controller.isShown,"Selecting layers and dragging sliders must keep the dropdown open")
  }

  @MainActor func testCustomMenuPagesRenderInLightAndDarkWithoutTimers() throws {
    _=NSApplication.shared
    let restore=saved();defer{restore()}
    let app=AppDelegate(),item=app.makeStatusItem()
    defer{NSStatusBar.system.removeStatusItem(item)}
    app.menuNeedsUpdate(try XCTUnwrap(item.menu))
    let domain="Atmos.menu64.\(UUID())"
    let store=UserDefaults(suiteName:domain)!
    defer{store.removePersistentDomain(forName:domain)}
    let library=AtmosphereLibrary(defaults:store)
    library.save(AtmospherePreset(name:"atmos1",weather:.rain,drift:.leaves,wildlife:.birds,intensity:2,wind:12))
    library.save(AtmospherePreset(name:"Evening garden",weather:.none,drift:.cherryBlossoms,wildlife:.butterflies,intensity:1,wind:5))
    let model=AtmosMenuModel(menu:try XCTUnwrap(item.menu),library:library)
    model.attribution=NSImage(size:NSSize(width:2048,height:384),flipped:false){_ in
      ("Weather" as NSString).draw(at:NSPoint(x:20,y:50),withAttributes:[.font:NSFont.systemFont(ofSize:250,weight:.medium),.foregroundColor:NSColor.black]);return true
    }
    model.attribution?.isTemplate=true
    let commands=model.commands(in:try XCTUnwrap(model.details))
    XCTAssertEqual(commands.count,3)
    XCTAssertFalse(commands.contains{$0.action.map(NSStringFromSelector)=="openWeatherProvider"})
    for appearance in [NSAppearance.Name.aqua,.darkAqua] {
      for (page,category,live,loading) in [("",0,false,false),("",0,true,false),("",1,true,false),("",0,true,true),("manual",0,false,false),("manual",1,false,false),("manual",2,false,false),("manual",3,false,false),("presets",0,false,false),("settings",0,false,false),("weather",0,true,false),("weather",1,true,false)] {
        Preferences.liveWeather=live
        Preferences.weatherUnits = page == "weather" && category == 1 ? .imperial : .metric
        model.lastUpdateCheck=Date();model.updateAvailable=page.isEmpty && category == 1
        model.updateStatus=model.updateAvailable ? "Update available":"Up-To-Date"
        model.reading=live && !loading ? WeatherSnapshot(time:Date().timeIntervalSince1970,weatherCode:51,temperature:12,windSpeed:14,windDirection:270,precipitation:0.2,isDay:1) : nil
        if model.reading != nil {
          model.reading?.cloudCover=58;model.reading?.humidity=86;model.reading?.apparentTemperature=11
          model.reading?.windGust=22;model.reading?.visibility=8_000
          model.reading?.precipitationUnit="mm/h"
        }
        model.activeScene=model.reading.map { WeatherScene(weather:$0,date:Date(timeIntervalSince1970:1_794_139_290)) }
        model.place="Hounslow"
        let view=NSHostingView(rootView:AtmosMenuView(model:model,page:page,category:category).frame(width:320,height:520))
        view.frame=CGRect(x:0,y:0,width:320,height:520)
        let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:appearance);window.contentView=view
        window.setFrameOrigin(CGPoint(x:100,y:100));window.orderFront(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.04));view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width,320,accuracy:1)
        if let output=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
          let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
          view.cacheDisplay(in:view.bounds,to:bitmap)
          try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
          let file=URL(fileURLWithPath:output).appendingPathComponent("menu-\(page.isEmpty ? (live ? (loading ? "loading" : "live") : "home"):page)-\(category)-\(appearance.rawValue).png")
          try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:file)
        }
        window.orderOut(nil);window.contentView=nil
      }
    }
  }
}
