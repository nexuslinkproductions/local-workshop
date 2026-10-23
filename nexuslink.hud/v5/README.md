# nexuslink.hud v5 deck kit

The DP-2 "Command" deck. Design reference: `hud-candidates/comp-r1/s2/` while its
PNGs are on the Linux box, `comp-r1/s1/` on the Mac until they land. Plan and
acceptance: `MAIN-SCREEN-BUILD.md` in the HUD project root.

Wave 0 (this card, C1 SCAFFOLD) ships the skeleton only: two token singletons,
the Satoshi faces, feed fixtures and this file. Components arrive in Wave 1.

## Layout

    nexuslink.hud/v5/
      kit/
        qmldir              module NexusHud.V5, integrator-owned registration list
        Tokens.qml          singleton: guides, spacing, palette, type, focus
        Motion.qml          singleton: spring specs, stagger, breath, drift, curves
      fonts/
        Satoshi-Regular.ttf  weight 400
        Satoshi-Medium.ttf   weight 500
        Satoshi-Bold.ttf     weight 700
        Satoshi-Black.ttf    weight 900
        FFL.txt              licence
      fixtures/
        sessions.json       open crew sessions (3, from the real snapshot)
        metrics.json        host load, local AI, token day, screens, windows, kanban
        apps.json           9 most-used apps plus Arc Raiders, launcher arc order
        link.json           Mac link: route, tunnel, RTT samples, battery, load
      README.md

`DeckMain.qml` and the shell-runtime layer are not in this tree yet. The
integrator card owns them.

## The pure-QtQuick rule

Every file under `kit/` imports only `QtQuick`, `QtQuick.Shapes` and
`QtQuick.Effects`. Nothing else, ever. The desktop shell runtime that hosts the
deck on Linux (named in `MAIN-SCREEN-BUILD.md`, constraint 2) is not installed on
the Mac and cannot be imported from a kit file, because the Mac is the machine
that lints and offscreen-renders every still.

Data enters the kit by properties. The shell-runtime surface (IPC, Process,
FileView, PanelWindow) stays in `DeckMain.qml` and friends, stays thin, and is
verified on Linux.

Check before every push: one recursive grep of that module name over
`nexuslink.hud/v5/` must print nothing and exit 1. This file deliberately does
not spell the token, so the grep stays honest when it walks the README too. The
same grep is written out in the C1 and V1 cards.

## Adding a component in Wave 1

1. Add exactly one file, `nexuslink.hud/v5/kit/<Name>.qml`. Import `QtQuick`,
   `NexusHud.V5 1.0` for the tokens, and `QtQuick.Shapes` or `QtQuick.Effects`
   only if the component actually draws with them. Nothing else. Icon files are
   W4's (`kit/icons/`, not in this tree yet): import that directory only in a
   card that lands after W4, otherwise draw the glyph inside the component.
2. Take every number from `Tokens` and `Motion`. A literal pixel or colour in a
   component is a review failure unless it is geometry for one drawing.
3. Do not edit `kit/qmldir`. The integrator owns it and adds your line:

       <Name> 1.0 <Name>.qml

4. Put that exact line in your PR body under a heading `qmldir line` and say
   which mechanical check proves it: the registration must resolve, not just
   exist. See the load test below.

One owner per file per wave. Two cards never touch the same `.qml`.

## Import path and the transaction that proves it

Qt resolves `import NexusHud.V5 1.0` by looking for `<importPath>/NexusHud/V5/qmldir`.
The directory on disk is `v5/kit`, so the import path needs the module-shaped
view. A symlink is enough and is what a component card or verifier should use:

    W=~/NEXUS_AI_CENTER/04_PROJECTS/HUD/plugins/.worktrees/<card>/nexuslink.hud/v5
    H=<scratch>/imports
    mkdir -p "$H/NexusHud" && ln -sfn "$W/kit" "$H/NexusHud/V5"

    # lint: consumer file, resolves the qmldir
    qmllint -I "$H" mytest.qml
    # load: singletons instantiate and their values are readable
    QT_QPA_PLATFORM=offscreen qml -I "$H" mytest.qml

