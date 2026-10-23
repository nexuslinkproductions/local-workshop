-- Minimal private Hyprland config for a nested/headless HUD run.
-- No autostart, no bindings, no animations, no user config, no Omarchy defaults.
-- Loaded with: Hyprland -c hyprland.lua
-- It must never be loaded by the live session.

hl.config({
  general = {
    gaps_in = 0,
    gaps_out = 0,
    border_size = 0,
    layout = "master",
    resize_on_border = false,
    allow_tearing = false,
  },
  decoration = {
    rounding = 0,
    shadow = { enabled = false },
    blur = { enabled = false },
  },
  animations = { enabled = false },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
    vfr = false,
    mouse_move_enables_dpms = false,
    focus_on_activate = false,
    background_color = 0x000000,
  },
  cursor = {
    no_hardware_cursors = true,
    inactive_timeout = 0,
  },
  ecosystem = {
    no_update_news = true,
    no_donation_nag = true,
  },
  xwayland = { enabled = false },
  render = {
    explicit_sync = 0,
    explicit_sync_kms = 0,
  },
})

-- One 2560x1440 output, no scaling. On the headless backend this is the only output.
hl.monitor({
  output = "HEADLESS-1",
  mode = "2560x1440@60",
  position = "0x0",
  scale = 1,
})

-- Keep the render path on the Mesa (Intel) driver, as the live session does.
hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")
