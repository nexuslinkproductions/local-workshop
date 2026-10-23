# deckmain-shell: offscreen test shell for DeckMain.qml

Runs the real DeckMain.qml inside a private Quickshell, offscreen, with the
commands it would run stubbed, so a scenario can read the hud state and drive
it. It never touches a live Wayland session.

## Run

    tools/linux/deckmain-shell.sh --scenario smoke              # 3 s, prints status, quits
    tools/linux/deckmain-shell.sh --scenario keys-demo          # synthetic keys into a TextInput
    tools/linux/deckmain-shell.sh --scenario smoke --seconds 20 --stub-log /path/stub.log
    tools/linux/deckmain-shell.sh                               # no scenario: runs --seconds, then killed

`--scenario` takes a path, or a name under scenarios/ (with or without .qml).
`--seconds` (default 20) is the hard limit. Exit codes: 0 clean; 1 an error
line, a scenario that did not quit in time, a quickshell crash or a leftover
process; 2 usage; 3 the generator failed.

Output is only the SCENARIO, WARN, ERROR, RangeError, TypeError, ReferenceError
and "Binding loop" lines. The SCENARIO prefix is normalised to "SCENARIO ...".
The raw quickshell log is $TMPDIR/deckmain-shell-<key>.last.log. A summary line
goes to stderr. The known benign line "qmlscanner: Module path contains invalid
characters" (caused by the dotted nexuslink.hud directory name) is filtered.

## Files

- tools/linux/deckmain-shell.sh     runner (isolation, stubs, timeout, census)
- deckmain-shell/gen_testshell.py   builds the mirror from the CURRENT DeckMain.qml
- deckmain-shell/stubs/_stub        the one stub script; NAMES lists omarchy-* names
- deckmain-shell/scenarios/         smoke.qml, keys-demo.qml

## Isolation

The env is the one from SHARED.md rule 2: `env -u WAYLAND_DISPLAY -u
HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY`, XDG_RUNTIME_DIR = a private
`mktemp -d` under $TMPDIR (chmod 700), QT_QPA_PLATFORM=offscreen,
QT_QPA_PLATFORMTHEME=none, NEXUSLINK_HUD_V5=1. XDG_CACHE_HOME and
XDG_STATE_HOME also go to the private dir. quickshell runs as
`quickshell -n -p <mirror>` under `nice -n 19 ionice -c3 timeout -k 3 -s TERM N`
in its own process group. At the end the group is killed, and a census kills
anything still running from this mirror and prints ERROR. Marcel's
`quickshell -n -p /usr/share/omarchy/shell` is never matched or touched.

## Mirror and test copy

The mirror is $TMPDIR/deckmain-shell-<cksum of worktree path>. It is rebuilt on
every run and carries a marker file; the generator refuses to wipe a directory
that has no marker. Layout:

- shell.qml: ShellRoot. It imports "nexuslink.hud/v5" and makes a DeckMain
  instance, then loads DECKMAIN_SCENARIO (if set) with setSource(url, {hud, log}).
- nexuslink.hud/v5/<every entry of the real v5>: symlinks, except DeckMain.qml.
- nexuslink.hud/v5/DeckMain.qml: the test copy (below).
- nexuslink.hud/v4: symlink (ScreenRoles.js).
- imports/NexusHud/V5 -> v5/kit and imports/NexusHud/fonts -> v5/fonts, on
  QML_IMPORT_PATH (same mapping as deck-shot.sh).
- GENERATED.txt: the list of every change. The same list is printed as WARN.

Changes to DeckMain.qml (the only window block, found by brace depth):

- `PanelWindow {` becomes `FloatingWindow {`. Added: visible: true,
  implicitWidth/implicitHeight 2560x1440 (width/height print a deprecation
  warning), title, and `id: testPanel` if the window has no id.
- Dropped direct children of the window: `screen:`, `anchors {...}`,
  `exclusionMode:`, `WlrLayershell.namespace/layer`.
- `WlrLayershell.keyboardFocus: <expr>` is dropped as a binding and becomes
  `property var keyboardFocusProbe: <expr>` on the window. The root object
  exposes `testPanel` (the window) and `keyboardFocusProbe`, so a scenario reads
  what the real binding evaluates to: `hud.keyboardFocusProbe`.
- Everything else is untouched, including the IpcHandler and the feeds.

Test copy is re-derived on every run. A new `WlrLayershell.*` line in
DeckMain.qml shows up as a WARN line, so check it there.

## How a scenario drives hud

A scenario is a QML file whose root is an Item with two properties:

    property var hud: null     // the DeckMain root (test copy)
    property var log: null     // log(msg) prints "SCENARIO " + msg

Read hud properties directly (clockText, dayText, sessions, apps, allApps,
hero, findResults, findQuery, findFilter, focusId, mediaTitle, mediaPlaying,
rttMs, batteryLevel, loadLevel, lastFeedError, v5DeckEnabled), call its
functions (launch(slug), runQuickAction(id), toggleMedia(), setClock(date)),
and read the window through hud.testPanel and hud.keyboardFocusProbe. Waits are
Timers. End with Qt.quit(). See scenarios/smoke.qml.

## Stub log

Stubbed: xdg-open, yuri, playerctl, ssh, the names in stubs/NAMES, and every
/usr/share/omarchy/bin/omarchy-* file (read-only listing at run time). Each
symlink points at stubs/_stub. Each call appends ONE line to
$DECKMAIN_STUB_LOG: the command name, then each argument, tab separated. The
default log is $TMPDIR/deckmain-shell-<key>.stub.log; --stub-log overrides it.
It is truncated at the start of each run. Exceptions: `yuri search ...` prints a
two-item JSON array, other yuri calls print a usage text, and `ssh` exits 255
(the link feed uses ssh, so no feed reaches a Mac).

## Keys (verified recipe)

scenarios/keys-demo.qml shows it. Verified output:

    SCENARIO keys begin
    SCENARIO keys field.activeFocus=true
    SCENARIO keys text=[hud] length=3      (exit 0)

- `import QtTest`, then `TestEvent { id: ev }` in the scenario root.
- `ev.keyClick(Qt.Key_H, Qt.NoModifier, 0)`. All three arguments are needed;
  the one-argument form fails with "Error: Insufficient arguments".
- The target is the focused item in a FloatingWindow inside the scenario. Call
  `field.forceActiveFocus()` first; it gives activeFocus=true.
- Not functions on Quickshell's FloatingWindow: requestActivate(), raise().
  `win.active` is undefined there. Do not use them.
- Not tried: keyClickChar, and Item.grabToImage (no PNG proof in this wave).

## Limits (what this does NOT prove)

- Layer-shell placement: Background layer, namespace, output choice (the
  command role), exclusion and anchors are not exercised. FloatingWindow is a
  plain toplevel.
- Real keyboard focus: the compositor's grant of WlrKeyboardFocus is not
  tested. keyboardFocusProbe only shows the value of the expression.
- Feeds: DeckMain's Process readers run for real. sessions.py reads the Hermes
  state db read-only. Any command or network path that is not stubbed runs for
  real. Only the commands listed above are intercepted.
- Offscreen platform noise: "This plugin does not support setting window masks"
  is printed as WARN. It is expected.
- Qt warns at load time about DeckSurface.qml: `signal focusChanged(string id)`
  is reported as "Duplicate signal name" (line 117 or 118 depending on the
  edit). This is a finding for the surface owner, not a runner error.
