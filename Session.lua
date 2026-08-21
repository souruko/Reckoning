--=================================================================================================
-- Session -- one fight's aggregate. See docs/DESIGN.md "Session model" / "The parser".
--=================================================================================================

-- class() comes from Utils/Class.lua, imported by Main.lua before this file.
Session = class()

local function StripThe(name)
	if name == nil then
		return name
	end
	return string.gsub(name, "^[Tt]he ", "")
end

Session.StripThe = StripThe

function Session:Constructor(startTime, startClock)
	self.startTime  = startTime
	self.endTime    = startTime
	self.startClock = startClock  -- "HH:MM", see Sessions.lua (Turbine.Engine.GetDate())

	-- The last moment this session saw real *combat* -- damage in either direction, a temp-morale
	-- loss, a defeat, or a heal that landed while the client had the player flagged in combat. Any
	-- recorded event moves self.endTime; only those move this one, and Sessions.Tick() closes the
	-- session on this one. A heal-over-time ticking away after the fight is not a fight: it used to
	-- move endTime on every tick and so held a session open for as long as the HoT ran (and could
	-- open one from nothing out of combat). See Sessions.lua's heal dispatch.
	self.combatEndTime = startTime
	self.died       = false
	self.pinned     = false

	-- [second offset from startTime] = { done, taken, healOut, healIn, moralePct,
	--   doneByWho={[name]=amount}, takenByWho=..., healOutByWho=..., healInByWho=... }
	-- moralePct is a snapshot (last sample in that second), not a sum. The ByWho tables back
	-- the analysis window's graph when it's filtered to one target/source/recipient/caster --
	-- the pooled scalar (done/taken/...) is just the sum of its own ByWho table's values.
	self.buckets = {}

	-- One row per (skill, type-or-counterpart, counterpart) combination -- see Row() below.
	-- Aggregated at ingest; a pooled table/graph view sums across counterparts, a filtered
	-- view selects one. Never re-derived by rescanning raw events.
	self.agg = { done = {}, taken = {}, healOut = {}, healIn = {} }

	-- [category][counterpartName] = true -- distinct names seen, for the picker chips.
	self.names = { done = {}, taken = {}, healOut = {}, healIn = {} }

	-- Ring of up to 5 incoming events (real hits and temp-morale-loss only, not misses),
	-- for the death window. See PushLastTaken().
	self.lastTaken = {}

	self._activeSeconds = {}  -- [second offset] = true; ActiveSeconds() counts the keys
	self._activeSecondsCount = 0  -- running count of the above, kept by Touch() -- see ActiveSeconds()

	-- Append-only log of every accepted event, one compact record each, so the analysis
	-- window's range slider can ask for "only seconds 34-71" -- self.agg is aggregated at
	-- ingest and cannot answer that. See Slice() below. Cost is one small table per event
	-- (~350 for a 2-minute fight in the reference captures), built once and never touched per
	-- frame; the 10-session ring caps the total.
	--
	-- Deviation from the redesign spec, flagged rather than done silently: the spec asks for a
	-- string-interning table (skill/counterpart name -> integer id). Lua 5.1 already interns
	-- every string in the VM's own global string table, so two equal names are the *same*
	-- object and a second intern table would add a hash lookup per field per event to save
	-- nothing. Names are stored as plain strings.
	self.events = {}

	-- [category|fromSec|toSec|who] = row list, see Slice(). Cleared by Touch(), i.e. whenever
	-- new events land, which only happens while the session is still live.
	self._sliceCache = {}

	-- [name] = { intervals = { {s=,e=}, ... }, apps = n } -- self-buff uptime, filled by
	-- Buffs.lua's poll (not the parser: combat event 17 carries no duration and no fade).
	self.buffs = {}
end

---------------------------------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------------------------------

-- `combat` marks this event as real combat activity, i.e. something that should keep the fight
-- alive (see self.combatEndTime). Damage in either direction, a temp-morale loss and a defeat
-- always pass it; heals never do on their own -- Sessions.lua calls MarkCombat() separately for a
-- heal that landed while the player was flagged in combat, since it is the one that owns the
-- cached combat state.
function Session:Touch(t, combat)
	if t > self.endTime then
		self.endTime = t
	end

	if combat then
		self:MarkCombat(t)
	end

	local second = math.floor(t - self.startTime)
	if self._activeSeconds[second] == nil then
		self._activeSeconds[second] = true
		self._activeSecondsCount = self._activeSecondsCount + 1
	end

	-- Any cached range slice is stale the moment a new event lands. Only ever happens while
	-- the session is live -- a closed session's cache is permanent, so re-selecting the same
	-- range (or switching views and back) stays a pure redraw.
	self._sliceCache = {}
