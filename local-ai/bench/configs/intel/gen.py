#!/usr/bin/env python3
"""Generate bench/configs/intel/ — one-variable Intel tuning sweep for Qwen3.6-35B-A3B.

Every V*.env / S*.env is its base (V00 / S00) with EXACTLY ONE variable changed
(ENVSH, pointing at an env-*.sh that exports one knob). The generator asserts that.
Run: python3 gen.py    (idempotent; rewrites the directory)
Knobs + citations: research/18-intel-gpu-tuning.md
"""
import os, pathlib

HERE = pathlib.Path(__file__).resolve().parent

BASE_VK = """# INTEL SWEEP BASE - Qwen3.6-35B-A3B, llama.cpp-vulkan-tip (B580 / Mesa ANV).
# Every V*.env is THIS file with exactly one variable changed (ENVSH).
# run: bench/matrix-server.sh --cfg configs/intel/V00-qwen36-vulkan-base.env
ENGINE="llama.cpp-vulkan-tip"
BINDIR="engines/llama.cpp-vulkan-tip/build/bin"
MODEL="models/llm/unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
QUANT="UD-Q4_K_XL"
MMPROJ=""
VISION_ELEMENT=""
NGL=99
NCMOE=48
CTX=65536
KV="q8_0"
THREADS=16
CAP="34G"
PROMPT=512
GEN=128
REPS=3
DEPTHS=""
PLACEMENT="ngl=99/ncmoe=48"
PORT=18082
NP=1
MAXTOK=4096
PROMPT_TOKENS="4096 32768"
ENVSH=""
DEVICE_NAME=""
EXTRA=()
SERVER_EXTRA=(--temp 0 --repeat-penalty 1.05)
"""

BASE_SYCL = BASE_VK.replace(
    'ENGINE="llama.cpp-vulkan-tip"', 'ENGINE="llama.cpp-sycl-tip"'
).replace(
    'BINDIR="engines/llama.cpp-vulkan-tip/build/bin"',
    'BINDIR="engines/llama.cpp-sycl-tip/build/bin"',
).replace(
    'ENVSH=""', 'ENVSH="bench/configs/intel/env-sycl-base.sh"'
).replace(
    'DEVICE_NAME=""', 'DEVICE_NAME="SYCL0"'
)

# (id, slug, exports, citation, note)
VK = [
 ("V01","disable-coopmat2",["GGML_VK_DISABLE_COOPMAT2=1"],
  "ggml-vulkan.cpp:4064,4963","tensor-core path OFF (coopmat2); B580/ANV advertises VK_NV_cooperative_matrix2, so it is ON by default"),
 ("V02","disable-coopmat",["GGML_VK_DISABLE_COOPMAT=1"],
  "ggml-vulkan.cpp:4056,4958","KHR coopmat path OFF"),
 ("V03","disable-dot2",["GGML_VK_DISABLE_DOT2=1"],
  "ggml-vulkan.cpp:4089,4988","VK_VALVE_shader_mixed_float_dot_product OFF (advertised on B580)"),
 ("V04","disable-integer-dot-product",["GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1"],
  "ggml-vulkan.cpp:4072,4971","DP4a/DP2a integer dot OFF"),
 ("V05","disable-bfloat16",["GGML_VK_DISABLE_BFLOAT16=1"],
  "ggml-vulkan.cpp:4077,4976","bf16 path OFF (B580 advertises VK_KHR_shader_bfloat16 + bf16 coopmat)"),
 ("V06","force-mmvq",["GGML_VK_FORCE_MMVQ=1"],
  "ggml-vulkan.cpp:4914","force the quantized mat-vec decode path"),
 ("V07","disable-mmvq",["GGML_VK_DISABLE_MMVQ=1"],
  "ggml-vulkan.cpp:4912","disable mmvq; opposite of V06"),
 ("V08","allow-sysmem-fallback",["GGML_VK_ALLOW_SYSMEM_FALLBACK=1"],
  "ggml-vulkan.cpp:4015","oversubscribe VRAM via host-visible memory; bandwidth cliff risk (research/10 wedged the driver)"),
 ("V09","prefer-host-memory",["GGML_VK_PREFER_HOST_MEMORY=1"],
  "ggml-vulkan.cpp:4009","prefer host memory for device buffers"),
 ("V10","async-transfer-queue",["GGML_VK_ASYNC_USE_TRANSFER_QUEUE=1"],
  "ggml-vulkan.cpp:4882","route copies to the transfer queue (expert uploads)"),
 ("V11","disable-async",["GGML_VK_DISABLE_ASYNC=1"],
  "ggml-vulkan.cpp:4180","async submission OFF (diagnostic baseline)"),
 ("V12","disable-fusion",["GGML_VK_DISABLE_FUSION=1"],
  "ggml-vulkan.cpp:4901","kernel fusion OFF (the Vulkan 'graph' lever)"),
 ("V13","disable-graph-optimize",["GGML_VK_DISABLE_GRAPH_OPTIMIZE=1"],
  "ggml-vulkan.cpp:4018","graph optimisation OFF (diagnostic baseline)"),
 ("V14","max-nodes-per-submit-500",["GGML_VK_MAX_NODES_PER_SUBMIT=500"],
  "ggml-vulkan.cpp:4259","batch more ops per submit (default 100)"),
 ("V15","visible-devices-0",["GGML_VK_VISIBLE_DEVICES=0"],
  "ggml-vulkan.cpp:5274","CUDA_VISIBLE_DEVICES analogue; pin to the B580 only"),
 ("V16","mesa-shader-cache",[
    "MESA_SHADER_CACHE_DIR=/home/nexuslink/.cache/mesa_shader_cache_intel",
    "MESA_SHADER_CACHE_MAX_SIZE=4G"],
  "Mesa envvars (docs.mesa3d.org/envvars.html)","STARTUP lever: persistent ANV pipeline cache; first-token/JIT cost only"),
 ("V17","anv-pipeline-cache-off",["ANV_ENABLE_PIPELINE_CACHE=0"],
  "Mesa envvars","STARTUP/control: force ANV to reparse+recompile every VkShaderModule"),
 ("V18","fa-sparse-disable",["GGML_VK_FA_SPARSE_DISABLE=1"],
  "ggml-vulkan.cpp:8139","Vulkan flash-attn sparse path OFF"),
]

