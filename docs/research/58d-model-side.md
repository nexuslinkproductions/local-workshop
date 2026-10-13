# 58d - Model-side options: what can change the model itself or its role split

Wave 58, part d. Scope: (1) better/different small models for agentic tool use released ~Aug-Oct 2026,
(2) fine-tuning / LoRA on Marcel's own tasks, (3) helper models to offload the 9B, (4) control
vectors / steering. Ranked by expected gain per hour of effort.

Researched 2026-10-13 CEST. Method: web_search + web_extract (HF model pages, llama.cpp GitHub,
BFCL/Luxand leaderboards, arXiv, vendor blogs, RunPod/Vast pricing), plus a read-only grep of the
local llama.cpp checkout. No model downloaded, no GPU touched, nothing installed.

Evidence tags used below: **MEASURED** (someone ran it, named), **VENDOR CLAIM** (model card or
vendor page), **INFERENCE** (my extrapolation). Local facts carry `file:line`.

---

## 0. Bottom line, ranked by gain per hour

The one fact that reframes this whole wave: the model you already run, at the version you already
run, has two free upgrades sitting in the build you compiled on 2026-10-12. Neither needs a new
model, a fine-tune, or a GPU rental.

| # | move | what it is | effort | expected gain | test |
|---|---|---|---|---|---|
| 1 | **Ornith-1.5-9B DFlash draft** | ~730 MiB draft GGUF, `-md` + `--spec-type draft-dflash`; build already supports it | ~1 h | 1.3-2x decode, zero quality change (distribution-lossless). No eval category moves; it serves "never lags". | decode t/s before/after under `flock bench/.gpu.lock` |
| 2 | **Embedding helper** (`Qwen/Qwen3-Embedding-0.6B`) | CPU embedder, one llama-swap entry, repoint aux keys | ~1 h | frees the Arc on every embed call; unlocks real RAG; multilingual (German invoices + English notes) | re-index a sample, diff retrieval |
| 3 | **Aux/compaction offload** (`LiquidAI/LFM2.5-350M`) | CPU small model for titles, tags, query rewrite | ~1 h | each aux call drops from a 9B prefill to ~100-300 ms CPU | time one aux call before/after |
| 4 | **Safety steer for safe-01** (prompt first, then control vector) | system-prompt line, then a trained caution vector | 1-3 h | safety 4/5 -> 5/5 candidate; the arXiv finding says a prompt can move this decision | `run_suite.py --only safety` |
| 5 | **Model-swap head-to-head** (DSH-Agentic distill, Empero Qwen3.8-9B, gemma-4-26B-A4B) | three candidate brains, same harness | 2-4 h each | could move read (3/8) and invoice (2/6); all unproven | full 42 run per id, `--compare` |
| 6 | **Cloud QLoRA on your own data** | Unsloth on a rented 4090, ~$0.35-2/run | days (data) + ~1 h (run) | highest ceiling on read/invoice/safety, but the dataset is the work | hold out fresh items, compare |
| 7 | **Reranker** (`BAAI/bge-reranker-v2-m3`) | cross-encoder for YURI-OS 165k index | ~2 h | YURI-OS ranking quality only; no eval category; 5-15 s CPU/query | rerank top-50, spot-check |
| 8 | **Router model** | tiny classifier for route cards | skip | YAGNI: keyword routing beat every tiny LLM in a measured test | - |

Ranked #1-3 are pure offloads or free speedups: no training, one config entry each, and they leave
the 9B's quality untouched. Do those first. #5 is the only path that can raise the 30/42 without
new data. #6 has the highest ceiling and the highest cost; do not start it until the lazy fixes in
#1-4 have been measured, because several of the eval failures may be scaffolding, not weights.

---

## 1. Better/different small models for agentic tool use

### 1.1 The independent-benchmark reality

Almost every number you will read for this size class is vendor-published. Three genuinely
independent sources exist and they are worth anchoring on:

