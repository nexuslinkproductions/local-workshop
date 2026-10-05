# NEXUS HUD — Premium Design Pass

**Scope:** visual direction and implementation-ready tokens for `candidates/HudFinal.qml` (5,504 lines). This is a design-system pass, not a code patch. Preserve the dark cyberpunk/synthwave identity and the existing cyan / magenta / green / amber semantics; remove the “everything is a neon instrument” treatment so the data, not the decoration, owns the hierarchy.

**Design intent:** *precision instrument, not arcade cockpit*. Keep the dark plate, controlled chroma, telemetry motion, and one unmistakable reactor focal point. Make typography, spacing, and restraint carry the premium feel.

## 1. Typography

### Current state

`HudFinal.qml` routes its reusable `TLabel` through `Style.font.family` (1140–1143), but the file does not select a concrete family. The visible system therefore inherits an external style default; the file’s own comment calls it “monospace” (1137–1143). Most operational labels, values, and titles share that same face. Many recurring text sizes are 7–11 px (for example row labels/values at 1164–1212, SparkBox at 1652–1665, and list rows at 1926–1964), and the title treatment uses 11 px bold with 2.2 px tracking (1438–1444). At `ux < 1`, those sizes shrink further. That combination reads cramped and technical in the cheap sense, rather than deliberate and legible.

### Ship with the installed families

| Role | Family | Size at `ux = 1` | Weight | Rules |
|---|---|---:|---:|---|
| Screen masthead / settings title | **Adwaita Sans** | 16 px | 600 / SemiBold | Use normal title case. Reserve accent color for the product name, not the full line. |
| Panel headers | **Adwaita Sans** | 13 px | 600 / SemiBold | Sentence case; `letterSpacing: 0.4 px`. No leading decorative glyph in the title string. |
| Section labels / control labels | **Adwaita Sans** | 11 px | 500 / Medium | Sentence case; `letterSpacing: 0.2 px`. All caps only for short status tokens (e.g. `GPU`, `IO`, `RX`). |
| Explanatory / list text | **Adwaita Sans** | 12 px | 400 / Regular | Keep full words and use secondary alpha for supporting text, not tiny type. |
| Telemetry values / units / timestamps | **JetBrainsMono Nerd Font** | 13 px | 500 / Medium | Keep units attached with a standard space (`62 %`, `145 W`); align numeric columns on their right edge. |
| Compact secondary data | **JetBrainsMono Nerd Font** | 11 px | 400 / Regular | Use only for inline metadata, timestamps, and secondary values. Do not use for long descriptions. |
| Panel hero metric | **JetBrainsMono Nerd Font** | 36 px | 600 / SemiBold | One dominant value per hero panel. Avoid text glow. |
| Reactor center value | **JetBrainsMono Nerd Font** | 22 px | 600 / SemiBold | Fixed-width numerals keep the clock/value stable as it changes. |
| Micro metadata (rare) | **Adwaita Sans** | 9 px | 500 / Medium | Hard minimum: 9 px at rendered size; decorative only, never the sole label for a control or metric. |

**Scale rule:** multiply display sizes by `ux` only down to these rendered minimums: 9 px for micro metadata, 11 px for labels, 12 px for body/data, 20 px for the reactor value, and 26 px for a hero. If the panel cannot fit those minimums, remove secondary copy or wrap the content; do not compress the type. For accessibility, allow OS text scaling to increase these values without clipping.

**Weight rule:** regular (400) for prose; medium (500) for data and labels; semibold (600) for panel headings and primary metrics; bold (700) only for a transient alert or a single high-priority number. Do not set every label to bold.

**Casing and tracking:** use sentence case for panel names and controls (`Core matrix`, `Repo activity`, `Ambient shader`). Keep all caps only for short, conventional telemetry abbreviations or explicit machine states. Do not uppercase whole hostnames or long labels. Header tracking is 0.4 px, labels 0.2 px, micro labels 0.6 px; remove the current 1–3 px tracking from normal text. Never use tracking to make tiny text appear “futuristic.”

### Optional installed-font upgrade

The installed pairing above is the default and requires no font install. If a single, stronger UI family is desired, **[needs install] Inter** is the practical upgrade for headers, controls, and explanatory text; retain JetBrains Mono for telemetry. Arch package: **`inter-font`** (`pacman -S inter-font`, Extra repository). Inter has a broader UI weight ladder and is tuned for interface legibility.

