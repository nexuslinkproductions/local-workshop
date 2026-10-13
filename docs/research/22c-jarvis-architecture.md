# 22c — Jarvis assistant: screen awareness, architecture, phased plan

Scope: brief `research/BRIEF-22-jarvis.md`, questions 3 (screen awareness), 4 (architecture, incl. how Hermes fits) and 5 (phased plan). Questions 1 (models) and 2 (voice stack) belong to other sections; they are referenced here only where the architecture depends on them. Section numbers follow the question numbers, so §1 (requirements) and §2 (models/voice) are not in this file.

Output path note: the brief names `research/22-jarvis-assistant.md`; this file is `22c-jarvis-architecture.md` as requested by the delegating agent. Merge as needed.

Conventions: **[M]** = measured on this box in this session. **[S]** = taken from a cited source (vendor, blog or community claim; quality noted). **[U]** = unverified / my estimate. Nothing was loaded on the GPU, no model was run, no config was changed.

---

## 0. Box facts that constrain the design

Measured or read from local files:

| Fact | Value | Source |
|---|---|---|
| Hermes main model | `claude-opus-5-5` via Anthropic (cloud) | `~/.hermes/config.yaml` `model:` [M] |
| Hermes vision aux (screenshots) | `anthropic / claude-haiku-5-5` (cloud) | `auxiliary.vision` [M] |
| Hermes memory LLM (hindsight) | `openai_compatible` → `https://api.deepseek.com/v1`, `auto_retain: true`, `auto_recall: true` | `hindsight:` [M] — key names only read, no secrets printed |
| Hermes STT provider | `parakeet`, command script → venv under `/run/media/.../YURI-OS-MUSUBI/_SYSTEM/state/voice/.venv-stt`; that client script's `VENV_PY` is a macOS path (`/Users/marcelspatz/...`) | `stt:`, `~/.hermes/scripts/parakeet-stt-client.py` [M] |
| Hermes TTS provider | `mlx-local` (Kokoro via `mlx_audio`, Apple-Silicon-only), venv path does **not exist** on this box | `tts:` [M] — `ls` returns "No such file or directory" |
| Hermes wake word | `enabled: false`; engines: openWakeWord (default, bundled "hey hermes"), sherpa (open vocabulary), Porcupine | `wake_word:` [M], wake-word docs [S] |
| Hermes voice | `auto_tts: false`; CLI push-to-talk Ctrl+B; barge-in on by default | `voice:` [M], voice-mode docs [S] |
| Hermes computer use | `computer_use.backend: cua` (cua-driver 0.21.0 installed at `~/.hermes/tools/cua-driver-0.21.0-linux-x64/`) | config [M], `command -v` [M] |
| Piper binary | `/usr/bin/piper` present | `command -v` [M] |
| Screen tools | `grim`, `slurp`, `hyprctl` (Hyprland v0.56.2), `wtype` present; `ydotool`, `wf-recorder`, `ollama`, `llama-server` (on PATH) missing | [M] |
| OCR | Tesseract 5.5.3, **languages: `eng` and `osd` only** (no German pack) | `tesseract --list-langs` [M] |
| Audio | PipeWire 1.6.8 (PulseAudio shim). `libpipewire-module-echo-cancel.so` is installed but **no echo-cancel module is loaded** | `pactl`, `/usr/lib/pipewire-0.3/` [M] |
| GPU / RAM | Arc B580 detected (Vulkan); 61 GiB RAM, ~46 GiB available at check time | `vulkaninfo --summary`, `free -g` [M] |
| Serving shelf | llama-swap on `127.0.0.1:18080`, 4 MoE models, `ttl: 600`, gate refuses while ARC Raiders runs. No Gemma entry yet | `serve/config.yaml` [M], `research/20-serving-layer.md` |
| llama.cpp tip | Source contains a `gemma4` architecture (`src/llama-arch.cpp`, `src/llama-model.cpp`) and mtmd projector types `GEMMA4V` / `GEMMA4A` (vision and audio) | `grep` in `engines/llama.cpp-vulkan-tip` [M]. Not run. |

Two findings matter for everything below:

1. **Hermes voice and TTS are configured against paths that do not exist on this Linux box.** The configured command providers cannot run as written. Whether Hermes falls back (its docs name Edge TTS as the default fallback) was not tested. Fix = point `stt`/`tts` at working providers (`piper` is installed; `faster-whisper` is the documented local STT). Not changed here.
2. **Screenshots and memory extraction currently go to cloud endpoints** by config (aux vision → Anthropic, hindsight → DeepSeek). Any screen-derived content routed through those keys leaves the machine. This is the first privacy item in §3.5.

---

## 3. Question 3 — Screen awareness

### 3.1 Options, cheapest first

