#!/usr/bin/env python3
"""ov-bench.py — OpenVINO GenAI LLMPipeline timing on the Arc B580 (GPU).

Measures, per prompt length, N repetitions of a fixed-length generation:
  TTFT (ms, measured by the pipeline) and decode tok/s (= 1000 / TPOT).
KV cache is pinned with MAX_PROMPT_LEN / MIN_RESPONSE_LEN so the model never
allocates its full 40 K context — otherwise a 12 GB card cannot host it next to
the game. Rows go to bench/results-openvino.tsv via results-openvino.py.

Run it under the machine's exclusive GPU mutex, never bare:

    flock -x bench/.gpu.lock \
      engines/openvino/.venv/bin/python bench/ov-bench.py --model models/openvino/Qwen3-4B-int4-ov
"""
import argparse
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module  # noqa: E402  (name has a hyphen)

row = import_module("results-openvino")


def build_prompt(tok, n):
    """A prompt that tokenizes to exactly n tokens (filler repeated, then cut)."""
    filler = "The quick brown fox jumps over the lazy dog while the benchmark runs steadily onward. "
    text = filler * (n // 6 + 64)
    ids = tok.encode(text)[:n]
    return tok.decode(ids)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--device", default="GPU")
    ap.add_argument("--gen", type=int, default=512)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--prompts", default="512,4096")
    ap.add_argument("--quant", default="int4")
    a = ap.parse_args()
    prompts = [int(x) for x in a.prompts.split(",")]

    import openvino_genai as og

    kv_prompt = max(prompts)
    # MAX_PROMPT_LEN / MIN_RESPONSE_LEN are GenAI properties, not device plugins —
    # they go in the config Mapping (3rd arg), not **kwargs (device properties).
    pipe = og.LLMPipeline(a.model, a.device,
                          {"MAX_PROMPT_LEN": kv_prompt,
                           "MIN_RESPONSE_LEN": a.gen + 128})
    tok = pipe.get_tokenizer()
    ver = og.get_version()
    model_name = os.path.basename(os.path.normpath(a.model))

    def gen_cfg(mnt):
        c = og.GenerationConfig()
        c.max_new_tokens = mnt
        c.ignore_eos = True
        c.do_sample = False
        c.temperature = 0.0
        return c

    pipe.generate("Warmup.", gen_cfg(8))          # compile + first-run JIT
    print(f"# openvino-genai {ver} | device={a.device} | model={model_name} "
          f"| gen={a.gen} | reps={a.reps}")

    for pt in prompts:
        prompt = build_prompt(tok, pt)
        ttfts, tps = [], []
        for r in range(a.reps):
            res = pipe.generate(prompt, gen_cfg(a.gen))
            pm = getattr(res, "perf_metrics", None)
            ttft = pm.get_ttft()
            tpot = pm.get_tpot()
            n = pm.get_num_generated_tokens()
            dec = 1000.0 / tpot if tpot else 0.0
            ttfts.append(ttft)
            tps.append(dec)
            print(f"  prompt={pt} run={r + 1} ttft={ttft:.1f}ms decode={dec:.2f}tok/s gen={n}")
        m_ttft, m_tps = statistics.mean(ttfts), statistics.mean(tps)
        sd = lambda v: statistics.stdev(v) if len(v) > 1 else 0.0
        print(f"  MEAN prompt={pt} ttft={m_ttft:.1f}ms(±{sd(ttfts):.1f}) "
              f"decode={m_tps:.2f}tok/s(±{sd(tps):.2f})")
        print("  row:", row.append_row("openvino-genai", ver, model_name, a.quant,
                                       pt, m_ttft, m_tps))


if __name__ == "__main__":
    main()
