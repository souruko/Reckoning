# Reckoning — redesign spec (Lua side)

Companion to `Reckoning Analyzer.dc.html` (design doc: `1a` redesigned analysis window,
`1b` live meter, `1c` death cause; `0a–0c` are the current UI recreated from source).
Everything below is expressed against the files as they stand at `main` (`Constants.lua`,
`Session.lua`, `UI/Analysis.lua`, `UI/AnalysisGraph.lua`).

Four changes: (1) the graph becomes a line-and-dot plot, (2) morale becomes a background bar
graph, (3) self-buff tracking with its own table, (4) a two-handle time-range slider that
rescopes the whole window.

---

## 1. Constants.lua — new tokens

```lua
-- morale as a background bar graph (AnalysisGraph): fill + a brighter 1px top edge, so a bar
-- reads as a bar and not as a wash. Two pairs: normal, and below the danger threshold.
Theme.Hex.MoraleBg      = "#302e21"
Theme.Hex.MoraleBgEdge  = "#5f5936"
Theme.Hex.MoraleBgLow   = "#3f2a30"   -- morale < MORALE_DANGER
Theme.Hex.MoraleBgLowEdge = "#7d5563"
Theme.Hex.MoraleGuide   = "#3b3722"   -- 100% guide line
Theme.Hex.MoraleGuideMid= "#302f26"   -- 50% guide line
Theme.Hex.RangeDim      = "#161826"   -- out-of-range plot wash, mixed at ~0.72 over PlotFill
Theme.Hex.PlotFill      = "#1d1f2d"   -- the plot now has its own recessed ground
Theme.Hex.PlotBorder    = "#262939"
-- buff lane colours, in pick order (max 3 charted at once)
Theme.BuffLane = { "#9184d9", "#b5abfc", "#7fb3a6" }
```

`MORALE_DANGER = 0.30`. No new fonts.

---

## 2. UI/AnalysisGraph.lua — line plot instead of area columns

> Technique research, alternatives and the `SetRotation` probe: `GRAPH_RESEARCH.md`.
> What follows is Option A from that document — the one with no unknowns.

The current file draws, per bucket, a 13%-opacity column plus a 2px cap. Replace with a real
polyline built from axis-aligned Controls. Three pools per series, all sized once in
`BuildSeries()` and only ever repositioned:

| Pool | Count | Size | Role |
|---|---|---|---|
| `dots[slot][i]` | 48 | 5×5 | the value marker at bucket *i* |
| `hSeg[slot][i]` | 47 | `bucketWidth`×2 | horizontal run between *i* and *i+1* |
| `vSeg[slot][i]` | 47 | 2×`abs(dy)` | vertical riser between *i* and *i+1* |

Drawing one segment (this is the whole trick — a diagonal is not drawable, so each step is
drawn as an L: horizontal at the *midpoint* height, riser between the two):

```lua
local function Step(hSeg, vSeg, x0, y0, x1, y1, colour)
	local yMid = math.floor((y0 + y1) / 2)
	hSeg:SetPosition(x0, yMid)
	hSeg:SetSize(x1 - x0, 2)
	hSeg:SetBackColor(colour)
	hSeg:SetVisible(true)

	local top = math.min(y0, y1)
	local h = math.abs(y1 - y0)
	vSeg:SetPosition(x1 - 1, top)          -- riser sits on the *right* end of the run
	vSeg:SetSize(2, math.max(2, h))
	vSeg:SetBackColor(colour)
	vSeg:SetVisible(h > 0)
end
```

Notes that matter in-game:

- **Draw order:** morale background → guide lines → risers → horizontal runs → dots →
  range dim/markers → hover zones. Set `SetZOrder` explicitly per pool (10/11/12/13/20);
  do not rely on creation order once pools are reused across views.
- The riser at the midpoint height is what makes the trace read as a line rather than a
  staircase; with 48 buckets over ~640–1200px the steps are 13–25px wide, which at 2px
  stroke reads as a line at normal viewing distance. Do **not** try to subdivide further —
  more Controls per bucket is the one thing `docs/IMPLEMENTATION_PLAN.md`'s performance note
  rules out.
