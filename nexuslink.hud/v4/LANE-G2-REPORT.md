# LANE-G2-REPORT — HDMI-A-3 workbench: slim dock, media art, functional rows, overflow fixes

Scope honored: edits confined to `v4/Workbench.qml`, `v4/UtilityDock.qml`,
plus new `v4/MediaCell.qml` registered in the qmldir LANE block and this
report. `cellDefs` registry untouched; CommandHub/DP-1 dock unchanged.

## 1. Dock slimming (UtilityDock.qml)

- New `property bool compact: false` profile. CommandHub instantiates
  `UtilityDock` without it → DP-1 keeps all 17 cells, identical layout.
- `compactIds = [media, vol, mic, notif, wthr, ws, pwr, theme]` — the
  operator's curated set (THEME kept: it's a single stats key, cost-free).
- `activeCellDefs` filters the registry in compact order; `cellWeight(id)`
  gives media 1.7× share so the art cell is expanded while the rest breathe
  (≈212 px per unit cell on a ~1850 px strip vs ≈109 px before).
- Hidden cells' pollers are gated off via new `DockPoll.active`
  (`pulse()`, `maybeFire()`, `Component.onCompleted` all guard on it) — bt,
  cap, idle, rem, night, dl no longer spawn processes on HDMI-A-3.
  `clipFile.watchChanges` also gates on `cellActive("clip")`.
- Workbench.qml passes `compact: true` on its `dockStrip`.

## 2. Media cell with thumbnail (MediaCell.qml + UtilityDock.qml)

- `omarchy-shell media status` (the existing 2 s mediaPoll argv) was verified
  live to already emit `artUrl` — e.g.
  `{"title":"Restless","artist":"Kakkmaddafakka","artUrl":"https://i.scdn.co/image/..."}`.
  No extra poll/process added; `dock.mediaArtUrl` reads the key.
- `MediaCell.qml`: left ~square thumb (≤62 px, rounded well, `clip:true`)
  with `Image` `asynchronous:true, cache:true, fillMode:PreserveAspectCrop`,
  `sourceSize` ≈2× display size so decode stays cheap. Source is bound to
  `mediaArtUrl` — refetches only when the URL changes; no timers.
- Fallback: `♪` glyph in the well whenever art is absent/decoding/failed.
- In `full` profile the MediaCell stays `visible:false` with `artUrl:""`
  → the Image never fetches on DP-1.
- Registered in qmldir LANE block (`MediaCell 1.0 MediaCell.qml`).

## 3. Functional rows (Workbench.qml)

All launches are argv vectors through the same
`Quickshell.execDetached(["bash","-lc",'exec "$@"',"wb"].concat(argv))`
wrapper Navigator/UtilityDock use — zero shell concatenation.

- **Workspace chips** → `hyprctl dispatch 'hl.dsp.focus({ workspace = "N" })'`
  (numeric coerced + sanitized). Verified against omarchy shell's
  `Workspaces.qml` pattern; live probe `hyprctl dispatch 'hl.dsp.focus({
  workspace = "hl_dsp_probe_nonexistent" })'` → `Bad workspace` (parses).
- **Window rows** → `hl.dsp.focus({ window = "address:0x…" })`; addr sanitized
  to `[0-9a-fA-Fx]`. Verified: bogus address → `hl.focus: window not found`
  (no-op, rc 0).
- **Agent rows** → `gtk-launch` the desktop id where one exists:
  `devin→devin-desktop` (/usr/share/applications), `october→october` and
  `haze→haze` (~/.local/share/applications — haze.desktop DOES exist, so it
  is mapped). `opencode` has no .desktop → falls back to
  `hl.dsp.focus({ window = "class:opencode" })`, which no-ops cleanly.
  Launchable ids get a `↗` hint on the row.
- **Repo rows** → `ghev{i}_repo` is `owner/name` (no local path key exists in
  the stream — confirmed in collector src, `github_poll`). Click probes
  `$HOME/{projects,Projects,repos}/<basename>` via a fixed literal bash
  script with the basename passed as `$1` (argv-safe); hit →
  `gtk-launch devin-desktop <dir>`; miss → `uwsm-app -- xdg-open
  https://github.com/<owner/name>`. Repo string whitelisted
  `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`. Probe is re-entrancy guarded.
- **Proc rows** → click selects/toggles (`selProc`), accent edge shows the
  selection. No kill actions wired, per spec.
- Hover affordance: ws chips, window cards, agent cards tint
  accent2 + border; proc/repo rows get a subtle accent2 wash.

## 4. Text overflow

- Window card: `clip:true` on the card; title/sub column width floored at 0;
  `elide` added to ws and monitor Texts.
- Agent card: `clip:true`; name Text elides (with `↗` suffix); trailing
  detail Text width floored at 0 (badge `stTxt` is implicit-width).
- ws chip: width capped at 132 px + inner Text elides (was implicit-width —
  long ws names could overrun the strip).
- Proc rows: name width floored at 0; delegate clipped.
- Repo rows: type/age Texts elide; delegate clipped; repo width floored.
- Token rows: `clip:true` on the row card.
- Masthead spacer width floored at 1 (can't go negative on narrow widths).
- Bonus data fix: `win{i}_mon` is a monitor index ("0","1","2") but the card
  sort/display wanted a name — `wsMonName(wsid)` resolves it via
  `ws{j}_id → ws{j}_mon`, so this-screen windows now sort first correctly
  and the mon column shows "HDMI-A-3"/"DP-1" instead of a bare index
  (falls back to the raw key when unresolvable).

## Verification

    $ cd v4 && /usr/lib/qt6/bin/qmllint Workbench.qml UtilityDock.qml MediaCell.qml
    EXIT=0            # no diagnostics
    $ cd <mirror>/v4 && /usr/lib/qt6/bin/qmllint Workbench.qml UtilityDock.qml MediaCell.qml
    MIRROR-LINT-OK

qmllint sanity: probe file with syntax error → exit 255, so 0 is real.

Mirror sync (no shell restart, per spec):
`cp Workbench.qml UtilityDock.qml MediaCell.qml qmldir →
 /home/nexuslink/.config/omarchy/plugins/nexuslink.hud/v4/`
