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

6. Round 3: symmetric launcher (geometry)
   LauncherArc.qml now lays the band out about one centre slot and DeckView
   centres it on the deck line, not on a hard coded x.
     * LauncherArc width 1380, placed at x = 1280 - width/2 = 590, y 1230.
     * pitch 116 between every neighbouring tile centre; 11 slots:
       deck centres 700, 816, 932, 1048, 1164, 1280, 1396, 1512, 1628, 1744, 1860.
     * the hero is the app with size "feature" (ARC Raiders), display index 5,
       deck x 1280, scale 1.3. Five tiles each side.
     * display order = first half of the non hero apps, hero, second half:
       hermes devin files terminal chromium | ARC RAIDERS | discord x youtube
       whatsapp obs. The source order in assets/apps.json is unchanged (the hero
       is still last there); layoutOrder() reorders for display only.
     * pure functions for tests: slotX(i), slotScale(i), heroIndexInList,
       layoutOrder(), droppedApp(), arcY(i). deckX(i) = x + slotX(i).
     * smile kept: y_i = 78 - 48 k^2, k = (deck x_i - 1280) / 560. Outer slots
       land at y 26.5 and the hero at 78, so the band is still a smile centred
       on 1280. Idle drift uses |i - centreIndex| as its phase, so mirrored
       tiles move in step (y mirror is exact, not just within tolerance).
     * hover bell unchanged in shape, now measured over the new slots, so the
       magnify is mirror symmetric. Label clamp is width relative, not 1134.
   Before (measured, deck x): nine tiles at 722 + 116 i (722..1650), hero at
   1834. The gap between the last normal tile and the hero was 184, not 116,
   and the group centroid was (722+...+1650+1834)/10 = 1250.8, i.e. 29.2 px
   left of 1280, with the hero 554 px right of it. The extreme midpoint
   (722+1834)/2 = 1278 hid that: 5 centres sat left of the line and 4 right,
   the hero stuck out on its own. That is the imbalance Marcel saw, and it is
   gone: 5 / hero / 5, every gap 116, every pair summing to 2560.

7. Round 3: tenth app (OBS Studio) and the rule that picked it
   Old launcher ranking: v4/AppGrid.qml refilter(), the MOST USED section
   (lines 404-417): count each app's gtk-launch hits from
   ~/.config/omarchy/nexuslink/appuse.json, sort by count descending, and on a
   tie by byName() = name.toLowerCase().localeCompare (lines 391-393).
   Applied to installed desktop ids in appuse.json that are not already in
   apps.json and not October (excluded by the apps.json note):
     com.obsproject.Studio.desktop  Name=OBS Studio  1 launch
     spotify.desktop                Name=Spotify     1 launch
   Count ties, so the tie break decides: "obs studio" sorts before "spotify".
   OBS Studio is the pick; Spotify stays out. Added as a normal tile, size
   tile, launch mode desktop, id com.obsproject.Studio.desktop, launches 1,
   running false. obsidian.desktop is installed but has 0 launches.
   glyph is "" on purpose: IconTile now draws a neutral 18 px ink dot at 30
   percent when the glyph is empty or its svg does not load (IconTile.qml,
   fallback Rectangle bound to !glyphImage.visible). The real icon is s5's job;
   nothing throws (the test renders all 11 tiles with no QWARN).

8. Round 3: why the deck reads about 35 px off centre
   A2/A-DESIGN numbers, restated: the v4 slab is not the window. Persisted
   DP-2 hub is fx 0.028125 fy 0.033946 fw 0.95 fh 0.94; the HUD window sits at
   y=26 because of the 26 px bar (ExclusionMode.Auto), so the slab is
   x 72, y 48, width 2432, height 0.94 * 1414 = 1329.
   DeckV5 fit = min(2432/2560, 1329/1440) = min(0.95, 0.923) = 0.923; the design
   is 2560 * 0.923 = 2363 wide; x = round((2432 - 2363)/2) = 35, leaving 35 on
   the left and 34 on the right. Design x 1280 maps to 35 + 1280 * 0.923 =
   1216.4 in a slab whose centre is 1216, so the deck's own centring is within
   0.4 px; the 35 is the letterbox, not a shift. The launcher band was the part
   that really sat off centre: 29.2 px left by centroid and 184 px pitch break
   at the hero (section 6). A2 removes the slab at v5 (deck fills the window at
   fit 1), and this band is centred in DECK coordinates, so it stays correct
   whatever the slab does.

9. Round 3: test
   nexuslink.hud/v5/verify/tst_launcher_symmetry.qml, run by
   tools/linux/measure/run-launcher-test.sh (offscreen, software, flock on
   /tmp/hudlive-render.lock, QML_XHR_ALLOW_FILE_READ=1 so the real
   assets/apps.json is read). Three cases: rest geometry, hover mirror, odd
   non hero count. Positions are read with mapToItem on the real IconTiles, not
   from slotX(). 5 passed, 0 failed. Mutation check on a scratch copy with the
   hero shifted 12 px: 3 failed (hero centre x 1292, hover mirror 2584) - the
   test does catch it.

10. Round 3: the OBS tile mark
   OBS Studio shipped with an empty glyph, so IconTile drew its neutral dot at
   the end of the row and the row read as if an icon were missing. Round 3 adds
   assets/icons/obs.svg, built by build_icons.py from the simple-icons obsstudio
   path (CC0, same builder and ink as chrome, x, discord, youtube, whatsapp) at
   scale 0.95 with stroke fattening 1.0, because the bare mark is a thin ring and
   the s3 value of 0.5 left it the lightest glyph in the band. That is a stopgap
   against the dot only; icon art for the final set is s5 work and s5 may replace
   it.

