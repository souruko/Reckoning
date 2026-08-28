--=================================================================================================
-- ChatPost -- turns a Session into the single line of a chat post.
--
-- Pure string building: nothing in this file touches Turbine.UI, so tools/offline can exercise
-- every branch of it against real Session objects. The UI side (the quickslot that fires the post
-- and the channel/preset button next to it) lives in UI/PostButton.lua.
--
-- HOW POSTING ACTUALLY WORKS, because it constrains everything here:
-- there is no chat-send API in Turbine. Turbine.Shell.WriteLine prints only to your own chat
-- window; Turbine.Chat.Received is receive-only. The only mechanism that reaches a channel --
-- used by CombatAnalysis, Arebel/ParseGraph, PrimePlugins/Parse, PrimePlugins/RaidTools and
-- LootLogs, i.e. every plugin in this install that posts -- is a Turbine.UI.Lotro.Quickslot
-- holding a Shortcut(ShortcutType.Alias, "/f <text>") that the USER CLICKS. Arebel tried firing
-- one programmatically (slot:Use()/:Execute()/:DoClick(), Main.lua:7403-7428) and none of those
-- methods exist; it falls back to telling the user to click. So: no auto-post on combat end, and
-- `/basil post` can only ever print locally.
--
-- A POST IS ONE LINE, and that was learned the hard way. The first version built a 6-line post and
-- joined it with "\n", on the strength of CombatAnalysis and Arebel/ParseGraph both doing exactly
-- that (Arebel posts up to 11). Clicking it in-game produced:
--
--     "That text is prohibited because of a content, size, or mixed-alphabet restriction."
--
-- The individual lines were 56-88 characters, far too short to trip a size limit on their own --
-- so the whole 400-1000 character blob was going out as a SINGLE message. The client does not
-- split an alias on "\n"; it just refuses the oversized result. Whatever those two plugins get out
-- of that pattern, it is not what their code reads like it should do, and it was not safe to copy
-- on their say-so. The only precedent here with a *measured* limit is PrimePlugins/Parse, which
-- builds one line and clamps it with `output:sub(1, 256)` (UI/OutputWindow.lua:125).
--
-- So there is exactly one output shape: `BuildLine` returns a string. There is no multi-line form
-- and no separate preview form -- `/basil post` prints the same line, so what you check is what
-- you send. An earlier draft had both and the two drifted apart immediately.
--
-- COLOUR is budgeted rather than assumed free, and it is budgeted against TWO limits.
-- MAX_MESSAGE (240) caps the VISIBLE text -- what a reader actually sees, and what the death
-- report's row packing is measured against. MAX_RENDERED (400) caps the string including markup.
-- The split exists because the one-limit version could not pay for the number highlight at all:
-- measuring 240 against the rendered form left a 113-character summary unable to afford more than
-- three tag pairs, and tinting the numbers wants around thirteen. See MAX_RENDERED's own comment
-- for what is actually known about the client's limit, which is less than anyone would like -- if a
-- post ever comes back refused, that constant is the dial, and setting it equal to MAX_MESSAGE
-- restores the old single-limit behaviour exactly.
--
-- The palette is DELIBERATELY NOT the window palette (Theme.Hex). Two reasons. A post is read on a
-- game chat background nobody here controls, not on this plugin's own window fill, so a token tuned
-- against Theme.Hex.WindowFill has no reason to be legible there; and a chat line built out of six
-- different hues reads as noise. CombatAnalysis -- the one plugin in this install that posts
-- combat numbers and has been read by other players for years -- uses a tight yellow family and
-- almost nothing else (StatOverview/StatOverviewTab.lua:19-23: #FFFF00 titles and separators,
-- #FFFF99 values, #FFF533 sub-titles, one #DD77DD accent for temp morale). ChatPost.Hex below is
-- the same idea at four entries.
--
-- THE NUMBERS ARE HIGHLIGHTED, and that is the one place this file spends colour switches freely
-- rather than hoarding them. A post is read at a glance in a scrolling chat window: the totals, the
-- rate, the hit count, the crit percentage and the amounts are what anyone is looking for, and the
-- labels around them are only there to say which number is which. So every numeric run -- including
-- its own suffix, the "%" of a crit rate and the "k"/"m" of an abbreviated total -- is emitted as
-- its own segment in ChatPost.Hex.Number, against the pale ChatPost.Hex.Value the surrounding words
-- carry. Units that are separate WORDS (DPS, hits, crit, the skill name after a largest hit) stay in
-- Value: they are labels, not numbers.
--
-- Highlighting costs real markup, so the palette is still a LADDER rather than a flag -- a post
-- that cannot afford the highlight must lose the highlight, never the text:
--
--   1. RICH     -- every role tinted, death rows included. A full-part summary lands here, and it
--                  is what everything above describes.
--   2. HEADLINE -- rich except the death rows' own amounts. A death report lands here: twelve rows
--                  want twelve tag pairs, and those are what would cost it entries.
--   3. FLAT     -- numbers fold back into the colour of whatever they sit in; three tag pairs, i.e.
--                  exactly what this post looked like before the highlight existed. Reached only by
--                  a line long enough that even HEADLINE's markup crosses MAX_RENDERED.
--   4. PLAIN    -- no markup at all.
--
-- and BuildLine will not take a richer rung that costs a DEATH ROW: a death report packs its
-- trailing last-hits list greedily against the visible budget, so highlighting the amounts there
-- could buy colour with content. Rows beat colour -- the same trade this file already makes when it
-- falls back to plain rather than truncating mid-tag. `Assemble` returns how many pieces fitted for
-- exactly that comparison.
--
-- ASCII ONLY in post text. Everywhere else in this codebase a questionable glyph only has to
-- survive OUR client's fonts (and this codebase has already been caught twice: the session rail's
-- pin diamonds and the picker's ellipsis both rendered as "?"). A chat post renders on other
-- players' clients, whose fonts and locales we control even less -- so separators here are " - "
-- and " | ", never an em dash or a middle dot, even though the windows themselves use the latter.
--=================================================================================================

ChatPost = {}

-- The slash verb lives in this table rather than inline so a de/fr drop-in is a data change --
-- CombatAnalysis's Locale/de.lua proves the command itself is localised (g/szc/sc, not f/ra/k),
-- not just the label.
ChatPost.Channels = {
	{ key = "say",        label = "Say",        short = "SAY",  command = "say" },
	{ key = "fellowship", label = "Fellowship", short = "FELL", command = "f"   },
	{ key = "raid",       label = "Raid",       short = "RAID", command = "ra"  },
	{ key = "kinship",    label = "Kinship",    short = "KIN",  command = "k"   },
}

-- The two shapes a post can take. They are NOT a mode toggle any more: the analysis window has one
-- button for each (UI/PostButton.lua), and the death button only exists while the selected fight
-- actually ended in a death. This table survives as the label source for `/basil post` and for the
-- two buttons' captions -- `_G.settings.postPreset` is no longer read anywhere.
ChatPost.Presets = {
	{ key = "summary", label = "Fight summary", caption = "POST"  },
	{ key = "death",   label = "Death report",  caption = "DEATH" },
}

-- The pieces of the SUMMARY line, in the order they are emitted, and the labels the channel
-- button's menu offers them under. Any of them can be switched off -- what people want in a
-- fellowship post is not what they want in a kinship one, and the 240-character budget means an
-- unwanted piece is not free, it is a death row or a skill name that did not fit.
--
-- The death report is deliberately NOT part-selectable: it is already the smallest thing it can be
-- (a killing blow plus as many preceding hits as fit) and there is nothing in it to drop.
ChatPost.Parts = {
	{ key = "fight", label = "Fight name & time" },
	{ key = "label", label = "View label"        },
	{ key = "total", label = "Total"             },
	{ key = "rate",  label = "Rate (DPS/HPS)"    },
	{ key = "hits",  label = "Hit count"         },
	{ key = "crit",  label = "Crit %"            },
	{ key = "max",   label = "Largest hit"       },
	{ key = "died",  label = "DIED marker"       },
}

-- Chat-post palette. See the header for why this is not Theme.Hex. Six hex digits exactly -- Tint
-- drops anything else rather than emitting malformed markup, and Events.lua's inbound strip
-- pattern assumes the same width.
-- Number is white on purpose: it only ever sits on Value's pale yellow (there is no rung that
-- highlights a number over untinted text), and white is the strongest reading against that without
-- introducing a fourth hue into a palette the header argues should stay tight.
ChatPost.Hex = {
	Title  = "#FFFF00", -- what identifies the post: the fight and who it was against
	Value  = "#FFFF99", -- the words around the numbers -- labels, units, names, separators
	Number = "#FFFFFF", -- every numeric run, suffix included ("527,738", "52.8k", "55%")
	Alert  = "#FF8888", -- the one exception, a death
}

