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

- `load_test.lua` loads **`Main.lua` itself**, top to bottom, constructing all four windows and
  the Plugin Manager stub, then drives a whole fight through `Turbine.Chat.Received` and
  `Events.heartbeat:Update()` and runs every `/reck` subcommand.
- the rest construct the **real classes** (`Graph`, `RangeSlider`, `Analysis`, `LiveMeter`,
  `DeathCause`, `OptionsWindow`, `OptionsPage`, `Slider`, `Segment`) and call their real methods.
- `options_test.lua` in particular never pokes `_G.settings` and calls a refresh: it fires the
  control's own `MouseClick` / `CheckedChanged` / `MouseDown`+`MouseMove`+`MouseUp`, because
  "write the setting directly and re-render" is precisely the shortcut that hid three bugs before.

`stub.lua` asserts on a non-numeric or negative `SetSize`/`SetPosition` argument. That is how a
nil constant reaching a layout call gets caught, which `luac -p` cannot see. It also asserts on
`SetOpacity` **when the control already has a solid `BackColor`** -- that is the case where it
does not blend in this engine (use `Theme.Mix` instead). The guard used to ban `SetOpacity`
outright, which encoded the lesson slightly too broadly: a whole-window fade on a `Window` with no
`BackColor` of its own is confirmed to work, and `UI/PostButton.lua` uses the same call to fade
its quickslot down over the themed button underneath it.

## What each file covers

| File | Covers |
| --- | --- |
| `stub.lua` | The Turbine stub + package loader every other file starts with. |
| `slice_test.lua` | `Session:Slice` against `Session.agg`, over the repo's real reference logs: full-range parity, disjoint sub-ranges summing to the whole, per-counterpart slices summing to pooled, and the cache invalidating on `Touch()`. |
| `graph_test.lua` | `Graph` geometry: nothing escapes the plot, morale bars carry forward, series hide/show, range overlays, buff lanes, resize, tooltip clamping, and the plotted values summing to `Session:Total`. |
| `buffs_test.lua` | `Buffs` polling against a fake `EffectList`, in both 0-based and 1-based index conventions, plus a failed read (must not read as "everything faded"), range clipping, and the ignore list. |
| `lifecycle_test.lua` | Session open/close: heals only open or extend a session while the client has the player flagged in combat, a heal-over-time ticking after a fight cannot postpone the close, a short fight with a long heal tail is still discarded, a revive never opens a session, and a throwing `IsInCombat` degrades to "out of combat". |
| `analysis_test.lua` | The whole analysis window: tab order, the block stack's y offsets, table columns fitting their viewport in all four views, KPI cards not colliding, range dragging rescoping every widget, buff charting, resize at both extremes, and (section 18) the post button's invisible quickslot overlay tracking the window through drag, resize, show/hide, re-raise and shutdown. |
| `chatpost_test.lua` | `ChatPost` against real sessions: that a post is always a single line within `MAX_MESSAGE` (a multi-line alias was refused in-game), range and counterpart scoping reaching it, the death preset's availability and its killing-blow-relative timestamps, colour being budgeted and stripping back to exactly the plain line, alias assembly per channel, and the newline/angle-bracket injection guard on names taken from parsed game text. |
| `windows_test.lua` | Live meter (footprint, tab underlines, sparkline band) and death cause (killing blow vs. biggest hit marking, morale percentages, column bounds). |
| `options_test.lua` | The whole options window, driven through real clicks: the shell's geometry, all seven pages building and the pane never holding more than one item, rail hover/selection, a checkbox writing and saving exactly once, a slider drag persisting **once** rather than per move (and not running away from the pointer), `deathRows` resizing the death window and the `lastTaken` ring, segment cells sharing their borders, palette presets reaching the live meter's sparkline / the analysis plot / a chat post's tint, `bucketWidth` changing the graph's bucket count with the window and slider staying in step, the buff picker's cap refusal and reordering, the ignore chips, the two-step Clear data, `Settings.Clamp`'s range and enum guards, the live meter's opacity/idle-fade/click-through states, `clockThroughAvoids`, the session rules (`sessionsKept`, `minFightLength`, pin exemption, `DropUnpinned`, an unreadable zone id failing safe), and Defaults putting every control back. |
| `load_test.lua` | The plugin as a whole, as described above. |

## What these still cannot tell you

They exercise **layout arithmetic and game logic**, not rendering. Whether a Control actually
draws, whether a mouse event reaches it through a mouse-invisible sibling, whether a font renders
a given glyph, and whether an undocumented call exists at all are still in-game questions. See
`CLAUDE.md` "Build status" for the list of things in this codebase that are still assumptions.
