# 35a — Agent "act layer" on Linux Wayland / Hyprland 0.56 (options survey)

Scope: web-only survey of ways to give an AI agent click/type/keys/scroll/focus on Hyprland 0.56 (Lua config). No installs. Target: multi-monitor incl. a monitor at negative x (e.g. `x=-1920`).

---

## 1. Hermes `computer_use` → cua-driver (trycua/cua)

- Drives the desktop via a **router**: AT-SPI 2 over D-Bus for the element tree + **XTEST / XSendEvent** for input; agent cursor is a painted overlay, real pointer untouched. ([cua blog](https://cua.ai/blog/inside-linux-computer-use))
- **Supported backend is X11 and XWayland.** On a Wayland session it talks to XWayland and treats it as X11; native-Wayland-only apps (some Firefox/GTK4) may be invisible. ([cua blog](https://cua.ai/blog/inside-linux-computer-use))
- **Native Wayland is preview, opt-in** via `CUA_DRIVER_RS_ENABLE_WAYLAND=1`; screen capture + full AT-SPI parity "still landing". ([cua blog](https://cua.ai/blog/inside-linux-computer-use))
- Wayland input synthesis is **gated by `org.freedesktop.portal.RemoteDesktop`**; without it the tool surface degrades to passive (snapshot/screenshot) only. ([cua LINUX.md](https://github.com/trycua/cua/blob/9045b0c7/libs/cua-driver/rust/Skills/cua-driver/LINUX.md?plain=1))
- Hyprland has a **separate experimental compositor plugin**, not enabled by the installer; build needs exact Hyprland ABI + toolchain, flag `CUA_HYPRLAND_INPUT=ON`, validated in [PR #3572](https://github.com/trycua/cua/pull/3572). Docs list "Hyprland/Omarchy experimental support". ([cua Linux guide](https://cua.ai/docs/cua-driver/guide/getting-started/linux))
- Install: no sudo for the binary (sudo only for runtime libs `libXi6 at-spi2-core`); daemon runs in the graphical session. ([cua Linux guide](https://cua.ai/docs/cua-driver/guide/getting-started/linux))
- **Verdict for Hyprland-native:** usable today only via XWayland; native path is beta + needs a plugin. Good *shape* (AT-SPI + explicit refusal), weak fit for a native-Wayland-only Hyprland.

## 2. Kernel uinput / virtual-keyboard tools (ydotool, dotool, wtype, wlrctl)

- **ydotool**: uinput-based, works on X11/Wayland/TTY; `ydotoold` daemon **mandatory since v1.0.0**; `/dev/uinput` access "usually requires root". Has `mousemove --absolute` and `click`. ([ydotool README](https://github.com/ReimuNotMoe/ydotool))
- **dotool**: reads actions from stdin, uinput, **no daemon**, **supports keyboard layouts** (XKB) — better than ydotool for non-US layouts. ([dotool](https://git.sr.ht/~geb/dotool))
- **wtype**: uses the Wayland **`zwp_virtual_keyboard_v1`** protocol; **works on Hyprland/Sway/River**, **fails on KDE Plasma & GNOME**, no X11, assumes US layout. ([atx/wtype](https://github.com/atx/wtype); [voxtype docs](https://mintlify.wiki/peteonrails/voxtype/guides/output-modes))
- **wlrctl** (wlroots control): another Wayland client of the compositor, "same standing as wlrctl" per [hypruse](https://lobehub.com/ko/mcp/ilyaskhallouki-hypruse) — small surface (window/keyboard/mouse), no daemon.
- No-root setup: ydotool/dotool need a udev rule `KERNEL=="uinput", GROUP="input", MODE="0660"` + `input` group (or a pre-granted `/dev/uinput` ACL). wtype needs no root. ([blabby.ai](https://blabby.ai/blog/speech-to-text-linux), [voxtype docs](https://mintlify.wiki/peteonrails/voxtype/guides/output-modes))

## 3. Hyprland native IPC + Lua API (hyprctl / hl.dsp.*)

- Hyprland exposes a full **IPC surface**: `hyprctl dispatch`, `cursorpos` (global layout coords), window/monitor/workspace queries. ([using-hyprctl](https://wiki.hypr.land/configuring/core/advanced-configuration/using-hyprctl))
- **Lua dispatchers** (`hl.dsp.*`) incl. `hl.dsp.cursor.move({x,y})`, `hl.dsp.cursor.move_to_corner({window?,corner})`, `hl.dsp.focus({window|workspace|monitor|direction})`, `hl.dsp.send_shortcut({window?,mods,key})`, `hl.dsp.window.*`. Dispatchers only *describe* an action; must be wrapped in `hl.dispatch()`/`hl.bind()`. ([dispatchers](https://wiki.hypr.land/configuring/core/dispatchers))
- Invoke from shell: `hyprctl dispatch 'hl.dsp.cursor.move({ x = 500, y = 300 })'` or `hyprctl eval '...'`. ([using-hyprctl](https://wiki.hypr.land/configuring/core/advanced-configuration/using-hyprctl))
- **Pitfall:** on 0.56 with a Lua config, the **classic `hyprctl dispatch <name> args` syntax silently fails** (`expected a dispatcher (e.g. hl.dsp.window.close())`) — intentional; hyprlang dispatch table is being removed. Use the quoted Lua form. ([HyDE issue #2114](https://github.com/HyDE-Project/HyDE/issues/2114))
- `send_shortcut` is **focus-free / per-window**, and `cursor.move` takes **global logical coordinates** — the reliable absolute-positioning path on multi-monitor. ([dispatchers](https://wiki.hypr.land/configuring/core/dispatchers))
- **No mouse button / scroll dispatcher exists** — clicking still needs a virtual-pointer or uinput tool. ([r/hyprland](https://www.reddit.com/r/hyprland/comments/1kdq2xy/automate_cursor/))
- **Verdict:** the best *no-root, compositor-native* layer for move/focus/keys-to-window; pair it with a click/scroll backend.

## 4. `zwlr_virtual_pointer_v1` + python-evdev/uinput

- `zwlr_virtual_pointer_v1` (wlr protocol) is how Hyprland-native tools inject **clicks and scroll**; hypruse speaks it directly, and deliberately routes **positioning through `hyprctl dispatch movecursor`** to sidestep the known multi-monitor bugs of absolute virtual-pointer motion ([hyprwm/Hyprland#6749](https://github.com/hyprwm/Hyprland/issues/6749)). ([hypruse](https://lobehub.com/ko/mcp/ilyaskhallouki-hypruse))
- Direct **python-evdev / uinput**: create a virtual pointer/keyboard at kernel level; works under any compositor. `evemu-event` on an existing device is used for accurate relative motion (accel must be disabled). ([KDE discuss](https://discuss.kde.org/t/move-mouse-to-screen/28971))
- User already has ACL rw on `/dev/uinput` → no root needed for a direct uinput client (the uinput path, not the daemon).
- **Verdict:** `virtual-pointer` for clicks/scroll (no root) + `hyprctl movecursor` for positioning = the hypruse recipe; python-evdev/uinput as the low-level fallback when a protocol isn't exposed.

## 5. xdg-desktop-portal RemoteDesktop / libei

- The portal `org.freedesktop.impl.portal.RemoteDesktop` (libei/EIS) is the "official" Wayland input-injection route, but **upstream `xdg-desktop-portal-hyprland` does not implement RemoteDesktop** (its InputCapture is capture, not injection). ([hypruse](https://lobehub.com/ko/mcp/ilyaskhallouki-hypruse); [PR #402](https://github.com/hyprwm/xdg-desktop-portal-hyprland/pull/402) open)
- Third-party backends exist and translate `Notify*`/EIS into `zwlr_virtual_pointer_v1` + `zwp_virtual_keyboard_v1`: [gac3k/xdg-desktop-portal-hypr-remote](https://github.com/gac3k/xdg-desktop-portal-hypr-remote) (libei path, delivery reportedly broken), [sophronesis/xdg-desktop-portal-hyprland-input](https://github.com/sophronesis/xdg-desktop-portal-hyprland-input) (v1, no libei, verified with KDE Connect), [gfhdhytghd/hypr-kdeconnect-fix](https://github.com/gfhdhytghd/hypr-kdeconnect-fix).
- Routing via `~/.config/xdg-desktop-portal/portals.conf`. All require `xdg-desktop-portal` + compositor virtual-input protocols; no root. ([hypr-kdeconnect-fix](https://github.com/gfhdhytghd/hypr-kdeconnect-fix))
- **Verdict:** heavyweight, immature on Hyprland; only worth it if a client *requires* the portal interface. Adds a permission/session handshake and D-Bus indirection = more latency + more failure modes.

## 6. AT-SPI accessibility tree (pyatspi / dogtail)

- AT-SPI gives the semantic element tree (name/role/bounds) — the closest Linux analogue to macOS AX. Needs toolkit accessibility on: `gsettings set org.gnome.desktop.interface toolkit-accessibility true`, `QT_ACCESSIBILITY=1` for Qt, **`--force-renderer-accessibility` for Chromium/Electron**. ([dogtail README](https://github.com/vhumpa/dogtail/blob/master/README.md); [tessl at-spi-linux](https://tessl.io/registry/testland/at-spi-linux))
- **On Wayland only local window coordinates are known**; dogtail 1.0 bridges this via the **Screen Cast + Remote Desktop API** and `gnome-ponytail-daemon` (GNOME-only) to translate local→global and to inject input. ([dogtail README](https://github.com/vhumpa/dogtail/blob/master/README.md))
- AT-SPI alone cannot inject input on Wayland — it still needs a portal/uinput/virtual-pointer backend. Many GTK4/Qt6 apps populate the tree lazily → partial trees, re-snapshot needed. ([cua LINUX.md](https://github.com/trycua/cua/blob/9045b0c7/libs/cua-driver/rust/Skills/cua-driver/LINUX.md?plain=1))
- **Verdict:** excellent for *finding* exact element coordinates, but on Hyprland the input side is unsolved by AT-SPI itself and the GNOME helper doesn't apply. Best used to locate targets, then act via §3/§4.

---

## Pitfalls: absolute pointer on multi-monitor Wayland (negative x)

- **ydotool absolute `mousemove` is broken across monitors**: negative x resolves to x=0 on the current screen or lands on the wrong display; positive x clamps to the *current* monitor's width, not the layout width. ([ydotool issue #164](https://github.com/ReimuNotMoe/ydotool/issues/164))
- **Hyprland cursor bugs:** with explicit per-output `position=`, `cursorpos` can clamp to a monitor's size (`x∈[0,1279]`, [#15770](https://github.com/hyprwm/Hyprland/issues/15770)); Wayland-backend multi-output cursor x scales as `n*x` ([#14073](https://github.com/hyprwm/Hyprland/issues/14073)). Hardware-cursor desync fixed only by `no_hardware_cursors=true` ([#13449](https://github.com/hyprwm/Hyprland/discussions/13449)).
- **Mitigation:** use **`hyprctl dispatch movecursor`** (global logical coords, works with negative offsets) for positioning, and only button/scroll events on the virtual pointer — the documented hypruse workaround for #6749. ([hypruse](https://lobehub.com/ko/mcp/ilyaskhallouki-hypruse))
- **Mouse acceleration** corrupts relative-motion injection; must be disabled for accurate relative moves. ([KDE discuss](https://discuss.kde.org/t/move-mouse-to-screen/28971))
- Screenshots are **pixel space**; convert `global = origin + pixel/scale` — never use image pixels directly as screen coords. ([hyprland-mcp](https://github.com/alderban107/hyprland-mcp))

---

## Ranking — Hyprland 0.56

| Rank | Option | Reliability on Hyprland 0.56 | Latency | Safety / blast radius | No-root setup |
|---|---|---|---|---|---|
| 1 | **Hyprland native IPC + Lua** (`hyprctl`, `hl.dsp.cursor.move`, `send_shortcut`, `focus`) | High for move/focus/keys; no click/scroll | ~10–30 ms (IPC; use `--batch`) | Good — explicit targets, focus-free shortcuts; no raw pointer hijack | Yes (socket only) |
| 2 | **wlr virtual-pointer + `hyprctl movecursor`** (hypruse recipe) | High — click/scroll + exact positioning | Low (ms; screenshot ~0.5 s) | Good if approval-gated; one shared seat/cursor | Yes (no uinput) |
| 3 | **wtype** (virtual keyboard) | High on Hyprland/Sway/River | Low | Keyboard injection to focused window only | Yes |
| 4 | **dotool / ydotool** (uinput) | High, compositor-agnostic | ydotool ~ok; dotool fast | Blast radius = whole desktop (raw input device) | dotool: udev rule; ydotool: daemon + `/dev/uinput` |
| 5 | **cua-driver** (Hermes `computer_use`) | Medium — XWayland now; native = beta plugin | Medium (daemon) | Good design (AT-SPI + explicit refusal) | Binary yes; plugin needs ABI build |
| 6 | **python-evdev / uinput direct** | High (low-level, always works) | Lowest | Highest risk — full raw input device | Needs `/dev/uinput` ACL (user has it) |
| 7 | **AT-SPI** (pyatspi/dogtail) | Medium for *finding*; input unsolved on Hyprland | Medium (D-Bus tree walk) | Read-mostly, safe | Yes, but needs toolkit-a11y flags |
| 8 | **portal RemoteDesktop / libei** | Low — upstream Hyprland lacks it; 3rd-party immature | Highest (D-Bus + session handshake) | Safest by design (explicit grant) | Yes, but most moving parts |

**Recommendation:** build on §3 + §2/§4 — `hyprctl`/`hl.dsp.*` for focus/move/keys-to-window, `zwlr_virtual_pointer_v1` for click/scroll, `hyprctl dispatch movecursor` for absolute positioning (negative offsets included). Treat cua-driver and the RemoteDesktop portal as not-ready on native Hyprland 0.56.