-- What a channel will accept in one message, measured against the VISIBLE text. Under
-- PrimePlugins/Parse's measured 256, with room for the "/fellowship " prefix the alias carries on
-- top of it.
ChatPost.MAX_MESSAGE = 240

-- The same limit measured against the string WITH its markup, and the one number in this file that
-- is a judgement call rather than something observed.
--
-- What is actually known: a ~400-1000 character multi-LINE blob was refused in-game ("content,
-- size, or mixed-alphabet restriction" -- and note that a "\n" in an alias is at least as likely to
-- have been the *content* half of that message as the size half); PrimePlugins/Parse clamps a plain
-- line at 256; and this plugin's own coloured posts, which have been going out at ~227 rendered
-- characters, are accepted. Nothing anywhere establishes whether the client counts the markup at
-- all. CombatAnalysis is no help either way: its own alias runs to a thousand characters and thirty
-- tag pairs, which either proves markup is free or proves that post has never worked, and there is
-- no way to tell which from the source.
--
-- 400 is chosen to clear a fully-tinted summary (~360 rendered for a 113-character line) while
-- staying well under the shortest length ever seen refused. The visible text is still capped at
-- MAX_MESSAGE either way, so nobody ever receives more than 240 characters of actual post.
--
-- IF A POST IS EVER REFUSED IN-GAME, THIS IS THE DIAL: set it to ChatPost.MAX_MESSAGE and the file
-- goes back to the old single-limit behaviour (three tag pairs, no number highlight) without any
-- other change -- the palette ladder in BuildLine will simply stop being able to afford the richer
-- rungs and fall through to FLAT on its own.
ChatPost.MAX_RENDERED = 400

