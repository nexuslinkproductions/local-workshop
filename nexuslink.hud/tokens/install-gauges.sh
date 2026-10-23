#!/usr/bin/env bash
# Install the gauge collector to a path that survives branch switches and
# worktree removal, then restart the user unit. Run from any checkout.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.local/lib/nexuslink"
unit_dir="$HOME/.config/systemd/user"
mkdir -p "$dest" "$unit_dir"
install -m 0644 "$here/gauges.py" "$dest/gauges.py"
install -m 0644 "$here/systemd/nexuslink-gauges.service" "$unit_dir/nexuslink-gauges.service"
python3 -m py_compile "$dest/gauges.py"
systemctl --user daemon-reload
systemctl --user enable nexuslink-gauges.service
systemctl --user restart nexuslink-gauges.service
systemctl --user is-active nexuslink-gauges.service
systemctl --user is-enabled nexuslink-gauges.service
