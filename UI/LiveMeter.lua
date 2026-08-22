--=================================================================================================
-- LiveMeter -- window 1, 260x186. The always-on number you watch mid-fight.
-- See docs/DESIGN.md "1. Live meter".
--
-- Permanently visible whenever settings.liveMeterEnabled is true, per direct user feedback
-- overriding docs/DESIGN.md's original "dims and holds the last fight 8s, then hides": it now
-- just holds the last fight (or a zeroed idle state if nothing has been fought yet this play
-- session) indefinitely -- no out-of-combat opacity change either (also removed per feedback).
--=================================================================================================

LiveMeter = class(Frame)

local TABS = { "done", "taken", "healOut", "healIn" }
local TAB_LABELS = { done = "Done", taken = "Taken", healOut = "Heal out", healIn = "Heal in" }

-- The sparkline takes the active tab's own series colour, so the band and the headline number
-- below it are obviously about the same thing. RESOLVED PER CALL, not a module-level table of
-- hexes: that table was built once at load and could never see a palette-preset change
-- (Constants.lua's Theme.Series -- this is the exact trap the options panel's Palette page
-- introduced, and it was a live bug in the draft before this).
local function TabColor(key)
	return Theme.Series(key)
end

-- docs/IMPLEMENTATION_PLAN.md suggested ~5Hz (0.2s); bumped to 0.1s (10Hz) per direct feedback,
-- and now a setting (options window, Live meter page: 2 / 5 / 10 Hz). Read inside Update() rather
-- than captured here, so a change takes effect on the next tick.
local DEFAULT_HZ = 10

local function RefreshInterval()
	local hz = tonumber(_G.settings and _G.settings.refreshHz) or DEFAULT_HZ
	if hz <= 0 then
		hz = DEFAULT_HZ
	end
	return 1 / hz
end

-- Redesign geometry (REDESIGN_SPEC.md section 8). The tab row loses 2px and the sparkline is
-- paid for out of the body's existing height -- the window's 260x186 footprint does not change.
local TAB_ROW_HEIGHT = 22
local SPARK_WIDTH = 240   -- the body's full content width
local SPARK_MAX_SECONDS = 60 -- the pool is built at the setting's UPPER BOUND, never per window:
                             -- growing it later would mean creating Controls at refresh time
local SPARK_HEIGHT = 16
local SPARK_BAR_GAP = 2   -- air between columns
local SPARK_BAR_MIN = 2

-- Seconds of history the band covers (settings.sparklineWindow, 10-60). Clamped to the pool so a
-- hand-edited save can never ask for a column that was never built. The 60 ceiling is deliberate:
-- 240px / 60 is 4px per column, and below that the band stops reading as a band.
local function SparkSeconds()
	local seconds = tonumber(_G.settings and _G.settings.sparklineWindow) or 30
	if seconds < 1 then
		seconds = 1
	elseif seconds > SPARK_MAX_SECONDS then
		seconds = SPARK_MAX_SECONDS
	end
	return seconds
end

