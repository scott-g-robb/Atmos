import AppKit
import SwiftUI
import XCTest
@testable import Aeolian

final class Personalisation143Tests:XCTestCase {
  private func preserve()->()->Void {
    let keys=["interfaceAppearance","interfaceAccent","weatherUnits","temperatureUnits","windUnits","rainfallUnits","visibilityUnits","menuBarStyle"]
    let store=UserDefaults.standard,values=keys.map{UserDefaults.standard.object(forKey:$0)}
    return {for(key,value) in zip(keys,values){if let value {store.set(value,forKey:key)}else{store.removeObject(forKey:key)}}}
  }
  func testSkyCloudsAndVeilNeverInheritTheFogOpacityAgain() {
    for fog:Float in [0,0.04,0.2,0.8] {
      XCTAssertEqual(WeatherRenderer.decorationOpacity(kind:12,mist:true,fog:fog),1)
      XCTAssertEqual(WeatherRenderer.decorationOpacity(kind:15,mist:true,fog:fog),1)
      XCTAssertEqual(WeatherRenderer.decorationOpacity(kind:7,mist:true,fog:fog),fog)
    }
    var a=WeatherSnapshot(time:Date().timeIntervalSince1970,weatherCode:2,temperature:6,windSpeed:2,windDirection:108,precipitation:0,isDay:0)
    a.cloudCover=50;a.visibility=12_400
    var b=a;b.visibility=200
    let clear=WeatherScene(weather:a),fog=WeatherScene(weather:b)
    XCTAssertEqual(clear.clouds,0.5);XCTAssertEqual(clear.clouds,fog.clouds)
    XCTAssertGreaterThan(fog.fog,clear.fog)
  }
  @MainActor func testCustomUnitsAndAppearanceControlsPersistWithoutChangingPhysics() throws {
    let restore=preserve();defer{restore();AeolianAppearance.shared.apply()}
    _=NSApplication.shared;Preferences.weatherUnits = .metric
    UserDefaults.standard.removeObject(forKey:"interfaceAccent")
    XCTAssertEqual(Preferences.interfaceAccent,.blue)
    XCTAssertEqual(InterfaceAccent.allCases.map(\.rawValue),["blue","teal","green","orange","pink","purple"])
    let view=QuickCustomisationView(frame:CGRect(x:0,y:0,width:440,height:380))
    func controls(_ root:NSView)->[NSView] {root.subviews.flatMap{[$0]+controls($0)}}
    func choose(_ tag:Int,_ index:Int) throws {
      let control=try XCTUnwrap(controls(view).compactMap{$0 as? NSPopUpButton}.first{$0.tag==tag})
      control.selectItem(at:index);XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(control.action),to:control.target,from:control))
    }
    try choose(3,1)
    XCTAssertEqual(Preferences.displayUnits.temperature(12),"12°C")
    XCTAssertEqual(Preferences.displayUnits.wind(16.09344),"10 mph")
    XCTAssertEqual(Preferences.displayUnits.rainfall(1),"1.0 mm/h")
    try choose(0,2);XCTAssertEqual(Preferences.interfaceAppearance,.dark)
    let purple=try XCTUnwrap(controls(view).compactMap{$0 as? NSButton}.first{$0.toolTip=="Purple"})
    purple.performClick(nil);XCTAssertEqual(Preferences.interfaceAccent,.purple)
    try choose(1,1)
    XCTAssertEqual(Preferences.displayUnits,WeatherDisplayUnits(preset:.imperial))
  }
  @MainActor func testSettingsCategoriesAssignEveryControlOnce() throws {
    _=NSApplication.shared
    let app=AppDelegate(),item=app.makeStatusItem();defer{NSStatusBar.system.removeStatusItem(item)}
    let menu=try XCTUnwrap(item.menu?.items.first{$0.title=="Settings"}?.submenu)
    for control in menu.items where !control.isSeparatorItem && !["Units","Menu Bar Style","Personalise Aeolian…"].contains(control.title) {
      XCTAssertEqual(AeolianSettingsSection.allCases.filter{$0.includes(control)}.count,1,control.title)
    }
  }
  @MainActor func testCustomisationPageFitsAndRendersBothAppearances() throws {
    let restore=preserve();defer{restore();AeolianAppearance.shared.apply()}
    _=NSApplication.shared
    for mode in [InterfaceAppearance.light,.dark] {
      Preferences.interfaceAppearance=mode;Preferences.interfaceAccent = .purple
      let page=SetupPageView(frame:CGRect(x:0,y:0,width:520,height:630),page:.customisation,permissions:[])
      let window=NSWindow(contentRect:page.frame,styleMask:.borderless,backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false;window.appearance=mode.native;window.contentView=page
      window.orderFront(nil);page.layoutSubtreeIfNeeded()
      let choices=try XCTUnwrap(page.subviews.flatMap{$0.subviews}.compactMap{$0 as? QuickCustomisationView}.first)
      let frame=page.convert(choices.bounds,from:choices)
      XCTAssertGreaterThan(frame.minY,85,"Choices must stay above the navigation footer")
      XCTAssertLessThan(frame.maxY,600)
      if let path=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
        let bitmap=try XCTUnwrap(page.bitmapImageRepForCachingDisplay(in:page.bounds))
        page.cacheDisplay(in:page.bounds,to:bitmap)
        try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("customisation-\(mode.rawValue).png"))
      }
      window.close()
    }
  }
}
