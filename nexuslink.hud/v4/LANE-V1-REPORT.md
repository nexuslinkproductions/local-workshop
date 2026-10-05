# LANE V1 — DP-2 OPS tab "missing" root cause + tab-bar affordance rebuild + visual pass

## Scope owned
- `v4/BoardView.qml` (edited)
- `v4/OpsView.qml` (edited)
- `v4/LANE-V1-REPORT.md` (this file)

Mirror synced: `~/.config/omarchy/plugins/nexuslink.hud/v4/` (both files + report).
No shell restart needed — Quickshell picks up the module on next reload.

## ROOT CAUSE — "board schematic side doesn't have any second continuous page"

**The OPS tab existed and worked; the operator could not discover it.** The tab
bar rendered live (proof below) but read as anonymous chassis chrome — an
unlabeled full-width dark strip identical in finish to the masthead and shelf,
with two 22 px dim keys and a 8 px `cFaint` "VIEW 1/2 · REV n" caption that is
effectively invisible at seat distance. Zero hover feedback, zero cursor
change, zero cue that it is *navigation*. Diagnosis: cause (b) — present but
styled below the threshold of noticeability, compounded by (a)-class missing
affordances (no hover/cursor) on an otherwise-wired click path.

### Evidence
- `verify/v4/wave3-dp2.png` (live-shell screenshot, post-deploy): OCR of the
  strip region yields `[ BOARD ] OPS` — the tab bar was on screen.
- Same region measured: mean luminance ≈ 6 % (16/255), caption at cFaint α0.40.
- Click path audit: `tkey` delegate MouseArea `anchors.fill` →
  `onClicked: root.viewTab = …` is the topmost child of each key; deck
  `dragPad` sits below the screen content in `HudV4.qml`, so presses land.
  End-to-end verified offscreen: `viewTab` flip renders the full OPS page.
- Live `journalctl --user` grep for the shell shows zero QML errors for
  BoardView/OpsView — OPS does not render empty (its feed shows a waiting
  caption even before data).
- Cause (c) ruled out by design: `HudV4.qml:557` sets
  `WlrLayershell.keyboardFocus: WlrKeyboardFocus.None` — panel windows can
  never receive key events, so keyboard tabbing is impossible *for any lane*,
  not a BoardView defect. Mitigation added via wheel + ‹ › steppers instead.
- Cause (d) assessed: `viewTab` is a per-instance property — it survives deck
  hide/show but resets to BOARD on shell restart. Cross-restart persistence
  would require files outside this lane (HudV4's `st.panels` persistence or a
  singleton). Documented, not changed. The discovery pulse re-arms after
  restart, which doubles as a re-onboarding cue.
- Cause (e) ruled out: offscreen `qs` render of `viewTab: 1` shows the full
  OPS page (feed events, services, perf, net, procs, host) — verified by
  screenshot + OCR.

## What changed

### BoardView.qml
- **Tab bar rebuilt as a true segmented page control** (was an anonymous
  34 px strip): 40 px tall; engraved `PAGE` label; keys sit in a recessed
  machined track; each key is indexed (`01 BOARD`, `02 OPS`); the seated key
  gets an acid-tinted face, acid text, acid border and a 2 px acid top strip;
  inactive keys get hover rim + brighter text + `PointingHandCursor`.
- **Discovery pulse**: a 5 px acid dot on each unseen, inactive key breathes
  (1.4 s in/out, `SequentialAnimation`, `running: root.running && unseen`).
  A `_seenPages` latch marks each page on first visit — the hint stops
  *forever* once the page has been seen. No perpetual motion after discovery.
- **N-view ready**: `property var viewDefs` drives the Repeater by `index`;
  `viewCount` feeds the `n/N` caption; `stepPage(d)` wraps; an
  `onViewCountChanged` clamp keeps `viewTab` in range if the model shrinks.
  A third view = one def entry + one `visible: viewTab === 2` page item.
- **‹ › stepper keys** right of the bar + a WheelHandler over the whole bar —
  wheel pages views (wrap-around), the "continuous page" affordance.
- Right caption upgraded: `1/2` in readable `cDim`, `REV n` kept as live tick.
- Narrow-deck guards: hint text folds under 700 px, `REV` tick under 560 px —
  the keys never collide with the steppers.
- LENS keys given the same hover/cursor treatment (same affordance gap); the
  board-only dim now animates (`Style.dur.snap`).
- Fixed latent `font.pixelSize: 8.5` (non-integer) on small node captions → 9.

### OpsView.qml
- **Rail clipping fixed** — measured overflows at the ~966 px page height:
  services pane was 2 px short, net pane ~13 px (caption was clipped),
  proc pane ~42 px (~2 of 8 proc rows cut), host pane ~67 px (~4 of 15 rows
  cut). Now:
  - `svcPane` 94 px; `netPane` 120 px; `perfPane`/`procPane` scale with
    `rail.height` (0.22/0.25, clamped); `hostPane` takes the remainder.
  - `procPane.rowH` is computed so all 8 slots always fit the pane.
  - `hostPane` is now a **two-column vitals grid** (8 + 7 rows) with adaptive
    row pitch — all 15 keys render, verified in-screenshot (through WX).
- Header rows (`LIVEFEED`, `PERF`, `NET`) now vertically center their captions
  — was mismatched baselines.

## Honesty / rules check
- No new perpetual timers: the only Timer remains the gated 2.5 s staleness
  watchdog (`running: root.active`). The hint pulse is an opacity animation,
  not a Timer, and it parks permanently once every page has been visited.
- Unknown data → "—" everywhere (unchanged); `viewTab` stays `int`; no
  comments removed.

## Verify
```
$ /usr/lib/qt6/bin/qmllint -I . BoardView.qml OpsView.qml   → exit 0 (both trees)
  1 warning: OpsView.qml onExited — Quickshell qmltypes gap, pre-existing,
  same class noted in LANE-B4-REPORT.md.
Runtime smoke (offscreen): qs -p harness → "Configuration Loaded", zero QML
errors; grabToImage at viewTab 0 and 1 confirms both pages and the new
segmented control render; active-key acid state follows viewTab; all 15 HOST
rows and all 8 PROC rows render unclipped.
```
