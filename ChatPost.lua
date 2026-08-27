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
-- COLOUR is emitted as <rgb=#RRGGBB>..</rgb>, and it is budgeted rather than assumed free. Nothing
-- establishes whether the client's size limit counts the markup or only the visible text, so
-- MAX_MESSAGE is measured against the RENDERED string -- the conservative reading. If colour
-- pushes a line over, the line falls back to plain rather than being truncated mid-tag; losing
-- the colour is always better than losing the numbers.
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

ChatPost.Presets = {
	{ key = "summary", label = "Fight summary" },
	{ key = "death",   label = "Death report"  },
}

-- What a channel will accept in one message. Under PrimePlugins/Parse's measured 256, with room
-- for the "/fellowship " prefix the alias carries on top of it.
ChatPost.MAX_MESSAGE = 240

local SKILL_CHARS = 30
local WHO_CHARS = 22

-- UI/Analysis.lua's VIEW_META is a file-local and unreachable from a root-level module, so the
-- four labels a post needs are repeated here rather than lifting that whole constant out of the
-- window. `hitWord` and `rateWord` match VIEW_META's own values on purpose -- a post that said
-- "DPS" over a healing view would be its own little bug.
-- The colour is a ROLE key, not a hex: this is a module-level table built once at load, and a
-- hex baked into it could never follow a palette-preset change (Constants.lua's Theme.Series).
local VIEW_META = {
	done    = { label = "Damage done",   hitWord = "hits",  hitOne = "hit",  rateWord = "DPS", role = "done"    },
	taken   = { label = "Damage taken",  hitWord = "hits",  hitOne = "hit",  rateWord = "DPS", role = "taken"   },
	healOut = { label = "Healing done",  hitWord = "heals", hitOne = "heal", rateWord = "HPS", role = "healOut" },
	healIn  = { label = "Healing taken", hitWord = "heals", hitOne = "heal", rateWord = "HPS", role = "healIn"  },
}

-- "1 hits" reads as a bug to whoever you posted it to, and single-hit skills are common in a
-- short fight. The window itself never needs this -- its counts sit under a plural column header
-- rather than in a sentence.
local function Count(n, meta)
	return Format.Number(n) .. " " .. (n == 1 and meta.hitOne or meta.hitWord)
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

-- Chat colour is "<rgb=#RRGGBB>text</rgb>" -- exactly six hex digits, which is also what
-- Events.lua's own inbound strip pattern assumes. Theme.Hex carries at least one 8-digit token
-- (PanelFill), so anything not exactly "#RRGGBB" is dropped rather than emitted malformed.
local function Tint(text, hex, color)
	if not color or hex == nil or string.len(hex) ~= 7 then
		return text
	end
	return "<rgb=" .. hex .. ">" .. text .. "</rgb>"
end

-- Renders a { text, hex } segment list. Adjacent segments sharing a colour are coalesced into one
-- tag pair -- segments are written for readability at the call site, which naturally produces
-- same-colour neighbours, and each redundant pair costs 19 characters of a budget the client may
-- well be measuring.
local function Render(segments, color)
	local out = ""
	local i, n = 1, table.getn(segments)

	while i <= n do
		local hex = segments[i].hex
		local text = segments[i].text
		local j = i + 1
		while j <= n and segments[j].hex == hex do
			text = text .. segments[j].text
			j = j + 1
		end
		out = out .. Tint(text, hex, color)
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

-- Reads the persisted post options. Defensive about _G.settings because the offline harnesses
-- build sessions before (or without) a settings load.
function ChatPost.Options()
	local s = _G.settings or {}
	return { color = (s.postColor ~= false) }
end

---------------------------------------------------------------------------------------------------
-- Segment builders -- one per preset
---------------------------------------------------------------------------------------------------

-- Fight summary:
--   Training-dummy (00:13) - Damage done: 527,738 (52,774 DPS) | 29 hits | 55% crit
--       | max 89,709 Serrated Slash | DIED
--
-- Deliberately no per-skill breakdown. It used to list the top five, which spent the whole message
-- budget on detail nobody reads in a chat window -- the largest hit and what produced it is the
-- one piece of skill-level information worth the characters.
local function SummarySegments(session, view, who, fromSec, toSec)
	local meta = VIEW_META[view] or VIEW_META.done

	-- Argument-order trap worth stating: Total/Rate/HitStats take (category, who, fromSec, toSec)
	-- but Session:Slice takes (category, fromSec, toSec, who).
	local stats = session:HitStats(view, who, fromSec, toSec)
	if stats.hits == 0 and stats.max == 0 then
		return nil
	end

	local total = session:Total(view, who, fromSec, toSec)
	local rate = session:Rate(view, who, fromSec, toSec)
	local critPct = stats.hits > 0 and ((stats.crits + stats.devs) / stats.hits) or 0

	local duration = Format.Clock(session:Duration())
	local rangeText = duration
	if fromSec ~= nil and toSec ~= nil then
		rangeText = Format.Clock(fromSec) .. "-" .. Format.Clock(toSec) .. " of " .. duration
	end

	local head = Name(session:DisplayName(), WHO_CHARS)
	if who ~= nil then
		head = head .. " > " .. Name(who, WHO_CHARS)
	end

	local segments = {
		{ text = head .. " (" .. rangeText .. ")", hex = Theme.Hex.Accent300 },
		{ text = " - " .. meta.label .. ": ",      hex = Theme.Hex.MutedText },
		{ text = Format.Number(total) .. " (" .. Format.Number(rate) .. " " .. meta.rateWord .. ")",
		  hex = Theme.Series(meta.role) },
		{ text = " | " .. Count(stats.hits, meta) .. " | " .. Format.Percent(critPct) .. " crit",
		  hex = Theme.Hex.DimText },
	}

	if stats.max > 0 then
		segments[table.getn(segments) + 1] = { text = " | max ", hex = Theme.Hex.DimText }
		segments[table.getn(segments) + 1] = {
			text = Format.Number(stats.max) .. " " .. Name(stats.maxSkill or "?", SKILL_CHARS),
			hex = Theme.Hex.AccentLight,
		}
	end

	if session.died then
		segments[table.getn(segments) + 1] = { text = " | DIED", hex = Theme.Hex.DamageFatal }
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
	local segments = { { text = "Died to ", hex = Theme.Hex.MutedText } }

	if kill then
		segments[2] = {
			text = Name(kill.initiator or "Unknown", WHO_CHARS) .. "'s " .. Name(kill.skill, SKILL_CHARS),
			hex = Theme.Hex.Text,
		}
		segments[3] = { text = " for " .. Format.Number(kill.amount), hex = Theme.Hex.DamageFatal }
	else
		segments[2] = { text = "something unrecorded", hex = Theme.Hex.Text }
	end

	-- Every character the header spends is one the last-hits list cannot use, and under colour the
	-- budget is tight enough that it shows -- hence "(01:33)" rather than "| 01:33 fight", and no
	-- "Basil - " prefix at all (a chat post is obviously from a person).
	segments[table.getn(segments) + 1] = {
		text = " (" .. Format.Clock(session:Duration()) .. ")",
		hex = Theme.Hex.DimText,
	}

	return segments, kill
end

-- The optional trailing detail BuildLine packs on for as long as the budget allows. Only the death
-- preset has any: the last incoming hits, oldest first. t=0 is the killing blow, NOT session.endTime
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
			pieces[table.getn(pieces) + 1] = rel .. " " .. what .. " " .. Format.Number(entry.amount)
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
	local budget = ChatPost.MAX_MESSAGE

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

	-- Builds the whole line at one colour setting. The trailing detail is accumulated PLAIN and
	-- tinted ONCE at the end rather than per piece: every piece carries the same colour, so a tag
	-- pair each would cost 19 characters apiece out of the very budget that decides how many of
	-- them fit -- with colour on, that alone cut the death report from four entries to one. An
	-- empty detail must emit no tag at all; "<rgb=#8b8d9b></rgb>" is 19 characters of nothing, and
	-- it was enough on its own to push the summary line over the cap.
	local function Assemble(color)
		-- The detail is appended as a SEGMENT and the whole line rendered in one pass, rather than
		-- tinted separately and concatenated. Render coalesces adjacent same-colour runs, and the
		-- header's own last segment is already DimText -- appending a separately-tinted string
		-- instead emitted "</rgb><rgb=#8b8d9b>" between them, 19 characters to switch a colour to
		-- itself. An empty detail must add no segment at all, for the same reason.
		local function render(detail)
			if detail == "" then
				return Render(segments, color)
			end
			local segs = {}
			for i = 1, table.getn(segments) do
				segs[i] = segments[i]
			end
			segs[table.getn(segs) + 1] = { text = detail, hex = Theme.Hex.DimText }
			return Render(segs, color)
		end

		local out, detail = render(""), ""
		for i = 1, table.getn(pieces) do
			local candidate = detail .. " | " .. pieces[i]
			local rendered = render(candidate)
			if string.len(rendered) > budget then
				break
			end
			out, detail = rendered, candidate
		end
		return out
	end

	-- Colour is budgeted, not assumed free: the RENDERED string is what gets measured, since
	-- nothing establishes whether the client's limit counts markup. If the tinted form does not
	-- fit, fall back to plain rather than truncate mid-tag -- losing colour beats losing numbers,
	-- and a half-written tag would be worse than either.
	local text = Assemble(opts.color)
	if string.len(text) > budget then
		text = Assemble(false)
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
