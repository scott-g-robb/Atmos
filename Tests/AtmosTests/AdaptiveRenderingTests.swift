import Metal
import XCTest
import simd

@testable import Atmos

final class AdaptiveRenderingTests: XCTestCase {
  func testCursorAndWindowMovementWakeImmediatelyAndThenRest() {
    let activity = FrameActivity()
    let size = SIMD2<Float>(1200, 900)
    activity.observeCursor(SIMD2(100, 100), size: size, now: 0)
    XCTAssertFalse(activity.isActive(now: 0))
    activity.observeCursor(SIMD2(100.01, 100), size: size, now: 0.01)
    XCTAssertFalse(activity.isActive(now: 0.01), "Sub-pixel noise must not keep a display awake")
    activity.observeCursor(SIMD2(101, 100), size: size, now: 0.02)
    XCTAssertTrue(activity.isActive(now: 0.02))
    XCTAssertTrue(activity.isActive(now: 0.4))
    XCTAssertFalse(activity.isActive(now: 0.43))
    activity.wake(now: 1)
    XCTAssertTrue(activity.isActive(now: 1), "Window movement wakes independently of the cursor")
    XCTAssertFalse(activity.isActive(now: 1.41))
    activity.resetCursor()
    activity.observeCursor(SIMD2(-1000, -1000), size: size, now: 2)
    activity.observeCursor(SIMD2(-1100, -1000), size: size, now: 2.01)
    XCTAssertFalse(activity.isActive(now: 2.01), "Motion on another display must not wake this one")
  }

  func testVideoWakesButOccasionalDesktopUpdatesDoNotHoldFullRate() {
    let activity = FrameActivity()
    for time in [0.0, 0.5, 1.0] { activity.observeDesktopChange(samples: 100, now: time) }
    XCTAssertFalse(activity.isActive(now: 1))
    for time in [1.1, 1.134, 1.168] { activity.observeDesktopChange(samples: 10, now: time) }
    XCTAssertFalse(
      activity.isActive(now: 1.17), "Small live indicators do not require full-screen refresh")
    for time in [2.0, 2.034, 2.068] { activity.observeDesktopChange(samples: 100, now: time) }
    XCTAssertTrue(activity.isActive(now: 2.07))
    XCTAssertFalse(activity.isActive(now: 2.5))
  }

  func testGPUDetectorIgnoresIdenticalFramesAndColourNoiseButDetectsMotion() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw XCTSkip("Metal unavailable")
    }
    let sensor = try ReflectionMotion(device: device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 64, height: 36, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    func fill(_ red: UInt8) {
      let pixels = (0..<(64 * 36)).flatMap { _ in [red, UInt8(100), UInt8(120), UInt8(255)] }
      pixels.withUnsafeBytes {
        texture.replace(
          region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: $0.baseAddress!,
          bytesPerRow: 256)
      }
    }
    func probe(_ now: Double) throws -> UInt32? {
      let command = try XCTUnwrap(queue.makeCommandBuffer())
      let result = sensor.encode(texture: texture, into: command, now: now)
      command.commit()
      command.waitUntilCompleted()
      XCTAssertNil(command.error)
      return result?.contents().load(as: UInt32.self)
    }
    fill(80)
    XCTAssertEqual(
      try probe(0), 0, "The first frame establishes a reference rather than reporting motion")
    XCTAssertNil(try probe(0.01), "GPU probing is bounded independently of the display rate")
    XCTAssertEqual(try probe(0.04), 0)
    fill(81)
    XCTAssertEqual(try probe(0.08), 0)
    fill(180)
    XCTAssertGreaterThan(try XCTUnwrap(probe(0.12)), 500)
    XCTAssertEqual(try probe(0.16), 0, "A new still image must settle back to idle")
  }
}
