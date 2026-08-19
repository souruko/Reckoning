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
end

---------------------------------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------------------------------

function Session:Touch(t)
	if t > self.endTime then
		self.endTime = t
	end
	self._activeSeconds[math.floor(t - self.startTime)] = true
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
	names[who] = true
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
	names[who] = true
	return row
end

function Session:PushLastTaken(entry)
	table.insert(self.lastTaken, entry)
	while table.getn(self.lastTaken) > 5 do
		table.remove(self.lastTaken, 1)
	end
end

function Session:MoralePct()
	local morale, maxMorale = _G.lp:GetMorale(), _G.lp:GetMaxMorale()
	if morale == nil or maxMorale == nil or maxMorale <= 0 then
		return nil
	end
	return morale / maxMorale
end

---------------------------------------------------------------------------------------------------
-- Event ingest -- one method per Events.lua dispatch case. `t` is the arrival timestamp
-- (Turbine.Engine.GetGameTime()), stamped by Events.lua since the chat line carries none.
---------------------------------------------------------------------------------------------------

function Session:AddDone(skill, dmgType, target, amount, avoidType, critType, t)
	target = StripThe(target)
	self:Touch(t)

	local row = DamageRow(self.agg.done, self.names.done, skill, dmgType, target)

	if AvoidType.IsFull(avoidType) then
		row.avoided = row.avoided + 1
		row.avoidBreakdown[avoidType] = (row.avoidBreakdown[avoidType] or 0) + 1
	else
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

	AddToBucket(self:Bucket(t), "done", target, amount)
end

function Session:AddTaken(skill, dmgType, initiator, amount, avoidType, critType, t)
	initiator = StripThe(initiator)
	self:Touch(t)

	local row = DamageRow(self.agg.taken, self.names.taken, skill, dmgType, initiator)
	local moralePct = self:MoralePct()

	if AvoidType.IsFull(avoidType) then
		row.avoided = row.avoided + 1
		row.avoidBreakdown[avoidType] = (row.avoidBreakdown[avoidType] or 0) + 1
	else
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

	local row = HealRow(self.agg.healOut, self.names.healOut, skill, target)
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

	AddToBucket(self:Bucket(t), "healOut", target, amount)
end

function Session:AddHealIn(skill, initiator, amount, critType, t)
	initiator = StripThe(initiator)
	self:Touch(t)

	local row = HealRow(self.agg.healIn, self.names.healIn, skill, initiator)
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

	AddToBucket(self:Bucket(t), "healIn", initiator, amount)
end

function Session:AddTempMoraleLoss(amount, t)
	self:Touch(t)
	self:PushLastTaken({ time = t, kind = "tempMorale", amount = amount, moralePct = self:MoralePct() })
end

function Session:OnDefeat(defeatedName, t)
	defeatedName = StripThe(defeatedName)
	self:Touch(t)
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

function Session:ActiveSeconds()
	local n = 0
	for _ in pairs(self._activeSeconds) do
		n = n + 1
	end
	return n
end

-- Sum of `total` across every row in one of the four aggregates ("done", "taken", "healOut",
-- "healIn"), optionally restricted to a single counterpart name (nil = pooled).
function Session:Total(category, who)
	local sum = 0
	for _, row in pairs(self.agg[category]) do
		if who == nil or row.who == who then
			sum = sum + row.total
		end
	end
	return sum
end

-- DPS/HPS-style rate: total over the category divided by active seconds (never wall-clock).
function Session:Rate(category, who)
	local active = self:ActiveSeconds()
	if active <= 0 then
		return 0
	end
	return self:Total(category, who) / active
end

-- Sums hits/crits/devs/avoided across every row in a category (optionally restricted to one
-- counterpart name), and tracks the single largest hit plus which skill produced it. Backs the
-- live meter's crit/dev/avoided percentages and "largest hit" line, and the analysis window's
-- KPI row -- one pass over the same rows Total()/Rate() already use, never a raw-event rescan.
function Session:HitStats(category, who)
	local stats = { hits = 0, crits = 0, devs = 0, avoided = 0, max = 0, maxSkill = nil, maxWho = nil }
	for _, row in pairs(self.agg[category]) do
		if who == nil or row.who == who then
			stats.hits = stats.hits + row.hits
			stats.crits = stats.crits + row.crits
			stats.devs = stats.devs + row.devs
			stats.avoided = stats.avoided + (row.avoided or 0)
			if row.max > stats.max then
				stats.max = row.max
				stats.maxSkill = row.skill
				stats.maxWho = row.who
			end
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
