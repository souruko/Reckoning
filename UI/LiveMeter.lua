--=================================================================================================
-- LiveMeter -- window 1, 260x186. The always-on number you watch mid-fight.
-- See docs/DESIGN.md "1. Live meter".
--=================================================================================================

LiveMeter = class(Frame)

local TABS = { "done", "taken", "healOut", "healIn" }
local TAB_LABELS = { done = "Done", taken = "Taken", healOut = "Heal out", healIn = "Heal in" }

local HOLD_SECONDS = 8
local REFRESH_INTERVAL = 0.2 -- ~5Hz, per docs/IMPLEMENTATION_PLAN.md Phase 3

---------------------------------------------------------------------------------------------------
-- Per-tab data providers -- one function per tab, all returning the same
-- { headline={caption,value,rate}, second={label,value}, stat={label,value}, max={label,value} }
-- shape so BuildBody/Refresh can stay generic even though what each tab actually shows differs
-- (docs/DESIGN.md's table has a different second/stat/max meaning per tab, not a uniform one).
---------------------------------------------------------------------------------------------------

local function CurrentTargetName()
	local target = _G.lp:GetTarget()
	if target ~= nil and target.GetName ~= nil then
		return Session.StripThe(target:GetName())
	end
	return nil
end

local function MaxLine(stats)
	if stats.max <= 0 then
		return "--"
	end
	return Format.Number(stats.max) .. "  " .. (stats.maxSkill or "")
end

local function DoneLine(session)
	local targetName = CurrentTargetName()
	local stats = session:HitStats("done")
	local critPct = stats.hits > 0 and (stats.crits / stats.hits) or 0
	local devPct = stats.hits > 0 and (stats.devs / stats.hits) or 0

	return {
		headline = { caption = "DAMAGE DONE", value = Format.Number(session:Total("done")), rate = Format.Rate(session:Rate("done")) },
		second = {
			label = targetName and string.upper("To " .. targetName) or "TO TARGET",
			value = targetName and (Format.Number(session:Total("done", targetName)) .. "  " .. Format.Rate(session:Rate("done", targetName))) or "--",
		},
		stat = { label = "CRIT / DEV", value = Format.Percent(critPct) .. " / " .. Format.Percent(devPct) },
		max = { label = "LARGEST HIT", value = MaxLine(stats) },
	}
end

local function TakenLine(session)
	local stats = session:HitStats("taken")
	local critPct = stats.hits > 0 and (stats.crits / stats.hits) or 0
	local devPct = stats.hits > 0 and (stats.devs / stats.hits) or 0
	local swings = stats.hits + stats.avoided
	local avoidedPct = swings > 0 and (stats.avoided / swings) or 0

	return {
		headline = { caption = "DAMAGE TAKEN", value = Format.Number(session:Total("taken")), rate = Format.Rate(session:Rate("taken")) },
		second = { label = "INCOMING CRIT / DEV", value = Format.Percent(critPct) .. " / " .. Format.Percent(devPct) },
		stat = { label = "AVOIDED", value = Format.Percent(avoidedPct) },
		max = { label = "LARGEST HIT TAKEN", value = MaxLine(stats) },
	}
end

local function HealOutLine(session)
	local stats = session:HitStats("healOut")
	local critPct = stats.hits > 0 and (stats.crits / stats.hits) or 0
	local devPct = stats.hits > 0 and (stats.devs / stats.hits) or 0
	local selfName = Session.StripThe(LocalPlayer.name)
	local total = session:Total("healOut")
	local toSelf = session:Total("healOut", selfName)

	return {
		headline = { caption = "HEALING DONE", value = Format.Number(total), rate = Format.Rate(session:Rate("healOut")) },
		second = { label = "SELF / OTHERS", value = Format.Number(toSelf) .. " / " .. Format.Number(total - toSelf) },
		stat = { label = "CRIT / DEV", value = Format.Percent(critPct) .. " / " .. Format.Percent(devPct) },
		max = { label = "LARGEST HEAL", value = MaxLine(stats) },
	}
end

local function HealInLine(session)
	local stats = session:HitStats("healIn")
	local critHealPct = stats.hits > 0 and ((stats.crits + stats.devs) / stats.hits) or 0
	local healIn = session:Total("healIn")
	local taken = session:Total("taken")
	local coverPct = taken > 0 and (healIn / taken) or 0

	return {
		headline = { caption = "HEALING TAKEN", value = Format.Number(healIn), rate = Format.Rate(session:Rate("healIn")) },
		second = { label = "COVER OF DAMAGE", value = Format.Percent(coverPct) },
		stat = { label = "CRIT HEALS", value = Format.Percent(critHealPct) },
		max = { label = "LARGEST HEAL IN", value = MaxLine(stats) },
	}
end

local PROVIDERS = { done = DoneLine, taken = TakenLine, healOut = HealOutLine, healIn = HealInLine }

---------------------------------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------------------------------

function LiveMeter:Constructor()
	Frame.Constructor(self, {
		key = "liveMeter", title = nil, closable = false,
		width = 260, height = 186, headerHeight = 26,
	})

	-- tab row (24px) sits directly under the header; body (136px) below that.
	self.body = Turbine.UI.Control()
	self.body:SetParent(self.client)
	self.body:SetPosition(0, 24)
	self.body:SetSize(260, 136)
	self.body:SetMouseVisible(false)

	self:BuildCombatHeader()
	self:BuildTabs()
	self:BuildBody()

	self.holdUntil = nil
	self.lastRefresh = 0

	local meter = self
	Sessions.OnClosed(function(s) meter:OnSessionClosed(s) end)

	self:SetWantsUpdates(true)
	self:SetVisible(false)
end

function LiveMeter:BuildCombatHeader()
	local tick = Turbine.UI.Control()
	tick:SetParent(self.header)
	tick:SetPosition(10, 8)
	tick:SetSize(4, 10)
	tick:SetBackColor(Theme.Color(Theme.Hex.Accent))
	tick:SetMouseVisible(false)
	self.combatTick = tick

	self.combatLabel = self:HeaderLabel(20, 120, Font.Verdana10, Theme.Hex.DimText, Turbine.UI.ContentAlignment.MiddleLeft)
	self.combatLabel:SetText("IN COMBAT")

	self.clockLabel = self:HeaderLabel(160, 90, Font.LucidaConsole12, Theme.Hex.Accent300, Turbine.UI.ContentAlignment.MiddleRight)
	self.clockLabel:SetText("00:00")
end

function LiveMeter:HeaderLabel(x, w, font, colorHex, align)
	local label = Turbine.UI.Label()
	label:SetParent(self.header)
	label:SetFont(font)
	label:SetForeColor(Theme.Color(colorHex))
	label:SetPosition(x, 0)
	label:SetSize(w, self.headerHeight)
	label:SetTextAlignment(align)
	label:SetMouseVisible(false)
	return label
end

function LiveMeter:BuildTabs()
	self.tabControls = {}
	local tabWidth = 260 / table.getn(TABS)
	local meter = self

	for i = 1, table.getn(TABS) do
		local key = TABS[i]

		local tab = Turbine.UI.Control()
		tab:SetParent(self.client)
		tab:SetPosition((i - 1) * tabWidth, 0)
		tab:SetSize(tabWidth, 24)
		tab:SetBackColor(Theme.Color(Theme.Hex.WindowFill))

		local fill = Turbine.UI.Control()
		fill:SetParent(tab)
		fill:SetPosition(0, 0)
		fill:SetSize(tabWidth, 24)
		fill:SetBackColor(Theme.Color(Theme.Hex.Accent))
		fill:SetOpacity(0)
		fill:SetMouseVisible(false)

		local label = Turbine.UI.Label()
		label:SetParent(tab)
		label:SetFont(Font.Verdana10)
		label:SetText(string.upper(TAB_LABELS[key]))
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetPosition(0, 0)
		label:SetSize(tabWidth, 24)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
		label:SetMouseVisible(false)

		tab.MouseClick = function() meter:SelectTab(key) end
		tab.MouseEnter = function() meter:TabHover(key, true) end
		tab.MouseLeave = function() meter:TabHover(key, false) end

		self.tabControls[key] = { control = tab, fill = fill, label = label }
	end

	self:SelectTab(TABS[_G.settings.liveTab] or "done", true)
end

function LiveMeter:BuildBody()
	local x, w = 10, 240

	self.captionLabel = self:BodyLabel(x, 0, 160, 14, Font.Verdana10, Theme.Hex.DimText, Turbine.UI.ContentAlignment.BottomLeft)
	self.valueLabel = self:BodyLabel(x, 8, 150, 27, Font.Verdana22, Theme.Hex.Text, Turbine.UI.ContentAlignment.BottomLeft)
	self.rateLabel = self:BodyLabel(x + 150, 18, 90, 17, Font.Verdana12, Theme.Hex.Accent300, Turbine.UI.ContentAlignment.BottomRight)

	local divider = Turbine.UI.Control()
	divider:SetParent(self.body)
	divider:SetPosition(x, 42)
	divider:SetSize(w, 1)
	divider:SetBackColor(Theme.Color(Theme.Hex.MeterDivider))
	divider:SetMouseVisible(false)

	self.lineLabels = {}
	local ys = { 50, 81, 112 }
	for i = 1, 3 do
		local labelL = self:BodyLabel(x, ys[i], 120, 24, Font.Verdana10, Theme.Hex.DimText, Turbine.UI.ContentAlignment.MiddleLeft)
		local valueL = self:BodyLabel(x + 120, ys[i], 120, 24, Font.LucidaConsole12, Theme.Hex.Text, Turbine.UI.ContentAlignment.MiddleRight)
		self.lineLabels[i] = { label = labelL, value = valueL }
	end
end

function LiveMeter:BodyLabel(x, y, w, h, font, colorHex, align)
	local label = Turbine.UI.Label()
	label:SetParent(self.body)
	label:SetFont(font)
	label:SetForeColor(Theme.Color(colorHex))
	label:SetPosition(x, y)
	label:SetSize(w, h)
	label:SetTextAlignment(align)
	label:SetMouseVisible(false)
	return label
end

---------------------------------------------------------------------------------------------------
-- Interaction
---------------------------------------------------------------------------------------------------

function LiveMeter:SelectTab(key, skipSave)
	self.activeTab = key

	for i = 1, table.getn(TABS) do
		local k = TABS[i]
		local t = self.tabControls[k]
		local selected = (k == key)
		t.fill:SetOpacity(selected and 0.13 or 0)
		t.label:SetForeColor(Theme.Color(selected and Theme.Hex.Accent200 or Theme.Hex.DimText))
		t.control:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	end

	if not skipSave then
		for i = 1, table.getn(TABS) do
			if TABS[i] == key then
				_G.settings.liveTab = i
			end
		end
		Settings.Save()
	end

	self:Refresh()
end

function LiveMeter:TabHover(key, entering)
	if key == self.activeTab then
		return
	end
	self.tabControls[key].control:SetBackColor(Theme.Color(entering and Theme.Hex.Hover or Theme.Hex.WindowFill))
end

---------------------------------------------------------------------------------------------------
-- Refresh / lifecycle
---------------------------------------------------------------------------------------------------

function LiveMeter:ActiveSession()
	if Sessions.current ~= nil then
		return Sessions.current
	end
	if self.holdUntil ~= nil then
		return Sessions.list[1]
	end
	return nil
end

function LiveMeter:Refresh()
	if Sessions.current ~= nil then
		self.holdUntil = nil
	end

	local session = self:ActiveSession()
	if session == nil then
		self:SetVisible(false)
		return
	end

	self:SetVisible(true)

	local lines = PROVIDERS[self.activeTab](session)

	self.captionLabel:SetText(lines.headline.caption)
	self.valueLabel:SetText(lines.headline.value)
	self.rateLabel:SetText(lines.headline.rate)

	local rows = { lines.second, lines.stat, lines.max }
	for i = 1, 3 do
		self.lineLabels[i].label:SetText(rows[i].label)
		self.lineLabels[i].value:SetText(rows[i].value)
	end

	local inCombat = (Sessions.current ~= nil)
	self.combatLabel:SetText(inCombat and "IN COMBAT" or "LAST FIGHT")
	self.clockLabel:SetText(Format.Clock(session:Duration()))

	self:SetOpacity(inCombat and 1 or 0.55)
end

function LiveMeter:OnSessionClosed(session)
	self.holdUntil = Turbine.Engine.GetGameTime() + HOLD_SECONDS
end

function LiveMeter:Update()
	local now = Turbine.Engine.GetGameTime()
	if now - self.lastRefresh < REFRESH_INTERVAL then
		return
	end
	self.lastRefresh = now

	if self.holdUntil ~= nil and Sessions.current == nil and now >= self.holdUntil then
		self.holdUntil = nil
		self:SetVisible(false)
		return
	end

	self:Refresh()
end
