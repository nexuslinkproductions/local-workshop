# tools/linux/env: the background slot proofs and the hall converter (E1)

Files
- `r2qt.py`: converts the s6 hall fragment shader (`s6/r/src/r.frag`, WebGL GLSL) into the Qt
  environment fragment shader. Only the text between the `// SHADE-BEGIN` and `// SHADE-END`
  lines of `nexuslink.hud/v5/live/shaders/env.frag` changes; every other line is kept.
- `env-proof.py`: the proofs. `plain` = plain base and three-origin grid stitch. `hall` = the
  converted hall rendered and compared with `r-bg-only.png` and `r-panorama.png`.
- The plugin side is `nexuslink.hud/v5/live/Environment.qml`, `shaders/env.vert`, `shaders/env.frag`,
  `shaders/env-bake.sh` and the baked `.qsb` files.

Drop a new shade() in (the hall is the first case; the steps are the same for any shader)
1. Write the design as WebGL-style GLSL with the s6 names: `ORG`, `R`, `PAR`, `T`, `LINK`, `AI`,
   `BAY[6]`, `DISK[2]`, `gl_FragCoord`, `gl_FragColor`, `void main()`. Anything else is an error.
2. Convert into scratch (never the plugin folder):
   `python3 tools/linux/env/r2qt.py <file.frag> nexuslink.hud/v5/live/shaders/env.frag <scratch>/env-new.frag`
   Exit 0 prints the rule counts. Exit 1: an unknown uniform, an unconverted gl_ name, or a
   missing or doubled SHADE marker. Nothing is written on failure.
3. Bake the converted copy: `FRAG=<scratch>/env-new.frag nice -n 19 ionice -c3 nexuslink.hud/v5/live/shaders/env-bake.sh`
   (writes `<scratch>/env-new.frag.qsb`, same qsb flags as bake.sh).
4. Prove it: `python3 tools/linux/env/env-proof.py hall nexuslink.hud/v5/live <scratch>/run <r.frag> <s6/r>`
   (renders under `flock /tmp/hudlive-render.lock`).
5. Only when the design is accepted: copy the converted file over `shaders/env.frag` and run
   `shaders/env-bake.sh` in the plugin. Until then the plugin ships the plain base.

Conversion rules (in `r2qt.py`)
- `uniform ORG, R, PAR, T, LINK, AI` are removed; the template `#define`s map them to the block
  members `origin`, `itemSize`, `par`, `t`, `link`, `ai`.
- `BAY[i]` becomes `bayAt(i)` (template helper over `bayA` and `bayB`); `DISK[i]` becomes `disk[i]`.
- `gl_FragCoord` becomes `qtFragCoord()`, which folds in the global origin: the s6 line
  `vec2 p = vec2(ORG.x + gl_FragCoord.x, R.y - gl_FragCoord.y)` gives the global pixel for any origin.
- `gl_FragColor` becomes `qtColor`; `void main()` becomes `void hallMain()`, called from `shade(P)`.
- `precision` statements are dropped; the GLSL 4.40 keyword `patch` is renamed `hall_patch`.

What the host (HudV4 / DeckMain) must set on each Environment
- `origin`: the output's global top left (ShellScreen x, y). `world`: the bounding box of all
  outputs (a JS binding over Quickshell.screens, no timer). Item size: fill the output.
- `t`: only when a shader moves (a constant t draws once). `par`, `link`, `ai`, `bayA`, `bayB`,
  `disk`: live data, written on change. `running`: false hides the effect.
- `debugGrid`: false in production; true only for the stitch proof.
- `objectName`: the output name, used only in the load evidence line.
- Keep an opaque base Rectangle under the Loader, so a load failure never shows a transparent hole.

Proof numbers and how to read them: see work5/E1/REPORT.md. Needs python3 with Pillow.
