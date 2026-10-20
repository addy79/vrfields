# VRFields: GPU-Accelerated Vector Calculus in VR

A virtual-reality app that draws **multivariable calculus** in 3D with **GPU compute shaders**,
built for the research proposal *"GPU-Accelerated Real-Time Vector Field Visualization for
Calculus Education in Virtual Reality"*. You type a function, the GPU evaluates it every frame,
and you walk around the result, grab it, slice it and probe it. It has five topics:

1. **Vector Fields**: F(x, y, z) as a 3D arrow grid colored by |F|, flow particles advected on
   the GPU, field lines from a movable rake, and a probe that reads F, div F and curl F
   (it can also inject dye to draw streaklines).
2. **Divergence & Curl**: a ray-marched volume cloud of div F or |curl F| (sources, sinks,
   rotation), a slicing plane you can grab and turn, a **paddle wheel** that spins at
   ω = ½ (curl F)·axis, and live checks of **Gauss's** and **Stokes's** theorems.
3. **Gradient**: the surface z = f(x, y) with level curves, ∇f arrows on the floor, a movable
   **tangent plane**, the directional derivative D_u f = ∇f · u, and the steepest-ascent path.
4. **Parametric Surfaces**: r(u, v) meshes generated on the GPU, colored by **Gaussian
   curvature** K, with tangent vectors r_u, r_v, the normal and the mean curvature H at a point.
   Sliders a, b and time t morph the surface live.
5. **Solids of Revolution**: a profile curve (or two, for washers) swept around the x-axis,
   a movable cross-section A(x), and n disks/washers converging to the volume integral.

Every topic has **two interchangeable backends**: the GPU compute shader, and a CPU
(GDScript) baseline that computes the same thing. Pressing **G** switches between them, and a
built-in **benchmark** measures both. That gives the proposal's GPU-vs-CPU performance data.

It runs on a PC (keyboard and mouse, no headset needed) and on a **Meta Quest** headset.

---

## At a glance

