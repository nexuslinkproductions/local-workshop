#!/usr/bin/env python3
"""count_first_request.py <profile> [model-id]: token count of Chief's first request, CPU only (research/58b section 1 method).

Builds the system prompt with Hermes' own build_system_prompt for the profile (in a scratch HERMES_HOME copy, so the profile is not
touched), renders system + tools + one user turn through the Ornith GGUF's own chat template, and counts it with llama-tokenize on
the GGUF vocabulary (vocab only; Vulkan/CUDA devices hidden). Run through the launcher (it sets up the Hermes python):
  bench/bakeoff42/count_first_request.sh chief-v3-t5
Prints: profile, system chars, tool count, tool-JSON chars, tokens(system alone), tokens(first request).
"""
import json, os, re, shutil, struct, subprocess, sys, tempfile
import yaml, jinja2   # before sys.path gets the hermes-agent dir (it has a yaml/ folder that shadows PyYAML)
from pathlib import Path

LAB = Path.home() / "NEXUS_AI_CENTER/LOCAL-AI-LAB"
GGUF = LAB / "models/llm/ornith-ai/Ornith-1.5-9B-GGUF/Ornith-1.5-9B-Q4_K_M.gguf"
TOK = LAB / "llm/llama.cpp/build/bin/llama-tokenize"
USER = "Where is the speed data for Chief?"   # nav-05, same turn as 58b so the numbers compare
HIDE = {**os.environ, "CUDA_VISIBLE_DEVICES": "", "VK_ICD_FILENAMES": "/nonexistent", "GGML_VK_VISIBLE_DEVICES": "-1",
        "ONEAPI_DEVICE_SELECTOR": "opencl:cpu"}


def gguf_template(path):
    f = open(path, "rb")
    rd = lambda fmt: struct.unpack(fmt, f.read(struct.calcsize(fmt)))
    rstr = lambda: f.read(rd("<Q")[0]).decode("utf8", "replace")
    SZ = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<?", 10: "<Q", 11: "<q", 12: "<d"}

    def val(t):
        if t in SZ: return rd(SZ[t])[0]
        if t == 8: return rstr()
        (et,) = rd("<I"); (n,) = rd("<Q")
        if et in SZ:
            f.seek(struct.calcsize(SZ[et]) * n, 1); return None
        return [val(et) for _ in range(n)]

    f.read(4); rd("<I"); rd("<Q"); (nkv,) = rd("<Q")
    for _ in range(nkv):
        k = rstr(); (t,) = rd("<I"); v = val(t)
        if k == "tokenizer.chat_template": return v
    raise SystemExit("no chat template in GGUF")


def count(text):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, dir=os.environ.get("TMPDIR")) as t:
        t.write(text)
    o = subprocess.run([str(TOK), "-m", str(GGUF), "--file", t.name, "--no-bos", "--show-count", "--log-disable"],
                       capture_output=True, env=HIDE).stdout.decode("utf8", "replace")
    os.unlink(t.name)
    return int(re.findall(r"Total number of tokens: (\d+)", o)[0])


def main():
    prof = Path.home() / ".hermes/profiles" / sys.argv[1]
    model = sys.argv[2] if len(sys.argv) > 2 else "ornith-chief-v3"
    home = Path(tempfile.mkdtemp(prefix="cfr-", dir=os.environ.get("TMPDIR")))
    for name in ("config.yaml", "SOUL.md", "plugins", "memories", ".env"):
        if (prof / name).exists():
            (shutil.copytree if (prof / name).is_dir() else shutil.copy2)(prof / name, home / name)

    cwd = yaml.safe_load((home / "config.yaml").read_text())["terminal"]["cwd"]
    os.environ.update(HERMES_HOME=str(home), TERMINAL_CWD=cwd, CUDA_VISIBLE_DEVICES="")
    sys.path.insert(0, str(Path.home() / ".hermes/hermes-agent")); os.chdir(cwd)
    from run_agent import AIAgent
    from agent.system_prompt import build_system_prompt
    a = AIAgent(base_url="http://127.0.0.1:18080/v1", api_key="dummy", provider="custom", model=model,
                enabled_toolsets=["terminal", "file", "vision", "memory", "web"], quiet_mode=True, platform="cli",
                session_db=None, skip_memory=False)
    system = build_system_prompt(a)
    from jinja2.sandbox import ImmutableSandboxedEnvironment
    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
    env.filters["tojson"] = lambda x, ensure_ascii=False, indent=None, **k: json.dumps(x, ensure_ascii=ensure_ascii, indent=indent)
    def boom(m): raise Exception(m)
    tpl = env.from_string(gguf_template(GGUF))
    msgs = [{"role": "system", "content": system}, {"role": "user", "content": USER}]
    rendered = tpl.render(messages=msgs, tools=a.tools, add_generation_prompt=True, enable_thinking=False, raise_exception=boom)
    print(json.dumps({"profile": sys.argv[1], "cwd": cwd, "tools": [t["function"]["name"] for t in a.tools],
                      "system_chars": len(system), "tools_json_chars": sum(len(json.dumps(t)) for t in a.tools),
                      "tokens_system": count(system), "tokens_first_request": count(rendered)}))
    shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
