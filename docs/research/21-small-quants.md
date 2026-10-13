# 21 — Small quants: 3-bit and 4-bit GGUFs (Qwen3.6-35B-A3B, MiniCPM-V-4.7-35B-A3B, UI-Venus-1.5-30B-A3B)

Updated 2026-10-13 09:40 (Europe/Vienna). Sizes and sha256 come from the HF API (`/api/models/<repo>/tree/main?recursive=true`: `size`, `lfs.oid`). Raw state: `scratch/s21/state.json`.

## Assumptions and method
- Params: 35.0 B for Qwen3.6-35B-A3B and MiniCPM-V-4.7-35B-A3B, 30.5 B for UI-Venus-1.5-30B-A3B (from model names). bits/weight = size x 8 / params, approximate. MTP files carry the MTP layers and read slightly high.
- Est. RAM need = size in GiB minus 9 GiB, assuming ~9 GiB of the weights sit on the Arc B580 (12 GB) and the rest in system RAM. KV cache not counted.
- Download: `CAP=4G jobcap nice -n 19 ionice -c 3 curl -L -C -`, one file at a time. Gate before each file: MemAvailable >= 12 GiB and io PSI some avg10 <= 5, else wait 60 s. During a download the curl is SIGSTOPped when MemAvailable < 6 GiB or io some avg10 > 25, and resumed at >= 10 GiB and <= 10.
- Verify: exact byte size vs HF API, first 4 bytes = `GGUF`, sha256 vs HF `lfs.oid` (new files and mmproj < 2 GiB). Larger pre-existing files: size + magic only.
- Not touched: GPU, model loads, `bench/.gpu.lock`.

## Downloaded in this run
| model | quant | bits/weight (est.) | size (bytes) | size (GiB) | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|
| Qwen3.6-35B-A3B-GGUF | UD-IQ3_XXS | 3.02 | 13211155424 | 12.30 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf` | PASS (size+magic+sha256) | 3.3 |
| Qwen3.6-35B-A3B-GGUF | UD-Q3_K_XL | 3.85 | 16845511648 | 15.69 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf` | PASS (size+magic+sha256) | 6.7 |
| MiniCPM-V-4.7-35B-A3B-gguf | mix_q3gud_im | 3.54 | 15503944896 | 14.44 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf` | PASS (size+magic+sha256) | 5.4 |
| MiniCPM-V-4.7-35B-A3B-gguf | Q4_K_M | 4.84 | 21166255008 | 19.71 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf` | PASS (size+magic+sha256) | 10.7 |
| UI-Venus-1.5-30B-A3B-i1-GGUF | i1-Q3_K_M | 3.86 | 14711848704 | 13.70 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/mradermacher/UI-Venus-1.5-30B-A3B-i1-GGUF/UI-Venus-1.5-30B-A3B.i1-Q3_K_M.gguf` | PASS (size+magic+sha256) | 4.7 |
| UI-Venus-1.5-30B-A3B-i1-GGUF | i1-Q4_K_M | 4.87 | 18556688128 | 17.28 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/mradermacher/UI-Venus-1.5-30B-A3B-i1-GGUF/UI-Venus-1.5-30B-A3B.i1-Q4_K_M.gguf` | PASS (size+magic+sha256) | 8.3 |
| gemma-4-12B-it-qat-q4_0-gguf | qat-q4_0 | 4.65 | 6975879296 | 6.50 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/gemma-4-12b-it-qat-q4_0.gguf` | PASS (size+magic+sha256) | 0.0 |
| gemma-4-12B-it-qat-q4_0-gguf | qat-q4_0 | 0.12 | 175115616 | 0.16 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/mmproj-gemma-4-12b-it-qat-q4_0.gguf` | PASS (size+magic+sha256) | 0.0 |
| gemma-4-12b-it-GGUF | Q8_0 | 8.45 | 12669647680 | 11.80 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-12b-it-GGUF/gemma-4-12b-it-Q8_0.gguf` | PASS (size+magic+sha256) | 2.8 |
| gemma-4-E4B-it-GGUF | Q4_K_M | n/a | 4977171584 | 4.64 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-E4B-it-GGUF/gemma-4-E4B-it-Q4_K_M.gguf` | PASS (size+magic+sha256) | 0.0 |
| gemma-4-E4B-it-GGUF | mmproj-F16 | n/a | 990372672 | 0.92 | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-E4B-it-GGUF/mmproj-F16.gguf` | PASS (size+magic+sha256) | 0.0 |

## Projectors (mmproj)
| repo | file | bytes | status | local path | verified |
|---|---|---|---|---|---|
| unsloth/Qwen3.6-35B-A3B-GGUF | mmproj-BF16.gguf | 902822624 | not on disk | - | - |
| unsloth/Qwen3.6-35B-A3B-GGUF | mmproj-F16.gguf | 899283680 | already on disk, reused | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/Qwen3.6-35B-A3B-GGUF/mmproj-F16.gguf` | PASS (size+magic+sha256) |
| unsloth/Qwen3.6-35B-A3B-GGUF | mmproj-F32.gguf | 1786305248 | not on disk | - | - |
| unsloth/Qwen3.6-35B-A3B-MTP-GGUF | mmproj-BF16.gguf | 902822528 | not on disk | - | - |
| unsloth/Qwen3.6-35B-A3B-MTP-GGUF | mmproj-F16.gguf | 899283584 | not on disk | - | - |
| unsloth/Qwen3.6-35B-A3B-MTP-GGUF | mmproj-F32.gguf | 1786305152 | not on disk | - | - |
| openbmb/MiniCPM-V-4.7-35B-A3B-gguf | mmproj-model-f16-4x.gguf | 910491648 | already on disk, reused | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/mmproj-model-f16-4x.gguf` | FAIL: sha256 |
| openbmb/MiniCPM-V-4.7-35B-A3B-gguf | mmproj-model-f16.gguf | 1119575840 | already on disk, reused | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/mmproj-model-f16.gguf` | PASS (size+magic+sha256) |
| mradermacher/UI-Venus-1.5-30B-A3B-GGUF | UI-Venus-1.5-30B-A3B.mmproj-Q8_0.gguf | 712149184 | not on disk | - | - |
| mradermacher/UI-Venus-1.5-30B-A3B-GGUF | UI-Venus-1.5-30B-A3B.mmproj-f16.gguf | 1083499840 | already on disk, reused | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/mradermacher/UI-Venus-1.5-30B-A3B-GGUF/UI-Venus-1.5-30B-A3B.mmproj-f16.gguf` | PASS (size+magic+sha256) |
| ggml-org/gemma-4-12B-it-GGUF | mmproj-gemma-4-12B-it-BF16.gguf | 175115616 | not on disk | - | - |
| ggml-org/gemma-4-12B-it-GGUF | mmproj-gemma-4-12B-it-Q8_0.gguf | 158987616 | not on disk | - | - |
| ggml-org/gemma-4-E2B-it-GGUF | mmproj-gemma-4-E2B-it-BF16.gguf | 986833664 | not on disk | - | - |
| ggml-org/gemma-4-E2B-it-GGUF | mmproj-gemma-4-E2B-it-Q8_0.gguf | 557368064 | not on disk | - | - |
| ggml-org/gemma-4-E4B-it-GGUF | mmproj-gemma-4-E4B-it-BF16.gguf | 991552256 | not on disk | - | - |
| ggml-org/gemma-4-E4B-it-GGUF | mmproj-gemma-4-E4B-it-Q8_0.gguf | 559874816 | not on disk | - | - |
| ggml-org/gemma-4-26B-A4B-it-GGUF | mmproj-gemma-4-26B-A4B-it-BF16.gguf | 1194828160 | not on disk | - | - |
| ggml-org/gemma-4-26B-A4B-it-GGUF | mmproj-gemma-4-26B-A4B-it-Q8_0.gguf | 806408320 | not on disk | - | - |
| ggml-org/gemma-4-31B-it-GGUF | mmproj-gemma-4-31B-it-BF16.gguf | 1200726368 | not on disk | - | - |
| ggml-org/gemma-4-31B-it-GGUF | mmproj-gemma-4-31B-it-Q8_0.gguf | 809541728 | not on disk | - | - |
| unsloth/gemma-4-12b-it-GGUF | mmproj-BF16.gguf | 175115840 | not on disk | - | - |
| unsloth/gemma-4-12b-it-GGUF | mmproj-F16.gguf | 175115840 | not on disk | - | - |
| unsloth/gemma-4-12b-it-GGUF | mmproj-F32.gguf | 209522240 | not on disk | - | - |
| unsloth/gemma-4-E2B-it-GGUF | mmproj-BF16.gguf | 986833728 | not on disk | - | - |
| unsloth/gemma-4-E2B-it-GGUF | mmproj-F16.gguf | 985654080 | not on disk | - | - |
| unsloth/gemma-4-E2B-it-GGUF | mmproj-F32.gguf | 1903027008 | not on disk | - | - |
| unsloth/gemma-4-E4B-it-GGUF | mmproj-BF16.gguf | 991552320 | not on disk | - | - |
| unsloth/gemma-4-E4B-it-GGUF | mmproj-F16.gguf | 990372672 | downloaded this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-E4B-it-GGUF/mmproj-F16.gguf` | PASS (size+magic+sha256) |
| unsloth/gemma-4-E4B-it-GGUF | mmproj-F32.gguf | 1912464192 | not on disk | - | - |
| unsloth/gemma-4-26B-A4B-it-GGUF | mmproj-BF16.gguf | 1194828256 | not on disk | - | - |
| unsloth/gemma-4-26B-A4B-it-GGUF | mmproj-F16.gguf | 1193058784 | not on disk | - | - |
| unsloth/gemma-4-26B-A4B-it-GGUF | mmproj-F32.gguf | 2291200480 | not on disk | - | - |
| unsloth/gemma-4-31B-it-GGUF | mmproj-BF16.gguf | 1200726496 | not on disk | - | - |
| unsloth/gemma-4-31B-it-GGUF | mmproj-F16.gguf | 1198957024 | not on disk | - | - |
| unsloth/gemma-4-31B-it-GGUF | mmproj-F32.gguf | 2302996960 | not on disk | - | - |
| unsloth/gemma-4-12B-it-qat-GGUF | mmproj-BF16.gguf | 175115840 | not on disk | - | - |
| unsloth/gemma-4-12B-it-qat-GGUF | mmproj-F16.gguf | 175115840 | not on disk | - | - |
| unsloth/gemma-4-12B-it-qat-GGUF | mmproj-F32.gguf | 209522240 | not on disk | - | - |
| bartowski/gemma-4-12B-it-GGUF | mmproj-gemma-4-12B-it-bf16.gguf | 175115712 | not on disk | - | - |
| bartowski/gemma-4-12B-it-GGUF | mmproj-gemma-4-12B-it-f16.gguf | 122031552 | not on disk | - | - |
| bartowski/google_gemma-4-E2B-it-GGUF | mmproj-google_gemma-4-E2B-it-bf16.gguf | 986833408 | not on disk | - | - |
| bartowski/google_gemma-4-E2B-it-GGUF | mmproj-google_gemma-4-E2B-it-f16.gguf | 985653760 | not on disk | - | - |
| bartowski/google_gemma-4-E4B-it-GGUF | mmproj-google_gemma-4-E4B-it-bf16.gguf | 991552000 | not on disk | - | - |
| bartowski/google_gemma-4-E4B-it-GGUF | mmproj-google_gemma-4-E4B-it-f16.gguf | 990372352 | not on disk | - | - |
| bartowski/google_gemma-4-26B-A4B-it-GGUF | mmproj-google_gemma-4-26B-A4B-it-bf16.gguf | 1194828000 | not on disk | - | - |
| bartowski/google_gemma-4-26B-A4B-it-GGUF | mmproj-google_gemma-4-26B-A4B-it-f16.gguf | 1193058528 | not on disk | - | - |
| bartowski/google_gemma-4-31B-it-GGUF | mmproj-google_gemma-4-31B-it-bf16.gguf | 1200726208 | not on disk | - | - |
| bartowski/google_gemma-4-31B-it-GGUF | mmproj-google_gemma-4-31B-it-f16.gguf | 1198956736 | not on disk | - | - |
| google/gemma-4-12B-it-qat-q4_0-gguf | mmproj-gemma-4-12b-it-qat-q4_0.gguf | 175115616 | downloaded this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/mmproj-gemma-4-12b-it-qat-q4_0.gguf` | PASS (size+magic+sha256) |
| google/gemma-4-E2B-it-qat-q4_0-gguf | gemma-4-E2B-it-mmproj.gguf | 986833664 | not on disk | - | - |
| google/gemma-4-E4B-it-qat-q4_0-gguf | gemma-4-E4B-it-mmproj.gguf | 991552256 | not on disk | - | - |
| google/gemma-4-26B-A4B-it-qat-q4_0-gguf | gemma-4-26B-it-mmproj.gguf | 1194828160 | not on disk | - | - |
| google/gemma-4-31B-it-qat-q4_0-gguf | gemma-4-31B-it-mmproj.gguf | 1200726368 | not on disk | - | - |

## Full quant listing per repo (every main GGUF on HF, sorted by size)
Bits/weight and RAM need are estimates (see assumptions). BF16 is split into two shards; sizes are summed and the row is not downloadable as one file.

### unsloth/Qwen3.6-35B-A3B-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/Qwen3.6-35B-A3B-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| UD-IQ1_M | Qwen3.6-35B-A3B-UD-IQ1_M.gguf | 2.30 | 10047749088 | 9.36 | no | - | - | 0.4 |
| UD-IQ2_XXS | Qwen3.6-35B-A3B-UD-IQ2_XXS.gguf | 2.46 | 10756586464 | 10.02 | no | - | - | 1.0 |
| UD-IQ2_M | Qwen3.6-35B-A3B-UD-IQ2_M.gguf | 2.63 | 11522702304 | 10.73 | no | - | - | 1.7 |
| UD-Q2_K_XL | Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf | 2.81 | 12290628576 | 11.45 | no | - | - | 2.4 |
| UD-IQ3_XXS | Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf | 3.02 | 13211155424 | 12.30 | yes, this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf` | PASS (size+magic+sha256) | 3.3 |
| UD-IQ3_S | Qwen3.6-35B-A3B-UD-IQ3_S.gguf | 3.13 | 13676723168 | 12.74 | no | - | - | 3.7 |
| UD-Q3_K_S | Qwen3.6-35B-A3B-UD-Q3_K_S.gguf | 3.51 | 15359196128 | 14.30 | no | - | - | 5.3 |
| UD-Q3_K_M | Qwen3.6-35B-A3B-UD-Q3_K_M.gguf | 3.79 | 16600710112 | 15.46 | no | - | - | 6.5 |
| UD-Q3_K_XL | Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf | 3.85 | 16845511648 | 15.69 | yes, this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf` | PASS (size+magic+sha256) | 6.7 |
| UD-IQ4_XS | Qwen3.6-35B-A3B-UD-IQ4_XS.gguf | 4.05 | 17730509792 | 16.51 | no | - | - | 7.5 |
| UD-IQ4_NL | Qwen3.6-35B-A3B-UD-IQ4_NL.gguf | 4.12 | 18040888288 | 16.80 | no | - | - | 7.8 |
| UD-IQ4_NL_XL | Qwen3.6-35B-A3B-UD-IQ4_NL_XL.gguf | 4.46 | 19500506080 | 18.16 | no | - | - | 9.2 |
| UD-Q4_K_S | Qwen3.6-35B-A3B-UD-Q4_K_S.gguf | 4.78 | 20893015008 | 19.46 | no | - | - | 10.5 |
| MXFP4_MOE | Qwen3.6-35B-A3B-MXFP4_MOE.gguf | 4.96 | 21706144736 | 20.22 | no | - | - | 11.2 |
| UD-Q4_K_M | Qwen3.6-35B-A3B-UD-Q4_K_M.gguf | 5.06 | 22134528992 | 20.61 | no | - | - | 11.6 |
| UD-Q4_K_XL | Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf | 5.11 | 22360456160 | 20.82 | yes, earlier | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` | PASS (size+magic) | 11.8 |
| UD-Q5_K_S | Qwen3.6-35B-A3B-UD-Q5_K_S.gguf | 5.70 | 24942050272 | 23.23 | no | - | - | 14.2 |
| UD-Q5_K_M | Qwen3.6-35B-A3B-UD-Q5_K_M.gguf | 6.05 | 26456194016 | 24.64 | no | - | - | 15.6 |
| UD-Q5_K_XL | Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf | 6.08 | 26592508896 | 24.77 | no | - | - | 15.8 |
| UD-Q6_K | Qwen3.6-35B-A3B-UD-Q6_K.gguf | 6.70 | 29308320736 | 27.30 | no | - | - | 18.3 |
| UD-Q6_K_XL | Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf | 7.28 | 31843777504 | 29.66 | no | - | - | 20.7 |
| Q8_0 | Qwen3.6-35B-A3B-Q8_0.gguf | 8.44 | 36903140320 | 34.37 | no | - | - | 25.4 |
| UD-Q8_K_XL | Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf | 8.79 | 38451182560 | 35.81 | no | - | - | 26.8 |
| BF16 | Qwen3.6-35B-A3B-BF16-00001-of-00002.gguf, Qwen3.6-35B-A3B-BF16-00002-of-00002.gguf | 15.86 | 69376638176 | 64.61 | no (split) | - | - | 55.6 |

