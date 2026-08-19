# Reckoning — combat analyser for LOTRO

Design documentation for the plugin mocked up in `Combat Analyzer.dc.html`.
Everything below is grounded in the real client API and in the combat-chat parser
from `souruko/Gibberish3` (`UTILS/COMBATCHATPARSE/en.lua`), read 2026-08-19.

## Scope

Three windows, one data pipeline:

1. **Live meter** (260 × 186) — always on screen, four tabs.
2. **Death cause** (380 × 200) — auto-popup on defeat, auto-hides after 15s (configurable).
3. **Post-combat analysis** (1080 × 600, resizable to 1440 × 800) — four views, session rail.

Tracked scope is **the local player only**. Nothing is read off targets or the
group: no target morale, no target effects. The only live target datum is the
current target's *name*, used to split your own damage into "to current target".

## Data source

Every number comes from `Trigger.ParseCombatChat(line)` over the
`PlayerCombat` / `EnemyCombat` chat channels, plus `LocalPlayer` for your own vitals.

| Event | Returns | Used for |
|---|---|---|
| `1` damage | initiator, target, skill, amount, avoidType, critType, dmgType | damage done / damage taken, type split, crit + dev, avoidance |
| `3` heal | initiator, target, skill, amount, critType | healing done / healing taken |
| `14` temp morale loss | target = you, amount | its own row in the death list |
| `9` defeat | defeated name only | session boundary, death popup trigger |
| `10` revive | name | session boundary |

Direction is decided by name: `initiator == LocalPlayer.name` → outgoing,
`target == LocalPlayer.name` → incoming. Discard everything else.

## Consequences of the parser that shaped the design

- **Avoidance is in the damage stream.** A full avoid is event `1` with
  `amount == 0` and `avoidType` 2–7 or 11 (miss, immune, resist, block, parry,
  evade, deflect). Partials are 8–10 on a real hit. So the damage-taken table's
  *Avoided* column is `avoided ÷ (hits + avoided)` per source — no second feed.
- **Heal lines carry no type.** `critType` yes, damage-type no. Hence the healing
  tables show caster / recipient where damage tables show type.
- **Self-heals rearrange the names.** When `skillName` is nil the parser swaps
  initiator and target, so both healing views key on `target`.
- **Power is not tracked.** `moralePower == 2` returns nil from the parser, and
  event `4` (power heal) is ignored here.
- **The defeat line has no killer.** Event `9` gives only the defeated name — for
  the local player it is your own name. The death window therefore says
  *"last hit by"* and takes the initiator of the final damage-taken event.
- **`dmgType 13` means unknown / absorbed.** Absorbed damage arrives as amount 0
  with type 13; keep it out of the type split.
- **No timestamps.** The chat line has none. Each event is stamped by the plugin
  on arrival (`Turbine.Engine.GetGameTime()`), which is also the session's
  start-time label and the 1s bucket key for the graph.

### The parser

The parser is included in this bundle as `parser/en.lua` — the exact file the
plugin should use. **Port it verbatim; do not rewrite it.** It is
`Trigger.ParseCombatChat(line)` from `souruko/Gibberish3`
(`UTILS/COMBATCHATPARSE/en.lua`), already handling mounted combat, absorbs,
deflects and the self-heal name swap. Its two external dependencies are
`L.DirectDamage` (the label used when a hit has no named skill) and
`LocalPlayer.name`.

It returns `eventCode, ...` and `nil` for anything unparseable. The signature
differs per event code:

```
 1  damage   → 1, initiator, target, skill, amount, avoidType, critType, dmgType
 3  heal     → 3, initiator, target, skill, amount, critType
 4  power    → 4, initiator, target, skill, amount, critType      (ignored here)
 7  interrupt→ 7, initiator, target                               (ignored here)
 8  dispel   → 8, initiator, target                               (ignored here)
 9  defeat   → 9, defeatedName
10  revive   → 10, revivedName
14  temp mor → 14, nil, LocalPlayer.name, nil, amount
16  state brk→ 16, nil, target, nil                               (ignored here)
17  buff     → 17, initiator, target, skill                       (ignored here)
```

This plugin consumes **1, 3, 9, 10 and 14** and drops the rest.

### Lines it matches

