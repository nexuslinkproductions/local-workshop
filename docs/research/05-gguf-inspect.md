# 05 — GGUF metadata inspection + KV-cache math (qwen35 hybrid, 3 local files)

Read-only inspection, 2026-10-12. No model file was modified, no llama-server started, no GPU touched.
Reader: `gguf-py` from this repo. Stock `llm/llama.cpp/gguf-py` for the Qwen file; the prism fork
`llm/llama.cpp-prism/gguf-py` for the two PQ2_0 files (stock reader rejects tensor type 142 —
`ValueError: np.uint32(142) is not a valid GGMLQuantizationType`; the fork defines `PQ2_0 = 142`).
`general.file_type = 141` on both Bonsai files has no named entry in either fork's constants
(prism only names `MOSTLY_PQ2_0 = 128`); reported as the raw value.

## 1. Files inspected

| file | bytes on disk | GiB | reader | tensors | kv_count | file_type |
|---|---|---|---|---|---|---|
| `Qwen3.8-27B-OBLITERATED/Qwen3.8-27B-OBLITERATED-IQ4_XS.gguf` | 15,420,450,080 | 14.36 | stock | 866 | 40 | 30 (IQ4_XS) |
| `bonsai/Ternary-Bonsai-2-27B-PQ2_0.gguf` | 7,206,168,928 | 6.71 | prism fork | 851 | 49 | 141 (unnamed) |
| `bonsai-abliterated/Ternary-Bonsai-2-27B-Abliterated-PQ2_0.gguf` | 7,206,168,928 | 6.71 | prism fork | 851 | 49 | 141 (unnamed) |

Weights-only tensor bytes (computed from tensor list × `GGML_QUANT_SIZES`, excludes KV/tokenizer/alignment padding):

| file | weights bytes | GiB | breakdown |
|---|---|---|---|
| Qwen IQ4_XS | 15,409,455,104 | 14.3512 | IQ4_XS 11.2450 GiB, Q5_K 2.1249, Q6_K 0.9713, F32 0.0100 |
| Bonsai PQ2_0 | 7,195,047,936 | 6.7009 | PQ2_0 6.6471 GiB, BF16 0.0439, F32 0.0099 |
| Bonsai Abliterated | 7,195,047,936 | 6.7009 | identical to Bonsai (byte-identical tensor layout) |

The `mmproj-*.gguf` projectors in those directories were not inspected (vision sidecar, no KV cache).

## 2. Non-tokenizer KV dump

`tokenizer.*` skipped: `ggml.model`, `ggml.pre`, `ggml.tokens`, `ggml.token_type`, `ggml.merges`,
`ggml.eos_token_id`, `ggml.padding_token_id`, `ggml.bos_token_id`, `ggml.add_bos_token`, `chat_template`
— identical key set in all three files.

| key | Qwen IQ4_XS | Bonsai PQ2_0 | Bonsai Abliterated |
|---|---|---|---|
| `general.architecture` | qwen35 | qwen35 | qwen35 |
| `general.name` | Qwen3.8 27b S51 Full Merged | Hf | Hf |
| `general.basename` / `finetune` / `version` | qwen3.8 / s51-full-merged / — | folded / — / v5 | folded / — / v5 |
| `general.size_label` | 27B | 27B | 27B |
| `general.quantization_version` | 2 | 2 | 2 |
| `general.file_type` | 30 | 141 | 141 |
| `general.sampling.top_k` | 20 | 20 | 20 |
| `general.sampling.top_p` | 0.949999988079071 | 0.949999988079071 | 0.949999988079071 |
| `general.sampling.temp` | 1.0 | 1.0 | 1.0 |
| `qwen35.block_count` | **65** | **64** | **64** |
| `qwen35.context_length` | 262144 | 262144 | 262144 |
| `qwen35.embedding_length` | 5120 | 5120 | 5120 |
| `qwen35.feed_forward_length` | 17408 | 17408 | 17408 |
| `qwen35.attention.head_count` | 24 | 24 | 24 |
| `qwen35.attention.head_count_kv` | 4 | 4 | 4 |
| `qwen35.attention.key_length` | 256 | 256 | 256 |
| `qwen35.attention.value_length` | 256 | 256 | 256 |
| `qwen35.attention.layer_norm_rms_epsilon` | 1e-6 (9.999999974752427e-07) | same | same |
| `qwen35.rope.freq_base` | 10000000.0 | 10000000.0 | 10000000.0 |
| `qwen35.rope.dimension_count` | 64 | 64 | 64 |
| `qwen35.rope.dimension_sections` | [11, 11, 10, 0] | [11, 11, 10, 0] | [11, 11, 10, 0] |
| `qwen35.full_attention_interval` | 4 | 4 | 4 |
| `qwen35.ssm.conv_kernel` | 4 | 4 | 4 |
| `qwen35.ssm.state_size` | 128 | 128 | 128 |
| `qwen35.ssm.group_count` | 16 | 16 | 16 |
| `qwen35.ssm.time_step_rank` | 48 | 48 | 48 |
| `qwen35.ssm.inner_size` | 6144 | 6144 | 6144 |
| `qwen35.nextn_predict_layers` | **1** | absent | absent |
| `prism.hadamard.*` | absent | present | present |