local SKILL_CHARS = 30
local WHO_CHARS = 22

-- UI/Analysis.lua's VIEW_META is a file-local and unreachable from a root-level module, so the
-- four labels a post needs are repeated here rather than lifting that whole constant out of the
-- window. `hitWord` and `rateWord` match VIEW_META's own values on purpose -- a post that said
-- "DPS" over a healing view would be its own little bug.
--
-- There is no colour ROLE here any more. This table used to carry one so the post's total could be
-- tinted with the view's own series colour, resolved per call (a module-level table built once at
-- load cannot follow a palette-preset change -- Constants.lua's Theme.Series). The post palette no
-- longer varies by view at all, which removes the trap along with the feature.
local VIEW_META = {
	done    = { label = "Damage done",   hitWord = "hits",  hitOne = "hit",  rateWord = "DPS" },
	taken   = { label = "Damage taken",  hitWord = "hits",  hitOne = "hit",  rateWord = "DPS" },
	healOut = { label = "Healing done",  hitWord = "heals", hitOne = "heal", rateWord = "HPS" },
	healIn  = { label = "Healing taken", hitWord = "heals", hitOne = "heal", rateWord = "HPS" },
}

-- "1 hits" reads as a bug to whoever you posted it to, and single-hit skills are common in a
-- short fight. The window itself never needs this -- its counts sit under a plural column header
-- rather than in a sentence. The word is returned on its own, not glued to the number, because the
-- number is a separate segment now (see the header).
local function HitWord(n, meta)
	return (n == 1) and meta.hitOne or meta.hitWord
end

---------------------------------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------------------------------

-- Every value interpolated into a post goes through this first. The newline strip is the one that
-- matters: a newline arriving from parsed game text must never reach the alias, both because it
-- would break the single-line guarantee and because it is exactly the shape of an injection
-- (Arebel does the same scrub at Main.lua:7337). Angle brackets go too, since they would otherwise
-- land inside the <rgb=...> markup below.
local function Clean(text)
	if text == nil then
		return ""
	end
	text = string.gsub(tostring(text), "[\r\n]+", " ")
	text = string.gsub(text, "[<>]", "")
	return text
end

local function Name(text, maxChars)
	return Format.Truncate(Clean(text), maxChars)
end

