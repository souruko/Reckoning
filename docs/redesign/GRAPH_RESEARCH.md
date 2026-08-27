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
order (30 minutes with `/reck debug` and one throwaway window):

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
to +75°, plus a flat one), ship them in `Reckoning/RESOURCES/`, then per segment pick the
nearest bucket and stretch the sprite over the segment's bounding box:

```lua
seg:SetSize(w, h)
seg:SetStretchMode(2)                                  -- scale image to control
seg:SetBlendMode(Turbine.UI.BlendMode.Overlay)         -- so SetBackColor tints it
seg:SetBackColor(colour)
seg:SetBackground("Reckoning/RESOURCES/slope_08.tga")  -- path, not a shared Graphic
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

## 7. The probe, as built (`/reck probe`)

§3's checklist is now a window: `UI/RotationProbe.lua`, opened with
`/reck probe [control|window] [plain|sprite]`. Reading Gibberish3's
`UI_ELEMENTS/TIMER/CIRCEL/Element.lua` in full added two questions §3 did not ask, and both
change the shipping code if they come back the wrong way:

- **Back colour or sprite?** Every rotated control in that file carries a *background image*
  (`SetStretchMode(2)`), tinted by `SetBackColorBlendMode(Overlay)` + `SetBackColor`. Nothing
  anywhere rotates a control painted with `SetBackColor` alone. If a bare fill does rotate,
  `Resources/line.tga` is unnecessary and each segment loses three calls.
- **Can a rotated `Turbine.UI.Window` be parented into a `Turbine.UI.Control`?** Gibberish3 only
  ever parents its rotated Windows into other Windows, and `Graph` is a Control. If the answer is
  no, either `Graph` becomes a Window or the segments get a Window host of their own.

So the window's first four cells are a 2x2 of the *same* 45-degree segment -- control/window x
plain/sprite -- each drawn between two marker dots, which makes them a pivot check as well: a
segment rotating about its top-left corner swings away from both markers. Cells 5-8 are §3's
items 2, 3, 4 and 7 (sign and units, pivot, clipping, stroke edges), drawn in whichever flavour
the command asked for. Cell 9 is a real 9-point polyline drawn by the exact arithmetic
`UI/AnalysisGraph.lua` would ship, and is the acceptance test.

§3's items 5 and 6 are deliberately **not** probed. Hit-testing does not matter -- every segment
is mouse-invisible. And "does rotation survive `SetVisible` / `SetBackColor`" does not matter
either, because the shipping `Redraw()` re-specifies every visible segment completely (size,
colour, position, rotation last) on every pass; the whole "rotation does not survive X" bug class
is structurally impossible as long as **nothing touches a segment outside `DrawSegment`**. That
rule is the one thing to preserve when editing the plot.

**The failure signature to expect** if rotation silently no-ops rather than erroring: a steep
segment's *unrotated* rect is `len` wide, so the plot renders as long flat bars punched through
the data rather than as a line.

### Round one, and why its result was unreadable

The first probe drew a 45-degree segment in all four combinations of Control/Window x
back-colour/sprite, plus a sign quad, a pivot test, a clip test, a stroke ladder and the real
polyline. **Every rotated subject came out flat horizontal.** That is the documented no-op
signature, and it is *not* a conclusion, because every subject it drew was either a flat colour or
a uniform white block. Rotate either one inside its own rectangle and it looks exactly the same.
Two very different engine behaviours produce identical flat bars:

- **(a)** `SetRotation` does nothing at all; or
- **(b)** it rotates the control's *content* inside a rect that stays axis-aligned.

(b) is not a stretch. Every rotation subject in Gibberish3 is a **square** control fully covered by
a **structured** image (`circelBack`, `circelFull`, `circelLead`, all sized to the whole timer and
backgrounded with a circle quadrant) -- which looks identical under both behaviours. The only
production evidence anywhere cannot distinguish them either. And the difference decides the rework:
under (b) a 2px-tall segment can never draw a diagonal at any angle, and Option B is dead.

Round one's clip cell was first written up as "a control is not clipped to its parent's bounds",
which was wrong: that subject was built in the command's default flavour, and the default is
**window**. The real rule, per the plugin's author: **Controls clip to their parent, Windows do
not.** So the cell showed only that a Window escapes its parent's bounds -- a 120px bar at 30
degrees running out of its 70x70 box both sides -- and said nothing about Controls at all.

That is very likely *why* Gibberish3 makes every rotated piece a `Turbine.UI.Window`: a rotated
draw extends past the control's own axis-aligned rect by definition, and a Control would clip
exactly that overflow away. It also cuts two ways for the rework. A rotated **Control** at 45
degrees may render as an octagon (the rotated square clipped back to the unrotated one) rather than
a diamond -- still evidence that the rect rotated. And if the segment pool has to be **Windows**,
segments will not be clipped by the plot ground, so the plot's own frame will not contain them; the
geometry has to. (It does: a segment control centred on its midpoint has a rotated y-extent of
`len*|sin| + stroke*|cos|`, which is the span between the two data points it joins, and a rotated
x-extent of `len*|cos|`, which is smaller than the unrotated one. A segment can never reach past
the bounding box of the data it draws.)

### Round two, and what it settled

Subjects that could not hide the difference: solid squares and an asymmetric icon.

**Settled: the control's own rect does not rotate.** The solid squares at 45 stayed square, Control
and Window alike, and a 44x2 Window bar at z=90 -- parented straight into the frame's own Window,
with nothing in the chain that could clip it -- stayed horizontal.

**Not settled, and the reason matters:** every ICON cell came back completely blank. They used
`SetStretchMode(2)` to scale a 16x16 `.tga` up to 36x36, and **nothing in this codebase has ever
rendered a stretched file-path image.** Every icon that works here is drawn at its asset's exact
native size, and `Icon.Apply` (`Constants.lua`) dropped `SetStretchMode` outright in round seven of
the self-buff icon saga precisely because stretching was what kept those tiles empty.

Which means the sprite subjects in rounds one *and* two never had a background image at all -- they
rendered their `SetBackColor` and nothing else. **No probe cell so far has successfully drawn an
image, so "does a rotated image draw outside its rect" has never actually been asked.** That is not
a small gap: Gibberish3 only ever rotates image-backed controls, so it is the only configuration
with any production evidence behind it.

### Round three, and what it settled

Every image subject at its asset's native size, no stretch, plus the window carrying its own API
status so a screenshot answers everything.

**`SetRotation` is ABSENT on `Turbine.UI.Control` and present on `Turbine.UI.Window`.** On a Control
the call throws -- 4 of 5 applied, the miss being the one Control subject. Gibberish3 rotating only
Windows was not a style choice.

**On a Window it is callable and has no visible effect.** Not on a solid square, not on a
native-size image, not at 45, not at 90, not on a thin bar, not through a Control ancestry, not
parented straight into the frame's own Window.

Three other facts came out of it, and two of them are worth keeping whatever happens to rotation:

- **`SetStretchMode(2)` TILES an image, it does not scale it.** Cell A drew a 16x16 lens repeated
  in a 3x3 grid across a 36x36 control. That -- not "a stretched image renders nothing" -- is what
  round two's blank icon cells were showing, once combined with `SetBlendMode(Overlay)`, which
  round two also set and cell A did not. `SetBlendMode(Overlay)` **plus** stretch renders blank.
- **A native-size image renders correctly** (cell B).
- **`SetBackColorBlendMode(Overlay)` + `SetBackColor` tints a white image** (cell H: the same asset
  drew white on the left and accent-purple on the right). The plot can get every series colour out
  of one white asset, which is what `line_long.tga` is for.

### Round four -- rotation works, and the missing ingredient was TIMING

Cell E rotated a wedge **once, in the constructor**: nothing happened. Cells F and G rotated the
same wedge **on every `Update` tick**: it turned, at 90 and at 45 both.

**A rotation set before the control has ever painted is silently dropped.** That is why three
rounds came back flat, and why Gibberish3 never hit it -- its timers re-apply on every progress
change, to a control long since on screen. Nothing here did.

So, on a `Turbine.UI.Window`: `SetRotation` works, at **arbitrary** angles, provided it is applied
after the control has painted.

Cells A-D showed all four stretch modes tiling -- which was **the probe's fault, not the engine's**.
Per the plugin's author, scaling needs a specific sequence:

    control:SetSize(imageW, imageH)     -- the IMAGE's size first
    control:SetBackground(image)
    control:SetStretchMode(1)
    control:SetSize(targetW, targetH)   -- and only now the size you want

Rounds one to four sized the control to the target and set the background after, so the stretch
mode had no native-sized control to scale from. (`Icon.Size` in `Constants.lua` already leans on
the same ordering quirk from the other direction, using `SetStretchMode(2)` to snap a control to
its image's native size so it can read it back.)

### Round five -- the mechanism, completely

- **One deferred apply is enough and it sticks.** Cell C rotated a wedge once, on the first frame
  after it had painted, and it stayed rotated for the whole session; cell D, applied in the
  constructor, never moved. So the plot rotates each segment **once per data change**, not every
  frame -- the cost question is settled in the cheap direction.
- **The author's scaling sequence works.** Cell A's lens scaled 16 -> 48 as one big glyph, next to
  a reference that tiled because it was sized before its background was set.
- **A scaled image still rotates** (cell B), even though scaling ends in a `SetSize` that clears
  the rotation -- because the rotation comes later, on its own frame.

**And the finding that decides the design: the control's rect never rotates. The IMAGE is rotated
and then FITTED to the rect.** Cell E's 64x16 wedge at 90 came back still 64x16 with its content
reoriented -- not 16x64. Cells F, G and H confirm the consequence: a 64x2 control carrying a
uniform white bar shows nothing at any angle, because a rotated white rectangle refitted into a
64x2 slot is still a 64x2 white bar. The polyline was flat bars again.

**So Option B as written in section 3 is dead.** A thin control cannot draw a diagonal, whatever
angle it is given.

### Round six -- square controls, which rotate-then-fit makes work

Rotate-then-fit hands back something better than Option C's slope atlas:

> **Make the segment's control SQUARE, with its side equal to the segment's LENGTH.**

A square rect makes the fit a uniform scale, so a rotated line stays a straight line at exactly the
angle asked for -- no shear, no slope quantisation, no atlas. `stroke.tga` is a 64x64 sprite with a
full-width band through its centre and transparent elsewhere; rotated to the segment's angle and
scaled to an L x L control centred on the segment's midpoint, the band runs from one data point to
the other and stops. The band's ends sit half a width from the centre, well inside the square's
half-diagonal, so nothing is cropped at any angle, and the transparent region means neighbouring
squares can overlap freely.

| Cell | Subject | Reads as |
| --- | --- | --- |
| A | one segment @45, with a dot on each endpoint | a line that turns but misses its dots is a different bug from one that does not turn |
| B | a near-flat and a near-vertical segment | the two extremes real combat data produces |
| C | segments of length 24 / 44 / 64 | stroke is 3/64 of the length -- how visible is the spread? |
| D | three overlapping segments | the squares overlap by design; does the sprite's transparency hold? |
| E | a real 12-point series | **the acceptance test** -- if this reads as a line graph, the rework is a port |

If C's spread is too visible, the fix is a handful of sprites at different band ratios chosen by
length -- not a different mechanism.

### Round six -- it works, with one sign inverted

Real diagonals, on the first try. Cells A-D drew clean sloped lines, and D confirmed the sprite's
transparency composes correctly across heavily overlapping squares.

One bug, and it was total: **the engine's positive z turns the opposite way from screen space**, so
`atan2(dy, dx)` as-is draws every segment MIRRORED about its own midpoint -- right length, right
centre, both ends on the wrong side. The angle has to be negated.

Cell D is what proves the diagnosis rather than just the symptom: its zigzag is symmetric, so
mirroring each segment about its own midpoint maps the shared vertices consistently and it still
looked connected -- while cell E's irregular series diverged at every joint. Same-length, wrong-side
is the only failure that produces both of those at once, which also establishes that the segment
LENGTHS were right all along and no fit-compensation is needed.

### The technique, as shipped

```lua
-- one Window per step, pooled; Control has no SetRotation at all
segment:SetSize(STROKE_NATIVE, STROKE_NATIVE)   -- the IMAGE's size first
segment:SetBackground(StrokeSprite(side))       -- the ladder rung nearest a 2px stroke
segment:SetStretchMode(1)
segment:SetSize(side, side)                     -- square, side = the segment's own LENGTH
segment:SetBackColorBlendMode(Turbine.UI.BlendMode.Overlay)
segment:SetBackColor(color)                     -- one white sprite, every series colour
segment:SetPosition(midX - side / 2, midY - side / 2)
segment.rotation.z = -math.deg(math.atan2(dy, dx))   -- NEGATED
-- ...and SetRotation on a LATER FRAME, once (Graph:FlushRotation, driven by Analysis:Update)
```

### Answers

| Question | Answer |
| --- | --- |
| `SetRotation` on `Turbine.UI.Control` | **ABSENT** -- the call throws |
| `SetRotation` on `Turbine.UI.Window` | **present and working**, at arbitrary angles |
| Rotation applied before the first paint | **silently dropped** |
| One apply on a later frame | **enough, and it sticks** |
| The control's rect rotates | **no -- the IMAGE rotates and is FITTED to the rect** |
| Therefore a thin control can draw a diagonal | **no** -- Option B as written is dead |
| A square control, side = segment length | **draws a true diagonal** -- this is what shipped |
| Positive z turns | **the opposite way from screen space** -- negate the angle |
| Segment length needs fit-compensation | **no** -- lengths were correct all along |
| Scaling an image | `SetSize(native)` -> `SetBackground` -> `SetStretchMode(1)` -> `SetSize(target)` |
| Size set before background | every stretch mode **tiles** |
| `SetBackColorBlendMode(Overlay)` + `SetBackColor` tints an image | **yes** |
| Sprite transparency composes across overlapping controls | **yes** |
| Clipping | **Controls clip to their parent, Windows do not** |
| Stroke width | a fraction of the segment's LENGTH, because the control is sized to it -- so the stroke is a ladder of eight sprites picked by length, not one sprite |

The probe has answered everything it was built for. **Delete `UI/RotationProbe.lua`, its
`/reck probe` command, `Resources/wedge.tga`, `Resources/line.tga`, `Resources/line_long.tga` and
the `windows.probe` key it leaves in saved settings** once the line graph is confirmed in-game.

### The one thing a probe did not catch

The first in-game load of the real plot came back with "the width of the line is very different
depending on the angle". It is the **length**, not the angle: the control is sized to the segment's
own length and the sprite's band is a *fraction* of the sprite, so one sprite draws a stroke
proportional to length -- about 1px across a flat second and 6px up a steep spike.

No probe cell could have caught it, because every probe drew a handful of segments at hand-picked
lengths rather than a real series across a real plot width. The fix is a ladder of eight sprites
(`Resources/stroke_10` … `stroke_60.tga`, the number being the band width in tenths of a pixel) with
`StrokeSprite(side)` picking the rung whose `band * side / 64` lands nearest 2px. That holds the
drawn stroke between roughly 1.7 and 2.2px across every length the plot produces, and
`tools/offline/graph_test.lua` now measures exactly that over the reference logs rather than
trusting the arithmetic.

The fractional 1.5 rung is not padding: whole-pixel bands can only manage 1.4px or 2.8px on the
longest segments, and that gap is visible.

### The second thing a probe did not catch

The same load also showed the line "shortly as a horizontal line" on every redraw. That is the
deferred rotation made visible: a segment is sized -- which clears its rotation -- two frames before
it is rotated, so in between it paints flat. Segments are now drawn **hidden** and revealed by
`FlushRotation`, after the angle is on.

That fix has a trap of its own, which is worth more than the fix. Dragging the range slider redraws
on every bucket it crosses *without moving the series at all*, so hiding on every redraw would have
blanked the plot for the whole drag -- trading a brief flat line for a much worse flicker.
`DrawSegment` therefore memoises size, position, angle, sprite and colour, and returns without
touching the control when none of them changed.
