--=================================================================================================
-- Graph -- the analysis window's time plot, rebuilt as a line-and-dot plot per the redesign
-- (design_handoff_reckoning_redesign/REDESIGN_SPEC.md sections 2-4). What used to be a 13%-opacity
-- area column per bucket with a 2px cap is now two real polylines with dots on the data points;
-- morale, which used to be a 22px lane of dots above the plot, is now a background bar graph
-- behind the lines; and the block owns three more rows underneath the plot: the charted buff
-- lanes, the two-handle range slider, and the timeline/legend.
--
-- Stacked top to bottom (see GraphHeightFor, which Analysis:Layout needs before any Graph
-- instance necessarily exists):
--
--   plot            150   morale bars, guide lines, the series polylines, range dim + markers
--   buff lanes    0..60   one 16px lane (+4px gap) per charted self-buff, max 3
--   range slider     16   UI/RangeSlider.lua
--   timeline         14   5 MM:SS marks
--   legend           18   series swatches (clickable) + the range's peak/low morale readout
--
-- A DIAGONAL IS NOT DRAWABLE HERE. Turbine.UI has no canvas, no line primitive and no per-pixel
-- access -- a Control is an axis-aligned rectangle with a back colour, and that is the whole
-- toolbox. So each step of the polyline is drawn as an L: a horizontal run at the *midpoint*
-- height between the two values, plus a vertical riser at the run's right end. At 48 buckets
-- over 640-1200px that is 13-25px per step, which at a 2px stroke reads as a line rather than a
-- staircase. This is Option A from the bundle's GRAPH_RESEARCH.md -- deliberately the one with
-- no unknowns. Option B (the undocumented SetRotation, which Gibberish3 does use in production
-- but only ever at 0/90/180/270) would halve the Control count and give true diagonals, but it
-- needs a seven-item in-game probe first; the pooling shape here is identical either way, so
-- switching later is a local change to DrawStep and nothing else.
--
-- Everything is pooled once in the constructor and only ever repositioned/recoloured -- never
-- rebuilt per refresh, never reparented, never detached (Turbine has no confirmed-safe
-- "detach a child" call anywhere in this codebase -- see UI/Row.lua's Reconfigure).
--=================================================================================================

Graph = class(Turbine.UI.Control)

local BUCKET_COUNT = 48
local MAX_REGULAR_SERIES = 2 -- the busiest view (taken+healIn) never needs more than this
local MAX_LANES = 3          -- max charted buffs, matching Theme.BuffLane's three colours

local PLOT_HEIGHT = 150
local TOP_PAD     = 22 -- headroom, so a peak bucket never touches the frame
local BOTTOM_PAD  = 4  -- the zero baseline sits this far above the plot's bottom edge
local STROKE      = 2
local DOT_SIZE    = 5

local LANE_HEIGHT     = 16
local LANE_GAP        = 4
local LANE_STRIP_GAP  = 4  -- between the plot and the first lane
local LANE_ICON_SIZE  = 16
local LANE_RAIL_GAP   = 6  -- between the rail's right end and the icon
local LANE_SEGMENTS   = 24 -- pooled interval segments per lane

local SLIDER_HEIGHT   = 16
local SLIDER_GAP      = 6
local TIMELINE_HEIGHT = 14
local TIMELINE_GAP    = 2
local LEGEND_HEIGHT   = 18
local LEGEND_GAP      = 2

local TIMELINE_MARKS = 5 -- 0%, 25%, 50%, 75%, 100% of the session's duration
local TIMELINE_LABEL_WIDTH = 60

local TOOLTIP_WIDTH = 160
local TOOLTIP_LINES = 4 -- time + up to 2 series + morale

-- Explicit z-order per pool. Creation order decides this by default, but pools are reused
-- across views and sessions for the life of the window, so nothing may depend on the order they
-- happened to be built in.
local Z_GROUND  = 0
local Z_MORALE  = 10
local Z_GUIDE   = 11
local Z_GRID    = 11
local Z_RISER   = 12 -- risers under the runs, so an L joint has no visible seam
local Z_RUN     = 13
local Z_DOT     = 14
local Z_RANGE   = 20
local Z_TOOLTIP = 25

-- Height of the whole block for a given number of charted buff lanes. Analysis:Layout needs
-- this before a Graph necessarily exists, which is why it is a plain function rather than a
-- method or a constant duplicated by hand in two files.
function GraphHeightFor(laneCount)
	laneCount = laneCount or 0
	if laneCount > MAX_LANES then
		laneCount = MAX_LANES
	end

	local lanes = 0
	if laneCount > 0 then
		lanes = LANE_STRIP_GAP + laneCount * (LANE_HEIGHT + LANE_GAP)
	end

	return PLOT_HEIGHT + lanes
		+ SLIDER_GAP + SLIDER_HEIGHT
		+ TIMELINE_GAP + TIMELINE_HEIGHT
		+ LEGEND_GAP + LEGEND_HEIGHT
end

function GraphBucketCount()
	return BUCKET_COUNT
end

---------------------------------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------------------------------

function Graph:Constructor(width)
	Turbine.UI.Control.Constructor(self)

	self.plotWidth = width
	self.bucketWidth = width / BUCKET_COUNT
	self.laneCount = 0
	self.duration = 1
	self.rangeFrom = 1
	self.rangeTo = BUCKET_COUNT
	self.slices = {}
	self.moraleBySlice = {}
	self.seriesList = {}
	self.hidden = {}
	self.legendWidgets = {}

	self:SetSize(width, GraphHeightFor(0))
	self:SetMouseVisible(false)

	self:BuildPlotGround()
	self:BuildMorale()
	self:BuildGridlines()
	self:BuildSeriesPools()
	self:BuildRangeOverlay()
	self:BuildLanes()
	self:BuildSlider()
	self:BuildTimeline()
	self:BuildLegend()
	self:BuildTooltip()

	self:LayoutRows()
end

-- The plot's recessed ground -- and, deliberately, the only mouse-visible Control in the whole
-- plot. An earlier version put one invisible hover zone per bucket *on top* of the data and it
-- hid the morale trace underneath (found by an in-game load; the exact mechanism was never
-- pinned down). Hovering the ground instead sidesteps that question completely: the ground is
-- meant to be behind everything, it needs an opaque BackColor anyway, and every Control drawn
-- over it is mouse-invisible -- which this codebase already relies on for click-through
-- (UI/Row.lua is mouse-invisible precisely so the death window's own hover fires through it).
-- One Control replaces 48, and the bucket comes from args.X instead of from which zone fired.
function Graph:BuildPlotGround()
	local ground = Turbine.UI.Control()
	ground:SetParent(self)
	ground:SetPosition(0, 0)
	ground:SetSize(self.plotWidth, PLOT_HEIGHT)
	ground:SetBackColor(Theme.Color(Theme.Hex.PlotFill))
	ground:SetMouseVisible(true)
	ground:SetZOrder(Z_GROUND)

	local graph = self
	ground.MouseMove = function(sender, args)
		graph:ShowTooltip(graph:BucketAt(args.X))
	end
	ground.MouseLeave = function()
		graph:HideTooltip()
	end

	self.plotGround = ground

	-- 1px inner border, drawn as four edges (Turbine has no border property).
	self.plotBorder = {}
	for i = 1, 4 do
		local edge = Turbine.UI.Control()
		edge:SetParent(self)
		edge:SetBackColor(Theme.Color(Theme.Hex.PlotBorder))
		edge:SetMouseVisible(false)
		edge:SetZOrder(Z_RANGE)
		self.plotBorder[i] = edge
	end
	self:LayoutPlotBorder()
end

function Graph:LayoutPlotBorder()
	local w = self.plotWidth
	self.plotBorder[1]:SetPosition(0, 0)
	self.plotBorder[1]:SetSize(w, 1)
	self.plotBorder[2]:SetPosition(0, PLOT_HEIGHT - 1)
	self.plotBorder[2]:SetSize(w, 1)
	self.plotBorder[3]:SetPosition(0, 0)
	self.plotBorder[3]:SetSize(1, PLOT_HEIGHT)
	self.plotBorder[4]:SetPosition(w - 1, 0)
	self.plotBorder[4]:SetSize(1, PLOT_HEIGHT)
end

-- Morale as a background bar graph: one bar per bucket with a brighter 1px top edge, so a bar
-- reads as a bar rather than as a flat wash. Below MORALE_DANGER the pair switches to the "low"
-- colours -- the one thing you want to spot at a glance is the stretch where you were nearly dead.
function Graph:BuildMorale()
	self.moraleBars = {}
	self.moraleEdges = {}

	for i = 1, BUCKET_COUNT do
		local bar = Turbine.UI.Control()
		bar:SetParent(self)
		bar:SetVisible(false)
		bar:SetMouseVisible(false)
		bar:SetZOrder(Z_MORALE)
		self.moraleBars[i] = bar

		local edge = Turbine.UI.Control()
		edge:SetParent(self)
		edge:SetVisible(false)
		edge:SetMouseVisible(false)
		edge:SetZOrder(Z_MORALE)
		self.moraleEdges[i] = edge
	end

	-- 100% and 50% guide lines. The 50% line is deliberately unlabelled: it is a reading aid,
	-- and a second number there only competes with the peak.
	self.moraleGuideTop = self:BuildLine(Theme.Hex.MoraleGuide, Z_GUIDE)
	self.moraleGuideMid = self:BuildLine(Theme.Hex.MoraleGuideMid, Z_GUIDE)

	self.moraleAxisLabel = Turbine.UI.Label()
	self.moraleAxisLabel:SetParent(self)
	self.moraleAxisLabel:SetFont(Font.Verdana10)
	self.moraleAxisLabel:SetForeColor(Theme.Color(Theme.Hex.Morale))
	self.moraleAxisLabel:SetSize(160, 12)
	self.moraleAxisLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
	self.moraleAxisLabel:SetMouseVisible(false)
	self.moraleAxisLabel:SetVisible(false)
	self.moraleAxisLabel:SetZOrder(Z_GUIDE)
end

function Graph:BuildLine(colorHex, z)
	local line = Turbine.UI.Control()
	line:SetParent(self)
	line:SetSize(self.plotWidth, 1)
	line:SetBackColor(Theme.Color(colorHex))
	line:SetMouseVisible(false)
	line:SetVisible(false)
	line:SetZOrder(z)
	return line
end

function Graph:BuildGridlines()
	self.gridlines = {}
	for i = 1, 2 do
		local line = self:BuildLine("#ffffff", Z_GRID)
		line:SetBackColor(Theme.Mix("#ffffff", Theme.Hex.PlotFill, 0.05))
		line:SetVisible(true)
		self.gridlines[i] = line
	end
end

-- Three pools per series slot: the dots, the horizontal runs and the vertical risers. Sized
-- once here, only ever repositioned afterwards. 2 slots x (48 + 47 + 47) = 284 Controls.
function Graph:BuildSeriesPools()
	self.dots = {}
	self.hSeg = {}
	self.vSeg = {}

	for slot = 1, MAX_REGULAR_SERIES do
		self.dots[slot] = {}
		self.hSeg[slot] = {}
		self.vSeg[slot] = {}

		for i = 1, BUCKET_COUNT do
			local dot = Turbine.UI.Control()
			dot:SetParent(self)
			dot:SetSize(DOT_SIZE, DOT_SIZE)
			dot:SetVisible(false)
			dot:SetMouseVisible(false)
			dot:SetZOrder(Z_DOT)
			self.dots[slot][i] = dot
		end

		for i = 1, BUCKET_COUNT - 1 do
			local run = Turbine.UI.Control()
			run:SetParent(self)
			run:SetVisible(false)
			run:SetMouseVisible(false)
			run:SetZOrder(Z_RUN)
			self.hSeg[slot][i] = run

			local riser = Turbine.UI.Control()
			riser:SetParent(self)
			riser:SetVisible(false)
			riser:SetMouseVisible(false)
			riser:SetZOrder(Z_RISER)
			self.vSeg[slot][i] = riser
		end
	end
end

-- The two dim washes covering everything outside the selected range, plus a 1px accent vertical
-- at each handle position. Mouse-invisible, so hovering the plot still reaches the ground.
function Graph:BuildRangeOverlay()
	local function Wash()
		local c = Turbine.UI.Control()
		c:SetParent(self)
		c:SetBackColor(Theme.Mix(Theme.Hex.RangeDim, Theme.Hex.PlotFill, 0.72))
		c:SetVisible(false)
		c:SetMouseVisible(false)
		c:SetZOrder(Z_RANGE)
		return c
	end

	local function Marker()
		local c = Turbine.UI.Control()
		c:SetParent(self)
		c:SetSize(1, PLOT_HEIGHT)
		c:SetBackColor(Theme.Color(Theme.Hex.Accent))
		c:SetVisible(false)
		c:SetMouseVisible(false)
		c:SetZOrder(Z_RANGE)
		return c
	end

	self.dimLeft, self.dimRight = Wash(), Wash()
	self.markerA, self.markerB = Marker(), Marker()
end

-- One 16px lane per charted buff: a 2px rail, up to LANE_SEGMENTS pooled interval segments on
-- it, and the buff's 16x16 icon closing the lane on the right. The icon replaces the name
-- entirely -- three names at Verdana10 was the noisiest thing on the plot, and the icon is how a
-- player actually recognises a buff.
function Graph:BuildLanes()
	self.lanes = {}

	for i = 1, MAX_LANES do
		local rail = Turbine.UI.Control()
		rail:SetParent(self)
		rail:SetSize(1, 2)
		rail:SetBackColor(Theme.Color(Theme.Hex.PlotBorder))
		rail:SetVisible(false)
		rail:SetMouseVisible(false)

		local segments = {}
		for k = 1, LANE_SEGMENTS do
			local seg = Turbine.UI.Control()
			seg:SetParent(self)
			seg:SetSize(2, 6)
			seg:SetVisible(false)
			seg:SetMouseVisible(false)
			segments[k] = seg
		end

		-- Icon tile: a lane-coloured 1px border (an inset Control, as everywhere else) around
		-- either the real client art or, when GetIcon() gave us nothing, the buff's initials.
		-- Falling back to a plain tile rather than shifting the lane keeps the geometry fixed
		-- whether or not the art resolves.
		local icon = Turbine.UI.Control()
		icon:SetParent(self)
		icon:SetSize(LANE_ICON_SIZE, LANE_ICON_SIZE)
		icon:SetVisible(false)
		icon:SetMouseVisible(false)

		local iconInset = Turbine.UI.Control()
		iconInset:SetParent(icon)
		iconInset:SetPosition(1, 1)
		iconInset:SetSize(LANE_ICON_SIZE - 2, LANE_ICON_SIZE - 2)
		iconInset:SetBackColor(Theme.Color(Theme.Hex.RailFill))
		iconInset:SetMouseVisible(false)

		local iconLabel = Turbine.UI.Label()
		iconLabel:SetParent(icon)
		iconLabel:SetFont(Font.Verdana10)
		iconLabel:SetPosition(0, 0)
		iconLabel:SetSize(LANE_ICON_SIZE, LANE_ICON_SIZE)
		iconLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
		iconLabel:SetMouseVisible(false)

		self.lanes[i] = {
			rail = rail, segments = segments,
			icon = icon, iconInset = iconInset, iconLabel = iconLabel,
		}
	end
end

function Graph:BuildSlider()
	local graph = self
	self.slider = RangeSlider(self.plotWidth, BUCKET_COUNT)
	self.slider:SetParent(self)
	self.slider.OnChange = function(from, to)
		graph.rangeFrom = from
		graph.rangeTo = to
		graph:DrawRangeOverlay()
		if graph.OnRangeChanged ~= nil then
			graph.OnRangeChanged(from, to)
		end
	end
end

function Graph:BuildTimeline()
	self.timelineLabels = {}
	for i = 1, TIMELINE_MARKS do
		local label = Turbine.UI.Label()
		label:SetParent(self)
		label:SetFont(Font.LucidaConsole12)
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetSize(TIMELINE_LABEL_WIDTH, TIMELINE_HEIGHT)
		label:SetMouseVisible(false)
		self.timelineLabels[i] = label
	end
end

function Graph:BuildLegend()
	self.legendRow = Turbine.UI.Control()
	self.legendRow:SetParent(self)
	self.legendRow:SetSize(self.plotWidth, LEGEND_HEIGHT)
	self.legendRow:SetMouseVisible(false)

	self.peakLabel = Turbine.UI.Label()
	self.peakLabel:SetParent(self.legendRow)
	self.peakLabel:SetFont(Font.LucidaConsole12)
	self.peakLabel:SetForeColor(Theme.Color(Theme.Hex.DimText))
	self.peakLabel:SetSize(240, LEGEND_HEIGHT)
	self.peakLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
	self.peakLabel:SetMouseVisible(false)
end

function Graph:BuildTooltip()
	local box = Turbine.UI.Control()
	box:SetParent(self)
	box:SetSize(TOOLTIP_WIDTH, TOOLTIP_LINES * 14 + 8)
	box:SetBackColor(Theme.Color(Theme.Hex.RailFill))
	box:SetVisible(false)
	box:SetMouseVisible(false)
	box:SetZOrder(Z_TOOLTIP)

	local border = Turbine.UI.Control()
	border:SetParent(box)
	border:SetPosition(0, 0)
	border:SetSize(TOOLTIP_WIDTH, 1)
	border:SetBackColor(Theme.Color(Theme.Hex.Border))
	border:SetMouseVisible(false)

	local lines = {}
	for i = 1, TOOLTIP_LINES do
		local label = Turbine.UI.Label()
		label:SetParent(box)
		label:SetFont(Font.Verdana10)
		label:SetPosition(6, 4 + (i - 1) * 14)
		label:SetSize(TOOLTIP_WIDTH - 12, 14)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)
		lines[i] = label
	end

	self.tooltip = { box = box, lines = lines }
end

---------------------------------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------------------------------

function Graph:BucketX(i)
	return (i - 1) * self.bucketWidth + self.bucketWidth / 2
end

function Graph:BucketAt(x)
	local i = math.floor(x / self.bucketWidth) + 1
	if i < 1 then
		return 1
	elseif i > BUCKET_COUNT then
		return BUCKET_COUNT
	end
	return i
end

-- Value -> pixel y inside the plot. TOP_PAD of headroom at the top, BOTTOM_PAD under the zero
-- baseline, so neither a peak nor an empty bucket ever sits on the frame.
function Graph:ValueY(value, maxValue)
	if maxValue <= 0 then
		return PLOT_HEIGHT - BOTTOM_PAD
	end
	local usable = PLOT_HEIGHT - TOP_PAD - BOTTOM_PAD
	return PLOT_HEIGHT - BOTTOM_PAD - math.floor(value / maxValue * usable + 0.5)
end

-- y of the top of each row under the plot, for the current lane count.
function Graph:RowTops()
	local laneStripY = PLOT_HEIGHT + LANE_STRIP_GAP
	local afterLanes = PLOT_HEIGHT
	if self.laneCount > 0 then
		afterLanes = laneStripY + self.laneCount * (LANE_HEIGHT + LANE_GAP)
	end

	local sliderY = afterLanes + SLIDER_GAP
	local timelineY = sliderY + SLIDER_HEIGHT + TIMELINE_GAP
	local legendY = timelineY + TIMELINE_HEIGHT + LEGEND_GAP

	return laneStripY, sliderY, timelineY, legendY
end

-- Positions every row under the plot for the current width and lane count, and resizes the
-- whole block. Called on construction, on resize, and whenever the charted-buff set changes.
function Graph:LayoutRows()
	local laneStripY, sliderY, timelineY, legendY = self:RowTops()

	self:SetSize(self.plotWidth, GraphHeightFor(self.laneCount))

	local railWidth = math.max(1, self.plotWidth - LANE_ICON_SIZE - LANE_RAIL_GAP)
	self.laneRailWidth = railWidth

	for i = 1, MAX_LANES do
		local lane = self.lanes[i]
		local y = laneStripY + (i - 1) * (LANE_HEIGHT + LANE_GAP)
		lane.rail:SetPosition(0, y + 7)
		lane.rail:SetSize(railWidth, 2)
		lane.icon:SetPosition(self.plotWidth - LANE_ICON_SIZE, y)
		lane.laneY = y
	end

	self.slider:SetPosition(0, sliderY)
	self.slider:Resize(self.plotWidth)

	for i = 1, TIMELINE_MARKS do
		local label = self.timelineLabels[i]
		local fraction = (i - 1) / (TIMELINE_MARKS - 1)
		local x = math.floor(fraction * self.plotWidth)

		-- First mark left-anchored, last right-anchored so it cannot run off the plot,
		-- everything between centred on its own position.
		if i == 1 then
			label:SetPosition(x, timelineY)
			label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		elseif i == TIMELINE_MARKS then
			label:SetPosition(x - TIMELINE_LABEL_WIDTH, timelineY)
			label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		else
			label:SetPosition(x - TIMELINE_LABEL_WIDTH / 2, timelineY)
			label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
		end
	end

	self.legendRow:SetPosition(0, legendY)
	self.legendRow:SetSize(self.plotWidth, LEGEND_HEIGHT)
	self.peakLabel:SetPosition(self.plotWidth - 240, 0)
end

-- Re-widths the plot in place. Bucket count stays fixed; only bucketWidth and the x-positions
-- scale. Heights/positions of the data pools are left to Redraw(), which the caller runs next.
function Graph:Resize(width)
	self.plotWidth = width
	self.bucketWidth = width / BUCKET_COUNT

	self.plotGround:SetSize(width, PLOT_HEIGHT)
	self:LayoutPlotBorder()

	for i = 1, 2 do
		self.gridlines[i]:SetSize(width, 1)
	end
	self.moraleGuideTop:SetSize(width - 2, 1)
	self.moraleGuideMid:SetSize(width - 2, 1)
	self.moraleAxisLabel:SetPosition(width - 164, 3)

	self:LayoutRows()
	self:Redraw()
end

---------------------------------------------------------------------------------------------------
-- Series / data
---------------------------------------------------------------------------------------------------

-- seriesList: { {key=, label=, colorHex=}, ... }, at most MAX_REGULAR_SERIES entries. Rebuilds
-- the legend row; does not touch data (call SetData after).
function Graph:SetSeries(seriesList)
	self.seriesList = seriesList
	self.hidden = {}

	for i = 1, table.getn(self.legendWidgets) do
		self.legendWidgets[i].swatch:SetVisible(false)
		self.legendWidgets[i].label:SetVisible(false)
	end

	local x = 0
	local graph = self
	for i = 1, table.getn(seriesList) do
		local series = seriesList[i]
		local widgets = self.legendWidgets[i]

		if widgets == nil then
			local swatch = Turbine.UI.Control()
			swatch:SetParent(self.legendRow)
			swatch:SetSize(8, 8)
			swatch:SetMouseVisible(true)

			local label = Turbine.UI.Label()
			label:SetParent(self.legendRow)
			label:SetFont(Font.Verdana10)
			label:SetSize(120, LEGEND_HEIGHT)
			label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)

			widgets = { swatch = swatch, label = label }
			self.legendWidgets[i] = widgets
		end

		widgets.swatch:SetPosition(x, math.floor((LEGEND_HEIGHT - 8) / 2))
		widgets.swatch:SetVisible(true)

		widgets.label:SetPosition(x + 12, 0)
		widgets.label:SetText(series.label)
		widgets.label:SetVisible(true)

		widgets.key = series.key
		widgets.colorHex = series.colorHex

		-- The third legend entry (morale) is a non-interactive marker, so only the real series
		-- get a click handler; a nil key means "not a series".
		local key = series.key
		if key ~= nil then
			widgets.label.MouseClick = function() graph:ToggleSeries(key) end
			widgets.swatch.MouseClick = function() graph:ToggleSeries(key) end
		else
			widgets.label.MouseClick = nil
			widgets.swatch.MouseClick = nil
		end

		x = x + 18 + 12 + string.len(series.label) * 6
	end

	self.legendCount = table.getn(seriesList)
	self:RefreshLegendColors()
