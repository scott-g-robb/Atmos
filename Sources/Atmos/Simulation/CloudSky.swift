import Foundation
import simd

/// One geometric sky description drives both visible clouds and precipitation.
/// Calibrate the original noise field to the requested width, without replacing
/// the original cloud volume with separate geometric shapes.
struct CloudSky {
  struct Band {
    var x: Float
    var width: Float
    var depth: Float
    var seed: Float
    var time: Float
    func bottom(at x: Float, ceiling: Float) -> Float {
      // Match the original volume's soft, noise-shaped underside in Metal.
      let lower = 0.12 + CloudSky.noise(x * 0.009 - time * 0.012, 7.3) * 0.42
      return ceiling - depth * (1.1 / 1.5) + depth * (lower + 0.05)
    }

  }
  private(set) var bands: [Band] = []
  private(set) var formation: Float = 0
  private(set) var cover: Float = 0
  private(set) var darkness: Float = 0
  private(set) var ceiling: Float = 0
  private(set) var width: Float = 0
  private var drift: Double = 0
  private var age: Double = 0
  private var samples = [Float](repeating: 0, count: 129)
  private(set) var threshold: Float = 0
  private(set) var maskPhase: Float = 0
  private(set) var depth: Float = 0
  var occupiedWidth: Float { bands.reduce(0) { $0 + max(0, min(width, $1.x + $1.width) - max(0, $1.x)) } }

  mutating func step(size: SIMD2<Float>, cover: Float, rainLoad: Float, wind: Float,
    dt: Float, active: Bool, clearing: Bool, time: Float? = nil, calibrated: Bool = true
  ) {
    let target: Float = active && !clearing ? 1 : 0
    formation += (target - formation) * (1 - exp(-dt * (target > formation ? 0.65 : 2.2)))
    self.cover = max(0, min(1, cover))
    darkness = max(0, min(1, rainLoad))
    width = size.x; ceiling = size.y
    drift += Double(wind * dt * 0.000025)
    maskPhase = Float(drift)
    age += Double(dt)
    bands.removeAll(keepingCapacity: true)
    guard width > 0, formation > 0.0001, self.cover > 0 else { return }
    let fair = min(size.y * 0.35, 90 + self.cover * 130) * (0.65 + 0.35 * self.cover)
    let loaded = min(size.y * 0.35, 220) * (0.65 + 0.35 * self.cover)
    depth = (fair + (loaded - fair) * darkness) * 1.5
    let moment = time ?? Float(age.truncatingRemainder(dividingBy: 1000))
    if !calibrated {
      let occupied = width * self.cover * formation
      bands.append(Band(x: (width-occupied)*0.5, width: occupied, depth: depth, seed: 0.37, time: moment))
      return
    }
    let spacing = width / 128
    var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
    for i in 0...128 {
      let value = Self.noise(Float(i) * spacing * 0.0018 - maskPhase, 1.7)
      samples[i] = value; low = min(low, value); high = max(high, value)
    }
    let wanted = width * self.cover * formation
    // A percentile of the actual on-screen field prevents low cover values
    // from vanishing when the whole field happens to lie below 1-cover.
    for _ in 0..<22 {
      let middle = (low + high) * 0.5
      var occupied: Float = 0
      for i in 0..<128 {
        let a = samples[i], b = samples[i+1]
        if a >= middle && b >= middle { occupied += spacing }
        else if (a >= middle) != (b >= middle) {
          let crossing = (middle-a)/(b-a)
          occupied += spacing * (a >= middle ? crossing : 1-crossing)
        }
      }
      if occupied > wanted { low = middle } else { high = middle }
    }
    threshold = (low + high) * 0.5
    for i in 0..<128 {
      let a = samples[i], b = samples[i+1], x = Float(i) * spacing
      guard a >= threshold || b >= threshold else { continue }
      var left = x, right = x + spacing
      if a < threshold { left = x + (threshold-a)/(b-a)*spacing }
      if b < threshold { right = x + (threshold-a)/(b-a)*spacing }
      if let last = bands.indices.last, abs(bands[last].x+bands[last].width-left)<0.01 {
        bands[last].width = right-bands[last].x
      } else {
        bands.append(Band(x: left, width: right-left, depth: depth, seed: 0.37, time: moment))
      }
    }
  }

  private static func noise(_ x: Float, _ y: Float) -> Float {
    func fract(_ v: Float) -> Float { v - floor(v) }
    func hash(_ x: Float, _ y: Float) -> Float {
      var a = fract(x * 123.34), b = fract(y * 456.21)
      let d = a * (a + 45.32) + b * (b + 45.32)
      a += d; b += d
      return fract(a * b)
    }
    let ix = floor(x), iy = floor(y), fx = fract(x), fy = fract(y)
    let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
    let a = hash(ix, iy), b = hash(ix + 1, iy), c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
    return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v
  }
  func contains(x: Float) -> Bool { bands.contains { x >= $0.x && x <= $0.x + $0.width } }
  func bottom(at x: Float) -> Float? {
    bands.first { x >= $0.x && x <= $0.x + $0.width }?.bottom(at: x, ceiling: ceiling)
  }
  /// Use the same covered columns as the clouds, but enter above the visible
  /// desktop so precipitation can strike ledges inside the cloud layer too.
  func rainSource(_ fraction: Float) -> SIMD2<Float>? {
    let total = occupiedWidth
    guard total > 0.5 else { return nil }
    var distance = max(0, min(0.999999, fraction)) * total
    for band in bands {
      let left = max(0, band.x), right = min(width, band.x + band.width)
      let span = max(0, right - left)
      if distance < span {
        let x = left + distance
        return SIMD2(x, ceiling + 3)
      }
      distance -= span
    }
    return nil
  }
}