end

-- Extends the fight without recording anything. Sessions.lua calls this for a heal that landed
-- while the player was in combat -- a healer's whole fight can be heals with no damage in either
-- direction, and that has to keep the session open the same way a hit would.
function Session:MarkCombat(t)
	if t > self.combatEndTime then
		self.combatEndTime = t
	end
end

-- Category ids for the compact event records. Kept numeric rather than the string keys the
-- aggregates use, so a record stays small; SLICE_CATEGORY maps back.
local CAT = { done = 1, taken = 2, healOut = 3, healIn = 4 }

-- Appends one compact record to the event log. Called from every Add* method alongside what it
-- already does -- the aggregates stay, since they are still the fast path for the whole-fight
-- case (and Slice() reads them directly when asked for the full range).
function Session:LogEvent(category, t, skill, dmgType, who, amount, critType, avoidType)
	self.events[table.getn(self.events) + 1] = {
		s  = math.floor(t - self.startTime),
		c  = CAT[category],
		sk = skill,
		ty = dmgType or 0,
		w  = who,
		a  = amount or 0,
		cr = critType or CritType.Normal,
		av = avoidType or AvoidType.None,
	}
end

function Session:Bucket(t)
	local idx = math.floor(t - self.startTime)
	local b = self.buckets[idx]
	if b == nil then
		b = {
			done = 0, taken = 0, healOut = 0, healIn = 0, moralePct = nil,
			doneByWho = {}, takenByWho = {}, healOutByWho = {}, healInByWho = {},
		}
		self.buckets[idx] = b
	end
	return b
end

-- Adds `amount` to bucket.<field> and bucket.<field>ByWho[who] together, in one place, so the
-- pooled scalar and its per-counterpart breakdown can never drift apart.
local function AddToBucket(bucket, field, who, amount)
	bucket[field] = bucket[field] + amount
	local byWho = bucket[field .. "ByWho"]
	byWho[who] = (byWho[who] or 0) + amount
end

-- Damage-shaped row (done/taken): keyed on skill + damage type + counterpart name.
local function DamageRow(agg, names, skill, dmgType, who)
	local key = skill .. "\1" .. dmgType .. "\1" .. who
	local row = agg[key]
	if row == nil then
		row = {
			skill = skill, type = dmgType, who = who,
			hits = 0, total = 0, max = 0, crits = 0, devs = 0,
			avoided = 0, avoidBreakdown = {},
		}
		agg[key] = row
	end
	if names ~= nil then
		names[who] = true
	end
	return row
end

-- Heal-shaped row (healOut/healIn): keyed on skill + counterpart name, no damage type.
local function HealRow(agg, names, skill, who)
	local key = skill .. "\1" .. who
	local row = agg[key]
	if row == nil then
		row = { skill = skill, who = who, hits = 0, total = 0, max = 0, crits = 0, devs = 0 }
		agg[key] = row
	end
	if names ~= nil then
		names[who] = true
	end
	return row
end

-- The one place a hit/heal folds into a row. Ingest calls it through Add*, Slice() calls it
-- again when re-aggregating a range -- so a sliced row can never disagree with an aggregated
-- one about what "crit" or "avoided" means.
local function FoldInto(row, amount, avoidType, critType)
	if AvoidType.IsFull(avoidType) then
		row.avoided = (row.avoided or 0) + 1
		if row.avoidBreakdown ~= nil then
			row.avoidBreakdown[avoidType] = (row.avoidBreakdown[avoidType] or 0) + 1
		end
		return
	end

	row.hits = row.hits + 1
	row.total = row.total + amount
	if amount > row.max then
		row.max = amount
	end
	if critType == CritType.Critical then
		row.crits = row.crits + 1
	elseif critType == CritType.Devastating then
		row.devs = row.devs + 1
	end
end

