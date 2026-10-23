#!/usr/bin/env bash
# audit.sh [state]: text overlap audit of the deck scene on the software offscreen platform.
# states: rest (default) | crew | storage | find. Prints the AUDIT summary and every violation.
set -o pipefail
V=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
s=${1:-rest}
view=""; fo=false
case $s in crew) view=crew ;; storage) view=storage ;; find) fo=true ;; esac
sed -e "s/VIEWSTATE/$view/" -e "s/FINDSTATE/$fo/g" "$V/deck.qml" > "$V/_deck_audit.qml"
QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software nice -n 19 timeout 60 /usr/lib/qt6/bin/qml "$V/audit.qml" 2>&1 | grep -E "^(qml: )?(AUDIT|OVERLAP|TEXT)" | sed -e 's/^qml: //' | { if [ "${AUDIT_VERBOSE:-0}" = 1 ]; then cat; else grep -E "^(AUDIT|OVERLAP)"; fi; }
rm -f "$V/_deck_audit.qml"