end

function Graph:ToggleSeries(key)
	self.hidden[key] = not self.hidden[key]
	self:Redraw()
end

-- A hidden series keeps its legend entry but drops to the "off" colours, so it is obvious the
-- data is hidden rather than absent.
function Graph:RefreshLegendColors()
	for i = 1, table.getn(self.legendWidgets) do
		local widgets = self.legendWidgets[i]
		if widgets.label:IsVisible() then
			local off = (widgets.key ~= nil and self.hidden[widgets.key])
			widgets.swatch:SetBackColor(Theme.Color(off and "#3a3d4e" or widgets.colorHex))
			widgets.label:SetForeColor(Theme.Color(off and Theme.Hex.Disabled or widgets.colorHex))
		end
	end
end

-- Adds the non-interactive morale entry after the real series (or removes it), so the legend
-- explains the background bars on the two views that carry them.
function Graph:SetSeriesWithMorale(seriesList, showMorale)
	local list = {}
	for i = 1, table.getn(seriesList) do
		list[i] = seriesList[i]
	end
	if showMorale then
		list[table.getn(list) + 1] =
			{ key = nil, label = "MORALE (background)", colorHex = Theme.Hex.MoraleLegend }
	end
	self:SetSeries(list)
end

-- session: the Session to plot. showMorale: whether this view reads your own vitals (morale is
-- incoming context, so it draws on `taken` and `healIn` only). filterWho: optional counterpart
-- name -- when set, reads each bucket's per-counterpart breakdown (Session.lua's *ByWho tables)
-- instead of the pooled scalar, so the plot respects the window's picker the same way the
-- KPIs/table/side panels do.
function Graph:SetData(session, showMorale, filterWho)
	self.session = session
	self.showMorale = showMorale
	self.filterWho = filterWho

	local duration = session and session:Duration() or 0
	if duration <= 0 then
		duration = 1
	end
	self.duration = duration

	for i = 1, TIMELINE_MARKS do
		local seconds = (i - 1) / (TIMELINE_MARKS - 1) * duration
		self.timelineLabels[i]:SetText(Format.Clock(seconds))
	end

	self.slices = {}
	for i = 1, BUCKET_COUNT do
		self.slices[i] = {}
	end

	local sampled = {}
	if session ~= nil then
		for second, bucket in pairs(session.buckets) do
			local slice = math.floor(second / duration * BUCKET_COUNT) + 1
			if slice < 1 then slice = 1 end
			if slice > BUCKET_COUNT then slice = BUCKET_COUNT end

			for i = 1, table.getn(self.seriesList) do
				local key = self.seriesList[i].key
				if key ~= nil then
					local value
					if filterWho ~= nil then
						local byWho = bucket[key .. "ByWho"]
						value = (byWho and byWho[filterWho]) or 0
					else
						value = bucket[key] or 0
					end
					self.slices[slice][key] = (self.slices[slice][key] or 0) + value
				end
			end

			-- Morale is the local player's own vitals, not per-counterpart -- the picker filter
			-- never applies to it.
			if bucket.moralePct ~= nil then
				sampled[slice] = bucket.moralePct
			end
		end
	end

	-- A second in which you took no damage is not a second at 0 morale: only AddTaken samples
	-- morale, so unsampled slices carry the last known value forward. Leading slices (before
	-- the first sample) carry the first known value *backward* for the same reason -- the bar
	-- graph is a readout of where your morale was, and a hole in the sampling is not a dip.
	self.moraleBySlice = {}
	local firstKnown = nil
	for i = 1, BUCKET_COUNT do
		if sampled[i] ~= nil then
			firstKnown = sampled[i]
			break
		end
	end

	local lastKnown = firstKnown
	for i = 1, BUCKET_COUNT do
		if sampled[i] ~= nil then
			lastKnown = sampled[i]
		end
		self.moraleBySlice[i] = lastKnown
	end

	self:Redraw()
