# CPU recon v3 — where quickshell's ~76% of one core goes (measured)

Probe date: this session. Target: live plugin `/home/nexuslink/.config/omarchy/plugins/nexuslink.hud/Hud.qml`
(6663 lines, v3 line per BRIEF-V4-COMMON: Hud.qml == R/candidates/HudV3.qml).
PID 1871285, re-checked with `pgrep -x quickshell` before every sample; no restart occurred
during any sample window (pid identical before/after each). All CPU numbers below are
measured unless tagged otherwise.

This supersedes R/recon/perf.md, which was a static estimate of an older v2.2 file
(30 Hz unconditional `sv` storm, unguarded canvases). The live file already has the
converge-guard, `effVisible` walk, and paint signatures. The burn is smaller but not gone.

## 1. Process-level and per-thread split (measured)

Three `/proc/<pid>/task/*/stat` delta samples (USER_HZ=100), plus `top -H -b -n 3 -d 5 -p`:

| Sample | Window | GUI thread (`quickshell`) | 3× QSGRenderThread | 3× quickshe:gdrv0 | 2× WaylandEventThr | Total |
|---|---|---|---|---|---|---|
| 1 | 13.26 s | 645 j = **48.6%** | 180 j = 13.6% | 56 j = 4.2% | 10 j = 0.8% | 67.2% |
| 2 | 10.33 s | 491 j = **47.5%** | 138 j = 13.4% | 40 j = 3.9% | 8 j = 0.8% | 65.5% |
| 3 | 10.31 s | 577 j = **56.0%** | 144 j = 14.0% | 44 j = 4.3% | 9 j = 0.9% | 75.1% |

`top -H` instantaneous GUI-thread readings across the same period: 44.6%, 54.9%, 60.7%.
Mean over the three windows: **GUI thread ≈ 50.7% of one core, render threads ≈ 13.7%,
gdrv0 ≈ 4.1%, Wayland ≈ 0.8% → process total ≈ 69%**, consistent with the 76.4% 30 s
baseline (sample 3 lands on 75%). utime dominates stime (~95/5 in cumulative
`/proc/<pid>/stat`), so this is compute, not syscall or GPU wait.

Split of the measured total: **GUI thread ~73%, scene-graph render threads ~20%,
driver (gdrv0) ~6%, Wayland events ~1%.** The GUI thread is the problem; everything
else is a symptom of what it dirties.

## 2. perf symbol profile — unavailable (measured)

- `/proc/sys/kernel/perf_event_paranoid` = 2 (would allow per-process user-space
  profiling without sudo).
- `perf` is **not installed** on this box (`which perf` empty; exit 1). No symbol
  profile possible in this lane without installing packages, which the brief forbids
  (throwaway files only under /tmp/cpuf). Ranking below is therefore built from the
  thread split + static call-graph reading; shares are tagged.

## 3. Plugin attribution (measured + inferred)

`omarchy-shell shell listPlugins` (exit 0): 42 plugins, all `active:false` except
`omarchy.bar` (the top bar, `active:true`). `nexuslink.hud` is a `service` plugin,
`enabled:true`, `active:false` — expected: its PanelWindows are always-on layer-shell
surfaces, not toggleable overlays, so "active" never flips. Other always-running
candidates in the same process: `omarchy.bar` (active), `expose.window-overview`,
`community.window-overview`, `nexuslink.medianotch`, `nexuslink.taskbar`,
`crmne.hyprmoncfg` (all enabled, inactive).

Attribution: the HUD owns three full-screen PanelWindows (2560×1440 + 2×1920×1200),
the only full-screen `ShaderEffect` in the process, and the only 20 Hz JS animation
clock. The bar is a few hundred pixels tall with no shader and 1 Hz widgets. The
measured 13.7% render-thread load across exactly **three** busy QSGRenderThreads
(one per window) matches the HUD's three screens. **Inferred: ≥85% of the process
burn is nexuslink.hud; the bar and other plugins share the remainder.** A definitive
split needs per-plugin CPU attribution, which Quickshell does not expose.

## 4. Static inventory of the live Hud.qml (measured counts)

### Timers (14 total)

