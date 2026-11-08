use crate::atmosphere::{FlowSample, flow};
use crate::{cos, exp, len, sin};
use core::slice;
unsafe extern "C" {
    #[link_name = "sin"]
    fn sin64(x: f64) -> f64;
}
#[repr(C, align(16))]
#[derive(Clone, Copy, Default)]
pub struct Float4(pub [f32; 4]);
#[repr(C, align(16))]
#[derive(Clone, Copy, Default)]
pub struct Flake {
    pub position: [f32; 2],
    pub velocity: [f32; 2],
    pub retirement: f32,
    pub fall: f32,
    pub size: f32,
    pub depth: f32,
    pub alpha: f32,
    pub soft: f32,
    pub phase: f32,
    pub sway_rate: f32,
    pub sway_amount: f32,
    pub mass: f32,
    pub tint: Float4,
    pub tint_amount: f32,
    pub blown: f32,
    pub leaf: f32,
    pub previous_y: f32,
    pub settles: u32,
    pub status: u32,
    pub render_velocity: [f32; 2],
}
#[repr(C, align(8))]
#[derive(Clone, Copy, Default)]
pub struct Grain {
    pub position: [f32; 2],
    pub velocity: [f32; 2],
    pub area: f32,
    pub size: f32,
    pub lump: f32,
    pub seed: f32,
    pub flags: u32,
    pub status: u32,
    pub previous_y: f32,
}
#[repr(C, align(8))]
#[derive(Clone, Copy, Default)]
pub struct Mote {
    pub position: [f32; 2],
    pub velocity: [f32; 2],
    pub size: f32,
    pub alpha: f32,
    pub age: f32,
    pub life: f32,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SnowStep {
    pub dt: f32,
    pub time: f32,
    pub wind: f32,
    pub weather_wind: f32,
    pub slide: f32,
    pub gust: f32,
    pub width: f32,
    pub gravity: f32,
    pub style: f32,
    pub drag: f32,
    pub cursor_x: f32,
    pub cursor_y: f32,
    pub previous_x: f32,
    pub previous_y: f32,
    pub cursor_vx: f32,
    pub cursor_vy: f32,
    pub wake_x: f32,
    pub wake_y: f32,
    pub wake_vx: f32,
    pub wake_vy: f32,
    pub flags: u32,
}
fn motion(f: &Flake) -> [f32; 2] {
    let sway = (cos(f.phase) + 0.3 * cos(f.phase * 2.3)) * f.sway_amount;
    let flutter = if f.leaf > 0.0 {
        0.3 + 1.1 * cos(f.phase).abs()
    } else {
        1.0 + 0.12 * sin(f.phase * 1.3)
    };
    [f.velocity[0] + sway, f.velocity[1] * flutter]
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_snow_motion(f: *const Flake) -> FlowSample {
    let v = motion(unsafe { &*f });
    FlowSample { x: v[0], y: v[1] }
}
#[unsafe(no_mangle)]
pub extern "C" fn sh_snow_breeze(time: f64, strength: f32, wind: f32) -> f32 {
    let breeze = unsafe {
        10.0 * sin64(time * 0.07) + 6.0 * sin64(time * 0.19 + 1.7) + 3.0 * sin64(time * 0.43 + 4.1)
    } as f32;
    breeze * (0.6 + 0.4 * strength) + wind
}
fn touches(p: [f32; 2], size: f32, s: &SnowStep) -> bool {
    if s.flags & 4 == 0 || len(s.cursor_vx, s.cursor_vy) <= 70.0 {
        return false;
    }
    let dx = s.cursor_x - s.previous_x;
    let dy = s.cursor_y - s.previous_y;
    let length = dx * dx + dy * dy;
    let t = (((p[0] - s.previous_x) * dx + (p[1] - s.previous_y) * dy) / length.max(0.001))
        .clamp(0.0, 1.0);
    let contact = if length > 160000.0 {
        [s.cursor_x, s.cursor_y]
    } else {
        [s.previous_x + dx * t, s.previous_y + dy * t]
    };
    len(p[0] - contact[0], p[1] - contact[1]) < size * 0.44 + 4.0
}
fn stir(v: &mut [f32; 2], p: [f32; 2], s: &SnowStep) {
    if s.flags & 8 == 0 {
        return;
    }
    let d = (p[0] - s.wake_x) * (p[0] - s.wake_x) + (p[1] - s.wake_y) * (p[1] - s.wake_y);
    if d >= 6400.0 {
        return;
    }
    let falloff = 1.0 - unsafe { crate::sqrtf(d) } / 80.0;
    let t = (falloff * falloff * 4.0 * s.dt).min(1.0);
    v[0] += (s.wake_vx - v[0]) * t;
    v[1] += (s.wake_vy - v[1]) * t;
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_advance_snow_flakes(
    flakes: *mut Flake,
    count: usize,
    step: *const SnowStep,
    cells: *const [f32; 4],
    columns: usize,
    rows: usize,
    spacing: f32,
    base: f32,
) {
    if count == 0 {
        return;
    }
    let s = unsafe { &*step };
    let flakes = unsafe { slice::from_raw_parts_mut(flakes, count) };
    let follow = (s.dt * (1.2 + s.slide.abs() * 0.03)).min(1.0);
    let settle = (s.dt * 1.6).min(1.0);
    for f in flakes {
        f.status = 0;
        if s.flags & 1 != 0 {
            f.retirement -= s.dt;
            if f.retirement <= 0.0 {
                f.status = 1;
                continue;
            }
            if f.retirement < 1.0 {
                f.alpha = f.alpha.min(f.retirement)
            }
        }
        if f.blown != 0.0 {
            f.velocity[0] +=
                (f.blown * s.gust * (1.3 + 1.3 * f.depth) - f.velocity[0]) * (s.dt * 2.5).min(1.0)
        } else {
            let local = unsafe {
                flow(
                    cells,
                    columns,
                    rows,
                    spacing,
                    base,
                    f.position[0],
                    f.position[1],
                )
            };
            let wind = s.wind - s.weather_wind + local[0];
            let response = if s.style == 3.0 || s.style == 6.0 {
                1.6
            } else if s.style == 5.0 {
                0.8
            } else {
                1.0
            };
            f.velocity[0] +=
                (wind * (0.35 + 0.65 * f.depth) - f.velocity[0]) * (follow * response).min(1.0);
            f.velocity[1] += local[1] * s.dt * response;
        }
        f.velocity[1] += (-f.fall - f.velocity[1]) * settle;
        if s.style == 3.0 && f.leaf > 2.0 && touches(f.position, f.size, s) {
            f.status = 2;
            continue;
        }
        stir(&mut f.velocity, f.position, s);
        f.phase += f.sway_rate * s.dt;
        if f.phase > 20.0 * core::f32::consts::PI {
            f.phase -= 20.0 * core::f32::consts::PI
        }
        if f.tint_amount > 0.0 {
            f.tint_amount = (f.tint_amount - s.dt * 1.3).max(0.0)
        }
        f.previous_y = f.position[1];
        f.render_velocity = motion(f);
        f.position[0] += f.render_velocity[0] * s.dt;
        f.position[1] += f.render_velocity[1] * s.dt;
        if f.blown != 0.0 && (f.position[0] < -30.0 || f.position[0] > s.width + 30.0) {
            f.status = 1;
            continue;
        }
        if f.position[0] < -30.0 {
            f.position[0] += s.width + 60.0
        } else if f.position[0] > s.width + 30.0 {
            f.position[0] -= s.width + 60.0
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_advance_snow_grains(
    grains: *mut Grain,
    count: usize,
    step: *const SnowStep,
    cells: *const [f32; 4],
    columns: usize,
    rows: usize,
    spacing: f32,
    base: f32,
) {
    if count == 0 {
        return;
    }
    let s = unsafe { &*step };
    let grains = unsafe { slice::from_raw_parts_mut(grains, count) };
    let damping = exp(-s.drag * s.dt);
    let air = exp(-3.2 * s.dt);
    for g in grains {
        g.status = 0;
        if s.style == 3.0 && g.seed > 2.0 && touches(g.position, g.size, s) {
            g.status = 2;
            continue;
        }
        g.previous_y = g.position[1];
        if g.flags & 1 != 0 {
            let speed = if g.velocity[0] < 0.0 {
                -s.gust * 1.6
            } else {
                s.gust * 1.6
            };
            g.velocity[0] += (speed - g.velocity[0]) * (s.dt * 2.0).min(1.0);
            g.velocity[1] -= s.gravity * 0.08 * s.dt;
        } else if s.flags & 2 != 0 {
            let phase = s.time * (1.2 + g.seed) + g.seed * 40.0;
            let fall = (35.0 + 30.0 * g.seed) * (0.3 + 1.1 * cos(phase).abs());
            let local = unsafe {
                flow(
                    cells,
                    columns,
                    rows,
                    spacing,
                    base,
                    g.position[0],
                    g.position[1],
                )
            };
            let carried = s.wind - s.weather_wind + local[0];
            g.velocity[0] = (g.velocity[0] - carried) * air + carried;
            g.velocity[1] += local[1] * s.dt;
            g.velocity[1] = (g.velocity[1] + fall) * air - fall;
            if g.flags & 2 == 0 {
                stir(&mut g.velocity, g.position, s)
            }
            g.position[0] += cos(phase) * 60.0 * s.dt;
        } else {
            g.velocity[1] -= s.gravity * s.dt;
            g.velocity[0] *= damping;
            g.velocity[1] *= damping;
        }
        g.position[0] += g.velocity[0] * s.dt;
        g.position[1] += g.velocity[1] * s.dt;
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sh_advance_snow_motes(
    motes: *mut Mote,
    count: usize,
    dt: f32,
    wind: f32,
) -> usize {
    if count == 0 {
        return 0;
    }
    let m = unsafe { slice::from_raw_parts_mut(motes, count) };
    let mut n = count;
    let damping = exp(-3.2 * dt);
    for i in (0..count).rev() {
        let mut mote = m[i];
        mote.age += dt;
        if mote.age >= mote.life {
            n -= 1;
            m[i] = m[n]
        } else {
            mote.velocity[1] -= 35.0 * dt;
            mote.velocity[0] *= damping;
            mote.velocity[1] *= damping;
            mote.position[0] += (mote.velocity[0] + wind * 0.4) * dt;
            mote.position[1] += mote.velocity[1] * dt;
            m[i] = mote;
        }
    }
    n
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snow_layouts_match_c() {
        assert_eq!(core::mem::size_of::<Flake>(), 112);
        assert_eq!(core::mem::offset_of!(Flake, tint), 64);
        assert_eq!(core::mem::size_of::<Grain>(), 48);
        assert_eq!(core::mem::size_of::<Mote>(), 32);
        assert_eq!(core::mem::size_of::<SnowStep>(), 84);
    }
    #[test]
    fn wake_is_stationary_without_cursor_motion() {
        let mut v = [5.0, -20.0];
        let s = SnowStep::default();
        stir(&mut v, [0.0, 0.0], &s);
        assert_eq!(v, [5.0, -20.0]);
    }
}