A throwaway `mytest.qml` that reads `Tokens.acid` and `Motion.breathPeriod` and
exits 0 is the proof that the module resolves. Linting a singleton file directly
(`qmllint kit/Tokens.qml`) prints the diagnostic `Type Tokens not declared as
singleton in qmldir but using pragma Singleton`; qmllint 6.12 prints it for every
`pragma Singleton` lint target, untouched v4 files included. It is a tool
artifact, not a defect. The consumer lint above is clean.

## Tokens provenance

Target 2560x1440. Numbers come from `hud-candidates/comp-r1/s1/src/build.py`
(10-24 guides, 20 palette, 203-214 type) and `comp-r1/s1/README.md`.

| Token | Value | Where it comes from |
|---|---|---|
| `unit` | 8 px | base grid |
| `spacing` | 8 13 21 34 55 89 144 233 377 | Fibonacci from 8, each ratio is phi to 0.02 |
| `goldenX1` / `goldenX2` | 978 / 1582 | 0.382 and 0.618 of 2560 (977.92, 1582.08) |
| `goldenY1` / `goldenY2` | 550 / 890 | 0.382 and 0.618 of 1440 (550.08, 889.92) |
| `thirdX1` / `thirdX2` | 853 / 1707 | 2560 / 3 and 2 * 2560 / 3 |
| `thirdY1` / `thirdY2` | 480 / 960 | screen thirds |
| `centreX` | 1280 | half width |
| `knotDiameter` | 540 | 37.5 percent of the height, s1 engine call |
| `knotCentreY` | 550 | upper golden line |
| `heroRadius`, `powerPoints` | 112, four thirds points | s1 hero widgets |
| `ice` `azure` `cyan` `white` `acid` `amber` | #8fd8e8 #60a5fa #00c8f0 #f4f8fb #c8f31d #ffb454 | s1 build.py:20 |
| `red` | #ff4a3d | v4 `Style.qml` "alert"; s1 ships no red face |
| `field` `ink` `textLabel` `textCaption` `textDim` `textDate` | #06080a #eaf4f8 #b3d0da #a8c4cf #8fb2c0 #9fc3cf | s1 page CSS |
| type ramp | 16 20 26 44 68 110 168 px | s1 scale 16 / 26 / 68 / 110 / 168, plus label and title |
| `focusDim` | 0.26, band 0.18 to 0.30 | plan band; motion-r1 `focusEnv` 0.3, s1 rendered 0.16 |
| `focusScrim`, `focusBlur` | 0.35, 10 px (8 to 12) | plan and motion-r1 `scrim`, `focusEnv` |

Nothing paints below 16 px (`minTypeSize`). `s2` wins over `s1` when its PNGs
land and a value disagrees; the lead says so on the card, no one guesses.

## Motion provenance

Numbers are from `hud-candidates/motion-r1/motion.json`, with the plan's bands
enforced.

| Token | Value | Source |
|---|---|---|
| `expandZeta` / `expandOmega` | 0.69 / 16.7 | motion.json `springs.expand` |
| `expandOvershoot` | 0.05 (5.00 percent) | exp(-zeta * pi / sqrt(1 - zeta^2)) |
| `expandMillis` | 347 ms | 4 / (zeta * omega) |
| `returnZeta` / `returnOmega` | 1.0 / 9.0 | motion.json `springs.return`, no overshoot |
| `returnMillis` | 444 ms | 4 / (zeta * omega), slower than expand |
| `stagger` / `staggerTight` | 45 / 30 ms | motion.json staggers 22 to 45, band is 30 to 60 |
| `breathPeriod` / `breathInhale` | 5.8 s / 0.40 | motion.json `idle.breath`, 40 inhale 60 exhale |
| `driftAmpMin` to `driftAmpMax` | 1.0 to 2.0 px | motion.json `idle.drift` |
| `driftPeriodMin` to `driftPeriodMax` | 7 to 13 s | motion.json `idle.drift` |
| curves, role durations | see the file | motion.json `curves`, `roles` |

