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

function Turbine.Chat.Received(sender, args)
	if previousChatReceived ~= nil then
		previousChatReceived(sender, args)
	end

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
	elseif code == EventCode.Heal and mine then
		Sessions.AddHealOut(skill, target, amount, critType, t)
	elseif code == EventCode.Heal and onMe then
		Sessions.AddHealIn(skill, initiator, amount, critType, t)
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

---------------------------------------------------------------------------------------------------
-- Heartbeat -- Sessions.Tick() has to run even when chat is silent, to close a session after
-- CLOSE_AFTER seconds of no own events. A bare Turbine.UI.Window (not parented to anything) can
-- still receive per-frame Update() once shown, so it doubles as a free timer host.
---------------------------------------------------------------------------------------------------

Events.heartbeat = Turbine.UI.Window()
Events.heartbeat:SetSize(1, 1)
Events.heartbeat:SetPosition(0, 0)
Events.heartbeat:SetVisible(true)
Events.heartbeat:SetWantsUpdates(true)

local lastTick = 0

function Events.heartbeat:Update()
	local now = Turbine.Engine.GetGameTime()
	if now - lastTick < 0.5 then
		return
	end
	lastTick = now
	Sessions.Tick(now)
end

function Events.Shutdown()
	Events.heartbeat:SetWantsUpdates(false)
	Events.heartbeat:SetVisible(false)
	Turbine.Chat.Received = previousChatReceived
end
