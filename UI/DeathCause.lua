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
-- The morale column now holds a bar AND its percentage -- the bar alone doesn't say how close
-- you actually were -- so the columns shift left to make room, and the skill column gives up the
-- width. A MAX tag sits between the skill name and the amount for the biggest single hit.
local COL_TIME   = { x = 10,  width = 44 }
local COL_SKILL  = { x = 54,  width = 160 }
local COL_MAXTAG = { x = 214, width = 28 }
local COL_AMOUNT = { x = 242, width = 62 }
local COL_BAR    = { x = 308, width = 32 }
local COL_PCT    = { x = 344, width = 26 }

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

-- The biggest single incoming hit, which is very often NOT the killing blow -- the last hit is
-- just the one that happened to land when your morale was already gone. Telling those two apart
-- is the whole point of this window, so both get marked. Temp-morale rows are excluded: a popped
-- bubble is not a hit, and it would win this comparison almost every time if it counted.
local function FindBiggestHit(session)
	local bestIndex, best = nil, 0
	for i = 1, table.getn(session.lastTaken) do
		local entry = session.lastTaken[i]
		if entry.kind == "damage" and entry.amount > best then
			bestIndex, best = i, entry.amount
		end
	end
	return bestIndex
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

	-- Legend for the two marked rows -- colour swatches plus labels, not a "killing blow" suffix
	-- on the row itself (docs/DESIGN.md: that would truncate the skill/type text). Two entries,
	-- not one, because the killing blow and the biggest hit are usually different rows and the
	-- distinction is the reason this window exists.
	local function LegendEntry(left, colorHex, text, width)
		local swatch = Turbine.UI.Control()
		swatch:SetParent(self.client)
		swatch:SetPosition(left, 39)
		swatch:SetSize(6, 6)
		swatch:SetBackColor(Theme.Color(colorHex))
		swatch:SetMouseVisible(false)

		local legend = Turbine.UI.Label()
		legend:SetParent(self.client)
		legend:SetFont(Font.Verdana10)
		legend:SetText(text)
		legend:SetForeColor(Theme.Color(colorHex))
		legend:SetPosition(left + 12, 36)
		legend:SetSize(width, 14)
		legend:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		legend:SetMouseVisible(false)
	end

	LegendEntry(x, Theme.Hex.DamageFatal, "Killing blow", 80)
	LegendEntry(x + 100, Theme.Hex.AccentLight, "Biggest hit", 80)
end

-- Each row is a container holding, back to front: a tint (only on the killing blow and the
-- biggest hit), a 2px left border in that row's mark colour, the three text columns, the morale
-- bar and its percentage. The tint and border are what make the two marked rows findable at a
-- glance -- a coloured number alone was too quiet for the one line this window exists to show.
function DeathCause:BuildRows()
	local columns = {
		{ x = COL_TIME.x, width = COL_TIME.width, font = Font.LucidaConsole12, colorHex = Theme.Hex.DimText },
		{ x = COL_SKILL.x, width = COL_SKILL.width, font = Font.Verdana12, colorHex = Theme.Hex.Text },
		{ x = COL_AMOUNT.x, width = COL_AMOUNT.width, font = Font.LucidaConsole12, colorHex = Theme.Hex.DamageTaken, align = Turbine.UI.ContentAlignment.MiddleRight },
	}

	self.rows = {}
	for i = 1, ROW_COUNT do
		local container = Turbine.UI.Control()
		container:SetParent(self.client)
		container:SetPosition(0, CAUSE_BLOCK_HEIGHT + (i - 1) * ROW_HEIGHT)
		container:SetSize(378, ROW_HEIGHT)
		container:SetVisible(false)
		container:SetMouseVisible(false)

		local tint = Turbine.UI.Control()
		tint:SetParent(container)
		tint:SetPosition(1, 0)
		tint:SetSize(377, ROW_HEIGHT)
		tint:SetVisible(false)
		tint:SetMouseVisible(false)

		local mark = Turbine.UI.Control()
		mark:SetParent(container)
		mark:SetPosition(1, 0)
		mark:SetSize(2, ROW_HEIGHT)
		mark:SetVisible(false)
		mark:SetMouseVisible(false)

		local row = Row(378, ROW_HEIGHT, columns)
		row:SetParent(container)
		row:SetPosition(0, 0)

		-- An 8px-equivalent tag is not available (the client has no face below Verdana10), so
		-- MAX sits at Verdana10 in the mark colour, in its own column rather than appended to
		-- the skill name -- appending it would push long skill names into the amount column.
		local maxTag = Turbine.UI.Label()
		maxTag:SetParent(container)
		maxTag:SetFont(Font.Verdana10)
		maxTag:SetForeColor(Theme.Color(Theme.Hex.AccentLight))
		maxTag:SetPosition(COL_MAXTAG.x, 0)
		maxTag:SetSize(COL_MAXTAG.width, ROW_HEIGHT)
		maxTag:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		maxTag:SetMouseVisible(false)

		-- Current morale pool as a bar, matching the analysis window's own bars, per direct
		-- feedback -- but now with the number beside it, since a bar alone doesn't say how close
		-- to dead you actually were.
		local bar = Bar(COL_BAR.width, 5, Theme.Hex.Morale, Theme.Hex.DeathMoraleTrack)
		bar:SetParent(container)
		bar:SetPosition(COL_BAR.x, math.floor((ROW_HEIGHT - 5) / 2))

		local pct = Turbine.UI.Label()
		pct:SetParent(container)
		pct:SetFont(Font.Verdana10)
		pct:SetForeColor(Theme.Color(Theme.Hex.DimText))
		pct:SetPosition(COL_PCT.x, 0)
		pct:SetSize(COL_PCT.width, ROW_HEIGHT)
		pct:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		pct:SetMouseVisible(false)

		self.rows[i] = {
			container = container, tint = tint, mark = mark, row = row,
			maxTag = maxTag, bar = bar, pct = pct,
		}
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
	local maxIndex = FindBiggestHit(session)
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
		local widgets = self.rows[i]
		local entry = session.lastTaken[i]

		if entry == nil then
			widgets.container:SetVisible(false)
		else
			widgets.container:SetVisible(true)
			self:FillRow(widgets, entry, i == killIndex, i == maxIndex)
		end
	end

	self.countdownTotal = _G.settings.deathAutoHide or 15
	self.remaining = self.countdownTotal
	self.paused = false
	self.lastTick = Turbine.Engine.GetGameTime()
	self.lastShownSeconds = nil -- force Update()'s first tick to set the label, see below
	self.countdownBar:SetPercent(1)

	self:SetVisible(true)
	self:Activate()
