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
void sh_build_wind(simd_float4 *cells, size_t columns, size_t rows, float spacing,
    const simd_float4 *windows, size_t window_count, float wind, float turbulence, float time);
simd_float2 sh_sample_wind(const simd_float4 *cells, size_t columns, size_t rows,
    float spacing, float base, float x, float y);
typedef struct { float left, right; uint32_t moved; } SHSnowRelaxResult;
SHSnowRelaxResult sh_snow_relax(float *heights, float *packed, const float *bed,
    const uint8_t *held, size_t count, float limit, float rounding, uint32_t forward,
    uint32_t open, float outside_left, float outside_right);
float sh_snow_deposit(float *heights, size_t count, float base_x, float column_width,
    float area, float x, uint32_t wide);
void sh_snow_heap(float *heights, float *packed, const float *bed, size_t count,
    float column_width, float bed_depth, float area, size_t edge, int32_t inward, float slope);
float sh_snow_thaw(float *heights, float *packed, size_t count, float dt, float floor, float rate, float settle);
void sh_snow_smooth(const float *heights, const float *bed, size_t count, float *output);
float sh_snow_bed(float *bed, size_t count, float column_width, float radius, float exponent);
void sh_snow_capacity(float *capacity, size_t count, float column_width, float depth, float phase_a, float phase_b);
void sh_snow_visible(uint8_t *visible, const float *bed, size_t count, float base_x,
    float origin_y, float column_width, float screen_width, const simd_float4 *blockers, size_t blocker_count);
float sh_snow_slide(float *heights, float *packed, size_t count, int32_t direction);
typedef struct { float x, y; } SHFloat2;
typedef struct {
    simd_float2 position, velocity;
    float retirementLife, fallSpeed, size, depth, alpha, soft, phase, swayRate, swayAmount, mass;
    simd_float4 tintRGBA;
    float tintAmount, blown, leaf, previousY;
    uint32_t settlesFlag, status;
    simd_float2 renderVelocity;
} SHSnowFlake;
typedef struct {
    simd_float2 position, velocity;
    float area, size, lump, seed;
    uint32_t flags, status;
    float previousY;
} SHSnowGrain;
typedef struct { simd_float2 position, velocity; float size, alpha, age, life; } SHSnowMote;
typedef struct {
    float dt, time, wind, weatherWind, slideWind, gustWind, width, gravity, style, grainDrag;
    float cursorX, cursorY, previousX, previousY, cursorVX, cursorVY, wakeX, wakeY, wakeVX, wakeVY;
    uint32_t flags;
} SHSnowStep;
SHFloat2 sh_snow_motion(const SHSnowFlake *flake);
float sh_snow_breeze(double time, float strength, float weather_wind);
void sh_advance_snow_flakes(SHSnowFlake *flakes, size_t count, const SHSnowStep *step,
    const simd_float4 *flow, size_t columns, size_t rows, float spacing, float base);
void sh_advance_snow_grains(SHSnowGrain *grains, size_t count, const SHSnowStep *step,
    const simd_float4 *flow, size_t columns, size_t rows, float spacing, float base);
size_t sh_advance_snow_motes(SHSnowMote *motes, size_t count, float dt, float wind);
typedef struct { simd_float2 point, velocity; float amount; uint32_t continuous; } SHWaterRelease;
typedef struct {
    float originX, originY, width, spacing, supportVX, supportVY;
    float cursorX, cursorY, previousX, previousY, velocityX, velocityY, splashScale;
    float foam, foamCenter, foamRadius;
} SHWaterCursor;
typedef struct { size_t count; uint32_t touched; float foam, foamCenter, foamRadius; } SHWaterCursorResult;
SHWaterCursorResult sh_collide_water(float *depths, float *horizontal, float *speeds,
    simd_float2 *impulses, size_t count, const simd_float4 *blockers, size_t blocker_count,
    const SHWaterCursor *cursor, SHWaterRelease *releases, size_t capacity);
typedef struct {
    simd_float2 position, velocity;
    uint32_t species; float seed, facing, age, phase; uint32_t perchID;
    float perchX, rest, restLimit; uint32_t leavingFlag;
    simd_float2 supportPoint, supportVelocity; float supportSeenAt; uint32_t hasSupport;
} SHBird;
typedef struct { simd_float2 point; uint32_t available; } SHBirdTarget;
size_t sh_step_birds(SHBird *birds, size_t count, const SHBirdTarget *targets,
    SHParticle *particles, float dt, float time, float width, float height,
    float wind, uint32_t active, float cursor_x, float cursor_y,
    const simd_float4 *flow, size_t columns, size_t rows, float spacing, float base);
