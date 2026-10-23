# LOCAL AI actions for hudfix (card F8d)

`nexuslink.hud/v5/feeds/hudfix_localai.py` owns the LOCAL AI utility view from
`MAIN-SCREEN-BUILD.md`: unload model, clear slot cache, VRAM, installed models.
It exports one registry and stands alone: it imports nothing from `hudfix.py`,
so `python3 hudfix_localai.py --self-check` runs from a bare checkout. F8a's
`hudfix.py` discovers it as `hudfix_localai` and merges `ACTIONS` with the other
five modules; the registration line for `feeds/README.md` is requested in the
PR body, not edited here (shared file, one owner).

## Host reality: local inference is Linux only

Local inference runs on the Linux box (chief). Nothing in this module can run a
model on this Mac: there is no llama-swap, no llama-server and no
`nvidia-smi` here. That is why four of the five actions are `linux_only`, and
it is correct behaviour, not a gap:

| Action | Class | linux_only | Live source | On this Mac |
|---|---|---|---|---|
| `localai.status` | read | false | `/run/user/1000/chief/metrics.json` | fixture, or `ok:false` with a reason when the file is absent |
| `localai.unload` | reversible | true | `POST /api/models/unload/<model>` on llama-swap | refuses: `not this host`; plan exit 0, run exit 2 |
| `localai.clear-slot` | reversible | true | `POST /slots/<id>?action=erase` on llama-server | refuses: `not this host`; plan exit 0, run exit 2 |
| `localai.vram` | read | true | `nvidia-smi --query-compute-apps=...` | refuses: `not this host`, exit 0 (honest absence) |
| `localai.models` | read | true | model directory scan, or `models` in metrics | refuses: `not this host`, exit 0 (honest absence) |

`--fixture PATH` builds the same plan and the same payload on any host from a
documented snapshot, because the plan is what the UI renders and what Linux
pre-flights. `--fixture` never acts: `run` stops after the guards with
`fixture mode never acts`.

## The registry (the F8a contract)

```python
ACTIONS = {
    "<name>": {
        "class": "read|safe|reversible|destructive",
        "doc": "...",
        "plan": callable,   # plan(ctx=None) -> dry-run object, side-effect free
        "run": callable,    # run(ctx, confirm) -> result object
        "linux_only": bool,
    }
}
```

`plan()` writes nothing, spawns nothing that changes state, opens no socket and
never writes the cache; it returns exact items, exact bytes where countable, a
`count`, a `bytes` total and a `would` sentence. `run(ctx, confirm)` performs
the action; `confirm` must equal the action name for `reversible` actions.
`ctx` is an `argparse.Namespace` or a plain dict; missing keys use the defaults
in the module header (`--metrics`, `--cache`, `--llama-swap-url`,
`--slot-url`, `--models-dir`, `--force`, `--slot`, `--fixture`).

Standalone CLI, same verbs as `hudfix.py`:

```
python3 hudfix_localai.py list
python3 hudfix_localai.py plan localai.unload --fixture ../fixtures/localai.json
python3 hudfix_localai.py run  localai.status --fixture ../fixtures/localai.json
python3 hudfix_localai.py run  localai.unload --confirm localai.unload --fixture ../fixtures/localai.json
python3 hudfix_localai.py --self-check
```

Exit codes follow the feeds brief: `0` for data and for honest absence (`ok:false`
with a reason), which includes a `linux_only` read action refused on the wrong
host; `2` for a bad argument, a named missing fixture, a refusal to act (no
`--confirm`, a request in flight or unknown in flight, fixture mode, a
`linux_only` reversible run on the wrong host), or a request whose outcome is
unknown.

## Key parity with F7 `chief.py` (head a448a2d, branch `v5/f7-callcap-chief`)

The LOCAL AI dock (F7) and this utility view describe the same model, so the
status payload reuses F7's key names, arithmetic and fixture semantics. F7 at
head a448a2d (F7 REPAIR 3), on its own fixture (`fixtures/chief.json`):

```json
{"ok":true,"source":"fixture","generated_at":"2026-10-23T01:44:41Z","running":true,
 "model":"ornith-chief-v3","vram_gb":10.75,"tokens_per_s":41.6,"metrics_age_s":null,
 "vram_total_gb":12.0,"queue":0,"stale":null,
 "metrics_age_reason":"fixture mode reads no clock; age and stale are not measured",
 "snapshot_ts":"2026-10-22T21:07:02Z"}
```

The dock payload is identical at the previous head 5d7c2e5: F7 REPAIR 3
changed the source field on refusals and how paths are displayed, not the
status keys or values.

This module, on the same numbers (`fixtures/localai.json` carries F7's exact
`ts`, model, tokens/s, queue and VRAM values):

```json
{"ok":true,"source":"fixture","generated_at":"2026-10-22T21:07:02Z",
 "action":"localai.status","class":"read","running":true,"model":"ornith-chief-v3",
 "vram_gb":10.75,"tokens_per_s":41.6,"metrics_age_s":null,"vram_total_gb":12.0,
 "queue":0,"stale":null,"snapshot_ts":"2026-10-22T21:07:02Z",
 "slots":[{"slot":0,"busy":false,...},{"slot":1,"busy":true,"request_id":"req_7f3a",...}],
 "slot_occupancy":{"used":1,"total":2},
 "metrics_age_reason":"fixture mode reads no clock; age and stale are not measured"}
```

