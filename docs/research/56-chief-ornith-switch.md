# 56 — Chief brain switched to Ornith-1.5-9B @ 256K

Measured winner (research/42 + bakeoff): Ornith-1.5-9B Q4_K_M, ctx 262144, KV q4_0, vision encoder on CPU,
`-b 256 -ub 256`, thinking off by default. Decode ~57 t/s, 30K prefill ~1200 t/s, min free VRAM ~1.1 GB, Chief eval 30/42.
No MTP/spec flags, no GGML_SYCL_NO_PINNED.

## What changed
- `serve/config.yaml`: new model `"ornith-chief"` (line 152). Uses `bakeoff-launch.sh ${PORT} 262144 <gguf> <mmproj> q4_0 --mmproj-cpu`,
  llama-swap per-model `env: ["BAKEOFF_EXTRA=-ub 256 -b 256"]` (supported in v264, `-validate` passes; no extra launch script needed),
  alias `ornith-chief-think` (enable_thinking true, thinking_budget_tokens 512), main id enable_thinking false,
  capabilities text+image, tools, context 262144. `gemma4-12b` entries untouched (fallback).
- `~/.hermes/profiles/chief/config.yaml`: `model.default`, `providers.local-ai.model` / `models`, and all 19 aux/helper `model:` pins
  gemma4-12b -> ornith-chief; `context_length` (model + provider) 65536 -> 262144; comments updated.
  (`compression.threshold_tokens` 32768 left as is.)

## Backups
- `serve/config.yaml.bak-chief-ornith`
- `~/.hermes/profiles/chief/config.yaml.bak-chief-ornith`

## Validation
- `llama-swap -validate -config serve/config.yaml` -> valid, 9 models. Both YAMLs load with PyYAML.
- `hermes -p chief config` read-back shows model ornith-chief, ctx 262144, aux pinned to ornith-chief.

## Smoke test (under `flock -x bench/.gpu.lock`)
- No llama-swap was running on :18080 (no installed unit; `serve/local-ai.service` is not enabled), so the smoke started a
  throwaway `llama-swap --listen 127.0.0.1:18080`, then `/unload` and killed it. Nothing else was touched.
- Effective argv: `... --no-mmproj-offload -c 262144 -ctk q4_0 -ctv q4_0 -b 1024 -ub 1024 ... -ub 256 -b 256` (last flag wins).
- Chat "Reply with exactly: ready" -> `ready`, 5.5 s cold incl. model load (48 t/s decode).
- Tool call (get_weather, city) -> `get_weather {"city":"Vienna"}`, finish_reason tool_calls, 1.3 s.
- Free VRAM while loaded: 1249 MiB, then 1215 MiB (>= 750 required). After unload: 9866 MiB free (baseline).
- `journalctl -k --since -5min | grep -iE 'reset|timedout'`: empty.

## Note
Chief needs llama-swap listening on :18080; it was not running before this change either. To keep it up:
`cp serve/local-ai.service ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now local-ai.service`.

## Rollback
```
cd /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
cp -p serve/config.yaml.bak-chief-ornith serve/config.yaml
cp -p ~/.hermes/profiles/chief/config.yaml.bak-chief-ornith ~/.hermes/profiles/chief/config.yaml
```
(then restart llama-swap if it is running)
