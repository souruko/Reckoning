# Handoff: Reckoning — analysis window redesign

For a Claude Code session working in **`souruko/Reckoning`** (`main`), a LOTRO plugin written
in Lua 5.1 against the Turbine UI API. Read this file first, then `REDESIGN_SPEC.md` (the
implementation plan, file by file) and `GRAPH_RESEARCH.md` (how to draw a line in this API,
with a probe checklist).

## Overview

Four changes to the post-combat analysis window, plus small passes on the live meter and the
death-cause window:

1. **The graph becomes a line-and-dot plot.** Today `UI/AnalysisGraph.lua` draws one
   13%-opacity column per bucket with a 2px cap — an area chart. It becomes two 2px polylines
   (the view's series and its counterpart) with dots on the data points.
2. **Morale becomes a background bar graph.** Today morale is a 22px lane of dots above the
   plot. It becomes 48 bars behind the series, each with a brighter 1px top edge, plus 100%
   and 50% guide lines. Only on the two views that read your own vitals (Damage taken,
   Healing taken).
3. **Self-buff tracking.** A new collapsible table under the graph: uptime %, uptime, apps,
   longest gap per self-buff, over the selected range, with a 16×16 buff icon per row. Up to
   three buffs can be "charted" — each gets a 16px lane under the plot showing its intervals
   on a rail, closed by its icon.
4. **A two-handle time-range slider** under the plot. Dragging either handle rescopes the
   whole window — KPIs, skill table, both side panels and the buff table — to that slice of
   the fight.

Plus: tabs reordered to Damage done / Damage taken / Healing done / Healing taken and centred;
Crit and Dev merged into one percentage column (which also fixes a real clipping bug, see
"Bugs found"); the skill table given the full content width; the live meter gains a 30s
sparkline; the death window marks the biggest single hit as well as the killing blow.

## About the design files

`mock/Reckoning Analyzer.dc.html` is a **design reference built in HTML**, not code to port.
Open it in a browser (it needs its sibling `support.js`; no build step, no network).

It contains two things, and the distinction matters:

- **Section `1a` / `1b` / `1c` — the redesign.** This is the target. It is interactive: drag
  the range handles, click the view tabs, click a legend swatch to hide a series, click the
  `SELF BUFFS` header to collapse, click a buff row to chart it (max 3, oldest drops out).
- **Section `0a` / `0b` / `0c` — the *current* UI, recreated from the Lua.** Geometry read out
  of `UI/Analysis.lua`, `UI/AnalysisGraph.lua`, `UI/LiveMeter.lua`, `UI/DeathCause.lua` and
  `Constants.lua`. Use it as the before-picture and as a check that a number in the spec means
  what you think. It faithfully reproduces two existing defects (see "Bugs found") — do not
  "fix" `0a`.

The mock's data is real: it was aggregated from `reference/Combat_20260819_1.txt` and
`reference/Enemy_20260819_1.txt` in the repo, so the numbers, skill names and morale curve
match what the parser actually produces for that fight.

## Fidelity

**High-fidelity.** Every colour, size and offset in the mock is deliberate and taken from (or
extends) `Constants.lua`'s `Theme`. Match the numbers. But the target is the **Turbine UI API,
not HTML** — there is no CSS, no flexbox, no border-radius, no text-overflow. Everything is an
absolutely positioned `Turbine.UI.Control` with a back colour, or a `Label`. Where the mock
uses a CSS affordance the API lacks, the spec says what to do instead; where it uses
`text-overflow: ellipsis`, Turbine labels simply clip.

Read the mock as *layout intent + exact values*, and `REDESIGN_SPEC.md` as *how it lands in
Lua*.

## The window (section `1a`)

Client area 1080×N, `Frame` chrome unchanged: 32px title bar, `WindowFill` ground, 1px border.
Left rail 200px wide (session list, unchanged). Content column starts at x=200, is 848px wide
inside 12px padding, and stacks:

| y (relative to content top) | Block | Height |
| --- | --- | --- |
| 0 | tab strip; goal line right-aligned in the same row | 30 |
| 40 | counterpart filter chips | 22 |
| 72 | 5 KPI cards, `label / value / sub` stacked, 8px gaps | 50 |
| 133 | plot | 150 |
| +4 | buff lanes, one per charted buff | 0–60 (16+4 each) |
| +6 | range slider | 16 |
| +2 | timeline labels (`MM:SS`) | 14 |
| +2 | legend + peak/low morale readout | 18 |
| +11 | skill table, full 848 width | 22 + rows×22 (min 9 rows) |
| +11 | buff section (604) + `SOURCES`/`BY TYPE` panels (233), side by side | 26 (+20 + rows×22 open) |

Total with the buff section open, 2 lanes charted and 9 skill rows: **851px**. `MAX_HEIGHT`
goes to 880.

Column widths, all inside 8px cell padding:

- Skill table, damage views: `366`→**306** skill / 110 type / 58 hits / 106 crit-dev /
  68 avoid / **88** max / **104** total = 848. Heal views drop Avoid: 336 / 156 / 58 / 106 /
  88 / 104. Max and Total are deliberately wide — a 7-figure comma-formatted number at
  `LucidaConsole12` needs ~80px, and a clipped total is the one number nobody can lose.
- Buff table: 22 chart box / 24 icon / 190 buff / 98 uptime % / 90 uptime / 74 apps /
  106 longest gap = 604.

Row treatment, both tables: 22px rows, 1px `#2a2c3a` bottom rule, and a share bar behind the
row — a rect from x=0 whose width is the row's share of the max (skill table: `total/rowMax ×
848`; buff table: `uptimePct × 604`) in an 8% tint of the series colour. That is the existing
`UI/Bar.lua`/`Row.lua` language, kept.

## Interactions

| Element | Behaviour |
| --- | --- |
| View tabs | Switch category; 2px accent underline + `#282a3d` fill on the active tab; recounts everything from the current range |
| Filter chips | `All sources` + one per counterpart; scopes the table and KPIs |
| Legend swatch/label | Toggles that series' visibility (hides all three of its Control pools) |
| Range handles | Drag either; snaps to bucket stops (48); clamps to `other handle − 1`; live-updates KPIs, tables, panels, buff stats, the plot dim overlays and the two marker verticals |
| `RESET RANGE` | Returns to full fight; dimmed and inert when already full |
| Header range chip | `FULL FIGHT · MM:SS` in dim text, or `RANGE 00:59 – 02:12 · 73s` in accent when scoped |
| `SELF BUFFS` header | Collapses the buff table; state persists in settings |
| Buff row | Toggles charted; max 3, the 4th click replaces the oldest; charted rows take the lane colour in the checkbox, icon border and name |
| Session row (left rail) | Selects a session; resets the range to full fight |

No animation anywhere. The API has no transitions and the window is a readout, not a toy.

## State

Per window: `view` (one of `done`/`taken`/`healOut`/`healIn`), `filter` (counterpart name or
nil), `rangeFrom`/`rangeTo` (bucket indices), `buffsOpen`, `charted` (ordered list of ≤3 buff
names), `hiddenSeries`. Persist `buffsOpen` and `charted` (names only — never a
`Turbine.UI.Color` — see `Settings.lua`); range and filter are per session and reset on
selection.

Data work needed on the session, which is the one real blocker: `session.agg` is aggregated at
ingest, so it cannot answer "only seconds 34–71". `REDESIGN_SPEC.md` §5 adds a compact interned
event log plus `Session:Slice(category, fromSec, toSec, who)` with a cache keyed
`cat|from|to|who`. Build and verify that first — a full-range `Slice` must match today's `agg`
totals exactly — then the UI work is mechanical.

Buff data comes from the live effect list, not the parser: `_G.lp:GetEffects()` polled at 4 Hz
while a session is open, opening and closing intervals per effect name.
**Not** combat event 17 — it carries no duration and no fade, so uptime from it would be a
guess. Details and the ignore-list in §6.

## Design tokens

All from `Constants.lua`'s `Theme.Hex` unless marked new. Nothing here is invented colour —
the new entries are tints of the existing ground and accent.

**Ground / chrome:** `#161826` page, `#212433` window fill, `#20222f` title bar + table header,
`#222534` KPI card, `#1d1f2d` plot ground (new), `#2e3140` border, `#262939` plot border /
lane rail, `#2a2c3a` row rule, `#2b2e3e` hover, `#282a3d` active tab, `#33364a` divider.

**Text:** `#e9e9ed` primary, `#a9abb8` secondary, `#8b8d9b` dim/labels, `#5c5f70` disabled.

**Accent:** `#9184d9` base, `#b5abfc` light (charted lanes, biggest-hit marker), `#d2cefd`
rates, `#e7e5fe` hover/emphasis, `#5d5294` outline, `#282a3d` tinted fill.

**Series:** damage `#c98fa8`, severe/low `#e3a3ba`, fatal `#f0b7c9`, healing `#7fb3a6` /
`#9dc7bc`.

**Morale (new):** bar `#302e21` with `#5f5936` top edge; below the 30% danger threshold
`#3f2a30` with `#7d5563`; guide lines `#3b3722` (100%) and `#302f26` (50%); label `#e6d98f`.

**Buff lanes (new):** `#9184d9`, `#b5abfc`, `#7fb3a6` in pick order. Icon tile: `#1e202d`
ground + `#3a3d4e` border when uncharted, lane colour border when charted.

**Death window:** `#251e2c` ground, `#453042` border, killing blow `#33222e` fill + `#f0b7c9`
2px left border, biggest hit `#2b2438` fill + `#b5abfc` 2px left border.

**Type:** the four fonts already in `Constants.lua` — `TrajanPro13` (window titles),
`Verdana12` (body, table cells, tabs), `Verdana10` (labels, kickers, legends), `LucidaConsole12`
(every number). Numbers are right-aligned and monospaced without exception; labels are
`Verdana10` upper-case with wide tracking. 9px/8px sizes in the mock correspond to `Verdana10`
— the API has no 8px face, so those (lane icons, sub-lines) use `Verdana10` and the mock's
sizes are a visual approximation, not a target.

**Spacing:** 12 window padding, 11 block gap, 8 cell padding, 22 row height, 4/6 micro-gaps.
No radii — nothing is rounded in this API. No shadows.

## Assets

Buff icons come from the client: `effect:GetIcon()` returns an asset id, set as a Control
background on a 16×16 control, cached per buff name at first sighting so the table and the
lanes share one lookup (§6). **The mock cannot show real icons** — it draws two-letter initial
tiles as stand-ins, sized and tinted exactly as the real Controls will be, so nothing shifts
when the art lands. No other assets; everything else is a coloured rect or a label. If you take
the sprite route for the polyline (`GRAPH_RESEARCH.md` §4) you will author ~17 `.tga` files into
`Reckoning/RESOURCES/`.

## Bugs found while measuring the current UI

Both reproduced faithfully in section `0a` — they are the before-picture, not mistakes in the
mock:

1. **The skill table's columns overflow their viewport.** `RefreshTableColumns` clamps
   `skillWidth` to a 150px floor, so the `taken` view's 8 columns total 620px inside a 594px
   ListBox and the Total column is clipped off-screen. The redesign fixes it by merging Crit
   and Dev into one `CRIT / DEV` percentage column and widening the table to 848.
2. **KPI value and sub-label overlap.** The value label is at y=18 with height 24, the sub at
   y=36 — a 6px collision. The redesign restacks the card as `label 12 / value 20 / sub 12`
   inside 50px.

## Order of work

1. `Session:Slice` + event log + cache. Nothing visible changes; verify against `agg`.
2. Graph rewrite: line plot + morale background, full-fight only.
3. Range slider wired to `Slice`; everything rescopes.
4. `Buffs.lua` polling, buff table, charted lanes, icons.
5. Tab order/centring, table columns, KPI cards, layout stack.
6. Live meter and death-cause passes.
7. Version bump in `Reckoning.plugin`, `Reckoning.plugincompendium`, `Constants.lua`
   (`Reckoning.Version`), and a player-facing `CHANGELOG.md` entry.

## Files in this bundle

- `README.md` — this file.
- `REDESIGN_SPEC.md` — the implementation plan: new tokens, the graph's Control pools with
  code, `RangeSlider.lua`, `Session:Slice`, `Buffs.lua`, the `Analysis.lua` layout numbers,
  live-meter and death-window changes, and the order of work.
- `GRAPH_RESEARCH.md` — how to draw a line in this API: four techniques with costs, the
  undocumented `SetRotation` finding (evidence in `souruko/Gibberish3`, and its two traps), the
  `Turbine.UI.Graphic` one-control-at-a-time constraint, the Overlay-blend tinting trick, and a
  seven-item probe checklist before committing to rotation.
- `mock/Reckoning Analyzer.dc.html` + `mock/support.js` — the interactive design reference.
  Open the HTML directly in a browser.
- `source-repo.md` — repo, branch and the screen-to-source-file map the mock was built from.
