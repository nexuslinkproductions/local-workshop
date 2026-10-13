# 10 — Local test matrix (Arc B580, latest llama.cpp builds)

Live report. Updated after every stage; rows land in `bench/results-matrix.tsv`.
Use case ranked first: **computer use** (screenshots in, tool calls out) — grounding +
tool-call pass, then screenshot latency, then prefill, then decode.

## Box / rules in force

* Intel Arc B580 12 GB (`Vulkan0` **and** `SYCL0`), Ryzen 9 7900X (12c/24t), 61 GiB RAM.
  `MemAvailable` is checked before every load. `Vulkan1` = Ryzen iGPU, never used.
  A reboot did **not** shift the device indexes: `llama-cli --list-devices` still shows
  `Vulkan0: Intel Arc B580`, `Vulkan1: AMD Raphael`; the GT 1030 has no driver loaded and
  no Vulkan device, so no pinning by name was needed.
* **One test at a time** — every run self-wraps in `flock -x bench/.gpu.lock`; a server
  session holds the lock start→kill. Game rule: `gate.sh` sleeps 120 s and re-checks while
  ARCRaiders runs (never `--force`).
* Engines: `engines/llama.cpp-vulkan-tip/build/bin` (`Vulkan0`) **and**
  `engines/llama.cpp-sycl-tip/build/bin` (`SYCL0`, env `bench/configs/sycl-env.sh`).
  Both at commit `358a420ec`.
* **Fit rule (corrected):** ≥ 1.2 GiB VRAM free **after a 4 K prompt has been processed**,
  and GTT growth = over-commit. The old after-load rule passed placements that wedge.
* Every load runs under `CAP=<RSS+6G> ~/.local/bin/jobcap`.

## Harness changes made this pass (`bench/`)

All verified with `bash -n` / `ast.parse`; every bug below produced **wrong numbers or an
orphaned server**, so they are fixes, not cosmetics.

| file | fix |
|---|---|
| `hillclimb.py` | `measure()` used `a.depths`/`a.reps` inside a function whose parameter is `args` → `NameError` on the first run. Also sliced `new[-2:]` of an **accumulating** scratch file, so a pp-only run returned the *previous* attempt's rows: every gain read as `+0.0%` and the keep/revert verdict was computed against the wrong reference. Now slices from the pre-run row count. |
| `hillclimb.py` | a run that produced **no row** used to read as a neutral `reverted`; now logs an explicit `test=lever-failed` row with the harness error tail. |
| `hillclimb.py` | added `"reset": true` per lever. llama-bench treats `-b`/`-ub`/`-t`/`-fa` as **accumulating lists** ("or by specifying the parameter multiple times"), so stacking a lever's flags on the previous best formed a *parameter sweep* (a cross-product of values), not the lever. |
| `matrix-bench.sh` | `-fa` was hardcoded `on`; added an `FA`/`FA_OVERRIDE` var so `-fa off` can be a real one-variable lever instead of duplicating the flag (which swept `on,off`). |
| `matrix-server.sh` | `SRV_PID="$(pgrep -P "$WPID")"` found nothing — the tree is `timeout → jobcap (systemd-run scope) → llama-server`, so the server is **not** a child of `WPID`. It then read `/proc/0/cmdline`, died under `set -e`, and **left the server running** (blocking every later test). Now resolves the pid by port, guards the `/proc` read, derives `placement` from the server's effective argv, and `cleanup()` also kills whatever still listens on the port. |
| `matrix-server.sh` | screenshot geometry: added `GRIM_ARGS` (array) so the shot can be a 1920×1080 crop (`-g "0,0 1920x1080"`) instead of the full 3-monitor desktop. |
| `grounding-test.sh` + `grounding-gen.py` | **new**: real grounding score (see below), replacing "valid JSON with x/y" which scored a point 160 px off as a pass. |

## Status

| # | model | quant | engine | state |
|---|---|---|---|---|
| 1 | Qwen3.8-27B-OBLITERATED (dense) | IQ4_XS | vulkan | baseline (below) |
| 2 | **Qwen3.6-35B-A3B** (MoE, 3B active) | UD-Q4_K_XL | **SYCL** | **S1 DONE** — placement + prefill hillclimb + server session + grounding |
| 3 | Qwen3.8-Flash-Next (MoE) | IQ3_XXS | vulkan | downloaded (both shards + mmproj + MTP) — **memory-blocked** (needs ≥48 GiB free; 46 GiB box) |
| 4 | MiniCPM-V-4.7-35B-A3B (MoE VLM) | Q8_0 | SYCL | grounding scored (6/16 synth, 0/4 real; 4× proj 0/16) — **out for grounding** |
| 5 | UI-Venus-1.5-30B-A3B (GUI specialist) | Q8_0 | **Vulkan** | grounding scored (**16/16 synth, 2/4 real**); **SYCL = GPU reset, never retry** |
| 6 | Qwen3.8-27B IQ3_S (dense) | IQ3_S | — | on disk — queued |

