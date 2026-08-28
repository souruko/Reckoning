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
	IsInCombat = function() return true end,
	GetEffects = function() return { GetCount = function() return 0 end, Get = function() return nil end } end,
}
LocalPlayer = _G.lp
LocalPlayer.name = LocalPlayer:GetName()

Settings.Load()

import "Basil.Session"
import "Basil.Sessions"
import "Basil.Events"
import "Basil.ChatPost"

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

-- What the reader actually sees. There are two limits now -- MAX_MESSAGE caps this, MAX_RENDERED
-- caps the string with its markup -- because measuring one 240-character budget against the
-- rendered form left no room to tint anything.
local function visible(text)
	return (string.gsub(string.gsub(text, "<rgb=#%x+>", ""), "</rgb>", ""))
end

-- Every line this module produces must satisfy all of these, on every path.
local function checkLine(label, line)
	ok(label .. ": produced a line", line ~= nil and line ~= "")
	if line == nil then return end
	ok(label .. ": is a single line", string.find(line, "\n", 1, true) == nil)
	-- The VISIBLE text is what MAX_MESSAGE caps -- markup is measured separately, so a tinted line
	-- can never deliver more post than a plain one would.
	ok(label .. ": fits MAX_MESSAGE", string.len(visible(line)) <= ChatPost.MAX_MESSAGE)
	ok(label .. ": fits MAX_RENDERED", string.len(line) <= ChatPost.MAX_RENDERED)
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
ok("the coloured line's visible text still fits",
	string.len(visible(colored)) <= ChatPost.MAX_MESSAGE)
ok("the coloured line's markup still fits", string.len(colored) <= ChatPost.MAX_RENDERED)
-- Colour must never change WHAT is said, only how it looks -- the summary carries no trailing
-- detail, so the two forms are the same text.
check("colour costs the summary nothing", visible(colored), full)
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

print("== 12. part selection ==")
-- Every summary piece can be switched off from the POST button's menu. What has to hold for all
-- 256 combinations is that the SEPARATORS follow: with the fight off the line must not open " - ",
-- and with total and rate both off the whole "Damage done:" field has to disappear rather than
-- leave a dangling colon. Building 256 lines is cheap and is the only way to actually cover that.
local PARTS = ChatPost.Parts
_G.settings.postOmit = {}
ok("every part is on by default", ChatPost.AnyPartEnabled())
for i = 1, table.getn(PARTS) do
	ok("part " .. PARTS[i].key .. " reads as enabled", ChatPost.PartEnabled(PARTS[i].key))
end

-- Each part off on its own: the line must survive, stay legal, and lose that piece's text.
local MARKERS = {
	fight = s:DisplayName(), label = "Damage done", hits = " hits", crit = "crit",
	max = "max ", died = "DIED",
}
for i = 1, table.getn(PARTS) do
	local key = PARTS[i].key
	_G.settings.postOmit = { [key] = true }
	local line = ChatPost.BuildLine(s, "summary", "done", nil, nil, nil, PLAIN)
	checkLine("summary/without " .. key, line)
	if line ~= nil and MARKERS[key] ~= nil then
		ok("dropping " .. key .. " removes its text",
			string.find(line, MARKERS[key], 1, true) == nil)
	end
	if line ~= nil then
		ok("dropping " .. key .. " leaves no doubled or dangling separator",
			string.find(line, "|  ", 1, true) == nil
			and string.find(line, "^%s*[-|]") == nil
			and string.find(line, ": *$") == nil)
	end
end