-- A segment is { text, role, under }. `role` is one of "title" / "value" / "number" / "rowNumber" /
-- "alert"; `under` is the role a segment falls back to at a palette that does not name its own, and
-- exists so the death header's amount folds back into the surrounding Alert run rather than into
-- Value -- folding it to the wrong colour would split one run into three and cost budget instead of
-- saving it.
--
-- "rowNumber" is a death row's amount and exists ONLY so a palette can highlight the numbers a
-- reader looks at first while leaving the trailing last-hits list alone. A death report carries up
-- to twelve rows; tinting every amount is 12 tag pairs, which is what pushes it past MAX_RENDERED
-- and costs rows. Splitting the role lets the ladder keep the killing blow's own amount bright and
-- pay nothing for it.
--
-- Built per call rather than held in a module-level table. This codebase has been caught three
-- times by a table of hexes built at load (Theme.Presets and the palette setting: UI/LiveMeter's
-- TAB_COLORS, UI/Analysis's VIEW_META.color and SERIES_FOR_VIEW were all exactly that trap), and
-- while ChatPost.Hex is a fixed design token set rather than a preset, resolving it per call costs
-- three tiny tables per post and removes the question entirely.
local function Palette(level)
	local H = ChatPost.Hex
	if level == "rich" then
		return { title = H.Title, value = H.Value, number = H.Number,
			rowNumber = H.Number, alert = H.Alert }
	elseif level == "headline" then
		-- Everything rich has except the death rows' own amounts, which fall back to Value. A death
		-- report almost always lands here: the highlight stays on the killing blow, and the twelve
		-- tag pairs the list would have wanted are what would have cost it entries.
		return { title = H.Title, value = H.Value, number = H.Number, alert = H.Alert }
	elseif level == "flat" then
		return { title = H.Title, value = H.Value, alert = H.Alert }
	end
	return {}
end

-- Richest first. The caller takes the first that fits without carrying fewer death rows than FLAT
-- would; FLAT itself is the reference, so it is not in the list.
local COLOUR_LADDER = { "rich", "headline" }

-- The empty palette is also how a candidate's VISIBLE length is measured -- rendering the same
-- segments with nothing resolved is the plain text by construction, so the two lengths can never
-- disagree about what the reader ends up with.
local PLAIN_PALETTE = {}

-- nil means "emit this run with no markup at all", which is what the plain level relies on.
local function HexFor(segment, palette)
	local hex = palette[segment.role]
	if hex == nil and segment.under ~= nil then
		hex = palette[segment.under]
	end
	return hex
end

-- Chat colour is "<rgb=#RRGGBB>text</rgb>" -- exactly six hex digits, which is also what
-- Events.lua's own inbound strip pattern assumes. Theme.Hex carries at least one 8-digit token
-- (PanelFill), so anything not exactly "#RRGGBB" is dropped rather than emitted malformed.
local function Tint(text, hex)
	if hex == nil or string.len(hex) ~= 7 then
		return text
	end
	return "<rgb=" .. hex .. ">" .. text .. "</rgb>"
end

-- Renders a segment list at one palette. Adjacent segments resolving to the SAME colour are
-- coalesced into one tag pair -- segments are written for readability at the call site (and a
-- number folding back into its `under` role deliberately produces same-colour neighbours), and each
-- redundant pair costs 19 characters of a budget the client may well be measuring.
local function Render(segments, palette)
	local out = ""
	local i, n = 1, table.getn(segments)

	while i <= n do
		local hex = HexFor(segments[i], palette)
		local text = segments[i].text
		local j = i + 1
		while j <= n and HexFor(segments[j], palette) == hex do
			text = text .. segments[j].text
			j = j + 1
		end
		out = out .. Tint(text, hex)
		i = j
	end

	return out
end

function ChatPost.ChannelByKey(key)
	for i = 1, table.getn(ChatPost.Channels) do
		if ChatPost.Channels[i].key == key then
			return ChatPost.Channels[i]
		end
	end
	return nil
end

function ChatPost.ChannelLabel(key)
	local channel = ChatPost.ChannelByKey(key)
	return channel and channel.label or ChatPost.Channels[1].label
end

-- Header-width abbreviation. The button states where a click will send, so a misdirected post is
-- visible before it goes out rather than after.
function ChatPost.ChannelShort(key)
	local channel = ChatPost.ChannelByKey(key)
	return channel and channel.short or ChatPost.Channels[1].short
end

function ChatPost.PresetLabel(key)
	for i = 1, table.getn(ChatPost.Presets) do
		if ChatPost.Presets[i].key == key then
			return ChatPost.Presets[i].label
		end
	end
	return ChatPost.Presets[1].label
end

function ChatPost.PresetCaption(key)
	for i = 1, table.getn(ChatPost.Presets) do
		if ChatPost.Presets[i].key == key then
			return ChatPost.Presets[i].caption
		end
	end
	return ChatPost.Presets[1].caption
end

-- Which summary pieces are in the post.
--
-- Stored as an EXCLUSION set (`_G.settings.postOmit[key] = true` drops that piece), not as an
-- inclusion map, and that is not a stylistic choice. Settings.Load's DEFAULTS merge gives a
-- table-valued default a FRESH EMPTY table rather than copying DEFAULTS' sub-keys -- see the note
-- on aliasing in Settings.lua -- so an inclusion map would arrive `{}` on every save that predates
-- this key and read as "every piece off", i.e. a plugin that silently stopped posting anything.
-- An exclusion set reads `{}` as "nothing excluded", which is exactly the intended default. Same
-- [name] = true shape as `buffIgnore`, for the same reason.
function ChatPost.PartEnabled(key)
	local s = _G.settings or {}
	local omit = s.postOmit
	return type(omit) ~= "table" or omit[key] ~= true
end

function ChatPost.SetPartEnabled(key, enabled)
	local s = _G.settings
	if s == nil then
		return
	end
	if type(s.postOmit) ~= "table" then
		s.postOmit = {}
	end
	-- Store `true` or nothing at all; never `false`. Nothing establishes that Turbine.PluginData's
	-- serializer round-trips a `false` sitting inside a nested table (every confirmed nested save in
	-- this codebase -- buffIgnore, the window geometry tables -- holds only truthy values), and a
	-- dropped `false` and an absent key mean the same thing here anyway.
	s.postOmit[key] = (not enabled) or nil
end

-- "Every part is off" is a state the menu can reach in eight clicks, and it disarms the POST
-- button. Callers use this to say so rather than reporting an empty post as no data.
function ChatPost.AnyPartEnabled()
	for i = 1, table.getn(ChatPost.Parts) do
		if ChatPost.PartEnabled(ChatPost.Parts[i].key) then
			return true
		end
	end
	return false
end

-- Reads the persisted post options. Defensive about _G.settings because the offline harnesses
-- build sessions before (or without) a settings load.
function ChatPost.Options()
	local s = _G.settings or {}
	return { color = (s.postColor ~= false) }
end

---------------------------------------------------------------------------------------------------
-- Segment builders -- one per preset
---------------------------------------------------------------------------------------------------

-- Fight summary, with every part switched on:
--   Training-dummy (00:13) - Damage done: 527,738 (52,774 DPS) | 29 hits | 55% crit
--       | max 89,709 Serrated Slash | DIED
--
-- Deliberately no per-skill breakdown. It used to list the top five, which spent the whole message
-- budget on detail nobody reads in a chat window -- the largest hit and what produced it is the
-- one piece of skill-level information worth the characters.
--
-- Every field is optional (ChatPost.Parts), so the separators cannot be baked into the strings the
-- way they used to be: with `fight` off, the line must not open with " - ", and with `total` and
-- `rate` both off the whole "Damage done:" field has to disappear rather than leave a dangling
-- colon. `Field()` below is what makes that hold for any of the 256 combinations -- it emits a
-- separator only when something has already been written.
local function SummarySegments(session, view, who, fromSec, toSec)
	local meta = VIEW_META[view] or VIEW_META.done

	-- Argument-order trap worth stating: Total/Rate/HitStats take (category, who, fromSec, toSec)
	-- but Session:Slice takes (category, fromSec, toSec, who).
	local stats = session:HitStats(view, who, fromSec, toSec)
	if stats.hits == 0 and stats.max == 0 then
		return nil
	end

	local on = ChatPost.PartEnabled
	local segments = {}

	local function Push(text, role, under)
		segments[table.getn(segments) + 1] = { text = text, role = role, under = under }
	end

	-- Opens a field. `sep` is spent only if this is not the first thing on the line, and it is glued
	-- to the END OF THE PREVIOUS SEGMENT rather than being one of its own -- a separator in its own
	-- colour would cost 19 characters per field for a three-character string. Trailing rather than
	-- leading, because a field usually OPENS with its number and closes with a word: hung on the
	-- front, every " | " would be swept into the number's highlight ("| 26" bright, "hits" not), and
	-- hung on the back it lands in a run of words that was going to be emitted anyway.
	local function Field(sep, text, role, under)
		local n = table.getn(segments)
		if n > 0 and sep ~= "" then
			segments[n].text = segments[n].text .. sep
		end
		Push(text, role, under)
	end

	if on("fight") then
		local duration = Format.Clock(session:Duration())
		local rangeText = duration
		if fromSec ~= nil and toSec ~= nil then
			rangeText = Format.Clock(fromSec) .. "-" .. Format.Clock(toSec) .. " of " .. duration
		end

		local head = Name(session:DisplayName(), WHO_CHARS)
		if who ~= nil then
			head = head .. " > " .. Name(who, WHO_CHARS)
		end

		-- The clock stays inside the title run. It is a number, but the title is already the line's
		-- other highlight colour, and pulling "(00:13)" out of it would spend two tag pairs to make
		-- a bright thing slightly differently bright.
		Field("", head .. " (" .. rangeText .. ")", "title")
	end

	-- The stat field is up to three pieces sharing one separator: "Damage done: 527,738 (52,774
	-- DPS)". Collected into its own segment list first, because whether it is emitted at all depends
	-- on whether either NUMBER survived the part selection -- the label alone is not worth a field,
	-- and it is no longer a plain string that can be tested for emptiness.
	local stat = {}
	local function Stat(text, role, under)
		stat[table.getn(stat) + 1] = { text = text, role = role or "value", under = under }
	end

	if on("total") then
		Stat(Format.Number(session:Total(view, who, fromSec, toSec)), "number")
	end
	if on("rate") then
		local rate = Format.Number(session:Rate(view, who, fromSec, toSec))
		-- Parenthesised only when it trails a total; on its own it is the value, not an aside.
		if table.getn(stat) > 0 then
			Stat(" (")
			Stat(rate, "number")
			Stat(" " .. meta.rateWord .. ")")
		else
			Stat(rate, "number")
			Stat(" " .. meta.rateWord)
		end
	end
	if table.getn(stat) > 0 then
		-- The label, when it is on, becomes the field's opening segment; without it the field opens
		-- with the total itself. Either way only the FIRST piece goes through Field, since that is
		-- what decides where the " - " separator lands.
		if on("label") then
			table.insert(stat, 1, { text = meta.label .. ": ", role = "value" })
		end
		Field(" - ", stat[1].text, stat[1].role, stat[1].under)
		for i = 2, table.getn(stat) do
			Push(stat[i].text, stat[i].role, stat[i].under)
		end
	end

	if on("hits") then
		Field(" | ", Format.Number(stats.hits), "number")
		Push(" " .. HitWord(stats.hits, meta), "value")
	end

	if on("crit") then
		local critPct = stats.hits > 0 and ((stats.crits + stats.devs) / stats.hits) or 0
		Field(" | ", Format.Percent(critPct), "number")
		Push(" crit", "value")
	end

	if on("max") and stats.max > 0 then
		Field(" | ", "max ", "value")
		Push(Format.Number(stats.max), "number")
		Push(" " .. Name(stats.maxSkill or "?", SKILL_CHARS), "value")
	end

	if on("died") and session.died then
		Field(" | ", "DIED", "alert")
	end

	-- Every part switched off is a real state the menu can reach. Returning nil rather than an
	-- empty string is what disarms the button instead of arming it with a bare "/f ".
	if table.getn(segments) == 0 then
		return nil
	end

	return segments
