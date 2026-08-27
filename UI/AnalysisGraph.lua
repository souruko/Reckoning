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
-- REAL DIAGONALS, and every word of how they are drawn was paid for by six rounds of in-game
-- probing (`/reck probe`, UI/RotationProbe.lua; the answers are in GRAPH_RESEARCH.md section 7).
-- Turbine has no canvas and no line primitive, so a diagonal can only come from rotating an
-- axis-aligned control, and `SetRotation` here has four properties that together dictate the
-- entire shape of this code:
--
--   1. It is ABSENT on `Turbine.UI.Control` and present on `Turbine.UI.Window`. Every segment in
--      the pool is therefore a Window, not a Control. This is not a preference.
--   2. **A rotation set before the control has painted is silently dropped.** One apply on a
--      LATER frame is enough and it sticks -- hence `rotateIn` and `FlushRotation` below, and
--      hence Analysis:Update, which is the only thing that calls it. A segment is therefore drawn
--      HIDDEN and revealed by that pass: between being sized and being rotated it would paint
--      flat, which reads in-game as the whole line snapping to a horizontal bar on every redraw.
--   3. **The control's rect never rotates -- the IMAGE is rotated and then FITTED to the rect.**
--      So a thin 2px control can never be a diagonal at any angle: a rotated white rectangle
--      refitted into a 2px slot is still a 2px horizontal bar. The segment control is instead a
--      SQUARE whose side is the segment's own LENGTH, centred on the segment's midpoint, carrying
--      a sprite with a full-width band through its middle. A square rect
--      makes the fit a uniform scale, so the rotated band stays a straight line at exactly the
--      angle asked for, running from one data point to the other and stopping. Any other aspect
--      ratio shears it off its angle.
--   4. Positive z turns the OPPOSITE way from screen-space convention, so the angle is NEGATED.
--      Without that every segment draws mirrored about its own midpoint -- right length, right
--      centre, both ends on the wrong side, so nothing meets at the joints.
--
-- Scaling an image also needs an exact call order -- size the control to the IMAGE's own size,
-- `SetBackground`, `SetStretchMode(1)`, and only THEN size it to the target. With the target size
-- set first, every stretch mode tiles instead. `DrawSegment` follows it literally.
--
-- The squares overlap heavily by construction (each is as wide as its segment is long) and that is
-- fine: the sprite is transparent outside its band, which round six confirmed composes correctly.
--
-- Everything is pooled once in the constructor and only ever repositioned/recoloured -- never
-- rebuilt per refresh, never reparented, never detached (Turbine has no confirmed-safe
-- "detach a child" call anywhere in this codebase -- see UI/Row.lua's Reconfigure).
--=================================================================================================

Graph = class(Turbine.UI.Control)

-- POOL SIZE, and the bucket count under "Auto". Every pool in this file is built at MAX_BUCKETS
-- once and never grows; settings.bucketWidth (options window, Sessions page) can ask for FEWER
-- buckets than this, never more, and the surplus pool entries are simply hidden.
local MAX_BUCKETS = 48
local MIN_BUCKETS = 2 -- one step needs two points, and the range slider needs two distinct stops

local MAX_REGULAR_SERIES = 2 -- the busiest view (taken+healIn) never needs more than this
local MAX_LANES = 3          -- max charted buffs, matching Theme.BuffLane's three colours

local PLOT_HEIGHT = 150
local TOP_PAD     = 22 -- headroom, so a peak bucket never touches the frame
local BOTTOM_PAD  = 4  -- the zero baseline sits this far above the plot's bottom edge
local DOT_SIZE    = 5

-- THE STROKE LADDER. Each sprite is a square with a full-width band through its centre and
-- transparent elsewhere -- see the header for why square is the whole trick.
--
-- The catch that made the first version look wrong in-game: the segment control is sized to the
-- segment's own LENGTH, and the band is a FRACTION of the sprite, so with one sprite the drawn
-- stroke is proportional to length -- about 1px across a flat second and 6px up a steep spike.
-- So there is a sprite per band width and DrawSegment picks the rung whose `band * side / 64`
-- lands nearest STROKE_TARGET, which holds the stroke between roughly 1.7 and 2.2px across every
-- length the plot produces. The 1.5 rung is not padding: whole-pixel bands can only manage 1.4 or
-- 2.8px on the longest segments, and that gap is visible.
--
-- Must match tools/icons/build_icons.py's own list.
local STROKE_NATIVE = 64
local STROKE_TARGET = 2 -- the stroke width the ladder is chosen to hold, in pixels
local STROKE_SPRITES = {
	{ band = 1.0, image = "Reckoning/Resources/stroke_10.tga" },
	{ band = 1.5, image = "Reckoning/Resources/stroke_15.tga" },
	{ band = 2.0, image = "Reckoning/Resources/stroke_20.tga" },
	{ band = 2.5, image = "Reckoning/Resources/stroke_25.tga" },
	{ band = 3.0, image = "Reckoning/Resources/stroke_30.tga" },
	{ band = 4.0, image = "Reckoning/Resources/stroke_40.tga" },
	{ band = 5.0, image = "Reckoning/Resources/stroke_50.tga" },
	{ band = 6.0, image = "Reckoning/Resources/stroke_60.tga" },
}

local SEGMENT_MIN = 4 -- a square smaller than this cannot show a band at all

-- The rung whose drawn stroke comes closest to STROKE_TARGET at this segment length. Eight
-- comparisons per segment, ~750 per redraw, and redraws are not per-frame.
local function StrokeSprite(side)
	local best, bestErr = STROKE_SPRITES[1], nil
	for i = 1, table.getn(STROKE_SPRITES) do
		local rung = STROKE_SPRITES[i]
		local err = math.abs(rung.band * side / STROKE_NATIVE - STROKE_TARGET)
		if bestErr == nil or err < bestErr then
			best, bestErr = rung, err
		end
	end
	return best.image
end

-- Frames to wait after a redraw before applying the rotation pass. A rotation set before the
-- control has painted is silently dropped (probe round 4), and one apply on a later frame sticks
-- (round 5), so this is a small margin rather than a repeating cost.
local ROTATE_DELAY = 2

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
local MAX_TOOLTIP_SKILLS = 4 -- skill-breakdown rows appended below the fixed lines; the last
                              -- slot becomes a "+N more" line instead of a row if there's overflow

-- Explicit z-order per pool. Creation order decides this by default, but pools are reused
-- across views and sessions for the life of the window, so nothing may depend on the order they
-- happened to be built in.
local Z_GROUND  = 0
local Z_MORALE  = 10
local Z_GUIDE   = 11
local Z_GRID    = 11
local Z_LINE    = 13
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

-- How many buckets a given session's plot uses, under the current settings.bucketWidth.
--
-- "Auto" (0, and the fallback) is what this always did: MAX_BUCKETS columns spread across however
-- long the fight was, so the plot always fills its width. 1s / 2s instead pin each bucket to that
-- many SECONDS -- for a 20-second fight at 1s that is 20 buckets, each a real second, rather than
-- 48 sub-second slivers. Long fights still cap at MAX_BUCKETS, because the pools are that size and
-- because 48 columns is already the most a 640-1400px plot can show as distinct marks; past the
-- cap, 1s and 2s and Auto are the same plot.
--
-- Called by UI/Analysis.lua too (for the range slider's stops and its seconds arithmetic), which
-- is why it is a plain global rather than a method -- exactly like GraphHeightFor above.
function GraphBucketCount(session)
	local width = tonumber(_G.settings and _G.settings.bucketWidth) or 0
	if width <= 0 then
		return MAX_BUCKETS
	end

	local duration = session and session:Duration() or 0
	if duration <= 0 then
		return MAX_BUCKETS
	end

	local count = math.ceil(duration / width)
	if count < MIN_BUCKETS then
		count = MIN_BUCKETS
	elseif count > MAX_BUCKETS then
		count = MAX_BUCKETS
	end
	return count
end

-- The pool size, i.e. the most buckets any plot can ever have. Distinct from GraphBucketCount:
-- callers sizing a pool or a loop bound want this, callers reading "how many are live right now"
-- want the graph's own BucketCount().
function GraphMaxBuckets()
	return MAX_BUCKETS
end

---------------------------------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------------------------------

function Graph:Constructor(width)
	Turbine.UI.Control.Constructor(self)

	self.plotWidth = width
	-- How many buckets the plot is currently drawing. Starts at the pool size and is recomputed
	-- from the session in SetData; the pools are always MAX_BUCKETS deep, so this can only ever
	-- shrink the drawn set, never ask for a Control that does not exist.
	self.buckets = MAX_BUCKETS
	self.bucketWidth = width / self.buckets
	self.laneCount = 0
	self.duration = 1
	self.rangeFrom = 1
	self.rangeTo = self.buckets
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

	for i = 1, MAX_BUCKETS do
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
	self.moraleAxisLabel:SetForeColor(Theme.Color(Theme.Series("morale")))
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

-- Two pools per series slot: the dots and the rotated segments. Sized once here, only ever
-- repositioned afterwards. 2 slots x (48 + 47) = 190 controls, down from 284 -- one segment per
-- step instead of a run plus a riser.
--
-- The segments are `Turbine.UI.Window`s, not Controls, and that is forced: SetRotation does not
-- exist on Turbine.UI.Control (the call throws -- probe round 3). A parented Window starts hidden
-- and draws BEHIND its parent, so SetVisible and an explicit ZOrder are load-bearing here in a way
-- they are not for the Control pools. Each also carries its own `rotation` table, because the
-- angle has to be kept in Lua and re-applied after anything that writes to the control.
function Graph:BuildSeriesPools()
	self.dots = {}
	self.seg = {}

	for slot = 1, MAX_REGULAR_SERIES do
		self.dots[slot] = {}
		self.seg[slot] = {}

		for i = 1, MAX_BUCKETS do
			local dot = Turbine.UI.Control()
			dot:SetParent(self)
			dot:SetSize(DOT_SIZE, DOT_SIZE)
			dot:SetVisible(false)
			dot:SetMouseVisible(false)
			dot:SetZOrder(Z_DOT)
			self.dots[slot][i] = dot
		end

		for i = 1, MAX_BUCKETS - 1 do
			local segment = Turbine.UI.Window()
			segment:SetParent(self)
			segment:SetVisible(false)
			segment:SetMouseVisible(false)
			segment:SetZOrder(Z_LINE)
			segment.rotation = { x = 0, y = 0, z = 0 }
			segment.shown = false -- set by DrawSegment, read by FlushRotation
			self.seg[slot][i] = segment
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
-- player actually recognises a buff. Clicking that icon un-charts the buff (Graph.OnLaneRemoved),
-- which is the only way to drop a lane without going back to the buff table's checkbox.
function Graph:BuildLanes()
	self.lanes = {}
	local graph = self

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
		-- Mouse-visible, with both its children left mouse-invisible: the same
		-- hover-wrapper-around-mouse-invisible-children shape as Frame's close button and the
		-- table header cells. Hover brightens the tile's own border (its BackColor, the lane
		-- colour) rather than filling it with Theme.Hex.Hover -- the tile is 16px of art with a
		-- 1px frame, and a fill behind the art would not read as a hover at all.
		local icon = Turbine.UI.Control()
		icon:SetParent(self)
		icon:SetSize(LANE_ICON_SIZE, LANE_ICON_SIZE)
		icon:SetVisible(false)
		icon:SetMouseVisible(true)

		icon.MouseEnter = function()
			if graph.lanes[i].name ~= nil then
				icon:SetBackColor(Theme.Color(Theme.Hex.Text))
			end
		end
		icon.MouseLeave = function()
			local hex = graph.lanes[i].colorHex
			if hex ~= nil then
				icon:SetBackColor(Theme.Color(hex))
			end
		end
		icon.MouseClick = function()
			local name = graph.lanes[i].name
			if name ~= nil and graph.OnLaneRemoved ~= nil then
				graph.OnLaneRemoved(name)
			end
		end

		local iconInset = Turbine.UI.Control()
		iconInset:SetParent(icon)
		iconInset:SetPosition(1, 1)
		iconInset:SetSize(LANE_ICON_SIZE - 2, LANE_ICON_SIZE - 2)
		iconInset:SetMouseVisible(false)
		-- Real art is applied by Icon.Apply (Constants.lua) at fill time -- see
		-- UI/Analysis.lua's matching buff-row iconInset comment.

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
	self.slider = RangeSlider(self.plotWidth, self.buckets)
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
	box:SetSize(TOOLTIP_WIDTH, (TOOLTIP_LINES + MAX_TOOLTIP_SKILLS) * 14 + 8)
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

	-- Per-skill breakdown rows, appended below the fixed lines in ShowTooltip. Pooled separately
	-- since their count varies per bucket (0 skills in a quiet second, up to MAX_TOOLTIP_SKILLS+
	-- in a busy one) -- positioned dynamically each show, hidden when unused.
	local skillLines = {}
	for i = 1, MAX_TOOLTIP_SKILLS do
		local label = Turbine.UI.Label()
		label:SetParent(box)
		label:SetFont(Font.Verdana10)
		label:SetSize(TOOLTIP_WIDTH - 12, 14)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)
		label:SetVisible(false)
		skillLines[i] = label
	end

	self.tooltip = { box = box, lines = lines, skillLines = skillLines }
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
	elseif i > self.buckets then
		return self.buckets
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
	self.bucketWidth = width / self.buckets

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

	self:SetBucketCount(GraphBucketCount(session))

	for i = 1, TIMELINE_MARKS do
		local seconds = (i - 1) / (TIMELINE_MARKS - 1) * duration
		self.timelineLabels[i]:SetText(Format.Clock(seconds))
	end

	self.slices = {}
	for i = 1, self.buckets do
		self.slices[i] = {}
	end

	local sampled = {}
	if session ~= nil then
		for second, bucket in pairs(session.buckets) do
			local slice = math.floor(second / duration * self.buckets) + 1
			if slice < 1 then slice = 1 end
			if slice > self.buckets then slice = self.buckets end

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
	for i = 1, self.buckets do
		if sampled[i] ~= nil then
			firstKnown = sampled[i]
			break
		end
	end

	local lastKnown = firstKnown
	for i = 1, self.buckets do
		if sampled[i] ~= nil then
			lastKnown = sampled[i]
		end
		self.moraleBySlice[i] = lastKnown
	end

	self:Redraw()