-- All 256 subsets, because separator handling is exactly the kind of thing that is right for the
-- seven combinations you thought of and wrong for the eighth.
--
-- Two subsets are EXPECTED to build nothing, and both disarm the button rather than arming an
-- alias of "/f " (or of "/f Damage done:"): the empty one, and "the view label on its own" -- the
-- label introduces the total and the rate, so with both of those off there is nothing for it to
-- introduce and the whole field is dropped.
_G.settings.postOmit = {}
local built, bad, empty = 0, 0, {}
for mask = 0, 255 do
	local omit, on = {}, {}
	for i = 1, 8 do
		if math.floor(mask / 2 ^ (i - 1)) % 2 == 1 then
			omit[PARTS[i].key] = true
		else
			on[table.getn(on) + 1] = PARTS[i].key
		end
	end
	_G.settings.postOmit = omit
	local line = ChatPost.BuildLine(s, "summary", "done", nil, nil, nil, COLOR)
	if line == nil or line == "" then
		empty[table.getn(empty) + 1] = table.concat(on, "+")
	elseif string.len(strip(line)) > ChatPost.MAX_MESSAGE
		or string.len(line) > ChatPost.MAX_RENDERED
		or string.find(line, "\n", 1, true) ~= nil
		or tags(line, "<rgb=") ~= tags(line, "</rgb>")
		or string.find(strip(line), "^[ |%-]") ~= nil
		or string.find(strip(line), "|  ", 1, true) ~= nil then
		bad = bad + 1
	else
		built = built + 1
	end
end
check("254 part subsets each build a legal, single, in-budget line", built, 254)
check("...and none of them was malformed", bad, 0)
-- Collected in mask order, and "every part off" is mask 255 -- the largest -- so the empty subset
-- is always the LAST entry, never the first.
check("...and exactly the two expected subsets built nothing",
	table.concat(empty, " / "), "label / ")

-- The exclusion-set shape is load-bearing: Settings.Load hands a table-valued default a FRESH
-- EMPTY table without copying sub-keys, so an inclusion map would arrive as "every part off".
_G.settings.postOmit = {}
ok("an empty postOmit means every part is on", ChatPost.AnyPartEnabled())
_G.settings.postOmit = nil
ok("a missing postOmit means every part is on too", ChatPost.AnyPartEnabled())
ChatPost.SetPartEnabled("crit", false)
check("switching a part off stores true, never false", _G.settings.postOmit.crit, true)
ChatPost.SetPartEnabled("crit", true)
check("switching it back on removes the key rather than storing false",
	_G.settings.postOmit.crit, nil)

-- The death report has no parts and must ignore them entirely.
_G.settings.postOmit = {}
for i = 1, table.getn(PARTS) do
	_G.settings.postOmit[PARTS[i].key] = true
end
local wasDead2 = s.died
s.died = true
ok("the death report ignores the part selection",
	ChatPost.BuildLine(s, "death", "done", nil, nil, nil, PLAIN) ~= nil)
s.died = wasDead2
_G.settings.postOmit = {}
print("")

print("== 13. the post palette ==")
-- A post renders on a game chat background nobody here controls, so it does NOT use Theme.Hex --
-- and every colour switch costs 19 characters of the 240 that decide how many death rows fit.
-- Both facts are checked here rather than left to review.
local function hexes(line)
	local seen, list = {}, {}
	for hex in string.gmatch(line, "<rgb=(#%x%x%x%x%x%x)>") do
		if not seen[hex] then seen[hex] = true; list[table.getn(list) + 1] = hex end
	end
	return list
end
local POST_HEX = { [ChatPost.Hex.Title] = true, [ChatPost.Hex.Value] = true,
	[ChatPost.Hex.Number] = true, [ChatPost.Hex.Alert] = true }
local tokens = 0
for _ in pairs(ChatPost.Hex) do tokens = tokens + 1 end
check("the palette is four tokens", tokens, 4)
for _, hex in pairs(ChatPost.Hex) do
	check("post token " .. hex .. " is exactly 6 hex digits", string.len(hex), 7)
end
local sumHexes = hexes(colored)
ok("the summary uses only post tokens", (function()
	for i = 1, table.getn(sumHexes) do
		if not POST_HEX[sumHexes[i]] then return false end
	end
	return true
end)())

