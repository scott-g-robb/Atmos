use crate::atmosphere::flow;
use crate::{Particle, len, sin};
use core::slice;
#[repr(C, align(8))]
#[derive(Clone, Copy, Default)]
pub struct Bird {
    pub position: [f32; 2],
    pub velocity: [f32; 2],
    pub species: u32,
    pub seed: f32,
    pub facing: f32,
    pub age: f32,
    pub phase: f32,
    pub perch: u32,
    pub perch_x: f32,
    pub rest: f32,
    pub rest_limit: f32,
    pub leaving: u32,
    pub support: [f32; 2],
    pub support_velocity: [f32; 2],
    pub seen: f32,
    pub has_support: u32,
}
#[repr(C, align(8))]
#[derive(Clone, Copy, Default)]
pub struct Target {
    pub point: [f32; 2],
    pub available: u32,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_step_birds(
    birds: *mut Bird,
    count: usize,
    targets: *const Target,
    particles: *mut Particle,
    dt: f32,
    time: f32,
    width: f32,
    height: f32,
    _wind: f32,
    active: u32,
    cx: f32,
    cy: f32,
    cells: *const [f32; 4],
    columns: usize,
    rows: usize,
    spacing: f32,
    base: f32,
) -> usize {
    if count == 0 {
        return 0;
    }
    let birds = unsafe { slice::from_raw_parts_mut(birds, count) };
    let targets = unsafe { slice::from_raw_parts(targets, count) };
    let particles = unsafe { slice::from_raw_parts_mut(particles, count) };
    let mut n = 0;
    for i in 0..count {
        let mut b = birds[i];
        b.age += dt;
        if b.velocity[0].abs() > 2.0 {
            b.facing = if b.velocity[0] < 0.0 { -1.0 } else { 1.0 }
        }
        let mut target = targets[i].available != 0;
        let point = targets[i].point;
        let mut startled = false;
        if target {
            if b.has_support != 0 && len(b.support[0] - point[0], b.support[1] - point[1]) > 0.2 {
                let interval = dt.max((time - b.seen).min(0.12));
                let velocity = [
                    ((point[0] - b.support[0]) / interval).clamp(-1200.0, 1200.0),
                    ((point[1] - b.support[1]) / interval).clamp(-900.0, 900.0),
                ];
                let delta = len(
                    velocity[0] - b.support_velocity[0],
                    velocity[1] - b.support_velocity[1],
                );
                let acceleration = delta / interval;
                startled = b.phase == 1.0
                    && (len(velocity[0], velocity[1]) > 340.0
                        || (acceleration > 3200.0 && delta > 120.0));
                b.support_velocity = velocity;
                b.seen = time;
            }
            if b.has_support == 0 {
                b.seen = time
            }
            b.support = point;
            b.has_support = 1;
        }
        if startled {
            b.velocity = [
                b.support_velocity[0] * 0.35 + b.facing * 80.0,
                b.support_velocity[1] * 0.35 + 70.0,
            ];
            target = false
        }
        if active == 0
            || startled
            || (b.perch != 0 && !target)
            || len(cx - b.position[0], cy - b.position[1]) < 50.0
            || b.rest > b.rest_limit
        {
            b.leaving = 1;
            b.perch = 0;
            b.phase = 0.0;
        }
        if b.phase == 1.0 && target {
            b.position = point;
            b.velocity = [0.0, 0.0];
            b.rest += dt
        } else {
            let local = unsafe {
                flow(
                    cells,
                    columns,
                    rows,
                    spacing,
                    base,
                    b.position[0],
                    b.position[1],
                )
            };
            let mut desired = [
                (if b.velocity[0] < 0.0 { -1.0 } else { 1.0 }) * 105.0 + local[0] * 0.15,
                sin(time * 1.7 + b.seed * 31.0) * 9.0 + local[1] * 0.12,
            ];
            if target && b.leaving == 0 {
                let delta = [point[0] - b.position[0], point[1] - b.position[1]];
                let distance = len(delta[0], delta[1]);
                let speed = (distance * 1.8).max(14.0).min(125.0);
                desired = [
                    delta[0] / distance.max(1.0) * speed,
                    delta[1] / distance.max(1.0) * speed,
                ];
                if distance < 8.0 {
                    b.phase = 1.0;
                    b.position = point;
                    b.velocity = [0.0, 0.0]
                }
            } else if b.leaving != 0 {
                desired[1] = 55.0
            }
            let follow = (dt * 3.0).min(1.0);
            b.velocity[0] += (desired[0] - b.velocity[0]) * follow;
            b.velocity[1] += (desired[1] - b.velocity[1]) * follow;
            if b.phase != 1.0 {
                b.position[0] += b.velocity[0] * dt;
                b.position[1] += b.velocity[1] * dt
            }
        }
        if b.age > 48.0
            || b.position[0] < -200.0
            || b.position[0] > width + 200.0
            || b.position[1] > height + 80.0
        {
            continue;
        }
        particles[n] = Particle {
            rect: [
                b.position[0],
                b.position[1],
                if b.species == 3 {
                    33.0
                } else {
                    28.0 + b.seed * 2.0
                },
                if b.species == 3 { 25.0 } else { 27.0 },
            ],
            motion: [b.velocity[0], b.velocity[1], b.seed, 14.0],
            color: [0.24, 0.28, 0.33, (b.age * 2.0).min(1.0)],
            life: [2.0, 10000.0, b.facing * (b.species + 1) as f32, b.phase],
        };
        birds[n] = b;
        n += 1;
    }
    n
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bird_layout() {
        assert_eq!(core::mem::size_of::<Bird>(), 80);
        assert_eq!(core::mem::size_of::<Target>(), 16);
    }
}
