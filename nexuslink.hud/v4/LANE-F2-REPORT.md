# LANE-F2-REPORT — GlassPane anchor sweep (Workbench.qml)

Scope: `v4/Workbench.qml` only. Deployed mirror synced to
`~/.config/omarchy/plugins/nexuslink.hud/v4/Workbench.qml`.

## Defect

`GlassPane.qml` reparents declared children into its inner `content` item via
`default property alias contentData: content.data` (GlassPane.qml L10, content
item at L131-135). A child declared inside `GlassPane { id: X }` therefore has
`content` as its parent — `X` is its *grandparent*, which is neither a legal
parent nor sibling anchor target. Qt discards the anchor with:

    "Cannot anchor to an item that isn't a parent or sibling"

and the body Column collapses to implicit size (0 width content → invisible
panel bodies; AppGrid unanchored → apps navigator blank).

Fix per site: `anchors.fill: <paneId>` → `anchors.fill: parent`. Post-reparent
`parent` *is* the `content` item (already inset by `pane.padding`), so
parent-fill + the existing `anchors.margins: 12` reproduces the intended
geometry exactly.

## Sites fixed (6)

| Line | Item | Was | Now | Enclosing pane |
|---|---|---|---|---|
| 386 | `winPanelBody` Column | `anchors.fill: winPanel` | `anchors.fill: parent` | `GlassPane id: winPanel` (L378, WINDOWS / WORKSPACES) |
| 589 | `agPanelBody` Column | `anchors.fill: agPanel` | `anchors.fill: parent` | `GlassPane id: agPanel` (L581, AGENT SESSIONS) |
| 702 | `procPanelBody` Column | `anchors.fill: procPanel` | `anchors.fill: parent` | `GlassPane id: procPanel` (L694, PROCESS LEDGER) |
| 803 | `repoPanelBody` Column | `anchors.fill: repoPanel` | `anchors.fill: parent` | `GlassPane id: repoPanel` (L795, REPOS / CI) |
| 903 | `tokPanelBody` Column | `anchors.fill: tokPanel` | `anchors.fill: parent` | `GlassPane id: tokPanel` (L895, TOKEN LEDGER) |
| 1056 | `AppGrid` | `anchors.fill: appsPanel` | `anchors.fill: parent` | `GlassPane id: appsPanel` (L1050, APPS NAVIGATOR) |

All six are direct children declared inside a `GlassPane` — verified by reading
each enclosing scope. Each retains its `anchors.margins: 12` (AppGrid has none).

## Sites audited and left alone (legal parent/sibling anchors)

- L260 `anchors.fill: parent` — `layoutRoot` Column, child of root Item.
- L276-278 `anchors.left/right/top: mast.*` — child Rectangle of `mast` (parent).
- L315 `anchors.fill: mast` — `mastRow` Row, child of `mast` (plain Rectangle,
  no reparenting — mast IS the parent).
- L322/332/345/354 `anchors.verticalCenter: mastRow.verticalCenter` — children
  of `mastRow` (parent).
- L397 `winPanelHead.verticalCenter`, L600 `agPanelHead`, L713 `procPanelHead`,
  L814 `repoPanelHead`, L914 `tokPanelHead` — all parent anchors.
- L431 `anchors.centerIn: wsChip`, L438 `anchors.fill: wsChip` — children of
  the `wsChip` Rectangle delegate (parent). `wsChip` is a plain Rectangle, not
  a GlassPane — no reparenting occurs.
- L478/L556 `anchors.fill: wcard`; L488/516/537/546 `wcardRow.verticalCenter`
  — children of the `wcard` delegate Rectangle / `wcardRow` Row (parent).
- L636 `anchors.fill: agCard`; L643/651/670/678 `agCardRow.verticalCenter`;
  L660 `anchors.centerIn: parent` — all parent anchors.
- L762 `anchors.verticalCenter: prow.verticalCenter` — child of `prow` Row
  delegate (parent).
- L986 `anchors.fill: trow`; L992/1002/1011/1020 `trowRow.verticalCenter` —
  children of the `trow` delegate Rectangle / `trowRow` Row (parent).

No `anchors.centerIn: <nonparent>` occurrences exist in the file (only the two
parent-targeting ones above).

## Journal line-number note

The journal's warning lines (~384, 463, 587, 666, 700, 779, 801, 880, 901,
980, 1205, 1055) were captured against an earlier revision — L1205 is beyond
the current 1069-line EOF. In the current file the complete defect set is the
six sites above; every anchor binding in the file was enumerated and
individually verified against its parentage.

## Verification

    /usr/lib/qt6/bin/qmllint v4/Workbench.qml   →  exit 0, no output
