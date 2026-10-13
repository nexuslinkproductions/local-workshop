#!/usr/bin/env python3
"""pick_ctx.py <main.gguf> [mmproj_bytes] [kv_type]
Pick the largest ctx that leaves >= MIN_FREE MiB VRAM free on the B580.

KV bytes/token = kv_layers * n_head_kv * (key_length + value_length) * bytes_per_elem,
bytes_per_elem: q8_0 1.0625, q4_0 0.5625, f16 2.0 (llama.cpp block overhead included).
kv_layers = n_layer for plain transformers. Hybrid models (qwen35, qwen35moe, qwen3next) keep KV only in
the full-attention layers: llama.cpp src/models/qwen35.cpp marks layer i recurrent unless
(i + 1) % full_attention_interval == 0, so kv_layers = n_layer // full_attention_interval.
Self-check: python3 pick_ctx.py --selftest   (asserts on the Ornith GGUF, then on a non-hybrid GGUF)

Anchor: gemma4-12b (Q4_0 6.50 GiB + mmproj 0.16 GiB) at ctx 65536 q8_0 used 9492 MiB
with 1648 MiB free => practical ceiling (used+free) = 11140 MiB; require free >= 1536 MiB.
"""
import importlib.util, os, sys

LAB = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB"
CEIL_MIB = 11140   # fallback ceiling if the measured idle free is not supplied
MIN_FREE = 1536
OVERHEAD = 320
BPE = {"q8_0": 1.0625, "q4_0": 0.5625, "f16": 2.0, "bf16": 2.0}
PREFERRED = (65536, 49152, 32768)
CANDIDATES = (65536, 49152, 32768, 24576, 16384, 8192)


def load_meta():
    spec = importlib.util.spec_from_file_location("ggufmeta", f"{LAB}/bench/gguf-meta.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def kvget(vals, suffix):
    for k, v in vals.items():
        if k.endswith(suffix) and isinstance(v, int):
            return v
    return None


HYBRID_DEFAULT_INTERVAL = {"qwen35": 4, "qwen35moe": 4, "qwen3next": 4}   # llama.cpp default when the key is absent


def kv_layer_count(kvv, n_layer):
    """Layers that own KV cache. Hybrid (full_attention_interval) models count full-attention layers only."""
    interval = kvget(kvv, "full_attention_interval")
    if not interval:
        interval = HYBRID_DEFAULT_INTERVAL.get(kvv.get("general.architecture"))
    if not interval or interval <= 1:
        return n_layer
    return sum(1 for il in range(n_layer) if (il + 1) % interval == 0)


SELFTEST_ORNITH = f"{LAB}/models/llm/ornith-ai/Ornith-1.5-9B-GGUF/Ornith-1.5-9B-Q4_K_M.gguf"
SELFTEST_PLAIN = f"{LAB}/models/llm/mistralai/Ministral-3-14B-Instruct-2512-GGUF/Ministral-3-14B-Instruct-2512-Q4_K_M.gguf"


def selftest():
    # Ornith-1.5-9B: qwen35, 33 blocks, full_attention_interval 4 -> layers 3,7,...,31 hold KV = 8 layers.
    kvv = load_meta().read_kv(SELFTEST_ORNITH, limit_mb=8)["kv"]
    n_layer = kvget(kvv, "block_count")
    assert kvv["general.architecture"] == "qwen35", kvv.get("general.architecture")
    assert n_layer == 33, n_layer
    assert kvget(kvv, "full_attention_interval") == 4
    assert kv_layer_count(kvv, n_layer) == 8, kv_layer_count(kvv, n_layer)
    per_tok = kv_layer_count(kvv, n_layer) * kvget(kvv, "attention.head_count_kv") * (
        kvget(kvv, "attention.key_length") + kvget(kvv, "attention.value_length")) * BPE["q8_0"]
    assert per_tok == 17408, per_tok      # 17 KB/token at q8_0 (was 71808 with all 33 layers)
    # missing key falls back to the llama.cpp default for the hybrid arch; unknown arch keeps every layer
    assert kv_layer_count({"general.architecture": "qwen35"}, 33) == 8
    assert kv_layer_count({"general.architecture": "llama"}, 33) == 33
    # a non-hybrid model must be untouched
    if os.path.exists(SELFTEST_PLAIN):
        pk = load_meta().read_kv(SELFTEST_PLAIN, limit_mb=8)["kv"]
        nl = kvget(pk, "block_count")
        assert kvget(pk, "full_attention_interval") is None
        assert kv_layer_count(pk, nl) == nl, (kv_layer_count(pk, nl), nl)
    print(f"selftest ok: ornith kv_layers=8/33 bytes/tok(q8_0)={per_tok:.0f}")


def main():
    if "--selftest" in sys.argv[1:]:
        selftest()
        return
    path = sys.argv[1]
    mmproj_mib = float(sys.argv[2]) / 1048576 if len(sys.argv) > 2 else 0.0
    kvtype = sys.argv[3] if len(sys.argv) > 3 else "q8_0"
    ceil = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4].isdigit() else CEIL_MIB
    info = load_meta().read_kv(path, limit_mb=8)
    kvv = info["kv"]
    n_layer = kvget(kvv, "block_count")
    n_head_kv = kvget(kvv, "attention.head_count_kv") or kvget(kvv, "head_count_kv")
    kl = kvget(kvv, "attention.key_length") or kvget(kvv, "key_length")
    vl = kvget(kvv, "attention.value_length") or kvget(kvv, "value_length")
    if not all((n_layer, n_head_kv, kl, vl)):
        print(f"ERR missing hyperparams: layer={n_layer} head_kv={n_head_kv} kl={kl} vl={vl}")
        sys.exit(2)
    main_mib = os.path.getsize(path) / 1048576
    bpe = BPE[kvtype]
    kv_layers = kv_layer_count(kvv, n_layer)
    bytes_per_tok = kv_layers * n_head_kv * (kl + vl) * bpe
    print(f"kv_type={kvtype} layer={n_layer} kv_layers={kv_layers} head_kv={n_head_kv} kl={kl} vl={vl} "
          f"bytes/tok={bytes_per_tok:.0f} main={main_mib:.0f} mmproj={mmproj_mib:.0f} "
          f"ceil={ceil} MiB")
    def free_at(ctx):
        return ceil - (main_mib + mmproj_mib + bytes_per_tok * ctx / 1048576 + OVERHEAD)
    for ctx in CANDIDATES:
        kv_mib = bytes_per_tok * ctx / 1048576
        free = free_at(ctx)
        tag = "OK>=1.5G" if free >= 1536 else ("ok>=1.0G" if free >= 1024 else "too tight")
        star = " *" if ctx in PREFERRED else ""
        print(f"  ctx {ctx:6}: kv={kv_mib:7.1f} used~{ceil-free:7.1f} free~{free:7.1f} {tag}{star}")
    # tier 1: parent's set with >=1.5 GiB free; tier 2: parent's set with >=1.0 GiB (stop line);
    # tier 3: any candidate with >=1.0 GiB; tier 4: max free.
    pick = None
    for cands, thr in ((PREFERRED, 1536), (PREFERRED, 1024), (CANDIDATES, 1024)):
        for ctx in cands:
            if free_at(ctx) >= thr:
                pick = ctx
                break
        if pick:
            break
    if not pick:
        pick = max(CANDIDATES, key=free_at)
    print(f"PICK {pick}")


if __name__ == "__main__":
    main()
