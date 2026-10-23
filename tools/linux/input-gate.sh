#!/usr/bin/env bash
# input-gate.sh - click input check for the v5 deck (Find, Crew, Mac).
#
#   tools/linux/input-gate.sh [--since "10 min ago"]
#
# Part 1 (harness, offscreen, no compositor): synthetic clicks on the composed
#   scene (DeckView over the Environment slot). Exit 1 on any FAIL.
# Part 2 (live, read only): `hyprctl layers -j` for namespace nexuslink-hud,
#   one line per output with its rect. The JSON has no input region, so the
#   click-through mask is NOT checked here (documented limit).
# Part 3 (live, read only): journal count of "v5 find: open=true" against
#   "v5 find: grab cleared". Any cleared grab after an open is the Find bug.
# Never dispatches to Hyprland, never opens a window.
set -u
since="10 min ago"
[ "${1:-}" = "--since" ] && since="${2:-$since}"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
plugin=$(cd -- "$here/../../nexuslink.hud" && pwd -P)
rc=0

echo "== part 1: harness clicks (tst_input_clicks.qml)"
( cd "$plugin/v5/verify" && flock /tmp/hudlive-render.lock nice -n 19 ionice -c3 \
    env QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QSG_RENDER_LOOP=basic \
    timeout 170 /usr/lib/qt6/bin/qmltestrunner -maxwarnings 0 -input tst_input_clicks.qml 2>&1 \
  | grep -E "^(PASS|FAIL)|Totals" | grep -v "initTestCase\|cleanupTestCase" ) || rc=1
[ $rc -eq 0 ] && echo "part 1: PASS" || { echo "part 1: FAIL"; }

echo "== part 2: hyprctl layers (namespace nexuslink-hud)"
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    sig=$(ls -t "/run/user/$(id -u)/hypr" 2>/dev/null | head -n 1)
    [ -n "$sig" ] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
fi
if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    hyprctl layers -j 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as e:
    print("part 2: no layer JSON (%s)" % e); sys.exit(0)
hits = 0
for mon, body in (data.items() if isinstance(data, dict) else []):
    for lv in body.get("levels", {}).values() if isinstance(body, dict) else []:
        for s in lv:
            if s.get("namespace") == "nexuslink-hud":
                hits += 1
                print("  %-10s x=%s y=%s w=%s h=%s" % (mon, s.get("x"), s.get("y"), s.get("w"), s.get("h")))
print("part 2: %d nexuslink-hud surface(s); input region not exposed by hyprctl" % hits)
' || true
else
    echo "part 2: skipped (hyprctl or jq missing)"
fi

echo "== part 3: Find grab (journal since: $since)"
j=$(journalctl --user --since "$since" --no-pager 2>/dev/null | grep "v5 find:")
opened=$(printf '%s\n' "$j" | grep -c "open=true")
cleared=$(printf '%s\n' "$j" | grep -c "grab cleared")
echo "  opens=$opened grab_cleared=$cleared"
if [ "$cleared" -gt 0 ]; then
    echo "part 3: FAIL (compositor cleared the Find grab; build predates the grab removal or grab is back)"
    rc=1
else
    echo "part 3: PASS (no grab-cleared lines in window)"
fi
exit $rc
