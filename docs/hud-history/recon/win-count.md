# win_count diagnostic — "0 clients — no clients reported by collector"

## Verdict

**Root cause is collector-side**, in `hud-collect` (Rust). The DISPLAY is correct per the
stream-keys contract — it renders exactly what the (missing) keys imply.

The `win_count` / `win{i}_*` keys are **never emitted** — not even `win_count\t0` —
while `ws_count` / `ws{i}_*` flow every batch. The Hyprland slow lane runs (ws keys
prove it); only the *clients* half of `hypr_poll()` fails, silently, every 3 s cycle.

## Evidence

1. `timeout 10 hud-collect stream | grep 'win_count|ws_count|win0_|ws0_'`
   → `ws_count 6`, `ws0_*`, `ws1_*` … repeat every ~1 s batch; **zero `win*` lines**.
2. `hyprctl clients -j` → 6 healthy clients, all with string `title`/`class`/`workspace`
   objects, numeric `monitor`, no `null` fields. Raw data is fine.
3. Deployed binary `~/.config/omarchy/plugins/nexuslink.hud/hud-collect` ==
   `~/.cache/hud-collect-build/release/hud-collect` (623352 B, built 23:39, same minute
   as `main.rs` mtime) — the shipped binary matches current source.
   `win_count` *is* in the binary (constructed inline via `movabs` + `mov byte 't'`,
   so it doesn't appear as a contiguous literal — don't be fooled by `grep -c`).
4. `jq` exists (`/usr/bin/jq`, pkg `jq 1.8.2-1`) and works — the workspaces pipeline
   uses the same `sh -c 'hyprctl -j … | jq -r …'` shape and succeeds.

## Exact bug

`collector/src/main.rs:980` — the clients command string inside `hypr_poll()`:

```rust
"hyprctl -j clients 2>/dev/null | jq -r '.[] | [.address, .workspace.name,
 .workspace.id, .class, .initialClass,
 (.title | gsub(\"[\\t\\n\\x1f]\"; \" \")), .monitor] | join(\"\\u001f\")' 2>/dev/null"
```

The jq program contains the string literal `"[\t\n\x1f]"`. **jq does not support `\x`
hex escapes in string literals** (only `\" \\ \/ \b \f \n \r \t \uXXXX`). jq aborts at
compile time:

    jq: error: Invalid escape at line 1, column N (while parsing '"\x"')
    jq: 1 compile error        → exit status ≠ 0

Consequently at `main.rs:984` `o.status.success()` is **false**, so the whole block
(lines 986–1001) — every `win{i}_*` insert *and* `m.insert("win_count", i)` — is
skipped on every poll. The error text is swallowed by the trailing `2>/dev/null`,
so nothing is ever logged.

The workspaces command (`main.rs:1008`) uses only `"\u001f"` — a valid escape — so it
compiles, runs, and fills `ws*` keys. That asymmetry is the whole bug: same lane, one
bad escape in one of two filters.

Display side (downstream victim, correct per contract "panels must tolerate missing
keys"): `HudN.qml:778` `winCount = Math.max(0, num(stats.win_count))` → `num(undefined)`
→ 0 (`num()` at HudN.qml:240); `HudN.qml:3683–3684` shows "— no clients reported by
collector —" when `winCount === 0`; `HudN.qml:3661` prints "0 clients". Deployed
`~/.config/omarchy/plugins/nexuslink.hud/Hud.qml` is byte-for-line identical at these
lines.

## Minimal fix (1 char)

`collector/src/main.rs:980`: change `\\x1f` → `\\u001f` in the Rust literal, i.e. the jq
regex becomes `gsub("[\t\n\u001f]"; " ")`. (`[\t\n]` alone would also work — the \x1f
guard only strips the field separator itself from titles.)

Then rebuild + redeploy (`deploy.sh` rebuilds via `cargo build --release` into
`~/.cache/hud-collect-build` and installs to the plugin dir).

## Suggested hardening (optional, beyond minimal)

- Emit `win_count 0` even when the subprocess fails (initialize the SlowMap entry or
  move the insert outside `if o.status.success()`) so the panel can distinguish
  "collector broken" from "no windows".
- `(.title // "")` before `gsub` guards against a future `null` title, which would
  otherwise fail the same way (runtime error → non-zero exit → all win keys dropped).
- Same for `(.address // "")` etc. if older/newer Hyprland builds omit fields.
