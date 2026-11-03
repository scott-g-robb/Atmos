import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Export the same full-canvas artwork at every legacy macOS icon size.
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fatalError("Invalid icon artwork") }
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let context = CGContext(
      data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
      bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    let body = bounds.insetBy(dx: CGFloat(pixels) * 0.10, dy: CGFloat(pixels) * 0.10)
    context.addPath(
      CGPath(
        roundedRect: body, cornerWidth: body.width * 0.22,
        cornerHeight: body.height * 0.22, transform: nil))
    context.clip()
    context.interpolationQuality = .high
    context.draw(image, in: body)
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    let destination = CGImageDestinationCreateWithURL(
      output.appendingPathComponent(name) as CFURL,
      UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not export \(name)") }
  }
}
