# 55 — Why built-in MTP costs ~1.6 GB extra VRAM at 256K (Ornith-1.5-9B, SYCL tip)

Engine `engines/llama.cpp-sycl-tip` @ 358a420ec. Read-only source pass (no build, no GPU). GGUF header: 33 blocks (32 trunk + blk.32 MTP), `nextn_predict_layers 1`, `full_attention_interval 4`, n_embd 4096, n_ff 12288, n_head_kv 4, key/value len 256, n_vocab 248320, `qwen35.ssm.*` (hybrid). **No `nextn.embed_tokens` and no `nextn.shared_head_head` tensor exists in the file.**

## 0. Verdict

`--spec-type draft-mtp` builds a **second full `llama_context` on the target's weights, hard-sized to the target's `n_ctx` (262144)**, not a cheap side-car. Cost at 256K: **144.0 MiB** MTP weights blk.32 + **288.0 MiB** draft KV (1 layer × 262144 × 1024 K + 1024 V @ q4_0) + **~1230 MiB** draft compute buffer = **~1666 MiB**, exactly the measured 1124 → −542 delta. It is **not** a duplicated head/embedding (the `vocab 248320 × 4096 × 2 B ≈ 2 GB` hypothesis is refuted in §2), **not** KV (with `-nkvo` the delta is still 1794 MiB, 2821 → 1027), **not** recurrent state. The driver is the draft context's own compute buffer, reserved for the whole 262144-cell cache.

## 1. Where the draft context is created and what params it gets

- `common/speculative.cpp:2600-2657`; self-MTP branch `2645-2656`, `llama_init_from_model(model_tgt, cparams)` at `2650` — **same `llama_model`, so no second weight set**. Caller `tools/server/server-context.cpp:1250-1258`.
- `cparams = common_context_params_to_llama(params_dft)` (`speculative.cpp:2611`), then `ctx_type = LLAMA_CONTEXT_TYPE_MTP` (`2613-2614`), `n_ctx = llama_n_ctx(ctx_tgt)` — hard-set to 262144, no flag (`2618`), `n_rs_seq = 0` (`2622`), `ctx_other = ctx_tgt` (`2623`).
- From `common_base_params_to_speculative` (`2531-2569`): `cache_type_k/v = draft's` (`2563-2564`), `n_outputs_max = n_parallel` (`2565`), `n_outputs_max_per_seq = 1` (`2566`), `moe_cache_size = 0` (`2569`).
- From `common/common.cpp:1710-1748`: `n_seq_max = n_parallel` (1714), `n_batch`/`n_ubatch` (1718-1719), `flash_attn_type` (1734), `offload_kqv = !no_kv_offload` (1737), `type_k/v` (1743-1744). → draft gets **n_ctx 262144, n_seq 1, n_batch/n_ubatch 256, FA on, kqv offload on, q4_0 KV, ctx_type MTP.**
- **`--spec-draft-type-k/-v` DO reach it**: `arg.cpp:4110/4123` → `params.speculative.draft.cache_type_k/v` → `2563-2564` → `cparams.type_k/v`. Default is **F16** (`common/common.h:346-347`).
- **`--spec-draft-ngl` does NOT**: `arg.cpp:4257` sets `params.speculative.draft.n_gpu_layers`, but `common_base_params_to_speculative` copies it only inside `if (has_draft)` (`2546`), and for self-MTP `has_dft()` is false (`common.h:391-393`, `draft.mparams` empty). Same for `--spec-draft-device` (2542-2544), `--spec-draft-override-tensor` (2547), `--spec-draft-cpu-moe`/`-n-cpu-moe` (2547). → matches −566 / −495 vs −542.

## 2. What allocates the ~1.6 GB

- **MTP weights 144.0 MiB.** `load_mtp` is forced on by the spec type (`common/common.cpp:1705`); `nextn_flags` skips the block only when `!load_mtp` (`src/llama-model.cpp:3870-3872`). Exact sum of the 15 blk.32 tensors = 150 980 608 B (`bench/bakeoff42/logs/ornith-9b-direct.server.log:6-20`).
- **No head/embedding duplication.** The GGUF carries neither `blk.32.nextn.embed_tokens` nor `blk.32.nextn.shared_head_head`; `qwen35.cpp:534` / `661` fall back to `model.tok_embd` / `model.output`, which exist once in the shared `llama_model`. 144 + 288 + compute ≈ 1666 leaves no room for a 2 GB copy.
- **Draft KV = one layer.** For `ctx_type == MTP` on `LLAMA_ARCH_QWEN35` the memory is a plain `llama_kv_cache` with `filter = il >= hparams.n_layer()` (`llama-model.cpp:3070-3073`, `3211`, `3217-3218`, built `3277-3293`); `n_layer() == 32` (the MTP index, cf. `3865`), so only blk.32 gets a cache. `n_ctx_seq = 262144`, `n_embd_k_gqa = n_embd_v_gqa = 4×256 = 1024` (`llama-kv-cache.cpp:233-234`) → `262144 × 1024 × 18/32 × 2 = 288.0 MiB` q4_0, **1024.0 MiB at the F16 default**. No recurrent state (hybrid wrapper bypassed for MTP); `mem_other` is `nullptr` here, so no KV sharing.
- **Dominant: the draft context's own compute buffer (~1.2 GB), n_ctx-linear.** `sched_reserve()` reserves against `memory->init_full()` (`llama-context.cpp:746, 774`), whose `n_kv` is the **whole** cache (`llama-kv-cache.cpp:2811-2813`: `n_kv = kv->get_size()`), so the FA KQ mask is `[n_kv = 262144, n_ubatch]` F16 (`llama-graph.cpp:42`) = 128 MiB at ub256, and the graph is reserved for `n_tokens = n_ubatch` (`llama-context.cpp:729`). Same reason the *target's* buffer is n_ctx-linear (`research/34-chief-256k.md:43`: 262144 ub256 681 / ub512 849 / ub1024 1185 MiB) and the draft's ≈ the target's (`research/46-long-context-speed.md` §2: 833.78 vs 848.80 MiB at 262144/ub512; `bench/logs/chief256k/g1-262k-q4-ub512-mmcpu-mtpq4.server.log:185,356`).
- **`-nkvo` cross-check**: with all KV in system RAM the MTP delta stays 1794 MiB (`vram-speedpush-or-nkvo.csv` 2821 vs `vram-speedpush-or-nkvo-mtp2.csv` 1027) — the compute buffer never leaves VRAM.
- **Sharing is impossible here**: the MTP block owns its own `attn_k`/`attn_v` (`qwen35.cpp:104`), so it cannot reuse the target's KV slots the way Gemma-4's assistant head does.

