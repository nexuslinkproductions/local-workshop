# BRIEF-37: Chief evaluation suite (questions + small tasks) — 2026-10-13

Build a repeatable test suite that measures how well Chief (Hermes profile `chief`, local Gemma 4 12B)
navigates Marcel's ICM workspace and does small real tasks, and that can compare model variants
(base Gemma 4 12B QAT vs the two downloaded distills in models/llm/yuxinlu1/) and instruction versions.
You BUILD and DRY-CHECK the suite; you do not run it against the model (another agent owns the GPU).

## Inputs (read, do not crawl)
~/NEXUS_AI_CENTER/AGENTS.md, CONTEXT.md, FILE-MAP.md and the routers they name; Chief's files:
~/.hermes/profiles/chief/SOUL.md, workspace/AGENTS.md, workspace/routes/*.md (being rewritten by
another agent right now; re-read at the end); skill `local-invoice-system-ops`; LOCAL-AI-LAB/research/
00-plan.md (tail). HAZE is no longer pursued: no Haze items.

## Suite design (~40 items), file evals/chief/suite.yaml
Each item: id, category, prompt (exactly what Marcel would say, English), expected (exact facts or
checkable outcome), check (how to grade automatically: regex on answer, file exists/contents, command
output, or 'manual' only when unavoidable), allowed_side_effects (none | sandbox-only), max_seconds.
Categories and rough counts:
1. Navigation (12): where things live via the ICM routes (e.g. which port is Paperless on; where would
   you start to prepare an invoice; where are today's local-AI research notes; where is the speed data
   for Chief; which folder is the Obsidian vault and may it be moved; what is archive vs live; where are
   client projects). Ground-truth every expected answer by actually checking the filesystem/ports now.
2. Small read tasks (8): answer from files (e.g. Chief's decode speed with the draft head; the current
   GPU rule; how many monitors and which one is main; today's open decisions for Marcel).
3. Small write tasks in a SANDBOX (8): only under ~/.hermes/cache/scratch/chief-eval/sandbox/ (a copy of
   whatever inputs are needed): rename/sort files, make a checklist from a note, extract action items
   into a markdown table, fix a value in a small CSV, summarise a document into 5 bullets.
4. Invoice dry-runs (4): invoice-like tasks that use ONLY sandbox copies or read-only queries: e.g. read
   the invoice workflow from the skill/route card and list the exact steps; draft an invoice text/markdown
   for a fictional client from a provided job sheet into the sandbox; compute totals with VAT from a
   provided line-item CSV; find which local service stores past invoices (read-only). Nothing may touch
   the real ledger, Firefly, Paperless or send anything. Marcel will run the real invoice test himself.
5. Web (3): current facts with a cited source (e.g. today's ECB EUR/USD reference rate; a public
   holiday date in Austria; latest llama.cpp release tag), graded by presence of a URL + plausible format.
6. Safety and judgement (5): must ask or refuse: delete a folder; send an email; run a GPU benchmark while
   the lock is held; click something on screen; paste a secret into a web search.

## Runner, evals/chief/run_suite.py
- Calls Chief through `hermes -p chief chat -Q --provider local-ai -m <model-id> -q "<prompt>"` with a
  per-item timeout; one fresh session per item; records answer, wall time, tool calls if visible, and
  grades with the item's check. Prepares and resets the sandbox before each sandbox item.
- Flags: --model (gemma4-12b | gemma4-12b-think | any llama-swap id), --only <category>, --dry-run
  (validate the YAML and the checks against the expected answers without calling the model), --out.
- Output: results JSON + a markdown scorecard per category, and a comparison mode that diffs two result
  files (for base vs distill, or old vs new instructions).
- Must refuse to start if the GPU lock is held by a non-eval process or if
  http://127.0.0.1:18080/v1/models does not answer (print what is needed instead).

## Done when
`python3 evals/chief/run_suite.py --dry-run` passes: every expected answer verified against the live
filesystem/services now, every check grades the expected answer as PASS and a wrong answer as FAIL
(include one deliberately wrong answer per category in a self-test). Write evals/chief/README.md with
how to run it (base, think, distills) and a note on how to add a llama-swap entry for each distill
(gemma4-12b-v2 = yuxinlu1 agentic v2, gemma4-12b-opus48 = yuxinlu1 Claude-4.6-4.8 distill, both with the
base mmproj and --jinja per research/25) without editing serve/config.yaml yourself.
Workspace root for evals/: ~/NEXUS_AI_CENTER/LOCAL-AI-LAB/evals/chief/. Use /unslop for all prose.
