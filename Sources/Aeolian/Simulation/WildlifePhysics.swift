import CWeatherCore
import CoreGraphics

extension SHBird {
  var perch: CGWindowID? {get {perchID==0 ? nil:perchID} set {perchID=newValue ?? 0}}
  init(position: SIMD2<Float>, velocity: SIMD2<Float>, species: Int, seed: Float,
    perch: CGWindowID?, perchX: Float, restLimit: Float) {
    self.init();self.position=position;self.velocity=velocity;self.species=UInt32(species)
    self.seed=seed;facing=1;self.perch=perch;self.perchX=perchX;self.restLimit=restLimit
  }
}
