use crate::{exp, len, sqrtf};
use core::slice;
unsafe extern "C" {
    fn floorf(x: f32) -> f32;
}
#[repr(C, align(8))]
#[derive(Default)]
pub struct Support {
    pub track: [f32; 2],
    pub velocity: [f32; 2],
    pub offset: [f32; 2],
    pub offset_velocity: [f32; 2],
    pub swing_direction: [f32; 2],
    pub agitation: f32,
    pub swing_peak: f32,
    pub previous_peak: f32,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_support(
    support: *mut Support,
    tx: f32,
    ty: f32,
    dt: f32,
    track_time: f32,
    gravity: f32,
    stick: f32,
    hold: f32,
    rub: f32,
    top: f32,
) {
    if dt <= 0.0 || track_time <= 0.0 || gravity <= 0.0 {
        return;
    }
    let s = unsafe { &mut *support };
    let previous = s.velocity;
    let omega = 2.0 / track_time;
    let x = omega * dt;
    let decay = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x);
    let target = [tx, ty];
    for k in 0..2 {
        let change = s.track[k] - target[k];
        let temp = (s.velocity[k] + omega * change) * dt;
        s.velocity[k] = (s.velocity[k] - omega * temp) * decay;
        s.track[k] = target[k] + (change + temp) * decay;
    }
    let acceleration = [
        (s.velocity[0] - previous[0]) / dt,
        (s.velocity[1] - previous[1]) / dt,
    ];
    s.agitation *= exp(-dt / 0.3);
    let magnitude = len(acceleration[0], acceleration[1]);
    if magnitude > 1.0
        && acceleration[0] * s.swing_direction[0] + acceleration[1] * s.swing_direction[1] < 0.0
    {
        s.agitation = s.agitation.max(s.previous_peak.min(s.swing_peak) / gravity);
        s.previous_peak = s.swing_peak;
        s.swing_peak = magnitude;
        s.swing_direction = [acceleration[0] / magnitude, acceleration[1] / magnitude];
    } else {
        s.swing_peak = s.swing_peak.max(magnitude);
        if magnitude > 1.0 && s.swing_direction == [0.0, 0.0] {
            s.swing_direction = [acceleration[0] / magnitude, acceleration[1] / magnitude]
        }
    }
    if top <= 0.05 {
        s.offset = [0.0, 0.0];
        s.offset_velocity = [0.0, 0.0];
        return;
    }
    let fall = -gravity - acceleration[1];
    if s.offset[1] > 0.0 || fall > stick {
        s.offset_velocity[1] += fall * dt;
        s.offset[1] += s.offset_velocity[1] * dt;
        if s.offset[1] <= 0.0 {
            s.offset[1] = 0.0;
            s.offset_velocity[1] = 0.0
        }
    }
    let pressure = if s.offset[1] > 0.0 {
        0.0
    } else {
        (gravity + stick + acceleration[1]).max(0.0)
    };
    let drive = -acceleration[0];
    let mut velocity = s.offset_velocity[0];
    if !(velocity == 0.0 && drive.abs() <= hold * pressure) {
        let direction = if velocity != 0.0 {
            if velocity > 0.0 { 1.0 } else { -1.0 }
        } else if drive > 0.0 {
            1.0
        } else {
            -1.0
        };
        let next = velocity + (drive - direction * rub * pressure) * dt;
        velocity = if pressure > 0.0 && next * direction <= 0.0 {
            0.0
        } else {
            next
        };
    }
    s.offset[0] += velocity * dt;
    s.offset_velocity[0] = velocity;
}
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct Cut {
    pub x: f32,
    pub surface: f32,
    pub area: f32,
    pub sprayed: f32,
    pub side: f32,
    pub index: u32,
    pub held: u32,
    pub removed: u32,
}
#[repr(C)]
#[derive(Default)]
pub struct Resting {
    pub x: f32,
    pub rest: f32,
    pub top: f32,
    pub size: f32,
    pub seed: f32,
    pub tilt: f32,
    pub around: f32,
    pub from_turn: f32,
    pub from_flip: f32,
    pub slide: f32,
    pub settling: f32,
    pub settled: f32,
    pub life: f32,
    pub age: f32,
    pub fade: f32,
}
#[repr(C)]
pub struct RestingStep {
    pub dt: f32,
    pub px: f32,
    pub py: f32,
    pub surface: f32,
    pub agitation: f32,
    pub shaking: f32,
    pub retirement: f32,
    pub cx: f32,
    pub cy: f32,
    pub vx: f32,
    pub vy: f32,
    pub radius: f32,
    pub carried_x: f32,
    pub carried_y: f32,
    pub out_x: f32,
    pub out_y: f32,
    pub flags: u32,
}
fn random(state: &mut u64) -> f32 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    (*state >> 40) as f32 / (1u32 << 24) as f32
}
fn range(state: &mut u64, lo: f32, hi: f32) -> f32 {
    lo + (hi - lo) * random(state)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_tend_resting_leaf(
    leaf: *mut Resting,
    step: *mut RestingStep,
    state: *mut u64,
) -> u32 {
    let l = unsafe { &mut *leaf };
    let s = unsafe { &mut *step };
    let rng = unsafe { &mut *state };
    let speed = len(s.vx, s.vy);
    if s.flags & 1 != 0 && speed > 8.0 && len(s.px - s.cx, s.py - s.cy) < s.radius + l.size * 0.4 {
        let scale = range(rng, 0.5, 0.9);
        let mut v = [s.vx * scale, s.vy * scale];
        let speed = len(v[0], v[1]);
        if speed > 450.0 {
            v[0] *= 450.0 / speed;
            v[1] *= 450.0 / speed
        }
        s.out_x = v[0] + range(rng, -20.0, 20.0);
        s.out_y = v[1] + range(rng, 10.0, 35.0) + speed * range(rng, 0.03, 0.1);
        return 3;
    }
    let shake = (0.3 * (s.agitation - s.shaking).max(0.0)).min(0.8);
    if random(rng) < shake * 2.0 * s.dt {
        s.out_x = s.carried_x + range(rng, -80.0, 80.0);
        s.out_y = s.carried_y + range(rng, 20.0, 80.0);
        return 1;
    }
    if s.surface < l.rest - 3.0 {
        let (x, y) = if s.agitation > s.shaking {
            (range(rng, -40.0, 40.0), range(rng, 20.0, 80.0))
        } else {
            (range(rng, -15.0, 15.0), 0.0)
        };
        s.out_x = s.carried_x + x;
        s.out_y = s.carried_y + y;
        return 1;
    }
    let mut changed = false;
    let buried = s.surface > l.top + 10.0;
    if s.surface < l.top {
        let sink = (l.top - s.surface).min(20.0 * s.dt);
        l.top -= sink;
        l.rest -= sink;
        changed = true
    }
    if l.settled < 1.0 {
        l.settled = (l.settled + s.dt / l.settling).min(1.0);
        changed = true
    }
    if buried {
        l.fade -= s.dt * 2.0;
        changed = true
    } else if s.flags & 2 != 0 {
        l.age += s.dt * s.retirement;
        if l.age > l.life {
            l.fade -= s.dt * s.retirement / 4.0;
            changed = true
        }
    }
    (if changed { 4 } else { 0 }) | (if l.fade <= 0.0 { 8 } else { 0 })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_carve(
    heights: *mut f32,
    packed: *mut f32,
    bed: *const f32,
    visible: *const u8,
    count: usize,
    bx: f32,
    by: f32,
    cw: f32,
    cx: f32,
    cy: f32,
    radius: f32,
    vx: f32,
    vy: f32,
    travel: f32,
    final_step: u32,
    autumn: u32,
    leaf_cover: f32,
    cuts: *mut Cut,
) -> usize {
    if count == 0 || cw <= 0.0 || radius <= 0.0 {
        return 0;
    }
    let h = unsafe { slice::from_raw_parts_mut(heights, count) };
    let packed = unsafe { slice::from_raw_parts_mut(packed, count) };
    let bed = unsafe { slice::from_raw_parts(bed, count) };
    let visible = unsafe { slice::from_raw_parts(visible, count) };
    let out = unsafe { slice::from_raw_parts_mut(cuts, count) };
    let local = cy - by;
    let t = ((len(vx, vy) - 60.0) / if autumn != 0 { 440.0 } else { 360.0 }).clamp(0.0, 1.0);
    let share = t * t * (3.0 - 2.0 * t);
    let mut n = 0;
    let lower = (unsafe { floorf((cx - radius - bx) / cw) } as isize).max(0);
    let upper = (unsafe { floorf((cx + radius - bx) / cw) } as isize).min(count as isize - 1);
    if lower > upper {
        return 0;
    }
    for i in lower as usize..=upper as usize {
        if visible[i] == 0 {
            continue;
        }
        let x = bx + (i as f32 + 0.5) * cw;
        let dx = x - cx;
        let reach = radius * radius - dx * dx;
        if reach <= 0.0 {
            continue;
        }
        let half = unsafe { sqrtf(reach) };
        let bottom = (local - half - bed[i]).max(0.0);
        let top = local + half - bed[i];
        if top <= bottom {
            continue;
        }
        let height = h[i];
        let buried = height > top;
        let held = final_step != 0 && !buried && height >= bottom - 1.0;
        let mut cut = Cut {
            x,
            index: i as u32,
            held: held as u32,
            ..Cut::default()
        };
        if height > bottom + 0.01 {
            let removed = if buried {
                (top - bottom) * (travel / (2.0 * radius)).min(1.0)
            } else {
                height - bottom
            };
            if removed > 0.001 {
                h[i] = (height - removed).max(0.0);
                packed[i] = packed[i].min(h[i]);
                cut.removed = 1;
                let hidden = if autumn != 0 {
                    (leaf_cover - if buried { height - top } else { 0.0 }).max(0.0)
                } else {
                    0.0
                };
                cut.area = (removed - hidden).max(0.0) * cw;
                cut.sprayed = cut.area * share;
                cut.surface = by + bed[i] + if buried { height - removed } else { height };
                cut.side = if vx.abs() > 40.0 { vx } else { dx };
            }
        }
        if cut.held != 0 || cut.removed != 0 {
            out[n] = cut;
            n += 1
        }
    }
    n
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pile_abi() {
        assert_eq!(core::mem::size_of::<Support>(), 56);
        assert_eq!(core::mem::size_of::<Cut>(), 32);
        assert_eq!(core::mem::size_of::<Resting>(), 60);
        assert_eq!(core::mem::size_of::<RestingStep>(), 68);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_erode(
    heights: *mut f32,
    packed: *mut f32,
    bed: *const f32,
    visible: *const u8,
    count: usize,
    bx: f32,
    by: f32,
    cw: f32,
    dt: f32,
    front: f32,
    direction: f32,
    mode: u32,
    finish: u32,
    share: f32,
    cuts: *mut Cut,
) -> usize {
    if count == 0 {
        return 0;
    }
    let h = unsafe { slice::from_raw_parts_mut(heights, count) };
    let p = unsafe { slice::from_raw_parts_mut(packed, count) };
    let bed = unsafe { slice::from_raw_parts(bed, count) };
    let visible = unsafe { slice::from_raw_parts(visible, count) };
    let out = unsafe { slice::from_raw_parts_mut(cuts, count) };
    let mut n = 0;
    for i in 0..count {
        let height = h[i];
        let x = bx + (i as f32 + 0.5) * cw;
        let loss = if mode == 2 {
            if visible[i] == 0 || height <= 1.5 {
                continue;
            }
            let around = (h[i.saturating_sub(12)] + h[(i + 12).min(count - 1)]) / 2.0;
            (height * 0.2).min((0.2 + (height - around).max(0.0) * 1.5) * share * dt)
        } else {
            if height <= 0.0 || (mode != 0 && (front - x) * direction <= 0.0) {
                continue;
            }
            if finish != 0 {
                height
            } else {
                height.min(
                    (if mode == 0 {
                        height * 2.5 + 6.0
                    } else {
                        height * 8.0 + 50.0
                    }) * dt,
                )
            }
        };
        h[i] = (height - loss).max(0.0);
        p[i] = p[i].min(h[i]);
        out[n] = Cut {
            x,
            surface: by + bed[i] + if mode == 2 { h[i] } else { height },
            area: if mode != 0 && visible[i] != 0 {
                loss * cw
            } else {
                0.0
            },
            removed: 1,
            ..Cut::default()
        };
        n += 1;
    }
    n
}
