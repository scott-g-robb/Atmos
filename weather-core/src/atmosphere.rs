//! CPU field and height-field kernels. Callers own contiguous storage; no heap
//! allocation, callbacks, platform handles or ownership crosses this boundary.
use crate::{cos, exp, sin};
use core::slice;
unsafe extern "C" {
    fn powf(x: f32, y: f32) -> f32;
    fn floorf(x: f32) -> f32;
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_build_wind(
    cells: *mut [f32; 4],
    columns: usize,
    rows: usize,
    spacing: f32,
    windows: *const [f32; 4],
    window_count: usize,
    wind: f32,
    turbulence: f32,
    time: f32,
) {
    if columns == 0 || rows == 0 {
        return;
    }
    let cells = unsafe { slice::from_raw_parts_mut(cells, columns * rows) };
    let windows = if window_count == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(windows, window_count.min(48)) }
    };
    let direction = if wind < 0.0 { -1.0 } else { 1.0 };
    let energy = (wind.abs() * 0.12).max(turbulence);
    for y in 0..rows {
        for x in 0..columns {
            let px = x as f32 * spacing;
            let py = y as f32 * spacing;
            let front = sin(px * 0.006 - direction * time * 0.9 + sin(py * 0.004 + time * 0.17));
            let vx = wind + energy * front;
            let mut vy =
                energy * 0.35 * sin(px * 0.011 + time * 0.7) * cos(py * 0.009 - time * 0.3);
            let mut exposure = 1.0_f32;
            for b in windows {
                let down = if direction > 0.0 {
                    px - b[2]
                } else {
                    b[0] - px
                };
                let vertical = (b[1] - py).max(py - b[3]).max(0.0);
                if down >= 0.0 && down < 320.0 && vertical < 48.0 {
                    let shelter = (1.0 - down / 320.0) * (1.0 - vertical / 48.0);
                    exposure = exposure.min(1.0 - shelter * 0.82);
                    let edge = (py - b[1]).abs().min((py - b[3]).abs());
                    let curl = exp(-edge / 45.0) * exp(-down / 160.0);
                    vy += direction * energy * 2.0 * sin(down * 0.035 - time * 1.7) * curl;
                }
                if px >= b[0] && px <= b[2] && py >= b[1] && py <= b[3] {
                    exposure = exposure.min(0.28)
                }
            }
            cells[y * columns + x] = [vx * exposure, vy * exposure, exposure, 0.0];
        }
    }
}
pub(crate) unsafe fn flow(
    cells: *const [f32; 4],
    columns: usize,
    rows: usize,
    spacing: f32,
    base: f32,
    x: f32,
    y: f32,
) -> [f32; 2] {
    if cells.is_null() || columns < 2 || rows < 2 || spacing <= 0.0 {
        return [base, 0.0];
    }
    let c = unsafe { slice::from_raw_parts(cells, columns * rows) };
    let px = (x / spacing).clamp(0.0, columns as f32 - 1.001);
    let py = (y / spacing).clamp(0.0, rows as f32 - 1.001);
    let ix = px as usize;
    let iy = py as usize;
    let fx = px - ix as f32;
    let fy = py - iy as f32;
    let mut out = [0.0; 2];
    for k in 0..2 {
        let a = c[iy * columns + ix][k] * (1.0 - fx) + c[iy * columns + ix + 1][k] * fx;
        let b = c[(iy + 1) * columns + ix][k] * (1.0 - fx) + c[(iy + 1) * columns + ix + 1][k] * fx;
        out[k] = a * (1.0 - fy) + b * fy;
    }
    out
}
// A vector return is represented explicitly as a small C struct on both ABIs.
// The public SIMD wrapper is supplied by the C shim below.
#[repr(C)]
pub struct FlowSample {
    pub x: f32,
    pub y: f32,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_sample_wind_value(
    c: *const [f32; 4],
    cols: usize,
    rows: usize,
    spacing: f32,
    base: f32,
    x: f32,
    y: f32,
) -> FlowSample {
    let v = unsafe { flow(c, cols, rows, spacing, base, x, y) };
    FlowSample { x: v[0], y: v[1] }
}
#[repr(C)]
#[derive(Default)]
pub struct SnowRelaxResult {
    pub left: f32,
    pub right: f32,
    pub moved: u32,
}
#[inline(always)]
fn transfer(h: &mut [f32], p: &mut [f32], amount: f32, a: usize, b: usize) {
    // Loose snow has no packed mass. Avoid a division for that common case,
    // especially across the six alternating repose passes.
    let share = if p[a] > 0.0 && h[a] > 0.0 {
        p[a].min(amount * p[a] / h[a])
    } else {
        0.0
    };
    h[a] -= amount;
    h[b] += amount;
    p[a] -= share;
    p[b] += share;
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_relax(
    heights: *mut f32,
    packed: *mut f32,
    bed: *const f32,
    held: *const u8,
    count: usize,
    limit: f32,
    rounding: f32,
    forward: u32,
    open: u32,
    outside_left: f32,
    outside_right: f32,
) -> SnowRelaxResult {
    let mut result = SnowRelaxResult::default();
    if count < 2 {
        return result;
    }
    let h = unsafe { slice::from_raw_parts_mut(heights, count) };
    let p = unsafe { slice::from_raw_parts_mut(packed, count) };
    let b = unsafe { slice::from_raw_parts(bed, count) };
    let held = unsafe { slice::from_raw_parts(held, count) };
    for pass in 0..6 {
        let forwards = (pass % 2 == 0) == (forward != 0);
        for k in 0..count - 1 {
            let i = if forwards { k } else { count - 2 - k };
            if held[i] != 0 || held[i + 1] != 0 {
                continue;
            }
            let delta = (b[i] + h[i]) - (b[i + 1] + h[i + 1]);
            if delta > limit + 0.01 {
                let amount = ((delta - limit) * 0.5).min(h[i]);
                transfer(h, p, amount, i, i + 1);
                if amount > 0.0 {
                    result.moved = 1
                }
            } else if delta < -limit - 0.01 {
                let amount = ((-delta - limit) * 0.5).min(h[i + 1]);
                transfer(h, p, amount, i + 1, i);
                if amount > 0.0 {
                    result.moved = 1
                }
            }
        }
        if open != 0 {
            for (i, outside, left) in [(0, outside_left, true), (count - 1, outside_right, false)] {
                if held[i] == 0 && h[i] - outside > limit + 0.01 {
                    let amount = (h[i] - outside - limit) * 0.5;
                    h[i] -= amount;
                    p[i] = p[i].min(h[i]);
                    if left {
                        result.left += amount
                    } else {
                        result.right += amount
                    }
                    result.moved = 1;
                }
            }
        }
    }
    if count > 3 {
        for i in 1..count - 2 {
            if held[i - 1] != 0 || held[i] != 0 || held[i + 1] != 0 || held[i + 2] != 0 {
                continue;
            }
            let s0 = b[i - 1] + h[i - 1];
            let s1 = b[i] + h[i];
            let s2 = b[i + 1] + h[i + 1];
            let s3 = b[i + 2] + h[i + 2];
            let kink = (s1 - s2) - 0.5 * ((s0 - s1) + (s2 - s3));
            if kink.abs() <= 0.02 {
                continue;
            }
            let amount = if kink > 0.0 {
                (kink * rounding).min(h[i])
            } else {
                (kink * rounding).max(-h[i + 1])
            };
            if amount > 0.0 {
                transfer(h, p, amount, i, i + 1)
            } else {
                transfer(h, p, -amount, i + 1, i)
            }
            if amount.abs() > 0.003 {
                result.moved = 1
            }
        }
    }
    result
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_deposit(
    heights: *mut f32,
    count: usize,
    base: f32,
    width: f32,
    area: f32,
    x: f32,
    wide: u32,
) -> f32 {
    if area <= 0.0 {
        return 0.0;
    }
    if count == 0 || width <= 0.0 {
        return area;
    }
    let h = unsafe { slice::from_raw_parts_mut(heights, count) };
    let center = unsafe { floorf((x - base) / width) } as isize;
    let narrow = [0.25, 0.5, 0.25];
    let broad = [0.0625, 0.25, 0.375, 0.25, 0.0625];
    let weights: &[f32] = if wide != 0 { &broad } else { &narrow };
    let offset = (weights.len() / 2) as isize;
    let mut missed = 0.0;
    for (k, w) in weights.iter().enumerate() {
        let i = center + k as isize - offset;
        if i >= 0 && (i as usize) < count {
            h[i as usize] += area / width * w
        } else {
            missed += area * w
        }
    }
    missed
}
fn wedge(
    h: &mut [f32],
    p: &mut [f32],
    b: &[f32],
    level: f32,
    edge: usize,
    inward: i32,
    slope: f32,
    scale: f32,
    bed_depth: f32,
) -> f32 {
    let reach = if inward > 0 { h.len() - edge } else { edge + 1 };
    let mut total = 0.0;
    for k in 0..reach {
        let line = level - slope * k as f32;
        if line <= -bed_depth {
            break;
        }
        let i = (edge as isize + inward as isize * k as isize) as usize;
        let gap = line - (b[i] + h[i]);
        if gap <= 0.0 {
            continue;
        }
        total += gap;
        h[i] += gap * scale;
        p[i] += gap * scale;
    }
    total
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_heap(
    heights: *mut f32,
    packed: *mut f32,
    bed: *const f32,
    count: usize,
    width: f32,
    bed_depth: f32,
    area: f32,
    edge: usize,
    inward: i32,
    slope: f32,
) {
    if count == 0 || edge >= count || area <= 0.0 || width <= 0.0 || (inward != 1 && inward != -1) {
        return;
    }
    let h = unsafe { slice::from_raw_parts_mut(heights, count) };
    let p = unsafe { slice::from_raw_parts_mut(packed, count) };
    let b = unsafe { slice::from_raw_parts(bed, count) };
    let amount = area / width;
    let mut low = b[edge] + h[edge];
    let mut high = low + amount;
    for _ in 0..20 {
        let middle = (low + high) / 2.0;
        if wedge(h, p, b, middle, edge, inward, slope, 0.0, bed_depth) < amount {
            low = middle
        } else {
            high = middle
        }
    }
    let total = wedge(h, p, b, high, edge, inward, slope, 0.0, bed_depth);
    if total > 0.0 {
        wedge(
            h,
            p,
            b,
            high,
            edge,
            inward,
            slope,
            amount / total,
            bed_depth,
        );
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_thaw(
    heights: *mut f32,
    packed: *mut f32,
    count: usize,
    dt: f32,
    floor: f32,
    rate: f32,
    settle: f32,
) -> f32 {
    if count == 0 {
        return 0.0;
    }
    let h = unsafe { slice::from_raw_parts_mut(heights, count) };
    let p = unsafe { slice::from_raw_parts_mut(packed, count) };
    let mut fastest = 0.0_f32;
    for i in 0..count {
        if h[i] <= 0.0 {
            continue;
        }
        let loss = h[i].min((rate + (h[i] - floor).max(0.0) / settle) * dt);
        h[i] -= loss;
        p[i] = p[i].min(h[i]);
        fastest = fastest.max(loss)
    }
    fastest
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_smooth(
    heights: *const f32,
    bed: *const f32,
    count: usize,
    output: *mut f32,
) {
    if count == 0 {
        return;
    }
    let h = unsafe { slice::from_raw_parts(heights, count) };
    let b = unsafe { slice::from_raw_parts(bed, count) };
    let out = unsafe { slice::from_raw_parts_mut(output, count * 2) };
    for i in 0..count {
        out[i] =
            b[i] + 0.25 * h[i.saturating_sub(1)] + 0.5 * h[i] + 0.25 * h[(i + 1).min(count - 1)];
        out[count + i] = b[i]
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_bed(
    bed: *mut f32,
    count: usize,
    width: f32,
    radius: f32,
    exponent: f32,
) -> f32 {
    if count == 0 {
        return 0.0;
    }
    let b = unsafe { slice::from_raw_parts_mut(bed, count) };
    let span = count as f32 * width;
    let mut depth = 0.0_f32;
    for i in 0..count {
        let x = (i as f32 + 0.5) * width;
        let inset = x.min(span - x);
        b[i] = if radius > 0.0 && inset < radius {
            let u = 1.0 - inset / radius;
            -radius * (1.0 - unsafe { powf((1.0 - powf(u, exponent)).max(0.0), 1.0 / exponent) })
        } else {
            0.0
        };
        depth = depth.max(-b[i]);
    }
    depth
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_capacity(
    capacity: *mut f32,
    count: usize,
    width: f32,
    depth: f32,
    a: f32,
    b: f32,
) {
    if count == 0 {
        return;
    }
    let c = unsafe { slice::from_raw_parts_mut(capacity, count) };
    for i in 0..count {
        let x = i as f32 * width;
        let drift = 0.12 * sin(x * 0.0105 + a) + 0.07 * sin(x * 0.037 + b);
        c[i] = depth * (0.95 + drift);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_visible(
    visible: *mut u8,
    bed: *const f32,
    count: usize,
    base_x: f32,
    origin_y: f32,
    width: f32,
    screen: f32,
    blockers: *const [f32; 4],
    blocker_count: usize,
) {
    if count == 0 {
        return;
    }
    let visible = unsafe { slice::from_raw_parts_mut(visible, count) };
    let bed = unsafe { slice::from_raw_parts(bed, count) };
    let blockers = if blocker_count == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(blockers, blocker_count) }
    };
    for i in 0..count {
        let x = base_x + (i as f32 + 0.5) * width;
        let y = origin_y + bed[i] + 1.0;
        visible[i] = (x >= 0.0
            && x <= screen
            && !blockers
                .iter()
                .any(|b| x >= b[0] && x < b[2] && y >= b[1] && y < b[3]))
            as u8;
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_slide(
    heights: *mut f32,
    packed: *mut f32,
    count: usize,
    direction: i32,
) -> f32 {
    if count == 0 {
        return 0.0;
    }
    let h = unsafe { slice::from_raw_parts_mut(heights, count) };
    let p = unsafe { slice::from_raw_parts_mut(packed, count) };
    if direction > 0 {
        let dropped = h[count - 1];
        h.copy_within(0..count - 1, 1);
        p.copy_within(0..count - 1, 1);
        h[0] = 0.0;
        p[0] = 0.0;
        dropped
    } else {
        let dropped = h[0];
        h.copy_within(1..count, 0);
        p.copy_within(1..count, 0);
        h[count - 1] = 0.0;
        p[count - 1] = 0.0;
        dropped
    }
}
