# 38 - YURI out of Haze, into the OS (phase 1: find, map, design)

Date: 2026-10-13. Brief: `LOCAL-AI-LAB/research/BRIEF-38-yuri-extraction.md`. Visual: `LOCAL-AI-LAB/reports/yuri-os-design.html`.
YURI is Marcel's cognitive governance architecture. Memory and recall are one organ of it, not its definition.
Phase 1 only: nothing in any Haze or YURI repo was changed. All probes ran in scratch copies under
`~/.hermes/cache/scratch/b38/` (a `git archive` export of Haze plus reflinked `node_modules`).

## TL;DR

- Latest YURI code: Haze commit `074768b5` (2026-09-27, ref `origin/fix/hrn-5-cli-served-model` inside
  `~/projects/haze`). It differs from the v1.4.0 checkouts on 2 YURI files only (`src-tauri/src/yuri_capture_sink.rs`,
  `src/lib/yuri-sessions/store.ts`, 12+/7-). The Haze `v1.5.0` branch has no newer YURI change.
- Latest governance/control-plane source: `04_PROJECTS/YURI-OS-MUSUBI` (HEAD `e2f81876`, 2026-08-10, plus ~190 uncommitted edits).
  This is where YURI started (macOS, Claude Code hooks). Haze holds a Rust+TS re-implementation of a subset.
- Blocker: the Kingston Windows drive (`nvme0n1p3`) does not mount (dirty NTFS). Uncommitted work in
  `C:\NEXUS_AI_CENTER\04_PROJECTS\Haze\versions\v1.5.0` is unread. Committed refs up to 2026-09-27 are readable.
- Status: the data core works (Rust store, SEARCH indexer, ontology, admission: tests pass headless). The model-driven
  organs (extract, drain, synthesis) are tested in TS but tied to Haze IPC and the Haze model router. Governance proper
  (protected surfaces, evidence grammar, placement) exists only in MUSUBI as docs and Node scripts.
- Design: one Rust binary `yuri` with one local store. Harnesses reach it through Claude-Code-dialect shell hooks
  (Hermes already speaks that dialect), a CLI, and an MCP server. A systemd user unit runs the watcher. Chief gets
  zero extra tool schema bytes. Nine stages, governance in stage 3.

## 0. Drives and reachability

| Drive | Path | State |
|---|---|---|
| Linux root/home (btrfs) | `/home/nexuslink` | mounted, searched |
| Samsung DATA (ntfs3) | `/mnt/DATA` | mounted. Holds only `OMARCHY_*.txt` and `System Volume Information` |
| T7 SSD (exfat) | `/run/media/nexuslink/T7` | mounted, searched |
| Kingston Windows C: (ntfs3, `nvme0n1p3`) | `/run/media/nexuslink/82CC5F65CC5F5311` | NOT READABLE. Kernel: `ntfs3(nvme0n1p3): volume is dirty and "force" flag is not set!`. Automount fails, `udisksctl mount -o ro` is refused by polkit, sudo needs a password. |

`~/projects/haze` has `origin` set to the Kingston path
(`/run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/PROJECTS/HAZE/VERSIONS/BETA/v1.4.0`). Its fetched
refs include `origin/haze/v1.5.0` (a3724668, 2026-09-25, package.json `1.5.0`) and
`origin/fix/hrn-5-cli-served-model` (074768b5, 2026-09-27). So committed Kingston work up to 2026-09-27 is readable with
`git -C ~/projects/haze show <ref>:<path>`.

## 1. Inventory

Recency is ranked by the last commit that touched a YURI path
(`git log --all -- ':(glob,icase)**/*yuri*' ':(glob,icase)**/*yuri*/**'`).

### Haze-embedded YURI (Rust `src-tauri/src/yuri*`, TS `src/lib/yuri*`, docs)