| Line | id | Interval | Running | Cost |
|---|---|---|---|---|
| 380-389 | `animClock` | `1000/tickHz` = **50 ms (tickHz=20 default, line 206)** | always | the driver — see §5 |
| 231 | saveTimer | 500 ms, one-shot | on edit | nil |
| 296 | persist watchdog | 1200 ms, one-shot | startup | nil |
| 1050 | stream watchdog | 4000 ms repeat | always | nil (function refresh() just re-arms streamProc) |
| 1058 | clock | 1000 ms repeat | always | `root.now = new Date()` → 1 Hz binding pulse to clock text |
| 1068 | probe | 300 s repeat | always | nil |
| 1108 | ledgerTimer | 60 s repeat | always | nil |
| 3218/3226 | PixelKnot cycleTimer/fxTimer | 50 ms repeat **only while an effect runs** (30-60 s cadence, ~2-4 s active) | gated | near nil |
| 4069-4099 | flash/say/reflow/anim one-shots | 140-3000 ms | event | nil |
| 4099 | initRetry | 140 ms repeat | until layout hydrates | nil after startup |

**One continuous animation timer: animClock at 20 Hz.** Everything else is ≤1 Hz or gated.

### Canvases (25 mentions; ~11 repaint-relevant instances per screen)

- `TraceCanvas` component (2071) with instances at 2195 (SparkBox inner), 4391 (sys
  load trace), 5129, 5253, 5590, 6214 → **6 TraceCanvas sites**, all gated by
  `live` + `effVisible` + `seriesSig()` (2085-2118).
- `PwrDial` face Canvas (2221), instance at 5184 → gated by `live` + `amountSig()`.
- `dialCanvas` (4673) — the reactor dial, **one per screen, repaint on every
  tickSeq with no signature gate** (4680-4682: `if (dialCanvas.visible)
  dialCanvas.requestPaint()`). `visible` here is the local flag; the enclosing
  `centerZone` is `visible: win.isCommand && ...` (4415), so on the hardware and
  ops screens `dialCanvas.visible` is true while its ancestor hides it — the
  `effVisible` guard used everywhere else is missing on this one canvas. It paints
  72 orbit ticks + 4 rings + telemetry text per paint (4695+).
- `bezel` Canvas per CPanel (1782) — repaint on resize/collapse/accent only. 23
  CPanel instances per window, all static between events. Good pattern.
- `PixelKnot` (3002) — Canvas, one instance (5701), repaint only during effects.
- `fxCanvas` (6628) — full-screen scanline/vignette texture, repaint on resize only.
  One extra full-screen textured quad composited per frame per screen.

### ShaderEffects (1)

`ambientField` (3424-3441): `anchors.fill: parent`, one per screen → **3 full-screen
ShaderEffects** (2560×1440 + 2×1920×1200 ≈ 8.3 Mpx total). Uniforms `uTime:
root.animT` (3429) and `uPulse: root.pulse` (3433) change **every animClock tick,
20×/s, unconditionally** — they are not behind the converge guard. Each uniform
change dirties the window's scene graph → full re-render of that window at up to
20 Hz. Fragment cost (ambient.frag, measured count): hash() ×3 (dot+sin+mul+fract
each), exp ×3, sin/cos ×6 (c1/c2 per-pixel even though they depend only on t and
aspect — hoistable), shimmer sin ×1, ~4 smoothstep → ~13 transcendentals + ~40 ALU
per pixel. GPU-side trivial for the B580; CPU-side the cost is the render pass it
forces (the measured 13.7% render + 4.1% gdrv0).

### Continuous animations

No `NumberAnimation`/`RotationAnimation` with `loops: Animation.Infinite` and no
`running: true` animators exist in the file (grep-verified). All `Behavior on`
animations (1765-1768, 2340, 2641, 4439-4441, 5035, 5533, 5699, 6303, 6478) are
event-driven. **The only continuous motion sources are `animT` and `pulse`, both
fed by animClock.**

## 5. Where the GUI thread's ~50% goes (measured split + inferred shares)

`tick()` runs at 20 Hz (Hud.qml:390-498). Per tick, measured structure:

1. **Eases, every tick, unconditionally** (392-471): ~19 `easeFrac` calls, a fresh
   `nv` object, a fresh 24-element `core` array with per-element loop, a 19-key
   movement scan, and **9 `easeHist` calls × 60 elements = 540 eased points +
   array shift/push churn** (462-471). Estimated 1-3 ms of JS per tick →
   **20-60 ms/s = 2-6% of a core** (inferred share).
