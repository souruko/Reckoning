--=================================================================================================
-- Analysis -- window 3, 1080x820 resizable to 1440x880. The post-mortem, per fight and per
-- target. See docs/DESIGN.md "3. Post-combat analysis" and the redesign bundle's
-- REDESIGN_SPEC.md section 7.
--
-- The content column is 848px wide at the minimum window size (1080 - 208 rail - 2x12 padding),
-- which is exactly the width every number in the redesign mock was measured against. Blocks
-- stack: tab strip + goal line (30), picker chips (22), 5 KPI cards (50), the graph block
-- (plot + charted buff lanes + range slider + timeline + legend, see UI/AnalysisGraph.lua),
-- the skill table at full content width, then the SELF BUFFS table and the two side panels
-- sharing the bottom row.
--
-- Deliberate deviations from the literal mock numbers, since this is the one window meant to
-- resize:
--  - Every block stretches to fill the available content width instead of being pinned at 848 --
--    a fixed-width graph and table would get no benefit from resizing up to 1440px, which is the
--    whole point of the resize gripper existing on this window and not the other two. Bucket
--    COUNT stays fixed at 48 (docs/IMPLEMENTATION_PLAN.md); bucket width scales instead. The two
--    side panels keep their 233px so the buff table gets every pixel the window gains.
--  - The 5 KPIs are one uniform shape across all four views (total+rate, hits/heals+skill count,
--    crit/dev%, largest+skill, active-or-range time) rather than bespoke per view --
--    docs/DESIGN.md specifies "five KPIs" per view without dictating their exact content.
--
-- EVERYTHING IS RANGE-SCOPED. Dragging either handle on the range slider re-runs a single
-- Session:Slice for the selected seconds, and the KPIs, skill table, both side panels and the
-- buff table are all fed from that one result -- one recount per interaction, not one per
-- widget. A full-fight range takes Slice's aggregate path, so an unscoped window shows exactly
-- the same numbers it did before the slider existed.
--=================================================================================================

Analysis = class(Frame)

local MIN_WIDTH, MIN_HEIGHT = 1080, 600
local MAX_WIDTH, MAX_HEIGHT = 1440, 880
-- The redesign's own stack (buff section open, 2 lanes charted, 9 skill rows) comes to ~851px,
-- so a new install opens tall enough to show all of it. MIN_HEIGHT stays at 600 for anyone on a
-- short screen -- the skill table shrinks and scrolls first, the buff table second.
local DEFAULT_HEIGHT = 820

local RAIL_WIDTH = 208
local HEADER_HEIGHT = 32
local TAB_STRIP_HEIGHT = 30
local TAB_WIDTH = 140
local GAP = 11
local PAD = 12
local KPI_ROW_HEIGHT = 50
local PICKER_HEIGHT = 22
local ROW_HEIGHT = 22
local RAIL_ROW_HEIGHT = 34
local SCROLLBAR_WIDTH = 10
local RAIL_POOL = 20 -- generous: ring cap is 10 but pinned sessions are exempt from it
local PANEL_WIDTH = 233

