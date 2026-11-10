import AppKit
import Metal
import XCTest
@testable import Aeolian

final class RustMigrationBenchmarkTests: XCTestCase {
  func testProfilePhysicsKernelsWhenRequested() throws {
    guard let output=ProcessInfo.processInfo.environment["ATMOS_PHYSICS_BENCHMARK_DIR"] else {
      throw XCTSkip("Set ATMOS_PHYSICS_BENCHMARK_DIR for physics migration baselines")
    }
    var report=[[String:Any]]()
    var windows=[SIMD4<Float>]()
    for i in 0..<8 {
      let x=Float(i%4)*700, y=Float(i/4)*700
      windows.append(SIMD4(x+50,y+100,x+650,y+600))
    }
    let field=WindField(),size=SIMD2<Float>(3024,1964)
    var start=CACurrentMediaTime()
    for i in 0..<360 {field.update(size:size,windows:windows,wind:70,turbulence:20,time:Double(i)/10)}
    report.append(["kernel":"wind field","milliseconds_per_step":(CACurrentMediaTime()-start)/360*1000,"cells":field.cells.count])
    let layer=SnowLayer(origin:.zero,columns:1008,columnWidth:3,depth:80,opensAtEdges:true,phases:(0.3,1.2))
    for i in stride(from:0,to:1008,by:7) {layer.deposit(300,at:Float(i)*3,wide:true)}
    layer.refreshTop();start=CACurrentMediaTime()
    for i in 0..<2400 {
      layer.deposit(9,at:Float((i*37)%1008)*3,wide:true)
      _=layer.relax(repose:0.8,rounding:0.1);layer.refreshTop()
    }
    report.append(["kernel":"snow piles","milliseconds_per_step":(CACurrentMediaTime()-start)/2400*1000,"columns":layer.count])
    for style:Float in [0,1,3,5] {
      let sim=SnowSimulation(width:1920,height:1080,snowfall:.heavy)
      if style>0 {sim.autumn=true;sim.botanicalStyle=style}
      sim.weatherWind=45;sim.airflow=field
      for i in 0..<1200 {_=sim.step(dt:1/120,cursor:SIMD2(Float(i%1920),250))}
      start=CACurrentMediaTime()
      for i in 0..<2400 {_=sim.step(dt:1/120,cursor:SIMD2(Float((i*13)%1920),250+sin(Float(i)*0.03)*150))}
      report.append(["kernel":"snow/botanical scene \(Int(style))","milliseconds_per_step":(CACurrentMediaTime()-start)/2400*1000,"sprites":sim.spriteCount])
    }
    try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
      .write(to:URL(fileURLWithPath:output).appendingPathComponent("physics.json"))
  }
}
