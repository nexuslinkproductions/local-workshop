#!/usr/bin/env python3
"""gguf-meta.py — read a GGUF's key/value header only (no numpy, no model load).

    gguf-meta.py <file.gguf> [key-substring ...]

Prints every metadata key whose name matches any substring (default: a useful
set of architecture keys). Needs only the first few MB of the file, so it works
on a partially-downloaded model. --selftest checks the parser on a local file.
"""
import struct
import sys

WANT = ("block_count", "expert_count", "expert_used_count", "context_length", "head_count",
        "key_length", "value_length", "embedding_length", "split.count", "architecture",
        "file_type", "vision", "name")
# GGUF value type -> struct format (variable-length types handled separately)
FIXED = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?"}
SIZED = {8: None, 9: None, 10: "Q", 11: "q", 12: "d"}


def _str(f):
    n = struct.unpack("<Q", f.read(8))[0]
    return f.read(n).decode("utf-8", "replace")


def _value(f, t):
    if t in FIXED:
        return struct.unpack("<" + FIXED[t], f.read(struct.calcsize(FIXED[t])))[0]
    if t == 8:
        return _str(f)
    if t == 9:
        et = struct.unpack("<I", f.read(4))[0]
        n = struct.unpack("<Q", f.read(8))[0]
        return [_value(f, et) for _ in range(n)]
    if t in SIZED:
        return struct.unpack("<" + SIZED[t], f.read(struct.calcsize(SIZED[t])))[0]
    raise ValueError(f"unknown gguf value type {t}")


def read_kv(path, limit_mb=8):
    out = {}
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic != b"GGUF":
            raise ValueError(f"not a GGUF file: {magic!r}")
        version, = struct.unpack("<I", f.read(4))
        n_tensors, = struct.unpack("<Q", f.read(8))
        n_kv, = struct.unpack("<Q", f.read(8))
        for _ in range(n_kv):
            if f.tell() > limit_mb * 1024 * 1024:
                break
            k = _str(f)
            t, = struct.unpack("<I", f.read(4))
            try:
                out[k] = _value(f, t)
            except Exception as e:
                out[k] = f"<unreadable: {e}>"
                break
    return dict(version=version, n_tensors=n_tensors, n_kv=n_kv, kv=out)


def main():
    path = sys.argv[1]
    wants = [a for a in sys.argv[2:]] or list(WANT)
    info = read_kv(path)
    print(f"{path}: gguf v{info['version']} tensors={info['n_tensors']} kv={info['n_kv']}")
    for k, v in info["kv"].items():
        if any(w.lower() in k.lower() for w in wants):
            print(f"  {k} = {v}")


def selftest():
    import glob
    cands = glob.glob("/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/*/*.gguf") + \
            glob.glob("/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/*/*/*.gguf")
    cands = [c for c in cands if "mmproj" not in c and "compare" not in c]
    assert cands, "no model found for the selftest"
    info = read_kv(cands[0])
    assert info["version"] in (2, 3), info["version"]
    assert info["n_tensors"] > 0 and info["n_kv"] > 0
    arch = [v for k, v in info["kv"].items() if k.endswith("architecture")]
    assert arch and arch[0] != "<unreadable>", info["kv"]
    print(f"selftest ok: {cands[0].split('/')[-1]} arch={arch[0]} tensors={info['n_tensors']}")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        main()
