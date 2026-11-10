import AppKit
import XCTest
@testable import Aeolian

final class WaterPolish50Tests:XCTestCase {
  private let away=SIMD2<Float>(-1000,-1000)
  func testWindControlDisablesManualAdjustmentWhileAutomatic() throws {
    let control=WindSlider();control.speed=42
    let slider=try XCTUnwrap(control.subviews.compactMap {$0 as? NSSlider}.first)
    XCTAssertTrue(slider.isEnabled);XCTAssertEqual(slider.doubleValue,42)
    control.automatic=true
    XCTAssertFalse(slider.isEnabled);XCTAssertEqual(slider.doubleValue,42)
    control.automatic=false;XCTAssertTrue(slider.isEnabled)
    let defaults=UserDefaults.standard,old=UserDefaults.standard.object(forKey:"manualWindSpeed")
    defer {if let old {defaults.set(old,forKey:"manualWindSpeed")} else {defaults.removeObject(forKey:"manualWindSpeed")}}
    Preferences.manualWindSpeed=135;XCTAssertEqual(Preferences.manualWindSpeed,100)
    Preferences.manualWindSpeed = -20;XCTAssertEqual(Preferences.manualWindSpeed,0)
    let storm=WeatherSimulation(size:SIMD2(800,400),seed:42)
    storm.setEffect(.storm);storm.manualWind=true;storm.wind=36
    storm.step(dt:1/120,cursor:away)
    XCTAssertTrue(storm.particles.filter {$0.motion.w==0}.allSatisfy {abs($0.motion.x-36)<1},"Manual wind must replace the storm preset's hidden sideways boost")
  }

  func testUnderwaterLitterIsClippedAndFloatsClearTheWaterline() {
    let sim=SnowSimulation(width:800,height:300,snowfall:.heavy);sim.autumn=true
    for _ in 0..<2400 {_=sim.step(dt:1/60,cursor:away)}
    let pool=WaterSurface(id:0,origin:.zero,width:800)
    for x in stride(from:Float(0),through:800,by:4) {pool.hit(x:x,amount:18,impulse:0)}
    for _ in 0..<60 {pool.step(dt:1/120,evaporates:false,clearing:false)}
    sim.waterSurfaces=[pool];_=sim.step(dt:1/120,cursor:away)
    XCTAssertGreaterThan(sim.surfaceDrift.count,0)
    for sprite in sim.surfaceDrift.sprites {
      XCTAssertGreaterThanOrEqual(sprite.position.y-pool.depth(at:sprite.position.x),sprite.size*0.054)
      XCTAssertEqual(sprite.flip,0.16)
    }
    let buffer=UnsafeMutablePointer<Float>.allocate(capacity:sim.columnCount)
    defer {buffer.deallocate()}
    let layers=sim.writeLayers(into:buffer,capacity:sim.columnCount)
    XCTAssertFalse(layers.isEmpty)
    for layer in layers {
      for i in 0..<layer.count {
        let x=layer.origin.x+(Float(i)+0.5)*2
        if pool.accepts(x:x),pool.depth(at:x)>0.3 {
          XCTAssertGreaterThanOrEqual(buffer[layer.offset+layer.count+i]+layer.origin.y,pool.depth(at:x)-0.01)
        }
      }
    }
  }

  func testMapleMaterialDecaysWithoutEnablingGlobalThaw() {
    let sim=SnowSimulation(width:800,height:300,snowfall:.heavy)
    sim.botanicalStyle=5;sim.autumn=true;sim.thaws=false
    for _ in 0..<2400 {_=sim.step(dt:1/60,cursor:away)}
    XCTAssertGreaterThan(sim.spriteCount,0)
    sim.snowfall = .off
    for _ in 0..<4800 {_=sim.step(dt:1/60,cursor:away)}
    XCTAssertEqual(sim.spriteCount,0)
    XCTAssertLessThan(sim.pileTop,0.1)
  }

  func testRainImpactSpeedScalesSplashAndStormRipplesStayBounded() {
    func peak(_ effect:WeatherEffect)->Float {
      let sim=WeatherSimulation(size:SIMD2(800,400),seed:42);sim.setEffect(effect)
      sim.evaporates=false;sim.intensity = .heavy
      for x in stride(from:Float(0),through:800,by:4) {sim.water[0].hit(x:x,amount:8,impulse:0)}
      var result:Float=0
      for _ in 0..<180 {
        sim.step(dt:1/120,cursor:away)
        result=max(result,sim.particles.filter {$0.motion.w==9}.map {$0.motion.y}.max() ?? 0)
        XCTAssertLessThanOrEqual(sim.ripples.count,32)
        XCTAssertTrue(sim.ripples.allSatisfy {$0.strength<=1.7})
      }
      return result
    }
    let drizzle=peak(.drizzle),storm=peak(.storm)
    XCTAssertGreaterThan(drizzle,10);XCTAssertGreaterThan(storm,drizzle*1.2)
  }

  func testLightningTransfersEnergyToAnExistingPuddle() {
    let sim=WeatherSimulation(size:SIMD2(800,400),seed:42);sim.setEffect(.lightning)
    sim.evaporates=false;sim.intensity = .light
    for x in stride(from:Float(0),through:800,by:4) {sim.water[0].hit(x:x,amount:10,impulse:0)}
    var peak:Float=0
    for _ in 0..<480 {
      sim.step(dt:1/60,cursor:away)
      peak=max(peak,sim.particles.filter {$0.motion.w==9}.map {$0.motion.y}.max() ?? 0)
    }
    XCTAssertNotNil(sim.lastStrikeTarget);XCTAssertGreaterThan(peak,350)
  }
}
