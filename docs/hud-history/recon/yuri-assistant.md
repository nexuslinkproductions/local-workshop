# Recon: YURI Assistant — what exists, what's missing, what to build

Date: 2026-09-30. Read-only recon. Every claim cites a real path.
Scope note: `PROJECTS/YURI-OS-MUSUBI/` is only a launch folder (two files, `AGENTS.md` + `CONTEXT.md`). The real repo is the Mac-migration snapshot at `04_PROJECTS/YURI-OS-MUSUBI/`. This report covers the real repo plus the related artifacts requested. Haze is excluded by instruction.

---

## (a) What YURI-OS-MUSUBI actually is

**A governance/control-plane monorepo for AI-assisted work, with a real app inside — not a personal voice assistant.** Self-description: "The deterministic gateway for AI. Governance, safety, and continuity that hold on any model" (`04_PROJECTS/YURI-OS-MUSUBI/README.md`). `INSTALL.md` describes YURI as "a governance + continuity exoskeleton for a coding AI… not an agent and not a model."

### Structure (repo root: `04_PROJECTS/YURI-OS-MUSUBI/`)

| Path | Role |
|---|---|
| `_SYSTEM/` | The control plane: backend, frontend, 712 operational scripts, memory, docs, labs |
| `_SYSTEM/backend/` | Express 5 + TypeScript API server, own `package.json`, `better-sqlite3`, `data/yuri.db` |
| `_SYSTEM/src/` | Vite/React frontend (`App.tsx`, `operator/OperatorShell`) — a portfolio/operator site, **not a chat app** |
| `_SYSTEM/Scripts/` | 712 files: memory-kernel, ollama lanes, autonomy runner, workcell, `voice/` subdir |
| `_SYSTEM/memory/` | Markdown memory index; real DBs in `_SYSTEM/OS_KERNEL/` (`memory.db`, `memory-cold.db`, `search-index.db`) |
| `_SYSTEM/mure/` | 20-role agent-fleet orchestration (`ceo.mjs`, `company.mjs`, `goal-engine.mjs`) |
| `skills/` | 178 governed skill dirs |
| `integrations/` | `agent-native`, `framer-mcp`, `spec-kit` |
| `demos/`, `dist/`, `docs/` | HTML demos, built frontends, docs |
| `00_COMMAND-CENTER/` … `04_ARCHIVE/` | Human work areas |

### Languages & LOC (git-tracked files, excluding node_modules/dist/locks)

| Language | Files | Lines |
|---|---|---|
| JS (.mjs) | 1,127 | 319,345 |
| JSON | 300 | 231,454 |
| Markdown | 3,169 | 147,462 |
| Python | 183 | 41,360 |
| HTML | 64 | 40,652 |
| TypeScript (.ts) | 182 | 38,174 |
| TSX | 126 | 29,009 |
| Rust (`_SYSTEM/nexus-rs/`) | 47 | 12,557 |
| JS (.js) | 72 | 11,865 |
| CSS | 16 | 10,397 |
| Shell | 78 | 4,891 |
| C / CJS / Swift / Zsh | 18 | 6,658 |

Dominant mass is Node ESM scripts + an enormous docs corpus (147k lines of Markdown).

### Does it run?

**Not as-is, and not on this machine without porting work.**

- `node_modules` is **not installed** anywhere (root and `_SYSTEM/backend/node_modules` are empty). Nothing runs until `npm install` × 2 + `tsc` build.
- `npm run dev` (root `package.json`) starts **only the Vite site** on 5173 — an operator/portfolio shell, not an assistant UI.
- `_SYSTEM/backend` (`ts-node src/server.ts`, PM2 `ecosystem.config.js` → port 3004) is the real service: sqlite, RAG services, executor, scheduler.
- macOS coupling throughout: `ecosystem.config.js` hardcodes `/Users/marcelspatz/.pm2/logs/`; `_SYSTEM/launchd/*.plist` (7 plists) + root `backend-operation-lock.plist`; `_SYSTEM/Scripts/llm-compat.sh` hydrates keys via macOS `security find-generic-password`; Swift/launchd/APFS scripts (`backend-volume-broker.swift`, `ollama-kv-launchd.mjs`, `yuri-session-launchd.mjs`); the entire voice stack is Apple-Silicon MLX.
- Git state: branch `main`, last commit 2026-08-10 (`fix(gitnexus-mcp): harden wrapper lifecycle`), **dirty tree** — 155 untracked, 17 modified, 16 type-changed, 2 deleted. It's a mid-migration snapshot.

### The October remotion folders

