# Drawing a line graph in LOTRO's Lua UI — what the API actually allows

Research notes behind `REDESIGN_SPEC.md` §2. Sources: the published API reference
(`Turbine.UI.Control` / `Turbine.UI` class lists), this repo's `UI/AnalysisGraph.lua`, and
working code in `souruko/Gibberish3` — which turns out to contain the most useful evidence.

## 1. What you have to work with

`Turbine.UI.Control` (and `Window`, which extends it) is the whole toolbox. Its members are
position/size/z-order/visibility, `SetBackColor` + `SetBackColorBlendMode`, `SetBackground` +
`SetBlendMode`, opacity, parenting, and the mouse/key/`Update` events. There is **no canvas,
no line/polygon primitive, no per-pixel access, no vector layer** — the reference lists
nothing of the sort, and `Turbine.UI`'s class list is just Button / CheckBox / Color /
ContextMenu / Control / ControlList / Display / DragDropInfo / Graphic / Label / ListBox /
Menu* / ScrollableControl / ScrollBar / TextBox / Tree* / Window.

So a "line" is always one of three things:

1. an **axis-aligned rectangle** (`SetBackColor` on a small Control) — the only primitive that
   is guaranteed, cheap and exact;
2. an **image** (`SetBackground("Plugin/RESOURCES/x.tga")`, sized by `SetStretchMode`) — which
   can contain a diagonal drawn offline;
3. an image or rect that has been **rotated** with the undocumented `SetRotation` (see §3).

Two facts from Gibberish3 that constrain all three, and that cost real debugging time to find:

- **`Turbine.UI.Graphic` draws in one control at a time.** `UTILS/IconIDs.lua` builds
  `Turbine.UI.Graphic(...)` objects per image; `CIRCEL/Element.lua` warns that handing the
  same Graphic to two controls "leaves all but the last of them blank". For a 94-segment
  polyline sharing one line sprite this is fatal unless you pass the *path string* to each
  control (each control then owns its own copy) or build one Graphic per control.
- **A `.tga` background cannot be tinted** by `SetBackColor` — the colour fills the control
  *behind* the image (`OPTIONS2/ELEMENTS/RowParts.lua`, `WINDOW/BaseWindow.lua`). The way
  Gibberish3 colours monochrome glyphs is `SetBlendMode(Turbine.UI.BlendMode.Overlay)` plus
  `SetBackColor(colour)` — an Overlay-blended white sprite takes the control's back colour.
  That is what makes one white line sprite serve both series colours.
