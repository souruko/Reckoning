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
handoff bundle (`REDESIGN_SPEC.md` is the Lua-side plan, `GRAPH_RESEARCH.md` is the four ways to
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
tools/offline/run.sh` runs 246 checks in about a second. It caught three genuine bugs during the
redesign that `luac -p` could not have: an index-base probe that could not actually distinguish a
0-based from a 1-based `EffectList`, a `nil` layout constant reaching `SetPosition`, and the
analysis window failing to adopt an already-archived session. **Run it before every in-game
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
| `Constants.lua` | `L` (localisation), `EventCode` / `AvoidType` / `CritType` / `DamageType` enums mirroring the parser's return codes, `Font` table (only the faces/sizes the design actually uses), `Theme` palette + `Theme.Color(hex)`, `Icon.Size`/`Icon.Apply` (setting a numeric effect-icon id as a Control's background, modelled on Gibberish3's `IconElement` -- see "Build status" below). |
| `Settings.lua` | `Settings.Load()` / `Settings.Save()` / `Settings.FixColors()` via `Turbine.PluginData`, `DEFAULTS` as single source of truth, `COLOR_KEYS` for colour rebuild. |
| `Parse/en.lua` | `Trigger.ParseCombatChat` -- ported **verbatim** from `souruko/Gibberish3` (`UTILS/COMBATCHATPARSE/en.lua`). Do not rewrite it; `de.lua` / `fr.lua` are later drop-ins with the same signature. |
| `Session.lua` | The `Session` class -- one fight's aggregate (`agg.done/taken/healOut/healIn`, `buckets`, `lastTaken` ring). One `Add*`/`On*` method per event kind: `AddDone`, `AddTaken`, `AddHealOut`, `AddHealIn`, `AddTempMoraleLoss`, `OnDefeat`, `OnRevive`. Each `buckets[second]` entry also carries a `<field>ByWho[counterpartName] = amount` table alongside its pooled scalar (`done`/`taken`/`healOut`/`healIn`) -- added so the analysis window's graph can respect the target/source picker; the pooled scalar is always exactly the sum of its own `ByWho` table (`AddToBucket()` updates both together, in one place, so they can't drift apart). Verified offline (a synthetic multi-target fight, checked the per-target and pooled sums against hand-computed expectations). |
| `Sessions.lua` | The manager singleton (not a class): `Sessions.current` / `Sessions.list` (ring of 10, pinned exempt) / `Sessions.selected`; opens a `Session` lazily on the first own event, closes it after 5s of silence via `Sessions.Tick()`, discards anything under 3s. `Sessions.OnClosed` / `Sessions.OnSelfDefeat` are the callback lists Phase 3/4 UI hooks into. |
| `Events.lua` | Wraps `Turbine.Chat.Received` (chaining to whatever was already registered), strips `<rgb=#......>` tags and trims before calling `Trigger.ParseCombatChat`, dispatches into `Sessions.*`. Also hosts the heartbeat (`Events.heartbeat`, a bare `Turbine.UI.Window` with `SetWantsUpdates(true)`) that drives `Sessions.Tick()`, since session-close-on-silence has to run even when chat is quiet. `Events.Shutdown()` restores the previous `Turbine.Chat.Received` and stops the heartbeat -- called from `plugin.Unload`. |
| `Buffs.lua` | Self-buff uptime tracking. Polls `_G.lp:GetEffects()` at 4Hz from Events.lua's heartbeat (**not** the live meter's Update, as the spec suggested -- that meter can be switched off and uptime must keep recording either way), opening/closing an interval per effect name on `session.buffs[name] = { intervals, apps }`. `Buffs.Stats(session, fromSec, toSec)` clips every interval to a range and returns uptime / uptime% / apps / longest gap, sorted. Data source is the live effect list, **not** parser event 17 -- event 17 carries no duration and no fade, so uptime from it would be a guess. Everything here is defensive (one pcall around the whole enumeration; a failed read is a no-op, never "everything faded"; the 0-vs-1-based index base of `EffectList:Get` is **detected**, by probing index 0, not assumed) because nothing in this codebase has touched `Turbine.Gameplay.EffectList` before -- see the three "guessed the shape of a Turbine object" bugs in Build status. |
| `Utils/Class.lua`, `Utils/Type.lua` | Vendored OOP shim, see above. |

