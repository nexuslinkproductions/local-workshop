# LANE-AI1-REPORT — DP-1 CommandHub: "AI CENTER" key under the reactor

Scope honored: edits confined to `v4/CommandHub.qml` + this report. Synced to
the deployed mirror `/home/nexuslink/.config/omarchy/plugins/nexuslink.hud/v4/`
(the inotify plugin watcher picks up `close_write` — no shell restart needed).
`qmllint -I .` exit 0 on both copies; md5 match.

Repo used: `/run/media/.../NEXUS_AI_CENTER/nexuslink.hud` — the
`/home/nexuslink/NEXUS_AI_CENTER/nexuslink.hud` migration target exists but is
an empty directory, so the media tree is still the live source.

## 1. The element — compact EmbossedTile, not a grid tile

`CommandHub.qml:2127-2142`. A bare `EmbossedTile` (same chrome as the HubTile
component minus the fact-row machinery) is anchored
`horizontalCenter: parent` / `top: reactor.bottom + 16` — the dead space
between the dial's lower rim and the chassis tag, on the same centred axis
the mock's `.corebox` column already establishes. It does not touch the tile
grid (`leftTiles`/`rightTiles` stay 5+5) or the masthead.

- `title: "AI CENTER"`, `keyCap: "NAV"` — the Tag chip names the destination
  surface, matching the "↗ navigator · F3" hint idiom rather than claiming an
  F-key this screen never binds (CommandHub has no keyboard path; HudV4 keeps
  `ExclusionMode.Auto` and no focus).
- `padding: 10`, implicit size ≈230×56 px on DP-1 — pedestal-key scale under
  the ≈595 px dial.
- `hot` left unset: this is a destination affordance, not an alert — ice led,
  ice hover rim, same as any nominal tile.
- `insight` carries the live annotation (§3).

## 2. Activation → Navigator files at the AI center

`openNav(sec, path)` gained an optional second arg
(`CommandHub.qml:135-143`): it forwards to `navigator.openSection(sec, p)`
(injected scope) or the documented IPC fallback `omarchy-shell -q
nexuslink.nav open <sec> <p>`. All nine existing callers pass one arg and
behave exactly as before (`p` defaults to `""`).

Verified in Navigator.qml: `openSection` maps `"files"` → idx 0 and, when
`path` is non-empty, sets `filesDir = resolveNavPath(path)`
(Navigator.qml:981-1007); `resolveNavPath`/`normalizeDir` expand `~/` and
absolute paths (Navigator.qml:542-560). The IPC `open(section, path)` handler
passes `path` straight through (Navigator.qml:1322-1325), so both routes land
in the same place.

The click sends the probed dir, falling back to `~/NEXUS_AI_CENTER` while the
probe hasn't resolved (or if neither candidate exists — Navigator's own
dirProbe then reports the unreadable/missing state honestly):

```qml
onClicked: root.openNav("files", root.aiCenterDir !== "" ? root.aiCenterDir : "~/NEXUS_AI_CENTER")
```

## 3. Dir resolution + live annotation — one bounded probe, no new timer

`CommandHub.qml:356-390` (state + parser + `aiPoll` Process), gated inside the
existing `pollTick()` at a 30 s period (`CommandHub.qml:403,418-422`) — the
same cadence contract `pwrPoll` uses; stats frames and the pre-existing 1 Hz
clock remain the only tick sources, and nothing runs while `shown` is false.
`Component.onCompleted → pollTick()` fires the first probe at startup.

The probe is one `bash -lc` line in the Navigator/Workbench `[ -d ]` idiom:

```bash
d="$HOME/NEXUS_AI_CENTER"; [ -d "$d" ] || d=/run/media/.../NEXUS_AI_CENTER;
[ -d "$d" ] || exit 0; printf "%s\n" "$d"; find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l
```

- btrfs-home path first, Kingston mount second, empty output when neither
  exists → `aiCenterDir = ""`, `aiCenterCount = -1` → insight renders "—"
  (Style.unknownGlyph), never a fabricated 0.
- `find -mindepth 1 -maxdepth 1 | wc -l` counts top-level entries only — same
  bound as Navigator's execProbe/dirProbe and UtilityDock's count cells.
- `aiCenterCount` is a real `int` prop; `applyAiCenter` writes `Math.round(n)`
  or -1.
- `aiCenterShort` (`CommandHub.qml:365-375`) renders `~/NEXUS_AI_CENTER` under
  `$HOME`, `…/<parent>/<leaf>` off it — the Kingston path would print at
  ~420 px and break the key's compact footprint.

Insight line: `"<b>N</b> entries · <i2>~/NEXUS_AI_CENTER</i2>"` — count first
(the live number), path second (which mount it resolved). Verified live:
`$HOME/NEXUS_AI_CENTER` resolves and reports 27 top-level entries today.

## 4. Verification

```
$ cd v4 && /usr/lib/qt6/bin/qmllint -I . CommandHub.qml        → exit 0
$ cd <mirror>/v4 && /usr/lib/qt6/bin/qmllint -I . CommandHub.qml → exit 0
$ md5sum repo & mirror CommandHub.qml  → 7793696343d5478b680994fbae37a209 (match)
$ probe dry-run → /home/nexuslink/NEXUS_AI_CENTER \n 27
```

## 5. Notes / follow-ups for the conductor

- No live-fire click test — would pop the Navigator overlay on the operator's
  screen. Both routes (scope + IPC) are already proven by the five existing
  nav tiles; only the path argument is new, and its handling is Navigator-side
  code that predates this lane.
- The element sits over the knot field's lower glow (knot bottom ≈ y1136 on
  DP-1, key occupies ≈1034-1090) — the knot is background by design and the
  tile is opaque chrome, same as tiles over field washes elsewhere.
- If the operator later wants a masthead slot instead, the mastRule centre has
  room right of the cadence readout; the `aiKey` block is self-contained and
  re-parents cleanly.
- `qmldir`, HudV4 injection (`navigator: nav`), and the IPC surface needed no
  changes — `openSection` already accepted the path.
