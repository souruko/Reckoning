-- Exercises ChatPost against real Session objects fed through the real chat entry point
-- (Turbine.Chat.Received), same as slice_test.lua -- it is pure string code, so this is the one
-- part of the posting feature that can be checked completely offline.
--
-- The invariants here are not cosmetic. A post is ONE line within MAX_MESSAGE: a multi-line alias
-- was refused in-game with "That text is prohibited because of a content, size, or mixed-alphabet
-- restriction", because the client does not split an alias on "\n" -- it sends the whole blob as
-- one oversized message. Several checks below exist purely so that cannot come back.
--
-- What this deliberately cannot see: whether a Quickslot click actually fires its alias, and
-- whether the client accepts what we build. Both need a real in-game load.
local env = dofile("stub.lua")
local ROOT = env.ROOT

import "RedBook.Utils.Type"
import "RedBook.Utils.Class"
import "RedBook.Constants"
Trigger = {}
import "RedBook.Parse.en"
import "RedBook.Settings"

_G.lp = {
	GetName = function() return "Luxtheninth" end,
	GetMorale = function() return 500000 end,
	GetMaxMorale = function() return 900000 end,
	GetTarget = function() return nil end,
	IsInCombat = function() return true end,
	GetEffects = function() return { GetCount = function() return 0 end, Get = function() return nil end } end,
}
LocalPlayer = _G.lp
LocalPlayer.name = LocalPlayer:GetName()

Settings.Load()

import "RedBook.Session"
import "RedBook.Sessions"
import "RedBook.Events"
import "RedBook.ChatPost"

local fails = 0
local function check(label, got, want)
	if got == want then
		print(string.format("  ok   %-58s %s", label, tostring(got)))
	else
		fails = fails + 1
		print(string.format("  FAIL %-58s got %s want %s", label, tostring(got), tostring(want)))
	end
end
local function ok(label, cond)
	check(label, cond and true or false, true)
end

local function tags(text, pattern)
	local n = 0
	for _ in string.gmatch(text, pattern) do n = n + 1 end
	return n
end

-- Every line this module produces must satisfy all of these, on every path.
local function checkLine(label, line)
	ok(label .. ": produced a line", line ~= nil and line ~= "")
	if line == nil then return end
	ok(label .. ": is a single line", string.find(line, "\n", 1, true) == nil)
	ok(label .. ": fits MAX_MESSAGE", string.len(line) <= ChatPost.MAX_MESSAGE)
	check(label .. ": colour tags balance", tags(line, "<rgb="), tags(line, "</rgb>"))
	-- Events.lua strips exactly "<rgb=#......>" -- six hex digits. An 8-digit Theme token reaching
	-- a post would produce markup this client's own inbound path could not undo.
	check(label .. ": every tag is a 6-digit tag",
		tags(line, "<rgb=#%x%x%x%x%x%x>"), tags(line, "<rgb="))
end

local clock = 1000
local function Feed(path, chatType)
	for line in io.lines(path) do
		if line ~= "" and not line:match("^###") then
			clock = clock + 0.37
			Turbine.Engine._time = clock
			Turbine.Chat.Received(nil, { ChatType = chatType, Message = line })
		end
	end
end

Turbine.Engine._time = clock
Feed(ROOT .. "/reference/Combat_20260819_1.txt", Turbine.ChatType.PlayerCombat)
Feed(ROOT .. "/reference/Enemy_20260819_1.txt", Turbine.ChatType.EnemyCombat)

local s = Sessions.current
assert(s ~= nil, "no session opened -- the pipeline is broken, not ChatPost")
local dur = math.floor(s:Duration())

local COLOR = { color = true }
local PLAIN = { color = false }

local function strip(text)
	return (string.gsub(string.gsub(text, "<rgb=#%x+>", ""), "</rgb>", ""))
end

print("== 1. the summary line ==")
local full = ChatPost.BuildLine(s, "summary", "done", nil, nil, nil, PLAIN)
checkLine("summary/done", full)
ok("names the fight", string.find(full, s:DisplayName(), 1, true) ~= nil)
ok("carries the view label", string.find(full, "Damage done", 1, true) ~= nil)
ok("carries DPS not HPS", string.find(full, "DPS", 1, true) ~= nil)
ok("carries the hit count", string.find(full, " hits", 1, true) ~= nil)
ok("carries the crit rate", string.find(full, "crit", 1, true) ~= nil)
-- The largest hit and the skill that produced it replaced the old top-five skill list.
local stats = s:HitStats("done", nil, nil, nil)
ok("carries the largest hit", string.find(full, Format.Number(stats.max), 1, true) ~= nil)
ok("names the skill that produced it",
	stats.maxSkill == nil or string.find(full, stats.maxSkill, 1, true) ~= nil)
