#!/usr/bin/python3
"""computer_act.py -- safe act layer for Chief on Hyprland 0.56 / Wayland (BRIEF-35).

  click X Y [--button left|right|middle] [--double]   absolute GLOBAL layout coords (= screen_locate output)
  type "text"            keys go to the ACTIVE window (wtype)
  key "ctrl+l"           chord to the ACTIVE window (wtype); super/logo chords refused (they hit Hyprland binds)
  scroll DX DY [--at X Y]   notches; DY>0 = down, DX>0 = right; pointer is first moved to --at if given
  focus --window REGEX | --monitor NAME

Backends (no root, nothing installed): pointer position = hyprctl `hl.dsp.cursor.move` (global coords, negative x ok);
button/wheel = a uinput relative pointer (python-evdev, /dev/uinput ACL); keys = wtype.
Safety: default is DRY-RUN (prints the plan). Executes with --yes, or y/N on a tty. --only REGEX (or env CA_ONLY)
restricts every action to windows whose class/title match; deny-list blocks password/auth prompts; click/scroll
target = window under the point, type/key target = active window. Cursor is restored after click/scroll.
Every executed action appends a line to $CA_LOG (default serve/computer_act.log). Exit 0 ok, 1 refused/failed.
"""
import argparse, json, os, re, subprocess, sys, time
from pathlib import Path

LOG = Path(os.environ.get("CA_LOG") or Path(__file__).with_suffix(".log"))
DENY_WIN = re.compile(r"keepass|bitwarden|1password|polkit|pinentry|gcr-prompter|hyprlock|password|sudo", re.I)
DENY_TYPE = re.compile(r"(curl|wget)[^|]*\|\s*(ba|z)?sh|rm\s+-\w*r\w*f|mkfs|dd\s+if=|:\(\)\s*\{", re.I)
MODS = {"ctrl": "ctrl", "control": "ctrl", "shift": "shift", "alt": "alt"}
SUPER = {"super", "logo", "win", "meta", "mod4", "cmd"}


def sh(*a, **k):
    return subprocess.run(a, capture_output=True, text=True, **k)


def hl_dispatch(lua):
    r = sh("hyprctl", "dispatch", lua)
    if r.returncode or "ok" not in r.stdout.lower():  # Lua-config hyprctl prints "ok" on success
        raise RuntimeError(f"hyprctl {lua!r}: {r.stdout.strip()} {r.stderr.strip()}")


def cursor():
    x, y = sh("hyprctl", "cursorpos").stdout.split(",")
    return int(x), int(y)


def move_cursor(x, y):
    hl_dispatch(f"hl.dsp.cursor.move({{ x = {x}, y = {y} }})")


def windows():
    cs = json.loads(sh("hyprctl", "clients", "-j").stdout)
    vis = {m["activeWorkspace"]["id"] for m in json.loads(sh("hyprctl", "monitors", "-j").stdout)}
    return [c for c in cs if c["mapped"] and not c["hidden"] and c["workspace"]["id"] in vis]


def window_at(x, y):
    hit = [c for c in windows() if c["at"][0] <= x < c["at"][0] + c["size"][0] and c["at"][1] <= y < c["at"][1] + c["size"][1]]
    hit.sort(key=lambda c: (not c["floating"], c["focusHistoryID"]))  # floating on top, then most recently focused
    return hit[0] if hit else None


def active():
    a = json.loads(sh("hyprctl", "activewindow", "-j").stdout or "{}")
    return a if a.get("address") else None


def gate(win, only):
    """Return None if allowed, else the refusal reason."""
    if win is None:
        return "no window at target"
    name = f"{win['class']} | {win['title']}"
    if DENY_WIN.search(name):
        return f"deny-list window: {name}"
    if only and not re.search(only, name, re.I):
        return f"window not in --only /{only}/: {name}"
    return None


def keys_args(combo):
    parts = [p.strip() for p in combo.split("+") if p.strip()]
    if not parts:
        raise ValueError("empty key")
    *mods, key = parts
    args = []
    for m in mods:
        if m.lower() in SUPER:
            raise ValueError("super/logo chords are refused (they trigger Hyprland binds)")
        args += ["-M", MODS[m.lower()]]
    args += ["-k", key]
    return args + [x for m in reversed(mods) for x in ("-m", MODS[m.lower()])]