| Rank | Copy | Branch / commit | Last YURI commit | YURI files | Note |
|---|---|---|---|---|---|
| 1 | `~/projects/haze`, ref `origin/fix/hrn-5-cli-served-model` | `074768b5` (2026-09-27) | `ad6763b0` 2026-09-27 "fix(desktop): headless runs its tools again" | 185 tracked, 1.74 MB | NEWEST. Ref only (fetched from Kingston), read via `git show`. Exported to scratch for tests. |
| 2 | `~/projects/haze`, refs `origin/haze/v1.5.0`, `origin/fix/v1.5.1-batch` | `a3724668`, `f2489a94` (2026-09-25) | `3a85c0fe` 2026-09-24 | 185 | v1.5.0 adds no YURI change over 3a85c0fe |
| 3 | `PROJECTS/HAZE/VERSIONS/BETA/v1.4.0`, branch `v1.4.0` | `0a552783` (2026-09-24) | `3a85c0fe` 2026-09-24 | 185 | Working tree dirty in 3 non-YURI files. Not an ancestor of rank 1. Differs from rank 1 on 2 YURI files. |
| 4 | `~/projects/haze` working tree, branch `v1.4.0-subagent-acp+comms` | `c4975d44` (2026-09-24) | `aefb2e0b` 2026-09-23 | 185 | Newest file mtime 2026-10-10 is untracked `REVIEWS/`, not YURI |
| 5 | `04_PROJECTS/Haze/haze-main`, branch `v1.4.0` | `95a959b7` (2026-09-23) | `74325c22` 2026-09-24 | 185 | Old carried snapshot. Has a live index: `.haze/index/search.db` 18.1 MB, `graph.db` 1.2 MB |
| 6 | `PROJECTS/HAZE/VERSIONS/RELEASE/v1.3.670` | detached `ddf90a2` (2026-09-11) | `63ffbba` 2026-09-22 (`origin/bug-fixes-2`) | 164 | Last shipped build |
| - | Kingston `C:\NEXUS_AI_CENTER\04_PROJECTS\Haze\versions\v1.5.0` + worktrees | unknown | unknown | unknown | Unreadable (dirty NTFS). Only its committed refs are known. |

### YURI-OS-MUSUBI family (governance control plane, origin of YURI)

| Copy | Kind | HEAD | Newest content | Size | Note |
|---|---|---|---|---|---|
| `04_PROJECTS/YURI-OS-MUSUBI` | git repo, `main` | `e2f81876` 2026-08-10 | 2026-09-06 (`_SYSTEM/state/...`), ~190 dirty files | 15 GB | Canonical. 639 `.mjs` scripts + 364 tests in `_SYSTEM/Scripts`. No `node_modules` anywhere. 905 files hardcode `/Users/marcelspatz`. |
| `/run/media/nexuslink/T7/NEXUS_AI_CENTER/04_PROJECTS/YURI-OS-MUSUBI` | git repo | same `e2f81876` | 2026-09-06 | 84 GB | Same lineage, full history on exfat |
| `04_PROJECTS/YURI-BUSINESS` | dead worktree (`.git` points at `/Users/marcelspatz/YURI-OS-MUSUBI/.git/worktrees/YURI-BUSINESS`) | - | 2026-07-20 | 1.4 GB | Older, smaller branch of MUSUBI |
| `/run/media/nexuslink/T7/NEXUS_AI_CENTER/04_PROJECTS/YURI-BUSINESS` | plain dir | - | superset of the home copy | 1.9 GB | Has `_SYSTEM/yuri-wiki`, `YURI-COGNITION.md`, `YURI-ARCHITECTURAL-OVERVIEW.md` that the home copy lacks |
| `PROJECTS/YURI-OS-MUSUBI`, `PROJECTS/YURI-BUSINESS` | launch stubs | - | 2026-09-22 | 8 KB | Route to `C:\...` Windows paths that are stale on Linux |
| T7 `YURI-OS-MUSUBI-Backup.sparsebundle` | macOS disk image | - | 2026-07-17 | 78 GB | Not mountable here; content predates the live repo |
| T7 `YURI-Backend-Runtime-v1.sparsebundle` | macOS disk image | - | 2026-07-17 | 39 MB | Not mounted |
| T7 `YURI-OS-MUSUBI-Sealed-Recovery*.sparsebundle` (2) | broken images | - | 2026-07-16 | 640 KB each | No `Info.plist`, 0 bands. Not sealed, nothing to recover |

### Schematics and design docs

