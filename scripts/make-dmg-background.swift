import AppKit
import ImageIO
import UniformTypeIdentifiers

// Finder's icons supply the app and Applications artwork; the background stays quiet.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for scale in [1, 2] {
  let width = 600
  let height = 380
  let context = CGContext(
    data: nil, width: width * scale, height: height * scale,
    bitsPerComponent: 8, bytesPerRow: width * scale * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  let colors = [
    CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1),
    CGColor(srgbRed: 0.87, green: 0.91, blue: 0.95, alpha: 1),
  ]
  let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
  context.drawLinearGradient(
    gradient, start: CGPoint(x: 300, y: 380), end: CGPoint(x: 300, y: 0), options: [])
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  func text(_ string: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (string as NSString).size(withAttributes: attrs)
    (string as NSString).draw(at: CGPoint(x: (600 - size.width) / 2, y: y), withAttributes: attrs)
  }
  text(
    "Atmos", y: 307, font: .systemFont(ofSize: 28, weight: .semibold),
    color: NSColor(srgbRed: 0.16, green: 0.23, blue: 0.32, alpha: 1))
  text(
    "A little atmosphere on your desktop.", y: 280, font: .systemFont(ofSize: 13),
    color: NSColor(srgbRed: 0.34, green: 0.41, blue: 0.49, alpha: 1))
  context.setStrokeColor(CGColor(srgbRed: 0.38, green: 0.49, blue: 0.60, alpha: 0.8))
  context.setLineWidth(2)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  context.move(to: CGPoint(x: 263, y: 181))
  context.addLine(to: CGPoint(x: 337, y: 181))
  context.move(to: CGPoint(x: 329, y: 189))
  context.addLine(to: CGPoint(x: 337, y: 181))
  context.addLine(to: CGPoint(x: 329, y: 173))
  context.strokePath()
  text(
    "Drag to install", y: 145, font: .systemFont(ofSize: 12, weight: .medium),
    color: NSColor(srgbRed: 0.30, green: 0.39, blue: 0.49, alpha: 1))
  NSGraphicsContext.restoreGraphicsState()
  let image = context.makeImage()!
  let output = directory.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png")
  let destination = CGImageDestinationCreateWithURL(
    output as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(
    destination, image,
    [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
  guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not write installer background")
  }
}