end

function Graph:BucketCount()
	return self.buckets
end

-- Changes how many of the pooled buckets are live (settings.bucketWidth). Everything downstream
-- reads self.buckets, so this only has to fix up the three things that cache a count of their
-- own: the pixel width of a bucket, the range slider's stops, and the range itself -- which is
-- clamped rather than reset, so narrowing the plot keeps as much of the reader's selection as
-- still exists.
--
-- Pool entries past the new count are hidden here rather than left to the draw loops: DrawMorale
-- and DrawSeries only ever walk 1..self.buckets, so a bucket that was visible under a larger
-- count would otherwise stay on screen forever.
function Graph:SetBucketCount(count)
	if count == self.buckets then
		return
	end

	self.buckets = count
	self.bucketWidth = self.plotWidth / count

	for i = count + 1, MAX_BUCKETS do
		self.moraleBars[i]:SetVisible(false)
		self.moraleEdges[i]:SetVisible(false)
		for slot = 1, MAX_REGULAR_SERIES do
			self.dots[slot][i]:SetVisible(false)
			if self.seg[slot][i] ~= nil then
				self.seg[slot][i].shown = false
				self.seg[slot][i]:SetVisible(false)
			end
		end
	end
	-- The step at index `count` bridges into bucket count+1, which no longer exists.
	for slot = 1, MAX_REGULAR_SERIES do
		if self.seg[slot][count] ~= nil then
			self.seg[slot][count].shown = false
			self.seg[slot][count]:SetVisible(false)
		end
	end

	if self.rangeTo > count then
		self.rangeTo = count
	end
	if self.rangeFrom >= self.rangeTo then
		self.rangeFrom = math.max(1, self.rangeTo - 1)
	end

	self.slider:SetBucketCount(count)
	self.slider:SetRange(self.rangeFrom, self.rangeTo)
