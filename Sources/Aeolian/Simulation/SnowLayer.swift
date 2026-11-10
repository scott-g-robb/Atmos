import CWeatherCore
import Foundation
import simd

/// A height field of snow columns lying on a bed: the screen bottom, or the top edge of a window
/// whose rounded corners curve the bed down at both ends.
final class SnowLayer {
  let columnWidth: Float
  let opensAtEdges: Bool
  var origin: SIMD2<Float>
  private(set) var heights: [Float]
  /// How much of each column's snow a wall has packed down already, so it isn't packed again.
  private(set) var packed: [Float]
  /// The bed under each column relative to `origin.y`; zero along a flat edge, negative where a corner rounds off.
  private(set) var bed: [Float]
  private(set) var capacity: [Float] = []
  private(set) var visible: [Bool]
  private(set) var top: Float = 0
  private(set) var bedDepth: Float = 0
  var occluders: [SIMD4<Float>] = []
  /// Lies on the Dock's shelf, and so is drawn below the Dock.
  var isDock = false
  var motionGraceUntil: Double = -1
  var movedAt: Double = -1
  /// Brought where it is by a switch between Spaces: past the screen's edge, no wall scrapes its snow off.
  var carried = false
  /// When a switch between Spaces last shook the snow off the window's ends.
  var trimmedAt: Double = -10
  var spill: (left: Float, right: Float) = (0, 0)
  /// How high the snow lying just past each end comes up that end: it holds up the snow on the ledge, which spills
  /// off only above it.
  var outside: (left: Float, right: Float) = (0, 0)
  /// Smoothed path of the supporting edge; the snow reacts to its accelerations, not to raw jittery samples.
  var track: SIMD2<Float>
  var trackVelocity = SIMD2<Float>(repeating: 0)
  /// The snow body's displacement from its support: x slides along it, y lifts off it.
  var offset = SIMD2<Float>(repeating: 0)
  var offsetVelocity = SIMD2<Float>(repeating: 0)
  var previousBaseY: Float
  var agitation: Float = 0
  /// How far the snow has moved along the window since it came, as the window's left edge was dragged in or out
  /// under it: what is drawn in it moves along too.
  var drift: Float = 0
  /// The window's right edge, where the snow ends short of a whole column: which edge moved tells a resize from a move.
  var right: Float = 0
  /// Where the snow's own positions along it start: what lies in it keeps its place there as it slides or the
  /// window's left edge moves under it.
  var heapX: Float { base.x + drift }
  var swingDirection = SIMD2<Float>(repeating: 0)
  var swingPeak: Float = 0
  var previousSwingPeak: Float = 0

  private let depth: Float
  private let phases: (Float, Float)
  private var corner: (radius: Float, exponent: Float) = (0, 2)
  private var supported: [Bool]
  private var supportedRange: ClosedRange<Int>?
  private var parity = false

  init(
    origin: SIMD2<Float>, columns: Int, columnWidth: Float, depth: Float, opensAtEdges: Bool,
    phases: (Float, Float)
  ) {
    self.origin = origin
    self.track = origin
    self.previousBaseY = origin.y
    self.columnWidth = columnWidth
    self.depth = depth
    self.opensAtEdges = opensAtEdges
    self.phases = phases
    heights = Array(repeating: 0, count: columns)
    packed = Array(repeating: 0, count: columns)
    bed = Array(repeating: 0, count: columns)
    visible = Array(repeating: true, count: columns)
    supported = Array(repeating: false, count: columns)
    updateCapacity()
  }

  var count: Int { heights.count }
  var width: Float { Float(heights.count) * columnWidth }
  var base: SIMD2<Float> { origin + offset }

  func index(at x: Float) -> Int? {
    let i = Int(((x - base.x) / columnWidth).rounded(.down))
    return i >= 0 && i < heights.count ? i : nil
  }

  func clampedIndex(at x: Float) -> Int {
    min(max(Int(((x - base.x) / columnWidth).rounded(.down)), 0), heights.count - 1)
  }

  func centerX(_ i: Int) -> Float {
    base.x + (Float(i) + 0.5) * columnWidth
  }

  /// Height of the snow's underside (the bed) at column `i`, in overlay coordinates.
  func floor(_ i: Int) -> Float {
    base.y + bed[i]
  }

