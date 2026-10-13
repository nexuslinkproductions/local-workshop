#!/usr/bin/python3
"""act.py "<instruction>" [--monitor DP-1] [--only REGEX] [--yes]   (BRIEF-35)

Chains screen_locate (find) -> plan -> computer_act (confirm + act). Default is DRY-RUN: it prints the planned
action; --yes executes (computer_act also asks y/N on a tty). Instructions:
  [double-|right-|middle-]click <target description>   locate <target> on --monitor, then click its centre
  type <text> | key <combo> | scroll up|down|left|right [N] | focus <window regex>
"""
import argparse, json, os, re, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOCATE = os.environ.get("SCREEN_LOCATE", str(HERE / "screen_locate.py"))  # override for offline tests
ACT = str(HERE / "computer_act.py")


def parse(ins):
    """-> (verb, arg). verb in click|type|key|scroll|focus (+ button/double for click)."""
    m = re.match(r"\s*(double[- ]|right[- ]|middle[- ])?click\s+(?:on\s+)?(.+)", ins, re.I)
    if m:
        k = (m.group(1) or "").strip(" -").lower()
        return "click", {"target": m.group(2).strip(), "button": k if k in ("right", "middle") else "left",
                         "double": k == "double"}
    m = re.match(r"\s*(type|key|press|focus)\s+(.+)", ins, re.I)
    if m:
        v = m.group(1).lower()
        return {"press": "key"}.get(v, v), m.group(2).strip().strip("\"'")
    m = re.match(r"\s*scroll\s+(up|down|left|right)(?:\s+(\d+))?", ins, re.I)
    if m:
        n = int(m.group(2) or 3)
        d = m.group(1).lower()
        return "scroll", {"up": (0, -n), "down": (0, n), "left": (-n, 0), "right": (n, 0)}[d]
    raise ValueError(f"cannot parse instruction: {ins!r}")


def build(ins, monitor):
    v, a = parse(ins)
    if v == "click":
        r = subprocess.run([sys.executable, LOCATE, a["target"], "--monitor", monitor], capture_output=True, text=True)
        try:
            loc = json.loads(r.stdout.splitlines()[-1])
        except Exception:
            raise RuntimeError(f"screen_locate failed (is the vision endpoint up?): {(r.stdout + r.stderr)[-200:]}")
        if loc.get("x") is None:
            raise RuntimeError(f"target not found on {monitor}: {loc}")
        cmd = ["click", str(loc["x"]), str(loc["y"]), "--button", a["button"]] + (["--double"] if a["double"] else [])
        return cmd, loc
    if v == "scroll":
        return ["scroll", str(a[0]), str(a[1])], None
    if v == "focus":
        return ["focus", "--window", a], None
    return [v, a], None


def selftest():
    assert parse("click the Save button") == ("click", {"target": "the Save button", "button": "left", "double": False})
    assert parse("Double-click on icon")[1] == {"target": "icon", "button": "left", "double": True}
    assert parse("right click menu")[1]["button"] == "right"
    assert parse("type hello world") == ("type", "hello world") and parse("press ctrl+l") == ("key", "ctrl+l")
    assert parse("scroll down 5") == ("scroll", (0, 5)) and parse("scroll up") == ("scroll", (0, -3))
    assert build("focus firefox", "DP-1")[0] == ["focus", "--window", "firefox"]
    for bad in ("dance", "scroll sideways"):
        try:
            parse(bad); raise SystemExit("should fail: " + bad)
        except ValueError:
            pass
    print("act selftest ok")


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("instruction")
    ap.add_argument("--monitor", default="DP-1", help="monitor screen_locate searches (click targets)")
    ap.add_argument("--only"), ap.add_argument("--yes", action="store_true")
    a = ap.parse_args()
    try:
        cmd, loc = build(a.instruction, a.monitor)
    except (ValueError, RuntimeError) as e:
        print(json.dumps({"status": "error", "reason": str(e)}))
        return 1
    pre = (["--yes"] if a.yes else []) + (["--only", a.only] if a.only else [])
    if loc:
        print(json.dumps({"located": loc}))
    return subprocess.run([ACT, *pre, *cmd]).returncode


if __name__ == "__main__":
    sys.exit(main())
