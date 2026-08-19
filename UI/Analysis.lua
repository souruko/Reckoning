--=================================================================================================
-- Analysis -- window 3, 1080x600 resizable to 1440x800. The post-mortem, per fight and per
-- target. See docs/DESIGN.md "3. Post-combat analysis".
--
-- Deliberate deviations from the literal mockup numbers, since this is the one window meant to
-- resize:
--  - The graph and skill table stretch to fill the available content width instead of the
--    mockup's fixed 640px graph -- a fixed-width graph would get no benefit from resizing up to
--    1440px, which is the whole point of the resize gripper existing on this window and not the
--    other two. Bucket COUNT stays fixed at 48 per docs/IMPLEMENTATION_PLAN.md; bucket width
--    scales instead.
--  - The 5 KPIs are one uniform shape across all four views (total+rate, hits/heals+distinct
--    count, crit/dev%, largest+skill, active time) rather than bespoke per view -- docs/DESIGN.md
--    specifies "five KPIs" per view without dictating their exact content.
--=================================================================================================

Analysis = class(Frame)

local MIN_WIDTH, MIN_HEIGHT = 1080, 600
local MAX_WIDTH, MAX_HEIGHT = 1440, 800
local RAIL_WIDTH = 208
local HEADER_HEIGHT = 32
local TAB_STRIP_HEIGHT = 30
local GAP = 11
local PAD = 12
local KPI_ROW_HEIGHT = 50
local GRAPH_HEIGHT = 150 + 22
local ROW_HEIGHT = 22
local RAIL_ROW_HEIGHT = 34
local SCROLLBAR_WIDTH = 10
local RAIL_POOL = 20 -- generous: ring cap is 10 but pinned sessions are exempt from it

local VIEWS = { "done", "healOut", "healIn", "taken" }
local VIEW_META = {
	done = {
		label = "Damage done", question = "Which skills carried it, against whom",
		pickerLabel = "targets", hitWord = "hits", color = Theme.Hex.DamageDone,
		headers = { "Skill", "Type", "Hits", "Crit", "Dev", "Max", "Total" },
	},
	healOut = {
		label = "Healing done", question = "Self-sustain and group contribution",
		pickerLabel = "recipients", hitWord = "heals", color = Theme.Hex.HealingDone,
		headers = { "Skill", "To", "Heals", "Crit", "Dev", "Max", "Total" },
	},
	healIn = {
		label = "Healing taken", question = "Did healers keep pace",
		pickerLabel = "casters", hitWord = "heals", color = Theme.Hex.HealingTaken,
		headers = { "Skill", "From", "Heals", "Crit", "Dev", "Max", "Total" },
	},
	taken = {
		label = "Damage taken", question = "What hit you, what got through",
		pickerLabel = "sources", hitWord = "hits", color = Theme.Hex.DamageTaken,
		headers = { "Skill", "Type", "Hits", "Crit", "Dev", "Avoided", "Max", "Total" },
	},
}

local NUMERIC_HEADERS = { Hits = true, Heals = true, Crit = true, Dev = true, Avoided = true, Max = true, Total = true }

local AVOID_NAMES = {
	[AvoidType.Missed] = "Missed", [AvoidType.Immune] = "Immune", [AvoidType.Resisted] = "Resisted",
	[AvoidType.Blocked] = "Blocked", [AvoidType.Parried] = "Parried", [AvoidType.Evaded] = "Evaded",
	[AvoidType.Deflected] = "Deflected",
}

---------------------------------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------------------------------

