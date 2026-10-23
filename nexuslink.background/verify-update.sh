#!/bin/bash
# Compare the stock Omarchy background plugin with this clone, ignoring the
# hunks this clone added (every one is marked with a "// NEXUS:" comment).
#
# Exit 0 and "clone is in sync with stock" means: apart from the NEXUS edits,
# the clone still matches the Background.qml shipped by the installed Omarchy.
# Anything else means upstream changed the stock plugin and the clone needs a
# manual re-sync.

set -o pipefail

STOCK="/usr/share/omarchy/shell/plugins/background/Background.qml"
CLONE="$(dirname "$(readlink -f "$0")")/Background.qml"

if [[ ! -f $STOCK ]]; then
  echo "verify-update: stock plugin not found at $STOCK" >&2
  exit 2
fi
if [[ ! -f $CLONE ]]; then
  echo "verify-update: clone not found at $CLONE" >&2
  exit 2
fi

raw=$(mktemp)
filtered=$(mktemp)
trap 'rm -f "$raw" "$filtered"' EXIT

diff -U0 "$STOCK" "$CLONE" >"$raw"
rc=$?
if ((rc == 0)); then
  echo "clone is in sync with stock"
  exit 0
fi
if ((rc > 1)); then
  echo "verify-update: diff failed (exit $rc)" >&2
  exit 2
fi

# Drop every hunk that contains a NEXUS marker. Hunk = "@@" header plus its
# lines; keep grows once a marker is seen inside the hunk.
awk '
  /^@@/ {
    if (hunk != "" && !keep) printf "%s", hunk
    hunk = $0 "\n"
    keep = 0
    next
  }
  /^---/ { next }
  /^\+\+\+/ { next }
  {
    hunk = hunk $0 "\n"
    if ($0 ~ /\/\/ NEXUS:/) keep = 1
  }
  END { if (hunk != "" && !keep) printf "%s", hunk }
' "$raw" >"$filtered"

if [[ ! -s $filtered ]]; then
  echo "clone is in sync with stock"
  exit 0
fi

echo "clone has drifted from stock (non-NEXUS differences below):"
cat "$filtered"
echo
echo "Re-sync: diff the stock Background.qml above against the clone, port the"
echo "upstream changes into $CLONE, keep every edit marked '// NEXUS:', then"
echo "run 'omarchy restart shell'. Stock: $STOCK"
exit 1