Other candidates, not the default recommendation:

- **[needs install] Space Grotesk** — package target `otf-space-grotesk` (AUR). It can add a distinctive display voice to the masthead only; it is not a reason to change data text or add more caps/tracking.
- **[needs install] Oxanium** — package `ttf-oxanium` (AUR). Its futuristic geometry reinforces the exact “cheap cyberpunk” risk in the critique; do not use it for the operational UI.
- **[needs install] Geist Mono** — package target `ttf-geist-mono` (AUR). It is a viable mono, but it is not a material readability upgrade over installed JetBrains Mono Nerd Font, so do not add a dependency for it.

Font Awesome 7 should supply icons as icons, not as substitute text characters. Do not mix several Unicode symbol styles in headings. `Adwaita Mono`, `Noto Sans Mono`, and the installed iA Writer Mono variants remain reasonable fallbacks, but they do not improve the proposed two-family pairing.

## 2. What makes it read “cheap”

These are source-level findings, not a claim about runtime rendering. The theme has good raw ingredients; the issue is that nearly every ingredient is turned up at once.

1. **Every panel gets the same overworked bezel.** The shared `CPanel` paints a chamfered face, accent gradient, scanlines every 3 px, inner highlight, bottom shade, full outline, second diagonal accent, and then separate corner brackets (1291–1381, 1398–1410). Repeating all of these on every card makes the interface look like a kit of identical sci-fi boxes. **Remove per-panel scanlines and double accents; retain one quiet surface, one hairline, and one small identifying accent.**
2. **Outline and edge color are too uniformly loud.** Expanded panels use the full panel accent at alpha 1.0 for the perimeter, plus a 1.6 px accent diagonal at alpha 0.9 (1360–1380). The global frame adds two nested outlines, corner brackets, and edge index ticks (3054–3107). The result is a neon wireframe around nearly every object, so nothing is visually primary.
3. **Headers are both tiny and over-tracked.** Panel titles are 11 px bold with 2.2 px letter spacing (1438–1444), the main plate reaches 3 px tracking (3147–3171), and long settings section labels use 1.6 px at 8.5 px (5351–5355, 5405–5410). This sacrifices useful word shape and makes the UI feel like a game overlay. **Use a real UI sans, 13 px headers, and sub-1 px tracking.**
4. **Operational text is too small for a three-monitor dashboard.** Common labels and values sit at 7–10 px (HudRow 1164–1212; traces 1652–1665; windows rows 1926–1964; controls 5330–5335). Since the interface scales with `ux`, the smallest output makes already-small text smaller. A HUD is still a reading surface: raise the baseline and remove redundant microcopy before shrinking type.
5. **The visual hierarchy is mostly hue, not size or weight.** Cyan, green, magenta, and amber are used for titles, values, bars, edges, and focus states; `cTxt` and `cMuted` are the only neutral text levels (101–111). Labels, telemetry, and control names often have similar size and contrast. Use neutral text for most content, reserve hue for metric meaning/state, and establish clear 100 / 70 / 50 / 35% text levels.
6. **Unnecessary glow makes the two important readouts look less expensive.** The NEXUS masthead pulses a shadow (3147–3159), the 36 px CPU value has a pulsing shadow (3273–3285), and the reactor clock has another pulsing shadow (3638–3652). The entire dial also has orbiting tick marks, a comet, glowing arc passes, and two rotating dashed rings (3478–3573, 3577–3620). The competing effects dilute the focal point and create constant motion. Keep glow for alert feedback and at most one static hero accent; simplify the dial motion.
7. **Rows and chips repeat borders and fills too aggressively.** Bars have a bordered 5 px track plus gradient fill and a white hot cap (1171–1200); rows/chips add filled backgrounds and borders for hover/active states (1790–1816, 1907–1916, 1847–1856). Multiple borders around nested elements add clutter at this scale. Use a quiet track and a single selected/hover cue, not a miniature bezel for each row.
8. **Decoration leaks into empty and configuration states.** The empty sensor/peripheral states are one-line dash-wrapped text at 9 px (4085–4089, 4453–4458), while the settings sheet repeats frame brackets, 1 px separators, tiny section labels, and bordered chips (5220–5256, 5295–5355, 5348–5460). Empty state should look intentional and calm; settings should read like a standard utility surface, not another cockpit panel.

