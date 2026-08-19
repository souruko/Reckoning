--=================================================================================================
-- Graph -- the analysis window's time plot. 640x150 plot, per docs/DESIGN.md, plus a taller
-- bottom strip than the mockup's 22px (see AXIS_HEIGHT) to fit a timeline row in addition to the
-- legend, added per direct feedback. One column of Controls per bucket
-- (docs/IMPLEMENTATION_PLAN.md: "cheap to redraw, no bitmap needed") -- 48 buckets spanning the
-- session's actual duration, rebuilt only on session or view change, never per frame. No
-- animation: values are set directly.
--
-- Simplification from the mockup, flagged here rather than silently: a literal dashed line
-- needs sub-pixel line drawing Turbine.UI's axis-aligned Controls can't do cheaply. The morale
-- overlay is rendered as dot markers instead of a dashed stroke. It also gets its own reserved
-- lane at the top of the plot (MORALE_LANE_HEIGHT) rather than sharing space with the
-- damage/heal bars -- per direct feedback that overlaying dots directly on the bars read as
-- confusing (unclear which marks belonged to which series/axis). Bars are scaled to leave that
-- lane clear rather than being allowed to draw into it.
--=================================================================================================

Graph = class(Turbine.UI.Control)

local BUCKET_COUNT = 48
local PLOT_HEIGHT = 150
local MORALE_LANE_HEIGHT = 22 -- reserved strip at the TOP of the plot, dots only, bars never enter it
local TIMELINE_HEIGHT = 14
local LEGEND_HEIGHT = 18
local AXIS_HEIGHT = TIMELINE_HEIGHT + LEGEND_HEIGHT + 4
local AREA_OPACITY = 0.13
local CAP_HEIGHT = 2 -- the "line" on top of each bucket's area fill, see BuildColumns
local MAX_REGULAR_SERIES = 2 -- the busiest view (taken+healIn) never needs more than this
local TIMELINE_MARKS = 5 -- labels at 0%, 25%, 50%, 75%, 100% of the session's duration

function Graph:Constructor(width)
	Turbine.UI.Control.Constructor(self)

	self.plotWidth = width
	self.bucketWidth = width / BUCKET_COUNT

	self:SetSize(width, PLOT_HEIGHT + AXIS_HEIGHT)
	self:SetMouseVisible(false)

	self:BuildGridlines()
	self:BuildColumns()
	self:BuildMoraleLane()
	self:BuildTimeline()
	self:BuildAxis()

	self.seriesList = {}
	self.hidden = {}
	self.legendWidgets = {}
end

function Graph:BuildGridlines()
	self.gridlines = {}
	for i = 1, 4 do
		local line = Turbine.UI.Control()
		line:SetParent(self)
		line:SetPosition(0, math.floor(PLOT_HEIGHT * i / 5))
		line:SetSize(self.plotWidth, 1)
		line:SetBackColor(Theme.Mix("#ffffff", Theme.Hex.WindowFill, 0.05))
		line:SetMouseVisible(false)
		self.gridlines[i] = line
	end
end