function Analysis:Constructor()
	Frame.Constructor(self, {
		key = "analysis", title = "Reckoning", closable = true,
		width = MIN_WIDTH, height = MIN_HEIGHT, headerHeight = HEADER_HEIGHT,
	})

	self.viewTab = "done"
	self.filter = { done = nil, healOut = nil, healIn = nil, taken = nil }
	self.selectedSession = nil

	self:BuildSessionRail()
	self:BuildContentArea()
	self:BuildResizeGripper()

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
	end
	self:RefreshRail()
	if self.selectedSession == newSession then
		self:RefreshContent()
	end
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
	row:SetVisible(false)

	local leftBorder = Turbine.UI.Control()
	leftBorder:SetParent(row)
	leftBorder:SetPosition(0, 0)
	leftBorder:SetSize(0, RAIL_ROW_HEIGHT)
	leftBorder:SetMouseVisible(false)

	local fill = Turbine.UI.Control()
	fill:SetParent(row)
	fill:SetPosition(0, 0)
	fill:SetSize(RAIL_WIDTH, RAIL_ROW_HEIGHT)
	fill:SetBackColor(Theme.Color(Theme.Hex.Accent))
	fill:SetOpacity(0)
	fill:SetMouseVisible(false)

	local pin = Turbine.UI.Label()
	pin:SetParent(row)
	pin:SetFont(Font.Verdana12)
	pin:SetPosition(8, 2)
	pin:SetSize(14, 16)
	pin:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)

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

	local widgets = { control = row, leftBorder = leftBorder, fill = fill, pin = pin, name = name, meta = meta, session = nil }

	local window = self
	row.MouseClick = function() window:SelectSession(widgets.session) end
	row.MouseEnter = function() if widgets.session ~= window.selectedSession then fill:SetOpacity(0.05) end end
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
			widgets.pin:SetText(s.pinned and "◆" or "◇")
			widgets.pin:SetForeColor(Theme.Color(s.pinned and Theme.Hex.Accent or "#5c5f70"))
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

	widgets.fill:SetOpacity(selected and 0.11 or 0)
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

function Analysis:SelectSession(session)
	if session == nil then
		return
	end
	self.selectedSession = session
	self:RefreshRail()
	self:RefreshContent()
end

---------------------------------------------------------------------------------------------------
-- Content area: tab strip, goal line, picker, KPI row, graph, table + side panels
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
	self:BuildPanels()
end

function Analysis:BuildTabStrip()
	self.viewTabs = {}
	local x = PAD
	local tabWidth = 140
	local window = self

	for i = 1, table.getn(VIEWS) do
		local key = VIEWS[i]
		local meta = VIEW_META[key]

		local tab = Turbine.UI.Control()
		tab:SetParent(self.contentArea)
		tab:SetPosition(x, 0)
		tab:SetSize(tabWidth, TAB_STRIP_HEIGHT)

		local fill = Turbine.UI.Control()
		fill:SetParent(tab)
		fill:SetPosition(0, 0)
		fill:SetSize(tabWidth, TAB_STRIP_HEIGHT)
		fill:SetBackColor(Theme.Color(Theme.Hex.Accent))
		fill:SetOpacity(0)
		fill:SetMouseVisible(false)

		local label = Turbine.UI.Label()
		label:SetParent(tab)
		label:SetFont(Font.Verdana12)
		label:SetText(meta.label)
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetPosition(0, 0)
		label:SetSize(tabWidth, TAB_STRIP_HEIGHT - 2)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)

		local underline = Turbine.UI.Control()
		underline:SetParent(tab)
		underline:SetPosition(0, TAB_STRIP_HEIGHT - 2)
		underline:SetSize(tabWidth, 2)
		underline:SetMouseVisible(false)

		tab.MouseClick = function() window:SelectView(key) end
		tab.MouseEnter = function() if window.viewTab ~= key then fill:SetOpacity(0.05) end end
		tab.MouseLeave = function() if window.viewTab ~= key then fill:SetOpacity(0) end end

		self.viewTabs[key] = { control = tab, label = label, underline = underline, fill = fill }
		x = x + tabWidth
	end
end

function Analysis:BuildGoalLine()
	self.goalLine = Turbine.UI.Label()
	self.goalLine:SetParent(self.contentArea)
	self.goalLine:SetFont(Font.Verdana12)
	self.goalLine:SetForeColor(Theme.Color(Theme.Hex.DimText))
	self.goalLine:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	self.goalLine:SetMouseVisible(false)
end

