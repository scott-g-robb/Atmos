import AppKit
import XCTest
@testable import Aeolian

final class WindowTracking144Tests: XCTestCase {
  private func entry(_ id:UInt32, layer:Int=0, alpha:Double=1) -> [String:Any] {
    [kCGWindowNumber as String:id, kCGWindowOwnerPID as String:99999,
     kCGWindowOwnerName as String:"Fixture",kCGWindowLayer as String:layer,
     kCGWindowAlpha as String:alpha,kCGWindowIsOnscreen as String:true,
     kCGWindowBounds as String:CGRect(x:100,y:100,width:500,height:350).dictionaryRepresentation]
  }
  @MainActor func testDismissedContextMenuNeverLowersForegroundCloudWisps() {
    var windows=[entry(101)]
    let tracker=WindowTracker(windowList:{ _ in windows as CFArray })
    tracker.screen=CGRect(x:0,y:0,width:1000,height:800)
    tracker.primaryHeight=800;tracker.menuBarHeight=24
    _=tracker.poll(now:10,eager:true)
    XCTAssertFalse(tracker.hasPresentationTransition(now:10))
    windows.insert(entry(202,layer:Int(CGWindowLevelForKey(.popUpMenuWindow))),at:0)
    let menu=tracker.poll(now:11,eager:true)
    XCTAssertFalse(menu?.surfaces.contains{$0.id==202} ?? false,"A temporary menu must not collect particles")
    XCTAssertFalse(tracker.hasPresentationTransition(now:11))
    windows[0]=entry(202,layer:Int(CGWindowLevelForKey(.popUpMenuWindow)),alpha:0.65)
    _=tracker.poll(now:11.05,eager:true)
    XCTAssertFalse(tracker.hasPresentationTransition(now:11.05),"Menu dismissal must not switch foreground wisps behind the window")
    windows.removeFirst()
    _=tracker.poll(now:11.1,eager:true)
    XCTAssertFalse(tracker.hasPresentationTransition(now:11.1))
    XCTAssertEqual(tracker.applicationWindows.count,1)
    windows[0]=entry(101,alpha:0.65)
    _=tracker.poll(now:12,eager:true)
    XCTAssertTrue(tracker.hasPresentationTransition(now:12),"Real window dismissal still uses native occlusion")
  }
}