- Dots every bucket at 48 buckets is noisy: draw a dot on **even** indices only (`i % 2 == 0`)
  plus always on the range endpoints. Hide the rest.
- Keep `MAX_REGULAR_SERIES = 2`. Pool total per graph: 2×(48+47+47) = 284 Controls for the
  series, 96 for morale, 48 hover zones — all created once in the constructor, never rebuilt.
- `CAP_HEIGHT`, `AREA_OPACITY` and the whole `columns`/`caps` pool are deleted.
- The morale lane (`MORALE_LANE_HEIGHT`, `moraleLaneLine`, `moraleDots`) is deleted — morale
  moves to the background (§3), so `barAreaHeight` is now the full plot height minus a 22px
  headroom band at the top (`TOP_PAD = 22`) so a peak bucket never touches the frame.
- Legend swatch/label click still toggles a series (`ToggleSeries`); when a series is hidden,
  hide all three of its pools.

## 3. Morale as a background bar graph

Two pools of 48 (`moraleBar[i]`, `moraleEdge[i]`) plus two guide lines and two right-edge
labels. Per bucket, from `bucket.moralePct` (already sampled in `Session:AddTaken`):

```lua
local h = math.max(1, math.floor(pct * (PLOT_HEIGHT - 2)))
local low = pct < MORALE_DANGER
bar:SetPosition(math.floor((i - 1) * bw) + 1, PLOT_HEIGHT - 1 - h)
bar:SetSize(math.max(1, math.floor(bw) - 2), h)
bar:SetBackColor(Theme.Color(low and Theme.Hex.MoraleBgLow or Theme.Hex.MoraleBg))
edge:SetPosition(bar x, PLOT_HEIGHT - 1 - h)      -- 1px, same width as the bar
edge:SetBackColor(Theme.Color(low and Theme.Hex.MoraleBgLowEdge or Theme.Hex.MoraleBgEdge))
```

- Buckets with no sample (`moralePct == nil`) **carry the previous bucket's value forward**
  rather than dropping to zero — a second in which you took no damage is not a second at 0
  morale. Track `lastKnown` while filling `moraleBySlice` in `SetData`.
- Guide lines: 1px at `y = 1` (100%) and `y = floor(PLOT_HEIGHT/2)` (50%). The top line
  carries one right-aligned `Verdana10` label in `Theme.Hex.Morale` — `MORALE <peak>`, the
  session's **highest morale value in points** (`max(bucket.moralePct) × lp:GetMaxMorale()`,
  `Format.Number`), session-wide and not rescoped by the range slider, so the axis stays a
  fixed reference while the range moves. The 50% line is unlabelled — it is a reading aid, and
  a second number there only competed with the peak. `showMorale` stays as a per-view flag and
  keeps its current
  meaning — morale is *incoming* context, so it draws on `taken` and `healIn` only. On
  `done` and `healOut` the bar pool, guide lines, right-edge labels, legend entry and the
  peak/low readout are all hidden and the plot ground is empty behind the line.
- The legend gains a non-interactive third entry, `MORALE (background)`, and the right end of
  the legend row prints `peak morale N% · low N%` **for the selected range** (replacing the
  old `MORALE (peak N%)` axis label).

## 4. UI/RangeSlider.lua (new) — two-handle time range

A `Turbine.UI.Control`, `plotWidth × 16`, sitting between the plot and the timeline labels.

```
Frame:  track      1px, full width,  Theme.Hex.Border
        selected   2px, from a to b, Theme.Hex.Accent
        handleA/B  9×16, WindowFill fill + 1px Accent border, mouse-visible
```

- Drag: `MouseDown` on a handle stores which handle and the press offset; `MouseMove` on the
  **handle** (same pattern as `Frame:WireDrag`, which re-reads `args.X` every move) converts
  x → fraction → bucket index, clamps to `[0, other handle − 1]`, and calls
  `self.OnChange(fromBucket, toBucket)`; `MouseUp` clears the drag.
- Snap to buckets (48 stops), not pixels: that keeps re-aggregation cheap and makes the
  numbers in the window agree with the plot exactly.