-- Picker chips are rebuilt on session/view change (a handful of controls, not a hot path) since
-- the distinct-name set differs per session and view. Width is a rough per-character estimate --
-- Turbine.UI exposes no text-measurement call used elsewhere in this codebase.
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

	local labels = { "All " .. meta.pickerLabel }
	local values = { nil }
	for i = 1, table.getn(names) do
		table.insert(labels, names[i])
		table.insert(values, names[i])
	end

	local x = 0
	local window = self
	for i = 1, table.getn(labels) do
		local chip = self.pickerChips[i]
		if chip == nil then
			chip = self:BuildPickerChip()
			self.pickerChips[i] = chip
		end

		local text = labels[i]
		local w = ChipWidth(text)
		chip.control:SetPosition(x, 0)
		chip.control:SetSize(w, 22)
		chip.fill:SetSize(w, 22)
		chip.border:SetSize(w, 22)
		chip.label:SetSize(w, 22)
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

	local fill = Turbine.UI.Control()
	fill:SetParent(control)
	fill:SetPosition(0, 0)
	fill:SetBackColor(Theme.Color(Theme.Hex.Accent))
	fill:SetOpacity(0)
	fill:SetMouseVisible(false)

	local border = Turbine.UI.Control()
	border:SetParent(control)
	border:SetPosition(0, 0)
	border:SetBackColor(Theme.Color(Theme.Hex.Border))
	border:SetMouseVisible(false)

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

	local chip = { control = control, fill = fill, border = border, inset = inset, label = label, value = nil }

	local window = self
	control.MouseClick = function() window:SelectFilter(chip.value) end
	control.MouseEnter = function() if window.filter[window.viewTab] ~= chip.value then fill:SetOpacity(0.05) end end
	control.MouseLeave = function() window:RefreshPickerSelection() end

	return chip
end

function Analysis:RefreshPickerSelection()
	local selected = self.filter[self.viewTab]
	for i = 1, table.getn(self.pickerChips) do
		local chip = self.pickerChips[i]
		if chip.control:IsVisible() then
			local isSelected = (chip.value == selected)
			chip.fill:SetOpacity(isSelected and 0.11 or 0)
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

function Analysis:BuildKpiRow()
	self.kpiRow = Turbine.UI.Control()
	self.kpiRow:SetParent(self.contentArea)
	self.kpiRow:SetMouseVisible(false)

	self.kpiCards = {}
	for i = 1, 5 do
		self.kpiCards[i] = self:BuildKpiCard()
	end
end

function Analysis:BuildKpiCard()
	local card = Turbine.UI.Control()
	card:SetParent(self.kpiRow)
	card:SetBackColor(Theme.Color(Theme.Hex.PanelFill))
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
	label:SetPosition(8, 6)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	label:SetMouseVisible(false)

	local value = Turbine.UI.Label()
	value:SetParent(card)
	value:SetFont(Font.Verdana20)
	value:SetForeColor(Theme.Color(Theme.Hex.Text))
	value:SetPosition(8, 18)
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
-- Skill table
---------------------------------------------------------------------------------------------------

function Analysis:BuildTable()
	self.tableHolder = Turbine.UI.Control()
	self.tableHolder:SetParent(self.contentArea)
	self.tableHolder:SetMouseVisible(false)

	self.tableHeaderRow = Turbine.UI.Control()
	self.tableHeaderRow:SetParent(self.tableHolder)
	self.tableHeaderRow:SetPosition(0, 0)
	self.tableHeaderRow:SetSize(1, ROW_HEIGHT)
	self.tableHeaderRow:SetBackColor(Theme.Color(Theme.Hex.HeaderFill))
	self.tableHeaderRow:SetMouseVisible(false)

	self.tableHeaderLabels = {}
	for i = 1, 8 do
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
	self.scrollView:SetPosition(0, ROW_HEIGHT)
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
-- never sits in the ListBox until it actually has data for the current view/filter.
function Analysis:BuildTableRowSlot()
	local container = Turbine.UI.Control()
	container:SetSize(1, ROW_HEIGHT)

	local divider = Turbine.UI.Control()
	divider:SetParent(container)
	divider:SetPosition(0, ROW_HEIGHT - 1)
	divider:SetSize(1, 1)
	divider:SetBackColor(Theme.Color(Theme.Hex.RowBorder))
	divider:SetMouseVisible(false)

	local shareBar = Turbine.UI.Control()
	shareBar:SetParent(container)
	shareBar:SetPosition(0, 0)
	shareBar:SetSize(0, ROW_HEIGHT - 1)
	shareBar:SetOpacity(0.08)
	shareBar:SetMouseVisible(false)

	local row = nil -- built lazily once column geometry is known, see RefreshTableColumns

	return { container = container, divider = divider, shareBar = shareBar, row = row }