-- The summary line is a FIXED shape now: no ranked skill list, so its separator count does not
-- grow with how many skills the fight used. (name | hits | crit | max [| DIED])
ok("is a fixed shape, not a variable-length skill list", tags(full, " | ") <= 4)
print("")

print("== 2. healing views say HPS/heals ==")
local heal = ChatPost.BuildLine(s, "summary", "healOut", nil, nil, nil, PLAIN)
if heal ~= nil then
	checkLine("summary/healOut", heal)
	ok("heal line says HPS", string.find(heal, "HPS", 1, true) ~= nil)
	ok("heal line counts heals, not hits", string.find(heal, " heal", 1, true) ~= nil)
	ok("heal line never says hits", string.find(heal, " hit", 1, true) == nil)
	ok("heal line never says DPS", string.find(heal, "DPS", 1, true) == nil)
else
	print("  --   no healing recorded in the fixture; skipped")
end
print("")

print("== 3. range scoping ==")
local cut = math.floor(dur / 2)
local scoped = ChatPost.BuildLine(s, "summary", "done", nil, 0, cut, PLAIN)
checkLine("summary/scoped", scoped)
ok("scoped line shows a range, not just a duration",
	string.find(scoped, Format.Clock(0) .. "-" .. Format.Clock(cut), 1, true) ~= nil)
ok("scoped line says 'of' the full duration", string.find(scoped, " of ", 1, true) ~= nil)
ok("scoped line differs from the whole-fight line", scoped ~= full)
print("")

print("== 4. counterpart filter scoping ==")
local who = s:TopCounterpart("done")
ok("fixture has a counterpart to filter by", who ~= nil)
if who ~= nil then
	local filtered = ChatPost.BuildLine(s, "summary", "done", who, nil, nil, PLAIN)
	checkLine("summary/filtered", filtered)
	ok("filtered line names the counterpart", string.find(filtered, " > ", 1, true) ~= nil)
	local ft = s:Total("done", who, nil, nil)
	ok("filtered line shows the filtered total",
		string.find(filtered, Format.Number(ft), 1, true) ~= nil)
end
print("")

print("== 5. colour ==")
local colored = ChatPost.BuildLine(s, "summary", "done", nil, nil, nil, COLOR)
checkLine("summary/coloured", colored)
ok("colour on emits <rgb=", string.find(colored, "<rgb=", 1, true) ~= nil)
ok("colour off emits no <rgb=", string.find(full, "<rgb=", 1, true) == nil)
check("stripping the markup reproduces the plain line", strip(colored), full)
-- Adjacent same-colour segments are coalesced -- each redundant tag pair costs 19 characters of a
-- budget the client may well be measuring.
local redundant = 0
for closeHex, openHex in string.gmatch(colored, "<rgb=(#%x+)>[^<]*</rgb><rgb=(#%x+)>") do
	if closeHex == openHex then redundant = redundant + 1 end
end
check("no run re-opens the colour it just closed", redundant, 0)
ok("the coloured line still fits", string.len(colored) <= ChatPost.MAX_MESSAGE)
print("")

print("== 6. death preset ==")
local reallyDied = s.died
ok("fixture session recorded a death", reallyDied)
s.died = false
check("no death report for a session that did not die",
	ChatPost.BuildLine(s, "death", "done", nil, nil, nil, PLAIN), nil)
s.died = true
local death = ChatPost.BuildLine(s, "death", "done", nil, nil, nil, PLAIN)
checkLine("death", death)
ok("death line says what killed you", string.find(death, "Died to", 1, true) ~= nil)
-- The death preset takes no scoping at all, unlike the summary -- that is the point.
check("death line ignores view, filter and range",
	ChatPost.BuildLine(s, "death", "healIn", "Somebody", 2, 5, PLAIN), death)
-- t=0 is the killing blow, not session.endTime, so the fatal entry is always "+0s".
ok("death line carries a +0s entry", string.find(death, "+0s", 1, true) ~= nil)
local deathColored = ChatPost.BuildLine(s, "death", "done", nil, nil, nil, COLOR)
checkLine("death/coloured", deathColored)
-- Colour costs budget, so a coloured death report may carry fewer trailing entries than the plain
-- one -- but what it does carry must be a prefix of it, never something different.
local strippedDeath = strip(deathColored)
ok("stripping the death markup yields a prefix of the plain line",
	string.sub(death, 1, string.len(strippedDeath)) == strippedDeath)
-- Colour costs real budget here: the coloured death report carries fewer of the last-hits than
-- the plain one does. That is the accepted trade (turn postColor off for the full list), but it
-- must still carry at least one, or the preset would be reduced to its header.
ok("the coloured death report still carries some detail",
	tags(strippedDeath, " | ") >= 1,
	tags(strippedDeath, " | ") .. " of " .. tags(death, " | "))
