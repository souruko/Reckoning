--=================================================================================================
-- Buffs -- self-buff uptime tracking. Backs the analysis window's SELF BUFFS table and its
-- charted lanes (design_handoff_reckoning_redesign/REDESIGN_SPEC.md section 6).
--
-- The data source is the LIVE EFFECT LIST, not the combat parser. Parser event 17 (EventCode.Buff)
-- fires when a benefit is applied but carries no duration and no fade, so uptime derived from it
-- would be a guess -- which is the whole number this table exists to report. Polling
-- _G.lp:GetEffects() instead gives the real "is it on me right now", and an interval opens and
-- closes on the transitions.
--
-- Only effects on the local player are ever read, so this stays inside the plugin's
-- "local player only" scope (docs/DESIGN.md "Scope").
--
-- UNVERIFIED IN-GAME, and the reason everything here is defensive: nothing in this codebase has
-- touched Turbine.Gameplay.EffectList before, and this repo's own history has three separate
-- bugs caused by guessing the shape of a Turbine-supplied object (args.Type vs args.ChatType,
-- LocalPlayer.name, the ChatType.Death channel -- see CLAUDE.md "Build status"). So: the whole
-- enumeration runs inside one pcall, a failed read is a no-op rather than an error, the
-- 0-vs-1-based index base of EffectList:Get is DETECTED at first read rather than assumed, and
-- every optional accessor (GetIcon, IsDebuff) is probed before use. If effects never show up
-- in-game, the read helper below is the first place to look.
--=================================================================================================

Buffs = {}

-- 4 Hz, driven from Events.lua's heartbeat. Enough for a table that reports whole-second
-- uptime, and one list walk per tick is cheap; the heartbeat runs at this rate whether or not
-- any window is open, so tracking never depends on the live meter being enabled.
Buffs.PollInterval = 0.25

-- [name] = asset id, or false for "looked, there wasn't one". Cached at first sighting so the
-- buff table and the graph's lanes share a single lookup.
Buffs.Icons = {}

-- Effects that are never self-buffs worth reporting. Deliberately EXACT-name matching, not
-- substring: a substring rule ("Riding") would silently eat a real buff that happens to contain
-- the word, and a player can never tell why their buff vanished from the table.
--
-- These defaults are a best guess at the client's own strings and are NOT verified against a
-- running game -- a wrong entry here is harmless (it simply never matches), and `/reck buffs`
-- lists what is actually being tracked so a player can add their own with
-- `/reck buffs ignore <name>`. That command, not this table, is the real mechanism.
Buffs.Ignore = {
	["Riding"] = true,
	["Mounted"] = true,
	["War-steed"] = true,
	["Travelling"] = true,
	["Resting"] = true,
	["Well-Rested"] = true,
}

-- Detected at the first successful read: some Turbine list types index from 0 and some from 1,
-- and getting it wrong silently drops an effect (or throws). Rather than assume, probe once.
Buffs.indexBase = nil

---------------------------------------------------------------------------------------------------
-- Ignore list
---------------------------------------------------------------------------------------------------

function Buffs.IsIgnored(name)
	if Buffs.Ignore[name] then
		return true
	end
	local user = _G.settings and _G.settings.buffIgnore
	return user ~= nil and user[name] == true
end

function Buffs.AddIgnore(name)
	_G.settings.buffIgnore = _G.settings.buffIgnore or {}
	_G.settings.buffIgnore[name] = true
	Settings.Save()
end

function Buffs.RemoveIgnore(name)
	if _G.settings.buffIgnore ~= nil then
		_G.settings.buffIgnore[name] = nil
		Settings.Save()
	end
end

---------------------------------------------------------------------------------------------------
-- Reading the live effect list
---------------------------------------------------------------------------------------------------

-- Two-letter initials, used as the icon tile's content when the client gives us no art (and by
-- the design mock for the same reason). "Writ of Health" -> "WH", "Reflect" -> "R".
function Buffs.Initials(name)
	local out = ""
	for word in string.gmatch(name or "", "[%a][%w']*") do
		out = out .. string.upper(string.sub(word, 1, 1))
		if string.len(out) >= 2 then
			break
		end
	end
	return out
