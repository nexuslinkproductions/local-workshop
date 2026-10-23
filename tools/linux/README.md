# tools/linux: offscreen GPU renders and CPU sampling on Linux

Qt is 6.12.0 here. Tested on this machine with the Intel Arc B580 (Mesa 26.2).

## v5-shot.sh

    tools/linux/v5-shot.sh <scene.qml> <out.png> [W H]      default 2560 1440

Renders one QtQuick item through QQuickRenderControl into a QRhi texture and
reads it back, so ShaderEffect items draw. No window is mapped on any monitor.
It builds the patched harness (harness/) once into tools/linux/.build, runs the
render under `flock /tmp/hudlive-render.lock nice -n 19 ionice -c3`, prints the
harness evidence line and exits non zero when `api=software` or the frame is
flat (fewer than 32 distinct colours).

What works, measured: Qt RHI with the OpenGL backend on the `offscreen`
platform, with `DISPLAY` set. The GLX context for the unmapped offscreen
surface comes from Xwayland and nothing is shown. The evidence line reads
`api=opengl gpu=Intel Mesa Intel(R) Arc(tm) B580 ...`. The OpenGL readback is
bottom-up, so the script flips the PNG (`V5_NO_FLIP=1` keeps the raw readback).

What does not work, measured: Vulkan on the offscreen platform. Qt answers
`This plugin does not support createPlatformVulkanInstance` and QRhi rejects
the adopted instance. `V5_RHI=vulkan` keeps that path for a later Qt.

Shader packs must carry the legacy GLSL targets too. The offscreen GL context
negotiates a legacy profile, and a pack baked with only `--glsl "300 es,330"`
loads without any warning and draws nothing. Bake with

    qsb --glsl "100 es,120,150,300 es,330" --hlsl 50 --msl 12 -o x.qsb x.frag

`flat` varyings do not exist in GLSL 120, so shaders must not use them. A
ShaderEffect uniform block must list the same members in the same order in the
vertex and the fragment shader (qt_Matrix, qt_Opacity, then the properties).

Environment: `V5_ALLOW_FLAT=1`, `V5_RHI=opengl|vulkan`, `V5_NO_FLIP=1`,
`V5_TIMEOUT` seconds (default 120), `V5_GPU` (Vulkan ICD), `V5_BUILD_DIR`,
`V5_HARNESS`.

## cpu-sample.sh

    tools/linux/cpu-sample.sh <pid> <seconds> [warmup]

Percent of one core from the `/proc/<pid>/stat` utime plus stime delta, thread
count and RSS. The logic is in cpu-sample.py.

## A nested headless compositor does not work here

Hyprland 0.56.2 builds its backend list in code and its headless backend needs
a DRM allocator from another backend, so it cannot start without a logind
session. No other headless compositor (sway, weston, cage, labwc) is installed.
The real shell therefore cannot run headless with GPU rendering on this
machine today. Installing sway and running it with WLR_BACKENDS=headless would
be the cheapest route.

## Text audit

The text overlap audit is nexuslink.hud/v5/verify/audit.sh. It runs on the
software offscreen platform and needs no GPU.
