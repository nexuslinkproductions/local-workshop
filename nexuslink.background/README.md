# nexuslink.background

A clone of the stock Omarchy background plugin (`omarchy.background`) that
draws no wallpaper on outputs owned by the NEXUS HUD.

## What it is and why it is a clone

The stock plugin is the thing that paints the desktop wallpaper, and it is also
the owner of the `background` IPC target and the code that applies new theme
colours (`Commons.Color.loadColors` / `loadShell`) when a wallpaper or theme
changes. Switching it off with `disabledPlugins` therefore breaks theme
switching. Cloning it keeps the IPC target, the theme application, the reveal
animation and the double-click background/theme switchers exactly as shipped,
and changes only which outputs get a wallpaper surface.

The clone is a normal user plugin in `~/.config/omarchy/plugins/`; the shell
routes it through `omarchy.clonedFrom` and, while the clone is enabled, the
built-in is listed in `disabledPlugins`.

## Ownership rule

An output is HUD owned (no wallpaper surface) when all three are true:

1. `~/.config/nexuslink/hud-v5` existed when the shell started (read once, the
   same flag HudV4 uses for the v5 deck).
2. `~/.config/omarchy/shell.json` lists `nexuslink.hud` in `plugins[]`
   (watched: disabling the HUD plugin brings the wallpaper back at once).
3. The output is not the glasses: `model` + `serialNumber`, lowercased,
   contains `xreal` or `nreal` (the rule from `v4/ScreenRoles.js`).

Without the flag, or without the HUD plugin listed, the clone behaves exactly
like the stock plugin on every output. On a HUD owned output the PanelWindow is
created with `visible: false`, so no wallpaper surface is mapped or composited
there at all.

## Install (parent, after the files are in the live tree)

```
mkdir -p ~/.config/omarchy/plugins
cp -a /path/to/nexuslink.background ~/.config/omarchy/plugins/nexuslink.background
omarchy-shell shell rescanPlugins
omarchy plugin enable nexuslink.background
omarchy restart shell
```

`omarchy plugin enable` refuses ids it has not scanned, so the rescan comes
first. Nothing is enabled by copying alone.

## shell.json afterwards

`omarchy plugin enable nexuslink.background` writes the clone into `plugins[]`,
switches the built-in off and records that the built-in should come back when
the clone goes away:

```json
{
  "version": 1,
  "plugins": [
    { "id": "nexuslink.background" }
  ],
  "disabledPlugins": [
    "omarchy.background"
  ],
  "cloneSourceRestores": [
    "nexuslink.background"
  ]
}
```

(`disabledPlugins` and `cloneSourceRestores` are written by
`PluginRegistry.setEnabled`; other keys in your shell.json are left alone.)

## Rollback

Fast rollback (keeps the plugin installed, wallpaper returns everywhere):

```
rm ~/.config/nexuslink/hud-v5
omarchy restart shell
```

Full removal (restores `omarchy.background` and removes the clone's entries):

```
omarchy plugin disable nexuslink.background
omarchy restart shell
```

## Omarchy updates

The clone is a copy: `pacman -Syu` replaces
`/usr/share/omarchy/shell/plugins/background/Background.qml` but does not touch
`~/.config/omarchy/plugins/nexuslink.background`. The clone keeps working with
its own copy of the old Background.qml; it does not pick up upstream fixes.

After every Omarchy update run:

```
~/.config/omarchy/plugins/nexuslink.background/verify-update.sh
```

It prints `clone is in sync with stock` when the only differences are the
`// NEXUS:` hunks, otherwise it prints the remaining diff and the re-sync
steps. Re-sync is manual: port the upstream changes into the clone, keep every
`// NEXUS:` edit, then `omarchy restart shell`.

## Log lines

```
journalctl --user -b | grep 'nexuslink.background'
```

```
nexuslink.background: output=DP-2 wallpaper=suppressed (HUD owns the output)
nexuslink.background: output=DP-2 wallpaper=drawn exclusion=Ignore size=2560x1440
```

One line per output at load and again when ownership changes; the drawn line is
repeated once the compositor has configured the surface, so the size is real
(1440 here proves the exclusive zone is ignored, unlike 1414 with Auto).

## Risk

If the HUD plugin fails to load while the flag file still exists, the clone
still suppresses the wallpaper and the non-glasses outputs show the HUD's own
background or black, never the wallpaper. Recovery is the fast rollback above:
`rm ~/.config/nexuslink/hud-v5 && omarchy restart shell`. If shell.json is
missing or unreadable the clone draws the wallpaper everywhere (safe default).