end

-- Charted self-buffs: { { name=, colorHex=, initials=, icon=, intervals={ {s=,e=}, ... } }, ... },
-- at most MAX_LANES. Changes the block's height, so the caller re-runs its own layout after.
function Graph:SetLanes(lanes)
	lanes = lanes or {}
	local count = table.getn(lanes)
	if count > MAX_LANES then
		count = MAX_LANES
	end

	self.laneData = lanes
	self.laneCount = count
	self:LayoutRows()
	self:DrawLanes()
end

function Graph:SetRange(from, to)
	self.rangeFrom = from
	self.rangeTo = to
	self.slider:SetRange(from, to)
	self:DrawRangeOverlay()
end

---------------------------------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------------------------------

-- One step of the polyline, as an L: the horizontal run sits at the midpoint height between the
-- two values, the riser closes the gap at the run's right end. The riser is a z-order below the
-- runs so the joint has no visible seam where the two strokes overlap.
local function DrawStep(run, riser, x0, y0, x1, y1, color)
	local yMid = math.floor((y0 + y1) / 2)

	run:SetPosition(math.floor(x0), yMid)
	run:SetSize(math.max(1, math.floor(x1 - x0)), STROKE)
	run:SetBackColor(color)
	run:SetVisible(true)

	local top = math.min(y0, y1)
	local height = math.abs(y1 - y0) + STROKE
	riser:SetPosition(math.floor(x1) - 1, top)
	riser:SetSize(STROKE, height)
	riser:SetBackColor(color)
	riser:SetVisible(math.abs(y1 - y0) > 0)