  func surface(_ i: Int) -> Float {
    base.y + bed[i] + heights[i]
  }

  /// Rounds the bed's ends like the window's corners: a superellipse quadrant of the given radius.
  func shapeCorners(radius: Float, exponent: Float) {
    guard radius != corner.radius || exponent != corner.exponent else { return }
    corner = (radius, exponent)
    updateBed()
  }

  /// Moves the snow one column along its support and returns the column that slid off the end.
  func slideColumn(toward direction: Int) -> (height: Float, x: Float, y: Float) {
    releaseSupport()
    let edge=direction>0 ? count-1:0,x=centerX(direction>0 ? count-1:0)
    let y=floor(edge),n=count
    let dropped=heights.withUnsafeMutableBufferPointer { h in
      packed.withUnsafeMutableBufferPointer { p in sh_snow_slide(h.baseAddress,p.baseAddress,n,Int32(direction)) }
    }
    return (dropped,x,y)
  }

  func fill(_ i: Int) -> Float {
    max(0, 1 - heights[i] / capacity[i])
  }

  func set(_ i: Int, _ height: Float) {
    heights[i] = max(0, height)
    packed[i] = min(packed[i], heights[i])
  }

  func replace(heights fresh: [Float]) {
    heights = fresh
    packed = Array(repeating: 0, count: fresh.count)
    visible = Array(repeating: true, count: fresh.count)
    supported = Array(repeating: false, count: fresh.count)
    supportedRange = nil
    updateCapacity()
    updateBed()
  }

  func resize(columns: Int) {
    guard columns != heights.count else { return }
    replace(
      heights: Array(heights.prefix(columns))
        + Array(repeating: 0, count: max(0, columns - heights.count)))
  }

  func updateVisibility(screenWidth: Float, blockers: [SIMD4<Float>]) {
    let n=count,x=base.x,y=origin.y,cw=columnWidth
    visible.withUnsafeMutableBytes { v in
      bed.withUnsafeBufferPointer { b in
        blockers.withUnsafeBufferPointer { blockers in
          sh_snow_visible(v.baseAddress?.assumingMemoryBound(to:UInt8.self),b.baseAddress,n,x,y,cw,screenWidth,blockers.baseAddress,blockers.count)
        }
      }
    }
  }

  func refreshTop() {
    top = heights.max() ?? 0
  }

  /// Adds snow centred on `x` and returns the area that fell outside the layer.
  @discardableResult
  func deposit(_ area: Float, at x: Float, wide: Bool) -> Float {
    let n=count,x0=base.x,cw=columnWidth
    return heights.withUnsafeMutableBufferPointer { h in
      sh_snow_deposit(h.baseAddress,n,x0,cw,area,x,wide ? 1:0)
    }
  }

  /// Piles snow against a wall just past column `edge`, as a plough heaps it: a wedge falling away from the wall
  /// at `slope` per column, the way `inward` points.
  func heap(_ area: Float, against edge: Int, inward: Int, slope: Float) {
    let n=count,cw=columnWidth,bd=bedDepth
    heights.withUnsafeMutableBufferPointer { h in
      packed.withUnsafeMutableBufferPointer { p in
        bed.withUnsafeBufferPointer { b in sh_snow_heap(h.baseAddress,p.baseAddress,b.baseAddress,n,cw,bd,area,edge,Int32(inward),slope) }
      }
    }
  }

  /// Displace a cursor's swept volume in one allocation-free Rust batch.
  func carve(center:SIMD2<Float>,velocity:SIMD2<Float>,radius:Float,travel:Float,
    final:Bool,autumn:Bool,leafCover:Float,cuts:inout [SHSnowCut]) -> Int {
    if cuts.count < count {cuts=Array(repeating:SHSnowCut(),count:count)}
    let n=count,base=base,cw=columnWidth
    return heights.withUnsafeMutableBufferPointer { h in
      packed.withUnsafeMutableBufferPointer { p in
        bed.withUnsafeBufferPointer { b in
          visible.withUnsafeBytes { v in
            cuts.withUnsafeMutableBufferPointer { out in
              sh_snow_carve(h.baseAddress,p.baseAddress,b.baseAddress,
                v.baseAddress?.assumingMemoryBound(to:UInt8.self),n,base.x,base.y,cw,
                center.x,center.y,radius,velocity.x,velocity.y,travel,final ? 1:0,
                autumn ? 1:0,leafCover,out.baseAddress)
            }
          }
        }
      }
    }
  }