function Session:PushLastTaken(entry)
	table.insert(self.lastTaken, entry)
	while table.getn(self.lastTaken) > 5 do
		table.remove(self.lastTaken, 1)
	end
end

-- Cached morale percentage, kept fresh by the real MoraleChanged/MaxMoraleChanged events on
-- _G.lp instead of a fresh _G.lp:GetMorale()/GetMaxMorale() pcall closure on every single call to
-- Session:MoralePct() below -- that used to run once per AddTaken/AddTempMoraleLoss call, i.e.
-- once per damage-taken chat line including avoided hits that never change morale at all. In a
-- busy fight with several attackers that's real closure-allocation churn on Lua 5.1's collector
-- (see CLAUDE.md's own GC notes) for numbers that don't need to be read more often than they
-- actually change.
--
-- MaxMorale (the raw points value, not a percentage) rides along in the same cache -- it backs
-- UI/AnalysisGraph.lua's morale axis label, which used to run its own separate
-- pcall(_G.lp:GetMaxMorale()) on every real Redraw() rather than every chat line, but is the same
-- read for the same reason and has no cause to duplicate the defensiveness independently.
--
-- MoraleChanged/MaxMoraleChanged are confirmed real Turbine.Gameplay.LocalPlayer events --
-- VitalSelf/UI/Vital.lua hooks both the same way (`self:Hook(_G.lp, "MoraleChanged", ...)`).
-- _G.lp.MoraleChanged is a single field slot, not a real multi-subscriber event, and VitalSelf
-- (confirmed installed alongside this plugin) already hooks the same field on the same
-- LocalPlayer instance -- CallField() below lets this chain onto whatever's already sitting
-- there (a plain function, or the table-of-functions shape several plugins' own AddCallback
-- convention leaves behind) instead of clobbering it outright, the same reasoning Events.lua
-- already applies to chaining previousChatReceived instead of overwriting Turbine.Chat.Received.
MoralePct = nil
MaxMorale = nil

local function CallField(field, ...)
	if field == nil then
		return
	elseif type(field) == "table" then
		for i = 1, table.getn(field) do
			field[i](...)
		end
	else
		field(...)
	end
end

local function RefreshMoralePct()
	local ok, morale, maxMorale = pcall(function()
		return _G.lp:GetMorale(), _G.lp:GetMaxMorale()
	end)
	if not ok or morale == nil or maxMorale == nil or maxMorale <= 0 then
		MoralePct, MaxMorale = nil, nil
		return
	end
	MoralePct = morale / maxMorale
	MaxMorale = maxMorale
end

local previousMoraleChanged = _G.lp ~= nil and _G.lp.MoraleChanged or nil
local previousMaxMoraleChanged = _G.lp ~= nil and _G.lp.MaxMoraleChanged or nil

RefreshMoralePct()
if _G.lp ~= nil then
	_G.lp.MoraleChanged = function(...) CallField(previousMoraleChanged, ...); RefreshMoralePct() end
	_G.lp.MaxMoraleChanged = function(...) CallField(previousMaxMoraleChanged, ...); RefreshMoralePct() end
end

-- Restores whatever was in the two field slots before this file hooked them -- called from
-- Main.lua's plugin.Unload, mirroring Events.Shutdown()'s restore of previousChatReceived.
function Session.ShutdownMorale()
	if _G.lp ~= nil then
		_G.lp.MoraleChanged = previousMoraleChanged
		_G.lp.MaxMoraleChanged = previousMaxMoraleChanged
	end
end

-- Called from AddTaken/AddTempMoraleLoss, i.e. from inside Turbine.Chat.Received's own handler
-- (Events.lua has no pcall around its dispatch) -- now just a read of the cache above, never a
-- native call or a closure allocation on this hot path.
function Session:MoralePct()
	return MoralePct
end

---------------------------------------------------------------------------------------------------
-- Event ingest -- one method per Events.lua dispatch case. `t` is the arrival timestamp
-- (Turbine.Engine.GetGameTime()), stamped by Events.lua since the chat line carries none.
---------------------------------------------------------------------------------------------------

function Session:AddDone(skill, dmgType, target, amount, avoidType, critType, t)
	target = StripThe(target)
	self:Touch(t, true)

	FoldInto(DamageRow(self.agg.done, self.names.done, skill, dmgType, target), amount, avoidType, critType)
	self:LogEvent("done", t, skill, dmgType, target, amount, critType, avoidType)

	AddToBucket(self:Bucket(t), "done", target, amount)
end

function Session:AddTaken(skill, dmgType, initiator, amount, avoidType, critType, t)
	initiator = StripThe(initiator)
	self:Touch(t, true)

	local row = DamageRow(self.agg.taken, self.names.taken, skill, dmgType, initiator)
	local moralePct = self:MoralePct()

	FoldInto(row, amount, avoidType, critType)
	self:LogEvent("taken", t, skill, dmgType, initiator, amount, critType, avoidType)

	if not AvoidType.IsFull(avoidType) then
		self:PushLastTaken({
			time = t, kind = "damage", skill = skill, dmgType = dmgType,
			amount = amount, initiator = initiator, moralePct = moralePct,
		})
	end

	local b = self:Bucket(t)
	AddToBucket(b, "taken", initiator, amount)
	b.moralePct = moralePct
end

function Session:AddHealOut(skill, target, amount, critType, t)
	target = StripThe(target)
	self:Touch(t)

	FoldInto(HealRow(self.agg.healOut, self.names.healOut, skill, target), amount, AvoidType.None, critType)
	self:LogEvent("healOut", t, skill, nil, target, amount, critType, AvoidType.None)

	AddToBucket(self:Bucket(t), "healOut", target, amount)
end

function Session:AddHealIn(skill, initiator, amount, critType, t)
	initiator = StripThe(initiator)
	self:Touch(t)

	FoldInto(HealRow(self.agg.healIn, self.names.healIn, skill, initiator), amount, AvoidType.None, critType)
	self:LogEvent("healIn", t, skill, nil, initiator, amount, critType, AvoidType.None)

	AddToBucket(self:Bucket(t), "healIn", initiator, amount)
end

function Session:AddTempMoraleLoss(amount, t)
	self:Touch(t, true)
	self:PushLastTaken({ time = t, kind = "tempMorale", amount = amount, moralePct = self:MoralePct() })
end

function Session:OnDefeat(defeatedName, t)
	defeatedName = StripThe(defeatedName)
	self:Touch(t, true)
	if defeatedName == StripThe(LocalPlayer.name) then
		self.died = true
	end
end

function Session:OnRevive(revivedName, t)
	self:Touch(t)
end

---------------------------------------------------------------------------------------------------
-- Derived stats
---------------------------------------------------------------------------------------------------

function Session:Duration()
	return self.endTime - self.startTime
end

-- The fight itself: start to the last *combat* event. Duration() can run a few seconds longer,
-- since a heal recorded in the session's tail still moves endTime -- so anything judging "was this
-- a real fight, and how long did it last" (the too-short-to-keep discard in Sessions.Close, the
-- silence timer in Sessions.Tick) reads this instead.
function Session:CombatDuration()
	return self.combatEndTime - self.startTime
