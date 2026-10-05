#!/usr/bin/env python3
"""Verification harness for nexuslink.hud. Decides the P1..P9 done predicate from R/PLAN-V4.md against the live shell and writes raw evidence per run."""

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time

VERIFY_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(VERIFY_DIR)
OUT_DIR = os.path.join(VERIFY_DIR, "out")
DEVICES_JSON = os.path.join(ROOT, "recon", "devices-bus.json")
HUD_STATE = os.path.expanduser("~/.config/omarchy/nexuslink/hud-state.json")

VERIFIED = "VERIFIED"
NOT_VERIFIED = "NOT VERIFIED"
INCONCLUSIVE = "INCONCLUSIVE"

CHECK_ORDER = ["P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8", "P9"]
CHECK_NAMES = {
    "P1": "TOP PROCS",
    "P2": "CENTERS",
    "P3": "IN-SCREEN",
    "P4": "MOVE",
    "P5": "KNOT",
    "P6": "TOPOLOGY",
    "P7": "INTEGRATIONS",
    "P8": "CPU",
    "P9": "JOURNAL",
}
# P4 mutates layout and can restart the shell. P8 samples an idle shell, so it
# runs after P4 settles. P9 reads the journal of the PID P8 sampled.
EXEC_ORDER = ["P1", "P2", "P3", "P6", "P7", "P5", "P4", "P8", "P9"]

MOUSE_WARN = 'Parameter "mouse" is not declared'


