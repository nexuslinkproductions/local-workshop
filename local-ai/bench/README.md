# bench/ — benchmark harness for the local llama.cpp builds

Re-runnable, one-config-at-a-time benchmarks for the two Vulkan builds on the
Intel Arc B580, with every run serialized on a single machine-wide lock.

| File | Purpose |
|---|---|
| `bench.sh <config.env>` | run one config with llama-bench, append rows to `results.tsv` |
| `ttft.sh --port <p> [--server-cmd CMD]` | TTFT + decode tok/s against a llama-server |
| `fit-ngl.sh <config.env> <ngl...>` | step `-ngl` down until it loads; prints the winner |
| `gate.sh` | lock path, safety gate, VRAM read, `--help` flag lint (sourced, not run) |
| `parse-bench.py` | `llama-bench -o json` → TSV rows; `--selftest` asserts the parsing |
| `configs/*.env` | one variable per config |
| `logs/` | wall-clock logs of past runs (audit trail for rule 6) |

## Machine rules (Marcel, 2026-10-12)

1. **Every test runs EXCLUSIVE** on `bench/.gpu.lock`. `bench.sh` and `ttft.sh`
   re-exec themselves under `flock -x -w 3600` — a caller cannot forget it.
2. **A server-based test holds the lock for the whole session in one call**:
   start server → wait for `/health` → measure → kill it. That is
   `ttft.sh --server-cmd "<launcher>"`. A server started outside the lock cannot
   be rule-2 clean, and `ttft.sh` says so in a WARNING instead of pretending.
3. **Builds/compiles take the lock SHARED** so they may overlap each other but
   never overlap a test:
   ```bash
   flock -s /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu.lock cmake --build build -j
   ```
   The lock is what serializes: a test waits for running builds, a build waits
   for a running test, and CPU load therefore never skews a number.
4. **Downloads and installs need no lock.**
5. **Before a test, anything else running is reported, never killed.**
   `gate.sh` inspects `llama-server` / `llama-bench` / `benchmark_genai` (argv
   based, so a shell that merely mentions the name is not a false positive) and
   refuses with a "wait for it, or --force" message. Nothing is ever killed that
   the script did not start.
6. **Every test records wall-clock `start=` / `end=`** on stderr; `logs/` keeps
   them. See "Serialization log" below.

The game (ARCRaiders keeps `PioneerGame.exe` in its cmdline) is a **WARNING, not
a refusal**: rows taken with it open are tagged `game-open` and are not
comparable to clean-GPU rows. One GPU, so only one test at a time regardless.

## Usage

```bash
cd LOCAL-AI-LAB/bench
./bench.sh configs/bonsai-prism-q8kv.env --check   # lint only: no lock, no GPU, ~1 s
./bench.sh configs/cpu-only-bonsai.env             # run (takes the lock itself)

# fit -ngl to the VRAM that is free RIGHT NOW, then run the winner
./fit-ngl.sh configs/bonsai-prism-q8kv.env 99 64 48 32 24 16 8 4

# server test, rule-2 compliant: start/measure/kill inside one locked call
./ttft.sh --port 8082 --server-cmd "../chat-bonsai.sh"
./ttft.sh --port 8082 --tokens 16384 --server-cmd "../chat-bonsai.sh"
```

Adding a config: copy a file in `configs/`, change **one** variable, `--check`
first. Config vars: `BIN`, `MODEL` (relative to `LOCAL-AI-LAB` or absolute),
`NGL`, `EXTRA` (extra flags), `NOTE`, and optional `DEPTHS`/`PROMPT`/`GEN`/`REPS`.
Any of `NGL DEPTHS PROMPT GEN REPS` can be overridden per run from the
environment as `<VAR>_OVERRIDE=<value>` — that is how `fit-ngl.sh` probes.
`--probe` runs tiny tests and records **no** rows; `--force` skips the
"something else is running" refusal.

| config | bin | model | vars |
|---|---|---|---|
| `bonsai-prism-f16kv` | prism | Ternary-Bonsai-2-27B PQ2_0 | ngl 99, `-fa on -ctk f16 -ctv f16` |
| `bonsai-prism-q8kv` | prism | Ternary-Bonsai-2-27B PQ2_0 | ngl 99, `-fa on -ctk q8_0 -ctv q8_0` |
| `obliterated-stock-ngl40` | stock | Qwen3.8-27B-OBLITERATED IQ4_XS | ngl 40, `-fa on -t 16` |
| `cpu-only-obliterated` | stock | Qwen3.8-27B-OBLITERATED IQ4_XS | ngl 0, `-t 12` — DDR5 baseline |
| `cpu-only-bonsai` | prism | Ternary-Bonsai-2-27B PQ2_0 | ngl 0, `-t 12` — DDR5 baseline |

