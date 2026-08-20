--=================================================================================================
-- Sessions -- the manager: opens/closes Session instances on silence, keeps the ring of 10
-- (pinned exempt), tracks which session is selected for the analysis window.
-- See docs/DESIGN.md "Session model". Not a class -- a single static namespace.
--=================================================================================================

Sessions = {}

Sessions.list = {}      -- newest first; pinned entries are exempt from the MAX_SESSIONS cap
Sessions.current = nil  -- the open Session, or nil between fights
Sessions.selected = nil -- the Session shown in the analysis window

local MAX_SESSIONS = 10
local CLOSE_AFTER  = 5  -- seconds of silence closes the open session
local MIN_DURATION = 3  -- seconds; a session shorter than this is discarded, not archived

local onClosedCallbacks = {}
local onSelfDefeatCallbacks = {}

-- Fires once a session closes and is kept (i.e. survived the MIN_DURATION discard).
function Sessions.OnClosed(callback)
	table.insert(onClosedCallbacks, callback)
end

-- Fires the moment event 9 (defeat) names the local player -- independent of session close,
-- so the death window can pop up immediately rather than waiting on the 5s silence timer.
function Sessions.OnSelfDefeat(callback)
	table.insert(onSelfDefeatCallbacks, callback)
end

local function StartClock()
	local d = Turbine.Engine.GetDate()
	return string.format("%02d:%02d", d.Hour, d.Minute)
end

local function EnsureOpen(t)
	if Sessions.current == nil then
		Sessions.current = Session(t, StartClock())
	end
end

-- Trims Sessions.list down to MAX_SESSIONS non-pinned entries, dropping the oldest non-pinned
-- session first. Pinned sessions never count against the cap and are never dropped here.
local function TrimRing()
	local nonPinned = 0
	for i = 1, table.getn(Sessions.list) do
		if not Sessions.list[i].pinned then
			nonPinned = nonPinned + 1
		end
	end

	while nonPinned > MAX_SESSIONS do
		for i = table.getn(Sessions.list), 1, -1 do
			if not Sessions.list[i].pinned then
				table.remove(Sessions.list, i)
				nonPinned = nonPinned - 1
				break
			end
		end
	end
end

function Sessions.Close()
	local s = Sessions.current
	Sessions.current = nil
	if s == nil then
		return nil
	end

	if s:Duration() < MIN_DURATION then
		return nil
	end

	table.insert(Sessions.list, 1, s)
	TrimRing()

	if Sessions.selected == nil then
		Sessions.selected = s
	end

	for i = 1, table.getn(onClosedCallbacks) do
		onClosedCallbacks[i](s)
	end

	-- REVERTED (see CLAUDE.md "Build status"): this used to call collectgarbage() here, reasoned
	-- from CombatAnalysis's own "free state, then collect" pattern. Wrong call -- LOTRO plugins
	-- share ONE Lua VM across every loaded addon, not one per plugin, so that call forced a full
	-- stop-the-world sweep of every other addon's heap too, not just Reckoning's own few MB. In
	-- practice, reported in-game as a much longer death loading screen plus 5-10s of
	-- unresponsiveness right after -- entirely consistent with a client-wide GC pause landing at
	-- the worst possible moment (~5s after the fatal hit, right as the player releases spirit and
	-- the zone transition starts). Left as a comment, not deleted outright, specifically so this
	-- exact call is not reintroduced the same way a second time.

	return s
end

-- Called on a heartbeat tick (see Events.lua) -- not from an event handler. Closes the open
-- session once it has gone quiet for CLOSE_AFTER seconds.
function Sessions.Tick(now)
	if Sessions.current ~= nil and (now - Sessions.current.endTime) >= CLOSE_AFTER then
		Sessions.Close()
	end
end

---------------------------------------------------------------------------------------------------
-- Dispatch entry points -- called from Events.lua, one per consumed event code.
---------------------------------------------------------------------------------------------------

function Sessions.AddDone(skill, dmgType, target, amount, avoidType, critType, t)
	EnsureOpen(t)
	Sessions.current:AddDone(skill, dmgType, target, amount, avoidType, critType, t)
end

function Sessions.AddTaken(skill, dmgType, initiator, amount, avoidType, critType, t)
	EnsureOpen(t)
	Sessions.current:AddTaken(skill, dmgType, initiator, amount, avoidType, critType, t)
end

function Sessions.AddHealOut(skill, target, amount, critType, t)
	EnsureOpen(t)
	Sessions.current:AddHealOut(skill, target, amount, critType, t)
end

function Sessions.AddHealIn(skill, initiator, amount, critType, t)
	EnsureOpen(t)
	Sessions.current:AddHealIn(skill, initiator, amount, critType, t)
end

function Sessions.AddTempMoraleLoss(amount, t)
	EnsureOpen(t)
	Sessions.current:AddTempMoraleLoss(amount, t)
end

function Sessions.OnDefeat(defeatedName, t)
	EnsureOpen(t)
	Sessions.current:OnDefeat(defeatedName, t)

	if Session.StripThe(defeatedName) == Session.StripThe(LocalPlayer.name) then
		for i = 1, table.getn(onSelfDefeatCallbacks) do
			onSelfDefeatCallbacks[i](Sessions.current)
		end
	end
end

function Sessions.OnRevive(revivedName, t)
	EnsureOpen(t)
	Sessions.current:OnRevive(revivedName, t)
end

---------------------------------------------------------------------------------------------------
-- Pins
---------------------------------------------------------------------------------------------------

-- Sessions are not persisted (docs/DESIGN.md), so pins are keyed by table identity for the
-- current play session only -- there is nothing to look a pin up by after a reload.
function Sessions.TogglePin(session)
	session.pinned = not session.pinned
	TrimRing()
end
