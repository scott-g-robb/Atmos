use crate::water_interaction::Release;
use crate::{Particle, cos, exp, sin, sqrtf};
use core::slice;
#[repr(C, align(8))]
#[derive(Clone, Copy, Default)]
pub struct Ripple {
    pub point: [f32; 2],
    pub age: f32,
    pub strength: f32,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_step_ripples(ripples: *mut Ripple, count: usize, dt: f32) -> usize {
    if count == 0 {
        return 0;
    }
    let ripples = unsafe { slice::from_raw_parts_mut(ripples, count) };
    let mut n = 0;
    for i in 0..count {
        let mut r = ripples[i];
        r.age += dt;
        if r.age <= 1.5 {
            ripples[n] = r;
            n += 1
        }
    }
    n
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_add_ripple(
    ripples: *mut Ripple,
    count: usize,
    capacity: usize,
    x: f32,
    y: f32,
    strength: f32,
) -> usize {
    if capacity == 0 || count > capacity {
        return count;
    }
    let ripples = unsafe { slice::from_raw_parts_mut(ripples, capacity) };
    for r in &mut ripples[..count] {
        let dx = r.point[0] - x;
        let dy = r.point[1] - y;
        if r.age < 0.1 && dx * dx + dy * dy < 576.0 {
            let total = r.strength + strength;
            r.point = [
                (r.point[0] * r.strength + x * strength) / total.max(0.001),
                (r.point[1] * r.strength + y * strength) / total.max(0.001),
            ];
            r.strength = unsafe { sqrtf(r.strength * r.strength + strength * strength) }.min(1.7);
            return count;
        }
    }
    let mut n = count;
    if n == capacity {
        let mut weakest = 0;
        let mut value = f32::INFINITY;
        for (i, r) in ripples[..count].iter().enumerate() {
            let score = r.strength * exp(-r.age * 4.0);
            if score < value {
                weakest = i;
                value = score
            }
        }
        if ripples[weakest].age <= 0.2 {
            return count;
        }
        ripples.copy_within(weakest + 1..count, weakest);
        n -= 1;
    }
    ripples[n] = Ripple {
        point: [x, y],
        age: 0.0,
        strength: strength.min(1.7),
    };
    n + 1
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_emit_liquid(
    particles: *mut Particle,
    count: usize,
    capacity: usize,
    release: *const Release,
    maximum: usize,
    phase: f32,
) -> usize {
    if capacity <= count || maximum == 0 {
        return count;
    }
    let r = unsafe { &*release };
    if r.amount <= 0.0001 {
        return count;
    }
    // ceil without libm: positive finite mass is bounded by the water columns.
    let needed = unsafe { ceilf(r.amount / 0.08) } as usize;
    let n = needed.max(1).min(maximum).min(capacity - count);
    let mass = r.amount / n as f32;
    let diameter = (unsafe { sqrtf(mass) } * 2.3).clamp(0.75, 1.8);
    let particles = unsafe { slice::from_raw_parts_mut(particles, capacity) };
    let extent = (unsafe { sqrtf(n as f32) } * 0.42).max(0.6);
    for k in 0..n {
        let angle = phase + k as f32 * 2.3999632;
        let radius = unsafe { sqrtf((k as f32 + 0.5) / n as f32) } * extent;
        let x = r.point[0] + cos(angle) * radius;
        let y = r.point[1] + sin(angle) * radius;
        let seed = phase / (2.0 * core::f32::consts::PI);
        particles[count + k] = Particle {
            rect: [x, y, diameter, diameter],
            motion: [
                r.velocity[0],
                r.velocity[1],
                if r.continuous != 0 {
                    -seed.max(0.001)
                } else {
                    seed
                },
                9.0,
            ],
            color: [x, y, diameter * 0.5, 0.9],
            life: [0.0, 14.0, mass, 0.0],
        };
    }
    count + n
}
unsafe extern "C" {
    fn ceilf(x: f32) -> f32;
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_lightning_liquid(
    particles: *mut Particle,
    count: usize,
    x: f32,
    radius: f32,
    line: f32,
    mass: f32,
    vx: f32,
    vy: f32,
    rise: f32,
    weight: f32,
) {
    if count == 0 || radius <= 0.0 {
        return;
    }
    let particles = unsafe { slice::from_raw_parts_mut(particles, count) };
    let extent = (unsafe { sqrtf(count as f32) } * 0.42).max(0.6);
    for p in particles {
        let z = (0.5 + (p.rect[1] - (line + 0.8)) / (2.0 * extent)).clamp(0.0, 1.0);
        p.rect[1] = line - mass + z * mass;
        let r = (p.rect[0] - x) / radius;
        p.motion[0] = vx + r * rise * 0.20;
        p.motion[1] = vy
            + rise * unsafe { sqrtf((1.0 - r * r).max(0.12)) } * unsafe { sqrtf(0.35 + 0.65 * z) };
        p.life[3] = 0.7 * weight;
    }
}
#[repr(C)]
pub struct Splash {
    pub radius: f32,
    pub fraction: f32,
    pub rise: f32,
    pub kick: f32,
    pub carried_x: f32,
    pub carried_y: f32,
}
#[unsafe(no_mangle)]
pub extern "C" fn sh_splash_parameters(
    vx: f32,
    vy: f32,
    water_vx: f32,
    water_vy: f32,
    amount: f32,
    desktop: u32,
) -> Splash {
    let speed = vy.abs();
    let rise = (speed * 0.23).min(500.0);
    Splash {
        radius: (speed * 0.007).clamp(4.0, 14.0),
        fraction: (if desktop != 0 { 0.08f32 } else { 0.14f32 }).min(amount * speed / 18000.0),
        rise,
        kick: rise * 0.3 * (amount / 4.0).min(1.0),
        carried_x: vx * 0.8 + water_vx * 0.2,
        carried_y: water_vy * 0.2 + rise,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn emission_keeps_real_mass_and_incoming_momentum() {
        let mut particles = [Particle::default(); 64];
        let r = Release {
            point: [3.0, 8.0],
            velocity: [70.0, 150.0],
            amount: 2.4,
            continuous: 0,
        };
        let n = unsafe { sh_emit_liquid(particles.as_mut_ptr(), 0, 64, &r, 64, 0.5) };
        assert!(n >= 29);
        let mass = particles[..n].iter().map(|p| p.life[2]).sum::<f32>();
        assert!((mass - r.amount).abs() < 0.00001);
        assert!(
            particles[..n]
                .iter()
                .all(|p| p.motion[0] == 70.0 && p.motion[1] == 150.0)
        );
        assert_eq!(core::mem::size_of::<Ripple>(), 16);
        assert_eq!(core::mem::size_of::<Splash>(), 24);
    }
}