end

-- (Re)builds the header labels and the pooled rows' column geometry for the active view. Called
-- on view change and on resize -- not per data refresh.
function Analysis:RefreshTableColumns(tableWidth)
	local meta = VIEW_META[self.viewTab]
	local headers = meta.headers

	local FIXED, NAME_COL = 60, 110
	local fixedTotal = 0
	for i = 2, table.getn(headers) do
		fixedTotal = fixedTotal + (NUMERIC_HEADERS[headers[i]] and FIXED or NAME_COL)
	end
	local skillWidth = tableWidth - fixedTotal
	if skillWidth < 150 then
		skillWidth = 150
	end

	local columns = {}
	local x = 0
	for i = 1, table.getn(headers) do
		local h = headers[i]
		local numeric = NUMERIC_HEADERS[h] and i > 1
		local width = (i == 1) and skillWidth or (numeric and FIXED or NAME_COL)

		columns[i] = {
			x = x, width = width,
			font = numeric and Font.LucidaConsole12 or Font.Verdana12,
			align = numeric and Turbine.UI.ContentAlignment.MiddleRight or Turbine.UI.ContentAlignment.MiddleLeft,
			colorHex = Theme.Hex.Text,
		}
		x = x + width
	end
	self.tableColumns = columns
	self.tableWidth = x

	for i = 1, 8 do
		local label = self.tableHeaderLabels[i]
		local h = headers[i]
		if h == nil then
			label:SetVisible(false)
		else
			local col = columns[i]
			label:SetPosition(col.x + 8, 0)
			label:SetSize(col.width - (i == 1 and 8 or 0), ROW_HEIGHT)
			label:SetText(string.upper(h))
			label:SetTextAlignment(col.align)
			label:SetVisible(true)
		end
	end
	self.tableHeaderRow:SetSize(x, ROW_HEIGHT)

	for i = 1, table.getn(self.tableRowPool) do
		local slot = self.tableRowPool[i]
		slot.container:SetSize(x, ROW_HEIGHT)
		slot.shareBar:SetBackColor(Theme.Color(meta.color))

		if slot.row == nil then
			slot.row = Row(x, ROW_HEIGHT, columns)
			slot.row:SetParent(slot.container)
			slot.row:SetPosition(0, 0)
		else
			slot.row:Reconfigure(x, columns)
		end
	end
end

function Analysis:TableRows(session, view, filterWho)
	if view == "healOut" or view == "healIn" then
		local list = {}
		for _, row in pairs(session.agg[view]) do
			if filterWho == nil or row.who == filterWho then
				table.insert(list, row)
			end
		end
		table.sort(list, function(a, b) return a.total > b.total end)
		return list
	end

	local grouped = {}
	local order = {}
	for _, row in pairs(session.agg[view]) do
		if filterWho == nil or row.who == filterWho then
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
	end
	table.sort(order, function(a, b) return a.total > b.total end)
	return order
end

function Analysis:RowValues(view, row)
	if view == "healOut" or view == "healIn" then
		return { row.skill, row.who, Format.Number(row.hits), Format.Number(row.crits), Format.Number(row.devs), Format.Number(row.max), Format.Number(row.total) }
	elseif view == "taken" then
		local swings = row.hits + row.avoided
		local avoidedPct = swings > 0 and Format.Percent(row.avoided / swings) or "0%"
		return { row.skill, DamageType.Names[row.type] or "?", Format.Number(row.hits), Format.Number(row.crits), Format.Number(row.devs), avoidedPct, Format.Number(row.max), Format.Number(row.total) }
	else
		return { row.skill, DamageType.Names[row.type] or "?", Format.Number(row.hits), Format.Number(row.crits), Format.Number(row.devs), Format.Number(row.max), Format.Number(row.total) }
	end
end

