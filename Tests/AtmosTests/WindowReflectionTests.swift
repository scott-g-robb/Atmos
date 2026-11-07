import CoreVideo
import Metal
import ScreenCaptureKit
import XCTest

@testable import Atmos

final class WindowReflectionTests: XCTestCase {
  func testStoppingSharingRequiresAnExplicitChoiceBeforeCaptureRestarts() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let reflection = ScreenReflection(device: device, displayID: CGMainDisplayID())
    reflection.enabled = true
    reflection.captureStopped(
      with: NSError(domain: SCStreamErrorDomain, code: SCStreamError.userStopped.rawValue))
    XCTAssertTrue(reflection.stoppedByUser)
    reflection.invalidate()
    reflection.stop()
    XCTAssertTrue(reflection.stoppedByUser, "Pausing or changing Spaces must not undo Stop Sharing")
    reflection.fogBloomEnabled = true
    XCTAssertFalse(reflection.stoppedByUser, "Explicitly enabling fog bloom permits capture")
    reflection.captureStopped(
      with: NSError(domain: SCStreamErrorDomain, code: SCStreamError.userStopped.rawValue))
    reflection.fogBloomEnabled = true
    XCTAssertTrue(reflection.stoppedByUser, "An unchanged fog setting must not undo Stop Sharing")
    reflection.fogBloomEnabled = false
    reflection.fogBloomEnabled = true
    XCTAssertFalse(reflection.stoppedByUser)
    reflection.enabled = true
    XCTAssertFalse(
      reflection.stoppedByUser, "Selecting a reflection source explicitly allows capture again")
    reflection.captureStopped(
      with: NSError(domain: SCStreamErrorDomain, code: SCStreamError.internalError.rawValue))
    XCTAssertFalse(
      reflection.stoppedByUser,
      "A recoverable capture error is different from the user's stop action")
  }

  private func buffer(_ id: UInt32, size: CGSize) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
    let buffer = try XCTUnwrap(result)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<Int(size.height) {
      for x in 0..<Int(size.width) {
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        // ID 1 is red at the top and green at the bottom; ID 2 is blue.
        base[offset] = id == 2 ? 255 : 0
        base[offset + 1] = id == 1 && y >= Int(size.height) / 2 ? 255 : 0
        base[offset + 2] = id == 1 && y < Int(size.height) / 2 ? 255 : 0
        base[offset + 3] = 255
      }
    }
    return buffer
  }

  private func render(_ cache: WindowReflections, device: MTLDevice) throws -> [UInt8] {
    let texture = try XCTUnwrap(cache.texture)
    let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    cache.encode(into: command)
    let row = (texture.width * 4 + 255) & ~255
    let buffer = try XCTUnwrap(
      device.makeBuffer(length: row * texture.height, options: .storageModeShared))
    let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
    blit.copy(
      from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
      sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
      to: buffer, destinationOffset: 0, destinationBytesPerRow: row,
      destinationBytesPerImage: row * texture.height)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    XCTAssertNil(command.error)
    return Array(
      UnsafeBufferPointer(
        start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: row * texture.height))
  }

  @MainActor func testSnapshotsFollowWindowGeometryWithoutRecaptureAndRespectOrderAndClosure()
    async throws
  {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    var captures = 0
    let cache = try WindowReflections(device: device) { [self] id, size in
      captures += 1
      return try buffer(id, size: size)
    }
    let now = CACurrentMediaTime()
    let size = CGSize(width: 256, height: 200)
    let rear = ReflectionWindow(
      id: 1, frame: CGRect(x: 20, y: 20, width: 80, height: 100), alpha: 1)
    let front = ReflectionWindow(
      id: 2, frame: CGRect(x: 60, y: 40, width: 80, height: 100), alpha: 1)
    cache.update(windows: [front, rear], size: size, wallpaper: nil, now: now)
    await cache.captureTask?.value
    var pixels = try render(cache, device: device)
    func rgb(_ x: Int, _ y: Int) -> [UInt8] {
      Array(pixels[(y * 1024 + x * 4)..<(y * 1024 + x * 4 + 3)])
    }
    XCTAssertEqual(rgb(30, 30), [255, 0, 0])
    XCTAssertEqual(rgb(30, 105), [0, 255, 0])
    XCTAssertEqual(rgb(70, 60), [0, 0, 255], "Front-to-back order must match the desktop")
    let moved = ReflectionWindow(id: 2, frame: front.frame.offsetBy(dx: 80, dy: 0), alpha: 1)
    cache.update(windows: [moved, rear], size: size, wallpaper: nil, now: now + 0.01)
    pixels = try render(cache, device: device)
    XCTAssertEqual(captures, 2, "Moving an unchanged window reuses its pixels")
    XCTAssertEqual(rgb(70, 60), [255, 0, 0])
    XCTAssertEqual(rgb(150, 60), [0, 0, 255])
    cache.update(windows: [rear], size: size, wallpaper: nil, now: now + 0.02)
    pixels = try render(cache, device: device)
    XCTAssertNotEqual(rgb(150, 60), [0, 0, 255], "Closed windows cannot leave ghost reflections")
    cache.stop()
    XCTAssertNil(cache.texture)
  }

  @MainActor func testResizingRefreshesTheImageAndStoppingRejectsPendingSnapshots() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    var captures = 0
    let cache = try WindowReflections(device: device) { [self] id, size in
      captures += 1
      return try buffer(id, size: size)
    }
    let now = CACurrentMediaTime()
    let size = CGSize(width: 256, height: 200)
    cache.update(
      windows: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 40), alpha: 1)],
      size: size, wallpaper: nil, now: now)
    await cache.captureTask?.value
    cache.update(
      windows: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 80, height: 40), alpha: 1)],
      size: size, wallpaper: nil, now: now + 0.2)
    await cache.captureTask?.value
    XCTAssertEqual(captures, 2)
    cache.update(
      windows: [.init(id: 2, frame: CGRect(x: 0, y: 0, width: 40, height: 40), alpha: 1)],
      size: size, wallpaper: nil, now: now + 0.4)
    let task = cache.captureTask
    cache.stop()
    await task?.value
    XCTAssertNil(cache.texture, "An obsolete async snapshot must not revive a stopped renderer")
  }
}
