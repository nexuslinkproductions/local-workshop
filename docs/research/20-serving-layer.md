# 20 — On-demand serving layer (model shelf) + Hermes wiring

Status: **prepared, not activated.** Nothing here has loaded a model; the GPU is
untouched. Written 2026-10-13 while another agent owned the B580.

Goal: the shelf models become an OpenAI-compatible endpoint that **loads a model
on the first request for it and unloads it after idle**, refuses to load while
ARC Raiders runs, and is usable by Hermes as a provider with ≥ 64 K context.

---

## 1. Chosen tool: **llama-swap v264** (not llama.cpp's own router mode)

The tip build **does** have a router/multi-model mode — this is not a missing
feature. `tools/server/README.md` §"Using multiple models" and
`tools/server/server-models.cpp`:

| capability | llama.cpp router mode (tip `358a420ec`) | llama-swap v264 |
|---|---|---|
| per-model command line | `--models-preset <file.ini>`, `[*]` global + per-model sections | `models.<id>.cmd` (free-form shell string) |
| on-demand load on first request | `--models-autoload` (default on), `?autoload=true/false` per request | default behaviour |
| idle unload | `--sleep-idle-seconds N` (sleeps model+KV out of RAM, reloads on next task) + `POST /models/unload` | `ttl` / `globalTTL` (seconds of inactivity) + `POST /api/models/unload` |
| one OpenAI endpoint, route by model id | yes (`model` field in body) | yes (`model` field in body) |
| **refuse to load while a game runs** | **no hook** | **yes** — `cmd` can be `serve/gate-run.sh …` |

**The gate requirement decides it.** Router mode spawns *its own* `llama-server`
binary with the preset's args; the only preset-exclusive keys are
`load-on-startup`, `stop-timeout`, `dedup-cache-models` (README.md:1957-1960) —
there is no `cmd`/hook to interpose a script before the child starts, and the
child is launched from the router's own executable path (not a PATH lookup), so
you cannot shadow it with a wrapper. llama-swap's per-model `cmd` is exactly the
insertion point `bench/gate.sh` needs, so the ARC Raiders rule is enforced with a
three-line script instead of a patched engine build.

Secondary reasons: `ttl` is the exact semantics asked for (inactivity timer,
resets on every request); `-validate` gives a no-load config check; single static
binary, no deps, root-free.

Cost of the choice: llama-swap is one more process to keep updated (it pins a
`cmd`, so the engine path/args are ours to maintain — which is the same thing we
already do in `bench/configs/`).

---

## 2. Install (root-free, done)

Release binary into `~/.local/bin` (no `go` on this box; prebuilt is the lazy
path). v264, sha256 verified against the release checksums:

```sh
curl -sL -o /tmp/lswap.tgz https://github.com/mostlygeek/llama-swap/releases/download/v264/llama-swap_264_linux_amd64.tar.gz
tar xzf /tmp/lswap.tgz -C /tmp/lswap llama-swap
install -m755 /tmp/lswap/llama-swap ~/.local/bin/llama-swap
# sha256 ed3569386f0194401b39732e592b881c72223c8a0a49f6a2e1376f1796e3101d  (matches llama-swap_264_checksums.txt)
```

`~/.local/bin/llama-swap --version` → `v264 (a025e03)`, built 2026-10-12.

---

## 3. Files written

| file | what |
|---|---|
| `serve/config.yaml` | llama-swap config: `globalTTL: 600`, `healthCheckTimeout: 900`, `startPort: 18100`, one entry per shelf model, each `cmd` wrapped in the gate |
| `serve/gate-run.sh` | the gate: `source ../bench/gate.sh`, `game_running()` → exit 1, else `exec "$@"` (chmod +x) |
| `serve/local-ai.service` | systemd `--user` unit (**written, NOT enabled/started**) |
| `serve/hermes-provider.yaml` | Hermes provider block **proposal** (not merged; `~/.hermes/config.yaml` untouched) |
| `research/20-serving-layer.md` | this report |

Model IDs (used verbatim by Hermes → llama-swap routing):
`qwen3.6-35b-a3b-mtp`, `minicpm-v-4.7-35b-a3b`, `ui-venus-1.5-30b-a3b`,
`qwen3.8-flash-next-iq3_xxs`.

### Measured vs placeholder (read this before trusting a number)

* **Measured** — `qwen3.6-35b-a3b-mtp`: `-ngl 99 --n-cpu-moe 32 -c 65536 -np 1
  -fa on -ctk q8_0 -ctv q8_0 -fit off -t 16 --jinja`, i.e. research/10-test-matrix.md
  §3 "Recommended daily driver today" — the one placement measured to serve a real
  agent prompt **with the vision projector** on the B580. (It is measured on the
  base build; the MTP build is the same arch/quant.)
