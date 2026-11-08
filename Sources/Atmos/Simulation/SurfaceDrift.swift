import CWeatherCore
import CoreGraphics
import Foundation
import simd

/// Buoyant material shares the actual water field. It rides ripples and support motion,
/// drifts with surface currents, and falls back to the supporting ledge as water dries.
final class SurfaceDrift {
  struct Released {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var size: Float
    var seed: Float
    var area: Float
  }
  private typealias Floating = SHFloating
  var botanicalStyle:Float=1
  private func clearance(size:Float,turn:Float)->Float {size*0.055}
  var lifetime: Float = 90
  private var floating: [Floating] = []
  private(set) var groundCount = 0
  private(set) var groundTop: Float = 0
  private(set) var sprites: [Sprite] = []
  var count: Int { floating.count }
  var positions: [SIMD2<Float>] { floating.map(\.position) }

  @discardableResult
  func catchMaterial(
    x: Float, from: Float, to: Float, velocity: SIMD2<Float>, size: Float,
    seed: Float, area: Float, turn: Float, water: [WaterSurface]
  ) -> Bool {
    guard floating.count < 384, to <= from else { return false }
    let hit = water.filter {
      let depth = $0.depth(at: x)
      let top = $0.origin.y + depth
      return depth > 0.3 && $0.accepts(x: x) && from >= top - 0.5 && to <= top + 0.5
    }.max { $0.origin.y < $1.origin.y }
    guard let hit else { return false }
    floating.append(
      Floating(
        position: SIMD2(x, hit.origin.y + hit.depth(at: x)+clearance(size:size,turn:turn)), releaseVelocity:.zero,surfaceID:hit.id,x:x-hit.origin.x,velocity: velocity.x * 0.16,
        size: size, seed: seed, area: area, turn: atan2(sin(turn), cos(turn)),
        age:0,alpha:1,belowDock:hit.belowDock ? 1:0,status:0))
    hit.hit(x: x, amount: 0, impulse: min(1.4, max(0.25, abs(velocity.y) * 0.008)))
    rebuildSprites()
    return true
  }

  func step(
    dt: Float, water: [WaterSurface], wind: Float, cursor: SIMD2<Float>?,
    cursorVelocity: SIMD2<Float>, retiring: Bool, clearing: Bool,
    cursorFrom: SIMD2<Float>? = nil
  ) -> [Released] {
    var released:[Released]=[]
    var input=SHDriftStep(dt:dt,wind:wind,cursorX:cursor?.x ?? 0,cursorY:cursor?.y ?? 0,
      previousX:(cursorFrom ?? cursor)?.x ?? 0,previousY:(cursorFrom ?? cursor)?.y ?? 0,
      cursorVX:cursorVelocity.x,cursorVY:cursorVelocity.y,lifetime:lifetime,
      flags:(cursor != nil ? 1:0)|(retiring ? 2:0)|(clearing ? 4:0))
    floating.withUnsafeMutableBufferPointer { items in
      sh_drift_begin(items.baseAddress,items.count)
      for surface in water {
        surface.withPhysicsField { view in sh_drift_surface(items.baseAddress,items.count,&view,&input) }
      }
    }
    for i in floating.indices.reversed() where floating[i].status != 0 {
      let item=floating[i]
      if item.status == 1 {released.append(Released(position:item.position+SIMD2(0,1),
        velocity:item.releaseVelocity,size:item.size,seed:item.seed,area:item.area))}
      floating.remove(at:i)
    }
    rebuildSprites()
    return released
  }

  private func rebuildSprites() {
    sprites.removeAll(keepingCapacity: true)
    groundCount = 0
    groundTop = 0
    for belowDock in [true, false] {
      for item in floating where (item.belowDock != 0) == belowDock {
        sprites.append(
          Sprite(
            position: item.position, velocity: SIMD2(item.velocity, 0),
            size: item.size, alpha: item.alpha * 0.94, soft: 0, leaf: item.seed,
            turn: item.turn, flip: 0.16))
        if belowDock {
          groundCount += 1
          groundTop = max(groundTop, item.position.y + item.size * 0.55)
        }
      }
    }
  }
  func removeAll() {
    floating.removeAll()
    sprites.removeAll()
    groundCount = 0
    groundTop = 0
  }
}
