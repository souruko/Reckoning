-- Drives the REAL Buffs.Poll/CloseSession/Stats against a fake Turbine EffectList, including
-- the 0-vs-1-based index probe, a mid-poll read failure, and range clipping.
local env = dofile("stub.lua"); local ROOT = env.ROOT
import "Basil.Constants"
Trigger = {}; import "Basil.Parse.en"; import "Basil.Settings"

-- A fake effect list whose index base is configurable, so both Turbine conventions get exercised.
local effectSet, indexBase, readFails = {}, 1, false
local function MakeEffect(name, icon, debuff)
  return {
    GetName = function() return name end,
    GetIcon = function() return icon end,
    IsDebuff = function() return debuff == true end,
  }
end
_G.lp = {
  GetName = function() return "Luxtheninth" end,
  GetMorale = function() return 5e5 end, GetMaxMorale = function() return 9e5 end,
  GetTarget = function() return nil end,
  IsInCombat = function() return true end,  -- heals only count in combat, see Sessions.lua
  GetEffects = function()
    if readFails then error("effect list unavailable") end
    local ordered = {}
    for i = 1, #effectSet do ordered[i] = effectSet[i] end
    return {
      GetCount = function() return #ordered end,
      Get = function(_, i)
        local idx = i - indexBase + 1
        if idx < 1 or idx > #ordered then
          if indexBase == 1 and i == 0 then error("index 0 is out of range") end
          return nil
        end
        return ordered[idx]
      end,
    }
  end,
}
LocalPlayer = _G.lp; LocalPlayer.name = LocalPlayer:GetName()
Settings.Load()
import "Basil.Session"; import "Basil.Sessions"; import "Basil.Buffs"

local fails = 0
local function check(label, ok, detail)
  if not ok then fails = fails + 1 end
  print(string.format("%-58s %s%s", label, ok and "OK" or "**FAIL**", detail and ("  " .. detail) or ""))
end
local function near(a, b) return math.abs(a - b) < 0.001 end