class Pointer:
    """uinput relative pointer: used only for buttons and wheel; position is set by Hyprland."""

    def __enter__(self):
        from evdev import UInput, ecodes as e
        self.e = e
        cap = {e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE],
               e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL, e.REL_HWHEEL]}
        self.ui = UInput(cap, name="chief-computer-act")
        time.sleep(0.4)  # compositor must attach the new device before the first event
        return self

    def __exit__(self, *a):
        self.ui.close()

    def nudge(self):  # +1/-1px so the client gets pointer-enter/motion at the new spot (first click was lost without it)
        for d in (1, -1):
            self.ui.write(self.e.EV_REL, self.e.REL_X, d); self.ui.syn(); time.sleep(0.05)
        time.sleep(0.1)

    def click(self, button, double):
        b = {"left": self.e.BTN_LEFT, "right": self.e.BTN_RIGHT, "middle": self.e.BTN_MIDDLE}[button]
        for i in range(2 if double else 1):
            self.ui.write(self.e.EV_KEY, b, 1); self.ui.syn(); time.sleep(0.04)
            self.ui.write(self.e.EV_KEY, b, 0); self.ui.syn(); time.sleep(0.06)

    def scroll(self, dx, dy):
        for code, n in ((self.e.REL_WHEEL, -dy), (self.e.REL_HWHEEL, dx)):  # wheel +1 = up
            for _ in range(abs(n)):
                self.ui.write(self.e.EV_REL, code, 1 if n > 0 else -1); self.ui.syn(); time.sleep(0.03)


def plan(a):
    """-> (description, target window or None, runner). Raises ValueError on bad input."""
    c = a.cmd
    if c in ("click", "scroll"):
        pos = (a.x, a.y) if c == "click" else (a.at if a.at else None)
        win = window_at(*(pos or cursor()))
        if c == "click":
            desc = f"{a.button}{' double' if a.double else ''} click at ({a.x},{a.y})"
        else:
            desc = f"scroll dx={a.dx} dy={a.dy}" + (f" at {tuple(a.at)}" if a.at else " at cursor")

        def run():
            old = cursor()
            try:
                if pos:
                    move_cursor(*pos)
                    time.sleep(0.15)
                with Pointer() as p:
                    p.nudge()
                    p.click(a.button, a.double) if c == "click" else p.scroll(a.dx, a.dy)
            finally:
                move_cursor(*old)
        return desc, win, run
    if c in ("type", "key"):
        if c == "type" and DENY_TYPE.search(a.text):
            raise ValueError("text matches the dangerous-pattern deny-list")
        args = ["--", a.text] if c == "type" else keys_args(a.text)
        return f"{c} {a.text!r}", active(), lambda: sh("wtype", *args, check=True)
    if c == "focus":
        if a.monitor:
            return f"focus monitor {a.monitor}", None, lambda: hl_dispatch(f'hl.dsp.focus({{ monitor = "{a.monitor}" }})')
        m = [w for w in windows() if re.search(a.window, f"{w['class']} | {w['title']}", re.I)]
        if len(m) != 1:
            raise ValueError(f"--window /{a.window}/ matched {len(m)} windows (need exactly 1): "
                             f"{[w['class'] for w in m]}")
        w = m[0]
        return f"focus window {w['class']} | {w['title'][:50]}", w, \
            lambda: hl_dispatch(f'hl.dsp.focus({{ window = "address:{w["address"]}" }})')
    raise ValueError(c)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--yes", action="store_true", help="execute (default: dry-run, or y/N on a tty)")
    ap.add_argument("--only", default=os.environ.get("CA_ONLY"), help="regex on 'class | title' of the target window")
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("click"); s.add_argument("x", type=int); s.add_argument("y", type=int)
    s.add_argument("--button", choices=["left", "right", "middle"], default="left"); s.add_argument("--double", action="store_true")
    s = sp.add_parser("type"); s.add_argument("text")
    s = sp.add_parser("key"); s.add_argument("text", metavar="combo")
    s = sp.add_parser("scroll"); s.add_argument("dx", type=int); s.add_argument("dy", type=int)
    s.add_argument("--at", nargs=2, type=int, metavar=("X", "Y"))
    s = sp.add_parser("focus"); g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--window"); g.add_argument("--monitor")
    a = ap.parse_args(argv)
    res = {"cmd": a.cmd}
    try:
        desc, win, run = plan(a)
        res.update(plan=desc, target=win and f"{win['class']} | {win['title'][:60]}")
        why = None if (a.cmd == "focus" and a.monitor) else gate(win, a.only)
        if why:
            res.update(status="refused", reason=why)
        else:
            go = a.yes or (sys.stdin.isatty() and input(f"{desc} -> {res['target']}  [y/N] ").strip().lower() == "y")
            if go:
                run()
                res["status"] = "done"
                LOG.open("a").write(json.dumps({"t": time.strftime("%FT%T"), **res}) + "\n")
            else:
                res["status"] = "dry-run"
    except Exception as e:
        res.update(status="error", reason=str(e))
    print(json.dumps(res))
    return 0 if res["status"] in ("done", "dry-run") else 1


if __name__ == "__main__":
    sys.exit(main())