- Also draw, on the graph itself: two 1px accent verticals at the handle positions, and two
  dim overlays (`Theme.Mix(RangeDim, PlotFill, 0.72)`) covering `[0,a)` and `(b,width]`.
  These are Controls owned by `Graph`, updated from the same callback.
- Header shows `RANGE 00:59 – 02:12 · 73s` in `Accent300` while a range is active,
  `FULL FIGHT · MM:SS` in `DimText` when not, next to a `RESET RANGE` label-button
  (dimmed and inert when already full).
- Range is **per window, not per session**: selecting another session in the rail resets to
  full fight (the bucket count is the same but the seconds behind it are not).

## 5. Session.lua — range-scoped aggregation

The blocker: `session.agg` is aggregated at ingest, so it cannot answer "only seconds 34–71".
Buckets hold per-second *totals* but no per-skill breakdown. Add a flat event log and
re-aggregate on demand.

```lua
-- Session:Constructor
self.events = {}   -- append-only; one compact record per accepted event
self.strings = {}  -- interning table: name/skill string -> integer id
self.stringList = {}
```

`Intern(s)` returns an id (and stores the reverse lookup). Each ingest method appends one
record alongside what it already does (aggregates stay — they are still the fast path for the
full-fight case):

```lua
-- cat: 1 done, 2 taken, 3 healOut, 4 healIn
self.events[n + 1] = {
	s = math.floor(t - self.startTime),  -- second offset, the same key buckets use
	c = cat, sk = Intern(skill), ty = dmgType or 0, w = Intern(who),
	a = amount, cr = critType, av = avoidType,
}
```

Cost: a 2-minute fight in the reference captures is ~350 accepted events → ~350 small tables,
built once at ingest, never touched per frame. The 10-session ring caps total memory.

```lua
-- Rows + stats for one category over [fromSec, toSec], optionally one counterpart.
-- Returns the same row shape Analysis:TableRows already consumes, so the table/panel code
-- does not change: { skill, type, who, hits, total, max, crits, devs, avoided, avoidBreakdown }
function Session:Slice(category, fromSec, toSec, who)
```

- Cache the result on `self._sliceCache[category .. "|" .. fromSec .. "|" .. toSec .. "|" .. (who or "*")]`
  and clear that cache in `Touch()` (i.e. whenever new events land, which only happens while
  the session is live). Switching views or re-selecting the same range stays a redraw.
- `Total`, `Rate`, `HitStats`, `ActiveSeconds` gain the same optional `fromSec, toSec` pair;
  when both are nil they take the existing full-fight path unchanged.
- Active seconds inside a range = count of `_activeSeconds` keys within it, so DPS in a range
  is still "total ÷ seconds you were actually acting".
- `Analysis:RefreshContent()` calls `Slice` once per refresh and feeds KPIs, table, both side
  panels **and** the buff table from it. One recount per interaction, not one per widget.

## 6. Buffs.lua (new) — self-buff tracking

Data source is the live effect list, not parser event 17 (event 17 carries no duration and no
fade, so uptime from it would be a guess):

```lua
local effects = _G.lp:GetEffects()        -- Turbine.Gameplay.EffectList
for i = 1, effects:GetCount() do
	local e = effects:Get(i)
	local name = e:GetName()
	-- e:GetIcon() is available if buff icons are wanted later
end
```

- Poll at **4 Hz** from the existing `Update()` throttle (`REFRESH_INTERVAL` pattern in
  `LiveMeter`), only while `Sessions.current ~= nil`. 4 Hz is enough for a table that reports
  whole-second uptime and keeps the per-tick cost to one list walk.
- Per poll: build a name set; for a name newly present open an interval
  `{ s = now - session.startTime }` and bump `apps`; for a name that disappeared close it
  (`e = now - startTime`). On session close, close every open interval at `endTime`.
- Store on the session: `session.buffs = { [name] = { intervals = {...}, apps = n } }`.
  Only effects on the local player are ever read, so this stays inside the plugin's
  "local player only" scope (`docs/DESIGN.md` "Scope").
- Filter list: skip effects whose name matches the tracked-out set (travel skills, mounts) —
  ship a small `Buffs.Ignore` table, user-extensible via `/reck buffs ignore <name>`.
