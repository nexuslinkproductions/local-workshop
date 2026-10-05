# LANE-F1-REPORT — AppGrid empty rows + GlassPane implicitWidth binding loop

Lane F1. Two confirmed defects in the live v4 HUD
(`nexuslink.hud/v4`, deployed mirror `~/.config/omarchy/plugins/nexuslink.hud/v4`).
Files touched: `AppGrid.qml`, `GlassPane.qml` (+ this report). No other files
modified; shell not restarted.

---

## DEFECT 1 — APPS NAVIGATOR renders header/filter but ZERO app rows

### Symptom
HDMI-A-3: pane header shows `APPS NAVIGATOR · 67 entries · gtk-launch`,
filter hint `⌕ / 67/67` — model clearly populated — but no rows below.

### Root cause (NOT the model, NOT the height math)
`Workbench.qml:1056` declares `AppGrid { anchors.fill: appsPanel }` inside
`GlassPane { id: appsPanel }`. `GlassPane` redirects declared children into
its inner `content` item via `default property alias contentData: content.data`
(GlassPane.qml, `content` at the `face` inset). AppGrid's real parent is
therefore `content` — `appsPanel` is its *ancestor* (`content → face → pane`),
not a parent or sibling. Qt discards the anchor:

    WARN scene: QML AppGrid at .../v4/Workbench.qml[1055:21]:
        Cannot anchor to an item that isn't a parent or sibling.
    (journal, live run pid 230284, 2026-09-30 00:12:09 — reproduced verbatim)

With the fill dropped, `root` stays 0×0 → `keyCatcher`/`body` (`anchors.fill`
+ margins 12) evaluate to **−24×−24** → the list container's height
`body.height − head.height − filterBox.height − foot.height − 3·spacing`
≈ **−101** → `ListView` has a negative viewport → zero delegates instantiated,
even though `model: root.rows` holds 67 entries.

Why the rest still painted: nothing in the chain clips until `face`, so the
`head`/`filterBox`-inner/`foot` `Text`s drew at implicit size from y=0 —
exactly the reported screenshot (header + filter hint visible, list empty).

### Offline evidence (QT_QPA_PLATFORM=offscreen, qmltestrunner, plain QtQuick)
GlassPane { Item { anchors.fill: <paneId> } } → same "Cannot anchor" warning,
item 0×0, body −24×−24, `lvCount=67` but zero-height view.
With `anchors.fill: parent` → item 598×798, body 574×774, rows render.

### Fix (AppGrid.qml, root item — 2 lines)
```qml
width: parent ? parent.width : 0
height: parent ? parent.height : 0
```
Sizes the grid to the content box it is actually reparented into, regardless
of what anchor the consumer declared (valid or invalid). Verified offscreen:
with the broken `anchors.fill: appsPanel` still in place the grid now comes
up 598×798, row area 682 px, 67 delegates live. Keyboard nav (`keyCatcher`
focus/`Keys.BeforeItem`) and `HyprlandFocusGrab` arm/disarm untouched.

### Notes
- The one-time "Cannot anchor" warning still logs per pane creation — it is
  emitted by the consumer-side `anchors.fill: appsPanel`, which cannot be
  removed from inside AppGrid.qml. Equivalent consumer-side fix (not applied,
  outside scope): `anchors.fill: parent` at `Workbench.qml:1056`.
- Same latent idiom (`anchors.fill: <paneId>` inside a GlassPane) exists at
  ~10 other Workbench children (Columns at 463/587/666/700/779/801/880/901/980/
  1205) — same warning, visually harmless today because positioner children
  still paint unclipped. Out of scope for this lane.

---

## DEFECT 2 — "Binding loop detected for property implicitWidth" spam

### Symptom
Journal repeats per shell start (9× observed):
`QML GlassPane at CommandHub.qml[373:5]: Binding loop detected for property
"implicitWidth" → GlassPane.qml:20:5`.

### Root cause (in GlassPane.qml, not the masthead block)
`GlassPane.qml:20` bound `implicitWidth` to `content.childrenRect.width`.
`content` holds consumer children injected through the `contentData` alias.
The masthead's two `Row`s anchor to *opposite* edges of `content` with nonzero
margins (`anchors.left/leftMargin: 22`, `anchors.right/rightMargin: 22`), so
`childrenRect.width` is a function of `content.width` — i.e. of the pane's own
anchored size. When the implicitWidth binding first evaluates, reading
`childrenRect` lazily resolves the alias-injected children's pending anchor
bindings; their geometry writes mark `childrenRect` dirty and re-notify the
binding while it is still evaluating → Qt reports the loop.

### Bisection evidence (offscreen probes)
- Same structure, children declared in the same file (no alias): **no loop**.
- Children injected via `contentData` alias + left/right anchors + margins:
  **loop fires** (iw=688 vs w=732 — value correct, warning bogus).
- Margins 0, single-side anchors, or unanchored children: **no loop**.
- Anchored vs implicitly-sized pane: irrelevant — the loop is a lazy-eval
  re-entry artifact, not a value cycle.

### Fix (GlassPane.qml — CommandHub.qml untouched, its anchors are legitimate)
The two bindings moved into `Binding { target: pane; delayed: true }`.
`delayed` defers first evaluation until the injected children's anchor
bindings have settled, closing the notify-while-evaluating window. It remains
a live binding: verified offscreen — zero warnings across construction AND a
resize storm; `implicitWidth` still tracks pane width (732→682); an
unconstrained pane still shrink-wraps (56×21).

---

## Verification
- `qmllint AppGrid.qml GlassPane.qml` → exit 0, no diagnostics (run from `v4/`).
- Offscreen `qmltestrunner` (QT_QPA_PLATFORM=offscreen):
  - Defect 1: grid 598×798, list viewport 682 px, `lv.count=67`, rows render.
  - Defect 2: mast-shaped pane + shrink-wrap pane + resize storm → zero
    "Binding loop" warnings; implicit sizes correct (688→638 on resize).
- Edited files synced to `~/.config/omarchy/plugins/nexuslink.hud/v4/`
  (mirror verified byte-identical via `diff`). Shell left running, not
  restarted — changes take effect on next HUD reload.