end

function Graph:Redraw()
	local maxValue = 0
	for slot = 1, table.getn(self.seriesList) do
		local key = self.seriesList[slot].key
		if key ~= nil and not self.hidden[key] then
			for i = 1, BUCKET_COUNT do
				local v = self.slices[i][key] or 0
				if v > maxValue then
					maxValue = v
				end
			end
		end
	end

	self:DrawMorale()
	self:DrawSeries(maxValue)
	self:DrawRangeOverlay()
	self:DrawLanes()
	self:RefreshLegendColors()

	for i = 1, 2 do
		self.gridlines[i]:SetPosition(1, math.floor(PLOT_HEIGHT * i / 4) - 1)
		self.gridlines[i]:SetSize(self.plotWidth - 2, 1)
	end
end

function Graph:DrawMorale()
	local show = self.showMorale and true or false

	self.moraleGuideTop:SetVisible(show)
	self.moraleGuideMid:SetVisible(show)
	self.moraleAxisLabel:SetVisible(show)

	if show then
		self.moraleGuideTop:SetPosition(1, 1)
		self.moraleGuideTop:SetSize(self.plotWidth - 2, 1)
		self.moraleGuideMid:SetPosition(1, math.floor(PLOT_HEIGHT / 2))
		self.moraleGuideMid:SetSize(self.plotWidth - 2, 1)

		-- The axis label is the session's own peak morale in POINTS, not a percentage, and is
		-- deliberately never rescoped by the range slider: it is the fixed reference the bars
		-- are drawn against, so it has to stay put while the range moves.
		local peak = 0
		for i = 1, BUCKET_COUNT do
			local pct = self.moraleBySlice[i]
			if pct ~= nil and pct > peak then
				peak = pct
			end
		end

		local maxMorale = nil
		if _G.lp ~= nil and _G.lp.GetMaxMorale ~= nil then
			maxMorale = _G.lp:GetMaxMorale()
		end

		if maxMorale ~= nil and maxMorale > 0 then
			self.moraleAxisLabel:SetText("MORALE " .. Format.Number(peak * maxMorale))
		else
			self.moraleAxisLabel:SetText("MORALE " .. Format.Percent(peak))
		end
		self.moraleAxisLabel:SetPosition(self.plotWidth - 164, 3)
	end

	local barWidth = math.max(1, math.floor(self.bucketWidth) - 2)

	for i = 1, BUCKET_COUNT do
		local bar = self.moraleBars[i]
		local edge = self.moraleEdges[i]
		local pct = show and self.moraleBySlice[i] or nil

		if pct == nil then
			bar:SetVisible(false)
			edge:SetVisible(false)
		else
			if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end

			local height = math.max(1, math.floor(pct * (PLOT_HEIGHT - 2)))
			local x = math.floor((i - 1) * self.bucketWidth) + 1
			local y = PLOT_HEIGHT - 1 - height
			local low = (pct < MORALE_DANGER)

			bar:SetPosition(x, y)
			bar:SetSize(barWidth, height)
			bar:SetBackColor(Theme.Color(low and Theme.Hex.MoraleBgLow or Theme.Hex.MoraleBg))
			bar:SetVisible(true)

			edge:SetPosition(x, y)
			edge:SetSize(barWidth, 1)
			edge:SetBackColor(Theme.Color(low and Theme.Hex.MoraleBgLowEdge or Theme.Hex.MoraleBgEdge))
			edge:SetVisible(true)
		end
	end