end

local function EffectName(effect)
	if effect.GetName == nil then
		return nil
	end
	return effect:GetName()
end

-- Reverted the Turbine.UI.Graphic(id) wrap tried in an earlier round: Gibberish3's own
-- ResolveTimerIcon (UTILS/Functions.lua) -- the function the exact icon id this codebase reads
-- would pass through in Gibberish3 itself -- returns a plain effect-icon id completely unchanged
-- (it only rewrites string paths, for its unrelated external-image-file feature). Real, constantly
-- -exercised code hands SetBackground the bare number; wrapping it was an unproven guess that did
-- not fix anything in-game, so this goes back to the bare id -- see Constants.lua's Icon module,
-- which now matches Gibberish3's actual control setup instead.
local function EffectIcon(effect)
	if effect.GetIcon == nil then
		return nil
	end
	return effect:GetIcon()
end

-- A debuff is not a self-buff. IsDebuff is not confirmed to exist on this client's Effect type,
-- so a missing method just means "keep it" rather than an error.
local function EffectIsDebuff(effect)
	if effect.IsDebuff == nil then
		return false
	end
	return effect:IsDebuff() == true
end

-- Returns { [name] = iconIdOrFalse } for everything currently on the player, or nil if the
-- effect list could not be read at all (in which case the caller does nothing -- a failed read
-- must never be mistaken for "every buff dropped").
function Buffs.Read()
	if _G.lp == nil or _G.lp.GetEffects == nil then
		return nil
	end

	local ok, result = pcall(function()
		local effects = _G.lp:GetEffects()
		if effects == nil or effects.GetCount == nil or effects.Get == nil then
			return nil
		end

		local count = effects:GetCount()
		if count == nil or count <= 0 then
			return {}
		end

		-- Detect the index base once, by probing index 0 -- NOT index 1. Index 1 cannot tell
		-- the two conventions apart: a 0-based list with more than one entry also returns
		-- something at 1 (its second element), so "Get(1) is non-nil" would wrongly conclude
		-- 1-based every time. Index 0 is the discriminating probe: a 1-based list has nothing
		-- there, a 0-based one has its first element. The probe is wrapped, so a client that
		-- throws on an out-of-range index simply reads as 1-based.
		if Buffs.indexBase == nil then
			local okZero, zero = pcall(function() return effects:Get(0) end)
			if okZero and zero ~= nil then
				Buffs.indexBase = 0
			else
				local okOne, first = pcall(function() return effects:Get(1) end)
				if not okOne or first == nil then
					return nil -- could not read either index; try again next poll
				end
				Buffs.indexBase = 1
			end
		end

		local base = Buffs.indexBase
		local present = {}

		for i = base, base + count - 1 do
			local effect = effects:Get(i)
			if effect ~= nil then
				local name = EffectName(effect)
				if name ~= nil and name ~= "" and not Buffs.IsIgnored(name)
					and not EffectIsDebuff(effect)
				then
					if Buffs.Icons[name] == nil then
						Buffs.Icons[name] = EffectIcon(effect) or false
					end
					present[name] = Buffs.Icons[name]
				end
			end
		end

		return present
	end)

	if not ok then
		return nil
	end
	return result
end

---------------------------------------------------------------------------------------------------
-- Polling
---------------------------------------------------------------------------------------------------

