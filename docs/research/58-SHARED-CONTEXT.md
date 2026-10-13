# Shared context for the Chief improvement research wave (2026-10-13)

Chief = Marcel's local, always-available assistant: a Hermes Agent profile (`~/.hermes/profiles/chief/`: SOUL.md, config.yaml, workspace/AGENTS.md, workspace/route cards, workspace/bin/think) running fully local.

## Runtime (measured, today)
- Brain: Ornith-1.5-9B Q4_K_M (Qwen3.5-family hybrid: gated-delta recurrent layers + full attention every 4th layer, built-in MTP head unused), llama.cpp SYCL on Intel Arc B580 12 GB, served by llama-swap on 127.0.0.1:18080 (model id `ornith-chief`, thinking off; `ornith-chief-think` = thinking on, 512-token budget). ctx 262144, q4_0 KV, -ub 256, vision encoder on CPU. Decode ~57 t/s, prefill ~1200 t/s at 30K. Loads on demand (~3 s), unloads after 600 s idle.
- Hermes Agent source: `~/.hermes/hermes-agent` (Python). Chief's first request is ~7-8.5K tokens (system prompt ~1.2K + 8 tool schemas). Toolsets: terminal, file, vision, memory (web via helper). Auxiliary tasks (titles, compaction, vision) are pinned to the same local model.
- Eval: `LOCAL-AI-LAB/evals/chief/` 42 tasks in 6 categories (nav 12, read 8, write 8, invoice 6, web 3, safety 5). Ornith at 256K scored 30/42: nav 11/12, read 3/8, write 8/8, invoice 2/6, web 2/3, safety 4/5. Latest per-item results: `LOCAL-AI-LAB/bench/bakeoff42/logs/suite-ornith-9b.out` (PASS/FAIL lines with the failing check), result JSON in `LOCAL-AI-LAB/results/`. Failure clusters: reading exact numbers out of lab notes/logs, the invoice Kleinunternehmer clause and invoice file creation, asking before risky actions (safety), one web citation.
- Prompt history: research/43-chief-prompt-v2.md (v1 17/42 -> v2 26/42 on Gemma), the 8-tool fix (29K -> ~8K token first request).
- Knowledge base on disk: Marcel's workspace `~/NEXUS_AI_CENTER` (ICM-structured projects, invoice system at 04_PROJECTS/Clients/invoice-system with AGENTS.md). YURI-OS (PROJECTS/YURI-OS, Rust) indexed 165,290 docs but ranking is weak (4/12 top-3).
- Hardware for helpers: Ryzen 9 7900X CPU (12C), 61 GiB RAM, GT 1030 2 GB (CUDA 12.9, speech-to-text).
- Marcel's goals: reliable, snappy, useful daily assistant for basic work (navigate files, read notes, write, invoices, web lookups, computer use, voice), British male voice, never lags, 256K context. Quality per task matters more than raw speed now.

## Rules for every research agent
- Read-only on the system: no GPU, no llama-server, no `bench/.gpu.lock`, no installs, no downloads, no edits outside your own output file.
- Plain English, no em dashes. Cite every claim (URL with date, or file:line). Mark: measured by someone / vendor claim / your inference.
- Concrete over generic: every recommendation = exact change (file, setting, text, flag) + expected effect on which eval category + how to test it in one run.
- Lab root: /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB. Write your file to research/ with the name given in your task.
