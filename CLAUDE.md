# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## What this is

Reckoning is a Lord of the Rings Online (LotRO) plugin written in Lua. It reads the combat
chat log and reports on the local player's own combat via three windows: an always-on live
meter, a death post-mortem, and a post-combat analysis window. It runs inside the game via the
Turbine plugin engine -- there is no build step, package manager, linter, or test runner.

Read `docs/DESIGN.md` first (the data model and parser facts that decide what is buildable),
then `docs/IMPLEMENTATION_PLAN.md` (the phased build order). Both came from a design handoff
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
developers.

## Build status

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
almost entirely `Turbine.UI.ScrollView`/`Control`/`Label` construction and layout arithmetic,
checked only with `luac -p` (syntax) and by hand-tracing the pixel math in review. Specific
things that need an actual in-game load to confirm, roughly in order of how likely they are to
be wrong:

- `Turbine.UI.ScrollView()` is used bare (`SetParent` + child positioning only) for the skill
  table. If it needs an explicit `SetAutoScroll`/similar call to actually scroll once pooled rows
  exceed its viewport, that call is missing.
- The picker chip width estimate (`ChipWidth` in `UI/Analysis.lua`, `16 + len(text)*7`) is a
  guess -- there's no text-measurement API used anywhere else in this codebase to check against.
  Long names will likely need retuning.
- At the window's minimum size (1080x600), the "Damage taken" view's table columns sum to a few
  px more than the table's allotted width once the Skill column hits its 150px floor (8 fixed
  columns leave less room than the other three 7-column views) -- minor overflow, only in that
  one view, only at minimum width, self-corrects once the window is widened.
