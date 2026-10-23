# I1 integration — how the v5 deck is wired

Three questions, in the order they matter: how a feed reaches the deck, how a
widget expands into its deeper view, and how the whole thing rolls back.

## 0. The file split (and why it exists)

| file | imports | role |
|---|---|---|
| `nexuslink.hud/v5/DeckMain.qml` | `Quickshell`, `Quickshell.Io`, `Quickshell.Wayland` | the shell layer: one `PanelWindow` on the command-role output, every feed `Process`, every `FileView`, the IPC target, the launch table, the rollout flag |
| `nexuslink.hud/v5/DeckSurface.qml` | `QtQuick` + `NexusHud.V5` only | the composition: knot slot, crew orb, gauges, launcher, find, clock, deep views, the focus manager, the four `FontLoader`s |
| `nexuslink.hud/v5/kit/*` | `QtQuick`, `QtQuick.Shapes`, `QtQuick.Effects`, `NexusHud.V5` | Wave 1 components, property-driven, no I/O |
| `nexuslink.hud/v4/HudV4.qml` | unchanged imports | the v4 root, with one flag and one extra `Loader` |

A grep for the Quickshell import line under `nexuslink.hud/v5/` matches
`DeckMain.qml` and nothing else — the hard rule from the plan.

The split is not decoration. Quickshell is not installed on this Mac and there is
no Wayland compositor, so a file that imports it cannot be loaded by
`tools/qml-shot.sh` at all; if the composition lived inside `DeckMain.qml` the
deck could not be rendered, audited or benchmarked here, and the acceptance
evidence would have to come from Linux. With the split, the deck is proved
offscreen on the Mac (`DeckSurface.qml`) and the shell layer is thin enough to
review by reading (`DeckMain.qml`).

## 1. How a feed enters

```
feeds/<reader>.py  --stdout JSON-->  Process.stdout (StdioCollector)  -->  DeckMain property
                                                                          |
                                      DeckSurface.<property>  <--------- binds
```

Concretely, in `DeckMain.qml`:

```
Process {
    id: linkProc
    command: ["python3", hud.feedsDir + "/link.py"]
    stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: { var v = hud.readJson(text, null); … hud.rttMs = …; hud.batteryLevel = … }
    }
}
Timer { interval: 10000; repeat: true; triggeredOnStart: true
        onTriggered: { sessionsProc.running = true; linkProc.running = true; metricsProc.running = true } }
```

and in the panel:

```
DeckSurface {
    rttMs: hud.rttMs
    batteryLevel: hud.batteryLevel
    sessions: hud.sessions
    …
}
```

Rules the layer keeps:

* **Nothing in `DeckSurface.qml` or `kit/` reads a file, spawns a process or
  starts a timer that reads a feed.** Data arrives by property. `FindResults`
  gets `results` from `DeckMain`; the stills get the same properties from
  `v5/stills/DeckFixtures.qml`.
* **A missing or malformed feed is not an error state.** `readJson()` returns the
  fallback, the deck keeps its calm rest state, and the last good value stays on
  screen. `FileView`s over `v5/fixtures/*.json` are the fallback when a reader is
  not installed on the host.
* **Cadence:** 10 s for link/sessions/metrics, 60 s for apps and `df`. Fleet pulse
  asks for "cache 10 s, never faster"; the deck keeps that as the ceiling.
* **`disks` has no reader yet.** `DeckMain` runs `df -B1 --output=source,used,size,target`
  and shapes the rows as `{label, mount, used, usedGb, sizeGb}`; the storage deep
  view consumes exactly that.
* **Typography** is loaded once in `DeckSurface.qml` from `Tokens.fontFiles`
  (`v5/fonts/Satoshi-{Regular,Medium,Bold,Black}.ttf`), and again in `DeckMain`
  for the shell instance. Two registrations of the same file are harmless, and
  the second one is what makes an offscreen still Satoshi without Quickshell.
  (`kit/Clock.qml` has its own loaders that resolve one directory too high through
  the module symlink; the family is already registered by then, so it is inert.)

## 2. How a widget expands into its deeper view