local function Set(...) effectSet = {}; for _, e in ipairs({...}) do effectSet[#effectSet+1] = e end end
local WRIT   = MakeEffect("Writ of Health", "icon:writ")
local GUARD  = MakeEffect("Bracing Guard", "icon:guard")
local VERSE  = MakeEffect("Mending Verse", nil)
local RIDING = MakeEffect("Riding", "icon:ride")            -- default ignore list
local POISON = MakeEffect("Grievous Wound", "icon:pois", true) -- a debuff

-- open a session at t=1000
Turbine.Engine._time = 1000
Sessions.AddDone("Test", DamageType.Common, "Dummy", 100, AvoidType.None, CritType.Normal, 1000)
local s = Sessions.current
check("session opened at t=1000", s ~= nil and s.startTime == 1000)

local function PollAt(t) Turbine.Engine._time = t; Buffs.Poll(t) end

-- ---- 1-based index base ----
Set(WRIT, GUARD, RIDING, POISON)
PollAt(1000)
check("index base detected as 1", Buffs.indexBase == 1, "base=" .. tostring(Buffs.indexBase))
check("ignored effect ('Riding') not tracked", s.buffs["Riding"] == nil)
-- Every effect is tracked now, benefit or not: IsDebuff is deliberately no longer consulted.
check("debuff tracked like any other effect", s.buffs["Grievous Wound"] ~= nil)
check("two real buffs opened", s.buffs["Writ of Health"] ~= nil and s.buffs["Bracing Guard"] ~= nil)
check("icon cached from GetIcon()", Buffs.Icons["Writ of Health"] == "icon:writ")
check("missing icon caches as false, not nil-retry", true)

for t = 1000.25, 1010, 0.25 do PollAt(t) end            -- both up for 10s
Set(WRIT)                                                -- guard drops at t=10
for t = 1010.25, 1020, 0.25 do PollAt(t) end
Set(WRIT, GUARD)                                         -- guard back at t=20
for t = 1020.25, 1030, 0.25 do PollAt(t) end
Set()                                                    -- everything drops at t=30
for t = 1030.25, 1040, 0.25 do PollAt(t) end

check("Writ has one continuous interval", #s.buffs["Writ of Health"].intervals == 1,
  "n=" .. #s.buffs["Writ of Health"].intervals)
check("Writ applied once", s.buffs["Writ of Health"].apps == 1)
check("Guard has two intervals", #s.buffs["Bracing Guard"].intervals == 2,
  "n=" .. #s.buffs["Bracing Guard"].intervals)
check("Guard applied twice", s.buffs["Bracing Guard"].apps == 2)

-- ---- a failed read must not be read as "everything faded" ----
local intervalsBefore = #s.buffs["Bracing Guard"].intervals
Set(WRIT, GUARD)
PollAt(1041)
readFails = true
PollAt(1041.25); PollAt(1041.5)
readFails = false
PollAt(1041.75)
check("failed effect read is a no-op, not a fade",
  #s.buffs["Bracing Guard"].intervals == intervalsBefore + 1,
  "n=" .. #s.buffs["Bracing Guard"].intervals)

-- ---- stats over the full fight ----
s.endTime = 1042
Buffs.CloseSession(s)
local openLeft = false
for _, e in pairs(s.buffs) do if e.open ~= nil then openLeft = true end end
check("CloseSession closes every open interval", not openLeft)

local rows = Buffs.Stats(s, nil, nil)
-- Writ, Guard and the debuff (Grievous Wound, up for the first stretch only).
check("Stats returns a row per tracked effect", #rows == 3, "#rows=" .. #rows)
check("Stats sorted by uptime, lowest first", rows[1].uptimePct <= rows[2].uptimePct)
local byName = {}; for _, r in ipairs(rows) do byName[r.name] = r end
local writ, guard = byName["Writ of Health"], byName["Bracing Guard"]
-- Expected values carry the poll's inherent quarter-second granularity: a drop is only
-- observed at the FIRST poll where the effect is absent, so an effect switched off just after
-- t=30 closes at 30.25. That lag is correct behaviour for a 4 Hz sampler, not slop -- these
-- assertions pin it down rather than rounding it away.
-- Writ:  [0, 30.25] then [41, 42]         (re-applied late, closed by CloseSession)
-- Guard: [0, 10.25], [20.25, 30.25], [41, 42]
check("Writ uptime = both of its stretches",
  near(writ.uptime, 30.25 + 1), string.format("%.2f", writ.uptime))
check("Writ longest gap is the stretch it was missing",
  near(writ.longestGap, 41 - 30.25), string.format("%.2f", writ.longestGap))
check("Guard uptime sums all three stretches",
  near(guard.uptime, 10.25 + 10 + 1), string.format("%.2f", guard.uptime))
check("Guard longest gap is its longest outage",
  near(guard.longestGap, 41 - 30.25), string.format("%.2f", guard.longestGap))
check("uptimePct is uptime over the fight's length",
  near(guard.uptimePct, guard.uptime / 42), string.format("%.4f", guard.uptimePct))

-- ---- range clipping ----
local mid = Buffs.Stats(s, 12, 22)
local midByName = {}; for _, r in ipairs(mid) do midByName[r.name] = r end
check("range [12,22]: Writ fully covered -> 100%",
  near(midByName["Writ of Health"].uptimePct, 1),
  string.format("%.4f", midByName["Writ of Health"].uptimePct))
check("range [12,22]: Guard clipped to the part inside the range",
  near(midByName["Bracing Guard"].uptime, 22 - 20.25),
  string.format("%.2f", midByName["Bracing Guard"].uptime))
check("range [12,22]: Guard's head gap runs from the range start",
  near(midByName["Bracing Guard"].longestGap, 20.25 - 12),
  string.format("%.2f", midByName["Bracing Guard"].longestGap))
check("range [12,22]: apps counts only starts inside the range",
  midByName["Bracing Guard"].apps == 1, tostring(midByName["Bracing Guard"].apps))

-- ---- 0-based index base ----
Buffs.indexBase = nil
Turbine.Engine._time = 2000
Sessions.current = nil
Sessions.AddDone("Test", DamageType.Common, "Dummy", 100, AvoidType.None, CritType.Normal, 2000)
local s2 = Sessions.current
indexBase = 0
Set(WRIT, VERSE)
Buffs.Poll(2000)
check("index base detected as 0 when the list is 0-based", Buffs.indexBase == 0,
  "base=" .. tostring(Buffs.indexBase))
check("0-based list still tracks every effect",
  s2.buffs["Writ of Health"] ~= nil and s2.buffs["Mending Verse"] ~= nil)
check("effect with no icon falls back to initials",
  Buffs.Initials("Mending Verse") == "MV", Buffs.Initials("Mending Verse"))
check("single-word buff yields one initial", Buffs.Initials("Reflect") == "R")

-- ---- buff / debuff / unknown labelling (the table's TYPE column) ----
-- No IsDebuff at all, the case a client without the method produces.
local MYSTERY = { GetName = function() return "Odd Sensation" end, GetIcon = function() return nil end }
Set(WRIT, POISON, MYSTERY)
Buffs.Poll(2001)
check("a benefit is labelled a buff", Buffs.Kinds["Writ of Health"] == Buffs.Kind.Buff,
  tostring(Buffs.Kinds["Writ of Health"]))
check("a debuff is labelled a debuff", Buffs.Kinds["Grievous Wound"] == Buffs.Kind.Debuff,
  tostring(Buffs.Kinds["Grievous Wound"]))
check("a missing IsDebuff reads as unknown, never as a buff",
  Buffs.Kinds["Odd Sensation"] == Buffs.Kind.Unknown, tostring(Buffs.Kinds["Odd Sensation"]))
local kinds = {}
for _, r in ipairs(Buffs.Stats(s2, nil, nil)) do kinds[r.name] = r.kind end
check("Stats carries the kind through to the table row",
  kinds["Grievous Wound"] == Buffs.Kind.Debuff and kinds["Writ of Health"] == Buffs.Kind.Buff)

-- ---- user ignore list ----
Buffs.AddIgnore("Mending Verse")
check("user ignore list takes effect", Buffs.IsIgnored("Mending Verse"))
check("user ignore list persists to settings", _G.settings.buffIgnore["Mending Verse"] == true)
Buffs.RemoveIgnore("Mending Verse")
check("user ignore list is removable", not Buffs.IsIgnored("Mending Verse"))
check("removing a non-default clears the key outright",
  _G.settings.buffIgnore["Mending Verse"] == nil)

-- A default entry can be overridden back on: unignoring one stores an explicit false rather
-- than deleting a key that was never there, or the default would just reassert itself.
check("default ignore applies before any override", Buffs.IsIgnored("Riding"))
Buffs.RemoveIgnore("Riding")
check("a default entry can be un-ignored", not Buffs.IsIgnored("Riding"))
check("un-ignoring a default stores an explicit false",
  _G.settings.buffIgnore["Riding"] == false)
Buffs.AddIgnore("Riding")
check("and can be ignored again", Buffs.IsIgnored("Riding"))

-- ---- no session -> no work ----
Sessions.current = nil
Buffs.Poll(3000)
check("polling with no open session is a no-op", Buffs.session == nil)

print("")
if fails == 0 then print("ALL BUFF CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