SYCL = [
 ("S01","graph",["GGML_SYCL_ENABLE_GRAPH=1"],
  "ggml-sycl.cpp:419","SYCL graph capture (default 0) - the CUDA-graphs analogue"),
 ("S02","mkl-fa-off",["GGML_SYCL_ENABLE_MKL_FA=0"],
  "ggml-sycl.cpp:423","oneMKL XMX flash-attn prefill OFF -> TILE kernel"),
 ("S03","fa-onednn-off",["GGML_SYCL_FA_ONEDNN=0"],
  "ggml-sycl.cpp:421","oneDNN fused SDPA OFF -> native SYCL FA kernel"),
 ("S04","xmx-gather-off",["GGML_SYCL_XMX_GATHER_TYPES=0"],
  "ggml-sycl.cpp:431","XMX dequant-GEMM paths OFF (the 'tensor cores off' A/B)"),
 ("S05","dynamic-precision-bf16",["GGML_SYCL_DYNAMIC_PRECISION=BF16"],
  "ggml-sycl.cpp:433","XMX operand type BF16 (default F16 with GGML_SYCL_F16=ON)"),
 ("S06","mmvq-wide-off",["GGML_SYCL_MMVQ_WIDE=0"],
  "ggml-sycl.cpp:429","narrow Q8_0 mat-vec loads"),
 ("S07","prioritize-dmmv",["GGML_SYCL_PRIORITIZE_DMMV=1"],
  "ggml-sycl.cpp:430","prioritize dequant-mat-vec"),
 ("S08","upload-staging-8",["GGML_SYCL_UPLOAD_STAGING_SLOTS=8"],
  "ggml-sycl.cpp:462","8 pinned 8MiB staging slots (default 4)"),
 ("S09","host-pinned-off",["GGML_SYCL_ENABLE_HOST_PINNED_MEM=0"],
  "ggml-sycl.cpp:457","pinned host memory OFF (SYCL.md:804 says do this with -lm mlock)"),
 ("S10","level-zero-api-off",["GGML_SYCL_USE_LEVEL_ZERO_API=0"],
  "ggml-sycl.cpp:439","use SYCL instead of direct L0 allocation"),
 ("S11","dev2dev-l0",["GGML_SYCL_DEV2DEV_MEMCPY=1"],
  "ggml-sycl.cpp:443","device-to-device copy via L0 API (faster; crash-prone)"),
 ("S12","sparse-fa",["GGML_SYCL_SPARSE_FA=1"],
  "ggml-sycl.cpp:464","sparse flash-attention ON"),
 ("S13","fusion-off",["GGML_SYCL_ENABLE_FUSION=0"],
  "ggml-sycl.cpp:427","SYCL fused-kernel dispatch OFF"),
 ("S14","usm-system",["GGML_SYCL_USM_SYSTEM=1"],
  "ggml-sycl.cpp:456","USM system allocations for large buffers (Xe2+/BMG, Linux, XE_GPUSVM)"),
 ("S15","cache-persistent",[
    "SYCL_CACHE_PERSISTENT=1",
    "SYCL_CACHE_DIR=/home/nexuslink/.cache/libsycl_cache_intel"],
  "SYCL.md:922-934","STARTUP lever: persistent JIT kernel cache. llama.cpp WARNS against it (stale-cache crashes)"),
 ("S16","immediate-cmdlists-0",["SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=0"],
  "Intel L0 immediate-command-lists guide","force regular cmd lists; B580 = L0 V2 adapter = immediate-only, expect a no-op/refusal"),
 ("S17","fa-onednn-max-kv-24576",["GGML_SYCL_FA_ONEDNN_MAX_KV=24576"],
  "ggml-sycl.cpp:422","cap oneDNN SDPA KV length (DEVICE_LOST mitigation)"),
 ("S18","zes-sysman",["ZES_ENABLE_SYSMAN=1"],
  "SYCL.md:828","enable free-VRAM query (needed for -ngl/--split-mode layer placement)"),
]

