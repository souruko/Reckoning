--=================================================================================================
-- DeathCause -- window 2, 380x200. Tells you what killed you, without being asked.
-- See docs/DESIGN.md "2. Death cause".
--=================================================================================================

DeathCause = class(Frame)

local ROW_COUNT = 5
local ROW_HEIGHT = 24
local CAUSE_BLOCK_HEIGHT = 50
local RULE_HEIGHT = 2

-- "38px 1fr 62px 46px" grid from docs/DESIGN.md, resolved against the 360px content width
-- (380 window - 10px padding each side). 1fr = 360 - 38 - 62 - 46 = 214.
local COL_TIME = { x = 10, width = 38 }
local COL_SKILL = { x = 48, width = 214 }
local COL_AMOUNT = { x = 262, width = 62 }
local COL_MORALE = { x = 324, width = 46 }

local function DamageTypeName(dmgType)
	return DamageType.Names[dmgType] or "Unknown"
end

-- The initiator of the final damage-taken event is "last hit by" (docs/DESIGN.md: event 9
-- carries no killer). Scans backward past a trailing temp-morale-loss row, if any, so a popped
-- bubble logged after the fatal hit doesn't get mistaken for the killing blow itself.
local function FindKillingBlow(session)
	for i = table.getn(session.lastTaken), 1, -1 do
		local entry = session.lastTaken[i]
		if entry.kind == "damage" then
			return i, entry
		end
	end
	return nil, nil
end

function DeathCause:Constructor()
	Frame.Constructor(self, {
		key = "deathCause", title = nil, closable = true,
		width = 380, height = 200, headerHeight = 28,
		fillHex = Theme.Hex.DeathFill, borderHex = Theme.Hex.DeathBorder,
		headerRuleHex = Theme.Hex.DeathRule,
	})

	self:BuildHeaderContent()
	self:BuildCauseBlock()
	self:BuildRows()
	self:BuildCountdown()

	self.hideAt = nil
	self.countdownTotal = 1

	local window = self
	Sessions.OnSelfDefeat(function(s) window:Show(s) end)

	self:SetWantsUpdates(true)
	self:SetVisible(false)
end

function DeathCause:BuildHeaderContent()
	local title = Turbine.UI.Label()
	title:SetParent(self.header)
	title:SetFont(Font.TrajanPro13)
	title:SetText("You were defeated")
	title:SetForeColor(Theme.Color(Theme.Hex.Text))
	title:SetPosition(10, 0)
	title:SetSize(230, self.headerHeight)
	title:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	title:SetMouseVisible(false)

	self.countdownLabel = Turbine.UI.Label()
	self.countdownLabel:SetParent(self.header)
	self.countdownLabel:SetFont(Font.LucidaConsole12)
	self.countdownLabel:SetForeColor(Theme.Color(Theme.Hex.MutedText))
	self.countdownLabel:SetPosition(250, 0)
	self.countdownLabel:SetSize(100, self.headerHeight)
	self.countdownLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
	self.countdownLabel:SetMouseVisible(false)
end

function DeathCause:BuildCauseBlock()
	local x = 10

	local caption = Turbine.UI.Label()
	caption:SetParent(self.client)
	caption:SetFont(Font.Verdana10)
	caption:SetText("LAST HIT BY")
	caption:SetForeColor(Theme.Color(Theme.Hex.DimText))
	caption:SetPosition(x, 0)
	caption:SetSize(90, 20)
	caption:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	caption:SetMouseVisible(false)

	self.bossLabel = Turbine.UI.Label()
	self.bossLabel:SetParent(self.client)
	self.bossLabel:SetFont(Font.TrajanPro16)
	self.bossLabel:SetForeColor(Theme.Color(Theme.Hex.Text))
	self.bossLabel:SetPosition(x + 90, 0)
	self.bossLabel:SetSize(360 - 90, 20)
	self.bossLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	self.bossLabel:SetMouseVisible(false)

	self.moraleLostLabel = Turbine.UI.Label()
	self.moraleLostLabel:SetParent(self.client)
	self.moraleLostLabel:SetFont(Font.Verdana12)
	self.moraleLostLabel:SetForeColor(Theme.Color(Theme.Hex.MutedText))
	self.moraleLostLabel:SetPosition(x, 20)
	self.moraleLostLabel:SetSize(360, 16)
	self.moraleLostLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	self.moraleLostLabel:SetMouseVisible(false)

	-- Legend for the killing-blow row's tint -- a colour swatch plus label, not a "killing
	-- blow" suffix on the row itself (docs/DESIGN.md: that would truncate the skill/type text).
	local swatch = Turbine.UI.Control()
	swatch:SetParent(self.client)
	swatch:SetPosition(x, 39)
	swatch:SetSize(6, 6)
	swatch:SetBackColor(Theme.Color(Theme.Hex.DamageFatal))
	swatch:SetMouseVisible(false)

	local legend = Turbine.UI.Label()
	legend:SetParent(self.client)
	legend:SetFont(Font.Verdana10)
	legend:SetText("Killing blow")
	legend:SetForeColor(Theme.Color(Theme.Hex.DamageFatal))
	legend:SetPosition(x + 12, 36)
	legend:SetSize(150, 14)
	legend:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	legend:SetMouseVisible(false)
