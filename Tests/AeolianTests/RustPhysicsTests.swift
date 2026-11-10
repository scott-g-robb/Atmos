import CWeatherCore
import XCTest
@testable import Aeolian

final class RustPhysicsTests: XCTestCase {
  func testWindowCursorUsesHalfTheImpulseWithoutChangingDisplacedVolume() {
    func collide(scale:Float)->(volume:Float,impulse:Float) {
      var depths=[Float](repeating:5,count:101),horizontal=[Float](repeating:0,count:101)
      var speeds=horizontal,kicks=[SIMD2<Float>](repeating:.zero,count:101)
      var releases=[SHWaterRelease](repeating:SHWaterRelease(),count:512)
      var cursor=SHWaterCursor(originX:0,originY:0,width:400,spacing:4,supportVX:0,supportVY:0,
        cursorX:200,cursorY:4,previousX:200,previousY:4,velocityX:0,velocityY:-1800,
        splashScale:scale,foam:0,foamCenter:0,foamRadius:0)
      let result=depths.withUnsafeMutableBufferPointer {d in
        horizontal.withUnsafeMutableBufferPointer {h in
          speeds.withUnsafeMutableBufferPointer {v in
            kicks.withUnsafeMutableBufferPointer {k in
              releases.withUnsafeMutableBufferPointer {out in
                sh_collide_water(d.baseAddress,h.baseAddress,v.baseAddress,k.baseAddress,d.count,
                  nil,0,&cursor,out.baseAddress,out.count)
              }
            }
          }
        }
      }
      XCTAssertNotEqual(result.touched,0)
      return (depths.reduce(0,+)+releases.prefix(result.count).reduce(0){$0+$1.amount},kicks.reduce(0){$0+$1.y})
    }
    let full=collide(scale:1),half=collide(scale:0.5)
    XCTAssertEqual(full.volume,505,accuracy:0.001);XCTAssertEqual(half.volume,505,accuracy:0.001)
    XCTAssertGreaterThan(full.impulse,0);XCTAssertEqual(half.impulse,full.impulse*0.5,accuracy:0.01)
  }
  func testHeightFieldResizingKeepsAllRustBufferExtentsEqual() {
    let layer=SnowLayer(origin:.zero,columns:40,columnWidth:3,depth:60,opensAtEdges:true,phases:(0.3,1.2))
    layer.shapeCorners(radius:12,exponent:2.5)
    for count in [120,9,80,4,256,1,64] {
      layer.resize(columns:count)
      XCTAssertEqual(layer.heights.count,count);XCTAssertEqual(layer.bed.count,count)
      XCTAssertEqual(layer.packed.count,count);XCTAssertEqual(layer.capacity.count,count)
      XCTAssertEqual(layer.visible.count,count)
      _=layer.deposit(20,at:Float(count)*1.5,wide:true);layer.refreshTop()
      _=layer.relax(repose:0.8,rounding:0.1)
      XCTAssertTrue(layer.heights.allSatisfy{$0.isFinite && $0>=0})
      for i in 0..<count {XCTAssertTrue(layer.surface(i).isFinite)}
    }
  }
  func testHeightTransportConservesMassIncludingSpilledEdgesAndPackedMass() {
    let layer=SnowLayer(origin:.zero,columns:128,columnWidth:3,depth:50,opensAtEdges:true,phases:(0,0))
    layer.heap(300,against:0,inward:1,slope:0.4);layer.refreshTop()
    let mass=layer.heights.reduce(0,+)*3
    for _ in 0..<120 { _=layer.relax(repose:0.3,rounding:0.1);layer.refreshTop() }
    XCTAssertEqual(layer.heights.reduce(0,+)*3+layer.spill.left+layer.spill.right,mass,accuracy:0.02)
    XCTAssertTrue(zip(layer.packed,layer.heights).allSatisfy{$0.0>=0 && $0.0 <= $0.1+0.001})
  }
  func testEmptyRustHeightFieldsAcceptNullSpansWithoutDereferencingThem() {
    XCTAssertEqual(sh_snow_deposit(nil,0,0,3,20,0,1),20)
    sh_snow_smooth(nil,nil,0,nil)
    sh_snow_capacity(nil,0,3,50,0,0)
    XCTAssertEqual(sh_snow_thaw(nil,nil,0,1/120,0,1,10),0)
  }
}
