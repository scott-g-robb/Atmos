#![cfg_attr(not(test), no_std)]

// Allocation-free C ABI kernels. Swift owns all memory and macOS integration; Metal owns drawing.
use core::slice;
mod atmosphere;
mod liquid_emission;
#[cfg(test)]
mod liquid_reference;
mod pile_interaction;
mod snow;
mod water_fields;
mod water_interaction;
mod wildlife;

unsafe extern "C" {
    fn sinf(x: f32) -> f32;
    fn cosf(x: f32) -> f32;
    fn expf(x: f32) -> f32;
    fn sqrtf(x: f32) -> f32;
    fn atan2f(y: f32, x: f32) -> f32;
    #[cfg(not(test))]
    fn abort() -> !;
}
#[cfg(not(test))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo<'_>) -> ! {
    unsafe { abort() }
}
#[inline]
fn sin(x: f32) -> f32 {
    unsafe { sinf(x) }
}
#[inline]
fn cos(x: f32) -> f32 {
    unsafe { cosf(x) }
}
#[inline]
fn exp(x: f32) -> f32 {
    unsafe { expf(x) }
}
#[inline]
fn len(x: f32, y: f32) -> f32 {
    unsafe { sqrtf(x * x + y * y) }
}
#[inline]
fn fract(x: f32) -> f32 {
    x - (x as i32 as f32)
}