## 3. Premium system — tokens

### Color and surface tokens

Keep the existing semantic accents: cyan `#00e5ff`, magenta `#ff2bd6`, green `#39ff14`, amber `#ffb300`, alert `#ff3b4e`. They are status/data colors, not default decoration colors. Keep the existing dark base `#040e16`.

| Token | Concrete value | Use |
|---|---|---|
| `canvas` | `#040e16` | Screen base / deepest layer. |
| `panel` | `rgba(7,18,28,0.96)` | Primary panel face; stable, nearly opaque. |
| `panel-raised` | `rgba(11,25,36,0.98)` | Settings sheet and one active floating surface. |
| `inset` | `rgba(2,9,15,0.72)` | Meter tracks, graph plot area, recessed fields. |
| `hover-wash` | Accent at `0.07` alpha | Hover only; no border change required. |
| `selected-wash` | Accent at `0.13` alpha | Selected chip/tab/active row. |
| `disabled-wash` | Neutral at `0.035` alpha | Disabled/idle chip fill. |
| `scrim` | `rgba(1,7,12,0.68)` | Modal settings background. |
| `hairline` | `rgba(137,178,192,0.22)` | Default panel and separator line. |
| `divider` | `rgba(137,178,192,0.14)` | Within-panel grouping only. |

Do not put a colored gradient on every panel. Each panel may have **one** 2 px accent rail or one 2 px active marker. Use the active semantic color at 100% only for current value/alert indicator; all other accents are 35–70% opacity.

### Text alpha hierarchy

Apply four deliberate levels to the neutral text color `#d7e8ed`:

- **100%** — primary values, active selection, current clock.
- **70%** — labels, row names, panel headings, action text.
- **50%** — units, timestamps, explanatory captions, secondary facts.
- **35%** — disabled text, inactive legends, nonessential metadata only.

Never use 35% for actionable text, a required axis/series label, or a value. Semantic warning text stays at 100% of its semantic color; do not make alerts depend on hue alone.

### Geometry and spacing

- Base grid: **4 px**. Allowed spacing tokens: **4 / 8 / 12 / 16 / 20 / 24 px**. Use 8 px for row rhythm, 12 px between groups, and 16 px internal padding for a full-size panel; use 12 px internal padding only for genuinely compact strips.
- Panel radius: **6 px**. Settings sheet radius: **8 px**. Chips and list-row hover surfaces: **4 px**. Meter track radius: **2 px**. No bevel plus chamfer plus corner brackets on one element. If the outer HUD retains angular corners, use one chamfer style on the screen frame only; panel cards stay rounded.
- Standard panel outline: **1 px** hairline at 22% neutral alpha. Active panel marker: **2 px** accent rail, never a second full perimeter. Use **2 px** outline only for keyboard focus or a selected control.
- Screen frame: one **1 px** outline at 35% accent alpha. Drop the default nested frame, brackets, and mid-edge ticks; show an alert halo only while alert is active.
- Dividers: **1 px** at 14% neutral alpha, with **12 px** vertical breathing room above/below. No full-width decorative separator after every settings row.

### Glow rules

1. No glow on small labels, normal values, list rows, borders, or chips.
2. The reactor may use one soft static halo behind the primary value: accent alpha **0.08**, blur radius **12 px**; no pulsing opacity.
3. Active alert may use a **2 px** outer halo at **20%** alpha, pulsing once over **1.8 s** only while the alert state is present. Do not pulse the text itself.
4. A live data arc may have one under-stroke at **18%** accent alpha and **2×** the core stroke width. Do not add a second glow pass or moving comet.

### Meters and traces

- Meter track: **4 px** high, `inset` fill, no outline; radius **2 px**.
- Meter fill: solid semantic color at 100% for the active segment; no left-to-right gradient. Add a **2 px** end cap only if it improves precise reading, at 70% white—not a glowing white hot tip.
- Animate fill only when the value changes; minimum visual change threshold **0.5 percentage point**. A missing value shows an empty track and `—`, not a falsely zeroed fill.
- Standard sparkline plot area: no border; grid at **8%** neutral alpha with only a baseline and two vertical reference guides. Trace core: **1.5 px** at 90% series color; optional fill-under-trace at 6%. Keep the newest endpoint static (no comet). For RX/TX, use two distinct lanes and a 12% divider, not a bright mirrored center line.
- Keep units and the current value outside the plot in 12–13 px mono. A trace never replaces a readable numeric value.