2. **`animT += dt` + quantized `pulse` re-evaluate their binding graph every tick**
   (396, 378): 16 direct `root.pulse`/`root.animT` binding sites (grep, §4) across
   3 windows — opacities on agent chips, battery rows, dev rows, alert halo, dial
   breathe — plus the two shader uniforms. Each dirty property marks its item and
   propagates a scene-graph dirty on that window. This is the steady-state floor:
   it never converges, by design (sin never settles). **Inferred: the largest
   single GUI-thread cost — the binding re-eval + node dirtying at 20 Hz × 3
   windows, plausibly half of the 50%.**
3. **Converge-guarded `sv = nv`** (473): only fires when movement > 0.0009 or a
   batch landed. Telemetry batches arrive ~1/1.2 s, and each batch re-primes the
   eases, so in practice `sv` swaps a few times per second, not 20. The v2.2
   binding storm is mostly fixed. **Measured-in-code, inferred share small.**
4. **Repaint gate** (489-492): `tickSeq++` fires when a batch landed, anything is
   still gliding, or `scrollPhase < 1`. Since `scrollPhase` resets to 0 on every
   batch (applyFrame:973) and takes `batchPeriod` (~1.2 s) to reach 1, and batches
   arrive every ~1.2 s, **scrollPhase is < 1 almost always → tickSeq pulses at
   nearly the full 20 Hz** (inferred from the cadence math; the guard only closes
   if the stream stalls >~1.5 s). So the "quiet" state the gate was built for
   never actually arrives.
5. Consequence of (4): gated canvases re-check signatures at ~20 Hz. TraceCanvas
   `seriesSig()` includes the scroll bucket `(sp < 1 ? Math.round(sp*32) : 999983)`
   (2101) — while scrolling, the bucket changes every tick → **visible traces
   repaint ~20×/s each** (measured code path). Per screen the actually-visible set
   is ~2-4 traces + 1 dial. CPU raster per trace paint ~100-400 µs, dial ~0.5-1.5 ms
   (static estimate, consistent with perf.md). **~6-10 visible canvas paints/tick/screen
   × 3 screens × 20 Hz ≈ 360-600 paint ops/s ≈ 3-8% of a core** (inferred).
6. Plus the ungated `dialCanvas` on the two non-command screens marking dirty every
   tickSeq (§4) — wasted mark-dirty scheduling even if the paint is culled.

Ranked cost drivers (share of the ~69% process total; basis tagged):

| # | Driver | File:line | Share | Tag |
|---|---|---|---|---|
| 1 | `animT`/`pulse` binding + shader-uniform dirty at 20 Hz × 3 windows (GUI-thread re-eval + SG dirty; forces the render passes behind render-thread 13.7% + gdrv0 4.1%) | Hud.qml:378, 396, 3429, 3433 + 16 binding sites | ~35-45% of process (GUI-thread bulk + all render/gdrv0) | measured (thread split) + inferred (share) |
| 2 | tick() JS body: 540 eased hist points + 24-core array + object churn at 20 Hz | Hud.qml:390-498, easeHist 519-533 | ~5-10% | inferred |
| 3 | Canvas raster: traces + dial repainting ~20 Hz while scrollPhase<1 (which is always) | Hud.qml:489-492, 2101, 4673-4682 | ~5-10% | inferred (cadence math measured) |
| 4 | dialCanvas missing `effVisible` guard — dirty marks on 2 hidden screens every tick | Hud.qml:4680-4682 vs 2113 | ~1-3% | measured (code) + inferred (cost) |
| 5 | 1 Hz batch apply: 9×histPush slice+push, 9×dspShift, stats swap, Repeater model rebuilds (agList/wsList/winList re-run per stats change) | Hud.qml:939-1010, 4926, 5779, 5794, 5883 | ~1-2% | inferred |
| 6 | fxCanvas full-screen quad composited per frame × 3 screens | Hud.qml:6628-6662 | <1% | inferred |
| 7 | watchdog/clock/probe/ledger timers, bezel canvases, Behaviors | 1050-1114, 1782 | <1% | measured (intervals) |

Key structural finding (measured): **the repaint gate never closes.** `scrollPhase`
resets on every ~1.2 s batch and takes ~1.2 s to reach 1, so condition
`scrollPhase < 1.0` (490) is true ~100% of the time, `tickSeq` pulses at the full
20 Hz forever, and every `seriesSig` keeps changing because the scroll bucket is in
the signature. The v3 gate converted "repaint everything always" into "repaint
everything that is visible, always". The converge logic works for `sv` but is
overridden by the scroll term for canvases.