#[repr(C, align(16))]
#[derive(Clone, Copy, Default)]
pub struct Particle {
    pub rect: [f32; 4],
    pub motion: [f32; 4],
    pub color: [f32; 4],
    pub life: [f32; 4],
}
#[repr(C)]
pub struct Step {
    pub dt: f32,
    pub time: f32,
    pub width: f32,
    pub height: f32,
    pub wind: f32,
    pub cursor_x: f32,
    pub cursor_y: f32,
    pub cursor_vx: f32,
    pub cursor_vy: f32,
    pub motion_scale: f32,
    pub previous_x: f32,
    pub previous_y: f32,
    pub effect: u32,
    pub surface_count: u32,
    pub blocker_count: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Surface {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub blocker_start: u32,
    pub blocker_count: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Impact {
    pub x: f32,
    pub y: f32,
    pub amount: f32,
    pub impulse: f32,
    pub surface_index: u32,
    pub kind: u32,
    pub vx: f32,
    pub vy: f32,
}
#[repr(C)]
pub struct StepResult {
    pub count: usize,
    pub impact_count: usize,
}

/// # Safety
/// All nonempty spans must point to initialized, disjoint storage of their declared lengths.
/// Particle capacity includes room for the generated firefly trails, at most 128 in one call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_step_particles(
    ptr: *mut Particle,
    count: usize,
    capacity: usize,
    step: *const Step,
    surfaces: *const Surface,
    blockers: *const [f32; 4],
    impacts: *mut Impact,
    impact_capacity: usize,
) -> StepResult {
    if count == 0 || ptr.is_null() || step.is_null() || capacity < count {
        return StepResult {
            count: 0,
            impact_count: 0,
        };
    }
    let s = unsafe { &*step };
    if !s.dt.is_finite() || s.dt <= 0.0 || s.width <= 0.0 || s.height <= 0.0 {
        return StepResult {
            count,
            impact_count: 0,
        };
    }
    let particles = unsafe { slice::from_raw_parts_mut(ptr, capacity) };
    let ledges = if s.surface_count == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(surfaces, s.surface_count as usize) }
    };
    let covers = if s.blocker_count == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(blockers, s.blocker_count as usize) }
    };
    let events = if impact_capacity == 0 {
        &mut [][..]
    } else {
        unsafe { slice::from_raw_parts_mut(impacts, impact_capacity) }
    };
    let dt = s.dt.min(0.05);
    let cursor_speed = len(s.cursor_vx, s.cursor_vy);
    let mut groups = [[0.0f32; 3]; 12];
    for p in particles.iter().take(count) {
        if p.motion[3] == 4.0 {
            let g = (p.life[2] as usize).min(11);
            groups[g][0] += p.rect[0];
            groups[g][1] += p.rect[1];
            groups[g][2] += 1.0;
        }
    }
    let mut live_flies = 0;
    let mut live_butterflies = 0;
    let mut out = 0;
    let mut event_count = 0;
    let mut trails = [Particle::default(); 128];
    let mut trail_count = 0;
    let drag = exp(-dt * 0.6);
    for index in 0..count {
        let mut p = particles[index];
        p.life[0] += dt;
        if p.life[0] >= p.life[1] || !p.rect[0].is_finite() || !p.rect[1].is_finite() {
            continue;
        }
        let kind = p.motion[3] as u32;
        if kind == 4 {
            if live_flies >= 40 {
                continue;
            }
            live_flies += 1;
        }
        if kind == 13 {
            if live_butterflies >= 12 {
                continue;
            }
            live_butterflies += 1;
        }
        if kind == 6 {
            particles[out] = p;
            out += 1;
            continue;
        }
        let x = p.rect[0];
        let y = p.rect[1];
        let seed = p.motion[2];
        let mut vx = p.motion[0];
        let mut vy = p.motion[1];
        // A stationary pointer cannot transfer momentum. Avoid segment projection
        // and square roots for every particle when there is no interaction.
        if kind != 2 && kind != 9 && cursor_speed > 6.0 {
            let sx = s.cursor_x - s.previous_x;
            let sy = s.cursor_y - s.previous_y;
            let fraction = (((x - s.previous_x) * sx + (y - s.previous_y) * sy)
                / (sx * sx + sy * sy).max(0.001))
            .clamp(0.0, 1.0);
            let dx = x - (s.previous_x + sx * fraction);
            let dy = y - (s.previous_y + sy * fraction);
            let distance2 = dx * dx + dy * dy;
            if distance2 < 18.0 * 18.0 && distance2 > 0.01 * 0.01 {
                let distance = len(dx, dy);
                let gain = (1.0 - distance / 18.0) * (dt * 18.0).min(1.0);
                vx +=
                    (dx / distance * (cursor_speed * 0.12).min(160.0) + s.cursor_vx * 0.25) * gain;
                vy +=
                    (dy / distance * (cursor_speed * 0.12).min(160.0) + s.cursor_vy * 0.25) * gain;
            }
        }
        match kind {
            0 => {
                let gust = if s.effect == 1 {
                    0.0
                } else if s.effect == 2 {
                    sin(s.time * 0.57) * 75.0 + 70.0
                } else {
                    12.0
                };
                vx += (s.wind
                    + gust
                    + sin(s.time * 0.7 + seed * 9.0)
                        * (if s.effect == 1 {
                            s.wind.abs() * 0.05
                        } else {
                            12.0
                        })
                    - vx)
                    * (dt * 1.8).min(1.0);
            }
            1 | 5 | 9 => {
                vy -= (if kind == 1 { 750.0 } else { 950.0 }) * dt;
                vx *= drag;
            }
            2 => {
                vx += (s.wind * 0.16 + sin(s.time * 0.13 + seed * 17.0) * 7.0 - vx)
                    * (dt * 0.65).min(1.0);
                vy += (cos(s.time * 0.18 + seed * 19.0) * 2.5 - vy) * (dt * 0.65).min(1.0);
            }
            3 => {
                vx += (sin(s.time * 0.27 + seed * 14.0) * 15.0 + s.wind * 0.10 - vx) * dt;
                vy += (6.0 + cos(s.time * 0.41 + seed * 23.0) * 9.0 - vy) * dt;
            }
            4 => {
                // Several loose swarms, each following its own moving centre. Individual epicycles,
                // cohesion and curl produce looping, crossing trajectories without an O(n²) flock.
                let g = (p.life[2] as usize).min(11);
                let group = g as f32;
                let cx = s.width * (0.19 + 0.62 * fract(group * 0.618034 + 0.13))
                    + sin(s.time * 0.11 + group * 2.4) * s.width * 0.07;
                let cy = s.height * (0.2 + 0.58 * fract(group * 0.381966 + 0.27))
                    + cos(s.time * 0.09 + group * 1.7) * s.height * 0.07;
                let phase = s.time * (0.39 + seed * 0.35) + seed * 31.0;
                let radius = (45.0 + seed * 95.0).min(s.width * 0.18);
                let mut tx =
                    cx + sin(phase) * radius + sin(phase * 1.73 + seed * 7.0) * radius * 0.32;
                let mut ty =
                    cy + cos(phase * 0.82) * radius * 0.6 + sin(phase * 1.43) * radius * 0.25;
                if groups[g][2] > 1.0 {
                    tx = tx * 0.88 + groups[g][0] / groups[g][2] * 0.12;
                    ty = ty * 0.88 + groups[g][1] / groups[g][2] * 0.12;
                }
                vx += ((tx - x) * 1.05 - vx * 1.35) * dt;
                vy += ((ty - y) * 1.05 - vy * 1.35) * dt;
                let speed = len(vx, vy);
                if speed > 105.0 {
                    vx *= 105.0 / speed;
                    vy *= 105.0 / speed;
                }
            }
            13 => {
                vx += (sin(s.time * 0.43 + seed * 31.0) * 42.0 + s.wind * 0.10 - vx) * dt * 1.4;
                vy += (cos(s.time * 0.67 + seed * 19.0) * 24.0
                    + sin(s.time * 1.7 + seed * 9.0) * 12.0
                    - vy)
                    * dt
                    * 1.6;
            }
            _ => {}
        }
        if kind == 13 && len(vx, vy) > 2.0 {
            let target = unsafe { atan2f(-vx, vy) };
            let mut delta = target - p.life[3];
            while delta > core::f32::consts::PI {
                delta -= core::f32::consts::TAU;
            }
            while delta < -core::f32::consts::PI {
                delta += core::f32::consts::TAU;
            }
            p.life[3] += delta * (dt * 3.5).min(1.0);
            if p.life[3] > core::f32::consts::PI {
                p.life[3] -= core::f32::consts::TAU;
            }
            if p.life[3] < -core::f32::consts::PI {
                p.life[3] += core::f32::consts::TAU;
            }
        }
        let slow = if (2..=4).contains(&kind) || kind == 13 {
            s.motion_scale
        } else {
            1.0
        };
        p.rect[0] += vx * dt * slow;
        p.rect[1] += vy * dt * slow;
        if kind == 9 {
            if p.rect[0] < 3.0 {
                p.rect[0] = 3.0;
                vx = vx.abs() * 0.28;
            }
            if p.rect[0] > s.width - 3.0 {
                p.rect[0] = s.width - 3.0;
                vx = -vx.abs() * 0.28;
            }
        }
        p.motion[0] = vx;
        p.motion[1] = vy;
        if kind == 2 || kind == 3 || kind == 4 || kind == 13 {
            // Keep atmosphere on the display. Wide mist billows wrap continuously rather than flying away.
            let margin = if kind == 2 {
                p.rect[2] * 0.5 + 5.0
            } else {
                12.0
            };
            if p.rect[0] < -margin {
                p.rect[0] = s.width + margin;
            }
            if p.rect[0] > s.width + margin {
                p.rect[0] = -margin;
            }
            if p.rect[1] < -margin {
                p.rect[1] = s.height + margin;
            }
            if p.rect[1] > s.height + margin {
                p.rect[1] = -margin;
            }
        }
        let mut landed = false;
        if (kind == 0 || kind == 1 || kind == 5 || kind == 9)
            && vy < 0.0
            && (kind != 9 || p.life[0] > 0.012)
        {
            let mut best = None;
            let mut top = -f32::MAX;
            for (i, l) in ledges.iter().enumerate() {
                if l.y < top
                    || y < l.y
                    || p.rect[1] > l.y + l.height
                    || p.rect[0] < l.x
                    || p.rect[0] > l.x + l.width
                {
                    continue;
                }
                let start = l.blocker_start as usize;
                let end = (start + l.blocker_count as usize).min(covers.len());
                if start > end {
                    continue;
                }
                if covers[start..end].iter().any(|b| {
                    p.rect[0] >= b[0] && p.rect[0] <= b[2] && l.y >= b[1] - 1.0 && l.y <= b[3] + 1.0
                }) {
                    continue;
                }
                best = Some(i);
                top = l.y;
            }
            if let Some(surface) = best {
                let hit_y = ledges[surface].y + ledges[surface].height.max(0.5);
                if kind == 1 && p.life[2] < 2.0 {
                    p.rect[1] = hit_y + p.rect[2] * 0.5;
                    p.motion[1] = (vy.abs() * if p.life[2] == 0.0 { 0.46 } else { 0.28 }).max(65.0);
                    p.motion[0] += (seed - 0.5) * 140.0;
                    p.life[2] += 1.0;
                } else {
                    landed = true;
                }
                if event_count < events.len() {
                    events[event_count] = Impact {
                        x: p.rect[0],
                        y: hit_y,
                        amount: if kind == 5 || kind == 9 {
                            p.life[2]
                        } else {
                            2.0
                        },
                        impulse: if kind == 9 {
                            (vy.abs() * 0.012).min(8.0)
                        } else if kind == 5 {
                            0.4
                        } else {
                            (vy.abs() * 0.004).clamp(0.4, 8.0)
                        },
                        surface_index: surface as u32,
                        kind,
                        vx,
                        vy,
                    };
                    event_count += 1;
                }
            }
        }
        if !landed
            && p.rect[1] > -60.0
            && p.rect[0] > -500.0
            && p.rect[0] < s.width + 500.0
            && p.rect[1] < s.height + 500.0
        {
            if kind == 4 {
                p.life[3] += dt;
                if p.life[3] >= 0.08 && trail_count < trails.len() {
                    p.life[3] = 0.0;
                    let distance = len(p.rect[0] - x, p.rect[1] - y);
                    if distance > 0.1 && distance < 30.0 {
                        trails[trail_count] = Particle {
                            rect: [
                                (p.rect[0] + x) * 0.5,
                                (p.rect[1] + y) * 0.5,
                                5.0,
                                distance + 3.0,
                            ],
                            motion: [vx, vy, seed, 6.0],
                            color: [0.91, 0.88 + seed * 0.1, 0.37 + seed * 0.2, 0.46],
                            life: [0.0, 0.48 + seed * 0.28, 0.0, 0.0],
                        };
                        trail_count += 1;
                    }
                }
            }
            particles[out] = p;
            out += 1;
        }
    }
    let available = (capacity - out).min(trail_count);
    particles[out..out + available].copy_from_slice(&trails[..available]);
    StepResult {
        count: out + available,
        impact_count: event_count,
    }
}