## 3. Every existing flag / env that shrinks it

No MTP-specific size flag exists — there is **no `--spec-draft-ctx-size` / `-cd`** in `common/arg.cpp`.

- `-c`/`--ctx-size` (`arg.cpp:1642`) — the draft `n_ctx` is copied from the target (`2618`); halving `-c` ~halves the buffer.
- `-b`/`--batch-size` (`1672`), `-ub`/`--ubatch-size` (`1679`) — draft inherits both; graph + mask scale with `n_ubatch`.
- `--spec-draft-type-k`/`-ctkd` (`4110`, env `LLAMA_ARG_SPEC_DRAFT_CACHE_TYPE_K`) and `-ctvd` (`4123`, env `LLAMA_ARG_SPEC_DRAFT_CACHE_TYPE_V`) — F16 → q4_0 saves 736 MiB of draft KV.
- `--no-kv-offload`/`-nkvo` (`2418`) — both KVs to host RAM (frees 288 MiB), at ~½ decode (`speed-push.tsv`: 23.6 vs 50.5 t/s).
- `-fit` sizes target + draft together when a draft/MTP context exists (`common/common.cpp:1249-1275`).
- Inert for self-MTP: `--spec-draft-ngl`/`-ngld` (`4257`, env `LLAMA_ARG_N_GPU_LAYERS_DRAFT`), `--spec-draft-device`/`-devd` (`4248`), `--spec-draft-override-tensor`/`-otd` (`4136`), `--spec-draft-cpu-moe` (`4142`), `--spec-draft-n-cpu-moe` (`4149`).

## 4. Smallest code patch (unified diff, NOT applied)

The n_kv term cannot go without bounding the draft `n_ctx`, and the draft KV must still cover the sequence (it ingests every prompt ubatch: `speculative.cpp:1614` → `llama_process(..., DECODE, ...)`, `llama-context.cpp:4695`). Smallest safe lever = the ubatch dimension; the `n_ctx` cap is env-gated so default behaviour is unchanged and reversible.

```diff
--- a/common/speculative.cpp
+++ b/common/speculative.cpp
@@ -2617,6 +2617,15 @@ common_speculative_init_result::common_speculative_init_result(
     // the draft context holds as many tokens per sequence as the target context
     cparams.n_ctx = llama_n_ctx(ctx_tgt);
 
+    if (spec_mtp) {
+        // MTP drafts n_max tokens at a time; a small ubatch shrinks the draft reserve graph,
+        // whose FA KQ mask is [n_kv, n_ubatch] with n_kv = the full target cache
+        // (llama-graph.cpp:42, llama-kv-cache.cpp:2813). Draft KV is left alone.
+        cparams.n_batch  = std::min<uint32_t>(cparams.n_batch,  64);
+        cparams.n_ubatch = std::min<uint32_t>(cparams.n_ubatch, 64);
+        // ponytail: the n_kv term is n_ctx-sized; capping it is only safe when the deployment
+        // bounds the sequence, so opt-in: LLAMA_MTP_DRAFT_CTX=65536 (0/unset = target ctx)
+        const char * cap = getenv("LLAMA_MTP_DRAFT_CTX");
+        if (cap && atoi(cap) > 0) cparams.n_ctx = std::min<uint32_t>(cparams.n_ctx, (uint32_t) atoi(cap));
+    }
+
     // note: for small models maybe we can set this to the maximum possible draft from all speculative types
```

Not done (deliberately): KV sharing MTP↔target (impossible for qwen35) and reserving with a bounded `n_kv` instead of `init_full()` in core `llama.cpp` — the real fix, but not a small diff. Prior work confirmed: `research/46-long-context-speed.md:25` + §2, `research/34-chief-256k.md:43-44`, `research/53-decode-speed-levers.md:93`; `research/00-plan.md:182` (duplicated f16 head ≈ 2 GB) is **refuted** above.
