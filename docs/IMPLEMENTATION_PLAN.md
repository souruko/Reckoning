# Implementation plan — Reckoning

A build order for the plugin described in `DESIGN.md`. Each phase ends somewhere
you can load in-game and see something real; nothing is left half-wired between
phases.

Read `DESIGN.md` first — it holds the data model and the parser facts that decide
what is buildable. This file is only the order of work.

---

## Phase 0 — Skeleton that loads

**Goal:** `/plugins load Reckoning` prints a line and nothing errors.

- `Reckoning.plugin` + `Reckoning.plugincompendium` (keep `<Version>` in sync in
  both — same rule as `VitalSelf`).
- `Main.lua` as the package entry point.
- Vendor `Utils/Class.lua` + `Utils/Type.lua` from `VitalSelf` unchanged. They are
  the shared Turbine OOP shim (`class()`, `final_class()`, mixins), not
  plugin-specific.
- `Constants.lua` — the font table (copy the shape from `Gibberish3/Constants.lua`),
  the theme palette, event-code and damage-type enums.
- `Settings.lua` — load/save via
  `Turbine.PluginData.Save(Turbine.DataScope.Character, "Reckoning", settings)`,
  plus a `FixColors()` that rebuilds **every** colour key on load.
  Read unknown keys defensively.
- `/reck` shell command with `help`.

**Done when:** loads clean, saves and reloads settings without error.

---

## Phase 1 — Event pipeline (no UI)

**Goal:** the whole data model is correct before a single pixel is drawn.

- `Parse/en.lua` — **drop in `parser/en.lua` from this bundle verbatim.** It is
  `Trigger.ParseCombatChat` from `Gibberish3/UTILS/COMBATCHATPARSE/en.lua` and
  already handles mounted combat, absorbs, deflects and the self-heal name swap.
  Do not rewrite it. Provide its two dependencies: `L.DirectDamage` (label for a
  hit with no named skill) and `LocalPlayer.name`. Keep `de` / `fr` as a later
  drop-in, selected the way `Constants.lua` does it
  (`Turbine.Shell.IsCommand("hilfe")` / `("aide")`).
- The full event-code, `avoidType`, `critType` and `dmgType` tables are in
  `DESIGN.md` § *The parser* — read that before writing the dispatcher.
- `Events.lua` — subscribe to `Turbine.Chat.Received`, filter to the combat
  channels, run the parser, discard anything where neither initiator nor target
  is `LocalPlayer.name` (event 14 excepted — it names you as target already):

```lua
local code, initiator, target, skill, amount, avoidType, critType, dmgType
      = Trigger.ParseCombatChat(args.Message)
if code == nil then return end

local mine = (initiator == LocalPlayer.name)
local onMe = (target    == LocalPlayer.name)
if not (mine or onMe) and code ~= 14 then return end

if     code == 1  and mine then Session:AddDone(skill, dmgType, target, amount, avoidType, critType)
elseif code == 1  and onMe then Session:AddTaken(skill, dmgType, initiator, amount, avoidType, critType)
elseif code == 3  and mine then Session:AddHealOut(skill, target, amount, critType)
elseif code == 3  and onMe then Session:AddHealIn(skill, initiator, amount, critType)
elseif code == 14          then Session:AddTempMoraleLoss(amount)
elseif code == 9           then Session:OnDefeat(initiator)
elseif code == 10          then Session:OnRevive(initiator)
end
```

  Only codes **1, 3, 9, 10, 14** are consumed; 4, 7, 8, 16, 17 are dropped.
  Names are already `^[Tt]he `-stripped by the parser — compare against the
  stripped form.
- Stamp each event with `Turbine.Engine.GetGameTime()` on arrival — the chat line
  has no timestamp.
- On every **incoming** damage event also sample `lp:GetMorale()` /
  `lp:GetMaxMorale()` and store it on the event. That single sample feeds the
  morale line and the death list's morale column.
- `Session.lua` — the aggregate:

```lua
Session = {
  startTime, endTime, startClock,   -- startClock = local time string for the rail
  activeSeconds,                    -- seconds with >=1 own event, for dps
  died = false, pinned = false,
  buckets = { [second] = { done, taken, healOut, healIn, moralePct } },
  agg = {
    done      = { [skill .. "|" .. dmgType]   = row },
    healOut   = { [skill .. "|" .. target]    = row },
    healIn    = { [skill .. "|" .. caster]    = row },
    taken     = { [skill .. "|" .. dmgType]   = row },
  },
  -- row = { skill, type, who, hits, total, max, crits, devs, avoided,
  --         avoidBreakdown = { [avoidType] = count } }
  lastTaken = {},   -- ring of 5, for the death window
}
```

- Session lifecycle: opens on the first own event; closes after **5s** of
  silence; discarded under **3s**; ring buffer of 10 with pinned sessions exempt.
