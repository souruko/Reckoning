# Basil

A Lord of the Rings Online (LotRO) plugin that reads the combat chat log and reports on the
local player's own combat: a compact always-on live meter, a death post-mortem that appears
by itself, and a post-combat analysis window covering the last ten fights. Tracked scope is
the local player only -- nothing is read off targets or the group.

## Status

All six phases of `docs/IMPLEMENTATION_PLAN.md` are built and have been loaded and used in-game:
the full data pipeline, four windows (live meter, death post-mortem, post-combat analysis,
options), chat posting, and the `/basil` commands. `CLAUDE.md`'s "Build status" section is the
running record of what a real load has confirmed and what is still only reasoned-about -- read it
before changing any `Turbine.UI` call, since most of its entries are bugs that only an in-game
load could have found.

Only English combat chat is parsed (`Parse/en.lua`); German and French drop-ins are documented in
that file's header but not written.

## Commands

`/basil help` lists them. `/basil options` opens the settings window (the same thing the Plugin
Manager's **Open options** button does), `/basil post [death]` previews the chat post the analysis
window currently has armed, and `/basil show|hide|move <live|death|analysis|options>` plus
`/basil reset` are the window recovery commands.

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

Run `sh tools/offline/run.sh` before every in-game load. It needs `lua5.1` (the game's own Lua
version) and runs the real classes and the real `Main.lua` against a `Turbine` stub. It cannot
tell you whether anything actually draws, but everything it catches is a reload you don't spend.

## Version bumps

The version appears in **three** places and must be kept in sync: `Basil.plugin` (`<Version>`),
`Basil.plugincompendium` (`<Version>`) and `Constants.lua` (`Basil.Version`) --
`tools/offline/load_test.lua` asserts the last of those, so a half-done bump fails there.
`CHANGELOG.md` gets a matching entry, written for players rather than developers.
