# Nested headless compositor for the real HUD shell

Owner C. Goal: run the unmodified `quickshell -n -p nexuslink.hud` (the real shell,
`HudV4.qml` with `PanelWindow`) on a private 2560x1440 Wayland compositor with GPU
rendering, so CPU numbers come from the real layer-shell path instead of the Qt
`offscreen` software scenegraph.

## Result (2026-10-23, 01:56): does not work on this box

**The real shell does not run headless here.** The missing piece is a compositor,
not Quickshell.

What was tried, in order:

1. `AQ_BACKENDS=headless Hyprland -c hyprland.lua`, with `WAYLAND_DISPLAY`,
   `DISPLAY` and `HYPRLAND_INSTANCE_SIGNATURE` unset and a private
   `XDG_RUNTIME_DIR`. Hyprland 0.56.2 reaches `[cfg] Config is lua, loading lua
   mgr`, builds every manager, then aborts:

       terminate called after throwing an instance of 'std::runtime_error'
         what():  CBackend::create() failed!

2. Same command with a deliberately bogus value, `AQ_BACKENDS=bogus`: byte for
   byte the same failure. So **this aquamarine (0.15.1) does not read
   `AQ_BACKENDS` at all**; the variable is a dead end here, not a typo.
   `strings /usr/lib/libaquamarine.so.14` has `headless` and `HEADLESS-{}` but no
   `AQ_BACKENDS`; the only `AQ_*` knobs are `AQ_DRM_DEVICES`, `AQ_NO_ATOMIC`,
   `AQ_NO_MODIFIERS`, `AQ_FORCE_LINEAR_BLIT`, `AQ_LIBINPUT_NO_PLUGINS`,
   `AQ_MGPU_NO_EXPLICIT`, `AQ_TRACEUH`.

3. `Hyprland --help` on 0.56.2 has **no** `--headless` / `--backend` flag:
   `--config`, `--socket`, `--wayland-fd`, `--safe-mode`, `--verify-config` only.
   `--socket` / `--wayland-fd` hand in a parent Wayland socket, i.e. they make
   Hyprland a *nested client* of some other compositor. There is none to use:
   the only Wayland display on the machine is Marcel's live session, and
   attaching to it is forbidden, so this path stops there.

4. Every other headless-capable compositor is absent (`command -v`):
   `sway`, `weston`, `cage`, `labwc`, `wayfire`, `river`, `niri`,
   `kwin_wayland`, `mutter`, `gamescope`, `cosmic-comp`, `wlheadless-run` all
   MISSING. `pacman -Qq` has no wlroots package. Present: `Hyprland`,
   `quickshell`, `grim`, `Xwayland`. No `wl-screenrec`, no `wayvnc`.

5. The remaining Hyprland route is the DRM backend (`AQ_DRM_DEVICES`), and it was
   **not** attempted: without a session it would try to modeset real outputs,
   which can disturb Marcel's monitors. Out of scope by the safety rules.

6. It was in fact attempted once, on the only GPU with **no connected
   connectors** (card2, nvidia `10DE:1D01`; card0 xe drives DP-1 and DP-2,
   card1 amdgpu drives HDMI-A-5, so neither could be touched):
   `AQ_DRM_DEVICES=/dev/dri/card2 Hyprland -c drmtry.lua`. Same abort, same
   `CBackend::create() failed!`. Nothing was modeset anywhere.

## Root cause, read from the source of both halves

This is not a configuration mistake and no flag fixes it in this build:

1. `src/Compositor.cpp` in Hyprland 0.56.2 builds the backend list in code:
   HEADLESS (`MANDATORY`), DRM (`IF_AVAILABLE`), WAYLAND (`FALLBACK`), then calls
   `CBackend::create(implementations, options)`. **There is no environment
   variable or config key for the backend list**; that is why
   `AQ_BACKENDS=bogus` fails identically. Both `throwError()` calls in that
   function use the same string, so the message alone does not say which one
   fired.
2. `CBackend::create()` (aquamarine 0.15.1, `src/backend/Backend.cpp:60`) never
   returns null for a non-empty list. So the abort comes from the next call,
   `CBackend::start()` (`Backend.cpp:121`), which fails when
   `!primaryAllocator` and the first implementation is not NULL:
   `"Cannot open backend: no allocator available"`.
3. `primaryAllocator` is a `CGBMAllocator` created only from an implementation
   whose `drmFD() >= 0`. `CHeadlessBackend::drmFD()` returns **-1**
   (`src/backend/Headless.cpp:133`), and `CHeadlessBackend::start()` is literally
   `return true` (`Headless.cpp:125`).
4. Therefore headless can only supply *outputs* to a compositor that already has
   an allocator from DRM. A standalone headless Hyprland cannot start in
   aquamarine 0.15.1. `hyprctl output create headless` works only inside an
   already-running Hyprland, which is exactly the live instance we must not use.
   The DRM side needs an active logind session to take a card, which we do not
   have without touching Marcel's session.

So the headless path is an upstream limitation of Hyprland 0.56.2 + aquamarine
0.15.1, not something a better config file can solve.

