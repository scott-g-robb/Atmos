//! Borrowed water fields: no allocation, readback or ownership crosses the ABI.
use crate::water_interaction::{Cursor, Release, push};
use crate::{cos, exp, len, sin, sqrtf};
use core::slice;
#[repr(C, align(8))]
pub struct Field {
    pub heights: *const f32,
    pub depths: *const f32,
    pub horizontal: *const f32,
    pub speeds: *const f32,
    pub impulses: *const [f32; 2],
    pub blockers: *const [f32; 4],
    pub count: usize,
    pub blocker_count: usize,
    pub origin: [f32; 2],
    pub support: [f32; 2],
    pub width: f32,
    pub spacing: f32,
    pub id: u32,
}
#[repr(C)]
#[derive(Default)]
pub struct Sample {
    pub depth: f32,
    pub current: f32,
    pub vx: f32,
    pub vy: f32,
    pub accepts: u32,
}
impl Field {
    fn accepts(&self, x: f32) -> bool {
        if x < self.origin[0] || x > self.origin[0] + self.width {
            return false;
        }
        if self.blocker_count == 0 {
            return true;
        }
        !unsafe { slice::from_raw_parts(self.blockers, self.blocker_count) }
            .iter()
            .any(|b| {
                x >= b[0]
                    && x <= b[2]
                    && self.origin[1] >= b[1] - 1.0
                    && self.origin[1] <= b[3] + 1.0
            })
    }
    fn depth(&self, x: f32) -> f32 {
        if self.count < 2 || self.width <= 0.0 {
            return 0.0;
        }
        let h = unsafe { slice::from_raw_parts(self.heights, self.count) };
        let column = ((x - self.origin[0]) / self.width * (self.count - 1) as f32)
            .clamp(0.0, (self.count - 1) as f32 - 0.0001);
        let i = column as usize;
        let t = column - i as f32;
        let a = h[i.saturating_sub(1)];
        let b = h[i];
        let c = h[i + 1];
        let d = h[(i + 2).min(self.count - 1)];
        let t2 = t * t;
        let t3 = t2 * t;
        let value = 0.5
            * ((2.0 * b)
                + (-a + c) * t
                + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2
                + (-a + 3.0 * b - 3.0 * c + d) * t3);
        let mut result = value.clamp((b.min(c) - 0.2).max(0.0), b.max(c) + 0.2);
        if self.origin[1] > 0.5 {
            let edge = (x - self.origin[0]).min(self.origin[0] + self.width - x);
            let t = (edge / 10.0).clamp(0.0, 1.0);
            result *= t * t * (3.0 - 2.0 * t)
        }
        result
    }
    fn sample(&self, x: f32) -> Sample {
        if self.count < 3 || self.width <= 0.0 {
            return Sample::default();
        }
        let h = unsafe { slice::from_raw_parts(self.heights, self.count) };
        let u = unsafe { slice::from_raw_parts(self.horizontal, self.count) };
        let v = unsafe { slice::from_raw_parts(self.speeds, self.count) };
        let kick = unsafe { slice::from_raw_parts(self.impulses, self.count) };
        let i = (((x - self.origin[0]) / self.spacing) as isize).clamp(1, self.count as isize - 2)
            as usize;
        let j = (((x - self.origin[0]) / self.width * (self.count - 1) as f32) as isize)
            .clamp(0, self.count as isize - 1) as usize;
        Sample {
            depth: self.depth(x),
            current: (u[i] * 0.12 - (h[i + 1] - h[i - 1]) / (2.0 * self.spacing) * 18.0)
                .clamp(-65.0, 65.0),
            vx: self.support[0] + u[j] + kick[j][0],
            vy: self.support[1] + v[j] + kick[j][1],
            accepts: self.accepts(x) as u32,
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_sample_water(field: *const Field, x: f32) -> Sample {
    unsafe { &*field }.sample(x)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_water_depth(field: *const Field, x: f32) -> f32 {
    unsafe { &*field }.depth(x)
}
unsafe extern "C" {
    fn floorf(x: f32) -> f32;
    fn ceilf(x: f32) -> f32;
}
fn columns(
    count: usize,
    ox: f32,
    width: f32,
    x: f32,
    radius: f32,
) -> Option<core::ops::RangeInclusive<usize>> {
    if count < 2 || width <= 0.0 {
        return None;
    }
    let scale = (count - 1) as f32 / width;
    let lower = (unsafe { floorf((x - radius - ox) * scale) } as isize).max(0);
    let upper = (unsafe { ceilf((x + radius - ox) * scale) } as isize).min(count as isize - 1);
    if lower > upper {
        None
    } else {
        Some(lower as usize..=upper as usize)
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_water_hit(
    depths: *mut f32,
    speeds: *mut f32,
    count: usize,
    ox: f32,
    width: f32,
    x: f32,
    amount: f32,
    impulse: f32,
    limit: f32,
    bounded: u32,
) {
    if count < 3 || width <= 0.0 {
        return;
    }
    let h = unsafe { slice::from_raw_parts_mut(depths, count) };
    let v = unsafe { slice::from_raw_parts_mut(speeds, count) };
    let i =
        (((x - ox) / width * (count - 1) as f32) as isize).clamp(1, count as isize - 2) as usize;
    for j in i.saturating_sub(2)..=(i + 2).min(count - 1) {
        let w = if i == j {
            0.4
        } else if i.abs_diff(j) == 1 {
            0.22
        } else {
            0.08
        };
        h[j] += amount * w;
        if bounded != 0 {
            h[j] = h[j].min(limit)
        }
        v[j] = (v[j] + impulse * w).clamp(-8.0, 8.0);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_water_extract(
    depths: *mut f32,
    count: usize,
    ox: f32,
    width: f32,
    x: f32,
    radius: f32,
    fraction: f32,
) -> f32 {
    if count < 2 || width <= 0.0 {
        return 0.0;
    }
    let h = unsafe { slice::from_raw_parts_mut(depths, count) };
    let mut amount = 0.0;
    let fraction = fraction.clamp(0.0, 1.0);
    if let Some(range) = columns(count, ox, width, x, radius) {
        for i in range {
            if (ox + i as f32 / (count - 1) as f32 * width - x).abs() <= radius {
                let taken = h[i] * fraction;
                h[i] -= taken;
                amount += taken
            }
        }
    }
    amount
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_water_kick(
    impulses: *mut [f32; 2],
    count: usize,
    ox: f32,
    width: f32,
    x: f32,
    radius: f32,
    vx: f32,
    vy: f32,
) {
    if count < 2 || width <= 0.0 {
        return;
    }
    let kicks = unsafe { slice::from_raw_parts_mut(impulses, count) };
    let radius = radius.max(1.0);
    if let Some(range) = columns(count, ox, width, x, radius) {
        for i in range {
            let w =
                (1.0 - (ox + i as f32 / (count - 1) as f32 * width - x).abs() / radius).max(0.0);
            kicks[i][0] += vx * w;
            kicks[i][1] += vy * w;
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_water_impart(
    depths: *mut f32,
    horizontal: *mut f32,
    speeds: *const f32,
    bed: *const f32,
    waves: *const f32,
    impulses: *mut [f32; 2],
    count: usize,
    cursor: *mut Cursor,
    vx: f32,
    vy: f32,
    interval: f32,
    releases: *mut Release,
    capacity: usize,
) -> usize {
    if count < 2 || capacity == 0 {
        return 0;
    }
    let c = unsafe { &mut *cursor };
    let dt = interval.clamp(1.0 / 120.0, 0.1);
    let delta = [vx - c.svx, vy - c.svy];
    let h = unsafe { slice::from_raw_parts_mut(depths, count) };
    let u = unsafe { slice::from_raw_parts_mut(horizontal, count) };
    let v = unsafe { slice::from_raw_parts(speeds, count) };
    let bed = unsafe { slice::from_raw_parts(bed, count) };
    let waves = unsafe { slice::from_raw_parts(waves, count) };
    let kicks = unsafe { slice::from_raw_parts_mut(impulses, count) };
    let out = unsafe { slice::from_raw_parts_mut(releases, capacity) };
    let mut n = 0;
    let volume = h.iter().sum::<f32>();
    let speed = len(delta[0], delta[1]);
    if speed > 350.0 && volume > 0.1 {
        c.foam = c.foam.max(((speed - 300.0) / 600.0).min(1.0))
    }
    c.foam_x = c.ox + c.width * 0.5;
    c.foam_radius = c.width;
    let separating = (-delta[1] / dt - 950.0).max(0.0);
    if separating > 0.0 && volume > 0.001 {
        for j in 0..count {
            let adhesion = 180.0 / h[j].max(0.3);
            let fraction = 1.0 - exp(-(separating - adhesion).max(0.0) / 950.0 * dt * 8.0);
            let mass = h[j] * fraction;
            if mass <= 0.0001 {
                continue;
            }
            let height = (h[j] - bed[j] + waves[j]).max(0.0);
            let velocity = [c.svx + u[j], c.svy + v[j]];
            h[j] -= mass;
            kicks[j] = velocity;
            push(
                out,
                &mut n,
                Release {
                    amount: mass,
                    point: [
                        c.ox + j as f32 / (count - 1) as f32 * c.width,
                        c.oy + height * 0.5,
                    ],
                    velocity,
                    continuous: 0,
                },
            );
        }
    }
    for value in u {
        *value = (*value - delta[0]).clamp(-1200.0, 1200.0)
    }
    c.svx = vx;
    c.svy = vy;
    n
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_water_pressure(
    depths: *mut f32,
    horizontal: *const f32,
    speeds: *const f32,
    bed: *const f32,
    impulses: *mut [f32; 2],
    count: usize,
    cursor: *const Cursor,
    dt: f32,
    sustained: *mut u32,
    releases: *mut Release,
    capacity: usize,
) -> usize {
    if count < 2 || capacity == 0 {
        return 0;
    }
    let c = unsafe { &*cursor };
    let h = unsafe { slice::from_raw_parts_mut(depths, count) };
    let u = unsafe { slice::from_raw_parts(horizontal, count) };
    let v = unsafe { slice::from_raw_parts(speeds, count) };
    let bed = unsafe { slice::from_raw_parts(bed, count) };
    let kicks = unsafe { slice::from_raw_parts_mut(impulses, count) };
    let out = unsafe { slice::from_raw_parts_mut(releases, capacity) };
    let mut n = 0;
    let mut strongest = 0.0f32;
    let decay = exp(-dt * 9.0);
    for i in 0..count {
        kicks[i][0] *= decay;
        kicks[i][1] *= decay;
        let up = kicks[i][1];
        strongest = strongest.max(up);
        let head = h[i];
        if unsafe { *sustained } != 0
            && head > 0.03
            && up > 120.0f32.max(unsafe { sqrtf(2.0 * 950.0 * head) })
        {
            let energy = (1.0 - 2.0 * 950.0 * head / (up * up)).max(0.0);
            let fraction = (energy * dt * 6.0).min(0.2);
            let mass = head * fraction;
            if mass > 0.001 {
                push(
                    out,
                    &mut n,
                    Release {
                        amount: mass,
                        point: [
                            c.ox + i as f32 / (count - 1) as f32 * c.width,
                            c.oy + (head - bed[i]).max(0.0),
                        ],
                        velocity: [c.svx + u[i] + kicks[i][0], c.svy + v[i] + kicks[i][1]],
                        continuous: 1,
                    },
                );
                h[i] -= mass;
                let damp = unsafe { sqrtf((1.0 - fraction).max(0.0)) };
                kicks[i][0] *= damp;
                kicks[i][1] *= damp;
            }
        }
    }
    if strongest < 120.0 {
        unsafe { *sustained = 0 }
    }
    n
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_water_release_all(
    depths: *mut f32,
    horizontal: *const f32,
    speeds: *const f32,
    bed: *const f32,
    impulses: *const [f32; 2],
    count: usize,
    cursor: *const Cursor,
    releases: *mut Release,
    capacity: usize,
) -> usize {
    if count < 2 || capacity == 0 {
        return 0;
    }
    let c = unsafe { &*cursor };
    let h = unsafe { slice::from_raw_parts_mut(depths, count) };
    let u = unsafe { slice::from_raw_parts(horizontal, count) };
    let v = unsafe { slice::from_raw_parts(speeds, count) };
    let bed = unsafe { slice::from_raw_parts(bed, count) };
    let kicks = unsafe { slice::from_raw_parts(impulses, count) };
    let out = unsafe { slice::from_raw_parts_mut(releases, capacity) };
    let mut n = 0;
    for i in 0..count {
        if h[i] > 0.0001 {
            push(
                out,
                &mut n,
                Release {
                    amount: h[i],
                    point: [
                        c.ox + i as f32 / (count - 1) as f32 * c.width,
                        c.oy + (h[i] - bed[i]).max(0.0) * 0.5,
                    ],
                    velocity: [c.svx + u[i] + kicks[i][0], c.svy + v[i] + kicks[i][1]],
                    continuous: 0,
                },
            );
            h[i] = 0.0;
        }
    }
    n
}

#[repr(C, align(8))]
#[derive(Clone, Copy, Default)]
pub struct Floating {
    pub position: [f32; 2],
    pub release_velocity: [f32; 2],
    pub surface_id: u32,
    pub x: f32,
    pub velocity: f32,
    pub size: f32,
    pub seed: f32,
    pub area: f32,
    pub turn: f32,
    pub age: f32,
    pub alpha: f32,
    pub below_dock: u32,
    pub status: u32,
}
#[repr(C)]
pub struct DriftStep {
    pub dt: f32,
    pub wind: f32,
    pub cx: f32,
    pub cy: f32,
    pub px: f32,
    pub py: f32,
    pub vx: f32,
    pub vy: f32,
    pub lifetime: f32,
    pub flags: u32,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_drift_begin(items: *mut Floating, count: usize) {
    if count == 0 {
        return;
    }
    for item in unsafe { slice::from_raw_parts_mut(items, count) } {
        item.status = 1;
        item.release_velocity = [item.velocity, -12.0];
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_drift_surface(
    items: *mut Floating,
    count: usize,
    field: *const Field,
    step: *const DriftStep,
) {
    if count == 0 {
        return;
    }
    let f = unsafe { &*field };
    let s = unsafe { &*step };
    for item in unsafe { slice::from_raw_parts_mut(items, count) } {
        if item.surface_id != f.id {
            continue;
        }
        let x = f.origin[0] + item.x;
        let water = f.sample(x);
        if water.vy > 45.0 {
            item.position = [x, f.origin[1] + water.depth];
            item.release_velocity = [water.vx, water.vy];
            continue;
        }
        if water.depth <= 0.16 || water.accepts == 0 {
            item.position[0] = x;
            continue;
        }
        if s.flags & 1 != 0 && len(s.vx, s.vy) > 100.0 {
            let stroke = [s.cx - s.px, s.cy - s.py];
            let squared = stroke[0] * stroke[0] + stroke[1] * stroke[1];
            let t = (((item.position[0] - s.px) * stroke[0]
                + (item.position[1] - s.py) * stroke[1])
                / squared.max(0.001))
            .clamp(0.0, 1.0);
            let point = if squared < 160000.0 {
                [s.px + stroke[0] * t, s.py + stroke[1] * t]
            } else {
                [s.cx, s.cy]
            };
            let mut normal = [item.position[0] - point[0], item.position[1] - point[1]];
            let mut distance = len(normal[0], normal[1]);
            if distance < 0.001 {
                let speed = len(s.vx, s.vy).max(1.0);
                normal = [s.vx / speed, s.vy / speed];
                distance = 1.0
            }
            if distance < 11.0 + item.size * 0.3 && distance > 0.001 {
                normal[0] /= distance;
                normal[1] /= distance;
                let impulse = (s.vx * normal[0] + s.vy * normal[1]).max(0.0);
                item.release_velocity = [
                    water.vx + normal[0] * impulse,
                    water.vy + normal[1] * impulse,
                ];
                continue;
            }
        }
        item.age += s.dt;
        let current = water.current + s.wind * 0.025;
        item.velocity += (current - item.velocity) * (1.0 - exp(-s.dt * 2.8));
        item.x += item.velocity * s.dt;
        let world_x = f.origin[0] + item.x;
        let target = if cos(item.turn) < 0.0 {
            if item.turn < 0.0 {
                -core::f32::consts::PI
            } else {
                core::f32::consts::PI
            }
        } else {
            0.0
        };
        let ripple = (f.depth(world_x + 3.0) - f.depth(world_x - 3.0)) * 0.04;
        item.turn += (target + ripple + sin(item.age * 0.7 + item.seed * 17.0) * 0.08 - item.turn)
            * (s.dt * 3.0).min(1.0);
        item.position = [world_x, f.origin[1] + f.depth(world_x) + item.size * 0.055];
        if s.flags & 6 != 0 || item.age > s.lifetime {
            item.alpha = (item.alpha - s.dt * if s.flags & 4 != 0 { 2.0 } else { 0.7 }).max(0.0)
        }
        item.status = if item.alpha <= 0.0 { 2 } else { 0 };
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn borrowed_water_abi() {
        assert_eq!(core::mem::size_of::<Field>(), 96);
        assert_eq!(core::mem::size_of::<Sample>(), 20);
        assert_eq!(core::mem::size_of::<Floating>(), 64);
        assert_eq!(core::mem::size_of::<DriftStep>(), 40);
    }
}
