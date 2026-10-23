# PORTING: HUD bleed, no-grab and the Environment slot to deck B (main-live)

Owner: H1 (work5, 13:xx). Scope: HudV4.qml bleed and no-grab made generic, the Environment host, and the three patches. The launcher section is L1's and is not here.
Status: patches checked, lint checked, nothing run live. Section 6 lists what is NOT verified.

## 1. What is where

| File | Base it applies to | Check result |
|---|---|---|
| tools/linux/porting/hudv4-bleed-deckA.patch | deck A base ff0fefe, nexuslink.hud/v4/HudV4.qml | `git apply --check` PASS against the ff0fefe copy |
| tools/linux/porting/hudv4-bleed-deckB.patch | main-live HEAD 41986e2, nexuslink.hud/v4/HudV4.qml | `git apply --check` PASS against the HEAD copy |
| tools/linux/porting/deckmain-environment-deckB.patch | main-live HEAD 41986e2, nexuslink.hud/v5/DeckMain.qml | `git apply --check` PASS against the HEAD copy |
| nexuslink.hud/v5/live/Environment.qml | (new file, E1) | not in these patches; must be copied (step 2) |

Main-live HEAD used: 41986e233031f0378ec2879ff34d233d2600c7c1 (recorded 13:15). Its working tree has uncommitted edits by another lead (DeckMain.qml among them), so the checks ran against `git show HEAD:<path>` copies in a scratch dir, not against the working tree. Re-run the check after that lead commits, from the repo: `git -C ~/hud-wt/main-live apply --check <patch>`.

## 2. Ordered steps for deck B (parent or main-deck lead)

1. Confirm main-live HEAD is still 41986e2 or re-check the patches against the new HEAD (copy the two files with `git show HEAD:<path>` into a scratch dir and `git apply --check` there). Do not apply onto a dirty tree you do not own.
2. Copy the Environment item and its shaders from deck A into main-live, new files only: `nexuslink.hud/v5/live/Environment.qml` and `nexuslink.hud/v5/live/shaders/env.*` (E1 ships them; confirm each env.frag/env.vert has its .qsb). HudV4 loads it from `../v5/live/Environment.qml`, relative to v4/.
3. Apply `hudv4-bleed-deckB.patch` and `deckmain-environment-deckB.patch` (different files, any order). Commit by the lead, never from H1.
4. Turn the switch on for deck B only with the environment variable `NEXUSLINK_HUD_V5=1` (values 1, true, on) in the session that starts the shell. No flag file for deck B.
5. Restart the shell (omarchy-restart-shell). Then run the section 4 checks.

Deck A (v5-live) for comparison: the switch is the flag file ~/.config/nexuslink/hud-v5 (hud.bleedFlag = v5Enabled). Deck A does not need the deck B patches.

## 3. Flags, rollback

- Single switch per deck: one line each. Deck A: `readonly property bool bleedFlag: v5Enabled`. Deck B: `readonly property bool bleedFlag: v5Deck`. Every other bleed test reads `bleed` (every window of the deck, full output) or `bleedOwner` (the command window's deck owns the surface).
- Flag off = the v4 path: exclusion Auto, no base, no Environment, no geometry log, the same drag, resize and IPC behaviour (deck A diff hunks reduce to the old expressions).
- Roll back deck B without code changes: unset NEXUSLINK_HUD_V5 and restart the shell.
- Roll back deck B code: reverse-apply the two patches on the committed tree (`git apply -R`) or revert the commit.
- Roll back deck A: `rm ~/.config/nexuslink/hud-v5 && omarchy restart shell` (VA finding 1 recovery).

## 4. Parent verification (live install only, never run by H1)

Run these in order, after the switch is on and the shell restarted.

1. Layers (Hyprland): `hyprctl layers -j | jq '.. | objects | select(has("namespace")) | select(.namespace=="nexuslink-hud" or .namespace=="nexuslink-hud-v5")'`. The JSON field names were NOT captured in this session (the raw output was empty here): check the first raw object before trusting the filter. Expect, on DP-2: y 0 and h equal to the DP-2 height (1440 at 2560x1440). Fail if h is 26 px short (exclusion Auto).
2. Geometry and environment log lines: `journalctl --user -b | rg 'nexuslink-hud (geometry|environment)'`. Expect one geometry line per window (exclusion=Ignore, fullBleed=true) and one environment line per bleed output. The environment line appears twice per output for now: once from Environment.qml at completion (its size can be 0x0 there) and once from HudV4 after load (size correct). Trust the HudV4 line for size; the lead may drop one of the two.
3. Edge crop (no wallpaper at the edges): `grim -o DP-2 <scratch>/dp2.png`, then check the top 40 rows and the 8 px edges are field colour #06080a (6,8,10). The VA crop check (work3/V/VA/check_bleed_VA.py) is the reference; note VA finding 3: pixel checks have detection power only on the top strip, left, right and bottom are proven by the geometry in step 1.
4. Idle CPU for the shell with the switch on: 60 s samples, three of them, against the 12 percent budget (VA finding 2).

## 5. Decisions

- Deck B command window: kept, but unmapped (`visible: !win.bleedOwner`) instead of not instantiated. Reason: HudV4 deckLoader (the Loader that picks commandScreenV5 when hud.v5Deck) is the only thing that instantiates DeckMain on the command output; removing the window removes that loader. Unmapping removes the slab frame, the exclusion, the drag pad, the grip and all pointer input. The bleedOwner guards (commitRect, dragPress, sizePress, setHidden, applyPreset, ipcMove, ipcResize, ipcShowHide, ipcLayout) refuse moves if the window is ever mapped.
- Deck B side outputs keep their HudV4 windows and get the deck A treatment: exclusion Ignore, opaque base #06080a, Environment, geometry log.
- DeckMain: the window colour becomes the opaque base (#06080a); the Environment Loader is the first child of the panel, DeckSurface follows. Minimal hunks, no other edits.
- World box: one JS binding per file (`desktopWorld`, bounding box of Quickshell.screens), no Timer, no polling.
- VA finding 7 (IPC find/toggle keyboard grab): documented exception, not changed here. find() and toggle() set keyboard focus (Exclusive) only while the Find pill is open (findKeysWanted), and it does not move, resize or hide the deck. The bleedOwner guards do not cover it by design.

## 6. NOT VERIFIED (the private harness cannot prove these)

- Quickshell PanelWindow does not load under the offscreen QPA: no runtime test of the Loader, the Bindings, the world box values, the log lines, or the DeckMain window mapping under an unmapped command window.
- Environment.qml shader output and the seam test (E1's proof) are not part of these patches.
- Compositor geometry (hyprctl layers) and the grim edge crop: parent install check only (section 4).
- qmllint: 0 new warnings in deck A (before 0, after 0); deck B HudV4 3 before and 3 after, DeckMain 1 before and 1 after (the same pre-existing warnings).
- ASCII: all added lines are ASCII. The patches and files still carry the non-ASCII characters that already exist in the ff0fefe and main-live text (context lines, 6 lines in the deck A patch).
