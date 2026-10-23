#!/usr/bin/env bash
# Verify the full bleed HUD on one output, read only.
#
#   tools/linux/verify/verify-bleed.sh [output]        default DP-2
#   tools/linux/verify/verify-bleed.sh --image <png>    analyse an existing capture
#   tools/linux/verify/verify-bleed.sh --dry-run [output]
#   tools/linux/verify/verify-bleed.sh --geometry [output]
#        geometry assertions only (no grim, no pixels). Live by default;
#        --layers-json FILE and --monitors-json FILE read fixtures instead.
#        Without an output name every monitor is checked; a monitor with no
#        HUD layer is SKIP there, and FAIL when the output was named.
#
# What is proven how (VA finding 3):
#   top strip      pixels (crop_check.py, --image or normal mode). The only
#                  edge where the wallpaper differs from the field colour.
#   left, right,   geometry only: hyprctl layers -j gives nexuslink-hud at
#   bottom         layer origin 0,0 with the monitor's w and h, and no
#                  omarchy-background surface left above it. The wallpaper is
#                  too dark to be told apart from the field there (crop_check
#                  prints wallpaper=n/a), so a pixel pass proves nothing there.
#
# Normal mode, on the live session:
#   1. hyprctl layers -j + hyprctl monitors -j: the output must carry a layer
#      namespace nexuslink-hud at x=0 y=0 with w and h equal to the monitor
#      size. omarchy-background must not exist on that output, or it must be
#      covered by the HUD (WARN with both levels). omarchy-bar must sit on
#      level 2.
#   2. grim -o <output> into a private temp png (never touches the compositor
#      state; grim only reads the output).
#   3. crop_check.py on that png: the four edge strips must be the field
#      colour and must not match the wallpaper.
#
# --image skips 1 and 2 (use for captures taken elsewhere, e.g. the old
#   live-dp2.jpg) and runs 3 only.
# --dry-run prints the commands and the jq filters without running anything.
#
# Exit 0 all checks pass, 1 a check failed, 2 usage or tool error.
# The bar height defaults to 26 (omarchy-bar reserved zone); pass --bar to
# change it. Extra arguments after --bar are forwarded to crop_check.py.
set -u -o pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
OUT=DP-2
IMAGE=
DRY=0
BAR=26
FIELD=06080a
EXTRA=()
GEO=0
OUT_SET=0
LAYERS_JSON=
MONS_JSON=

usage() {
    sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE=${2:?--image needs a path}; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --geometry) GEO=1; shift ;;
        --layers-json) LAYERS_JSON=${2:?--layers-json needs a file}; shift 2 ;;
        --monitors-json) MONS_JSON=${2:?--monitors-json needs a file}; shift 2 ;;
        --bar) BAR=${2:?--bar needs a number}; shift 2 ;;
        --field) FIELD=${2:?--field needs a hex colour}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "verify-bleed: unknown option $1" >&2; exit 2 ;;
        *) OUT=$1; OUT_SET=1; shift ;;
    esac
done