| # | Pattern | Emits |
|---|---|---|
| 1 | `X scored a ...hit... on Y.` | damage (or absorb: amount 0, dmgType 13) |
| 2 | `X applied a ...heal ... .` | heal 3, or power heal 4 |
| 3 | `X applied a benefit with S on Y.` | 17 buff |
| 4 | `X tried/missed/was deflected trying to use S on Y...` | damage 1, amount 0, avoidType set |
| 5 | `X reflected N T to the Morale of Y.` | damage 1 (skill `"Reflect"`) or heal 3 |
| 6 | `You have lost N points of temporary Morale!` | 14 |
| 7 | root / daze / fear broken | 16 |
| 8 | `X was interrupted by Y!` | 7 |
| 9 | `You have dispelled C from Y.` | 8 |
| 10 | six defeat phrasings | 9 |
| 11 | four revive phrasings | 10 |

### `avoidType`

```
 1 none (a clean hit)      5 blocked            9 partial parry
 2 missed                  6 parried           10 partial evade
 3 immune                  7 evaded            11 deflected
 4 resisted                8 partial block
```

Full avoids (2–7, 11) arrive as event **1** with `amount == 0` and
`dmgType == 13`. Partials (8–10) arrive on a real hit with a real amount. Both
come down the same pipe as ordinary damage — that is the whole source of the
Avoided column.

### `critType`

```
1 normal    2 critical    3 devastating
```

Present on both damage and heal lines. Keep 2 and 3 in separate counters; never sum them.

### `dmgType`

```
 1 Common      5 Acid        9 Westernesse        13 unknown / none / absorbed
 2 Fire        6 Shadow     10 Ancient Dwarf-make
 3 Lightning   7 Light      11 Orc-craft
 4 Frost       8 Beleriand  12 Fell-wrought
```

Type 13 covers absorbs and any line with no stated type — exclude it from the
type split rather than charting it as a type.

### Behaviours to preserve when porting

- `^[Tt]he ` is stripped from every entity name, so `"the Blood-sworn Guard"`
  and `"Blood-sworn Guard"` aggregate as one source. Match your own name
  comparisons against the stripped form.
- Damage to **Power** returns `nil` (`moralePower == 2`), so power damage never
  reaches you.
- A hit with no named skill falls back to `L.DirectDamage` — provide that string.
- **Self-heals** have no `with <skill>` clause, so `skillName` comes back nil
  and the function swaps: `skillName = initiatorName; initiatorName = targetName`.
  Always key heal direction on `target`.
- Reflect damage is reported under the fixed skill name `"Reflect"`.
- Defeat (9) reports only the **defeated** entity — for your own death, your own
  name. The killer is never in that line.
- Numbers arrive comma-formatted and are converted with
  `string.gsub(amount,",","")+0`.
- Localisation: `de.lua` and `fr.lua` exist in Gibberish3 with the same
  signature. Select by language the way `Constants.lua` does
  (`Turbine.Shell.IsCommand("hilfe")` / `("aide")`).

### Wiring it

```lua
local code, initiator, target, skill, amount, avoidType, critType, dmgType
      = Trigger.ParseCombatChat(args.Message)

if code == nil then return end

local mine = (initiator == LocalPlayer.name)
local onMe = (target    == LocalPlayer.name)
if not (mine or onMe) and code ~= 14 then return end
```

Then: `1` + `mine` → damage done; `1` + `onMe` → damage taken (and sample
`lp:GetMorale()` here); `3` + `mine` → healing done; `3` + `onMe` →
healing taken; `14` → temp-morale row; `9`/`10` → session boundary and the
death popup.

### Not buildable, and why

| Wanted | Why not |
|---|---|
| Overkill | needs the target's remaining morale |
| Overheal on other players | needs their morale pool — kept only for heals **on you** |
| Enemy debuff/buff uptime | reading target effects is out of scope |
| Power damage | dropped by the parser |

## Session model

- A session opens on the first own event and closes after **5s** of silence.
- Anything under **3s** is discarded.
- Ring buffer of **10**; dropped on reload.
- **Pinned** sessions (the diamond in the rail) are exempt from the buffer and
  sort to the top. Pins persist for the play session via `Turbine.PluginData`.
- Rail label = start time + name + duration + dps, `· died` when you fell.
- Each view keeps its own aggregate table, so switching views is a redraw,
  not a recount.
- DPS is `total ÷ active seconds`; wall-clock rate is shown underneath.