s.died = reallyDied
print("")

print("== 7. alias assembly ==")
check("unknown channel builds no alias", ChatPost.Alias("nope", full), nil)
check("nil line builds no alias", ChatPost.Alias("say", nil), nil)
check("empty line builds no alias", ChatPost.Alias("say", ""), nil)
local alias = ChatPost.Alias("fellowship", full)
ok("fellowship alias starts with /f ", string.sub(alias, 1, 3) == "/f ")
ok("the alias is a single line", string.find(alias, "\n", 1, true) == nil)
ok("raid alias uses /ra", string.sub(ChatPost.Alias("raid", full), 1, 4) == "/ra ")
ok("kinship alias uses /k", string.sub(ChatPost.Alias("kinship", full), 1, 3) == "/k ")
ok("say alias uses /say", string.sub(ChatPost.Alias("say", full), 1, 5) == "/say ")
print("")

print("== 8. injection guard ==")
-- A mob name carrying a newline would forge an extra chat line straight out of parsed game text
-- and break the single-line guarantee; angle brackets would land inside the <rgb=...> markup.
local evil = Session(0, "00:00")
evil:AddDone("Nasty\nSkill", 1, "Bad<rgb=#ff0000>Guy", 100, nil, nil, 0)
evil:Touch(1)

local ePlain = ChatPost.BuildLine(evil, "summary", "done", nil, nil, nil, PLAIN)
checkLine("summary/hostile names", ePlain)
ok("newline stripped from skill name", string.find(ePlain, "Nasty\nSkill", 1, true) == nil)
ok("no '<' survives into an uncoloured post", string.find(ePlain, "<", 1, true) == nil)
ok("no '>' survives into an uncoloured post", string.find(ePlain, ">", 1, true) == nil)

local eColor = ChatPost.BuildLine(evil, "summary", "done", nil, nil, nil, COLOR)
checkLine("summary/hostile names, coloured", eColor)
ok("the injected colour is not a live tag",
	string.find(eColor, "<rgb=#ff0000>", 1, true) == nil)

local evil2 = Session(0, "00:00")
evil2:AddTaken("Ba<d", 1, "Guy\nTwo", 50, nil, nil, 0)
evil2:Touch(1)
evil2.died = true
local edeath = ChatPost.BuildLine(evil2, "death", "done", nil, nil, nil, PLAIN)
checkLine("death/hostile names", edeath)
if edeath ~= nil then
	ok("death preset strips '<' from names too", string.find(edeath, "Ba<d", 1, true) == nil)
end
print("")

print("== 9. a pathological name cannot overflow the cap ==")
-- Colour must never be the thing that pushes a line over: it degrades to plain instead.
local huge = Session(0, "00:00")
huge:AddDone(string.rep("VeryLongSkillName", 40), 1, string.rep("Enormous Mob Name", 40), 999999, nil, nil, 0)
huge:Touch(1)
checkLine("summary/pathological, plain",
	ChatPost.BuildLine(huge, "summary", "done", nil, nil, nil, PLAIN))
checkLine("summary/pathological, coloured",
	ChatPost.BuildLine(huge, "summary", "done", nil, nil, nil, COLOR))
print("")

print("== 10. Format.Truncate on a UTF-8 boundary ==")
-- "Utûgi" -- the û is two bytes; cutting between them renders as garbage.
local acc = "Ut\195\187gi Destroyer of Everything"
check("CharCount counts characters, not bytes", Format.CharCount("Ut\195\187gi"), 5)
local t = Format.Truncate(acc, 8)
ok("truncated ends with the ASCII marker", string.sub(t, -2) == "..")
ok("truncated is shorter than the original", string.len(t) < string.len(acc))
check("truncated stays a valid UTF-8 walk", Format.CharCount(t) <= 8, true)
check("short text is returned unchanged", Format.Truncate("abc", 40), "abc")
print("")

print("== 11. empty and nil sessions ==")
check("nil session builds nothing",
	ChatPost.BuildLine(nil, "summary", "done", nil, nil, nil, PLAIN), nil)
check("nil session builds no death report",
	ChatPost.BuildLine(nil, "death", "done", nil, nil, nil, PLAIN), nil)
local empty = Session(0, "00:00")
check("a view with nothing recorded builds nothing",
	ChatPost.BuildLine(empty, "summary", "healIn", nil, nil, nil, PLAIN), nil)
print("")

print("== 12. Options() ==")
_G.settings.postColor = false
check("Options reads postColor", ChatPost.Options().color, false)
_G.settings.postColor = nil
check("Options defaults colour on", ChatPost.Options().color, true)
print("")

if fails == 0 then print("ALL CHATPOST CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