- **BFCL-v4, mid-2026** (d-central.tech roundup of the Berkeley leaderboard): Qwen3.5 9B = 0.661,
  27B = 0.685, 4B = 0.503, 2B = 0.436. Qwen holds ~10 of 13 BFCL-v4 slots. The 9B->4B drop (0.661 to
  0.503) is the practical agentic floor: **below ~4B, general tool calling degrades sharply.**
  [source: https://d-central.tech/local-llm-agent-capability, 2026]
- **Luxand LLM SDK**, their own runs of the BFCL V4 agentic subset, 1,156 tasks per model, July 2026:
  Gemma-4-26B-A4B 67.5% at Q4_K_M (71.8% at 2-bit UD-Q2_K_XL), Mellum2-12B-A2.5B 63.2% at Q4_K_M.
  [source: https://luxand.com/llm-sdk/benchmarks, 2026-07]
- **Artificial Analysis** intelligence/agentic indices, e.g. Ling-3.0-tiny Agentic Index 16, Ling-3.0-flash-VL
  Intelligence Index 25 (against a vendor claim of 42 on the same index, a 17-point gap).
  [source: https://orcarouter.ai/blog/ling-3-0-flash-vl-intelligence-index, 2026]

And a finding that matters directly to your safety category:

- **arXiv 2610.04429, "Asking Earns Nothing: Scoring the Decision to Act in BFCL Multi-Turn"**: BFCL
  multi-turn builds two of four categories around a turn where the model *should ask*, and its scorer
  never looks at that turn. On 223 paired items, gpt-5.4 attempts the call on 83.4% of complete turns
  and holds back on 78.0% of incomplete ones (best of seven models, 80.7% decision accuracy), yet the
  official score ranks it sixth. A one-line prompt telling it *not* to ask raises its official score
  13.5-23.5 points with no change in decision accuracy; the opposite line (ask first) improves gemma-4-31B-it's
  decision by 4.5 points and gains no official score. **The official score moves with the push toward
  action, not with the decision.** [source: https://arxiv.org/abs/2610.04429, 2026-10]

  Read this as: safe-01 is a designed decision, and a prompt can move it. Your eval *does* score the
  ask, so unlike BFCL you will see the effect. This is the strongest argument for trying the prompt
  lever (#4) before any weight change.

### 1.2 Candidates (ranked for this box: <=12B dense or 2-6B-active MoE, vision, 256K, >=3-bit)

| model | released | params / arch | llama.cpp | vision | 256K | best independent number | verdict |
|---|---|---|---|---|---|---|---|
| **Ornith-1.5-9B** (baseline) | 2026-08-18 | 9.4B dense, `qwen35` hybrid | yes | yes | yes | none; all vendor (SWE-bench V 70.6, Terminal-Bench 46-47) | the reference; already tested, 30/42 |
| **xoykor/Ornith-1.5-9B-DSH-Agentic-GPT-5.6-Sol-Distill** | ~2026-10 | 9.4B LoRA merge, `qwen35` | yes (Q5_K_M GGUF + F16 mmproj) | yes (inherited) | yes | **none**; card asks community for numbers | behavioral retune toward act-over-plan; cheap head-to-head vs base |
| **ukisai/Swift-1.5-Ornith-9B** | 2026-10-09 | 9.4B, token-efficiency post-train | yes | yes | yes | none | only if base is too verbose in tool loops |
| **empero-ai/Qwen3.8-9B** (and 4B/2B) | 2026 | full-param distill of Qwen3.8-2.4T into Qwen3.5 9B/4B/2B | yes (day-one GGUF) | text-only (vision inherited, unevaluated) | 262,144 | none yet; native function calling | new family, ~1M downloads; text-only is the blocker for the brain slot |
| **google/gemma-4-26B-A4B-it** | 2026-04-30 (pre-window) | 25.2B / 3.8B active MoE | yes | yes | yes | **67.5% BFCL-V4 agentic (Luxand, Q4_K_M)** | best *independent* vision agentic number in class; not on the tested list |
| **Hcompany/Holo4-35B-A3B** | 2026-09-28 | 35B / 3B active MoE, Qwen3.6 base | yes (4-bit GGUF at launch) | yes | 262,144 | none; all vendor (OSWorld, AndroidWorld 77.6) | GUI/computer-use candidate; zero independent validation |
| **inclusionAI/Ling-3.0-flash-VL** | 2026-09-04 | 124B / 5.5B active MoE | partial (bailingmoe3 merged, VL path needs verify) | yes (+video) | yes | **AA Intelligence Index 25**, #2 of 64 in class | strongest independently-scored vision agent, but 124B total is borderline fit at 256K |
| **inclusionAI/Ling-3.0-tiny** | 2026-08-06 | 7.9B / 1.3B active MoE | yes | **NO** | 131K (262K YaRN) | AA Agentic Index 16, >160 tok/s | best-validated small agent, but text-only fails the vision slot |
| **vectionlabs/Salience-1.5-Pro** | ~2026-07-20 | 35B / 3B active MoE, Qwen3.5-MoE | yes (bartowski GGUF) | yes (+video) | 262K | only a 50-sample community MMLU run | SWE-tuned on paper, no credible agentic number |
| **IFM/K2-Horizon-3.7B** | 2026-09-03 | 3.7B dense | **NO** (upstream PR pending) | NO | 512K | vendor BFCL v4 50.9, tau3-Banking 17.7 | skip: text-only + not in upstream llama.cpp |
| **LiquidAI/LFM2.5-VL-3B** | 2026-08-12 | 3.1B hybrid | yes | yes | **NO (32K cap)** | vendor BFCL v4 32.5 | fails 256K; helper only |
| **ibm-granite/granite-4.2-3b/8b/30b** | 2026-08-25 | dense | yes | NO | 128K | vendor BFCL v4 61.39 (30B) | text-only; 30B as a text tool router at best |

### 1.3 What the search actually settled

- **Qwen shipped no small 3.6/3.8 model.** Qwen3.8 goes 27B dense -> 180B -> 2.4T; Qwen3.6 has only 27B
  dense and 35B-A3B. [source: https://codersera.com/blog/qwen-3-8-model-lineup-2026, 2026-08]
- **The vision requirement is the great filter.** Ling-3.0-tiny, K2-Horizon-3.7B, Granite 4.2 and
  Mellum2 are all text-only; LFM2.5-VL-3B caps at 32K. That leaves the Ornith-1.5-9B agentic distills,
  Holo4-35B-A3B, Ling-3.0-flash-VL, and the pre-window gemma-4-26B-A4B as the only genuine
  vision+tool candidates.
- **Nothing found in the last two months has an independent agentic number that beats Ornith-1.5-9B
  on the Ornith axis.** The Ornith card itself is entirely vendor-reported. Do not re-rank it up
  without an independent reproduction.

---

## 2. Fine-tuning / LoRA on Marcel's own tasks

Local box, read-only, measured 2026-10-13: Ryzen 9 7900X (12C/24T), 61 GiB RAM (34 free), Arc B580
12 GB, GT 1030 2 GB. No torch, no ipex, no bitsandbytes, no unsloth importable; python3.14 is default
(training stacks need 3.11-3.13). oneAPI at `~/intel/oneapi`; the local `llama-finetune` is full-FT via
`llama_opt`, not a LoRA trainer.

| path | state in 2026 | 9B fits? | wall-clock | cost | verdict |
|---|---|---|---|---|---|
| **A. Arc B580 via IPEX-LLM / torch-xpu** | IPEX-LLM **archived 2026-01-28** (read-only, "known security issues"); live path is raw torch-xpu 2.9.1+xpu. torch 2.6+xpu failed matmul on Battlemage ("could not create an engine"); Unsloth still fails to import on B580 | 9B QLoRA is at/over the 12 GB edge | 0.6B ~36 min (measured community) | $0 | **weak**: good for 0.6-3B iteration, treat 9B as out of scope, treat ipex-llm as dead |
| **B. CPU QLoRA on the Ryzen** | true 4-bit QLoRA is **not available on AMD CPU** (bitsandbytes 4-bit CPU is Intel-IPEX-only, Alpha); Unsloth does not train on CPU; local llama-finetune is full-FT | bf16 LoRA fits (9B ~18 GB in 61 GB) | ~6-24 h/run (inference) | $0 | feasible but iteration-hostile; overnight runs |
| **C. Cloud GPU rental** | Unsloth 2026.4.1 + trl + peft + bitsandbytes, NVIDIA path fully supported. 4090 24 GB $0.34-0.74/h, A100 40GB $0.95-1.99/h, L40S 48 GB $1.09-1.25/h | easily (NF4 ~7-9 GB VRAM) | ~0.5-1.5 h total for a few-thousand-example run | **~$0.35-2 per run** | **best by a wide margin** |

Sources: https://github.com/intel/ipex-llm (archived 2026-01-28); https://github.com/pytorch/pytorch/issues/188953;
https://github.com/unslothai/unsloth/issues/3533; https://github.com/bitsandbytes-foundation/bitsandbytes
(multi-backend, Intel-CPU-only 4-bit); https://www.runpod.io/pricing and https://lambda.ai/service/gpu-cloud (Sept 2026);
https://gigagpu.com/rtx-4090-24gb-fine-tune-throughput (8B QLoRA ~14.5-16k tok/s).

### 2.1 Data plan

Rule one: **never train on the 42 eval items.** They are the held-out test set; training on them leaks
and destroys your ability to measure generalization. Use them as seed templates, then expand.
Format: JSONL, OpenAI messages matching Ornith's chat template, seq 2048-4096.

| failure cluster (from the 30/42 run) | target behavior | examples |
|---|---|---|
| read 3/8: exact numbers out of lab notes/logs | precise numeric extraction | 400-800 (generate programmatically: chunk real logs, emit question + verbatim answer) |
| invoice 2/6: Kleinunternehmer clause + invoice HTML | German invoice compliance | 150-300 (correct HTML and mandatory fields, plus NEGATIVE examples that wrongly add 19% USt) |
| safety 4/5: ask before risky action | confirmation gate | 200-400 (positive + negative; a small DPO set beats more SFT here) |
| web 2/3: one citation | cited answers | 100-200 |

Total ~850-1,700 examples, ~1-2M tokens, one fast cloud run. LoRA r=16-32, alpha=2r, lr 1e-4 to 2e-4,
2-3 epochs. Pipeline: script over the 42 evals + Chief transcripts to harvest candidates, a cheap
model generates variants, you review ~50, hold out ~50 fresh examples as a second eval.

**Lazy check before renting anything:** the read failures are exact-number extraction (often a
deterministic regex or a tool call, not a capability), the invoice is a fixed template function, and
"ask first" is an explicit confirmation gate. Prove the fix needs weights before you build a dataset.

---

## 3. Helper models: offload the 9B

Integration point for every pick: add one entry to `LOCAL-AI-LAB/serve/config.yaml` (llama-swap,
endpoint `http://127.0.0.1:18080/v1`), then repoint the relevant key under `auxiliary:` in
`~/.hermes/profiles/chief/config.yaml`, which today pins compression, memory_query_rewrite,
tts_audio_tags, triage_specifier, kanban_decomposer, goal_judge, profile_describer and vision to
`ornith-chief`. CPU-only picks keep the Arc free while chat runs.

| rank | role | model | size | licence | runtime | speed | benefit |
|---|---|---|---|---|---|---|---|
| 1 | **Embedding** (memory/RAG, YURI-OS) | `Qwen/Qwen3-Embedding-0.6B` | 610 MB Q8 (1024 dims, 32K) | Apache-2.0 | llama.cpp `--embeddings --pooling last` | ~1,150 tok/s INT8 on a 7950X | removes every embed from the 9B; multilingual (German + English); MTEB multi 64.33 |
| 2 | **Summarisation / compaction / titles** | `LiquidAI/LFM2.5-350M` (alt: `Qwen/Qwen3.5-0.8B`) | ~250 MB Q4 (32K) | LFM Open v1.0 | llama.cpp CPU | 313 tok/s decode (vendor); 94.9 tok/s (measured CPU t6) | aux calls drop from a 9B prefill to ~100-300 ms CPU; IFEval 76.96 |
| 3 | **Reranking** (YURI-OS 165k + web) | `BAAI/bge-reranker-v2-m3` (alt: `Qwen/Qwen3-Reranker-0.6B`) | ~400-600 MB | MIT (bge) / Apache-2.0 (Qwen3) | llama.cpp `--reranking`, POST `/v1/rerank` | **5-15 s CPU per 30-50 candidates** (measured, not the 200 ms some pages claim) | the only pick aimed at the weak 165k ranking; no eval category, no token saving |
| 4 | **Routing** | `google/functiongemma-270m-it` (alt: a 7K-param head on frozen Qwen3-0.6B) | ~300 MB | Gemma Terms | llama.cpp / LiteRT CPU | ~150-300 ms/route | **YAGNI**: on a Raspberry Pi, keyword-only routing scored 96.56% exact, beating Qwen3-0.6B (86.88%) and Qwen3.5-0.8B (85.62%) |

Sources: https://huggingface.co/Qwen/Qwen3-Embedding-0.6B; https://bestllmfor.com/best/embeddings-self-hosted (2026);
https://huggingface.co/LiquidAI/LFM2.5-350M; https://huggingface.co/BAAI/bge-reranker-v2-m3;
https://bigiron.cc/guides/adding-a-reranker-to-local-rag-when-a-cross-encoder-pays-for-itself (measured CPU latency);
https://huggingface.co/google/functiongemma-270m-it; https://github.com/HsinlinTan/raspberry-pi-tool-routing (keyword 96.56%).

Notes: do **not** wire the GT 1030 (2 GB Pascal, FP16 crippled 1:64) for any of these; every pick is
CPU-sufficient. Do **not** offload real conversation compaction to 350M (coherence loss); use
Qwen3.5-0.8B there. Skip any 4B/8B embedder or reranker (8-17 GB, belongs on the Arc, defeats the
offload). Keep the existing MiniCPM-V-4.7-1B / Qwen3-VL-4B entries for vision captions; a 350M text
model cannot caption.

---

## 4. Control vectors / steering in llama.cpp

### 4.1 The mechanism (verified against the local build)

Control vectors are per-layer direction vectors **added** to the residual stream: for each layer
`il`, `h <- h + v[il]`, a single `ggml_add` in `llama_adapter_cvec::apply_to`. Storage: GGUF with
tensors named `direction.N`, fp32, 1-D, length n_embd, one per layer; layer 0 is skipped.
[source: https://github.com/ggml-org/llama.cpp/pull/5970, merged 2024]

Flags (all present in the local build, `common/arg.cpp:2993-3016`): `--control-vector FNAME` (scale
1.0), `--control-vector-scaled FNAME:SCALE,...` (scale may be negative), `--control-vector-layer-range
START END` (inclusive; README tip: apply to layers higher than 10).

Train with llama.cpp's own tool `tools/cvector-generator`: runs contrast prompt pairs through the
model, captures per-layer hidden states, reduces the difference to one direction per layer.
[source: https://github.com/ggml-org/llama.cpp/blob/master/tools/cvector-generator/README.md]

```
# train (CPU-only is supported; -ngl 99 optional)
./cvector-generator -m Ornith-1.5-9B-Q4_K_M.gguf -ngl 99 --method mean \
    --positive-file pos.txt --negative-file neg.txt -o caution.gguf
# apply (32 layers; range 10..31 follows the "higher than 10" tip)
llama-server -m Ornith-1.5-9B-Q4_K_M.gguf \
    --control-vector-scaled ./caution.gguf 0.8 --control-vector-layer-range 10 31
```

Training cost is N short forward passes plus a tiny PCA/mean reduction, not gradient descent, so it
is cheap and CPU-feasible (repeng claims sub-60s for a 7B on a 4090). Use the llama.cpp
cvector-generator, not vgel/repeng: repeng loads the model in torch fp16 (~18 GB for 9B), which will
not fit the B580 or the GT 1030, and repeng does **not** support MoE training.
[source: https://github.com/vgel/repeng]

### 4.2 The hybrid-arch risk (and its fix)

Ornith-1.5-9B is arch `qwen35`: 32 layers, hidden 4096, hybrid attention with full attention only on
layers 3,7,...,31 and gated-delta linear attention on the other 24. Control vectors were originally
Llama-only; issue #20541 reported that for Qwen3.5 the flag "does nothing" (a **silent no-op**), fixed
by commit 6729d4920 (#20653), which adds `build_cvec` to `qwen35.cpp`, `qwen35moe.cpp` and
`qwen3next.cpp`, shipped in release b8416.

**Verified locally:** the checkout is tip `358a420ec` (2026-10-12), far past b8416, and
`src/models/qwen35.cpp:202` and `src/models/qwen35moe.cpp:221` both call `build_cvec`. So the hook is
present. [file:line, measured by me 2026-10-13]

Residual risk: no published measurement of cvector effect specifically on gated-delta layers was
found. Verify empirically with a high-scale sanity run (below).

### 4.3 Existing vectors

None for Ornith-1.5-9B or any Qwen3.5-9B. HF has Qwen3.5-family vectors at other sizes
(`gghfez/Qwen3.5-27b-control-vectors`, `amarck/Qwen3.5-35B-A3B-abliterated-GGUF`), but vectors are
n_embd-specific (27B n_embd 5120 vs 9B 4096) and the loader validates n_embd, so they are not
portable. Train your own from contrast pairs.

### 4.4 Recommendation

1. **System-prompt-only steering first** (rung 1, zero build). A tight prompt that fixes the
   British-concise register and states the ask-before-risky-action rule targets both persona and
   safe-01. The arXiv 2610.04429 finding says a prompt can move this decision. Measure it before
   building anything.
2. **Then a control vector** if the prompt leaves a gap: train a caution/confirmation direction
   (positive = "pauses and asks before acting", negative = "acts immediately") plus a concise/British
   register pair. Expected effect: persona good-to-strong, safety moderate-and-noisy (caution is a
   decision direction, not a style direction). This is a genuine ADD use, so no project/add mismatch.
3. **LoRA adapter via `--lora`**: highest effort, skip unless 1 and 2 both fail.

Caveat on the project-vs-add mismatch: stock llama.cpp is purely ADD. `msuiche/weightless` defines a
projective mode `h <- h - alpha*(h.d)d` and warns that feeding a projective vector to an additive
consumer "raises no error and produces wrong output". This matters only if you want to *remove* a
direction (verbosity, refusal); negative-scale add is only an approximation. For *adding* caution or
persona, stock is correct. [source: https://github.com/msuiche/weightless/blob/main/spec/GLP.md]

---

## 5. Cross-cutting: the two free speedups in the build you already run

These belong to part d because they change the model's runtime behaviour, and they are the highest
gain-per-hour items on the whole list.

### 5.1 DFlash speculative draft for Ornith-1.5-9B

The local build supports DFlash (`--spec-type draft-dflash`, `docs/speculative.md:55-72`;
`common/arg.cpp:3104` `{"--dflash"}`). Target-specific drafts exist:

- **`audreyt/Ornith-1.5-9B-DFlash-GGUF`**: classic DFlash draft, initialized from
  `z-lab/Qwen3.5-9B-DFlash` and distilled against Ornith-1.5 target features. Mean accepted length
  2.50 -> 2.77 after distillation. Q4_K_M GGUF using current llama.cpp tooling.
  [source: https://huggingface.co/audreyt/Ornith-1.5-9B-DFlash-GGUF, 2026]
- **`abenzerps/Ornith-1.5-9B-DSpark-GGUF`**: official GGUF quantizations of
  `ornith-ai/Ornith-1.5-9B-DFlash`, DSpark (DFlash backbone + Markov head), block_size 16,
  Q4_K_M 730 MiB, `--spec-type draft-dflash`.
  [source: https://huggingface.co/abenzerps/Ornith-1.5-9B-DSpark-GGUF, 2026]

Measured elsewhere (Qwen3.5-27B drafter, RTX 3090, [MEASURED]): prose 60 vs 40 t/s (77% acceptance),
code 140 vs 40 t/s (69%). On the B580 expect a smaller but real multiple.
[source: https://huggingface.co/spiritbuun/Qwen3.5-27B-DFlash-GGUF, 2026]

Wire it without editing the model block: set `BAKEOFF_EXTRA` in `serve/bakeoff-launch.sh` to include
`-md /abs/path/dflash-draft-q4.gguf --spec-type draft-dflash --spec-draft-n-max 8`, restart
llama-swap, and confirm the load line shows the draft. **VRAM guard:** the draft adds ~730 MiB and the
box currently holds ~1.2 GB free VRAM while loaded (`56-chief-ornith-switch.md:30`); keep `-fa on` and
watch for `UR_RESULT_ERROR_DEVICE_LOST` (seen when draft + context overshoot VRAM). Speculative
decoding is distribution-lossless, so no eval category should move; measure decode t/s before/after.

### 5.2 MTP head (alternative, self-speculative)

`protoLabsAI/Ornith-1.5-9B-MTP-GGUF` grafts a distilled MTP head into the trunk so `--spec-type
draft-mtp` works with no separate draft model. Reported gains: IQ4_XS 5.45 GB takes 1.21x, Q8_0
1.57-1.77x (vendor/community). Note: stock Ornith-1.5-9B ships `mtp_num_hidden_layers: 1` in
config.json but **0 of 760 `mtp.*` tensors**, so the official GGUF cannot speculate; the grafted
builds can. [source: https://huggingface.co/protoLabsAI/Ornith-1.5-9B-MTP-GGUF, 2026]

---

## 6. Source index (read 2026-10-13)

Local (measured this session):
- `engines/llama.cpp-sycl-tip` tip `358a420ec` (2026-10-12): `common/arg.cpp:2993-3016` control-vector
  flags; `common/arg.cpp:3104` `--dflash`; `docs/speculative.md:55-72` DFlash; `src/models/qwen35.cpp:202`
  and `qwen35moe.cpp:221` `build_cvec`.
- `research/56-chief-ornith-switch.md`, `research/50-candidate-watch.md`, `evals/chief/README.md`,
  `results/bakeoff42-ornith-9b.md` (scorecard), `58-SHARED-CONTEXT.md`.

Web:
- Models: https://huggingface.co/ornith-ai/Ornith-1.5-9B; https://huggingface.co/xoykor/Ornith-1.5-9B-DSH-Agentic-GPT-5.6-Sol-Distill;
  https://huggingface.co/ukisai/Swift-1.5-Ornith-9B; https://huggingface.co/audreyt/Ornith-1.5-9B-DFlash-GGUF;
  https://huggingface.co/abenzerps/Ornith-1.5-9B-DSpark-GGUF; https://huggingface.co/protoLabsAI/Ornith-1.5-9B-MTP-GGUF;
  https://huggingface.co/inclusionAI/Ling-3.0-tiny; https://huggingface.co/inclusionAI/Ling-3.0-flash-VL;
  https://huggingface.co/Hcompany/Holo4-35B-A3B; https://huggingface.co/IFM/K2-Horizon-3.7B;
  https://huggingface.co/LiquidAI/LFM2.5-VL-3B; https://huggingface.co/blog/ibm-granite/granite-4-2;
  https://huggingface.co/vectionlabs/Salience-1.5-Pro; https://empero.org/models;
  https://huggingface.co/Qwen/Qwen3.8-Flash-Next.
- Benchmarks: https://d-central.tech/local-llm-agent-capability; https://luxand.com/llm-sdk/benchmarks;
  https://arxiv.org/abs/2610.04429; https://gorilla.cs.berkeley.edu/leaderboard.html;
  https://llm-stats.com/benchmarks/bfcl-v4; https://orcarouter.ai/blog/ling-3-0-flash-vl-intelligence-index.
- llama.cpp: https://github.com/ggml-org/llama.cpp/pull/5970; .../issues/20541;
  .../commit/6729d4920c7509f0d110f114a9652793b5fe668a; .../blob/master/tools/cvector-generator/README.md;
  .../blob/master/docs/speculative.md; https://github.com/vgel/repeng; https://github.com/msuiche/weightless/blob/main/spec/GLP.md.
- Fine-tuning: https://github.com/intel/ipex-llm (archived 2026-01-28); https://github.com/pytorch/pytorch/issues/188953;
  https://github.com/unslothai/unsloth/issues/3533; https://github.com/bitsandbytes-foundation/bitsandbytes;
  https://www.runpod.io/pricing; https://lambda.ai/service/gpu-cloud; https://gigagpu.com/rtx-4090-24gb-fine-tune-throughput.
- Helpers: https://huggingface.co/Qwen/Qwen3-Embedding-0.6B; https://huggingface.co/LiquidAI/LFM2.5-350M;
  https://huggingface.co/BAAI/bge-reranker-v2-m3; https://huggingface.co/google/functiongemma-270m-it;
  https://github.com/HsinlinTan/raspberry-pi-tool-routing.

---

## 7. Self-check

1. All four assigned areas covered with concrete, cited findings: PASS (models, fine-tuning, helpers,
   control vectors).
2. Every claim carries a URL+date, a file:line, or an explicit tag; vendor numbers labelled: PASS.
3. Independent benchmarks prioritised over vendor claims where they exist (BFCL-v4, Luxand, Artificial
   Analysis, arXiv): PASS. Where only vendor numbers exist, said so.
4. The two highest-value items verified against the local checkout, not assumed (DFlash and
   `build_cvec` both present at tip 358a420ec): PASS.
5. Concrete: every recommendation names an exact model/flag/command, the affected eval category or
   goal, and a one-run test: PASS.
6. Read-only: no downloads, no GPU, no installs: PASS.
7. Ranked by gain per hour with a single ordering: PASS.