end

-- Same scan UI/DeathCause.lua's own FindKillingBlow does: backward past a trailing temp-morale
-- row, since a bubble popping after the fatal hit is not the thing that killed you.
local function FindKillingBlow(session)
	for i = table.getn(session.lastTaken), 1, -1 do
		if session.lastTaken[i].kind == "damage" then
			return session.lastTaken[i]
		end
	end
	return nil
end

-- Death report:
--   Basil - died to Khardamu Blood-sworn's Cleave for 15,482 | 01:33 fight
--       | -8s Lingering Pain 17,919 | +0s Cleave 15,482
--
-- Whole-fight by nature: it ignores the range slider and the counterpart filter that the summary
-- follows. A death report scoped to seconds 12-48, or to one of the three mobs that were hitting
-- you, is not a death report.
--
-- Returns nil when the session did not end in a death, which is what lets the menu grey the entry
-- out rather than offering a post that would come out empty.
local function DeathSegments(session)
	if not session.died then
		return nil
	end

	local kill = FindKillingBlow(session)

	-- The killing-blow clause is ONE run of words plus its amount, where it used to be three runs of
	-- words. Splitting "Died to" / the attacker / the amount across MutedText, Text and DamageFatal
	-- cost two tag pairs -- 38 characters -- to make three neighbouring WORDS look different from
	-- each other, out of the same budget that decides how many of the preceding hits fit. The amount
	-- is a different case: it is the one number in the header, it is what the report is about, and
	-- at the flat palette it folds straight back into the Alert run around it (`under`) and costs
	-- nothing at all.
	local segments = {}
	if kill then
		segments[1] = {
			text = "Died to " .. Name(kill.initiator or "Unknown", WHO_CHARS)
				.. "'s " .. Name(kill.skill, SKILL_CHARS) .. " for ",
			role = "alert",
		}
		segments[2] = { text = Format.Number(kill.amount), role = "number", under = "alert" }
	else
		segments[1] = { text = "Died to something unrecorded", role = "alert" }
	end

	-- Every character the header spends is one the last-hits list cannot use, and under colour the
	-- budget is tight enough that it shows -- hence "(01:33)" rather than "| 01:33 fight", and no
	-- "Basil - " prefix at all (a chat post is obviously from a person).
	segments[table.getn(segments) + 1] = {
		text = " (" .. Format.Clock(session:Duration()) .. ")",
		role = "value",
	}

	return segments, kill