| `UI/Frame.lua` | `Frame` (extends `Turbine.UI.Window`) -- shared chrome every window subclasses: background + 1px border Controls, header with `TrajanPro13` title + close glyph, manual drag on the header, position persisted to `_G.settings.windows[key]`. |
| `UI/Bar.lua` | `Bar` -- 1px-border track Control with a fill child; `SetPercent(pct)` sets width directly (no tweening anywhere, per `docs/DESIGN.md`). |
| `UI/Row.lua` | `Row` -- a fixed-column-offset row of Labels for tables; pooled and reused across refreshes, never rebuilt per redraw. |
| `UI/RangeSlider.lua` | `RangeSlider` -- the two-handle time-range control under the plot. Snaps to the graph's 48 bucket stops, not to pixels, so the numbers in the window and the marks on the plot agree exactly and only 48 distinct ranges per endpoint can ever be asked for. Drag uses the same MouseDown/MouseMove/MouseUp shape as `Frame:WireDrag` and the resize gripper -- confirmed-working precedent, no new assumption about mouse delivery. Handles clamp to `other handle -/+ 1`; a zero-width range would divide by zero everywhere downstream. |

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

| `UI/LiveMeter.lua` | `LiveMeter` (extends `Frame`, `key = "liveMeter"`, `closable = false`) -- window 1. Bespoke header: accent tick (colour toggles `Accent`/`Border` for in-combat/idle) + "IN COMBAT"/"IDLE" label + an "open the analysis window" button (`BuildAnalysisButton`, reads the root-level `analysis` global at click time, not captured at construction) + elapsed clock. The header doubles as a small button bar per direct feedback -- what used to be a static "LAST FIGHT" text state is that button instead; more buttons can go in the same header the same way. 4 tabs, 4-line body. One `local` provider function per tab (`DoneLine`/`TakenLine`/`HealOutLine`/`HealInLine`) normalizes very different per-tab content (see `docs/DESIGN.md`'s table) into one `{headline,second,stat,max}` shape so the body-refresh code stays generic. Refreshed on a throttled `Update()` (~10Hz, bumped from ~5Hz per feedback). The "max" line (`self.lineLabels[3]`) is a real two-line value cell -- the number on top (`MaxLine()`, LucidaConsole12, unchanged from every other value), the skill name on a second, smaller Verdana10 line directly below it (`self.lineLabels[3].sub`) -- **not** appended to the same string. An earlier draft truncated a single combined `"29,557  Strike Towards the Sky"` string instead; that was reportedly not wanted even once it stopped overflowing, so it's a real second line now, in the vertical room the row already had (13px number + 11px name = the row's existing 24px). **Permanently visible** whenever `settings.liveMeterEnabled` is true -- per direct user feedback, this overrides `docs/DESIGN.md`'s original "dims and holds the last fight 8s, then hides": it now shows the live fight, or the last finished one, or (if nothing has been fought yet this play session) a permanent zeroed `self.idleSession` placeholder -- a real empty `Session` instance, not a separate "no data" rendering path. `ActiveSession()` therefore never returns nil; every provider function can assume a real session. **No opacity change at all now** (also per feedback -- the original 0.55 out-of-combat dim was removed too; full opacity always). |

| `UI/DeathCause.lua` | `DeathCause` (extends `Frame`, `key = "deathCause"`, death-specific fill/border/header-rule colours) -- window 2. Fires from `Sessions.OnSelfDefeat`. "Last hit by" resolved by scanning `session.lastTaken` backward for the last `kind == "damage"` entry (temp-morale-loss rows don't carry an attacker). 5 pooled `Row` instances (never rebuilt), tinted per row: the killing-blow row's amount goes `DamageFatal`, temp-morale rows go `MutedText` end to end, everything else scales `DamageTaken`/`DamageSevere` off post-hit `moralePct`. Countdown is a `Bar`, `_G.settings.deathAutoHide` seconds (default 15) -- tracked as `self.remaining` (seconds left, decremented by real elapsed `dt` each `Update()` tick) rather than an absolute target timestamp, specifically so **pausing is just "skip subtracting this tick"**: `self.MouseEnter`/`self.MouseLeave` toggle `self.paused`, per direct feedback that hovering the window to read it shouldn't race the auto-hide closing it. Row time column widened (38px -> 46px) and format changed from one decimal (`"-3.7s"`) to whole seconds (`"-4s"`) per feedback that the times "seemed broken" -- most likely a width/overflow problem given the format itself checked out fine standalone, but the exact in-game rendering was never confirmed, so this is a defensive fix (shorter string, wider column) rather than a diagnosed-and-proven one; if it's still wrong, the underlying `entry.time - self.deathTime` computation itself is the next thing to check with a real capture, the way the `ChatType.Death` bug was found. The morale column is now a `Bar` per row (`self.moraleBars`, pooled) instead of a `Format.Percent` Label, matching the analysis window's own bar style per feedback. Depends on `UI/Row.lua`'s rows being mouse-invisible (`SetMouseVisible(false)`, changed from `true` -- nothing in a `Row` was ever individually clickable) so a row sitting over the window doesn't swallow the hover before it reaches the window's own `MouseEnter`/`MouseLeave`. **Unverified**: whether `Turbine.UI.Window.MouseEnter`/`.MouseLeave` fire based on the window's own bounds regardless of mouse-invisible children on top (assumed, consistent with how mouse-invisible children behave for click-through elsewhere, but not confirmed for Enter/Leave specifically) -- if hover-pause doesn't trigger in-game, check this first. |

| `UI/Analysis.lua` | `Analysis` (extends `Frame`, `key = "analysis"`, resizable 1080x820, min 1080x600, max 1440x880) -- window 3, redesigned in v0.2.0. Session rail (unchanged), 4 view tabs in **damage-pair-then-healing-pair** order (`done`/`taken`/`healOut`/`healIn`) with centred labels, picker chips, 5 KPI cards, the graph block, the skill table at **full content width**, then the SELF BUFFS table and the two 233px side panels sharing the bottom row. `RESET RANGE` and the range chip live in `Frame`'s own header. State: `viewTab`, `filter[view]`, `selectedSession`, `rangeFrom`/`rangeTo`, `charted` (ordered, max 3), `buffsOpen`. **Everything is range-scoped through one `Session:Slice` per refresh** -- KPIs, table, both panels and the buff table are all fed from that single result, never from their own separate passes. `Layout()` and `RefreshContent()` call each other exactly once each: `RefreshContent` detects that the charted-lane or buff-row count changed shape, sets `laneCountWanted`/`buffRowsWanted` and re-runs `Layout()`, which ends by calling back with `skipRelayout` set -- that flag is the only thing stopping an infinite bounce, so do not remove it. The SELF BUFFS table now scrolls (`self.buffScrollView`/`self.buffScrollBar`, the same `ListBox` + `Lotro.ScrollBar` host as the skill table's `scrollView`/`tableScrollBar` -- see `BuildTable`'s comment) instead of the section growing to fit every tracked buff and silently dropping whatever didn't fit past the `BUFF_POOL` pool size or the space the window had -- `REDESIGN_SPEC.md` section 7 already called for this ("let the skill table shrink to its 150px floor first and the buff table scroll second"), it just wasn't wired up. `BuildBuffRow`'s container is unparented until `RefreshBuffSection`'s `ClearItems`/`AddItem` loop, mirroring `BuildTableRowSlot`'s own comment. |
| `UI/AnalysisGraph.lua` | `Graph` -- the time plot, rewritten in v0.2.0 as a **line-and-dot plot**. Owns four stacked rows: the 150px plot, 0-3 charted buff lanes, the range slider, and the timeline + legend; `GraphHeightFor(laneCount)` is a plain global so `Analysis:Layout` can ask for the total before a Graph exists. **A diagonal is not drawable here** -- Turbine has no canvas or line primitive -- so each polyline step is an L: a horizontal run at the *midpoint* height plus a vertical riser at its right end, risers z-ordered *under* the runs so the joint has no seam. This is Option A from `GRAPH_RESEARCH.md`, deliberately the one with no unknowns; Option B (the undocumented `SetRotation`, which Gibberish3 does use but only at 0/90/180/270) would halve the Control count and needs a 7-item in-game probe first, and `DrawStep` is the only function that would change. Morale is a **background bar graph** (48 bars + 48 brighter 1px top edges, low-morale pair below `MORALE_DANGER`, guide lines at 100%/50%), replacing the old 22px dot lane; unsampled buckets carry the last known value forward, because a second in which you took no damage is not a second at 0 morale. **Hovering is one mouse-visible Control -- the plot ground -- not 48 zones on top of the data**: the old per-bucket zones hid the morale trace underneath them (found in-game, mechanism never pinned down), and putting the hover surface *behind* everything sidesteps that question entirely while relying only on the click-through behaviour `UI/Row.lua` already depends on. Pools: 2x(48 dots + 47 runs + 47 risers) + 96 morale + 3x24 lane segments, all built once. |

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

| `UI/Options.lua` | `Options` (extends `Turbine.UI.ListBox`) -- returned via `plugin.GetOptionsPanel`. Scoped to what `docs/DESIGN.md` actually calls settable: `deathAutoHide` (validated numeric row) and the two enable checkboxes. No colour rows and no "window scale" row -- neither is a real setting in this design (see `Settings.lua`'s `COLOR_KEYS` comment); `docs/IMPLEMENTATION_PLAN.md`'s Phase 6 line mirrors `VitalSelf`'s options shape generically and oversells what applies here. |

`/reck show|hide [live\|death\|analysis]`, `/reck move <live\|death\|analysis>`,
`/reck testdeath`, `/reck reset`, `/reck buffs [list|ignore <name>|unignore <name>]` are in
`Main.lua`. `buffs` re-parses its arguments from the **raw** command string, not the lower-cased
single-token parse the other subcommands use -- buff names are case-sensitive and contain spaces. `show`/`hide` for `live`/`death` only flip
their enable flag (same effect as the options panel checkboxes) rather than forcing
`SetVisible` -- `death` is still entirely event-driven (`Sessions.OnSelfDefeat`) and popping it
open with no real death would be misleading; `live` is now permanently visible whenever enabled
(see `UI/LiveMeter.lua`'s note above) so its enable flag *is* the real show/hide. `analysis` is
the one window a forced show/hide makes sense for directly. `move` is a recovery command (reset
to (200, 200) and show) for a window dragged off-screen. `testdeath` pops the death window
directly with synthesized data, bypassing `Sessions.OnSelfDefeat` entirely -- added specifically
to tell "the window itself doesn't work" apart from "a real death was never detected" (e.g.
nothing fought so far can actually kill the player) without waiting to die for real; if this
command doesn't show the window either, the bug is in `DeathCause`/`Frame`, not in event
detection. `reset` calls `Settings.ResetToDefaults()` then repositions all three windows and
refreshes the options panel in place.

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
- Sessions are **not** persisted (`docs/DESIGN.md` "Session model"). Persist: window
  positions/size, `liveTab`, `deathAutoHide`, `buffsOpen`, `chartedBuffs`, `buffIgnore`.
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
`tools/offline/README.md`). It parses every file with the game's own Lua version and runs 246
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
