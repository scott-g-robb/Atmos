#include "WeatherCore.h"
_Static_assert(sizeof(SHParticle) == 64, "Particle ABI must match Swift and Metal");
_Static_assert(sizeof(SHStep) == 60, "Step ABI must match Rust");
_Static_assert(sizeof(SHSurface) == 24, "Surface ABI must match Rust");
_Static_assert(sizeof(SHImpact) == 24, "Impact ABI must match Rust");

_Static_assert(sizeof(SHWaterOutflow) == 16, "Water transport ABI must match Rust");
