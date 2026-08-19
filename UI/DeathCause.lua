--=================================================================================================
-- DeathCause -- window 2, 380x200. Tells you what killed you, without being asked.
-- See docs/DESIGN.md "2. Death cause".
--=================================================================================================

DeathCause = class(Frame)

local ROW_COUNT = 5
local ROW_HEIGHT = 24
local CAUSE_BLOCK_HEIGHT = 50
local RULE_HEIGHT = 2

-- Adapted from docs/DESIGN.md's "38px 1fr 62px 46px" grid (360px content width, 380 window -
-- 10px padding each side): TIME widened from 38 to 46px -- "-3.7s" at LucidaConsole12 was
-- reportedly overflowing/unreadable in the original 38px, confirmed by switching to whole
-- seconds too (below) rather than one decimal, which needs less width to begin with. SKILL
-- gives up the same 8px. MORALE keeps its 46px but now holds a Bar (see BuildMoraleBars), not
-- a percentage Label -- direct feedback: match the analysis window's own bar style instead of
-- printing a number.
local COL_TIME = { x = 10, width = 46 }
local COL_SKILL = { x = 56, width = 206 }
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

	self.remaining = nil
	self.countdownTotal = 1
	self.paused = false

	local window = self

	-- Pause (not close) the countdown while the mouse is over the window, per direct user
	-- feedback -- reading the cause shouldn't race the auto-hide. Rows are mouse-invisible
	-- (UI/Row.lua) specifically so they don't block this from firing when the cursor is over
	-- the row list rather than the background.
	self.MouseEnter = function() window.paused = true end
	self.MouseLeave = function() window.paused = false end

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
	-- Only 3 text columns -- the morale column is a Bar (below), not a Label.
	local columns = {
		{ x = COL_TIME.x, width = COL_TIME.width, font = Font.LucidaConsole12, colorHex = Theme.Hex.DimText },
		{ x = COL_SKILL.x, width = COL_SKILL.width, font = Font.Verdana12, colorHex = Theme.Hex.Text },
		{ x = COL_AMOUNT.x, width = COL_AMOUNT.width, font = Font.LucidaConsole12, colorHex = Theme.Hex.DamageTaken, align = Turbine.UI.ContentAlignment.MiddleRight },
	}

	self.rows = {}
	self.moraleBars = {}
	for i = 1, ROW_COUNT do
		local row = Row(380, ROW_HEIGHT, columns)
		row:SetParent(self.client)
		row:SetPosition(0, CAUSE_BLOCK_HEIGHT + (i - 1) * ROW_HEIGHT)
		row:SetVisible(false)
		self.rows[i] = row

		-- Current morale pool as a bar, matching the analysis window's skill/side-panel bars,
		-- per direct feedback -- not a raw percentage number.
		local bar = Bar(COL_MORALE.width - 8, 6, Theme.Hex.Morale, Theme.Hex.RowBorder)
		bar:SetParent(row)
		bar:SetPosition(COL_MORALE.x, math.floor((ROW_HEIGHT - 6) / 2))
		self.moraleBars[i] = bar
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
		local bar = self.moraleBars[i]
		local entry = session.lastTaken[i]

		if entry == nil then
			row:SetVisible(false)
			bar:SetVisible(false)
		else
			row:SetVisible(true)
			bar:SetVisible(true)
			bar:SetPercent(entry.moralePct or 0)

			-- Whole seconds, not one decimal -- "-3.7s" was reportedly unreadable/overflowing
			-- at this column's width; "-4s" is shorter regardless of how wide the column ends
			-- up being, and sub-second precision doesn't add anything readers need here.
			local relTime = string.format("%+ds", math.floor(entry.time - self.deathTime + 0.5))

			if entry.kind == "tempMorale" then
				-- Its own row so a popped temp-morale bubble never reads as mitigated damage.
				row:SetValues({ relTime, "Temporary morale", "-" .. Format.Number(entry.amount) })
				row:SetColumnColor(2, Theme.Hex.MutedText)
				row:SetColumnColor(3, Theme.Hex.MutedText)
			else
				row:SetValues({
					relTime,
					entry.skill .. " · " .. DamageTypeName(entry.dmgType),
					Format.Number(entry.amount),
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
	self.remaining = self.countdownTotal
	self.paused = false
	self.lastTick = Turbine.Engine.GetGameTime()
	self.countdownBar:SetPercent(1)

	self:SetVisible(true)
	self:Activate()
end

-- Delta-time based (not an absolute target timestamp) specifically so pausing is just "skip
-- subtracting this tick" -- an absolute hideAt would need shifting forward by however long the
-- pause lasted, which is more bookkeeping for the same result.
function DeathCause:Update()
	if self.remaining == nil then
		return
	end

	local now = Turbine.Engine.GetGameTime()
	local dt = now - self.lastTick
	self.lastTick = now

	if not self.paused then
		self.remaining = self.remaining - dt
	end

	if self.remaining <= 0 then
		self.remaining = nil
		self:SetVisible(false)
		return
	end

	self.countdownBar:SetPercent(self.remaining / self.countdownTotal)
	self.countdownLabel:SetText(string.format("%ds", math.ceil(self.remaining)))
end

function DeathCause:Close()
	self.remaining = nil
	Frame.Close(self)
end
