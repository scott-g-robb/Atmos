#include "WeatherCore.h"
_Static_assert(sizeof(SHParticle) == 64, "Particle ABI must match Swift and Metal");
_Static_assert(sizeof(SHStep) == 60, "Step ABI must match Rust");
_Static_assert(sizeof(SHSurface) == 24, "Surface ABI must match Rust");
_Static_assert(sizeof(SHImpact) == 32, "Impact ABI must match Rust");

_Static_assert(sizeof(SHWaterOutflow) == 16, "Water transport ABI must match Rust");
typedef struct { float x, y; } SHFlowValue;
extern SHFlowValue sh_sample_wind_value(const simd_float4 *, size_t, size_t, float, float, float, float);
simd_float2 sh_sample_wind(const simd_float4 *cells, size_t columns, size_t rows, float spacing, float base, float x, float y) {
    SHFlowValue v=sh_sample_wind_value(cells,columns,rows,spacing,base,x,y);
    return (simd_float2){v.x,v.y};
}
_Static_assert(sizeof(SHSnowRelaxResult) == 12, "Snow spill ABI must match Rust");
_Static_assert(sizeof(SHSnowFlake) == 112 && offsetof(SHSnowFlake,tintRGBA)==64, "Snow flake ABI");
_Static_assert(sizeof(SHSnowGrain) == 48 && sizeof(SHSnowMote)==32, "Snow body ABI");
_Static_assert(sizeof(SHSnowStep) == 84, "Snow step ABI");
_Static_assert(sizeof(SHWaterRelease) == 24 && sizeof(SHWaterCursor)==64 && sizeof(SHWaterCursorResult)==24, "Water cursor ABI");
_Static_assert(sizeof(SHBird)==80 && sizeof(SHBirdTarget)==16, "Bird physics ABI");
_Static_assert(sizeof(SHWaterField)==96 && sizeof(SHWaterSample)==20, "Water field ABI");
_Static_assert(sizeof(SHFloating)==64 && sizeof(SHDriftStep)==40, "Buoyancy ABI");
_Static_assert(sizeof(SHSnowSupport)==56 && sizeof(SHSnowCut)==32, "Pile interaction ABI");
_Static_assert(sizeof(SHRestingLeaf)==60 && sizeof(SHRestingStep)==68, "Resting botanical ABI");