end

-- Re-reads the settings this plot depends on. Only the bucket width needs work here: the palette
-- reaches the plot through Analysis:RefreshContent re-declaring the series (see its own comment),
-- and everything else the graph draws is a fixed design token.
function Graph:ApplySettings()
	self:SetBucketCount(GraphBucketCount(self.session))
	self:SetData(self.session, self.showMorale, self.filterWho)
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

-- One step of the polyline, as a real diagonal. The control is a SQUARE whose side is the
-- segment's own length, centred on the segment's midpoint; the sprite's band runs the full width
-- of that square, so once rotated it runs from one data point to the other and stops.
--
-- The call order is exact and none of it is interchangeable (see the file header):
--
--   SetSize(native) -> SetBackground -> SetStretchMode(1) -> SetSize(target)   scaling only works
--                                                                              in this order
--   SetBackColorBlendMode(Overlay) + SetBackColor    tints the white sprite to the series colour
--   SetPosition                                       centre on the segment's midpoint
--   ...and SetRotation LAST, on a LATER FRAME -- see Graph:FlushRotation.
--
-- The angle is negated because the engine's positive z turns the opposite way from screen space.
-- Without it every segment draws mirrored about its own midpoint: right length, right centre, both
-- ends on the wrong side, nothing meeting at the joints.
--
-- `lastColor` compares Turbine.UI.Color objects by identity, which is sound because Theme.Color
-- caches one instance per hex (Constants.lua) -- the same hex always hands back the same object.
--
-- The full scale sequence is re-run on every draw rather than once at construction. Resizing a
-- control that has already been through it *might* just rescale, but nothing establishes that, and
-- this codebase's history is a list of clever shortcuts that failed in-game. Redraws happen on data
-- and range changes, not per frame; if that ever profiles badly, hoisting the first three calls
-- into BuildSeriesPools is the optimisation to try, and tiling is the symptom if it is wrong.
local function DrawSegment(segment, x0, y0, x1, y1, color)
	local dx, dy = x1 - x0, y1 - y0
	local side = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
	if side < SEGMENT_MIN then
		side = SEGMENT_MIN
	end

	local x = math.floor((x0 + x1) / 2 - side / 2)
	local y = math.floor((y0 + y1) / 2 - side / 2)
	local deg = -math.deg(math.atan2(dy, dx))
	local image = StrokeSprite(side)

	-- A segment that is already on screen exactly like this is left completely alone. This is not
	-- only a saved SetBackground: because a redrawn segment has to go hidden until the rotation
	-- pass catches up (see below), re-specifying an unchanged one would blink it. Dragging the
	-- range slider redraws on every bucket it crosses without moving the series at all, so without
	-- this the plot would flicker for the whole drag.
	if segment.shown and segment:IsVisible()
		and segment.lastSide == side and segment.lastX == x and segment.lastY == y
		and segment.lastDeg == deg and segment.lastImage == image
		and segment.lastColor == color then
		return
	end

	segment:SetSize(STROKE_NATIVE, STROKE_NATIVE)
	segment:SetBackground(image)
	segment:SetStretchMode(1)
	segment:SetSize(side, side)

	segment:SetBackColorBlendMode(Turbine.UI.BlendMode.Overlay)
	segment:SetBackColor(color)
	segment:SetPosition(x, y)

	segment.lastSide, segment.lastX, segment.lastY = side, x, y
	segment.lastDeg, segment.lastImage, segment.lastColor = deg, image, color

	segment.rotation.z = deg

	-- Deliberately NOT made visible here. SetSize above cleared the rotation, and re-applying it
	-- in this same frame would be silently dropped -- so between now and Graph:FlushRotation the
	-- segment would paint FLAT, which in-game reads as the line snapping to a horizontal bar on
	-- every redraw. `shown` is the "this segment has data" flag FlushRotation reveals from.
	segment.shown = true
	segment:SetVisible(false)