No `rope.scaling.*` key in any file → plain RoPE at base 1e7, no YaRN/linear scaling. No
`attention.sliding_window`. Relevant prism keys (Bonsai only, quantization transform, not runtime):
`version=1`, `block_size=1024`, `transform=normalized-sylvester-walsh-hadamard`,
`axis=input-last-dimension`, `sign_mode=explicit`, `sign_widths=[5120, 6144, 17408]`,
`sign_values=<array[28672]>`, `weight_names=<array[401]>`,
`inverse_weight_names=['token_embd.weight']`, `gdn_v_grouped=true`.

Tensor type histograms: Qwen — IQ4_XS 432, F32 360, Q5_K 73, Q6_K 1. Bonsai — PQ2_0 402, F32 353, BF16 96.

## 3. Full-attention vs linear-attention layers (counted from tensor names)

Classification rule: a layer is **full attention** if it binds `attn_k.weight`/`attn_v.weight`;
it is **linear attention (gated delta net)** if it binds `attn_qkv.weight` + `ssm_*`.

| file | layers | full attn (tensor names) | linear attn |
|---|---|---|---|
| Qwen IQ4_XS | blk.0–blk.64 (65) | 17 = {3,7,…,63} (16) + **blk.64** | 48 |
| Bonsai PQ2_0 | blk.0–blk.63 (64) | 16 = {3,7,11,…,63} | 48 |
| Bonsai Abliterated | blk.0–blk.63 (64) | 16 = {3,7,11,…,63} | 48 |

Example tensor sets:
- full-attn trunk layer `blk.3.*`: `attn_k.weight, attn_k_norm.weight, attn_norm.weight, attn_output.weight, attn_q.weight, attn_q_norm.weight, attn_v.weight, ffn_down.weight, ffn_gate.weight, ffn_up.weight, post_attention_norm.weight`
- linear layer `blk.0.*`: `attn_gate.weight, attn_norm.weight, attn_qkv.weight, ffn_down.weight, ffn_gate.weight, ffn_up.weight, post_attention_norm.weight, ssm_a, ssm_alpha.weight, ssm_beta.weight, ssm_conv1d.weight, ssm_dt.bias, ssm_norm.weight, ssm_out.weight`

**The 17th full-attn layer in the Qwen file is the MTP/NextN block, not a trunk layer.** Verified in
source, not assumed: `src/models/qwen35.cpp` loads trunk blocks `for i < n_layer` and MTP blocks
`for i = n_layer … n_layer_all`, and `n_layer() = n_layer_all − n_layer_nextn` (`src/llama-hparams.cpp`).
So Qwen: n_layer = 65 − 1 = 64 trunk layers, of which `is_recr_impl[i] = (i + 1) % 4 != 0`
== 48 linear; blk.64 is a dense-attention MTP block excluded from the trunk KV cache
(`llama-model.cpp`: `filter_attn = il < hparams.n_layer() && !is_recr(il)`).

**KV-carrying trunk layers = 16 for every file in this set.**

Shape check (Qwen, IQ4_XS) confirming the metadata is what the cache uses:

| tensor | shape | derived from |
|---|---|---|
| `blk.3.attn_k.weight` | (5120, 1024) | head_count_kv 4 × key_length 256 = 1024 |
| `blk.3.attn_v.weight` | (5120, 1024) | head_count_kv 4 × value_length 256 = 1024 |
| `blk.3.attn_q.weight` | (5120, 12288) | head_count 24 × 256 × 2 (Q + gate) |
| `blk.4.ssm_conv1d.weight` | (4, 10240) | key_dim 2×128×16 = 4096, value_dim 128×48 = 6144 → 10240 |
| `blk.4.ssm_out.weight` | (6144, 5120) | value_dim = 6144 |
| `blk.4.ssm_a` / `blk.4.ssm_dt.bias` | (48,) | time_step_rank |
| `blk.4.ssm_norm.weight` | (128,) | state_size |

## 4. KV-cache bytes