`04_PROJECTS/October/yuri-os-musubi-46526cef-remotion/` (246M) is an unrelated **Remotion video project** (package name `october-remotion`): one composition (`src/Root.tsx`, 88 lines) that recuts `public/assets/source.mov` into `out/nexus-demo-15s.mp4` — a NEXUS LINK promo render. The other two (`-92e3ac95-` empty, `-d886c2a1-` 112K scaffold) are stubs. Named after the workspace hash, not the assistant. Not assistant code.

---

## (b) What's built

### Persona / Yuri identity — three layers, all present

1. **Repo persona**: `_SYSTEM/persona.md` (full identity: adversarial ally, Rick Sanchez × Deadpool fusion, belief spine, 10 communication tells, AuDHD-informed operating base), `SOUL.md` (injection anchor for `.claude/hooks/soul-persona-inject.js`), `persona.template.md` (sanitized shipped template; Rick overlay gated behind `YURI_PRIVATE_RICK_OVERLAY=1`).
2. **Hermes persona**: `02_HERMES/personalities/yuri.txt` and `~/.hermes/personalities/yuri.txt` are **byte-identical** (18,126 bytes, `diff -q` clean) — 146-line "Hermes embodying the Yuri persona" spec: decode pipeline, five-state thought router, standing execution rules, binding floor, anti-slop list.
3. **Hermes live profile**: `~/.hermes/profiles/yuri/` — `config.yaml` (provider `cursor`, model `cursor/grok-4.6`, base_url `http://127.0.0.1:10100/v1`, reasoning xhigh), `SOUL.md` (Yuri-as-conductor of a 5-bot fleet: levi/itachi/roger/zenitsu/atlas), `state.db` (13 MB), `projects.db`, memories, sessions, skills. The `02_HERMES/profiles/yuri` copy is the older Mac overlay (config differs: 2,228 vs 2,282 bytes). `01_CREDENTIALS/config_misc/yuri/env.sh` is a keychain-pointer env file (secrets migrated to macOS keychain 2026-06-03; no plaintext) — **Mac-only mechanism, dead on Linux**.

### Memory / recall — real and multi-layered (in the repo)

- `_SYSTEM/Scripts/memory-kernel.mjs`: lexical/embedding/MSA recall modes, proposal→decide→promote pipeline, JSONL audit ledgers in `_SYSTEM/state/`, protected-path guards; deterministic 256-dim sha256-based encoder (`_SYSTEM/Scripts/static-encoder.mjs`) — zero-infra dense cosine recall.
- `_SYSTEM/MEMORY_ARCHITECTURE.md`: Track A canonical memory in `memory.db`; Track B behavioral memory (109 markdown files, written only via `claude-memory-write.mjs`); FTS5 "subconscious" cold store `_SYSTEM/OS_KERNEL/memory-cold.db`.
- Backend RAG: `_SYSTEM/backend/src/services/vectorSearchService.ts` + `hybridSearchService.ts` (sqlite FTS5 + semantic hybrid via better-sqlite3), `notebookRagService.ts`, `*:rag` ingest scripts; `.smart-env/` embedding contexts present.
- Recall scripts: `yuri-total-recall.mjs`, `yuri-recall.mjs`, `spreading-activation-memory.mjs`, `kagami-memory-pipeline.mjs`.

### Tools / executor — real, gated

- `_SYSTEM/backend/src/services/executor.ts`: allowlisted command executor (`GITNEXUS_ANALYZE`, `PALACE_REBUILD`, `VAULT_INGEST`, `SYSTEM_UPDATE`, `PLANE_SYNC`, `OUTLOOK_SYNC`, `OPEN_IMAGES_FOLDER`) via spawn, logged to sqlite.
- `_SYSTEM/Scripts/yuri-guarded-executor.mjs`: policy-gated execution with a readonly policy JSON.
- `_SYSTEM/Scripts/yuri-autonomy-runner.mjs`: dry-run-first autonomy levels L0→L4.
- `_SYSTEM/Scripts/yuri-workcell.mjs`: DAG-validated workcell orchestration, `yuri-patch-v0` patch format.
- Backend services: `browserAutomation.ts` (Puppeteer), `fileSystem.ts`, `outlookIcs.ts` (calendar), `planeSync.ts`, `vaultIngestion.ts`/`vaultWatcher.ts` (Obsidian), `swarmOrchestrator.ts`.

### Channels