CROP_ARGS=(--bar "$BAR" --field "$FIELD" --edge 8)
if [ ${#EXTRA[@]} -gt 0 ]; then CROP_ARGS+=("${EXTRA[@]}"); fi

LAYERS_JQ='
  .[$out].levels // {} | to_entries[]
  | .key as $level | .value | to_entries[]
  | select(.value.namespace == $ns)
  | "\($level) \(.key) \(.value.x) \(.value.y) \(.value.w) \(.value.h)"'

MON_JQ='.[] | select(.name == $out) | "\(.width) \(.height) \(.x) \(.y)"'

json_body() {
    # hyprctl may print a non JSON first line; keep everything from the first [ or {.
    awk 'found || /^[[:space:]]*[\[{]/ {found=1; print}' "$1"
}

hud_layer_line() {
    local ns line
    for ns in nexuslink-hud nexuslink-hud-v5; do
        line=$(jq -r --arg out "$1" --arg ns "$ns" "$LAYERS_JQ" "$2" 2>/dev/null | head -n 1)
        if [ -n "$line" ]; then printf '%s\n' "$line"; return 0; fi
    done
    return 1
}

# Geometry assertions (VA finding 3, left, right and bottom are proven here).
# Exit 0 PASS, 1 FAIL, 2 usage or read error. Read only.
geometry_mode() {
    local tmp lay mon names out mline hline bg res msgs bstate evaluated=0 geo_fail=0
    local MW MH MX MY HL HIDX HX HY HW HH GL GIDX
    command -v jq >/dev/null 2>&1 || { echo "verify-bleed: jq not found" >&2; return 2; }
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/hud-geo-XXXXXX") || return 2
    if [ -n "$LAYERS_JSON" ] && [ ! -r "$LAYERS_JSON" ]; then
        echo "verify-bleed: cannot read $LAYERS_JSON" >&2; rm -rf "$tmp"; return 2
    fi
    if [ -n "$MONS_JSON" ] && [ ! -r "$MONS_JSON" ]; then
        echo "verify-bleed: cannot read $MONS_JSON" >&2; rm -rf "$tmp"; return 2
    fi
    if [ -n "$LAYERS_JSON" ]; then
        json_body "$LAYERS_JSON" >"$tmp/layers.json"
    else
        command -v hyprctl >/dev/null 2>&1 || { echo "verify-bleed: hyprctl not found" >&2; rm -rf "$tmp"; return 2; }
        hyprctl layers -j 2>/dev/null | json_body /dev/stdin >"$tmp/layers.json"
    fi
    if [ -n "$MONS_JSON" ]; then
        json_body "$MONS_JSON" >"$tmp/monitors.json"
    else
        command -v hyprctl >/dev/null 2>&1 || { echo "verify-bleed: hyprctl not found" >&2; rm -rf "$tmp"; return 2; }
        hyprctl monitors -j 2>/dev/null | json_body /dev/stdin >"$tmp/monitors.json"
    fi
    lay="$tmp/layers.json"; mon="$tmp/monitors.json"
    if [ ! -s "$lay" ] || [ ! -s "$mon" ]; then
        echo "verify-bleed: no JSON read (is Hyprland running? HYPRLAND_INSTANCE_SIGNATURE)" >&2
        rm -rf "$tmp"; return 2
    fi
    if ! jq empty "$lay" >/dev/null 2>&1 || ! jq empty "$mon" >/dev/null 2>&1; then
        echo "verify-bleed: layers or monitors JSON unreadable" >&2
        rm -rf "$tmp"; return 2
    fi
    if [ "$OUT_SET" = 1 ]; then names=$OUT; else names=$(jq -r '.[].name' "$mon"); fi
    while IFS= read -r out; do
        [ -n "$out" ] || continue
        mline=$(jq -r --arg out "$out" "$MON_JQ" "$mon" 2>/dev/null | head -n 1)
        if [ -z "$mline" ]; then
            echo "FAIL  $out: monitor not found"; geo_fail=1; continue
        fi
        read -r MW MH MX MY <<<"$mline"
        hline=$(hud_layer_line "$out" "$lay") || hline=
        if [ -z "$hline" ]; then
            if [ "$OUT_SET" = 1 ]; then echo "FAIL  $out: no nexuslink-hud layer"; geo_fail=1
            else echo "SKIP  $out: no HUD layer"; fi
            continue
        fi
        evaluated=$((evaluated + 1))
        read -r HL HIDX HX HY HW HH <<<"$hline"
        res=PASS; msgs=""
        if [ "$HX" != 0 ] || [ "$HY" != 0 ]; then res=FAIL; msgs="$msgs hud origin $HX,$HY is not 0,0;"; fi
        if [ "$HW" != "$MW" ] || [ "$HH" != "$MH" ]; then res=FAIL; msgs="$msgs hud ${HW}x${HH} is not monitor ${MW}x${MH};"; fi
        bg=$(jq -r --arg out "$out" --arg ns omarchy-background "$LAYERS_JQ" "$lay" 2>/dev/null | head -n 1)
        if [ -z "$bg" ]; then
            bstate="absent"
        else
            read -r GL GIDX GX GY GW GH <<<"$bg"
            if [ "$GL" -lt "$HL" ] || { [ "$GL" -eq "$HL" ] && [ "$GIDX" -lt "$HIDX" ]; }; then
                bstate="covered(map order)"
            else
                bstate="visible level $GL"; res=FAIL; msgs="$msgs omarchy-background not covered by hud;"
            fi
        fi
        printf '%s  %s: hud x=%s y=%s w=%s h=%s on monitor %sx%s; omarchy-background %s%s\n' \
            "$res" "$out" "$HX" "$HY" "$HW" "$HH" "$MW" "$MH" "$bstate" "${msgs:+ --$msgs}"
        [ "$res" = PASS ] || geo_fail=1
    done <<<"$names"
    rm -rf "$tmp"
    if [ "$evaluated" = 0 ] && [ "$geo_fail" = 0 ]; then
        echo "FAIL  no output with a HUD layer was checked"; geo_fail=1
    fi
    if [ "$geo_fail" = 0 ]; then echo "VERDICT: PASS (geometry)"; return 0; fi
    echo "VERDICT: FAIL (geometry)"; return 1
}

if [ "$GEO" = 1 ]; then
    geometry_mode
    exit $?
fi

if [ "$DRY" = 1 ]; then
    echo "# verify-bleed dry run: output=$OUT bar=$BAR field=$FIELD"
    echo "hyprctl monitors -j | jq -r --arg out $OUT '$MON_JQ'"
    echo "hyprctl layers -j | jq -r --arg out $OUT --arg ns nexuslink-hud '$LAYERS_JQ'"
    echo "hyprctl layers -j | jq -r --arg out $OUT --arg ns omarchy-background '$LAYERS_JQ'"
    echo "hyprctl layers -j | jq -r --arg out $OUT --arg ns omarchy-bar '$LAYERS_JQ'"
    echo "grim -o $OUT <tmpdir>/hud-bleed-XXXX.png"
    echo "python3 $HERE/crop_check.py <png> --bar $BAR --field $FIELD --edge 8"
    exit 0
fi

fail=0
note() { printf '%s\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }

monitor_line() {
    hyprctl monitors -j 2>/dev/null | jq -r --arg out "$1" "$MON_JQ" 2>/dev/null | head -n 1
}

layer_lines() {
    hyprctl layers -j 2>/dev/null \
        | jq -r --arg out "$1" --arg ns "$2" "$LAYERS_JQ" 2>/dev/null
}

if [ -z "$IMAGE" ]; then
    command -v hyprctl >/dev/null 2>&1 || { echo "verify-bleed: hyprctl not found" >&2; exit 2; }
    command -v jq >/dev/null 2>&1 || { echo "verify-bleed: jq not found" >&2; exit 2; }

    mon=$(monitor_line "$OUT")
    if [ -z "$mon" ]; then
        bad "monitor $OUT not found in hyprctl monitors -j"
        exit 1
    fi
    read -r MW MH MX MY <<<"$mon"
    note "monitor $OUT: ${MW}x${MH} at ${MX},${MY}"

    hud=$(layer_lines "$OUT" nexuslink-hud | head -n 1)
    if [ -z "$hud" ]; then
        bad "layer namespace nexuslink-hud missing on $OUT"
    else
        read -r HL HIDX HX HY HW HH <<<"$hud"
        note "nexuslink-hud: level=$HL x=$HX y=$HY w=$HW h=$HH"
        [ "$HX" = "0" ] && [ "$HY" = "0" ] && ok "hud at 0,0" || bad "hud not at 0,0 (x=$HX y=$HY)"
        [ "$HW" = "$MW" ] && ok "hud width $HW equals monitor width" || bad "hud width $HW != monitor width $MW"
        [ "$HH" = "$MH" ] && ok "hud height $HH equals monitor height" || bad "hud height $HH != monitor height $MH (exclusive zone still applied?)"
    fi

    bar=$(layer_lines "$OUT" omarchy-bar | head -n 1)
    if [ -z "$bar" ]; then
        bad "layer namespace omarchy-bar missing on $OUT"
    else
        read -r BL BIDX BX BY BW BH <<<"$bar"
        note "omarchy-bar: level=$BL x=$BX y=$BY w=$BW h=$BH"
        [ "$BL" = "2" ] && ok "omarchy-bar on level 2" || bad "omarchy-bar level $BL != 2"
    fi

    bg=$(layer_lines "$OUT" omarchy-background | head -n 1)
    if [ -z "$bg" ]; then
        ok "no omarchy-background layer on $OUT"
    else
        read -r GL GIDX GX GY GW GH <<<"$bg"
        note "omarchy-background: level=$GL x=$GX y=$GY w=$GW h=$GH"
        if [ -z "${HL:-}" ]; then
            bad "omarchy-background present and no hud layer to cover it"
        elif [ "$GL" -lt "$HL" ] || { [ "$GL" -eq "$HL" ] && [ "$GIDX" -lt "$HIDX" ]; }; then
            printf 'WARN  omarchy-background present on %s at level %s (hud level %s); covered by map order\n' \
                "$OUT" "$GL" "$HL"
        else
            bad "omarchy-background at level $GL is not covered by hud at level $HL"
        fi
    fi

    command -v grim >/dev/null 2>&1 || { echo "verify-bleed: grim not found" >&2; exit 2; }
    PNG=$(mktemp --suffix=.png "${TMPDIR:-/tmp}/hud-bleed-XXXXXX")
    if ! grim -o "$OUT" "$PNG"; then
        rm -f "$PNG"
        echo "verify-bleed: grim -o $OUT failed" >&2
        exit 2
    fi
    note "capture: $PNG"
else
    PNG=$IMAGE
    [ -r "$PNG" ] || { echo "verify-bleed: cannot read $PNG" >&2; exit 2; }
fi

if ! python3 "$HERE/crop_check.py" "$PNG" "${CROP_ARGS[@]}"; then
    fail=1
fi

if [ -z "$IMAGE" ] && [ "${KEEP:-0}" != 1 ]; then
    rm -f "$PNG"
fi

if [ "$fail" = 0 ]; then
    echo "VERDICT: PASS ($OUT)"
    exit 0
fi
echo "VERDICT: FAIL ($OUT)"
exit 1