Second structural finding: **the shader and pulse bindings bypass the gate
entirely.** Even if tickSeq stopped pulsing, `uTime: root.animT` dirties all three
full-screen ShaderEffects 20×/s, forcing three render passes forever. That is the
floor under the render threads' measured 13.7%.

## 6. Paints per second per screen (estimate, tagged)

Per screen, steady state: ~2-4 visible TraceCanvas + 1 dial (command) or 1-2
PwrDial/traces (hardware/ops) repainting at ~20 Hz while scrolling → **40-100
canvas paints/s/screen**, plus **20 full-window scene-graph renders/s/screen**
driven by the shader uniforms. At 2560×1440 the command screen does ~20 full
re-renders/s of an 8.3 Mpx-layer stack. (Inferred from the cadence math in §5;
a `QSG_RENDER_TIMING`/`QSG_VISUALIZE` run would confirm but needs a shell restart,
which this lane must not do.)

## 7. v4 design rules (derived from the above)

1. **Max continuous timers: ONE.** A single animation clock (animClock pattern is
   fine). Everything else ≤1 Hz or event-gated. v3 already complies; keep it.
2. **Decouple "data glide" from "scroll".** The scroll bucket must leave the paint
   signature. Scroll the *viewport transform* (a `translate` on the trace path, or
   draw with an x-offset argument) instead of encoding scroll into the series
   identity. Then a converged trace with a new sample scrolling in needs exactly
   one repaint per batch, not 20/s. Rule: **a Canvas repaints at most once per
   telemetry batch (≤1 Hz) plus during user interaction.**
3. **The converge gate must actually close.** Gate condition should be
   `batchSeq changed || maxDelta > ε` only — no `scrollPhase < 1` term. If scroll
   motion is wanted, drive it from the same 1-per-batch repaint (draw the curve at
   its settled position; the eye cannot track a 1.2 s glide at 20 Hz vs 5 Hz on a
   60 px sparkline). Expected effect from §5: canvas cost → ~1/20th, tickSeq
   binding pulse stops between batches.
4. **Full-screen ShaderEffect at 2560×1440: affordable only if its uniforms are
   dead at rest.** GPU cost is fine (B580, ~13 transcendentals/px). The CPU-side
   render pass it forces is not. Rule: `uTime` may update at most 2-4 Hz (drift is
   invisible below that at these speeds — the blooms move at sin(0.1·t)), and the
   whole effect should drop to 0 Hz updates when the screen is covered or the
   machine is idle. Budget: at most ONE full-screen shader layer per screen, no
   per-pixel trig that depends only on time (hoist c1/c2 to JS uniforms — removes
   4 sin/cos × 3.7 Mpx/frame). If v4 cannot gate it, cut it: the measured render
   + driver cost (~18% of a core) is the price of this one layer.
5. **No animation property may be unconditional.** `pulse` and `animT` must stop
   advancing when nothing visible consumes them (no alert, no charging battery, no
   live dev session, shader gated). Rule: every continuous property needs a
   consumer-count; at zero consumers the clock drops to 1 Hz (keep the dial
   second-hand honest) or pauses.
6. **Every Canvas dirty path needs the ancestor-visibility walk.** `effVisible`
   exists (544-551) and is used everywhere except `dialCanvas` (4680). v4 rule:
   no `requestPaint()` without an `effVisible` (or equivalent) guard; hidden-role
   windows must be paint-silent. Better: instantiate role pages lazily (Loader per
   role) so off-role screens don't carry the component tree at all — also kills
   the hidden binding re-eval on those windows.
7. **Binding budget on the animation clock:** anything bound to the tick must be
   cheap to re-evaluate and cheap to no-op. Quantized `pulse` (378) is the right
   pattern; extend it — quantize `animT` to the shader's actual update rate.
8. **Batch apply stays ≤1 Hz and O(samples),** which v3 already does. Keep
   Repeater models stable across batches (append/trim in place) to avoid the 1 Hz
   delegate teardown spike on ops/hardware pages.

## 8. Probe artifacts

- PID 1871285 throughout; `pgrep -x quickshell` before/after each sample matched.
- Raw samples: /tmp/cpuf/t0..t5.tasks, /tmp/cpuf/t0..t5.uptime, /tmp/cpuf/top-H.txt,
  /tmp/cpuf/plugins.txt.
- top -H GUI-thread instantaneous: 44.6 / 54.9 / 60.7 %CPU.
- perf: paranoid=2 but perf binary absent (`which perf` exit 1).
- `omarchy-shell shell listPlugins` exit 0; only omarchy.bar active.