### Empty states

- Reserve a stable **48 px** minimum body area so a panel does not collapse into an awkward hole.
- Use one calm sentence in 12 px Adwaita Sans at 50% text alpha, left aligned. Optional 16 px icon at 35% alpha; do not put the sentence between decorative dashes.
- Distinguish absent data from zero: `No auxiliary sensors reported` / `No wireless peripherals reporting`; for collector startup use `Waiting for process samples…`. Keep controls and headings at their normal contrast.

## 4. Panel-level recipes

### Hero stat (SYSTEM / main CPU)

- Set one hero metric to **36 px** JetBrains Mono 600; retain a stable width for up to three digits plus `%`.
- Place its label at **11 px** Adwaita Sans 500 / 50% text alpha, and its supporting facts at **12 px**; do not make the supporting facts another competing accent headline.
- Use neutral white for the value under normal conditions; apply cyan/amber/red only at defined thresholds. Remove the CPU text shadow.
- Give the stat block **12 px** below/above breathing room; align the value and the supporting column to a shared vertical center.
- Keep the mini load trace below as secondary context; it uses a **1.5 px** line and does not receive its own panel bezel inside the hero panel.

### Sensor sheet

- Keep one compact, consistent row structure: 12 px label at 70%, 13 px right-aligned mono value at 100%, optional 4 px meter beneath only when a fraction is meaningful.
- Use **8 px** vertical row gap and a **12 px** group gap between sensor families (thermal, power, PSI); group titles are 11 px medium at 50% alpha.
- Show threshold color only on the value and meter fill; remove accent-colored cell borders and background fills from every sensor tile.
- For empty state, maintain 48 px minimum body height and use the one-line 12 px empty-state recipe above.
- For high-density details, wrap the value or abbreviate a unit consistently; do not lower type below 11 px to force it onto one line.

### List rows (windows, processes, repos, sessions)

- Use **32 px** standard row height; use **36 px** only where two text lines are genuinely needed. Separate rows by 1 px divider at 14% neutral alpha.
- Primary row name is **12 px** Adwaita Sans 500 at 100%; title/detail/host metadata is **11 px** at 50%. Numeric columns are **12 px** JetBrains Mono, right aligned.
- Show workspace/kind/status as a compact **4 px-radius** text badge with selected wash and no permanent box outline. Use one status marker (dot or short rail), not badge + row tint + border simultaneously.
- Hover uses a **7%** cyan wash with no full border; selected row uses a 2 px leading rail and **13%** wash. Keep row height and text position fixed during state changes.
- Preserve elision on untrusted long names, but expose the full value through an accessible tooltip if the runtime supports it.

### Chips and toggles

- Standard chip height **28 px**, horizontal padding **10 px**, corner radius **4 px**; minimum pointer target **32 px** high where practical.
- Label is **11 px** Adwaita Sans 500 with 0.2 px tracking. Remove bold/uppercase on every chip; use concise title case except conventional modes like `15 Hz`.
- Idle chip has transparent/inset fill and no visible border (or a 1 px hairline at 22%); hover gets a 7% wash; selected gets a 13% wash and 2 px lower marker. Only one cue changes between states.
- Use a Font Awesome 7 icon at **12 px** only when it clarifies the action; maintain a 6 px icon/text gap. No decorative glyph before every word.
- Keep color semantics limited to selected/urgent state; never assign a different saturated accent to each neighboring action.

### Reactor dial

- Keep the dial as the single visual centerpiece and give it open breathing space; remove its enclosing repeated bezel.
- Draw one primary **3 px** 270° arc (CPU) and at most two secondary arcs at **1.5 px** (GPU power and memory), each with an inset track at 20% neutral alpha. Use 12 major ticks at 18% alpha; remove the 48-tick orbit and duplicate dashed rings.
- Center the **22 px** mono value/time at 100% neutral, with an 11 px label at 50%. If the center is the clock, keep the current clock format and put host/role context outside the dial instead of uppercasing the hostname around it.
- Data arcs ease with telemetry; no continuously rotating comet or rotating tick ring. A single short-lived endpoint cue may travel only during a value transition and must stop within **240 ms**.
- Use the one 8%-alpha static halo rule; reserve the alert halo for an active alert. Keep semantic colors stable and label each arc directly or with a clear nearby legend.