## 1. Dense baseline (unchanged, kept for reference)

Qwen3.8-27B-OBLITERATED IQ4_XS, 65 layers > 12 GB → `-ngl 44` at 64 K/q8_0 KV loads in
~10 s; 46 loads but takes 176 s; 48 wedges. `pp512 @ d0` 301.7 t/s, `tg128 @ d0` 5.8 t/s,
`pp512 @ d32768` 59.5 t/s (a 32 K prompt ≈ 9.2 min). Dense, so prefill collapses with
context and decode is bandwidth-bound — not a computer-use candidate.

## 2. Qwen3.6-35B-A3B UD-Q4_K_XL — S1 (the first hillclimb)

`qwen35moe`: 40 blocks, 256 experts / 8 active, 2 KV heads, native ctx 262 144, 22.4 GB.

### 2.1 Placement cliff (Vulkan, no projector, 64 K, q8_0 KV)

Sweep high→low, so each point is *more* experts in VRAM than the one above it.

| `--n-cpu-moe` | peak VRAM used | headroom vs 11605 MiB | verdict |
|---|---|---|---|
| 40 (all experts in RAM) | 4732 MiB | +7484 | safe reference |
| 32 | 7398 MiB | +4818 | ok |
| **24** | 11069 MiB | **+1147** | **placement** |
| 22 | 13105 MiB | −889 | over-commit (spills through GTT, no error) |
| 16 | 12419 MiB | −814 | over-commit |

### 2.2 PREFILL hillclimb, 4 K prompt (`-p 4096 -n 128 -r 3`, Vulkan, ncmoe 24)

Baseline is a **plain** config (no levers). Each row below is one lever, measured alone.

| lever | pp4096 t/s | tg128 t/s | verdict |
|---|---|---|---|
| baseline | 182.4–184.9 | 34.4–35.2 | reference |
| **`-b 1024 -ub 1024`** | **277.7** | 35.1 | **KEPT (+50.8 %)** |
| `-b 2048 -ub 2048` | — | — | **FAILED** (compute buffer, rc=1) |
| `-b 4096 -ub 4096` | — | — | **FAILED** (compute buffer, rc=1) |
| `-lm none` alone | 222.9 | 33.9 | −19.7 % vs ub1024 |
| **`-lm none` + `-b/-ub 1024`** | **316.0** | 33.8 | **KEPT (+13.8 % over ub1024)** |
| `-t 12 -C 0x00000fff --cpu-strict 1` | 184.2 | 35.6 | neutral (reverted) |
| `-t 6 -C 0x0000003f --cpu-strict 1` | 184.4 | 35.1 | neutral (reverted) |
| `-b 2048 -ub 2048 @ ncmoe 26` | 106.9 | 21.0 | −42 % — raising ncmoe to fit a bigger ubatch costs far more than it gains |
| `-fa off` | — | — | **FAILED**: a quantized V cache requires FA (`research/13`); we run `-ctv q8_0` |