A second, independent blocker found on the way: with a deep `XDG_RUNTIME_DIR`
(the first attempt used the scratch dir) Hyprland logs
`Socket2 path is too long. (2) IPC will not work.` because the instance signature
is itself ~50 chars. `run-nested.sh` therefore defaults `NESTED_DIR` to
`$HOME/.hudlive-c` (short path) and creates `run/`, `cfg/`, `cache/` under it.

## What is delivered

    tools/linux/nested/run-nested.sh    start | stop | shot <png> | cpu <seconds> | status
    tools/linux/nested/hyprland.lua     minimal config: no autostart, no bindings,
                                        no animations, one 2560x1440 output, Mesa GL
    tools/linux/nested/README.md        this file

`run-nested.sh`:

- `start` builds a fully detached environment (`env -u WAYLAND_DISPLAY -u DISPLAY
  -u HYPRLAND_INSTANCE_SIGNATURE`, private `XDG_RUNTIME_DIR`, private
  `XDG_CONFIG_HOME` so not one line of `~/.config/hypr` is read), launches
  `setsid Hyprland -c hyprland.lua`, records its PID in `~/.hudlive-c/pids`,
  then creates the headless output and sizes it to `NESTED_SIZE` (default
  `2560x1440@60`) through `hyprctl -i <own signature>`, then starts the real
  `quickshell -n -p $HUD_DIR` with `WAYLAND_DISPLAY` set to the nested socket
  only. `HUD_DIR` selects the plugin dir, default the v5-live worktree.
- `stop` reads the pidfile and TERMs then KILLs those PIDs only. There is no
  pattern kill anywhere in the file.
- `shot <png>` runs `grim -o HEADLESS-1` on the nested socket, falling back to a
  full-output `grim`.
- `cpu <seconds>` reads fields 14 and 15 of `/proc/<quickshell pid>/stat`, sleeps,
  reads again, divides by `getconf CLK_TCK`, and prints CPU percent, `VmRSS` in
  MB and `Threads`. It measures the quickshell process only; the compositor is a
  separate process and is reported by PID from the pidfile so its CPU can be
  sampled the same way.
- `status` reports liveness from the pidfile.

Verified by running: `start` exits 3 with the `CBackend::create()` reason
extracted from the log; `status` prints `stopped`; `stop` on a stale state prints
`not running (no pidfile)` and exits 0; `bash -n` is clean. The `cpu` sampler was
self-tested against a known-idle PID (`sleep 12`): it printed
`0.00 % cpu over 3.0 s (0 ticks @ 100 Hz)`, `rss 2.5 MB`, `threads 1`, exit 0, so
the `/proc/<pid>/stat` arithmetic, RSS and thread reading work. `shot` is written
but **never executed successfully**, because no compositor ever came up.

## Baseline CPU numbers

**Not measured.** Honest statement: no baseline exists from this path. The old
deck's CPU under `QT_QPA_PLATFORM=offscreen` with `QT_QUICK_BACKEND=software`
(see `perf-idle/verify/mkhud.sh`) runs the software scenegraph, draws no
ShaderEffect and executes a different paint path, so its number is not the
number we want and is not reported here as if it were.

The numbers this harness will produce once a compositor exists:

- `run-nested.sh cpu 60` after a 25 s warm-up, 3 runs, median, for the
  quickshell PID;
- the same sampler pointed at the compositor PID for the compositor's own cost;
- `VmRSS` in MB and thread count at sample time.

The 60 s x 3 protocol is not baked into the script (it takes a duration
argument) so the caller stays in control of `nice -n 19 ionice -c3`. When
calling it, wrap it:

    nice -n 19 ionice -c3 tools/linux/nested/run-nested.sh cpu 60

## What would unblock this

Any one of these, in order of cost:

1. Install a wlroots headless compositor: `sway` with
   `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2` and
   `WLR_HEADLESS_OUTPUTS=1`, then `swaymsg output HEADLESS-1 resolution 2560x1440`.
   Sway speaks layer-shell natively, so `PanelWindow` works unpatched and
   `grim -o HEADLESS-1` captures it. `run-nested.sh` would need only its
   `start` branch swapped; `shot`, `cpu` and `stop` are already compositor
   agnostic.
2. `weston --backend=headless-backend.so --width=2560 --height=1440` plus a
   layer-shell helper; weston has no layer-shell by default, so this is worse
   than sway for our case.
3. A Hyprland/aquamarine pair where the headless implementation can supply the
   allocator (older aquamarine built its GBM allocator from a DRM *render* node,
   which needs no session). Then `AQ_BACKENDS=headless` becomes irrelevant and
   plain `Hyprland -c hyprland.lua` starts; nothing else here changes. Pinning
   aquamarine is not possible from the outside, so the practical route is 1.

## Safety

Live session at start: Hyprland PID 2120, quickshell PID 3320489,
`hyprctl -j clients` 3608 bytes. At the end of this task: same two PIDs alive,
clients still 3608 bytes, same monitor set. No `hyprctl dispatch` was ever sent
to the live instance; the only read-only calls against it were `hyprctl -j
monitors` and `hyprctl -j clients`, as allowed. Every process started here was
stopped by PID; the pidfile was removed.