| | |
|---|---|
| **Language** | GDScript (Godot's Python-like scripting language) for the app; **GLSL** compute shaders generated at runtime from your typed function; Godot shading language for the visuals (`shaders/`) |
| **Engine** | Godot 4.7.2, Mobile renderer (Vulkan), OpenXR for VR |
| **Platforms** | Linux desktop (works without a headset), Meta Quest (Android APK, package `com.example.vrfields`) |
| **Addons** | Godot XR Tools 4.5.1 (patched for Godot 4.7, see `patches/`), Godot OpenXR Vendors 5.1.0 |
| **Tests** | windowed self-test (**76 checks**: GPU = CPU texel by texel, calculus against exact answers, real input events) + expression compiler test |
| **Research tools** | GPU-vs-CPU benchmark (CSV), per-participant interaction log (CSV) for the user study |

---

## How it works (the GPU pipeline)

```
typed text ──► MathExpr parser ──► AST ─┬─► GLSL source ──► compute shader (compiled at runtime)
 "(-y, x, 0)"   scripts/expr/           │      │  runs every frame on the GPU, writes textures
                                         │      ▼
                                         │   Texture2DRD / Texture3DRD ──► visual shaders
                                         │   (arrows, particles, volume, surfaces) sample them
                                         │   directly: no copy back to the CPU
                                         │
                                         └─► Godot Expression ──► CPU baseline (GDScript loop)
                                                writes the SAME texture layout, uploaded each update
```

- **One parser, two outputs.** `scripts/expr/math_expr.gd` turns your text into a syntax tree
  and emits it both as GLSL (for the GPU) and as a Godot `Expression` (for the CPU baseline
  and the probes). So both backends compute exactly the same function.
- **Compute shaders** (`scripts/gpu/`): `gpu_program.gd` compiles the generated GLSL with
  `RenderingDevice.shader_compile_spirv_from_source` on Godot's main rendering device, so the
  output textures are used by the renderer with no CPU-GPU round trip. Parameters (t, a, b)
  travel as 128-byte push constants. One engine per kind of data:
  `vector_field_engine.gd`, `scalar_surface_engine.gd`, `parametric_engine.gd`, `profile_engine.gd`.
- **Rendering:** arrows and particles are instanced meshes whose vertex shaders read their
  position and vector from the field texture; the div/curl cloud is ray-marched through a 3D
  texture; surfaces are flat grids displaced in the vertex shader.
- **The CPU baseline** loops over the same points in GDScript and uploads an `ImageTexture`.
  Same layout, same shaders, so the only difference is where the math runs.

---

## Where do the numbers come from?

**Short answer:** everything is **computed numerically from the function you type**, live,
on the GPU (or on the CPU when you pick the baseline). Nothing is pre-recorded and there is no
physics engine. The benchmark numbers are **real measurements** on whatever machine runs it.

| Quantity | Method | Code |
|---|---|---|
| Your function | recursive-descent parser → GLSL (GPU) and Godot `Expression` (CPU) | `scripts/expr/math_expr.gd` |
| div F, curl F | central differences of the function itself, h = 0.001 × domain (not limited by the arrow grid) | `scripts/gpu/vector_field_engine.gd` |
| Flow particles | dp/dt = F(p), **RK4** on the GPU | `vector_field_engine.gd` |
| Field lines | unit-speed RK4 (arc-length parametrised) from the rake's seed points | `vector_field_engine.gd` |
| Gauss check (flux ≈ div F × volume) | flux out of a sphere of radius 0.35, 400-point Fibonacci-sphere quadrature | `scripts/topics/div_curl_topic.gd` |
| Stokes check (circulation ≈ (curl F)·n × area) | ∮ F · dr around a circle, 96-point midpoint rule | `div_curl_topic.gd` |
| Paddle wheel speed | ω = ½ (curl F) · axis at the probe | `div_curl_topic.gd` |
| ∂f/∂x, ∂f/∂y, ∇f, tangent plane | central differences, h = 0.001 × domain | `scripts/gpu/scalar_surface_engine.gd` |
| Steepest-ascent path | dp/ds = ∇f/\|∇f\|, midpoint rule, step 0.03 | `scripts/topics/gradient_topic.gd` |
| Gaussian curvature K, mean curvature H | first and second fundamental forms, K = (LN − M²)/(EG − F²), derivatives by central differences (step 0.004 × range) | `scripts/gpu/parametric_engine.gd` |
| Volume of revolution | V = π ∫ \|f² − g²\| dx, **composite Simpson's rule**, 2000 intervals | `scripts/gpu/profile_engine.gd` |
| Disk/washer Riemann sum | n midpoint disks/washers | `profile_engine.gd` |
| Frame time, fps, p95/p99 | wall-clock time between frames; GPU time from Godot's viewport timer and compute-shader timestamps | `scripts/bench/stats_monitor.gd` |

These are float32 numerical approximations. The self-test compares them with exact answers;
for example div F and curl F at the probe agree with the exact values to within 10⁻⁴, and
the Simpson volumes match the closed forms to within 0.2 %. Surfaces are scaled to fit the
box for drawing only; the readouts always show the true values.

**Writing functions:** `^` for powers, implicit multiplication (`2x`, `x y`, `3sin(x)`),
`sin cos tan asin acos atan sinh cosh tanh sqrt exp ln abs floor ceil sign min max atan2`,
the constants `pi`, `e`, `tau`, time `t`, and the slider parameters `a` and `b`.
Formats per topic:

| Topic | Example |
|---|---|
| Vector Fields, Divergence & Curl | `(-y, x, 0)` |
| Gradient | `x^2 - y^2` |
| Parametric Surfaces | `((2 + a cos(v)) cos(u), (2 + a cos(v)) sin(u), a sin(v)), u = 0..2pi, v = 0..2pi` |
| Solids of Revolution | `sqrt(x), x / 2, x = 0..4` (outer f, optional inner g, range) |

Each topic also has presets (rotation, source, sink, saddle, ABC flow, point charge, torus,
Möbius strip, Klein bottle, Gabriel's horn, and more), each with a short note on what it shows.

---

## How to use it

### Start it
- **On the PC:** double-click **`VRFields.godotapp`** in this folder (or run `./VRFields.godotapp`).
  Without a headset it starts in desktop mode.
- **From the Godot editor:** open the project and press **F5**.
- **On the Quest:** see [Install on the Quest](#install-on-the-quest).

### Desktop controls

| Input | Action |
|---|---|
| 1 2 3 4 5 | switch topic |
| W A S D, Q / E, Shift | fly the camera, down / up, faster (keys by position, so Z Q S D and A / E on AZERTY) |
| hold the right mouse button | look around |
| left click and drag | press buttons, drag probes, slices and the rake |
| arrow keys | nudge the topic's probe / slice |
| mouse wheel | the topic's scroll control (e.g. slice position) |
| Space | the topic's action |
| **G** | switch **GPU ↔ CPU** backend |
| P | show the 3D panels (VR layout) on the desktop |
| Tab | hide/show the HUD |
| H | help |
| R | reset the view |
| F1 | enter/leave VR (when a headset runtime is present) |
| F12 | screenshot |

The right-hand HUD column has the topic, backend, quality (Low / Medium / High / Ultra),
presets, the function text box, sliders, and **Run benchmark**. The top-left shows live fps,
frame time, GPU time and the compute-shader time.

### VR controls (Quest)

| Input | Action |
|---|---|
| trigger + laser | press panel buttons and keypad keys, grab handles at a distance |
| grip near a handle | grab it by hand (follows the controller, so slices and the paddle wheel can be turned) |
| grip on empty space | move the whole plot; **both grips** scale and turn it |
| left stick | walk (head-relative) |
| right stick | snap-turn 30° (X), fly up/down (Y) |
| hold grip + right stick | drive the topic's probe / slice |
| A / X | the topic's action |
| B / Y | reset position |
| right stick click | switch GPU ↔ CPU |
| menu button | open the 3D keypad to type a function |

Two floating panels (topic controls and session/benchmark controls) stand beside the plot.

---

## Benchmarks (research question 1)

Run the full sweep (every topic × GPU/CPU × 4 quality levels, the data recomputed **every**
frame on both backends so they do the same work):

```bash
godot --path ~/"VR APPs/VRFields" -- --benchmark          # full sweep, then quits (~5 min)
godot --path ~/"VR APPs/VRFields" -- --benchmark-quick    # 3 levels, shorter
```

or press **Run benchmark** in the app (desktop HUD or VR panel). Results are written as CSV to
`benchmarks/` (when run from the project folder) and to `user://benchmarks/`
(`/sdcard/Android/data/com.example.vrfields/files/benchmarks/` on the Quest). On the desktop,
vsync is turned off during the sweep so the real frame cost is measured; in VR the headset's
refresh rate applies. A CPU level slower than 1.5 s per frame ends that topic's CPU sweep.

Columns: `fps`, `mean_ms`, `p50/p95/p99/max_ms` (frame time), `over_budget_pct` (frames over the
11.1 ms budget of 90 Hz, 5 % tolerance), `gpu_frame_ms` (whole render), `compute_gpu_ms` (our
compute shaders only), `cpu_update_ms` (time the CPU baseline spent computing).

### Results: laptop (NVIDIA RTX 4050 Laptop GPU, Mobile renderer, desktop window, vsync off)

Measured 2026-10-10 (`benchmarks/benchmark_desktop_2026-10-10T14-34-52.csv`). Mean frame time in ms (fps in brackets); the 90 Hz VR budget is 11.1 ms.

| Topic | Level | Points / frame | GPU | CPU | GPU p99 | CPU p99 |
|---|---|---:|---:|---:|---:|---:|
| Vector Fields | Low | 2,264 | 0.46 (2196) | 15.1 (66.4) | 1.07 | 17.9 |
| Vector Fields | Medium | 9,192 | 0.47 (2151) | 58.0 (17.2) | 1.18 | 60.1 |
| Vector Fields | High | 35,512 | 0.47 (2109) | 225.9 (4.4) | 1.11 | 227.2 |
| Vector Fields | Ultra | 98,304 | 1.35 (743) | 487.9 (2.0) | 2.25 | 488.8 |
| Divergence & Curl | Low | 4,608 | 0.52 (1911) | 33.9 (29.5) | 1.20 | 35.9 |
| Divergence & Curl | Medium | 33,280 | 0.54 (1844) | 255.0 (3.9) | 1.36 | 255.9 |
| Divergence & Curl | High | 111,104 | 0.53 (1876) | 854.0 (1.2) | 1.36 | 855.8 |
| Divergence & Curl | Ultra | 262,656 | 0.51 (1964) | 2018.8 (0.5) | 1.21 | 2019.7 |
| Gradient | Low | 2,385 | 0.45 (2240) | 9.7 (102.8) | 1.24 | 10.7 |
| Gradient | Medium | 9,385 | 0.46 (2157) | 37.1 (26.9) | 1.26 | 38.9 |
| Gradient | High | 25,889 | 0.45 (2244) | 101.5 (9.8) | 1.17 | 104.3 |
| Gradient | Ultra | 65,977 | 0.47 (2148) | 257.2 (3.9) | 1.29 | 258.1 |
| Parametric Surfaces | Low | 2,304 | 0.49 (2046) | 54.2 (18.4) | 1.35 | 56.0 |
| Parametric Surfaces | Medium | 9,216 | 0.44 (2257) | 213.3 (4.7) | 1.10 | 214.7 |
| Parametric Surfaces | High | 25,600 | 0.45 (2249) | 588.6 (1.7) | 1.17 | 589.5 |
| Parametric Surfaces | Ultra | 65,536 | 0.46 (2160) | 1503.6 (0.7) | 1.26 | 1506.8 |
| Solids of Revolution | Low | 20,544 | 0.43 (2297) | 0.5 (1971.6) | 0.88 | 1.1 |
| Solids of Revolution | Medium | 20,608 | 0.46 (2159) | 0.6 (1548.9) | 1.12 | 1.4 |
| Solids of Revolution | High | 20,736 | 0.46 (2158) | 0.9 (1145.6) | 1.21 | 2.0 |
| Solids of Revolution | Ultra | 20,992 | 0.47 (2147) | 1.2 (814.8) | 1.11 | 2.3 |

**What this shows:**

- **GPU:** every topic at every level stays far under 11.1 ms (worst mean 1.35 ms, worst p99 2.3 ms: Vector Fields Ultra, 98 k points). Our compute shaders take 0.007–0.036 ms per frame; nearly all the frame cost is ordinary rendering.
- **CPU baseline:** only Gradient Low (9.7 ms) and the Solids of Revolution levels fit the budget. Everything else misses it: Vector Fields Medium is 58 ms, and Divergence & Curl Ultra takes 2.0 s per frame (0.5 fps). On the CPU, frame time grows with the point count; on the GPU it stays flat.
- **Solids of Revolution** is the exception. Only the profile curve (64–512 samples) is computed per frame; the swept surface is built in the vertex shader on both backends. So the CPU keeps up there, and it shows the GPU win comes from moving the per-point math, not just from rendering.
- These are desktop numbers. A Quest run (`--benchmark` on the headset, CSV via `adb pull`) is still needed to answer research question 1 for standalone hardware.

> Note: an earlier sweep (in `benchmarks/old/`) under-reported slow CPU frames. Godot caps `delta` at 8 physics ticks (89 ms), so those CPU rows bottomed out at ~11 fps. Frame time is now wall-clock. Don't use the old file.

---

## User study tools (research question 3)

Start with a participant code to log every interaction (topic changes, presets, typed
functions, grabs with their duration, control changes, benchmark runs):

```bash
godot --path ~/"VR APPs/VRFields" -- --participant=P07
```

One CSV per session (`time_s, event, topic, detail`) in `user://sessions/`:
`~/.local/share/godot/app_userdata/VRFields/sessions/` on Linux,
`/sdcard/Android/data/com.example.vrfields/files/sessions/` on the Quest
(`adb pull` it). `--no-log` disables logging. The pre/post tests and surveys themselves are not
part of the app.

---

## Tests

```bash
cd ~/"VR APPs/VRFields"
godot --headless --path . -s tests/expr_test.gd   # parser, CPU evaluation and generated GLSL
godot --path . -- --autotest                      # windowed, 76 checks, saves screenshots/
```

The windowed self-test has three parts:
1. **GPU = CPU:** reads every compute-shader output back and compares it with the CPU
   evaluation of the same expressions, texel by texel.
2. **The calculus:** numerical answers against exact ones (div, curl, Gauss, Stokes,
   gradients, curvature, volumes, cross-sections).
3. **The app:** real mouse and keyboard events on the HUD, the 3D panels and the probes.

It needs a window (compute shaders need a real GPU). It quits with the number of failures as the
exit code.

---

## Install on the Quest

Requires the toolchain described in the Godot VR setup (JDK 17, Android SDK, Godot export
templates 4.7.2). The project uses a Gradle build (needed by the OpenXR Vendors plugin).

```bash
cd ~/"VR APPs/VRFields"
# first time: add --install-android-build-template to create android/build
godot --headless --path . --install-android-build-template --export-debug "Quest" build/vrfields-quest.apk
# later builds
godot --headless --path . --export-debug "Quest" build/vrfields-quest.apk
adb install -r build/vrfields-quest.apk
adb shell monkey -p com.example.vrfields -c android.intent.category.LAUNCHER 1
```

The app is called **VRFields** in the headset's library (Unknown Sources).

---

## Project layout

```
scenes/Main.tscn        entry scene (everything else is built in code)
scripts/main.gd         world, XR/desktop rig, topic switching, input routing
scripts/expr/           MathExpr: parser -> GLSL + Godot Expression
scripts/gpu/            compute-shader programs and the four field engines (GPU + CPU backends)
scripts/topics/         the five calculus topics and the vector-field presets
scripts/ui/             desktop HUD, 3D panels, sliders, buttons, VR keypad
scripts/core/           pointer/grab protocol, XR hands, locomotion, desktop camera
scripts/bench/          stats monitor, benchmark sweep, session log
shaders/                visual shaders (arrows, particles, lines, volume, slice, surfaces, revolution)
tests/                  autotest.gd (windowed), expr_test.gd (headless)
benchmarks/             CSV results
patches/                XR Tools fix for Godot 4.7 (reapply after updating the addon)
```

---

## Known limits

- No Quest benchmark has been recorded yet; the numbers above are from the laptop GPU.
- The CPU baseline is single-threaded GDScript. A C++/GDExtension or multithreaded CPU version
  would be faster, so the GPU speedups here are against a straightforward CPU implementation,
  not the fastest possible one.
- The divergence-free noise field from the proposal (helix-noise) is not included; the analytic
  presets (rotation, ABC flow, etc.) cover divergence-free fields instead.