- `SetOpacity` is used very heavily (every "tinted fill" -- tabs, chips, session rail selection,
  KPI cards' implied fill, panel/graph area fills) as the way to approximate the mockup's
  8-digit-hex alpha values. It's a confirmed-real method (`VitalSelf/UI/Vital.lua` uses it), but
  the actual visual result of stacking several `SetOpacity`'d Controls hasn't been seen rendered. Follow the implementation plan in order -- each phase is
written to end somewhere loadable and testable in-game.

Two Design-token values `docs/DESIGN.md` names but never gives hex for (`--color-accent-200`,
`-300`, `-500`, `-700`) were pulled directly from the mockup's own CSS custom properties and
added as `Theme.Hex.Accent200/300/500/700` in `Constants.lua` -- see that file's comment. If a
future design revision changes the mockup's accent scale, re-check those four values there.

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
| `Constants.lua` | `L` (localisation), `EventCode` / `AvoidType` / `CritType` / `DamageType` enums mirroring the parser's return codes, `Font` table (only the faces/sizes the design actually uses), `Theme` palette + `Theme.Color(hex)`. |
| `Settings.lua` | `Settings.Load()` / `Settings.Save()` / `Settings.FixColors()` via `Turbine.PluginData`, `DEFAULTS` as single source of truth, `COLOR_KEYS` for colour rebuild. |
| `Parse/en.lua` | `Trigger.ParseCombatChat` -- ported **verbatim** from `souruko/Gibberish3` (`UTILS/COMBATCHATPARSE/en.lua`). Do not rewrite it; `de.lua` / `fr.lua` are later drop-ins with the same signature. |
| `Session.lua` | The `Session` class -- one fight's aggregate (`agg.done/taken/healOut/healIn`, `buckets`, `lastTaken` ring). One `Add*`/`On*` method per event kind: `AddDone`, `AddTaken`, `AddHealOut`, `AddHealIn`, `AddTempMoraleLoss`, `OnDefeat`, `OnRevive`. |
| `Sessions.lua` | The manager singleton (not a class): `Sessions.current` / `Sessions.list` (ring of 10, pinned exempt) / `Sessions.selected`; opens a `Session` lazily on the first own event, closes it after 5s of silence via `Sessions.Tick()`, discards anything under 3s. `Sessions.OnClosed` / `Sessions.OnSelfDefeat` are the callback lists Phase 3/4 UI hooks into. |
| `Events.lua` | Wraps `Turbine.Chat.Received` (chaining to whatever was already registered), strips `<rgb=#......>` tags and trims before calling `Trigger.ParseCombatChat`, dispatches into `Sessions.*`. Also hosts the heartbeat (`Events.heartbeat`, a bare `Turbine.UI.Window` with `SetWantsUpdates(true)`) that drives `Sessions.Tick()`, since session-close-on-silence has to run even when chat is quiet. `Events.Shutdown()` restores the previous `Turbine.Chat.Received` and stops the heartbeat -- called from `plugin.Unload`. |
| `Utils/Class.lua`, `Utils/Type.lua` | Vendored OOP shim, see above. |

| `UI/Frame.lua` | `Frame` (extends `Turbine.UI.Window`) -- shared chrome every window subclasses: background + 1px border Controls, header with `TrajanPro13` title + close glyph, manual drag on the header, position persisted to `_G.settings.windows[key]`. |
| `UI/Bar.lua` | `Bar` -- 1px-border track Control with a fill child; `SetPercent(pct)` sets width directly (no tweening anywhere, per `docs/DESIGN.md`). |
| `UI/Row.lua` | `Row` -- a fixed-column-offset row of Labels for tables; pooled and reused across refreshes, never rebuilt per redraw. |

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

| `UI/LiveMeter.lua` | `LiveMeter` (extends `Frame`, `key = "liveMeter"`, `closable = false`) -- window 1. Bespoke header (accent tick + "IN COMBAT"/"LAST FIGHT" + elapsed clock), 4 tabs, 4-line body. One `local` provider function per tab (`DoneLine`/`TakenLine`/`HealOutLine`/`HealInLine`) normalizes very different per-tab content (see `docs/DESIGN.md`'s table) into one `{headline,second,stat,max}` shape so the body-refresh code stays generic. Refreshed on a throttled `Update()` (~5Hz); shows/hides itself based on `Sessions.current` plus an 8s post-combat hold (`Sessions.OnClosed`). |

| `UI/DeathCause.lua` | `DeathCause` (extends `Frame`, `key = "deathCause"`, death-specific fill/border/header-rule colours) -- window 2. Fires from `Sessions.OnSelfDefeat`. "Last hit by" resolved by scanning `session.lastTaken` backward for the last `kind == "damage"` entry (temp-morale-loss rows don't carry an attacker). 5 pooled `Row` instances (never rebuilt), tinted per row: the killing-blow row's amount goes `DamageFatal`, temp-morale rows go `MutedText` end to end, everything else scales `DamageTaken`/`DamageSevere` off post-hit `moralePct`. Countdown is a `Bar` depleting via `Update()`, `_G.settings.deathAutoHide` seconds (default 15). |

| `UI/Analysis.lua` | `Analysis` (extends `Frame`, `key = "analysis"`, resizable) -- window 3. Session rail (pooled rows, pinned sort-to-top), 4 view tabs, picker chips (rebuilt on session/view change, not pooled -- a handful of controls, not a hot path), 5 KPI cards, skill table (`ScrollView` of pooled `Row`s with a per-row share-bar), two side panels. State: `self.viewTab`, `self.filter[view]`, `self.selectedSession`. `Analysis:Layout()` recomputes every block's position/size from the current window size and is called at construction and after a resize-drag ends (not continuously during the drag -- see the gripper's `MouseMove`/`MouseUp` comments). |
| `UI/AnalysisGraph.lua` | `Graph` -- the time plot. Fixed 48 buckets (`docs/IMPLEMENTATION_PLAN.md`) spanning the session's actual duration, one pooled column of Controls per bucket per series slot (max 2 regular series), a **dotted approximation of the dashed morale overlay** (flagged as a deliberate simplification in the file's own header comment -- Turbine.UI Controls are axis-aligned rectangles, no cheap way to draw a literal dashed line). `Graph:Resize(width)` repositions the existing pool in place rather than rebuilding it. |

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

`/reck show|hide [live\|death\|analysis]`, `/reck move <live\|death\|analysis>`, `/reck reset`
are in `Main.lua`. `show`/`hide` for `live`/`death` only flip their enable flag (same effect as
the options panel checkboxes) rather than forcing `SetVisible` -- both windows are entirely
event-driven (`Sessions.current`, `Sessions.OnSelfDefeat`) and would re-hide themselves on the
next throttled `Update()` if forced visible with no active data. `analysis` is the one window a
forced show/hide makes sense for. `move` is a recovery command (reset to (200, 200) and show) for
a window dragged off-screen. `reset` calls `Settings.ResetToDefaults()` then repositions all
three windows and refreshes the options panel in place.

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
  `_G.lp` is the conventional handle (matches `VitalSelf`); the bare `LocalPlayer` global
  exists **only** because `Trigger.ParseCombatChat` reads `LocalPlayer.name` directly as a
  property, not a method call -- do not remove it even though it looks redundant with `_G.lp`.
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
  positions, `liveTab`, `deathAutoHide`, pins.
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

There is no test runner in the repo. `/reck dump` (in `Main.lua`) prints the current or most
recent session's totals to chat -- the in-game way to re-check the event pipeline against
`reference/Combat_20260819_1.txt` / `reference/Enemy_20260819_1.txt` (read the two logs by eye
and compare). See "Build status" above for how Phase 1 was checked offline before any in-game
load existed to run `/reck dump` against.