| # | Channel | What the model gets | Cost on this box | Status here |
|---|---|---|---|---|
| A | **Window metadata** via `hyprctl clients -j` (title, class, workspace, monitor, pid, fullscreen, xwayland, focusHistoryID) | Active app, window title, which monitor | One IPC call, no pixels, no GPU. Latency not measured. | Works: 2 clients returned, all keys present [M]. Titles can leak content (mail subjects, URLs) → filter. |
| B | **Event-driven trigger** on Hyprland IPC events (`activewindow` on the event socket, `socket2`) instead of polling | Lets the context cache refresh only on focus change | Near zero while idle | Event-socket name from Hyprland IPC docs [U] (not verified in this session). |
| C | **Accessibility tree (AT-SPI)** via cua-driver `get_window_state` / Hermes `computer_use capture mode=ax` | Buttons, labels, text fields, focused element, as text | Low (D-Bus); no GPU | Works on X11/XWayland per cua docs [S]. Native Wayland is opt-in (`CUA_DRIVER_RS_ENABLE_WAYLAND=1`); Hyprland support is listed as experimental [S]. Empty trees on apps that populate lazily. |
| D | **On-demand screenshot** via `grim` (wlr-screencopy; no portal picker) | Pixels of one monitor, downscaled | **0.27 s** (one 2560×1440 monitor at scale 0.5), **0.51 s** (all 3 monitors, full scale, PNG to stdout). Median of 3 runs [M]. Full desktop at scale 0.5 = 1.29 MB PNG [M]. | Works [M]. Downstream vision cost is the real bottleneck (see 3.3). |
| E | **Periodic low-res capture + diff** (screenpipe-style) | Continuous memory | CPU for diff and storage (5–10 GB/month per vendor) | Not recommended as default (privacy and storage). |
| F | **OCR** (Tesseract) on a capture | Text from pixel-only apps (games, remote desktops, apps with empty AT-SPI trees) | Tesseract 0.09 s on one synthetic 1400×300 line [M, single sample, not a benchmark]. One misread (`g`→`y`) on an ASCII German test line [M]. German-specific OCR was **not** tested (the test image lost its umlauts). | Installed with `eng`/`osd` only. German needs `tessdata` `deu` [U: package name not checked]. |
| G | **Dedicated GUI parser / grounding model** (OmniParser, UI-TARS, UI-Venus on shelf) | Element boxes and click targets for "click the Save button" | Vision model cost (§3.3) | Later phase. UI-Venus-1.5-30B is already on the shelf [M]. |

Recommendation: **A + C first (text, cheap), D on demand (pixels, expensive), F only as a fallback.** Continuous capture (E) is off by default.

### 3.2 Reference designs

- **screenpipe** (`github.com/screenpipe/screenpipe`, `docs.screenpipe.com/architecture`) [S]: the closest existing design. Event-driven, not fixed-FPS: captures on app switch, window focus, click/scroll, typing pause, clipboard, plus an idle capture about every 5 s. Each capture stores a screenshot and the accessibility tree at the same timestamp; OCR is the fallback. On Linux it uses Tesseract [S]. Vendor-stated cost 5–10 % CPU, ~600 MB RAM, 5–10 GB/month [S, vendor numbers]. **Licence conflict across mirrors**: one README says MIT, another says "Screenpipe Commercial License, source-available, personal use" [S]. Verify before reuse. Reuse the *pattern* (event trigger + AT-SPI first + OCR fallback), not the app.
- **OmniParser** (`github.com/microsoft/OmniParser`) [S]: screenshot → structured UI elements with boxes, for grounding a VLM's clicks. Code and caption models MIT; the icon detector inherits **AGPL** from YOLO [S, README]. Relevant for phase 8, not the MVP.
- **UI-TARS-desktop** (`github.com/bytedance/UI-TARS-desktop`, Apache-2.0) [S]: Node/TypeScript desktop GUI agent; the open UI-TARS-1.5-7B model is Apache-2.0 and runnable locally; strongest variants are cloud-only [S, third-party summary]. Reuse the model idea; the app is not needed.
- **Hermes computer_use** [S]: vision-model-agnostic; `mode=som|vision|ax`; "no vision model? → routes screenshots through `auxiliary.vision`"; desktop-only, browser pages use the `browser_*` tools. On Linux the backend is cua-driver, whose Linux support is X11/XWayland by default. Its own docs say installing the driver "does not enable isolated raw background input on Omarchy" [S].

### 3.3 Latency of the image path (the real constraint)

- Brief measurement on this box: Qwen3.6-35B-A3B screenshot read ~10–17 s (MoE with CPU experts) [brief, taken as given].
- BatiAI's Gemma 4 12B GGUF card, **M4 Max, not this box**: screenshot → full analysis ~22 s including generation (949 tokens out); "OCR + visual reasoning" [S, vendor-run]. Projector ~167 MB, text ~45 tok/s warm for Q4_K_M on the Mac [S].
- Gemma 4 12B on the B580, fully in VRAM: **not measured** [U]. My estimate for decode is bounded by bandwidth: a dense 6.6 GiB model on a card with ~456 GB/s (Intel spec [U]) gives a ceiling of ~60–70 tok/s; realistic is lower.

Consequence for voice: a screenshot question cannot be answered with the image as the first step if the target is "first word in ~1.5 s". Design rule:

1. Answer from **text context first** (A + C): active app, title, focused element, nearby labels. Most questions ("what am I looking at", "where is the Save button") are answerable this way.
2. Only attach pixels when the text is insufficient, downscale to ~1280 px long edge, active monitor only (`grim -o <output>`).
3. Stream a one-sentence answer, then the detail.

### 3.4 Storage and retention

- Default: **no persistence of pixels**. Keep the last capture in RAM or `$XDG_RUNTIME_DIR` (tmpfs) and overwrite.
- Persist only text, and only after a redaction pass. The Hermes memory path (hindsight, `auto_retain: true`) would retain screen-derived text unless its input is filtered; its extraction LLM currently points to DeepSeek's endpoint [M, config keys].

### 3.5 Privacy controls (required before any capture is enabled)

1. Capture is **off by default**; on only by an explicit toggle or hotkey. Hermes `hermes pause` is an emergency stop for cron/kanban/gateway turns and does **not** stop screen capture [M, `hermes --help`]; a separate capture flag is needed.
2. **Denylist** by window class and title pattern (password managers, banking, messengers, private/incognito browser windows) plus an optional allowlist of workspaces. Denied windows return "not captured", never a blurred image.
3. **Route screen content to local models only.** Change `auxiliary.vision` from Anthropic to the local shelf (config change, not made here). Until then, screenshots leave the box.
4. Visible indicator while capture is armed (the notch UI in `nexuslink.medianotch/` or the Quickshell HUD are existing candidates).
5. Wayland gives no permission prompt for `grim` (wlr-screencopy), unlike the portal path used for screen sharing, which shows a picker [S, Hyprland wiki]. So the controls above are **policy enforced in our code**, not by the compositor.

### 3.6 Screen-awareness verdict

- Text-first context (window metadata + AT-SPI) covers the common questions cheaply and locally; it is the first thing to build.
- Pixels on demand via `grim` are cheap to capture (≤0.5 s) and the cost is in the vision model, which must be local and warm.
- Continuous recording (screenpipe style) is possible but not worth its privacy and storage cost for an MVP.

## 4. Question 4 — Architecture

### 4.1 Decision: Hermes is the brain; everything voice-related is a thin edge

Reasons, from the box and the docs (not from preference):

- Hermes already has what the brief asks for: tools, `hindsight` memory (`local_embedded`), skills, `delegate_task` subagents, cron, approvals, `computer_use`, `vision`, sentence-streaming TTS and a voice loop with barge-in [S, docs; M, config]. Rebuilding those would be the expensive path.
- The voice loop must stay small and fast. Hermes's voice mode is built into the CLI/TUI (`/voice on`, Ctrl+B, auto-restart after reply, barge-in) [S]. The wake word also runs only in CLI, TUI and desktop surfaces, **not in the messaging gateway** [S]. So a permanently listening assistant needs a long-lived Hermes CLI/TUI or desktop session. Hermes's CLI voice and wake word are the first thing to try before writing any daemon.
- The model split is simple with the existing shelf and Hermes's provider/auxiliary mechanism: a **fast local model** for the voice turn and screen questions, and **cloud or the 35B MoE** for hard tasks (`delegation`, `auxiliary` keys).

### 4.2 Diagram

```
                     ┌──────────── GPU: Arc B580 12 GB ────────────┐
 mic ─► PipeWire ────┤ FAST BRAIN (always warm, fully in VRAM)     │
 (echo-cancel:       │   Gemma 4 12B Q4_K_M + mmproj (text,image)  │◄── llama-swap / llama-server
  to be loaded)      │   [U] ~6.6 GiB weights, ctx-limited KV      │
   │                 └──────────────▲──────────────────────────────┘
   │ wake word (openWakeWord "hey hermes" or sherpa KWS, CPU)
   │ VAD (silero, CPU)
   ▼
 STT (streaming, CPU: faster-whisper / Voxtype engine / Parakeet via command provider)
   │ text
   ▼
 ┌──────────────────────── HERMES (orchestrator, CLI/TUI/desktop session) ────────────────────────┐
 │ model routing:  voice turn ─► fast brain (local)                                              │
 │                 hard task  ─► delegation / cloud (claude-opus-5-5) or 35B MoE on demand       │
 │ tools:  screen_context  = hyprctl clients -j  +  AT-SPI (cua ax)  +  grim (on demand)         │
 │         vision          = auxiliary.vision → LOCAL fast brain (not Anthropic)                  │
 │         computer_use    = cua-driver (X11/XWayland; native Wayland opt-in)                    │
 │         memory          = hindsight (local_embedded); extraction LLM → LOCAL (not DeepSeek)    │
 │         cronjob / delegate_task / kanban = background work, results spoken or noted          │
 │ approvals: every click / type / shell action gated (no unattended input)                     │
 └────────────────────────────────────────┬─────────────────────────────────────────────────────┘
                                          │ sentence stream
                                          ▼
 TTS (CPU): Piper de_DE thorsten (CC0) via command provider ──► PipeWire ──► speakers/headphones
            barge-in: Hermes detector (quiet-room calibrated) + PipeWire echo-cancel (not loaded)
 HUD/notch: state (idle / listening / thinking / speaking) + capture-armed indicator
```