### unsloth/Qwen3.6-35B-A3B-MTP-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/Qwen3.6-35B-A3B-MTP-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| UD-IQ1_M | Qwen3.6-35B-A3B-UD-IQ1_M.gguf | 2.60 | 11366414624 | 10.59 | no | - | - | 1.6 |
| UD-IQ2_XXS | Qwen3.6-35B-A3B-UD-IQ2_XXS.gguf | 2.70 | 11819399456 | 11.01 | no | - | - | 2.0 |
| UD-IQ2_M | Qwen3.6-35B-A3B-UD-IQ2_M.gguf | 2.72 | 11882969376 | 11.07 | no | - | - | 2.1 |
| UD-Q2_K_XL | Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf | 2.87 | 12574128416 | 11.71 | no | - | - | 2.7 |
| UD-IQ3_XXS | Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf | 3.22 | 14069266720 | 13.10 | no | - | - | 4.1 |
| UD-IQ3_S | Qwen3.6-35B-A3B-UD-IQ3_S.gguf | 3.51 | 15346432288 | 14.29 | no | - | - | 5.3 |
| UD-Q3_K_M | Qwen3.6-35B-A3B-UD-Q3_K_M.gguf | 3.91 | 17104402720 | 15.93 | no | - | - | 6.9 |
| UD-Q3_K_XL | Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf | 3.94 | 17227569440 | 16.04 | no | - | - | 7.0 |
| UD-IQ4_XS | Qwen3.6-35B-A3B-UD-IQ4_XS.gguf | 4.16 | 18209036576 | 16.96 | no | - | - | 8.0 |
| UD-IQ4_NL | Qwen3.6-35B-A3B-UD-IQ4_NL.gguf | 4.24 | 18536192288 | 17.26 | no | - | - | 8.3 |
| UD-Q4_K_S | Qwen3.6-35B-A3B-UD-Q4_K_S.gguf | 4.89 | 21388319008 | 19.92 | no | - | - | 10.9 |
| MXFP4_MOE | Qwen3.6-35B-A3B-MXFP4_MOE.gguf | 5.07 | 22182574368 | 20.66 | no | - | - | 11.7 |
| UD-Q4_K_M | Qwen3.6-35B-A3B-UD-Q4_K_M.gguf | 5.18 | 22663387424 | 21.11 | no | - | - | 12.1 |
| UD-Q4_K_XL | Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf | 5.22 | 22853663008 | 21.28 | yes, earlier | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` | PASS (size+magic) | 12.3 |
| UD-Q5_K_S | Qwen3.6-35B-A3B-UD-Q5_K_S.gguf | 5.84 | 25538017568 | 23.78 | no | - | - | 14.8 |
| UD-Q5_K_M | Qwen3.6-35B-A3B-UD-Q5_K_M.gguf | 6.19 | 27087812896 | 25.23 | no | - | - | 16.2 |
| UD-Q5_K_XL | Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf | 6.21 | 27159116064 | 25.29 | no | - | - | 16.3 |
| UD-Q6_K | Qwen3.6-35B-A3B-UD-Q6_K.gguf | 6.86 | 30011242784 | 27.95 | no | - | - | 19.0 |
| UD-Q6_K_XL | Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf | 7.45 | 32611711264 | 30.37 | no | - | - | 21.4 |
| Q8_0 | Qwen3.6-35B-A3B-Q8_0.gguf | 8.64 | 37801097504 | 35.21 | no | - | - | 26.2 |
| UD-Q8_K_XL | Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf | 8.94 | 39099447584 | 36.41 | no | - | - | 27.4 |
| BF16 | Qwen3.6-35B-A3B-BF16-00001-of-00002.gguf, Qwen3.6-35B-A3B-BF16-00002-of-00002.gguf | 16.24 | 71065942560 | 66.19 | no (split) | - | - | 57.2 |

### openbmb/MiniCPM-V-4.7-35B-A3B-gguf
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| mix_q3gud_im | MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf | 3.54 | 15503944896 | 14.44 | yes, this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf` | PASS (size+magic+sha256) | 5.4 |
| Q4_0 | MiniCPM-V-4_7-35B-A3B-Q4_0.gguf | 4.51 | 19714550688 | 18.36 | no | - | - | 9.4 |
| Q4_K_S | MiniCPM-V-4_7-35B-A3B-Q4_K_S.gguf | 4.55 | 19889400736 | 18.52 | no | - | - | 9.5 |
| Q4_K_M | MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf | 4.84 | 21166255008 | 19.71 | yes, this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf` | PASS (size+magic+sha256) | 10.7 |
| Q4_1 | MiniCPM-V-4_7-35B-A3B-Q4_1.gguf | 4.99 | 21847643040 | 20.35 | no | - | - | 11.3 |
| Q5_0 | MiniCPM-V-4_7-35B-A3B-Q5_0.gguf | 5.48 | 23980735392 | 22.33 | no | - | - | 13.3 |
| Q5_K_S | MiniCPM-V-4_7-35B-A3B-Q5_K_S.gguf | 5.48 | 23980735392 | 22.33 | no | - | - | 13.3 |
| Q5_K_M | MiniCPM-V-4_7-35B-A3B-Q5_K_M.gguf | 5.65 | 24728583072 | 23.03 | no | - | - | 14.0 |
| Q5_1 | MiniCPM-V-4_7-35B-A3B-Q5_1.gguf | 5.97 | 26113827744 | 24.32 | no | - | - | 15.3 |
| Q6_K | MiniCPM-V-4_7-35B-A3B-Q6_K.gguf | 6.52 | 28513556640 | 26.56 | no | - | - | 17.6 |
| Q8_0 | MiniCPM-V-4_7-35B-A3B-Q8_0.gguf | 8.43 | 36902368928 | 34.37 | yes, earlier | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/MiniCPM-V-4_7-35B-A3B-Q8_0.gguf` | FAIL: size (+32 bytes vs HF) | 25.4 |
| F16 | MiniCPM-V-4_7-35B-A3B-F16.gguf | 15.86 | 69375191008 | 64.61 | no | - | - | 55.6 |