end

-- The optional trailing detail BuildLine packs on for as long as the budget allows. Each piece is
-- its own little SEGMENT LIST ("+8s Lingering Pain " in Value, "17,919" as a number) rather than a
-- string, so the amounts get the same highlight the rest of the post's numbers do -- and BuildLine
-- refuses the highlight outright if it costs a row, which is the only reason that is affordable
-- here at all. Only the death preset has any: the last incoming hits, oldest first. t=0 is the
-- killing blow, NOT session.endTime
-- -- by the time a session is archived and posted, endTime has often been dragged seconds later by
-- heal-over-time ticks (see Sessions' two clocks), and every offset here would read wrong.
--
-- MOST RECENT FIRST, despite the list reading oldest-first on screen. The budget cuts the tail,
-- and the entries nearest the death are the ones a death report is about -- the killing blow's own
-- "+0s" row must never be the one that gets dropped. This only started mattering when
-- settings.deathRows made the ring up to 12 deep: at the old fixed 5 the whole list fit anyway.
local function DeathPieces(session, kill)
	local pieces = {}
	local deathTime = kill and kill.time or session.endTime

	for i = table.getn(session.lastTaken), 1, -1 do
		local entry = session.lastTaken[i]
		-- Avoided swings are in the ring only when settings.deathIncludeAvoids is on, and they
		-- carry no amount -- "+0s Cleave 0" in a death report reads as a broken number, and the
		-- 240-character budget is better spent on hits that landed.
		if entry.kind ~= "avoided" then
			local rel = string.format("%+ds", math.floor(entry.time - deathTime + 0.5))
			local what = (entry.kind == "tempMorale") and "Temp morale" or Name(entry.skill, SKILL_CHARS)
			-- The offset is a number too, but it leads the piece and would put a tag pair between
			-- every row and the " | " that introduces it. The amount is the one worth spending on.
			pieces[table.getn(pieces) + 1] = {
				{ text = rel .. " " .. what .. " ", role = "value" },
				{ text = Format.Number(entry.amount), role = "rowNumber", under = "value" },
			}
		end
	end

	return pieces
end

---------------------------------------------------------------------------------------------------
-- The one output shape
---------------------------------------------------------------------------------------------------

-- `fromSec`/`toSec` nil means the whole fight -- that is Session:Slice's own aggregate fast path,
-- and Analysis:RangeSeconds already returns nil,nil for a full range. Returns nil when there is
-- nothing to say, which is what disarms the button.
function ChatPost.BuildLine(session, preset, view, who, fromSec, toSec, opts)
	if session == nil then
		return nil
	end

	opts = opts or ChatPost.Options()
	local budget = ChatPost.MAX_MESSAGE   -- the visible text
	local ceiling = ChatPost.MAX_RENDERED -- the same text with its markup

	local segments, pieces
	if preset == "death" then
		local kill
		segments, kill = DeathSegments(session)
		if segments == nil then
			return nil
		end
		pieces = DeathPieces(session, kill)
	else
		segments = SummarySegments(session, view, who, fromSec, toSec)
		if segments == nil then
			return nil
		end
		pieces = {}
	end

	-- Builds the whole line at one palette, packing on as many trailing pieces as fit, and reports
	-- how many that was -- the caller compares that count across palettes so a richer one can never
	-- buy its colour with a death row.
	--
	-- Everything is appended as SEGMENTS and the whole line rendered in one pass, rather than tinted
	-- separately and concatenated. Render coalesces adjacent same-colour runs, and a piece's first
	-- segment carries the same colour as whatever preceded it -- appending a separately-tinted
	-- string instead emitted "</rgb><rgb=#FFFF99>" between them, 19 characters to switch a colour to
	-- itself, and with colour on that alone cut the death report from four entries to one. For the
	-- same reason an empty detail must add no segment at all: "<rgb=#FFFF99></rgb>" is 19 characters
	-- of nothing, and it was once enough on its own to push the summary over the cap.
	local function Assemble(level)
		local palette = Palette(level)
		local segs = {}
		for i = 1, table.getn(segments) do
			segs[i] = segments[i]
		end

		-- A piece has to clear BOTH limits: the visible text is what the reader gets and what
		-- MAX_MESSAGE is about, the rendered form is what the client is handed. Measuring only the
		-- rendered one is what used to make the markup compete with the death rows for the same 240
		-- characters -- now the rows are packed against the visible length and colour cannot take
		-- one away.
		local out, fitted = Render(segs, palette), 0
		for i = 1, table.getn(pieces) do
			local piece = pieces[i]
			local mark = table.getn(segs)

			-- The separator rides the piece's first segment rather than being one of its own, the
			-- same trick SummarySegments' Field uses and for the same 19 characters. It is always a
			-- "value" segment, so this one never lands inside a number's highlight.
			segs[mark + 1] = {
				text = " | " .. piece[1].text,
				role = piece[1].role,
				under = piece[1].under,
			}
			for j = 2, table.getn(piece) do
				segs[table.getn(segs) + 1] = piece[j]
			end

			local rendered = Render(segs, palette)
			if string.len(Render(segs, PLAIN_PALETTE)) > budget or string.len(rendered) > ceiling then
				-- Put the list back the way it was; a piece that did not fit must not be left
				-- hanging off the end for the next iteration to measure against.
				for k = table.getn(segs), mark + 1, -1 do
					table.remove(segs, k)
				end
				break
			end
			out, fitted = rendered, fitted + 1
		end

		return out, fitted, string.len(Render(segs, PLAIN_PALETTE))
	end

	-- FLAT is the reference rung -- the three-tag-pair line this post was before the numbers were
	-- highlighted -- so RICH is taken only when it fits AND carries every trailing row flat would
	-- have carried. `visible > budget` can only happen when the HEADER alone is too long (a
	-- pathological name), and it is the same for every palette, so it drops straight to plain and
	-- the truncation below: losing colour beats losing numbers, and a half-written tag would be
	-- worse than either.
	local text
	if opts.color then
		local flat, flatRows, visible = Assemble("flat")
		if visible <= budget then
			for i = 1, table.getn(COLOUR_LADDER) do
				local candidate, rows = Assemble(COLOUR_LADDER[i])
				if string.len(candidate) <= ceiling and rows >= flatRows then
					text = candidate
					break
				end
			end
			if text == nil and string.len(flat) <= ceiling then
				text = flat
			end
		end
	end

	-- Only the plain fallback can need truncating, and only it may BE truncated: a coloured
	-- candidate was already measured against both limits above, and cutting one to a character count
	-- would slice through a tag -- which is worse than either losing the colour or losing the tail.
	if text == nil then
		text = Assemble("plain")
		if string.len(text) > budget then
			text = Format.Truncate(text, budget)
		end
	end

	return text
end

-- The string a Quickslot's Alias shortcut takes. Returns nil for an unknown channel or an empty
-- line, which is the caller's signal not to arm the quickslot at all.
function ChatPost.Alias(channelKey, line)
	if line == nil or line == "" then
		return nil
	end
	local channel = ChatPost.ChannelByKey(channelKey)
	if channel == nil or channel.command == nil then
		return nil
	end
	return "/" .. channel.command .. " " .. line
end