typedef struct {
    const float *heights, *depths, *horizontal, *speeds;
    const simd_float2 *impulses;
    const simd_float4 *blockers;
    size_t count, blockerCount;
    simd_float2 origin, supportVelocity;
    float width, spacing;
    uint32_t id;
} SHWaterField;
typedef struct { float depth, current, vx, vy; uint32_t accepts; } SHWaterSample;
SHWaterSample sh_sample_water(const SHWaterField *field, float x);
float sh_water_depth(const SHWaterField *field, float x);
void sh_water_hit(float *depths, float *speeds, size_t count, float origin_x,
    float width, float x, float amount, float impulse, float limit, uint32_t bounded);
float sh_water_extract(float *depths, size_t count, float origin_x, float width,
    float x, float radius, float fraction);
void sh_water_kick(simd_float2 *impulses, size_t count, float origin_x,
    float width, float x, float radius, float vx, float vy);
size_t sh_water_impart(float *depths, float *horizontal, const float *speeds,
    const float *bed, const float *waves, simd_float2 *impulses, size_t count,
    SHWaterCursor *context, float vx, float vy, float interval,
    SHWaterRelease *releases, size_t capacity);
size_t sh_water_pressure(float *depths, const float *horizontal, const float *speeds,
    const float *bed, simd_float2 *impulses, size_t count, const SHWaterCursor *context,
    float dt, uint32_t *sustained, SHWaterRelease *releases, size_t capacity);
size_t sh_water_release_all(float *depths, const float *horizontal, const float *speeds,
    const float *bed, const simd_float2 *impulses, size_t count, const SHWaterCursor *context,
    SHWaterRelease *releases, size_t capacity);
typedef struct {
    simd_float2 position, releaseVelocity;
    uint32_t surfaceID; float x, velocity, size, seed, area, turn, age, alpha;
    uint32_t belowDock, status;
} SHFloating;
typedef struct {
    float dt, wind, cursorX, cursorY, previousX, previousY, cursorVX, cursorVY, lifetime;
    uint32_t flags;
} SHDriftStep;
void sh_drift_begin(SHFloating *items, size_t count);
void sh_drift_surface(SHFloating *items, size_t count, const SHWaterField *field, const SHDriftStep *step);
typedef struct {
    simd_float2 track, trackVelocity, offset, offsetVelocity, swingDirection;
    float agitation, swingPeak, previousSwingPeak;
} SHSnowSupport;
void sh_snow_support(SHSnowSupport *support, float target_x, float target_y,
    float dt, float track_time, float gravity, float stick, float hold, float rub, float top);
typedef struct { float x, surface, area, sprayed, side; uint32_t index, held, removed; } SHSnowCut;
size_t sh_snow_carve(float *heights, float *packed, const float *bed, const uint8_t *visible,
    size_t count, float base_x, float base_y, float column_width,
    float cursor_x, float cursor_y, float radius, float vx, float vy,
    float travel, uint32_t final, uint32_t autumn, float leaf_cover, SHSnowCut *cuts);
typedef struct {
    float x, rest, top, size, seed, tilt, around, fromTurn, fromFlip, slide, settling,
        settled, life, age, fade;
} SHRestingLeaf;
typedef struct {
    float dt, pointX, pointY, surface, agitation, leafShaking, retirementRate,
        cursorX, cursorY, cursorVX, cursorVY, cursorRadius, carriedVX, carriedVY,
        outputVX, outputVY;
    uint32_t flags;
} SHRestingStep;
uint32_t sh_tend_resting_leaf(SHRestingLeaf *leaf, SHRestingStep *step, uint64_t *random);
typedef struct { simd_float2 point; float age, strength; } SHWaterRipple;
size_t sh_step_ripples(SHWaterRipple *ripples, size_t count, float dt);
size_t sh_add_ripple(SHWaterRipple *ripples, size_t count, size_t capacity, float x, float y, float strength);
size_t sh_emit_liquid(SHParticle *particles, size_t count, size_t capacity,
    const SHWaterRelease *release, size_t maximum, float phase);
void sh_lightning_liquid(SHParticle *particles, size_t count, float x, float radius,
    float line, float mass, float vx, float vy, float rise, float weight);
typedef struct { float radius, fraction, rise, kick, carriedX, carriedY; } SHSplash;
SHSplash sh_splash_parameters(float vx, float vy, float water_vx, float water_vy, float amount, uint32_t desktop);
size_t sh_snow_erode(float *heights, float *packed, const float *bed, const uint8_t *visible,
    size_t count, float base_x, float base_y, float column_width, float dt, float front,
    float direction, uint32_t mode, uint32_t finish, float share, SHSnowCut *cuts);
#endif
