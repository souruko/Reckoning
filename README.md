# Basil

A Lord of the Rings Online (LotRO) plugin that reads the combat chat log and reports on the
local player's own combat: a compact always-on live meter, a death post-mortem that appears
by itself, and a post-combat analysis window covering the last ten fights. Tracked scope is
the local player only -- nothing is read off targets or the group.

## Status

All six phases of `docs/IMPLEMENTATION_PLAN.md` are built: the full data pipeline, all three
windows (live meter, death cause, post-combat analysis), and the options panel / `/basil`
commands. **None of it has been loaded in-game yet.** Phases 1-2 were checked offline against
real combat logs; everything from Phase 2 on (all the `Turbine.UI` code) is syntax-checked only.
See `CLAUDE.md`'s "Build status" and "Analysis window: what's genuinely unverified" before
trusting any of it -- load it in-game and work through each phase's "Done when" line next.

## Design source

This plugin was built from a design handoff bundle, kept in full under `docs/`:

- `docs/DESIGN.md` -- the data model: which parser event feeds which number, session rules,
  window specs, design tokens.
- `docs/IMPLEMENTATION_PLAN.md` -- the phased build order this plugin follows.
- `docs/mockup/LOTRO Combat Analyzer.html` -- the high-fidelity design reference. Open in a
  browser; not production code, nothing in it is ported literally.
- `reference/*.txt` -- real combat log captures, used as parser fixtures.

`Parse/en.lua` is `Trigger.ParseCombatChat`, ported verbatim from `souruko/Gibberish3`
(`UTILS/COMBATCHATPARSE/en.lua`) -- do not rewrite it.

## Development

The plugins folder is the live game directory -- edits here are immediately live. Reload
in-game to see a change:

```
/plugins refresh
/plugins load Basil
```

Runtime errors surface in the LotRO chat window; there is no other log.

## Version bumps

The version appears in **two** files and must be kept in sync: `Basil.plugin`
(`<Version>`) and `Basil.plugincompendium` (`<Version>`), plus `Constants.lua`
(`Basil.Version`). `CHANGELOG.md` gets a matching entry, written for players rather than
developers.
