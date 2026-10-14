# M1 kit contract — deck builders' API surface

Scope: everything a deck builder needs to implement `DeckCommand.qml` (DP-1),
`DeckTokens.qml` (DP-2) or `DeckSystem.qml` (HDMI-A-3) without reading the
kit's implementation. Design target: `docs/m1/M1-*.png`, `M-README.md`
(+ approved refinements: one hero per deck, F2 concentric limit rings on
DP-2, F1 swim-lane crew table, no monogram tiles / filled bars / stock
buttons).

## Ownership

| Builder | Owns | May create |
|---|---|---|
| command | `v4/DeckCommand.qml` | `v4/command/*` |
| tokens  | `v4/DeckTokens.qml`  | `v4/tokens/*`  |
| system  | `v4/DeckSystem.qml`  | `v4/system/*`  |

**Never edit:** `v4/fui/*`, `v4/HudV4.qml`, `v4/qmldir`,
`tokens/crew.py`, `tokens/ledger.py`. If a primitive is missing a feature,
build a local helper inside your own directory and flag it — kit changes go
through the M1-kit lane only.

Retired v4 screens (`CommandHub`, `BoardView`, `Workbench`, `OpsView`,
`AppGrid`, `DeviceBay`, `UtilityDock`, `Navigator`…) stay in the tree and
qmldir for reference but are NOT instantiated. Deck builders remove them
when their deck ships (own that deletion in your deck's PR).

## Deck inputs (HudV4 injects; do not rename)

```qml
property var stats: ({})        // last hud-collect frame: key -> string (1 Hz)
property var tokData: ({})      // parsed tokens.json
property var crew: ({})         // parsed crew.json
property string screenName      // "DP-1" | "DP-2" | "HDMI-A-3"
property bool shown: true       // deck visible — gate anything expensive
property var navigator: null    // Navigator scope (all decks get it; only DP-1 uses today)
property string sayText: ""     // ipc say payload (DP-1 reactor face)
property bool sayFlash: false
```

`stats` keys are strings or absent — render `FuiTokens.unknownGlyph` ("—")
for absent keys, never fabricate. `tokData`/`crew` are `{}` until the first
feed lands; decks must render empty-state, not error. The deck fills its
window's slab (movable/resizable by HudV4); use `width`/`height`, not fixed
monitor sizes.

HudV4 cadence: `stats` ~1 Hz, `tokData` after each 60 s ledger run,
`crew` after each 60 s crew run.

## Design tokens — `FuiTokens` (singleton)

Colors: `bg panel recess txt dim mute faint` · `hair hair2 hair3` (ice
hairlines at .30/.16/.08 alpha) · `ice acid azure warn alert white`.
Semantics: **acid = live state only**, **azure = flow**, warn/alert =
limits/alarms, ice = default instrument stroke.

Lines: `lwHair: 1, lwArc: 2, lwGlow: 8, glowAlpha: 0.10`.
Grid: `gridMinor: 16, gridMajor: 128, deckMargin: 32, gutter: 24`.
Fonts: `display` (Michroma), `mono` (Kode Mono), `icons` (FA solid).
Type ramp `px`: micro 8, tag 9, cap 10, code/body/num 11, mid 14, big 20,
hero 52, heroXL 92. Tracking `ls`: cap .5, tag 1, body .4, label 2.5,
title 3, hero 2.
Helpers: `tone(color,a)`, `css(color)` (canvas strokeStyle), `pol(cx,cy,r,deg)`
(0°=12 o'clock, CW), `stateColor(state)`, `fmtTok(n)` ("2.20B","484M"),
`fmtHm(epochS)` ("00:35"), `ico` map (FA codepoints), `unknownGlyph`.

## Primitives

All are `Item`s registered in qmldir (`import NexusHud.V4` scope — same
module, use them unqualified). Canvas primitives repaint **only** on
property/size change; none animate. `live` properties always paint acid.

### FuiFrame — bracketed panel
```
code:"CRW-TL", title:"CREW ACTIVITY", meta:"src: state.db · 00:35",
live:false, bare:false, brackets:true, bracketLen:12, chamfer:0,
headerH:28, pad:12, contentTop (readonly)
```
Header strip auto-hides when code/title/meta are all empty. Children go in
the default property (`contentData`) and are inset by `pad` + header.

### TickRing — graduated ring gauge
```
value (null="—"), minimum:0, maximum:100, startAngle:-135, sweep:270,
ticks:48, majorEvery:6, color:ice, live:false, glow:true,
minMark:null, maxMark:null, warnAt:null,
tickLabels:true, labelDecimals:0, unit:"", label:"", valuePx:30, margin:4
```
Angles: 0°=top CW (`-180/180` = half ring, `-135/270` = gauge, `0/360` =
bezel). minMark/maxMark = dim whiskers, warnAt = alert whisker.
Example: `TickRing { value:72; maximum:100; label:"CPU"; unit:"°C"; warnAt:95 }`

### ConcentricRings — N provider rings + 0-100% bezel (DP-2 hero)
```
model: [{label, color, value, limit, state, dash, valueText, reset}]
bezel:true, bezelLabels:true, labelMode:"inside"|"none",
innerHole:0.34, ringPitch:0(auto), margin:6, glow:true
```
Per ring: `value` 0..1 thin share arc · `limit` 0..1 thick arc just outside
(`null` = no feed) · `state` "warn"/"alert" recolours the thick arc ·
`dash:[2,3]` dots the share arc · label row inside-left shows
chip+label+valueText+reset. Outer bezel = 0-100% scale (major 10/minor 2/
micro 0.5) + acid zero index. Default property = centre content.
Example:
```qml
ConcentricRings { model: [
  {label:"OCG", color:FuiTokens.ice, value:0.662, limit:1.0, state:"alert",
   valueText:"1.46B", reset:"E-429"},
  {label:"CLD", color:FuiTokens.white, value:0.220, limit:null,
   valueText:"484M", reset:"A401"} ]
  Text { anchors.centerIn: parent; text:"2.20B" } }
```

### HairBar — hairline bar + min/max whiskers
```
value (null="—"), minimum:0, maximum:100, minMark:null, maxMark:null,
color:ice, live:false, trackH:9
```
1px track + thin value line + whiskers at observed min/max + end caps.
Never a filled bar.

### Sparkline — hairline series + 8% fill
```
values:[n|null], color:ice, fill:true, maximum:-1(auto), minimum:0,
lastDot:true, floor:true
```

### SwimLane — rows × time axis (F1 crew table)
```
model:[{label, sub, color, events, meta}]
windowStart, windowEnd, now(-1=end), rowHeight:18, headerH:16,
labelWidth:150, metaWidth:0, separators:true, nowColor:acid
signal eventClicked(int rowIndex, var event)
```
Events: crew.json `[start,endOrNull,title]` triples **or** objects
`{start,end,title,live,dashed}`. Open+live = acid block, open+idle =
`dashed` outline, closed <90 s = diamond ping. Hour gridlines + 10-min
ticks + HH:MM labels auto from the window; NOW cursor follows `now` —
update `now` on your own 60 s tick, never rebuild rows.
Example: see DeckCommand.qml scaffold (it renders crew.json directly).

### LeaderLine — annotation leader
```
x1,y1 (target dot) → x2,y2 (elbow) → x3 (optional horizontal run),
label:"", sub:"", color:ice, dot:true, side:"right"|"left",
labelDx:6, labelDy:-7
```
Local coords — size the item to the region it overlays.

### HexWell — flat-top hex icon well
```
icon:"firefox" (theme name or /abs/path — resolved via Quickshell.iconPath),
glyph:"" (FA fallback), label:"FIREFOX", sub:"network", serial:"APP-0x1F",
count:-1 (launches; <0 = "untracked"), live:false, margin:5,
signal activated()
```

### Ruler — graduated ruler strip
```
from:0, to:100, minor:20, majorEvery:5, labels:[], vertical:false,
flip:false, showLabels:true, labelDecimals:0, color:ice,
tickMinor:4, tickMajor:8
```
`labels` overrides per-major strings; `flip` grows ticks up/left.

### EngravedButton — chamfered control
```
label:"REGION CAPTURE", glyph:FuiTokens.ico.pick, keybind:"SUPER+PRINT",
code:"QA-02", active:false, interactive:true, chamfer:6,
signal activated()
```

## Feeds

### crew.json — `~/.local/state/nexuslink/crew.json` (tokens/crew.py, 60 s)
```json
{"generated": 1791244425,
 "bots": [{"name":"neji", "model":"deepseek-v4.1-flash",
           "provider":"opencode-go", "state":"idle",
           "last_active":1791240000.0, "sessions_24h":8,
           "calls_24h":150, "tokens_24h":8330000,
           "current_title":"HUD verify WS-05",
           "events":[[start_epoch, end_epoch|null, "title"], ...]}],
 "totals": {"bots":23,"active":0,"warm":1,"idle":7,"dormant":15,
            "sessions_24h":196,"calls_24h":6184,"tokens_24h":750379955}}
```
- `name` = profile dir; `default` = the shared `~/.hermes/state.db` store
  (filter it out if your layout wants only named crew).
- `model`/`provider` = profile config.yaml `model:` block (`default:`,
  `provider:`), `null` when unparseable.
- `state`: active ≤2 min · warm ≤30 min · idle ≤24 h · dormant (last_seen
  is `MAX(last_activity_at|ended_at|started_at)`, `null` = no sessions).
- `sessions_24h` = sessions started in window; `calls_24h` = Σ
  api_call_count; `tokens_24h` = Σ input+cache_read+cache_write+output.
- `events` = sessions overlapping the last 24 h, `[start, end|null,
  title]`, newest first, capped 60. `end null` = still open.
- `archived`/`hidden` sessions are excluded everywhere.

### tokens.json — unchanged schema + additive `sessions` (see SCHEMA.md)
`providers`, `history` (per-day per-provider, ≤90 d — already present,
use for skyline/heatmap/sparklines) and new top-level `sessions`:
top 10 sessions over the last 14 days across all Hermes stores —
`{id, bot, provider(raw billing_provider), model, title, in, out, tokens,
calls, start, last}` (epochs). Ranked by `tokens` desc; `archived`/`hidden`
and zero-token sessions skipped.

### stats — collector frame keys (unchanged)
Same `key<TAB>value` map the v4 decks consumed: `cpu_temp`, `mem_total_kb`,
`mem_avail_kb`, `load1`, `uptime_s`, `net_rx`/`net_tx`, `dev_usb_*`,
`aud_*`, `ws_*`, etc. Absent = "—".

## Rules of the M1 look (from the approved refinement)

1. One large hero per deck, readable across the room: DP-1 clock + app
   dial, DP-2 the concentric token rings, HDMI device topology. Detail
   stays dense but grouped in tiers around the hero.
2. Drop filler micro-text — no `src:` path lines or `n/a` rows unless the
   datum is real. Missing data = `FuiTokens.unknownGlyph`, never invented.
3. Hairlines only: 1px strokes on near-black, no filled bars, no blobs,
   no emoji, no rounded bubbles. Glow = wide low-alpha under-stroke
   (`lwGlow`/`glowAlpha`), never blur/MultiEffect.
4. Canvas repaints on data change only. The only 1 Hz element anywhere is
   the DP-1 clock; the only per-minute mover is a NOW cursor.
5. Acid = live, azure = flow, warn/alert = limits. One live `FuiFrame`
   maximum per deck.