Reading it: **the batch, not the threads, moves prefill.** `-ub 1024` doubles it; `-lm none`
(the loader's own advice for CPU-expert overrides) stacks another 14 %. Pinning is worth
nothing here because at ncmoe 24 only 16 layers' experts are on the CPU — the box is
bandwidth-bound, not thread-starved. Larger ubatches do not fit: at ncmoe 24 the compute
buffer alone over-commits, and buying VRAM with `ncmoe 26` costs 42 %.

### 2.3 SYCL vs Vulkan (same flags)

First SYCL row passed the **output-sanity check** (`llama-cli` under SYCL0 emitted coherent
text; the reported #28728 bad-output case did **not** reproduce for this file).

| config | pp4096 | tg128 | headroom | verdict |
|---|---|---|---|---|
| `sycl @ ncmoe 24` (plain) | — | — | **−462 MiB, gtt 1027** | **WEDGE**: over-committed (`used=12067/11605`) and sat 13 min at 99 % CPU on one thread with no output; killed |
| `sycl @ ncmoe 32` (plain) | 271.2 | 38.2 | — | kept vs plain baseline (tg **+11.9 %**) |
| `sycl @ ncmoe 36` (plain) | 248.7 | 36.4 | — | reverted |
| `sycl-graph @ ncmoe 32` (`GGML_SYCL_ENABLE_GRAPH=1`) | 270.7 | 35.9 | — | flat (−0.2 % pp, −6.1 % tg) → dropped |

SYCL loads ~1 GiB more free than Vulkan at the same placement, which is why 24 wedges on
SYCL where Vulkan survives it.

### 2.4 SYCL **with the Vulkan winner flags** (the actual winner)

`-b 1024 -ub 1024 -lm none`, `-r 3`, SYCL0:

| placement | pp4096 t/s | tg128 t/s | headroom before projector | fit rule (≥1.2 GiB) |
|---|---|---|---|---|
| vulkan-win (reference) | 315.5 | 33.8 | ~640 MiB | fails |
| **sycl @ ncmoe 26** | **495.3** | **40.78** | 394 MiB | fails |
| sycl @ ncmoe 28 | 475.9 | 39.77 | 777 MiB | fails |
| **sycl @ ncmoe 30** | **481.0** | **39.99** | **1890 MiB** | **PASS — text-only pick** |
| sycl @ ncmoe 32 | 462.7 | 37.69 | 2818 MiB | PASS (used for the projector session) |

**SYCL + ub1024 + `-lm none` is the prefill result of the pass: 481–495 t/s vs 184 t/s for
the old plain Vulkan config (+165 %), and decode 40 t/s vs 34.4 (+16 %).** ncmoe 26 is the
fastest but breaks the fit rule; ncmoe 30 is the fastest that keeps ≥1.2 GiB.

### 2.5 Full server session (SYCL + winner flags, ncmoe 32 + projector on GPU)

`matrix-server.sh`, `-c 65536 -np 1 -fa on -ctk/-ctv q8_0 -b 1024 -ub 1024 -lm none -fit off`,
1920×1080 crop of the primary monitor, `PROMPT_SOURCE=AGENTS.md`.

| metric | value |
|---|---|
| cold start → `/health` | **11.1 s** |
| warm start → `/health` | **11.1 s** |
| VRAM after load (with projector) | 10024 MiB → headroom ≈ 1581 MiB |
| 4 K prompt TTFT | **14.3 s** (387.6 t/s prompt, 36.5 t/s decode) |
| 32 K prompt TTFT | **99.5 s** (400.3 t/s prompt, 28.0 t/s decode) |
| screenshot 1920×1080 | 1.16 MB PNG; **≈2060 image tokens** |
| image encode+prefill | **9.5–10.6 s** at ~200–216 t/s (server log `print_timing`) |
| vision-describe TTFT | 37.3 s (image + text) |
| **tool-call smoke test** | **PASS** — `get_weather({"city":"Vienna"})` |

The number that decides computer-use usability: **one screenshot costs ~10 s of image
prefill on top of the text prompt**, so a screenshot turn is ~10 s + (text prompt)/400 t/s.

### 2.6 Grounding (real score, not JSON validity)

`bench/grounding-test.sh` renders a 1920×1080 page with 16 targets at **known boxes** in
four size classes (large buttons 140×40, small buttons 80–100×28, icons 24×24, text links
60–90×18), asks for each target's centre, and scores a HIT only if the point falls **inside
the box**. Coordinates are scored under the model's majority convention; the parser accepts
`{"x","y"}`, Qwen's native `point_2d`/`bbox_2d` and fenced JSON — a parse failure is not a
grounding miss.

| model / engine | synthetic 16-target | real 1920×1080 screenshot (4 targets) |
|---|---|---|
| **Qwen3.6-35B-A3B, SYCL, mmproj-F16** | **16/16** (conv=norm; large 4/4, small 4/4, icon 4/4, link 4/4) | **0/4** → **1/4** with `--image-min-tokens 2048 --image-max-tokens 4096` |
| MiniCPM-V-4.7, SYCL, mmproj-f16 | 6/16 (large 3/4, small 1/4, icon 0/4, link 2/4) | 0/4 |
| MiniCPM-V-4.7, SYCL, mmproj-f16-4x | **0/16** | — |
| **UI-Venus-1.5, Vulkan, mmproj-f16** | **16/16** (all four classes 4/4) | **2/4** — best real-desktop score |
| UI-Venus-1.5, SYCL | **GPU-RESET** (see below) | — |

The earlier "6/6" on 200–560 px boxes was **not** a pass: the targets were 2–5× larger than
real controls and the score mixed two coordinate conventions. Under one convention that run
was 5/6. The realistic set is the one to rank on.

**The real-desktop score is the one that matters, and it splits the field.** On the actual
screen (waybar clock, active tab, + button, focused-window label — 26-px-tall text)
**UI-Venus-1.5 lands 2/4** and Qwen3.6 0/4 (1/4 with a raised image-token budget); MiniCPM
0/4. So for small-UI grounding the GUI specialist (UI-Venus) beats the bigger generalist.
The server warns at load: *"Qwen-VL models require at minimum 1024 image tokens to function
correctly on grounding tasks … try adding `--image-min-tokens 1024`"*; raising the budget to
2048/4096 moved Qwen3.6 0/4 → 1/4 only. The remaining lever for both is a **crop-and-zoom**
pass (send a 960×540 region and map coordinates back), which is how computer-use agents
normally handle small UI.

**MiniCPM-V-4.7 is out for grounding**: 6/16 on large synthetic targets and 0/4 real; its
4×-downsampled projector scores 0/16. A smaller image-token count is *not* a free speed win
here — it destroys grounding.

### ⚠ GPU reset — UI-Venus (`qwen3vl_moe`) must NOT run on SYCL on this box

`UI-Venus-1.5-30B-A3B Q8_0` on `SYCL0` took the whole card down:

```
xe 0000:03:00.0: [drm] Tile0: GT0: Timedout job ... in llama-server [2474315]
xe 0000:03:00.0: [drm] Tile0: GT0: reset started / reset done   (04:20:25 and 04:21:08)
ggml_backend_sycl_synchronize → UR_RESULT_ERROR_DEVICE_LOST
```

Marcel's monitors are driven by this card, so a reset is a hard stop, not a slow row. It is
recorded as a `GPU-RESET` row and **must never be retried**; run this arch on the Vulkan tip
build instead. `grounding-test.sh` now greps `journalctl -k --since <test start>` for
`GT0: reset started` / `DEVICE_LOST` after every test and writes a `GPU-RESET` row + exits 9
so no later step can re-run a resetting config.

## 3. Ranked pick + the winning command (as measured)

| # | model | engine | placement | ctx/KV | 4 K TTFT | 32 K TTFT | decode | image prefill | grounding synth / real | tool call |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **Qwen3.6-35B-A3B UD-Q4_K_XL** | **llama.cpp SYCL `358a420ec`** | `-ngl 99 -ncmoe 32` (+projector) | 65536 / q8_0 | **14.3 s** | **99.5 s** | 36.5 / 28.0 t/s | ~10 s (2060 tok) | **16/16 / 0/4** (1/4 w/ big image budget) | **PASS** |
| 2 | **UI-Venus-1.5-30B-A3B Q8_0** (GUI specialist) | **llama.cpp Vulkan `358a420ec`** | `-ngl 99 -ncmoe 40` (+projector) | 65536 / q8_0 | not measured | not measured | not measured | not measured | **16/16 / 2/4 — best real** | not measured |
| — | Qwen3.6-35B-A3B (text-only, fastest that fits) | SYCL | `-ncmoe 30` | 65536 / q8_0 | — | — | 40.0 t/s | — | — | — |
| — | Qwen3.6-35B-A3B | Vulkan | `-ngl 99 -ncmoe 24` | 65536 / q8_0 | ~16 s | ~110 s | 33.8 t/s | — | — | — |
| — | MiniCPM-V-4.7-35B-A3B Q8_0 | SYCL | `-ngl 99 -ncmoe 40` | 65536 / q8_0 | — | — | — | — | 6/16 / 0/4 (4× proj 0/16) | — |
| — | UI-Venus-1.5-30B-A3B Q8_0 | **SYCL** | — | — | — | — | — | — | **GPU-RESET — never retry** | — |
| — | Qwen3.8-27B-OBLITERATED (dense) | Vulkan | `-ngl 44` | 65536 / q8_0 | 32 K ≈ 9.2 min | — | 5.8 t/s | — | — | — |

**Verdict:** Qwen3.6 on SYCL is the fastest computer-use config measured (14 s 4K TTFT, 10 s
screenshot, tool-call PASS) and ties UI-Venus on the synthetic page, but **UI-Venus grounds
the real desktop better (2/4 vs 0/4)**. For a screenshot→click loop, pair them: UI-Venus (or
a crop-and-zoom pass) for the click target, Qwen3.6-SYCL for the text/tool work.

**Daily driver (measured, best computer-use config on this box):**

```bash
set +u; . /home/nexuslink/intel/oneapi-env.sh >/dev/null 2>&1
export LD_LIBRARY_PATH="/home/nexuslink/intel/oneapi/dnnl/2026.0/lib:${LD_LIBRARY_PATH:-}"; set -u
CAP=34G ~/.local/bin/jobcap \
engines/llama.cpp-sycl-tip/build/bin/llama-server \
  -m models/llm/unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --mmproj models/llm/unsloth/Qwen3.6-35B-A3B-GGUF/mmproj-F16.gguf \
  --device SYCL0 -ngl 99 -ncmoe 32 \
  -c 65536 -np 1 -fa on -ctk q8_0 -ctv q8_0 -b 1024 -ub 1024 -lm none \
  -fit off -t 16 --host 127.0.0.1 --port 18082 --jinja --temp 0 --repeat-penalty 1.05
```

Use `-ncmoe 30` instead of 32 for the fastest **text-only** config (481 vs 463 t/s, 40.0 vs
37.7 t/s decode, 1890 MiB headroom). The Vulkan fallback is the same line with
`engines/llama.cpp-vulkan-tip/build/bin`, `--device Vulkan0`, `-ncmoe 24` (~316 t/s prefill)
— keep it if SYCL misbehaves on a future file.

**UI-Venus-1.5-30B-A3B (best real-desktop grounding; Vulkan only):**

```bash
CAP=44G ~/.local/bin/jobcap \
engines/llama.cpp-vulkan-tip/build/bin/llama-server \
  -m models/llm/mradermacher/UI-Venus-1.5-30B-A3B-GGUF/UI-Venus-1.5-30B-A3B.Q8_0.gguf \
  --mmproj models/llm/mradermacher/UI-Venus-1.5-30B-A3B-GGUF/UI-Venus-1.5-30B-A3B.mmproj-f16.gguf \
  --device Vulkan0 -ngl 99 -ncmoe 40 \
  -c 65536 -np 1 -fa on -ctk q8_0 -ctv q8_0 -b 1024 -ub 1024 -lm none \
  -fit off -t 16 --host 127.0.0.1 --port 18087 --jinja --temp 0 --repeat-penalty 1.05
```

Do **not** run UI-Venus on SYCL (GPU reset, §2.6). Its speed was not measured this pass —
only grounding.

## 4. Queued / next (configs are in place)

| model | state | command |
|---|---|---|
| Qwen3.6 MTP file (`unsloth/Qwen3.6-35B-A3B-MTP-GGUF`) | downloaded | `spec-levers.sh` / `-md … --spec-type draft-mtp` on the SYCL winner (text-only; never with an image, #30307) |
| MiniCPM-V-4.7 / UI-Venus **server sessions** | grounding done | run `matrix-server.sh` on `configs/matrix-minicpmv47-sycl.env` and `configs/matrix-ui-venus-vulkan.env` for TTFT/decode/image-prefill/tool-call (grounding alone was measured) |
| **UI-Venus on SYCL** | **banned** | GPU reset — never retry |
| Qwen3.8-Flash-Next IQ3_XXS (S4) | downloaded | **needs MemAvailable ≥ 48 GiB** (box has ~46); contexts 65536 then 131072; screenshot test on Vulkan `-fa on`, Vulkan `-fa off`, SYCL (#29093); never MTP + image together |
| Flash-Next IQ3_S SSD-offload (S5) | downloaded | needs more than free RAM; log major page faults (`/proc/<pid>/stat` field 12) |
| **crop-and-zoom grounding** | not implemented | send a 960×540 region and map coordinates back — the fix for 26-px real-desktop text |
| `--moe-cache-mib 1024/2048` | server-only flag | run through `matrix-server.sh`/`spec-levers.sh` on the winner (not `llama-bench`) |
| `GGML_SYCL_ENABLE_HOST_PINNED_MEM=1` | default is already 1 | explicit set is a **no-op** on this build — documented, not swept |

## 5. Not measured (honest list)

* **S2 MiniCPM-V-4.7 and S3 UI-Venus — grounding scored, but no server session**: TTFT,
  decode, image-prefill time and tool-call were **not** measured for either; only the
  grounding score. MiniCPM was run on SYCL (6/16), UI-Venus on Vulkan (16/16) — so the two
  models' grounding numbers are from *different engines*.
* **S4 Flash-Next, S5 IQ3_S** — not run. S4/S5 are additionally **memory-blocked** on a
  61 GiB box (IQ3_XXS trunk 47 GB + 28.8 GB lazy table).
* **MTP / `draft-mtp` decode on Qwen3.6** — the MTP file is on disk but the lever was not run.
* **`--moe-cache-mib`** — server-only; not run.
* **Crop-and-zoom grounding** (the obvious next lever for the 26-px real-desktop text) — not
  implemented.
* **16 K prompt prefill** — measured at 4 K and 32 K; the 16 K point was skipped.
* **Thread pinning effect on the SYCL winner** — pinning was neutral on the Vulkan plain
  config; not re-run on top of `-lm none + ub1024`.
* **Real-screenshot ground truth is eyeballed** (waybar clock, active tab, + button,
  focused-window label) from a screenshot, not a pixel-perfect annotation — treat those 4 as
  indicative. The synthetic 16-target set is exact.
* **Grounding is a synthetic page + 4 real targets**, not ScreenSpot-Pro; every vendor
  GUI/tool number in `research/12` remains vendor-reported.
* **`-fa off` with f16 KV** (the only way it could run) — not tested.
* **SYCL long-context correctness** beyond the 32 K served prompt was not re-verified.

## 6. Quiet mode (does a bench lag the desktop?)

Marcel's rule: a test must not make the PC lag. Probe = `bench/lag-probe.py`, a 1 ms
sleep loop **pinned to CCD0** (`taskset -c 0-5` — the CPUs the desktop lives on),
recording wakeup overshoot for 60 s. `bench/quiet-run.sh` starts the Qwen3.6 SYCL
daily-driver bench (pp4096/tg128, ncmoe 30, `-r 6`, depth 0) and runs the probe during it.
Rows: `test=lagprobe` in `results-matrix.tsv`.

| config | jobcap knobs | `-t` | pp4096 t/s | tg128 t/s | probe p50 | p99 | max |
|---|---|---|---|---|---|---|---|
| idle (no job) | — | — | — | — | 0.05 | **0.06** | 1.47 ms |
| A current | none | 16 | 478.84 | 40.42 | 0.05 | **0.06** | 1.04 ms |
| B | CPUS=6-11,18-23 CPUW=20 | 12 | 479.24 | 38.82 | 0.05 | **0.06** | 0.93 ms |
| C | CPUS=6-11 CPUW=20 | 6 | 479.38 | 40.13 | 0.05 | **0.06** | 1.02 ms |

**Verdict: no quiet-mode change is needed.** All three configs sit exactly on the idle
p99 floor (0.06 ms), so the current default (`-t 16`, no pin, CPUW 100) already does not
lag the desktop — SYCL prefill/decode is GPU-side and its 16 CPU-expert layers are
bandwidth-bound, not CPU-hogging. B costs 4.0 % decode for nothing; C is neutral. The
jobcap `CPUS`/`CPUW` knobs are therefore **available but left off**; defaults unchanged in
every bench config and in `serve/config.yaml`.

**If the screen still stutters it is GPU-side** (the card also drives Marcel's monitors),
which the CPU probe cannot see. The lever there is a smaller ubatch: `-ub 512` costs
**39 % prefill** (291.85 vs 478.84 t/s at ub 1024, tg flat 39.21 vs 40.42), so the default
stays `-ub 1024`.

## 7. Wave 5 (2026-10-13): watchdog, grounding fix, quiet A/B, small quants

### 7.1 Watchdog — PROVEN (fake load, no model)
`bench/watchdog.sh` wraps every model run now (`matrix-bench.sh` and `matrix-server.sh` route
through it). Proof with a Python RAM allocator under `jobcap` (scratch `wd/`, rows in `wd/proof.tsv`):

| case | thresholds | result |
|---|---|---|
| control, 1 GiB load | defaults | rc=0, no row |
| memory trip | MemAvailable floor = avail−1500 MiB | rc=9, killed after ~2 GiB allocated, 0 leftover procs, 0 user scopes left |
| PSI trip | psi_full max 0.0 | rc=9 on `psi_io_full avg10=0.02`, 0 leftovers |

Also logged in `results-matrix.tsv` as `test=watchdog-proof`.

### 7.2 Grounding scorer — fixed and wired
* `grounding-score.py` is now the only scorer (`score()`, `summary()`, `selftest()`).
  `grounding-test.sh` imports it; the inline copy (which counted hits over all targets but
  by-class over parsed ones only) is gone. A mock OpenAI endpoint run exercised the live path
  end to end (live and offline scores agree).
* Rule: `covered` = target box intersects the crop; headline is `hits/covered`; by-class
  always lists all 16 targets; a missing/unparseable answer is a miss with a reason.
* Re-scored from the audit dump `gt-dump-matrix-qwen36-sycl-srv-3476662.tsv` (no model loaded):

| row | old (inline rule) | new |
|---|---|---|
| Qwen3.6 SYCL topstrip 08:25:38 | 8/16 (cover 4/16) | **8/8 covered** (16 targets; icons + links are out of crop) |
| Qwen3.6 SYCL quadrant 08:30:36 | 12/16 | **12/16** (by-class now sums to 16: small 1/4, large 3/4) |

* 4 quadrant targets (UPLOAD, OK, APPLY, EDIT) were `nojson`: Qwen answered `{"x": [291, 506]}`,
  a point list the parser does not read. Kept as misses per the scorer's rule. Decision for
  Marcel: accept list-valued x/y in the parser (then re-score from the same dump).
* **VOID**: `grounding-quadrant` 08:34:26 and `grounding-topstrip` 08:34:24 (UI-Venus,
  Vulkan). The orchestrator killed the server mid-run: dump has 29 `ERR connection refused`
  rows. The topstrip row was also written after the kill, so it is void too (beyond the one row
  named in the brief).

### 7.3 Quiet mode A/B (Qwen3.6-35B-A3B UD-Q4_K_XL, SYCL, -t16 unpinned) — NOT YET MEASURED
What the desktop actually stalled on:
* 08:47 `-lm dio`: watchdog ABORT-LAG `psi_io_full avg10=3.20` (load). Root cause: nvme0n1
  ran I/O scheduler `none`, so `ionice` was ignored. Orchestrator switched it to `bfq`.
* 2nd dio run (BFQ, no ionice yet): ABORT-LAG `psi_io_full avg10=1.23` during the load.
* `matrix-bench.sh` now runs jobs under `ionice -c 3` (idle class, `IOCLASS_ARGS` overrides;
  fallback `-c 2 -n 7`) in the jobcap scope; same change in `matrix-server.sh`,
  `grounding-test.sh`, `spec-levers.sh`.
* New pre-load IO guard: waits for `io full avg10 < 0.5` up to 30 min, else `SKIPPED-IO` row.
  Worked as intended on 09:28 (downloader held io full ~2–4%): `SKIPPED-IO`, no load.
* `quiet-run.sh` takes `CFG=` and starts the CCD0 probe when `llama-bench` starts (not after a
  fixed 6 s). Config for `-lm mmap` written (`configs/matrix-qwen36-sycl-mmap.env`), not run.
* Probe during the dio run that did load: `p50 0.05 / p99 0.06 ms` (idle floor), so the CPU side
  is not what stalls the desktop.

Still to measure: dio vs mmap load time, PSI deltas during load and bench, and the threads A/B/C.

### 7.4 Small quants (research/21)
Verified so far: Qwen3.6-35B-A3B UD-IQ3_XXS (12.3 GiB) and the rest as the downloader finishes.
Gemma 4 12B not listed in research/21 yet, so it is not tested.
Pending for the next run, in order: Gemma 4 12B (all-VRAM candidate, vision gate first), the
dio vs mmap A/B, then the other small quants.

Assistant score (Marcel, widened goal): per tested model: (a) describe the live screen vs
`hyprctl clients -j` titles, (b) short German and English answers to a work question (text
recorded), (c) time to first token and first sentence for a 200-token prompt with and without a
screenshot, (d) tool-call smoke. Not run yet.

## 8. Gemma 4 12B (QAT Q4_0 + mmproj), SYCL — 2026-10-13

Config: `bench/configs/matrix-gemma4-12b-qat-sycl-nothink.env` (ngl 99, ctx 16384, q8_0 KV, `-lm dio`,
`--reasoning off`). Vulkan twin: `matrix-gemma4-12b-qat-vulkan-nothink.env` (**not run**).

### 8.0 What was broken, and what the numbers mean
* **Gemma 4 thinks by default.** Thinking-on replies spend the whole `max_tokens` in `reasoning_content`
  (`finish_reason=length`, `content=""`). The empty vision answers of the first sessions (10:02 SYCL,
  Vulkan probe, SYCL gpu/cpu-projector probes) are that, **not** a broken projector. Verdict: VISION NOT
  BROKEN. The Vulkan and SYCL probes both failed identically with thinking on.
* Harness bugs fixed this pass: `matrix-server.sh` `grep|pipefail` (EFF_NGL/EFF_NCMOE, `|| true`);
  ASSIST block moved out of the python heredoc; `assistant-score.py` German answer replaced with a second
  English one and a `row.append` timestamp clash fixed; **`grounding-test.sh` dropped the config's
  `SERVER_EXTRA`** (no `--reasoning off`, no `--jinja`), so the first grounding run was thinking-on.
  It now passes `SERVER_EXTRA` and writes `finish_reason`, `completion_tokens`, `reasoning_chars` per row.
* Watchdog: `WATCH_IO_GRACE_S` (default 0 = unchanged) skips only the io-full trip for the first N s of a
  launch. Used 30 s for model launches. Why: a 6.5 GB direct read at 5.2 GB/s alone gives `psi_io_full`
  1.41 (1.35 s read). A cold launch tripped at 1.03 with nothing else loading. Memory trips stay on.
  Lag-probe during 3 direct reads (CCD0, 8 s each): p99 0.07 / 0.20 / 0.68 ms, max 2.46 ms (idle p99 0.06).
  **Needs Marcel's OK** (see 8.6).

### 8.1 Load, VRAM, speed (SYCL, thinking off, 16K)
| item | result |
|---|---|
| cold / warm load | 2.0 s / 2.0–3.0 s (`-lm dio`) |
| VRAM after load | 9263–9408 MiB of 11605 (free ~2.2–2.8 GiB) |
| free VRAM after image and text requests | 2342 MiB (vprobe `arc-vram`); fit rule ≥1.2 GiB holds |
| 32K ctx headroom (q8_0 KV) | **not run** |
| pp4096 (prompt 2173-char AGENTS.md, `ttft` row) | 7.3 s TTFT, 791 tok/s |
| tg | 26.8 tok/s (27.3 in the thinking-on run) |
| 200-tok prompt, cached prefix, median of 3 | TTFT 80 ms, first sentence 478 ms (no image); TTFT 111 ms, first sentence 769 ms (with screenshot) |
| PSI, whole session | mem 0 ms; io full +217 ms (other agents' disk work overlapped) |
| harness gap | `peak_rss`/`peak_vram` read 0: the poll looks for the server as a child, but jobcap puts it outside. Not fixed. |

### 8.2 Vision gate (SYCL)
* Thinking off: describe OK. It matches the live screen (Hermes app plus a browser report, dark theme,
  hardware and benchmark table). `finish=stop`.
* **Vision coords FAIL.** JSON parses (`{"x":681,"y":15}`) but the clock sits at x≈1230–1330. The parser
  passing is not a grounding pass.
* Thinking on: describe and coords both `finish=length`, `content=""` (reasoning only).
* Projector on CPU (`--no-mmproj-offload`) vs GPU: both thinking-on, same failure. The projector placement
  question is therefore **still open**. The thinking-off Vulkan vision run is not done.
* Tool-call smoke (`get_weather Vienna`): PASS, thinking on and off.

### 8.3 Assistant score (thinking off, SYCL)
* Describe vs `hyprctl clients -j` (only title: `Hermes`): scorer 0/1. The reply describes the window
  content but never names "Hermes". Qualitative match, not a name match.
* EN work answer 1 (client delivery, Thursday): "Your order is currently scheduled to be delivered this
  coming Thursday. I will let you know if there are any updates regarding your shipment."
* EN work answer 2 (supplier, March invoice): "Thank you for your inquiry regarding the March order. We
  will confirm the invoice number and get back to you by Friday."

### 8.4 Grounding, synthetic 16 targets, convention **norm** (0–1000 grid), thinking off
| crop | hits | large-btn | small-btn | icon | text-link | note |
|---|---|---|---|---|---|---|
| none (1920×1080) | 8/16 | 4/4 | 4/4 | 0/4 | 0/4 | replies finish=stop, 21–22 tok, reasoning 0 |
| topstrip | 8/8 covered (of 16) | 4/4 | 4/4 | — | — | 8 targets lie outside the strip |
| quadrant (2× zoom) | **16/16** | 4/4 | 4/4 | 4/4 | 4/4 | |

The `none` misses are a **systematic y drift**, not format failures. Icon replies sit at y≈488 for boxes at
y 420–444. Link replies sit at y≈605–608 for boxes at y 560–578. The 2× zoom removes it. Under `abs` the
hit count is ~0–1 everywhere, so norm is the convention the model uses.
Void: the first synthetic run (10:18, thinking on, 4/16, 7 empty replies), row `grounding-none` 10:22:16.

### 8.5 Grounding, live desktop (DP-1 crop 0,0 1920×1080)
* Fresh screenshot 10:28, `gt-live-2026-10-13.png`. The old `gt-real.tsv` (pre-reboot browser tabs) was **not**
  used: the layout changed. Boxes come from a vision-model estimate, ±3 px. They are **not pixel ground truth**.
  6 targets: clock, focused window label, workspace "1", New session row, "Show all 31 sessions" link, N logo.
* topstrip: 2/5 covered (of 6; one target below the strip). quadrant: **4/6**. `none` was not run.
* Misses: window label (both crops), workspace "1" (both), "Show all" in the topstrip (nojson).

### 8.6 Thinking toggle (per request, no restart) — `bench/thinking-toggle.py`
Server: SYCL, same flags, **without** `--reasoning off`. Prompt (the same for every variant):
> Two trains leave the same station on the same track in the same direction. Train A leaves at 14:20 at
> 84 km/h. Train B leaves at 14:50 at 112 km/h. At what clock time does B catch up with A? Give the clock
> time, then one short sentence explaining the reasoning.

**Correct answer: 16:20.** At 14:50 A is 84 × 0.5 = 42 km ahead. B closes at 112 − 84 = 28 km/h, so
42 / 28 = 1.5 h after 14:50 = 16:20.

| variant | reasoning chars | TTFT | first sentence | total | answer | right? |
|---|---|---|---|---|---|---|
| `chat_template_kwargs.enable_thinking=false` (bool) | 0 | 0.98 s | 2.16 s | 2.39 s | "16:00 … 30-minute head start (42 km) … 1.5 hours" | **no** (arithmetic slip) |
| no field (server default, thinking on) | 1346 | 1.08 s | 20.9 s | 21.1 s | "16:20 … closes the 42 km head start at 28 km/h, 1.5 hours" | **yes** |
| `enable_thinking=true` | — | — | — | — | — | **not run** |
| `enable_thinking="false"` (string) | — | — | — | — | — | **not run** |
| `reasoning_effort="none"` | — | — | — | — | — | **not run** |
| `reasoning_effort="high"` | — | — | — | — | — | **not run** |
| `thinking_budget_tokens=64` + enable_thinking true | — | — | — | — | — | **not run** |

Findings so far:
* **The per-request switch works** for `enable_thinking=false`. Reasoning is 0 chars and the first sentence
  arrives in ~2 s. Thinking adds ~19 s to the first sentence.
* **Thinking off is fast but got this puzzle wrong.** Thinking on got it right. Marcel's "think about this"
  path is needed for multi-step arithmetic.
* The remaining variants were blocked: the watchdog tripped on `psi_io_full 2.16` (other agents' disk
  work, row `ABORT-LAG gemma-thinking-toggle`). The GPU lock is then held by a process that is not this
  run: `flock -x bench/.gpu.lock sleep 7000` (pids 281089/281146). **Not killed.** Resume with
  `bench/thinking-toggle.py <port> <outdir> <variants>` once the lock is free.
* Server args for the toggle: `reasoning_effort` and `thinking_budget_tokens` exist in this build
  (`server-common.cpp:1419–1442`). Budget was not tested. Build help: `--reasoning-budget N` (-1 default).

### 8.7 Still open (not run in this pass)
* 32K ctx headroom. Gemma E4B (step 2). Qwen3.6 dio vs mmap (step 3). Small-quant sweep (step 4).
* Vulkan0 thinking-off vision and grounding. Live `none` grounding. The remaining toggle variants.
* The grounding text-link and icon misses are a y-drift at 1×. Quadrant zoom fixes it; a 1× default is not usable for those.