* **PLACEHOLDER** — every other `--n-cpu-moe`/`-c`, and the MTP/spec lever. Values
  came from `bench/configs/matrix-*.env` (the sweep's own defaults), not from a
  finished hillclimb. Each is tagged `PLACEHOLDER` in `serve/config.yaml`.
  - minicpm-v-4.7: `--n-cpu-moe 40` (sweep 40/32/24 queued); mmproj = the 4x
    downsampled projector (fewer image tokens → cheaper screenshots), full
    `mmproj-model-f16.gguf` is the untested alternative.
  - ui-venus-1.5: `--n-cpu-moe 40` (sweep queued).
  - qwen3.8-flash-next: `--n-cpu-moe 0` (unknown for this arch) and `-c 65536`
    (research/10 §4 says start at 131072; 262144 needs `MemAvailable ≥ 52 GiB`).
  - MTP: `--spec-type draft-mtp` is the lever to try on the MTP build; left off
    until measured (speculation can hurt).

---

## 4. Dry-run evidence (no model loaded)

```
$ ~/.local/bin/llama-swap --config serve/config.yaml -validate
config is valid: 4 model(s), 0 peer(s)          # exit 0

$ serve/gate-run.sh echo GATE_EXEC_OK
GATE_EXEC_OK                                     # execs the real command, exit 0

$ PATH=<stub pgrep that returns 0> serve/gate-run.sh echo SHOULD_NOT_RUN
gate-run: REFUSING to load a model — ARCRaiders (PioneerGame.exe) is running
exit 1                                           # SHOULD_NOT_RUN never printed

$ source bench/gate.sh; game_state
clean                                            # game not running right now
```

No server was started, no weights were read. `ss` shows 18080/18100 free.

---

## 5. Activation steps (when you want it live)

1. **Start the proxy** — either foreground:
   ```sh
   ~/.local/bin/llama-swap --config ~/NEXUS_AI_CENTER/LOCAL-AI-LAB/serve/config.yaml --listen 127.0.0.1:18080
   ```
   or as the user unit (this is the only place the unit gets installed):
   ```sh
   mkdir -p ~/.config/systemd/user
   cp ~/NEXUS_AI_CENTER/LOCAL-AI-LAB/serve/local-ai.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now local-ai.service
   journalctl --user -u local-ai.service -f
   ```
   The proxy holds **no VRAM** until the first request; a model only loads then.

2. **Smoke test** (only when no bench test owns the GPU — see caveat 6.2):
   ```sh
   curl -s http://127.0.0.1:18080/v1/models | jq -r '.data[].id'      # lists the shelf, nothing loaded
   curl -s http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' \
     -d '{"model":"qwen3.6-35b-a3b-mtp","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
   curl -s http://127.0.0.1:18080/running                              # which model is up
   curl -s -X POST http://127.0.0.1:18080/api/models/unload/qwen3.6-35b-a3b-mtp
   ```
   First request waits for the cold load (`healthCheckTimeout: 900`); after 600 s
   idle the model unloads and VRAM is released.

3. **Wire Hermes** — merge `providers.local-ai` from `serve/hermes-provider.yaml`
   into the `providers:` map of `~/.hermes/config.yaml` (same shape as the existing
   `october`/`cursor` entries). Do this only when approved; the file is untouched.

---

## 6. Caveats / open items

1. **The gate guards the game, not the bench lock.** `game_running()` is what was
   asked for. If you also want the shelf to refuse while a bench test holds the GPU
   lock, call `gate_check()` in `gate-run.sh` instead — it already includes the game
   check *and* refuses while any `llama-server`/`llama-bench` runs (same file,
   one-line change). Left out so the shelf stays startable during ad-hoc work.
2. **Two llama-servers can still collide** if the shelf is live *and* a bench test
   starts. Within llama-swap only one model runs at a time, but llama-swap does not
   know about `bench/.gpu.lock`. Rule: don't leave the service enabled while the
   hillclimb/matrix is running (caveat 1 fixes this if you want it automated).
3. **`ttl: 600` is a guess for this box.** Cold start is 22.7 s for Qwen3.6 but the
   30-37 GB models load slower; a 10-minute idle window means a repeated request
   usually hits a warm model. Tune per model if a cold start starts to bite.
4. **Placeholders must be replaced** after the hillclimb — the per-model
   `--n-cpu-moe`/`-c` (and the MTP spec lever) are unmeasured. research/10 §3/§5 is
   the source of truth; update `serve/config.yaml` when the sweep lands.
5. **Vision needs the projector.** Every entry loads its `--mmproj`, so a screenshot
   request works — but on the tight Qwen3.6 placement that projector is exactly what
   caused the GTT-spill wedge in research/10 §2. The `--n-cpu-moe 32` value is the
   measured-safe one; do not tighten it to 24 in this config without re-testing with
   the projector loaded.