end

function Graph:Redraw()
	local maxValue = 0
	for slot = 1, table.getn(self.seriesList) do
		local key = self.seriesList[slot].key
		if key ~= nil and not self.hidden[key] then
			for i = 1, self.buckets do
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

	-- Every segment was just re-sized, which clears its rotation, and a rotation re-applied in
	-- this same frame would be silently dropped. Arm the pass instead; Analysis:Update runs it a
	-- couple of frames from now, once.
	self.rotateIn = ROTATE_DELAY
end

-- Applies the rotation to every visible segment, a couple of frames after the redraw that sized
-- them. This exists because of the single hardest-won fact in `/reck probe`: **a rotation set
-- before the control has painted is silently dropped**, and one apply on a later frame is enough
-- and sticks. Three rounds of a completely flat plot were exactly this.
--
-- Returns true while there is still work pending, so the caller can stop asking.
function Graph:FlushRotation()
	if self.rotateIn == nil then
		return false
	end

	self.rotateIn = self.rotateIn - 1
	if self.rotateIn > 0 then
		return true
	end
	self.rotateIn = nil

	-- Rotate FIRST, reveal second, and walk the whole pool rather than 1..buckets-1: a segment
	-- left over from a wider bucket count has had `shown` cleared by SetBucketCount, and reading
	-- the flag rather than the count means no path can leak a stale one back onto the plot.
	for slot = 1, MAX_REGULAR_SERIES do
		local pool = self.seg[slot]
		for i = 1, MAX_BUCKETS - 1 do
			local segment = pool[i]
			if segment ~= nil and segment.shown then
				-- pcall'd for the same reason every other undocumented native call here is: a
				-- throw must cost one segment's angle, never the whole refresh.
				pcall(segment.SetRotation, segment, segment.rotation)
				segment:SetVisible(true)
			end
		end
	end

	return false
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
		for i = 1, self.buckets do
			local pct = self.moraleBySlice[i]
			if pct ~= nil and pct > peak then
				peak = pct
			end
		end

		-- MaxMorale (Session.lua) is the same read this used to make itself with its own
		-- pcall(_G.lp:GetMaxMorale()) -- now kept fresh by the real MaxMoraleChanged event instead
		-- of a fresh native call + closure on every Redraw().
		if MaxMorale ~= nil and MaxMorale > 0 then
			self.moraleAxisLabel:SetText("MORALE " .. Format.Number(peak * MaxMorale))
		else
			self.moraleAxisLabel:SetText("MORALE " .. Format.Percent(peak))
		end
		self.moraleAxisLabel:SetPosition(self.plotWidth - 164, 3)
	end

	local barWidth = math.max(1, math.floor(self.bucketWidth) - 2)

	-- Only two colour pairs ever appear across all 48 buckets (normal / below MORALE_DANGER) --
	-- resolved once outside the loop instead of once per bucket (up to 96 Theme.Color calls per
	-- Redraw() otherwise).
	local normalFill, lowFill = Theme.Color(Theme.Hex.MoraleBg), Theme.Color(Theme.Hex.MoraleBgLow)
	local normalEdge, lowEdge = Theme.Color(Theme.Hex.MoraleBgEdge), Theme.Color(Theme.Hex.MoraleBgLowEdge)

	for i = 1, self.buckets do
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
			bar:SetBackColor(low and lowFill or normalFill)
			bar:SetVisible(true)

			edge:SetPosition(x, y)
			edge:SetSize(barWidth, 1)
			edge:SetBackColor(low and lowEdge or normalEdge)
			edge:SetVisible(true)
		end
	end