---------------------------------------------------------------------------------------------------
-- Per-tab data providers -- one function per tab, all returning the same
-- { headline={caption,value,rate}, second={label,value}, stat={label,value}, max={label,value} }
-- shape so BuildBody/Refresh can stay generic even though what each tab actually shows differs
-- (docs/DESIGN.md's table has a different second/stat/max meaning per tab, not a uniform one).
---------------------------------------------------------------------------------------------------

-- Used to be the one continuously-firing (10Hz, unconditional on combat state) call anywhere in
-- this codebase that read the live Turbine.Gameplay player object -- LotRO's target API is
-- reportedly expensive, so this no longer touches it from Refresh()/Update() at all. Instead it
-- mirrors Session.lua's MoralePct cache exactly: hook the real TargetChanged event on _G.lp
-- (confirmed real and fired with no useful payload, callback has to re-query -- VitalSelf/UI/
-- Vital.lua hooks it the identical way, `self:Hook(_G.lp, "TargetChanged", function() ...
-- _G.lp:GetTarget() ... end)`), and only touch the target API -- one GetTarget() to get the
-- object, one GetName() on it -- when that event actually fires. Between changes, DoneLine()
-- just reads the cached name: zero native target calls per render, zero per Update() tick.
--
-- _G.lp.TargetChanged is a single field slot, not a real multi-subscriber event -- other
-- installed plugins (VitalTarget, PrimePlugins) hook the same field on the same LocalPlayer
-- instance, confirmed by grep. CallField() chains onto whatever's already sitting there instead
-- of clobbering it, same reasoning as Session.lua's MoraleChanged hook and Events.lua's
-- previousChatReceived.
local CachedTargetName = nil

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

local function RefreshTargetName()
	local ok, name = pcall(function()
		local target = _G.lp:GetTarget()
		if target ~= nil and target.GetName ~= nil then
			return Session.StripThe(target:GetName())
		end
		return nil
	end)
	CachedTargetName = ok and name or nil
end

local previousTargetChanged = _G.lp ~= nil and _G.lp.TargetChanged or nil

RefreshTargetName()
if _G.lp ~= nil then
	_G.lp.TargetChanged = function(...) CallField(previousTargetChanged, ...); RefreshTargetName() end
end

-- Restores whatever was in the field slot before this file hooked it -- called from Main.lua's
-- plugin.Unload, mirroring Session.ShutdownMorale().
function LiveMeter.ShutdownTarget()
	if _G.lp ~= nil then
		_G.lp.TargetChanged = previousTargetChanged
	end
end

local function CurrentTargetName()
	return CachedTargetName
end

-- The "max" line is the one line with a second piece of text (the skill name) alongside its
-- number. Cramming both into one LucidaConsole12 value column overflowed badly on long skill
-- names, so it's a real two-line cell instead: the number on top (LucidaConsole12, same as
-- every other value), the skill name in a smaller Verdana10 line below it (BuildBody/Refresh),
-- not appended to the same string. MaxLine() only ever returns the number now.
local function MaxLine(stats)
	if stats.max <= 0 then
		return "--"
	end
	return Format.Number(stats.max)
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
		max = { label = "LARGEST HIT", value = MaxLine(stats), sub = stats.maxSkill or "" },
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
		max = { label = "LARGEST HIT TAKEN", value = MaxLine(stats), sub = stats.maxSkill or "" },
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
		max = { label = "LARGEST HEAL", value = MaxLine(stats), sub = stats.maxSkill or "" },
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
		max = { label = "LARGEST HEAL IN", value = MaxLine(stats), sub = stats.maxSkill or "" },
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

	-- tab row (22px) sits directly under the header; body fills the rest of the client.
	self.body = Turbine.UI.Control()
	self.body:SetParent(self.client)
	self.body:SetPosition(0, TAB_ROW_HEIGHT)
	self.body:SetSize(260, 160 - TAB_ROW_HEIGHT)
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
	-- Toggles: a second click closes the window it opened.
	button.MouseClick = function()
		if analysis:IsVisible() then
			analysis:SetVisible(false)
		else
			analysis:SetVisible(true)
			analysis:Activate()
			analysis.postButton:Raise()
		end
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
		tab:SetSize(tabWidth, TAB_ROW_HEIGHT)
		tab:SetBackColor(Theme.Color(Theme.Hex.WindowFill))

		local label = Turbine.UI.Label()
		label:SetParent(tab)
		label:SetFont(Font.Verdana10)
		label:SetText(string.upper(TAB_LABELS[key]))
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetPosition(0, 0)
		label:SetSize(tabWidth, TAB_ROW_HEIGHT - 2)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
		label:SetMouseVisible(false)

		-- Underline instead of a filled block: at 65px per tab a solid fill is a heavy mark
		-- for what is only a mode switch, and a 2px rule reads the way the analysis window's
		-- own tabs do.
		local underline = Turbine.UI.Control()
		underline:SetParent(tab)
		underline:SetPosition(0, TAB_ROW_HEIGHT - 2)
		underline:SetSize(tabWidth, 2)
		underline:SetMouseVisible(false)

		tab.MouseClick = function() meter:SelectTab(key) end
		tab.MouseEnter = function() meter:TabHover(key, true) end
		tab.MouseLeave = function() meter:TabHover(key, false) end

		self.tabControls[key] = { control = tab, label = label, underline = underline }
	end

	self:SelectTab(TABS[_G.settings.liveTab] or "done", true)
end

