LAUNCH-NOTES.md - which call launches what (v4, read only) and the v5 adapter
Notes on the launcher. All v4 files under nexuslink.hud/v4/. Line numbers from this worktree.

1. Desktop entry (gtk-launch)
   v4/command/AppModel.qml:212-217
       // argv-only gtk-launch, same contract as Navigator.execArgv
       Quickshell.execDetached(["gtk-launch", String(id)]);
   Same mechanism elsewhere:
     v4/AppGrid.qml:493-501   execArgv(["gtk-launch", row.id])
     v4/CommandHub.qml:1075   root.execArgv(["gtk-launch", String(r.launch)])
   gtk-launch takes the desktop-file id only (for example chromium.desktop); it
   cannot carry arguments, so an app that needs flags cannot use this path.

2. Plain command
   v4/command/ActionRail.qml:14
       Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "qa"].concat(argv));
   Same wrapper, different tag:
     v4/Navigator.qml:161     ... 'exec "$@"', "nav" ... argv
     v4/CommandHub.qml:145    ... 'exec "$@"', "hub" ... argv
     v4/DeckTokens.qml:74     ... 'exec "$@"', "tk" ... argv
   The tag becomes $0 inside the shell; argv is positional and never string
   concatenated, so quoting in the command line is handled by bash.
   Process in v4 is only used to capture output (AppModel.qml:156-158 is
   mkdir -p), never to fire and forget a launch.

3. URL
   v4/Navigator.qml:1256 and :1266
       execArgv(["uwsm-app", "--", "xdg-open", r.data.path])
   xdg-open is what hands a heroic:// URL to the registered handler. uwsm-app
   puts the child in the same session scope as the other launches. No v4 file
   launches a custom scheme directly.

4. v5 adapter: nexuslink.hud/v5/live/feeds/AppLauncher.qml
   function launch(app) reads app.launch = { mode, ... } from assets/apps.json:
     mode "desktop" + id    -> execDetached(["gtk-launch", id])
     mode "command" + argv  -> execDetached(["bash", "-lc", 'exec "$@"', "v5-launch"].concat(argv))
     mode "url"     + url   -> execDetached(["uwsm-app", "--", "xdg-open", url])
   property bool dryRun: false. When dryRun is true nothing is executed; it
   only console.log("v5 launch dry-run: " + JSON.stringify(argv)).
   The launcher component never calls this adapter itself: LauncherArc emits
   launchRequested(app) and the deck decides who handles it.

5. Not verified
   No process was started while writing this. gtk-launch ids were not probed,
   the plain commands were not run, and the Arc Raiders heroic:// URL was never
   opened. Runtime launching is NOT VERIFIED.