From the dump: `n_embd_k_gqa = head_count_kv × key_length = 4 × 256 = 1024` elements/token/layer,
`n_embd_v_gqa = 4 × 256 = 1024`. This matches the tensor shapes above and `llama-kv-cache.cpp`,
which allocates `ggml_new_tensor_3d(ctx, type_k, n_embd_k_gqa, kv_size, n_stream)` (no extra padding;
1024 is a multiple of both the q8_0 and q4_0 block size of 32).

```
bytes = n_full_attn_layers × n_ctx × head_count_kv × (key_length + value_length) × bytes_per_elem
      = 16 × n_ctx × 4 × (256 + 256) × bpe
      = 16 × n_ctx × 2048 × bpe
```

Per-token cost (16 layers): f16 2048×2×16 = 65,536 B (64.00 KiB) · q8_0 2176×16 = 34,816 B (34.00 KiB) ·
q4_0 1152×16 = 18,432 B (18.00 KiB).

| n_ctx | f16 (2.0 B/elem) | q8_0 (1.0625) | q4_0 (0.5625) |
|---|---|---|---|
| 32,768 | 2,147,483,648 B = **2.0000 GiB** | 1,140,850,688 B = **1.0625 GiB** | 603,979,776 B = **0.5625 GiB** |
| 65,536 | 4,294,967,296 B = **4.0000 GiB** | 2,281,701,376 B = **2.1250 GiB** | 1,207,959,552 B = **1.1250 GiB** |
| 131,072 | 8,589,934,592 B = **8.0000 GiB** | 4,563,402,752 B = **4.2500 GiB** | 2,415,919,104 B = **2.2500 GiB** |
| 262,144 | 17,179,869,184 B = **16.0000 GiB** | 9,126,805,504 B = **8.5000 GiB** | 4,831,838,208 B = **4.5000 GiB** |

Identical for all three files (same head_count_kv/key_length/value_length/16 KV layers). The Qwen
file's MTP block would add a *separate* 1-layer cache if a `LLAMA_CONTEXT_TYPE_MTP` context is used
(add 4.0000 / 2.1250 / 1.1250 GiB at 64K); default serves do not.

## 5. Recurrent SSM state per sequence

Derived from the dump plus `src/llama-memory-recurrent.cpp` + `n_embd_r()/n_embd_s()` in
`src/llama-hparams.cpp`:

```
n_embd_r = (conv_kernel − 1) × (inner_size + 2 × group_count × state_size)
         = (4 − 1) × (6144 + 2 × 16 × 128) = 3 × 10240   =   30,720 elems
n_embd_s = state_size × inner_size = 128 × 6144          =  786,432 elems
per layer, F32 = (30,720 + 786,432) × 4 B = 3,268,608 B  = 3.1172 MiB
× 48 linear layers                        = 156,893,184 B = 149.62 MiB = 0.1461 GiB
```

Rows = `mem_size × (1 + n_rs_seq)`; the hybrid path passes `rs_size = max(1, n_seq_max)` and
`n_rs_seq` defaults to 0 (`llama-context.cpp`), so **the state does not scale with context** — only
with `n_seq_max` (parallel slots): ~0.1461 GiB per sequence. Both recurrent tensors are allocated
`GGML_TYPE_F32` (hardcoded at the hybrid call site in `src/llama-model.cpp`), so `-ctk/-ctv` do not
shrink this. This is why the hybrid layout is cheap at long context: 16 attention layers of KV
instead of 64, region-independent state for the other 48.

## 6. What fits on a 12 GiB card

Budget (the 1.0 GiB compute and 0.4 GiB driver numbers are **assumed**, as specified in the task):

```
card                    12.0   GiB = 12,884,901,888 B
− driver overhead        0.4   GiB =    429,496,730 B
− compute buffer         1.0   GiB =  1,073,741,824 B
= weights + KV budget   10.6   GiB = 11,381,663,334 B
```

| model | weights | headroom for KV+state | fits |
|---|---|---|---|
| Bonsai PQ2_0 6.7009 GiB | 7,195,047,936 B | 4,186,615,398 B = **3.8991 GiB** | yes |
| Bonsai Abliterated 6.7009 GiB | 7,195,047,936 B | 4,186,615,398 B = **3.8991 GiB** | yes |
| Qwen IQ4_XS 14.3512 GiB | 15,409,455,104 B | **−4,027,791,770 B = −3.7512 GiB** | no — does not fit at all |

Bonsai (either file), after subtracting the 0.1461 GiB recurrent state → 4,029,722,214 B = 3.7530 GiB for KV:

