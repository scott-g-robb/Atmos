#![cfg_attr(not(test), no_std)]

// Allocation-free C ABI kernels. Swift owns all memory and macOS integration; Metal owns drawing.
use core::slice;

unsafe extern "C" {
    fn sinf(x: f32) -> f32;
    fn cosf(x: f32) -> f32;
    fn expf(x: f32) -> f32;
    fn sqrtf(x: f32) -> f32;
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
        if kind != 2 && cursor_speed > 6.0 {
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
                let gust = if s.effect == 2 {
                    sin(s.time * 0.57) * 75.0 + 70.0
                } else {
                    12.0
                };
                vx += (s.wind + gust + sin(s.time * 0.7 + seed * 9.0) * 12.0 - vx)
                    * (dt * 1.8).min(1.0);
            }
            1 | 5 | 9 => {
                vy -= (if kind == 1 { 750.0 } else { 950.0 }) * dt;
                vx *= drag;
            }
            2 => {
                vx += (s.wind * 0.025 + sin(s.time * 0.13 + seed * 17.0) * 7.0 - vx)
                    * (dt * 0.65).min(1.0);
                vy += (cos(s.time * 0.18 + seed * 19.0) * 2.5 - vy) * (dt * 0.65).min(1.0);
            }
            3 => {
                vx += (sin(s.time * 0.27 + seed * 14.0) * 15.0 + s.wind * 0.025 - vx) * dt;
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
            _ => {}
        }
        let slow = if (2..=4).contains(&kind) {
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
        if kind == 2 || kind == 3 || kind == 4 {
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
            && (kind != 9 || p.life[0] > 0.08)
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
                            2.5
                        },
                        surface_index: surface as u32,
                        kind,
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
    let diffusion = (h * 3.0).min(0.24);
    let mut current: &mut [f32] = original;
    let mut next: &mut [f32] = spare;
    for _ in 0..steps {
        for i in 0..count {
            let left = i.saturating_sub(1);
            let right = (i + 1).min(count - 1);
            speed[i] = (speed[i] + (wave[left] + wave[right] - 2.0 * wave[i]) * 180.0 * h
                - wave[i] * 5.0 * h)
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
        assert_eq!(core::mem::size_of::<Impact>(), 24);
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
    let damping = exp(-h * 1.15);
    for _ in 0..steps {
        mass.fill(0.0);
        momentum.fill(0.0);
        for i in 0..count {
            let left = i.saturating_sub(1);
            let right = (i + 1).min(count - 1);
            v[i] = ((v[i] - (d[right] - d[left]) * 180.0 * h / (2.0 * spacing)) * damping)
                .clamp(-1200.0, 1200.0);
        }
        for i in 0..count {
            let amount = d[i].max(0.0);
            let fraction = (v[i].abs() * h / spacing).min(0.42);
            let flux = amount * fraction;
            mass[i] += amount - flux;
            momentum[i] += (amount - flux) * v[i];
            let edge = (i == 0 && v[i] < 0.0) || (i == count - 1 && v[i] > 0.0);
            if edge && v[i].abs() >= 25.0 {
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
    }
    out
}