/// # Safety
/// Six disjoint arrays of `count` floats. No allocation, cached bed geometry, stable substeps.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_step_water(
    depths: *mut f32,
    waves: *mut f32,
    speeds: *mut f32,
    scratch: *mut f32,
    heights: *mut f32,
    bed: *const f32,
    count: usize,
    dt: f32,
    evaporation: f32,
) -> f32 {
    if count < 3 || !dt.is_finite() || dt <= 0.0 {
        return 0.0;
    }
    let original = unsafe { slice::from_raw_parts_mut(depths, count) };
    let wave = unsafe { slice::from_raw_parts_mut(waves, count) };
    let speed = unsafe { slice::from_raw_parts_mut(speeds, count) };
    let spare = unsafe { slice::from_raw_parts_mut(scratch, count) };
    let shown = unsafe { slice::from_raw_parts_mut(heights, count) };
    let bed = unsafe { slice::from_raw_parts(bed, count) };
    let steps = ((dt.min(0.05) * 120.0) as usize + 1).min(7);
    let h = dt.min(0.05) / steps as f32;
    let damping = exp(-h * 3.0);
    // Surface pressure equalizes displaced water within a fraction of a second.
    let diffusion = (h * 90.0).min(0.24);
    let mut current: &mut [f32] = original;
    let mut next: &mut [f32] = spare;
    for _ in 0..steps {
        for i in 0..count {
            let left = i.saturating_sub(1);
            let right = (i + 1).min(count - 1);
            speed[i] = (speed[i] + (wave[left] + wave[right] - 2.0 * wave[i]) * 180.0 * h
                - wave[i] * 14.0 * h)
                * damping;
            next[i] = (current[i]
                + (current[left] + current[right] - 2.0 * current[i]) * diffusion
                - evaporation * h)
                .max(0.0);
        }
        core::mem::swap(&mut current, &mut next);
        for i in 0..count {
            wave[i] = (wave[i] + speed[i] * h).clamp(-2.5, 2.5);
        }
    }
    let mut top = 0.0f32;
    for i in 0..count {
        let water = (current[i] - bed[i]).max(0.0);
        shown[i] = if water > 0.0 {
            (water + wave[i] * water.min(1.0)).max(0.0)
        } else {
            0.0
        };
        top = top.max(shown[i]);
    }
    if steps % 2 == 1 {
        unsafe { core::ptr::copy_nonoverlapping(scratch, depths, count) };
    }
    top
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn abi_layout() {
        assert_eq!(core::mem::size_of::<Particle>(), 64);
        assert_eq!(core::mem::align_of::<Particle>(), 16);
        assert_eq!(core::mem::size_of::<Step>(), 60);
        assert_eq!(core::mem::size_of::<Surface>(), 24);
        assert_eq!(core::mem::size_of::<Impact>(), 32);
    }
    #[test]
    fn water_conserves_volume_and_stays_finite() {
        let mut d = [0.0; 128];
        d[64] = 12.0;
        let mut w = [0.0; 128];
        let mut v = [0.0; 128];
        let mut s = [0.0; 128];
        let mut h = [0.0; 128];
        let b = [0.1; 128];
        for _ in 0..10000 {
            unsafe {
                sh_step_water(
                    d.as_mut_ptr(),
                    w.as_mut_ptr(),
                    v.as_mut_ptr(),
                    s.as_mut_ptr(),
                    h.as_mut_ptr(),
                    b.as_ptr(),
                    128,
                    1.0 / 30.0,
                    0.0,
                )
            };
        }
        assert!((d.iter().sum::<f32>() - 12.0).abs() < 0.01);
        assert!(h.iter().all(|x| x.is_finite() && *x >= 0.0));
    }
    #[test]
    fn trails_are_bounded_and_stationary() {
        let mut p = [Particle::default(); 256];
        p[0] = Particle {
            rect: [100.0, 100.0, 12.0, 12.0],
            motion: [40.0, 10.0, 0.3, 4.0],
            color: [1.0; 4],
            life: [0.0, 30.0, 0.0, 0.1],
        };
        let s = Step {
            dt: 1.0 / 30.0,
            time: 0.0,
            width: 1000.0,
            height: 800.0,
            wind: 0.0,
            cursor_x: -100.0,
            cursor_y: -100.0,
            cursor_vx: 0.0,
            cursor_vy: 0.0,
            motion_scale: 1.0,
            previous_x: -1000.0,
            previous_y: -1000.0,
            effect: 8,
            surface_count: 0,
            blocker_count: 0,
        };
        let result = unsafe {
            sh_step_particles(
                p.as_mut_ptr(),
                1,
                p.len(),
                &s,
                core::ptr::null(),
                core::ptr::null(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(result.count, 2);
        let old = p[1].rect;
        unsafe {
            sh_step_particles(
                p.as_mut_ptr(),
                2,
                p.len(),
                &s,
                core::ptr::null(),
                core::ptr::null(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(p[1].rect, old);
    }
    #[test]
    fn empty_spans_are_safe() {
        let r = unsafe {
            sh_step_particles(
                core::ptr::null_mut(),
                0,
                0,
                core::ptr::null(),
                core::ptr::null(),
                core::ptr::null(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(r.count, 0);
    }
}

/// Bounded semi-Lagrangian smoke with incompressible flow. Caller owns all scratch storage.
/// # Safety
/// Three disjoint grid spans and a valid source span, with at least 3x3 cells.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_step_smoke(
    cells: *mut [f32; 4],
    spare: *mut [f32; 4],
    pressure: *mut f32,
    columns: usize,
    rows: usize,
    spacing: f32,
    dt: f32,
    time: f32,
    wind: f32,
    cursor: *const [f32; 4],
    previous: *const [f32; 2],
    sources: *const [f32; 4],
    source_count: usize,
) {
    if columns < 3 || rows < 3 || spacing <= 0.0 || dt <= 0.0 {
        return;
    }
    let cursor = unsafe { &*cursor };
    let previous = unsafe { &*previous };
    let n = columns * rows;
    let c = unsafe { slice::from_raw_parts_mut(cells, n) };
    let s = unsafe { slice::from_raw_parts_mut(spare, n) };
    let p = unsafe { slice::from_raw_parts_mut(pressure, n) };
    let sources = if source_count == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(sources, source_count) }
    };
    let dt = dt.min(0.05);
    let sx = cursor[0] - previous[0];
    let sy = cursor[1] - previous[1];
    // Each column/row has the same ambient drift. Calculate it once rather than
    // re-evaluating thousands of identical transcendentals on every grid step.
    let mut vertical_drift = [0.0f32; 128];
    if columns <= vertical_drift.len() {
        for (x, value) in vertical_drift[..columns].iter_mut().enumerate() {
            *value = cos(x as f32 * spacing * 0.017 + time * 0.12) * 2.5;
        }
    }
    for y in 0..rows {
        let horizontal_drift = wind * 0.025 + sin(y as f32 * spacing * 0.021 + time * 0.16) * 3.5;
        for x in 0..columns {
            let i = y * columns + x;
            let bx = (x as f32 - c[i][0] * dt / spacing).clamp(0.0, columns as f32 - 1.001);
            let by = (y as f32 - c[i][1] * dt / spacing).clamp(0.0, rows as f32 - 1.001);
            let ix = bx as usize;
            let iy = by as usize;
            let fx = bx - ix as f32;
            let fy = by - iy as f32;
            let mut value = [0.0; 4];
            for k in 0..3 {
                value[k] = (c[iy * columns + ix][k] * (1.0 - fx)
                    + c[iy * columns + ix + 1][k] * fx)
                    * (1.0 - fy)
                    + (c[(iy + 1) * columns + ix][k] * (1.0 - fx)
                        + c[(iy + 1) * columns + ix + 1][k] * fx)
                        * fy;
            }
            let wx = x as f32 * spacing;
            let wy = y as f32 * spacing;
            let t = (((wx - previous[0]) * sx + (wy - previous[1]) * sy)
                / (sx * sx + sy * sy).max(0.001))
            .clamp(0.0, 1.0);
            let dx = wx - previous[0] - sx * t;
            let dy = wy - previous[1] - sy * t;
            let influence = exp(-(dx * dx + dy * dy) / (spacing * spacing * 2.0));
            let gain = (dt * 12.0).min(1.0) * influence;
            value[0] += (cursor[2] * 0.55 - dy * 2.8) * gain;
            value[1] += (cursor[3] * 0.55 + dx * 2.8) * gain;
            value[0] += (horizontal_drift - value[0]) * dt * 0.45;
            value[1] += ((if columns <= vertical_drift.len() {
                vertical_drift[x]
            } else {
                cos(wx * 0.017 + time * 0.12) * 2.5
            }) - value[1])
                * dt
                * 0.45;
            value[0] = value[0].clamp(-360.0, 360.0);
            value[1] = value[1].clamp(-360.0, 360.0);
            let mut exponent = -f32::MAX;
            for source in sources {
                let dx = (wx - source[0]).abs() / source[2].max(1.0);
                let dy = (wy - source[1]).abs() / source[3].max(1.0);
                if dx < 1.8 && dy < 2.2 {
                    exponent = exponent.max(-dx * dx * 3.0 - dy * dy * 2.0);
                }
            }
            // exp is monotonic: one exponential of the maximum is identical to
            // evaluating and comparing every overlapping source.
            let target = if exponent == -f32::MAX {
                0.0
            } else {
                exp(exponent)
            };
            // Slow replenishment preserves a swept wake, rather than simply erasing opacity at the cursor.
            value[2] = (value[2] + (target - value[2]) * dt * 0.32).clamp(0.0, 1.0);
            if x == 0 || y == 0 || x == columns - 1 || y == rows - 1 {
                value[0] *= 0.5;
                value[1] *= 0.5;
            }
            s[i] = value;
        }
    }
    c.copy_from_slice(s);
    for y in 1..rows - 1 {
        for x in 1..columns - 1 {
            let i = y * columns + x;
            s[i][3] = (c[i + 1][0] - c[i - 1][0] + c[i + columns][1] - c[i - columns][1])
                / (2.0 * spacing);
            c[i][3] = 0.0;
        }
    }
    for _ in 0..8 {
        for y in 1..rows - 1 {
            for x in 1..columns - 1 {
                let i = y * columns + x;
                p[i] = (c[i - 1][3] + c[i + 1][3] + c[i - columns][3] + c[i + columns][3]
                    - s[i][3] * spacing * spacing)
                    * 0.25;
            }
        }
        for i in 0..n {
            c[i][3] = p[i];
        }
    }
    for y in 1..rows - 1 {
        for x in 1..columns - 1 {
            let i = y * columns + x;
            c[i][0] -= (c[i + 1][3] - c[i - 1][3]) / (2.0 * spacing);
            c[i][1] -= (c[i + columns][3] - c[i - columns][3]) / (2.0 * spacing);
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct WaterOutflow {
    pub left: f32,
    pub right: f32,
    pub left_momentum: f32,
    pub right_momentum: f32,
}

/// Conservative shallow-water transport in the moving support's reference frame.
/// Open boundaries return the actual lost volume and momentum for ballistic droplets.
/// # Safety
/// Four disjoint initialized spans of `count` floats, with at least three cells.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_transport_water(
    depths: *mut f32,
    velocities: *mut f32,
    mass_scratch: *mut f32,
    momentum_scratch: *mut f32,
    count: usize,
    spacing: f32,
    dt: f32,
    retention_depth: f32,
) -> WaterOutflow {
    let mut out = WaterOutflow::default();
    if count < 3 || spacing <= 0.0 || !dt.is_finite() || dt <= 0.0 {
        return out;
    }
    let d = unsafe { slice::from_raw_parts_mut(depths, count) };
    let v = unsafe { slice::from_raw_parts_mut(velocities, count) };
    let mass = unsafe { slice::from_raw_parts_mut(mass_scratch, count) };
    let momentum = unsafe { slice::from_raw_parts_mut(momentum_scratch, count) };
    let max_speed = v.iter().fold(60.0f32, |a, b| a.max(b.abs()));
    let steps = ((dt.min(0.05) * max_speed / (spacing * 0.38)) as usize + 1).min(48);
    let h = dt.min(0.05) / steps as f32;
    let damping = exp(-h * 8.0);
    for _ in 0..steps {
        mass.fill(0.0);
        momentum.fill(0.0);
        for i in 0..count {
            let left = i.saturating_sub(1);
            let right = (i + 1).min(count - 1);
            v[i] = ((v[i] - (d[right] - d[left]) * 1900.0 * h / (2.0 * spacing)) * damping)
                .clamp(-1200.0, 1200.0);
        }
        // Capillary pinning holds a shallow resting film. Once the edge head exceeds
        // the meniscus, gravity opens it; pressure replenishes the edge from the pool.
        let left_head = (d[0] - retention_depth).max(0.0);
        let right_head = (d[count - 1] - retention_depth).max(0.0);
        if left_head > 0.0 {
            v[0] = v[0].min(-unsafe { sqrtf(1900.0 * left_head) });
        }
        if right_head > 0.0 {
            v[count - 1] = v[count - 1].max(unsafe { sqrtf(1900.0 * right_head) });
        }
        for i in 0..count {
            let amount = d[i].max(0.0);
            let fraction = (v[i].abs() * h / spacing).min(0.42);
            let flux = amount * fraction;
            mass[i] += amount - flux;
            momentum[i] += (amount - flux) * v[i];
            let edge = (i == 0 && v[i] < 0.0) || (i == count - 1 && v[i] > 0.0);
            if edge && (v[i].abs() >= 80.0 || d[i] > retention_depth) {
                if i == 0 {
                    out.left += flux;
                    out.left_momentum += flux * v[i];
                } else {
                    out.right += flux;
                    out.right_momentum += flux * v[i];
                }
            } else {
                let j = if edge {
                    i
                } else if v[i] < 0.0 {
                    i - 1
                } else {
                    (i + 1).min(count - 1)
                };
                mass[j] += flux;
                momentum[j] += flux * v[i];
            }
        }
        for i in 0..count {
            d[i] = mass[i];
            v[i] = if mass[i] > 0.00001 {
                momentum[i] / mass[i]
            } else {
                0.0
            };
        }
        // Incompressible pressure projection: a thin ledge cannot store unlimited
        // vertical columns. Excess volume travels through neighbouring cells to
        // the nearest open boundary. It is returned with flux momentum, not deleted.
        for side in 0..2 {
            for k in 0..count {
                let i = if side == 0 { count - 1 - k } else { k };
                if (i < count / 2) != (side == 0) {
                    continue;
                }
                let excess = (d[i] - retention_depth).max(0.0);
                if excess <= 0.0 {
                    continue;
                }
                d[i] -= excess;
                let speed = unsafe { sqrtf(2.0 * 1900.0 * excess) }.max(v[i].abs());
                if i == 0 {
                    out.left += excess;
                    out.left_momentum -= excess * speed;
                } else if i == count - 1 {
                    out.right += excess;
                    out.right_momentum += excess * speed;
                } else {
                    let j = if side == 0 { i - 1 } else { i + 1 };
                    let total = d[j] + excess;
                    v[j] = (v[j] * d[j] + v[i] * excess) / total.max(0.0001);
                    d[j] = total;
                }
            }
        }
    }
    out
}

/// Local airflow correction after the original integrator. No allocation or change to the particle ABI.
/// # Safety
/// `particles` spans count initialized particles; cells spans columns*rows float4s.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_apply_airflow(
    particles: *mut Particle,
    count: usize,
    cells: *const [f32; 4],
    columns: usize,
    rows: usize,
    spacing: f32,
    base: f32,
    dt: f32,
) {
    if count == 0
        || particles.is_null()
        || cells.is_null()
        || columns < 2
        || rows < 2
        || spacing <= 0.0
        || !dt.is_finite()
        || dt <= 0.0
    {
        return;
    }
    let particles = unsafe { slice::from_raw_parts_mut(particles, count) };
    let cells = unsafe { slice::from_raw_parts(cells, columns * rows) };
    for p in particles {
        let kind = p.motion[3] as u32;
        if kind == 6 {
            continue;
        }
        let gx = (p.rect[0] / spacing).clamp(0.0, columns as f32 - 1.001);
        let gy = (p.rect[1] / spacing).clamp(0.0, rows as f32 - 1.001);
        let x = gx as usize;
        let y = gy as usize;
        let fx = gx - x as f32;
        let fy = gy - y as f32;
        let mut flow = [0.0; 2];
        for axis in 0..2 {
            let a =
                cells[y * columns + x][axis] * (1.0 - fx) + cells[y * columns + x + 1][axis] * fx;
            let b = cells[(y + 1) * columns + x][axis] * (1.0 - fx)
                + cells[(y + 1) * columns + x + 1][axis] * fx;
            flow[axis] = a * (1.0 - fy) + b * fy;
        }
        let (follow, existing) = match kind {
            0 => (1.8, 1.0),
            2 => (0.65, 0.16),
            3 => (1.0, 0.10),
            4 => (0.14, 0.0),
            13 => (0.35, 0.10),
            _ => (0.18, 0.0),
        };
        p.motion[0] += (flow[0] - base * existing) * (dt * follow).min(1.0);
        p.motion[1] += flow[1] * dt * follow * if kind == 0 { 0.2 } else { 0.65 };
    }
}

#[cfg(test)]
mod airflow_tests {
    use super::*;
    #[test]
    fn local_flow_drives_different_motion_without_changing_particle_mass() {
        let mut particles = [Particle::default(); 2];
        particles[0].rect = [0.0, 0.0, 3.0, 20.0];
        particles[1].rect = [48.0, 0.0, 3.0, 20.0];
        particles[0].life[2] = 2.0;
        particles[1].life[2] = 3.0;
        let flow = [
            [100.0, 4.0, 1.0, 0.0],
            [20.0, -4.0, 0.2, 0.0],
            [100.0, 4.0, 1.0, 0.0],
            [20.0, -4.0, 0.2, 0.0],
        ];
        unsafe {
            sh_apply_airflow(
                particles.as_mut_ptr(),
                2,
                flow.as_ptr(),
                2,
                2,
                48.0,
                0.0,
                1.0 / 120.0,
            );
        }
        assert!(particles[0].motion[0] > particles[1].motion[0] * 4.0);
        assert!(particles[0].motion[1] > 0.0 && particles[1].motion[1] < 0.0);
        assert_eq!(particles[0].life[2], 2.0);
        assert_eq!(particles[1].life[2], 3.0);
    }
    #[test]
    fn empty_flow_is_safe() {
        unsafe {
            sh_apply_airflow(
                core::ptr::null_mut(),
                0,
                core::ptr::null(),
                0,
                0,
                0.0,
                0.0,
                0.0,
            );
        }
    }
}

/// Four independent IEEE divisions in one vector instruction. This preserves
/// each scalar result, including the pair's mass weights, on both shipped CPUs.
#[inline(always)]
fn liquid_quotients(dx: f32, dy: f32, mj: f32, mi: f32, distance: f32) -> [f32; 4] {
    let numerator = [dx, dy, mj, mi];
    let denominator = [distance, distance, mi + mj, mi + mj];
    let mut result = [0.0; 4];
    #[cfg(target_arch = "aarch64")]
    unsafe {
        use core::arch::aarch64::*;
        vst1q_f32(
            result.as_mut_ptr(),
            vdivq_f32(
                vld1q_f32(numerator.as_ptr()),
                vld1q_f32(denominator.as_ptr()),
            ),
        );
    }
    #[cfg(target_arch = "x86_64")]
    unsafe {
        use core::arch::x86_64::*;
        _mm_storeu_ps(
            result.as_mut_ptr(),
            _mm_div_ps(
                _mm_loadu_ps(numerator.as_ptr()),
                _mm_loadu_ps(denominator.as_ptr()),
            ),
        );
    }
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    for axis in 0..4 {
        result[axis] = numerator[axis] / denominator[axis];
    }
    result
}

/// Interacting free liquid: local pressure projection, cohesion, viscosity and a
/// solid pointer boundary. A spatial hash bounds neighbourhood work. All transfers
/// conserve pair momentum; no splash count, launch speed or animation is selected.
/// # Safety
/// `particles` spans count initialized particles (at most 8192).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_couple_liquid(
    particles: *mut Particle,
    count: usize,
    dt: f32,
    cx: f32,
    cy: f32,
    cvx: f32,
    cvy: f32,
) {
    if count == 0 || count > 8192 || particles.is_null() || dt <= 0.0 {
        return;
    }
    let p = unsafe { slice::from_raw_parts_mut(particles, count) };
    let liquid_count = p.iter().filter(|item| item.motion[3] == 9.0).count();
    if liquid_count == 0 {
        return;
    }
    let foam_decay = exp(-dt * 6.0);
    let mut counts = [0usize; 4096];
    let mut starts = [0usize; 4097];
    let mut cursor = [0usize; 4096];
    let mut members = [0u16; 8192];
    let mut cells = [[0i32; 2]; 8192];
    let mut buckets = [0u16; 8192];
    let mut future = [0u16; 4096];
    #[inline(always)]
    fn pair(
        p: &mut [Particle],
        cells: &mut [[i32; 2]; 8192],
        i: usize,
        j: usize,
        xx: i32,
        yy: i32,
        dt: f32,
        pass: usize,
        weight: f32,
    ) {
        let dx = p[j].rect[0] - p[i].rect[0];
        let dy = p[j].rect[1] - p[i].rect[1];
        let d2 = dx * dx + dy * dy;
        if d2 < 0.000001 || d2 >= 36.0 {
            return;
        }
        let rest = (p[i].rect[2] + p[j].rect[2]) * 0.43;
        let reach = (rest * 3.0).min(6.0);
        if d2 >= reach * reach {
            return;
        }
        if cells[j][0] != xx || cells[j][1] != yy {
            return;
        }
        let d = unsafe { sqrtf(d2) };
        let mi = p[i].life[2].max(0.001);
        let mj = p[j].life[2].max(0.001);
        let [nx, ny, wi, wj] = liquid_quotients(dx, dy, mj, mi, d);
        let correction = if d < rest {
            (d - rest) * 0.45 * weight
        } else {
            (d - rest) * dt * 18.0 * weight
        };
        let correction = correction.clamp(-1.2, 0.65);
        p[i].rect[0] += nx * correction * wi;
        p[i].rect[1] += ny * correction * wi;
        p[j].rect[0] -= nx * correction * wj;
        p[j].rect[1] -= ny * correction * wj;
        // Only an interacting pair moves this future particle.
        // Cache its exact live cell after that move, avoiding
        // repeated coordinate division on every rejected probe.
        // i's query cell remains fixed through its original pass.
        cells[j] = [(p[j].rect[0] / 6.0) as i32, (p[j].rect[1] / 6.0) as i32];
        let dv = correction / dt.max(0.004) * 0.65;
        p[i].motion[0] += nx * dv * wi;
        p[i].motion[1] += ny * dv * wi;
        p[j].motion[0] -= nx * dv * wj;
        p[j].motion[1] -= ny * dv * wj;
        if pass == 0 {
            let sx = p[j].motion[0] - p[i].motion[0];
            let sy = p[j].motion[1] - p[i].motion[1];
            let shear2 = sx * sx + sy * sy;
            let aeration = if shear2 > 14400.0 {
                ((unsafe { sqrtf(shear2) } - 120.0) / 550.0).clamp(0.0, 1.0)
            } else {
                0.0
            };
            p[i].life[3] = p[i].life[3].max(aeration);
            p[j].life[3] = p[j].life[3].max(aeration);
            for axis in 0..2 {
                let visc = (p[j].motion[axis] - p[i].motion[axis])
                    * (1.0 - d / reach)
                    * (0.07 * weight).min(0.2);
                p[i].motion[axis] += visc * wi;
                p[j].motion[axis] -= visc * wj;
            }
        }
    }

    fn hash(x: i32, y: i32) -> usize {
        ((x.wrapping_mul(73856093) ^ y.wrapping_mul(19349663)) as usize) & 4095
    }
    for pass in 0..if liquid_count > 2048 { 2 } else { 3 } {
        counts.fill(0);
        future.fill(0);
        for (i, item) in p.iter_mut().enumerate() {
            if item.motion[3] != 9.0 {
                continue;
            }
            if pass == 0 {
                item.life[3] *= foam_decay;
            }
            cells[i] = [(item.rect[0] / 6.0) as i32, (item.rect[1] / 6.0) as i32];
            buckets[i] = hash(cells[i][0], cells[i][1]) as u16;
            counts[buckets[i] as usize] += 1;
        }
        starts[0] = 0;
        for cell in 0..4096 {
            starts[cell + 1] = starts[cell] + counts[cell];
            cursor[cell] = starts[cell];
        }
        for i in 0..count {
            if p[i].motion[3] != 9.0 {
                continue;
            }
            let cell = buckets[i] as usize;
            members[cursor[cell]] = i as u16;
            cursor[cell] += 1;
        }
        for i in 0..count {
            if p[i].motion[3] != 9.0 {
                continue;
            }
            future[buckets[i] as usize] += 1;
            let gx = cells[i][0];
            let gy = cells[i][1];
            for yy in gy - 1..=gy + 1 {
                for xx in gx - 1..=gx + 1 {
                    let cell = hash(xx, yy);
                    let population = counts[cell];
                    // Members are inserted in ascending particle order. A
                    // single prefix cursor per bucket tracks processed indices.
                    // Skip an exhausted bucket before phase division/loads.
                    if future[cell] as usize == population {
                        continue;
                    }
                    let phase = (i * 13 + pass * 7) % population;
                    let start = starts[cell];
                    if population <= 16 {
                        // A sparse bucket uses every member. Its sorted prefix
                        // has already been processed; visit only the future
                        // suffix in the original rotated order, with no per-
                        // probe wrap, stride calculation or rejected old pairs.
                        let cut = future[cell] as usize;
                        for offset in phase.max(cut)..population {
                            pair(
                                p,
                                &mut cells,
                                i,
                                members[start + offset] as usize,
                                xx,
                                yy,
                                dt,
                                pass,
                                1.0,
                            );
                        }
                        for offset in cut..phase {
                            pair(
                                p,
                                &mut cells,
                                i,
                                members[start + offset] as usize,
                                xx,
                                yy,
                                dt,
                                pass,
                                1.0,
                            );
                        }
                    } else {
                        let probes = if liquid_count > 2048 { 4 } else { 6 };
                        let weight = (population as f32 / probes as f32).min(4.0);
                        for k in 0..probes {
                            let offset = phase + k * population / probes;
                            let offset = if offset >= population {
                                offset - population
                            } else {
                                offset
                            };
                            let j = members[start + offset] as usize;
                            if j > i {
                                pair(p, &mut cells, i, j, xx, yy, dt, pass, weight);
                            }
                        }
                    }
                }
            }
            let dx = p[i].rect[0] - cx;
            let dy = p[i].rect[1] - cy;
            let d2 = dx * dx + dy * dy;
            let radius = 11.0 + p[i].rect[2] * 0.5;
            if d2 < radius * radius && d2 > 0.000001 {
                let d = unsafe { sqrtf(d2) };
                let nx = dx / d;
                let ny = dy / d;
                p[i].rect[0] = cx + nx * radius;
                p[i].rect[1] = cy + ny * radius;
                let closing = (p[i].motion[0] - cvx) * nx + (p[i].motion[1] - cvy) * ny;
                if closing < 0.0 {
                    p[i].motion[0] -= closing * nx;
                    p[i].motion[1] -= closing * ny;
                    p[i].life[3] = p[i].life[3].max(((-closing - 100.0) / 500.0).clamp(0.0, 1.0));
                }
            }
        }
    }
}

/// # Safety
/// Input spans count particles (<=8192); output spans count*8 float4 values,
/// scratch spans 4096*9 float4 values and is reused by the caller between frames.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_liquid_field(
    particles: *const Particle,
    count: usize,
    output: *mut [f32; 4],
    scratch: *mut [f32; 4],
) {
    if count == 0 || count > 8192 || particles.is_null() || output.is_null() || scratch.is_null() {
        return;
    }
    let p = unsafe { slice::from_raw_parts(particles, count) };
    if !p.iter().any(|item| item.motion[3] == 9.0) {
        return;
    }
    let field = unsafe { slice::from_raw_parts_mut(output, count * 8) };
    let mut heads = [-1i32; 4096];
    let mut next = [-1i32; 8192];
    fn hash(x: i32, y: i32) -> usize {
        ((x.wrapping_mul(73856093) ^ y.wrapping_mul(19349663)) as usize) & 4095
    }
    for i in 0..count {
        if p[i].motion[3] == 9.0 {
            let h = hash((p[i].rect[0] / 4.0) as i32, (p[i].rect[1] / 4.0) as i32);
            next[i] = heads[h];
            heads[h] = i as i32;
        }
    }
    // Dense liquid samples share a small spatial neighbourhood. Cache nine
    // candidates per small cell, then exclude the sample itself when writing
    // its eight neighbours. This preserves particle count and native-rate motion.
    let mut keys = [[i32::MIN; 2]; 4096];
    let cache = unsafe { slice::from_raw_parts_mut(scratch, 4096 * 9) };
    for i in 0..count {
        if p[i].motion[3] != 9.0 {
            continue;
        }
        let cell = [(p[i].rect[0] / 1.5) as i32, (p[i].rect[1] / 1.5) as i32];
        let entry = hash(cell[0], cell[1]);
        if keys[entry] != cell {
            keys[entry] = cell;
            for slot in 0..9 {
                cache[entry * 9 + slot] = [0.0; 4];
            }
            let centre = [(cell[0] as f32 + 0.5) * 1.5, (cell[1] as f32 + 0.5) * 1.5];
            let x = (centre[0] / 4.0) as i32;
            let y = (centre[1] / 4.0) as i32;
            let mut distances = [36.0f32; 9];
            let mut indices = [-1i32; 9];
            let mut slot = 0;
            for yy in y - 1..=y + 1 {
                for xx in x - 1..=x + 1 {
                    let mut node = heads[hash(xx, yy)];
                    while node >= 0 {
                        let j = node as usize;
                        node = next[j];
                        // Hash collisions are not extra fluid samples.
                        if (p[j].rect[0] / 4.0) as i32 != xx || (p[j].rect[1] / 4.0) as i32 != yy {
                            continue;
                        }
                        let dx = p[j].rect[0] - centre[0];
                        let dy = p[j].rect[1] - centre[1];
                        let d = dx * dx + dy * dy;
                        if d < distances[slot]
                            || (d == distances[slot] && j as i32 > indices[slot] && d < 36.0)
                        {
                            distances[slot] = d;
                            cache[entry * 9 + slot] =
                                [p[j].rect[0], p[j].rect[1], p[j].rect[2] * 0.5, 1.0];
                            indices[slot] = j as i32;
                            slot = 0;
                            for k in 1..9 {
                                if distances[k] > distances[slot]
                                    || (distances[k] == distances[slot]
                                        && indices[k] < indices[slot])
                                {
                                    slot = k;
                                }
                            }
                        }
                    }
                }
            }
            for n in 1..9 {
                let mut k = n;
                while k > 0
                    && (distances[k] < distances[k - 1]
                        || (distances[k] == distances[k - 1] && indices[k] > indices[k - 1]))
                {
                    distances.swap(k, k - 1);
                    indices.swap(k, k - 1);
                    cache.swap(entry * 9 + k, entry * 9 + k - 1);
                    k -= 1;
                }
            }
        }
        let mut k = 0;
        for candidate in cache[entry * 9..entry * 9 + 9].iter().copied() {
            if k == 8 {
                break;
            }
            if candidate[3] > 0.5
                && (candidate[0] - p[i].rect[0]).abs() < 0.0001
                && (candidate[1] - p[i].rect[1]).abs() < 0.0001
            {
                continue;
            }
            field[i * 8 + k] = candidate;
            k += 1;
        }
        while k < 8 {
            field[i * 8 + k] = [0.0; 4];
            k += 1;
        }
    }
}

/// Merge samples occupying the same four-point cell, with stable ordering and
/// exactly the existing mass, momentum and rendered-area rules. Fixed storage
/// avoids rebuilding a heap-allocated map during a full-puddle interaction.
/// # Safety
/// `particles` spans count initialized particles (at most 8192).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_coalesce_liquid(particles: *mut Particle, count: usize) -> usize {
    if count == 0 || count > 8192 || particles.is_null() {
        return count;
    }
    let p = unsafe { slice::from_raw_parts_mut(particles, count) };
    let mut heads = [-1i32; 4096];
    let mut next = [-1i32; 8192];
    let mut keys = [[0i32; 2]; 8192];
    let mut out = 0;
    for i in 0..count {
        let sample = p[i];
        if sample.motion[3] != 9.0 {
            p[out] = sample;
            out += 1;
            continue;
        }
        fn cell(value: f32) -> i32 {
            let scaled = value * 0.25;
            let integer = scaled as i32;
            if scaled < integer as f32 {
                integer.saturating_sub(1)
            } else {
                integer
            }
        }
        let key = [cell(sample.rect[0]), cell(sample.rect[1])];
        let hash =
            ((key[0].wrapping_mul(73856093) ^ key[1].wrapping_mul(19349663)) as usize) & 4095;
        let mut node = heads[hash];
        while node >= 0 && keys[node as usize] != key {
            node = next[node as usize];
        }
        if node >= 0 {
            let kept = &mut p[node as usize];
            let mass = kept.life[2] + sample.life[2];
            let t = sample.life[2] / mass.max(0.001);
            for axis in 0..2 {
                kept.rect[axis] += (sample.rect[axis] - kept.rect[axis]) * t;
                kept.motion[axis] += (sample.motion[axis] - kept.motion[axis]) * t;
            }
            kept.life[2] = mass;
            kept.life[3] = kept.life[3].max(sample.life[3]);
            let diameter = (unsafe { sqrtf(mass) } * 2.3).min(3.6);
            kept.rect[2] = diameter;
            kept.rect[3] = diameter;
        } else {
            p[out] = sample;
            keys[out] = key;
            next[out] = heads[hash];
            heads[hash] = out as i32;
            out += 1;
        }
    }
    out
}
