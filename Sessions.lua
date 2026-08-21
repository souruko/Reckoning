--=================================================================================================
-- Sessions -- the manager: opens/closes Session instances on silence, keeps the ring of 20
-- (pinned exempt), tracks which session is selected for the analysis window.
-- See docs/DESIGN.md "Session model". Not a class -- a single static namespace.
--=================================================================================================

Sessions = {}

Sessions.list = {}      -- newest first; pinned entries are exempt from the MAX_SESSIONS cap
Sessions.current = nil  -- the open Session, or nil between fights
Sessions.selected = nil -- the Session shown in the analysis window

local MAX_SESSIONS = 20
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

---------------------------------------------------------------------------------------------------
-- Combat state
---------------------------------------------------------------------------------------------------
-- A session has to start and end with combat. Damage in either direction (and a temp-morale loss,
-- and a defeat) says so by itself; a heal does not. Heal-over-time ticks run on well past the end
-- of a fight and can be cast entirely out of one, and they used to both open a session from
-- nothing and hold it open for as long as they kept ticking -- every tick moved endTime, which is
-- what the silence timer closed on.
--
-- So heals are gated on the client's own combat flag instead. _G.lp:IsInCombat() is confirmed-real
-- LocalPlayer API, used identically by four independently-written installed plugins (FervourFocus,
-- Gibberish3's TRIGGER/COMBAT/Functions.lua, Darf/MiniRaid, Thurallor) -- not a guess at a Turbine
-- shape, which is the category of bug this codebase has already been bitten by three times.
--
-- The flag is refreshed on the heartbeat (Tick, 4Hz) rather than by hooking the InCombatChanged
-- event: both FervourFocus and Gibberish3 assign that field slot outright, so hooking it here
-- would be a clobbering contest with them, and a combat flag up to 250ms stale cannot change
-- whether a heal belongs to a fight. Falls back to "not in combat" if the read ever throws, which
-- degrades to "heals never open a session on their own" -- the safe direction.
local inCombat = false

local function RefreshInCombat()
	local ok, value = pcall(function() return _G.lp:IsInCombat() end)
	inCombat = (ok and value == true)
end

RefreshInCombat()  -- the plugin can be loaded (or reloaded) mid-fight

-- True while the client has the player flagged in combat, as of the last heartbeat tick.
function Sessions.InCombat()
	return inCombat
end

-- Heal dispatch: opens a session only in combat, and only then does the heal count as combat
-- activity. Out of combat a heal is still recorded into whatever session is already open (the last
-- ticks of a HoT do belong to the fight that was just fought) -- it simply cannot start one or
-- keep one alive. Returns false when there is nothing to record into.
local function EnsureOpenForHeal(t)
	if inCombat then
		EnsureOpen(t)
		Sessions.current:MarkCombat(t)
		return true
	end
	return Sessions.current ~= nil
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

	-- CombatDuration, not Duration: a two-second scuffle followed by four seconds of heal ticks is
	-- a two-second fight, and the discard has to judge it as one.
	if s:CombatDuration() < MIN_DURATION then
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

-- Called on a heartbeat tick (see Events.lua) -- not from an event handler. Refreshes the cached
-- combat flag and closes the open session once it has gone quiet for CLOSE_AFTER seconds.
--
-- The silence is measured against combatEndTime, not endTime: a session ends when the *fight*
-- does. Heals landing after that still get recorded into it for as long as it stays open, but they
-- no longer postpone the close, which is what let a rotation of heal-over-times keep one session
-- running indefinitely.
function Sessions.Tick(now)
	RefreshInCombat()

	if Sessions.current ~= nil and (now - Sessions.current.combatEndTime) >= CLOSE_AFTER then
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
	if not EnsureOpenForHeal(t) then
		return
	end
	Sessions.current:AddHealOut(skill, target, amount, critType, t)
end

function Sessions.AddHealIn(skill, initiator, amount, critType, t)
	if not EnsureOpenForHeal(t) then
		return
	end
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

-- Deliberately does not open a session: a revive is the end of a fight, never the start of one,
-- and reviving at a rez circle with nothing else happening used to open an empty one.
function Sessions.OnRevive(revivedName, t)
	if Sessions.current == nil then
		return
	end
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
