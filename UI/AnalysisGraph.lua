--=================================================================================================
-- Graph -- the analysis window's time plot. 640x150 plot + 22px axis strip, per
-- docs/DESIGN.md. One column of Controls per bucket (docs/IMPLEMENTATION_PLAN.md: "cheap to
-- redraw, no bitmap needed") -- 48 buckets spanning the session's actual duration, rebuilt only
-- on session or view change, never per frame. No animation: values are set directly.
--
-- Simplification from the mockup, flagged here rather than silently: a literal dashed line
-- needs sub-pixel line drawing Turbine.UI's axis-aligned Controls can't do cheaply. The morale
-- overlay is rendered as small dot markers instead of a dashed stroke -- visually a scatter
-- trace rather than a continuous dashed line. Revisit in-game if it reads worse than expected.
--=================================================================================================

Graph = class(Turbine.UI.Control)

local BUCKET_COUNT = 48
local PLOT_HEIGHT = 150
local AXIS_HEIGHT = 22
local AREA_OPACITY = 0.13
local MAX_REGULAR_SERIES = 2 -- the busiest view (taken+healIn) never needs more than this

function Graph:Constructor(width)
	Turbine.UI.Control.Constructor(self)

	self.plotWidth = width
	self.bucketWidth = width / BUCKET_COUNT

	self:SetSize(width, PLOT_HEIGHT + AXIS_HEIGHT)
	self:SetMouseVisible(false)

	self:BuildGridlines()
	self:BuildColumns()
	self:BuildMoraleDots()
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
		line:SetBackColor(Turbine.UI.Color(1, 1, 1))
		line:SetOpacity(0.05)
		line:SetMouseVisible(false)
		self.gridlines[i] = line
	end
end

-- Up to MAX_REGULAR_SERIES translucent columns per bucket, pooled once and reused for whichever
-- series the active view actually has (docs/IMPLEMENTATION_PLAN.md "Performance notes": never
-- rebuild per refresh).
function Graph:BuildColumns()
	self.columns = {}
	for slot = 1, MAX_REGULAR_SERIES do
		self.columns[slot] = {}
		for i = 1, BUCKET_COUNT do
			local col = Turbine.UI.Control()
			col:SetParent(self)
			col:SetPosition(math.floor((i - 1) * self.bucketWidth), PLOT_HEIGHT)
			col:SetSize(math.max(1, math.floor(self.bucketWidth) - 1), 0)
			col:SetOpacity(AREA_OPACITY)
			col:SetVisible(false)
			col:SetMouseVisible(false)
			self.columns[slot][i] = col
		end
	end
end

function Graph:BuildMoraleDots()
	self.moraleDots = {}
	for i = 1, BUCKET_COUNT do
		local dot = Turbine.UI.Control()
		dot:SetParent(self)
		dot:SetSize(2, 2)
		dot:SetBackColor(Theme.Color(Theme.Hex.Morale))
		dot:SetVisible(false)
		dot:SetMouseVisible(false)
		self.moraleDots[i] = dot
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
	self.legendRow:SetPosition(0, PLOT_HEIGHT + 4)
	self.legendRow:SetSize(self.plotWidth, AXIS_HEIGHT - 4)
	self.legendRow:SetMouseVisible(false)
end

-- Re-widths the plot in place (gridlines, the 48-bucket column grid, morale dots, legend row)
-- without ever reparenting or destroying a Control -- see UI/Row.lua's Reconfigure for why.
-- Bucket count stays fixed at BUCKET_COUNT; only bucketWidth and every x-position scale.
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
			col:SetPosition(math.floor((i - 1) * self.bucketWidth), PLOT_HEIGHT - h)
			col:SetSize(math.max(1, math.floor(self.bucketWidth) - 1), h)
		end
	end

	for i = 1, BUCKET_COUNT do
		local dot = self.moraleDots[i]
		local x, y = dot:GetPosition()
		dot:SetPosition(math.floor((i - 1) * self.bucketWidth + self.bucketWidth / 2), y)
	end

	self.moraleAxisLabel:SetPosition(width - 70, 2)
	self.legendRow:SetSize(width, AXIS_HEIGHT - 4)
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
			label:SetSize(110, AXIS_HEIGHT - 4)
			label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)

			widgets = { swatch = swatch, label = label }
			self.legendWidgets[i] = widgets
		end

		widgets.swatch:SetPosition(x, (AXIS_HEIGHT - 4 - 8) / 2)
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

	for slot = 1, MAX_REGULAR_SERIES do
		local series = self.seriesList[slot]
		for i = 1, BUCKET_COUNT do
			local col = self.columns[slot][i]
			if series == nil or self.hidden[series.key] then
				col:SetVisible(false)
			else
				local value = self.slices[i][series.key] or 0
				local h = (maxValue > 0) and math.floor(value / maxValue * PLOT_HEIGHT) or 0
				col:SetBackColor(Theme.Color(series.colorHex))
				col:SetPosition(math.floor((i - 1) * self.bucketWidth), PLOT_HEIGHT - h)
				col:SetSize(math.max(1, math.floor(self.bucketWidth) - 1), h)
				col:SetVisible(h > 0)
			end
		end
	end

	self.moraleAxisLabel:SetVisible(self.showMorale)
	if self.showMorale then
		self.moraleAxisLabel:SetText("MORALE")
	end

	for i = 1, BUCKET_COUNT do
		local dot = self.moraleDots[i]
		local pct = self.moraleBySlice[i]
		if self.showMorale and pct ~= nil then
			dot:SetPosition(math.floor((i - 1) * self.bucketWidth + self.bucketWidth / 2), PLOT_HEIGHT - math.floor(pct * PLOT_HEIGHT))
			dot:SetVisible(true)
		else
			dot:SetVisible(false)
		end
	end
end
