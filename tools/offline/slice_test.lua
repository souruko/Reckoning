-- Verifies Session:Slice against Session.agg using the repo's real reference combat logs,
-- driven through the real Turbine.Chat.Received entry point (Events.lua), not a hand-rolled
-- reimplementation of the dispatch -- that shortcut is exactly what hid three bugs before.
local env = dofile("stub.lua")
local ROOT = env.ROOT

import "Basil.Utils.Type"
import "Basil.Utils.Class"
import "Basil.Constants"
Trigger = {}
import "Basil.Parse.en"
import "Basil.Settings"

_G.lp = {
	GetName = function() return "Luxtheninth" end,
	GetMorale = function() return 500000 end,
	GetMaxMorale = function() return 900000 end,
	GetTarget = function() return nil end,
	-- Sessions.lua gates heal events on this (a heal only opens/extends a session in combat);
	-- replaying a real fight log means the player was in combat the whole way through.
	IsInCombat = function() return true end,
	GetEffects = function() return { GetCount = function() return 0 end, Get = function() return nil end } end,
}
LocalPlayer = _G.lp
LocalPlayer.name = LocalPlayer:GetName()

Settings.Load()

import "Basil.Session"
import "Basil.Sessions"
import "Basil.Events"

-- Feed a log file through the REAL chat handler, one line per simulated second-ish so events
-- spread across buckets the way a real fight does.
-- The clock is a module-level running counter, never reset per file: game time is monotonic,
-- so an event can never predate the session it lands in. (An earlier version of this harness
-- restarted the clock for the second file and produced an event at second -1, invisible to
-- every range query -- a harness artefact, but a good reminder of what the range code assumes.)
local clock = 1000
local function Feed(path, chatType)
	local n = 0
	for line in io.lines(path) do
		if line ~= "" and not line:match("^###") then
			n = n + 1
			clock = clock + 0.37
			Turbine.Engine._time = clock
			Turbine.Chat.Received(nil, { ChatType = chatType, Message = line })
		end
	end
	return n
end

Turbine.Engine._time = clock
Feed(ROOT .. "/reference/Combat_20260819_1.txt", Turbine.ChatType.PlayerCombat)
Feed(ROOT .. "/reference/Enemy_20260819_1.txt", Turbine.ChatType.EnemyCombat)

local s = Sessions.current
assert(s ~= nil, "no session was opened -- the pipeline is broken, not the slice")

local CATS = { "done", "taken", "healOut", "healIn" }
local fails = 0
local function check(label, got, want)
	local ok = math.abs(got - want) < 1e-9
	if not ok then fails = fails + 1 end
	print(string.format("%-58s %-14s got=%s want=%s", label, ok and "OK" or "**FAIL**",
		tostring(got), tostring(want)))
end

print("events logged: " .. #s.events .. "   duration: " .. string.format("%.1f", s:Duration()) .. "s")
print("")

local dur = math.ceil(s:Duration())

for _, cat in ipairs(CATS) do
	-- 1. Full-range explicit slice must equal the aggregate exactly.
	local aggTotal, aggHits, aggCrits, aggDevs, aggAvoid, aggMax = 0, 0, 0, 0, 0, 0
	for _, row in pairs(s.agg[cat]) do
		aggTotal = aggTotal + row.total
		aggHits = aggHits + row.hits
		aggCrits = aggCrits + row.crits
		aggDevs = aggDevs + row.devs
		aggAvoid = aggAvoid + (row.avoided or 0)
		if row.max > aggMax then aggMax = row.max end
	end

	local rows = s:Slice(cat, 0, dur + 5, nil)
	local sTotal, sHits, sCrits, sDevs, sAvoid, sMax = 0, 0, 0, 0, 0, 0
	for i = 1, #rows do
		sTotal = sTotal + rows[i].total
		sHits = sHits + rows[i].hits
		sCrits = sCrits + rows[i].crits
		sDevs = sDevs + rows[i].devs
		sAvoid = sAvoid + (rows[i].avoided or 0)
		if rows[i].max > sMax then sMax = rows[i].max end
	end

	check(cat .. ": full-range slice total vs agg", sTotal, aggTotal)
	check(cat .. ": full-range slice hits vs agg", sHits, aggHits)
	check(cat .. ": full-range slice crits vs agg", sCrits, aggCrits)
	check(cat .. ": full-range slice devs vs agg", sDevs, aggDevs)
	check(cat .. ": full-range slice avoided vs agg", sAvoid, aggAvoid)
	check(cat .. ": full-range slice max vs agg", sMax, aggMax)
	check(cat .. ": distinct rows slice vs agg", #rows, (function()
		local n = 0; for _ in pairs(s.agg[cat]) do n = n + 1 end; return n end)())

	-- 2. Disjoint sub-ranges covering the fight must sum back to the same total.
	local cut = math.floor(dur / 3)
	local a = s:Total(cat, nil, 0, cut)
	local b = s:Total(cat, nil, cut + 1, cut * 2)
	local c = s:Total(cat, nil, cut * 2 + 1, dur + 5)
	check(cat .. ": three disjoint sub-ranges sum to the whole", a + b + c, aggTotal)

	-- 3. Per-counterpart slices must sum to the pooled slice.
	local perWho = 0
	for who in pairs(s.names[cat]) do
		perWho = perWho + s:Total(cat, who, 0, cut)
	end
	check(cat .. ": per-counterpart range slices sum to pooled", perWho, a)

	-- 4. The nil/nil signature (agg fast path) must equal the explicit full range.
	check(cat .. ": Total(nil range) vs Total(explicit full range)", s:Total(cat), sTotal)

	-- 5. HitStats over a range agrees with the rows that range returns.
	local st = s:HitStats(cat, nil, 0, cut)
	local rr = s:Slice(cat, 0, cut, nil)
	local rh = 0
	for i = 1, #rr do rh = rh + rr[i].hits end
	check(cat .. ": HitStats(range).hits vs its own slice", st.hits, rh)
	print("")
end

-- 6. ActiveSeconds partitions the same way.
local cut = math.floor(dur / 2)
check("ActiveSeconds: two halves sum to the whole",
	s:ActiveSeconds(0, cut) + s:ActiveSeconds(cut + 1, dur + 5), s:ActiveSeconds())

-- 7. Cache: the same query twice returns the identical table (a redraw, not a recount).
local r1 = s:Slice("taken", 3, 20, nil)
local r2 = s:Slice("taken", 3, 20, nil)
check("slice cache returns the same table object", r1 == r2 and 1 or 0, 1)
s:Touch(Turbine.Engine._time)
local r3 = s:Slice("taken", 3, 20, nil)
check("Touch() invalidates the cache", r3 ~= r1 and 1 or 0, 1)

print("")
if fails == 0 then print("ALL SLICE CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
