# Launcher symmetry test: porting guide

Scope: `nexuslink.hud/v5/verify/tst_launcher_symmetry.qml` checks that any
launcher band is mirror symmetric about its centre line. The test is
portable: it imports only QtQuick and QtTest and reaches the launcher through
an adapter component. Deck A (v5-live) and deck B (main-live) run the same
test file.

## Run it

    tools/linux/measure/run-launcher-test.sh

Default: deck A adapter (`nexuslink.hud/v5/verify/launcher/AdapterDeckA.qml`),
test dir of this worktree. Exit 0 = all cases pass; the totals line is
`Totals: N passed, M failed`.

Environment (all optional):

| variable | meaning | default |
|---|---|---|
| `HUD_LAUNCHER_ADAPTER` | adapter QML file to test | `<verify>/launcher/AdapterDeckA.qml` |
| `HUD_LAUNCHER_IMPORT` | extra QML import dir, for the adapter's own module imports | unset |
| `HUD_VERIFY_DIR` | verify dir to run (scratch copies, mutants) | this worktree |

The script builds its own paths from its location (`$here/../../..`) and a
per-run module directory under `$TMPDIR` (removed on exit). No home path is
written in the script.

Example, a new launcher `Foo` in a scratch dir:

    HUD_LAUNCHER_ADAPTER=/abs/scratch/foo/AdapterFoo.qml \
    HUD_LAUNCHER_IMPORT=/abs/scratch/foo/import \
    bash tools/linux/measure/run-launcher-test.sh

The runner takes the shared render lock (`/tmp/hudlive-render.lock`), so
do not wrap it in another `flock`.

## How the selection works

QML has no environment access, so the runner writes a module per run:

    $TMPDIR/hud-launcher-sut.XXXX/HudLauncherSut/qmldir
        module HudLauncherSut
        LauncherSut 1.0 LauncherSut.qml
    $TMPDIR/.../HudLauncherSut/LauncherSut.qml
        import "file:///abs/dir/of/adapter"
        AdapterFileBaseName { }

The test does `import HudLauncherSut 1.0` and instantiates `LauncherSut`.
The adapter file's base name is the component name, so an adapter file must
be named like its type (`AdapterDeckA.qml`, type `AdapterDeckA`).

## Adapter contract

An adapter is one QML file: an `Item` sized 2560 x 1440 (the test window)
that renders the launcher at its real position in that window.

Inputs (writable properties):

- `apps`: array of app objects from `assets/apps.json` (`id`, `name`,
  `glyph`, `launches`, `running`, `size`; `size` "feature" marks the hero).
- `hoverIndexOverride`: int, visual slot to hover, or -1. The adapter maps it
  to whatever its launcher uses.

Outputs (read by the test):

- `centreX`: real, the centre line in window coordinates the group must
  mirror about.
- `pitch`: real, the expected distance between neighbouring tile centres.
- `heroScale`: real, the hero's effective scale (1.3 on both decks).
- `hoverMinScale`: real, a hovered tile must reach at least this scale.
- `dropId`: string, the app id the adapter leaves out of an odd list, or "".
- `tiles()`: function, array of Items in visual order (left to right).
  Each Item's centre is `item.mapToItem(window, width / 2, height / 2)`.
- `idAt(i)`: function, app id at visual slot i.
- `heroIndex()`: function, visual slot of the hero, or -1.
- `scaleAt(i)`: function, effective scale of slot i (the hero's enlargement
  as drawn; deck B grows the hero by tile width, so it is not `scale`).

Assertions (each prints one `LSYM` line with value, target and limit):

| group | name | rule |
|---|---|---|
| rest | count | tile count equals the list length |
| rest | odd_count | tile count is odd (every slot has a twin) |
| rest | hero_on_centre_x | hero centre within 1.0 px of `centreX` |
| rest | hero_slot | `heroIndex()` equals floor(n / 2) |
| rest | hero_scale | `scaleAt(hero)` within 0.001 of `heroScale` |
| rest | mirror_x_err | max over i of abs((x_i + x_mirror) - 2 * centreX) <= 1.0 |
| rest | mirror_y_err | max over i of abs(y_i - y_mirror) <= 0.2 |
| rest | pitch_vs_target | max abs(neighbour pitch - `pitch`) <= 0.5 |
| rest | pitch_spread | max - min neighbour pitch <= 0.5 |
| rest | balance_left_right | tiles left of centreX equal tiles right |
| hover | grow_left_1, grow_right_(n-2) | hovered scale > `hoverMinScale` |
| hover | scale_mirror_err | <= 0.01 between the two hover states |
| hover | hover_moves_tiles | no tile centre moves more than 1.0 px |
| hover | hover_mirror_x_err | mirror about `centreX` holds in the hover state |
| odd | dropped_ids | ids left out equal `dropId` ("none" when empty) |
| odd | rest rows | the same rest rows on the odd list, count minus the dropped app |

`pitch_min_max` is printed as an info row (no pass or fail).

Each group prints every row first, then fails once through `compare` if any
row failed, so a failing adapter still shows all its numbers.

## Deck A (default)

Adapter: `nexuslink.hud/v5/verify/launcher/AdapterDeckA.qml`. It wraps
`DeckView` (the `launcherBand`), centre 1280, pitch 116, hero scale 1.3,
`dropId` "obs". Result on this worktree (checkpoint c8a53a3 plus the
launcher-test change): `Totals: 5 passed, 0 failed`, exit 0.