## Window 1 — live meter

Four tabs, each with the same four-line shape: headline total + rate, a second
figure, one context stat, and a max hit.

| Tab | Headline | Second line | Stat | Max |
|---|---|---|---|---|
| Done | damage done + dps | to current target + dps | crit / dev | largest hit + skill |
| Taken | damage taken + tps | incoming crit / dev | avoided % of swings | largest hit taken |
| Heal out | healing done + hps | self / others | crit / dev | largest heal cast |
| Heal in | healing taken + hps | cover of damage taken | crit heals | largest heal received |

Rate resets on combat end; the meter dims, holds the last fight for 8s, then hides.

## Window 2 — death cause

Header, "last hit by" block, then the **last five damage-taken events**: time
relative to death, skill · damage type, amount, and your morale after that hit
(sampled from `LocalPlayer:GetMorale()` on every incoming event). Temporary-morale
loss (event 14) is a separate row so a popped bubble does not read as mitigated
damage. A 2px rule counts down the auto-hide.

## Window 3 — post-combat analysis

Session rail (176px) + four view tabs. Every view: goal line, target/source
picker, five KPIs, the time graph, a skill table, and two side panels.

**Target/source picker** — defaults to all targets pooled. When pooled, the side
panels show *per target / per source* comparison **and** the type split; when
filtered, the split and the source's own defence breakdown.

| View | Question | Table columns | Graph series |
|---|---|---|---|
| Damage done | which skills carried it, against whom | Skill, Type, Hits, Crit, Dev, Max, Total | damage |
| Healing done | self-sustain and group contribution | Skill, To, Heals, Crit, Dev, Max, Total | healing out |
| Healing taken | did healers keep pace | Skill, From, Heals, Crit, Dev, Max, Total | healing in, taken, morale |
| Damage taken | what hit you, what got through | Skill, Type, Hits, Crit, Dev, Avoided, Max, Total | taken, healing in, morale |

Crit and devastating are **always separate columns** — never summed.
The morale line is a dashed overlay on its own 0–max axis, labelled at the right edge.

## Type

Only the client's own fonts exist (`Constants.lua` in Gibberish3), so every size
in the mockup is a real one:

- `Verdana10` — uppercase labels
- `Verdana12` — rows and body; this is the floor, there is no 11 or 13
- `Verdana20` / `Verdana22` — headline numbers
- `TrajanPro13` / `TrajanPro16` — window titles and the boss name
- `LucidaConsole12` — every number column (the only fixed-width face, so digits
  align without measuring text width per row)

## Controls

**No `Turbine.UI.Lotro.Window`.** The stock Lotro window carries parchment
chrome that cannot be themed into this palette. Every window is a bare
`Turbine.UI.Window` with the frame built by hand:

- a solid background `Control`, plus 1px child Controls as borders
- a header `Control` holding the title `Label` and a close glyph `Label`
- drag handled manually on the header (`MouseDown` / `MouseMove` / `MouseUp`
  storing the offset, as `VitalSelf`'s move overlay does), position saved to
  `Turbine.PluginData`
- `SetMouseVisible(false)` on everything decorative so clicks fall through

Square corners, flat fill — nothing in the mockup needs a rounded rect:

- Each inner panel is a `Turbine.UI.Control` with a solid background plus 1px
  child Controls as borders.
- Bars are Controls whose width is set on refresh.
- Tables are rows of `Label`s at fixed x offsets inside a `ScrollView`.
- The graph is one column of 1px Controls per bucket (48 buckets, ~13px each) —
  cheap to redraw, no bitmap needed.
- Icons load as external images into a Control background.

## Persistence

Follow the `VitalSelf` pattern: `Turbine.PluginData.Save(Turbine.DataScope.Character, "Reckoning", settings)`.

- `Turbine.UI.Color` does **not** survive serialization — it returns as a plain
  `{R,G,B}` table. Rebuild every color key on load (a `FixColors()` equivalent)
  or the plugin breaks on second load.
- Read new keys defensively; existing saves will not have them.
- Persist window positions, the live tab, the auto-hide duration and pins.
- Sessions themselves are **not** persisted.

## Open questions

- Should pins survive a reload (persist the session, not just the pin)?
- Fellowship-wide tracking is out of scope now; the log only shows what your
  channels are set to receive.
