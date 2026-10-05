# Perf recon — nexuslink.hud (quickshell, 3× PanelWindow @ WlrLayer.Bottom)

Probe date: session time of this report. Target analyzed: the LIVE file
`~/.config/omarchy/plugins/nexuslink.hud/Hud.qml` (v2.2, animated/eased build).
NOTE: `nexuslink.hud/Hud.qml` in this repo is an older pre-`animClock` snapshot
(1500 ms poll timers, no shader) — the deployed plugin copy is the hot one.

## Measured CPU

`pidof`/`top` were blocked in this lane; equivalent read-only probes used instead:

| Probe | Result |
|---|---|
| `pgrep -a quickshell` + `ps --sort=-pcpu` | PID 4145129, instantaneous **92% CPU**, #1 on box |
| `/proc/4145129/stat` Δ(utime+stime) vs `/proc/uptime`, 3 intervals | **85.7%, 84.2%, 86.3%** of one core — steady ~**85%** |
| utime vs stime | ~95% user time → compute-bound (JS + raster), not syscall-bound |
| `/proc/.../task/*/stat` | main `quickshell` thread ≈ **90%** of all ticks; 6 `QSGRenderThread`s split the remainder |

Hardware: Ryzen 9 7900X, 24 threads — 85% of one core ≈ 3.5% system CPU, but it's
a sustained single-thread burn on the QML GUI thread, i.e. the thread that also
owns event/input latency. The earlier ~65% sighting is consistent — same regime,
slightly quieter telemetry day.

## Cost model

One shared `Timer { id: animClock; interval: 33 }` (Hud.qml:141-148) → `tick()`
(Hud.qml:150-203) at ~30 Hz. Everything below is per-tick, ×30/s.

### Driver 1 — `tick()` + `sv`/`animT` binding storm on the GUI thread (~largest)

Hud.qml:150-203. Each tick:

- ~14 `easeFrac` scalar eases + allocates a fresh `nv` object and a fresh
  24-element `core` array (line 185-191), then **`sv = nv` (line 193)** — an
  identity-swap. Every binding that touches `sv` — `root.s(key)` (215-218),
  `svCore(i)` (219-222), `alertMix`→`frameCol` (666-670) — re-evaluates on all
  3 windows whether or not values changed. Estimated 150–300 dependent bindings
  per window: ~30 HudRow `fraction:`/`accent:`/`gaugeColor` pairs, 24+24 core
  bars (delegates at 2280-2302 and 3119-3149 are instantiated on every window,
  hidden columns included), TempBox colors, 4 frame Brackets + bezel lines via
  `frameCol`, etc.
- `animT += dt` (155) feeds `pulse` (139), `scanSweep.y` (2100),
  `dashRingA/B.rotation` (2732/2754), every `shadowOpacity`/opacity bound to
  `root.pulse` (2141, 2159, 2236, 1564, 1583, 1609, 2063, 2799, 3077…), and the
  shader uniforms — so each window's scene graph is dirty every 33 ms and does a
  full render pass ~30×/s regardless of whether any pixel visibly changed.
- `easeHist` (227-237): 5 display arrays × ≤60 pts = ≤300 eased points + shift/
  push churn per tick.

Rough budget: tick body ~0.5–1.5 ms + binding re-eval storm ~2–5 ms → **3–6 ms
of GUI-thread JS per tick → ~10–20% of a core before any painting happens**.
Key structural flaw: the notification is object-identity — bindings keep firing
at 30 Hz forever, even after every eased value has converged.

### Driver 2 — `tickSeq` Canvas repaints, including off-role/hidden ones

- `tickSeq++` (202) → `onTickSeqChanged` handlers in `TraceCanvas`
  (1238-1243) and `dialCanvas` (2608-2613).
- Every window instantiates ALL role pages (role columns are `visible:false`,
  not destroyed), so each PanelWindow contains ~12 tick-connected canvases:
  11 TraceCanvas (2535, 2545, 2572, 2581, 2947, 3309, 3401, 3567, 4083, 4093,
  4208) + dialCanvas (2603). → **36 `requestPaint()` calls per tick ≈ 1080/s**.
- Guard bug: `tc.visible` (1241) is the *local* visible flag — canvases inside a
  `visible:false` role column still report `visible == true`, so off-role
  canvases get marked dirty every tick on all 3 windows (whether `onPaint`
  executes is Qt-version-dependent; the mark-dirty + update scheduling is not).
- Paints that do run are pure CPU raster (Canvas→QPainter→texture upload):
  - `paintTrace` (313-398): per ~60-pt run — 2 array allocs, gradient creation,
    and the smoothed quadratic path walked **3 times** (fill + glow stroke +
    core stroke) + 3 head-dot arcs. ~100–400 µs per trace.
  - `dialCanvas.onPaint` (2614-2722): the heaviest canvas — ~120 tick-mark
    segments, 7 comet-tail arcs, 3 rings × (track + glow + core + tip fills) +
    a radial gradient. ~0.5–1.5 ms.
  - Actually-visible ~12 paints/tick → ~360 paint ops/s ≈ **2–6 ms/tick**.
- `SparkBox` does not forward `live` (1313-1318): traces inside collapsed
  panels keep repainting. CPanel bezels (1012) and `fxCanvas` (4225) correctly
  repaint only on resize/collapse/hover — good pattern, already proven in-file.

### Driver 3 — full-screen `ShaderEffect` per window, re-rendered at 30 Hz

