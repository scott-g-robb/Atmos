use crate::{len, sqrtf};
use core::slice;
unsafe extern "C" {
    fn floorf(x: f32) -> f32;
    fn ceilf(x: f32) -> f32;
    fn roundf(x: f32) -> f32;
}
#[repr(C, align(8))]
#[derive(Clone, Copy, Default)]
pub struct Release {
    pub point: [f32; 2],
    pub velocity: [f32; 2],
    pub amount: f32,
    pub continuous: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Cursor {
    pub ox: f32,
    pub oy: f32,
    pub width: f32,
    pub spacing: f32,
    pub svx: f32,
    pub svy: f32,
    pub x: f32,
    pub y: f32,
    pub px: f32,
    pub py: f32,
    pub vx: f32,
    pub vy: f32,
    pub scale: f32,
    pub foam: f32,
    pub foam_x: f32,
    pub foam_radius: f32,
}
#[repr(C)]
#[derive(Default)]
pub struct Result {
    pub count: usize,
    pub touched: u32,
    pub foam: f32,
    pub foam_x: f32,
    pub foam_radius: f32,
}
pub(crate) fn push(out: &mut [Release], n: &mut usize, release: Release) {
    if release.amount <= 0.0 || out.is_empty() {
        return;
    }
    if *n < out.len() {
        out[*n] = release;
        *n += 1
    } else {
        let last = out.len() - 1;
        let old = out[last];
        let total = old.amount + release.amount;
        for k in 0..2 {
            out[last].point[k] =
                (old.point[k] * old.amount + release.point[k] * release.amount) / total;
            out[last].velocity[k] =
                (old.velocity[k] * old.amount + release.velocity[k] * release.amount) / total;
        }
        out[last].amount = total;
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_collide_water(
    depths: *mut f32,
    horizontal: *mut f32,
    speeds: *mut f32,
    impulses: *mut [f32; 2],
    count: usize,
    blockers: *const [f32; 4],
    blocker_count: usize,
    cursor: *const Cursor,
    releases: *mut Release,
    capacity: usize,
) -> Result {
    let mut result = Result::default();
    if count < 3 || capacity == 0 {
        return result;
    }
    let c = unsafe { &*cursor };
    result.foam = c.foam;
    result.foam_x = c.foam_x;
    result.foam_radius = c.foam_radius;
    if c.width <= 0.0 {
        return result;
    }
    let h = unsafe { slice::from_raw_parts_mut(depths, count) };
    let u = unsafe { slice::from_raw_parts_mut(horizontal, count) };
    let v = unsafe { slice::from_raw_parts_mut(speeds, count) };
    let kicks = unsafe { slice::from_raw_parts_mut(impulses, count) };
    let out = unsafe { slice::from_raw_parts_mut(releases, capacity) };
    let blockers = if blocker_count == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(blockers, blocker_count) }
    };
    let stroke = [c.x - c.px, c.y - c.py];
    let steps = (unsafe { ceilf(len(stroke[0], stroke[1]) / 5.0) } as usize).clamp(1, 100);
    for step in 1..=steps {
        let t = step as f32 / steps as f32;
        let centre = [c.px + stroke[0] * t, c.py + stroke[1] * t];
        let lower = (unsafe { floorf((centre[0] - 11.0 - c.ox) / c.width * (count - 1) as f32) }
            as isize)
            .max(0);
        let upper = (unsafe { ceilf((centre[0] + 11.0 - c.ox) / c.width * (count - 1) as f32) }
            as isize)
            .min(count as isize - 1);
        if lower > upper {
            continue;
        }
        for i in lower as usize..=upper as usize {
            let x = c.ox + i as f32 / (count - 1) as f32 * c.width;
            let dx = x - centre[0];
            if dx.abs() >= 11.0
                || h[i] <= 0.001
                || blockers
                    .iter()
                    .any(|b| x >= b[0] && x <= b[2] && c.oy >= b[1] - 1.0 && c.oy <= b[3] + 1.0)
            {
                continue;
            }
            let half = unsafe { sqrtf((121.0 - dx * dx).max(0.0)) };
            let bottom = (centre[1] - half - c.oy).max(0.0);
            if centre[1] + half <= c.oy || h[i] <= bottom {
                continue;
            }
            result.touched = 1;
            let cap = bottom.max(centre[1] + half - c.oy);
            let above = (h[i] - cap).max(0.0);
            if above > 0.001 {
                push(
                    out,
                    &mut result.count,
                    Release {
                        amount: above,
                        point: [x, c.oy + cap + above * 0.5],
                        velocity: [c.svx + u[i], c.svy + v[i]],
                        continuous: 0,
                    },
                )
            }
            let amount = (h[i].min(cap) - bottom).max(0.0);
            let point_y = c.oy + bottom.max(h[i]);
            let mut normal = [x - centre[0], point_y - centre[1]];
            let distance = len(normal[0], normal[1]).max(0.001);
            normal[0] /= distance;
            normal[1] /= distance;
            let closing = (c.vx * normal[0] + c.vy * normal[1]).max(0.0);
            let down = (-c.vy).max(0.0);
            let confinement = (amount / half.max(1.0)).min(1.0);
            let rebound = down * unsafe { sqrtf(confinement) } * 0.65;
            let mut impulse = [normal[0] * closing, (normal[1] * closing).max(rebound)];
            impulse[0] += if dx < 0.0 {
                -rebound * 0.25
            } else {
                rebound * 0.25
            };
            // Reduce only cursor energy on window films. Displaced volume and
            // rain/support momentum are unchanged by the UI's splash preference.
            impulse[0] *= c.scale;
            impulse[1] *= c.scale;
            let impact = closing.max(rebound) * c.scale;
            if len(c.vx, c.vy) > 350.0 && centre[1] < point_y && amount > 0.15 && impact > 180.0 {
                result.foam = result.foam.max(((impact - 150.0) / 450.0).min(1.0));
                result.foam_x = x;
                result.foam_radius = 35.0;
            }
            h[i] = bottom;
            if impulse[1] > unsafe { sqrtf(2.0 * 950.0 * (h[i] + amount).max(0.5)) } {
                push(
                    out,
                    &mut result.count,
                    Release {
                        amount,
                        point: [centre[0] + normal[0] * 11.0, centre[1] + normal[1] * 11.0],
                        velocity: [c.svx + u[i] + impulse[0], c.svy + v[i] + impulse[1]],
                        continuous: 0,
                    },
                );
            } else {
                let side = if dx == 0.0 {
                    if c.vx < 0.0 { -1.0 } else { 1.0 }
                } else if dx < 0.0 {
                    -1.0
                } else {
                    1.0
                };
                let destination = centre[0] + side * (11.0 + c.spacing);
                let j = (unsafe { roundf((destination - c.ox) / c.width * (count - 1) as f32) }
                    as isize)
                    .clamp(0, count as isize - 1) as usize;
                h[j] += amount;
                u[j] += impulse[0] * amount / h[j].max(0.01);
                v[j] += impulse[1] * amount / h[j].max(0.01);
            }
            for k in i.saturating_sub(3)..=(i + 3).min(count - 1) {
                let weight =
                    (1.0 - (k as isize - i as isize).unsigned_abs() as f32 / 4.0) / steps as f32;
                kicks[k][0] += impulse[0] * weight;
                kicks[k][1] += impulse[1] * weight;
            }
        }
    }
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cursor_layout() {
        assert_eq!(core::mem::size_of::<Release>(), 24);
        assert_eq!(core::mem::size_of::<Cursor>(), 64);
        assert_eq!(core::mem::size_of::<Result>(), 24);
    }
}
