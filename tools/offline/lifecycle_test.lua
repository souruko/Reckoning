-- Session lifecycle: a session must start and end with *combat*, not with any parsed event.
-- Heal-over-time ticks are the case this exists for -- they run on long after a fight and can be
-- cast entirely outside one, and they used to both open a session from nothing and hold it open
-- for as long as they kept ticking (every tick moved endTime, which is what the silence timer
-- closed on).
--
-- Driven through the REAL entry points -- Turbine.Chat.Received (Events.lua) and Sessions.Tick --
-- never a hand-rolled dispatch: that shortcut is exactly what hid three bugs before.
local env = dofile("stub.lua")

import "Reckoning.Utils.Type"
import "Reckoning.Utils.Class"
import "Reckoning.Constants"
Trigger = {}
import "Reckoning.Parse.en"
import "Reckoning.Settings"

-- The one stub value this whole file is about: Sessions.lua reads it (pcall'd) on every heartbeat
-- tick, and heals are gated on the result.
local combatFlag = false

_G.lp = {
	GetName = function() return "Luxtheninth" end,
	GetMorale = function() return 500000 end,
	GetMaxMorale = function() return 900000 end,
	GetTarget = function() return nil end,
	GetEffects = function() return { GetCount = function() return 0 end, Get = function() return nil end } end,
	IsInCombat = function() return combatFlag end,
}
LocalPlayer = _G.lp
LocalPlayer.name = LocalPlayer:GetName()

Settings.Load()

import "Reckoning.Session"
import "Reckoning.Sessions"
import "Reckoning.Events"

local fails = 0
local function check(label, ok, detail)
	if not ok then fails = fails + 1 end
	print(string.format("%-64s %s%s", label, ok and "OK" or "**FAIL**", detail and ("  " .. detail) or ""))
end

---------------------------------------------------------------------------------------------------
-- Harness
---------------------------------------------------------------------------------------------------

-- Real captured lines (reference/Combat_20260819_1.txt, reference/Enemy_20260819_1.txt), so the
-- parser is exercised on text the client actually sends rather than on something written to match.
local HEAL_IN = "Silthelion applied a heal with Prelude to Hope to Luxtheninth restoring 4,008 points to Morale."
local HIT_ON_ME = "Khardâmu Blood-sworn scored a hit with a minor melee attack on Luxtheninth for 12,657 Common damage to Morale."
local REVIVED = "You have been revived."

local function Say(t, line, chatType)
	Turbine.Engine._time = t
	Turbine.Chat.Received(nil, { ChatType = chatType or Turbine.ChatType.PlayerCombat, Message = line })
end

-- The heartbeat (Events.lua) calls this at 4Hz; it is also what refreshes the cached combat flag,
-- so flipping combatFlag only takes effect on the next tick -- the same one-tick lag the real
-- plugin has.
local function Tick(t)
	Turbine.Engine._time = t
	Sessions.Tick(t)
end

local function Reset(t)
	Sessions.current = nil
	Sessions.list = {}
	Sessions.selected = nil
	Tick(t)
end

---------------------------------------------------------------------------------------------------
-- 1. Out of combat, heals alone never open a session
---------------------------------------------------------------------------------------------------

combatFlag = false
Reset(1000)

for i = 0, 20 do
	Say(1000 + i, HEAL_IN)
	Tick(1000 + i)
end

check("20s of out-of-combat heal ticks open no session", Sessions.current == nil)
check("...and archive nothing", table.getn(Sessions.list) == 0)

---------------------------------------------------------------------------------------------------
-- 2. In combat, heals alone do open and sustain one (a healer's fight can be all heals)
---------------------------------------------------------------------------------------------------

combatFlag = true
Reset(1100)

Say(1101, HEAL_IN)
check("a heal in combat opens a session", Sessions.current ~= nil)

for t = 1103, 1121, 2 do
	Say(t, HEAL_IN)
	Tick(t)
	Tick(t + 1)
end

check("heals in combat keep it open past the 5s silence timer", Sessions.current ~= nil)
check("...and count as combat activity",
	Sessions.current ~= nil and Sessions.current.combatEndTime == 1121,
	Sessions.current and tostring(Sessions.current.combatEndTime) or "no session")

---------------------------------------------------------------------------------------------------
-- 3. The bug: heal ticks after the fight must not postpone the close
---------------------------------------------------------------------------------------------------

combatFlag = true
Reset(1200)

for t = 1201, 1205 do
	Say(t, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
	Tick(t)
end

-- Fight over; the client drops the combat flag, but a HoT keeps ticking every half second.
combatFlag = false
local closedAt = nil
local t = 1205.5
while t <= 1230 and closedAt == nil do
	Say(t, HEAL_IN)
	Tick(t)
	if Sessions.current == nil then
		closedAt = t
	end
	t = t + 0.5
end

check("a session under a running HoT still closes", closedAt ~= nil, tostring(closedAt))
-- The silence window is settings.idleTimeout now (options window, Sessions page), not a
-- hardcoded 5 -- read it rather than restating it, so changing the default cannot quietly make
-- this assertion about the wrong number.
local IDLE = _G.settings.idleTimeout
check("...one idle timeout after the last COMBAT event, not the last heal",
	closedAt ~= nil and closedAt >= 1205 + IDLE and closedAt < 1206 + IDLE, tostring(closedAt))

local archived = Sessions.list[1]
check("...and is archived", archived ~= nil)
-- The fight ends at the last hit, give or take one heartbeat: the combat flag is only re-read on
-- Tick, so a heal arriving in the gap between the client dropping the flag and the next tick still
-- counts as combat. That lag is real (0.25s in game) and harmless -- what matters is that it is
-- bounded by one tick instead of running for as long as the HoT does.
check("...ending at the last hit (within one heartbeat), not the last tick",
	archived ~= nil and archived.combatEndTime >= 1205 and archived.combatEndTime <= 1205.5,
	archived and tostring(archived.combatEndTime))
check("...so the close is exactly one idle timeout past the fight's end",
	archived ~= nil and closedAt == archived.combatEndTime + IDLE,
	archived and tostring(closedAt - archived.combatEndTime))
check("...with the trailing heals still recorded in it",
	archived ~= nil and archived:Total("healIn") > 0,
	archived and tostring(archived:Total("healIn")))

---------------------------------------------------------------------------------------------------
-- 4. Damage opens a session whatever the combat flag says
---------------------------------------------------------------------------------------------------
-- The flag is refreshed on a 4Hz tick and the client sets it around the first hit either way, so
-- damage must never depend on it: it IS combat.

combatFlag = false
Reset(1300)

Say(1301, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
check("damage opens a session even with the combat flag still false", Sessions.current ~= nil)

---------------------------------------------------------------------------------------------------
-- 5. A short fight with a long heal tail is still a short fight
---------------------------------------------------------------------------------------------------

combatFlag = true
Reset(1400)

Say(1401, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
Say(1402, HIT_ON_ME, Turbine.ChatType.EnemyCombat)

combatFlag = false
Tick(1402)
for i = 1, 8 do
	Say(1402 + i * 0.5, HEAL_IN)
	Tick(1402 + i * 0.5)
end
Tick(1403 + _G.settings.idleTimeout)

check("a 1s fight padded out by heal ticks is discarded, not archived",
	table.getn(Sessions.list) == 0, tostring(table.getn(Sessions.list)))
check("...and the session is closed either way", Sessions.current == nil)

---------------------------------------------------------------------------------------------------
-- 6. A revive is the end of a fight, never the start of one
---------------------------------------------------------------------------------------------------

combatFlag = false
Reset(1500)

Say(1501, REVIVED, Turbine.ChatType.Death)
check("a revive with no session open does not open one", Sessions.current == nil)

-- ...but it is still recorded into a session that is already open.
combatFlag = true
Reset(1600)
Say(1601, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
local before = Sessions.current
Say(1602, REVIVED, Turbine.ChatType.Death)
check("a revive during a fight still lands in that fight", Sessions.current == before)

---------------------------------------------------------------------------------------------------
-- 7. A missing/throwing IsInCombat degrades safely
---------------------------------------------------------------------------------------------------
-- Sessions.lua pcall-wraps the read. If it ever fails, the safe direction is "not in combat":
-- heals stop opening sessions on their own, damage still opens them as normal.

local realIsInCombat = _G.lp.IsInCombat
_G.lp.IsInCombat = function() error("no such method") end

Reset(1700)
check("a throwing IsInCombat reads as out of combat", Sessions.InCombat() == false)

Say(1701, HEAL_IN)
check("...so a heal opens nothing", Sessions.current == nil)

Say(1702, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
check("...and damage still opens a session", Sessions.current ~= nil)

_G.lp.IsInCombat = realIsInCombat

---------------------------------------------------------------------------------------------------
-- 7. settings.mergeFights decides whether a lull splits one fight into two
---------------------------------------------------------------------------------------------------
-- On (the default): a gap shorter than the idle timeout is still one fight. Off: the session
-- closes as soon as the client's own combat flag drops.

combatFlag = true
Reset(1800)
Say(1801, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
Say(1805, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
Tick(1805)
combatFlag = false
Tick(1807)
Tick(1809)
check("mergeFights on: a lull shorter than the timeout keeps one fight open",
	Sessions.current ~= nil)

_G.settings.mergeFights = false
combatFlag = true
Reset(1900)
Say(1901, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
Say(1905, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
Tick(1905)
check("mergeFights off: the fight stays open while the combat flag is up", Sessions.current ~= nil)

-- The flag drops; the session must close well before the idle timeout would have closed it.
combatFlag = false
Tick(1906)
check("...and closes once the flag drops, without waiting out the idle timeout",
	Sessions.current == nil and table.getn(Sessions.list) == 1,
	tostring(table.getn(Sessions.list)))

-- The floor: damage opens a session on the first hit, but the combat flag is only re-read on the
-- tick and the client takes a moment to raise it. Without UNMERGED_FLOOR the very next tick would
-- close a fight that had only just started.
combatFlag = false
Reset(2000)
Say(2001, HIT_ON_ME, Turbine.ChatType.EnemyCombat)
Tick(2001.25)
check("...but a fight that just started is not closed by the flag still being false",
	Sessions.current ~= nil)
_G.settings.mergeFights = true
combatFlag = true

---------------------------------------------------------------------------------------------------

print("")
if fails == 0 then
	print("ALL LIFECYCLE CHECKS PASSED")
else
	print(fails .. " LIFECYCLE CHECK(S) FAILED")
	os.exit(1)
end