  func erode(dt:Float,front:Float,direction:Float,mode:UInt32,finish:Bool,share:Float,
    cuts:inout [SHSnowCut])->Int {
    if cuts.count<count {cuts=Array(repeating:SHSnowCut(),count:count)}
    let n=count,base=base,cw=columnWidth
    return heights.withUnsafeMutableBufferPointer { h in
      packed.withUnsafeMutableBufferPointer { p in
        bed.withUnsafeBufferPointer { b in
          visible.withUnsafeBytes { v in
            cuts.withUnsafeMutableBufferPointer { out in
              sh_snow_erode(h.baseAddress,p.baseAddress,b.baseAddress,v.baseAddress?.assumingMemoryBound(to:UInt8.self),
                n,base.x,base.y,cw,dt,front,direction,mode,finish ? 1:0,share,out.baseAddress)
            }
          }
        }
      }
    }
  }

  func isHeld(_ i: Int) -> Bool {
    supported[i]
  }

  /// Columns touching the cursor are held up by it, so their walls don't slump into the hole until it leaves.
  func hold(_ i: Int) {
    supported[i] = true
    if let range = supportedRange {
      supportedRange = min(range.lowerBound, i)...max(range.upperBound, i)
    } else {
      supportedRange = i...i
    }
  }

  func releaseSupport() {
    guard let range = supportedRange else { return }
    for i in range { supported[i] = false }
    supportedRange = nil
  }

  /// Slumps slopes steeper than the angle of repose and rounds crests, measured on the snow surface over the bed,
  /// so snow slides off rounded corners. Open layers shed what slides past their ends into `spill`.
  func relax(repose: Float, rounding: Float) -> Bool {
    let n=count
    guard n>1,top>0 else {return false}
    let forward=parity;parity.toggle()
    let limit=repose*columnWidth,open=opensAtEdges,edges=outside
    let result=heights.withUnsafeMutableBufferPointer { h in
      packed.withUnsafeMutableBufferPointer { p in
        bed.withUnsafeBufferPointer { b in
          supported.withUnsafeBytes { held in
            sh_snow_relax(h.baseAddress,p.baseAddress,b.baseAddress,held.baseAddress?.assumingMemoryBound(to:UInt8.self),n,limit,rounding,forward ? 1:0,open ? 1:0,edges.left,edges.right)
          }
        }
      }
    }
    spill.left+=result.left*columnWidth;spill.right+=result.right*columnWidth
    return result.moved != 0
  }

  /// Snow down to `floor` melts slowly; anything heaped above it settles back down over `settle` seconds.
  func thaw(dt: Float, down floor: Float, rate: Float, settle: Float) -> Bool {
    guard top>0 else {return false}
    let n=count
    let fastest=heights.withUnsafeMutableBufferPointer { h in
      packed.withUnsafeMutableBufferPointer { p in sh_snow_thaw(h.baseAddress,p.baseAddress,n,dt,floor,rate,settle) }
    }
    return fastest>0.01
  }

  /// Writes the smoothed snow surface for each column, then the bed under it.
  func writeSmoothed(into buffer: UnsafeMutablePointer<Float>) {
    let n=count
    heights.withUnsafeBufferPointer { h in bed.withUnsafeBufferPointer { b in sh_snow_smooth(h.baseAddress,b.baseAddress,n,buffer) } }
  }

  private func updateBed() {
    if bed.count != count { bed = Array(repeating:0,count:count) }
    let n=count,cw=columnWidth,r=corner.radius,e=corner.exponent
    bedDepth=bed.withUnsafeMutableBufferPointer { b in sh_snow_bed(b.baseAddress,n,cw,r,e) }
  }

  private func updateCapacity() {
    capacity=Array(repeating:0,count:count)
    let n=count,cw=columnWidth,depth=self.depth,phases=self.phases
    capacity.withUnsafeMutableBufferPointer { c in sh_snow_capacity(c.baseAddress,n,cw,depth,phases.0,phases.1) }
  }
}