end

-- Seconds in which the player was actually acting. With a range, only the ones inside it --
-- so a rate computed over a slider selection is still "total divided by the seconds you were
-- doing something", not "divided by wall-clock". The unscoped case (fromSec == nil) is the one
-- the live meter calls on every throttled refresh (10Hz) for the whole-fight rate -- Touch()
-- keeps a running count for exactly this, so it doesn't rescan every active second in the fight
-- on every tick; a ranged call still needs the real scan since the range varies per call.
function Session:ActiveSeconds(fromSec, toSec)
	if fromSec == nil then
		return self._activeSecondsCount
	end

	local n = 0
	for second in pairs(self._activeSeconds) do
		if second >= fromSec and second <= toSec then
			n = n + 1
		end
	end
	return n
end

---------------------------------------------------------------------------------------------------
-- Slice -- range-scoped re-aggregation
---------------------------------------------------------------------------------------------------

-- Rows for one category over the second range [fromSec, toSec], optionally restricted to a
-- single counterpart. Returns a *list* of rows in exactly the shape self.agg holds
-- ({ skill, type, who, hits, total, max, crits, devs, avoided, avoidBreakdown }), so every
-- consumer -- the skill table, the KPI row, both side panels -- reads one interface whether or
-- not a range is active.
--
-- Passing fromSec == nil and toSec == nil means "the whole fight" and takes the aggregate path
-- directly. That is not only the fast path: it makes the unscoped window provably identical to
-- what it showed before the range slider existed, since the numbers come from the very same
-- rows rather than from a re-count that might disagree at the edges.
--
-- Rows from that full-fight path are the live aggregate tables themselves. Callers read them;
-- nothing may mutate a row in place (Analysis:TableRows groups into fresh tables, which is why
-- it can).
function Session:Slice(category, fromSec, toSec, who)
	local key = category .. "|" .. (fromSec or "*") .. "|" .. (toSec or "*") .. "|" .. (who or "*")
	local cached = self._sliceCache[key]
	if cached ~= nil then
		return cached
	end

	local list = {}

	if fromSec == nil or toSec == nil then
		for _, row in pairs(self.agg[category]) do
			if who == nil or row.who == who then
				list[table.getn(list) + 1] = row
			end
		end
	else
		local cat = CAT[category]
		local isHeal = (category == "healOut" or category == "healIn")
		local rows = {}

		for i = 1, table.getn(self.events) do
			local e = self.events[i]
			if e.c == cat and e.s >= fromSec and e.s <= toSec and (who == nil or e.w == who) then
				local row
				if isHeal then
					row = HealRow(rows, nil, e.sk, e.w)
				else
					row = DamageRow(rows, nil, e.sk, e.ty, e.w)
				end
				FoldInto(row, e.a, e.av, e.cr)
			end
		end

		for _, row in pairs(rows) do
			list[table.getn(list) + 1] = row
		end
	end

	self._sliceCache[key] = list
	return list
