# LOCAL AI LAB — LLM Stack

Local LLM serving on **Intel Arc B580 (12 GB VRAM, Xe2)** via the **Vulkan** backend,
Arch Linux (Omarchy), 61 GB RAM, 24-core Ryzen. No CUDA/NVIDIA anywhere in the stack.

Two models, **two separate llama.cpp builds** — see "Why two builds" below.

| Model | File | Size | Quant | Runtime build | Port |
|---|---|---|---|---|---|
| Qwen3.8-27B-OBLITERATED | `models/llm/Qwen3.8-27B-OBLITERATED/Qwen3.8-27B-OBLITERATED-IQ4_XS.gguf` | 14.4 GiB | IQ4_XS | `llm/llama.cpp` (stock, Vulkan) | 8081 |
| Ternary-Bonsai-2-27B | `models/llm/bonsai/Ternary-Bonsai-2-27B-PQ2_0.gguf` | 6.7 GiB | **PQ2_0** (ternary) | `llm/llama.cpp-prism` (PrismML fork, Vulkan) | 8082 |

Both GGUFs declare `Architecture: qwen35` — the **Qwen3.5 hybrid linear-attention
arch** (per layer, 3× `linear_attention` Gated-DeltaNet : 1× `full_attention`;
64 layers, hidden 5120, head_dim 256, native ctx 262144). Think "Qwen3-Next-style",
next generation.

### Verified by direct GGUF inspection (`file`/`grep` on the binaries)

- Metadata keys present in both files: `qwen35.{block_count,context_length,
  embedding_length,feed_forward_length,attention.head_count{,_kv},attention.
  {key,value}_length,ssm.{conv_kernel,state_size,group_count,time_step_rank,
  inner_size},full_attention_interval,rope.dimension_{sections,count}}` — the
  full set llama.cpp's qwen35 loader expects. Both embed `tokenizer.chat_template`
  and `general.sampling.{top_k,top_p,temp}` defaults.
- OBLITERATED additionally has `qwen35.nextn_predict_layers` = 1 and a
  `blk.64.*` NextN/MTP block (full-attn style layer + `nextn` tensors) on top of
  blocks 0–63.
- Bonsai additionally carries `prism.hadamard.*` metadata (version, block_size,
  transform, axis, sign_mode, weight_names, sign_widths, sign_values,
  gdn_v_grouped) — PrismML's Hadamard-transform sign packing for ternary weights.
  Stock llama.cpp fails on this even before the PQ2_0 type question.
- Linear-attn layers store `attn_qkv`+`attn_gate`+`ssm_{a,alpha,beta,conv1d,dt,
  norm,out}`; full-attn layers store separate `attn_{q,k,v,output}`+`attn_{q,k}_norm`.

---

## Quick start

```bash
# one-time build + verify (clones, cmake/ninja Vulkan builds, test-loads both
# models, benchmarks, writes llm/BUILD-REPORT.txt):
bash llm/setup-llm.sh            # or: chmod +x llm/setup-llm.sh && ./llm/setup-llm.sh

# daily use:
bash chat-obliterated.sh         # → http://127.0.0.1:8081
bash chat-bonsai.sh              # → http://127.0.0.1:8082
```

(If the launchers aren't executable — NTFS mounts often show 644 — either
`chmod +x chat-*.sh` or just run them with `bash`.)

---

## Why two llama.cpp builds