function Analysis:RefreshTable(session)
	local view = self.viewTab
	local filterWho = self.filter[view]
	local rows = session and self:TableRows(session, view, filterWho) or {}

	local maxTotal = 0
	for i = 1, table.getn(rows) do
		if rows[i].total > maxTotal then
			maxTotal = rows[i].total
		end
	end

	-- ListBox is item-list based, not freeform positioning: clear and re-add each refresh, but
	-- reuse the same pooled container/Row/shareBar objects every time -- only the ListBox's
	-- membership list is rebuilt, never the Controls themselves.
	self.scrollView:ClearItems()

	local n = table.getn(rows)
	local poolSize = table.getn(self.tableRowPool)
	if n > poolSize then
		n = poolSize
	end

	for i = 1, n do
		local slot = self.tableRowPool[i]
		local row = rows[i]

		slot.row:SetValues(self:RowValues(view, row))
		local share = (maxTotal > 0) and (row.total / maxTotal) or 0
		slot.shareBar:SetSize(math.floor(self.tableWidth * share), ROW_HEIGHT - 1)

		self.scrollView:AddItem(slot.container)
	end
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
	for i = 1, 6 do
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
		valueLabel:SetForeColor(Theme.Color(Theme.Hex.Text))
		valueLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		valueLabel:SetMouseVisible(false)
		valueLabel:SetVisible(false)

		local bar = Bar(1, 3, Theme.Hex.Accent, "#ffffff0e")
		bar:SetParent(holder)
		bar:SetVisible(false)

		rows[i] = { name = nameLabel, value = valueLabel, bar = bar }
	end

	return { holder = holder, title = title, rows = rows }
end

function Analysis:PanelData(session, view, filterWho)
	local isHeal = (view == "healOut" or view == "healIn")
	local meta = VIEW_META[view]

	local function totalsBy(field, who)
		local totals = {}
		for _, row in pairs(session.agg[view]) do
			if who == nil or row.who == who then
				local key = (field == "type") and (DamageType.Names[row.type] or "Unknown") or row[field]
				totals[key] = (totals[key] or 0) + row.total
			end
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
		local panelA = { title = string.upper(meta.pickerLabel), items = toItems(totalsBy("who", nil)) }
		local panelB = { title = isHeal and "BY SKILL" or "BY TYPE", items = toItems(totalsBy(isHeal and "skill" or "type", nil)) }
		return panelA, panelB
	end

	local panelA = { title = isHeal and "BY SKILL" or "BY TYPE", items = toItems(totalsBy(isHeal and "skill" or "type", filterWho)) }

	if isHeal then
		local crit, normal = 0, 0
		for _, row in pairs(session.agg[view]) do
			if row.who == filterWho then
				crit = crit + row.crits + row.devs
				normal = normal + (row.hits - row.crits - row.devs)
			end
		end
		local items = {}
		if crit > 0 then table.insert(items, { name = "Critical", value = crit }) end
		if normal > 0 then table.insert(items, { name = "Normal", value = normal }) end
		return panelA, { title = "CRIT SPLIT", items = items }
	end

	local avoidTotals = {}
	for _, row in pairs(session.agg[view]) do
		if row.who == filterWho then
			for avoidType, count in pairs(row.avoidBreakdown) do
				local name = AVOID_NAMES[avoidType] or "Other"
				avoidTotals[name] = (avoidTotals[name] or 0) + count
			end
		end
	end
	return panelA, { title = "AVOIDANCE", items = toItems(avoidTotals) }
end

function Analysis:RefreshPanel(panel, data)
	panel.title:SetText(data.title)

	local maxValue = 0
	for i = 1, table.getn(data.items) do
		if data.items[i].value > maxValue then
			maxValue = data.items[i].value
		end
	end

	local barWidth = select(1, panel.holder:GetSize())

	for i = 1, 6 do
		local widgets = panel.rows[i]
		local item = data.items[i]

		if item == nil then
			widgets.name:SetVisible(false)
			widgets.value:SetVisible(false)
			widgets.bar:SetVisible(false)
		else
			local y = 16 + (i - 1) * 16
			widgets.name:SetPosition(0, y)
			widgets.name:SetSize(barWidth - 70, 12)
			widgets.name:SetText(item.name)
			widgets.name:SetVisible(true)

			widgets.value:SetPosition(barWidth - 60, y)
			widgets.value:SetSize(60, 12)
			widgets.value:SetText(Format.Number(item.value))
			widgets.value:SetVisible(true)

			widgets.bar:SetPosition(0, y + 13)
			widgets.bar.maxWidth = barWidth
			widgets.bar:SetSize(barWidth, 3)
			widgets.bar:SetPercent(maxValue > 0 and (item.value / maxValue) or 0)
			widgets.bar:SetVisible(true)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- View / data refresh
