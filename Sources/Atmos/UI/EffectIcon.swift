import AppKit
import SwiftUI

/// Butterfly is not an SF Symbol on all supported macOS releases.
/// Keep a vector silhouette rather than silently drawing a missing glyph.
enum EffectArtwork {
  static let butterfly: NSImage = {
    let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      let transform = NSAffineTransform()
      transform.translateX(by: rect.minX, yBy: rect.minY)
      transform.scaleX(by: rect.width/32, yBy: rect.height/32)
      transform.concat()
      let path = NSBezierPath()
      for side in [CGFloat(-1), CGFloat(1)] {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 16+side*x, y: y) }
        path.move(to: point(1, 17))
        path.curve(to: point(13, 27), controlPoint1: point(3, 31), controlPoint2: point(15, 33))
        path.curve(to: point(3, 14), controlPoint1: point(16, 20), controlPoint2: point(10, 17))
        path.curve(to: point(9, 4), controlPoint1: point(15, 15), controlPoint2: point(14, 2))
        path.curve(to: point(1, 13), controlPoint1: point(3, 3), controlPoint2: point(2, 9))
        path.close()
      }
      NSColor.black.setFill(); path.fill()
      let body = NSBezierPath(roundedRect: CGRect(x: 14.8, y: 9, width: 2.4, height: 15), xRadius: 1.2, yRadius: 1.2)
      body.fill()
      let antenna = NSBezierPath(); antenna.lineWidth = 1.2
      antenna.move(to: CGPoint(x: 16, y: 23)); antenna.line(to: CGPoint(x: 12, y: 29))
      antenna.move(to: CGPoint(x: 16, y: 23)); antenna.line(to: CGPoint(x: 20, y: 29)); antenna.stroke()
      return true
    }
    image.isTemplate = true
    return image
  }()
  static func image(for effect: WeatherEffect) -> NSImage? {
    effect == .butterflies ? butterfly : NSImage(systemSymbolName: effect.symbol, accessibilityDescription: effect.title)
  }
  static func statusImage(for effect: WeatherEffect) -> NSImage? {
    guard effect == .butterflies else { return image(for: effect) }
    let image = butterfly.copy() as! NSImage
    image.size = NSSize(width: 18, height: 18)
    return image
  }
}

struct EffectIcon: View {
  let effect: WeatherEffect
  var size: CGFloat = 30
  var body: some View {
    if effect == .butterflies { Image(nsImage: EffectArtwork.butterfly).resizable().scaledToFit().frame(width: size, height: size) }
    else { Image(systemName: effect.symbol) }
  }
}
