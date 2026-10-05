#!/usr/bin/env bash
# Deploy nexuslink.hud into the omarchy-shell user plugin directory and enable it.
# Run from anywhere:  bash /path/to/nexuslink.hud/deploy.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/.config/omarchy/plugins/nexuslink.hud"

install -d "$DST"
for f in manifest.json Hud.qml HudSection.qml HudRow.qml collect.sh README.md; do
  install -m 0644 "$SRC/$f" "$DST/$f"
done
chmod 0755 "$DST/collect.sh"

# Rust collector: rebuild when cargo is available, else reuse/keep bash path.
if command -v cargo >/dev/null 2>&1 && [[ -f "$SRC/collector/Cargo.toml" ]]; then
  (cd "$SRC/collector" && CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/hud-collect-build}" cargo build --release) \
    && install -m 0755 "$HOME/.cache/hud-collect-build/release/hud-collect" "$DST/hud-collect" \
    && echo "installed Rust collector -> $DST/hud-collect" \
    || echo "cargo build failed; keeping bash collector"
elif [[ -f "$SRC/hud-collect" ]]; then
  install -m 0755 "$SRC/hud-collect" "$DST/hud-collect"
  echo "installed prebuilt collector -> $DST/hud-collect"
else
  echo "no collector binary; using bash collect.sh"
fi

# The inotify watcher may pick the new files up on its own; rescan anyway so
# the plugin is registered before enable.
omarchy-shell shell rescanPlugins || true

omarchy plugin validate "$DST"
omarchy plugin enable nexuslink.hud

echo
echo "== plugin state =="
omarchy-shell shell listPlugins | jq -r '.[] | select(.id=="nexuslink.hud")'

echo
echo "Recent omarchy-shell log lines (check for QML errors):"
journalctl --user -u omarchy-shell -n 30 --no-pager 2>/dev/null \
  || journalctl --user -u quickshell -n 30 --no-pager 2>/dev/null \
  || true

echo
echo "IPC smoke test (should print collapsed/expanded):"
omarchy-shell nexuslink.hud toggleAll || true
omarchy-shell nexuslink.hud status || true