### mradermacher/UI-Venus-1.5-30B-A3B-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/mradermacher/UI-Venus-1.5-30B-A3B-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| Q2_K | UI-Venus-1.5-30B-A3B.Q2_K.gguf | 2.95 | 11258611168 | 10.49 | no | - | - | 1.5 |
| Q3_K_S | UI-Venus-1.5-30B-A3B.Q3_K_S.gguf | 3.49 | 13292469728 | 12.38 | no | - | - | 3.4 |
| Q3_K_M | UI-Venus-1.5-30B-A3B.Q3_K_M.gguf | 3.86 | 14711848416 | 13.70 | no | - | - | 4.7 |
| Q3_K_L | UI-Venus-1.5-30B-A3B.Q3_K_L.gguf | 4.17 | 15900671456 | 14.81 | no | - | - | 5.8 |
| IQ4_XS | UI-Venus-1.5-30B-A3B.IQ4_XS.gguf | 4.34 | 16557094368 | 15.42 | no | - | - | 6.4 |
| Q4_K_S | UI-Venus-1.5-30B-A3B.Q4_K_S.gguf | 4.58 | 17456010720 | 16.26 | no | - | - | 7.3 |
| Q4_K_M | UI-Venus-1.5-30B-A3B.Q4_K_M.gguf | 4.87 | 18556687840 | 17.28 | no | - | - | 8.3 |
| Q5_K_S | UI-Venus-1.5-30B-A3B.Q5_K_S.gguf | 5.53 | 21080511968 | 19.63 | no | - | - | 10.6 |
| Q5_K_M | UI-Venus-1.5-30B-A3B.Q5_K_M.gguf | 5.70 | 21725582816 | 20.23 | no | - | - | 11.2 |
| Q6_K | UI-Venus-1.5-30B-A3B.Q6_K.gguf | 6.58 | 25092533728 | 23.37 | no | - | - | 14.4 |
| Q8_0 | UI-Venus-1.5-30B-A3B.Q8_0.gguf | 8.52 | 32483933664 | 30.25 | yes, earlier | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/mradermacher/UI-Venus-1.5-30B-A3B-GGUF/UI-Venus-1.5-30B-A3B.Q8_0.gguf` | PASS (size+magic) | 21.3 |

### mradermacher/UI-Venus-1.5-30B-A3B-i1-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/mradermacher/UI-Venus-1.5-30B-A3B-i1-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| i1-IQ1_S | UI-Venus-1.5-30B-A3B.i1-IQ1_S.gguf | 1.68 | 6416510720 | 5.98 | no | - | - | 0.0 |
| i1-IQ1_M | UI-Venus-1.5-30B-A3B.i1-IQ1_M.gguf | 1.86 | 7078293248 | 6.59 | no | - | - | 0.0 |
| i1-IQ2_XXS | UI-Venus-1.5-30B-A3B.i1-IQ2_XXS.gguf | 2.15 | 8181264128 | 7.62 | no | - | - | 0.0 |
| i1-IQ2_XS | UI-Venus-1.5-30B-A3B.i1-IQ2_XS.gguf | 2.38 | 9076223744 | 8.45 | no | - | - | 0.0 |
| i1-IQ2_S | UI-Venus-1.5-30B-A3B.i1-IQ2_S.gguf | 2.44 | 9287132928 | 8.65 | no | - | - | 0.0 |
| i1-IQ2_M | UI-Venus-1.5-30B-A3B.i1-IQ2_M.gguf | 2.67 | 10169509632 | 9.47 | no | - | - | 0.5 |
| i1-Q2_K_S | UI-Venus-1.5-30B-A3B.i1-Q2_K_S.gguf | 2.76 | 10519365376 | 9.80 | no | - | - | 0.8 |
| i1-Q2_K | UI-Venus-1.5-30B-A3B.i1-Q2_K.gguf | 2.95 | 11258611456 | 10.49 | no | - | - | 1.5 |
| i1-IQ3_XXS | UI-Venus-1.5-30B-A3B.i1-IQ3_XXS.gguf | 3.11 | 11849328384 | 11.04 | no | - | - | 2.0 |
| i1-IQ3_XS | UI-Venus-1.5-30B-A3B.i1-IQ3_XS.gguf | 3.30 | 12598443776 | 11.73 | no | - | - | 2.7 |
| i1-Q3_K_S | UI-Venus-1.5-30B-A3B.i1-Q3_K_S.gguf | 3.49 | 13292470016 | 12.38 | no | - | - | 3.4 |
| i1-IQ3_S | UI-Venus-1.5-30B-A3B.i1-IQ3_S.gguf | 3.49 | 13299154688 | 12.39 | no | - | - | 3.4 |
| i1-IQ3_M | UI-Venus-1.5-30B-A3B.i1-IQ3_M.gguf | 3.54 | 13513064192 | 12.59 | no | - | - | 3.6 |
| i1-Q3_K_M | UI-Venus-1.5-30B-A3B.i1-Q3_K_M.gguf | 3.86 | 14711848704 | 13.70 | yes, this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/mradermacher/UI-Venus-1.5-30B-A3B-i1-GGUF/UI-Venus-1.5-30B-A3B.i1-Q3_K_M.gguf` | PASS (size+magic+sha256) | 4.7 |
| i1-Q3_K_L | UI-Venus-1.5-30B-A3B.i1-Q3_K_L.gguf | 4.17 | 15900671744 | 14.81 | no | - | - | 5.8 |
| i1-IQ4_XS | UI-Venus-1.5-30B-A3B.i1-IQ4_XS.gguf | 4.29 | 16368350976 | 15.24 | no | - | - | 6.2 |
| i1-Q4_0 | UI-Venus-1.5-30B-A3B.i1-Q4_0.gguf | 4.56 | 17379989248 | 16.19 | no | - | - | 7.2 |
| i1-Q4_K_S | UI-Venus-1.5-30B-A3B.i1-Q4_K_S.gguf | 4.58 | 17456011008 | 16.26 | no | - | - | 7.3 |
| i1-Q4_K_M | UI-Venus-1.5-30B-A3B.i1-Q4_K_M.gguf | 4.87 | 18556688128 | 17.28 | yes, this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/mradermacher/UI-Venus-1.5-30B-A3B-i1-GGUF/UI-Venus-1.5-30B-A3B.i1-Q4_K_M.gguf` | PASS (size+magic+sha256) | 8.3 |
| i1-Q4_1 | UI-Venus-1.5-30B-A3B.i1-Q4_1.gguf | 5.03 | 19192502016 | 17.87 | no | - | - | 8.9 |
| i1-Q5_K_S | UI-Venus-1.5-30B-A3B.i1-Q5_K_S.gguf | 5.53 | 21080512256 | 19.63 | no | - | - | 10.6 |
| i1-Q5_K_M | UI-Venus-1.5-30B-A3B.i1-Q5_K_M.gguf | 5.70 | 21725583104 | 20.23 | no | - | - | 11.2 |
| i1-Q6_K | UI-Venus-1.5-30B-A3B.i1-Q6_K.gguf | 6.58 | 25092534016 | 23.37 | no | - | - | 14.4 |

## Gemma 4 family (added on request)
Members: E2B, E4B, 12B (dense), 26B-A4B (MoE), 31B (dense). Per-repo listings below with exact sizes.
Downloaded (only these):
- 12B QAT (official Google, preferred): `google/gemma-4-12B-it-qat-q4_0-gguf` -> `gemma-4-12b-it-qat-q4_0.gguf` + vision projector `mmproj-gemma-4-12b-it-qat-q4_0.gguf`.
- 12B Q8_0 (kept from the earlier request): `unsloth/gemma-4-12b-it-GGUF` -> `gemma-4-12b-it-Q8_0.gguf`.
- E4B fallback: `unsloth/gemma-4-E4B-it-GGUF` -> `gemma-4-E4B-it-Q4_K_M.gguf` + projector `mmproj-F16.gguf`.
Skipped by instruction: 26B-A4B and 31B (listed, not downloaded).
Audio: HF tags E2B/E4B/12B as any-to-any. No separate audio projector file appears in the listings (mmproj only), so audio input is unverified.
Params: 12B, 26B, 31B from model names; E2B/E4B bits/weight n/a (effective-parameter architecture).

### ggml-org/gemma-4-12B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/ggml-org/gemma-4-12B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| Q4_0 | gemma-4-12B-it-Q4_0.gguf | 4.81 | 7219673216 | 6.72 | no | - | - | 0.0 |
| Q8_0 | gemma-4-12B-it-Q8_0.gguf | 8.45 | 12669646976 | 11.80 | no | - | - | 2.8 |
| BF16 | gemma-4-12B-it-BF16.gguf | 15.89 | 23832066176 | 22.20 | no | - | - | 13.2 |

### ggml-org/gemma-4-E2B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/ggml-org/gemma-4-E2B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| Q4_0 | gemma-4-E2B-it-Q4_0.gguf | n/a | 2841481184 | 2.65 | no | - | - | 0.0 |
| Q8_0 | gemma-4-E2B-it-Q8_0.gguf | n/a | 4967497152 | 4.63 | no | - | - | 0.0 |
| BF16 | gemma-4-E2B-it-BF16.gguf | n/a | 9311305152 | 8.67 | no | - | - | 0.0 |

### ggml-org/gemma-4-E4B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/ggml-org/gemma-4-E4B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| Q4_0 | gemma-4-E4B-it-Q4_0.gguf | n/a | 4590807392 | 4.28 | no | - | - | 0.0 |
| Q8_0 | gemma-4-E4B-it-Q8_0.gguf | n/a | 8031242688 | 7.48 | no | - | - | 0.0 |
| BF16 | gemma-4-E4B-it-BF16.gguf | n/a | 15053097408 | 14.02 | no | - | - | 5.0 |

### ggml-org/gemma-4-26B-A4B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/ggml-org/gemma-4-26B-A4B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| Q4_0 | gemma-4-26B-A4B-it-Q4_0.gguf | 4.50 | 14618145824 | 13.61 | no | - | - | 4.6 |
| Q8_0 | gemma-4-26B-A4B-it-Q8_0.gguf | 8.26 | 26859860992 | 25.02 | no | - | - | 16.0 |
| BF16 | gemma-4-26B-A4B-it-BF16.gguf | 15.54 | 50505137152 | 47.04 | no | - | - | 38.0 |

### ggml-org/gemma-4-31B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/ggml-org/gemma-4-31B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| Q4_0 | gemma-4-31B-it-Q4_0.gguf | 4.64 | 17992313088 | 16.76 | no | - | - | 7.8 |
| Q8_0 | gemma-4-31B-it-Q8_0.gguf | 8.42 | 32635676896 | 30.39 | no | - | - | 21.4 |
| BF16 | gemma-4-31B-it-BF16.gguf | 15.85 | 61413189856 | 57.20 | no | - | - | 48.2 |

### unsloth/gemma-4-12b-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-12b-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| UD-IQ2_M | gemma-4-12b-it-UD-IQ2_M.gguf | 2.81 | 4213353280 | 3.92 | no | - | - | 0.0 |
| UD-IQ3_XXS | gemma-4-12b-it-UD-IQ3_XXS.gguf | 3.09 | 4639716160 | 4.32 | no | - | - | 0.0 |
| UD-Q2_K_XL | gemma-4-12b-it-UD-Q2_K_XL.gguf | 3.11 | 4661419840 | 4.34 | no | - | - | 0.0 |
| Q3_K_S | gemma-4-12b-it-Q3_K_S.gguf | 3.42 | 5135014720 | 4.78 | no | - | - | 0.0 |
| Q3_K_M | gemma-4-12b-it-Q3_K_M.gguf | 3.80 | 5693872960 | 5.30 | no | - | - | 0.0 |
| UD-Q3_K_XL | gemma-4-12b-it-UD-Q3_K_XL.gguf | 4.02 | 6022684480 | 5.61 | no | - | - | 0.0 |
| IQ4_XS | gemma-4-12b-it-IQ4_XS.gguf | 4.25 | 6375734080 | 5.94 | no | - | - | 0.0 |
| IQ4_NL | gemma-4-12b-it-IQ4_NL.gguf | 4.48 | 6716357440 | 6.26 | no | - | - | 0.0 |
| Q4_0 | gemma-4-12b-it-Q4_0.gguf | 4.49 | 6738475840 | 6.28 | no | - | - | 0.0 |
| Q4_K_S | gemma-4-12b-it-Q4_K_S.gguf | 4.51 | 6764526400 | 6.30 | no | - | - | 0.0 |
| Q4_K_M | gemma-4-12b-it-Q4_K_M.gguf | 4.75 | 7121861440 | 6.63 | no | - | - | 0.0 |
| UD-Q4_K_XL | gemma-4-12b-it-UD-Q4_K_XL.gguf | 4.91 | 7366423360 | 6.86 | no | - | - | 0.0 |
| Q4_1 | gemma-4-12b-it-Q4_1.gguf | 4.93 | 7397604160 | 6.89 | no | - | - | 0.0 |
| Q5_K_S | gemma-4-12b-it-Q5_K_S.gguf | 5.47 | 8204680000 | 7.64 | no | - | - | 0.0 |
| Q5_K_M | gemma-4-12b-it-Q5_K_M.gguf | 5.61 | 8413576000 | 7.84 | no | - | - | 0.0 |
| UD-Q5_K_XL | gemma-4-12b-it-UD-Q5_K_XL.gguf | 5.74 | 8606021440 | 8.01 | no | - | - | 0.0 |
| Q6_K | gemma-4-12b-it-Q6_K.gguf | 6.52 | 9786022720 | 9.11 | no | - | - | 0.1 |
| UD-Q6_K_XL | gemma-4-12b-it-UD-Q6_K_XL.gguf | 7.12 | 10685012800 | 9.95 | no | - | - | 1.0 |
| Q8_0 | gemma-4-12b-it-Q8_0.gguf | 8.45 | 12669647680 | 11.80 | yes, this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-12b-it-GGUF/gemma-4-12b-it-Q8_0.gguf` | PASS (size+magic+sha256) | 2.8 |
| UD-Q8_K_XL | gemma-4-12b-it-UD-Q8_K_XL.gguf | 9.09 | 13637327680 | 12.70 | no | - | - | 3.7 |
| BF16 | gemma-4-12b-it-BF16.gguf | 15.89 | 23832066656 | 22.20 | no | - | - | 13.2 |

