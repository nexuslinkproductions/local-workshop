# Shared Qt discovery for the tools/*.sh scripts. Source this, do not execute it.
#
# Order: QML_QT_PREFIX, QT_PREFIX, QTDIR, Homebrew, qmake6/qtpaths6, distro paths.
# Every helper prints to stdout and returns non-zero when it finds nothing.
# Written for bash 3.2 (the macOS default): no mapfile, no assoc arrays.

hud_qt_prefix() {
    local cand
    for cand in "${QML_QT_PREFIX:-}" "${QT_PREFIX:-}" "${QTDIR:-}"; do
        if [ -n "$cand" ] && [ -d "$cand/lib/cmake/Qt6" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    if command -v brew >/dev/null 2>&1; then
        cand=$(brew --prefix qt 2>/dev/null) || cand=""
        if [ -n "$cand" ] && [ -d "$cand/lib/cmake/Qt6" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    fi
    for cand in /opt/homebrew/opt/qt /usr/local/opt/qt; do
        if [ -d "$cand/lib/cmake/Qt6" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    if command -v qmake6 >/dev/null 2>&1; then
        cand=$(qmake6 -query QT_INSTALL_PREFIX 2>/dev/null) || cand=""
        if [ -n "$cand" ] && [ -d "$cand/lib/cmake/Qt6" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    fi
    for cand in /usr/lib/qt6 /usr/lib64/qt6 /usr; do
        if [ -d "$cand/lib/cmake/Qt6" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

hud_qt_version() {
    local prefix out
    prefix=${1:-}
    if [ -z "$prefix" ]; then
        prefix=$(hud_qt_prefix) || return 1
    fi
    if [ -x "$prefix/bin/qmake6" ]; then
        out=$("$prefix/bin/qmake6" -query QT_VERSION 2>/dev/null) || out=""
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    if [ -x "$prefix/bin/qmake" ]; then
        out=$("$prefix/bin/qmake" -query QT_VERSION 2>/dev/null) || out=""
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    if [ -f "$prefix/lib/cmake/Qt6/Qt6ConfigVersion.cmake" ]; then
        out=$(sed -n 's/^set(PACKAGE_VERSION "\(.*\)")$/\1/p' \
             "$prefix/lib/cmake/Qt6/Qt6ConfigVersion.cmake" | head -n 1)
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    return 1
}

# hud_find_qt_tool <name> [fallback name ...]
# Prefers the Qt prefix (bin/ and the distro lib/qt6/bin layout), then PATH.
hud_find_qt_tool() {
    local name dir prefix
    prefix=$(hud_qt_prefix 2>/dev/null) || prefix=""
    for name in "$@"; do
        if [ -n "$prefix" ]; then
            for dir in "$prefix/bin" "$prefix/lib/qt6/bin" "$prefix/lib64/qt6/bin"; do
                if [ -x "$dir/$name" ]; then
                    printf '%s\n' "$dir/$name"
                    return 0
                fi
            done
        fi
        if command -v "$name" >/dev/null 2>&1; then
            command -v "$name"
            return 0
        fi
    done
    return 1
}