- Hud.qml:1977-1989: `anchors.fill: parent`, `uTime: root.animT` → uniforms
  change every tick → each of the 3 windows does a full render pass ~30×/s
  (vsync-capped, so 30 not 165 Hz — the screens' refresh doesn't multiply it).
- `ambient.frag` per-pixel cost: hash() called **3×** (lines 21, 25, 26 —
  each = dot + sin + mul + fract), bloom centers `c1`/`c2` burn **4 trig**
  (29-30) *even though they only depend on t and aspect* (hoistable to
  uniforms), `exp` **3×** (27, 31, 32), shimmer `sin` (46), ~4 smoothstep,
  ~4 length/fract pairs → **~11 transcendentals + ~40 ALU ops per pixel**.
- At ~2560×1440 ×3 screens ≈ 11 Mpx → ~330 Mpx/s → tens of Gflops on the GPU.
  Cheap for the B580, but if RHI ever lands on llvmpipe this alone is >1 core.
  CPU-side the cost is the dirty-driven re-render: render threads show ~10% of
  process ticks — real but secondary.

### Minor but worth noting

- `sv` reassigns every tick even when fully converged (see Driver 1 fix).
- `sensorRows()` invoked 3× per batch (3195, 3196, 3202) — rebuilds the same
  array three times at 1 Hz; trivial but free to memoize.
- Repeater model rebuilds per ~1 s batch (`wsList`, `winList`, `agList`,
  `devsessList`, `tmuxList`, `ghevList`, `batList` → delegate teardown/recreate
  spike each second on ops/hw pages). 1 Hz, so minor jitter not steady cost.
- `layer.enabled` + `MultiEffect` shadows bound to `pulse` (2136-42, 2231-37,
  2794-2800, 3072-78): shadow recomposites every tick ×3 windows. Small
  textures; secondary.
- `fxCanvas` (4225-4257) is the *topmost* child — one extra full-screen textured
  quad composited over every frame. Static; minor.
- mask: 35 `Region` items/window (1924-1965) — event-driven only, cheap. Fine.
- Watchdog 4 s (559), clock 1 s (567), probe 300 s (577) timers: negligible.

## Ranked fix list (cheap wins first)

1. **Adaptive tick / early-exit.** Keep `interval: 33` but bail when nothing is
   moving: compute max eased |Δ| in tick(); if `< ~5e-4` AND `scrollPhase`
   settled AND `batchSeq` unchanged for a few hundred ms → skip `sv = nv`,
   skip `tickSeq++`. Telemetry arrives at ~1 Hz, so the HUD is "at rest" most of
   each cycle. Cheapest variant: `interval: 66` flat (15 Hz — easing τ=0.25 s
   still looks smooth). Expected: **~2× reduction of Drivers 1+2**; converged
   variant cuts steady-state cost by 5–10×.
2. **Gate canvas repaints properly.** (a) Fix the visibility guard —
   `tc.visible` doesn't see hidden ancestors: wire `live` through `SparkBox`
   (add `live` passthrough at 1313-1318) and set it role-aware, e.g.
   `live: win.isCommand && !root.isCollapsed("...")` per host page.
   (b) Repaint traces only while gliding: repaint for ~1.5×`batchPeriod` after
   each `batchSeq` bump, then stop — same visual, ~60–70% fewer paints.
   (c) `dialCanvas` at `tickSeq % 2` (15 Hz) — the comet/tick drift is
   slow enough to halve.
3. **Converge-guard `sv`.** Only do `sv = nv` when some eased value actually
   moved > ε, or a batch landed. One `changed` flag in tick() kills the
   permanent 30 Hz binding storm on all 3 windows.
4. **Shader cheapening.** Hoist `c1`/`c2` to JS-computed uniforms (1 eval/tick
   vs 4 trig × 3.7 Mpx/frame → removes ~1/3 of per-pixel transcendentals);
   share one `hash(id)` result where possible; update `uTime` every other tick
   (15 Hz drift is invisible at these speeds). Optionally gate by screen
   coverage later: emit a `mon_fullscreen` flag from `hud-collect` (Hyprland
   knows active fullscreen windows) → `ambientField.visible: !covered`.
5. **Micro-trims (free).** Memoize `sensorRows()` once per `stats` change;
   quantize `pulse` (`Math.round(p*24)/24`) to cut redundant opacity/shadow
   dirty marks; keep Repeater arrays stable across batches if delegates churn
   visibly.

## Suggested verification

After (1)+(2): expect GUI-thread ≈ <20% of a core, canvas ops only during
glide windows. Verify with the same probe: two `/proc/<pid>/stat` reads 10 s
apart vs `/proc/uptime` delta; and `QSG_INFO=1` / `qs` log to confirm which RHI
device renders the shader (guard against llvmpipe before doing shader work).

## Probe artifacts

- PID 4145129, `/proc` jiffy sampling @USER_HZ=100: utime+stime deltas
  1216/14.19 s, 1677/19.92 s, 748/8.67 s → 84–86% of one core.
- Thread totals at sample time: main thread 96742 jiffies; QSGRenderThreads
  11977 / 9409 / 9078 / 2736 / 2552 / 2403; `quickshe:gdrv0` 2168.
- `collect.sh stream` execs `hud-collect` when present (confirmed in dir);
  bash fallback polls every 1.5 s — `batchPeriod` tracks ~1–1.5 s.