- External images load from the plugin folder in `.tga`, `.dds`, `.png` and `.jpg`
  (Gibberish3's own `CHANGELOG.md` confirms all four).

## 2. Option A — the L-step polyline (what the mock draws, and the safe floor)

Per bucket pair, two rects: a horizontal run at the midpoint height and a vertical riser at
the right end of the run; a 5×5 dot on every other bucket.

```lua
local yMid = math.floor((y0 + y1) / 2)
hSeg:SetPosition(x0, yMid);            hSeg:SetSize(x1 - x0, 2)
vSeg:SetPosition(x1 - 1, math.min(y0, y1)); vSeg:SetSize(2, math.abs(y1 - y0))
```

- Cost for 48 buckets × 2 series: 284 pooled Controls, positioned only when the data or the
  range changes. Nothing per frame.
- Guaranteed to work on every client, no assets, exact pixel control, tint is free
  (`SetBackColor`), and it hit-tests normally.
- Reads as a line at 13–25px per bucket. At the extremes it reads as a staircase, and a steep
  riser next to a short run looks heavier than the line elsewhere (constant-width strokes on
  an L joint overlap at the corner). Mitigate by drawing the riser *under* the runs
  (`SetZOrder`) and overlapping 1px so joints have no gap.

This is the floor: it always works. Everything below is an upgrade on top of it.

## 3. Option B — rotated segments (`SetRotation`)

Not in the published reference, but **real and in production**: `Gibberish3`'s circular timer
rotates its sweep pieces with

```lua
control.rotation = { x = 0, y = 0, z = 90 }
control:SetRotation( control.rotation )
```

on `Turbine.UI.Window` instances (`UI_ELEMENTS/TIMER/CIRCEL/Element.lua`). Two hard-won
facts documented in that file:

- **Rotation does not survive a later `SetSize` or `SetBackground`** — the angle must be kept
  in Lua and re-applied after anything that writes to the control (they keep a `rotation`
  table per control and re-`SetRotation` in `Resize()` and after every background swap).
- It is applied on Windows there, together with `SetStretchMode(2)` (scale the image to the
  control) and `BlendMode.Overlay`.

If arbitrary `z` works — Gibberish3 only ever uses 0/90/180/270, so this is the one thing to
probe before committing — a true polyline is one rect per segment:

```lua
local dx, dy = x1 - x0, y1 - y0
local len    = math.sqrt(dx * dx + dy * dy)
local deg    = math.deg(math.atan2(dy, dx))          -- atan2 exists in Lua 5.1

seg:SetSize(math.floor(len + 1), STROKE)             -- size FIRST: it clears rotation
seg:SetBackColor(colour)
-- rotation pivots on the control's centre, so place the centre on the segment midpoint
seg:SetPosition(math.floor((x0 + x1) / 2 - len / 2), math.floor((y0 + y1) / 2 - STROKE / 2))
seg.rotation.z = deg
seg:SetRotation(seg.rotation)                        -- re-apply, always last
```

47 segments per series instead of 94 rects, and a genuine diagonal. Probe checklist, in this
order (30 minutes with `/redbook debug` and one throwaway window):

1. Does `SetRotation` exist on `Turbine.UI.Control`, or only on `Window`? (Gibberish3 only
   proves `Window`. If it's Window-only, each segment becomes a Window — heavier, and worth
   measuring before shipping 94 of them.)
2. Does a non-90° `z` render, and is it degrees (not radians)?
3. Is the pivot the control's centre? Verify with a 100×2 rect at z=45 against a known point.
4. Does a rotated control still **clip to its parent**? If not, a segment near the plot edge
   will spill over the frame and the plot needs an inset or a mask.
5. Is a rotated control's **hit-testing** rotated too? The graph's hover zones are unrotated
   columns either way, so this only matters if a segment must be clickable — it doesn't.
6. Does rotation survive `SetVisible(false)` → `SetVisible(true)` (pooling relies on that),
   and does it survive `SetBackColor`? (`SetSize`/`SetBackground` are known to clear it.)
7. Antialiasing: is a rotated 2px rect antialiased (smooth) or nearest-neighbour (jagged)?
   If jagged, Option C looks better at the same cost.

Fail any of 1–4 and fall back to Option A; the row of pooled rects is the same pool either
way, which is why A is worth building first.

## 4. Option C — a slope sprite atlas

No rotation needed. Author one white 32×32 `.tga` per slope bucket (say 16 buckets from −75°
to +75°, plus a flat one), ship them in `RedBook/RESOURCES/`, then per segment pick the
nearest bucket and stretch the sprite over the segment's bounding box:

```lua
seg:SetSize(w, h)
seg:SetStretchMode(2)                                  -- scale image to control
seg:SetBlendMode(Turbine.UI.BlendMode.Overlay)         -- so SetBackColor tints it
seg:SetBackColor(colour)
seg:SetBackground("RedBook/RESOURCES/slope_08.tga")  -- path, not a shared Graphic
```

- Works on documented API only, gives smooth antialiased diagonals, and the Overlay + BackColor
  trick keeps one asset set for both series.
- Costs: 17 art files; stretching distorts stroke width (a 60px-wide, 4px-tall bounding box
  makes a 2px line thinner vertically), and slope quantisation shows as a small kink at
  joints. Both are mild at this data density.
- The stretch distortion argues for authoring each sprite tall (e.g. 64×64) and accepting
  that near-vertical segments get their own dedicated asset.

## 5. Option D — the ribbon (cheapest continuous read)

One rect per bucket spanning from the previous value to the current one
(`top = min(y0,y1)`, `height = abs(y1-y0) + 2`). 48 controls per series, no joints to line up,
and it reads as a continuous band rather than a line. Good for the *background* series
(healing-in behind damage-taken) and for the live meter's 30s sparkline, where 20px of height
can't express a line anyway. It is what the sparkline in `1b` does.

## 6. Recommendation

1. Ship **Option A**. It has no unknowns, no assets, and the pooling shape is identical to
   every later option — `dots` / `hSeg` / `vSeg` become `dots` / `seg` and nothing else moves.
2. Run the §3 probe. If arbitrary `z` rotation renders and clips, switch the segment pool to
   **Option B** — half the controls and a real diagonal, ~20 lines of change, and keep the
   angle table + re-apply discipline Gibberish3 documents.
3. If rotation is jagged or Window-only and 94 Windows measure badly, go to **Option C**;
   the sprite atlas is a one-time art cost and the drawing code is the same shape as B.
4. Use **Option D** for the sparkline and any secondary/background series.

Two things to hold onto whichever way it goes: the morale background stays plain
`SetBackColor` rects (48 bars + 48 edge rects — no image, no rotation, cheapest thing on the
plot), and every control is created once in the constructor and only ever repositioned. The
current `AnalysisGraph.lua` already pools correctly; none of this changes that contract.
