import QuartzCore
import XCTest

@testable import Aeolian

final class WindowCoverageTests: XCTestCase {
  private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

  func testOverlapsCountOnceAndOffscreenPartsDoNotCount() {
    let a = CGRect(x: -100, y: 0, width: 600, height: 800)
    let b = CGRect(x: 200, y: 0, width: 500, height: 800)
    XCTAssertEqual(WindowCoverage.fraction(of: screen, windows: [a, a, b]), 0.7, accuracy: 0.00001)
    XCTAssertEqual(WindowCoverage.fraction(of: .zero, windows: [a]), 0)
    XCTAssertEqual(WindowCoverage.fraction(of: screen, windows: []), 0)
  }

  func testMultipleWindowsCrossSeventyPercentTogether() {
    let left = CGRect(x: 0, y: 0, width: 500, height: 700)
    let right = CGRect(x: 500, y: 0, width: 300, height: 700)
    XCTAssertFalse(WindowCoverage.shouldYield(screen: screen, windows: [left]))
    XCTAssertTrue(WindowCoverage.shouldYield(screen: screen, windows: [left, right]))
  }

  func testTopTouchingWindowOnlyOccludesItsOwnFootprint() {
    let topWindow = CGRect(x: 100, y: 476, width: 400, height: 300)
    let lower = CGRect(x: 650, y: 120, width: 200, height: 300)
    XCTAssertFalse(WindowCoverage.shouldYield(screen: screen, windows: [topWindow, lower]))
    let selected = WindowCoverage.windowsAtTop(
      screen: screen, top: 776, windows: [1: topWindow, 2: lower], previous: [])
    XCTAssertEqual(Set(selected.keys), [1])
    let path = WindowOcclusionMask.visiblePath(in: screen, excluding: Array(selected.values))
    XCTAssertFalse(path.contains(CGPoint(x: 300, y: 600)))
    XCTAssertTrue(
      path.contains(CGPoint(x: 750, y: 250)), "Other windows keep the existing foreground weather")
    XCTAssertTrue(path.contains(CGPoint(x: 50, y: 600)), "The surrounding desktop remains visible")
    let moved = topWindow.offsetBy(dx: 0, dy: -3)
    XCTAssertTrue(
      WindowCoverage.windowsAtTop(screen: screen, top: 776, windows: [1: moved], previous: [])
        .isEmpty)
    XCTAssertEqual(
      WindowCoverage.windowsAtTop(screen: screen, top: 776, windows: [1: moved], previous: [1])
        .count, 1)
    XCTAssertTrue(
      WindowCoverage.windowsAtTop(
        screen: screen, top: 776, windows: [1: topWindow.offsetBy(dx: 0, dy: -10)], previous: [1]
      ).isEmpty)
  }

  func testOverlappingOccludersNeverReopenTheWeatherAndRoundedCornersRemainVisible() {
    let a = CGRect(x: 100, y: 200, width: 400, height: 576)
    let b = CGRect(x: 300, y: 400, width: 400, height: 376)
    let path = WindowOcclusionMask.visiblePath(in: screen, excluding: [a, b])
    XCTAssertFalse(path.contains(CGPoint(x: 350, y: 500)), "An overlapping area stays hidden")
    XCTAssertFalse(path.contains(CGPoint(x: 150, y: 300)))
    XCTAssertFalse(path.contains(CGPoint(x: 650, y: 500)))
    XCTAssertTrue(
      path.contains(CGPoint(x: 100.5, y: 775.5)), "Weather follows the rounded window corner")
    let dock = WindowOcclusionMask.visiblePath(
      in: CGRect(x: 0, y: 0, width: 1000, height: 80),
      excluding: [CGRect(x: 100, y: -20, width: 400, height: 796)])
    XCTAssertFalse(
      dock.contains(CGPoint(x: 300, y: 30)), "The Dock strip uses the same screen coordinates")
    XCTAssertTrue(dock.contains(CGPoint(x: 700, y: 30)))
  }

  func testCompositorMaskIsRemovedAndResizedWithoutImplicitAnimation() {
    let layer = CALayer()
    let mask = WindowOcclusionMask()
    mask.apply(
      to: layer, bounds: screen, excluding: [CGRect(x: 100, y: 100, width: 400, height: 676)])
    XCTAssertNotNil(layer.mask)
    let resized = CGRect(x: 0, y: 0, width: 1200, height: 900)
    mask.apply(
      to: layer, bounds: resized, excluding: [CGRect(x: 100, y: 100, width: 400, height: 676)])
    XCTAssertEqual(layer.mask?.frame, resized)
    mask.apply(to: layer, bounds: resized, excluding: [])
    XCTAssertNil(layer.mask)
  }

  func testHysteresisAndScreenOrigins() {
    let coverage = CGRect(x: 0, y: 0, width: 1000, height: 550)
    XCTAssertFalse(WindowCoverage.shouldYield(screen: screen, windows: [coverage]))
    XCTAssertTrue(
      WindowCoverage.shouldYield(screen: screen, windows: [coverage], alreadyBehind: true)
    )
    let shifted = screen.offsetBy(dx: -1440, dy: 300)
    XCTAssertEqual(WindowCoverage.fraction(of: shifted, windows: [shifted]), 1)
  }
}
