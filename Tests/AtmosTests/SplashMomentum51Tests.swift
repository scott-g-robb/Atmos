import CWeatherCore
import XCTest
@testable import Atmos

final class SplashMomentum51Tests:XCTestCase {
  private let away=SIMD2<Float>(-1000,-1000)
  private func groundFixture()->WeatherSimulation {
    let sim=WeatherSimulation(size:SIMD2(800,800),seed:42);sim.intensity = .off;sim.evaporates=false
    for x in stride(from:Float(0),through:800,by:4) {sim.water[0].hit(x:x,amount:16,impulse:0)}
    for _ in 0..<60 {sim.step(dt:1/120,cursor:away)}
    return sim
  }
  func testVerticalRainHasSmallRadialSprayAndWindMomentumIsRetained() {
    for wind:Float in [0,180] {
      let sim=groundFixture(),pool=sim.water[0],mass=sim.water[0].volume
      sim.impactSplash(surface:pool,x:400,velocity:SIMD2(wind,-800),amount:2)
      let drops=sim.particles.filter {$0.motion.w==9}
      XCTAssertGreaterThan(drops.count,4)
      let mean=drops.reduce(SIMD2<Float>.zero) {$0+SIMD2($1.motion.x,$1.motion.y)}/Float(drops.count)
      XCTAssertEqual(mean.x,wind*0.8,accuracy:1)
      XCTAssertTrue(drops.allSatisfy {abs($0.motion.x-wind*0.8)<$0.motion.y*0.15})
      XCTAssertEqual(pool.volume+drops.reduce(Float(0)) {$0+$1.life.z},mass,accuracy:0.1)
    }
  }
  func testGroundImpactsCannotConsumeTheWindowPuddleSplashAllowance() {
    let sim=groundFixture()
    sim.updateWindows([WindowSurface(id:41,frame:CGRect(x:100,y:200,width:600,height:200),blockers:[],cornerRadius:18,cornerExponent:2.5,isDock:false)])
    let pool=sim.water[1]
    for x in stride(from:pool.origin.x,through:pool.origin.x+pool.width,by:4) {pool.hit(x:x,amount:3,impulse:0)}
    for _ in 0..<60 {sim.step(dt:1/120,cursor:away)}
    for _ in 0..<3 {sim.impactSplash(surface:sim.water[0],x:400,velocity:SIMD2(0,-800),amount:2)}
    sim.impactSplash(surface:pool,x:400,velocity:SIMD2(0,-800),amount:2)
    XCTAssertGreaterThan(sim.particles.filter {$0.motion.w==9 && $0.rect.y>pool.origin.y}.count,4)
  }
  func testLightningProducesABroadHighVolumeCrownWithoutCreatingWater() {
    let sim=groundFixture(),pool=sim.water[0],mass=sim.water[0].volume
    sim.lightningSplash(surface:pool,x:400)
    let drops=sim.particles.filter {$0.motion.w==9}
    XCTAssertGreaterThan(drops.count,100)
    XCTAssertGreaterThan(drops.map {$0.motion.y}.max() ?? 0,700)
    XCTAssertGreaterThan((drops.map {$0.rect.x}.max() ?? 0)-(drops.map {$0.rect.x}.min() ?? 0),80)
    XCTAssertEqual(pool.volume+drops.reduce(Float(0)) {$0+$1.life.z},mass,accuracy:0.15)
  }
  func testPhysicsImpactReportsMeasuredVelocity() {
    var particles=[WeatherParticle(rect:SIMD4(200,102,1,10),motion:SIMD4(120,-800,0.1,0),color:SIMD4(repeating:1),life:SIMD4(0,10,0,0))]
    var surfaces=[SHSurface(x:0,y:100,width:800,height:3,blocker_start:0,blocker_count:0)]
    var impacts=[SHImpact](repeating:SHImpact(),count:4)
    var step=SHStep(dt:1/120,time:0,width:800,height:400,wind:120,cursor_x:-1000,cursor_y:-1000,cursor_vx:0,cursor_vy:0,motion_scale:1,previous_x:-1000,previous_y:-1000,effect:1,surface_count:1,blocker_count:0)
    let result=particles.withUnsafeMutableBufferPointer {p in surfaces.withUnsafeBufferPointer {s in impacts.withUnsafeMutableBufferPointer {i in
      sh_step_particles(p.baseAddress,1,1,&step,s.baseAddress,nil,i.baseAddress,4)
    }}}
    XCTAssertEqual(MemoryLayout<SHImpact>.stride,32);XCTAssertEqual(result.impact_count,1)
    XCTAssertEqual(impacts[0].vx,120,accuracy:1);XCTAssertEqual(impacts[0].vy,-800,accuracy:1)
  }
}