### Traces

- Keep trace labels and live values at **11 px** / **12 px**, respectively; unit/value always stays outside the plot.
- Use a flat, quiet plot with only the baseline plus two guide lines at 8% alpha. Remove top/bottom bright edges, quarter grid, and input-port marker (1589–1609).
- Draw one 1.5 px series line at 90% opacity; dual RX/TX uses green and cyan at 85% with a 12% neutral divider. Avoid magenta as a second series unless it identifies a different metric.
- Fill under a trace only at 6% alpha and only for the hero trace. No glow stack, flashing endpoint, or animated grid.
- Keep the history window and autoscale behavior; animate data transitions but keep the chart frame, guides, labels, and baseline still.

### Settings sheet

- Use an **8 px-radius** raised surface, 1 px neutral outline at 22%, and **20 px** internal padding. Remove the matching corner brackets; the sheet is a utility dialog, not a fourth frame.
- Title is **16 px** Adwaita Sans 600; group headings are **12 px** 600 at 70%, with **16 px** between groups. Use 1 px 14%-alpha dividers only between major groups.
- Make controls at least **32 px** high. Use the standard chip/toggle recipe, provide text labels for swatches, and show selection with marker + wash rather than a 2 px colored outline and a colored full fill.
- Keep explanatory hint copy at **11 px** and 50% alpha. If the sheet does not fit, let the sheet content scroll; do not shrink text to fit.
- Scrim uses `rgba(1,7,12,0.68)`. Clicking the scrim closes it; focus/hover/selected states stay distinguishable without glow.

## 5. Micro-animation language

Motion should clarify state change, not continuously advertise that the interface is alive. Maintain the shared clock/data model but remove ambient movement from static UI.

| Motion | Duration | Easing / behavior |
|---|---:|---|
| Hover wash / focus color | **120 ms** | `OutCubic`; color/opacity only, no size/position movement. |
| Chip press feedback | **90 ms** | `OutCubic`; selected marker appears, no bounce. |
| Telemetry value and meter | **220 ms** | `OutCubic`; follow eased data. Skip changes below the 0.5-point visual threshold. |
| Trace sample transition | **220 ms** | Linear sample age/scroll; ease the incoming sample, not the plot grid. |
| Panel collapse/expand | **180 ms** | `InOutCubic`; clip body and preserve header position. |
| Panel reflow after drag | **220 ms** | `OutCubic`; no spring/overshoot. Direct drag remains pointer-led. |
| Settings open/close | **160 ms** | `OutCubic` fade plus 8 px translate; reverse on close. |
| Alert pulse | **1.8 s** cycle | Soft opacity pulse, alert-only, one surface; stop immediately when clear. |

**What may move:** values and fills when telemetry changes, trace samples as time advances, a panel during a user drag, a short reflow after drag, and a restrained active-alert indicator. The reactor’s data arcs may ease as telemetry updates.

**What must stay still:** panel edges, scanlines, grid guides, dial tick marks, ordinary labels, idle values, and all decorative ornaments. Remove the perpetually orbiting tick ring, comet, rotating dashed rings, background scan sweep, and regular cursor-like blinking. Avoid continuous breathing on healthy/idle status.

Honor reduced-motion settings: disable the alert pulse and nonessential transitions, draw each value/trace at its current state immediately, and retain direct user drag. Visibility/collapsed panels must not animate or repaint offscreen. No motion should be required to understand a warning or selection.

## Implementation priority

1. Replace the inherited single-family treatment with the installed Adwaita Sans + JetBrains Mono pairing and establish minimum readable rendered sizes.
2. Simplify `CPanel` and screen-frame drawing to one surface, one quiet hairline, and one accent cue.
3. Rebalance text alpha, reduce caps/tracking, and normalize row/chip typography.
4. Quiet the traces and dial; keep motion only on changing data and explicit interactions.
5. Bring settings and empty states onto the same surface/spacing/type tokens.