### unsloth/gemma-4-E2B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-E2B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| UD-IQ2_M | gemma-4-E2B-it-UD-IQ2_M.gguf | n/a | 2290860128 | 2.13 | no | - | - | 0.0 |
| UD-IQ3_XXS | gemma-4-E2B-it-UD-IQ3_XXS.gguf | n/a | 2372993120 | 2.21 | no | - | - | 0.0 |
| UD-Q2_K_XL | gemma-4-E2B-it-UD-Q2_K_XL.gguf | n/a | 2403614816 | 2.24 | no | - | - | 0.0 |
| Q3_K_S | gemma-4-E2B-it-Q3_K_S.gguf | n/a | 2445652064 | 2.28 | no | - | - | 0.0 |
| Q3_K_M | gemma-4-E2B-it-Q3_K_M.gguf | n/a | 2536786016 | 2.36 | no | - | - | 0.0 |
| UD-Q3_K_XL | gemma-4-E2B-it-UD-Q3_K_XL.gguf | n/a | 2923782240 | 2.72 | no | - | - | 0.0 |
| IQ4_XS | gemma-4-E2B-it-IQ4_XS.gguf | n/a | 2983944288 | 2.78 | no | - | - | 0.0 |
| IQ4_NL | gemma-4-E2B-it-IQ4_NL.gguf | n/a | 3041083488 | 2.83 | no | - | - | 0.0 |
| Q4_0 | gemma-4-E2B-it-Q4_0.gguf | n/a | 3041378400 | 2.83 | no | - | - | 0.0 |
| Q4_K_S | gemma-4-E2B-it-Q4_K_S.gguf | n/a | 3043934304 | 2.83 | no | - | - | 0.0 |
| Q4_K_M | gemma-4-E2B-it-Q4_K_M.gguf | n/a | 3106738272 | 2.89 | no | - | - | 0.0 |
| Q4_1 | gemma-4-E2B-it-Q4_1.gguf | n/a | 3154919520 | 2.94 | no | - | - | 0.0 |
| UD-Q4_K_XL | gemma-4-E2B-it-UD-Q4_K_XL.gguf | n/a | 3184496736 | 2.97 | no | - | - | 0.0 |
| Q5_K_S | gemma-4-E2B-it-Q5_K_S.gguf | n/a | 3321151584 | 3.09 | no | - | - | 0.0 |
| Q5_K_M | gemma-4-E2B-it-Q5_K_M.gguf | n/a | 3356037216 | 3.13 | no | - | - | 0.0 |
| UD-Q5_K_XL | gemma-4-E2B-it-UD-Q5_K_XL.gguf | n/a | 4294176864 | 4.00 | no | - | - | 0.0 |
| Q6_K | gemma-4-E2B-it-Q6_K.gguf | n/a | 4501721184 | 4.19 | no | - | - | 0.0 |
| UD-Q6_K_XL | gemma-4-E2B-it-UD-Q6_K_XL.gguf | n/a | 4710088800 | 4.39 | no | - | - | 0.0 |
| Q8_0 | gemma-4-E2B-it-Q8_0.gguf | n/a | 5048352864 | 4.70 | no | - | - | 0.0 |
| UD-Q8_K_XL | gemma-4-E2B-it-UD-Q8_K_XL.gguf | n/a | 5282807904 | 4.92 | no | - | - | 0.0 |
| BF16 | gemma-4-E2B-it-BF16.gguf | n/a | 9311305568 | 8.67 | no | - | - | 0.0 |

