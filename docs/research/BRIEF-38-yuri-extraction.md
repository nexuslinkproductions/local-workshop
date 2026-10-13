# BRIEF-38: YURI out of Haze, into the OS (phase 1: find, map, design) — 2026-10-13

## Marcel's intent (decode, keep his framing)
YURI is Marcel's cognitive governance architecture (governance, capture, recall, graph, xref, AI search
and more). It was meant to sit as a LAYER BETWEEN THE HARNESS AND THE OPERATING SYSTEM. It was built inside
Haze over months, but Haze was a mess and YURI is not fully operational. Haze itself is no longer pursued.
Goal: extract YURI from Haze and build it into Marcel's OS piece by piece, organ by organ, layer by layer,
test and optimise each, so that Chief (the local Gemma assistant, Hermes profile `chief`) AND Hermes in
general (any session, local work) can use it. Refine and clean the codebase on the way so it works
smoothly. NEVER describe YURI as "a memory layer" or "memory engine": it is a cognitive governance
architecture; memory/recall is one organ of it.

## Phase 1 scope (this brief): find, map, design. NO code changes to any Haze tree.
1. FIND every YURI source and pick the latest. Search ALL mounted filesystems, not just Linux home:
   ~/NEXUS_AI_CENTER/PROJECTS/HAZE/VERSIONS/BETA/v1.4.0 (branches v1.4.0 and v1.4.0-subagent-acp+comms),
   PROJECTS/HAZE/VERSIONS/RELEASE/v1.3.670, ~/projects/haze, 04_PROJECTS/Haze/haze-main,
   PROJECTS/YURI-OS-MUSUBI and 04_PROJECTS/YURI-OS-MUSUBI ("YURI OS / MUSUBI control plane": read its
   AGENTS/CONTEXT first, it may be the intended home), PROJECTS/YURI-BUSINESS, the Windows drive
   /run/media/nexuslink/82CC5F65CC5F5311 (autofs; look for NEXUS_AI_CENTER.win and Haze-Desktop
   versions incl. v1.5.0 and its worktrees; memory says C:\NEXUS_AI_CENTER\04_PROJECTS\Haze\versions\v1.5.0),
   /mnt/DATA (autofs), the T7 SSD /run/media/nexuslink/T7 (now attached). Use git log/branches/tags,
   version strings and file mtimes to rank recency; report every copy with path, branch/commit, date,
   size of the YURI part, and which is newest. Exclude node_modules/target/.git objects; never read
   secrets (.env, auth.json, keys). Read-only everywhere (no git checkout/fetch on Marcel's repos; use
   `git -C <repo> log/show/ls-tree` on any branch without switching).
2. MAP the YURI system from code AND the schematics/docs (find them: docs/yuri*, schematics, diagrams,
   ADRs, design notes). For each organ/layer (e.g. governance, capture, recall, AI search, xref, graph,
   wake/ledger, policy, provenance, and whatever else exists): purpose, entry points (files, functions,
   commands, services), data stores and formats, dependencies on Haze internals (Tauri, UI, Haze harness)
   vs standalone logic, test coverage, and FUNCTIONAL STATUS verified by running its own tests or a
   tiny CPU-only probe where cheap (works / partial / stub / broken) with evidence. Note the mess:
   duplicated code, dead code, contradictions between docs and code.
3. DESIGN the target: YURI as an OS-level layer between any harness and the OS on this box
   (Arch/Omarchy, Hyprland). Recommend the shape with reasons, e.g. a local daemon (systemd user
   service) + CLI + MCP server + a Hermes plugin/skill + a tiny API, sharing one store; how Chief (local,
   small context: every byte of tool schema counts) and Hermes sessions call it; how it relates to
   Hermes' existing memory/session_search/hindsight (complement, not duplicate); privacy (local-first).
   Then a staged build order: organ by organ, each with: what is extracted from which files, what is
   rewritten, the interface, acceptance tests (behavioural, live, measurable), and what it unlocks for
   Chief. Phase 2 starts only after Marcel approves this design.
4. HOME: propose where the new code lives (existing YURI-OS-MUSUBI vs a new ICM project under
   PROJECTS/), as an ICM workspace (AGENTS.md L0, CONTEXT.md L1, numbered stages). Do not create it yet;
   describe it.

## Team
You are the lead (reasoning-heavy). Spawn leaf subagents with delegate_task for the wide, mechanical
parts (filesystem search per drive, per-organ code reading, running test suites), each with a complete
self-contained brief and the read-only/no-secrets rules. Verify their claims yourself before using them
(spot-check paths and functions). Load skills `unslop` (all prose) and `design-nexus` (the HTML).

## Deliverables
- ~/NEXUS_AI_CENTER/LOCAL-AI-LAB/research/38-yuri-extraction.md (written incrementally): inventory
  table, organ map with status + evidence, design, staged build order, home proposal, open questions
  for Marcel (max 5, sharp).
- ~/NEXUS_AI_CENTER/LOCAL-AI-LAB/reports/yuri-os-design.html: visual-first (design-nexus, text budget:
  one visual + one headline + one caption per section): organ/layer schematic, current status heatmap,
  target architecture (harness -> YURI -> OS, with Chief and Hermes as clients), build-order timeline.
Self-check: every path cited exists, every status claim has evidence, nothing written outside the two
deliverables and scratch, no repo state changed (`git -C <repo> status` unchanged before/after).