end

-- The killing blow wins the marking when a row is both: it is the row the window's headline is
-- already about, and double-marking one row in two colours would just read as a rendering fault.
function DeathCause:FillRow(widgets, entry, isKill, isMax)
	local row = widgets.row

	-- Whole seconds, not one decimal -- "-3.7s" was reportedly unreadable/overflowing at this
	-- column's width, and sub-second precision adds nothing a reader needs here.
	local relTime = string.format("%+ds", math.floor(entry.time - self.deathTime + 0.5))

	if isKill then
		widgets.tint:SetBackColor(Theme.Color(Theme.Hex.DeathKillFill))
		widgets.mark:SetBackColor(Theme.Color(Theme.Hex.DamageFatal))
	elseif isMax then
		widgets.tint:SetBackColor(Theme.Color(Theme.Hex.DeathMaxFill))
		widgets.mark:SetBackColor(Theme.Color(Theme.Hex.AccentLight))
	end
	widgets.tint:SetVisible(isKill or isMax)
	widgets.mark:SetVisible(isKill or isMax)

	widgets.maxTag:SetText((isMax and not isKill) and "MAX" or "")

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

		if isKill then
			row:SetColumnColor(3, Theme.Hex.DamageFatal)
		elseif isMax then
			row:SetColumnColor(3, Theme.Hex.AccentLight)
		elseif entry.moralePct ~= nil and entry.moralePct < 0.15 then
			row:SetColumnColor(3, Theme.Hex.DamageSevere)
		else
			row:SetColumnColor(3, Theme.Hex.DamageTaken)
		end
	end

	local pct = entry.moralePct or 0
	widgets.bar:SetPercent(pct)
	widgets.bar:SetFillColor(pct < 0.20 and Theme.Hex.DamageSevere or Theme.Hex.Morale)
	widgets.pct:SetText(Format.Percent(pct))
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

	-- The bar animates every frame (SetWantsUpdates(true), unthrottled) so its motion stays
	-- smooth, but the label only ever shows whole seconds -- reformatting and re-setting its text
	-- every single rendered frame for a value that visibly changes once a second is wasted work
	-- for the ~15s this window is up. Only touch it when the displayed integer actually changes.
	local shown = math.ceil(self.remaining)
	if shown ~= self.lastShownSeconds then
		self.lastShownSeconds = shown
		self.countdownLabel:SetText(string.format("%ds", shown))
	end
end

function DeathCause:Close()
	self.remaining = nil
	Frame.Close(self)
end