One string is the whole focus manager: `DeckSurface.focusId` — `""` at rest, else
`crew`, `find`, `launcher`, `mac`, `storage` or `local`. It is set by a click on
the widget's own area, by the keyboard (`Esc` clears; `C F L M S A`), or by IPC
from the shell. It drives three things at once:

1. **`kit/Focus`** — `active: focusId !== ""` and `targetRect: focusRect`. Focus
   captures the HUD content once, draws a dimmed, scrimmed, blurred copy (0.26 in
   the 0.18 to 0.3 band, scrim 0.35, 10 px blur, all from `Tokens`) and crops the
   target rect out of the same snapshot at full opacity. Only HUD pixels are
   affected, never the desktop behind the panel.
2. **The widget's own expanded state** — `CrewOrb.expanded`, `LauncherArc.expanded`,
   `FindField.active`, and the deep-view overlay in `DeckSurface` for `mac`,
   `storage` and `local`.
3. **`focusRect`** — one rect per target, sized to what the focused widget
   actually paints. No slack: anything inside the rect is drawn crisp, so a
   too-large rect would ghost the neighbours back to full brightness.

Which view each target opens:

| focusId | deeper view | data |
|---|---|---|
| `crew` | the orb grows to 1.4x and lists one title per session; clicking a row drills into agent, state and activity | `sessions` |
| `find` | the pill widens to 560 and shows typed result tiles, dimming non-matches | `findResults`, `findQuery`, `findFilter` |
| `launcher` | the arc expands to the all-apps set (Obsidian and Spotify join, the Arc Raiders hero stays at the right end) | `apps`, `allApps`, `hero` |
| `mac` | `PulseRing` at the RTT, `DotArc` for the battery, and the load bar, under the segmented field | `rttMs`, `batteryLevel`, `loadLevel` |
| `storage` | one dot-bar per disk plus the capacity arc | `disks` |
| `local` | the W3 `LocalOrb` sphere beside the level stack, with the model size | `modelGb`, `modelActivity` |

The rest state stays under 40 words because every one of those labels is inside
the expanded view; the audit measures 16 words at rest (`acceptance.md` §3).

Transition in and out is a spring each way (`Motion.expandMillis` in with an
OutBack that peaks at 5 percent, `Motion.returnMillis` out, monotone, no
overshoot) — measured on the deck in `motion.md`.

## 3. How the flag rolls back

One environment variable, read in two places from the same expression:

```
NEXUSLINK_HUD_V5=1      -> the command output shows the v5 deck
unset / 0 / false / off -> the v4 DeckCommand, byte for byte as before
```

In `v4/HudV4.qml` the only changed lines are the property:

```
readonly property bool v5Deck: { … Quickshell.env("NEXUSLINK_HUD_V5") … }
```

and the role switch:

```
sourceComponent: win.isCommand
                 ? (hud.v5Deck ? commandScreenV5 : commandScreen)
                 : win.isHardware ? tokensScreen
                 : systemScreen
```

plus one new `Component { id: commandScreenV5; Loader { source: "../v5/DeckMain.qml" } }`.

Why that shape:

* **The v4 deck is untouched.** `DeckCommand`, `DeckTokens`, `DeckSystem` and
  every binding into them are as they were; `commandScreen` is still the default
  branch.
* **Loaded by URL, not by import.** `HudV4.qml` never imports the v5 tree, so a
  broken v5 file cannot take the v4 deck down while the flag is off, and the
  Quickshell import rule stays intact.
* **Rollback needs no file edit and no restart of anything but the shell:** flip
  the variable and restart the shell once. The same value is reported by the v5
  IPC `status()` as `enabled`, so an operator can see which deck the shell
  believes it is showing.

IPC surface (`omarchy-shell nexuslink.hud.v5 <method>`, deliberately a different
target from v4's `nexuslink.hud` so the two decks can never answer for each
other): `status`, `focus <id>`, `clearFocus`, `query <text>`, `filter <name>`,
`assembly <0..1>`, `launchApp <slug>`. Launches are looked up in the ranking and
spawned from a fixed table — an unknown slug is refused with a string, not a
shell interpolation.

