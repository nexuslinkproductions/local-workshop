#!/usr/bin/env bash
# qmllint wrapper: raw diagnostics, then one stable summary line.
#
#   tools/qml-lint.sh [options] [paths...]
#
# Paths may be files or directories; directories are searched for *.qml.
# With no paths, the current directory is linted.
#
# Options:
#   -s, --strict    exit 1 when there is any warning, not only errors
#   -v, --verbose   also print the file list and the qmllint command
#   -h, --help      this text
#
# Output:
#   <path> <n> warning(s)        one line per linted file, including 0
#   LINT files=<n> warnings=<w> errors=<e> exit=<rc>          the summary
#
# Exit: 0 clean, 1 errors (or warnings with --strict), 3 toolchain problem,
# 64 usage.

set -o pipefail

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/qt-env.sh
. "$TOOLS_DIR/lib/qt-env.sh"

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

strict=0
verbose=0
targets=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -s|--strict) strict=1; shift ;;
        -v|--verbose) verbose=1; shift ;;
        --) shift; while [ $# -gt 0 ]; do targets[${#targets[@]}]="$1"; shift; done ;;
        -*) echo "qml-lint: unknown option: $1" >&2; exit 64 ;;
        *) targets[${#targets[@]}]="$1"; shift ;;
    esac
done
if [ ${#targets[@]} -eq 0 ]; then
    targets[0]=.
fi

qmllint=$(hud_find_qt_tool qmllint qmllint6) || {
    echo "qml-lint: qmllint not found (set QML_QT_PREFIX or QT_PREFIX)" >&2
    exit 3
}

files=()
for target in "${targets[@]}"; do
    if [ -d "$target" ]; then
        while IFS= read -r -d '' f; do
            files[${#files[@]}]="$f"
        done < <(find "$target" -type f -name '*.qml' -print0)
    elif [ -f "$target" ]; then
        files[${#files[@]}]="$target"
    else
        echo "qml-lint: no such path: $target" >&2
        exit 64
    fi
done

if [ ${#files[@]} -eq 0 ]; then
    echo "qml-lint: no .qml files under: ${targets[*]}" >&2
    exit 64
fi

if [ "$verbose" = 1 ]; then
    echo "qml-lint: $qmllint (Qt $(hud_qt_version 2>/dev/null || echo unknown))" >&2
    for f in "${files[@]}"; do echo "  $f" >&2; done
fi

log=$(mktemp "${TMPDIR:-/tmp}/qml-lint.XXXXXX") || exit 3
trap 'rm -f "$log"' EXIT

"$qmllint" "${files[@]}" >"$log" 2>&1
rc=$?

# Raw diagnostics first: they are the actionable part.
if [ -s "$log" ]; then
    cat "$log"
fi

# Per-file counts. Two line formats are handled:
#   Qt 6.12+  "Warning: path/file.qml:12:5: message [category]"
#   classic   "path/file.qml:12:5: warning: message [category]"
summary=$(awk -v exit_code="$rc" '
    FNR == NR { files[++nf] = $0; known[$0] = 1; next }
    {
        line = $0
        sev = ""
        path = ""
        if (match(line, /^(Warning|Error|Info|Critical): /)) {
            sev = substr(line, 1, RLENGTH - 2)
            rest = substr(line, RLENGTH + 1)
            if (match(rest, /^.*:[0-9]+:[0-9]+: /)) {
                path = substr(rest, 1, RLENGTH)
                sub(/:[0-9]+:[0-9]+: $/, "", path)
            }
        } else if (match(line, /^.+:[0-9]+:[0-9]+: (warning|error|info|critical): /)) {
            path = line
            sub(/:[0-9]+:[0-9]+: .*/, "", path)
            rest = substr(line, length(path) + 2)
            split(rest, parts, ": ")
            sev = parts[2]
        }
        if (path == "")
            next
        if (!(path in known)) {
            # qmllint may echo an absolute path; match on the tail instead.
            for (i = 1; i <= nf; i++) {
                if (length(path) >= length(files[i]) &&
                    substr(path, length(path) - length(files[i]) + 1) == files[i]) {
                    path = files[i]
                    break
                }
            }
        }
        sev = tolower(sev)
        key = path
        if (sev == "warning")
            warn[key]++
        else if (sev == "error" || sev == "critical")
            err[key]++
    }
    END {
        total_w = 0; total_e = 0
        for (i = 1; i <= nf; i++) {
            f = files[i]
            w = warn[f] + 0
            e = err[f] + 0
            total_w += w
            total_e += e
            printf "%-64s %d warning(s)%s\n", f, w, (e ? sprintf(", %d error(s)", e) : "")
        }
        printf "LINT files=%d warnings=%d errors=%d exit=%d\n", nf, total_w, total_e, exit_code
    }
' <(printf '%s\n' "${files[@]}") "$log")

printf '%s\n' "$summary"

warnings=$(printf '%s\n' "$summary" | sed -n 's/^LINT .*warnings=\([0-9]*\).*/\1/p')
errors=$(printf '%s\n' "$summary" | sed -n 's/^LINT .*errors=\([0-9]*\).*/\1/p')

if [ "${errors:-0}" -gt 0 ]; then
    exit 1
fi
if [ "$strict" = 1 ] && [ "${warnings:-0}" -gt 0 ]; then
    exit 1
fi
exit 0