function LiveMeter:BuildBody()
	local x, w = 10, 240

	-- caption 12 / headline 24 / sparkline 16 / divider 1 / three stat rows 16 / sub-line 10,
	-- all inside the body the window already had. The headline number is Verdana20 rather than
	-- Verdana22 so it sits on a 24px line without the sparkline having to steal from it.
	self.captionLabel = self:BodyLabel(x, 6, 160, 12, Font.Verdana10, Theme.Hex.DimText, Turbine.UI.ContentAlignment.MiddleLeft)
	self.valueLabel = self:BodyLabel(x, 18, 150, 24, Font.Verdana20, Theme.Hex.Text, Turbine.UI.ContentAlignment.BottomLeft)
	self.rateLabel = self:BodyLabel(x + 150, 18, 90, 24, Font.LucidaConsole12, Theme.Hex.Accent300, Turbine.UI.ContentAlignment.BottomRight)

	self:BuildSparkline(x, 45)

	local divider = Turbine.UI.Control()
	divider:SetParent(self.body)
	divider:SetPosition(x, 65)
	divider:SetSize(w, 1)
	divider:SetBackColor(Theme.Color(Theme.Hex.MeterDivider))
	divider:SetMouseVisible(false)

	-- 19px pitch (16px row + 3px air) instead of the old flush 16px -- the three stat rows used
	-- to butt directly against each other with no gap at all, per feedback that the whole block
	-- read as too cramped. The body has 138px to work with and this now fills all of it deliberately.
	self.lineLabels = {}
	local ys = { 71, 90, 109 }
	for i = 1, 3 do
		local labelL = self:BodyLabel(x, ys[i], 120, 16, Font.Verdana10, Theme.Hex.DimText, Turbine.UI.ContentAlignment.MiddleLeft)
		local valueL = self:BodyLabel(x + 120, ys[i], 120, 16, Font.LucidaConsole12, Theme.Hex.Text, Turbine.UI.ContentAlignment.MiddleRight)
		self.lineLabels[i] = { label = labelL, value = valueL }
	end

	-- The max-hit row keeps its skill name on its own line under the number rather than crammed
	-- onto it -- a long skill name overflowed badly when the two shared one LucidaConsole12 cell.
	self.lineLabels[3].sub = self:BodyLabel(x, 128, w, 10, Font.Verdana10, Theme.Hex.DimText, Turbine.UI.ContentAlignment.TopRight)
end

-- Pooled columns, one per second of the window, drawn as a filled band rather than a line: 16px
-- of height cannot express a polyline, and the shape of the last N seconds is all this is for.
-- The pool is SPARK_MAX_SECONDS deep whatever the current window is -- see that constant.
function LiveMeter:BuildSparkline(x, y)
	self.sparkColumns = {}
	for i = 1, SPARK_MAX_SECONDS do
		local column = Turbine.UI.Control()
		column:SetParent(self.body)
		column:SetPosition(x, y + SPARK_HEIGHT)
		column:SetSize(SPARK_BAR_MIN, 0)
		column:SetVisible(false)
		column:SetMouseVisible(false)
		self.sparkColumns[i] = column
	end

	self.sparkX, self.sparkY = x, y
end

-- One column per whole second, read straight off session.buckets for the ACTIVE TAB's category,
-- ending at the fight's most recent second. Seconds before the fight started, and seconds with
-- no events, are simply absent -- a gap in the band is a real lull, not missing data.
--
-- Column pitch is recomputed per refresh from the current window (240px / N), not a constant:
-- settings.sparklineWindow can change between two refreshes and the band must always fill the
-- body's width exactly. Columns past the window are hidden, never destroyed.
function LiveMeter:RefreshSparkline(session)
	local seconds = SparkSeconds()
	local show = (_G.settings == nil) or (_G.settings.sparkline ~= false)

	if not show then
		for i = 1, SPARK_MAX_SECONDS do
			self.sparkColumns[i]:SetVisible(false)
		end
		return
	end

	local pitch = SPARK_WIDTH / seconds
	local barWidth = math.max(SPARK_BAR_MIN, math.floor(pitch) - SPARK_BAR_GAP)

	local key = self.activeTab
	local lastSecond = math.floor(session:Duration())

	local values, maxValue = {}, 0
	for i = 1, seconds do
		local second = lastSecond - seconds + i
		local bucket = (second >= 0) and session.buckets[second] or nil
		local value = bucket and (bucket[key] or 0) or 0
		values[i] = value
		if value > maxValue then
			maxValue = value
		end
	end

	-- Every visible column this refresh is the same colour (the active tab never changes mid-loop)
	-- -- resolved once outside the loop rather than once per column (up to 60 calls/refresh at
	-- 10Hz otherwise).
	local color = Theme.Color(TabColor(key))
	for i = 1, SPARK_MAX_SECONDS do
		local column = self.sparkColumns[i]
		local height = 0
		if i <= seconds and values[i] > 0 and maxValue > 0 then
			-- at least 1px, so a small second next to a huge one still shows something
			height = math.max(1, math.floor(values[i] / maxValue * SPARK_HEIGHT))
		end

		if height > 0 then
			column:SetPosition(self.sparkX + math.floor((i - 1) * pitch),
				self.sparkY + SPARK_HEIGHT - height)
			column:SetSize(barWidth, height)
			column:SetBackColor(color)
			column:SetVisible(true)
		else
			column:SetVisible(false)
		end
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
		t.underline:SetBackColor(Theme.Color(selected and Theme.Hex.Accent or Theme.Hex.Border))
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

-- How long the player has been out of combat, for the idle fade. Measured from the last fight's
-- own combat clock rather than from a timestamp this file keeps, so it survives a /plugins
-- refresh mid-lull and cannot drift from what Sessions.lua thinks the fight's end was.
function LiveMeter:IdleSeconds()
	if Sessions.current ~= nil then
		return 0
	end
	local last = Sessions.list[1]
	if last == nil then
		return nil -- nothing fought yet this play session: the fade has no clock to run against
	end
	return Turbine.Engine.GetGameTime() - last.combatEndTime