---------------------------------------------------------------------------------------------------

function Analysis:SelectView(key, skipReset)
	self.viewTab = key

	for i = 1, table.getn(VIEWS) do
		local k = VIEWS[i]
		local t = self.viewTabs[k]
		local selected = (k == key)
		t.label:SetForeColor(Theme.Color(selected and Theme.Hex.Accent200 or Theme.Hex.DimText))
		t.underline:SetBackColor(Theme.Color(selected and Theme.Hex.Accent or Theme.Hex.WindowFill))
		t.fill:SetOpacity(selected and 0.11 or 0)
	end

	if self.graph ~= nil then
		self:ConfigureGraphSeries()
	end

	self:RefreshTableColumns(self.tableWidth or 400)
	self:RefreshContent()
end

function Analysis:ConfigureGraphSeries()
	local seriesForView = {
		done = { { key = "done", label = "Damage", colorHex = Theme.Hex.DamageDone } },
		healOut = { { key = "healOut", label = "Healing out", colorHex = Theme.Hex.HealingDone } },
		healIn = {
			{ key = "healIn", label = "Healing in", colorHex = Theme.Hex.HealingTaken },
			{ key = "taken", label = "Damage taken", colorHex = Theme.Hex.DamageTaken },
		},
		taken = {
			{ key = "taken", label = "Damage taken", colorHex = Theme.Hex.DamageTaken },
			{ key = "healIn", label = "Healing in", colorHex = Theme.Hex.HealingTaken },
		},
	}
	self.graph:SetSeries(seriesForView[self.viewTab])
end

function Analysis:RefreshContent()
	local session = self.selectedSession
	local view = self.viewTab
	local filterWho = self.filter[view]
	local meta = VIEW_META[view]

	self.goalLine:SetText(meta.question)

	self:RefreshPicker()

	local kpis
	if session == nil then
		kpis = {}
		for i = 1, 5 do
			kpis[i] = { label = "--", value = "--", sub = "", subColor = Theme.Hex.DimText }
		end
	else
		kpis = self:ComputeKpis(session, view, filterWho, meta)
	end
	for i = 1, 5 do
		local card = self.kpiCards[i]
		card.label:SetText(kpis[i].label)
		card.value:SetText(kpis[i].value)
		card.sub:SetText(kpis[i].sub)
		card.sub:SetForeColor(Theme.Color(kpis[i].subColor))
	end

	if self.graph ~= nil then
		local showMorale = (view == "healIn" or view == "taken")
		self.graph:SetData(session, showMorale)
	end

	self:RefreshTable(session)

	if session == nil then
		self:RefreshPanel(self.panelA, { title = "", items = {} })
		self:RefreshPanel(self.panelB, { title = "", items = {} })
	else
		local dataA, dataB = self:PanelData(session, view, filterWho)
		self:RefreshPanel(self.panelA, dataA)
		self:RefreshPanel(self.panelB, dataB)
	end
end