-- Up to MAX_REGULAR_SERIES translucent columns per bucket, pooled once and reused for whichever
-- series the active view actually has (docs/IMPLEMENTATION_PLAN.md "Performance notes": never
-- rebuild per refresh). Each column also gets a "cap" -- a solid-colour 2px sliver at the top,
-- since a 13%-opacity area fill *alone* reads as "nothing" against a similarly dark background
-- (confirmed in-game: real damage data produced a graph that looked empty). The mockup's own
-- spec is "area fill... under a line" -- the cap is that line, just drawn as one short segment
-- per bucket rather than a single continuous stroke (same one-Control-per-bucket technique as
-- everything else here; a real polyline isn't cheap to draw with axis-aligned Controls).
function Graph:BuildColumns()
	self.columns = {}
	self.caps = {}
	for slot = 1, MAX_REGULAR_SERIES do
		self.columns[slot] = {}
		self.caps[slot] = {}
		for i = 1, BUCKET_COUNT do
			local col = Turbine.UI.Control()
			col:SetParent(self)
			col:SetPosition(math.floor((i - 1) * self.bucketWidth), PLOT_HEIGHT)
			col:SetSize(math.max(1, math.floor(self.bucketWidth) - 1), 0)
			col:SetVisible(false)
			col:SetMouseVisible(false)
			self.columns[slot][i] = col

			local cap = Turbine.UI.Control()
			cap:SetParent(self)
			cap:SetSize(math.max(1, math.floor(self.bucketWidth) - 1), CAP_HEIGHT)
			cap:SetVisible(false)
			cap:SetMouseVisible(false)
			self.caps[slot][i] = cap
		end
	end
end

-- The morale trace's own reserved strip at the top of the plot, plus a divider line marking
-- where it ends and the damage/heal bars begin (only shown when a view actually carries morale).
function Graph:BuildMoraleLane()
	self.moraleLaneLine = Turbine.UI.Control()
	self.moraleLaneLine:SetParent(self)
	self.moraleLaneLine:SetPosition(0, MORALE_LANE_HEIGHT)
	self.moraleLaneLine:SetSize(self.plotWidth, 1)
	self.moraleLaneLine:SetBackColor(Theme.Mix("#ffffff", Theme.Hex.WindowFill, 0.1))
	self.moraleLaneLine:SetVisible(false)
	self.moraleLaneLine:SetMouseVisible(false)

	self.moraleDots = {}
	for i = 1, BUCKET_COUNT do
		local dot = Turbine.UI.Control()
		dot:SetParent(self)
		dot:SetSize(3, 3)
		dot:SetBackColor(Theme.Color(Theme.Hex.Morale))
		dot:SetVisible(false)
		dot:SetMouseVisible(false)
		self.moraleDots[i] = dot
	end
end

-- 5 evenly-spaced elapsed-time labels under the plot, refreshed in SetData against the actual
-- session duration (a fixed bucket count spanning a variable-length fight, so "how many seconds
-- per bucket" only makes sense once a session is known).
function Graph:BuildTimeline()
	self.timelineLabels = {}
	for i = 1, TIMELINE_MARKS do
		local label = Turbine.UI.Label()
		label:SetParent(self)
		label:SetFont(Font.Verdana10)
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetPosition(0, PLOT_HEIGHT + 2)
		label:SetSize(40, TIMELINE_HEIGHT)
		label:SetMouseVisible(false)
		self.timelineLabels[i] = label
	end
	self:LayoutTimeline()
end

function Graph:LayoutTimeline()
	for i = 1, TIMELINE_MARKS do
		local label = self.timelineLabels[i]
		local fraction = (i - 1) / (TIMELINE_MARKS - 1)
		local x = math.floor(fraction * self.plotWidth)

		-- First mark left-anchored, last mark right-anchored (so it doesn't run off the plot),
		-- everything in between centred on its position.
		if i == 1 then
			label:SetPosition(x, PLOT_HEIGHT + 2)
			label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		elseif i == TIMELINE_MARKS then
			label:SetPosition(x - 40, PLOT_HEIGHT + 2)
			label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		else
			label:SetPosition(x - 20, PLOT_HEIGHT + 2)
			label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
		end
	end
end

function Graph:BuildAxis()
	self.moraleAxisLabel = Turbine.UI.Label()
	self.moraleAxisLabel:SetParent(self)
	self.moraleAxisLabel:SetFont(Font.Verdana10)
	self.moraleAxisLabel:SetForeColor(Theme.Color(Theme.Hex.Morale))
	self.moraleAxisLabel:SetPosition(self.plotWidth - 70, 2)
	self.moraleAxisLabel:SetSize(70, 12)
	self.moraleAxisLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
	self.moraleAxisLabel:SetMouseVisible(false)
	self.moraleAxisLabel:SetVisible(false)

	self.legendRow = Turbine.UI.Control()
	self.legendRow:SetParent(self)
	self.legendRow:SetPosition(0, PLOT_HEIGHT + TIMELINE_HEIGHT + 4)
	self.legendRow:SetSize(self.plotWidth, LEGEND_HEIGHT)
	self.legendRow:SetMouseVisible(false)
end

-- Re-widths the plot in place (gridlines, the 48-bucket column grid, morale dots, timeline,
-- legend row) without ever reparenting or destroying a Control -- see UI/Row.lua's Reconfigure
-- for why. Bucket count stays fixed at BUCKET_COUNT; only bucketWidth and every x-position scale.
-- Column heights/positions are left alone here -- Redraw() (called by the caller right after,
-- via SetData/Redraw) re-derives those from the current data anyway.
function Graph:Resize(width)
	self.plotWidth = width
	self.bucketWidth = width / BUCKET_COUNT
	self:SetSize(width, PLOT_HEIGHT + AXIS_HEIGHT)

	for i = 1, table.getn(self.gridlines) do
		self.gridlines[i]:SetSize(width, 1)
	end

	for slot = 1, MAX_REGULAR_SERIES do
		for i = 1, BUCKET_COUNT do
			local col = self.columns[slot][i]
			local _, h = col:GetSize()
			local colWidth = math.max(1, math.floor(self.bucketWidth) - 1)
			col:SetPosition(math.floor((i - 1) * self.bucketWidth), PLOT_HEIGHT - h)
			col:SetSize(colWidth, h)

			local cap = self.caps[slot][i]
			cap:SetPosition(math.floor((i - 1) * self.bucketWidth), PLOT_HEIGHT - h)
			cap:SetSize(colWidth, CAP_HEIGHT)
		end
	end

	self.moraleLaneLine:SetSize(width, 1)
	for i = 1, BUCKET_COUNT do
		local dot = self.moraleDots[i]
		local _, y = dot:GetPosition()
		dot:SetPosition(math.floor((i - 1) * self.bucketWidth + self.bucketWidth / 2), y)
	end

	self:LayoutTimeline()
	self.moraleAxisLabel:SetPosition(width - 70, 2)
	self.legendRow:SetSize(width, LEGEND_HEIGHT)
end

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
			swatch:SetMouseVisible(false)

			local label = Turbine.UI.Label()
			label:SetParent(self.legendRow)
			label:SetFont(Font.Verdana10)
			label:SetSize(110, LEGEND_HEIGHT)
			label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)

			widgets = { swatch = swatch, label = label }
			self.legendWidgets[i] = widgets
		end

		widgets.swatch:SetPosition(x, (LEGEND_HEIGHT - 8) / 2)
		widgets.swatch:SetBackColor(Theme.Color(series.colorHex))
		widgets.swatch:SetVisible(true)

		widgets.label:SetPosition(x + 12, 0)
		widgets.label:SetText(series.label)
		widgets.label:SetForeColor(Theme.Color(series.colorHex))
		widgets.label:SetVisible(true)

		local key = series.key
		widgets.label.MouseClick = function() graph:ToggleSeries(key) end
		widgets.swatch.MouseClick = function() graph:ToggleSeries(key) end

		x = x + 122
	end
end

function Graph:ToggleSeries(key)
	self.hidden[key] = not self.hidden[key]
	self:Redraw()
end

-- session: the Session to plot. showMorale: whether this view carries the morale overlay.
-- Buckets are per-second (Session.buckets); this maps that onto BUCKET_COUNT slices spanning
-- the session's actual duration, summing values that land in the same slice.
function Graph:SetData(session, showMorale)
	self.session = session
	self.showMorale = showMorale

	local duration = session and session:Duration() or 0
	if duration <= 0 then
		duration = 1
	end
	self.duration = duration

	for i = 1, TIMELINE_MARKS do
		local seconds = math.floor((i - 1) / (TIMELINE_MARKS - 1) * duration + 0.5)
		self.timelineLabels[i]:SetText(seconds .. "s")
	end

	self.slices = {}
	for i = 1, BUCKET_COUNT do
		self.slices[i] = {}
	end
	self.moraleBySlice = {}

	if session ~= nil then
		for second, bucket in pairs(session.buckets) do
			local slice = math.floor(second / duration * BUCKET_COUNT) + 1
			if slice < 1 then slice = 1 end
			if slice > BUCKET_COUNT then slice = BUCKET_COUNT end

			for i = 1, table.getn(self.seriesList) do
				local key = self.seriesList[i].key
				self.slices[slice][key] = (self.slices[slice][key] or 0) + (bucket[key] or 0)
			end

			if bucket.moralePct ~= nil then
				self.moraleBySlice[slice] = bucket.moralePct
			end
		end
	end

	self:Redraw()
end

function Graph:Redraw()
	local maxValue = 0
	for slot = 1, table.getn(self.seriesList) do
		local key = self.seriesList[slot].key
		if not self.hidden[key] then
			for i = 1, BUCKET_COUNT do
				local v = self.slices[i][key] or 0
				if v > maxValue then
					maxValue = v
				end
			end
		end
	end

	-- Bars are scaled against the space below the morale lane, never drawn into it, so the two
	-- traces can never visually collide -- the lane only exists (and only reserves height) on
	-- views that actually carry a morale series.
	local barAreaHeight = self.showMorale and (PLOT_HEIGHT - MORALE_LANE_HEIGHT) or PLOT_HEIGHT

	for slot = 1, MAX_REGULAR_SERIES do
		local series = self.seriesList[slot]
		for i = 1, BUCKET_COUNT do
			local col = self.columns[slot][i]
			local cap = self.caps[slot][i]
			if series == nil or self.hidden[series.key] then
				col:SetVisible(false)
				cap:SetVisible(false)
			else
				local value = self.slices[i][series.key] or 0
				local h = 0
				if value > 0 and maxValue > 0 then
					-- at least 1px so a small bucket next to a huge one still shows *something*,
					-- same rounding philosophy as UI/Bar.lua's SetPercent
					h = math.max(1, math.floor(value / maxValue * barAreaHeight))
				end

				local colWidth = math.max(1, math.floor(self.bucketWidth) - 1)
				col:SetBackColor(Theme.Mix(series.colorHex, Theme.Hex.WindowFill, AREA_OPACITY))
				col:SetPosition(math.floor((i - 1) * self.bucketWidth), PLOT_HEIGHT - h)
				col:SetSize(colWidth, h)
				col:SetVisible(h > 0)

				cap:SetBackColor(Theme.Color(series.colorHex))
				cap:SetPosition(math.floor((i - 1) * self.bucketWidth), PLOT_HEIGHT - h)
				cap:SetSize(colWidth, CAP_HEIGHT)
				cap:SetVisible(h > 0)
			end
		end
	end

	self.moraleAxisLabel:SetVisible(self.showMorale)
	self.moraleLaneLine:SetVisible(self.showMorale)
	if self.showMorale then
		self.moraleAxisLabel:SetText("MORALE")
	end

	for i = 1, BUCKET_COUNT do
		local dot = self.moraleDots[i]
		local pct = self.moraleBySlice[i]
		if self.showMorale and pct ~= nil then
			if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
			dot:SetPosition(
				math.floor((i - 1) * self.bucketWidth + self.bucketWidth / 2),
				math.floor((1 - pct) * MORALE_LANE_HEIGHT))
			dot:SetVisible(true)
		else
			dot:SetVisible(false)
		end
	end
end
