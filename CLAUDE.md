# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## What this is

Reckoning is a Lord of the Rings Online (LotRO) plugin written in Lua. It reads the combat
chat log and reports on the local player's own combat via three windows: an always-on live
meter, a death post-mortem, and a post-combat analysis window. It runs inside the game via the
Turbine plugin engine -- there is no build step, package manager, linter, or test runner.

Read `docs/DESIGN.md` first (the data model and parser facts that decide what is buildable),
then `docs/IMPLEMENTATION_PLAN.md` (the phased build order), then `docs/redesign/` -- the v0.2.0
handoff bundle (`REDESIGN_SPEC.md` is the Lua-side plan, `GRAPH_RESEARCH.md` is the ways to
draw a line in this API and why the code picked the one it did, `mock/` is an interactive HTML
design reference you open in a browser). Code comments cite `REDESIGN_SPEC.md` section numbers. Both came from a design handoff
bundle at `~/Downloads/design_handoff_combat_analyzer` and are reproduced here in full, along
with the HTML mockup (`docs/mockup/`) and real combat-log fixtures (`reference/`).

## Working directory

The two configured working directories are the **same directory** -- one is a symlink into
the Steam/Proton prefix. There is no separate source vs. deploy copy: edits here are
immediately live in the game. Reload to see a change:

```
/plugins refresh
/plugins load Reckoning
```

Runtime errors surface in the LotRO chat window; there is no other log.

## Version bumps

The version appears in **three** places and must be kept in sync: `Reckoning.plugin`
(`<Version>`), `Reckoning.plugincompendium` (`<Version>`), and `Constants.lua`
(`Reckoning.Version`). `CHANGELOG.md` gets a matching entry, written for players rather than
developers. `tools/offline/load_test.lua` asserts the `Constants.lua` value, so a half-done bump
fails there.

## Build status

**v0.2.0 applies the analysis-window redesign** from the handoff bundle
(`design_handoff_reckoning_redesign/`: `README.md`, `REDESIGN_SPEC.md`, `GRAPH_RESEARCH.md`, and
an interactive HTML mock). Four changes plus two small passes: the graph became a line-and-dot
plot, morale became a background bar graph, self-buff tracking arrived with its own table and
charted lanes, and a two-handle range slider rescopes the whole window. See `CHANGELOG.md` for
the player-facing version and `REDESIGN_SPEC.md` for the spec each piece came from.