`cpu-only-bonsai` uses the prism binary because the stock build cannot load
PQ2_0 at all, even with `-ngl 0` (`llama_bench: error: failed to load model ...`,
verified 2026-10-12). `-ngl 0` still means pure CPU, so it is a fair baseline.

`--device Vulkan0` (Arc B580) is injected by `bench.sh`, not left to configs --
Vulkan1 is the Ryzen iGPU and must never be benched.

## results.tsv

Tab-separated, header on first write, appended (never rewritten):

```
timestamp  git_sha  config  model  depth  test  tps_mean  tps_std  vram_note
```

* `test` — `pp<n>` (prefill) or `tg<n>` (decode), derived from llama-bench's
  `n_prompt`/`n_gen` (its JSON has no test field).
* `git_sha` — the llama.cpp commit the binary was built from (walked up from `BIN`).
* `vram_note` — `free=<N>MiB/<total>MiB Vulkan0 <game-open|clean> ngl=<N> | <NOTE>`.
  The free-VRAM figure comes from `<bin>/llama-cli --list-devices`, Vulkan0 line,
  read immediately before the run under the lock. `ttft.sh` writes
  `... ttft=<s> prompt_tps=<n>` instead and uses `git_sha=n/a`.

Reading the numbers: a `free=` value far below what a config needs means the
config was measured while something else held VRAM. Compare only rows that share
the `game-open`/`clean` tag and a similar `free=`.

## Flag verification

Every flag the scripts pass is quoted below from that binary's own `--help`.
Stock = `llm/llama.cpp` @ `a97cce86a`, prism = `llm/llama.cpp-prism` @ `adfffbe41`;
their `llama-bench` argument surfaces are identical apart from two legacy flags
(noted at the end). `./bench.sh <cfg> --check` re-verifies this in ~1 s.

Core flags (`bench.sh`): `-m -p -n -d -ngl -r -o --device`

```
  -r, --repetitions <n>                       number of times to repeat each test (default: 5)
  -o, --output <csv|json|jsonl|md|sql>        output format printed to stdout (default: md)
  -m, --model <filename>                            (default: models/7B/ggml-model-q4_0.gguf)
  -p, --n-prompt <n>                                (default: 512)
  -n, --n-gen <n>                                   (default: 128)
  -d, --n-depth <n>                                 (default: 0)
  -ngl, --n-gpu-layers <n>                          (default: -1)
  -dev, --device <dev0/dev1/...>                    (default: auto)
```

Config flags (`-fa -ctk -ctv -t` used by the shipped configs; `-b -ub -ot
-ncmoe -lm` available for new ones):

```
  -b, --batch-size <n>                              (default: 2048)
  -ub, --ubatch-size <n>                            (default: 512)
  -ctk, --cache-type-k <t>                          (default: f16)
  -ctv, --cache-type-v <t>                          (default: f16)
  -t, --threads <n>                                 (default: 12)
  -ncmoe, --n-cpu-moe <n>                           (default: 0)
  -fa, --flash-attn <on|off|auto>                   (default: auto)
  -lm, --load-mode <auto|none|mmap|mlock|mmap+mlock|dio> (default: auto)
  -ot --override-tensor <tensor name pattern>=<buffer type>;...
```

`-d/--n-depth` is what makes the depth sweep possible, and it exists in both
builds, so no per-build adaptation is needed. Build drift to watch:

```
stock only:  -lzm, --lazy-mode <on|auto|off>                (default: auto)
prism only:  -mmp, --mmap <0|1>                             (DEPRECATED IN FAVOUR OF --load-mode)
             -dio, --direct-io <0|1>                        (DEPRECATED IN FAVOUR OF --load-mode)
```

## Serialization log (rule 6)

Wall-clock `start=`/`end=` per test land on stderr; full runs are kept in
`logs/`. Example shape:

```
start=2026-10-12T23:41:02+02:00 launch: ../chat-bonsai.sh
healthy=2026-10-12T23:41:38+02:00 pid=123456
end=2026-10-12T23:43:10+02:00 (start=2026-10-12T23:41:02+02:00)
```

A run that is queued behind someone else's build shows the lock wait as dead
time before its own `start=` line — that gap is the serialization, not slowness.

## Validation status

* `bash -n bench.sh ttft.sh gate.sh fit-ngl.sh` — clean.
* `python3 parse-bench.py --selftest` — asserts pp/tg derivation, missing-stddev
  default, and the wrapped-object JSON shape.
* `--check` passes for all five configs; a deliberate `-lzm` against the prism
  build fails loudly, so the lint is not vacuous.
* Gate: game-open is a warning + tag (shown above); a stray `llama-server` /
  `llama-bench` refuses with a wait-or-`--force` message (differential-tested
  with a stub in scratch); `--force` and the port allowance both verified.
* Not covered: 32768/131072 depths (need a clean GPU), and `ttft.sh`'s decode
  path has not yet run against a live server.
* `shellcheck` is not installed on this box; lint is `bash -n` + the flag lint.