end

-- Whole-window opacity and the idle fade. SetOpacity on a Turbine.UI.Window with no BackColor of
-- its own is the ONE use of it this codebase has confirmed working (VitalSelf's own
-- incombat/outcombat fade); the banned case is SetOpacity as a tint over a solid Control fill,
-- which is what Theme.Mix exists for. Frame keeps its fill on a child Control, so this is the
-- confirmed shape.
function LiveMeter:ApplyFade()
	local inCombat = (Sessions.current ~= nil)
	local idle = self:IdleSeconds()

	if not inCombat and _G.settings.idleFadeEnabled == true and idle ~= nil
		and idle >= (_G.settings.idleFadeAfter or 20) then
		self:SetVisible(false)
		return false
	end

	self:SetVisible(true)

	local percent = inCombat and (_G.settings.opacityCombat or 100) or (_G.settings.opacityIdle or 55)
	self:SetOpacity(percent / 100)

	-- "Click-through when faded" applies to the dimmed out-of-combat state, not to the fully
	-- faded one (which is hidden and cannot be clicked either way).
	self:SetMouseVisible(inCombat or _G.settings.clickThroughFaded ~= true)
	return true
end

-- Re-reads every live-meter setting and repaints. Called from the options window; safe to call
-- at any time, and does not rebuild a single Control.
--
-- ApplyBorders is called HERE rather than left to Refresh: Refresh returns early when the meter
-- is disabled or fully faded, and the border toggle has to land whether or not the window is
-- currently drawing anything.
function LiveMeter:ApplySettings()
	self:ApplyBorders()
	self:Refresh()
end

function LiveMeter:Refresh()
	if not _G.settings.liveMeterEnabled then
		self:SetVisible(false)
		return
	end

	if not self:ApplyFade() then
		return -- faded out entirely; nothing to repaint behind it
	end

	local session = self:ActiveSession()
	local lines = PROVIDERS[self.activeTab](session)

	self.captionLabel:SetText(lines.headline.caption)

	-- settings.liveBarValue (options window, Live meter page) picks which number gets the big
	-- Verdana20 slot. "Both" is the default and is today's shipped headline -- the rate prominent
	-- with the raw total in the small LucidaConsole12 corner, which was set by direct feedback.
	-- The design handoff defaults this key to "Rate"; defaulting to "Both" instead is a deliberate
	-- deviation so that turning the feature on changes nothing until asked (see CLAUDE.md).
	local mode = _G.settings.liveBarValue or "Both"
	if mode == "Total" then
		self.valueLabel:SetText(lines.headline.value)
		self.rateLabel:SetText(lines.headline.rate)
	elseif mode == "Rate" then
		self.valueLabel:SetText(lines.headline.rate)
		self.rateLabel:SetText("")
	else
		self.valueLabel:SetText(lines.headline.rate)
		self.rateLabel:SetText(lines.headline.value)
	end

	local rows = { lines.second, lines.stat, lines.max }
	for i = 1, 3 do
		self.lineLabels[i].label:SetText(rows[i].label)
		self.lineLabels[i].value:SetText(rows[i].value)
	end
	self.lineLabels[3].sub:SetText(lines.max.sub or "")

	self:RefreshSparkline(session)

	-- Just two states, not three -- per feedback, "LAST FIGHT" is gone; the header space it used
	-- is the analysis-window button instead (BuildAnalysisButton). The tick still distinguishes
	-- "actively fighting" from "showing the last fight/idle" by colour.
	local inCombat = (Sessions.current ~= nil)
	self.combatLabel:SetText(inCombat and "IN COMBAT" or "IDLE")
	self.combatTick:SetBackColor(Theme.Color(inCombat and Theme.Hex.Accent or Theme.Hex.Border))

	-- session:Duration() is endTime - startTime, and endTime only moves when Touch() runs (i.e.
	-- on a real combat event) -- Session.lua's own Touch() comment says as much. Fine for a
	-- finished fight (where "duration" should mean "time of the last hit", not "time until the
	-- player happened to check"), but during a live fight it froze the clock between events
	-- instead of ticking with Refresh()'s own 0.1s timer. Only the live case needs the live
	-- game clock; a finished/idle session keeps the frozen, correct-for-a-fight-summary value.
	local elapsed = inCombat and (Turbine.Engine.GetGameTime() - session.startTime) or session:Duration()
	self.clockLabel:SetText(Format.Clock(elapsed))
end

function LiveMeter:Update()
	local now = Turbine.Engine.GetGameTime()
	if now - self.lastRefresh < RefreshInterval() then
		return
	end
	self.lastRefresh = now

	self:Refresh()
end
