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
  private struct Floating {
    var surfaceID: CGWindowID
    var x: Float
    var position: SIMD2<Float>
    var velocity: Float
    var size: Float
    var seed: Float
    var area: Float
    var turn: Float
    var age: Float = 0
    var alpha: Float = 1
    var belowDock: Bool
  }
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
        surfaceID: hit.id, x: x - hit.origin.x,
        position: SIMD2(x, hit.origin.y + hit.depth(at: x)+clearance(size:size,turn:turn)), velocity: velocity.x * 0.16,
        size: size, seed: seed, area: area, turn: atan2(sin(turn), cos(turn)),
        belowDock: hit.belowDock))
    hit.hit(x: x, amount: 0, impulse: min(1.4, max(0.25, abs(velocity.y) * 0.008)))
    rebuildSprites()
    return true
  }

  func step(
    dt: Float, water: [WaterSurface], wind: Float, cursor: SIMD2<Float>?,
    cursorVelocity: SIMD2<Float>, retiring: Bool, clearing: Bool,
    cursorFrom: SIMD2<Float>? = nil
  ) -> [Released] {
    var released: [Released] = []
    for i in floating.indices.reversed() {
      var item = floating[i]
      guard let surface = water.first(where: { $0.id == item.surfaceID }) else {
        released.append(release(item))
        floating.remove(at: i)
        continue
      }
      let x = surface.origin.x + item.x
      let depth = surface.depth(at: x)
      let liquid=surface.velocity(at:x)
      if liquid.y>45 {
        var airborne=release(item)
        airborne.position=SIMD2(x,surface.origin.y+depth+1)
        airborne.velocity=liquid
        released.append(airborne);floating.remove(at:i);continue
      }
      guard depth > 0.16, surface.accepts(x: x) else {
        item.position.x = x
        released.append(release(item))
        floating.remove(at: i)
        continue
      }
      if let cursor, simd_length(cursorVelocity)>100 {
        let start=cursorFrom ?? cursor,stroke=cursor-(cursorFrom ?? cursor)
        let t=max(0,min(1,simd_dot(item.position-start,stroke)/max(0.001,simd_length_squared(stroke))))
        let contact=simd_length_squared(stroke)<160_000 ? start+stroke*t : cursor
        var normal=item.position-contact
        var distance=simd_length(normal)
        if distance<0.001 { normal=cursorVelocity/max(1,simd_length(cursorVelocity));distance=1 }
        if distance<11+item.size*0.3 && distance>0.001 {
          normal/=distance
          let impulse=normal*max(0,simd_dot(cursorVelocity,normal))
          var airborne=release(item);airborne.velocity=liquid+impulse
          released.append(airborne);floating.remove(at:i);continue
        }
      }
      item.age += dt
      let current = surface.current(at: x) + wind * 0.025
      item.velocity += (current - item.velocity) * (1 - exp(-dt * 2.8))
      item.x += item.velocity * dt
      let worldX = surface.origin.x + item.x
      let targetTurn: Float = cos(item.turn) < 0 ? (item.turn < 0 ? -.pi : .pi) : 0
      let rippleTurn = (surface.depth(at: worldX + 3) - surface.depth(at: worldX - 3)) * 0.04
      item.turn +=
        (targetTurn + rippleTurn + sin(item.age * 0.7 + item.seed * 17) * 0.08 - item.turn)
        * min(1, dt * 3)
      item.position = SIMD2(
        worldX, surface.origin.y + surface.depth(at: worldX) + clearance(size:item.size,turn:item.turn))
      if retiring || clearing || item.age > lifetime {
        item.alpha = max(0, item.alpha - dt * (clearing ? 2 : 0.7))
      }
      if item.alpha <= 0 { floating.remove(at: i) } else { floating[i] = item }
    }
    rebuildSprites()
    return released
  }

  private func release(_ item: Floating) -> Released {
    Released(
      position: item.position + SIMD2(0, 1), velocity: SIMD2(item.velocity, -12),
      size: item.size, seed: item.seed, area: item.area)
  }
  private func rebuildSprites() {
    sprites.removeAll(keepingCapacity: true)
    groundCount = 0
    groundTop = 0
    for belowDock in [true, false] {
      for item in floating where item.belowDock == belowDock {
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