- **Voice (Mac-only)**: `_SYSTEM/Scripts/voice/` — `bot.py` (Pipecat realtime loop: mic → Silero VAD → **MLX Whisper** STT → brain-proxy into a live Claude Code tmux session → **Marvis/Kokoro TTS** with a "Rick" voice clone, barge-in), `parakeet-listen.py` (Parakeet-MLX always-on STT), `kokoro_tts.py` (Kokoro-82M "Yuri" preset), `marvis_tts.py` (MOSS-TTS-Nano clone), `orchestrator.mjs` (bun half-duplex loop), `voice-speak.sh` (OpenAI-compatible TTS endpoint, macOS `say` fallback), `voxkey-control.mjs` + `yuri-voxkey.lua` (push-to-talk). **No wake-word detection anywhere** — PTT or always-on VAD instead. All of it requires Apple Silicon MLX.
- **Chat UI**: none. The Vite frontend is an operator/portfolio shell; `yuri-os-dashboard.html` is a status dashboard; `_SYSTEM/observatory-ui` is a trading observatory.
- **Terminal**: `_SYSTEM/Scripts/yuri-repl.mjs` (DeepSeek HUD REPL via `llm-compat.sh`).
- **Messaging bots**: none (Telegram/Discord/Slack appear only as passing mentions in two SKILL.md files).

### Model backends

- Repo lanes: `_SYSTEM/Scripts/ollama-lane.mjs` + `ollama-adapter.mjs` (Ollama local + Ollama Cloud, IPv4-first, token ledger), `llm-compat.sh`/`llm-lane.mjs` (multi-lane, macOS-keychain key hydration), `.claude/config/models.json` (Mac policy: Qwen3.5-9B-GLM5.1-Distill Q5_K_M GGUF primary; `gemma4:12b-it-qat` multimodal fallback; `nomic-embed-text` embeddings; written for M2 Pro 16 GB). `_SYSTEM/model-registry.md`: one-model-at-a-time local registry + DeepSeek V4 router lanes + OpenRouter free lane. Backend deps: `openai`, `@anthropic-ai/sdk`, `@google/generative-ai`. No direct llama.cpp usage in the repo (GGUF via Ollama).

### LOCAL AI LAB — the part that actually runs on THIS machine

Root: `LOCAL AI LAB/` at NEXUS_AI_CENTER. README dated 2026-09-27: "Local AI on the Intel Arc B580 (12 GB VRAM) — no cloud, no NVIDIA."

**Chat scripts — all llama.cpp `llama-server`, NOT ollama:**

| Script | Binary | Model | Port | Key flags |
|---|---|---|---|---|
| `chat-bonsai.sh` | `llm/llama.cpp-prism/build/bin/llama-server` | `models/llm/bonsai/Ternary-Bonsai-2-27B-PQ2_0.gguf` (6.8G, ternary PQ2_0) + `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` (601M, vision) | **8082** | `-ngl 99` (full GPU), `-fa on`, `-c 32768`, temp 1.0 / top-p 0.95 / top-k 20 / min-p 0.05, `--jinja`, `--device Vulkan0` |
| `chat-bonsai-abliterated.sh` | same prism binary | `models/llm/bonsai-abliterated/Ternary-Bonsai-2-27B-Abliterated-PQ2_0.gguf` (6.8G) + same shared mmproj | **8083** | identical flags |
| `chat-obliterated.sh` | `llm/llama.cpp/build/bin/llama-server` (stock) | `models/llm/Qwen3.8-27B-OBLITERATED/Qwen3.8-27B-OBLITERATED-IQ4_XS.gguf` (15G, IQ4_XS) + `mmproj-model-bf16.gguf` (889M, `--no-mmproj-offload`) + `chat_template.jinja` | **8081** | `-ngl 40` (verified max w/ vision; 48 OOMs), `-fa on`, `-c 16384`, temp 0 greedy, repeat-penalty 1.15, thinking off, `--device Vulkan0` |

So: **"bonsai" = Ternary-Bonsai-2-27B, a multimodal (vision mmproj) reasoning model in PrismML's PQ2_0 ternary quant, served by llama.cpp's server — not ollama, not "Bonsai 2" the app.** All three expose the built-in web chat UI + OpenAI-compatible `/v1`. No system prompts anywhere (OBLITERATED by card mandate; bonsai thinks by default at xhigh).

**Models inventory (`models/` = 55 GB total):**

- LLM: Bonsai PQ2_0 6.8G + Q8_0 mmproj; Bonsai-Abliterated PQ2_0 6.8G + mmproj; Qwen3.8-27B-OBLITERATED IQ4_XS 15G + bf16 mmproj. All `qwen35` arch (hybrid linear-attention, 64 layers, native 262k ctx) per `notes/LLM.md`.
- Image: `qwen-image-2.1-UC-Q5_K_M.gguf` 4.9G transformer, two int8 text encoders (8.9G + 8.8G), bf16 VAE 645M, two speed LoRAs (turbo8 1.3G, PAI 4-step 330M). Qwen Research License — non-commercial only.