def run_cmd(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError as e:
        return 127, "", "command not found: %s" % e
    except subprocess.TimeoutExpired as e:
        out = e.output if isinstance(e.output, str) else ""
        return 124, out or "", "timeout after %ss: %s" % (timeout, " ".join(cmd))
    except OSError as e:
        return 126, "", str(e)


def shell_ipc(method, args=(), timeout=15):
    cmd = ["omarchy-shell", "nexuslink.hud", method] + [str(a) for a in args]
    rc, out, err = run_cmd(cmd, timeout)
    if rc != 0:
        return False, (err.strip() or out.strip() or "omarchy-shell exit %d" % rc)
    return True, out.strip()


def fetch_selftest():
    ok, text = shell_ipc("selftest")
    if not ok:
        return {"ok": False, "error": text}
    try:
        data = json.loads(text)
    except ValueError as e:
        return {"ok": False, "error": "invalid JSON from selftest: %s" % e}
    if not isinstance(data, dict) or not isinstance(data.get("screens"), list):
        return {"ok": False, "error": "selftest JSON lacks a screens list"}
    return {"ok": True, "data": data, "error": None}


def fetch_panels():
    ok, text = shell_ipc("panels")
    if not ok:
        return {"ok": False, "error": text}
    try:
        data = json.loads(text)
    except ValueError as e:
        return {"ok": False, "error": "invalid JSON from panels: %s" % e}
    if not isinstance(data, dict) or not isinstance(data.get("screens"), list):
        return {"ok": False, "error": "panels JSON lacks a screens list"}
    return {"ok": True, "data": data, "error": None}


def fetch_monitors():
    rc, out, err = run_cmd(["hyprctl", "monitors", "-j"], 15)
    if rc != 0:
        return {"ok": False, "error": (err or "").strip() or "hyprctl exit %d" % rc,
                "by_name": {}, "list": []}
    try:
        mons = json.loads(out)
    except ValueError as e:
        return {"ok": False, "error": "invalid JSON from hyprctl monitors: %s" % e,
                "by_name": {}, "list": []}
    slim, by = [], {}
    for m in mons if isinstance(mons, list) else []:
        e = {"name": m.get("name"), "w": m.get("width"), "h": m.get("height"),
             "x": m.get("x"), "y": m.get("y"), "focused": m.get("focused"),
             "workspace": (m.get("activeWorkspace") or {}).get("id")}
        slim.append(e)
        if e["name"]:
            by[e["name"]] = e
    return {"ok": True, "error": None, "by_name": by, "list": slim}


def screen_by_name(screens, name):
    for s in screens:
        if isinstance(s, dict) and s.get("screen") == name:
            return s
    return None


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def proc_stat(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            raw = f.read()
    except OSError:
        return None
    try:
        # comm can contain spaces and parens, so fields start after the last ")"
        rest = raw[raw.rindex(")") + 2:].split()
        return {"utime": int(rest[11]), "stime": int(rest[12]), "starttime": int(rest[19])}
    except (ValueError, IndexError):
        return None


def quickshell_procs():
    procs = []
    try:
        names = os.listdir("/proc")
    except OSError:
        return procs
    for name in names:
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            with open("/proc/%d/comm" % pid) as f:
                comm = f.read().strip()
        except OSError:
            continue
        if comm != "quickshell":
            continue
        try:
            with open("/proc/%d/cmdline" % pid) as f:
                cmdline = f.read().replace("\0", " ").strip()
        except OSError:
            cmdline = ""
        st = proc_stat(pid) or {}
        procs.append({"pid": pid, "cmdline": cmdline, "starttime": st.get("starttime")})
    procs.sort(key=lambda p: p["pid"])
    return procs


def pick_shell(procs):
    for p in procs:
        if "omarchy/shell" in p["cmdline"]:
            return p
    return procs[0] if procs else None


def check_p1(st):
    res = {"screens": {}}
    if not st["ok"]:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "selftest unavailable: %s" % st["error"]
        return res
    ok = True
    for name in ("DP-1", "HDMI-A-3"):
        scr = screen_by_name(st["data"]["screens"], name)
        if scr is None:
            res["screens"][name] = {"procRows": None, "error": "screen absent from selftest"}
            ok = False
            continue
        rows = scr.get("procRows")
        res["screens"][name] = {"procRows": rows}
        if not isinstance(rows, int) or isinstance(rows, bool) or rows < 3:
            ok = False
    res["verdict"] = VERIFIED if ok else NOT_VERIFIED
    return res


def check_p2(st):
    res = {}
    if not st["ok"]:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "selftest unavailable: %s" % st["error"]
        return res
    scr = screen_by_name(st["data"]["screens"], "DP-1")
    if scr is None:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "DP-1 absent from selftest"
        return res
    w, h = scr.get("w"), scr.get("h")
    if not is_num(w) or not is_num(h):
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "DP-1 size missing from selftest"
        return res
    res["screen"] = [w, h]
    res["screen_center"] = [w / 2.0, h / 2.0]
    ok = True
    for key in ("reactorCenter", "knotCenter"):
        c = scr.get(key)
        entry = {"value": c}
        if not (isinstance(c, (list, tuple)) and len(c) == 2 and all(is_num(v) for v in c)):
            entry["error"] = "null, missing or malformed"
            ok = False
        else:
            dx, dy = c[0] - w / 2.0, c[1] - h / 2.0
            entry["dx"] = dx
            entry["dy"] = dy
            entry["distance"] = math.hypot(dx, dy)
            if entry["distance"] > 8.0:
                ok = False
        res[key] = entry
    res["limit_px"] = 8.0
    res["verdict"] = VERIFIED if ok else NOT_VERIFIED
    return res


def check_p3(st, pn):
    res = {}
    if st["ok"]:
        violations = []
        for scr in st["data"]["screens"]:
            W, H = scr.get("w"), scr.get("h")
            for p in scr.get("panels") or []:
                x, y, w, h = p.get("x"), p.get("y"), p.get("w"), p.get("h")
                bad = not (is_num(x) and is_num(y) and is_num(w) and is_num(h)
                           and is_num(W) and is_num(H))
                if not bad and (x < -1.0 or y < -1.0 or x + w > W + 1.0 or y + h > H + 1.0):
                    bad = True
                if bad:
                    violations.append({"screen": scr.get("screen"), "id": p.get("id"),
                                       "x": x, "y": y, "w": w, "h": h, "W": W, "H": H})
        res["source"] = "selftest"
        res["violations"] = violations
        res["verdict"] = VERIFIED if not violations else NOT_VERIFIED
    elif pn["ok"]:
        violations = []
        eps = 1e-6
        for scr in pn["data"]["screens"]:
            for p in scr.get("panels") or []:
                fx, fy, fw, fh = p.get("fx"), p.get("fy"), p.get("fw"), p.get("fh")
                bad = not (is_num(fx) and is_num(fy) and is_num(fw) and is_num(fh))
                if not bad and (fx < -eps or fy < -eps or fx + fw > 1 + eps or fy + fh > 1 + eps):
                    bad = True
                if bad:
                    violations.append({"screen": scr.get("screen"), "id": p.get("id"),
                                       "fx": fx, "fy": fy, "fw": fw, "fh": fh})
        res["source"] = "panels-fallback"
        res["violations"] = violations
        res["verdict"] = VERIFIED if not violations else NOT_VERIFIED
    else:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "selftest unavailable (%s); panels unavailable (%s)" % (st["error"], pn["error"])
    return res


def dp1_source(st, pn, mons):
    """Normalized DP-1 view: screen pixel size plus panel rects in px with move fractions."""
    if st["ok"]:
        scr = screen_by_name(st["data"]["screens"], "DP-1")
        if scr is None:
            return None, "DP-1 absent from selftest"
        W, H = scr.get("w"), scr.get("h")
        if not is_num(W) or not is_num(H):
            return None, "DP-1 size missing from selftest"
        panels = []
        for p in scr.get("panels") or []:
            x, y, w, h = p.get("x"), p.get("y"), p.get("w"), p.get("h")
            if not (is_num(x) and is_num(y) and is_num(w) and is_num(h)):
                continue
            panels.append({"id": p.get("id"), "movable": p.get("movable") is True,
                           "hidden": False,
                           "rect": [float(x), float(y), float(w), float(h)],
                           "fx": float(x) / float(W), "fy": float(y) / float(H)})
        return {"W": float(W), "H": float(H), "panels": panels, "source": "selftest"}, None
    if pn["ok"]:
        scr = screen_by_name(pn["data"]["screens"], "DP-1")
        if scr is None:
            return None, "DP-1 absent from panels IPC"
        mon = mons.get("by_name", {}).get("DP-1") if mons.get("ok") else None
        if mon is None:
            return None, "hyprctl monitors unavailable for DP-1"
        W, H = float(mon["w"]), float(mon["h"])
        panels = []
        for p in scr.get("panels") or []:
            fx, fy, fw, fh = p.get("fx"), p.get("fy"), p.get("fw"), p.get("fh")
            if not (is_num(fx) and is_num(fy) and is_num(fw) and is_num(fh)):
                continue
            # fh 0 means the panel hugs its natural height, unknown over IPC
            eh = float(fh) if fh > 0 else 0.12
            panels.append({"id": p.get("id"),
                           "movable": p.get("hidden") is not True and p.get("visible") is True,
                           "hidden": p.get("hidden") is True,
                           "rect": [float(fx) * W, float(fy) * H, float(fw) * W, eh * H],
                           "fx": float(fx), "fy": float(fy)})
        return {"W": W, "H": H, "panels": panels, "source": "panels-fallback"}, None
    return None, "selftest unavailable (%s); panels unavailable (%s)" % (st["error"], pn["error"])


def fresh_dp1_view():
    return dp1_source(fetch_selftest(), fetch_panels(), fetch_monitors())


def choose_target(W, H, rect, others):
    """Free spot search in px: 48 px grid, 24 px screen margin, 96 px minimum move."""
    x, y, w, h = rect
    ox, oy = x + w / 2.0, y + h / 2.0
    step, margin = 48.0, 24.0

    def axis(size, limit):
        last = limit - size - margin
        if last < margin:
            return [max(0.0, limit - size)]
        vals, v = [], margin
        while v <= last:
            vals.append(v)
            v += step
        return vals or [max(0.0, limit - size)]

    cands = []
    for tx in axis(w, W):
        for ty in axis(h, H):
            cx, cy = tx + w / 2.0, ty + h / 2.0
            d = math.hypot(cx - ox, cy - oy)
            if d < 96.0:
                continue
            ov = 0.0
            for ox0, oy0, ow, oh in others:
                ix = max(0.0, min(tx + w, ox0 + ow) - max(tx, ox0))
                iy = max(0.0, min(ty + h, oy0 + oh) - max(ty, oy0))
                ov += ix * iy
            cands.append({"x": tx, "y": ty, "dist": d, "overlap": ov})
    free = [c for c in cands if c["overlap"] == 0.0]
    if free:
        best = min(free, key=lambda c: c["dist"])
    elif cands:
        best = min(cands, key=lambda c: (c["overlap"], c["dist"]))
    else:
        best = {"x": max(0.0, W - w - 2.0), "y": max(0.0, H - h - 2.0), "dist": 0.0, "overlap": -1.0}
    best["free"] = best["overlap"] == 0.0
    return best


def ipc_move(panel_id, fx, fy):
    last = "not attempted"
    for _ in range(2):
        ok, text = shell_ipc("move", [panel_id, "%.6f" % fx, "%.6f" % fy])
        last = text
        if ok and text == "ok":
            return True, "ok"
        time.sleep(1.0)
    return False, last


def restart_shell(old_pid):
    t0 = time.monotonic()
    rc, out, err = run_cmd(["omarchy-restart-shell"], 30)
    rec = {"rc": rc, "stdout": out.strip()[:200], "stderr": err.strip()[:200]}
    deadline = time.monotonic() + 45.0
    while time.monotonic() < deadline:
        sh = pick_shell(quickshell_procs())
        if sh is not None and sh["pid"] != old_pid:
            ok, text = shell_ipc("panels", timeout=5)
            if ok:
                try:
                    json.loads(text)
                    rec.update({"ok": True, "new_pid": sh["pid"],
                                "seconds": round(time.monotonic() - t0, 1)})
                    return rec
                except ValueError:
                    pass
        time.sleep(0.5)
    rec["ok"] = False
    rec["reason"] = "shell did not come back within 45 s"
    return rec


def check_p4(cfg, ts):
    view, err = dp1_source(fetch_selftest(), fetch_panels(), fetch_monitors())
    res = {"restart_check": bool(cfg.restart_check)}
    if err is not None:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = err
        return res
    res["source"] = view["source"]
    res["screen_px"] = [view["W"], view["H"]]
    snapshot = [dict(p) for p in view["panels"]]
    res["snapshot"] = snapshot
    movable = [p for p in view["panels"] if p["movable"]]
    res["movable_ids"] = [p["id"] for p in movable]
    if not movable:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "no movable panels on DP-1"
        return res
    if os.path.isfile(HUD_STATE):
        dst = os.path.join(OUT_DIR, ts + "-hud-state-preP4.json")
        try:
            shutil.copy2(HUD_STATE, dst)
            res["state_backup"] = dst
        except OSError as e:
            res["state_backup_error"] = str(e)

    def panel_by_id(v, pid):
        return next((q for q in v["panels"] if q["id"] == pid), None)

    panel_results = []
    all_moved = True
    for p in movable:
        r = {"id": p["id"]}
        view2, err2 = fresh_dp1_view()
        if err2 is not None:
            r["error"] = "re-read failed: %s" % err2
            all_moved = False
            panel_results.append(r)
            continue
        cur = panel_by_id(view2, p["id"])
        if cur is None:
            r["error"] = "panel vanished from DP-1"
            all_moved = False
            panel_results.append(r)
            continue
        r["before"] = cur["rect"]
        others = [q["rect"] for q in view2["panels"] if q["id"] != p["id"] and not q["hidden"]]
        tgt = choose_target(view2["W"], view2["H"], cur["rect"], others)
        fx, fy = tgt["x"] / view2["W"], tgt["y"] / view2["H"]
        r["target_px"] = [tgt["x"], tgt["y"]]
        r["target_fx_fy"] = [fx, fy]
        r["free_spot"] = tgt["free"]
        okm, text = ipc_move(p["id"], fx, fy)
        r["move_rc"] = text
        if not okm:
            all_moved = False
            panel_results.append(r)
            continue
        if cfg.restart_check:
            sh = pick_shell(quickshell_procs())
            rec = restart_shell(sh["pid"] if sh else 0)
            r["restart"] = rec
            if not rec.get("ok"):
                all_moved = False
                panel_results.append(r)
                continue
        view3, err3 = fresh_dp1_view()
        after = panel_by_id(view3, p["id"]) if err3 is None else None
        if after is None:
            r["error"] = "re-read after move failed: %s" % (err3 or "panel gone")
            all_moved = False
            panel_results.append(r)
            continue
        r["after"] = after["rect"]
        b, a = r["before"], r["after"]
        d = math.hypot((a[0] + a[2] / 2.0) - (b[0] + b[2] / 2.0),
                       (a[1] + a[3] / 2.0) - (b[1] + b[3] / 2.0))
        r["moved_px"] = round(d, 1)
        r["moved"] = d >= 24.0
        if not r["moved"]:
            all_moved = False
        okb, textb = ipc_move(p["id"], cur["fx"], cur["fy"])
        r["move_back_rc"] = textb
        if not okb:
            all_moved = False
        view4, err4 = fresh_dp1_view()
        if err4 is None:
            back = panel_by_id(view4, p["id"])
            if back is not None:
                r["after_move_back"] = back["rect"]
        panel_results.append(r)

    # resolveLayout can shove neighbours on every drop, so drift is measured
    # against the snapshot and repaired for up to three passes.
    restore_moves = []
    for _ in range(3):
        view5, err5 = fresh_dp1_view()
        if err5 is not None:
            break
        drift = []
        for sp in snapshot:
            q = panel_by_id(view5, sp["id"])
            if q is None:
                continue
            if math.hypot(q["rect"][0] - sp["rect"][0], q["rect"][1] - sp["rect"][1]) > 12.0:
                drift.append(sp)
        if not drift:
            break
        for sp in drift:
            ipc_move(sp["id"], sp["fx"], sp["fy"])
            restore_moves.append({"id": sp["id"], "fx": sp["fx"], "fy": sp["fy"]})

    view6, err6 = fresh_dp1_view()
    residual = []
    if err6 is not None:
        residual = [{"error": "final re-read failed: %s" % err6}]
    else:
        for sp in snapshot:
            q = panel_by_id(view6, sp["id"])
            if q is None:
                continue
            if math.hypot(q["rect"][0] - sp["rect"][0], q["rect"][1] - sp["rect"][1]) > 12.0:
                residual.append({"id": sp["id"], "rect": q["rect"], "snapshot_rect": sp["rect"]})
    res["restore"] = {"moves": restore_moves, "clean": not residual, "residual": residual}
    res["panels"] = panel_results
    res["verdict"] = VERIFIED if all_moved else NOT_VERIFIED
    return res


def check_p5(cfg):
    res = {"seconds": cfg.knot_seconds, "samples": []}
    if cfg.knot_seconds <= 0:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "knot-seconds must be positive"
        return res
    t0 = time.monotonic()
    i = 0
    err = None
    while True:
        st = fetch_selftest()
        if not st["ok"]:
            err = "selftest unavailable: %s" % st["error"]
            break
        scr = screen_by_name(st["data"]["screens"], "DP-1")
        kl = scr.get("knotLit") if isinstance(scr, dict) else None
        if not isinstance(kl, dict):
            err = "knotLit missing on DP-1"
            break
        res["samples"].append({"t": round(time.monotonic() - t0, 1),
                               "min": kl.get("min"), "cur": kl.get("cur"),
                               "cycles": kl.get("cycles")})
        if time.monotonic() - t0 >= cfg.knot_seconds:
            break
        i += 1
        d = t0 + i * 2.0 - time.monotonic()
        if d > 0:
            time.sleep(d)
    if err is not None:
        res["reason"] = err
        res["verdict"] = NOT_VERIFIED
        return res
    mins = [s["min"] for s in res["samples"]]
    if not all(is_num(v) for v in mins):
        res["reason"] = "knotLit.min missing or non-numeric in samples"
        res["verdict"] = NOT_VERIFIED
        return res
    res["min_of_min"] = min(mins)
    c0 = res["samples"][0].get("cycles")
    c1 = res["samples"][-1].get("cycles")
    res["cycles_first"] = c0
    res["cycles_last"] = c1
    ok = res["min_of_min"] >= 0.45 and isinstance(c0, int) and isinstance(c1, int) and c1 > c0
    res["verdict"] = VERIFIED if ok else NOT_VERIFIED
    return res


def check_p6(st):
    res = {}
    if not st["ok"]:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "selftest unavailable: %s" % st["error"]
        return res
    scr = screen_by_name(st["data"]["screens"], "DP-2")
    if scr is None:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "DP-2 absent from selftest"
        return res
    tn = scr.get("topologyNodes")
    res["topologyNodes"] = tn
    if not isinstance(tn, int) or isinstance(tn, bool):
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "topologyNodes is null or not an int"
        return res
    if not os.path.isfile(DEVICES_JSON):
        res["verdict"] = INCONCLUSIVE
        res["reason"] = "%s is missing" % os.path.relpath(DEVICES_JSON, ROOT)
        return res
    try:
        with open(DEVICES_JSON) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        res["verdict"] = INCONCLUSIVE
        res["reason"] = "unreadable recon/devices-bus.json: %s" % e
        return res
    nodes = data.get("nodes") if isinstance(data, dict) else None
    if not isinstance(nodes, list):
        res["verdict"] = INCONCLUSIVE
        res["reason"] = "devices-bus.json has no nodes list"
        return res
    res["devices_bus_nodes"] = len(nodes)
    res["verdict"] = VERIFIED if tn == len(nodes) else NOT_VERIFIED
    return res


def check_p7(st):
    res = {"per_screen": {}}
    if not st["ok"]:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "selftest unavailable: %s" % st["error"]
        return res
    ok_ids = []
    for scr in st["data"]["screens"]:
        ids = []
        for it in scr.get("integrationsLive") or []:
            if isinstance(it, dict) and it.get("ok") is True and "id" in it:
                ids.append(it["id"])
        res["per_screen"][scr.get("screen")] = ids
        ok_ids.extend(ids)
    res["ok_ids"] = sorted(set(ok_ids))
    res["ok_count"] = len(res["ok_ids"])
    res["verdict"] = VERIFIED if res["ok_count"] >= 10 else NOT_VERIFIED
    return res


def check_p8(cfg):
    res = {}
    procs = quickshell_procs()
    res["procs_at_start"] = [{"pid": p["pid"], "cmdline": p["cmdline"]} for p in procs]
    shell = pick_shell(procs)
    if shell is None:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "no quickshell process found"
        return res
    pid = shell["pid"]
    res["pid"] = pid
    s0 = proc_stat(pid)
    if s0 is None:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "cannot read /proc/%d/stat" % pid
        return res
    res["starttime"] = s0["starttime"]
    try:
        clk = os.sysconf("SC_CLK_TCK")
    except (ValueError, OSError):
        clk = 100
    if not clk or clk <= 0:
        clk = 100
    res["clk_tck"] = clk
    res["cpu_ticks_start"] = s0["utime"] + s0["stime"]
    t0 = time.monotonic()
    time.sleep(cfg.cpu_seconds)
    s1 = proc_stat(pid)
    elapsed = time.monotonic() - t0
    res["elapsed_s"] = round(elapsed, 3)
    if s1 is None:
        sh2 = pick_shell(quickshell_procs())
        res["pid_now"] = sh2["pid"] if sh2 else None
        res["verdict"] = INCONCLUSIVE
        res["reason"] = "sampled quickshell exited mid-sample"
        return res
    res["cpu_ticks_end"] = s1["utime"] + s1["stime"]
    sh2 = pick_shell(quickshell_procs())
    res["pid_now"] = sh2["pid"] if sh2 else None
    if sh2 is None or sh2["pid"] != pid or s1["starttime"] != s0["starttime"]:
        res["verdict"] = INCONCLUSIVE
        res["reason"] = "quickshell PID changed mid-sample"
        return res
    cpu_s = (res["cpu_ticks_end"] - res["cpu_ticks_start"]) / float(clk)
    res["cpu_seconds_used"] = round(cpu_s, 3)
    res["percent_of_one_core"] = round(100.0 * cpu_s / elapsed, 2)
    res["limit_percent"] = 15.0
    res["verdict"] = VERIFIED if res["percent_of_one_core"] <= 15.0 else NOT_VERIFIED
    return res


def check_p9(pid_hint):
    res = {"pid_hint": pid_hint}
    pid = pid_hint
    if pid is None or proc_stat(pid) is None:
        sh = pick_shell(quickshell_procs())
        pid = sh["pid"] if sh else None
    if pid is None:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "no quickshell process found"
        return res
    res["pid"] = pid
    rc, out, err = run_cmd(["journalctl", "--user", "_PID=%d" % pid, "--no-pager"], 60)
    if rc != 0:
        res["verdict"] = NOT_VERIFIED
        res["reason"] = "journalctl exit %d: %s" % (rc, (err or out).strip()[:200])
        return res
    lines = out.splitlines()
    hits = [l for l in lines if "nexuslink.hud" in l]
    kept = [l for l in hits if MOUSE_WARN not in l]
    res["total_lines"] = len(lines)
    res["hud_lines"] = len(hits)
    res["excluded_mouse_lines"] = len(hits) - len(kept)
    res["offending_count"] = len(kept)
    res["offending_lines"] = kept[:50]
    res["verdict"] = VERIFIED if not kept else NOT_VERIFIED
    return res


def hypr_dispatch(expr):
    # this hyprctl wraps "dispatch <expr>" in Lua: return hl.dispatch(<expr>)
    return run_cmd(["hyprctl", "dispatch", expr], 10)


def hypr_focus_workspace(name):
    rc, out, err = hypr_dispatch('hl.dsp.focus({ workspace = "%s" })' % str(name).replace('"', ""))
    return rc == 0 and out.strip() == "ok", (err or out).strip()[:200]


def take_shots(ts):
    shots = {"ok": False, "monitors": []}
    rc, out, err = run_cmd(["hyprctl", "monitors", "-j"], 15)
    if rc != 0:
        shots["error"] = "hyprctl monitors failed: %s" % (err or "").strip()[:200]
        return shots
    try:
        mons = json.loads(out)
    except ValueError as e:
        shots["error"] = "invalid JSON from hyprctl monitors: %s" % e
        return shots
    by_name = {m.get("name"): m for m in mons}
    dp1 = by_name.get("DP-1")
    if dp1 is None:
        shots["error"] = "DP-1 absent from hyprctl monitors"
        return shots
    rcc, cout, _ = run_cmd(["hyprctl", "cursorpos"], 10)
    try:
        cx, cy = (float(v) for v in cout.strip().split(","))
    except ValueError:
        cx, cy = None, None
    focused0 = next((m.get("name") for m in mons if m.get("focused")), None)
    ws0 = dp1.get("activeWorkspace") or {}
    shots["cursor_before"] = [cx, cy]
    shots["focused_before"] = focused0
    shots["workspace_before"] = ws0
    center = (dp1.get("x", 0) + dp1.get("width", 0) / 2.0,
              dp1.get("y", 0) + dp1.get("height", 0) / 2.0)
    if cx is not None:
        hypr_dispatch("hl.dsp.cursor.move({ x = %g, y = %g })" % center)
    target, how = None, None
    candidates = []
    rc, wout, _ = run_cmd(["hyprctl", "workspaces", "-j"], 15)
    if rc == 0:
        try:
            wss = json.loads(wout)
            for w in wss:
                if w.get("windows") == 0 and w.get("monitor") == "DP-1":
                    candidates.append((str(w.get("name")), "empty existing DP-1 workspace id %s" % w.get("id")))
            used = {str(w.get("name")) for w in wss}
            for n in range(1, 10):
                if str(n) not in used:
                    candidates.append((str(n), "fresh workspace %d" % n))
        except ValueError:
            pass
    if not candidates:
        candidates = [("9", "fallback workspace 9")]
    shots["workspace_candidates"] = [{"name": c, "how": h} for c, h in candidates]

    def dp1_active_full():
        rc, mout, _ = run_cmd(["hyprctl", "monitors", "-j"], 15)
        if rc != 0:
            return None, None
        try:
            cur = {m.get("name"): m for m in json.loads(mout)}
            aw = cur.get("DP-1", {}).get("activeWorkspace") or {}
            return aw.get("id"), aw.get("name")
        except ValueError:
            return None, None

    # the operator shares this desktop, so every switch is verified and
    # retried with a different candidate until DP-1 sits on the target
    attempts = []
    switched = False
    for cand, chow in candidates[:3]:
        target, how = cand, chow
        hypr_dispatch("hl.dsp.cursor.move({ x = %g, y = %g })" % center)
        okf, errf = hypr_focus_workspace(cand)
        time.sleep(0.4)
        act_id, act_name = dp1_active_full()
        attempts.append({"target": cand, "dp1_active_id": act_id, "dp1_active_name": act_name,
                         "rc": "ok" if okf else errf})
        if act_name == str(cand):
            switched = True
            break
    shots["switch_attempts"] = attempts
    shots["workspace_target"] = {"name": target, "how": how}
    shots["dp1_active_after_switch"] = dp1_active_full()
    shots["switched"] = switched
    for m in mons:
        name = m.get("name")
        path = os.path.join(OUT_DIR, "%s-%s.png" % (ts, name))
        rcg, _, errg = run_cmd(["grim", "-o", name, path], 30)
        entry = {"monitor": name, "path": path, "rc": rcg}
        if rcg == 0 and os.path.isfile(path):
            entry["bytes"] = os.path.getsize(path)
            entry["ok"] = entry["bytes"] > 0
        else:
            entry["ok"] = False
            entry["error"] = (errg or "").strip()[:200]
        shots["monitors"].append(entry)

    restore_attempts = []
    if ws0.get("name") is not None:
        for i in range(3):
            if i > 0:
                hypr_dispatch("hl.dsp.cursor.move({ x = %g, y = %g })" % center)
            okf, errf = hypr_focus_workspace(ws0.get("name"))
            time.sleep(0.3)
            act_id, act_name = dp1_active_full()
            restore_attempts.append({"dp1_active_id": act_id, "rc": "ok" if okf else errf})
            if act_id == ws0.get("id"):
                break
    shots["restore_attempts"] = restore_attempts
    rid, rname = dp1_active_full()
    shots["dp1_active_after_restore"] = {"id": rid, "name": rname}
    shots["workspace_restored"] = rid == ws0.get("id")
    rc, mout2, _ = run_cmd(["hyprctl", "monitors", "-j"], 15)
    if rc == 0:
        try:
            cur2 = {m.get("name"): m for m in json.loads(mout2)}
            focused_now = next((m.get("name") for m in cur2.values() if m.get("focused")), None)
            if focused0 and focused0 != focused_now:
                fw = (cur2.get(focused0, {}).get("activeWorkspace") or {}).get("name")
                if fw is not None:
                    hypr_focus_workspace(fw)
            rc, mout3, _ = run_cmd(["hyprctl", "monitors", "-j"], 15)
            cur3 = {m.get("name"): m for m in json.loads(mout3)}
            shots["focused_after"] = next((m.get("name") for m in cur3.values() if m.get("focused")), None)
        except ValueError:
            shots["focused_after"] = None
    if cx is not None:
        hypr_dispatch("hl.dsp.cursor.move({ x = %g, y = %g })" % (cx, cy))
    rcc2, cout2, _ = run_cmd(["hyprctl", "cursorpos"], 10)
    try:
        shots["cursor_after"] = [float(v) for v in cout2.strip().split(",")]
    except ValueError:
        shots["cursor_after"] = None
    shots["ok"] = bool(shots["monitors"]) and all(e.get("ok") for e in shots["monitors"])
    return shots


def detail(cid, r):
    try:
        if cid == "P1":
            s = r.get("screens") or {}
            return "DP-1 procRows=%s HDMI-A-3 procRows=%s" % (
                (s.get("DP-1") or {}).get("procRows"), (s.get("HDMI-A-3") or {}).get("procRows"))
        if cid == "P2":
            parts = []
            for k in ("reactorCenter", "knotCenter"):
                e = r.get(k) or {}
                parts.append("%s distance=%s px" % (k, e.get("distance")))
            return " ".join(parts) + " limit=8 px"
        if cid == "P3":
            return "source=%s violations=%d" % (r.get("source"), len(r.get("violations") or []))
        if cid == "P4":
            mv = r.get("panels") or []
            okn = sum(1 for p in mv if p.get("moved"))
            rst = r.get("restore") or {}
            return "source=%s moved=%d/%d restore_clean=%s" % (
                r.get("source"), okn, len(mv), rst.get("clean"))
        if cid == "P5":
            return "min knotLit.min=%s cycles %s->%s samples=%d" % (
                r.get("min_of_min"), r.get("cycles_first"), r.get("cycles_last"),
                len(r.get("samples") or []))
        if cid == "P6":
            return "topologyNodes=%s devices-bus nodes=%s" % (
                r.get("topologyNodes"), r.get("devices_bus_nodes"))
        if cid == "P7":
            return "integrations ok=%d limit=10 ids=%s" % (
                r.get("ok_count"), ",".join(r.get("ok_ids") or []))
        if cid == "P8":
            return "quickshell pid=%s %s%% of one core over %ss limit=15%%" % (
                r.get("pid"), r.get("percent_of_one_core"), r.get("elapsed_s"))
        if cid == "P9":
            return "pid=%s offending lines=%d" % (r.get("pid"), r.get("offending_count"))
    except Exception:
        pass
    return r.get("reason", "")


def unique_path(path):
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(path)
    i = 1
    while os.path.exists("%s-%d%s" % (stem, i, ext)):
        i += 1
    return "%s-%d%s" % (stem, i, ext)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Verify the nexuslink.hud v4 done predicate P1..P9 against the live shell.")
    ap.add_argument("--cpu-seconds", type=int, default=60,
                    help="P8 sample window in seconds (default 60)")
    ap.add_argument("--knot-seconds", type=int, default=150,
                    help="P5 sampling window in seconds (default 150)")
    ap.add_argument("--restart-check", action="store_true",
                    help="P4 also restarts the shell between move and re-read")
    ap.add_argument("--shots", action="store_true",
                    help="screenshot all monitors into verify/out")
    ap.add_argument("--only", action="append", default=[],
                    metavar="P1,P2,...", help="run a subset of checks; repeatable")
    ap.add_argument("--out", default=None, help="output JSON path (default verify/out/<ts>.json)")
    args = ap.parse_args(argv)

    selected = []
    for part in args.only:
        for tok in part.split(","):
            tok = tok.strip().upper()
            if not tok:
                continue
            if tok not in CHECK_ORDER:
                ap.error("unknown check %s (expected one of %s)" % (tok, ",".join(CHECK_ORDER)))
            if tok not in selected:
                selected.append(tok)
    if not selected:
        selected = list(CHECK_ORDER)
    ordered = [c for c in EXEC_ORDER if c in selected]

    try:
        os.makedirs(OUT_DIR, exist_ok=True)
    except OSError as e:
        print("fatal: cannot create %s: %s" % (OUT_DIR, e), file=sys.stderr)
        return 2
    ts = time.strftime("%Y%m%dT%H%M%S")
    out_path = args.out or unique_path(os.path.join(OUT_DIR, ts + ".json"))

    print("nexuslink.hud verification harness")
    print("ts=%s checks=%s" % (ts, ",".join(ordered)))
    print("cpu-seconds=%d knot-seconds=%d restart-check=%s shots=%s" % (
        args.cpu_seconds, args.knot_seconds, args.restart_check, args.shots), flush=True)

    st = fetch_selftest()
    pn = fetch_panels()
    mons = fetch_monitors()

    checks = {}

    def run_check(cid):
        t0 = time.monotonic()
        try:
            if cid == "P1":
                res = check_p1(st)
            elif cid == "P2":
                res = check_p2(st)
            elif cid == "P3":
                res = check_p3(st, pn)
            elif cid == "P4":
                res = check_p4(args, ts)
            elif cid == "P5":
                res = check_p5(args)
            elif cid == "P6":
                res = check_p6(st)
            elif cid == "P7":
                res = check_p7(st)
            elif cid == "P8":
                if "P4" in checks:
                    time.sleep(3.0)
                res = check_p8(args)
            else:
                res = check_p9(checks.get("P8", {}).get("pid"))
        except Exception as e:
            res = {"verdict": NOT_VERIFIED, "reason": "harness error: %s" % e}
        res["seconds"] = round(time.monotonic() - t0, 1)
        checks[cid] = res
        line = "%s %s: %s" % (cid, CHECK_NAMES[cid], res["verdict"])
        det = detail(cid, res)
        if det:
            line += "  " + det
        print(line, flush=True)

    for cid in ordered:
        run_check(cid)

    shots = take_shots(ts) if args.shots else []
    if args.shots:
        okm = ["%s:%s" % (e.get("monitor"), "ok" if e.get("ok") else "FAIL")
               for e in shots.get("monitors", [])]
        print("SHOTS: %s workspace_restored=%s" % (
            " ".join(okm), shots.get("workspace_restored")), flush=True)

    verdicts = {
        VERIFIED: sum(1 for r in checks.values() if r["verdict"] == VERIFIED),
        NOT_VERIFIED: sum(1 for r in checks.values() if r["verdict"] == NOT_VERIFIED),
        INCONCLUSIVE: sum(1 for r in checks.values() if r["verdict"] == INCONCLUSIVE),
    }
    exit_code = 0 if (checks and all(r["verdict"] == VERIFIED for r in checks.values())) else 1

    doc = {
        "harness": "verify/hudcheck.py",
        "started_local": time.strftime("%Y-%m-%d %H:%M:%S"),
        "ts": ts,
        "argv": sys.argv[1:],
        "config": {
            "cpu_seconds": args.cpu_seconds,
            "knot_seconds": args.knot_seconds,
            "restart_check": args.restart_check,
            "shots": args.shots,
            "only": selected,
        },
        "selftest": st,
        "panels": pn,
        "monitors": mons,
        "checks": {cid: checks[cid] for cid in CHECK_ORDER if cid in checks},
        "shots": shots,
        "summary": {
            "verdicts": verdicts,
            "all_verified": exit_code == 0,
            "exit_code": exit_code,
        },
    }
    try:
        tmp = out_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(doc, f, indent=2)
        os.replace(tmp, out_path)
    except OSError as e:
        print("fatal: cannot write %s: %s" % (out_path, e), file=sys.stderr)
        return 2

    print("RESULT: %d VERIFIED, %d NOT VERIFIED, %d INCONCLUSIVE" % (
        verdicts[VERIFIED], verdicts[NOT_VERIFIED], verdicts[INCONCLUSIVE]))
    print("output: %s" % out_path)
    print("exit: %d" % exit_code)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