- Derived per range `[t0, t1]` (clip every interval to the range first):
  - `uptime` = Σ clipped lengths; `uptimePct` = uptime ÷ (t1 − t0)
  - `apps` = intervals *starting* inside the range
  - `longestGap` = largest uncovered stretch inside the range, including the head and tail
    gaps (a buff that dropped at the end and never came back is exactly what this column is
    for)
- Persist `settings.buffsOpen` and `settings.chartedBuffs` (a name list, max 3) so the
  section and the charted lanes survive a reload. Strings only — no `Turbine.UI.Color` in
  settings (`Settings.lua`).

## 7. UI/Analysis.lua — layout changes

```lua
local TAB_STRIP_HEIGHT = 30      -- unchanged; the goal line now lives in this row, right-aligned
local GRAPH_HEIGHT     = 150 + 4 + 22 + 16 + 14 + 18   -- plot, lane gap, lanes, slider, timeline, legend
local BUFF_HEADER_H    = 26
local BUFF_ROW_H       = 22
local MAX_WIDTH, MAX_HEIGHT = 1440, 880   -- was 1440, 800: the expanded buff section needs the room
```

Vertical stack inside the content area (all values from the mockup, `PAD = 12`, `GAP = 11`):

| y | block | height |
|---|---|---|
| 0 | tab strip + goal line (same row) | 30 |

Tab order is **Damage done, Damage taken, Healing done, Healing taken** (was done / healOut /
healIn / taken) — the damage pair sits together and the healing pair sits together, so the two
views a reader actually compares are adjacent; `VIEWS` in `UI/Analysis.lua` changes to
`{ "done", "taken", "healOut", "healIn" }` (it drives tab order only — `VIEW_META`, the
filters table and the graph series map are all keyed, not ordered). Tab labels are
centred in their 140px cell (`ContentAlignment.MiddleCenter`), not flush left.
| 40 | picker chips | 22 |
| 72 | KPI row (5 cards, label / value / sub stacked) | 50 |
| 133 | plot | 150 |
| +4 | buff lanes, one 8px lane per charted buff (0–3) | 0–34 |
| +6 | range slider | 16 |
| +2 | timeline labels (now `MM:SS`, not `Ns`) | 14 |
| +2 | legend row + peak/low morale readout | 18 |
| +11 | skill table, **full content width** (848) | 22 + rows×22, min 9 rows |
| +11 | buff section (604) + side panels (233) side by side | 26 (+ 20 + rows×22) |

The skill table is the block that wants space, so it gets the full 848px and its own row;
the buff table and the two side panels share the row underneath (buffs left at 604,
`SOURCES`/`BY TYPE` right at 233). Skill columns at 848: `taken` = 306/110/58/106/68/88/104 — Max and
Total are deliberately wide (88/104) because a 7-figure comma-formatted total at
`LucidaConsole12` needs ~80px inside 8px padding, and a clipped total is the one number in the
table nobody can afford to lose; the heal views drop the Avoid column and give the width to
skill/counterpart (336/156/58/106/88/104). Buff columns at 604: 22/214/98/90/74/106. Window height with the
buff section open, 2 lanes charted and 9 skill rows is 851 — raise `MAX_HEIGHT` accordingly
(see below) or let the skill table shrink to its 150px floor first and the buff table scroll
second.

Two fixes to the table while you are in there:

- **The columns currently overflow the viewport.** `RefreshTableColumns` clamps `skillWidth`
  to a 150px floor, so the `taken` view's 8 columns total 620px inside a 594px ListBox — the
  Total column is clipped off-screen (visible in `0a`). Fix by merging `Crit` and `Dev` into
  one `CRIT / DEV` column printed as `14% / 0%` (percentages, which is what a reader wants
  anyway — the raw counters stay separate in the data, per `docs/DESIGN.md`) and dropping the
  numeric column width from 60 to 54. New totals: `taken` 604, `done`/heal views 604 — fits
  with the skill column flexible again.
- Right-align every numeric header over its column (already the case) and keep
  `LucidaConsole12` on the numbers.