end

function Graph:DrawSeries(maxValue)
	for slot = 1, MAX_REGULAR_SERIES do
		local series = self.seriesList[slot]
		local live = (series ~= nil and series.key ~= nil and not self.hidden[series.key])

		if not live then
			for i = 1, self.buckets do
				self.dots[slot][i]:SetVisible(false)
			end
			for i = 1, self.buckets - 1 do
				self.seg[slot][i].shown = false
				self.seg[slot][i]:SetVisible(false)
			end
		else
			local color = Theme.Color(series.colorHex)
			local key = series.key

			for i = 1, self.buckets - 1 do
				local y0 = self:ValueY(self.slices[i][key] or 0, maxValue)
				local y1 = self:ValueY(self.slices[i + 1][key] or 0, maxValue)
				DrawSegment(self.seg[slot][i],
					self:BucketX(i), y0, self:BucketX(i + 1), y1, color)
			end

			-- A dot on every bucket at 48 buckets is noise, so only odd indices carry one
			-- (1-based odd == the mock's 0-based even) -- plus both range endpoints, which are
			-- the two the reader is actually looking for while dragging a handle.
			for i = 1, self.buckets do
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
		return math.floor((bucket - 1) / (self.buckets - 1) * self.plotWidth)
	end

	local ax, bx = StopX(self.rangeFrom), StopX(self.rangeTo)
	local full = (self.rangeFrom == 1 and self.rangeTo == self.buckets)

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

		-- What the icon's own click/hover handlers read: a dead lane must not answer a click
		-- with whatever buff it happened to be showing last refresh.
		lane.name = live and data.name or nil
		lane.colorHex = live and data.colorHex or nil

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
				-- See UI/Analysis.lua's FillBuffRow comment: clears whatever the initials
				-- fallback left behind.
				-- lane.iconInset:SetBackColor(Turbine.UI.Color(0, 0, 0, 0))
				-- No stretch, native size -- see UI/Analysis.lua's FillBuffRow comment.
				Icon.Apply(lane.iconInset, data.icon)
				lane.iconInset:SetPosition(1, 1)
				lane.iconLabel:SetText("")
			else
				lane.iconInset:SetBackColor(Theme.Color(Theme.Hex.RailFill))
				lane.iconInset:SetVisible(true)
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

-- The integer-second range [fromSec, toSec] that maps to bucket i under SetData's own
-- `slice = math.floor(second / duration * BUCKET_COUNT) + 1` -- this is that formula's exact
-- inverse, kept in sync with it by hand since there's no single shared expression for both
-- directions. Used to ask Session:Slice for exactly the events that landed in this bucket.
function Graph:SliceSecondRange(i)
	local duration = self.duration
	local fromSec = math.ceil((i - 1) * duration / self.buckets)
	local toSec = math.ceil(i * duration / self.buckets) - 1
	if toSec < fromSec then
		toSec = fromSec
	end
	return fromSec, toSec
end

-- Skills that landed a hit within bucket i, summed across whichever series are currently shown
-- (and un-hidden) and respecting the picker's filterWho -- the same rows Session:Slice already
-- backs the KPI row and skill table with, just re-scoped to one bucket's second range. Avoided-
-- only rows (hits == 0) are dropped: this answers "what hit here", not "what was attempted".
-- Sorted by total descending.
function Graph:SkillsAt(bucketIndex)
	if self.session == nil then
		return {}
	end

	local fromSec, toSec = self:SliceSecondRange(bucketIndex)
	local totals = {}
	local order = {}

	for slot = 1, table.getn(self.seriesList) do
		local series = self.seriesList[slot]
		local key = series.key
		if key ~= nil and not self.hidden[key] then
			local rows = self.session:Slice(key, fromSec, toSec, self.filterWho)
			for i = 1, table.getn(rows) do
				local row = rows[i]
				if row.hits > 0 then
					local entry = totals[row.skill]
					if entry == nil then
						entry = { skill = row.skill, hits = 0, total = 0 }
						totals[row.skill] = entry
						order[table.getn(order) + 1] = entry
					end
					entry.hits = entry.hits + row.hits
					entry.total = entry.total + row.total
				end
			end
		end
	end

	table.sort(order, function(a, b) return a.total > b.total end)
	return order
end

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

	local elapsed = (bucketIndex - 1) / self.buckets * self.duration
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
		lines[row]:SetForeColor(Theme.Color(Theme.Series("morale")))
		row = row + 1
	end

	for i = row, TOOLTIP_LINES do
		lines[i]:SetText("")
	end
	local used = row - 1

	-- Skill breakdown, appended right after whichever fixed lines were actually used.
	local skills = self:SkillsAt(bucketIndex)
	local skillLines = self.tooltip.skillLines
	local totalSkills = table.getn(skills)
	local shown = totalSkills
	local overflow = 0
	if shown > MAX_TOOLTIP_SKILLS then
		shown = MAX_TOOLTIP_SKILLS - 1
		overflow = totalSkills - shown
	end

	for i = 1, MAX_TOOLTIP_SKILLS do
		local label = skillLines[i]
		if i <= shown then
			local entry = skills[i]
			label:SetPosition(6, 4 + used * 14)
			label:SetText("  " .. entry.skill .. "  " .. Format.Number(entry.total) .. " x" .. entry.hits)
			label:SetForeColor(Theme.Color(Theme.Hex.DimText))
			label:SetVisible(true)
			used = used + 1
		elseif overflow > 0 and i == shown + 1 then
			label:SetPosition(6, 4 + used * 14)
			label:SetText("  +" .. overflow .. " more")
			label:SetForeColor(Theme.Color(Theme.Hex.Disabled))
			label:SetVisible(true)
			used = used + 1
			overflow = 0
		else
			label:SetVisible(false)
		end
	end

	self.tooltip.box:SetSize(TOOLTIP_WIDTH, used * 14 + 8)

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
