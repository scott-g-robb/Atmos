# Atmos 0.14.3 performance and presentation

The build 70 startup correction clears the linked overlay using the display
clock's supplied drawable, then pauses. Build 69's manual clear raised
CAMetalLayerInvalidOperation before the menu was created; the profiling entry
points bypassed that ordinary welcome path. Startup, empty scenes and pause/wake
now have separate regression checks, including real display callbacks. This follows
[Apple's display-link drawable ownership guidance](https://github.com/apple/game-porting-toolkit/blob/main/game-porting-skills/skills/presenting-metal-drawables/references/frame-pacing.md).

The 0.14.3 work changes scheduling and redundant work, not resolution, particle
counts, simulation frequency or visual-quality settings. CAMetalDisplayLink supplies
ready drawables at native refresh and keeps the main thread out of MTKView's drawable
wait. GPU backpressure is checked before input/physics, so a frame that cannot be
submitted does no redundant work and the next frame integrates elapsed time.
Native background fog reuses an unchanged
light field and skips a redundant full-screen intermediate. Window-system snapshots
are shared, callbacks coalesce, and unsupported optional notifications no longer
prevent other supported notifications from registering.

A 20-second run of the installed 0.14.2 on this M5 desktop measured 11.36% Atmos CPU,
18.90% process GPU time and 113 MiB resident memory. This fog/idle sample was not
the reported heavy lightning/leaves/birds scene and is not a worst-case bound.

The user clarified that Roblox was running on another Stage/Space while Atmos was
visible on the desktop. Atmos must keep rendering in that case; fullscreen pause
logic was not changed. A subsequent visible **wet** heavy-lightning, autumn-leaves
and birds run reproduced high Atmos CPU: 48.06%, with cached screenshot reflections,
119.93 submissions/s and 2.96 ms simulation per submitted frame. A dry run at 8.39%
CPU had not exercised that water load. Sampling identified `sh_couple_liquid` as
the dominant CPU work.

The Rust solver now caches exact live cell coordinates, tracks each sorted bucket's
processed prefix, and visits remaining sparse neighbours in the original rotated
order. Independent IEEE divisions use ARM NEON/Intel SSE. Particle counts,
constraint passes, pair ordering, rendering and interaction rules are preserved.
The same 7,800-particle input measured 6.151 ms/step in the test-only baseline versus
4.366 ms after optimisation (29% faster). Regression checks compare position,
velocity, mass and foam bit for bit across sparse/dense populations and cursor
contact; both native ARM and Intel/Rosetta checks passed.

A 30-second shipping desktop run after optimisation measured 27.71% CPU, 119.90
submissions/s and 1.40 ms simulation/frame. Final primary particle counts differed
(7,618 before versus 3,976 after), so those native runs are **not a controlled
equal-population speedup**; emission and lightning are stochastic. The isolated
solver comparison above uses identical inputs. Roblox GPU contention was not
recreated, and the installed Atmos copy remained active; WindowServer CPU is
excluded. Dense water remains substantial work and ≤5% CPU across every scene
has not been established.
A repeat measured 27.15% CPU, 119.93 submissions/s and 1.35 ms simulation/frame
(3,040 primary particles at the end). Both native runs closed cleanly without a
new crash report.

The explicit 0.14.3 visible-fog diagnostic (fog density 0.72, 58% clouds, real desktop
geometry and screenshot bloom) delivered/presented 2,410 frames in 20.10 seconds:
119.90 submissions/s on a 120 Hz display, with 9.95% process CPU. The installed old
copy remained running. This is a successful native-rate desktop run, **not** a
controlled whole-app before/after comparison.
A repeat recorded 1,445 submissions in 12.05 seconds (119.87/s), 9.83% CPU and
60 window-geometry queries (5/s while still). The drag-mask path is pixel-equivalent
to the Boolean version: its isolated build cost fell from 0.00556 ms to 0.00049 ms
per update (about 11×). Stage Manager size checks and short-lived Space membership
metadata also avoid repeated WindowServer lookups during drags; position updates
still run at native rate. These are component improvements, not a measured bound
on interactive CPU spikes. Raw reports are under build/verification/fixes69. The new display-link shutdown
regression and repeated native close were verified after correcting a double
invalidation caught by the native test.

Visual regressions cover matching live icons, prominent warnings, zero fog under a
regional alert when local visibility is clear, height-balanced fog with no clouds,
unchanged cached light fields, refreshed geometry, window motion, screenshot crops,
registered screenshot content and the existing water projection, and fresh location on normal weather polls while the
previous reading stays active. Physical Intel/macOS 14 and long interactive stress runs still
need physical-device validation. No universal CPU/FPS guarantee is established.

## Earlier 0.14.2 measurements

Measured on this Apple M5 workstation with release optimisation. These are component
measurements, not a promise of 120 fps or ≤5% CPU on every Mac. All visible effects
retain native refresh in normal operation; Low Power Mode permits up to 60 Hz.

## Screenshot cache and live geometry

The production pipeline uses `SCScreenshotManager`, never `SCStream`. It shares
per-window IOSurface-backed Metal images between water and fog, refreshing every
10 seconds normally, 20 seconds on battery and 30 seconds in Low Power Mode.
New windows, resizing and content hints can refresh sooner. Geometry, stacking and
clipping update independently of image refresh. Updated images crossfade for 150 ms.
Still geometry skips the composite pass; invisible consumers stop all capture work.

The same eight-window, 12-second synthetic-IOSurface benchmark was recorded before
and after the pipeline change, with 1,440 geometry/render ticks (120 Hz):

| Measurement | Before | After |
| --- | ---: | ---: |
| Image refreshes | 96 | 16 |
| Process CPU, one-core basis | 6.01% | 5.60% |
| Metal encoding per tick | 0.0139 ms | 0.0153 ms |
| GPU per tick | 0.1439 ms | 0.1853 ms |
| Allocated GPU storage | 3,817,472 bytes | 3,817,472 bytes |

There were 83% fewer image refreshes. The crossfade adds short GPU work; the small
encoding/GPU measurements vary between runs. The baseline here is the previous
window-snapshot cache, **not a measurement of continuous recording**. The screenshot
service, WindowServer, full weather simulation and normal app UI are excluded.

The initial direct-shell diagnostics lacked capture permission. Launching the signed
copies through LaunchServices picked up the existing grant, so actual 12-second
before/after diagnostics also completed:

| Production capture + geometry + Metal composite/copy | Stream baseline | Screenshot pipeline |
| --- | ---: | ---: |
| Observed source frames / screenshots | 341 | 8 |
| Render ticks | 1440 | 1440 |
| Maximum enumerated windows | 7 | 5 |
| Diagnostic process CPU | 8.05% | 9.09% |
| Encoding per tick | 0.0753 ms | 0.1740 ms |
| GPU per tick | 0.1287 ms | 1.8586 ms |
| Allocated Metal storage | 10,584,064 bytes | 18,874,368 bytes |

This confirms actual screenshot operation and fewer screen-source updates. **It does
not demonstrate lower CPU/GPU cost in the real diagnostic**: the screenshot run was
slightly higher in CPU and used more texture storage. Desktop/window enumeration
also differed, the old installed app remained running, and GPU timings varied
substantially (the first screenshot run measured 0.765 ms/tick). These measurements
include the diagnostic's 120 Hz texture copy and scheduling; they exclude weather
simulation and WindowServer/capture-service CPU. They are not whole-app usage or a
controlled like-for-like GPU speedup. The synthetic benchmark above provides the
controlled cache comparison. No TCC state or system indicator was bypassed or altered.

macOS 14 supports this [one-off screenshot API](https://developer.apple.com/videos/play/wwdc2023/10136/).
Atmos labels its permission **Screenshot Access**, but macOS grants access through
its shared **Screen & System Audio Recording** category. Removing streams removes
the persistent recording session; it does not guarantee the absence of OS access
indicators or permission reminders. Screenshots stay in memory, never on disk or
uploaded. macOS 14/Intel, multiple physical displays, fresh permissions and the
actual indicator behavior remain device verification checks. Another installed Atmos
copy was active, so the indicator could not be attributed to this pipeline in isolation.

## Rust CPU physics

Swift retains AppKit integration, OS geometry, scene policy, emission scheduling,
visual assembly and buffer ownership. Metal retains parallel rendering, smoke and
liquid-contour reconstruction. The existing allocation-free Rust core now also owns:

- Window-sheltered wind-field generation and interpolation.
- Snow and botanical flight, grain/mote integration and cursor wake.
- Snow-pile transport, melting, settling, swept cursor displacement, support inertia,
  friction, lift, resting-leaf interaction and wind erosion.
- Water cursor displacement, support momentum, detachment, pressure-driven jets,
  cubic waterline/current queries, extraction, splash emission and ripple merging.
- Buoyant material motion, splash/cursor release and bird steering/perch/takeoff physics.

C-defined layouts are checked in C and Rust for both target architectures. Rust
borrows existing buffers for each call and never stores Swift pointers. Large loops
are batched; no runtime process, serialization layer or Rust heap allocator was added.
Window-top cursor impulse is halved; rainfall, lightning and support motion retain
their previous energy rules. Volume conservation and momentum regression tests pass.

The CPU-only before/after harness measures fixed-size wind/pile fields and warmed
snow/botanical scenes. Times are milliseconds per step:

| Kernel/scene | Before | After |
| --- | ---: | ---: |
| wind field | 0.0473 | 0.0469 |
| snow piles | 0.0126 | 0.0160 |
| snow/botanical scene 0 | 0.0927 | 0.0732 |
| snow/botanical scene 1 | 0.0125 | 0.0131 |
| snow/botanical scene 3 | 0.0024 | 0.0024 |
| snow/botanical scene 5 | 0.0130 | 0.0128 |

The heavy-snow scene improved by about 21%. Wind and sparse botanical timings are
close; the pile microbenchmark is about 0.0034 ms slower. Rust is not automatically
faster than optimised Swift. Random botanical population/lifetime changes also make
sparse scene results approximate; these are not equal-particle throughput claims.
Dense-liquid reports separately record CPU simulation, encoding and GPU time at
3024×1964, including an 8,160-particle cursor stress case. Capture is excluded.

## Reproduce and inspect

Run the release tests with `ATMOS_PHYSICS_BENCHMARK_DIR`,
`ATMOS_CAPTURE_BENCHMARK_DIR`, `ATMOS_BENCHMARK_DIR` and `ATMOS_RENDER_DIR` set to
absolute output directories. `ATMOS_SWEEP_NATIVE=1` selects the native-size stress
case; `ATMOS_TEST_GITHUB=1` enables the optional real update download/signature check.
Use `--profile-desktop-capture` only with already granted screenshot permission.
It writes counts/timings only, never screen images, window names or coordinates.

Raw local reports: `build/verification/hybrid-before`, `hybrid-after`, `rust-before`,
`rust-after` and `hybrid68`. Test/render artifacts and profiles are excluded from
the uploadable source archive. The signed app and installer include the supplied
6.32-second intro audio; welcome playback is once per flow, quiet on silent updates.


## 0.14.4 continuity check

Short sequential samples used the same visible-fog diagnostic (fog 0.72, cloud
coverage 58%, cached screenshot bloom and native geometry) on the 120 Hz M5 display:

| Build | Native presentations/s | Process CPU | Geometry queries in sample |
| --- | ---: | ---: | ---: |
| Installed 0.14.3 (72) | 119.81 | 17.66% | 59 |
| Notarized 0.14.4 (73) | 119.91 | 16.81% | 58 |

Each measured interval was about 12 seconds after warmup. The installed app also
remained open during both diagnostics; other desktop activity and GPU scheduling
were not controlled. These are pacing/regression observations, not evidence of a
general CPU speedup or a ≤5% CPU result. They exclude WindowServer CPU. Particle
counts were 11 in each run; the capture status was Fog bloom · Cached screenshots.
The release changes do not reduce render resolution, particle counts or native
refresh. No Rust physics algorithm changed in this release.

Full reports are in ignored build/verification/release144/visible-fog.json and
baseline72-visible-fog.json. The event-tracking regression confirms native frames
continue both during a context-menu run-loop mode and after returning to default
mode. The sky continuity tests cover identical refreshes, 50→60% cover, primary
precipitation changes, persistent wind direction and observation-stable accents.
