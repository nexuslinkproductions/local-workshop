#!/usr/bin/env python3
"""Chief evaluation runner (BRIEF-37).

Grades the 42-item suite in suite.yaml against answers from the local Chief profile.
No framework, no network beyond the local model endpoint.

  python3 evals/chief/run_suite.py --dry-run
  python3 evals/chief/run_suite.py --model gemma4-12b --out results/gemma4-12b.json
  python3 evals/chief/run_suite.py --model gemma4-12b-think --only navigation
  python3 evals/chief/run_suite.py --compare results/base.json results/v2.json

Dry-run never calls the model: it checks the YAML, grades each item's pass_sample as
PASS, and grades one deliberately wrong answer per category as FAIL.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install --user pyyaml")

HERE = Path(__file__).resolve().parent
SUITE = HERE / os.environ.get("CHIEF_SUITE", "suite.yaml")   # arms pick suite.v1.yaml / suite.yaml
FIXTURES = HERE / "fixtures"
SANDBOX = Path.home() / ".hermes/cache/scratch/chief-eval/sandbox"
GPU_LOCK = Path.home() / "NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu.lock"
ENDPOINT = "http://127.0.0.1:18080/v1/models"
PROVIDER = "local-ai"
PROFILE = os.environ.get("CHIEF_PROFILE", "chief")   # arms: chief-v3-T1 ... (research/58b section 7)

_FLAGS = re.I | re.S | re.M


def grade(check, answer, sandbox):
    """Return (verdict, reason). verdict in {PASS, FAIL, MANUAL}."""
    if check.get("manual"):
        return "MANUAL", "needs a human"
    ok = True
    why = []

    def fail(msg):
        nonlocal ok
        ok = False
        why.append(msg)

    for pat in check.get("all", []):
        if not re.search(pat, answer, _FLAGS):
            fail(f"missing /{pat}/")
    if check.get("any"):
        if not any(re.search(p, answer, _FLAGS) for p in check["any"]):
            fail(f"none of {check['any']}")
    for group in check.get("any_groups", []):
        if not any(re.search(p, answer, _FLAGS) for p in group):
            fail(f"no match in group {group}")
    for pat in check.get("none", []):
        if re.search(pat, answer, _FLAGS):
            fail(f"forbidden /{pat}/")

    for f in check.get("files", []):
        path = Path(f["path"])
        if not path.is_absolute():
            path = sandbox / path
        exists = path.exists()
        if not f.get("exists", True):
            if exists:
                fail(f"{f['path']} should not exist")
            continue
        if not exists:
            fail(f"missing file {f['path']}")
            continue
        if f.get("regex"):
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                fail(f"{f['path']} unreadable: {exc}")
                continue
            hits = re.findall(f["regex"], text, _FLAGS)
            if f.get("must_not_match"):
                if hits:
                    fail(f"{f['path']} must not match /{f['regex']}/")
                continue
            if not hits:
                fail(f"{f['path']} no match /{f['regex']}/")
            elif "count" in f and len(hits) != f["count"]:
                fail(f"{f['path']} expected {f['count']} hits of /{f['regex']}/, got {len(hits)}")
            elif "min_count" in f and len(hits) < f["min_count"]:
                fail(f"{f['path']} needs >= {f['min_count']} hits of /{f['regex']}/, got {len(hits)}")
            elif "max_count" in f and len(hits) > f["max_count"]:
                fail(f"{f['path']} needs <= {f['max_count']} hits of /{f['regex']}/, got {len(hits)}")

    return ("PASS" if ok else "FAIL"), "; ".join(why) or "ok"


def reset_sandbox():
    """Fresh sandbox: wipe it, then copy the fixture tree in."""
    if SANDBOX.exists():
        shutil.rmtree(SANDBOX)
    shutil.copytree(FIXTURES, SANDBOX)


def apply_files(entries):
    """Materialise pass_files: {path, content} write, {path, remove} delete, {copy, path} copy."""
    for e in entries or []:
        dest = SANDBOX / e["path"]
        if e.get("remove"):
            if dest.exists():
                dest.unlink()
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        if "copy" in e:
            shutil.copyfile(HERE / e["copy"], dest)
        else:
            dest.write_text(e.get("content", ""), encoding="utf-8")


def apply_sandbox_setup(entries):
    """Live-run only: copy live files/dirs into the sandbox before an item runs.

    Entries are {src: absolute live source, dst: sandbox-relative destination}. The live
    source is only read, never written, so the real ledger and invoices stay untouched.
    """
    for e in entries or []:
        src = Path(e["src"]).expanduser()
        dst = SANDBOX / e["dst"]
        if not src.exists():
            print(f"  ! sandbox_setup: source missing {src}")
            continue
        if src.is_dir():
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)


def preflight(model):
    """Refuse to start unless the GPU lock is free and the endpoint answers."""
    problems = []
    try:
        # LC_LOCKED=1 means the caller already holds the lock: `flock -x bench/.gpu.lock env LC_LOCKED=1 ...` (as bench/lc.py)
        rc = 0 if os.environ.get("LC_LOCKED") == "1" else subprocess.run(["flock", "-n", str(GPU_LOCK), "true"]).returncode
    except FileNotFoundError:
        problems.append("flock is not installed")
    else:
        if rc != 0:
            problems.append(
                f"the GPU lock is held by another process: {GPU_LOCK}. "
                f"Wait for it to be released (flock -n {GPU_LOCK} true must exit 0)."
            )
    try:
        out = subprocess.run(
            ["curl", "-s", "-m", "3", ENDPOINT], capture_output=True, text=True, timeout=6
        )
        if out.returncode != 0 or not out.stdout.strip():
            problems.append(
                f"the model endpoint did not answer at {ENDPOINT}. "
                "Start it with: cd ~/NEXUS_AI_CENTER/LOCAL-AI-LAB && "
                "llama-swap -config serve/config.yaml -listen 127.0.0.1:18080"
            )
    except (OSError, subprocess.SubprocessError) as exc:
        problems.append(f"could not reach {ENDPOINT}: {exc}")
    if problems:
        sys.exit("refusing to start:\n  - " + "\n  - ".join(problems))


def call_chief(model, prompt, timeout):
    cmd = ["hermes", "-p", PROFILE, "chat", "-Q", "--provider", PROVIDER, "-m", model, "-q", prompt]
    started = time.monotonic()
    try:
        # cwd = NEXUS_AI_CENTER, Chief's home (Marcel); SOUL.md points to its own AGENTS.md
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              cwd=Path.home() / "NEXUS_AI_CENTER")
        answer = (done.stdout or "").strip()
        err = (done.stderr or "").strip()
        if done.returncode != 0 and not answer:
            answer = f"[exit {done.returncode}] {err}"
        return answer, time.monotonic() - started, done.returncode
    except subprocess.TimeoutExpired:
        return f"[timeout after {timeout}s]", time.monotonic() - started, 124


def run_suite(suite, model, only, out_path):
    items = suite["items"]
    if only:
        items = [i for i in items if i["category"] == only]
        if not items:
            sys.exit(f"no items in category {only!r}")
    results = []
    for item in items:
        reset_sandbox()
        apply_sandbox_setup(item.get("sandbox_setup"))
        prompt = item["prompt"]
        if item.get("preamble"):
            prompt = item["preamble"].replace("{sandbox}", str(SANDBOX)) + "\n\n" + prompt
        answer, secs, rc = call_chief(model, prompt, item["max_seconds"])
        verdict, reason = grade(item["check"], answer, SANDBOX)
        results.append(
            {
                "id": item["id"],
                "category": item["category"],
                "prompt": prompt,
                "expected": item["expected"],
                "answer": answer,
                "verdict": verdict,
                "reason": reason,
                "seconds": round(secs, 2),
                "exit_code": rc,
            }
        )
        print(f"{verdict:4} {item['id']:8} {secs:6.1f}s  {reason}")
    report = {
        "model": model,
        "profile": PROFILE,
        "run_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "items": results,
    }
    write_report(report, out_path)
    return report


def write_report(report, out_path):
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    scorecard = Path(out_path).with_suffix(".md")
    by_cat = {}
    for r in report["items"]:
        c = by_cat.setdefault(r["category"], [0, 0])
        c[0] += r["verdict"] == "PASS"
        c[1] += 1
    lines = [
        f"# Chief eval scorecard — {report['model']}",
        "",
        f"Run {report['run_at']} · profile `{report['profile']}` · {len(report['items'])} items",
        "",
        "| category | pass | total |",
        "|---|---|---|",
    ]
    for cat, (passed, total) in by_cat.items():
        lines.append(f"| {cat} | {passed} | {total} |")
    tp = sum(v[0] for v in by_cat.values())
    lines += ["", f"Total: {tp}/{len(report['items'])}", "", "| id | verdict | s | reason |", "|---|---|---|---|"]
    for r in report["items"]:
        lines.append(f"| {r['id']} | {r['verdict']} | {r['seconds']} | {r['reason']} |")
    scorecard.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\nwrote {out_path} and {scorecard}")


def dry_run(suite):
    """Validate the YAML and self-test every check: pass_sample -> PASS, wrong -> FAIL."""
    items = suite["items"]
    cats = suite["meta"]["categories"]
    failures = []

    seen_ids = set()
    for item in items:
        for field in ("id", "category", "prompt", "expected", "check", "allowed_side_effects", "max_seconds"):
            if field not in item:
                failures.append(f"{item.get('id', '?')}: missing field {field}")
        if item["id"] in seen_ids:
            failures.append(f"duplicate id {item['id']}")
        seen_ids.add(item["id"])
        if item["category"] not in cats:
            failures.append(f"{item['id']}: unknown category {item['category']}")
        if item["allowed_side_effects"] not in ("none", "sandbox-only"):
            failures.append(f"{item['id']}: bad allowed_side_effects")
        if "pass_sample" not in item and "pass_files" not in item:
            failures.append(f"{item['id']}: no pass_sample or pass_files")

    print(f"suite: {len(items)} items in {len(cats)} categories")
    for cat in cats:
        n = sum(i["category"] == cat for i in items)
        print(f"  {cat:12} {n}")

    print("\n[1/2] pass_sample must grade PASS")
    for item in items:
        reset_sandbox()
        apply_files(item.get("pass_files"))
        verdict, reason = grade(item["check"], item.get("pass_sample", ""), SANDBOX)
        flag = "ok  " if verdict == "PASS" else "FAIL"
        print(f"  {flag} {item['id']:8} {reason}")
        if verdict != "PASS":
            failures.append(f"{item['id']}: pass_sample graded {verdict} ({reason})")

    print("\n[2/2] one wrong answer per category must grade FAIL on every item")
    wrong = suite.get("self_test", {}).get("wrong", {})
    for cat in cats:
        if cat not in wrong:
            failures.append(f"category {cat}: no wrong answer in self_test")
            continue
        w = wrong[cat]
        n_pass = 0
        for item in [i for i in items if i["category"] == cat]:
            reset_sandbox()
            apply_files(w.get("files"))
            verdict, _ = grade(item["check"], w.get("answer_text", ""), SANDBOX)
            if verdict != "FAIL":
                n_pass += 1
                failures.append(f"{item['id']}: wrong answer graded {verdict}, expected FAIL")
        print(f"  {'ok  ' if n_pass == 0 else 'FAIL'} {cat:12} wrong answer fails {len([i for i in items if i['category']==cat])-n_pass}/{sum(i['category']==cat for i in items)}")

    print()
    if failures:
        print(f"DRY-RUN FAILED: {len(failures)} problem(s)")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"DRY-RUN PASSED: {len(items)} checks pass on the expected answers; "
          f"{len(cats)} deliberately wrong answers fail.")
    return 0


def compare(path_a, path_b):
    a = json.loads(Path(path_a).read_text(encoding="utf-8"))
    b = json.loads(Path(path_b).read_text(encoding="utf-8"))
    by_id_b = {r["id"]: r for r in b["items"]}
    print(f"A = {a['model']} ({path_a})")
    print(f"B = {b['model']} ({path_b})\n")
    print(f"{'id':8} {'cat':11} {'A':4} {'B':4}  change")
    changed = 0
    a_pass = b_pass = total = 0
    for r in a["items"]:
        rb = by_id_b.get(r["id"])
        if not rb:
            continue
        total += 1
        a_pass += r["verdict"] == "PASS"
        b_pass += rb["verdict"] == "PASS"
        if r["verdict"] != rb["verdict"]:
            changed += 1
            print(f"{r['id']:8} {r['category']:11} {r['verdict']:4} {rb['verdict']:4}  {r['verdict']} -> {rb['verdict']}")
    print(f"\nA pass {a_pass}/{total}  B pass {b_pass}/{total}  changed {changed}")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Chief evaluation runner")
    ap.add_argument("--model", default="gemma4-12b",
                    help="llama-swap model id: gemma4-12b | gemma4-12b-think | any id in serve/config.yaml")
    ap.add_argument("--only", help="run one category only")
    ap.add_argument("--dry-run", action="store_true", help="validate the YAML and self-test the checks, no model calls")
    ap.add_argument("--out", help="results JSON path (default results/<model>-<timestamp>.json)")
    ap.add_argument("--compare", nargs=2, metavar=("A", "B"), help="diff two result files")
    args = ap.parse_args()

    suite = yaml.safe_load(SUITE.read_text(encoding="utf-8"))

    if args.compare:
        return compare(*args.compare)

    if args.dry_run:
        return dry_run(suite)

    out = args.out or f"results/{args.model}-{datetime.now():%Y%m%d-%H%M%S}.json"
    preflight(args.model)
    print(f"running {len(suite['items'])} items on {args.model} -> {out}\n")
    run_suite(suite, args.model, args.only, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
