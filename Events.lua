--=================================================================================================
-- Events -- Turbine.Chat.Received -> Trigger.ParseCombatChat -> Sessions dispatch.
-- See docs/DESIGN.md "The parser" / "Wiring it" and docs/IMPLEMENTATION_PLAN.md Phase 1.
--=================================================================================================

Events = {}

-- Gibberish3 feeds the parser this exact transform (verified against the live install, not
-- written down in the design bundle): strip <rgb=#......>...</rgb> colour tags, then trim.
-- Coloured combat lines the client actually sends would otherwise fail to match.
local function CleanLine(message)
	message = string.gsub(message, "<rgb=#......>(.*)</rgb>", "%1")
	message = string.gsub(message, "^%s*(.-)%s*$", "%1")
	return message
end

-- Chain to whatever was already registered (e.g. another plugin loaded first) rather than
-- clobbering it -- Turbine.Chat.Received is a single global function slot, not a
-- multi-subscriber event, so an uncooperative overwrite here would silently break that
-- plugin's chat handling.
local previousChatReceived = Turbine.Chat.Received

-- RedBook's own dispatch, split out so it can be pcall-wrapped below without also swallowing
-- errors from previousChatReceived (another plugin's handler) -- those are not this plugin's to
-- catch or hide.
local function Dispatch(args)
	-- The field is `args.ChatType`, not `args.Type` -- confirmed against Gibberish3
	-- (TRIGGER/CHAT/Functions.lua), CombatAnalysis (Parser/Parser.lua), and LootLogs
	-- (ChatParsing.lua), all three of which also guard a nil Message before using it (some
	-- chat events carry no text at all).
	if args.Message == nil then
		return
	end

	-- Defeat/incapacitate/succumb lines ("The X incapacitated you.", "You succumb to your
	-- wounds.") arrive on their own Turbine.ChatType.Death channel, not PlayerCombat/EnemyCombat
	-- -- confirmed against a real captured log (a defeat never reached this handler at all,
	-- despite regular damage/heal lines working) and against CombatAnalysis (a working combat
	-- meter), whose own live parser gate is this exact same three-way check.
	if args.ChatType ~= Turbine.ChatType.PlayerCombat
		and args.ChatType ~= Turbine.ChatType.EnemyCombat
		and args.ChatType ~= Turbine.ChatType.Death
	then
		return
	end

	local code, initiator, target, skill, amount, avoidType, critType, dmgType =
		Trigger.ParseCombatChat(CleanLine(args.Message))

	if code == nil then
		return
	end

	local t = Turbine.Engine.GetGameTime()

	local mine = (initiator == LocalPlayer.name)
	local onMe = (target == LocalPlayer.name)
	if not (mine or onMe) and code ~= EventCode.TempMoraleLoss then
		return
	end

	if code == EventCode.Damage and mine then
		Sessions.AddDone(skill, dmgType, target, amount, avoidType, critType, t)
	elseif code == EventCode.Damage and onMe then
		Sessions.AddTaken(skill, dmgType, initiator, amount, avoidType, critType, t)
	elseif code == EventCode.Heal then
		-- Not an elseif between mine/onMe like Damage above: a self-heal (e.g. "Bracing Guard")
		-- has no "with <skill>" clause, so the parser swaps names and initiator == target ==
		-- LocalPlayer.name, making both true at once. DESIGN.md is explicit that this should
		-- count on both sides -- self-sustain toward Healing Done *and* incoming heal toward
		-- Healing Taken (and the damage-taken graph's "healing in" series) -- not just whichever
		-- branch happened to be checked first.
		if mine then
			Sessions.AddHealOut(skill, target, amount, critType, t)
		end
		if onMe then
			Sessions.AddHealIn(skill, initiator, amount, critType, t)
		end
	elseif code == EventCode.TempMoraleLoss then
		Sessions.AddTempMoraleLoss(amount, t)
	elseif code == EventCode.Defeat then
		-- `initiator` holds the defeated name here (event 9 returns only one name). `mine`
		-- above already means "the defeated entity is you" for this code, so an enemy kill
		-- (mine == false, onMe == false since there is no target) was already filtered out.
		Sessions.OnDefeat(initiator, t)
	elseif code == EventCode.Revive then
		Sessions.OnRevive(initiator, t)
	end
end

function Turbine.Chat.Received(sender, args)
	if previousChatReceived ~= nil then
		previousChatReceived(sender, args)
	end

	-- pcall-wrapped: this fires on every single combat chat line, including bursts of them, so a
	-- thrown error here is not a one-off -- it's every subsequent line for as long as whatever
	-- caused it keeps being true. This codebase already has three documented bugs from a wrong
	-- assumption about a Turbine-supplied object's shape (see CLAUDE.md "Build status"), and the
	-- one path found so far that reads the live player object with no guard at all
	-- (`_G.lp:GetTarget()` in `UI/LiveMeter.lua`, and `_G.lp:GetMorale()`/`GetMaxMorale()` in
	-- `Session.lua`, both now pcall-wrapped at their own call sites) is exactly the shape of bug
	-- that would land here too if it ever recurred somewhere not yet found. This is the backstop,
	-- not the fix -- an error swallowed here means a dropped combat line, not a crash, which is
	-- the same trade this codebase already makes everywhere else defensive (Buffs.lua: "a failed
	-- read is a no-op, never mistaken for real data").
	pcall(Dispatch, args)
end

---------------------------------------------------------------------------------------------------
-- Heartbeat -- Sessions.Tick() has to run even when chat is silent, to close a session after
-- CLOSE_AFTER seconds of no own events. A bare Turbine.UI.Window (not parented to anything) can
-- still receive per-frame Update() once shown, so it doubles as a free timer host.
--
-- It also drives Buffs.Poll(). The redesign spec suggested polling from the live meter's own
-- Update() throttle, but that meter can be switched off in the options panel -- and buff uptime
-- has to keep being recorded either way, since the analysis window reads it afterwards. The
-- heartbeat is the one timer that always runs, so the poll lives here instead, and the tick
-- rate drops from 0.5s to Buffs.PollInterval (0.25s / 4 Hz) to match what that poll needs.
-- Sessions.Tick is unaffected by ticking twice as often: it only compares against a 5s silence
-- window.
---------------------------------------------------------------------------------------------------

Events.heartbeat = Turbine.UI.Window()
Events.heartbeat:SetSize(1, 1)
Events.heartbeat:SetPosition(0, 0)
Events.heartbeat:SetVisible(true)
Events.heartbeat:SetWantsUpdates(true)

local lastTick = 0

function Events.heartbeat:Update()
	local now = Turbine.Engine.GetGameTime()
	if now - lastTick < Buffs.PollInterval then
		return
	end
	lastTick = now

	-- Poll before Tick: Tick can close the session, and a poll afterwards would then have
	-- nothing to attribute the last quarter-second of uptime to.
	Buffs.Poll(now)
	Sessions.Tick(now)

	-- Backstop for the post button's overlay quickslot: it is a separate top-level Window and so
	-- does not follow the analysis window's visibility, which is toggled from at least four places
	-- (/redbook show|hide|move, the live meter's Details button, the close button, Escape). This only
	-- re-positions -- it never calls Activate(), which would take chat focus four times a second.
	if analysis ~= nil and analysis.SyncPostOverlay ~= nil then
		analysis:SyncPostOverlay(false)
	end
end

function Events.Shutdown()
	Events.heartbeat:SetWantsUpdates(false)
	Events.heartbeat:SetVisible(false)
	Turbine.Chat.Received = previousChatReceived
end