**llama.cpp builds (both Vulkan, both verified working on the B580):**

- Stock `llm/llama.cpp`: build 11222 / commit a97cce86a (2026-09-27), `libggml-vulkan.so.0.25.3`, full binary set in `build/bin/` (llama-server, llama-cli, llama-bench, llama-tts, llama-embedding…). **No whisper.cpp binary** (upstream removed it from llama.cpp; `whisper-enc.cpp` exists only compiled into libmtmd).
- Prism `llm/llama.cpp-prism`: fork `github.com/PrismML-Eng/llama.cpp` branch `prism`, build 10743 / adfffbe41, `libggml-vulkan.so.0.21.0` — required for PQ2_0/PTQ1_0 ternary quants (ggml type 142). Prebuilt prism binaries silently CPU-fallback (<2 tok/s); the fix (PR #238) is source-only — this build is from source.
- `llm/BUILD-REPORT.txt`: Vulkan0 = B580 (12,216 MiB, 9,732 free) via Mesa ANV 26.2.2; Vulkan1 = Ryzen iGPU (RADV). Measured on Bonsai: prompt 32.9 t/s, gen 24.5 t/s; llama-bench pp128 278 t/s / tg32 26 t/s. OBLITERATED `-ngl 99` OOMs; `-ngl 48` ceiling, ~7 t/s (IQ4_XS spills ~3 GB to host RAM).
- `llm/setup-llm.sh`: idempotent rebuild/test pipeline (cmake `-DGGML_VULKAN=ON -DGGML_NATIVE=ON`, Ninja, model test-loads, bench, writes BUILD-REPORT + `llm/logs/`).

**Imagegen**: `imagegen/ComfyUI/` 0.37.0 on torch 2.14.0+xpu with working `.venv` + `main.py` + `extra_model_paths.yaml` → UI on :8188; two ready workflows in `imagegen/workflows/`.

**Nothing voice-related in the LAB** — no whisper/piper/vosk/openwakeword installs, no mic config. Only an unused `llama-tts` binary (no model for it).

---

## (c) What's missing for an always-on local assistant on THIS machine

Machine state verified 2026-09-30:

| Need | Status | Evidence |
|---|---|---|
| GPU inference (B580 12 GB) | **DONE** | `llm/BUILD-REPORT.txt`: Vulkan0 B580, ANV 26.2.2, KHR_coopmat active; both llama.cpp builds have `libggml-vulkan.so` |
| Model that fits | **DONE** | Bonsai PQ2_0 6.8 GiB → full offload at `-ngl 99`, ~26 t/s (`chat-bonsai.sh`, BUILD-REPORT). Bonsai-Abliterated same. OBLITERATED 14.4 GiB does NOT fit — partial offload only (`-ngl 40`, ~7 t/s) |
| OpenAI-compatible endpoint | **DONE** | `http://127.0.0.1:8082/v1` (and 8081/8083) via llama-server |
| Vision | **DONE** | mmproj Q8_0 wired in both bonsai scripts |
| PipeWire mic path | **DONE** | PipeWire 1.6.8 live (`pactl`: "PipeWire 'pipewire-0'"), sources present: CORSAIR Slipstream Mono (default), Kiyo webcam, Ryzen analog; `pipewire-pulse` installed so `pactl`/Pulse API works |
| Audio out | **DONE** | sinks present (CORSAIR default, HDMI, Ryzen) |
| Wake word (openwakeword) | **MISSING** | no binary, no python package (`python-openwakeword` not found), no onnxruntime |
| ASR (faster-whisper / any whisper) | **MISSING** | no `whisper`/`faster-whisper`/`vosk` binary or package; no whisper.cpp build; ComfyUI's whisper nodes are cloud-API/internal only |
| TTS (piper) | **MISSING** | `/usr/bin/piper` + pacman `piper 0.8-5` is the **mouse-configuration GUI** (org.freedesktop.Piper, `piper.gresource`), NOT the TTS. No piper-TTS, no espeak-ng, no mimic, no voices anywhere. `qt6-speech` exists but has no engine backend installed |
| Always-on daemon | **MISSING** | no systemd user unit, no llama-server autostart; `pgrep llama-server` empty right now; ports 8081/8082/8083/8188 all closed |
| Assistant loop (wake→ASR→LLM→TTS) | **MISSING** | the repo's loop (`_SYSTEM/Scripts/voice/bot.py`) is MLX/macOS-only |
| Chat UI for the LAB models | partial | llama-server's built-in web UI per port; no dedicated assistant frontend |
| Memory wired to LAB models | **MISSING** | repo memory kernel targets Mac paths/Ollama; nothing connects it to :8082 |
| Key material on Linux | **MISSING** | `01_CREDENTIALS/config_misc/yuri/env.sh` points at macOS keychain; Hermes profile uses a local cursor relay (`127.0.0.1:10100`) — cloud-dependent, not local |

RAM headroom is fine (61 GiB total, 37 GiB available) for CPU-side ASR/TTS alongside a fully-offloaded Bonsai.

---

## (d) Honest verdict: reuse vs rebuild

### Reuse as-is
- **LOCAL AI LAB wholesale.** The llama.cpp Vulkan builds, the three chat scripts, the model set, and the measured performance data are the hard part and they're done. Bonsai-Abliterated PQ2_0 on :8083 is the right daily-driver brain: full VRAM fit, ~26 t/s, vision, no refusal weights (a wake-word assistant that refuses is useless), reasoning when wanted.
- **The Yuri persona.** `~/.hermes/personalities/yuri.txt` (146 lines) is complete, model-agnostic, and already the live Hermes persona. Drop it in as the system prompt (Bonsai accepts one; only OBLITERATED forbids it).
- **PipeWire.** Mic + sink routing already works; easyeffects is even running.

### Reuse with surgery
- **Memory kernel** (`_SYSTEM/Scripts/memory-kernel.mjs` + `static-encoder.mjs`): the zero-infra sha256-encoder recall is portable Node ESM with no Mac deps — but it's entangled with `_SYSTEM/state/` paths and the proposal pipeline. Extract the recall core, don't port the governance.
- **Guarded-executor pattern** (`yuri-guarded-executor.mjs`, backend `executor.ts`): the allowlist-and-log design is exactly right for voice-triggered actions; reimplement the pattern (it's small) rather than port the Mac-coupled files.
- **Voice loop architecture** (`_SYSTEM/Scripts/voice/bot.py`): the *shape* (VAD → STT → brain → TTS, barge-in) is proven; every library in it (Pipecat/MLX/Kokoro-Marvis) is Apple-only. Architecture: reuse. Code: rewrite.

### Rebuild / leave behind
- The YURI-OS-MUSUBI monorepo itself: 319k lines of governance .mjs, no node_modules, dirty mid-migration tree, launchd/keychain/MLX coupling, no chat UI, no wake word. It is a control plane for coding-AI fleets, not an assistant runtime. Do not try to "boot" it on Linux.
- MLX voice stack, launchd plists, keychain env.sh, the Vite operator site, the remotion folders (unrelated video work).

### Concrete minimal "hey nexus" → yuri → actions plan

One Python (or Node) daemon, ~400 lines, four new packages, zero monorepo:

1. **Serve the brain**: systemd user unit running `chat-bonsai-abliterated.sh` (port 8083, full VRAM, abliterated so the assistant doesn't refuse). VRAM rule already documented: one chat model at a time.
2. **Wake word**: `openwakeword` (pip, onnxruntime CPU — tiny) with a trained "hey nexus" model, reading the default PipeWire source via `sounddevice`/`pw-cat` at 16 kHz. Mic path already exists (CORSAIR mono source is default).
3. **ASR**: `faster-whisper` (CTranslate2, CPU int8 — small/base.en is plenty at 61 GB RAM; or GPU later via whisper.cpp Vulkan if latency matters). VAD-gated capture, barge-in = stop TTS on new speech.
4. **Brain**: HTTP POST to `http://127.0.0.1:8083/v1/chat/completions` with `~/.hermes/personalities/yuri.txt` as system prompt + rolling session history. Tool calls = a small allowlisted action map (the guarded-executor pattern): open app, run safe shell, read HUD stats from `nexuslink.hud/collect.sh`, toggle ComfyUI, search files. Log every action to sqlite.
5. **TTS**: real piper-TTS (`piper-tts` pip package or AUR `piper-tts`; the pacman `piper` on this box is the mouse GUI — do not confuse them) with one en_US voice onnx, output to the default PipeWire sink. ~100 ms first-audio on CPU.
6. **Memory (later, optional)**: extract `static-encoder.mjs` cosine recall into a sidecar store; append-only JSONL log first, fancy lifecycle never.

Everything in steps 1–5 is install-and-glue on top of verified-working pieces. No porting of the monorepo required.
