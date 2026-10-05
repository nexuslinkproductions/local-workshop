# LANE G1 — AppGrid: MOST USED persistence + category groups

Scope: `v4/AppGrid.qml` only (source of truth on the Kingston drive), synced
verbatim to the deployed mirror
`~/.config/omarchy/plugins/nexuslink.hud/v4/AppGrid.qml`. No other files
touched. Shell was NOT restarted.

## G1-a. MOST USED at top — persisted launch counts

Claim: every `gtk-launch` bumps a per-desktop-id counter persisted to
`~/.config/omarchy/nexuslink/appuse.json`; unfiltered list renders a
`MOST USED` section (count desc, cap 10) above the grouped remainder;
absent/corrupt state degrades to plain grouping and never blocks the list.

Mechanism mirrors HudV4.qml's `hud-state-v4.json` persistence exactly
(HudV4.qml:150-199): `mkdir -p` via dormant `Process` → `FileView`
(`watchChanges:false`, `atomicWrites:true`, `printErrors:false`, read through
`onLoaded`/`onLoadFailed`) → debounced `setText` write behind a `Timer` →
watchdog `Timer` so a missing file can't wedge `useLoaded`. `FileView`'s
`atomicWrites` already gives crash-safe writes (temp+rename), so no
`Process printf` shell-out is needed for the write itself — the mkdir is the
only Process in the loop.

### Evidence

| Piece | Location (AppGrid.qml) |
|---|---|
| state paths | :87-89 `useStateDir`/`useStatePath` → `appuse.json` |
| FileView read | :93-101 `onLoaded`/`onLoadFailed` → `loadUseCounts` |
| mkdir Process | :102-106 `useMkdirProc` |
| debounced write | :107-112 `useSaveTimer` → `useFile.setText(JSON.stringify(buildUseState()))` |
| load watchdog | :113-120 `useWatchdog` (1200 ms, frees `useLoaded` on first-run absence) |
| loader (merge, validates `{version:1, counts:{id:n}}` shape, corrupt→{}) | :126-152 `loadUseCounts` |
| counter bump + save trigger | :156-166 `bumpUse` |
| launch hook | `launch()` :459-465 calls `bumpUse(row.id)` right after `gtk-launch` |
| MOST USED section | `refilter()` :372-426 — counted slice `counted.sort` (count desc, alpha tiebreak), `slice(0,10)`, `section = "MOST USED"`, pinned ids removed from category groups via `inTop` |
| count shown on row | meta text prefixes `N× ·` when `section === "MOST USED"` (:715) |
| boot ordering | `Component.onCompleted` :246-252 — mkdir, `Qt.callLater(useFile.reload)`, rebuild |

Degrade path: `loadUseCounts("")` (onLoadFailed) or any non-object JSON
leaves `useCounts = {}` → `useCount()` returns 0 → no `MOST USED` rows →
list is pure grouped-alpha. `useWatchdog` covers the case where neither
FileView signal ever fires.

## G1-b. CATEGORIES — grouped sections

Claim: `Categories` is decoded on BOTH paths — `DesktopEntry.categories`
(QStringList, per quickshell-core.qmltypes `desktopentry.hpp` — verified on
system at `/usr/lib/qt6/qml/Quickshell/quickshell-core.qmltypes`) and the
FileView INI fallback (`Categories=` split on `;`). `groupOf()` maps
freedesktop main categories to HUD groups; `ListView.section.property:
"section"` renders headers. Filtered queries keep group headers for the
matching subset (rows keep `section = group`).

| Piece | Location |
|---|---|
| DesktopEntries path | decodeEntry :262-285 — `e.categories` → `cats` → `groupOf(cats)` |
| FileView INI fallback | parseDesktop :318-338 — `Categories` split on `;`, `groupOf(cats)` |
| mapping + precedence | `groupOf` :169-188 — Game→GAMES, Development→DEV, Graphics→GRAPHICS, AudioVideo/Audio/Video/Music/Player/Recorder/TV→MEDIA, Network→NET, Office→OFFICE, Settings/System→SYSTEM, Utility→TOOLS, else→OTHER |
| group display order | `groupRanks`/`groupRank` :190-197 (DEV, TOOLS, MEDIA, GRAPHICS, GAMES, NET, OFFICE, SYSTEM, OTHER) |
| section sort | `refilter` :403-418 — unfiltered: group rank then alpha; filtered: same ordering on the matching subset so headers stay meaningful |
| header delegate | ListView :639-664 — `section.property:"section"`, `ViewSection.FullString`, accent bar + group label (accent-lit for `MOST USED`) |

### Real categories resolved on this machine (spot check)

```
btop.desktop        Categories=System;Monitor;ConsoleOnly      → SYSTEM
foot.desktop        Categories=System;TerminalEmulator         → SYSTEM
chromium.desktop    Categories=Network;WebBrowser              → NET
localsend.desktop   Categories=Utility;Network                 → NET   (Network outranks Utility)
mpv.desktop         Categories=AudioVideo;Audio;Video;Player;TV→ MEDIA
cliamp.desktop      Categories=Audio;Music;Player;AudioVideo   → MEDIA
cmake-gui.desktop   Categories=Development;Building            → DEV
nvim.desktop        Categories=Utility;TextEditor;Development  → DEV   (Development outranks Utility)
pinta.desktop       Categories=Graphics;2DGraphics;RasterGraphics → GRAPHICS
moonlight.desktop   Categories=Qt;Game                         → GAMES
xournalpp.desktop   Categories=Office;GNOME;GTK                → OFFICE
```

Precedence inside `groupOf` puts the more specific category ahead of
`Utility`/`Settings` catch-alls, so e.g. Neovim files under DEV and
LocalSend under NET.

## Untouched (per brief)

- Keyboard nav (`handleKey`, selection clamp), `HyprlandFocusGrab` arm/disarm,
  icon resolution (`iconSrc` + fallback glyph), mouse launch path — all
  byte-identical except `launch()` gaining one `bumpUse` line.
- Launch still argv-only `["gtk-launch", row.id]`; count write is the only
  side effect added.

## Checks run

```
$ /usr/lib/qt6/bin/qmllint AppGrid.qml            → exit 0, no output
$ cp v4/AppGrid.qml ~/.config/omarchy/plugins/nexuslink.hud/v4/AppGrid.qml
$ diff -q <src> <mirror>                          → SYNCED (identical)
$ /usr/lib/qt6/bin/qmllint <mirror>/AppGrid.qml   → exit 0, no output
```