## Fonts

Satoshi, four weights, downloaded from the Fontshare API on 2026-10-22:

    curl -o Satoshi_Complete.zip https://api.fontshare.com/v2/fonts/download/satoshi
    # HTTP 200, content-type application/zip, 2168134 bytes, file name Satoshi_Complete.zip

Sources inside the zip: `Satoshi_Complete/Fonts/WEB/fonts/Satoshi-Regular.ttf`,
`Satoshi-Medium.ttf`, `Satoshi-Bold.ttf`, `Satoshi-Black.ttf`. All four are
TrueType, 73300 to 73888 bytes. Licence file: `fonts/FFL.txt`, the ITF Free Font
License 2.0 (17 Aug 2026) shipped in `Satoshi_Complete/License/FFL.txt`.

Family names, measured on Qt 6.12.0 on this Mac rather than read off the file:

    FontLoader over Satoshi-Regular / -Medium / -Bold / -Black -> name "Satoshi" for all four
    Qt.fontFamilies() filtered on "satoshi"                 -> ["Satoshi"]
    TextMetrics "HHHHH" at 68 px, family "Satoshi", weights   -> 239.69 / 245.47 / 252.27 / 259.69
    TextMetrics family "Satoshi Medium" or "Satoshi Black"    -> 240.78, equal to a bogus family
                                                                 name, plus a Qt warning that the
                                                                 family is missing

So there is one family, `Tokens.fontFamily` is `Satoshi`, and weight picks the face. Load the four
files once, then set `font.weight`. The style-linked names in the font name tables
(`Satoshi Medium`, `Satoshi Black`, nameID 1) are a trap on this build: they resolve
to a fallback face, so a deck that uses them draws the right text in the wrong font.

    FontLoader { id: satoshi400; source: <module>/fonts/Satoshi-Regular.ttf }
    FontLoader { id: satoshi500; source: <module>/fonts/Satoshi-Medium.ttf }
    FontLoader { id: satoshi700; source: <module>/fonts/Satoshi-Bold.ttf }
    FontLoader { id: satoshi900; source: <module>/fonts/Satoshi-Black.ttf }
    // then: font.family: Tokens.fontFamily, font.weight: Tokens.weightMedium

## Fixtures

One file per future feed, shaped like the real payload, small enough to read.
Copied from `hud-candidates/comp-r1/s2/src/data.json` (snapshot `gen`
1792703222.1396573, 2026-10-22T21:07:02Z), so the numbers and ids are real, not
invented.

| File | Shape | Notes |
|---|---|---|
| `sessions.json` | array of session objects | the 3 open sessions in that snapshot; absolute `started_at` and `last_activity_at` epoch plus ISO, so a fixture read tomorrow is still checkable. W2 extends it if it needs a denser orb |
| `metrics.json` | object snapshot | host load, local AI, token day, screens, windows, kanban counts out of `data.json`; the `local_ai` block (model, 0.33 GB, breath 6 s) is from the s1 study, and its `budget_scale_gb` 4.0 is that study's own scale, not a measured cap. `budget_note` says so in the file |
| `apps.json` | array of 10 | the 9 most used (`devin` 8, `hermes` 3, `october` 3, `Discord` 3, `Nautilus` 2, `spotify` 1, `OBS` 1, `chromium` 0, `foot` 0) in s1/s2 launcher arc order, then `arc-raiders` (`steam_app_1808500`, running in the snapshot) as the larger feature tile at slot 9 |
| `link.json` | object snapshot | route, tunnel, 24 RTT samples with median 7.5 ms, derived pulse period 2.932 s, battery, load, peers |

`apps.json` glyph ids match the s1 icon set. `arc-raiders` has no glyph yet; W4
draws it. Feed builders (W8) replace these files with live output of the same
shape, and the Linux side does the live-data check.

## Rules that outrank this file

`MAIN-SCREEN-BUILD.md` (constraints, waves, acceptance) and the fleet charter
`BRIDGE/FLEET.md`. A builder never merges its own PR. One owner per file per
wave. Stage explicit paths only.