- Sanity check before touching UI: `/reck dump` writing totals to chat. Feed the
  captures in `reference/` through the parser line by line as fixtures and
  compare.

**Done when:** `/reck dump` after a fight prints totals that match the log.

---

## Phase 2 — Window chrome

**Goal:** one reusable themed window; no `Turbine.UI.Lotro.Window` anywhere.

- `UI/Frame.lua` — `Frame` extends `Turbine.UI.Window`:
  - solid background `Control` + four 1px border Controls
  - header Control: title `Label` (TrajanPro13) + close glyph `Label`
  - manual drag on the header (`MouseDown` / `MouseMove` / `MouseUp` storing the
    offset — copy the pattern from `VitalSelf/UI/Vital.lua`'s move overlay)
  - position persisted per window key
  - `SetMouseVisible(false)` on everything decorative
- `UI/Bar.lua` — a 1px-border Control whose fill child's width is set on refresh.
- `UI/Row.lua` — a row of `Label`s at fixed x offsets; number labels use
  `LucidaConsole12` so digits align without measuring text.

**Done when:** an empty themed window opens, drags, closes and remembers where it was.

---

## Phase 3 — Live meter (window 1)

**Goal:** the thing you actually keep on screen.

- 260 × 186. Header 26, tab row 24, body 136.
- Four tabs: Done / Taken / Heal out / Heal in. Tab click writes
  `settings.liveTab` and redraws.
- Four lines per tab per `DESIGN.md`: headline total + rate, second figure,
  context stat, max hit.
- Refresh on a throttle (4–5 Hz), not per event — chat bursts hard in raids.
- On combat end: dim, hold the last fight 8s, hide.

**Done when:** numbers track a live fight and the tab choice survives a reload.

---

## Phase 4 — Death cause (window 2)

**Goal:** it tells you what killed you, unprompted.

- 380 × 200. Fires on event `9` where the defeated name is the local player.
- Event 9 carries **no killer** — take the initiator of the final damage-taken
  event for the "last hit by" line.
- Five rows from `lastTaken`: relative time, skill · damage type, amount,
  morale after that hit. Temp-morale loss (event `14`) gets its own row so a
  popped bubble does not read as mitigated damage.
- Tint the final row rather than appending "killing blow" to the label — the text
  column truncates.
- 2px rule counts down the auto-hide (`settings.deathAutoHide`, default 15s).

**Done when:** you die and the window explains it without being asked.

---

## Phase 5 — Analysis window (window 3)

**Goal:** the post-mortem.

Build in this order — each step is independently useful:

1. **Frame + session rail** (208px). Rows: name on the top line beside the pin
   glyph, `start · duration · dps` beneath. Pinned sort to the top.
2. **View tabs** — Damage done / Healing done / Healing taken / Damage taken.
   Each view keeps its own aggregate, so switching is a redraw not a recount.
3. **Target/source picker** — "All targets" first and selected by default; names
   come from the aggregate keys. Pooled vs. filtered changes which side panels show.
4. **KPI row** — five per view, per `DESIGN.md`.
5. **Skill table** — a `ScrollView` of `Row`s with the per-row share bar behind
   the labels. Crit and devastating are **separate columns**, never summed.
6. **Graph** — 48 buckets, one column of 1px Controls per bucket. Series per view;
   morale is a dashed overlay on its own 0–max axis. Rebuild only on session or
   view change, never per frame.
7. **Side panels** — pooled: per-target/source comparison **plus** type split;
   filtered: type split plus that source's avoidance breakdown.

**Done when:** you can select any of the last ten sessions and read all four views.

---

## Phase 6 — Options and polish

- Options panel (`plugin.GetOptionsPanel`) extending `Turbine.UI.ListBox`, same
  shape as `VitalSelf/UI/Settings.lua`: window scale, auto-hide duration, which
  windows are enabled, colours.
- `/reck` subcommands: `show`, `hide`, `move`, `reset`, `dump`.
- Decide whether pins should survive a reload (persist the session, not just the flag).
- German and French parser files.

---

## Performance notes

- One throttled refresh timer per window; never redraw from the event handler.
- Never rebuild a `ScrollView`'s children per refresh — pool the rows and set text.
- Aggregate on ingest (increment counters), never by re-scanning an event list.
- Keep the raw event list only as long as the session needs it; the buckets and
  aggregates are the durable form.

## Traps found while designing this

- Crit and devastating are distinct `critType` values (2 and 3). Do not add them.
- `avoidType` 2–7 and 11 are full avoids (amount 0, dmgType 13); 8–10 are
  partials on a real hit.
- A full avoid is event `1` with `amount == 0` — same stream as damage.
- Heal lines carry **no** damage type.
- Self-heals arrive with initiator and target rearranged; key on target.
- `dmgType 13` means unknown/absorbed — keep it out of the type split.
- `Turbine.UI.Color` does not survive serialization.
- Verdana has no 11 or 13 — 10, 12, 14, 16, 18, 20, 22, 23 only.