**There is now a real offline test suite: `tools/offline/`.** Unlike the original scratch harness
(described below), it runs the **real** classes and the **real** `Main.lua` under a **real Lua
5.1** interpreter against a `Turbine` stub built on this repo's own `class()` shim. `sh
tools/offline/run.sh` runs 756 checks in about a second. It caught three genuine bugs during the
redesign that `luac -p` could not have: an index-base probe that could not actually distinguish a
0-based from a 1-based `EffectList`, a `nil` layout constant reaching `SetPosition`, and the
analysis window failing to adopt an already-archived session. It caught three more during the
options-panel work, all of them the "a setting exists but nothing reads it" shape rather than a
crash: the live meter's borders never following the `showBorders` toggle (its `ApplySettings`
returned early through `Refresh` when the meter was faded), `Analysis:SyncBucketCount` and the
`Graph`'s own count disagreeing after a `bucketWidth` change, and `ChatPost`'s death preset losing
the killing blow's own `+0s` row once `deathRows` let the ring hold twelve entries instead of five. **Run it before every in-game
load** -- it does not replace one, but everything it catches is something you would otherwise
have burned a reload finding. Read `tools/offline/README.md` for what it deliberately cannot see.


All six implementation-plan phases are done. **None of it has been loaded in-game yet** --
every file is syntax-checked (`luac -p`) and, for Phases 1-2, verified offline against real
combat logs (see below); everything from Phase 2 on (all the `Turbine.UI` code) is unverified
beyond careful reading. Load it in-game and work through `docs/IMPLEMENTATION_PLAN.md`'s "Done
when" line for each phase before trusting any of it. The analysis window (Phase 5) is by far the
largest and least-verifiable piece -- see the "Analysis window" note below first.

German/French parser drop-ins (`docs/IMPLEMENTATION_PLAN.md` Phase 6) were not done -- English
only. `Parse/en.lua`'s own header already documents how to add them (same signature, selected the
way `Constants.lua` does it in Gibberish3).

### Analysis window: what's genuinely unverified

Phases 1-2's offline harness could exercise real logic outside the game; Phase 5 cannot -- it is
almost entirely `Turbine.UI.Control`/`Label`/`ListBox` construction and layout arithmetic,
checked only with `luac -p` (syntax) and by hand-tracing the pixel math in review. Specific
things that need an actual in-game load to confirm, roughly in order of how likely they are to
be wrong:

- **Found and fixed by an actual in-game load**: `Turbine.UI.ScrollView` does not exist --
  `UI/Analysis.lua` originally guessed at that name for the skill table's scroll host and errored
  on plugin load (`attempt to call field 'ScrollView' (a nil value)`). Confirmed via a working
  reference (`LootLogs/UI/Window/LootBrowser.lua`): the real pattern is `Turbine.UI.ListBox` as
  the scroll host plus a separate `Turbine.UI.Lotro.ScrollBar` wired in via
  `listBox:SetVerticalScrollBar(scrollBar)`. Items are added with `:AddItem(control)`, not
  manually positioned -- `Analysis:RefreshTable` now calls `self.scrollView:ClearItems()` then
  re-`AddItem`s the same pooled row containers every refresh (the ListBox's *membership list*
  gets rebuilt each time; the row Controls themselves are still the same reused pool, never
  destroyed). **This is a live example of the exact residual risk this whole section warns
  about** -- treat every other guessed-at-but-unverified Turbine.UI call below the same way:
  plausible, pattern-matched against real plugin code, but not proof until it's actually loaded.
- The picker chip width estimate (`ChipWidth` in `UI/Analysis.lua`, `16 + len(text)*7`) is a
  guess -- there's no text-measurement API used anywhere else in this codebase to check against.
  Long names will likely need retuning.
- At the window's minimum size (1080x600), the "Damage taken" view's table columns sum to a few
  px more than the table's allotted width once the Skill column hits its 150px floor (8 fixed
  columns leave less room than the other three 7-column views) -- minor overflow, only in that
  one view, only at minimum width, self-corrects once the window is widened.
- **Found and fixed by an actual in-game load, second occurrence**: `SetOpacity` was used
  everywhere (tabs, picker chips, session rail selection, KPI card fill, skill-table share bars,
  the graph's gridlines and data columns) to approximate the mockup's 8-digit-hex alpha tint
  tokens. In-game, every one of these rendered as full solid colour -- `SetOpacity` on a plain
  `Turbine.UI.Control` with its own solid `BackColor` does not blend in this engine; it draws the
  `BackColor` at full strength regardless of the opacity value. Re-grepped `VitalSelf`,
  `Gibberish3`, `CombatAnalysis`, and `LootLogs` afterward: there is no working precedent anywhere
  in ~450KB of real plugin code for `SetOpacity` used this way -- every real low-value or
  near-zero use is a whole-window/whole-icon fade, never a tint over an opaque fill. The real,
  repeated pattern (7+ sites in `LootLogs` alone, its own helper called `MixColor`) is
  precomputing the blended RGB and using a plain solid `SetBackColor` -- now `Theme.Mix(fgHex,
  bgHex, t)` and `Theme.AlphaColor(hex, bgHex)` in `Constants.lua`. `LiveMeter` originally kept one
  `SetOpacity` use for its whole-window post-combat dim (matching `VitalSelf/UI/Vital.lua`'s
  confirmed-working incombat/outcombat-opacity pattern), but that behaviour itself was removed
  entirely per later feedback (see the `UI/LiveMeter.lua` row above) -- as of now **nothing in
  this codebase calls `SetOpacity` at all**. If a future change wants a translucent wash, use
  `Theme.Mix`/`Theme.AlphaColor`; if something wants a genuine whole-window fade again, that's the
  one case `SetOpacity` is confirmed to actually work for -- just never on a Control that already
  has a solid `BackColor`.
- **Found and fixed by an actual in-game load, third occurrence**: the target/source picker's
  filter was silently wrong -- clicking a chip could filter by a *different* target than the one
  labelled on it, and the "All X" chip could end up filtering by a specific target instead of
  clearing the filter (confirmed by a screenshot: a target chip appeared selected while the KPIs/
  table/side-panel were still showing the full pooled sum). Root cause in
  `Analysis:RefreshPicker`: `local values = { nil }` followed by `table.insert(values, ...)` in
  a loop. A table whose first real content is a `nil` hole has an **undefined/zero length** in
  Lua (`#{nil}` is `0`), so `table.insert` -- which appends at `#t + 1` -- silently overwrote that
  first slot instead of appending after it, shifting every subsequent chip's `.value` (used for
  filtering) one position off from its `.label` (what's actually shown/clicked). Fixed by building
  `labels`/`values` with direct indexed assignment (`labels[i + 1] = ...`) instead of
  `table.insert`, which never depends on `#t`. Verified standalone with plain Lua before and after
  the fix (`{nil}` + `table.insert` really does misbehave exactly this way, independent of
  anything Turbine-specific -- this one's a pure Lua footgun, not an engine quirk). **General
  lesson**: never seed an array-style table with a leading `nil` and then `table.insert` into it;
  either pre-size with explicit indices or start the table genuinely empty and insert the "nil"
  placeholder's *label* separately from a value that defaults to nil via normal indexing.
- **Found and fixed by an actual in-game load, fourth occurrence**: the graph looked completely
  empty even with real combat data behind it. The design's own spec is "area fill at 13% opacity
  **under a line**" -- the implementation had the 13%-opacity area but never drew the line, and a
  13% tint of a mid-saturation purple against a similarly dark window fill is close enough to
  invisible at a glance that it read as "not working" rather than "very subtle." Added a solid
  (not tinted) 2px "cap" `Control` on top of each bucket's area column, in `UI/AnalysisGraph.lua`
  -- same one-`Control`-per-bucket technique as everything else in `Graph`, just a second pooled
  layer (`self.caps`, mirroring `self.columns`) instead of a real polyline (which axis-aligned
  Controls can't draw cheaply anyway -- same reasoning as the morale dashed-line simplification
  already noted above). Small values also now floor to a minimum 1px bar+cap instead of rounding
  to 0 and vanishing next to a much larger bucket in the same view.
- **The cap fix above was not the whole story -- the graph was still completely blank on the next
  in-game load.** Built a much more faithful offline harness this time: instead of hand-copying
  the bucket-slicing math into a throwaway script (which is what caught nothing the first time),
  wrote a `class(Turbine.UI.Control)`-compatible native-type stub (asserts on non-number
  `SetSize` args, tracks position/size/visibility per instance) and ran the **real** `Graph`
  class -- `Constructor` → `SetSeries` → `SetData` → `Redraw` -- against a real `Session` built
  from real `AddTaken` calls. It came back clean: 10 of 48 buckets visible, correct x/y/w/h,
  every value sane, nothing thrown. That meant the bug wasn't in `Graph`'s own logic at all, so
  the search moved outward to how `Graph` gets parented in `UI/Analysis.lua`, and found it:
  `self.graphHolder` (the plain `Control` the `Graph` is parented into) never once had `SetSize`
  called on it -- only `SetPosition`. Every *other* content container in `Analysis.lua`
  (`kpiRow`, `pickerRow`, `tableHolder`, `panelsHolder`, `rail`, ...) gets both in `Layout()`;
  `graphHolder` was the one silent omission. A zero-sized parent apparently doesn't render its
  children even though nothing in this codebase's own controls needs explicit clipping to be
  hidden by their parent's bounds otherwise (`SetClipMode` is opt-in and unused here) -- **not
  independently confirmed against another plugin**, inferred from elimination (data layer proven
  right, full render-call chain proven right, only the parent's own missing size was left).
  Fixed with one line: `self.graphHolder:SetSize(innerWidth, GRAPH_HEIGHT)` alongside the
  existing `SetPosition` call. **If any future container in this codebase looks structurally
  right (correctly parented, correctly positioned, children logically correct) but simply doesn't
  render, check whether *it itself* ever got a `SetSize` call before looking anywhere else** --
  a `SetParent` + `SetPosition` pair with no `SetSize` is easy to miss by eye since nothing about
  it looks wrong in isolation.
- **Also found the same load**: the mockup's Unicode pin glyphs (`◆`/`◇`, U+25C6/U+25C7) rendered
  as `?` -- not in this client's fonts. Session rail pins are now a small solid `Turbine.UI.Control`
  square (filled = pinned, dim = not), not a text glyph -- consistent with `docs/DESIGN.md`'s own
  fallback rule ("every mark in this design is a filled rectangle or a text glyph"). The `·`
  (middle dot, U+00B7) used elsewhere as a separator has not been reported broken and is a much
  more commonly-embedded character (Latin-1 vs. Geometric Shapes) -- left as is, but if it turns
  out broken too, the fix is the same: swap for an ASCII-safe separator.
- **Self-buff icon tiles have never rendered art in-game, across five separate fix rounds and
  in-game loads** (`UI/Analysis.lua`'s buff table, `UI/AnalysisGraph.lua`'s charted-lane icons) --
  always a plain, empty tile, no art and no initials fallback either (confirming `row.icon` *was*
  a real, truthy value the whole time; the `SetBackground` branch was always the one running).
  Tried and abandoned, each disproven by a real in-game load before moving to the next: (1)
  `SetStretchMode(2)` alone; (2) adding `SetBlendMode(AlphaBlend)` before `SetBackground`,
  reasoned from menu/list-icon precedents (`CombatAnalysisIcon.lua`, `EffectOverview.lua`) that
  turned out not to be the same situation (icons layered over other content, not a bare tile);
  (3) clearing `SetBackColor` to transparent on the icon-branch, reasoned from noticing no
  confirmed precedent combines an opaque `BackColor` with a `SetBackground` image on the same
  Control; (4) matching `Turbine.UI.BlendMode`/`SetVisible` exactly to Gibberish3's own timer
  icon element while still keeping the transparent-`BackColor` fix layered on top; (5) wrapping
  the raw icon id through `Turbine.UI.Graphic(id)` before `SetBackground`, reasoned from several
  *other* plugins doing this (Thurallor, Darf, PrimePlugins' `BackgroundHandler`, `Arebel`) --
  contradicted by Gibberish3's own code, which the round-5 grep had missed: its
  `ResolveTimerIcon` (`UTILS/Functions.lua`) returns a plain effect-icon id completely unwrapped,
  only ever rewriting *string* paths, for an unrelated external-image feature. Round 4's own
  diagnostic (`/reck buffs`, still in `Main.lua`, prints each tracked buff's `row.icon` value and
  Lua type) confirmed real data was never the problem: every tracked buff's icon is a real number
  in the `0x41000000`-`0x42000000` range, the same "0x41-prefixed" asset-id format used
  everywhere else in this environment that a bare `SetBackground(numericId)` is confirmed
  working -- so every round correctly stayed focused on the rendering side, it just kept guessing
  at *which* property was missing rather than rebuilding from a single working reference in full.
  **Current approach (round six): reset to a clean rebuild off Gibberish3's `IconElement`
  (`UI_ELEMENTS/TIMER/ICON/Element.lua`, `IconElement:UpdateContent`) line for line**, per direct
  user instruction after round five also failed, instead of layering another guessed property on
  top. That element is real, constantly-exercised code (Gibberish3's whole timer feature runs
  every rendered timer icon through it) and its exact sequence is: size the control to the art's
  own *native* size first (via a hidden probe Control backgrounded with the same image at
  `SetStretchMode(2)`, then `GetSize()` -- Gibberish3's own `UTILS.GetImageSize`), `SetStretchMode(1)`,
  *then* `SetBackground`, *then* resize down to the real target size, then `SetPosition` and an
  explicit `SetVisible(true)` -- never `SetBlendMode`, never `SetBackColor`, on that Control,
  anywhere in the file. Extracted as `Icon.Size`/`Icon.Apply` in `Constants.lua` (shared by both
  `UI/Analysis.lua` and `UI/AnalysisGraph.lua`, since it's root-level and both are siblings in
  `UI/`) so both call sites use the identical sequence rather than two hand-copies drifting apart.
  The `Turbine.UI.Graphic` wrap (round 5) was reverted in `Buffs.lua` -- `EffectIcon` is back to
  a bare `effect:GetIcon()` -- since Gibberish3's own code proves it isn't needed. The
  transparent-`SetBackColor` clear (round 3) is kept in both files' fill functions, since
  Gibberish3's icon control simply never has a competing `BackColor` in the first place (starts
  unset, stays unset) -- consistent with, not contradicted by, dropping it entirely would only
  matter for a pooled row that previously showed the initials fallback and now needs to show
  real art, a case Gibberish3's own single-purpose icon element never has to handle. **Round six
  also did not fix it**, confirmed by a sixth in-game load. **Round seven, per direct user
  instruction**: stop stretching entirely -- `Icon.Apply` (`Constants.lua`) no longer resizes
  down to a fixed tile size at all. It still sizes the control to the art's own native size first
  (`Icon.Size`'s probe-control trick) and calls `SetBackground`, but that native size is now the
  *final* size -- no `SetStretchMode` call anywhere in the function, matching "use them in
  default size" literally. `Icon.Apply(control, image)` dropped its `width`/`height` parameters
  entirely (previously `Icon.Apply(control, image, width, height)`); both call sites
  (`UI/Analysis.lua`'s `FillBuffRow`, `UI/AnalysisGraph.lua`'s `DrawLanes`) updated to match. This
  will very likely make the art larger than the 14x14/16x16 tile slot it sits in -- expected and
  accepted for now, per the same instruction; layout can be widened to fit once the art is
  confirmed to render at all. **Round seven was the first one to actually show art**, confirmed
  by a seventh in-game load -- progress, not a repeat failure, but the art rendered see-through:
  the icon's own soft/transparent edges blended straight through to whatever sits behind the
  control instead of compositing against anything opaque, since `iconInset`'s `BackColor` is
  deliberately fully transparent (round 3's fix, kept through every round since). **Round eight**:
  added `SetBlendMode(Turbine.UI.BlendMode.Overlay)` back into `Icon.Apply`, deliberately not
  `AlphaBlend` (round two's value) -- every confirmed-working precedent that renders a flat,
  non-see-through icon this way (`PlayerFrame.lua`'s class/checkmark/ready-check icons) uses
  `Overlay`; `AlphaBlend` is specifically the one that respects source alpha, which is the exact
  transparency this round is trying to eliminate. **Not yet confirmed in-game** (round eight).
  **`Turbine.UI.Lotro.EffectDisplay` was considered and rejected for this table**: every confirmed
  working use of it anywhere in ~1MB of real plugin code (`VitalSelf/UI/EffectIcon.lua`,
  `PrimePlugins/Vitals/EffectBox.lua`, `PrimePlugins/PartyVitals/EffectBox.lua`,
  `PrimePlugins/RaidTools/Counter.lua`, `PrimeUITools/EffectBoxes.lua`'s non-`Simple` branch) calls
  `:SetEffect(effect)` with a live `Turbine.Gameplay.Effect` object -- there is no icon-id-only
  entry point anywhere. The buff table and lane icons need to render buffs from **closed**
  sessions, often long after the underlying effect has faded and is no longer in
  `_G.lp:GetEffects()` -- `Buffs.lua` deliberately caches only the numeric icon id
  (`Buffs.Icons[name]`), not the effect object, for exactly this reason. `EffectDisplay` cannot
  serve that case at all, so the fix stays on the plain-`Control`+`SetBackground` path this
  codebase already uses elsewhere. If a future change wants richer icon art (native border/glow)
  for buffs that are *still currently active*, that would need a separate live-effect lookup
  (matching by name against `_G.lp:GetEffects()` at render time) with this fixed path kept as the
  fallback for anything not currently live -- not a wholesale swap.

**The analysis window's plot is now a REAL LINE GRAPH (v0.6.0), and every word of how it is drawn
was paid for by six rounds of in-game probing.** The morale background stays a bar graph and the
live meter's sparkline is untouched -- both explicitly out of scope per direct user request. The
full record is `docs/redesign/GRAPH_RESEARCH.md` section 7; the short version, because every one of
these dictates a line of `UI/AnalysisGraph.lua` and none is optional:

1. **`SetRotation` is ABSENT on `Turbine.UI.Control` and present on `Turbine.UI.Window`.** On a
   Control the call throws. Every segment in the pool is a Window; Gibberish3 rotating only Windows
   was never a style choice.
2. **A rotation applied before the control has painted is silently dropped.** One apply on a LATER
   frame is enough and it sticks. This is why `Graph:Redraw` only *arms* a pass (`rotateIn`) and
   `Graph:FlushRotation` runs it, driven by `Analysis:Update`. Three rounds of a completely flat
   plot were this one fact.
3. **The control's rect never rotates -- the IMAGE is rotated and then FITTED to the rect.** So a
   2px-tall control can never be a diagonal at any angle: a rotated white rectangle refitted into a
   2px slot is still a 2px horizontal bar. The segment control is instead a **SQUARE whose side is
   the segment's own LENGTH**, centred on the segment's midpoint, carrying a full-width band through
   a transparent square. A square rect makes the fit a uniform scale,
   so the rotated band stays straight at exactly the angle asked for; any other aspect ratio shears
   it. The squares overlap heavily by construction and that is fine -- the sprite is transparent
   outside its band, confirmed composing correctly.
4. **Positive z turns the opposite way from screen space, so the angle is NEGATED.** Without that
   every segment draws mirrored about its own midpoint: right length, right centre, both ends on
   the wrong side, nothing meeting at the joints.
5. **Scaling an image needs an exact call order** -- `SetSize(imageW, imageH)` ->
   `SetBackground` -> `SetStretchMode(1)` -> `SetSize(target)`. With the target size set first,
   every stretch mode **tiles** instead. `DrawSegment` follows it literally, and re-runs the whole
   sequence on every draw rather than hoisting the first three calls into the constructor --
   nothing establishes that resizing an already-configured control rescales rather than tiles, and
   redraws are not per-frame. Tiling is the symptom if that optimisation is ever tried and is wrong.
6. **`SetBackColorBlendMode(Overlay)` + `SetBackColor` tints a white image**, so one sprite serves
   every series colour. Note `SetBackColorBlendMode`, *not* the `SetBlendMode` the self-buff icon
   saga above fights with -- a different call with its own independent precedent.
7. **The stroke is a LADDER of eight sprites, not one**, and this is the one thing a first in-game
   load caught rather than a probe. Because the control is sized to the segment's own length and
   the band is a *fraction* of the sprite, a single sprite draws a stroke proportional to length --
   about 1px across a flat second and 6px up a steep spike, reported as "the width of the line is
   very different depending on the angle" (it is the length, not the angle). `StrokeSprite(side)`
   picks the rung whose `band * side / 64` lands nearest `STROKE_TARGET`, holding the drawn stroke
   between roughly 1.7 and 2.2px across every length the plot produces. The fractional 1.5 rung is
   load-bearing: whole-pixel bands can only manage 1.4 or 2.8px on the longest segments.
   `tools/icons/build_icons.py` must keep the same list as `STROKE_SPRITES`.

**Two of those correct things written elsewhere in this file.** `SetStretchMode` does not simply
"tile" (round three's conclusion) -- it tiles *when the size was set first*, which is also why
`Icon.Apply` has never been able to scale a buff icon, and is the most likely fix for that whole
saga. And "a control is not clipped to its parent" (round one) was wrong: **Controls clip, Windows
do not** -- that cell's subject was a Window, built in the command's default flavour.

**Three lessons from the probe rounds themselves, which cost more than the answers did.** *A probe
subject must be able to LOOK different under each hypothesis it is meant to separate* -- round one
drew flat colours and uniform white blocks, and "rotation does nothing" and "rotation turns the
content inside a fixed rect" render those identically. *A probe cell inherits whatever default the
command was invoked with*, so record which flavour produced an observation before generalising.
And *when a cell renders nothing, that is a result about the RECIPE, not a missing answer to the
question the cell was written to ask* -- round two's blank icons were a stretch-mode bug being
mistaken for a rotation one.

**`/reck probe` (`UI/RotationProbe.lua`) has now answered everything it was built for and should be
deleted** -- along with its command, `Resources/wedge.tga`, `Resources/line.tga`,
`Resources/line_long.tga`, and the `windows.probe` key it leaves in saved settings -- once the line
graph itself is confirmed in-game. **Not yet confirmed in-game**: the plot as ported. The failure
signature to know is a plot of long flat bars punched through the data, which is what a segment
drawn in a thin unrotated rect looks like -- and it is not by itself a diagnosis, since no
rotation, a rotation the engine ignores, an image that never rendered, and rotate-then-fit inside a
thin rect all produce it. Segments drawn at the right angle but not meeting at the joints is the
sign question (item 4) rather than any of those.

**Window chrome brought in line with Gibberish3/LootLogs, per direct user request.** Every text
glyph this codebase used as a UI control (`UI/Frame.lua`'s "x" close `Label`, the search box's "x"
clear `Label`, the session rail's plain filled/dim pin square) is now a real icon instead --
`Resources/*.tga` (new folder; `Resources/ICONS.md` has the source and licence, `tools/icons/
build_icons.py` rebuilds them from Phosphor Icons, MIT licensed, the same source Gibberish3's
`RESOURCES/` and LootLogs' `Ressources/` already draw from). Read both those folders' chrome first
(`Gibberish3/OPTIONS2/ELEMENTS/PanelWindow.lua`, `LootLogs/UI/Window/PanelWindow.lua`) -- they are
independent re-implementations of the *same* close-button shape (a plain `Control` sized 22x22,
transparent at rest, `Theme`'s hover fill on `MouseEnter`, a 16x16 child `Control` centred inside
it with `SetBlendMode(Overlay)` + `SetBackground(path)`) -- which is a strong confirmed-working
precedent, not a guess. `UI/Frame.lua`'s close button (`self.closeButton`/`closeIcon`, replacing
`self.closeLabel`), the session rail's pin (`Analysis:BuildSessionRow`, now `Resources/pin_on.tga`
/`pin_off.tga` swapped by state -- the same two-full-icon-no-tint technique as Gibberish3's own pin
toggle, `OPTIONS2/WINDOW/LIBRARY/LibraryItem.lua`) and the search box's magnifying-glass/clear
glyph (`Analysis:BuildSearchBox`, now `Resources/search.tga`/`cross.tga` -- matching LootLogs'
`UI/Window/Sidebar.lua`, the same file this box's `Turbine.UI.TextBox` itself was already ported
from) all follow this exactly. `Frame:Close()`'s Escape-key handling and `Resize()`'s reposition
logic are untouched beyond renaming `closeLabel` to `closeButton`. Offline-verified: `windows_test.lua`
and `analysis_test.lua` both construct the real `Analysis`/`DeathCause` windows (which is where the
close button and, for `Analysis`, the search boxes and session rail actually get built) and both
still report zero failures, so nothing in the construction path throws or mis-sizes under the stub.
**Not yet confirmed in-game**: this is the same residual risk every other `SetBackground` +
`BlendMode.Overlay` icon in this codebase carries (see the self-buff icon tile saga above) --
plausible, pattern-matched against two independent *confirmed-working* precedents rather than one
guessed-at reference, but not proof until a real load shows the glyphs actually painting instead of
rendering as an empty tile or a solid block. If they don't, re-read that saga's round six/seven/eight
before assuming the cause is something new -- the same `Icon.Apply` sequence in `Constants.lua` is
right there as a second, already-hardened reference for what this engine actually needs.

**Skill table and buff table each got a search box** (`Analysis:BuildSearchBox`, wired in
`BuildTable`/`BuildBuffSection`), filtering by skill/type/who name and buff name respectively,
case-insensitive substring. This is the first use anywhere in this codebase of
`Turbine.UI.TextBox` -- confirmed only against a same-shape precedent in a sibling plugin
(`LootLogs/UI/Window/Sidebar.lua`'s own sidebar search: `Turbine.UI.TextBox()`,
`SetMultiline(false)`, `TextChanged`/`FocusGained`/`FocusLost` events, and `SetText("")` not
itself firing `TextChanged` -- the clear glyph updates the filter directly rather than relying on
the event), not against any prior use in this plugin. `tools/offline/stub.lua` needed two new stub
methods to even load this (`Turbine.UI.TextBox` as a class alias and `Control:SetMultiline`) --
neither existed before because nothing in this codebase had touched a text-entry control.
**Not yet confirmed in-game**: whether the box actually accepts keyboard focus/typing, whether
`TextChanged` fires per-keystroke as assumed (bufferless filtering depends on it), and whether
`FocusGained`/`FocusLost` fire in a game window the way they do in LootLogs' distributed one.

**Both tables are also sortable by every one of their columns** -- click a heading to sort by it,
click the same heading again to reverse. Each header column is now a mouse-visible `Control`
(`self.tableHeaderCells` / `self.buffHeaderCells`) with the header `Label` parented *inside* it and
left mouse-invisible, so the column's 8px padding is clickable too and the cell can carry the
`Theme.Hex.Hover` fill on `MouseEnter` -- the same hover-wrapper-around-a-mouse-invisible-child
shape as `Frame`'s close button and the search box's clear glyph. That these receive clicks at all
inside a **mouse-invisible parent** (`tableHeaderRow`/`buffTableHeader`) is not a new assumption:
the picker chips (inside `pickerRow`) and the session-rail rows (inside `rail`) already work
exactly that way in-game. The direction marker appended to the sorted column's label is ASCII
`" ^"`/`" v"` (`SORT_ASC`/`SORT_DESC`), not the mock's Unicode triangles -- same reason the buff
section's own caret is `"v"`/`">"`. First click is descending for numeric columns and ascending for
name columns; the two sort states (`self.tableSort`/`self.buffSort`) are ephemeral like the search
text, and their defaults reproduce exactly what each table used to hardcode (skill table TOTAL
descending, buff table UPTIME % ascending, which is `Buffs.Stats`' own worst-uptime-first order).
Three things worth knowing before touching this: every sort **value** is the number the cell
actually displays (`TableSortValue`/`BuffSortValue`), so the order always matches what's on screen
-- CRIT / DEV is one column showing two percentages, so it sorts on the combined crit+dev rate;
both comparators carry a name/total tiebreak because `table.sort` needs a strict weak ordering or
it can raise "invalid order function for sorting", and AVOID/HITS/CRIT tie constantly; and
`RefreshTableColumns` resets the sort to TOTAL descending when the active view's column set doesn't
contain the current sort key (AVOID is damage-only), so a heal view is never silently ordered by a
column it doesn't show. Only the skill table's *sorting* changed -- the share bar is still scaled
against the largest total in the list, not against the top row. Offline-verified (`analysis_test.lua`
drives real `MouseClick` on both tables' header cells and checks the rendered column order,
the marker moving between columns, the row count surviving a re-sort, and the AVOID fallback).
**Not yet confirmed in-game**: only that the click actually lands on the header cell rather than
somewhere else -- the precedent above is strong but is the same category of pattern-matched-not-
proven as everything else in this section.

**The analysis window's height cap, the skill/buff split, and the buff collapse toggle**, all one
change per direct user request. (1) **Height** was capped at a hardcoded 880 -- it is now
`MaxHeight()` in `UI/Analysis.lua`: the display's own height (`Turbine.UI.Display.GetHeight`,
confirmed-working precedent in `FervourFocus/UI/SettingsPanel.lua` and `Darf/UI/framework.lua`,
read through a `pcall` like every other native read here) less a 40px margin, falling back to the
old constant if the read fails. `MIN_HEIGHT` stays 600, `MAX_WIDTH` stays 1440 -- only height was
asked for. A saved size is re-clamped on load rather than restored verbatim, so a geometry saved
on a bigger screen cannot open taller than the display it lands on. (2) **The skill table and the
bottom row (SELF BUFFS + the two side panels) are now separated by a draggable splitter**
(`BuildSplitter`/`SnapSplit`/`DragSplit`), which occupies the gap that already sat between them
and so costs no vertical space. Drag shape is `RangeSlider`'s exactly -- press offset stored on
`MouseDown`, `args.Y` re-read on `MouseMove` (relative to the handle, so it stays correct as the
handle moves under a still-pressed mouse), cleared on `MouseUp` -- and the split **snaps to whole
buff rows**, for the same reason the slider snaps to bucket stops: it keeps the row grid aligned
and bounds how many full `Layout()` passes one drag can trigger to one per row crossed. Two
things here are load-bearing and were both found by an offline check rather than by reading:
`self.splitBottom` is the user's **preference** and `self.splitEffective` is what the window could
actually give it last pass -- `Layout()` must never write the preference back, or one pass at a
short window height silently overwrites the split for good and growing the window again doesn't
restore it; and the clamp inside `SnapSplit` works in **whole rows**, not pixels, because a clamp
landing on an arbitrary pixel height doesn't survive being snapped again next pass (it rounds to
a neighbouring row, so shrink-then-grow lands somewhere the user never dragged to). Persisted as
`windows.analysis.split`. (3) **The SELF BUFFS collapse toggle is gone** -- caret, `ToggleBuffSection`,
`self.buffsOpen` and the `buffsOpen` setting -- since dragging the splitter to the bottom does the
same job and the two were redundant. The section header is a plain, non-clickable label now, and
`RefreshBuffSection` always lists every matching buff: the `ListBox` scrolls, so a short bottom row
means scrolling, never dropped rows. That also took the buff row count out of `RefreshContent`'s
shape-change relayout check (`layoutBuffRows`/`buffRowsWanted`, both removed) -- the block's height
is the splitter's now, not its content's, so listing more buffs can no longer trigger a re-layout.
**Confirmed in-game**: the splitter works exactly as intended.

**The resize gripper was "extremely sensitive" in that same load, and the cause is worth knowing
before writing another drag handler here.** Its `MouseMove` did `w = currentWidth + (args.X -
pressOffsetX)` -- which is only an *increment* if the gripper itself moves to keep up. It didn't:
the gripper's position was set in `Layout()` only, and `Layout()` is deliberately deferred to
`MouseUp` (see the comment in `BuildResizeGripper` about not rebuilding table rows and 48 graph
buckets on every drag tick). Because `args.X`/`args.Y` are measured **relative to the control**,
a mouse held 40px from the press point reported the same +40 on every single move event, and each
one added another 40px to the window -- so the window ran away from the pointer, faster the more
events the client delivered. Fixed by moving `self.gripper:SetPosition(width - 12, height - 12)`
out of `Layout()` and into `Analysis:Resize`, so it now happens on every resize, including the
per-tick ones during a drag; the arithmetic is then a true increment and a stationary mouse adds
nothing. **The general rule this establishes**: any drag handler in this codebase that reads
`args.X`/`args.Y` off the dragged control must move that control inside the same `MouseMove`, or
its deltas double-count. `RangeSlider` and the splitter both do (their handles are repositioned by
the very call that consumes the delta), which is exactly why those two always tracked the mouse
one-to-one while the gripper did not. `tools/offline/analysis_test.lua` section 17 pins this with
a mouse model that reproduces the client's control-relative coordinates: with the fix reverted,
three move events with the pointer *held still* drive the window from 920px to the 1040px cap.

**Not yet confirmed in-game**: that `Turbine.UI.Display.GetHeight` returns the usable client
height rather than something larger, and the re-tuned gripper drag itself.

Two Design-token values `docs/DESIGN.md` names but never gives hex for (`--color-accent-200`,
`-300`, `-500`, `-700`) were pulled directly from the mockup's own CSS custom properties and
added as `Theme.Hex.Accent200/300/500/700` in `Constants.lua` -- see that file's comment. If a
future design revision changes the mockup's accent scale, re-check those four values there.

**Performance pass, one new unverified-in-game assumption**: `Theme.Color`/`Theme.Mix`
(`Constants.lua`) used to construct a fresh `Turbine.UI.Color` on every single call. That is
called from genuinely hot paths -- the live meter's sparkline redraw (up to 30 calls/refresh at
10Hz) and the analysis graph's per-bucket morale/series draw (~150 calls per `Graph:Redraw()`) --
enough native-object churn per second of combat to plausibly be the "performance issues" felt
in-game. Both functions now cache by hex string (`Theme.Mix` by `fg|bg|t`) and hand back the same
`Turbine.UI.Color` instance to every caller that asks for that exact colour, rather than a fresh
one each time. **The one thing this assumes and does not prove**: that a `Turbine.UI.Color`
handed to many different controls' `Set*Color` behaves as a plain immutable value (copied into
each control's own render state), not as a live reference multiple controls end up sharing. Every
call site was grepped first and none of them ever mutates a `Color` after construction (no
`SetR`/`SetG`/`SetB`, no field assignment) -- consistent with, but not proof of, value semantics
-- and no other installed plugin (`VitalSelf`/`Gibberish3`/`CombatAnalysis`/`LootLogs`/etc.) has a
"share one Color instance across controls" precedent to check this against either way, so this is
the same category of educated-guess-pending-a-real-load as everything else in this section.
Offline-verified: the cache does return the identical object for the identical hex/mix args and a
different one for different args (`tools/offline` exercises `Theme.Color`/`Theme.Mix` and
`Session:ActiveSeconds`' fast path below through the real classes). **If colours ever render
wrong, shared, or flickering across multiple controls after this change, this caching is the
first thing to suspect and revert** -- go back to a fresh `Turbine.UI.Color()` per call. Also in
this pass: `Session:ActiveSeconds()` (`Session.lua`) used to rescan every active second in the
fight on every call; the unscoped whole-fight case (what the live meter's rate calculation calls
at 10Hz) now reads a running count `Touch()` already maintains, no rescan. The ranged-range case
(the analysis window's slider) is untouched, since the range varies per call and there's nothing
to cache. And the death window's countdown label (`UI/DeathCause.lua`) used to reformat and
`SetText` every single rendered frame for a number that only visibly changes once a second; it now
only touches the label when the displayed integer second actually changes -- the countdown bar
itself is untouched and still updates every frame, since that one needs to look smooth.

**A session now starts and ends with combat, not with any parsed event** (reported in-game: a heal
cast out of combat started a "fight", and it never ended for as long as heal-over-times kept
ticking). `Session.endTime` moves on every recorded event, and `Sessions.Tick()` closed on it, so
one HoT rotation could hold a session open indefinitely and archive a fight that never happened.
There are now two clocks: `endTime` (any recorded event, unchanged) and **`combatEndTime`** (damage
in either direction, a temp-morale loss, a defeat -- or a heal that landed while the client had the
player flagged in combat). `Sessions.Tick` closes on `combatEndTime`, and `Sessions.Close`'s
too-short discard reads `Session:CombatDuration()`, so a 2s scuffle padded out by 4s of heal ticks
is judged as the 2s fight it was. Heals are gated on `Sessions.InCombat()`: in combat they open and
extend a session like a hit; out of combat they are still *recorded* into whatever session is open
(the last ticks of a HoT do belong to the fight just fought) but can neither open one nor postpone
its close. A revive no longer opens a session either -- it is the end of a fight, never the start
of one. The combat flag comes from `_G.lp:IsInCombat()`, **confirmed-real LocalPlayer API used
identically by four independently-written installed plugins** (`FervourFocus`, `Gibberish3`'s
`TRIGGER/COMBAT/Functions.lua`, `Darf/MiniRaid`, `Thurallor`) -- not a guessed Turbine shape. It is
refreshed on the 4Hz heartbeat (`Sessions.Tick`) and cached, deliberately **not** by hooking
`InCombatChanged`: FervourFocus and Gibberish3 both assign that field slot outright, so hooking it
would be a clobbering contest with them (the chain-don't-clobber trick `Session.lua` uses for
`MoraleChanged` only works if everyone plays along, and those two don't), and a flag up to 250ms
stale cannot change whether a heal belongs to a fight. The read is `pcall`'d and falls back to "not
in combat", i.e. to "heals never open a session on their own" -- the safe direction. Offline-
verified end to end: `tools/offline/lifecycle_test.lua` drives real chat lines through
`Turbine.Chat.Received` plus real `Sessions.Tick` calls. **Not yet confirmed in-game**: that
`IsInCombat()` on the captured `_G.lp` handle tracks the real combat flag (the four precedents all
call it on a freshly-fetched instance in an event handler, this one reads a handle captured at
plugin load), and how long after the last hit the client actually drops the flag -- if a healer's
fight ever splits into fragments, that lag is the first thing to check.

**Later report: performance "very bad" specifically while a fight is being recorded**, prompting
a look at `Session:MoralePct()` (`Session.lua`), the one native read on `AddTaken`'s/
`AddTempMoraleLoss`'s own path (i.e. once per damage-taken chat line, including avoided hits that
never change morale at all -- a busy fight with several attackers can mean many of these per
second). It used to call `_G.lp:GetMorale()`/`GetMaxMorale()` inline, wrapped in a **freshly
allocated** `pcall(function() ... end)` closure every single time -- real per-event garbage on
Lua 5.1's collector, the same category of cost the `Theme.Color`/`Theme.Mix` caching pass above
already targeted, just not caught in that pass. Replaced with a cached `MoralePct`/`MaxMorale`
pair, kept fresh by the real `MoraleChanged`/`MaxMoraleChanged` events on `_G.lp` instead --
confirmed real `Turbine.Gameplay.LocalPlayer` events, `VitalSelf/UI/Vital.lua` hooks both the same
way (`self:Hook(_G.lp, "MoraleChanged", ...)`). `AddTaken`/`AddTempMoraleLoss` now just read the
cache, no native call and no closure on their own path at all. `UI/AnalysisGraph.lua`'s morale
axis label had its own independent `pcall(_G.lp:GetMaxMorale())` on every `Redraw()` for the same
value -- folded into the same cache rather than duplicating the defensiveness a second time.
**A real compatibility risk this raised, handled rather than ignored**: `_G.lp.MoraleChanged` is
a single field slot, not a real multi-subscriber event -- confirmed by reading the identical
`AddCallback`/`RemoveCallback` convention independently copied into at least six other installed
plugins (`VitalSelf`, `VitalTarget`, four `PrimePlugins` modules), which exists specifically to
chain multiple subscribers onto one slot without clobbering each other. Since `VitalSelf` is
confirmed installed alongside this plugin and already hooks the same two events on the same
`LocalPlayer` instance, a raw overwrite here would have silently broken its live morale bar.
`Session.lua` captures whatever was already in the slot before hooking (`previousMoraleChanged`/
`previousMaxMoraleChanged`) and calls through it first via `CallField()`, which handles both a
plain function and the table-of-functions shape that convention leaves behind -- the same
chain-don't-clobber reasoning `Events.lua` already applies to `Turbine.Chat.Received`. Restored on
unload via `Session.ShutdownMorale()`, called from `Main.lua`'s `plugin.Unload`. Offline-verified
(all five non-`load` harnesses set up `_G.lp` with `GetMorale`/`GetMaxMorale` before `import
"Reckoning.Session"`, exactly the order this hook needs, so `tools/offline/run.sh` exercises the
cache-population path already; the event-firing path itself cannot be exercised offline since the
stub's `_G.lp` is a plain table, not a real Turbine object that invokes the field on change).
**Not yet confirmed in-game** -- specifically, whether `_G.lp.MoraleChanged`/`MaxMoraleChanged`
actually fire as often (and only as often) as real morale changes, and whether chaining through a
pre-existing `VitalSelf` hook this way leaves its morale bar visibly unaffected. If morale-derived
numbers (the death window's per-row morale%, the analysis graph's morale lane) ever look stale or
wrong in-game after this, check whether the events are firing at all before assuming the cache
logic itself is wrong.

**Follow-up performance report, after the pass above, tried something and reverted it -- read
this before ever calling `collectgarbage()` from this codebase again.** The game was still
getting progressively laggier over several fights, which rules out steady-state allocation rate
(already addressed above) as the sole cause. Audited every global table this codebase ever
appends to (`Sessions.list`, `Buffs.Icons`, the two `On*` callback lists, every UI pool) for
unbounded growth -- all capped or bounded, no reference leak found. That pointed at Lua 5.1's own
collector instead: `Sessions.Close()` is the one moment a whole fight's tracking data turns to
garbage at once, which its incremental collector (steps sized to *ongoing* allocation rate) is a
poor match for. `CombatAnalysis` has the same "free state, then `collectgarbage()`" pattern, so
that call was added to `Sessions.Close()`, right after `TrimRing()`, gated to the real-archive
path only.

**This was wrong, and made things measurably worse.** `/reck dump`'s new memory readout (added in
the same pass) showed nothing alarming on its own -- 4192 KB in one session, 2710 KB fresh after a
reload, not a runaway climb. What came back instead was a much more specific and much worse
symptom: the death loading screen taking 2-3x longer than normal, then 5-10s of total
unresponsiveness after it loaded. That is not what a slow-but-harmless GC pause in a 3-4MB heap
would produce -- it is exactly what a **client-wide** GC pause would produce. LOTRO plugins share
ONE Lua VM across every loaded addon, not one per plugin (this install has a lot of them --
RaidTools, LootLogs, CombatAnalysis, Thurallor, Darf, TbdBars, and more). `collectgarbage()` with
no arguments forces a full stop-the-world collection of *that whole shared heap*, not just
Reckoning's own few MB -- and `Sessions.Close()` fires it ~5s after the last combat event, which
for a death is often right around when the player releases spirit and the real zone-transition
loading screen begins. A full sweep of a heap that likely spans tens of MB across every other
addon, landing at exactly that moment, is sufficient on its own to explain both symptoms. Reverted
in `Sessions.lua` (the call is left as a comment specifically so it doesn't get reintroduced the
same way twice) -- this codebase does not call `collectgarbage()` anywhere as of now.
**Lesson**: `CombatAnalysis`'s own `collectgarbage()` precedent is not actually a working
counter-example to this -- nothing establishes that its call sites don't have the exact same
shared-VM cost, only that nobody happened to report it. Precedent in a sibling plugin proves a
call is *accepted syntax*, never that it is *cheap* -- that has to be checked against what the
call actually does process-wide, not just against whether another plugin also calls it. If a
future change wants to nudge GC at all, `collectgarbage("count")` (read-only, already used by
`/reck dump`) is safe; anything that actually forces work (`collectgarbage()` bare or
`"collect"`) needs to be weighed against the fact that it is never scoped to this plugin's own
heap, no matter how it's justified.

The `/reck dump` memory readout itself is not reverted -- it is read-only and the only real
diagnostic available here (no profiler exists for this environment), and it's what caught this.
If lag reports come in again, get a `/reck dump` reading at the start of a session and again after
several fights before assuming growth is the shape of the problem -- the one data point gathered
so far does not show it.

**The actual reported symptom turned out to be older and more specific than general fight lag,
and unrelated to `collectgarbage()`**: the death loading screen itself taking 2-3x longer than
normal, then 5-10s of total unresponsiveness once it finishes loading -- present before any of the
performance work above, i.e. the real motivating complaint. Re-grepped every direct read of the
live `_G.lp` (`Turbine.Gameplay.LocalPlayer`) object across the whole codebase for whether it's
guarded. Found one clear outlier: `UI/LiveMeter.lua`'s `CurrentTargetName()` (`_G.lp:GetTarget()`)
is the *only* continuously-firing, unguarded read of it anywhere -- 10 times a second, unconditional
on combat state, because the live meter is permanently visible whenever enabled (see its own file
header). Every other read either already goes through `Buffs.Read()`'s deliberate `pcall`
(`Buffs.lua`'s own header explains why) or only fires on a rare event. `_G.lp` is captured once at
plugin load (`Main.lua`) and never re-validated -- death -> release spirit -> the zone-load
transition to the graveyard is exactly the kind of moment a captured native handle is most likely
to be temporarily invalid or mid-transition, and `CurrentTargetName()` is the one call still firing
straight through it, unthrottled, the whole time. Wrapped it in a `pcall`, same pattern as
`Buffs.Read()`: fail safe to "no target" rather than let a thrown error escape `LiveMeter:Refresh()`.
While in there, hardened the other two unguarded direct reads found by the same grep for
consistency and because one of them is a real correctness gap, not just a perf one:
`Session:MoralePct()` (`_G.lp:GetMorale()`/`GetMaxMorale()`) runs from `AddTaken`/
`AddTempMoraleLoss`, called directly from `Events.lua`'s chat dispatch with **no pcall anywhere in
that call chain at the time** -- an uncaught throw there would have aborted the whole `AddTaken`
call before the hit was ever logged to the row/bucket/event log (the damage silently vanishes from
tracking, not just a stutter) and could have propagated out into the chat dispatch itself; and
`UI/AnalysisGraph.lua`'s `GetMaxMorale()` read for the morale axis label, which only checked that
the method existed, not that calling it wouldn't throw.

**Also added a systemic backstop, not just the two/three found instances**: `Events.lua`'s entire
`Turbine.Chat.Received` dispatch had no error handling at all before this. It runs on every single
combat chat line, including bursts of them (exactly what a busy respawn/re-aggro produces), so an
uncaught throw there is not a one-off cost -- it's every subsequent line for as long as whatever
caused it stays true, which is a very plausible shape for "unresponsive for 5-10s." The dispatch
body is now a separate `Dispatch(args)` local function called via `pcall(Dispatch, args)`,
deliberately *not* wrapping the call to `previousChatReceived` (another plugin's own handler,
chained ahead of ours) -- only Reckoning's own logic. This is meant as a backstop for whatever the
next instance of this exact bug shape turns out to be, not a replacement for finding and fixing
real instances when they're found, the same trade this codebase already makes everywhere else
defensive (`Buffs.lua`: "a failed read is a no-op, never mistaken for real data").

**Not yet confirmed in-game.** This is reasoned from the single clearest candidate a full grep
turned up (the only continuously-firing unguarded native call in the codebase, correlated with
exactly the kind of state transition death/respawn causes) plus this codebase's own three-strong
history of bugs from the identical assumption (see the `args.ChatType`/`LocalPlayer.name`/
`ChatType.Death` entries above) -- not from a captured stack trace or profiler output, since
neither is available here. If the death loading screen is still long after this, the next thing to
check is whatever chat/combat lines are actually arriving in the few seconds around a death and
whether any of them hit a Turbine call this file doesn't yet guard -- the fix category (wrap the
call, fail safe, never let it propagate) is established either way, only the specific call site
would need to be found.

**The options panel became window 4** (`design_handoff_options_panel/`: `README.md`,
`IMPLEMENTATION_PLAN.md`, `SETTINGS_KEYS.md`, and an interactive HTML mock covering four
directions -- **1b, "Rail & pages", is the one built**; 1c and 1d are explicitly out of scope).
`/reck options` opens a 560x452 `Frame` with a category rail and seven pages, and the Plugin
Manager panel shrank to a stub with an **Open options** button. Roughly thirty new settings landed
with it; `Settings.lua`'s `DEFAULTS` is the single list, and `SETTINGS_KEYS.md` is the authority
for every range and label string. Things worth knowing before touching any of it:

- **There is no Accept, anywhere.** Checkboxes, segments, swatches and buttons write and
  `Settings.Save()` on change. Sliders write `_G.settings` live (so a preview follows the drag)
  but save on **release only** -- `Settings.Save` is a `Turbine.PluginData` write and one drag
  crosses dozens of stops. `tools/offline/options_test.lua` pins this by counting real
  `Settings.Save` calls across a six-move drag (it must be exactly 1).
- **A module-level table of theme hexes is now a bug, not a style.** `Theme.Presets` /
  `Theme.Series(role)` (`Constants.lua`) resolve a series colour per call, because a preset can
  change at runtime and a table built at load never sees it. Three separate tables were exactly
  that trap and were rewritten to carry a **role key** instead of a hex: `UI/LiveMeter.lua`'s
  `TAB_COLORS` (now `TabColor()`), `UI/Analysis.lua`'s `VIEW_META.color` (now `.role` +
  `MetaColor()`) and its `SERIES_FOR_VIEW` (now `SeriesForView()`), and `ChatPost.lua`'s own
  `VIEW_META.hex`. **If a fourth one is ever added, it will be stale from the day it is written.**
  Only the five *series* roles are presettable; `DamageSevere`/`DamageFatal`/`MoraleBg*`/`Type*`
  stay fixed, and the death window keeps its own ground on purpose.
- **`Analysis:RefreshContent` only re-declares the graph's series when the VIEW changes**, so a
  palette change alone would leave the plot on its old colours. `Analysis:ApplySettings` clears
  `self.graphSeriesView` to force exactly one re-declaration -- do not "simplify" that away.
- **The plot's bucket count is no longer a constant.** `settings.bucketWidth` (1s / 2s / Auto)
  makes it depend on the selected session's duration. `MAX_BUCKETS` (48) is the **pool** size and
  every pool in `UI/AnalysisGraph.lua` is still built at it; `self.buckets` is how many are live,
  and `Graph:SetBucketCount` hides the surplus (the draw loops only walk `1..self.buckets`, so a
  bucket left visible from a wider count would stay on screen forever). `GraphBucketCount(session)`
  is the one function both `Graph` and `Analysis:SyncBucketCount` derive from -- if those two ever
  disagreed, the range slider's stops and the seconds `RangeSeconds()` hands `Session:Slice` would
  silently describe different parts of the fight.
- **`Settings.Clamp` runs on load and on reset**, so every consumer can trust a numeric setting's
  range and an enum's value without re-checking. The enum guard is not cosmetic: an unknown
  `palettePreset` would put a nil hex into `Theme.Color`, and an unknown `numberFont` a nil font
  into `SetFont`.
- **`Settings.ResetWindow(windowKey)` is the single definition of what "Reset" does to a window**
  -- `/reck move <name>` and the options window's per-row Reset buttons both call it. It is the one
  place allowed to *replace* `_G.settings.windows[key]` rather than mutate it, because clearing the
  saved size and split is the point; everywhere else must still mutate (see `Frame`'s drag handler
  and the bug it used to cause).
- **The buff picker refuses a fourth charted buff; the analysis window's buff table drops the
  oldest.** That is deliberate and not an inconsistency to "fix": the picker greys every unchecked
  box the moment three are charted, so the refusal is visible, whereas greying rows in a long table
  would read as the table being broken.
- **Two settings ship with no consumer, and say so on the control itself**: `liveRows` ("Rows
  shown", Live meter) and `density` ("Row density", Appearance). Both describe structures this
  plugin does not have -- a per-skill row list in the live meter (the mockup draws one, but that is
  direction 1c's *preview strip*, not window 1 as built), and a shared row-height system (the three
  windows each have their own pitch, none of them 16 or 20, and the analysis window's splitter
  snaps to whole buff rows). They are stored, clamped and persisted so wiring them later is a small
  change; `Theme.RowHeight()` is where a `density` consumer would read it. **Do not quietly remove
  their sub-labels without also building the thing they describe.**
- **`announceSummary` cannot do what its label says**, and the Live meter page's closing note says
  so: a plugin cannot send to a chat channel without a user-clicked `Quickslot` alias (see the
  chat-posting section below). It writes the same summary line to your own chat window instead.
- **`postColor` is not in `SETTINGS_KEYS.md`** but was a real control on the panel this window
  replaces, so it lives on the Palette page rather than being stranded with no way to change it.

**Not yet confirmed in-game** for any of the above. The specific unknowns, in rough order of how
likely they are to bite:

1. **`Label:GetWidth()` measuring text.** `Segment` (`UI/Controls.lua`) tries it and falls back to
   a per-character estimate if it reads implausibly small, so a cell is never clipped either way --
   but which path actually runs in-game is unknown, and if it is the estimate the cells will be
   looser than the mock. Nothing else in this codebase has ever measured text (`ChipWidth` in
   `UI/Analysis.lua` estimates for the same reason).
2. **Mouse events reaching a page's children through the pane's `ListBox`.** The page is a
   mouse-invisible `Control` added as a ListBox item, with mouse-visible children inside it. Both
   halves have precedent -- `UI/Analysis.lua`'s buff rows are clickable ListBox items, and its
   picker chips and session-rail rows are mouse-visible children of mouse-invisible parents -- but
   the *combination* (mouse-visible grandchildren of a ListBox item) is not confirmed. **If the
   options window draws but nothing in it responds, this is the first thing to check**, and the fix
   is to make each row its own ListBox item rather than one page-sized item.
3. **`Turbine.UI.Lotro.ScrollBar` on this pane**, i.e. that the seven pages scroll and that only one
   scrollbar ever exists. Same `ListBox` + `SetVerticalScrollBar` pattern as the skill table, which
   is confirmed working.
4. **`SetOpacity` on the live meter's own `Frame`.** This is the *legitimate* use (a whole-window
   fade on a `Turbine.UI.Window` with no `BackColor` of its own, matching `VitalSelf`), not the
   banned one -- but it is the first time this codebase has actually done it since the tint saga.
5. **`_G.lp:GetPosition()` as a zone-change signal** (`Sessions.CheckZone`, for
   `dropOnZoneChange`). This one has **no precedent anywhere** in the ~1MB of installed plugin
   source this codebase checks its assumptions against -- grepped, and nothing reads a zone, map or
   region name. It is `pcall`'d and a failed read disables the feature permanently for that
   session, which fails in the safe direction (sessions kept, never wrongly dropped). If the
   feature simply never fires in-game, that read is why.

Phase 2 (window chrome) has **not** been exercised even offline -- it is pure `Turbine.UI`
(`Turbine.UI.Window`/`Control`/`Label`), which the offline harness described below cannot stub
meaningfully (no real layout, sizing, or mouse-event system to fake). It is syntax-checked only
(`luac -p`). Confirming it actually draws, drags, and persists its position needs an in-game
load.

Phase 1 (event pipeline) was verified **offline**, not in-game: `Utils/Class.lua`,
`Utils/Type.lua`, `Constants.lua`, `Parse/en.lua`, `Session.lua` and `Sessions.lua` were
`dofile`'d under a plain Lua 5.4 interpreter (this dev box has no Lua 5.1 and no real Turbine
runtime) against a hand-built `Turbine`/`_G.lp` stub, with `getfenv`/`setfenv`/`table.getn`
shimmed back in (all three are gone in 5.2+; the game's actual Lua 5.1 has them natively). Both
`reference/*.txt` fixtures were fed through the real dispatch logic this way and produced
correct aggregates (verified by hand against the raw lines) -- including the "Reflect" skill,
avoidance folding, the temp-morale ring row, and the "You have been incapacitated by
misadventure" self-death line correctly flipping `session.died`. That harness was scratch-only
and was not committed. **None of this exercised real Turbine.UI, `Turbine.Chat.Received`
registration order against other loaded plugins, or `Turbine.PluginData` -- those still need an
in-game load to confirm.**

**A real gap this left, found by an actual in-game load**: the harness called
`Trigger.ParseCombatChat` and the `Sessions.*` dispatch directly, hand-reimplementing the
mine/onMe branch inline -- it never went through `Turbine.Chat.Received` itself, so it could not
have caught a wrong field name on the real chat event object. `Events.lua` read `args.Type`,
which doesn't exist (the real field is `args.ChatType` -- confirmed against Gibberish3, LootLogs,
and CombatAnalysis, all three of which use it identically). `nil ~= Turbine.ChatType.X` is always
true, so every chat line was silently discarded before ever reaching the parser: plugin loaded
fine, UI drew fine, `/reck dump` after a real fight reported "no session data yet". Fixed, plus
added the `args.Message == nil` guard those same three plugins all have before touching the text.
**Lesson for next time**: anywhere this codebase reads a field off a Turbine-supplied event
object (`args.*`) without a same-directory precedent already confirmed working (mouse events were
fine -- `args.X`/`args.Y`/`args.Button` are a direct copy from `VitalSelf/UI/Vital.lua`'s already-
working drag code), that field name is a guess until grepped against real plugin source.

**A second, worse bug of the same shape, found immediately after fixing the first one**: fixing
`args.ChatType` still left every session empty. `LocalPlayer.name` (the bare property
`Trigger.ParseCombatChat` reads at five call sites, and that `Events.lua`'s own `mine`/`onMe`
check also reads) is **not a real Turbine property -- it is `nil`**. Confirmed by grepping every
other plugin: nothing anywhere assigns `.name` on a `Turbine.Gameplay` instance, only `:GetName()`
exists. Even Gibberish3's own `Variables.lua` (the source the parser was ported from) immediately
calls `LocalPlayer:GetName()` and stashes the result in a *different* table (`LpData.name`)
rather than trusting bare `.name` -- meaning the parser's own `LocalPlayer.name` reads were
**always dead code, even in Gibberish3**, just never exercised because nothing there relies on
those particular return branches. `CombatAnalysis` (a real working combat meter) hits this exact
same gap in its own local-player object and fixes it identically: `player.name =
player:GetName()`, a monkey-patched field assignment right after construction. `Main.lua` now
does the same: `LocalPlayer.name = LocalPlayer:GetName()`, once, right after `LocalPlayer =
_G.lp`. Since `nil ~= "AnyName"` is always true, this bug alone was sufficient to discard every
event except `TempMoraleLoss` regardless of the `args.ChatType` fix -- both had to be found.

**Both bugs share one root cause the offline harness structurally could not catch**: the harness
never went through the real entry points. It called `Trigger.ParseCombatChat` and `Sessions.*`
directly with a hand-reimplemented dispatch, and set `LocalPlayer = { name = "Whatever" }` as a
plain Lua table with the field already correct -- bypassing both real Turbine objects entirely
(`Turbine.Chat.Received`'s actual event shape, and `Turbine.Gameplay.LocalPlayer`'s actual
instance shape). Anything that depends on the *real* shape of a Turbine-supplied object, as
opposed to pure game logic, was invisible to it. If a third bug like this shows up, look there
first: any place code reads a bare field off something Turbine handed in, rather than a value
this codebase constructed itself.

**The predicted third bug did show up, and it was exactly that shape.** With both bugs above
fixed, regular damage/heal tracking worked correctly in-game (confirmed with real accumulated
numbers), but the death window never appeared -- even though `/reck testdeath` (which calls
`DeathCause:Show()` directly, bypassing detection) proved the window itself was fine. The user
captured a real combat log to a file and shared it; `Trigger.ParseCombatChat("The Utûgi Destroyer
incapacitated you.")` parsed correctly and `Sessions.OnSelfDefeat` fired correctly when tested
directly -- so the gap had to be upstream, in what never reached the parser at all.
`Events.lua`'s channel filter only accepted `Turbine.ChatType.PlayerCombat` /
`.EnemyCombat`. Defeat/incapacitate/succumb lines arrive on a **third, separate**
`Turbine.ChatType.Death` channel -- confirmed against `CombatAnalysis` (a real working combat
meter), whose own live parser gate (`Parser/Parser.lua`) is the identical three-way
`PlayerCombat`/`EnemyCombat`/`Death` check, feeding the *same* parser pipeline as damage/heal
lines, not a separate death-specific listener. `Gibberish3` itself never actually wires this up
(`Death` is referenced there only as a display-label string) -- so this one had no working
precedent in the plugin that the parser was ported from, only in a sibling plugin. Fixed by
adding `Turbine.ChatType.Death` as a third accepted channel in `Events.lua`'s gate, verified with
a probe script (`Turbine.Chat.Received` called directly, not hand-reimplemented) fed the real
captured line under both the old and new channel value. **Lesson reinforced**: a chat message's
`ChatType` cannot be assumed from which visible chat tab it showed up in -- LOTRO lets users
combine multiple channel types into one tab, so "it appeared in the Enemy tab" does not mean
`ChatType.EnemyCombat`.

## Load order

`Reckoning.plugin` names `Reckoning.Main` as the package entry point. `Main.lua` imports drive
everything else:

```
Utils/Type.lua  <->  Utils/Class.lua   (mutually importing; Class bootstraps the OOP system,
                                         then Type defines a final_class on it)
     |
Main.lua  ->  Constants.lua  ->  (Trigger = {} declared)  ->  Parse/en.lua  ->  Settings.lua
```

`Utils/Class.lua` / `Utils/Type.lua` are vendored unchanged from `VitalSelf` (renamed package
paths only, `VitalSelf.Utils.*` -> `Reckoning.Utils.*`) -- the shared Turbine OOP shim
(`class()`, `static_class()`, `abstract_class()`, `final_class()`, metatable single
inheritance + mixins). Treat them as vendored, not Reckoning-specific.

## Architecture

| File | Role |
|---|---|
| `Main.lua` | Import order, `_G.lp` / `LocalPlayer` globals, settings load, `/reck` shell command, `plugin.Unload`. |
| `Constants.lua` | `L` (localisation), `EventCode` / `AvoidType` / `CritType` / `DamageType` enums mirroring the parser's return codes, `Font` table (only the faces/sizes the design actually uses), `Theme` palette + `Theme.Color(hex)`, `Format` (`Number`/`Percent`/`Rate`/`Clock`, plus `CharCount`/`Truncate` -- UTF-8-safe, shared by the analysis window's picker chips and `ChatPost`'s line cap), `Icon.Size`/`Icon.Apply` (setting a numeric effect-icon id as a Control's background, modelled on Gibberish3's `IconElement` -- see "Build status" below). |
| `Settings.lua` | `Settings.Load()` / `Settings.Save()` / `Settings.FixColors()` via `Turbine.PluginData`, `DEFAULTS` as single source of truth, `COLOR_KEYS` for colour rebuild. |
| `Parse/en.lua` | `Trigger.ParseCombatChat` -- ported **verbatim** from `souruko/Gibberish3` (`UTILS/COMBATCHATPARSE/en.lua`). Do not rewrite it; `de.lua` / `fr.lua` are later drop-ins with the same signature. |
| `Session.lua` | The `Session` class -- one fight's aggregate (`agg.done/taken/healOut/healIn`, `buckets`, `lastTaken` ring). One `Add*`/`On*` method per event kind: `AddDone`, `AddTaken`, `AddHealOut`, `AddHealIn`, `AddTempMoraleLoss`, `OnDefeat`, `OnRevive`. Each `buckets[second]` entry also carries a `<field>ByWho[counterpartName] = amount` table alongside its pooled scalar (`done`/`taken`/`healOut`/`healIn`) -- added so the analysis window's graph can respect the target/source picker; the pooled scalar is always exactly the sum of its own `ByWho` table (`AddToBucket()` updates both together, in one place, so they can't drift apart). Verified offline (a synthetic multi-target fight, checked the per-target and pooled sums against hand-computed expectations). |
| `Sessions.lua` | The manager singleton (not a class): `Sessions.current` / `Sessions.list` (a ring of `settings.sessionsKept` -- 10/25/50 -- pinned exempt) / `Sessions.selected`; opens a `Session` lazily on the first own **combat** event, closes it after `settings.idleTimeout` seconds of combat silence via `Sessions.Tick()`, discards anything whose *combat* span is under `settings.minFightLength`. With `settings.mergeFights` off it instead closes as soon as the client's combat flag drops (with a 1s floor -- `UNMERGED_FLOOR` -- because damage opens a session before the flag has come up). `Sessions.CheckZone`/`DropUnpinned`/`ClearAll`/`SelectFallback` back `settings.dropOnZoneChange` and the options window's **Clear data**. `Sessions.OnClosed` / `Sessions.OnSelfDefeat` are the callback lists Phase 3/4 UI hooks into. **A session starts and ends with combat, not with any parsed event** -- see the heal-gating note in Build status. |
| `Events.lua` | Wraps `Turbine.Chat.Received` (chaining to whatever was already registered), strips `<rgb=#......>` tags and trims before calling `Trigger.ParseCombatChat`, dispatches into `Sessions.*`. Also hosts the heartbeat (`Events.heartbeat`, a bare `Turbine.UI.Window` with `SetWantsUpdates(true)`) that drives `Sessions.Tick()`, since session-close-on-silence has to run even when chat is quiet. `Events.Shutdown()` restores the previous `Turbine.Chat.Received` and stops the heartbeat -- called from `plugin.Unload`. The heartbeat also calls `analysis:SyncPostOverlay(false)`: the post button's quickslot overlay is a separate top-level Window that does not follow the analysis window's visibility, which is toggled from at least four places. It only re-*positions* -- it must never call `Activate`, which takes chat focus. |
| `Buffs.lua` | Self-**effect** uptime tracking -- **every** effect on the local player, benefit or not (the `IsDebuff` filter this file used to apply was dropped per direct user request: debuffs/DoTs on you are exactly what's worth reading next to a damage-taken graph). **`IsDebuff` is still read, but as a LABEL, not a filter**: `Buffs.Kinds[name]` caches `Buffs.Kind.Buff`/`.Debuff`/`.Unknown` at first sighting (re-probed as long as it reads Unknown, so a client that only answers once an effect is fully applied still gets a real label later), `Buffs.Stats` rows carry it as `row.kind`, and the analysis window renders it as the buff table's TYPE column. Three states, not a boolean, because `Effect:IsDebuff` is still not confirmed to exist here -- a missing or throwing method must read as Unknown (which is true) rather than silently labelling everything a buff (which would not be); the probe is `pcall`'d per effect rather than leaning on `Read`'s outer one, so a throw costs one label instead of abandoning the enumeration mid-walk. The module, its `session.buffs` field, `chartedBuffs`/`buffIgnore` and the `/reck buffs` command all keep the "buff" name -- read it as "tracked effect"; only the analysis window's user-facing label changed (SELF BUFFS -> SELF EFFECTS). The one remaining filter is the ignore list, which is the player's: `Buffs.Ignore` holds unverified best-guess defaults (mounts, travel), and `_G.settings.buffIgnore[name]` overrides them in **both** directions -- `true` ignores, `false` un-ignores a default, so `/reck buffs unignore Riding` actually works. Polls `_G.lp:GetEffects()` at 4Hz from Events.lua's heartbeat (**not** the live meter's Update, as the spec suggested -- that meter can be switched off and uptime must keep recording either way), opening/closing an interval per effect name on `session.buffs[name] = { intervals, apps }`. `Buffs.Stats(session, fromSec, toSec)` clips every interval to a range and returns uptime / uptime% / apps / longest gap, sorted. Data source is the live effect list, **not** parser event 17 -- event 17 carries no duration and no fade, so uptime from it would be a guess. Everything here is defensive (one pcall around the whole enumeration; a failed read is a no-op, never "everything faded"; the 0-vs-1-based index base of `EffectList:Get` is **detected**, by probing index 0, not assumed) because nothing in this codebase has touched `Turbine.Gameplay.EffectList` before -- see the three "guessed the shape of a Turbine object" bugs in Build status. |
| `Utils/Class.lua`, `Utils/Type.lua` | Vendored OOP shim, see above. |

| `UI/Frame.lua` | `Frame` (extends `Turbine.UI.Window`) -- shared chrome every window subclasses: background + 1px border Controls, header with `TrajanPro13` title + close glyph, manual drag on the header, position persisted to `_G.settings.windows[key]`. The header drag fires an optional `frame.OnMoved` hook on every `MouseMove`, for subclasses owning a control positioned in **screen** coordinates (the analysis window's post-button overlay, its own top-level Window) -- deferring that to `MouseUp` would strand it for the whole drag. `Frame` knows nothing about what the hook does. |
| `UI/Bar.lua` | `Bar` -- 1px-border track Control with a fill child; `SetPercent(pct)` sets width directly (no tweening anywhere, per `docs/DESIGN.md`). |
| `UI/Row.lua` | `Row` -- a fixed-column-offset row of Labels for tables; pooled and reused across refreshes, never rebuilt per redraw. |
| `UI/RangeSlider.lua` | `RangeSlider` -- the two-handle time-range control under the plot. Snaps to the graph's 48 bucket stops, not to pixels, so the numbers in the window and the marks on the plot agree exactly and only 48 distinct ranges per endpoint can ever be asked for. Drag uses the same MouseDown/MouseMove/MouseUp shape as `Frame:WireDrag` and the resize gripper -- confirmed-working precedent, no new assumption about mouse delivery. Handles clamp to `other handle -/+ 1`; a zero-width range would divide by zero everywhere downstream. |
| `UI/RotationProbe.lua` | `RotationProbe` (extends `Frame`) -- the `/reck probe` diagnostic window (round 6), and the only thing in this codebase that calls `SetRotation`. Nothing imports it but `UI/__init__.lua`; it exists to answer the questions the line-graph rework depends on and is meant to be **deleted once they are answered** (`docs/redesign/GRAPH_RESEARCH.md` section 7 holds the answer table) -- along with the `windows.probe` entry it leaves behind in saved settings, since it takes a `Frame` key like any other window. |

`UI/__init__.lua` imports Frame/Bar/Row in that order; `Main.lua` does `import "Reckoning.UI"`
once. **Cross-directory class visibility**: a bare `X = class(...)` assigned inside `UI/*.lua`
is only visible to *other files in `UI/`* (same-directory sibling access, confirmed against
`VitalSelf/UI/Vital.lua`, which is referenced from root-level `Main.lua` as `UI.Vital()`, not
bare `Vital()`). Root-level files (`Main.lua`, `Constants.lua`, `Session.lua`, `Sessions.lua`,
`Settings.lua`, `Events.lua` -- anything directly in `Reckoning/`) behave differently: a bare
global assigned there (`Trigger`, `L`, `EventCode`, `Theme`, `Font`, `Session`, `Sessions`, ...)
*is* visible everywhere, because the root package's own environment is `_G` itself. So: Phase
3-5 window classes (`LiveMeter`, `DeathCause`, `Analysis`) go in `UI/`, get instantiated from
`Main.lua` via `UI.LiveMeter()` etc. (matching `vital = UI.Vital()` in `VitalSelf/Main.lua`),
and can freely reference `Frame`/`Bar`/`Row` bare since they're siblings in the same directory.

| `UI/LiveMeter.lua` | `LiveMeter` (extends `Frame`, `key = "liveMeter"`, `closable = false`) -- window 1. Bespoke header: accent tick (colour toggles `Accent`/`Border` for in-combat/idle) + "IN COMBAT"/"IDLE" label + an "open the analysis window" button (`BuildAnalysisButton`, reads the root-level `analysis` global at click time, not captured at construction) + elapsed clock. The header doubles as a small button bar per direct feedback -- what used to be a static "LAST FIGHT" text state is that button instead; more buttons can go in the same header the same way. 4 tabs, 4-line body. One `local` provider function per tab (`DoneLine`/`TakenLine`/`HealOutLine`/`HealInLine`) normalizes very different per-tab content (see `docs/DESIGN.md`'s table) into one `{headline,second,stat,max}` shape so the body-refresh code stays generic. Refreshed on a throttled `Update()` (~10Hz, bumped from ~5Hz per feedback). The "max" line (`self.lineLabels[3]`) is a real two-line value cell -- the number on top (`MaxLine()`, LucidaConsole12, unchanged from every other value), the skill name on a second, smaller Verdana10 line directly below it (`self.lineLabels[3].sub`) -- **not** appended to the same string. An earlier draft truncated a single combined `"29,557  Strike Towards the Sky"` string instead; that was reportedly not wanted even once it stopped overflowing, so it's a real second line now, in the vertical room the row already had (13px number + 11px name = the row's existing 24px). **Permanently visible** whenever `settings.liveMeterEnabled` is true -- per direct user feedback, this overrides `docs/DESIGN.md`'s original "dims and holds the last fight 8s, then hides": it now shows the live fight, or the last finished one, or (if nothing has been fought yet this play session) a permanent zeroed `self.idleSession` placeholder -- a real empty `Session` instance, not a separate "no data" rendering path. `ActiveSession()` therefore never returns nil; every provider function can assume a real session. **No opacity change at all now** (also per feedback -- the original 0.55 out-of-combat dim was removed too; full opacity always). **`settings.compactMode` is a second shape for the same window**, 160x76 instead of 260x186 -- a quarter of the area, showing the clock, the tab row and exactly **one** number. `liveBarValue` still picks *which* number (it is the "big slot" half of that setting); the corner cell it would otherwise fill goes with the rest of the detail, which is what lets the number span the whole 144px content row. Everything the compact shape does not show (caption, `rateLabel`, sparkline, divider, the three stat rows, the sub-line) is **hidden, never torn down** -- there is no confirmed-safe `SetParent(nil)` in this codebase, and a visibility flip is reversible for free. `LiveMeter:ApplyMode()` is the single place both shapes are described; it early-returns when the mode has not changed, calls `Frame.Resize` (chrome only, which is why the three `Layout*` helpers beside it re-lay out the meter's own content) and is reached from the Constructor and from `ApplySettings`. **`LayoutHeader`/`LayoutTabs`/`LayoutBody` deliberately only touch the widgets compact mode SHOWS** -- everything hidden keeps its full-width coordinates permanently, since it is never visible at 160px. **`TAB_LABELS_COMPACT` is what makes 160 possible at all, and it is the binding constraint on the width** -- not the header and not the body. The tab strip has four cells that must each hold their label, so "Heal out"/"Heal in" (8 chars, ~56px by this codebase's own `chars * 7` estimate) were what cost the width: they shorten to "H out"/"H in" while DONE and TAKEN keep their full words, giving a 5-char maximum (~35px) in a 40px cell. **Going narrower than 160 means shortening the headings again**, nothing else; `windows_test.lua` asserts every compact heading clears its cell on that same estimate, which is the check that would catch it. Keep the width divisible by 4 -- `LayoutTabs` divides it straight into four cells and a fractional tab width would reach `SetPosition`/`SetSize`. The compact header drops the "IN COMBAT"/"IDLE" text entirely (the accent tick already carries that state by colour) and pulls the clock to the left edge -- that is precisely what buys room for the Details button at 160px, so restoring the text means giving up the button. Two guards are load-bearing and were both written for the 10Hz refresh, not for tidiness: `RefreshSparkline`'s `show` now also fails on `self.compact` (without it every tick re-shows the 60 columns `ApplyMode` just hid, straight over the number in a 28px body), and `Refresh` skips the caption and the three stat rows in compact. `self.valueHit` is compact mode's second way into the analysis window: a transparent mouse-visible `Control` over the headline row (created after the two labels so it sits above them), sharing `LiveMeter:ToggleAnalysis()` with the header's Details button. **Not yet confirmed in-game**: that a `Control` with no `BackColor` over two Labels actually receives the click -- the precedent is `Frame`'s close button and the analysis table's header cells, both the same shape, and if it is dead the first thing to check is that z-order, not the handler. |

| `UI/DeathCause.lua` | `DeathCause` (extends `Frame`, `key = "deathCause"`, death-specific fill/border/header-rule colours) -- window 2. Fires from `Sessions.OnSelfDefeat`. "Last hit by" resolved by scanning `session.lastTaken` backward for the last `kind == "damage"` entry (temp-morale-loss rows don't carry an attacker). 5 pooled `Row` instances (never rebuilt), tinted per row: the killing-blow row's amount goes `DamageFatal`, temp-morale rows go `MutedText` end to end, everything else scales `DamageTaken`/`DamageSevere` off post-hit `moralePct`. Countdown is a `Bar`, `_G.settings.deathAutoHide` seconds (default 15) -- tracked as `self.remaining` (seconds left, decremented by real elapsed `dt` each `Update()` tick) rather than an absolute target timestamp, specifically so **pausing is just "skip subtracting this tick"**: `self.MouseEnter`/`self.MouseLeave` toggle `self.paused`, per direct feedback that hovering the window to read it shouldn't race the auto-hide closing it. Row time column widened (38px -> 46px) and format changed from one decimal (`"-3.7s"`) to whole seconds (`"-4s"`) per feedback that the times "seemed broken" -- most likely a width/overflow problem given the format itself checked out fine standalone, but the exact in-game rendering was never confirmed, so this is a defensive fix (shorter string, wider column) rather than a diagnosed-and-proven one; if it's still wrong, the underlying `entry.time - self.deathTime` computation itself is the next thing to check with a real capture, the way the `ChatType.Death` bug was found. The morale column is now a `Bar` per row (`self.moraleBars`, pooled) instead of a `Format.Percent` Label, matching the analysis window's own bar style per feedback. Depends on `UI/Row.lua`'s rows being mouse-invisible (`SetMouseVisible(false)`, changed from `true` -- nothing in a `Row` was ever individually clickable) so a row sitting over the window doesn't swallow the hover before it reaches the window's own `MouseEnter`/`MouseLeave`. **Unverified**: whether `Turbine.UI.Window.MouseEnter`/`.MouseLeave` fire based on the window's own bounds regardless of mouse-invisible children on top (assumed, consistent with how mouse-invisible children behave for click-through elsewhere, but not confirmed for Enter/Leave specifically) -- if hover-pause doesn't trigger in-game, check this first. |

| `UI/Analysis.lua` | `Analysis` (extends `Frame`, `key = "analysis"`, resizable 1080x820, min 1080x600, max 1440 wide by the display's own height less 40px -- see `MaxHeight()`) -- window 3, redesigned in v0.2.0. Session rail (unchanged), 4 view tabs in **damage-pair-then-healing-pair** order (`done`/`taken`/`healOut`/`healIn`) with centred labels, picker chips, 5 KPI cards, the graph block, the skill table at **full content width**, then the SELF BUFFS table and the two 233px side panels sharing the bottom row. `RESET RANGE`, the range chip and the `POST` button (`BuildPostButton`, see `UI/PostButton.lua`) live in `Frame`'s own header, laid out right-to-left by `LayoutHeaderExtras`. State: `viewTab`, `filter[view]`, `selectedSession`, `rangeFrom`/`rangeTo`, `charted` (ordered, max 3), `tableSort`/`buffSort`, `splitBottom` (the user's skill/buff split; `splitEffective` is what the window could give it). **Everything is range-scoped through one `Session:Slice` per refresh** -- KPIs, table, both panels and the buff table are all fed from that single result, never from their own separate passes. `Layout()` and `RefreshContent()` call each other exactly once each: `RefreshContent` detects that the charted-lane or picker-row count changed shape, sets `laneCountWanted` and re-runs `Layout()`, which ends by calling back with `skipRelayout` set -- that flag is the only thing stopping an infinite bounce, so do not remove it. The buff table (labelled SELF EFFECTS) carries a **TYPE** column between EFFECT and UPTIME % -- `BUFF_KIND_TEXT`/`BUFF_KIND_HEX`/`BuffKindText` render `row.kind` (see `Buffs.lua`) as Buff/Debuff/Unknown, it sorts on the word it displays, and `FilterBuffStats` matches the search box against it as well as the name. Its 66px came out of the name column, which is the one that absorbs slack in `LayoutBuffColumns` -- and that function's name floor dropped 120 -> 100 in the same change, because at the window's **minimum** width the old floor made the eight columns sum wider than the section they sit in (which clips the last column instead of shortening the name; `analysis_test.lua` pins `buffWidth == 594` against the 604px section for exactly this). The SELF BUFFS table now scrolls (`self.buffScrollView`/`self.buffScrollBar`, the same `ListBox` + `Lotro.ScrollBar` host as the skill table's `scrollView`/`tableScrollBar` -- see `BuildTable`'s comment) instead of the section growing to fit every tracked buff and silently dropping whatever didn't fit past the `BUFF_POOL` pool size or the space the window had -- `REDESIGN_SPEC.md` section 7 already called for this ("let the skill table shrink to its 150px floor first and the buff table scroll second"), it just wasn't wired up. `BuildBuffRow`'s container is unparented until `RefreshBuffSection`'s `ClearItems`/`AddItem` loop, mirroring `BuildTableRowSlot`'s own comment. **The target/source picker wraps** (`RefreshPicker`/`FlowChips`): chips used to flow left-to-right off the right edge of the content column with no wrap, cap or clip, which at ~5 chips per row (848px at min width, `ChipWidth` is `16 + chars*7`) made every target past the fifth unreachable in any fight with more than a handful of enemies. Now: labels truncate to `PICKER_MAX_CHARS` on a **character** boundary (`TruncateChip`/`ChipWidth` are now thin wrappers over `Format.Truncate`/`Format.CharCount` in `Constants.lua`, which count UTF-8 lead bytes by hand -- Lua 5.1 has no `utf8` library and mob names carry accented characters; the marker is ASCII `..`, not `…`, per the pin-glyph lesson above. They moved out of this file when `ChatPost.lua` needed the identical logic for its line-length cap), chips flow into at most 2 rows, and the remainder folds into a trailing `+N more` chip that expands the picker to at most `PICKER_ROWS_EXPANDED` (5) rows with a `less` chip to fold it back. `pickerExpanded` is ephemeral and resets on view/session change. Row count feeds the same shape-change relayout path as lanes/buff rows (`pickerRowsWanted`/`layoutPickerRows`), and `Layout()` re-runs `RefreshPicker` itself before sizing the row so a resize that changes the chips-per-row count can't leave the geometry a pass behind. Chip **labels** are truncated but chip **values** stay the full name -- filtering matches on the value, so a shortened label never breaks the filter (offline-checked). |
| `UI/AnalysisGraph.lua` | `Graph` -- the time plot. Owns four stacked rows: the 150px plot, 0-3 charted buff lanes, the range slider, and the timeline + legend; `GraphHeightFor(laneCount)` is a plain global so `Analysis:Layout` can ask for the total before a Graph exists. **The series are real line graphs** (v0.6.0): one pooled `Turbine.UI.Window` per step, sized to a SQUARE the length of the step it draws, carrying a rung of the `Resources/stroke_*.tga` ladder (picked by length, so the drawn stroke stays near 2px instead of scaling with the segment) and rotated to the step's angle -- see the file header and the Build-status note for the six probe rounds behind every call in `DrawSegment`, none of which is interchangeable. `Graph:Redraw` only ARMS the rotation (`rotateIn`); `Graph:FlushRotation`, driven by `Analysis:Update`, applies it a couple of frames later, because a rotation set before the control has painted is silently dropped. Morale is a **background bar graph** (48 bars + 48 brighter 1px top edges, low-morale pair below `MORALE_DANGER`, guide lines at 100%/50%) and stays bars deliberately; unsampled buckets carry the last known value forward, because a second in which you took no damage is not a second at 0 morale. **Hovering is one mouse-visible Control -- the plot ground -- not 48 zones on top of the data**: the old per-bucket zones hid the morale trace underneath them (found in-game, mechanism never pinned down), and putting the hover surface *behind* everything sidesteps that question entirely while relying only on the click-through behaviour `UI/Row.lua` already depends on. Pools: 2x(48 dots + 47 segments) + 96 morale + 3x24 lane segments, all built once. |

**Two documented deviations from the mockup's literal pixel values**, both explained in
`UI/Analysis.lua`'s header comment: the graph and skill table stretch to fill the available
content width instead of the mockup's fixed 640px graph (a fixed-width graph would get zero
benefit from the resize gripper, which is the whole reason this window resizes and the other two
don't); and the 5 KPIs are one uniform shape across all four views (total+rate, hits/heals+count,
crit/dev%, largest+skill, active time) rather than bespoke content per view, since `docs/DESIGN.md`
specifies "five KPIs" per view without dictating what they show.

**A pattern worth knowing before touching either file**: nothing in `UI/Analysis.lua` or
`UI/AnalysisGraph.lua` ever calls `:SetParent(nil)` to detach/destroy a child Control, even
though an earlier draft did (to swap a `Row`'s column spec on view change, and to rebuild `Graph`
on resize). There's no confirmed-safe "detach a child" call anywhere in this codebase's existing
plugins (`VitalSelf`/`Gibberish3`), and view-switching is a hot-ish path -- if that call actually
throws in the real client, every view click would break plugin. Instead: `Row:Reconfigure(width,
columns)` (`UI/Row.lua`) re-points an existing pooled Row at a new column spec, reusing Label
children and only creating new ones if the column count grows; `Graph:Resize(width)`
repositions/resizes the existing pooled columns/dots/gridlines in place. If a future change needs
to genuinely remove a child Control, verify `SetParent(nil)` (or whatever the real teardown call
turns out to be) in-game first, on a low-stakes control, before relying on it anywhere hot.

| `UI/Options.lua` | `Options` (extends `Turbine.UI.ListBox`) -- the **Plugin Manager stub**, returned via `plugin.GetOptionsPanel`. Every real setting moved to `UI/OptionsWindow.lua`; this is one title, one line of text and an **Open options** button. The old panel is gone rather than kept in parallel, because two surfaces editing the same keys would reintroduce the exact problem the options window exists to remove (it had two commit models in one place -- checkboxes saved on change, the numeric box only on Accept). `Options:Refresh()` survives as a no-op so older callers stay valid. |
| `UI/Controls.lua` | `Slider` (single-handle) and `Segment` (a strip of shared-edge cells), the two controls the options window needed that this codebase did not already have. `Slider`'s drag is `RangeSlider`'s idiom verbatim, including the rule the resize-gripper bug established: a handler reading `args.X` off the dragged control must move that control inside the same `MouseMove`. `OnChange` fires per value, `OnCommit` once on release -- callers save in `OnCommit` only. `Segment`'s cell width tries `Label:GetWidth()` and falls back to a `Format.CharCount(text) * 7 + 20` estimate if it reads implausibly small; nothing in this codebase had ever relied on text measurement (see `ChipWidth` in `UI/Analysis.lua`), so both paths are live and the wider one wins. |
| `UI/OptionsPage.lua` | `OptionsPage` (extends `Turbine.UI.Control`) -- a y-cursor container so the seven pages read as declarative lists instead of 400 lines of `SetPosition`. `Section`/`Note`/`Check`/`Slider`/`Segment`/`Button`/`ButtonRow`, each returning its control, appending a 1px `RowBorder` rule and advancing the cursor. Every `Add*` registers a **refresher** (`OnRefresh`) that re-reads its own key -- `Refresh()` runs them all, which is what makes Defaults and `/reck reset` land on a page that was built minutes ago. `OptionsPage.Width` (402) is the pane's 412 less a 10px scrollbar gutter. A page can nest another `OptionsPage` inside itself (the Self buffs page does, so the ignore section's cursor need not know where the fixed-height picker above it ended). |
| `UI/OptionsWindow.lua` | `OptionsWindow` (extends `Frame`, `key = "options"`, 560x452) -- window 4, `/reck options`. Rail (7 rows) + one reused `ListBox` pane + footer. `BUILDERS[pageKey]` builds a page lazily on first open and caches it; `page.Repaint()` (optional) re-reads anything that comes from live data rather than from `_G.settings` -- the saved-geometry readouts and the buff picker -- every time the page is shown. `OptionsWindow.ApplyAll()` is the single place that pushes settings into all four windows, guarded so a handler firing during load cannot reach a window that does not exist yet. `Update()` exists only to disarm the Sessions page's two-step **Clear data** button. |
| `ChatPost.lua` | Turns a `Session` into a chat post. One output shape: **`BuildLine`** returns a single string within `MAX_MESSAGE`, optionally coloured -- the summary preset is a fixed shape (fight, range, view label, total, rate, hits, crit%, largest hit + its skill, DIED) with **no** per-skill list, and the death preset is the killing blow plus as many of `lastTaken` as the budget allows. `Alias(channelKey, line)` wraps it in the channel's slash verb. Pure string building, no `Turbine.UI`, so `tools/offline/chatpost_test.lua` exercises every branch. Root level (not `UI/`) because both `Main.lua` and `UI/PostButton.lua` need it. **ASCII only in post text** -- separators are `" - "`/`" | "`, never an em dash or middle dot: everywhere else a questionable glyph only has to survive *our* client's fonts (and this codebase has been caught twice already), but a post renders on other players' clients. Every interpolated name goes through `Clean()` (strips `[\r\n]+` and `<>`) -- a newline in a mob name would forge an extra chat line, since the whole post is one alias the client splits on `\n`. Lines are built as `{ text, hex }` segment lists so `Render()` can measure the *plain* length for the 240-char cap while emitting the tinted form, and coalesce adjacent same-colour runs into one tag pair. |
| `UI/PostButton.lua` | `PostButton` (extends `Turbine.UI.Control`) -- the post control pair in the analysis window's header. `PostButton` itself is the themed **POST** button, with an invisible `Turbine.UI.Lotro.Quickslot` floating over it inside its own 0x0 opacity-0 top-level Window (`self.overlay`) -- that quickslot is what actually fires the post. `self.channel` beside it is a plain `Control` naming the destination (`SAY`/`FELL`/`RAID`/`KIN`) whose `MouseClick` opens the channel/preset `ContextMenu`. `Place(x, y)` positions all three (deliberately not an override of the native `SetPosition`); `SyncOverlay(force)` keeps the overlay on the button in **screen** coordinates; `Raise()` puts it back above the window after anything activates it. `PostButton.Width` is what `Analysis:LayoutHeaderExtras` reserves. See the note below -- every part of this shape is there because a simpler-looking one failed in-game. |

**Chat posting requires a user click, and no amount of cleverness changes that.** There is no
chat-send API in Turbine: `Turbine.Shell.WriteLine` prints only to your own window and
`Turbine.Chat.Received` is receive-only. The only mechanism that reaches a channel -- used by
**every** plugin in this install that posts (`CombatAnalysis`, `Arebel/ParseGraph`,
`PrimePlugins/Parse`, `PrimePlugins/RaidTools`, `LootLogs`) -- is a `Turbine.UI.Lotro.Quickslot`
holding a `Shortcut(ShortcutType.Alias, "/f <text>")` that the user clicks. `Arebel` explicitly
tried firing one programmatically (`slot:Use()` / `:Execute()` / `:DoClick()`,
`ParseGraph/Main.lua:7403-7428`); none of those methods exist and it falls back to telling the user
to click. So: **no auto-post on combat end**, and `/reck post` can only ever print a local preview.
The alias is also a **static string**, so it must be rebuilt whenever view/filter/range/session/
channel/preset changes -- `RefreshContent` is the single funnel all of those already pass through
(CombatAnalysis calls its equivalent from six scattered sites for want of one).

**This feature took several in-game loads to get right, and every wrong turn came from trusting a
sibling plugin's code over what this client actually does. All of them are worth knowing.**

1. **A post is ONE line, plain-capped at `ChatPost.MAX_MESSAGE` (240).** The first version built 6
   lines and joined them with `\n`, because CombatAnalysis and Arebel both do exactly that (Arebel
   posts 11). In-game that produced *"That text is prohibited because of a content, size, or
   mixed-alphabet restriction."* The individual lines were 56-88 characters -- far too short to
   trip a size limit on their own -- so the whole 400-1000 character blob was going out as a
   **single message**. The client does not split an alias on `\n`. The only precedent with a
   *measured* limit is `PrimePlugins/Parse`, which builds one line and clamps it with
   `output:sub(1, 256)` (`UI/OutputWindow.lua:125`) -- that is the one to copy. There is now
   exactly one output shape (`BuildLine` returns a string); an earlier draft had a separate
   "preview" form as well and the two drifted apart immediately.
2. **Colour is budgeted, never assumed free.** `<rgb=#RRGGBB>` costs 19 characters per tinted run,
   and nothing establishes whether the client's limit counts markup -- so `MAX_MESSAGE` is measured
   against the **rendered** string, and a line that does not fit falls back to plain rather than
   being truncated mid-tag. Two bugs came out of getting this wrong: an empty trailing detail still
   emitted `<rgb=#8b8d9b></rgb>`, 19 characters of nothing that alone pushed the summary over the
   cap; and tinting each detail piece separately instead of appending it as a segment emitted
   `</rgb><rgb=#8b8d9b>` between same-coloured neighbours, which cut the coloured death report from
   four entries to one. `Render` coalesces adjacent same-colour segments for exactly this reason.
3. **Where the quickslot lives decides whether it can be clicked.** A `Quickslot` cannot be
   restyled and `SetOpacity` does **not** apply to one (confirmed in-game -- it rendered at full
   strength over the themed button and looked broken). So it goes in its own 0x0, opacity-0,
   top-level `Turbine.UI.Window` positioned in screen coordinates over the button, exactly as
   CombatAnalysis does (`StatOverviewPanel.lua:213-247`) -- opacity *does* work on a Window with no
   `BackColor` of its own. The catch, which shipped a completely dead POST button **twice**: two
   top-level windows compete for z-order, and any raise of the analysis window buries the overlay.
   The first fix hung the re-raise on the analysis window's own `self.MouseDown`, and that does not
   work: **Turbine mouse events do not bubble to a parent**, so a press landing on any mouse-visible
   child (a tab, a chip, a session row, a table header, the header itself) never reaches the
   window's handler -- while still raising the window. Since a user always clicks something before
   reaching for POST, the overlay stayed buried and the button was dead in practice.
   That non-bubbling is exactly why CombatAnalysis hand-forwards `WindowManager.MouseWasPressed(window)`
   out of ~60 separate mouse handlers (`UI/WindowManager.lua:340` walks up to the top-level window
   and calls `Activate()` on it); the re-raise itself then lands in its **overridden**
   `StatOverviewWindow:Activate()` (`StatOverviewWindow.lua:56-68`), which does the base activate
   and then `chatSendWindow:Activate()`. (An earlier version of this note said CombatAnalysis
   re-activates from a **per-frame `Update()`** -- that was a misread. `StatOverviewWindow:Update`
   is gated on `not self:GetWantsUpdates()` and `WantsUpdates` is only ever true during the
   minimize/maximize animation, so that body runs on the animation's last frame, not every frame.)
   Reckoning now gets the same funnel without 60 forwarding calls by hooking the window's real
   **`Activated`** event (`Analysis:BuildPostButton`), which fires however the window came to the
   front, including a client-initiated raise from a click on a child -- a confirmed-real Window
   event (`Thurallor/Common/Utils/Utils_13.lua:657` hooks it for exactly this meaning, alongside
   the `Deactivated` several other installed plugins use). Two backstops on top: the themed POST
   button underneath is now **mouse-visible** and re-raises on `MouseEnter` (it can only receive a
   hover when the overlay is *not* covering it, i.e. exactly when it is buried -- so the pointer
   arriving at POST fixes the z-order before the click that follows), and `Raise()` now syncs
   geometry before activating, because it is often called at the very moment the window becomes
   visible, before any `SyncOverlay` has run for that state. The 4Hz heartbeat still only
   re-*positions* the overlay; it must never call `Activate`. Because a raised overlay holds
   keyboard focus, `Frame`'s own Escape handler cannot fire while POST is on top -- the overlay
   takes `SetWantsKeyEvents(true)` and forwards Escape to `trackWindow:Close()`. **If POST is ever
   dead again, `Raise()` is the first thing to check, and adding a call to it is nearly always the
   fix -- not a timer.**
4. **The channel menu cannot live on the quickslot's right-click** -- the client uses that itself.
   It is on the separate channel button beside POST, a plain `Control` whose `MouseClick` is the
   pattern proven all over this codebase. CombatAnalysis reached the same shape from the other
   direction, putting its channel menu on a separate speech-bubble icon rather than on the send
   button.

**The general lesson, since it cost several reloads**: a sibling plugin's code proves a call is
*accepted syntax*, never that it *does what the code reads like it does*. `\n` in an alias, an
11-line post, an opacity-faded quickslot -- all three are right there in shipping plugins, and none
behaved as written here. Prefer the candidate with fewer moving parts, and treat a plugin's own
comment calling its approach a "hack" as a reason to look for a second precedent rather than to
copy it.

**Still not confirmed in-game**: that `Turbine.UI.ContextMenu`/`MenuItem` behave as
CombatAnalysis's use implies -- nothing else in Reckoning had touched them. `tools/offline/stub.lua`'s
`SetOpacity` guard was narrowed from "never call it" to "never call it on a Control that has a
`BackColor`", which is what the original lesson actually established. Offline-verified: the builder
in full (`chatpost_test.lua` -- single-line, within the cap, balanced 6-digit tags, colour
stripping back to exactly the plain line, and the newline/angle-bracket injection guard) and the
overlay tracking the window through drag, resize, show/hide, re-raise and shutdown
(`analysis_test.lua` section 18).

`/reck options` (alias `/reck config`),
`/reck show|hide [live\|death\|analysis\|options]`, `/reck move <live\|death\|analysis\|options>`,
`/reck testdeath`, `/reck reset`, `/reck post`,
`/reck buffs [list|ignore <name>|unignore <name>]`,
`/reck probe` are in
`Main.lua`. `options` toggles the settings window (window 4) -- the same thing the Plugin Manager
stub's button does. `buffs` re-parses its arguments from the **raw** command string, not the lower-cased
single-token parse the other subcommands use -- buff names are case-sensitive and contain spaces. `show`/`hide` for `live`/`death` only flip
their enable flag (same effect as the options panel checkboxes) rather than forcing
`SetVisible` -- `death` is still entirely event-driven (`Sessions.OnSelfDefeat`) and popping it
open with no real death would be misleading; `live` is now permanently visible whenever enabled
(see `UI/LiveMeter.lua`'s note above) so its enable flag *is* the real show/hide. `analysis` is
the one window a forced show/hide makes sense for directly. `move` is a recovery command (reset
to (200, 200) and show) for a window dragged off-screen. `probe` opens the
`SetRotation` diagnostic window (see the line-graph note in Build status) -- built lazily on first
use and kept, so re-running it re-shows the same window rather than leaking a second set. `testdeath` pops the death window
directly with synthesized data, bypassing `Sessions.OnSelfDefeat` entirely -- added specifically
to tell "the window itself doesn't work" apart from "a real death was never detected" (e.g.
nothing fought so far can actually kill the player) without waiting to die for real; if this
command doesn't show the window either, the bug is in `DeathCause`/`Frame`, not in event
detection. `reset` calls `Settings.ResetToDefaults()`, repositions all four windows, then re-reads every
built options page and calls `OptionsWindow.ApplyAll()` -- the same two steps the options window's
own **Defaults** button takes, which is why they live there rather than being spelled out twice. `post` prints the post the analysis window currently has
armed to **your own chat window only** -- it reads that window's live `viewTab`/`filter`/
`RangeSeconds()` so the preview matches what POST would send, and it exists because a slash
command structurally cannot do anything more than that (see the chat-posting note above). It is
also the fallback if the quickslot mechanism turns out to misbehave in-game.

**A real bug caught while building this**: `Settings.Load()`'s DEFAULTS-merge loop used to alias
`_G.settings.windows` directly to `DEFAULTS.windows` (the same table object, since `windows = {}`
in `DEFAULTS` is itself just a table value like any other and the merge did `_G.settings[key] =
value`). Every window drag or resize was therefore also silently mutating `DEFAULTS.windows`,
which `Settings.ResetToDefaults()` (added for `/reck reset`) would then have copied right back
out -- reset would have restored whatever the *current* window positions already were, not the
real defaults. Fixed by giving any table-valued default a fresh `{}` on merge instead of the
`DEFAULTS` table itself. Worth remembering if a future setting is table-shaped: table defaults
need this same fresh-copy treatment, not a bare reference.

### Key globals

- `_G.lp` / `LocalPlayer` -- both point at the same `Turbine.Gameplay.LocalPlayer` instance.
  `_G.lp` is the conventional handle (matches `VitalSelf`); the bare `LocalPlayer` global exists
  **only** because `Trigger.ParseCombatChat` reads `LocalPlayer.name` directly as a property, not
  a method call -- do not remove it even though it looks redundant with `_G.lp`. `.name` is
  **not** a real Turbine property (see "Build status" for the bug this caused and how it was
  found) -- `Main.lua` monkey-patches it on once, `LocalPlayer.name = LocalPlayer:GetName()`,
  immediately after assignment. If `LocalPlayer` is ever reassigned or rebuilt, that line has to
  run again or every event silently stops matching `mine`/`onMe` again.
- `_G.settings` -- the persisted settings table, populated by `Settings.Load()`.
- `Trigger` -- declared `{}` in `Main.lua` *before* `Parse/en.lua` is imported, because that
  file does `function Trigger.ParseCombatChat(...)` (attaches to an existing table) rather
  than declaring its own global. Mirrors Gibberish3's `Variables.lua`.
- `L` -- localisation table. `L.DirectDamage` is the fallback skill name for a hit with no
  named skill. **Gibberish3 itself never defines this key** (verified against the live
  Gibberish3 install: dead in the source `Parse/en.lua` was ported from) -- Reckoning defines
  it directly in `Constants.lua` instead of leaving `skillName` nil.

## The parser and its wiring

`Trigger.ParseCombatChat(line)` returns `eventCode, ...` (signature varies by code) or `nil`
for anything unparseable. Full details, including the `avoidType` / `critType` / `dmgType`
tables and which event codes to consume, are in `docs/DESIGN.md` "The parser".

Two things learned from reading the **live** Gibberish3 install (`TRIGGER/CHAT/Functions.lua`)
that are not written down in the design bundle and are easy to miss, both applied in
`Events.lua`:

1. **Strip colour tags and trim before parsing.** Gibberish3 feeds the parser
   `string.gsub(string.gsub(message, "<rgb=#......>(.*)</rgb>", "%1"), "^%s*(.-)%s*$", "%1")`,
   not the raw `args.Message`. `Events.lua` must do the same or coloured combat lines (which
   the client does send) will fail to match.
2. **Subscribe via `Turbine.Chat.Received`, filter on `Turbine.ChatType.PlayerCombat` /
   `Turbine.ChatType.EnemyCombat`.** `docs/IMPLEMENTATION_PLAN.md` already documents the
   dispatch logic (`mine` / `onMe` / event 14 exception); this note is only about the chat
   subscription and the tag-stripping step upstream of it.

## Persistence

Follow the `VitalSelf` pattern: `Turbine.PluginData.Save(Turbine.DataScope.Character,
"Reckoning", _G.settings)`, done in `Settings.Save()`.

- `Turbine.UI.Color` does **not** survive serialization -- it returns as a plain `{R,G,B}`
  table. `Settings.FixColors()` rebuilds every key listed in `COLOR_KEYS` on load. That list is
  currently empty: the palette in `Constants.lua` (`Theme.Hex`) is fixed design tokens, not
  user settings. A future options-panel colour override (Phase 6) would add its key to both
  `DEFAULTS` and `COLOR_KEYS` -- follow `VitalSelf/Main.lua`'s `COLOR_KEYS` / `FixColors`
  pattern exactly, including never storing a shared `Turbine.UI.Color` constant and never
  mutating a stored colour's `.R/.G/.B` in place.
- Read new keys defensively; existing saves will not have them (`DEFAULTS` merge in
  `Settings.Load()`).
- Sessions are **not** persisted (`docs/DESIGN.md` "Session model"). Everything else is, and
  `Settings.lua`'s `DEFAULTS` is the single list -- window positions/size, the analysis window's
  splitter position (`windows.analysis.split`), `liveTab`, `chartedBuffs`, `buffIgnore`, the three
  chat-post keys, and the ~30 options-window keys. Only `windows`, `chartedBuffs` and `buffIgnore`
  are table-valued and so need the fresh-`{}`-on-merge treatment; every options-window key is a
  scalar. (`buffsOpen` was removed along with the buff section's collapse toggle -- see the
  splitter note in Build status.)
- **Numeric and enum settings are validated on load AND on reset** (`Settings.Clamp`, called from
  both `Settings.Load` and `Settings.ResetToDefaults`). `CLAMPS` holds every slider's range;
  `ENUMS` holds every segment's allowed set, with the numeric ones (`refreshHz`, `sessionsKept`,
  `bucketWidth`, `liveTab`) run through `tonumber` first so a save holding the string `"10"` is
  recovered rather than discarded. `palettePreset` validates against `Theme.Presets` itself rather
  than a list duplicated here, so adding a preset in `Constants.lua` needs no edit in `Settings.lua`.
  This is not tidiness: an unknown preset name would put a **nil hex into `Theme.Color`**, and an
  unknown `numberFont` a nil font into `SetFont`.
- `palettePreset` is the **name** of a `Theme.Presets` entry, never a colour -- which is why
  `COLOR_KEYS` is still empty after adding a whole palette feature.
- Everything a window persists lives in one `_G.settings.windows[key]` table, so anything writing
  to it must **mutate** that table rather than replace it. `Frame`'s header-drag handler used to do
  `_G.settings.windows[key] = { left = left, top = top }`, which silently threw away the analysis
  window's saved `width`/`height` (and now `split`) every single time the window was dragged --
  fixed, but the shape is easy to reintroduce.
- `chartedBuffs` is an ordered list of buff **names**, never colours -- a charted buff's lane
  colour is derived from its position in that list at render time, so no `Turbine.UI.Color` ever
  reaches `PluginData`. `buffIgnore` is a `[name] = true` set. Both are table-valued defaults and
  so get the fresh-`{}`-on-merge treatment (see `Settings.Load`'s note); `tools/offline/load_test.lua`
  asserts that a mutation of `_G.settings.chartedBuffs` does not leak into `DEFAULTS`.
- Open question from `docs/DESIGN.md`: should pins survive a reload (persist the session, not
  just the pin flag)? Not yet decided -- ask before building session persistence.

## Turbine/package-scope gotchas (from Gibberish3's CLAUDE.md, verified applicable here)

- **Package scope.** Turbine gives each *directory* its own environment. A bare global
  *assigned* inside a subdirectory's file is not reliably visible from another directory;
  reads of a global that already exists at the root package resolve fine (this is exactly why
  `Trigger`, `L`, and `LocalPlayer` are all declared in `Main.lua`/`Constants.lua` at the
  package root, then only ever mutated -- never re-declared -- from `Parse/en.lua`).
- **No `Turbine.UI.Lotro.Window` anywhere** (`docs/DESIGN.md` "Controls"). The stock window
  chrome cannot be themed into this palette; every window is a bare `Turbine.UI.Window` with
  hand-built chrome, following the pattern in `VitalSelf/UI/Vital.lua`'s move overlay.
- **A `Turbine.UI.Window` starts hidden and draws behind its parent.** Needs
  `SetVisible(true)`, and a parented one needs `SetZOrder` above its parent's fill.
- **`Activate()` only raises a window that is already visible** -- show first, then activate.
- **The game runs Lua 5.1.** A local `luac` is likely newer and will accept syntax (`\u{}`
  escapes, `goto`, integer division) that fails in game.

## Testing

**Run `sh tools/offline/run.sh` before every in-game load** (needs `lua5.1`; see
`tools/offline/README.md`). It parses every file with the game's own Lua version and runs 756
checks against the real classes and the real `Main.lua`. It is not a substitute for loading the
plugin -- it cannot tell you whether anything actually *draws* -- but everything it catches is a
reload you don't have to spend.

Beyond that: `/reck dump` (in `Main.lua`) prints the current or most
recent session's totals to chat -- the in-game way to re-check the event pipeline against
`reference/Combat_20260819_1.txt` / `reference/Enemy_20260819_1.txt` (read the two logs by eye
and compare). See "Build status" above for how Phase 1 was checked offline before any in-game
load existed to run `/reck dump` against.

`reference/Enemy_20260819_2.txt` is a real user-captured log added specifically because it
contains the local player being defeated and reviving four separate times ("The X incapacitated
you." / "You succumb to your wounds.", lines 42/46, 68/74, 96/101, 125) -- the exact scenario
that caught the `Turbine.ChatType.Death` channel bug (see "Build status"). If `Events.lua`'s
channel filter ever regresses, feeding this file's defeat lines through
`Trigger.ParseCombatChat` plus the dispatch logic (with `ChatType = Turbine.ChatType.Death`, not
`EnemyCombat`) is the fastest way to re-catch it offline instead of waiting for another real
death.