- **Stock `ggml-org/llama.cpp` (master)** runs everything with standard quants —
  including the new `qwen35` arch (upstream support merged via PR
  [#19468](https://github.com/ggml-org/llama.cpp/pull/19468), 2026-02-10) and has
  Vulkan `GATED_DELTA_NET` compute shaders since PR
  [#20334](https://github.com/ggml-org/llama.cpp/pull/20334) / #20377
  (merged ~b8317+), so the hybrid linear-attention layers run on the GPU.
- **`PQ2_0` is PrismML's own ggml type (id 142)** — Bonsai's ternary {−1,0,+1}
  packing at group size 128, ~2.13 bpw. Stock llama.cpp has never heard of it and
  will refuse the file. The `prism` branch of
  [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp) adds PQ2_0
  on all backends including Vulkan (their PR #32) and is rebased onto
  `prism-b10658+` upstream, so it also has `qwen35` + the GDN Vulkan shaders.

### ⚠️ Do NOT use PrismML prebuilt binaries for this GPU

Their current *binary releases* still contain the **Vulkan PQ2_0 silent
CPU-fallback bug**: the log claims all layers offloaded, but the weights actually
sit in a multi-GB `CPU model buffer` and decode at **< 2 tok/s**. The Intel
Xe2/Xe3 fix ([PrismML PR #238](https://github.com/PrismML-Eng/llama.cpp/pull/238),
merged **2026-09-21**) is **source-only so far** — you must build the `prism`
branch yourself (setup-llm.sh does this). Same caveat applies to their PTQ1_0
files (fixed in source, ~9× faster post-fix on Xe3). Ref:
`prism-ml/Ternary-Bonsai-2-27B-gguf/KNOWN_ISSUES.md`.

---

## Build details

```bash
# llm/llama.cpp
git clone https://github.com/ggml-org/llama.cpp
cmake -S llama.cpp -B llama.cpp/build -G Ninja \
      -DGGML_VULKAN=ON -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build llama.cpp/build -j$(nproc)     # → build/bin/llama-server, -cli, -bench…

# llm/llama.cpp-prism
git clone -b prism https://github.com/PrismML-Eng/llama.cpp llama.cpp-prism
# same cmake flags, same build dir pattern
```

Vulkan device check: `build/bin/llama-cli --list-devices` must print
`Intel(R) Arc(TM) B580` as `Vulkan0` (or `Vulkan1` if a Ryzen iGPU claims slot 0
via RADV). `vulkaninfo --summary` should show the same device. ICDs installed:
`/usr/share/vulkan/icd.d/{intel_icd,intel_hasvk_icd,radeon_icd}.json`
(ANV + hasvk + RADV are all present; ANV serves the B580).

If both a B580 and an iGPU appear, force the B580:
`export LLAMA_VK_DEVICE=Vulkan0` (the launchers pick this up) or add
`--device Vulkan0`.

**NTFS note:** builds live on the mounted NTFS volume. Works fine but slower;
if git or ninja ever choke, building in `~/` and symlinking `llm/…/build/bin`
back here is a viable fallback.

---

## Model A — Qwen3.8-27B-OBLITERATED (port 8081)

Abliterated (refusal-geometry-removed) Qwen3.5-27B by OBLITERATUS/elder-plinius.
GGUF `arch=qwen35`, 866 tensors, 65 blocks (64 + 1 MTP block), ctx 262144.
IQ4_XS ≈ **14.4 GiB — larger than the 12 GB VRAM**, so `-ngl 99` offloads what
fits and the remainder stays in host RAM (61 GB free; mmap keeps it lazy). Expect
spillover: watch `load_tensors` / `model buffer size` lines in the log.

**Author-mandated settings** (baked into `chat-obliterated.sh`):

| setting | value | why |
|---|---|---|
| temperature | **0** (greedy) | fullest, code-rich output; >0.5 degrades |
| repetition_penalty | **1.15** | greedy loops on imports/boilerplate without it |
| system prompt | **none** | system prompts can reintroduce refusals |
| thinking | **off** | think chains eat the token budget |
| max tokens | ≥ 2048 | attack chains/code need room |

The GGUF embeds `tokenizer.chat_template` (ChatML + `enable_thinking` switch) and
the dir also ships the same `chat_template.jinja` — the launcher passes both
`--jinja` and `--chat-template-file` (belt and suspenders; either alone works).
Thinking is off by default; to enable it per request send
`"chat_template_kwargs": {"enable_thinking": true}`.

⚠️ *Open item:* the GGUF carries a 65th block — `blk.64.*` is the NextN/MTP
layer (`qwen35.nextn_predict_layers=1`). Runtimes either use it for speculative
decoding or warn-and-ignore it; if this build refuses on the extra tensors,
re-export without MTP or update llama.cpp — check `logs/server-obliterated.log`.

## Model B — Ternary-Bonsai-2-27B PQ2_0 (port 8082)

PrismML's second-gen **ternary-weight reasoning model** on the same `qwen35`
hybrid arch (851 tensors, 64 blocks). 6.7 GiB → **fits fully in 12 GB VRAM** with
`-ngl 99`. It *thinks* by default (reasoning effort `xhigh`; use `medium` for
shorter answers; `low` is unsupported and behaves like `xhigh`).

Card sampling defaults (thinking mode — also carried in GGUF `general.sampling.*`):
`temp 1.0, top_p 0.95, top_k 20, min_p 0.05 (llama.cpp's default)`.
Non-thinking: `temp 0.7, top_p 0.80, top_k 20, presence_penalty 1.5`.
These are server-side defaults; any request can override.

---

## Measured performance

> **Pending — run `bash llm/setup-llm.sh` to fill this in.** It writes
> `llm/BUILD-REPORT.txt` with per-model `tok/s` (server `/v1/chat/completions`
> timings + `llama-bench -p 128 -n 32`).

| Model | Backend | Expected | Measured |
|---|---|---|---|
| OBLITERATED IQ4_XS | Vulkan, partial offload | single-digit–low-teens t/s decode (spill tax) | ⏳ |
| Bonsai PQ2_0 | Vulkan, full offload | tens of t/s (ternary kernels are fast; post-#238 Xe2 path) | ⏳ |

Reference points: on B580 Vulkan, a dense 7B does ~65–130 t/s tg; PrismML's
Xe2 fix measured ~9× decode uplift vs. the broken path on Xe3. **If Bonsai
reports ~2 t/s and a multi-GB `CPU model buffer size`, you're on the CPU-fallback
bug — rebuild from `prism` source.**

---

## Tuning cheatsheet (B580 / Vulkan)

Flags used by the launchers / verified present in this build (setup-llm.sh
section 3 greps `llama-server --help` and prints what exists):

- `-ngl 99` — offload all layers; auto-spill past VRAM. Lower (≈48) if OOM.
- `-fa on` — flash attention. head_dim=256 is supported on the Xe path; if a
  build rejects it, drop to `-fa auto` or remove.
- `-c 32768` — context. Only the 16 `full_attention` layers pay KV-per-token
  (linear layers keep fixed SSM state — the hybrid advantage), so 32 K ctx ≈ ~2 GB.
- `--cache-type-k q8_0 --cache-type-v q8_0` — quarter-size KV; slight quality cost.
- `--temp / --top-p / --top-k / --min-p / --repeat-penalty` — server-side sampling
  defaults.
- `--jinja` + `--chat-template-file` / `--chat-template-kwargs` — Jinja chat
  templates and per-model kwargs (`enable_thinking`).
- `--device Vulkan0` / env `GGML_VULKAN_DEVICE=0` — pin the B580 if an iGPU shows up.
- `--override-tensor "regex=CPU"` — force specific tensors to CPU (last-resort
  workaround for quant-specific Vulkan bugs).
- `-t N` — CPU threads; matters for the RAM-resident fraction of the 15 GB model.
- `--override-tensor "blk\.(3[5-9]|4[0-9]|5[0-9]|6[0-4])\..*=CPU"`-style splits can
  hand-pick which layers spill — usually unnecessary; `-ngl` is enough.

Killing a wedged server: `pkill -f llama-server` or `fuser -k 8081/tcp`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `unknown architecture qwen35` | build too old — qwen35 needs ≥ ~Feb-2026 master (PR #19468); rebuild |
| Bonsai loads but ~2 t/s, "CPU model buffer" ≈ file size | PQ2_0-on-Vulkan bug in prebuilt prism binaries → build `prism` branch from source |
| load aborts on Vulkan OOM (15 GB file) | `-ngl` down to 48/40/32; or `--no-mmap` off + close other VRAM users |
| model won't load, `PQ2_0` / `unsupported type` | you're on the **stock** build — use `llm/llama.cpp-prism` binaries |
| no `Vulkan0` in `--list-devices` | ANV not seeing the card: check `vulkaninfo --summary`, reinstall `vulkan-intel`, verify `/dev/dri` |
| garbage output only on GPU | rare quant/Vulkan shader bug (cf. upstream #27022 for IQ1_M); try `--override-tensor` to CPU for the offending tensor type |
| refusal-ish behavior on OBLITERATED | you set a system prompt or temp > 0 — the card says neither |

## Housekeeping

- `llm/setup-llm.sh` — idempotent full pipeline; `--build-only`, `SKIP_BENCH=1`.
- `llm/logs/` — per-run server/bench/cmake logs. `llm/BUILD-REPORT.txt` — summary.
- Update builds: `git -C llm/llama.cpp pull && cmake --build llm/llama.cpp/build -j`
  (same for `llama.cpp-prism`; prism tracks its own `prism` branch).
- Web UIs are the stock llama.cpp SvelteKit pages — served by each `llama-server`.
- `llm/.permtest` is a leftover permission-probe file — safe to delete.
