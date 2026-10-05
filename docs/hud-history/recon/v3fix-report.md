# v3 live-fix report (Wave-1a)

Scope: five operator-reported defects on the deployed v3 HUD. Candidate
`candidates/HudV3.qml` was edited and deployed to the live plugin
`~/.config/omarchy/plugins/nexuslink.hud/Hud.qml`; the pre-fix file was
preserved as `Hud.qml.v3-bak` (md5 `7ea597daff70a0a3d96c5840dd1b1757`).
Candidate and live file are byte-identical (md5 `f51972646a08c2fe2096337e9b293d7b`).
All line numbers below refer to the deployed file.

## Defect 1 — TOP PROCS stuck on "collector starting"

**Root cause.** The QML read `root.stats.proc_n` for the row count, but the
collector (`hud-collect stream`) emits only `proc0_name/proc0_cpu` …
`proc5_name/proc5_cpu` — no `proc_n` key. `num(stats.proc_n)` therefore
always resolved to 0, so every TOP PROCS repeater modelled 0 rows and the
empty-state "collector starting" label stayed visible forever (original
reads at what were lines 4624/4631/4641 and 5828/5835/5845).

**Fix.** `property int procCount` added at line 315; in `applyFrame` the
batch counts consecutive `procN_name` keys capped at 6 (lines 1014–1017).
All six `proc_n` reads replaced with `root.procCount` (lines 4679, 4686,
4696 for the command reactor drawer; 5906, 5913, 5923 for the ops TOP
PROCS panel). `grep proc_n` now matches only an explanatory comment.

## Defect 2 — reactor + knot centred on free space, not the screen

**Root cause.** Two parts. (a) `defaultRects()` centred the command
chassis and knot on the free-space axis `W * 0.5` already, but a persisted
DP-1 `center` rect in `~/.config/omarchy/nexuslink/hud-state.json`
overrode the default. (b) There was no guard against the chassis growing
wide enough to collide with the left SYSTEM rail, which would have made a
"centred" rect overlap the rail.

**Fix.** In `defaultRects()` the command branch keeps the axis at
`field.width/2` and now shrinks the chassis width symmetrically if it
would reach the rail: `chassisW = Math.min(chassisW, Math.max(240*ux,
2*(axisX - L - g)))` (line 3733). The knot watermark (`knotMark`, lines
5765–5778) centres itself on `field.width` via
`x = (field.width - width) * 0.5` — same axis, no code change needed. The
DP-1 `center` entry was deleted from `hud-state.json` (only that entry);
live `panels` now reports `center fx=0.2574 fw=0.4852` → axis = 0.5.

## Defect 3 — STATUS panel cut off at the bottom (DP-1)

**Root cause.** Two stacked contributors. (a) `statusPanel.contentH` was
hardcoded `74 * win.ux` (old line 4952): the body clip box also eats
`10*ux` of bottom margin, so the declared body height under-fit the
five-row column and the NET row was clipped even at the panel's natural
height. (b) A persisted `fh` override smaller than the panel's natural
height was honoured verbatim — with no scrollbar in the body, an
under-fitting `fh` silently clipped content (old `sanitizeMap`/`apply`
check at line ~3632 accepted any `fh > 0`).

**Fix.** `contentH` now derives from the content:
`statusRows.implicitHeight + 10 * ux` (lines 5026–5029) so the declared
body always covers the column plus the clip margin. The persisted-height
path now drops any `fh` that under-fits natural height —
`fh * field.height >= nh(pid) - 1` required to keep an override (lines
3660–3665). Live `panels`: DP-1 `status fy=0.7647 fh=0.1197`,
bottom edge 0.8844 — inside the field, not clipped.

## Defect 4 — no panels movable

**Root cause (three contributing defects, all fixed).**

(a) *Region dropped mid-gesture.* `CPanel.masked` was
`shown && !dragging && !resizing` (old line ~1748) and the chassis bar had
the same `visible && !dragging && !resizing` shape (old line ~4422). When
a drag began, the panel's `Region` was removed from the window input mask
while the pointer was already pressed/grabbed; the compositor could stop
delivering motion and — worse — the release, leaving a dead press that
wedged the shared `dragItem`/`dragSrc` bookkeeping. Every subsequent press
then hit the busy guard: nothing moved again. Journal confirmed presses
reached the handlers (deprecation warnings at the body/header/grip/
chassis handlers, lines 1890/1971/2042/4532), so input was arriving — the
gesture state was the failure.

(b) *Chassis drag strip had no mask region at all.* The `mask:` Region
list (lines 3409–3413) covered sparkL/sparkR/proc/dial but not
`chassisBar`, so the grab-bar press could fall outside the surface's
input region entirely.

(c) *No recovery from a wedged gesture.* Once `dragItem` was stranded by a
lost release, nothing cleared it.

Additionally the mask regions for the centre-zone panels were gated on
`!win.zoneBusy` (old lines ~3381–3384), i.e. grabbing the chassis removed
four more regions mid-gesture — same stranding hazard.

**Fix.** `masked` is now `shown` for the whole gesture — a pressed pointer
is already grabbed, so keeping the region cannot eat anyone's click
(CPanel line 1759; chassis `masked: visible` line 4477). `chassisBar` was
added to the mask Region list and the `zoneBusy` gating was removed
(lines 3409–3413). A self-heal `gestureStale()` (lines 3887–3894) runs at
the top of `dragPress` and `sizePress` (lines 3896, 3942): one pointer
can't press twice, so a fresh `onPressed` while a gesture is still booked
means the old gesture is dead — it clears the bookkeeping and proceeds.
Z-order was audited: `knotMark` sits at `z: -2` under the panels, has no
MouseArea and no mask region, so clicks pass through; the dial legibility
discs and say chip are likewise inside the chassis/dial tree with no
interposing pointer-capturing item.

