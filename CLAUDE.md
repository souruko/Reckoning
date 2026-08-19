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

Phase 0 (skeleton) only, per `docs/IMPLEMENTATION_PLAN.md`: the plugin loads, settings
save/reload, `/reck help` responds. Phases 1-6 (event pipeline, window chrome, live meter,
death cause, analysis window, options/polish) are not started. Follow the implementation plan
in order -- each phase is written to end somewhere loadable and testable in-game.

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
| `Utils/Class.lua`, `Utils/Type.lua` | Vendored OOP shim, see above. |

Not yet created (see `docs/IMPLEMENTATION_PLAN.md` for what each owns): `Events.lua`
(Phase 1), `Session.lua` (Phase 1), `UI/Frame.lua` / `UI/Bar.lua` / `UI/Row.lua` (Phase 2),
and the three window modules (Phases 3-5).

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

## The parser and its wiring (Phase 1 -- not yet implemented)

`Trigger.ParseCombatChat(line)` returns `eventCode, ...` (signature varies by code) or `nil`
for anything unparseable. Full details, including the `avoidType` / `critType` / `dmgType`
tables and which event codes to consume, are in `docs/DESIGN.md` "The parser" -- read that
before writing `Events.lua`.

Two things learned from reading the **live** Gibberish3 install (`TRIGGER/CHAT/Functions.lua`)
that are not written down in the design bundle and are easy to miss:

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

There is no test runner in the repo. `docs/IMPLEMENTATION_PLAN.md` Phase 1 calls for
`/reck dump` (not yet implemented) to print session totals to chat, checked by hand against
`reference/Combat_20260819_1.txt` and `reference/Enemy_20260819_1.txt` fed through the parser
line by line.
