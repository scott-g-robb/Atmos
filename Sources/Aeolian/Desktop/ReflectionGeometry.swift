import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import simd

/// ScreenCaptureKit reports its content rectangle in surface points; conversion to pixels
/// happens once per frame. The shader samples only that region, preserving logical x alignment.
enum ReflectionGeometry {
  static func uvRect(sample: CMSampleBuffer) -> SIMD4<Float> {
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return SIMD4(0,0,1,1) }
    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String:Any]],
      let metadata = attachments.first,
      let dictionary = metadata[SCStreamFrameInfo.contentRect.rawValue] as? NSDictionary,
      let points = CGRect(dictionaryRepresentation: dictionary) else { return SIMD4(0,0,1,1) }
    let scale = (metadata[SCStreamFrameInfo.scaleFactor.rawValue] as? NSNumber)?.doubleValue ?? 1
    return uvRect(contentPixels: CGRect(x: points.minX * scale, y: points.minY * scale,
      width: points.width * scale, height: points.height * scale), textureSize: size)
  }
  static func uvRect(contentPixels rect: CGRect, textureSize: CGSize) -> SIMD4<Float> {
    guard textureSize.width > 0, textureSize.height > 0,
      rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
      rect.width > 0, rect.height > 0,
      rect.minX >= -1, rect.minY >= -1,
      rect.maxX <= textureSize.width + 1, rect.maxY <= textureSize.height + 1
    else { return SIMD4(0, 0, 1, 1) }
    return SIMD4(
      Float(max(0, rect.minX) / textureSize.width), Float(max(0, rect.minY) / textureSize.height),
      Float(min(rect.width, textureSize.width) / textureSize.width),
      Float(min(rect.height, textureSize.height) / textureSize.height))
  }
}