**Buff section** (`BuildBuffSection`): a header row (`▾ SELF BUFFS · 7 tracked · 2 charted ·
00:59–02:12`, hover tint `Theme.Hex.Hover`, `MouseClick` toggles) and, when open, a pooled
12-row table with columns `[chart box 22][ICON 24][BUFF 190][UPTIME % 98][UPTIME 90][APPS 74]
[LONGEST GAP 106]`. Each row carries a share bar behind it at `uptimePct` width in an 8% accent
tint (same `Theme.Mix` treatment the skill rows use). Clicking a row toggles it charted;
charted rows get their lane colour in the checkbox and light up the name in `Accent200`. Cap
charted at 3 — the 4th click replaces the oldest. Colour coding: uptime ≥75% `HealingDone`,
<35% `DamageSevere`, gap >12s `DamageSevere`.

Buff lanes in the graph: one 16px row (+4px gap) per charted buff under the plot, a 2px
`#262939` rail 826px wide with 6px segments per interval in the lane colour, and the buff's
**16×16 icon** at x=832 closing the lane — the icon replaces the name entirely (three names
at 9px was the noisiest thing on the plot, and the icon is how a player recognises a buff).
The icon carries the buff name as a tooltip. Same Control-per-interval pooling as everything
else (pool 24 segments per lane).

**Icons.** `effect:GetIcon()` returns the asset id; set it as a Control background —
`icon:SetBackground(e:GetIcon())` on a 16×16 `Turbine.UI.Control`, cached per buff name in
`Buffs.Icons[name]` at first sighting so the table and the lanes share one lookup. Both the
table's icon column and the lane end use the same 16×16 size (LOTRO effect icons are
32×32 art; the Control scales it). The mock draws two-letter initial tiles as stand-ins
because the real art only exists in the client — tint, border and size in the mock match what
the Control will occupy, so no layout changes when the real icons land. When a buff is not
charted the tile is dimmed (`#1e202d` ground, `#3a3d4e` border); charted, it takes the lane
colour as its border. If `GetIcon()` ever returns nil, fall back to the dimmed tile with no
content rather than shifting the columns.

## 8. Live meter (`1b`) and death cause (`1c`)

Small, both keep their exact footprint (260×186, 380×200):

- Live meter: tabs become underlined labels (2px accent underline on the active one) instead
  of filled blocks, and the tab row drops from 24 to 22px; the headline gains a 30-column,
  16px-tall sparkline of the last 30s (`session.buckets`, one Control per second, same
  pooling). No morale strip in the meter — morale reads in the analysis graph and the death
  window, not here. The sparkline is paid for out of the existing body,
  not by growing the window — `self.body` stays 260×136 at y=24 of the client and the rows
  retighten to: caption 12, headline 24, sparkline 16, divider 1 (+3/3 margins), three stat
  rows 16 each, max-hit skill sub-line 10. The headline number drops
  Verdana22 → Verdana20 to fit the 24px line, and the two-line max cell becomes one row plus
  the sub-line. Everything else (x offsets, 10px padding) unchanged.
- Death cause: the killing-blow row gets a tinted background (`#33222e`) and a 2px
  `DamageFatal` left border rather than only a coloured number; the **biggest single hit** in
  the list gets the same treatment in `AccentLight` (`#b5abfc` border, `#2b2438` fill, its
  amount in `AccentLight`, and an 8px `MAX` tag after the skill name) with a second legend
  swatch reading "Biggest hit" — the killing blow is often not the hit that actually killed
  you, and that distinction is the whole point of this window. Temp-morale rows are excluded
  from the max comparison (a popped bubble is not a hit). Each row's morale bar also
  gains its percentage in `Verdana10` to the right — the bar alone doesn't say how close you
  were. Rows and columns keep their current x offsets.

## 9. Order of work

1. `Session:Slice` + event log + cache (nothing visible changes; verify against a full-range
   slice matching today's `agg` totals exactly).
2. Graph rewrite (line + morale background), still full-fight only.
3. Range slider wired to `Slice`, everything rescoping.
4. `Buffs.lua` polling + buff table + lanes.
5. Live meter / death cause touch-ups.
6. Version bump in `Reckoning.plugin`, `Reckoning.plugincompendium`, `Constants.lua`
   (`Reckoning.Version`) plus a player-facing `CHANGELOG.md` entry.