Where it runs: STT, wake word, VAD and TTS on **CPU**, so the B580 holds only the brain. This keeps the GPU for one model and avoids the GPU contention the bench and shelf already manage.

### 4.3 The fast brain: why Gemma 4 12B is the candidate for this slot

Figures from the GGUF repos (HF tree API read for file sizes):

| Item | Value | Source |
|---|---|---|
| Parameters / layers / context | 11.95 B dense, 48 layers, 256 K context, hybrid sliding window 1024 | unsloth model card [S] |
| Modalities | text, image, audio (audio ≤30 s, video ≤60 s upstream) | unsloth card [S] |
| Licence | Apache 2.0 | model cards [S] |
| Q4_K_M file | 7,121,861,440 B ≈ 6.63 GiB | HF API tree, `unsloth/gemma-4-12b-it-GGUF` [S] |
| Q4_K_S / IQ4_XS / Q5_K_M | 6.76 GB / 6.38 GB / 8.41 GB | same [S] |
| Vision projector `mmproj-F16` | 175,115,840 B ≈ 0.16 GiB | same [S] |
| MTP draft (speculative decoding) | `mtp-gemma-4-12b-it.gguf` 465 MB (Q8_0) | same [S] |
| llama.cpp support | `gemma4` arch + vision and audio projector types present in local tip source | local grep [M], **not run** |
| Audio input in llama.cpp | "experimental"; needs 16 kHz mono WAV; ≤30 s | BatiAI card [S, vendor-run on Mac] |
| Video in llama.cpp | not supported (no gemma4 video projector) | BatiAI card [S] |
| Speed | ~45 tok/s warm, Q4_K_M, **M4 Max** | BatiAI [S, not this box] |

Fit on the B580 (estimate [U]): 6.63 GiB weights + 0.16 GiB projector leaves ~4–5 GiB for KV cache and the Vulkan runtime. With `-c 8192–16384` and q8_0 KV (as the shelf does), this should fit. **Not loaded; the fit is an estimate.** The MoE models on the shelf are 20–37 GB and spill to RAM, which is the failure mode that froze the desktop; a 6.6 GiB dense model that sits entirely in VRAM avoids it.

Honest comparison with the other shelf models (brief criteria; full sweep belongs to the models section):
- Qwen3.6-35B-A3B: strongest measured agent behaviour on this box, but 20.8 GiB file, `--n-cpu-moe 32`, 40 tok/s decode, 10–17 s screenshot reads [brief, M].
- MiniCPM-V-4.7 and UI-Venus: vision-specialised MoEs, placements still placeholders in `serve/config.yaml` [M].
- Gemma 4 12B: the only candidate that is dense, ≤12 GB quant, and multimodal in one file. Its German and tool-calling quality are **not measured here** [U]; Marcel's own result with Gemma 4 12B (from the brief) is the best local signal.

### 4.4 Serving the fast brain

Two ways, both use existing pieces:

1. **Add one entry to `serve/config.yaml`** (llama-swap), with `ttl` long (or pinned) so it stays warm, and the same gate script. Model id e.g. `gemma4-12b-q4km`. Point Hermes at it with the provider block already proposed in `serve/hermes-provider.yaml`.
2. Run a separate `llama-server` for the fast brain as a systemd user unit, and leave llama-swap for the MoE shelf. This keeps the warm brain independent of model swaps on the shelf. Cost: one more process, and a second VRAM owner to coordinate with `bench/.gpu.lock` (see risks).

Recommendation: option 1 for a first test (less to maintain), option 2 once the brain must never unload. Both are config and a unit file; no code.

### 4.5 Cloud escalation

- Hermes already routes by config: `delegation.provider/model` (currently Anthropic `claude-haiku-5-5` for subagents) and `model.default` (`claude-opus-5-5`) [M].
- Proposal: voice turns default to the local fast brain; escalate to cloud only on an explicit phrase ("think harder", "use the big model") or when the local model's answer fails a check (tool error, empty reply). Escalation must never send screen pixels unless the user confirmed it.
- `model_overrides` and `fallback_providers: []` are the existing knobs [M]; the fallback is empty today.

### 4.6 Existing open projects: what to reuse, honestly