end

function Graph:DrawSeries(maxValue)
	for slot = 1, MAX_REGULAR_SERIES do
		local series = self.seriesList[slot]
		local live = (series ~= nil and series.key ~= nil and not self.hidden[series.key])

		if not live then
			for i = 1, BUCKET_COUNT do
				self.dots[slot][i]:SetVisible(false)
			end
			for i = 1, BUCKET_COUNT - 1 do
				self.hSeg[slot][i]:SetVisible(false)
				self.vSeg[slot][i]:SetVisible(false)
			end
		else
			local color = Theme.Color(series.colorHex)
			local key = series.key

			for i = 1, BUCKET_COUNT - 1 do
				local y0 = self:ValueY(self.slices[i][key] or 0, maxValue)
				local y1 = self:ValueY(self.slices[i + 1][key] or 0, maxValue)
				DrawStep(self.hSeg[slot][i], self.vSeg[slot][i],
					self:BucketX(i), y0, self:BucketX(i + 1), y1, color)
			end

			-- A dot on every bucket at 48 buckets is noise, so only odd indices carry one
			-- (1-based odd == the mock's 0-based even) -- plus both range endpoints, which are
			-- the two the reader is actually looking for while dragging a handle.
			for i = 1, BUCKET_COUNT do
				local dot = self.dots[slot][i]
				local wanted = (i % 2 == 1) or (i == self.rangeFrom) or (i == self.rangeTo)
				if wanted then
					local y = self:ValueY(self.slices[i][key] or 0, maxValue)
					dot:SetPosition(
						math.floor(self:BucketX(i) - DOT_SIZE / 2),
						y - math.floor(DOT_SIZE / 2))
					dot:SetBackColor(color)
					dot:SetVisible(true)
				else
					dot:SetVisible(false)
				end
			end
		end
	end
end

function Graph:DrawRangeOverlay()
	local function StopX(bucket)
		return math.floor((bucket - 1) / (BUCKET_COUNT - 1) * self.plotWidth)
	end

	local ax, bx = StopX(self.rangeFrom), StopX(self.rangeTo)
	local full = (self.rangeFrom == 1 and self.rangeTo == BUCKET_COUNT)

	if ax > 0 then
		self.dimLeft:SetPosition(0, 0)
		self.dimLeft:SetSize(ax, PLOT_HEIGHT)
		self.dimLeft:SetVisible(true)
	else
		self.dimLeft:SetVisible(false)
	end

	if bx < self.plotWidth then
		self.dimRight:SetPosition(bx, 0)
		self.dimRight:SetSize(self.plotWidth - bx, PLOT_HEIGHT)
		self.dimRight:SetVisible(true)
	else
		self.dimRight:SetVisible(false)
	end

	self.markerA:SetPosition(ax, 0)
	self.markerA:SetVisible(not full)
	self.markerB:SetPosition(math.max(0, bx - 1), 0)
	self.markerB:SetVisible(not full)

	self:RefreshPeakLine()
end

-- The legend's right-hand readout: peak and low morale FOR THE SELECTED RANGE (unlike the axis
-- label, which stays session-wide). Blank on the two views that carry no morale.
function Graph:RefreshPeakLine()
	if not self.showMorale then
		self.peakLabel:SetText("")
		return
	end

	local peak, low = nil, nil
	for i = self.rangeFrom, self.rangeTo do
		local pct = self.moraleBySlice[i]
		if pct ~= nil then
			if peak == nil or pct > peak then peak = pct end
			if low == nil or pct < low then low = pct end
		end
	end

	if peak == nil then
		self.peakLabel:SetText("")
	else
		self.peakLabel:SetText("peak morale " .. Format.Percent(peak) .. " · low " .. Format.Percent(low))
	end