end

function DeathCause:BuildRows()
	local columns = {
		{ x = COL_TIME.x, width = COL_TIME.width, font = Font.LucidaConsole12, colorHex = Theme.Hex.DimText },
		{ x = COL_SKILL.x, width = COL_SKILL.width, font = Font.Verdana12, colorHex = Theme.Hex.Text },
		{ x = COL_AMOUNT.x, width = COL_AMOUNT.width, font = Font.LucidaConsole12, colorHex = Theme.Hex.DamageTaken, align = Turbine.UI.ContentAlignment.MiddleRight },
		{ x = COL_MORALE.x, width = COL_MORALE.width, font = Font.LucidaConsole12, colorHex = Theme.Hex.Morale, align = Turbine.UI.ContentAlignment.MiddleRight },
	}

	self.rows = {}
	for i = 1, ROW_COUNT do
		local row = Row(380, ROW_HEIGHT, columns)
		row:SetParent(self.client)
		row:SetPosition(0, CAUSE_BLOCK_HEIGHT + (i - 1) * ROW_HEIGHT)
		row:SetVisible(false)
		self.rows[i] = row
	end
end

function DeathCause:BuildCountdown()
	self.countdownBar = Bar(380, RULE_HEIGHT, Theme.Hex.Accent500, Theme.Hex.DeathRule)
	self.countdownBar:SetParent(self.client)

	local _, clientHeight = self.client:GetSize()
	self.countdownBar:SetPosition(0, clientHeight - RULE_HEIGHT)
end

---------------------------------------------------------------------------------------------------
-- Trigger / refresh
---------------------------------------------------------------------------------------------------

function DeathCause:Show(session)
	if not _G.settings.deathCauseEnabled then
		return
	end

	self.session = session
	self.deathTime = session.endTime

	local killIndex, killEntry = FindKillingBlow(session)
	self.killIndex = killIndex
	self.bossLabel:SetText(killEntry and killEntry.initiator or "Unknown")

	local n = table.getn(session.lastTaken)
	local lostTotal = 0
	for i = 1, n do
		lostTotal = lostTotal + session.lastTaken[i].amount
	end
	self.moraleLostLabel:SetText(
		"Lost " .. Format.Number(lostTotal) .. " morale over the last " .. n .. (n == 1 and " hit" or " hits"))

	for i = 1, ROW_COUNT do
		local row = self.rows[i]
		local entry = session.lastTaken[i]

		if entry == nil then
			row:SetVisible(false)
		else
			row:SetVisible(true)

			local relTime = string.format("%+.1fs", entry.time - self.deathTime)

			if entry.kind == "tempMorale" then
				-- Its own row so a popped temp-morale bubble never reads as mitigated damage.
				row:SetValues({ relTime, "Temporary morale", "-" .. Format.Number(entry.amount), Format.Percent(entry.moralePct) })
				row:SetColumnColor(2, Theme.Hex.MutedText)
				row:SetColumnColor(3, Theme.Hex.MutedText)
			else
				row:SetValues({
					relTime,
					entry.skill .. " · " .. DamageTypeName(entry.dmgType),
					Format.Number(entry.amount),
					Format.Percent(entry.moralePct),
				})
				row:SetColumnColor(2, Theme.Hex.Text)

				if i == killIndex then
					row:SetColumnColor(3, Theme.Hex.DamageFatal)
				elseif entry.moralePct ~= nil and entry.moralePct < 0.15 then
					row:SetColumnColor(3, Theme.Hex.DamageSevere)
				else
					row:SetColumnColor(3, Theme.Hex.DamageTaken)
				end
			end
		end
	end

	self.countdownTotal = _G.settings.deathAutoHide or 15
	self.hideAt = Turbine.Engine.GetGameTime() + self.countdownTotal
	self.countdownBar:SetPercent(1)

	self:SetVisible(true)
	self:Activate()
end

function DeathCause:Update()
	if self.hideAt == nil then
		return
	end

	local now = Turbine.Engine.GetGameTime()
	local remaining = self.hideAt - now

	if remaining <= 0 then
		self.hideAt = nil
		self:SetVisible(false)
		return
	end

	self.countdownBar:SetPercent(remaining / self.countdownTotal)
	self.countdownLabel:SetText(string.format("%ds", math.ceil(remaining)))
end

function DeathCause:Close()
	self.hideAt = nil
	Frame.Close(self)
end
