# tools/ : HUD v5 C0 toolchain

Qt 6.12.0 dev tooling for the DP-2 deck: offscreen stills, qmllint summaries and
shader packs. Mac is the build host, Linux verifies; both must report the same
Qt version or a shader pack baked here will not load in Quickshell there.

## Versions on this Mac

```
brew install qt                  -> qt 6.12.0 (Homebrew, /opt/homebrew/opt/qt)
qmake6 -query QT_VERSION         -> 6.12.0
qsb --version                    -> qsb 6.12.0
qmllint --version                -> qmllint 6.12.0
host                             -> macOS 26.4.1, arm64, AppleClang 21.0.0
```

Target on Linux is Quickshell 0.3.2 on Qt 6.12.0. Exact match, so a `.qsb`
baked here loads there. `tools/lib/qt-env.sh` finds Qt through
`QML_QT_PREFIX`, `QT_PREFIX`, `QTDIR`, Homebrew, `qmake6` or the distro paths,
in that order.

## tools/qml-shot.sh

```
tools/qml-shot.sh <file.qml> <out.png> [W H]      default 2560x1440
```

Renders one QtQuick item offscreen to a PNG, no display, no Xvfb, no Wayland.
The QML root must be an Item (resized to W x H) or a Window. The first run
compiles the grab harness in `tools/harness/` with cmake into `tools/.build/`
(about 5 s, once per Qt version); later runs take about 0.9 s at 2560x1440.

stdout is one machine-readable line, stderr carries build and Qt noise:

```
qt=6.12.0 platform=offscreen mode=rhi api=metal capture=readback frames=3
image=2560x1440 distinct=338 minlum=14 maxlum=204 center=#c7f21c
corner=#0a0f1c saved=/abs/out.png
```

`QML_SHOT_MODE=auto|rhi|window` picks the render path (default auto: RHI, then
the window grab). `QML_SHOT_DELAY`, `QML_SHOT_TIMEOUT`, `QML_SHOT_BUILD_DIR` and
`QML_SHOT_HARNESS` tune it.

## Does ShaderEffect render offscreen on this Mac?

No, not through the plain offscreen window path, and yes through the RHI path.
Both measured on `tools/tests/shadertest.qml` (gradient plus one round dot).

- `QT_QPA_PLATFORM=offscreen` plus a plain `QQuickWindow`: Qt selects the
  software scenegraph adaptation, because the offscreen QPA plugin cannot host
  an RHI swapchain. Setting `QSG_RHI_BACKEND=metal` does not change that. The
  software backend does not draw `ShaderEffect` items at all, so the grab is a
  flat frame: `api=software`, `distinct=1`, all pixels `#000000`. Exit code is
  still 0, the picture is just empty. Layout, text and `Rectangle` items do
  render on that path, so it is still usable for layout stills.
- Working path, and the harness default: `QQuickRenderControl` plus an RHI
  offscreen frame into a texture, then a texture readback. The switch that makes
  Qt accept it is `QT_QUICK_BACKEND=rhi`; without it Qt answers
  `QRhi is only compatible with default adaptation`. Result: `mode=rhi`,
  `api=metal`, 2560x1440 RGBA, `distinct=338`, centre `#c7f21c` (the dot),
  corner `#0a0f1c` (the gradient), about 0.9 s warm.
- Caveats for shader verification:
  - The RHI path needs a working RHI backend. Metal here; on Linux the offscreen
    plugin has no GL, so a verifier with a display should use the window path
    (`QML_SHOT_MODE=window` with `QT_QPA_PLATFORM` unset) or an EGL capable
    offscreen setup. Check the `api=` field before trusting a shader still.
  - The RHI path emits exactly W x H device pixels at device pixel ratio 1, so
    stills are directly comparable across hosts.
  - The cocoa window path scales by the display DPR: a 640x360 request came back
    1280x720. Use the RHI path for pixel work.
  - Animations are not advanced by the grab. Drive time through a property and
    render one still per value; there is no clock in a single frame.
  - A frame is not enough for first-use shader compilation, so the harness
    renders three frames and reads back the third. Keep that in mind when adding
    one-shot effects that mutate on the first frame.
  - `ShaderEffect` with a relative `fragmentShader` URL resolves against the QML
    file, so keep the `.qsb` next to the `.qml` or use an absolute URL.

## tools/qml-lint.sh

```
tools/qml-lint.sh [options] [paths...]           no path: current directory
  -s, --strict     exit 1 on warnings too
  -v, --verbose    print the file list and command
```

Raw qmllint diagnostics first, then one line per file including zeros, then the
summary line. Directories are searched for `*.qml`.

```
nexuslink.hud/HudSection.qml                                     13 warning(s)
LINT files=73 warnings=251 errors=0 exit=0
```

Exit 0 on warnings only, 1 on errors (or warnings with `--strict`), 3 when Qt is
missing, 64 on usage. Use the summary line as the gate: "no worse than base" is
a comparison of two `warnings=` numbers on the same file set.

## tools/qsb.sh

```
tools/qsb.sh <in.frag|in.vert|...> <out.qsb> [--glsl]
```

Wraps the Qt shader baker. By default it bakes the full Qt 6 target set
(`--qt6`: GLSL 100 es, 120, 150 plus HLSL 5.0 plus MSL 1.2) so one pack renders
on Linux GL, Windows and Metal. `--glsl` bakes GLSL 100 es, 120, 150 only, which
is what the Linux verification path needs and keeps the pack smaller (2264 vs
1630 bytes for the test shader). The stage comes from the file extension.
Arguments after `--` go to qsb, for example `-- --define FOO=1` or
`-- --batchable`.

stdout is one line with input, output, byte count, Qt version and targets.
A failed compile exits 1, a missing or empty pack exits 1.

## tools/tests/

`shadertest.qml` plus `shadertest.frag` (gradient and one round dot),
`run-tests.sh` runs the whole chain and asserts the pixels:

```
tools/tests/run-tests.sh
```

It compiles the shader, lints the directory, renders at 2560x1440, then checks
image size, `mode=rhi`, `api=metal`, at least 32 distinct colours, a centre
pixel different from the corner pixel, and finally the control case
(`QML_SHOT_MODE=window` must show `api=software` and `distinct=1`, which is the
documented empty-shader path). Exit 0 means all checks passed.

## Notes

- `tools/.build/` is the harness cache and `tools/tests/*.qsb` are test
  artifacts; both are gitignored.
- The repo root `.gitignore` only tracks allowlisted paths, so it carries
  `!/tools/` for this directory.
