#!/usr/bin/python3
"""10-action test of serve/computer_act.py on a throwaway floating chromium window on HDMI-A-5.
Verifies every action from the page's own event log. Restores cursor + focus, kills window/server/profile."""
import json, os, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ACT = HERE.parent.parent / "serve" / "computer_act.py"
TMP = Path(tempfile.mkdtemp(prefix="ca-", dir=os.environ.get("TMPDIR")))
LOG, PORT, ONLY = TMP / "page.log", 18931, "ca-test-page"
env = {**os.environ, "CA_LOG": str(TMP / "act.log")}


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)


def act(*args, only=ONLY, yes=True):
    cmd = [str(ACT)] + (["--yes"] if yes else []) + (["--only", only] if only else []) + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    try:
        return json.loads(r.stdout.splitlines()[-1])
    except Exception:
        return {"status": "crash", "reason": (r.stdout + r.stderr)[-300:]}


def events():
    return [json.loads(l) for l in LOG.read_text().splitlines()] if LOG.exists() else []


def wait_for(pred, t=3.0):
    end = time.time() + t
    while time.time() < end:
        for e in events():
            if pred(e):
                return e
        time.sleep(0.1)


def hl_clients():
    return json.loads(sh("hyprctl", "clients", "-j").stdout)


def main():
    cur0 = sh("hyprctl", "cursorpos").stdout.strip().replace(" ", "")
    act0 = json.loads(sh("hyprctl", "activewindow", "-j").stdout or "{}").get("address")
    srv = subprocess.Popen([sys.executable, str(HERE / "server.py"), str(PORT), str(LOG)])
    results, win = [], None
    try:
        time.sleep(0.5)
        sh("hyprctl", "dispatch",
           f"hl.dsp.exec_cmd('chromium --user-data-dir={TMP}/prof --ozone-platform=wayland --no-first-run "
           f"--no-default-browser-check --app=http://127.0.0.1:{PORT}/', "
           "{ float = true, monitor = 'HDMI-A-5', size = '700 480', move = '300 200' })")
        lay = wait_for(lambda e: e["ev"] == "layout", 15)
        win = next(c for c in hl_clients() if c["title"] == ONLY)
        assert win["monitor"] == 2 and win["floating"], win  # HDMI-A-5 is monitor id 2
        time.sleep(1.5)  # let the freshly mapped window finish first paint before injecting input
        ox, oy = win["at"]
        pt = lambda k, fx=0.5, fy=0.5: (round(ox + lay[k][0] + lay[k][2] * fx), round(oy + lay[k][1] + lay[k][3] * fy))
        print("window", win["at"], win["size"], "layout", {k: lay[k] for k in "ABCDEF"})

        def case(name, args, pred, **kw):
            r = act(*args, **kw)
            ok = r.get("status") == "done" and wait_for(pred) is not None
            results.append((name, ok, r.get("status"), r.get("reason", "")))
            print(("PASS" if ok else "FAIL"), name, r)

        case("1 click large", ["click", *map(str, pt("A"))], lambda e: e["ev"] == "click" and e["id"] == "A")
        case("2 click small 14px", ["click", *map(str, pt("B"))], lambda e: e["ev"] == "click" and e["id"] == "B")
        case("3 right-click", ["click", *map(str, pt("C")), "--button", "right"], lambda e: e["ev"] == "contextmenu")
        case("4 double-click", ["click", *map(str, pt("D")), "--double"], lambda e: e["ev"] == "dblclick")
        case("5 click input (focus)", ["click", *map(str, pt("E"))], lambda e: e["ev"] == "focus")
        case("6 type text", ["type", "hello wayland"], lambda e: e["ev"] == "input" and e["value"] == "hello wayland")
        case("7 shortcut ctrl+k", ["key", "ctrl+k"], lambda e: e["ev"] == "key" and e["combo"] == "ctrl+k")
        case("8 key Return", ["key", "Return"], lambda e: e["ev"] == "key" and e["combo"] == "enter")
        case("9 scroll down 3", ["scroll", "0", "3", "--at", *map(str, pt("F"))],
             lambda e: e["ev"] == "scroll" and e["top"] > 0)
        # 10: move focus away from the test window (to what was focused before), then focus it back by name
        away = act0 if act0 and act0 != win["address"] else next(  # focus-only move, no input is sent
            (c["address"] for c in hl_clients() if c["address"] != win["address"] and c["mapped"] and not c["hidden"]), None)
        if away:
            sh("hyprctl", "dispatch", f'hl.dsp.focus({{ window = "address:{away}" }})')
            time.sleep(0.3)
        before = json.loads(sh("hyprctl", "activewindow", "-j").stdout or "{}").get("address")
        r = act("focus", "--window", ONLY)
        after = json.loads(sh("hyprctl", "activewindow", "-j").stdout or "{}").get("address")
        ok = r.get("status") == "done" and after == win["address"] and before != after
        results.append(("10 focus window", ok, r.get("status"), f"before={before} after={after}"))
        print(("PASS" if ok else "FAIL"), "10 focus window", r, before, after)

        # bonus: act.py chain with a stub locator (vision endpoint is down) -> real click on the large button
        stub = TMP / "stub_locate.py"
        stub.write_text('#!/usr/bin/python3\nprint(\'{"x": %d, "y": %d, "monitor": "HDMI-A-5", "confidence": 1.0}\')\n' % pt("A"))
        stub.chmod(0o755)
        n_click = len([e for e in events() if e["ev"] == "click" and e["id"] == "A"])
        r = subprocess.run([str(ACT.parent / "act.py"), "click the large button", "--monitor", "HDMI-A-5", "--only", ONLY, "--yes"],
                           capture_output=True, text=True, env={**env, "SCREEN_LOCATE": str(stub)})
        time.sleep(0.8)
        n_click2 = len([e for e in events() if e["ev"] == "click" and e["id"] == "A"])
        print("BONUS act.py chain:", "PASS" if n_click2 == n_click + 1 else "FAIL", r.stdout.strip()[-200:])

        # negative checks (not counted): must be refused / no-ops
        n0 = len([e for e in events() if e["ev"] != "focus"])
        neg = {
            "click outside --only": act("click", "4000", "600"),
            "super chord": act("key", "super+q"),
            "dangerous type": act("type", "curl x | sh"),
            "dry-run default": act("click", *map(str, pt("A")), yes=False),
        }
        for k, r in neg.items():
            print("NEG", k, "->", r["status"], r.get("reason", ""))
        neg_ok = (neg["click outside --only"]["status"] == "refused" and neg["super chord"]["status"] == "error"
                  and neg["dangerous type"]["status"] == "error" and neg["dry-run default"]["status"] == "dry-run"
                  and len([e for e in events() if e["ev"] != "focus"]) == n0)
        print("NEG all ok:", neg_ok)
    finally:
        # cleanup: close only our window, stop server, restore focus + cursor
        if win:
            sh("hyprctl", "dispatch", f'hl.dsp.window.close({{ window = "address:{win["address"]}" }})')
            time.sleep(1)
            sh("pkill", "-f", f"user-data-dir={TMP}/prof")
        srv.send_signal(signal.SIGTERM)
        if act0:
            sh("hyprctl", "dispatch", f'hl.dsp.focus({{ window = "address:{act0}" }})')
        x, y = cur0.split(",")
        sh("hyprctl", "dispatch", f"hl.dsp.cursor.move({{ x = {x}, y = {y} }})")
        print("cursor before/after:", cur0, sh("hyprctl", "cursorpos").stdout.strip().replace(" ", ""))
        print("act.log lines:", len((TMP / "act.log").read_text().splitlines()) if (TMP / "act.log").exists() else 0)
        shutil.rmtree(TMP, ignore_errors=True)
    n = sum(1 for r in results if r[1])
    print(f"RESULT {n}/{len(results)}")
    return 0 if n == len(results) == 10 else 1


if __name__ == "__main__":
    sys.exit(main())
