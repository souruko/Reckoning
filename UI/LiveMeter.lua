--=================================================================================================
-- LiveMeter -- window 1, 260x186. The always-on number you watch mid-fight.
-- See docs/DESIGN.md "1. Live meter".
--
-- Permanently visible whenever settings.liveMeterEnabled is true, per direct user feedback
-- overriding docs/DESIGN.md's original "dims and holds the last fight 8s, then hides": it now
-- just holds the last fight (or a zeroed idle state if nothing has been fought yet this play
-- session) indefinitely, dimming out of combat rather than disappearing.
--=================================================================================================

LiveMeter = class(Frame)

local TABS = { "done", "taken", "healOut", "healIn" }
local TAB_LABELS = { done = "Done", taken = "Taken", healOut = "Heal out", healIn = "Heal in" }

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

	self.lastRefresh = 0

	-- Permanent placeholder for "enabled but nothing fought yet this play session" -- a real
	-- Session whose aggregates just stay empty, so every provider function (which all call real
	-- Session methods like :Total()/:HitStats()) already renders a clean zeroed state for free,
	-- with no separate "no data" branch to keep in sync with the real one. Built before anything
	-- that can trigger a Refresh() (BuildTabs ends by calling SelectTab, which refreshes
	-- immediately) -- ActiveSession() falls back to this and Refresh() no longer has a
	-- nil-session guard, so it has to exist first, same as captionLabel/etc. from BuildBody.
	self.idleSession = Session(Turbine.Engine.GetGameTime(), "--:--")

	self:BuildCombatHeader()
	self:BuildBody()
	self:BuildTabs()

	self:SetWantsUpdates(true)
end

function LiveMeter:BuildCombatHeader()
	local tick = Turbine.UI.Control()
	tick:SetParent(self.header)
	tick:SetPosition(10, 8)
	tick:SetSize(4, 10)
	tick:SetBackColor(Theme.Color(Theme.Hex.Accent))
	tick:SetMouseVisible(false)
	self.combatTick = tick

	self.combatLabel = self:HeaderLabel(20, 70, Font.Verdana10, Theme.Hex.DimText, Turbine.UI.ContentAlignment.MiddleLeft)
	self.combatLabel:SetText("IN COMBAT")

	-- The header doubles as a small button bar -- per direct feedback, the space that used to
	-- show a static "LAST FIGHT" label is more useful as a button (starting with "open the
	-- analysis window"; more could go here later the same way).
	self:BuildAnalysisButton()

	self.clockLabel = self:HeaderLabel(160, 90, Font.LucidaConsole12, Theme.Hex.Accent300, Turbine.UI.ContentAlignment.MiddleRight)
	self.clockLabel:SetText("00:00")
end

function LiveMeter:BuildAnalysisButton()
	local button = Turbine.UI.Label()
	button:SetParent(self.header)
	button:SetFont(Font.Verdana10)
	button:SetText("Details")
	button:SetForeColor(Theme.Color(Theme.Hex.DimText))
	button:SetPosition(95, 0)
	button:SetSize(55, 26)
	button:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)

	-- `analysis` is a root-level global (Main.lua) constructed after LiveMeter -- read at click
	-- time, not captured here, so construction order between the two windows doesn't matter.
	button.MouseClick = function()
		analysis:SetVisible(true)
		analysis:Activate()
	end
	button.MouseEnter = function() button:SetForeColor(Theme.Color(Theme.Hex.Accent200)) end
	button.MouseLeave = function() button:SetForeColor(Theme.Color(Theme.Hex.DimText)) end
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

		self.tabControls[key] = { control = tab, label = label }
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
		t.label:SetForeColor(Theme.Color(selected and Theme.Hex.Accent200 or Theme.Hex.DimText))
		t.control:SetBackColor(selected and Theme.Mix(Theme.Hex.Accent, Theme.Hex.WindowFill, 0.13) or Theme.Color(Theme.Hex.WindowFill))
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

-- The fight currently being shown: the live one if a fight is on, else the most recent
-- finished one (docs/DESIGN.md's "holds the last fight"), else the permanent idle placeholder
-- if nothing has been fought yet this play session. Always returns a real Session -- callers
-- never need a nil-session branch.
function LiveMeter:ActiveSession()
	if Sessions.current ~= nil then
		return Sessions.current
	end
	if Sessions.list[1] ~= nil then
		return Sessions.list[1]
	end
	return self.idleSession
end

function LiveMeter:Refresh()
	if not _G.settings.liveMeterEnabled then
		self:SetVisible(false)
		return
	end

	self:SetVisible(true)

	local session = self:ActiveSession()
	local lines = PROVIDERS[self.activeTab](session)

	self.captionLabel:SetText(lines.headline.caption)
	self.valueLabel:SetText(lines.headline.value)
	self.rateLabel:SetText(lines.headline.rate)

	local rows = { lines.second, lines.stat, lines.max }
	for i = 1, 3 do
		self.lineLabels[i].label:SetText(rows[i].label)
		self.lineLabels[i].value:SetText(rows[i].value)
	end

	-- Just two states, not three -- per feedback, "LAST FIGHT" is gone; the header space it used
	-- is the analysis-window button instead (BuildAnalysisButton). The tick still distinguishes
	-- "actively fighting" from "showing the last fight/idle" by colour.
	local inCombat = (Sessions.current ~= nil)
	self.combatLabel:SetText(inCombat and "IN COMBAT" or "IDLE")
	self.combatTick:SetBackColor(Theme.Color(inCombat and Theme.Hex.Accent or Theme.Hex.Border))
	self.clockLabel:SetText(Format.Clock(session:Duration()))
end

function LiveMeter:Update()
	local now = Turbine.Engine.GetGameTime()
	if now - self.lastRefresh < REFRESH_INTERVAL then
		return
	end
	self.lastRefresh = now

	self:Refresh()
end
