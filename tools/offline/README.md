# Offline checks

Everything here runs the **real** plugin source under a **real Lua 5.1** interpreter -- the same
version the game runs -- against a `Turbine` stub built on this repo's own `class()` shim, so
`class(Turbine.UI.Control)` and every `Turbine.UI.*` call in the source works unchanged.

```sh
apt-get install lua5.1      # or: brew install lua@5.1
sh tools/offline/run.sh
```

## Why this exists in this shape

The original Phase 1 harness (see `CLAUDE.md` "Build status") called `Trigger.ParseCombatChat`
and the `Sessions.*` dispatch **directly**, hand-reimplementing the mine/onMe branch, and set
`LocalPlayer = { name = "Whatever" }` as a plain table. It therefore could not see three separate
bugs that all had the same shape: code reading a field off an object *Turbine* constructed, whose
real shape the harness had replaced with a convenient fake (`args.Type` vs `args.ChatType`,
`LocalPlayer.name` not existing, and defeat lines arriving on a third `ChatType.Death` channel).

So these go through the real entry points instead:

- `load_test.lua` loads **`Main.lua` itself**, top to bottom, constructing all three windows and
  the options panel, then drives a whole fight through `Turbine.Chat.Received` and
  `Events.heartbeat:Update()` and runs every `/reck` subcommand.
- the rest construct the **real classes** (`Graph`, `RangeSlider`, `Analysis`, `LiveMeter`,
  `DeathCause`) and call their real methods.

`stub.lua` asserts on a non-numeric or negative `SetSize`/`SetPosition` argument, and errors
outright on `SetOpacity` (which does not blend in this engine -- see `Theme.Mix`). That is how a
nil constant reaching a layout call gets caught, which `luac -p` cannot see.

## What each file covers

| File | Covers |
| --- | --- |
| `stub.lua` | The Turbine stub + package loader every other file starts with. |
| `slice_test.lua` | `Session:Slice` against `Session.agg`, over the repo's real reference logs: full-range parity, disjoint sub-ranges summing to the whole, per-counterpart slices summing to pooled, and the cache invalidating on `Touch()`. |
| `graph_test.lua` | `Graph` geometry: nothing escapes the plot, morale bars carry forward, series hide/show, range overlays, buff lanes, resize, tooltip clamping, and the plotted values summing to `Session:Total`. |
| `buffs_test.lua` | `Buffs` polling against a fake `EffectList`, in both 0-based and 1-based index conventions, plus a failed read (must not read as "everything faded"), range clipping, and the ignore list. |
| `lifecycle_test.lua` | Session open/close: heals only open or extend a session while the client has the player flagged in combat, a heal-over-time ticking after a fight cannot postpone the close, a short fight with a long heal tail is still discarded, a revive never opens a session, and a throwing `IsInCombat` degrades to "out of combat". |
| `analysis_test.lua` | The whole analysis window: tab order, the block stack's y offsets, table columns fitting their viewport in all four views, KPI cards not colliding, range dragging rescoping every widget, buff charting, and resize at both extremes. |
| `windows_test.lua` | Live meter (footprint, tab underlines, sparkline band) and death cause (killing blow vs. biggest hit marking, morale percentages, column bounds). |
| `load_test.lua` | The plugin as a whole, as described above. |

## What these still cannot tell you

They exercise **layout arithmetic and game logic**, not rendering. Whether a Control actually
draws, whether a mouse event reaches it through a mouse-invisible sibling, whether a font renders
a given glyph, and whether an undocumented call exists at all are still in-game questions. See
`CLAUDE.md` "Build status" for the list of things in this codebase that are still assumptions.