## Deck B (main-live, scratch adapter)

Adapter (scratch only, not in the worktree):
`~/.hermes/cache/scratch/hud-live/work5/L1/deckB/AdapterDeckB.qml`, with the
kit copied from `git archive` of main-live HEAD into
`work5/L1/deckB/import/NexusHud/V5`.

- Source: main-live HEAD `ef6e5e0` (branch ws/main-deck-live), files
  `nexuslink.hud/v5/kit/LauncherArc.qml`, `IconTile.qml`, `Tokens.qml`,
  `Motion.qml`, `qmldir`, `icons/`. Read only via `git show` and `git archive`.
- Placement: `DeckSurface.qml` launcherX = 2560 - 96 - 1400 = 1064, launcherY
  988, box 1400 x 312. Centre line = 1764 (box x + 700).
- Adapter maps the default list: the `size` "feature" entry goes to the
  `hero` property; the other entries go to `apps` (slug, label, launchCount,
  running).

Run:

    HUD_LAUNCHER_ADAPTER=~/.hermes/cache/scratch/hud-live/work5/L1/deckB/AdapterDeckB.qml \
    HUD_LAUNCHER_IMPORT=~/.hermes/cache/scratch/hud-live/work5/L1/deckB/import \
    bash tools/linux/measure/run-launcher-test.sh

Result (11 apps, the shipped list): `Totals: 2 passed, 3 failed`, exit 3.

| group | row | value | target | limit | result |
|---|---|---|---|---|---|
| hover | grow_left_1 | 1.200 | 1.100 | min | PASS |
| hover | grow_right_9 | 1.200 | 1.100 | min | PASS |
| hover | scale_mirror_err | 0.300 | 0.000 | 0.010 | FAIL |
| hover | hover_moves_tiles | 0.000 | 0.000 | 1.000 | PASS |
| hover | hover_mirror_x_err | 50.981 | 0.000 | 1.000 | FAIL |
| rest | count | 11 | 11 | 0 | PASS |
| rest | odd_count | 11 | odd | 0 | PASS |
| rest | hero_on_centre_x | 2375.146 | 1764.000 | 1.000 | FAIL |
| rest | hero_slot | 10 | 5 | 0 | FAIL |
| rest | hero_scale | 1.300 | 1.300 | 0.001 | PASS |
| rest | mirror_x_err | 50.981 | 0.000 | 1.000 | FAIL |
| rest | mirror_y_err | 10.232 | 0.000 | 0.200 | FAIL |
| rest | pitch_min_max (info) | 117.131 .. 168.112 | | | |
| rest | pitch_vs_target | 46.112 | 122.000 | 0.500 | FAIL |
| rest | pitch_spread | 50.981 | 0.000 | 0.500 | FAIL |
| rest | balance_left_right | 6/5 | equal | 0 | FAIL |

Odd list (10 entries, no WhatsApp; deck B drops nothing): count 10 (even),
hero_slot 9, hero_on_centre_x 2339.550, mirror_x_err 53.100, pitch_spread
53.100; `balance_left_right` 5/5 PASS, `dropped_ids` none PASS.

What differs, from the numbers:

- The hero is the rightmost tile (slot 10, x 2375 against centre 1764), not
  the centre slot. Ten tiles sit left of it and none right. This is by design
  in deck B's LauncherArc ("ARC Raiders ... always the rightmost tile").
- The hero gap: the hero-to-neighbour centre distance is (122 + 148.2) / 2 +
  40 = 175.1 before fitting, and 168.1 measured. Normal neighbours are 122
  before fitting and 117.1 measured.
- The fit: the widths total 1408.2 px against a 1352 px span (the box less
  24 px air each side), so LauncherArc scales every gap by 1352 / 1408.2 =
  0.960. The pitch is 117.1, not 122.
- Hence the 51 px mirror error, the 10.2 px mirror y error and the 6/5
  balance.

Smallest change on the deck B side (words only, for the other lead): place
the hero at the centre slot of the drawn order (between the first and second
halves, like deck A's layoutOrder), and drop `heroGap` so every neighbour
pitch is the same. To keep 122 px pitch the box needs about 1408 px of span,
or the pitch must drop to about 117 px to fit 1400 px. Equal counts follow
from the centre slot. The hero scale (1.3 by tile width) is already right.

## Notes

- The test reads the shipped `assets/apps.json` over a file URL, so both
  decks get the same 11 apps. Run with `QML_XHR_ALLOW_FILE_READ=1`, which the
  runner sets.
- The deck B result is for main-live HEAD `ef6e5e0`. If that branch moves,
  rerun with the same env vars after refreshing the scratch kit copy.
- Mutation checks (C3 mutants on a copy of this worktree, `HUD_VERIFY_DIR`):
  `x3_drift_asym` exit 2, 3 passed / 2 failed (mirror_y 0.890 rest, 0.958
  odd); `x5_drift_right_plus03` exit 2, 3 passed / 2 failed (mirror_y 0.300
  rest and odd). Control: 5 passed.

## Adding a launcher

1. Make the launcher an `Item` that takes `apps` and renders at its real
   place in a 2560 x 1440 window.
2. Write `AdapterXxx.qml` next to it with the contract above (the file name
   is the type name).
3. Run the runner with `HUD_LAUNCHER_ADAPTER` and `HUD_LAUNCHER_IMPORT` set,
   and read the `LSYM` rows.
4. Do not hard code a centre or pitch in the test; the adapter supplies them.