## 4. Registration and token hoisting done in this PR

`kit/qmldir` registers `Swarm`, `SwarmSphere`, `Knot`, `CrewOrb`, `PulseRing`,
`DotArc`, `DotBar`, `LocalOrb`, `IconTile`, `LauncherArc`, `FindField`,
`FindResults`, `Clock`, `Focus`, `IdleDrift` (plus the two singletons). `kit/icons/*`
is deliberately not registered: `IconTile` reaches the glyphs with
`import "icons" as Icons` and `Glyph` maps a key to a `Component`, so the file
grows by two lines instead of nineteen (W4's measured reason).

Token hoisting promised during the wave, 61 literals moved out of components:

| component | hoisted to `Tokens` |
|---|---|
| `PulseRing.qml` | `pulseRingSize`, `rttWarnMs`, `rttPeriodFloorS`, `rttPeriodBaseS`, `rttPeriodSlope`, `rttFloorMs`, `focusLift`, `ringAlphaRead`, `ringAlphaFocusGain`, `ringAlphaRest`, `pulseScaleMin/Max`, `pulseAlphaMin/Max`, `ringPhases`, and `pulseCurve` → `Motion.curveInOut6` |
| `DotArc.qml` | `dotArcSize`, `dotArcDots`, `dotArcRadius`, `dotArcDotRadius`, `dotArcStartDegrees`, `dotArcSpanDegrees`, `focusLift`, `dotLit`, `dotDim`, `dotDimFocusGain` |
| `DotBar.qml` | `dotBarSegments`, `dotBarSize`, `dotLitShare`, `dotDimShare`, `barHeightHeadroom`, `focusLift`, `dotLitBar`, `dotDimBar`, `dotDimFocusGain` |
| `LocalOrb.qml` | `localBudgetGb`, `localOrbSize`, `localOrbRadius`, `orbRadiusFloor/Span`, `orbDotDensity`, `orbMinDots`, `activityLift`, `activityAlphaBase/Gain`, `focusLift`, `orbCoreSize/SizeGain/Alpha/AlphaGain`, `orbDotRadiusBase/DepthGain`, `orbDotAlphaBase/DepthGain`, and `breathCurve` → `Motion.curveInOut6` |
| `FindField.qml` | `findRestDotBand` (the `restDotBand` promise), `findFieldHeight`, `findFieldRestWidth`, `findFieldActiveWidth`, `findChipHeight`, and `expandOvershoot` → `Motion.curveOvershoot5` |

Every value is unchanged: the components read the token, the number lives in one
place. Nothing was renamed or removed, so every component that already read
`Tokens` or `Motion` still resolves. The two alpha pairs that differ between the
arc and the bar (0.95/0.18 against 1.0/0.16) are kept as four tokens rather than
collapsed into two, because both were measured design values from s2.

Still local (a token request that would mean editing W2/W4/W5 files, which this
card does not own — they are listed here so the next wave can fold them):
`CrewOrb` expand/anchor/depth/dot constants and the `agentAccents` map,
`IconTile`'s 13 `icon*` values, `LauncherArc`'s launcher band values.

## 5. Repair cards this PR raises

A component that is wrong goes back as a card, not as a local rewrite:

1. **`kit/LauncherArc.qml` loads glyphs by URL** (`source: "icons/" + slug + ".qml"`)
   while W4 shipped capitalised files (`Hermes.qml`, `XMark.qml`, …), so on a
   case-sensitive filesystem every tile falls back to its dot letterform and the
   brand glyphs never appear. It should use W4's dispatcher:
   `Icons.Glyph { glyph: slug }`.
2. **`kit/icons/` has no `spotify` or `obsidian` glyph**, so the all-apps view
   (which the binding amendment requires those two to appear in) draws the
   unknown-node fallback for them.
3. **`kit/LocalOrb.qml:81-82`** passes `damping 23.03` to a `SpringAnimation` and
   was flagged by W2 as outside the 4 to 6 percent band; not measured again here
   because the deck only composes `LocalOrb` in the `local` deep view.
