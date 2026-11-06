#ifndef ATMOS_WEATHER_CORE_H
#define ATMOS_WEATHER_CORE_H
#include <stddef.h>
#include <stdint.h>
#include <simd/simd.h>

typedef struct { simd_float4 rect, motion, color, life; } SHParticle;
typedef struct {
    float dt, time, width, height, wind, cursor_x, cursor_y, cursor_vx, cursor_vy, motion_scale, previous_x, previous_y;
    uint32_t effect, surface_count, blocker_count;
} SHStep;
typedef struct { float x, y, width, height; uint32_t blocker_start, blocker_count; } SHSurface;
typedef struct { float x, y, amount, impulse; uint32_t surface_index, kind; float vx, vy; } SHImpact;
typedef struct { size_t count, impact_count; } SHStepResult;
SHStepResult sh_step_particles(SHParticle *particles, size_t count, size_t capacity,
    const SHStep *step, const SHSurface *surfaces, const simd_float4 *blockers,
    SHImpact *impacts, size_t impact_capacity);
void sh_apply_airflow(SHParticle *particles, size_t count, const simd_float4 *cells,
    size_t columns, size_t rows, float spacing, float base, float dt);
float sh_step_water(float *depths, float *waves, float *speeds, float *scratch,
    float *heights, const float *bed, size_t count, float dt, float evaporation);
// RGBA: velocity in points/s, transported density, pressure. Sources are local point rectangles.
void sh_step_smoke(simd_float4 *cells, simd_float4 *spare, float *pressure,
    size_t columns, size_t rows, float spacing, float dt, float time, float wind,
    const simd_float4 *cursor, const simd_float2 *previous, const simd_float4 *sources, size_t source_count);

typedef struct { float left, right, left_momentum, right_momentum; } SHWaterOutflow;
SHWaterOutflow sh_transport_water(float *depths, float *velocities, float *mass_scratch,
    float *momentum_scratch, size_t count, float spacing, float dt, float retention_depth);
void sh_couple_liquid(SHParticle *particles, size_t count, float dt, float cursor_x, float cursor_y, float cursor_vx, float cursor_vy);
size_t sh_coalesce_liquid(SHParticle *particles, size_t count);
void sh_liquid_field(const SHParticle *particles, size_t count, simd_float4 *output, simd_float4 *scratch);
#endif