-- The number highlight. There is no tag-pair CAP any more -- BuildLine walks a ladder of palettes
-- (rich -> headline -> flat -> plain) and takes the richest that fits, so how many pairs a line
-- spends is a result, not an invariant. What has to hold instead:
--
-- (1) A normal full-part summary lands on RICH: the fight name in Title, the words around the
--     numbers in Value AND the numbers highlighted, all three at once. An earlier draft measured
--     MAX_MESSAGE against the rendered string, which left a 113-character line unable to afford
--     more than three tag pairs -- so it dropped to a rung that bought the highlight by giving up
--     the title and body tint, and the post came back missing exactly those two. If this check ever
--     fails, look at MAX_RENDERED before anything else.
local function has(line, hex)
	return string.find(line, "<rgb=" .. hex .. ">", 1, true) ~= nil
end
ok("the coloured summary tints the fight name", has(colored, ChatPost.Hex.Title))
ok("the coloured summary tints the body text", has(colored, ChatPost.Hex.Value))
ok("the coloured summary highlights its numbers", has(colored, ChatPost.Hex.Number))

-- (2) A highlighted run is a NUMBER, not a number plus the separator that introduced it. Field()
--     glues " | " to the end of the previous segment for exactly this reason; hung on the front it
--     would be swept into the following number's tint ("| 26" bright, "hits" not).
local dirty = 0
for run in string.gmatch(colored, "<rgb=" .. ChatPost.Hex.Number .. ">([^<]*)</rgb>") do
	if string.find(run, "|", 1, true) or string.find(run, " - ", 1, true) then dirty = dirty + 1 end
end
check("no highlighted run swallows a separator", dirty, 0)

-- (3) Every highlighted run is made of digits and the suffixes Format.Number/Percent produce
--     (",", ".", "%", "k", "m", "-") -- never a label word.
local wordy = 0
for run in string.gmatch(colored, "<rgb=" .. ChatPost.Hex.Number .. ">([^<]*)</rgb>") do
	if string.find(run, "[^%d%.,%%km%-]") then wordy = wordy + 1 end
end
check("every highlighted run is a number, not a word", wordy, 0)

s.died = true
local deathColored2 = ChatPost.BuildLine(s, "death", "done", nil, nil, nil, COLOR)
ok("the death report uses only post tokens", (function()
	local h = hexes(deathColored2)
	for i = 1, table.getn(h) do
		if not POST_HEX[h[i]] then return false end
	end
	return true
end)())

-- (4) THE HIGHLIGHT NEVER COSTS A DEATH ROW, and the death report still gets one. The rows are
--     packed against the VISIBLE budget so markup cannot take one away, but a rung whose markup
--     crosses MAX_RENDERED would still have to drop rows to fit -- which is why the ladder carries
--     a "headline" rung that highlights the killing blow's amount and leaves the twelve row amounts
--     alone. Measured by pointing Hex.Number at Hex.Value: every rung then renders identically to
--     flat (Render coalesces same-colour neighbours), which is exactly the reference BuildLine
--     compares against internally. This also pins that the palette is resolved PER CALL rather than
--     built once at load -- with a module-level table this check could not move the colour at all.
ok("the coloured death report highlights the killing blow",
	has(deathColored2, ChatPost.Hex.Number))
local savedNumber = ChatPost.Hex.Number
ChatPost.Hex.Number = ChatPost.Hex.Value
local deathFlat = ChatPost.BuildLine(s, "death", "done", nil, nil, nil, COLOR)
ChatPost.Hex.Number = savedNumber
check("highlighting numbers costs no death row",
	tags(strip(deathColored2), " | "), tags(strip(deathFlat), " | "))
s.died = wasDead2
print("")

print("== 14. Options() ==")
_G.settings.postColor = false
check("Options reads postColor", ChatPost.Options().color, false)
_G.settings.postColor = nil
check("Options defaults colour on", ChatPost.Options().color, true)
print("")

if fails == 0 then print("ALL CHATPOST CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