end

function Graph:DrawLanes()
	local railWidth = self.laneRailWidth or math.max(1, self.plotWidth - LANE_ICON_SIZE - LANE_RAIL_GAP)
	local duration = self.duration
	if duration <= 0 then
		duration = 1
	end

	for i = 1, MAX_LANES do
		local lane = self.lanes[i]
		local data = self.laneData and self.laneData[i] or nil
		local live = (data ~= nil and i <= self.laneCount)

		lane.rail:SetVisible(live)
		lane.icon:SetVisible(live)

		if not live then
			for k = 1, LANE_SEGMENTS do
				lane.segments[k]:SetVisible(false)
			end
		else
			local color = Theme.Color(data.colorHex)
			lane.icon:SetBackColor(color)
			lane.iconLabel:SetForeColor(color)

			-- The real client art if GetIcon() gave us an asset id, otherwise the buff's
			-- initials in the lane colour -- the same stand-in the design mock draws, at the
			-- same size, so nothing shifts when the art does resolve.
			if data.icon ~= nil then
				lane.iconInset:SetBackground(data.icon)
				lane.iconLabel:SetText("")
			else
				lane.iconLabel:SetText(data.initials or "")
			end

			local intervals = data.intervals or {}
			local n = table.getn(intervals)
			if n > LANE_SEGMENTS then
				n = LANE_SEGMENTS
			end

			for k = 1, LANE_SEGMENTS do
				local seg = lane.segments[k]
				local interval = (k <= n) and intervals[k] or nil

				if interval == nil then
					seg:SetVisible(false)
				else
					local x = math.floor(interval.s / duration * railWidth)
					local w = math.max(2, math.floor((interval.e - interval.s) / duration * railWidth))
					if x < 0 then x = 0 end
					if x + w > railWidth then w = math.max(2, railWidth - x) end

					seg:SetPosition(x, lane.laneY + 5)
					seg:SetSize(w, 6)
					seg:SetBackColor(color)
					seg:SetVisible(true)
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------------------------------