def env_file(backend, slug, exports, citation, note):
    if backend == "vk":
        head = [f"# INTEL knob V-{slug}: {' '.join(exports)}",
                f"# {citation} - {note}"]
        body = [f"export {e}" for e in exports]
    else:
        head = [f"# INTEL knob S-{slug}: {' '.join(exports)}",
                f"# {citation} - {note}",
                "# oneAPI prelude must be in the same shell as the binary:"]
        body = ["set +u", '# shellcheck disable=SC1091',
                '. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh']
        body += [f"export {e}" for e in exports] + ["set -u"]
    return "\n".join(head + body) + "\n"

def cfg_text(base, slug, backend, exports, citation, note):
    envsh = f"bench/configs/intel/env-{backend}-{slug}.sh"
    lines = base.splitlines()
    out = []
    for ln in lines:
        if ln.startswith("ENVSH="):
            out.append(f'ENVSH="{envsh}"')
        else:
            out.append(ln)
    # banner comment
    out.insert(0, f"# INTEL SWEEP {slug} - one variable vs the {backend.upper()} base: ENVSH")
    out.insert(1, f"# {' '.join(exports)} ({citation}) - {note}")
    return "\n".join(out) + "\n"

def write(path, text):
    path.write_text(text)
    return path

# --- emit -------------------------------------------------------------------
made = []
# SYCL base env (just the oneAPI prelude)
write(HERE / "env-sycl-base.sh",
      "# INTEL SYCL base prelude: oneAPI env + oneDNN path. No knob.\n"
      "set +u\n# shellcheck disable=SC1091\n"
      ". /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh\n"
      "set -u\n")

write(HERE / "V00-qwen36-vulkan-base.env", BASE_VK); made.append("V00-qwen36-vulkan-base.env")
write(HERE / "S00-qwen36-sycl-base.env", BASE_SYCL); made.append("S00-qwen36-sycl-base.env")

def emit(backend, base, knobs):
    for kid, slug, exports, citation, note in knobs:
        ef = HERE / f"env-{backend}-{slug}.sh"
        write(ef, env_file(backend, slug, exports, citation, note))
        text = cfg_text(base, slug, backend, exports, citation, note)
        cf = HERE / f"{kid}-{slug}.env"
        write(cf, text)
        # assert exactly one variable changed vs base
        b = [l for l in base.splitlines() if not l.startswith("#")]
        c = [l for l in text.splitlines() if not l.startswith("#")]
        diff = [(x, y) for x, y in zip(b, c) if x != y]
        assert len(diff) == 1 and diff[0][0].startswith("ENVSH="), (kid, diff)
        made.append(cf.name)

emit("vk", BASE_VK, VK)
emit("sycl", BASE_SYCL, SYCL)

print(f"wrote {len(made)} configs + {len(VK)+len(SYCL)+1} env files into {HERE}")
print("one-variable assertion: PASS for all knob configs")