### unsloth/gemma-4-E4B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-E4B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| UD-IQ2_M | gemma-4-E4B-it-UD-IQ2_M.gguf | n/a | 3545083008 | 3.30 | no | - | - | 0.0 |
| UD-IQ3_XXS | gemma-4-E4B-it-UD-IQ3_XXS.gguf | n/a | 3717115008 | 3.46 | no | - | - | 0.0 |
| UD-Q2_K_XL | gemma-4-E4B-it-UD-Q2_K_XL.gguf | n/a | 3757419648 | 3.50 | no | - | - | 0.0 |
| Q3_K_S | gemma-4-E4B-it-Q3_K_S.gguf | n/a | 3862379648 | 3.60 | no | - | - | 0.0 |
| Q3_K_M | gemma-4-E4B-it-Q3_K_M.gguf | n/a | 4058137728 | 3.78 | no | - | - | 0.0 |
| UD-Q3_K_XL | gemma-4-E4B-it-UD-Q3_K_XL.gguf | n/a | 4588440704 | 4.27 | no | - | - | 0.0 |
| IQ4_XS | gemma-4-E4B-it-IQ4_XS.gguf | n/a | 4715416704 | 4.39 | no | - | - | 0.0 |
| IQ4_NL | gemma-4-E4B-it-IQ4_NL.gguf | n/a | 4835839104 | 4.50 | no | - | - | 0.0 |
| Q4_0 | gemma-4-E4B-it-Q4_0.gguf | n/a | 4836002944 | 4.50 | no | - | - | 0.0 |
| Q4_K_S | gemma-4-E4B-it-Q4_K_S.gguf | n/a | 4844850304 | 4.51 | no | - | - | 0.0 |
| Q4_K_M | gemma-4-E4B-it-Q4_K_M.gguf | n/a | 4977171584 | 4.64 | yes, this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-E4B-it-GGUF/gemma-4-E4B-it-Q4_K_M.gguf` | PASS (size+magic+sha256) | 0.0 |
| Q4_1 | gemma-4-E4B-it-Q4_1.gguf | n/a | 5074390144 | 4.73 | no | - | - | 0.0 |
| UD-Q4_K_XL | gemma-4-E4B-it-UD-Q4_K_XL.gguf | n/a | 5126306944 | 4.77 | no | - | - | 0.0 |
| Q5_K_S | gemma-4-E4B-it-Q5_K_S.gguf | n/a | 5404855424 | 5.03 | no | - | - | 0.0 |
| Q5_K_M | gemma-4-E4B-it-Q5_K_M.gguf | n/a | 5481798784 | 5.11 | no | - | - | 0.0 |
| UD-Q5_K_XL | gemma-4-E4B-it-UD-Q5_K_XL.gguf | n/a | 6656154752 | 6.20 | no | - | - | 0.0 |
| Q6_K | gemma-4-E4B-it-Q6_K.gguf | n/a | 7074929792 | 6.59 | no | - | - | 0.0 |
| UD-Q6_K_XL | gemma-4-E4B-it-UD-Q6_K_XL.gguf | n/a | 7457762432 | 6.95 | no | - | - | 0.0 |
| Q8_0 | gemma-4-E4B-it-Q8_0.gguf | n/a | 8192953472 | 7.63 | no | - | - | 0.0 |
| UD-Q8_K_XL | gemma-4-E4B-it-UD-Q8_K_XL.gguf | n/a | 8711507072 | 8.11 | no | - | - | 0.0 |
| BF16 | gemma-4-E4B-it-BF16.gguf | n/a | 15053097856 | 14.02 | no | - | - | 5.0 |

### unsloth/gemma-4-26B-A4B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-26B-A4B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| UD-IQ2_XXS | gemma-4-26B-A4B-it-UD-IQ2_XXS.gguf | 3.05 | 9922480608 | 9.24 | no | - | - | 0.2 |
| UD-IQ2_M | gemma-4-26B-A4B-it-UD-IQ2_M.gguf | 3.08 | 10014755296 | 9.33 | no | - | - | 0.3 |
| UD-Q2_K_XL | gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf | 3.25 | 10546934240 | 9.82 | no | - | - | 0.8 |
| UD-IQ3_S | gemma-4-26B-A4B-it-UD-IQ3_S.gguf | 3.47 | 11289671136 | 10.51 | no | - | - | 1.5 |
| UD-IQ3_XXS | gemma-4-26B-A4B-it-UD-IQ3_XXS.gguf | 3.51 | 11416548832 | 10.63 | no | - | - | 1.6 |
| UD-Q3_K_M | gemma-4-26B-A4B-it-UD-Q3_K_M.gguf | 3.92 | 12728497888 | 11.85 | no | - | - | 2.9 |
| UD-Q3_K_XL | gemma-4-26B-A4B-it-UD-Q3_K_XL.gguf | 3.97 | 12907280096 | 12.02 | no | - | - | 3.0 |
| UD-IQ4_XS | gemma-4-26B-A4B-it-UD-IQ4_XS.gguf | 4.18 | 13597177568 | 12.66 | no | - | - | 3.7 |
| UD-IQ4_NL | gemma-4-26B-A4B-it-UD-IQ4_NL.gguf | 4.19 | 13613037280 | 12.68 | no | - | - | 3.7 |
| UD-Q4_K_S | gemma-4-26B-A4B-it-UD-Q4_K_S.gguf | 5.07 | 16487610080 | 15.36 | no | - | - | 6.4 |
| MXFP4_MOE | gemma-4-26B-A4B-it-MXFP4_MOE.gguf | 5.09 | 16551048928 | 15.41 | no | - | - | 6.4 |
| UD-Q4_K_M | gemma-4-26B-A4B-it-UD-Q4_K_M.gguf | 5.21 | 16947541728 | 15.78 | no | - | - | 6.8 |
| UD-Q4_K_XL | gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf | 5.23 | 17010980576 | 15.84 | no | - | - | 6.8 |
| UD-Q5_K_S | gemma-4-26B-A4B-it-UD-Q5_K_S.gguf | 5.80 | 18850707168 | 17.56 | no | - | - | 8.6 |
| UD-Q5_K_M | gemma-4-26B-A4B-it-UD-Q5_K_M.gguf | 6.51 | 21150365408 | 19.70 | no | - | - | 10.7 |
| UD-Q5_K_XL | gemma-4-26B-A4B-it-UD-Q5_K_XL.gguf | 6.53 | 21217769184 | 19.76 | no | - | - | 10.8 |
| UD-Q6_K | gemma-4-26B-A4B-it-UD-Q6_K.gguf | 7.13 | 23172478688 | 21.58 | no | - | - | 12.6 |
| UD-Q6_K_XL | gemma-4-26B-A4B-it-UD-Q6_K_XL.gguf | 7.17 | 23295391456 | 21.70 | no | - | - | 12.7 |
| Q8_0 | gemma-4-26B-A4B-it-Q8_0.gguf | 8.26 | 26859861728 | 25.02 | no | - | - | 16.0 |
| UD-Q8_K_XL | gemma-4-26B-A4B-it-UD-Q8_K_XL.gguf | 8.50 | 27636232928 | 25.74 | no | - | - | 16.7 |
| BF16 | gemma-4-26B-A4B-it-BF16-00001-of-00002.gguf, gemma-4-26B-A4B-it-BF16-00002-of-00002.gguf | 15.54 | 50505137824 | 47.04 | no (split) | - | - | 38.0 |

### unsloth/gemma-4-31B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-31B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| UD-IQ2_XXS | gemma-4-31B-it-UD-IQ2_XXS.gguf | 2.20 | 8534295488 | 7.95 | no | - | - | 0.0 |
| UD-IQ2_M | gemma-4-31B-it-UD-IQ2_M.gguf | 2.77 | 10752820160 | 10.01 | no | - | - | 1.0 |
| UD-Q2_K_XL | gemma-4-31B-it-UD-Q2_K_XL.gguf | 3.04 | 11774991296 | 10.97 | no | - | - | 2.0 |
| UD-IQ3_XXS | gemma-4-31B-it-UD-IQ3_XXS.gguf | 3.05 | 11837782976 | 11.02 | no | - | - | 2.0 |
| Q3_K_S | gemma-4-31B-it-Q3_K_S.gguf | 3.41 | 13210856384 | 12.30 | no | - | - | 3.3 |
| Q3_K_M | gemma-4-31B-it-Q3_K_M.gguf | 3.80 | 14736608192 | 13.72 | no | - | - | 4.7 |
| UD-Q3_K_XL | gemma-4-31B-it-UD-Q3_K_XL.gguf | 3.97 | 15380222912 | 14.32 | no | - | - | 5.3 |
| IQ4_XS | gemma-4-31B-it-IQ4_XS.gguf | 4.23 | 16372460480 | 15.25 | no | - | - | 6.2 |
| IQ4_NL | gemma-4-31B-it-IQ4_NL.gguf | 4.46 | 17287670720 | 16.10 | no | - | - | 7.1 |
| Q4_0 | gemma-4-31B-it-Q4_0.gguf | 4.47 | 17338248128 | 16.15 | no | - | - | 7.1 |
| Q4_K_S | gemma-4-31B-it-Q4_K_S.gguf | 4.49 | 17399835584 | 16.20 | no | - | - | 7.2 |
| Q4_K_M | gemma-4-31B-it-Q4_K_M.gguf | 4.73 | 18323733440 | 17.07 | no | - | - | 8.1 |
| UD-Q4_K_XL | gemma-4-31B-it-UD-Q4_K_XL.gguf | 4.86 | 18822970304 | 17.53 | no | - | - | 8.5 |
| Q4_1 | gemma-4-31B-it-Q4_1.gguf | 4.93 | 19118091200 | 17.81 | no | - | - | 8.8 |
| Q5_K_S | gemma-4-31B-it-Q5_K_S.gguf | 5.45 | 21124672448 | 19.67 | no | - | - | 10.7 |
| Q5_K_M | gemma-4-31B-it-Q5_K_M.gguf | 5.59 | 21658401728 | 20.17 | no | - | - | 11.2 |
| UD-Q5_K_XL | gemma-4-31B-it-UD-Q5_K_XL.gguf | 5.65 | 21890429888 | 20.39 | no | - | - | 11.4 |
| Q6_K | gemma-4-31B-it-Q6_K.gguf | 6.50 | 25201486784 | 23.47 | no | - | - | 14.5 |
| UD-Q6_K_XL | gemma-4-31B-it-UD-Q6_K_XL.gguf | 7.10 | 27521338304 | 25.63 | no | - | - | 16.6 |
| Q8_0 | gemma-4-31B-it-Q8_0.gguf | 8.42 | 32635677632 | 30.39 | no | - | - | 21.4 |
| UD-Q8_K_XL | gemma-4-31B-it-UD-Q8_K_XL.gguf | 9.04 | 35020041152 | 32.61 | no | - | - | 23.6 |
| BF16 | gemma-4-31B-it-BF16-00001-of-00002.gguf, gemma-4-31B-it-BF16-00002-of-00002.gguf | 15.85 | 61413190528 | 57.20 | no (split) | - | - | 48.2 |

### unsloth/gemma-4-12B-it-qat-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/unsloth/gemma-4-12B-it-qat-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| qat-UD-Q4_K_XL | gemma-4-12B-it-qat-UD-Q4_K_XL.gguf | 4.48 | 6716356800 | 6.26 | no | - | - | 0.0 |

### bartowski/gemma-4-12B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/bartowski/gemma-4-12B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| IQ2_S | gemma-4-12B-it-IQ2_S.gguf | 3.14 | 4708743648 | 4.39 | no | - | - | 0.0 |
| IQ2_M | gemma-4-12B-it-IQ2_M.gguf | 3.29 | 4940986848 | 4.60 | no | - | - | 0.0 |
| Q2_K | gemma-4-12B-it-Q2_K.gguf | 3.39 | 5077875168 | 4.73 | no | - | - | 0.0 |
| IQ3_XXS | gemma-4-12B-it-IQ3_XXS.gguf | 3.43 | 5145090528 | 4.79 | no | - | - | 0.0 |
| Q2_K_L | gemma-4-12B-it-Q2_K_L.gguf | 3.55 | 5321669088 | 4.96 | no | - | - | 0.0 |
| IQ3_XS | gemma-4-12B-it-IQ3_XS.gguf | 3.68 | 5525772768 | 5.15 | no | - | - | 0.0 |
| Q3_K_S | gemma-4-12B-it-Q3_K_S.gguf | 3.82 | 5724838368 | 5.33 | no | - | - | 0.0 |
| IQ3_M | gemma-4-12B-it-IQ3_M.gguf | 3.98 | 5969922528 | 5.56 | no | - | - | 0.0 |
| Q3_K_M | gemma-4-12B-it-Q3_K_M.gguf | 4.20 | 6301391328 | 5.87 | no | - | - | 0.0 |
| Q3_K_L | gemma-4-12B-it-Q3_K_L.gguf | 4.44 | 6652828128 | 6.20 | no | - | - | 0.0 |
| IQ4_XS | gemma-4-12B-it-IQ4_XS.gguf | 4.52 | 6780746208 | 6.32 | no | - | - | 0.0 |
| Q3_K_XL | gemma-4-12B-it-Q3_K_XL.gguf | 4.60 | 6896622048 | 6.42 | no | - | - | 0.0 |
| IQ4_NL | gemma-4-12B-it-IQ4_NL.gguf | 4.74 | 7105640928 | 6.62 | no | - | - | 0.0 |
| Q4_0 | gemma-4-12B-it-Q4_0.gguf | 4.75 | 7127759328 | 6.64 | no | - | - | 0.0 |
| Q4_K_S | gemma-4-12B-it-Q4_K_S.gguf | 4.78 | 7169538528 | 6.68 | no | - | - | 0.0 |
| Q4_K_M | gemma-4-12B-it-Q4_K_M.gguf | 5.11 | 7662533088 | 7.14 | no | - | - | 0.0 |
| Q4_1 | gemma-4-12B-it-Q4_1.gguf | 5.17 | 7755430368 | 7.22 | no | - | - | 0.0 |
| Q4_K_L | gemma-4-12B-it-Q4_K_L.gguf | 5.27 | 7906327008 | 7.36 | no | - | - | 0.0 |
| Q5_K_S | gemma-4-12B-it-Q5_K_S.gguf | 5.60 | 8405219808 | 7.83 | no | - | - | 0.0 |
| Q5_K_M | gemma-4-12B-it-Q5_K_M.gguf | 5.85 | 8774965728 | 8.17 | no | - | - | 0.0 |
| Q5_K_L | gemma-4-12B-it-Q5_K_L.gguf | 6.01 | 9018759648 | 8.40 | no | - | - | 0.0 |
| Q6_K | gemma-4-12B-it-Q6_K.gguf | 6.83 | 10239326688 | 9.54 | no | - | - | 0.5 |
| Q6_K_L | gemma-4-12B-it-Q6_K_L.gguf | 6.99 | 10483120608 | 9.76 | no | - | - | 0.8 |
| Q8_0 | gemma-4-12B-it-Q8_0.gguf | 8.45 | 12669647328 | 11.80 | no | - | - | 2.8 |
| bf16 | gemma-4-12B-it-bf16.gguf | 15.89 | 23832066272 | 22.20 | no | - | - | 13.2 |

### bartowski/google_gemma-4-E2B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/bartowski/google_gemma-4-E2B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| IQ2_M | google_gemma-4-E2B-it-IQ2_M.gguf | n/a | 2620200416 | 2.44 | no | - | - | 0.0 |
| Q2_K | google_gemma-4-E2B-it-Q2_K.gguf | n/a | 3020053984 | 2.81 | no | - | - | 0.0 |
| IQ3_XS | google_gemma-4-E2B-it-IQ3_XS.gguf | n/a | 3100712416 | 2.89 | no | - | - | 0.0 |
| Q3_K_S | google_gemma-4-E2B-it-Q3_K_S.gguf | n/a | 3134793184 | 2.92 | no | - | - | 0.0 |
| IQ3_M | google_gemma-4-E2B-it-IQ3_M.gguf | n/a | 3161611744 | 2.94 | no | - | - | 0.0 |
| Q3_K_M | google_gemma-4-E2B-it-Q3_K_M.gguf | n/a | 3226811872 | 3.01 | no | - | - | 0.0 |
| Q3_K_L | google_gemma-4-E2B-it-Q3_K_L.gguf | n/a | 3290414560 | 3.06 | no | - | - | 0.0 |
| IQ4_XS | google_gemma-4-E2B-it-IQ4_XS.gguf | n/a | 3324311008 | 3.10 | no | - | - | 0.0 |
| Q4_0 | google_gemma-4-E2B-it-Q4_0.gguf | n/a | 3378740704 | 3.15 | no | - | - | 0.0 |
| IQ4_NL | google_gemma-4-E2B-it-IQ4_NL.gguf | n/a | 3380639200 | 3.15 | no | - | - | 0.0 |
| Q4_K_S | google_gemma-4-E2B-it-Q4_K_S.gguf | n/a | 3382083040 | 3.15 | no | - | - | 0.0 |
| Q4_K_M | google_gemma-4-E2B-it-Q4_K_M.gguf | n/a | 3462680032 | 3.22 | no | - | - | 0.0 |
| Q4_1 | google_gemma-4-E2B-it-Q4_1.gguf | n/a | 3490069984 | 3.25 | no | - | - | 0.0 |
| Q5_K_S | google_gemma-4-E2B-it-Q5_K_S.gguf | n/a | 3603758560 | 3.36 | no | - | - | 0.0 |
| Q5_K_M | google_gemma-4-E2B-it-Q5_K_M.gguf | n/a | 3658384864 | 3.41 | no | - | - | 0.0 |
| Q2_K_L | google_gemma-4-E2B-it-Q2_K_L.gguf | n/a | 3686424032 | 3.43 | no | - | - | 0.0 |
| Q6_K | google_gemma-4-E2B-it-Q6_K.gguf | n/a | 3898486240 | 3.63 | no | - | - | 0.0 |
| Q3_K_XL | google_gemma-4-E2B-it-Q3_K_XL.gguf | n/a | 3956784608 | 3.69 | no | - | - | 0.0 |
| Q4_K_L | google_gemma-4-E2B-it-Q4_K_L.gguf | n/a | 4129050080 | 3.85 | no | - | - | 0.0 |
| Q5_K_L | google_gemma-4-E2B-it-Q5_K_L.gguf | n/a | 4324754912 | 4.03 | no | - | - | 0.0 |
| Q6_K_L | google_gemma-4-E2B-it-Q6_K_L.gguf | n/a | 4564856288 | 4.25 | no | - | - | 0.0 |
| Q8_0 | google_gemma-4-E2B-it-Q8_0.gguf | n/a | 4967497184 | 4.63 | no | - | - | 0.0 |
| bf16 | google_gemma-4-E2B-it-bf16.gguf | n/a | 9311304896 | 8.67 | no | - | - | 0.0 |

### bartowski/google_gemma-4-E4B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/bartowski/google_gemma-4-E4B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| IQ2_M | google_gemma-4-E4B-it-IQ2_M.gguf | n/a | 3959908832 | 3.69 | no | - | - | 0.0 |
| Q2_K | google_gemma-4-E4B-it-Q2_K.gguf | n/a | 4458093024 | 4.15 | no | - | - | 0.0 |
| IQ3_XS | google_gemma-4-E4B-it-IQ3_XS.gguf | n/a | 4632039904 | 4.31 | no | - | - | 0.0 |
| Q3_K_S | google_gemma-4-E4B-it-Q3_K_S.gguf | n/a | 4699695584 | 4.38 | no | - | - | 0.0 |
| IQ3_M | google_gemma-4-E4B-it-IQ3_M.gguf | n/a | 4767781344 | 4.44 | no | - | - | 0.0 |
| Q3_K_M | google_gemma-4-E4B-it-Q3_K_M.gguf | n/a | 4898730464 | 4.56 | no | - | - | 0.0 |
| Q3_K_L | google_gemma-4-E4B-it-Q3_K_L.gguf | n/a | 5034226144 | 4.69 | no | - | - | 0.0 |
| IQ4_XS | google_gemma-4-E4B-it-IQ4_XS.gguf | n/a | 5112828384 | 4.76 | no | - | - | 0.0 |
| Q4_0 | google_gemma-4-E4B-it-Q4_0.gguf | n/a | 5223860704 | 4.87 | no | - | - | 0.0 |
| IQ4_NL | google_gemma-4-E4B-it-IQ4_NL.gguf | n/a | 5232226784 | 4.87 | no | - | - | 0.0 |
| Q4_K_S | google_gemma-4-E4B-it-Q4_K_S.gguf | n/a | 5235657184 | 4.88 | no | - | - | 0.0 |
| Q2_K_L | google_gemma-4-E4B-it-Q2_K_L.gguf | n/a | 5303245280 | 4.94 | no | - | - | 0.0 |
| Q4_K_M | google_gemma-4-E4B-it-Q4_K_M.gguf | n/a | 5405170144 | 5.03 | no | - | - | 0.0 |
| Q4_1 | google_gemma-4-E4B-it-Q4_1.gguf | n/a | 5458479584 | 5.08 | no | - | - | 0.0 |
| Q5_K_S | google_gemma-4-E4B-it-Q5_K_S.gguf | n/a | 5701290464 | 5.31 | no | - | - | 0.0 |
| Q5_K_M | google_gemma-4-E4B-it-Q5_K_M.gguf | n/a | 5820883424 | 5.42 | no | - | - | 0.0 |
| Q3_K_XL | google_gemma-4-E4B-it-Q3_K_XL.gguf | n/a | 5879378400 | 5.48 | no | - | - | 0.0 |
| Q4_K_L | google_gemma-4-E4B-it-Q4_K_L.gguf | n/a | 6250322400 | 5.82 | no | - | - | 0.0 |
| Q6_K | google_gemma-4-E4B-it-Q6_K.gguf | n/a | 6329954784 | 5.90 | no | - | - | 0.0 |
| Q5_K_L | google_gemma-4-E4B-it-Q5_K_L.gguf | n/a | 6666035680 | 6.21 | no | - | - | 0.0 |
| Q6_K_L | google_gemma-4-E4B-it-Q6_K_L.gguf | n/a | 7175107040 | 6.68 | no | - | - | 0.0 |
| Q8_0 | google_gemma-4-E4B-it-Q8_0.gguf | n/a | 8031242720 | 7.48 | no | - | - | 0.0 |
| bf16 | google_gemma-4-E4B-it-bf16.gguf | n/a | 15053097184 | 14.02 | no | - | - | 5.0 |

### bartowski/google_gemma-4-26B-A4B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/bartowski/google_gemma-4-26B-A4B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| IQ2_XXS | google_gemma-4-26B-A4B-it-IQ2_XXS.gguf | 2.97 | 9656496128 | 8.99 | no | - | - | 0.0 |
| IQ2_XS | google_gemma-4-26B-A4B-it-IQ2_XS.gguf | 3.12 | 10126649856 | 9.43 | no | - | - | 0.4 |
| IQ2_S | google_gemma-4-26B-A4B-it-IQ2_S.gguf | 3.15 | 10230468736 | 9.53 | no | - | - | 0.5 |
| IQ2_M | google_gemma-4-26B-A4B-it-IQ2_M.gguf | 3.29 | 10700622464 | 9.97 | no | - | - | 1.0 |
| Q2_K | google_gemma-4-26B-A4B-it-Q2_K.gguf | 3.37 | 10951927936 | 10.20 | no | - | - | 1.2 |
| Q2_K_L | google_gemma-4-26B-A4B-it-Q2_K_L.gguf | 3.42 | 11130710144 | 10.37 | no | - | - | 1.4 |
| IQ3_XXS | google_gemma-4-26B-A4B-it-IQ3_XXS.gguf | 3.74 | 12160200320 | 11.33 | no | - | - | 2.3 |
| IQ3_XS | google_gemma-4-26B-A4B-it-IQ3_XS.gguf | 3.83 | 12437322880 | 11.58 | no | - | - | 2.6 |
| Q3_K_S | google_gemma-4-26B-A4B-it-Q3_K_S.gguf | 3.86 | 12553235072 | 11.69 | no | - | - | 2.7 |
| Q3_K_M | google_gemma-4-26B-A4B-it-Q3_K_M.gguf | 4.01 | 13019981440 | 12.13 | no | - | - | 3.1 |
| Q3_K_L | google_gemma-4-26B-A4B-it-Q3_K_L.gguf | 4.06 | 13199180416 | 12.29 | no | - | - | 3.3 |
| IQ3_M | google_gemma-4-26B-A4B-it-IQ3_M.gguf | 4.09 | 13280213632 | 12.37 | no | - | - | 3.4 |
| Q3_K_XL | google_gemma-4-26B-A4B-it-Q3_K_XL.gguf | 4.12 | 13377962624 | 12.46 | no | - | - | 3.5 |
| IQ4_XS | google_gemma-4-26B-A4B-it-IQ4_XS.gguf | 4.37 | 14205004928 | 13.23 | no | - | - | 4.2 |
| IQ4_NL | google_gemma-4-26B-A4B-it-IQ4_NL.gguf | 4.52 | 14697714816 | 13.69 | no | - | - | 4.7 |
| Q4_0 | google_gemma-4-26B-A4B-it-Q4_0.gguf | 4.54 | 14759385216 | 13.75 | no | - | - | 4.7 |
| Q4_K_S | google_gemma-4-26B-A4B-it-Q4_K_S.gguf | 4.88 | 15844288640 | 14.76 | no | - | - | 5.8 |
| Q4_1 | google_gemma-4-26B-A4B-it-Q4_1.gguf | 4.97 | 16144845952 | 15.04 | no | - | - | 6.0 |
| Q4_K_M | google_gemma-4-26B-A4B-it-Q4_K_M.gguf | 5.24 | 17035039872 | 15.87 | no | - | - | 6.9 |
| Q4_K_L | google_gemma-4-26B-A4B-it-Q4_K_L.gguf | 5.30 | 17213822080 | 16.03 | no | - | - | 7.0 |
| Q5_K_S | google_gemma-4-26B-A4B-it-Q5_K_S.gguf | 5.58 | 18129382528 | 16.88 | no | - | - | 7.9 |
| Q5_K_M | google_gemma-4-26B-A4B-it-Q5_K_M.gguf | 5.94 | 19319198848 | 17.99 | no | - | - | 9.0 |
| Q5_K_L | google_gemma-4-26B-A4B-it-Q5_K_L.gguf | 6.00 | 19497981056 | 18.16 | no | - | - | 9.2 |
| Q6_K | google_gemma-4-26B-A4B-it-Q6_K.gguf | 7.03 | 22862577280 | 21.29 | no | - | - | 12.3 |
| Q6_K_L | google_gemma-4-26B-A4B-it-Q6_K_L.gguf | 7.09 | 23041359488 | 21.46 | no | - | - | 12.5 |
| Q8_0 | google_gemma-4-26B-A4B-it-Q8_0.gguf | 8.26 | 26859861120 | 25.02 | no | - | - | 16.0 |
| bf16 | google_gemma-4-26B-A4B-it-bf16-00001-of-00002.gguf, google_gemma-4-26B-A4B-it-bf16-00002-of-00002.gguf | 15.54 | 50505135424 | 47.04 | no (split) | - | - | 38.0 |

### bartowski/google_gemma-4-31B-it-GGUF
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/bartowski/google_gemma-4-31B-it-GGUF`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| IQ1_M | google_gemma-4-31B-it-IQ1_M.gguf | 2.61 | 10112172384 | 9.42 | no | - | - | 0.4 |
| IQ2_XXS | google_gemma-4-31B-it-IQ2_XXS.gguf | 2.79 | 10830190944 | 10.09 | no | - | - | 1.1 |
| IQ2_XS | google_gemma-4-31B-it-IQ2_XS.gguf | 2.97 | 11500943712 | 10.71 | no | - | - | 1.7 |
| IQ2_S | google_gemma-4-31B-it-IQ2_S.gguf | 3.12 | 12075358560 | 11.25 | no | - | - | 2.2 |
| Q2_K | google_gemma-4-31B-it-Q2_K.gguf | 3.26 | 12631624032 | 11.76 | no | - | - | 2.8 |
| IQ2_M | google_gemma-4-31B-it-IQ2_M.gguf | 3.26 | 12649773408 | 11.78 | no | - | - | 2.8 |
| Q2_K_L | google_gemma-4-31B-it-Q2_K_L.gguf | 3.35 | 12972935520 | 12.08 | no | - | - | 3.1 |
| IQ3_XXS | google_gemma-4-31B-it-IQ3_XXS.gguf | 3.35 | 12981709152 | 12.09 | no | - | - | 3.1 |
| IQ3_XS | google_gemma-4-31B-it-IQ3_XS.gguf | 3.57 | 13841353056 | 12.89 | no | - | - | 3.9 |
| Q3_K_S | google_gemma-4-31B-it-Q3_K_S.gguf | 3.70 | 14329063776 | 13.34 | no | - | - | 4.3 |
| IQ3_M | google_gemma-4-31B-it-IQ3_M.gguf | 3.90 | 15129829728 | 14.09 | no | - | - | 5.1 |
| Q3_K_M | google_gemma-4-31B-it-Q3_K_M.gguf | 4.11 | 15918123360 | 14.82 | no | - | - | 5.8 |
| Q3_K_L | google_gemma-4-31B-it-Q3_K_L.gguf | 4.34 | 16810625376 | 15.66 | no | - | - | 6.7 |
| Q3_K_XL | google_gemma-4-31B-it-Q3_K_XL.gguf | 4.43 | 17151936864 | 15.97 | no | - | - | 7.0 |
| IQ4_XS | google_gemma-4-31B-it-IQ4_XS.gguf | 4.43 | 17155893600 | 15.98 | no | - | - | 7.0 |
| IQ4_NL | google_gemma-4-31B-it-IQ4_NL.gguf | 4.65 | 18025687392 | 16.79 | no | - | - | 7.8 |
| Q4_0 | google_gemma-4-31B-it-Q4_0.gguf | 4.66 | 18076264800 | 16.83 | no | - | - | 7.8 |
| Q4_K_S | google_gemma-4-31B-it-Q4_K_S.gguf | 4.70 | 18195655008 | 16.95 | no | - | - | 7.9 |
| Q4_K_M | google_gemma-4-31B-it-Q4_K_M.gguf | 5.06 | 19598489952 | 18.25 | no | - | - | 9.3 |
| Q4_1 | google_gemma-4-31B-it-Q4_1.gguf | 5.10 | 19765274976 | 18.41 | no | - | - | 9.4 |
| Q4_K_L | google_gemma-4-31B-it-Q4_K_L.gguf | 5.15 | 19939801440 | 18.57 | no | - | - | 9.6 |
| Q5_K_S | google_gemma-4-31B-it-Q5_K_S.gguf | 5.55 | 21504862560 | 20.03 | no | - | - | 11.0 |
| Q5_K_M | google_gemma-4-31B-it-Q5_K_M.gguf | 5.83 | 22608877920 | 21.06 | no | - | - | 12.1 |
| Q5_K_L | google_gemma-4-31B-it-Q5_K_L.gguf | 5.92 | 22950189408 | 21.37 | no | - | - | 12.4 |
| Q6_K | google_gemma-4-31B-it-Q6_K.gguf | 6.90 | 26726721888 | 24.89 | no | - | - | 15.9 |
| Q6_K_L | google_gemma-4-31B-it-Q6_K_L.gguf | 6.99 | 27068033376 | 25.21 | no | - | - | 16.2 |
| Q8_0 | google_gemma-4-31B-it-Q8_0.gguf | 8.42 | 32635677024 | 30.39 | no | - | - | 21.4 |
| bf16 | google_gemma-4-31B-it-bf16-00001-of-00002.gguf, google_gemma-4-31B-it-bf16-00002-of-00002.gguf | 15.85 | 61413189920 | 57.20 | no (split) | - | - | 48.2 |