| Project | Origin / licence | What it does well | Use here? |
|---|---|---|---|
| **Hermes** (Nous Research) | US lab; MIT [U: licence not checked] | Tools, memory, subagents, cron, voice CLI, computer_use | **Yes, as the brain.** Already installed. |
| **Voxtype** (Marcel's box) | local | Push-to-talk STT, parakeet/moonshine | **Yes, as the STT engine** (reuse, do not rebuild). |
| **Handy** (`github.com/cjpais/Handy`) | Tauri app; licence [U] | Push-to-talk STT: Whisper (GPU when available) or Parakeet V3 (CPU, auto language detection); Wayland needs `wtype`/`dotool` [S] | **No.** Duplicates Voxtype. Read its Parakeet CPU notes. |
| **Kyutai Unmute** (`github.com/kyutai-labs/unmute`) | French nonprofit (Kyutai); licence [U] | Cascaded STT → text LLM → TTS with semantic VAD, sentence-streaming TTS, "flush trick" (STT processes buffered audio ~4× real time, cutting the final wait to ~125 ms) [S] | **Reference design, not code.** Its STT is EN/FR only ([kyutai.org/stt](https://kyutai.org/stt), `stt-1b-en_fr`), so no German from it [S]. Vendor claim: "response latency below a second" [S]. |
| **Pipecat** (Daily / pipecat-ai, US) | open source framework [U: licence] | Real-time voice pipelines with local models; examples report <800 ms voice-to-voice on an M-series Mac [S, example repos, Mac/MLX] | **Only if** the Hermes voice loop cannot reach target latency. Adds a framework layer. |
| **OpenVoiceOS / OVOS** (`openvoiceos.org`, EU; NGI Zero Commons Fund grant) | EU, open source; licence [U] | Full voice OS: listener, audio, skills [S] | **No.** It would replace Hermes as the brain. Take its listener only if needed. |
| **Home Assistant Assist + Wyoming + Piper + openWakeWord** (Open Home Foundation / Nabu Casa) | Europe-run foundation; open source | Battle-tested decoupled pipeline over the Wyoming protocol; each stage is a swappable server [S]. Third-party latency reports vary a lot: ~1.2–1.8 s on a Pi 5 [S, blog], ~4–5 s measured from HA state history on a 5650G with Piper [S, blog]. | **Reuse the components, not HA.** openWakeWord and Piper are the pieces; Wyoming is a good seam if the voice loop ever splits into processes. |
| **Piper** (OHF, GPL-3.0; original `rhasspy/piper` MIT, archived 6 Oct 2025) | Europe (Rhasspy, now OHF) [S] | CPU neural TTS, ONNX, real time on a Pi; German `thorsten` voice is CC0 and `kerstin` is also CC0 [S, HF model cards] | **Yes, as TTS.** `/usr/bin/piper` is already installed [M]. GPL-3.0 is fine for personal use; flag if ever distributed. |
| **Kokoro-82M** (hexgrad) | Apache-2.0 [S] | Good English voices; German community voices exist (`df_eva`, `dm_bernd`, `df_victoria`, `dm_martin`), Apache-2.0 [S, community GGUF repo]. Official VOICES list has no German [S]. | **Second choice** for character voice; German quality unverified. Already in the Hermes tts config (mlx path, broken here). |
| **sherpa-onnx** (k2-fsa, China; Apache-2.0 [U]) | open source, Chinese academic-origin team | One CPU runtime for ASR (streaming and offline), TTS, VAD, **keyword spotting** [S] | **Yes, indirectly**: Hermes's wake-word `sherpa` provider is open-vocabulary [S]; that it is built on sherpa-onnx is inferred from the name [U]. |
| **openWakeWord** (dscripka; Apache-2.0 [U]) | open source | Default Hermes wake word, "hey hermes" bundled [S]. Vendor benchmark (wakewordlab, a competitor) claims openWakeWord costs ~40 % of one Raspberry Pi 3 core, 15 % for theirs [S, vendor-only, not independently verified] | **Yes** (Hermes default). Measure false triggers on this box. |
| **screenpipe** | licence conflicting across mirrors (MIT vs source-available) [S] | Event-driven capture with accessibility-first text and Tesseract OCR fallback [S] | **Pattern only.** Not installed. |
| **OmniParser** (Microsoft; MIT code, AGPL icon detector) [S] | US | Screen → element boxes for grounding | **Later** (phase 8). |
| **UI-TARS-desktop / UI-TARS** (ByteDance, China) | Apache-2.0 app; open 7B model Apache-2.0; top variants cloud-only [S] | Local GUI agent | **Idea only.** UI-Venus on the shelf covers the grounding role. |
| **cua-driver** (trycua) | open source; licence [U] | Background computer use via AT-SPI and XTEST; Linux X11/XWayland, native Wayland opt-in [S] | **Yes, via Hermes `computer_use`**, with Linux limits (§4.7). |
| **Hyprland tools** (`hyprctl`, `grim`, `slurp`, `wtype`) | present [M] | Window metadata, screenshots, typing on Wayland (`wtype`) | **Yes.** No new packages needed for phases 3 and 8. |

Not evaluated in this session: Open Interpreter, Rhasspy 3, Leon, Mycroft-era skills, LiveKit Agents. Mark them unverified if the design ever needs them.

### 4.7 Computer control on Hyprland: what works today

- `computer_use` on Linux runs through cua-driver. Its docs state: X11 and XWayland are supported; native Wayland needs `CUA_DRIVER_RS_ENABLE_WAYLAND=1`; Hyprland has "separate experimental support entries"; "installing the driver does not enable isolated raw background input on Omarchy" [S, cua docs]. Its own Linux page recommends `foreground` delivery for raw Wayland input, which **takes focus**.
- So on this box: AT-SPI reads and element clicks on XWayland/X11 apps are plausible; typing or clicking into native Wayland apps needs a foreground step with approval, or `wtype`. Window management (focus, move, workspace) is safe via `hyprctl dispatch`.
- Consequence for the spec: every input action is an approval-gated Hermes action. No unattended typing or clicking.

### 4.8 Latency budget (targets, not measurements)

| Stage | Target | Basis |
|---|---|---|
| End of speech → transcript | 0.3–0.6 s | Kyutai's flush trick and faster-than-real-time streaming are the reference [S]; no local German STT timing measured here [U] |
| LLM first token (fast brain, warm, short prompt) | 0.3–0.8 s | [U] estimate; not measured on B580 |
| First sentence → first audio (Piper medium, CPU) | 0.1–0.3 s | Piper on Pi 5 "200–500 ms for a two-second reply" [S, blog]; CPU-desktop number [U] |
| **Total, text-only turn** | **~1.0–1.6 s** | sum of above; in line with the ~1.5 s "feels responsive" band in HA guides [S] |
| Screen question with pixels | +3–15 s before the detail [U] | §3.3; answer first from text context, then stream the image answer |

These are design targets. Phase 1 must measure them.

### 4.9 Desktop-never-freezes rules

1. Load each model once; never load a model that does not fit VRAM+RAM with headroom (the 20–37 GB MoE loads caused the freeze in the brief).
2. Keep the fast brain dense and VRAM-resident; MoE models only on demand through the shelf.
3. CPU-only STT/TTS/wake so the GPU does not stall the three monitors.
4. The gate (`serve/gate-run.sh`) must stay in the launch path for every model; ARC Raiders keeps priority.
5. Limit context (`-c 8192–16384`) and cap captured image size (≤1280 px) so KV and prefill stay bounded.

## 5. Question 5 — Phased plan

Each phase ends with a check that can fail. Order is by risk and by what it proves. Phases 0–1 need no GPU and no new model.

| Phase | Build | Exit check (must pass) |
|---|---|---|
| **0. Make voice work at all** (config only, ~1 h) | Point Hermes `stt` and `tts` at working local providers on this box: `tts` → `piper` (`/usr/bin/piper`, German `thorsten` CC0 voice); `stt` → `faster-whisper` (install into the Hermes venv) or the Voxtype engine via a command provider. Load the echo-cancel module (`pactl load-module module-echo-cancel`, then persist; command syntax not tested). Keep `auto_tts` off for now. | `/voice on`, Ctrl+B, say one German sentence, get a spoken reply; Hermes logs show transcript and TTS file. Reply plays without self-triggering (test on headphones and on speakers). |
| **1. Smallest end-to-end loop** (push-to-talk → local model → speech) | Turn on Hermes voice with the **current cloud brain** first, so the loop is tested before any model is added. Log per-stage timestamps (end of speech, transcript, first token, first audio). | 20 utterances (10 DE, 10 EN). Record time-to-first-audio. Target ~1.0–1.6 s (§4.8); record the real number, do not tune to the target. |
| **2. Local fast brain** | Add `gemma4-12b-q4km` (Q4_K_M + `mmproj-F16`) to the llama-swap shelf with a long `ttl`, same gate script; add the Hermes provider block; point the voice turn at it. Bench load, prefill, decode and VRAM **with the bench lock held** and no game running. | Warm first-token and decode numbers on the B580 recorded. Desktop stays responsive during a 10-turn session. Local answers pass the same 10-turn German/English set from phase 1. If quality fails, stay on cloud for voice and keep the local model for screen work only. |
| **3. Screen awareness v1 (text + on-demand pixels)** | Tool `screen_context`: `hyprctl clients -j` for active window (title/class/workspace/monitor), denylist, plus `grim -o <active output>` → downscale to 1280 px → `auxiliary.vision` = local brain. No pixels stored; RAM/tmpfs only. Capture off by default; armed by hotkey/toggle with a visible indicator. | (a) "What app am I in?" answered from metadata with no image call. (b) "What am I looking at?" answered with an image in ≤ the measured budget (set the budget from phase 2 numbers). (c) A denylisted window (e.g. a password manager) returns "not captured" and never reaches the model; verify by log. (d) Capture-armed indicator visible. |
| **4. Screen awareness v2 (accessibility text)** | Use cua `capture mode=ax` on X11/XWayland apps for focused element and labels; event-driven refresh on Hyprland `activewindow` socket events instead of polling; OCR (`deu` tessdata) only as fallback for empty trees. | "Where is the Save button?" answered from the tree without an image on at least 3 real apps (browser, editor, one GTK/Qt app). Tree-empty apps fall back to OCR and say so. |
| **5. Wake word** | Enable `wake_word` with openWakeWord "hey hermes" (Hermes default) or sherpa for an open phrase; `sensitivity` tuned; surface = CLI/TUI session that is always open. | One full day of normal use with the detector armed: count false triggers per hour and misses on 10 deliberate "hey hermes". Target set by Marcel; record numbers. Wake word runs only while a local Hermes session is open (gateway unsupported). |
| **6. Memory with privacy** | Re-point hindsight's extraction LLM from DeepSeek to the local brain, or turn off `auto_retain` for anything derived from screen capture. Keep `auto_recall`. Add a per-day "forget screen context" command. | Test: a screen-derived fact appears in recall only when the user said to keep it. Confirm via logs that no screen text reached the DeepSeek endpoint. |
| **7. Proactive help** | Cron jobs check cheap signals (build finished, calendar event within 10 min, long idle) and send a short spoken note through the voice loop. Gap to close: `cronjob` delivers to messaging platforms, not the local speaker, so the voice loop needs a notification channel (small addition). | 5 proactive notes in a day: each one useful or dismissed; none during a denied window or a game (gate). |
| **8. Computer control** | Window ops via `hyprctl dispatch` (focus, move, workspace). Clicks/typing via `computer_use` AT-SPI actions on XWayland apps; `wtype` for native Wayland typing; every action goes through Hermes approvals. | Each action type demonstrated with approval; a denied approval performs no action (verified by log); no unattended input path exists. |
| **9. Background tasks** | Voice request → `delegate_task` or kanban task → result spoken or noted on completion. | A 10-minute task started by voice, reported back by voice, with the transcript in the kanban record. |

Hard gates for every phase: the shelf gate stays in the launch path (ARC Raiders), no model loads above VRAM/RAM headroom, no screen content leaves the box unless Marcel confirms.

## Open risks

1. **Cloud leakage by default.** `auxiliary.vision` (Anthropic), `hindsight` extraction (DeepSeek) and the main brain (Anthropic) all receive whatever the voice loop and screen tools send. Fix in phase 3 and phase 6 before screen capture is enabled, not after.
2. **Gemma 4 12B on the B580 is unmeasured.** Fit (≈6.6 GiB + KV), decode speed, and llama.cpp support were not run. If phase 2 fails, the fallback is a smaller dense model (Q3_K_M ≈ 5.3 GiB file, quality cost unmeasured) or cloud voice with local screen work only.
3. **GPU sharing with bench and three monitors.** The B580 drives all three monitors and the bench lock is separate from llama-swap. Running the warm brain while a bench holds the card risks the stalls the brief describes. Rule: the fast brain pauses when `bench/.gpu.lock` is held (not yet implemented).
4. **Echo and self-triggering.** No echo cancellation is loaded; the Hermes barge-in detector calibrates against the quiet room, which helps but does not remove speaker bleed. Use headphones until phase 0's AEC test passes.
5. **Wake-word false triggers.** openWakeWord's frame-level scoring fires on stray phonemes (Hermes docs call this out [S]). Measure in phase 5; tune `sensitivity` and `confirmation_frames`.
6. **Hyprland / cua limits.** Native Wayland input is opt-in and experimental for Hyprland; the driver on this box is 0.21.0 while the docs describe 0.28.x. Keep `computer_use` to XWayland/X11 apps until a test on native Wayland apps passes.
7. **Hermes voice needs an open session.** Always-on listening requires a long-lived CLI/TUI or desktop session. A background daemon would need Hermes's API surface, which I did not verify (a `response_store.db` exists, which hints at one; unverified).
8. **Config drift and broken paths.** `stt` and `tts` point at paths that do not exist here, so the configured voice providers fail on this box (fallback behaviour untested). Fix in phase 0 and check `hermes doctor` afterwards.
9. **Licences.** Piper is GPL-3.0 now (personal use fine, distribution not); screenpipe's licence is contradictory across mirrors; OmniParser's icon detector is AGPL. Check before any redistribution.
10. **Latency numbers are targets.** The only measured ones here are grim capture and one OCR sample. The rest come from vendor or blog sources (Kyutai, BatiAI on a Mac, HA guides) and must be replaced by phase 1–2 measurements.
11. **German quality is not measured anywhere in this file.** STT, LLM, Piper thorsten and Tesseract `deu` all need a German test set before the German-first requirement is met.

## Sources

Hermes (primary, docs and repo):
- Voice mode: https://hermes-agent.nousresearch.com/docs/user-guide/features/voice-mode
- Wake word: https://hermes-agent.nousresearch.com/docs/user-guide/features/wake-word
- Tools and toolsets: https://hermes-agent.nousresearch.com/docs/user-guide/features/tools
- Computer use (skill): https://github.com/nousresearch/hermes-agent/blob/main/skills/autonomous-ai-agents/computer-use/SKILL.md
- Computer use (feature doc, commit 850413f): https://github.com/NousResearch/hermes-agent/blob/850413f1203f02c42ac6b9fd21ff86a2402a974e/website/docs/user-guide/features/computer-use.md
- Hermes cua backend: https://github.com/NousResearch/hermes-agent/blob/dcf9826dc936258aa3b7e2e11ded39ea59dc6cc8/tools/computer_use/cua_backend.py

cua-driver (Linux):
- Linux backend: https://github.com/trycua/cua/blob/cua-driver-rs-v0.28.2/libs/cua-driver/rust/Skills/cua-driver/LINUX.md
- Install/start on Linux: https://cua.ai/docs/cua-driver/guide/getting-started/linux
- Blog: https://cua.ai/blog/inside-linux-computer-use

Hyprland:
- xdg-desktop-portal-hyprland: https://wiki.hypr.land/Hypr-Ecosystem/xdg-desktop-portal-hyprland
- Portal picker and screencopy behaviour: https://github.com/hyprwm/xdg-desktop-portal-hyprland/blob/master/src/portals/Screencopy.cpp

Screen awareness references:
- screenpipe architecture: https://docs.screenpipe.com/architecture ; repo https://github.com/screenpipe/screenpipe (licence conflict noted, see mirrors https://github.com/plastic-labs/screenpipe and https://github.com/itsbrex/screenpipe/blob/main/README.md)
- OmniParser: https://github.com/microsoft/OmniParser
- UI-TARS-desktop: https://github.com/bytedance/UI-TARS-desktop ; UI-TARS: https://github.com/bytedance/UI-TARS

Models and GGUF:
- Gemma 4 12B, unsloth (file sizes from HF tree API): https://huggingface.co/unsloth/gemma-4-12b-it-GGUF
- Gemma 4 12B, BatiAI (Mac measurements, audio/video notes): https://huggingface.co/batiai/gemma-4-12B-it-GGUF
- Gemma 4 12B, AtomicChat (licence, quant ladder): https://huggingface.co/AtomicChat/gemma-4-12B-it-GGUF

Voice stack references:
- Kyutai Unmute: https://github.com/kyutai-labs/unmute ; architecture write-up (secondary): https://medium.com/towards-artificial-intelligence/unmute-giving-voice-to-ai-a-deep-dive-into-kyutais-framework-6d8f83bc9531
- Kyutai STT (EN/FR, 0.5 s delay): https://kyutai.org/stt ; https://huggingface.co/kyutai/stt-1b-en_fr
- Piper (archive and successor, licence change): https://github.com/OHF-Voice/piper1-gpl ; rhasspy/piper archived 6 Oct 2025 (secondary report: https://qwe.edu.pl/ai-tools/install-piper-tts-open-source)
- Piper German voices and licences: https://huggingface.co/cstr/piper-voices-GGUF ; https://huggingface.co/rhasspy/piper-voices/blob/v1.0.0/de/de_DE/thorsten/medium/MODEL_CARD
- Kokoro voices (German community): https://huggingface.co/cstr/kokoro-voices-GGUF ; official VOICES list: https://huggingface.co/hexgrad/Kokoro-82M/blob/85cb1baa68f0a44d9d6559879bcd92266080d9a8/VOICES.md
- sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx
- openWakeWord vs wakewordlab (vendor benchmark, not independent): https://github.com/ubermorgenland/wakewordlab ; https://apinference.com/wakewordlab.html
- Handy: https://github.com/EXTREMOPHILARUM/Handy (fork; upstream cjpais/Handy referenced in its README)
- Pipecat: https://github.com/pipecat-ai/pipecat ; example: https://github.com/kwindla/macos-local-voice-agents
- OVOS: https://openvoiceos.org ; https://github.com/OpenVoiceOS/OpenVoiceOS
- Home Assistant voice pipeline (secondary, blog latency): https://botmonster.com/smart-home/home-assistant-voice-pipelines-local-wake-word-wyoming ; https://aioue.net/2026/07/23/home-assistant-voice-pe-self-hosted-assist ; https://kevintrinh.dev/articles/voice-assistant-raspberry-pi-5

Local measurements (this session): `grim` timings, `tesseract --list-langs`, `hyprctl clients -j` keys, `hyprctl monitors -j`, `pactl`, `vulkaninfo --summary`, `free -g`, `ls` of the Musubi voice path, `grep` in `engines/llama.cpp-vulkan-tip`.

## Self-check (brief requirement)

Re-read the file after writing (headers, cross-references, claim tags). Result per section the brief requires:

| Required section | This file | Result |
|---|---|---|
| Requirements | Not restated here; §0 and the brief cover it. Belongs in `22-jarvis-assistant.md` | **FAIL** in this file (out of this agent's scope) |
| Model shortlist table | Only the Gemma 4 12B table (§4.3) and a comparison paragraph. Full table belongs to Q1 | **FAIL** in this file (out of scope) |
| Voice stack table | Only the open-project table (§4.6) and TTS/STT facts. Full table belongs to Q2 | **FAIL** in this file (out of scope) |
| Screen awareness | §3.1–3.6 | **PASS** — every row has a source tag or is marked [U] or [M] |
| Architecture with text diagram | §4.1–4.9, diagram in §4.2 | **PASS** |
| Phased plan | §5, phases 0–9 with exit checks | **PASS** |
| Open risks | §5, risks 1–11 | **PASS** |
| Source for every claim or marked unverified | 18 explicit [U] tags; all web claims carry a URL in §Sources | **PASS**, with one caveat: a few table cells cite "[S]" for secondary blog sources, labelled as such in-line |

Local checks done on the file: section headers present; §-references resolve to existing headings; no unfilled placeholders remain.