-- Called from Events.lua's heartbeat at Buffs.PollInterval, and only while a session is open --
-- there is nothing to attribute uptime to between fights.
--
-- An open interval keeps its `e` pushed forward every tick rather than being left dangling, so
-- a session read mid-fight (the live meter, an analysis window left open on the current fight)
-- already sees correct uptime without anything having to close it first.
function Buffs.Poll(now)
	local session = Sessions.current
	if session == nil then
		Buffs.session = nil
		return
	end

	-- A new session starts with no open intervals, so whatever is up at the first poll opens
	-- there. Without this reset, a buff that was already running when the fight started would
	-- never look "newly present" and would report zero uptime for the whole fight.
	if Buffs.session ~= session then
		Buffs.session = session
	end

	local present = Buffs.Read()
	if present == nil then
		return -- could not read; do NOT interpret that as "everything faded"
	end

	local t = now - session.startTime
	if t < 0 then
		t = 0
	end

	for name in pairs(present) do
		local entry = session.buffs[name]
		if entry == nil then
			entry = { intervals = {}, apps = 0, open = nil }
			session.buffs[name] = entry
		end

		if entry.open == nil then
			entry.apps = entry.apps + 1
			entry.open = { s = t, e = t }
			entry.intervals[table.getn(entry.intervals) + 1] = entry.open
		else
			entry.open.e = t
		end
	end

	for name, entry in pairs(session.buffs) do
		if entry.open ~= nil and present[name] == nil then
			entry.open.e = t
			entry.open = nil
		end
	end
end

-- Closes every still-open interval at the session's own end. Wired to Sessions.OnClosed from
-- Main.lua, which runs before the windows' own OnClosed callbacks, so nothing ever renders a
-- closed session with a dangling interval.
function Buffs.CloseSession(session)
	if session == nil then
		return
	end

	local endSec = session:Duration()
	for _, entry in pairs(session.buffs) do
		if entry.open ~= nil then
			if endSec > entry.open.e then
				entry.open.e = endSec
			end
			entry.open = nil
		end
	end

	if Buffs.session == session then
		Buffs.session = nil
	end
end

---------------------------------------------------------------------------------------------------
-- Derived stats
---------------------------------------------------------------------------------------------------

-- Uptime / applications / longest gap for every tracked buff over [fromSec, toSec], clipping
-- each interval to the range first. Returns a list sorted by uptime, lowest first -- the buffs
-- worth acting on (the ones with gaps) sit at the top, the 100%-uptime ones at the bottom.
--
-- `longestGap` deliberately includes the head and tail gaps: a buff that dropped near the end
-- and never came back is exactly the case this column exists to make visible, and a version
-- that only measured gaps *between* two applications would report it as zero.
function Buffs.Stats(session, fromSec, toSec)
	local rows = {}
	if session == nil then
		return rows
	end

	local t0 = fromSec or 0
	local t1 = toSec or session:Duration()
	local span = t1 - t0
	if span < 0.5 then
		span = 0.5
	end

	for name, entry in pairs(session.buffs) do
		local covered, apps, gap = 0, 0, 0
		local cursor = t0

		local intervals = entry.intervals
		for i = 1, table.getn(intervals) do
			local interval = intervals[i]
			local s = interval.s
			local e = interval.e

			local s2 = (s > t0) and s or t0
			local e2 = (e < t1) and e or t1

			if e2 > s2 then
				covered = covered + (e2 - s2)
				if s2 - cursor > gap then
					gap = s2 - cursor
				end
				if e2 > cursor then
					cursor = e2
				end
			end

			if s >= t0 and s <= t1 then
				apps = apps + 1
			end
		end

		if t1 - cursor > gap then
			gap = t1 - cursor
		end

		rows[table.getn(rows) + 1] = {
			name = name,
			uptime = covered,
			uptimePct = covered / span,
			apps = apps,
			longestGap = gap,
			icon = Buffs.Icons[name] or nil,
			initials = Buffs.Initials(name),
			intervals = intervals,
		}
	end

	table.sort(rows, function(a, b)
		if a.uptimePct == b.uptimePct then
			return a.name < b.name -- stable order, so rows don't shuffle between refreshes
		end
		return a.uptimePct < b.uptimePct
	end)

	return rows
end

function Buffs.Count(session)
	local n = 0
	if session ~= nil then
		for _ in pairs(session.buffs) do
			n = n + 1
		end
	end
	return n
end