### google/gemma-4-12B-it-qat-q4_0-gguf
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| qat-q4_0 | gemma-4-12b-it-qat-q4_0.gguf | 4.65 | 6975879296 | 6.50 | yes, this run | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/gemma-4-12b-it-qat-q4_0.gguf` | PASS (size+magic+sha256) | 0.0 |

### google/gemma-4-E2B-it-qat-q4_0-gguf
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/google/gemma-4-E2B-it-qat-q4_0-gguf`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| gemma-4-E2B_q4_0-it | gemma-4-E2B_q4_0-it.gguf | n/a | 3349516256 | 3.12 | no | - | - | 0.0 |

### google/gemma-4-E4B-it-qat-q4_0-gguf
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/google/gemma-4-E4B-it-qat-q4_0-gguf`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| gemma-4-E4B_q4_0-it | gemma-4-E4B_q4_0-it.gguf | n/a | 5154941280 | 4.80 | no | - | - | 0.0 |

### google/gemma-4-26B-A4B-it-qat-q4_0-gguf
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/google/gemma-4-26B-A4B-it-qat-q4_0-gguf`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| gemma-4-26B_q4_0-it | gemma-4-26B_q4_0-it.gguf | 4.44 | 14439363584 | 13.45 | no | - | - | 4.4 |

