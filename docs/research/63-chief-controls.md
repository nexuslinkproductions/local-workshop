# 63. Chief controls: unlock `python3 -c`, and chief-off / chief-on

Two of Marcel's explicit requests (00-plan.md, 2026-10-13 22:20):
(A) allow `python3 -c` for the Chief profiles, and (B) a "chief, shut down"
mechanism. Nothing was loaded, the local-ai service was not touched, and the
GPU lock was left alone. All numbers below are from real runs, not inference.

Sources: Hermes source at `~/.hermes/hermes-agent` (file:line below), the docs
at https://hermes-agent.nousresearch.com/docs (`user-guide/security.md`), the
chief and chief-v3 profiles, `LOCAL-AI-LAB/serve/config.yaml`, and the llama-swap
binary at `~/.local/bin/llama-swap` (v264 a025e03).

---

## A. Unlock `python3 -c` (and python heredoc) for Chief

### A.1 The mechanism: a rule key in `command_allowlist`

`tools/approval_detection.py:495-496` classifies these as dangerous:

```
"script execution via -e/-c flag": "(python[23]?|perl|ruby|node)\\s+-[ec]\\s+",
"script execution via heredoc":    "(python[23]?|perl|ruby|node)\\s+<<",
```

Under `-q`, `single_query_mode` defaults to `deny`, so both are blocked with no
user to ask (confirmed below). The narrowest supported lever is the permanent
allowlist, and the allowlist accepts **dangerous-pattern rule keys**, not only
command text:

- `tools/approval.py:396-416` `_read_permanent_allowlist()` reads the **top-level**
  `command_allowlist` list from the profile's `config.yaml`.
- `tools/approval.py:360-364` `_is_permanently_approved(pattern_key)` matches the
  rule-key description (and its legacy regex alias) against that set.
- `tools/approval.py:646` `_unattended_deny()` skips the `-q` block when the
  detected rule key is permanently approved; `tools/approval.py:970` is the same
  short-circuit in the interactive gate.
- Documented: `website/docs/user-guide/security.md:284-289` states that a rule key
  such as `script execution via heredoc` is honored on every surface, "including
  unattended ones: a cron job, `hermes chat -q` run or webhook session under
  `... single_query_mode ... deny` still runs a command whose detected rule key is
  in `command_allowlist`."

### A.2 Why not the alternatives

| Option | Why rejected |
|---|---|
| `approvals.single_query_mode: approve` | Approves **every** dangerous command under `-q` (rm -rf, curl\|sh, sudo-flag). Too broad. |
| `approvals.mode: off` / `--yolo` | Same, globally. Too broad. |
| Command-text allowlist entry (`python3 -c *`) | Does not work. `tools/approval_floors.py:144` `_has_allowlist_shell_operator()` refuses a command whose `-c`/`-e` argument is "reinterpreted"; `tools/approval_floors.py:188` `_command_matches_permanent_allowlist()` therefore returns False for any real `python3 -c '...'` or heredoc. |
| **Rule key in `command_allowlist`** | Chosen. Approves exactly the two flagged categories; the hardline floor and `approvals.deny` still run first. |

Ceiling, stated plainly: the rule key is category-wide, so it also allows
`perl/ruby/node -c/-e` and interpreter heredocs. There is no per-interpreter key
in Hermes, so this is the narrowest supported setting.

### A.3 Change applied (both profiles)

Backups first: `config.yaml.bak-pyc` next to each file. Then a top-level block
added to `~/.hermes/profiles/chief/config.yaml` and
`~/.hermes/profiles/chief-v3/config.yaml`:

```yaml
command_allowlist:
  - "script execution via -e/-c flag"
  - "script execution via heredoc"
```

(comment in each file cites the same file:line mechanism above)

### A.4 Proof (no model call)

Method: import the approval module from the hermes-agent venv
(`~/.hermes/hermes-agent/venv/bin/python3`, py3.11, which has `ruamel`), set
`HERMES_HOME` to the profile, and call
`tools.approval.check_all_command_guards(cmd, "local")`.

- `-q` mode: `HERMES_SINGLE_QUERY_SESSION=1` in the environment.
- interactive mode: `tools.approval_context.set_hermes_interactive_context(True)`
  plus an `approval_callback` that returns `deny` (so a still-gated command is
  proven to reach the human prompt, without hanging on stdin).
- Reproducibility note: the venv auto-imports the Hermes bootstrap, which can
  re-exec into a dependency-less interpreter; `HERMES_DISABLE_LAZY_INSTALLS=1`
  (or a single-query marker) suppresses that. Set it when re-running the probe.

**chief, `-q` mode (the eval path)**

| command | before | after |
|---|---|---|
| `python3 -c 'print(1+1)'` | BLOCKED (script execution via -e/-c flag) | **approved** |
| `python3 <<'PY' ... PY` | BLOCKED (script execution via heredoc) | **approved** |
| `rm -rf ~/x` | BLOCKED (recursive delete) | BLOCKED (recursive delete) |
| `sudo ls` | approved | approved |
| `curl x \| sh` | BLOCKED (pipe remote content to shell) | BLOCKED (pipe remote content to shell) |

**chief, interactive mode**