local BUFF_HEADER_HEIGHT = 26
local BUFF_TABLE_HEADER_HEIGHT = 20
local BUFF_ROW_HEIGHT = 22
local BUFF_POOL = 40 -- generous, matching tableRowPool's 30: the section already scrolls
                      -- (BuildBuffSection's ListBox+ScrollBar) and Layout() already clamps
                      -- bottomHeight to available window space, so this only bounds how many
                      -- distinct buffs can ever be listed, not how many are visible at once.
local MAX_CHARTED = 3

-- Tab order is damage pair then healing pair, so the two views a reader actually compares sit
-- next to each other. This drives tab ORDER only -- VIEW_META, the filter table and the graph's
-- series map are all keyed, never indexed.
local VIEWS = { "done", "taken", "healOut", "healIn" }

local VIEW_META = {
	done = {
		label = "Damage done", question = "Which skills carried it, against whom",
		pickerLabel = "targets", hitWord = "hits", color = Theme.Hex.DamageDone,
		shape = "damage", counterpartHeader = "TYPE",
	},
	taken = {
		label = "Damage taken", question = "What hit you, what got through",
		pickerLabel = "sources", hitWord = "hits", color = Theme.Hex.DamageTaken,
		shape = "damage", counterpartHeader = "TYPE",
	},
	healOut = {
		label = "Healing done", question = "Self-sustain and group contribution",
		pickerLabel = "recipients", hitWord = "heals", color = Theme.Hex.HealingDone,
		shape = "heal", counterpartHeader = "TO",
	},
	healIn = {
		label = "Healing taken", question = "Did healers keep pace",
		pickerLabel = "casters", hitWord = "heals", color = Theme.Hex.HealingTaken,
		shape = "heal", counterpartHeader = "FROM",
	},
}

-- Column specs, replacing the old derive-widths-from-header-names approach. Crit and Dev are one
-- CRIT / DEV percentage column now: two separate 60px counter columns were what pushed the
-- `taken` view's 8 columns past its own viewport and clipped TOTAL off the right-hand edge, and
-- percentages are what a reader wants from those two anyway (the raw counters stay separate in
-- the data, per docs/DESIGN.md). MAX and TOTAL are deliberately wide -- a 7-figure comma-formatted
-- number at LucidaConsole12 needs ~80px inside 8px padding, and a clipped total is the one number
-- in this table nobody can afford to lose. `width = nil` means "take whatever is left over".
local COLUMN_SETS = {
	damage = {
		{ key = "skill",   label = "SKILL",      width = nil },
		{ key = "type",    label = nil,          width = 110 },
		{ key = "hits",    label = nil,          width = 58,  numeric = true },
		{ key = "critdev", label = "CRIT / DEV", width = 106, numeric = true },
		{ key = "avoid",   label = "AVOID",      width = 68,  numeric = true },
		{ key = "max",     label = "MAX",        width = 88,  numeric = true },
		{ key = "total",   label = "TOTAL",      width = 104, numeric = true, accent = true },
	},
	heal = {
		{ key = "skill",   label = "SKILL",      width = nil },
		{ key = "type",    label = nil,          width = 156 },
		{ key = "hits",    label = nil,          width = 58,  numeric = true },
		{ key = "critdev", label = "CRIT / DEV", width = 106, numeric = true },
		{ key = "max",     label = "MAX",        width = 88,  numeric = true },
		{ key = "total",   label = "TOTAL",      width = 104, numeric = true, accent = true },
	},
}

local SKILL_COLUMN_MIN = 150
local MAX_TABLE_COLUMNS = 7

-- [chart box 22][icon 24][name 190][uptime % 98][uptime 90][apps 74][longest gap 106] = 604,
-- which is exactly the content width minus the two side panels and their gap.
local BUFF_COLUMNS = {
	{ key = "check", width = 22,  label = "" },
	{ key = "icon",  width = 24,  label = "" },
	{ key = "name",  width = 190, label = "BUFF" },
	{ key = "pct",   width = 98,  label = "UPTIME %",    numeric = true },
	{ key = "up",    width = 90,  label = "UPTIME",      numeric = true },
	{ key = "apps",  width = 74,  label = "APPS",        numeric = true },
	{ key = "gap",   width = 106, label = "LONGEST GAP", numeric = true },
}

local BUFF_GOOD_UPTIME = 0.75
local BUFF_POOR_UPTIME = 0.35
local BUFF_LONG_GAP = 12 -- seconds

local AVOID_NAMES = {
	[AvoidType.Missed] = "Missed", [AvoidType.Immune] = "Immune", [AvoidType.Resisted] = "Resisted",
	[AvoidType.Blocked] = "Blocked", [AvoidType.Parried] = "Parried", [AvoidType.Evaded] = "Evaded",
	[AvoidType.Deflected] = "Deflected",
}

-- Search box geometry, shared by the skill table and the buff table.
local SEARCH_HEIGHT = 20
local SEARCH_WIDTH = 190

-- Plain substring match, case-insensitive -- `string.find(..., true)` (plain mode) so a name
-- with pattern-magic characters in it (unlikely in a skill/buff name, but free to guard) can't
-- break the search.
local function MatchesFilter(text, query)
	if query == nil or query == "" then
		return true
	end
	return string.find(string.lower(text or ""), string.lower(query), 1, true) ~= nil
end

---------------------------------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------------------------------

function Analysis:Constructor()
	Frame.Constructor(self, {
		key = "analysis", title = "Reckoning", closable = true,
		width = MIN_WIDTH, height = DEFAULT_HEIGHT, headerHeight = HEADER_HEIGHT,
	})

	self.viewTab = "done"
	self.filter = { done = nil, taken = nil, healOut = nil, healIn = nil }
	self.selectedSession = nil

	-- Search text for the skill table and the buff table, independent of each other and of the
	-- target/source picker filter above -- not persisted, same as viewTab/filter (ephemeral UI
	-- state, resets to blank when the window is next built).
	self.tableFilterText = ""
	self.buffFilterText = ""

	self.bucketCount = GraphBucketCount()
	self.rangeFrom = 1
	self.rangeTo = self.bucketCount

	-- Restored from settings, then re-validated against whatever buffs the selected session
	-- actually has (a name list is safe to persist; a Turbine.UI.Color never is -- Settings.lua).
	self.charted = {}
	local savedCharted = _G.settings.chartedBuffs
	if type(savedCharted) == "table" then
		for i = 1, table.getn(savedCharted) do
			if i <= MAX_CHARTED and type(savedCharted[i]) == "string" then
				self.charted[table.getn(self.charted) + 1] = savedCharted[i]
			end
		end
	end
	self.buffsOpen = (_G.settings.buffsOpen ~= false)

	-- What the last Layout() sized the variable-height blocks for. RefreshContent compares
	-- against these and re-runs Layout only when the shape actually changed, which is what stops
	-- the two from calling each other forever.
	self.layoutLanes = -1
	self.layoutBuffRows = -1
	self.laneCountWanted = 0
	self.buffRowsWanted = 0

	self:BuildHeaderExtras()
	self:BuildSessionRail()
	self:BuildContentArea()
	self:BuildResizeGripper()

	-- Adopt whatever the manager already has. Sessions.OnClosed only fires for fights that
	-- close AFTER this window exists, so without this the window would sit empty for anything
	-- already in the ring -- which is exactly the state a /plugins refresh mid-session leaves.
	self.selectedSession = Sessions.selected or Sessions.list[1]

	local saved = _G.settings.windows[self.windowKey]
	if saved ~= nil and saved.width ~= nil and saved.height ~= nil then
		self:Resize(saved.width, saved.height)
	end

	-- SelectView before Layout: it only needs self.viewTab/self.filter (already set above) and
	-- tolerates self.graph not existing yet (Layout's LayoutGraph creates it). Layout runs last
	-- so its own trailing RefreshContent() is the one that sees real, non-zero widths.
	self:SelectView("done", true)
	self:Layout()

	local window = self
	Sessions.OnClosed(function(s) window:OnSessionsChanged(s) end)

	self:SetVisible(false)
end

function Analysis:OnSessionsChanged(newSession)
	if self.selectedSession == nil then
		self.selectedSession = newSession
		self:ResetRange()
	end
	self:RefreshRail()
	if self.selectedSession == newSession then
		self:RefreshContent()
	end
end

---------------------------------------------------------------------------------------------------
-- Header extras: the range chip and RESET RANGE
---------------------------------------------------------------------------------------------------

-- Both live in Frame's own header bar, to the left of the close glyph. The chip states what the
-- window is currently showing, which matters most exactly when it is NOT showing the whole fight
-- -- an unnoticed range would make every number on screen quietly wrong to a reader who looked
-- away and back.
function Analysis:BuildHeaderExtras()
	self.rangeChip = Turbine.UI.Label()
	self.rangeChip:SetParent(self.header)
	self.rangeChip:SetFont(Font.LucidaConsole12)
	self.rangeChip:SetForeColor(Theme.Color(Theme.Hex.DimText))
	self.rangeChip:SetSize(220, HEADER_HEIGHT)
	self.rangeChip:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
	self.rangeChip:SetMouseVisible(false)

	local button = Turbine.UI.Label()
	button:SetParent(self.header)
	button:SetFont(Font.Verdana10)
	button:SetText("RESET RANGE")
	button:SetForeColor(Theme.Color(Theme.Hex.Disabled))
	button:SetSize(90, HEADER_HEIGHT)
	button:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)

	local window = self
	button.MouseClick = function()
		if not window:IsFullRange() then
			window:ResetRange()
			window:RefreshContent()
		end
	end
	button.MouseEnter = function()
		if not window:IsFullRange() then
			button:SetForeColor(Theme.Color(Theme.Hex.Accent200))
		end
	end
	button.MouseLeave = function() window:RefreshHeaderExtras() end

	self.resetButton = button

	-- The title label was sized by Frame to run the full width; pull it in so it cannot collide
	-- with the chip.
	if self.titleLabel ~= nil then
		self.titleLabel:SetSize(200, HEADER_HEIGHT)
	end

	self:LayoutHeaderExtras()
end

function Analysis:LayoutHeaderExtras()
	local width = select(1, self:GetSize())
	self.resetButton:SetPosition(width - 22 - 96, 0)
	self.rangeChip:SetPosition(width - 22 - 96 - 6 - 220, 0)
end

function Analysis:RefreshHeaderExtras()
	local full = self:IsFullRange()
	local session = self.selectedSession

	if session == nil then
		self.rangeChip:SetText("")
	elseif full then
		self.rangeChip:SetText("FULL FIGHT · " .. Format.Clock(session:Duration()))
	else
		local fromSec, toSec = self:RangeSeconds()
		self.rangeChip:SetText("RANGE " .. Format.Clock(fromSec) .. " - " .. Format.Clock(toSec)
			.. " · " .. math.floor(toSec - fromSec + 0.5) .. "s")
	end

	self.rangeChip:SetForeColor(Theme.Color(full and Theme.Hex.DimText or Theme.Hex.Accent300))
	self.resetButton:SetForeColor(Theme.Color(full and Theme.Hex.Disabled or Theme.Hex.Accent200))
end

-- Chrome resize plus the two header widgets Frame knows nothing about.
function Analysis:Resize(width, height)
	Frame.Resize(self, width, height)
	if self.titleLabel ~= nil then
		self.titleLabel:SetSize(200, HEADER_HEIGHT)
	end
	if self.resetButton ~= nil then
		self:LayoutHeaderExtras()
	end
end

-- Back to the shipped size and position, for /reck reset.
function Analysis:ResetGeometry()
	self:Resize(MIN_WIDTH, DEFAULT_HEIGHT)
	self:SetPosition(200, 200)
	self:Layout()
end

---------------------------------------------------------------------------------------------------
-- Range
---------------------------------------------------------------------------------------------------

function Analysis:IsFullRange()
	return self.rangeFrom == 1 and self.rangeTo == self.bucketCount
end

-- Bucket stops -> real seconds into the fight. Returns nil, nil for the whole fight, which is
-- Session:Slice's signal to take its aggregate path -- so an unscoped window is provably showing
-- the same numbers it always did rather than a re-count that might disagree at the edges.
function Analysis:RangeSeconds()
	local session = self.selectedSession
	if session == nil or self:IsFullRange() then
		return nil, nil
	end

	local duration = session:Duration()
	if duration <= 0 then
		return nil, nil
	end

	local span = self.bucketCount - 1
	local fromSec = math.floor((self.rangeFrom - 1) / span * duration)
	local toSec = math.ceil((self.rangeTo - 1) / span * duration)
	if toSec <= fromSec then
		toSec = fromSec + 1
	end
	return fromSec, toSec
end

function Analysis:ResetRange()
	self.rangeFrom = 1
	self.rangeTo = self.bucketCount
	if self.graph ~= nil then
		self.graph:SetRange(self.rangeFrom, self.rangeTo)
	end
end

function Analysis:OnRangeChanged(from, to)
	self.rangeFrom = from
	self.rangeTo = to
	self:RefreshContent()
end

---------------------------------------------------------------------------------------------------
-- Session rail
---------------------------------------------------------------------------------------------------

function Analysis:BuildSessionRail()
	self.rail = Turbine.UI.Control()
	self.rail:SetParent(self.client)
	self.rail:SetPosition(0, 0)
	self.rail:SetBackColor(Theme.Color(Theme.Hex.RailFill))
	self.rail:SetMouseVisible(false)

	self.railBorder = Turbine.UI.Control()
	self.railBorder:SetParent(self.client)
	self.railBorder:SetBackColor(Theme.Color(Theme.Hex.Border))
	self.railBorder:SetMouseVisible(false)

	self.railRows = {}
	for i = 1, RAIL_POOL do
		self.railRows[i] = self:BuildSessionRow()
	end

	self:RefreshRail()
end

function Analysis:BuildSessionRow()
	local row = Turbine.UI.Control()
	row:SetParent(self.rail)
	row:SetSize(RAIL_WIDTH, RAIL_ROW_HEIGHT)
	row:SetBackColor(Theme.Color(Theme.Hex.RailFill))
	row:SetVisible(false)

	local leftBorder = Turbine.UI.Control()
	leftBorder:SetParent(row)
	leftBorder:SetPosition(0, 0)
	leftBorder:SetSize(0, RAIL_ROW_HEIGHT)
	leftBorder:SetMouseVisible(false)

	-- Pin glyph: a small filled square, not a text glyph -- the Unicode diamonds (U+25C6/25C7)
	-- the mockup uses aren't in this client's fonts and render as "?". A filled rectangle is
	-- also literally what docs/DESIGN.md says every mark in this design is, absent an icon.
	local pin = Turbine.UI.Control()
	pin:SetParent(row)
	pin:SetPosition(9, 12)
	pin:SetSize(8, 8)
	pin:SetMouseVisible(true)

	local name = Turbine.UI.Label()
	name:SetParent(row)
	name:SetFont(Font.Verdana12)
	name:SetForeColor(Theme.Color(Theme.Hex.Text))
	name:SetPosition(24, 2)
	name:SetSize(RAIL_WIDTH - 32, 16)
	name:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	name:SetMouseVisible(false)

	local meta = Turbine.UI.Label()
	meta:SetParent(row)
	meta:SetFont(Font.LucidaConsole12)
	meta:SetForeColor(Theme.Color(Theme.Hex.DimText))
	meta:SetPosition(24, 18)
	meta:SetSize(RAIL_WIDTH - 32, 14)
	meta:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	meta:SetMouseVisible(false)

	local widgets = { control = row, leftBorder = leftBorder, pin = pin, name = name, meta = meta, session = nil }

	local window = self
	row.MouseClick = function() window:SelectSession(widgets.session) end
	row.MouseEnter = function()
		if widgets.session ~= window.selectedSession then
			row:SetBackColor(Theme.Mix(Theme.Hex.Accent, Theme.Hex.RailFill, 0.05))
		end
	end
	row.MouseLeave = function() window:RefreshRailRow(widgets) end
	pin.MouseClick = function()
		if widgets.session ~= nil then
			Sessions.TogglePin(widgets.session)
			window:RefreshRail()
		end
	end

	return widgets
end

function Analysis:SortedSessions()
	local pinned, normal = {}, {}
	for i = 1, table.getn(Sessions.list) do
		local s = Sessions.list[i]
		if s.pinned then
			table.insert(pinned, s)
		else
			table.insert(normal, s)
		end
	end
	for i = 1, table.getn(normal) do
		table.insert(pinned, normal[i])
	end
	return pinned
end

function Analysis:RefreshRail()
	local sessions = self:SortedSessions()

	for i = 1, RAIL_POOL do
		local widgets = self.railRows[i]
		local s = sessions[i]
		widgets.session = s

		if s == nil then
			widgets.control:SetVisible(false)
		else
			widgets.control:SetVisible(true)
			widgets.control:SetPosition(0, (i - 1) * RAIL_ROW_HEIGHT)
			widgets.name:SetText(s:DisplayName() .. (s.died and " · died" or ""))
			widgets.meta:SetText(s.startClock .. " · " .. Format.Clock(s:Duration()) .. " · " .. Format.Rate(s:Rate("done")))
			widgets.pin:SetBackColor(Theme.Color(s.pinned and Theme.Hex.Accent or Theme.Hex.Disabled))
			self:RefreshRailRow(widgets)
		end
	end
end

function Analysis:RefreshRailRow(widgets)
	local s = widgets.session
	if s == nil then
		return
	end
	local selected = (s == self.selectedSession)

	widgets.control:SetBackColor(selected and Theme.Mix(Theme.Hex.Accent, Theme.Hex.RailFill, 0.11) or Theme.Color(Theme.Hex.RailFill))
	if selected then
		widgets.leftBorder:SetBackColor(Theme.Color(Theme.Hex.Accent))
		widgets.leftBorder:SetSize(2, RAIL_ROW_HEIGHT)
	elseif s.pinned then
		widgets.leftBorder:SetBackColor(Theme.Color(Theme.Hex.Accent700))
		widgets.leftBorder:SetSize(2, RAIL_ROW_HEIGHT)
	else
		widgets.leftBorder:SetSize(0, RAIL_ROW_HEIGHT)
	end
end

-- Selecting a session always resets the range to the full fight: the bucket COUNT is the same
-- for every session but the seconds behind each stop are not, so carrying a range across would
-- silently mean a different slice of a different fight.
function Analysis:SelectSession(session)
	if session == nil then
		return
	end
	self.selectedSession = session
	self:ResetRange()
	self:RefreshRail()
	self:RefreshContent()
end

---------------------------------------------------------------------------------------------------
-- Content area: tab strip, goal line, picker, KPI row, graph, table, buff section, side panels
---------------------------------------------------------------------------------------------------

function Analysis:BuildContentArea()
	self.contentArea = Turbine.UI.Control()
	self.contentArea:SetParent(self.client)
	self.contentArea:SetMouseVisible(false)

	self:BuildTabStrip()
	self:BuildGoalLine()
	self:BuildPicker()
	self:BuildKpiRow()
	self:BuildGraphArea()
	self:BuildTable()
	self:BuildBuffSection()
	self:BuildPanels()
end

function Analysis:BuildTabStrip()
	self.viewTabs = {}
	local x = PAD
	local window = self

	for i = 1, table.getn(VIEWS) do
		local key = VIEWS[i]
		local meta = VIEW_META[key]

		local tab = Turbine.UI.Control()
		tab:SetParent(self.contentArea)
		tab:SetPosition(x, 0)
		tab:SetSize(TAB_WIDTH, TAB_STRIP_HEIGHT)
		tab:SetBackColor(Theme.Color(Theme.Hex.WindowFill))

		-- Centred in its cell, not flush left: four equal 140px cells read as a tab strip only
		-- when their labels are centred in them.
		local label = Turbine.UI.Label()
		label:SetParent(tab)
		label:SetFont(Font.Verdana12)
		label:SetText(meta.label)
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetPosition(0, 0)
		label:SetSize(TAB_WIDTH, TAB_STRIP_HEIGHT - 2)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
		label:SetMouseVisible(false)

		local underline = Turbine.UI.Control()
		underline:SetParent(tab)
		underline:SetPosition(0, TAB_STRIP_HEIGHT - 2)
		underline:SetSize(TAB_WIDTH, 2)
		underline:SetMouseVisible(false)

		tab.MouseClick = function() window:SelectView(key) end
		tab.MouseEnter = function()
			if window.viewTab ~= key then
				tab:SetBackColor(Theme.Color(Theme.Hex.Hover))
			end
		end
		tab.MouseLeave = function()
			if window.viewTab ~= key then
				tab:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
			end
		end

		self.viewTabs[key] = { control = tab, label = label, underline = underline }
		x = x + TAB_WIDTH
	end
end

-- The goal line shares the tab strip's row now, right-aligned in whatever the tabs leave over,
-- with a 1px rule under it that continues the inactive tabs' baseline across to the window edge.
function Analysis:BuildGoalLine()
	self.goalLine = Turbine.UI.Label()
	self.goalLine:SetParent(self.contentArea)
	self.goalLine:SetFont(Font.Verdana10)
	self.goalLine:SetForeColor(Theme.Color(Theme.Hex.DimText))
	self.goalLine:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
	self.goalLine:SetMouseVisible(false)

	self.goalRule = Turbine.UI.Control()
	self.goalRule:SetParent(self.contentArea)
	self.goalRule:SetBackColor(Theme.Color(Theme.Hex.Border))
	self.goalRule:SetMouseVisible(false)
end

-- Picker chips are rebuilt on session/view change (a handful of controls, not a hot path) since
-- the distinct-name set differs per session and view. Width is a rough per-character estimate --
-- Turbine.UI exposes no text-measurement call used anywhere in this codebase.
--
-- The chip set is deliberately SESSION-wide, not range-scoped: a chip vanishing mid-drag because
-- that target happened not to be hit inside the current range would be the opposite of useful.
function Analysis:BuildPicker()
	self.pickerRow = Turbine.UI.Control()
	self.pickerRow:SetParent(self.contentArea)
	self.pickerRow:SetMouseVisible(false)
	self.pickerChips = {}
end

local function ChipWidth(text)
	return 16 + string.len(text) * 7
end

function Analysis:RefreshPicker()
	for i = 1, table.getn(self.pickerChips) do
		self.pickerChips[i].control:SetVisible(false)
	end

	local session = self.selectedSession
	if session == nil then
		return
	end

	local meta = VIEW_META[self.viewTab]
	local names = {}
	local totals = {}
	for _, row in pairs(session.agg[self.viewTab]) do
		if not totals[row.who] then
			table.insert(names, row.who)
		end
		totals[row.who] = (totals[row.who] or 0) + row.total
	end
	table.sort(names, function(a, b) return totals[a] > totals[b] end)

	-- Built with direct indexing, not table.insert -- `values[1]` is a deliberate nil (the "All
	-- X" chip's filter value), and table.insert(t, v) on a table whose length is ambiguous
	-- because of a leading nil hole silently overwrites that slot instead of appending after
	-- it (confirmed live: it shifted every chip's filter value one position off from its
	-- label, so clicking a chip filtered by a *different* target than the one shown).
	local labels = { "All " .. meta.pickerLabel }
	local values = {}
	for i = 1, table.getn(names) do
		labels[i + 1] = names[i]
		values[i + 1] = names[i]
	end

	local x = 0
	for i = 1, table.getn(labels) do
		local chip = self.pickerChips[i]
		if chip == nil then
			chip = self:BuildPickerChip()
			self.pickerChips[i] = chip
		end

		local text = labels[i]
		local w = ChipWidth(text)
		chip.control:SetPosition(x, 0)
		chip.control:SetSize(w, PICKER_HEIGHT)
		chip.border:SetSize(w, PICKER_HEIGHT)
		chip.label:SetSize(w, PICKER_HEIGHT)
		chip.label:SetText(text)
		chip.value = values[i]
		chip.control:SetVisible(true)

		x = x + w + 6
	end

	self:RefreshPickerSelection()
end

function Analysis:BuildPickerChip()
	local control = Turbine.UI.Control()
	control:SetParent(self.pickerRow)

	local border = Turbine.UI.Control()
	border:SetParent(control)
	border:SetPosition(0, 0)
	border:SetBackColor(Theme.Color(Theme.Hex.Border))
	border:SetMouseVisible(false)

	-- Fills the 1px-inset interior; also doubles as the selected/hover tint target (a
	-- precomputed blend, not SetOpacity -- see Theme.Mix).
	local inset = Turbine.UI.Control()
	inset:SetParent(control)
	inset:SetPosition(1, 1)
	inset:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	inset:SetMouseVisible(false)

	local label = Turbine.UI.Label()
	label:SetParent(control)
	label:SetFont(Font.Verdana10)
	label:SetForeColor(Theme.Color(Theme.Hex.DimText))
	label:SetPosition(0, 0)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	label:SetMouseVisible(false)

	local chip = { control = control, border = border, inset = inset, label = label, value = nil }

	local window = self
	control.MouseClick = function() window:SelectFilter(chip.value) end
	control.MouseEnter = function()
		if window.filter[window.viewTab] ~= chip.value then
			inset:SetBackColor(Theme.Color(Theme.Hex.Hover))
		end
	end
	control.MouseLeave = function() window:RefreshPickerSelection() end

	return chip
end

function Analysis:RefreshPickerSelection()
	local selected = self.filter[self.viewTab]
	for i = 1, table.getn(self.pickerChips) do
		local chip = self.pickerChips[i]
		if chip.control:IsVisible() then
			local isSelected = (chip.value == selected)
			chip.inset:SetBackColor(Theme.Color(isSelected and Theme.Hex.ActiveTab or Theme.Hex.WindowFill))
			chip.border:SetBackColor(Theme.Color(isSelected and Theme.Hex.Accent700 or Theme.Hex.Border))
			chip.label:SetForeColor(Theme.Color(isSelected and Theme.Hex.Accent200 or Theme.Hex.DimText))

			local w, h = chip.control:GetSize()
			chip.inset:SetSize(w - 2, h - 2)
		end
	end
end

function Analysis:SelectFilter(who)
	self.filter[self.viewTab] = who
	self:RefreshPickerSelection()
	self:RefreshContent()
end

---------------------------------------------------------------------------------------------------
-- KPI cards
---------------------------------------------------------------------------------------------------

function Analysis:BuildKpiRow()
	self.kpiRow = Turbine.UI.Control()
	self.kpiRow:SetParent(self.contentArea)
	self.kpiRow:SetMouseVisible(false)

	self.kpiCards = {}
	for i = 1, 5 do
		self.kpiCards[i] = self:BuildKpiCard()
	end
end

-- Card content stacks label 12 / value 20 / sub 12 inside 50px with 4px of top padding. The old
-- card put the value at y=18 with height 24 and the sub at y=36 -- a 6px collision that clipped
-- the bottom of every value against the top of its own sub-label.
function Analysis:BuildKpiCard()
	local card = Turbine.UI.Control()
	card:SetParent(self.kpiRow)
	card:SetBackColor(Theme.Color(Theme.Hex.KpiFill))
	card:SetMouseVisible(false)

	local border = Turbine.UI.Control()
	border:SetParent(card)
	border:SetPosition(0, 0)
	border:SetBackColor(Theme.Color(Theme.Hex.Border))
	border:SetMouseVisible(false)

	local label = Turbine.UI.Label()
	label:SetParent(card)
	label:SetFont(Font.Verdana10)
	label:SetForeColor(Theme.Color(Theme.Hex.DimText))
	label:SetPosition(8, 4)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	label:SetMouseVisible(false)

	local value = Turbine.UI.Label()
	value:SetParent(card)
	value:SetFont(Font.Verdana20)
	value:SetForeColor(Theme.Color(Theme.Hex.Text))
	value:SetPosition(8, 16)
	value:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	value:SetMouseVisible(false)

	local sub = Turbine.UI.Label()
	sub:SetParent(card)
	sub:SetFont(Font.Verdana10)
	sub:SetPosition(8, 36)
	sub:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	sub:SetMouseVisible(false)

	return { control = card, border = border, label = label, value = value, sub = sub }
end

---------------------------------------------------------------------------------------------------
-- Graph area
---------------------------------------------------------------------------------------------------

function Analysis:BuildGraphArea()
	self.graphHolder = Turbine.UI.Control()
	self.graphHolder:SetParent(self.contentArea)
	self.graphHolder:SetMouseVisible(false)
end

---------------------------------------------------------------------------------------------------
-- Search boxes -- shared shape for the skill table and the buff table below; the pattern (border
-- + inset + TextBox + placeholder Label + clear glyph) matches LootLogs' own sidebar search
-- (Turbine.UI.TextBox, TextChanged/FocusGained/FocusLost, SetText not firing TextChanged so a
-- clear button has to update the filter itself) -- the only confirmed-working TextBox precedent
-- anywhere in this environment's installed plugins.
---------------------------------------------------------------------------------------------------

function Analysis:BuildSearchBox(parent, placeholderText)
	local control = Turbine.UI.Control()
	control:SetParent(parent)
	control:SetPosition(0, 0)
	control:SetSize(SEARCH_WIDTH, SEARCH_HEIGHT)
	control:SetBackColor(Theme.Color(Theme.Hex.Border))

	local inset = Turbine.UI.Control()
	inset:SetParent(control)
	inset:SetPosition(1, 1)
	inset:SetSize(SEARCH_WIDTH - 2, SEARCH_HEIGHT - 2)
	inset:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	inset:SetMouseVisible(false)

	local fieldWidth = SEARCH_WIDTH - 2 - 6 - 18

	local textbox = Turbine.UI.TextBox()
	textbox:SetParent(inset)
	textbox:SetPosition(6, 0)
	textbox:SetSize(fieldWidth, SEARCH_HEIGHT - 2)
	textbox:SetMultiline(false)
	textbox:SetFont(Font.Verdana10)
	textbox:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	textbox:SetForeColor(Theme.Color(Theme.Hex.Text))
	textbox:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	textbox:SetText("")

	-- A real placeholder Label, not seeded prompt text left in the field -- matching LootLogs'
	-- own comment on why (a seeded value would have to be filtered back out of every search).
	local placeholder = Turbine.UI.Label()
	placeholder:SetParent(inset)
	placeholder:SetPosition(8, 0)
	placeholder:SetSize(fieldWidth, SEARCH_HEIGHT - 2)
	placeholder:SetFont(Font.Verdana10)
	placeholder:SetForeColor(Theme.Color(Theme.Hex.DimText))
	placeholder:SetText(placeholderText)
	placeholder:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	placeholder:SetMouseVisible(false)

	local clear = Turbine.UI.Label()
	clear:SetParent(control)
	clear:SetPosition(SEARCH_WIDTH - 2 - 16, 1)
	clear:SetSize(16, SEARCH_HEIGHT - 2)
	clear:SetFont(Font.Verdana10)
	clear:SetText("x")
	clear:SetForeColor(Theme.Color(Theme.Hex.DimText))
	clear:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	clear:SetVisible(false)
	clear.MouseEnter = function() clear:SetForeColor(Theme.Color(Theme.Hex.Accent200)) end
	clear.MouseLeave = function() clear:SetForeColor(Theme.Color(Theme.Hex.DimText)) end

	return { control = control, textbox = textbox, placeholder = placeholder, clear = clear, focused = false }
end

-- Placeholder shows only while empty and unfocused; the clear glyph only while there's something
-- to clear. Called after every text/focus change on either search box.
function Analysis:RefreshSearchBox(widgets)
	local filtering = widgets.textbox:GetText() ~= ""
	widgets.placeholder:SetVisible(not filtering and not widgets.focused)
	widgets.clear:SetVisible(filtering)
end

---------------------------------------------------------------------------------------------------
-- Skill table
---------------------------------------------------------------------------------------------------

function Analysis:BuildTable()
	self.tableHolder = Turbine.UI.Control()
	self.tableHolder:SetParent(self.contentArea)
	self.tableHolder:SetMouseVisible(false)

	self.tableSearch = self:BuildSearchBox(self.tableHolder, "Search skills...")
	local window = self
	self.tableSearch.textbox.TextChanged = function()
		window.tableFilterText = window.tableSearch.textbox:GetText()
		window:RefreshSearchBox(window.tableSearch)
		window:RefreshContent()
	end
	self.tableSearch.textbox.FocusGained = function()
		window.tableSearch.focused = true
		window:RefreshSearchBox(window.tableSearch)
	end
	self.tableSearch.textbox.FocusLost = function()
		window.tableSearch.focused = false
		window:RefreshSearchBox(window.tableSearch)
	end
	self.tableSearch.clear.MouseClick = function()
		window.tableSearch.textbox:SetText("")
		window.tableFilterText = ""
		window:RefreshSearchBox(window.tableSearch)
		window:RefreshContent()
	end

	self.tableHeaderRow = Turbine.UI.Control()
	self.tableHeaderRow:SetParent(self.tableHolder)
	self.tableHeaderRow:SetPosition(0, SEARCH_HEIGHT)
	self.tableHeaderRow:SetSize(1, ROW_HEIGHT)
	self.tableHeaderRow:SetBackColor(Theme.Color(Theme.Hex.HeaderFill))
	self.tableHeaderRow:SetMouseVisible(false)

	self.tableHeaderLabels = {}
	for i = 1, MAX_TABLE_COLUMNS do
		local label = Turbine.UI.Label()
		label:SetParent(self.tableHeaderRow)
		label:SetFont(Font.Verdana10)
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetSize(0, ROW_HEIGHT)
		label:SetVisible(false)
		label:SetMouseVisible(false)
		self.tableHeaderLabels[i] = label
	end

	-- Turbine.UI has no ScrollView -- the real pattern (confirmed against LootLogs, a real
	-- distributed plugin) is a ListBox as the scrolling host plus a separate Lotro.ScrollBar
	-- wired to it. Items are Controls added via AddItem, not manually positioned/parented.
	self.scrollView = Turbine.UI.ListBox()
	self.scrollView:SetParent(self.tableHolder)
	self.scrollView:SetPosition(0, SEARCH_HEIGHT + ROW_HEIGHT)
	self.scrollView:SetBackColor(Theme.Color(Theme.Hex.WindowFill))

	self.tableScrollBar = Turbine.UI.Lotro.ScrollBar()
	self.tableScrollBar:SetParent(self.tableHolder)
	self.tableScrollBar:SetOrientation(Turbine.UI.Orientation.Vertical)
	self.tableScrollBar:SetWidth(SCROLLBAR_WIDTH)
	self.scrollView:SetVerticalScrollBar(self.tableScrollBar)

	self.tableRowPool = {}
	for i = 1, 30 do
		self.tableRowPool[i] = self:BuildTableRowSlot()
	end
end

-- Not parented here -- AddItem (called from RefreshTable, every data refresh) does that. A row
-- never sits in the ListBox until it actually has data for the current view/filter/range.
function Analysis:BuildTableRowSlot()
	local container = Turbine.UI.Control()
	container:SetSize(1, ROW_HEIGHT)

	local divider = Turbine.UI.Control()
	divider:SetParent(container)
	divider:SetPosition(0, ROW_HEIGHT - 1)
	divider:SetSize(1, 1)
	divider:SetBackColor(Theme.Color(Theme.Hex.RowBorder))
	divider:SetMouseVisible(false)

	-- Colour is set per-view in RefreshTableColumns (Theme.Mix'd to an 8% tint there, since
	-- SetOpacity does not blend -- see Theme.Mix's comment); only width changes per refresh.
	local shareBar = Turbine.UI.Control()
	shareBar:SetParent(container)
	shareBar:SetPosition(0, 0)
	shareBar:SetSize(0, ROW_HEIGHT - 1)
	shareBar:SetMouseVisible(false)

	local row = nil -- built lazily once column geometry is known, see RefreshTableColumns

	return { container = container, divider = divider, shareBar = shareBar, row = row }
end

-- Header text for a column, given the active view. Only three of them vary.
local function ColumnLabel(column, meta)
	if column.key == "type" then
		return meta.counterpartHeader
	elseif column.key == "hits" then
		return string.upper(meta.hitWord)
	end
	return column.label
end

-- (Re)builds the header labels and the pooled rows' column geometry for the active view. Called
-- on view change and on resize -- not per data refresh.
function Analysis:RefreshTableColumns(tableWidth)
	local meta = VIEW_META[self.viewTab]
	local spec = COLUMN_SETS[meta.shape]

	local fixedTotal = 0
	for i = 1, table.getn(spec) do
		fixedTotal = fixedTotal + (spec[i].width or 0)
	end

	local flexWidth = tableWidth - fixedTotal
	if flexWidth < SKILL_COLUMN_MIN then
		flexWidth = SKILL_COLUMN_MIN
	end

	local columns = {}
	local x = 0
	for i = 1, table.getn(spec) do
		local column = spec[i]
		local width = column.width or flexWidth
		local colorHex = Theme.Hex.MutedText
		if column.key == "skill" then
			colorHex = Theme.Hex.Text
		elseif column.accent then
			colorHex = meta.color
		end

		columns[i] = {
			x = x, width = width,
			font = column.numeric and Font.LucidaConsole12 or Font.Verdana12,
			align = column.numeric and Turbine.UI.ContentAlignment.MiddleRight or Turbine.UI.ContentAlignment.MiddleLeft,
			colorHex = colorHex,
		}
		x = x + width
	end

	self.tableColumns = columns
	self.tableWidth = x

	for i = 1, MAX_TABLE_COLUMNS do
		local label = self.tableHeaderLabels[i]
		local column = spec[i]
		if column == nil then
			label:SetVisible(false)
		else
			local col = columns[i]
			-- 8px cell padding on both sides, so a right-aligned header sits directly over the
			-- right-aligned number underneath it.
			label:SetPosition(col.x + 8, 0)
			label:SetSize(math.max(0, col.width - 16), ROW_HEIGHT)
			label:SetText(ColumnLabel(column, meta))
			label:SetTextAlignment(col.align)
			label:SetVisible(true)
		end
	end
	self.tableHeaderRow:SetSize(x, ROW_HEIGHT)

	-- The same 8px padding on the cells themselves.
	local padded = {}
	for i = 1, table.getn(columns) do
		padded[i] = {
			x = columns[i].x + 8, width = math.max(0, columns[i].width - 16),
			font = columns[i].font, align = columns[i].align, colorHex = columns[i].colorHex,
		}
	end

	for i = 1, table.getn(self.tableRowPool) do
		local slot = self.tableRowPool[i]
		slot.container:SetSize(x, ROW_HEIGHT)
		slot.divider:SetSize(x, 1)
		slot.shareBar:SetBackColor(Theme.Mix(meta.color, Theme.Hex.WindowFill, 0.08))

		if slot.row == nil then
			slot.row = Row(x, ROW_HEIGHT, padded)
			slot.row:SetParent(slot.container)
			slot.row:SetPosition(0, 0)
		else
			slot.row:Reconfigure(x, padded)
		end
	end
end

-- Damage views group across counterparts by skill+type; heal views keep one row per
-- skill+counterpart, since "who healed you" is the interesting axis there. `rows` is whatever
-- Session:Slice returned for the current category/range/filter, so this is the same code path
-- whether or not a range is active.
function Analysis:TableRows(rows, view)
	local meta = VIEW_META[view]

	if meta.shape == "heal" then
		local list = {}
		for i = 1, table.getn(rows) do
			list[i] = rows[i]
		end
		table.sort(list, function(a, b) return a.total > b.total end)
		return list
	end

	local grouped = {}
	local order = {}
	for i = 1, table.getn(rows) do
		local row = rows[i]
		local key = row.skill .. "\1" .. row.type
		local g = grouped[key]
		if g == nil then
			g = { skill = row.skill, type = row.type, hits = 0, total = 0, max = 0, crits = 0, devs = 0, avoided = 0 }
			grouped[key] = g
			table.insert(order, g)
		end
		g.hits = g.hits + row.hits
		g.total = g.total + row.total
		g.crits = g.crits + row.crits
		g.devs = g.devs + row.devs
		g.avoided = g.avoided + (row.avoided or 0)
		if row.max > g.max then
			g.max = row.max
		end
	end
	table.sort(order, function(a, b) return a.total > b.total end)
	return order
end

local function CritDevText(row)
	if row.hits <= 0 then
		return "0% / 0%"
	end
	return Format.Percent(row.crits / row.hits) .. " / " .. Format.Percent(row.devs / row.hits)
end

function Analysis:RowValues(view, row)
	local meta = VIEW_META[view]

	if meta.shape == "heal" then
		return {
			row.skill, row.who, Format.Number(row.hits), CritDevText(row),
			Format.Number(row.max), Format.Number(row.total),
		}
	end

	local swings = row.hits + (row.avoided or 0)
	local avoidedPct = swings > 0 and Format.Percent((row.avoided or 0) / swings) or "0%"
	return {
		row.skill, DamageType.Names[row.type] or "?", Format.Number(row.hits), CritDevText(row),
		avoidedPct, Format.Number(row.max), Format.Number(row.total),
	}
end

-- Matches the search text against the skill name plus whichever counterpart column the active
-- view shows (type for damage views, who for heal views), so "regen" finds a heal named that and
-- "orc" finds anything sourced from an orc, not only a skill literally named "orc".
function Analysis:FilterTableRows(list)
	local query = self.tableFilterText
	if query == nil or query == "" then
		return list
	end

	local filtered = {}
	for i = 1, table.getn(list) do
		local row = list[i]
		local haystack = row.skill or ""
		if row.who ~= nil then
			haystack = haystack .. " " .. row.who
		elseif row.type ~= nil then
			haystack = haystack .. " " .. (DamageType.Names[row.type] or "")
		end
		if MatchesFilter(haystack, query) then
			table.insert(filtered, row)
		end
	end
	return filtered
end

function Analysis:RefreshTable(rows)
	local view = self.viewTab
	local list = self:TableRows(rows, view)
	list = self:FilterTableRows(list)

	local maxTotal = 0
	for i = 1, table.getn(list) do
		if list[i].total > maxTotal then
			maxTotal = list[i].total
		end
	end

	-- ListBox is item-list based, not freeform positioning: clear and re-add each refresh, but
	-- reuse the same pooled container/Row/shareBar objects every time -- only the ListBox's
	-- membership list is rebuilt, never the Controls themselves.
	self.scrollView:ClearItems()

	local n = table.getn(list)
	local poolSize = table.getn(self.tableRowPool)
	if n > poolSize then
		n = poolSize
	end

	for i = 1, n do
		local slot = self.tableRowPool[i]
		local row = list[i]

		slot.row:SetValues(self:RowValues(view, row))
		local share = (maxTotal > 0) and (row.total / maxTotal) or 0
		slot.shareBar:SetSize(math.floor(self.tableWidth * share), ROW_HEIGHT - 1)

		self.scrollView:AddItem(slot.container)
	end
end

---------------------------------------------------------------------------------------------------
-- Self-buff section
---------------------------------------------------------------------------------------------------

function Analysis:BuildBuffSection()
	self.buffHolder = Turbine.UI.Control()
	self.buffHolder:SetParent(self.contentArea)
	self.buffHolder:SetMouseVisible(false)

	self.buffTopRule = Turbine.UI.Control()
	self.buffTopRule:SetParent(self.buffHolder)
	self.buffTopRule:SetPosition(0, 0)
	self.buffTopRule:SetSize(1, 1)
	self.buffTopRule:SetBackColor(Theme.Color(Theme.Hex.Border))
	self.buffTopRule:SetMouseVisible(false)

	local header = Turbine.UI.Control()
	header:SetParent(self.buffHolder)
	header:SetPosition(0, 1)
	header:SetSize(1, BUFF_HEADER_HEIGHT)
	header:SetBackColor(Theme.Color(Theme.Hex.WindowFill))

	-- ASCII caret, not the mock's Unicode triangles (U+25BE/25B8): the same class of glyph the
	-- session-rail pins had to give up on, since this client's fonts render them as "?".
	local caret = Turbine.UI.Label()
	caret:SetParent(header)
	caret:SetFont(Font.Verdana10)
	caret:SetForeColor(Theme.Color(Theme.Hex.Accent))
	caret:SetPosition(0, 0)
	caret:SetSize(14, BUFF_HEADER_HEIGHT)
	caret:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	caret:SetMouseVisible(false)

	local title = Turbine.UI.Label()
	title:SetParent(header)
	title:SetFont(Font.Verdana10)
	title:SetText("SELF BUFFS")
	title:SetForeColor(Theme.Color(Theme.Hex.MutedText))
	title:SetPosition(16, 0)
	title:SetSize(80, BUFF_HEADER_HEIGHT)
	title:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	title:SetMouseVisible(false)

	local summary = Turbine.UI.Label()
	summary:SetParent(header)
	summary:SetFont(Font.Verdana10)
	summary:SetForeColor(Theme.Color(Theme.Hex.DimText))
	summary:SetPosition(100, 0)
	summary:SetSize(1, BUFF_HEADER_HEIGHT)
	summary:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	summary:SetMouseVisible(false)

	local window = self
	header.MouseClick = function() window:ToggleBuffSection() end
	header.MouseEnter = function()
		header:SetBackColor(Theme.Color(Theme.Hex.Hover))
		title:SetForeColor(Theme.Color(Theme.Hex.Accent200))
	end
	header.MouseLeave = function()
		header:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
		title:SetForeColor(Theme.Color(Theme.Hex.MutedText))
	end

	self.buffHeader = { control = header, caret = caret, title = title, summary = summary }

	self.buffSearch = self:BuildSearchBox(self.buffHolder, "Search buffs...")
	self.buffSearch.control:SetPosition(0, BUFF_HEADER_HEIGHT + 1)
	self.buffSearch.textbox.TextChanged = function()
		window.buffFilterText = window.buffSearch.textbox:GetText()
		window:RefreshSearchBox(window.buffSearch)
		window:RefreshContent()
	end
	self.buffSearch.textbox.FocusGained = function()
		window.buffSearch.focused = true
		window:RefreshSearchBox(window.buffSearch)
	end
	self.buffSearch.textbox.FocusLost = function()
		window.buffSearch.focused = false
		window:RefreshSearchBox(window.buffSearch)
	end
	self.buffSearch.clear.MouseClick = function()
		window.buffSearch.textbox:SetText("")
		window.buffFilterText = ""
		window:RefreshSearchBox(window.buffSearch)
		window:RefreshContent()
	end

	self.buffTableHeader = Turbine.UI.Control()
	self.buffTableHeader:SetParent(self.buffHolder)
	self.buffTableHeader:SetSize(1, BUFF_TABLE_HEADER_HEIGHT)
	self.buffTableHeader:SetBackColor(Theme.Color(Theme.Hex.HeaderFill))
	self.buffTableHeader:SetMouseVisible(false)

	self.buffHeaderLabels = {}
	for i = 1, table.getn(BUFF_COLUMNS) do
		local column = BUFF_COLUMNS[i]
		local label = Turbine.UI.Label()
		label:SetParent(self.buffTableHeader)
		label:SetFont(Font.Verdana10)
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetText(column.label)
		label:SetSize(math.max(0, column.width - 16), BUFF_TABLE_HEADER_HEIGHT)
		label:SetTextAlignment(column.numeric and Turbine.UI.ContentAlignment.MiddleRight
			or Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)
		self.buffHeaderLabels[i] = label
	end

	-- Same ListBox + Lotro.ScrollBar host as the skill table (see BuildTable's comment) -- rows
	-- are pooled Controls added via AddItem, not manually positioned/parented, so overflow past
	-- whatever height Layout() gives the buff section scrolls instead of being silently dropped.
	self.buffScrollView = Turbine.UI.ListBox()
	self.buffScrollView:SetParent(self.buffHolder)
	self.buffScrollView:SetBackColor(Theme.Color(Theme.Hex.WindowFill))

	self.buffScrollBar = Turbine.UI.Lotro.ScrollBar()
	self.buffScrollBar:SetParent(self.buffHolder)
	self.buffScrollBar:SetOrientation(Turbine.UI.Orientation.Vertical)
	self.buffScrollBar:SetWidth(SCROLLBAR_WIDTH)
	self.buffScrollView:SetVerticalScrollBar(self.buffScrollBar)

	self.buffRows = {}
	for i = 1, BUFF_POOL do
		self.buffRows[i] = self:BuildBuffRow()
	end

	self:LayoutBuffColumns(604)
end

-- Not parented here -- AddItem (called from RefreshBuffSection, every data refresh) does that,
-- matching BuildTableRowSlot's own comment: a row never sits in the ListBox until it actually
-- has data for the current session/range.
function Analysis:BuildBuffRow()
	local container = Turbine.UI.Control()
	container:SetSize(1, BUFF_ROW_HEIGHT)

	local shareBar = Turbine.UI.Control()
	shareBar:SetParent(container)
	shareBar:SetPosition(0, 0)
	shareBar:SetSize(0, BUFF_ROW_HEIGHT - 1)
	shareBar:SetMouseVisible(false)

	local divider = Turbine.UI.Control()
	divider:SetParent(container)
	divider:SetPosition(0, BUFF_ROW_HEIGHT - 1)
	divider:SetSize(1, 1)
	divider:SetBackColor(Theme.Color(Theme.Hex.RowBorder))
	divider:SetMouseVisible(false)

	-- The charted checkbox: an 8x8 border square whose inset fills with the lane colour when
	-- this buff is charted, empty when it is not.
	local box = Turbine.UI.Control()
	box:SetParent(container)
	box:SetPosition(8, math.floor((BUFF_ROW_HEIGHT - 8) / 2))
	box:SetSize(8, 8)
	box:SetMouseVisible(false)

	local boxInset = Turbine.UI.Control()
	boxInset:SetParent(box)
	boxInset:SetPosition(1, 1)
	boxInset:SetSize(6, 6)
	boxInset:SetMouseVisible(false)

	local icon = Turbine.UI.Control()
	icon:SetParent(container)
	icon:SetPosition(22, math.floor((BUFF_ROW_HEIGHT - 16) / 2))
	icon:SetSize(16, 16)
	icon:SetMouseVisible(false)

	local iconInset = Turbine.UI.Control()
	iconInset:SetParent(icon)
	iconInset:SetPosition(1, 1)
	iconInset:SetSize(14, 14)
	iconInset:SetMouseVisible(false)
	-- Real art is applied by Icon.Apply (Constants.lua) at fill time, following Gibberish3's own
	-- timer icon element's exact call sequence -- nothing else is set here at construction.

	local iconLabel = Turbine.UI.Label()
	iconLabel:SetParent(icon)
	iconLabel:SetFont(Font.Verdana10)
	iconLabel:SetPosition(0, 0)
	iconLabel:SetSize(16, 16)
	iconLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	iconLabel:SetMouseVisible(false)

	local cells = {}
	for i = 3, table.getn(BUFF_COLUMNS) do
		local column = BUFF_COLUMNS[i]
		local label = Turbine.UI.Label()
		label:SetParent(container)
		label:SetFont(column.numeric and Font.LucidaConsole12 or Font.Verdana12)
		label:SetForeColor(Theme.Color(Theme.Hex.MutedText))
		label:SetSize(math.max(0, column.width - 16), BUFF_ROW_HEIGHT - 1)
		label:SetTextAlignment(column.numeric and Turbine.UI.ContentAlignment.MiddleRight
			or Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)
		cells[i] = label
	end

	local widgets = {
		container = container, shareBar = shareBar, divider = divider,
		box = box, boxInset = boxInset,
		icon = icon, iconInset = iconInset, iconLabel = iconLabel,
		cells = cells, name = nil,
	}

	local window = self
	container.MouseClick = function()
		if widgets.name ~= nil then
			window:ToggleCharted(widgets.name)
		end
	end
	container.MouseEnter = function()
		container:SetBackColor(Theme.Color(Theme.Hex.Hover))
	end
	container.MouseLeave = function()
		container:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	end

	return widgets
end

function Analysis:LayoutBuffColumns(width)
	-- The name column absorbs the slack when the window is wider than the mock's 604.
	local fixed = 0
	for i = 1, table.getn(BUFF_COLUMNS) do
		if BUFF_COLUMNS[i].key ~= "name" then
			fixed = fixed + BUFF_COLUMNS[i].width
		end
	end
	local nameWidth = math.max(120, width - fixed)

	local x = 0
	self.buffColumnX = {}
	for i = 1, table.getn(BUFF_COLUMNS) do
		local column = BUFF_COLUMNS[i]
		local w = (column.key == "name") and nameWidth or column.width
		self.buffColumnX[i] = { x = x, width = w }
		x = x + w
	end

	self.buffWidth = x

	for i = 1, table.getn(BUFF_COLUMNS) do
		local geo = self.buffColumnX[i]
		local label = self.buffHeaderLabels[i]
		label:SetPosition(geo.x + 8, 0)
		label:SetSize(math.max(0, geo.width - 16), BUFF_TABLE_HEADER_HEIGHT)
	end
	-- The BUFF header spans the checkbox+icon gutter as well as the name column, matching the
	-- mock's single 214px heading over the three of them.
	self.buffHeaderLabels[3]:SetPosition(self.buffColumnX[2].x + 8, 0)
	self.buffHeaderLabels[3]:SetSize(
		math.max(0, self.buffColumnX[2].width + self.buffColumnX[3].width - 16),
		BUFF_TABLE_HEADER_HEIGHT)

	self.buffTableHeader:SetSize(x, BUFF_TABLE_HEADER_HEIGHT)

	for r = 1, BUFF_POOL do
		local widgets = self.buffRows[r]
		widgets.container:SetSize(x, BUFF_ROW_HEIGHT)
		widgets.divider:SetSize(x, 1)
		for i = 3, table.getn(BUFF_COLUMNS) do
			local geo = self.buffColumnX[i]
			widgets.cells[i]:SetPosition(geo.x + 8, 0)
			widgets.cells[i]:SetSize(math.max(0, geo.width - 16), BUFF_ROW_HEIGHT - 1)
		end
	end
end

function Analysis:ToggleBuffSection()
	self.buffsOpen = not self.buffsOpen
	_G.settings.buffsOpen = self.buffsOpen
	Settings.Save()
	self:RefreshContent()
end

function Analysis:IsCharted(name)
	for i = 1, table.getn(self.charted) do
		if self.charted[i] == name then
			return i
		end
	end
	return nil
end

-- Charted buffs are capped at MAX_CHARTED because there are exactly that many lane colours, and
-- because more than three interval rails under one plot stops being readable. The fourth click
-- drops the OLDEST rather than refusing: a click that appears to do nothing reads as a bug.
function Analysis:ToggleCharted(name)
	local index = self:IsCharted(name)
	if index ~= nil then
		table.remove(self.charted, index)
	else
		table.insert(self.charted, name)
		while table.getn(self.charted) > MAX_CHARTED do
			table.remove(self.charted, 1)
		end
	end

	local names = {}
	for i = 1, table.getn(self.charted) do
		names[i] = self.charted[i]
	end
	_G.settings.chartedBuffs = names
	Settings.Save()

	self:RefreshContent()
end

-- Matches the search text against the buff's own name -- the only column that's ever a name.
function Analysis:FilterBuffStats(stats)
	local query = self.buffFilterText
	if query == nil or query == "" then
		return stats
	end

	local filtered = {}
	for i = 1, table.getn(stats) do
		if MatchesFilter(stats[i].name, query) then
			table.insert(filtered, stats[i])
		end
	end
	return filtered
end

-- `stats` is the full tracked set (drives the "N tracked" summary count); `filtered` is what the
-- search box narrowed it to and is what's actually listed. Kept separate so typing a search
-- doesn't make the summary lie about how many buffs the session tracks in total.
function Analysis:RefreshBuffSection(stats, filtered, fromSec, toSec)
	local open = self.buffsOpen
	local tracked = table.getn(stats)
	local shownCount = table.getn(filtered)

	self.buffHeader.caret:SetText(open and "v" or ">")

	local scope
	if fromSec == nil then
		scope = "full fight"
	else
		scope = Format.Clock(fromSec) .. "-" .. Format.Clock(toSec)
	end
	self.buffHeader.summary:SetText(
		"· " .. tracked .. " tracked · " .. table.getn(self.charted) .. " charted · " .. scope)

	self.buffSearch.control:SetVisible(open)
	self.buffTableHeader:SetVisible(open)
	self.buffScrollView:SetVisible(open)
	self.buffScrollBar:SetVisible(open)

	-- ListBox is item-list based, not freeform positioning: clear and re-add each refresh, but
	-- reuse the same pooled container/Row objects every time -- only the ListBox's membership
	-- list is rebuilt, never the Controls themselves (matching RefreshTable's own comment).
	self.buffScrollView:ClearItems()

	local shown = open and math.min(shownCount, BUFF_POOL) or 0
	for i = 1, shown do
		local widgets = self.buffRows[i]
		local row = filtered[i]

		widgets.name = row.name
		widgets.container:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
		self:FillBuffRow(widgets, row)

		self.buffScrollView:AddItem(widgets.container)
	end
end

function Analysis:FillBuffRow(widgets, row)
	local chartIndex = self:IsCharted(row.name)
	local laneHex = chartIndex and Theme.BuffLane[chartIndex] or nil

	widgets.shareBar:SetBackColor(Theme.Mix(laneHex or Theme.Hex.Accent, Theme.Hex.WindowFill, 0.08))
	widgets.shareBar:SetSize(
		math.floor(math.min(1, row.uptimePct) * self.buffWidth), BUFF_ROW_HEIGHT - 1)

	widgets.box:SetBackColor(Theme.Color(laneHex or Theme.Hex.Disabled))
	widgets.boxInset:SetBackColor(Theme.Color(laneHex or Theme.Hex.WindowFill))

	widgets.icon:SetBackColor(Theme.Color(laneHex or "#3a3d4e"))
	if row.icon ~= nil and row.icon ~= false then
		-- Clears whatever the initials-fallback branch left behind (a pooled row can flip
		-- between the two across refreshes) -- Icon.Apply itself never touches BackColor, and a
		-- leftover opaque one is a real, previously-confirmed way to hide the art underneath.
		-- widgets.iconInset:SetBackColor(Turbine.UI.Color(0, 0, 0, 0))
		-- No stretch, native size -- per direct instruction after stretching to a fixed tile
		-- also failed to show anything. May overflow the 14x14 slot; that's expected for now.

		Icon.Apply(widgets.iconInset, row.icon)
		widgets.iconInset:SetPosition(1, 1)
		widgets.iconLabel:SetText("")
	else
		-- widgets.iconInset:SetBackColor(Theme.Color(Theme.Hex.RailFill))
		widgets.iconInset:SetVisible(true)
		widgets.iconLabel:SetText(row.initials or "")
		widgets.iconLabel:SetForeColor(Theme.Color(laneHex or Theme.Hex.DimText))
	end

	local pctHex = Theme.Hex.Text
	if row.uptimePct >= BUFF_GOOD_UPTIME then
		pctHex = Theme.Hex.HealingDone
	elseif row.uptimePct < BUFF_POOR_UPTIME then
		pctHex = Theme.Hex.DamageSevere
	end

	local gapHex = (row.longestGap > BUFF_LONG_GAP) and Theme.Hex.DamageSevere or Theme.Hex.MutedText

	local texts = {
		[3] = row.name,
		[4] = Format.Percent(row.uptimePct),
		[5] = Format.Clock(row.uptime),
		[6] = Format.Number(row.apps),
		[7] = math.floor(row.longestGap + 0.5) .. "s",
	}
	local colors = {
		[3] = chartIndex and Theme.Hex.Accent200 or Theme.Hex.Text,
		[4] = pctHex,
		[5] = Theme.Hex.MutedText,
		[6] = Theme.Hex.MutedText,
		[7] = gapHex,
	}

	for i = 3, table.getn(BUFF_COLUMNS) do
		widgets.cells[i]:SetText(texts[i] or "")
		widgets.cells[i]:SetForeColor(Theme.Color(colors[i] or Theme.Hex.MutedText))
	end
end

-- Lane descriptors for the graph, in charted order so lane 1 always keeps lane colour 1. A
-- charted name with no stats row (a buff from a different session) is skipped rather than
-- dropped from self.charted -- reselecting the session it came from brings its lane back.
function Analysis:ChartedLanes(stats)
	local byName = {}
	for i = 1, table.getn(stats) do
		byName[stats[i].name] = stats[i]
	end

	local lanes = {}
	for i = 1, table.getn(self.charted) do
		local row = byName[self.charted[i]]
		if row ~= nil then
			lanes[table.getn(lanes) + 1] = {
				name = row.name,
				colorHex = Theme.BuffLane[i] or Theme.BuffLane[1],
				initials = row.initials,
				icon = (row.icon ~= false) and row.icon or nil,
				intervals = row.intervals,
			}
		end
	end
	return lanes
end

---------------------------------------------------------------------------------------------------
-- Side panels
---------------------------------------------------------------------------------------------------

function Analysis:BuildPanels()
	self.panelsHolder = Turbine.UI.Control()
	self.panelsHolder:SetParent(self.contentArea)
	self.panelsHolder:SetMouseVisible(false)

	self.panelA = self:BuildPanel()
	self.panelB = self:BuildPanel()
end

function Analysis:BuildPanel()
	local holder = Turbine.UI.Control()
	holder:SetParent(self.panelsHolder)
	holder:SetMouseVisible(false)

	local title = Turbine.UI.Label()
	title:SetParent(holder)
	title:SetFont(Font.Verdana10)
	title:SetForeColor(Theme.Color(Theme.Hex.DimText))
	title:SetPosition(0, 0)
	title:SetSize(200, 14)
	title:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	title:SetMouseVisible(false)

	local rows = {}
	for i = 1, 5 do
		local nameLabel = Turbine.UI.Label()
		nameLabel:SetParent(holder)
		nameLabel:SetFont(Font.Verdana10)
		nameLabel:SetForeColor(Theme.Color(Theme.Hex.Text))
		nameLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		nameLabel:SetMouseVisible(false)
		nameLabel:SetVisible(false)

		local valueLabel = Turbine.UI.Label()
		valueLabel:SetParent(holder)
		valueLabel:SetFont(Font.LucidaConsole12)
		valueLabel:SetForeColor(Theme.Color(Theme.Hex.MutedText))
		valueLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		valueLabel:SetMouseVisible(false)
		valueLabel:SetVisible(false)

		local bar = Bar(1, 3, Theme.Hex.Accent, Theme.Hex.RowBorder)
		bar:SetParent(holder)
		bar:SetVisible(false)

		rows[i] = { name = nameLabel, value = valueLabel, bar = bar }
	end

	return { holder = holder, title = title, rows = rows }
end

-- Both panels are fed from the same sliced rows as everything else, so they follow the range
-- and the picker without a second recount.
function Analysis:PanelData(rows, view, filterWho)
	local meta = VIEW_META[view]
	local isHeal = (meta.shape == "heal")

	local function totalsBy(field)
		local totals = {}
		for i = 1, table.getn(rows) do
			local row = rows[i]
			local key = (field == "type") and (DamageType.Names[row.type] or "Unknown") or row[field]
			totals[key] = (totals[key] or 0) + row.total
		end
		return totals
	end

	local function toItems(totals)
		local items = {}
		for name, value in pairs(totals) do
			table.insert(items, { name = name, value = value })
		end
		table.sort(items, function(a, b) return a.value > b.value end)
		return items
	end

	if filterWho == nil then
		local panelA = { title = string.upper(meta.pickerLabel), items = toItems(totalsBy("who")) }
		local panelB = { title = isHeal and "BY SKILL" or "BY TYPE", items = toItems(totalsBy(isHeal and "skill" or "type")) }
		return panelA, panelB
	end

	local panelA = { title = isHeal and "BY SKILL" or "BY TYPE", items = toItems(totalsBy(isHeal and "skill" or "type")) }

	if isHeal then
		local crit, normal = 0, 0
		for i = 1, table.getn(rows) do
			crit = crit + rows[i].crits + rows[i].devs
			normal = normal + (rows[i].hits - rows[i].crits - rows[i].devs)
		end
		local items = {}
		if crit > 0 then table.insert(items, { name = "Critical", value = crit }) end
		if normal > 0 then table.insert(items, { name = "Normal", value = normal }) end
		return panelA, { title = "CRIT SPLIT", items = items }
	end

	local avoidTotals = {}
	for i = 1, table.getn(rows) do
		local breakdown = rows[i].avoidBreakdown
		if breakdown ~= nil then
			for avoidType, count in pairs(breakdown) do
				local name = AVOID_NAMES[avoidType] or "Other"
				avoidTotals[name] = (avoidTotals[name] or 0) + count
			end
		end
	end
	return panelA, { title = "AVOIDANCE", items = toItems(avoidTotals) }
end

function Analysis:RefreshPanel(panel, data, colorHex)
	panel.title:SetText(data.title)

	local maxValue = 0
	for i = 1, table.getn(data.items) do
		if data.items[i].value > maxValue then
			maxValue = data.items[i].value
		end
	end

	local panelWidth = select(1, panel.holder:GetSize())

	for i = 1, 5 do
		local widgets = panel.rows[i]
		local item = data.items[i]

		if item == nil then
			widgets.name:SetVisible(false)
			widgets.value:SetVisible(false)
			widgets.bar:SetVisible(false)
		else
			local y = 16 + (i - 1) * 20
			widgets.name:SetPosition(0, y)
			widgets.name:SetSize(math.max(0, panelWidth - 70), 12)
			widgets.name:SetText(item.name)
			widgets.name:SetVisible(true)

			widgets.value:SetPosition(panelWidth - 66, y)
			widgets.value:SetSize(66, 12)
			widgets.value:SetText(Format.Number(item.value))
			widgets.value:SetVisible(true)

			widgets.bar:SetPosition(0, y + 14)
			widgets.bar.maxWidth = panelWidth
			widgets.bar:SetSize(panelWidth, 3)
			widgets.bar:SetFillColor(colorHex)
			widgets.bar:SetPercent(maxValue > 0 and (item.value / maxValue) or 0)
			widgets.bar:SetVisible(true)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- View / data refresh
---------------------------------------------------------------------------------------------------

function Analysis:SelectView(key, skipRefresh)
	self.viewTab = key

	for i = 1, table.getn(VIEWS) do
		local k = VIEWS[i]
		local t = self.viewTabs[k]
		local selected = (k == key)
		t.label:SetForeColor(Theme.Color(selected and Theme.Hex.Accent200 or Theme.Hex.DimText))
		t.underline:SetBackColor(Theme.Color(selected and Theme.Hex.Accent or Theme.Hex.Border))
		t.control:SetBackColor(Theme.Color(selected and Theme.Hex.ActiveTab or Theme.Hex.WindowFill))
	end

	self:RefreshTableColumns(self.tableListWidth or 400)

	if not skipRefresh then
		self:RefreshContent()
	end
end

-- Which series each view plots. The two "incoming" views carry both sides of the exchange, since
-- damage taken only means something next to the healing that did or didn't cover it.
local SERIES_FOR_VIEW = {
	done = { { key = "done", label = "Damage", colorHex = Theme.Hex.DamageDone } },
	healOut = { { key = "healOut", label = "Healing out", colorHex = Theme.Hex.HealingDone } },
	taken = {
		{ key = "taken", label = "Damage taken", colorHex = Theme.Hex.DamageTaken },
		{ key = "healIn", label = "Healing in", colorHex = Theme.Hex.HealingTaken },
	},
	healIn = {
		{ key = "healIn", label = "Healing in", colorHex = Theme.Hex.HealingTaken },
		{ key = "taken", label = "Damage taken", colorHex = Theme.Hex.DamageTaken },
	},
}

-- One recount per interaction. Every widget below is fed from `rows` (a single Session:Slice)
-- and `stats` (a single Buffs.Stats), never from its own separate pass over the session.
--
-- skipRelayout is set only by Layout()'s own trailing call: this function can discover that the
-- number of charted lanes or visible buff rows changed, which changes the window's block
-- geometry, and asks Layout() to run again -- but Layout() ends by calling back here, so the
-- second pass must not be allowed to bounce back.
function Analysis:RefreshContent(skipRelayout)
	local session = self.selectedSession
	local view = self.viewTab
	local filterWho = self.filter[view]
	local meta = VIEW_META[view]
	local showMorale = (view == "taken" or view == "healIn")

	self.goalLine:SetText(meta.question)
	self:RefreshPicker()
	self:RefreshHeaderExtras()

	local fromSec, toSec = self:RangeSeconds()
	local rows = session and session:Slice(view, fromSec, toSec, filterWho) or {}
	local stats = Buffs.Stats(session, fromSec, toSec)

	-- Re-run the layout if the variable-height blocks changed shape, then let that pass do the
	-- drawing (it calls back in with skipRelayout set). Lanes come from the UNFILTERED stats --
	-- the buff search narrows which rows the table lists, not what's plotted on the graph, so a
	-- charted buff the search doesn't match still keeps its lane.
	local lanes = self:ChartedLanes(stats)
	local laneCount = table.getn(lanes)
	local buffStats = self:FilterBuffStats(stats)
	local buffRowsWanted = self.buffsOpen and math.min(table.getn(buffStats), BUFF_POOL) or 0

	if not skipRelayout and (laneCount ~= self.layoutLanes or buffRowsWanted ~= self.layoutBuffRows) then
		self.laneCountWanted = laneCount
		self.buffRowsWanted = buffRowsWanted
		self:Layout()
		return
	end
	self.laneCountWanted = laneCount
	self.buffRowsWanted = buffRowsWanted

	self:RefreshKpis(session, view, filterWho, meta, rows, fromSec, toSec)

	if self.graph ~= nil then
		-- Only re-declare the series when the VIEW changed: SetSeries clears the hidden set, so
		-- doing it on every refresh would silently un-hide a series the reader had toggled off
		-- the moment they dragged a range handle or picked a different target.
		if self.graphSeriesView ~= view then
			self.graphSeriesView = view
			self.graph:SetSeriesWithMorale(SERIES_FOR_VIEW[view], showMorale)
		end
		self.graph:SetData(session, showMorale, filterWho)
		self.graph:SetRange(self.rangeFrom, self.rangeTo)
		self.graph:SetLanes(lanes)
	end

	self:RefreshTable(rows)
	self:RefreshBuffSection(stats, buffStats, fromSec, toSec)

	if session == nil then
		self:RefreshPanel(self.panelA, { title = "", items = {} }, meta.color)
		self:RefreshPanel(self.panelB, { title = "", items = {} }, meta.color)
	else
		local dataA, dataB = self:PanelData(rows, view, filterWho)
		self:RefreshPanel(self.panelA, dataA, meta.color)
		self:RefreshPanel(self.panelB, dataB, Theme.Hex.Accent)
	end
end

function Analysis:RefreshKpis(session, view, filterWho, meta, rows, fromSec, toSec)
	local kpis
	if session == nil then
		kpis = {}
		for i = 1, 5 do
			kpis[i] = { label = "--", value = "--", sub = "", subColor = Theme.Hex.DimText }
		end
	else
		kpis = self:ComputeKpis(session, view, filterWho, meta, rows, fromSec, toSec)
	end

	for i = 1, 5 do
		local card = self.kpiCards[i]
		card.label:SetText(kpis[i].label)
		card.value:SetText(kpis[i].value)
		card.sub:SetText(kpis[i].sub)
		card.sub:SetForeColor(Theme.Color(kpis[i].subColor))
	end
end

function Analysis:ComputeKpis(session, category, filterWho, meta, rows, fromSec, toSec)
	local total, hits, crits, devs, max, maxSkill = 0, 0, 0, 0, 0, nil
	for i = 1, table.getn(rows) do
		local row = rows[i]
		total = total + row.total
		hits = hits + row.hits
		crits = crits + row.crits
		devs = devs + row.devs
		if row.max > max then
			max = row.max
			maxSkill = row.skill
		end
	end

	local activeSeconds = session:ActiveSeconds(fromSec, toSec)
	local rate = (activeSeconds > 0) and (total / activeSeconds) or 0

	local critPct = hits > 0 and (crits / hits) or 0
	local devPct = hits > 0 and (devs / hits) or 0

	-- The fifth card swaps role with the range: unscoped it reports how much of the fight you
	-- were actually acting in, scoped it reports which slice you are looking at -- which is the
	-- thing you most need confirmed while dragging a handle.
	local timeCard
	if fromSec == nil then
		timeCard = {
			label = "ACTIVE", value = Format.Clock(activeSeconds),
			sub = "of " .. Format.Clock(session:Duration()), subColor = Theme.Hex.DimText,
		}
	else
		timeCard = {
			label = "RANGE", value = Format.Clock(toSec - fromSec),
			sub = Format.Clock(fromSec) .. "-" .. Format.Clock(toSec), subColor = Theme.Hex.Accent300,
		}
	end

	return {
		{ label = "TOTAL", value = Format.Number(total), sub = Format.Rate(rate), subColor = Theme.Hex.Accent300 },
		{ label = string.upper(meta.hitWord), value = Format.Number(hits),
		  sub = table.getn(rows) .. " skills", subColor = Theme.Hex.DimText },
		{ label = "CRIT / DEV", value = Format.Percent(critPct) .. " / " .. Format.Percent(devPct),
		  sub = "of " .. meta.hitWord, subColor = Theme.Hex.DimText },
		{ label = "LARGEST", value = max > 0 and Format.Number(max) or "--",
		  sub = maxSkill or "--", subColor = Theme.Hex.DimText },
		timeCard,
	}
end

---------------------------------------------------------------------------------------------------
-- Layout / resize
---------------------------------------------------------------------------------------------------

function Analysis:BuildResizeGripper()
	local gripper = Turbine.UI.Control()
	gripper:SetParent(self)
	gripper:SetSize(12, 12)
	gripper:SetBackColor(Theme.Mix(Theme.Hex.Border, Theme.Hex.WindowFill, 0.6))
	gripper:SetZOrder(5)

	local window = self
	gripper.MouseDown = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			window.resizing = true
			window.resizeStartX = args.X
			window.resizeStartY = args.Y
		end
	end
	-- Chrome only during the drag itself (Frame:Resize -- background/border/header/client);
	-- content stays where it was and just gets clipped/exposed by the growing/shrinking client
	-- area. Full re-layout (Analysis:Layout, which also rebuilds table columns and resizes the
	-- graph) happens once on MouseUp, not on every drag tick -- rebuilding pooled table rows and
	-- the 48-bucket graph continuously while dragging would be needless churn for a value nobody
	-- reads until the mouse comes up anyway.
	gripper.MouseMove = function(sender, args)
		if window.resizing then
			local w, h = window:GetSize()
			w = w + (args.X - window.resizeStartX)
			h = h + (args.Y - window.resizeStartY)
			if w < MIN_WIDTH then w = MIN_WIDTH elseif w > MAX_WIDTH then w = MAX_WIDTH end
			if h < MIN_HEIGHT then h = MIN_HEIGHT elseif h > MAX_HEIGHT then h = MAX_HEIGHT end
			window:Resize(w, h)
		end
	end
	gripper.MouseUp = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			window.resizing = false
			window:Layout()

			local w, h = window:GetSize()
			local saved = _G.settings.windows[window.windowKey]
			saved.width = w
			saved.height = h
			Settings.Save()
		end
	end

	self.gripper = gripper
end

function Analysis:Layout()
	local w, h = self:GetSize()
	local contentWidth = w - RAIL_WIDTH
	local contentHeight = h - self.headerHeight

	self.rail:SetSize(RAIL_WIDTH, contentHeight)
	self.railBorder:SetPosition(RAIL_WIDTH - 1, 0)
	self.railBorder:SetSize(1, contentHeight)

	self.contentArea:SetPosition(RAIL_WIDTH, 0)
	self.contentArea:SetSize(contentWidth, contentHeight)

	local innerX = PAD
	local innerWidth = math.max(200, contentWidth - PAD * 2)

	-- Tab strip: four 140px tabs from the left, the goal line filling whatever is left, and a
	-- 1px rule under the goal line continuing the inactive tabs' baseline to the window edge.
	local tabsWidth = table.getn(VIEWS) * TAB_WIDTH
	local goalX = innerX + tabsWidth
	local goalWidth = math.max(0, contentWidth - PAD - goalX)
	self.goalLine:SetPosition(goalX, 0)
	self.goalLine:SetSize(goalWidth, TAB_STRIP_HEIGHT - 3)
	self.goalRule:SetPosition(goalX, TAB_STRIP_HEIGHT - 1)
	self.goalRule:SetSize(goalWidth, 1)

	local pickerY = 40
	self.pickerRow:SetPosition(innerX, pickerY)
	self.pickerRow:SetSize(innerWidth, PICKER_HEIGHT)

	local kpiY = 72
	self.kpiRow:SetPosition(innerX, kpiY)
	self.kpiRow:SetSize(innerWidth, KPI_ROW_HEIGHT)
	self:LayoutKpiCards(innerWidth)

	-- The graph's own height depends on how many buff lanes are charted, so ask it rather than
	-- keeping a second copy of that arithmetic here.
	local graphHeight = GraphHeightFor(self.laneCountWanted or 0)

	local graphY = 133
	self.graphHolder:SetPosition(innerX, graphY)
	self.graphHolder:SetSize(innerWidth, graphHeight)
	self:LayoutGraph(innerWidth)

	local tableY = graphY + graphHeight + GAP

	-- The bottom row (buff table on the left, side panels on the right) claims what its content
	-- needs; the skill table takes everything that is left and scrolls. When the window is too
	-- short for both, the skill table shrinks to its floor first and the buff list scrolls
	-- second -- in that order, because the skill table is the block a reader came for. Either
	-- way the buff list itself now scrolls (REDESIGN_SPEC.md section 7) rather than silently
	-- dropping rows past whatever height it was given.
	local available = math.max(0, contentHeight - tableY - PAD)
	local buffRows = self.buffRowsWanted or 0
	local bottomHeight = BUFF_HEADER_HEIGHT + 1
	if self.buffsOpen then
		bottomHeight = bottomHeight + SEARCH_HEIGHT + BUFF_TABLE_HEADER_HEIGHT + buffRows * BUFF_ROW_HEIGHT
	end

	local minTable = SEARCH_HEIGHT + ROW_HEIGHT * 5
	local maxBottom = available - GAP - minTable
	if bottomHeight > maxBottom then
		bottomHeight = math.max(BUFF_HEADER_HEIGHT + 1, maxBottom)
	end
	if bottomHeight < BUFF_HEADER_HEIGHT + 1 then
		bottomHeight = BUFF_HEADER_HEIGHT + 1
	end

	local tableHeight = available - GAP - bottomHeight
	if tableHeight < SEARCH_HEIGHT + ROW_HEIGHT * 2 then
		tableHeight = SEARCH_HEIGHT + ROW_HEIGHT * 2
	end

	local listWidth = innerWidth - SCROLLBAR_WIDTH
	self.tableListWidth = listWidth

	self.tableHolder:SetPosition(innerX, tableY)
	self.tableHolder:SetSize(innerWidth, tableHeight)
	self.scrollView:SetPosition(0, SEARCH_HEIGHT + ROW_HEIGHT)
	self.scrollView:SetSize(listWidth, math.max(0, tableHeight - SEARCH_HEIGHT - ROW_HEIGHT))
	self.tableScrollBar:SetPosition(listWidth, SEARCH_HEIGHT + ROW_HEIGHT)
	self.tableScrollBar:SetHeight(math.max(0, tableHeight - SEARCH_HEIGHT - ROW_HEIGHT))
	self:RefreshTableColumns(listWidth)

	local bottomY = tableY + tableHeight + GAP
	local panelsWidth = PANEL_WIDTH
	local buffWidth = math.max(200, innerWidth - GAP - panelsWidth)

	self.buffHolder:SetPosition(innerX, bottomY)
	self.buffHolder:SetSize(buffWidth, bottomHeight)
	self.buffTopRule:SetSize(buffWidth, 1)
	self.buffHeader.control:SetSize(buffWidth, BUFF_HEADER_HEIGHT)
	self.buffHeader.summary:SetSize(math.max(0, buffWidth - 100), BUFF_HEADER_HEIGHT)
	self.buffTableHeader:SetPosition(0, BUFF_HEADER_HEIGHT + 1 + SEARCH_HEIGHT)

	local buffListWidth = math.max(0, buffWidth - SCROLLBAR_WIDTH)
	self:LayoutBuffColumns(buffListWidth)

	local buffListY = BUFF_HEADER_HEIGHT + 1 + SEARCH_HEIGHT + BUFF_TABLE_HEADER_HEIGHT
	local buffListHeight = math.max(0, bottomHeight - buffListY)
	self.buffScrollView:SetPosition(0, buffListY)
	self.buffScrollView:SetSize(buffListWidth, buffListHeight)
	self.buffScrollBar:SetPosition(buffListWidth, buffListY)
	self.buffScrollBar:SetHeight(buffListHeight)

	self.panelsHolder:SetPosition(innerX + buffWidth + GAP, bottomY)
	self.panelsHolder:SetSize(panelsWidth, bottomHeight)
	local panelHeight = math.max(20, math.floor((bottomHeight - GAP) / 2))
	self.panelA.holder:SetPosition(0, 0)
	self.panelA.holder:SetSize(panelsWidth, panelHeight)
	self.panelB.holder:SetPosition(0, panelHeight + GAP)
	self.panelB.holder:SetSize(panelsWidth, panelHeight)

	self.gripper:SetPosition(w - 12, h - 12)

	-- Record what this pass sized things for, so RefreshContent can tell whether the shape
	-- changed and skip re-entering here when it did not.
	self.layoutBuffRows = self.buffRowsWanted or 0
	self.layoutLanes = self.laneCountWanted or 0

	self:RefreshContent(true)
end

function Analysis:LayoutKpiCards(innerWidth)
	local cardWidth = math.floor((innerWidth - 4 * 8) / 5)
	local x = 0
	for i = 1, 5 do
		local card = self.kpiCards[i]
		card.control:SetPosition(x, 0)
		card.control:SetSize(cardWidth, KPI_ROW_HEIGHT)
		card.border:SetSize(cardWidth, KPI_ROW_HEIGHT)
		card.label:SetSize(cardWidth - 16, 12)
		card.value:SetSize(cardWidth - 16, 20)
		card.sub:SetSize(cardWidth - 16, 12)
		x = x + cardWidth + 8
	end
end

function Analysis:LayoutGraph(innerWidth)
	if self.graph == nil then
		local window = self
		self.graph = Graph(innerWidth)
		self.graph:SetParent(self.graphHolder)
		self.graph:SetPosition(0, 0)
		self.graph.OnRangeChanged = function(from, to) window:OnRangeChanged(from, to) end
	elseif self.graph.plotWidth ~= innerWidth then
		self.graph:Resize(innerWidth)
	end
end