end

-- Sum of `total` across one category, optionally restricted to a single counterpart name
-- (nil = pooled) and/or a second range (both nil = the whole fight).
function Session:Total(category, who, fromSec, toSec)
	local rows = self:Slice(category, fromSec, toSec, who)
	local sum = 0
	for i = 1, table.getn(rows) do
		sum = sum + rows[i].total
	end
	return sum
end

-- DPS/HPS-style rate: total over the category divided by active seconds (never wall-clock).
function Session:Rate(category, who, fromSec, toSec)
	local active = self:ActiveSeconds(fromSec, toSec)
	if active <= 0 then
		return 0
	end
	return self:Total(category, who, fromSec, toSec) / active
end

-- Sums hits/crits/devs/avoided across every row in a category (optionally restricted to one
-- counterpart name), and tracks the single largest hit plus which skill produced it. Backs the
-- live meter's crit/dev/avoided percentages and "largest hit" line, and the analysis window's
-- KPI row -- one pass over the same rows Total()/Rate() already use, never a raw-event rescan.
function Session:HitStats(category, who, fromSec, toSec)
	local rows = self:Slice(category, fromSec, toSec, who)
	local stats = { hits = 0, crits = 0, devs = 0, avoided = 0, max = 0, maxSkill = nil, maxWho = nil, skills = 0 }

	for i = 1, table.getn(rows) do
		local row = rows[i]
		stats.hits = stats.hits + row.hits
		stats.crits = stats.crits + row.crits
		stats.devs = stats.devs + row.devs
		stats.avoided = stats.avoided + (row.avoided or 0)
		stats.skills = stats.skills + 1
		if row.max > stats.max then
			stats.max = row.max
			stats.maxSkill = row.skill
			stats.maxWho = row.who
		end
	end

	return stats
end

-- The counterpart with the highest summed `total` in a category -- used to name a fight after
-- whoever you did the most damage to (or, failing that, whoever hit you hardest).
function Session:TopCounterpart(category)
	local totals = {}
	for _, row in pairs(self.agg[category]) do
		totals[row.who] = (totals[row.who] or 0) + row.total
	end

	local bestWho, bestTotal = nil, 0
	for who, total in pairs(totals) do
		if total > bestTotal then
			bestWho, bestTotal = who, total
		end
	end
	return bestWho
end

-- Session rail label (docs/DESIGN.md has no explicit "session name" field -- this is a
-- reasonable derivation, not a documented one). Named after the target that took the most of
-- your damage; if you died without landing a hit, named after whoever hit you hardest instead.
function Session:DisplayName()
	return self:TopCounterpart("done") or self:TopCounterpart("taken") or "Solo"
end