**Proof.** IPC `move` exercises the same `commitRect → resolveLayout →
persist` path (lines 3975, 3841, 4013). Before/after on DP-1 `status`:

    BEFORE:   fx=0.5630 fy=0.7647 fw=0.4341 fh=0.1197
    move status 0.60 0.65 → ok
    AFTER:    fx=0.5659 fy=0.6542 fw=0.4341 fh=0.1197
    move status 0.5630 0.7647 → ok → restored exactly.

## Defect 5 — knot ends unlit; reactor hard to read over it

**Why it ended dark.** The idle canvas alpha `idleA` was 0.14 (old line
~3101) and `knotMark` idles at `opacity 0.9` (line 5778), so the resting
knot was only ~12.6% lit. Worse, the effect cycle had three ways to land
off-base: `fxTimer.onTriggered` called `endEffect()` when elapsed ≥
effectDur, but the terminal effect frames never resolved back to `idleA`
(SCATTER's `a = idleA * (1-0.82f) + pi(1-f)*0.72` had no fade-out tail, and
the HUE/weave effect painted `a = idleA + 0.80` flat until it cut); SCATTER
overran its budget — the last cell's return flight ends at 4800 ms but
`durFor(0)` returned 4600, so `endEffect()` fired mid-flight and dropped
the last frame wherever it was; and `pause()` just stopped the timers,
freezing a scattered/blank frame. Any interruption or the truncated final
frame therefore left the knot dark.

**Fix (minimal, no effect redesign).** `idleA` is now 0.56 (line 3121) —
0.56 canvas × 0.9 mark opacity ≈ 0.50 effective, "always ~50% lit".
`endEffect()` resets `effect = -1` and then `requestPaint()`s, so the last
paint is always the base state (lines 3244–3248). `pause()` settles via
`endEffect()` when an effect is in flight, else repaints the idle frame —
an interruption can no longer freeze a mid-effect frame (lines
3029–3033). `durFor(0)` is 4900 ms so SCATTER's last return flight (4800
ms) completes (line 3209). SCATTER's land-flash now fades out over the
final 500 ms (`tail0`, lines 3310–3313) and the weave effect eases in and
back out (`tail4`, lines 3344–3348), so both land on exactly the base
alpha instead of cutting.

**Dial legibility.** Three layered translucent discs were added behind the
reactor dial (lines 4715–4733): a `1.20×dSize` disc at 16% near-black and
a `1.09×` disc at 34% give a soft drop shadow, and a `dSize` disc at 80%
near-black backs the face so the dial text stays readable over the now
brighter knot.

## Diff summary

- `procCount` property + `applyFrame` counting; six `proc_n` reads
  replaced.
- `CPanel.masked`/`chassisBar.masked` no longer drop mid-gesture;
  `chassisBar` added to the window mask; `zoneBusy` mask gating removed;
  `gestureStale()` self-heal on new press.
- `defaultRects` command branch: symmetric chassis shrink vs the SYSTEM
  rail; DP-1 `center` entry removed from `hud-state.json`.
- `statusPanel.contentH` now `implicitHeight + 10*ux`; persisted `fh`
  overrides that under-fit natural height are dropped.
- Knot: `idleA` 0.14 → 0.56; `endEffect` repaints base; `pause()` settles
  to base; SCATTER budget 4600 → 4900; SCATTER and HUE/weave get 500 ms
  terminal fade envelopes; dark backing disc + soft shadow behind the
  reactor dial.

## Verification

- `qmllint`: `/usr/lib/qt6/bin/qmllint candidates/HudV3.qml` → exit 0,
  zero `Error` lines.
- Backup: `Hud.qml.v3-bak` created before deploy (md5 `7ea597da…`).
- Deploy: candidate copied to live `Hud.qml`; md5 match `f5197264…`.
- `omarchy-restart-shell` succeeded; new quickshell PID **2242140**.
- `journalctl --user` for PID 2242140: no new Hud.qml errors. Only the
  permitted `Parameter "mouse" is not declared` deprecations (lines 1972
  at 17:41 and 1890 at 17:45 — fired by real pointer presses on the panel
  body/header) plus unrelated omarchy-plugin IpcHandler duplicate-target
  warnings.
- `omarchy-shell nexuslink.hud status` → JSON
  `{"cpu":"13%","mem":"27.9 / 61.9 GB  (45%)","gpu":"intel","rx":"40.4 KB/s","tx":"4.4 KB/s","frame":849,"alert":false,"tokProviders":6}`.
- `panels` → JSON; DP-1 excerpt: `center fx=0.2574 fy=0.1161 fw=0.4852
  fh=0.7594` (axis 0.5), `status fy=0.7647 fh=0.1197 bottom=0.8844`.
- IPC `move` proof: status fy 0.7647 → 0.6542 → restored (see above).
- Screenshot: DP-1 was on workspace 4; Omarchy pins workspaces 4–6 to
  DP-1 (workspace 9 is pinned to DP-2 by `hyprmoncfg-monitors.lua`
  workspace rules — `hl.dsp.focus({workspace})` moves the workspace to
  whichever monitor owns it, which is why ws9 kept landing on DP-2). DP-1
  was focused by focusing its ws4 window via `hl.dsp.focus({window})`,
  switched to empty ws5, `grim -o DP-1 verify/v3fix-dp1.png`, then
  switched straight back to ws4; DP-2 (stranded on ws9 during the
  dispatcher probing) was restored to ws7. Monitors confirmed: DP-1 ws4,
  DP-2 ws7, HDMI-A-3 ws2.
- Screenshot file: `verify/v3fix-dp1.png` (2560×1440 PNG, 818 KB).
- Shell left running (quickshell PID 2242140).