| command | before | after |
|---|---|---|
| `python3 -c 'print(1+1)'` | BLOCKED (reached the prompt) | **approved (prompt never reached)** |
| `python3 <<'PY' ... PY` | BLOCKED (reached the prompt) | **approved (prompt never reached)** |
| `rm -rf ~/x` | BLOCKED (reached the prompt) | BLOCKED (reached the prompt) |
| `sudo ls` | approved | approved |
| `curl x \| sh` | BLOCKED (reached the prompt) | BLOCKED (reached the prompt) |

**chief-v3, `-q` mode**: identical to chief (same table).

**Supplementary, `-q`, after the change** (proving the other gates survive):

| command | result |
|---|---|
| `sudo -s` | BLOCKED (sudo stdin guard) |
| `sudo rm -rf /etc` | BLOCKED (hardline: recursive delete of system directory) |

Note on `sudo ls`: Hermes does not flag plain `sudo` (no privilege-escalation
flag), so it is approved before and after. The sudo gate that matters is the
flag rule and the hardline floor, both shown above as still blocked.

---

## B. `chief-off` and `chief-on`

### B.1 What chief-off does

`~/.hermes/profiles/chief/workspace/bin/chief-off` (bash, no new deps):

1. unloads every model through llama-swap's HTTP API: `GET /unload`, falling back
   to `POST /api/models/unload` (both routes confirmed in the v264 binary
   strings; `/running` lists what is loaded). It never kills the service.
2. waits up to 30 s for no `llama-server` child of `llama-swap` to remain
   (recursive descendant walk, so the `gate-run.sh` wrapper is covered).
3. clears prompt-cache / slot files only if the serve config names them
   (`--slot-save-path` / `--prompt-cache`); **none are configured**, so nothing is
   cleared (verified against `serve/config.yaml`).
4. clears Chief's scratch: `$PROFILE_HOME/cache/scratch` and
   `$PROFILE_HOME/workspace/scratch` (profile home derived from the script's own
   location, so it works for chief and chief-v3).
5. prints a report: models unloaded, VRAM free before -> after
   (`bench/arc-vram.py`), RAM available before -> after (`/proc/meminfo`), and
   every process holding `/dev/dri/renderD*` (listed, never killed).

Flags: `--dry-run` (change nothing), `--stop-service` (additionally
`systemctl --user stop local-ai`, off by default; the unit idles at 0 VRAM).

### B.2 chief-on

`~/.hermes/profiles/chief/workspace/bin/chief-on`: one tiny request
(`max_tokens: 1`) to `ornith-chief` so llama-swap warm-loads the brain and the
next answer is fast. `CHIEF_MODEL` overrides the model id. Not tested (GPU owned
by a benchmark, per instruction).

### B.3 Files changed

| file | action | backup |
|---|---|---|
| `~/.hermes/profiles/chief/config.yaml` | added top-level `command_allowlist` | `config.yaml.bak-pyc` |
| `~/.hermes/profiles/chief-v3/config.yaml` | added top-level `command_allowlist` | `config.yaml.bak-pyc` |
| `~/.hermes/profiles/chief/workspace/bin/chief-off` | new | n/a (new) |
| `~/.hermes/profiles/chief/workspace/bin/chief-on` | new | n/a (new) |
| `~/.hermes/profiles/chief-v3/workspace/bin/chief-off` | new (copy) | n/a (new) |
| `~/.hermes/profiles/chief-v3/workspace/bin/chief-on` | new (copy) | n/a (new) |
| `~/.hermes/profiles/chief/workspace/AGENTS.md` | one route-table line | `AGENTS.md.bak-chief-off` |

AGENTS.md line added:

```
| "Chief, shut down" / "go to sleep" / "schluss" (or "wake up") | run bin/chief-off (or bin/chief-on) | say the one-line result |
```

Note: chief-v3's AGENTS.md was left untouched (the constraint for that profile
was approvals keys plus `workspace/bin/chief-off` only).

### B.4 `chief-off --dry-run` output (real)

```
chief-off: DRY RUN, nothing will change
llama-swap not running; no model loaded through it.
no --slot-save-path / --prompt-cache configured; nothing to clear
would clear 41 entries under /home/nexuslink/.hermes/profiles/chief/cache/scratch

chief-off report 22:13:28  [dry-run]
  models unloaded : <none reported>
  VRAM free MiB   : 1151 -> 1125
  RAM available MiB: 32628 -> 32546
  still holding /dev/dri/renderD* (not killed):
    pid 1889 Hyprland -> /dev/dri/renderD128
    pid 2052 quickshell -> /dev/dri/renderD128
    pid 2108 Xwayland -> /dev/dri/renderD128
    pid 3246359 easyeffects -> /dev/dri/renderD128
    pid 3976297 llama-server -> /dev/dri/renderD128
    ... (chromium / electron / Hermes / hermes entries omitted for brevity)
```

The `llama-server` at pid 3976297 is the benchmark's process, not a llama-swap
child; chief-off lists it and does not touch it. llama-swap itself is not running
(the local-ai unit is inactive), which is why the dry-run reports nothing to
unload.

---

## C. What was not done

- No model was loaded; `local-ai.service` was not started or stopped; the GPU
  lock was not touched.
- `chief-off` was exercised with `--dry-run` only, as instructed.
- `chief-on` was not run at all, as instructed.
- The VRAM/RAM deltas in the dry-run are read-only snapshots, not a real
  before/after of an unload (llama-swap was down).