### google/gemma-4-31B-it-qat-q4_0-gguf
Local dir: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/google/gemma-4-31B-it-qat-q4_0-gguf`

| quant | file(s) | bits/weight (est.) | size (bytes) | size (GiB) | downloaded | local path | verified | est. RAM need (GiB) |
|---|---|---|---|---|---|---|---|---|
| gemma-4-31B_q4_0-it | gemma-4-31B_q4_0-it.gguf | 4.56 | 17651001568 | 16.44 | no | - | - | 7.4 |

## Self-check (automated from state.json; manual re-check in the final report)
- A1 PASS: GGUF main quants listed per repo from HF API: {'unsloth/Qwen3.6-35B-A3B-GGUF': 24, 'unsloth/Qwen3.6-35B-A3B-MTP-GGUF': 22, 'openbmb/MiniCPM-V-4.7-35B-A3B-gguf': 12, 'mradermacher/UI-Venus-1.5-30B-A3B-GGUF': 11, 'mradermacher/UI-Venus-1.5-30B-A3B-i1-GGUF': 23, 'ggml-org/gemma-4-12B-it-GGUF': 3, 'ggml-org/gemma-4-E2B-it-GGUF': 3, 'ggml-org/gemma-4-E4B-it-GGUF': 3, 'ggml-org/gemma-4-26B-A4B-it-GGUF': 3, 'ggml-org/gemma-4-31B-it-GGUF': 3, 'unsloth/gemma-4-12b-it-GGUF': 21, 'unsloth/gemma-4-E2B-it-GGUF': 21, 'unsloth/gemma-4-E4B-it-GGUF': 21, 'unsloth/gemma-4-26B-A4B-it-GGUF': 21, 'unsloth/gemma-4-31B-it-GGUF': 22, 'unsloth/gemma-4-12B-it-qat-GGUF': 1, 'bartowski/gemma-4-12B-it-GGUF': 25, 'bartowski/google_gemma-4-E2B-it-GGUF': 23, 'bartowski/google_gemma-4-E4B-it-GGUF': 23, 'bartowski/google_gemma-4-26B-A4B-it-GGUF': 27, 'bartowski/google_gemma-4-31B-it-GGUF': 28, 'google/gemma-4-12B-it-qat-q4_0-gguf': 1, 'google/gemma-4-E2B-it-qat-q4_0-gguf': 1, 'google/gemma-4-E4B-it-qat-q4_0-gguf': 1, 'google/gemma-4-26B-A4B-it-qat-q4_0-gguf': 1, 'google/gemma-4-31B-it-qat-q4_0-gguf': 1}
- A2 PASS: 6 new files, each size + GGUF magic + sha256 match: Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf -> PASS (size+magic+sha256); Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf -> PASS (size+magic+sha256); MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf -> PASS (size+magic+sha256); MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf -> PASS (size+magic+sha256); UI-Venus-1.5-30B-A3B.i1-Q3_K_M.gguf -> PASS (size+magic+sha256); UI-Venus-1.5-30B-A3B.i1-Q4_K_M.gguf -> PASS (size+magic+sha256)
- A3 PASS: lowest bits/weight among new files = 3.02 (floor 3.0)
- A4 PASS: no *.part left in model dirs: none
- A5 FAIL: pre-existing files failing verification: ['openbmb/MiniCPM-V-4.7-35B-A3B-gguf/MiniCPM-V-4_7-35B-A3B-Q8_0.gguf', 'openbmb/MiniCPM-V-4.7-35B-A3B-gguf/mmproj-model-f16-4x.gguf']
- A7 PASS: Gemma files (size, magic, sha256 where computed): gemma-4-12b-it-qat-q4_0.gguf -> PASS (size+magic+sha256); mmproj-gemma-4-12b-it-qat-q4_0.gguf -> PASS (size+magic+sha256); gemma-4-12b-it-Q8_0.gguf -> PASS (size+magic+sha256); gemma-4-E4B-it-Q4_K_M.gguf -> PASS (size+magic+sha256); mmproj-F16.gguf -> PASS (size+magic+sha256)
- A6 info: during run MemAvailable min 43.9 GiB, io some avg10 max 8.90, samples 229, pauses 0; PSI full total delta memory 1935623 us, io 25027097 us



## Gemma 4 reasoning distills and GUI helper (added 2026-10-13, research 25)

Full analysis, ranking, and vendor/independent tags: `research/25-gemma4-variants.md`. Sizes from HF API; every file PASS on size, GGUF magic, and sha256 vs lfs.oid.

| model | quant | bits/weight (est.) | size (bytes) | size (GiB) | local path | verified | est RAM need (GiB) |
|---|---|---|---|---|---|---|---|
| yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF | Q4_K_M | 4.9 | 7381381664 | 6.87 | `models/llm/yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF/gemma4-v2-Q4_K_M.gguf` | PASS (size+magic+sha256) | ~1.3 (on VRAM, if fits) |
| yuxinlu1/gemma-4-12B-agentic-... (MTP draft) | MTP Q8_0 | 8.5 | 465109248 | 0.43 | `.../gemma-4-12B-it-MTP-Q8_0.gguf` | PASS (size+magic+sha256) | 0 |
| yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF | Q4_K_M | 4.9 | 7381381664 | 6.87 | `models/llm/yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF/gemma4-opus48-Q4_K_M.gguf` | PASS (size+magic+sha256) | ~1.3 |
| yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF (MTP draft) | MTP Q8_0 | 8.5 | 465109248 | 0.43 | `.../gemma-4-12B-it-MTP-Q8_0.gguf` | PASS (size+magic+sha256) | 0 |
| unsloth/gemma-4-12b-it-GGUF | mmproj-BF16 | 0.12 | 175115840 | 0.16 | `models/llm/unsloth/gemma-4-12b-it-GGUF/mmproj-BF16.gguf` | PASS (size+magic+sha256) | 0.0 |
| mradermacher/UI-Venus-1.5-8B-GGUF | Q8_0 | 8.5 | 8709520128 | 8.11 | `models/llm/mradermacher/UI-Venus-1.5-8B-GGUF/UI-Venus-1.5-8B.Q8_0.gguf` | PASS (size+magic+sha256) | ~9.5 (helper, est. at 4-8K ctx) |
| mradermacher/UI-Venus-1.5-8B-GGUF | mmproj-Q8_0 | 0.12 | 752289984 | 0.70 | `models/llm/mradermacher/UI-Venus-1.5-8B-GGUF/UI-Venus-1.5-8B.mmproj-Q8_0.gguf` | PASS (size+magic+sha256) | 0.0 |

Bits/weight: size x 8 / params (12B = 11.95 B; 8B = 8.2 B), approximate.
