import CWeatherCore
import simd

// Swift constructs visual/emission state; Rust integrates this exact storage in
// place. These C-defined layouts avoid copies and Swift/Rust ABI assumptions.
extension SHSnowFlake {
  var settles: Bool { get { settlesFlag != 0 } set { settlesFlag=newValue ? 1:0 } }
  var tint: SIMD3<Float> {
    get { SIMD3(tintRGBA.x,tintRGBA.y,tintRGBA.z) }
    set { tintRGBA=SIMD4(newValue,1) }
  }
  init(retirementLife: Float = .greatestFiniteMagnitude, position: SIMD2<Float>, velocity: SIMD2<Float>,
    fallSpeed: Float, size: Float, depth: Float, alpha: Float, soft: Float, phase: Float,
    swayRate: Float, swayAmount: Float, settles: Bool, mass: Float = 1,
    tint: SIMD3<Float> = SIMD3(repeating:1), tintAmount: Float = 0, blown: Float = 0, leaf: Float = 0) {
    self.init();self.retirementLife=retirementLife;self.position=position;self.velocity=velocity
    self.fallSpeed=fallSpeed;self.size=size;self.depth=depth;self.alpha=alpha;self.soft=soft
    self.phase=phase;self.swayRate=swayRate;self.swayAmount=swayAmount;self.settles=settles
    self.mass=mass;self.tint=tint;self.tintAmount=tintAmount;self.blown=blown;self.leaf=leaf
    refreshMotion()
  }
  mutating func refreshMotion() {
    let v=withUnsafePointer(to:&self) { sh_snow_motion($0) }
    renderVelocity=SIMD2(v.x,v.y)
  }
}
extension SHSnowGrain {
  var blown: Bool { get { flags & 1 != 0 } set { flags=newValue ? flags | 1:flags & ~1 } }
  var bulk: Bool { get { flags & 2 != 0 } set { flags=newValue ? flags | 2:flags & ~2 } }
  init(position: SIMD2<Float>, velocity: SIMD2<Float>, area: Float, size: Float,
    lump: Float = 0, blown: Bool = false, seed: Float = Float.random(in:0.001...1), bulk: Bool = false) {
    self.init();self.position=position;self.velocity=velocity;self.area=area;self.size=size
    self.lump=lump;self.blown=blown;self.seed=seed;self.bulk=bulk
  }
}
extension SHSnowMote {
  init(position: SIMD2<Float>, velocity: SIMD2<Float>, size: Float, alpha: Float, age: Float = 0,
    life: Float, usingDefaults: Bool = true) {
    self.init();self.position=position;self.velocity=velocity;self.size=size;self.alpha=alpha;self.age=age;self.life=life
  }
}
