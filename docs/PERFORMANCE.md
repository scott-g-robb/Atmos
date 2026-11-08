# Atmos 0.14.2 performance notes

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