A key-by-key diff of those two payloads: no F7 key is missing, every shared
key carries the same value, and the only keys this module adds are `slots`,
`slot_occupancy`, `action` and `class`. `vram_gb` is
`round(vram_used_mib / 1024.0, 2)` and `stale` is `age > 5.0 s` in both. In
fixture mode both give `metrics_age_s` and `stale` null with
`metrics_age_reason`, and `snapshot_ts` carries the snapshot's own `ts`, because
an age is a fact about this host's clock, not about the snapshot. On the live
path the age comes from the metrics file's mtime, as in F7, and a cached answer
re-derives it (the cache never freezes the age).

One shared key differs by design: `generated_at`. F7 stamps it with the host
clock in fixture mode too, which the feeds brief forbids ("a fixture run must
produce byte-identical output"). Here a fixture payload takes `generated_at`
from the fixture's `ts` (or null with `generated_at_reason`), so two runs over
the same fixture print the same bytes.

## Safety

`localai.unload` is the one action that can interrupt someone else's work. The
plan names the model, the VRAM it frees, the reload cost and every busy slot
with its request id and session:

```json
{"action":"localai.unload","class":"reversible","linux_only":true,
 "items":[{"model":"ornith-chief-v3","vram_freed_mib":11012,"vram_freed_gb":10.75,
           "reload_cost_s":3.8,"reload_cost_source":"metrics.model_load_s",
           "session":"chief-voice/2026-10-23T00:12Z","request_id":"req_7f3a"}],
 "in_flight":[{"slot":1,"busy":true,"request_id":"req_7f3a",
               "session":"chief-voice/2026-10-23T00:12Z","tokens_cached":1842}],
 "requires_force":true,
 "would":"POST http://127.0.0.1:18080/api/models/unload/ornith-chief-v3; ..."}
```

`run` refuses in this order, all exit 2 and none touching the model:

1. no `--confirm localai.unload` exactly;
2. live on a non-Linux host (`not this host`);
3. a request in flight, a slot row with no `busy` key (unknown counts as
   unknown, never as idle), or metrics with no `slots` array so it cannot tell;
4. `--fixture` (fixture mode never acts).

A POST that raises on the transport (connection refused, timeout, no route)
returns `kind: "unreachable"` with "outcome unknown: the request may have been
sent", exits 2, and still appends its audit row. A request that may have landed
is never reported as a clean no-op.

`localai.clear-slot` applies the same in-flight guard to the slot it is about
to erase and states what the caller loses ("the cached prompt for request
`req_7f3a` (session ..., 1842 tokens); the caller stays connected and its next
turn re-prefills from scratch"). Read actions never need a confirmation, and
`localai.unload` on an idle box is a no-op (`changed:false`), not a fake unload.

Live mechanisms, both upstream-documented and never exercised in a test:

- llama-swap: `POST /api/models/unload/<model_id>` (README "manually unload
  models"), the lab runs it on `127.0.0.1:18080`.
- llama.cpp server: `POST /slots/{id_slot}?action=erase`
  (`tools/server/README.md`). The request goes to llama-swap by default; if the
  live box does not forward `/slots` to the active backend, set `--slot-url` to
  the llama-server port.

## Fixtures

- `nexuslink.hud/v5/fixtures/localai.json`: one loaded model, slot 1 busy with
  `req_7f3a`, two `nvidia-smi` rows summing to `vram_used_mib`, five GGUF files
  with exact byte sizes. Shape and key names from `recon/05-local-ai.md`;
  numbers are a plausible snapshot, not a measured capture (the note inside
  says so). It extends F7's `chief.json` field for field on the shared keys,
  and carries no `age_s`: fixture mode reads no clock, so the age is null with
  a reason rather than a number copied from capture time.
- `nexuslink.hud/v5/fixtures/localai-idle.json`: the same box with nothing
  loaded, `running:false`, occupancy `0/2`, no GPU processes. What the dock
  shows at rest and what makes `unload` a no-op.

## Self-check

```
$ python3 hudfix_localai.py --self-check
... 41 checks ...
EXIT=0
```

It proves, with no model, no GPU, no Linux host and no socket: the registry
shape and the four classes; the F7 key set, F7 fixture semantics and the 1024
divisor; fixture output byte-identical across runs with no cache written; a
partial metrics object, an empty file, a malformed file and a missing named
fixture each get the specified answer and exit code; the 10 s cache, its
expiry, and a cached read keyed on its source (a `models_dir` change inside
the TTL is re-read, never served the other directory's answer); every plan is
side-effect free and deterministic over a hashed sandbox; one plan per action
with `count`, `bytes` and `would`; the unload
plan's model/VRAM/reload/session; the clear-slot plan's slot/request/loss;
exact VRAM and model totals, with `bytes` null for VRAM; the confirm refusal;
the in-flight refusal with the request id in the reason; the slot with no
`busy` key counted as unknown (plan needs force, run refuses); `--force`
getting past the guard into the fixture refusal; the idle no-op; the
unknown-in-flight refusal; the busy-slot refusal; every `linux_only` read
refusing honestly on this Mac with exit 0 and every reversible run without a
confirm token stopping at exit 2; a dead POST reported as an unknown outcome
with exit 2 and a log row; zero `_http_post` calls from any fixture run; and
one JSONL row per run in the hudfix log.

Nothing in the self-check can reach the live audit log. Every child process
runs with `HOME` pointed at the self-check's temp root, so its default log and
cache land there, and the run hashes `~/.local/state/nexuslink/hudfix.log`
before and after to prove the live file is byte-identical.