| KV type | bytes/token | max ctx (arith) | largest standard ctx that fits | KV bytes at that ctx | total card use |
|---|---|---|---|---|---|
| f16 | 65,536 | floor(4,029,722,214 / 65,536) = **61,488** | 32,768 | 2.0000 GiB | 0.4+1.0+6.7009+0.1461+2.0 = 10.247 GiB |
| q8_0 | 34,816 | floor(4,029,722,214 / 34,816) = **115,743** | 65,536 | 2.1250 GiB | 0.4+1.0+6.7009+0.1461+2.125 = 10.372 GiB |
| q4_0 | 18,432 | floor(4,029,722,214 / 18,432) = **218,650** | 131,072 | 2.2500 GiB | 0.4+1.0+6.7009+0.1461+2.25 = 10.497 GiB |

Bonsai verdict: 64K context at q8_0 KV, or 128K at q4_0 KV, on the card alone with room to spare.
Full native **262,144 does not fit** in any KV type (q4_0 would need 4.5 GiB > 3.7530 GiB headroom;
q8_0 8.5 GiB and f16 16 GiB are far out). Non-powers-of-two are usable up to the "max ctx" column.

Qwen verdict: no context fits while the model is fully resident — the weights alone are 3.75 GiB over
the weights+KV budget, before any KV. Partial offload is required (consistent with the measured
baseline of 40/65 layers on GPU in `llm/BUILD-REPORT.txt`). Arithmetic for a 25-trunk-layer-on-GPU
split: smallest 25 of 65 layers = 5,112,466,048 B, plus 1,718,394,880 B of non-layer tensors
(embedding + output + norms) = 6,830,860,928 B = 6.3617 GiB resident → headroom 4,550,802,406 B
= 4.2383 GiB, minus the 0.1461 GiB recurrent state = 4,393,909,222 B = 4.0921 GiB for KV →
f16 up to floor(4,393,909,222/65,536) = 67,045 tokens (65,536 needs 4.0 GiB, fits),
q8_0 up to 126,203, q4_0 up to 238,384.

## 7. Read vs assumed

Read from the files (GGUF KV key in §2, or tensor names/shapes in §3): architecture, block_count,
context_length, embedding_length, feed_forward_length, head_count, head_count_kv, key_length,
value_length, full_attention_interval, rope.freq_base/dimension_count/dimension_sections,
all `ssm.*`, `nextn_predict_layers`, sampling defaults, file_type, quantization_version,
layer-type census, per-layer tensor shapes, per-type tensor byte totals.

Read from source in this repo (not from the files):
`n_layer() = n_layer_all − n_layer_nextn`; `is_recr_impl[i] = (i + 1) % full_attention_interval != 0`
gated by `i < n_layer()`; KV filter `il < n_layer() && !is_recr(il)`; kv cache tensor = 3-D
`(n_embd_k_gqa, kv_size, n_stream)`, no padding; `n_embd_r()`/`n_embd_s()` formulas; recurrent state
tensors F32; `rs_size = max(1, n_seq_max)`; `n_rs_seq` default 0.

Assumed (given in the task, not derived): bytes_per_elem = 2.0 / 1.0625 / 0.5625; 12 GiB card;
1.0 GiB compute buffer; 0.4 GiB driver overhead. Also assumed: `n_seq_max = 1` (single client, state
row count 1), CUDA-style "bytes = elements × bpe" without allocator slack or per-buffer rounding,
and that no context type is MTP (so blk.64 KV is not allocated). Qwen partial-offload split assumes
the 25 byte-smallest trunk layers plus all non-layer tensors are the resident set.
zRAM/OS-side effects, Vulkan backend overhead, and the 2 GB GT 1030 are out of scope.

## 8. Reproduction

```bash
R=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm
S=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/llm/llama.cpp/gguf-py
P=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/llm/llama.cpp-prism/gguf-py
# stock reader (Qwen only)
PYTHONPATH=$S uv run --with numpy --with pyyaml python dump.py $R/Qwen3.8-27B-OBLITERATED/Qwen3.8-27B-OBLITERATED-IQ4_XS.gguf
# prism fork (PQ2_0 = tensor type 142)
PYTHONPATH=$P uv run --with numpy --with pyyaml python dump.py $R/bonsai/Ternary-Bonsai-2-27B-PQ2_0.gguf
PYTHONPATH=$P uv run --with numpy --with pyyaml python dump.py $R/bonsai-abliterated/Ternary-Bonsai-2-27B-Abliterated-PQ2_0.gguf
```

`dump.py` = `GGUFReader(path)`, print every `r.fields` entry whose key does not start with `tokenizer.`
(arrays capped at 8 shown, e.g. `prism.hadamard.sign_values` is 28,672 long), then histogram
`t.tensor_type.name` and classify `blk.N.*` layers by `attn_k./attn_v.` vs `attn_qkv./ssm_`.
Scratch scripts used for this report: `/home/nexuslink/.hermes/cache/scratch/{gguf_dump2.py,bytes.py,perlayer.py,calc.py}`.
