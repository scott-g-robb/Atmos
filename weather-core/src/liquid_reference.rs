// Test-only baseline for exact physics equivalence and isolated timing.
use super::*;

unsafe fn reference(
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
    fn hash(x: i32, y: i32) -> usize {
        ((x.wrapping_mul(73856093) ^ y.wrapping_mul(19349663)) as usize) & 4095
    }
    for pass in 0..if liquid_count > 2048 { 2 } else { 3 } {
        counts.fill(0);
        for item in p.iter_mut() {
            if item.motion[3] != 9.0 {
                continue;
            }
            if pass == 0 {
                item.life[3] *= foam_decay;
            }
            counts[hash((item.rect[0] / 6.0) as i32, (item.rect[1] / 6.0) as i32)] += 1;
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
            let cell = hash((p[i].rect[0] / 6.0) as i32, (p[i].rect[1] / 6.0) as i32);
            members[cursor[cell]] = i as u16;
            cursor[cell] += 1;
        }
        for i in 0..count {
            if p[i].motion[3] != 9.0 {
                continue;
            }
            let gx = (p[i].rect[0] / 6.0) as i32;
            let gy = (p[i].rect[1] / 6.0) as i32;
            for yy in gy - 1..=gy + 1 {
                for xx in gx - 1..=gx + 1 {
                    let cell = hash(xx, yy);
                    let population = counts[cell];
                    let probes = if population > 16 {
                        if liquid_count > 2048 { 4 } else { 6 }
                    } else {
                        population
                    };
                    if probes == 0 {
                        continue;
                    }
                    // Exact for sparse cells. In crowded cells sample uniformly across
                    // the entire contiguous population, never an unbounded linked list.
                    // Paired updates retain momentum; all particles still render/move.
                    let phase = (i.wrapping_mul(13) + pass * 7) % population;
                    let weight = (population as f32 / probes as f32).min(4.0);
                    for k in 0..probes {
                        // Sparse cells use every member; crowded cells use the same
                        // four/six uniform samples. The offset wraps at most once.
                        let stride = if probes == population {
                            k
                        } else if probes == 4 {
                            k * population / 4
                        } else {
                            k * population / 6
                        };
                        let offset = phase + stride;
                        let j = members[starts[cell]
                            + if offset >= population {
                                offset - population
                            } else {
                                offset
                            }] as usize;
                        if j <= i {
                            continue;
                        }
                        let dx = p[j].rect[0] - p[i].rect[0];
                        let dy = p[j].rect[1] - p[i].rect[1];
                        let d2 = dx * dx + dy * dy;
                        if d2 < 0.000001 || d2 >= 36.0 {
                            continue;
                        }
                        if (p[j].rect[0] / 6.0) as i32 != xx || (p[j].rect[1] / 6.0) as i32 != yy {
                            continue;
                        }
                        let rest = (p[i].rect[2] + p[j].rect[2]) * 0.43;
                        let reach = (rest * 3.0).min(6.0);
                        if d2 >= reach * reach {
                            continue;
                        }
                        let d = unsafe { sqrtf(d2) };
                        let nx = dx / d;
                        let ny = dy / d;
                        let mi = p[i].life[2].max(0.001);
                        let mj = p[j].life[2].max(0.001);
                        let wi = mj / (mi + mj);
                        let wj = mi / (mi + mj);
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

#[test]
fn liquid_broadphase_preserves_every_particle_and_interaction() {
    fn fixture(count: usize) -> Vec<Particle> {
        (0..count)
            .map(|i| {
                let mut p = Particle::default();
                p.rect = [
                    ((i * 37) % 113) as f32 * 2.1 - 12.0,
                    ((i * 17) % 73) as f32 * 1.9 - 8.0,
                    1.0 + (i % 7) as f32 * 0.2,
                    1.8,
                ];
                p.motion = [
                    (i % 31) as f32 * 11.0 - 160.0,
                    (i % 47) as f32 * 9.0 - 200.0,
                    0.0,
                    if i % 19 == 0 { 0.0 } else { 9.0 },
                ];
                p.life = [
                    0.1,
                    3.0,
                    0.03 + (i % 13) as f32 * 0.017,
                    (i % 11) as f32 / 11.0,
                ];
                p
            })
            .collect()
    }
    for count in [0, 3, 97, 2100, 7800] {
        let mut expected = fixture(count);
        let mut actual = expected.clone();
        for step in 0..4 {
            let dt = if step % 2 == 0 {
                1.0 / 120.0
            } else {
                1.0 / 60.0
            };
            unsafe {
                reference(expected.as_mut_ptr(), count, dt, 55.0, 63.0, 210.0, -125.0);
                sh_couple_liquid(actual.as_mut_ptr(), count, dt, 55.0, 63.0, 210.0, -125.0);
            }
            for (a, b) in actual.iter().zip(expected.iter()) {
                for (x, y) in a
                    .rect
                    .iter()
                    .chain(&a.motion)
                    .chain(&a.life)
                    .zip(b.rect.iter().chain(&b.motion).chain(&b.life))
                {
                    assert_eq!(x.to_bits(), y.to_bits(), "count {count}, step {step}");
                }
            }
        }
    }
    if let Ok(directory) = std::env::var("ATMOS_LIQUID_BENCHMARK_DIR") {
        let input = fixture(7800);
        let iterations = 180;
        let mut report = Vec::new();
        for optimized in [false, true] {
            let mut p = input.clone();
            let start = std::time::Instant::now();
            for _ in 0..iterations {
                p.copy_from_slice(&input);
                unsafe {
                    if optimized {
                        sh_couple_liquid(
                            p.as_mut_ptr(),
                            p.len(),
                            1.0 / 120.0,
                            55.0,
                            63.0,
                            210.0,
                            -125.0,
                        )
                    } else {
                        reference(
                            p.as_mut_ptr(),
                            p.len(),
                            1.0 / 120.0,
                            55.0,
                            63.0,
                            210.0,
                            -125.0,
                        )
                    }
                }
                std::hint::black_box(&p);
            }
            report.push(start.elapsed().as_secs_f64() * 1000.0 / iterations as f64);
        }
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(std::path::Path::new(&directory).join("liquid-broadphase.json"),format!("{{\n  \"previous_ms_per_step\": {},\n  \"optimized_ms_per_step\": {},\n  \"particles\": 7800,\n  \"bit_identical\": true\n}}\n",report[0],report[1])).unwrap();
    }
}