function Analysis:ComputeKpis(session, category, filterWho, meta)
	local stats = session:HitStats(category, filterWho)
	local total = session:Total(category, filterWho)
	local rate = session:Rate(category, filterWho)

	local names = {}
	local count = 0
	for _, row in pairs(session.agg[category]) do
		if (filterWho == nil or row.who == filterWho) and not names[row.who] then
			names[row.who] = true
			count = count + 1
		end
	end

	local critPct = stats.hits > 0 and (stats.crits / stats.hits) or 0
	local devPct = stats.hits > 0 and (stats.devs / stats.hits) or 0

	return {
		{ label = "TOTAL", value = Format.Number(total), sub = Format.Rate(rate), subColor = Theme.Hex.Accent300 },
		{ label = string.upper(meta.hitWord), value = Format.Number(stats.hits), sub = count .. " " .. meta.pickerLabel, subColor = Theme.Hex.DimText },
		{ label = "CRIT / DEV", value = Format.Percent(critPct) .. " / " .. Format.Percent(devPct), sub = "of " .. meta.hitWord, subColor = Theme.Hex.DimText },
		{ label = "LARGEST", value = stats.max > 0 and Format.Number(stats.max) or "--", sub = stats.maxSkill or "--", subColor = Theme.Hex.DimText },
		{ label = "ACTIVE", value = Format.Clock(session:ActiveSeconds()), sub = "of " .. Format.Clock(session:Duration()), subColor = Theme.Hex.DimText },
	}
end

---------------------------------------------------------------------------------------------------
-- Layout / resize
---------------------------------------------------------------------------------------------------

function Analysis:BuildResizeGripper()
	local gripper = Turbine.UI.Control()
	gripper:SetParent(self)
	gripper:SetSize(12, 12)
	gripper:SetBackColor(Theme.Color(Theme.Hex.Border))
	gripper:SetOpacity(0.6)
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
	local innerWidth = contentWidth - PAD * 2

	local goalY = TAB_STRIP_HEIGHT + GAP
	self.goalLine:SetPosition(innerX, goalY)
	self.goalLine:SetSize(innerWidth, 16)

	local pickerY = goalY + 16 + GAP
	self.pickerRow:SetPosition(innerX, pickerY)
	self.pickerRow:SetSize(innerWidth, 24)

	local kpiY = pickerY + 24 + GAP
	self.kpiRow:SetPosition(innerX, kpiY)
	self.kpiRow:SetSize(innerWidth, KPI_ROW_HEIGHT)
	self:LayoutKpiCards(innerWidth)

	local graphY = kpiY + KPI_ROW_HEIGHT + GAP
	self.graphHolder:SetPosition(innerX, graphY)
	self:LayoutGraph(innerWidth)

	local tableY = graphY + GRAPH_HEIGHT + GAP
	local tableAreaHeight = contentHeight - tableY - PAD
	if tableAreaHeight < 80 then
		tableAreaHeight = 80
	end

	local tableWidth = math.floor((innerWidth - GAP) * 2.6 / 3.6)
	local panelsWidth = innerWidth - GAP - tableWidth

	local listWidth = tableWidth - SCROLLBAR_WIDTH

	self.tableHolder:SetPosition(innerX, tableY)
	self.tableHolder:SetSize(tableWidth, tableAreaHeight)
	self.scrollView:SetPosition(0, ROW_HEIGHT)
	self.scrollView:SetSize(listWidth, tableAreaHeight - ROW_HEIGHT)
	self.tableScrollBar:SetPosition(listWidth, ROW_HEIGHT)
	self.tableScrollBar:SetHeight(tableAreaHeight - ROW_HEIGHT)
	self:RefreshTableColumns(listWidth)

	self.panelsHolder:SetPosition(innerX + tableWidth + GAP, tableY)
	self.panelsHolder:SetSize(panelsWidth, tableAreaHeight)
	local panelHeight = math.floor((tableAreaHeight - GAP) / 2)
	self.panelA.holder:SetPosition(0, 0)
	self.panelA.holder:SetSize(panelsWidth, panelHeight)
	self.panelB.holder:SetPosition(0, panelHeight + GAP)
	self.panelB.holder:SetSize(panelsWidth, panelHeight)

	self.gripper:SetPosition(w - 12, h - 12)

	self:RefreshContent()
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
		card.value:SetSize(cardWidth - 16, 24)
		card.sub:SetSize(cardWidth - 16, 12)
		x = x + cardWidth + 8
	end
end

function Analysis:LayoutGraph(innerWidth)
	if self.graph == nil then
		self.graph = Graph(innerWidth)
		self.graph:SetParent(self.graphHolder)
		self.graph:SetPosition(0, 0)
		self:ConfigureGraphSeries()
	elseif self.graph.plotWidth ~= innerWidth then
		self.graph:Resize(innerWidth)
	end
end