| Item | Path | Note |
|---|---|---|
| Authoritative Haze dev doc | `docs/yuri.md` in the Haze trees (export: `~/.hermes/cache/scratch/b38/haze-latest/docs/yuri.md`) | Contradicts itself on planned vs landed (see 2.4) |
| Wiring truth | `dev/proofs/yuri-wiring-coverage-table.md`, `dev/agents-md/map-yuri-api.md` (Haze) | Per-organ wired/cut claims |
| Organ notes | `src/lib/yuri-organs/ORGANS.md` (Haze) | Pre-cut description |
| Design canon | `docs/research/ARCT-YURI-SYNTHESIS.md`, `HAZE-ICM-REFACTOR-PLAN.md`, `ICM-CANON.md`, `arct-vps-brain-architecture.md` (Haze) | The VPS doc is the only written daemon design (systemd timers on a server) |
| Governance contract | `04_PROJECTS/YURI-OS-MUSUBI/_SYSTEM/yuri-origin.md` | Protected surfaces, mutation and evidence contracts |
| Architecture graph | `04_PROJECTS/YURI-OS-MUSUBI/_SYSTEM/yuri-graph.json` | 232 nodes, 443 edges (YURI's own wiring as data) |
| Dashboards | `04_PROJECTS/YURI-OS-MUSUBI/yuri-os-dashboard.html`, `04_PROJECTS/GeneratedContent/yuri-os-dashboard.html`, `yuri-os-v4-design-sheet.html`, `02_RESOURCES/RESEARCH/circuitry/yuri-chip-die.html` | Visual canon |
| Investor deck | `04_PROJECTS/YURI-OS-MUSUBI/02_RESOURCES/INVESTOR-DECK/` | `~/Desktop/NEXUS-LINK-AMS-Investor-Pack/` cited in the design-nexus skill does not exist on this box |

### Name collisions (not YURI code)

- `~/.hermes/profiles/yuri`: an active Hermes bot profile, "YURI: Conductor" of the bot fleet (`cursor/grok-4.6`). Its
  name collides with the architecture.
- `04_PROJECTS/Orchestra/Funnelink/engine/crates/yuri-cli`: a Rust CLI that builds a binary named `yuri` for bug-bounty
  lead ranking (362 LOC, 2026-07-25). Installing both would clash on `yuri` in `PATH`.

## 2. Organ map (status with evidence)

Legend: works = tests pass and a live caller exists. partial = tested but unwired, or wired but degraded/headless
failures. dead = present, tests pass, zero importers. broken = fails to run. doc = contract or data only.

### 2.1 Haze organs (export of `074768b5`)

TS: `npx vitest run src/lib/yuri* src/settings/YuriPanel` gave `Test Files 40 passed (40) / Tests 451 passed (451)`.
Rust: built once with `cargo test -p haze-desktop --lib --test yuri_contract --test yuri_e2e --no-run` (EXIT=0).

| Organ | Entry points | Store / format | Haze coupling | Status | Evidence |
|---|---|---|---|---|---|
| Store (paths, connection registry, migrations) | `src-tauri/src/yuri/{mod,db,schema}.rs` | `<ws>/.haze/index/search.db` (v2), `graph.db` (v4), `PRAGMA user_version` | none | works | 13 unit tests pass; `examples/yuri_index_path` created both DBs, graph.db has all 11 tables + 2 cost views |
| SEARCH (FTS5/BM25 corpus) | `src-tauri/src/yuri_index.rs` (`index_full`, `index_incremental`, `index_file`, `search`) | `yuri_docs` FTS5 `porter unicode61`, `yuri_files` | none | works | `indexed: IndexStats { indexed: 6, skipped: 0, removed: 0, errors: 0, total_docs: 6 }`; `MATCH '"scoreHit"'` returned the right doc |
| Watcher | `src-tauri/src/yuri_watch.rs` (`maybe_start`, 500 ms debounce) | search.db | `tauri::Emitter`, `AppHandle` | partial | 5 unit tests pass; needs an AppHandle to run |
| Capture (RAW, append-only) | TS `src/lib/yuri-capture/hook.ts` (`createCaptureHook`); Rust `yuri_capture`, `yuri_capture_sink.rs` | `captures(id, session_id, ts, kind, payload)` | Tauri IPC; haze-harness `CaptureSink` trait | partial | TS 12 tests pass, wired in 3 loops (`agent/harness.ts:1155`, `code-agent/haze-harness.ts:1542`, `engine.ts:372`). Rust sink: 4 tests fail headless, all on `consent gate used before app init` |
| Sessions mirror | `src/lib/yuri-sessions/{store,migrate}.ts` | `sessions` | localStorage, account scope | works (Haze only) | 20 tests pass. Not needed outside Haze: Hermes keeps transcripts in `state.db` |
| Extract (model proposes) | `src/lib/yuri-extract/{extract,fanout,prompt,session}.ts`; Rust validator `yuri_ontology.rs` | `envelopes` (pending/admitted/rejected), `yuri.ontology.v1`, 13 predicates | `chatWithTools`, `resolveRoutedModel`, IPC | partial | TS 30 tests pass, needs a model, not run live. Rust ontology 9 tests; `yuri_contract` `test result: ok. 5 passed` (re-run by lead under the GPU lock) |
| Admission (deterministic gates) | `src-tauri/src/yuri_admit.rs` (`admit_pending_envelopes`) | `entities`, `aliases`, `assertions` (quote + locator + supersede), `resolution_log` | none | works (unit) | 13 unit tests pass; no live envelope fed |
| Declared bridge | TS `src/lib/yuri-bridge/harvest.ts`; Rust `yuri_assert_declared` | entities from the Haze workspace registry | `workspace-context` registry | partial | 13 TS tests pass, wired via scheduler; `unifiedResolve` dead; Rust test `declared_bridge_envelope_passes_the_admission_schema_gate` fails headless (consent) |
| Recall (context pack) | TS `src/lib/yuri-recall/pack.ts` (`assembleContextPack`); Rust `yuri_context_pack` | L0 500 / L1 1500 / L2 1000 / L4 300 tokens, ceiling 3300 | IPC, compaction token estimate | works (TS), duplicate (Rust) | 13 TS tests pass, wired `haze-harness.ts:1566`, `engine.ts:415`. Two implementations, three `ContextPack` type shapes |
| Graph query | Rust `yuri_entities`, `yuri_assertions`, `yuri_graph_walk`, `yuri_graph_fts.rs` | `graph_fts` | consent gate in command layer | partial | graph_fts 3 tests pass; command layer fails headless |
| Agent tools | `src-tauri/src/yuri_tools.rs`, `src/lib/yuri/tools.ts` (`yuri_search`, `yuri_read`, `yuri_graph_walk`, `yuri_recall`) | - | IPC | works in-app | 7 Rust unit tests; TS wired in 3 loops. Haze CLI `--yuri` is capture-only |
| Distill (drain, synthesis, projections) | TS `src/lib/yuri-distill/`; Rust `yuri_distill_cmds.rs` | `sessions.summary`, `.haze/knowledge/{decisions,lessons,map}.md` | model call, IPC, fs | partial | TS 30 tests pass; Rust 8 commands, 0 tests |
| Scheduler | `src/lib/yuri-engine/scheduler.ts` (7 jobs, hourly) | - | in-app timers, settings | works (Haze only) | 17 tests pass; started from `code/CodeView.tsx:1935` |
| Energy kernel (gate, breaker) | `src/lib/yuri-energy/`; Rust `yuri_energy_cmds.rs` | energy captures | IPC | partial | 91 tests pass; one consumer (`yuri-extract/fanout.ts:251`); Rust 0 tests |
| Cost ledger | `src/lib/yuri-cost/`; Rust `yuri_cost_cmds.rs` | `cost_ledger` (micro-USD) + rollup views | IPC, pricing | partial | TS 40 tests pass; Rust 4 tests fail headless (consent) |
| Skills recall | `src/lib/yuri-skills/recall.ts` | BM25 over skills | Haze skill refs | works (Haze only) | 15 tests pass; `recallCapabilities` dead |
| ICM templates | `src/lib/yuri-icm/` | `.haze/stages/` | fs IPC | partial | 42 tests pass; instantiation has no caller |
| Design-frame indexing | `src/lib/yuri-design/` | search.db | canvas SceneStore | works (Haze only) | 15 tests pass |
| Nerve | `src/lib/yuri-organs/nerve.ts` | `nerve.event` captures | IPC | works | imported by `yuri-capture/hook.ts:22` |
| Claimgate, filing, openprocess, workledger, paths | `src/lib/yuri-organs/*.ts` | - | none | dead | tests pass (61 in organs dir), only importer is `yuri-organs/index.ts` (grep by lead) |
| End-to-end proof | `src-tauri/tests/yuri_e2e.rs` | - | consent | broken | lead re-ran the built test under the GPU lock: `[b] indexed 15 docs`, then `panicked at src-tauri/tests/yuri_e2e.rs:272:10`, `test result: FAILED. 0 passed; 1 failed` |

Rust lib filter `yuri`: `test result: FAILED. 65 passed; 10 failed` (leaf run; see the self-check). All 10 failures share one root cause: `yuri_commands::workspace_root` (`yuri_commands.rs:38`) calls
`consent::gate` (`:47`), which errors before app init. No YURI test calls `consent::init_store_dir_for_tests`.

### 2.2 MUSUBI organs (`04_PROJECTS/YURI-OS-MUSUBI`, probed in a scratch copy)

| Organ | Entry point | Store | Status | Evidence |
|---|---|---|---|---|
| Governance contract | `_SYSTEM/yuri-origin.md`, root `AGENTS.md` | markdown | doc | Protected surfaces, mutation contract, evidence grammar `TERM_COUNT`/`FILE_COUNT`/`MATCH`, `RESULT_LABEL` grammar |
| Protected surfaces / safety core | `_SYSTEM/Scripts/lane-kernel.mjs`, `policy/yuri-safety-core.mjs`, `yuri-protected-paths.mjs` | json prefixes in `config/artifact-registry.json` | unverified | tests exist; not run in this pass |
| Hook rail | `.claude/hooks/*.js`, `_SYSTEM/Scripts/yuri-hook-registry.mjs` | Claude Code hook events | partial | `--validate` fails `ERR_MODULE_NOT_FOUND .omp/hooks/pre/url-safety-guard.js`; Claude-Code-specific |
| Memory kernel | `_SYSTEM/Scripts/memory-kernel.mjs` (`surfaces`, `recall`, `propose`, `decide`) | `_SYSTEM/OS_KERNEL/memory.db`, `state/memory-canonical/` | works | `surfaces` returned `{"ok":true,...}`; `memory-canonical-store.test.mjs` 19 pass / 0 fail |
| AI search, xref, propagation, work ledger | `yuri-search.mjs`, `xref-query.mjs`, `propagation-scan.mjs`, `work-ledger.mjs` | `OS_KERNEL/search-index.db` (1.63 GB) | broken | `ERR_MODULE_NOT_FOUND: Cannot find package 'better-sqlite3'` (lead confirmed the import in `xref-query.mjs` and that no `node_modules` exists) |
| Architecture graph + navigation | `yuri-graph-unify.mjs` (`stat`, `verify`), `yuri-navigate.mjs` | `_SYSTEM/yuri-graph.json` + 3 generated views | works | `canonical: 232 nodes, 443 edges`; `verify` gives `lossless=true`; navigate test 50 pass / 0 fail |
| Artifact placement | `artifact-registry.mjs --classify/--validate` | `config/artifact-registry.json` | works | `--classify "_SYSTEM/docs/new-plan.md"` gave `ruleId: system-doc`; `--validate` EXIT=0 |
| Context cascade | `_SYSTEM/context/context-registry.json` | 14 packets | doc/data | read only |
| MURE roles | `_SYSTEM/mure/` (26 cards) | md/json | doc/data | Overlaps Hermes bot profiles |
| Backend runtime | `_SYSTEM/backend/src/server.ts` | `backend/data/yuri.db` (protected) | broken | no `node_modules` |
| launchd services | `_SYSTEM/launchd/*.plist` | - | macOS only | `/opt/homebrew/bin/node`, `launchctl`; marked DISARMED |

### 2.3 What Hermes already has (so YURI does not duplicate it)

| Hermes part | Path | What it is | YURI relation |
|---|---|---|---|
| Built-in memory | `~/.hermes/memories/{MEMORY,USER}.md` | small curated facts, always injected | leave alone |
| hindsight | `~/.hermes/plugins/hindsight/`, provider in `config.yaml` `memory.provider: hindsight` | embedding memory bank, auto retain/recall (default profile only; Chief has none) | different job: YURI KNOWLEDGE only admits quoted, gated, superseding facts |
| session_search | `~/.hermes/hermes-agent/tools/session_search_tool.py`, FTS5 in `~/.hermes/state.db` | transcript search | YURI reads `state.db` read-only as its capture source instead of re-capturing |
| Shell hooks | `~/.hermes/hermes-agent/agent/shell_hooks.py` | `hooks:` config, stdin JSON, exit 2 blocks `pre_tool_call`, `{"context": ...}` adds context | the YURI governance and recall entry, same dialect as Claude Code |
| `pre_llm_call` context | `agent/turn_context.py:793` | plugin/hook context appended to the user message, `is_first_turn` flag, oversize spill | where the recall pack goes |
| MCP | `config.yaml` `mcp_servers` | stdio or http servers, deferred via `tool_search` | `yuri mcp` for full Hermes sessions |
| Chief | `~/.hermes/profiles/chief/config.yaml` | Gemma 4 12B on llama.cpp, `context_length: 65536`, 10 tools = 15,931 bytes of schema (about 4K tokens), has `terminal` | reach YURI through `terminal` + hooks, add no tool |

### 2.4 The mess

1. `docs/yuri.md` says admission, watcher startup, schedulers and agent tools are "planned" in its body (lines
   194-216, 310-332, 367-368) and "landed" in its last section (lines 423-441). The code agrees with the last section.
2. Five organs were "cut" by commit `3c4f05d6` and merge `daa24ef4`, and the release notes say so. Merge `aefb2e0b`
   (PR 187) brought the files back. They are in the tree, re-exported by `yuri-organs/index.ts`, and imported nowhere else.
3. The `haze` CLI capture rail (`crates/haze-harness/src/bin/yuri.rs`) carries a hand copy of the graph schema at
   `GRAPH_SCHEMA_VERSION = 3` (line 213) while the desktop is at 4 (`yuri/schema.rs:20`). A crate dependency is
   impossible there (cycle), so the schema forked.
4. Parallel Rust and TS implementations: context pack, tool definitions, ontology (pinned by
   `fixtures/yuri/envelope.contract.json`), cost ledger, distill reads, energy. `src/lib/yuri/types.ts` has drifted from
   the wire; 11 of 19 `api.ts` wrappers have no caller.
5. The flagship e2e test and `examples/yuri_probe.rs` are red headless (consent gate), so the "live proof" cannot be
   reproduced with `cargo test`.
6. Naming drift: `docs/yuri.md` line 3 says "not a memory layer", while Haze `AGENTS.md:3`, `HAZE-ICM-REFACTOR-PLAN.md:53`
   and `map-yuri-api.md:5` call it a memory layer or engine.
7. Three Haze research docs (`yuri-memory-architecture.md`, `yuri-memory-layer-spec.md`, `yuri-memory-vs-search-design.md`)
   describe the MUSUBI memory model (Track A/B, cold store), which does not exist in Haze, without a banner saying so.
8. MUSUBI: `_SYSTEM/_SYSTEM/OS_KERNEL/` is a nested duplicate tree; junk dirs named `~` and `bashcd ~/YURI-OS-MUSUBI && find _SYSTEM`
   at the repo root; a 1.63 GB search index under `_SYSTEM/OS_KERNEL/`.
9. No document places YURI between a harness and a desktop OS. Haze put it inside the app; the ARCT VPS doc put it on a
   server. The OS-layer framing is new in this brief.

## 3. Design: YURI as an OS layer

### 3.1 Shape

```
  harnesses           Chief (Gemma, 64K)    Hermes sessions    Claude Code / Codex / others
      |                    |                      |                     |
      |   shell hooks (Claude-Code dialect: stdin JSON, exit 2 = block, {"context":...})
      |   CLI via terminal          MCP stdio (deferred tools)
      v                    v                      v                     v
  +-------------------------------- yuri (one Rust binary) ----------------------------+
  | govern  : pre_tool_call gate over policy (protected surfaces, write rules)          |
  | capture : ingest harness transcripts (Hermes state.db, read-only) -> RAW, append-only|
  | search  : FTS5 corpus of configured roots          (search.db)                      |
  | know    : extract (local model) -> envelopes -> admission gates -> graph (graph.db)  |
  | recall  : bounded pack on first turn: rails + evidence quotes + pointers            |
  | distill : drain, synthesis, decisions/lessons/map projections                       |
  +-------------------------------------------------------------------------------------+
      |  systemd --user: yuri-watch.service (watcher), yuri-distill.timer (hourly, GPU lock)
      v
  OS: ~/.local/share/yuri/{search.db,graph.db}, ~/.config/yuri/{roots,policy}.toml, filesystem
```

Choices and reasons:

- One Rust binary. The parts that would corrupt knowledge if wrong (schema, index, ontology, admission) already exist
  in Rust, run without Tauri, and pass headless. Haze's own rule (`docs/yuri.md:21-24`) put them in Rust for that reason.
  The TS organs become references; their tests become port fixtures.
- No custom daemon or HTTP API. SQLite in WAL mode lets the CLI, the hook, the MCP server and the watcher share the
  store. The only long-running process is the watcher, as a systemd user unit with `Nice=19`,
  `IOSchedulingClass=idle`, `CPUQuota=20%`, `MemoryMax=256M`. Model-driven jobs run from a timer and take the GPU lock.
  Add an API when a client cannot spawn a process.
- Shell hooks, not a Python plugin. Hermes `shell_hooks.py` already speaks the Claude Code dialect. One `yuri hook <event>`
  command serves Hermes, Claude Code, Codex and Cursor. That is the "between any harness and the OS" position, with no
  per-harness code. Hooks fail open, except governance blocks, which are explicit.
- Capture reads `state.db`, not every tool call. Hermes already records each message and tool call. `yuri ingest hermes
  --profile <p>` copies new rows into `captures` with a watermark. That is one code path, adds no cost to the loop, and
  keeps RAW immutable even after Hermes prunes a session.
- One store per machine at `~/.local/share/yuri/`, not one per workspace. Rows keep their absolute path and workspace,
  so recall can filter by the session's `cwd`. The schema already has `sessions.workspace` and `entities.scope`.
- Chief adds zero tool schema. Chief has `terminal`; a 3-line note in its SOUL lists `yuri search|read|recall`. The
  first-turn hook injects a pack capped at 600 tokens (about 1% of 64K). Full Hermes sessions use `yuri mcp`, deferred
  behind `tool_search`, so its schema costs nothing until needed.
- Local-first. The extraction and drain lanes call only the local OpenAI-compatible endpoint (Chief's llama.cpp), never
  a cloud model by default. The indexer skips everything the policy marks protected (`.env*`, `auth.json`, `*.pem`,
  `01_CREDENTIALS/`, keys) before reading bytes. The DB files are mode 0600.
- Complement Hermes, do not replace it. Built-in memory stays the always-on fact sheet, hindsight stays the associative
  bank, session_search stays transcript search. YURI adds what none of them do: a gate on actions, a file corpus, and a
  knowledge graph where every fact has a verbatim quote and a supersede chain.

### 3.2 Interface (the whole surface)

```
yuri index [--root P]            yuri search Q [--kind K] [--limit N]     yuri read URI
yuri status                      yuri recall "TASK" [--budget TOKENS]     yuri walk URI [--depth D]
yuri ingest hermes --profile P   yuri extract [--limit N]  yuri admit     yuri distill
yuri hook pre_tool_call|pre_llm_call|on_session_end   (stdin JSON in, Claude-Code dialect out)
yuri mcp                          (stdio: yuri_search, yuri_read, yuri_recall, yuri_walk)
yuri watch                        (systemd unit)
```

Output defaults to short text; `--json` for programs. URIs keep the `haze://` scheme readers working, with
`yuri://file/<abs path>` for new rows.

### 3.3 Staged build order

Each stage ships alone, gets measured, and leaves Chief better off. Builds and test runs use
`flock -s|-x ~/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu.lock env CAP=12G CPUS=6-11,18-23 CPUW=20 ~/.local/bin/jobcap nice -n 10 ionice -c 3 <cmd>`
with `-j 6` at most, shared lock to build, exclusive lock to run tests.

| # | Organ | Extract from (Haze export `074768b5`) | Rewrite | Acceptance (live, measurable) | Unlocks for Chief |
|---|---|---|---|---|---|
| 1 | Store + SEARCH | `src-tauri/src/yuri/{mod,db,schema}.rs`, `yuri_index.rs`, `yuri_graph_fts.rs`, `yuri_ontology.rs` as-is (2,671 LOC) | paths to XDG, roots from `roots.toml`, drop `consent::gate`, CLI `index/search/read/status` | the moved Rust unit tests pass; `yuri index` over `~/NEXUS_AI_CENTER` (minus `node_modules`, `target`, protected) finishes with `errors: 0`; `yuri search` p95 under 50 ms over 20 fixed queries; a planted `.env` is never indexed | `yuri search` through `terminal` instead of `grep -r` over 15 GB |
| 2 | Watcher | `yuri_watch.rs` debounce + `index_file` core | drop `tauri::Emitter`; systemd user unit with the caps above | edit a file, searchable within 2 s; idle CPU under 1%; RSS under 100 MB; no lag-watchdog hit during the GPU ladder | the index stays fresh without re-runs |
| 3 | Govern | policy from `YURI-OS-MUSUBI/_SYSTEM/yuri-origin.md` (protected surfaces, write rules) and `config/artifact-registry.json` prefixes | `yuri hook pre_tool_call` in Rust, policy as `policy.toml`; each block is written as a capture | live Hermes and Chief sessions: a write to `.env` or `01_CREDENTIALS/` is blocked with a reason, reads pass; hook adds under 10 ms p95; 0 false blocks over one day of normal sessions | Chief can run with fewer approval prompts because hard rails exist |
| 4 | Capture | capture semantics from `yuri-capture/hook.ts` (8 KB cap, fire-and-forget), `captures` table | `yuri ingest hermes` reading `state.db` read-only with a watermark; `on_session_end` hook triggers it | N new messages give N captures; a rerun adds 0; deleting the Hermes session leaves captures intact; ingest of the default `state.db` (3.3 GB) stays under the job caps | Chief and Hermes sessions become one RAW record |
| 5 | Recall | Rust `yuri_context_pack` (keep), budget rules from `yuri-recall/pack.ts` | delete the TS twin; `yuri hook pre_llm_call` returns the pack on `is_first_turn` only | pack never exceeds `--budget` (count with the model tokenizer); a cold store returns rails only; A/B over 10 fixed Chief tasks: fewer search tool calls, same or better answers judged blind | Chief starts each session pointed at the right files |
| 6 | Know (extract + admit) | `yuri_admit.rs` as-is; prompt and checks from `yuri-extract/{prompt,extract}.ts`; contract `fixtures/yuri/envelope.contract.json` | extract lane in Rust calling the local endpoint, under the GPU lock | the envelope contract fixture passes; an edge whose quote is not a substring of the source is rejected; admitting the same batch twice changes 0 rows; precision of 20 hand-checked admitted facts is 18 or more | Chief can cite decisions with a quote and a source |
| 7 | Distill | `yuri-distill/{drain,synthesis,projections,format}.ts`, `yuri_distill_cmds.rs` | Rust; hourly timer | `decision_signal=0` files nothing; projections are byte-identical on rerun; synthesis drafts only after 3 decision sessions | `decisions.md`, `lessons.md`, `map.md` that Chief can read cheaply |
| 8 | MCP | tool schemas from `yuri_tools.rs` | `yuri mcp` stdio | `hermes` lists 4 `mcp__yuri__*` tools; schema bytes measured and recorded; deferred under `tool_search` | full Hermes sessions use YURI mid-turn |
| 9 | Graph + xref | `yuri-graph.json` and `yuri-graph-unify.mjs` semantics from MUSUBI; Rust `yuri_graph_walk` | import the architecture graph as declared entities; `yuri walk` | `yuri walk` from any of the 232 nodes matches `yuri-navigate.mjs` output on 10 sampled nodes | "what does X touch" answered from data |

Left out until a need shows up: the cost ledger (Hermes already tracks usage), the energy kernel (start with plain
budget caps on the extract lane), the dead organs (claimgate, filing, openprocess, workledger, paths), ICM templates
(Hermes skills cover them), design-frame indexing and the sessions mirror (Haze-only), skills recall (Hermes has
`skills_list` and `tool_search`), OMP fleet and MURE (Hermes profiles and `delegate_task`).

## 4. Home

Proposal: a new ICM project at `PROJECTS/YURI-OS/`, not inside `04_PROJECTS/YURI-OS-MUSUBI`. Reasons: MUSUBI is a
15 GB macOS-era monorepo with ~190 uncommitted edits, 905 files hardcoding `/Users/marcelspatz`, protected surfaces and
no installed dependencies. Building there mixes new code with a tree nobody can run. MUSUBI stays the read-only
reference for governance; the Haze export stays the reference for the data core. Nothing gets created until Marcel approves.

```
PROJECTS/YURI-OS/
  AGENTS.md            L0, under 60 lines: what YURI is (cognitive governance), rules, where things live
  CONTEXT.md           L1, under 80 lines: task -> stage routing
  stages/
    01-store-search/   CONTEXT.md (contract + acceptance), references/, output/
    02-watch/  03-govern/  04-capture/  05-recall/  06-know/  07-distill/  08-mcp/  09-graph/
  yuri/                one Cargo crate (lib + bin), workspace-free
  policy/policy.toml   protected surfaces and write rules (from yuri-origin.md)
  deploy/              yuri-watch.service, yuri-distill.{service,timer}
  references/          pointers (not copies) to the Haze export commit 074768b5 and MUSUBI paths
```

Stage status comes from scanning each `output/`, never stored. The `PROJECTS/YURI-OS-MUSUBI` stub should then route to
the new project.

## 5. Open questions for Marcel

1. The Kingston drive is dirty NTFS and will not mount. Can you boot Windows once and run `chkdsk C: /f` (or let me mount
   it with `ntfs-3g -o ro` via sudo), so I can check the v1.5.0 tree for uncommitted YURI work after 2026-09-27?
2. Is the Rust-only rewrite acceptable? The TS organs (451 passing tests) would become references and fixtures, not
   shipped code.
3. Should YURI's governance gate be allowed to block Hermes and Chief tool calls (exit 2), or only warn at first?
4. One machine-wide store at `~/.local/share/yuri/`: which roots go in the corpus beyond `~/NEXUS_AI_CENTER`
   (`~/.hermes/skills`? `~/projects`?)
5. Two things already use the name: the Hermes profile `yuri` (fleet conductor) and the Orchestra `yuri` binary. Rename
   the profile, or call the binary something else?

## 6. Self-check

- Repo state: `git status --porcelain` (md5 of full output) and `HEAD` were recorded before any work for
  `PROJECTS/HAZE/VERSIONS/BETA/v1.4.0`, `PROJECTS/HAZE/VERSIONS/RELEASE/v1.3.670`, `~/projects/haze`,
  `04_PROJECTS/Haze/haze-main` and `04_PROJECTS/YURI-OS-MUSUBI`. After the work all five match.
  No checkout, fetch or worktree command ran on any of them; every read used `git log/show/ls-tree/archive`.
- Writes: the two deliverables, plus scratch under `~/.hermes/cache/scratch/b38/` (Haze export, reflinked `node_modules`,
  an 11 GB Cargo target dir, leaf reports `inv-fs.md`, `musubi.md`, `organs-ts-a.md`, `organs-ts-b.md`, `organs-rust.md`,
  `docs.md`, `hermes-side.md`). The scratch target dir can be deleted when phase 2 starts its own build.
- Paths: 129 backticked paths in this file were checked with a script. Every real path exists. The non-existent ones are
  intentional (the Kingston and `/Users/marcelspatz` paths, git ref names, runtime outputs such as `.haze/knowledge/`).
- Evidence verified by the lead, not only by leaves: TS 451/451 (run by lead); `yuri_contract` 5 passed and `yuri_e2e`
  panic at line 272 (re-run by lead under `flock -x` and the job caps); the consent gate at `yuri_commands.rs:38,47`;
  `GRAPH_SCHEMA_VERSION` 3 vs 4; the dead-organ importers; `better-sqlite3` import and absent `node_modules` in MUSUBI;
  `pre_llm_call` context injection (`agent/turn_context.py:793`) and shell-hook dialect (`agent/shell_hooks.py:1-5`).
  Taken from leaves without a second run: Rust lib 65/10 (the lead's capped re-run queued behind the GPU chain on the
  lock for 10 minutes and was cancelled so it would not delay the ladder), MUSUBI probe outputs, Chief schema bytes.
- House rules: the first Rust build (`-j 12`, before the rule arrived) ran uncapped. Every later run used the
  `flock` + `jobcap` + `nice` + `ionice` wrapper.