function Graph:ShowTooltip(bucketIndex)
	if self.session == nil or self.slices[bucketIndex] == nil then
		return
	end

	if self.tooltipBucket == bucketIndex and self.tooltip.box:IsVisible() then
		return -- MouseMove fires continuously; only rebuild the text when the bucket changes
	end
	self.tooltipBucket = bucketIndex

	local lines = self.tooltip.lines
	local row = 1

	local elapsed = (bucketIndex - 1) / BUCKET_COUNT * self.duration
	lines[row]:SetText(Format.Clock(elapsed))
	lines[row]:SetForeColor(Theme.Color(Theme.Hex.DimText))
	row = row + 1

	for slot = 1, table.getn(self.seriesList) do
		local series = self.seriesList[slot]
		if series.key ~= nil and row <= TOOLTIP_LINES then
			local value = self.slices[bucketIndex][series.key] or 0
			lines[row]:SetText(series.label .. ": " .. Format.Number(value))
			lines[row]:SetForeColor(Theme.Color(series.colorHex))
			row = row + 1
		end
	end

	if self.showMorale and row <= TOOLTIP_LINES then
		local pct = self.moraleBySlice[bucketIndex]
		lines[row]:SetText(pct and ("Morale: " .. Format.Percent(pct)) or "Morale: --")
		lines[row]:SetForeColor(Theme.Color(Theme.Hex.Morale))
		row = row + 1
	end

	for i = row, TOOLTIP_LINES do
		lines[i]:SetText("")
	end

	local x = math.floor((bucketIndex - 1) * self.bucketWidth) + 8
	if x > self.plotWidth - TOOLTIP_WIDTH then
		x = self.plotWidth - TOOLTIP_WIDTH
	end
	if x < 0 then
		x = 0
	end

	self.tooltip.box:SetPosition(x, TOP_PAD + 4)
	self.tooltip.box:SetVisible(true)
end

function Graph:HideTooltip()
	self.tooltipBucket = nil
	self.tooltip.box:SetVisible(false)
end
