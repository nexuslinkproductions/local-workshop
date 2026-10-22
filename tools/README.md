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
The QML root must be an Item (resized to W x H) or a Window. A Window root is
handled by hiding the QML window and moving its direct content items into the
grab window at the requested size, so the still shows what the window would
show; the QML window itself is never displayed. Any other root is refused with
exit 2 and a message. The first run compiles the grab harness in
`tools/harness/` with cmake into `tools/.build/` (about 5 s, once per Qt
version); later runs take about 0.27 s at 2560x1440.

stdout is one machine-readable line, stderr carries build and Qt noise:

```
qt=6.12.0 platform=offscreen mode=rhi api=metal capture=readback root=item
frames=3 image=2560x1440 distinct=338 minlum=14 maxlum=204 center=#c7f21c
corner=#0a0f1c saved=/abs/out.png
```

`root=` is `item` or `window` and says which path the file took.

`QML_SHOT_MODE=auto|rhi|window` picks the render path (default auto: RHI, then
the window grab). `QML_SHOT_DELAY`, `QML_SHOT_TIMEOUT`, `QML_SHOT_BUILD_DIR` and
`QML_SHOT_HARNESS` tune it.

`QML_SHOT_MIN_DISTINCT=<n>` turns a flat frame into a failure: when the number
of distinct colours is below `n`, the script exits 1 and says so. It is unset by
default because a legitimately single-colour still is still a valid still, but
anything asserting that a shader or a layout actually drew should set it.
`tools/tests/run-tests.sh` sets it to 32.

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
  corner `#0a0f1c` (the gradient), about 0.27 s warm.
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
  - A `--glsl`-only pack cannot render on Metal. Bake with `--glsl` and render
    on this Mac and the frame is black with exit 0 (`api=metal`, `distinct=1`);
    the full default pack is the one that carries MSL. See the `qsb.sh` section.
  - A Window root renders through its content items: the QML window is never
    shown, its direct children are moved into the grab window at the requested
    size, and the Window's own `color` becomes the grab background. Window-only
    concerns (frame, screen placement, `flags`) have no meaning in a still.
    Before the repair this path produced a black frame with exit 0.

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
LINT files=73 warnings=286 errors=0 exit=0
```

`warnings=` counts every `Warning:` diagnostic, including the ones without a
file path that the per-file lines cannot attribute (Qt 6.12 prints for example
`Warning: 2:1: Failed to import ...`), so two runs are compared on the same
basis. `errors=` counts `Error:`/`Critical:` diagnostics plus every `[syntax]`
failure, which Qt reports as a warning, and never stays at 0 when qmllint
exited non-zero: the raw exit code is the error signal, not the severity prefix.

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

A `--glsl` pack is Linux-path output only: it carries no MSL, so rendering it on
this Mac gives `api=metal`, `distinct=1`, a black frame and exit 0. Use the full
default pack for anything that renders here, and set `QML_SHOT_MIN_DISTINCT`
when a still has to prove that it drew something.

stdout is one line with input, output, byte count, Qt version and targets.
A failed compile exits 1, a missing or empty pack exits 1.

## tools/tests/

`shadertest.qml` plus `shadertest.frag` (gradient and one round dot),
`run-tests.sh` runs the whole chain and asserts the pixels:

```
tools/tests/run-tests.sh [output dir]
```

It is self-contained on a clean checkout: it bakes the pack into the output
directory, installs a copy next to `shadertest.qml` (which is where the QML's
relative `fragmentShader` URL resolves, and `tools/.gitignore` already ignores
`tests/*.qsb`), then lints, renders at 2560x1440 and checks the pixels. The
cases are:

1. `qsb.sh` produces a non-empty pack and the copy lands next to the QML.
2. `qml-lint.sh` passes a warnings-only file (exit 0, `warnings>=1`,
   `errors=0`) and fails a file with a syntax error (exit 1, `errors>=1`), and
   `--strict` turns the warnings-only file into exit 1.
3. `qml-shot.sh` renders 2560x1440 with `mode=rhi`, `api=metal`, at least 32
   distinct colours, a centre pixel different from the corner pixel, and
   `QML_SHOT_MIN_DISTINCT=32` in force.
4. A Window root renders its content (`root=window`, corner and centre
   `#f0a000`), the case that used to come back black with exit 0.
5. The control case: `QML_SHOT_MODE=window` must show `api=software` and
   `distinct=1`, which is the documented empty-shader path, and the same flat
   frame must make `QML_SHOT_MIN_DISTINCT=2` exit 1.

Exit 0 means all checks passed.

## Notes

- `tools/.build/` is the harness cache and `tools/tests/*.qsb` are test
  artifacts; both are gitignored.
- The repo root `.gitignore` only tracks allowlisted paths, so it carries
  `!/tools/` for this directory.
