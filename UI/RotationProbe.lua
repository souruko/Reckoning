--=================================================================================================
-- RotationProbe -- `/reck probe`, a throwaway diagnostic window.
--
-- Turbine has no canvas and no line primitive, so a diagonal can only be drawn by ROTATING an
-- axis-aligned Control. `SetRotation` is undocumented but real and in production: Gibberish3's
-- circular timer (UI_ELEMENTS/TIMER/CIRCEL/Element.lua) turns its leading sweep piece with it.
-- What that file proves, exactly:
--
--   * angles are DEGREES, passed as a { x =, y =, z = } table;
--   * the angle must be kept in Lua and RE-APPLIED after anything that writes to the control --
--     `SetSize` and `SetBackground` both clear it (their own comment says so, and their Resize()
--     re-applies for exactly that reason);
--   * the control is a `Turbine.UI.Window`, never a `Turbine.UI.Control`;
--   * it carries a BACKGROUND IMAGE (`SetStretchMode(2)`), tinted by
--     `SetBackColorBlendMode(Overlay)` + `SetBackColor` -- never a bare back-colour fill;
--   * and z is only ever 0, 90, 180 or 270.
--
-- Which leaves the questions that decide whether the analysis window's plot can become a real
-- line graph, and none of them can be answered by reading more code -- only by a load:
--
--   1. does an ARBITRARY z (45, not 90) actually render?
--   2. Control or Window?          -- decides what the segment pool is made of
--   3. back colour or sprite?      -- decides whether Resources/line.tga is needed at all
--   4. which way does positive z turn on screen, with y growing downward?
--   5. is the pivot the control's centre?
--   6. does a rotated control still clip to its parent?
--   7. is a rotated 2px stroke antialiased or jagged?
--
-- The window answers 2 and 3 with a 2x2 of the same 45-degree segment (control/window x
-- plain/sprite), then 4-7 one cell each, then draws a real 9-point polyline with the exact
-- arithmetic UI/AnalysisGraph.lua would ship. Read it against the key printed to chat.
--
-- NOTHING ELSE IMPORTS THIS. It is built on demand by /reck probe and is meant to be deleted
-- once the plot is converted and the answers are written into docs/redesign/GRAPH_RESEARCH.md.
--=================================================================================================

RotationProbe = class(Frame)

local WIDTH  = 480
local HEIGHT = 546

local PAD      = 12
local LABEL_H  = 14
local CELL_W   = 222
local CELL_H   = 76
local ROW_PITCH = LABEL_H + CELL_H + 8

local STROKE   = 2
local DOT      = 3
local WIDE_H   = 96 -- the full-width polyline cell

local LINE_IMAGE = "Reckoning/Resources/line.tga"

-- Positive z is ASSUMED to turn clockwise on screen (y grows downward, so a segment rising to
-- the right is a negative angle). Cell 5 is what checks it; if the quad comes out mirrored, this
-- flips to -1 and the same constant goes into UI/AnalysisGraph.lua.
local ROT_SIGN = 1

---------------------------------------------------------------------------------------------------
-- Primitives
---------------------------------------------------------------------------------------------------

-- Every SetRotation call in this file goes through here: it is undocumented, so a client that
-- does not have it at all must leave a flat bar behind rather than throw out of the constructor.
-- pcall on the method directly, not on a wrapper closure -- no reason to allocate one.
local function Apply(bar)
	local ok = pcall(bar.SetRotation, bar, bar.rotation)
	bar.applied = ok
	return ok
end

-- kind: "control" | "window".  paint: "plain" | "sprite".
--
-- The sprite path is Gibberish3's configuration verbatim: stretch the 8x8 white block to the
-- control and let SetBackColorBlendMode(Overlay) + SetBackColor tint it. The plain path is the
-- one with no precedent anywhere -- if it works, line.tga is unnecessary and the shipping code
-- gets simpler by one asset and three calls per segment.
--
-- The whole construction is pcall'd and returns nil on failure, because a probe whose failing
-- case takes the window down with it answers nothing: parenting a Turbine.UI.Window into a
-- Turbine.UI.Control has no precedent in this codebase either (Gibberish3 only ever parents its
-- rotated Windows into other Windows), and that is one of the things being asked here.
local function Bar(parent, kind, paint, color)
	local bar

	local ok = pcall(function()
		if kind == "window" then
			bar = Turbine.UI.Window()
		else
			bar = Turbine.UI.Control()
		end

		bar:SetParent(parent)
		bar:SetMouseVisible(false)
		-- A parented Turbine.UI.Window starts hidden and draws BEHIND its parent (CLAUDE.md's
		-- Turbine gotchas), so both of these are load-bearing for the "window" flavour and
		-- merely harmless for the "control" one.
		bar:SetZOrder(50)

		if paint == "sprite" then
			bar:SetStretchMode(2)
			bar:SetBackground(LINE_IMAGE)
			bar:SetBackColorBlendMode(Turbine.UI.BlendMode.Overlay)
		end

		bar:SetBackColor(color)
		bar:SetVisible(true)
	end)

	if not ok then
		return nil
	end

	bar.rotation = { x = 0, y = 0, z = 0 }
	return bar
end

-- A rotated bar of a given length, centred on (cx, cy). Used by the cells that are testing the
-- ANGLE rather than the geometry -- the sign quad, the pivot marker, the clip test, the stroke
-- ladder. Order matters and is the same everywhere: size, position, then rotation LAST, because
-- SetSize is one of the two calls known to clear it.
local function PlaceAngle(bar, cx, cy, length, stroke, deg)
	if bar == nil then return end
	bar:SetSize(length, stroke)
	bar:SetPosition(math.floor(cx - length / 2), math.floor(cy - stroke / 2))
	bar.rotation.z = deg
	Apply(bar)
end

-- THE ONE THAT MATTERS: a segment joining two data points, with exactly the arithmetic
-- UI/AnalysisGraph.lua's DrawSegment will ship if this probe comes back green.
--
-- The control is sized to the segment's own length and centred on its midpoint, because rotation
-- pivots on the centre (cell 6 is what confirms that). Length carries +stroke so consecutive
-- segments overlap by half a stroke at each joint instead of leaving a wedge-shaped gap on a
-- sharp corner.
local function PlaceSegment(bar, x0, y0, x1, y1, stroke)
	local dx, dy = x1 - x0, y1 - y0
	local len = math.sqrt(dx * dx + dy * dy)
	local deg = ROT_SIGN * math.deg(math.atan2(dy, dx))

	if bar == nil then return deg end

	bar:SetSize(math.max(stroke, math.floor(len + stroke)), stroke)
	bar:SetPosition(math.floor((x0 + x1) / 2 - len / 2), math.floor((y0 + y1) / 2 - stroke / 2))
	bar.rotation.z = deg
	Apply(bar)

	return deg
end

---------------------------------------------------------------------------------------------------
-- Chrome
---------------------------------------------------------------------------------------------------

function RotationProbe:Constructor(kind, paint)
	Frame.Constructor(self, {
		title = "ROTATION PROBE",
		key = "probe",
		width = WIDTH,
		height = HEIGHT,
	})

	-- Built per flavour on first request and kept, so re-running /reck probe with different
	-- arguments swaps visibility instead of leaking a second set of Controls (there is no
	-- confirmed-safe way to destroy one -- see UI/Row.lua's Reconfigure).
	self.sets = {}
	self.activeSet = nil

	self:BuildMatrix()
	self:BuildCellGrounds()

	-- Window + sprite is Gibberish3's own configuration, so it is the default: the one most
	-- likely to render something at all on the first load.
	self:ShowFlavour(kind or "window", paint or "sprite")
end

function RotationProbe:Label(x, y, w, text, hex, font)
	local label = Turbine.UI.Label()
	label:SetParent(self.client)
	label:SetPosition(x, y)
	label:SetSize(w, LABEL_H)
	label:SetFont(font or Font.Verdana10)
	label:SetForeColor(Theme.Color(hex or Theme.Hex.MutedText))
	label:SetText(text)
	label:SetMouseVisible(false)
	label:SetZOrder(5)
	return label
end

-- A recessed, bordered box to draw inside: a 1px border Control with an inset fill on top, the
-- same two-Control shape the analysis plot's own ground uses. Returns the FILL, which is what
-- everything else parents into -- so a cell's coordinates are its own, starting at (0, 0).
function RotationProbe:Ground(x, y, w, h, text)
	if text ~= nil then
		self:Label(x, y, w, text)
	end
	local top = (text ~= nil) and (y + LABEL_H) or y

	local border = Turbine.UI.Control()
	border:SetParent(self.client)
	border:SetPosition(x, top)
	border:SetSize(w, h)
	border:SetBackColor(Theme.Color(Theme.Hex.PlotBorder))
	border:SetMouseVisible(false)
	border:SetZOrder(6)

	local fill = Turbine.UI.Control()
	fill:SetParent(border)
	fill:SetPosition(1, 1)
	fill:SetSize(w - 2, h - 2)
	fill:SetBackColor(Theme.Color(Theme.Hex.PlotFill))
	fill:SetMouseVisible(false)
	fill:SetZOrder(7)

	return fill
end

-- A small square marker. Endpoint markers are what make cells 1-4 double as a pivot check: a
-- correctly rotated segment runs from one marker to the other, and a segment pivoting on its
-- top-left corner instead swings away from both.
function RotationProbe:Dot(parent, cx, cy, hex, size)
	size = size or DOT
	local dot = Turbine.UI.Control()
	dot:SetParent(parent)
	dot:SetSize(size, size)
	dot:SetPosition(math.floor(cx - size / 2), math.floor(cy - size / 2))
	dot:SetBackColor(Theme.Color(hex or Theme.Hex.DimText))
	dot:SetMouseVisible(false)
	dot:SetZOrder(20)
	return dot
end

---------------------------------------------------------------------------------------------------
-- Cells 1-4 -- the 2x2: Control vs Window, back colour vs sprite
---------------------------------------------------------------------------------------------------

-- All four are built once and stay visible, because they ARE the flavour question -- whichever
-- of them draws a clean diagonal between its two markers is the configuration the plot should
-- use. The other cells then re-test that answer in anger.
function RotationProbe:BuildMatrix()
	local combos = {
		{ kind = "control", paint = "plain",  text = "1  CONTROL + backcolor" },
		{ kind = "window",  paint = "plain",  text = "2  WINDOW + backcolor" },
		{ kind = "control", paint = "sprite", text = "3  CONTROL + line.tga" },
		{ kind = "window",  paint = "sprite", text = "4  WINDOW + line.tga  (Gibberish3's own)" },
	}

	self.matrix = {}

	for i, combo in ipairs(combos) do
		local col = (i - 1) % 2
		local row = math.floor((i - 1) / 2)
		local x = PAD + col * (CELL_W + PAD)
		local y = PAD + row * ROW_PITCH

		local ground = self:Ground(x, y, CELL_W, CELL_H, combo.text)

		-- A rising 45-degree segment, the shape a graph line actually makes.
		local x0, y0 = 20, 62
		local x1, y1 = 80, 2

		self:Dot(ground, x0, y0)
		self:Dot(ground, x1, y1)

		local bar = Bar(ground, combo.kind, combo.paint, Theme.Color(Theme.Hex.Accent))
		PlaceSegment(bar, x0, y0, x1, y1, STROKE)

		self.matrix[i] = { combo = combo, bar = bar }
	end
end

---------------------------------------------------------------------------------------------------
-- Cells 5-9 -- built per flavour
---------------------------------------------------------------------------------------------------

function RotationProbe:BuildCellGrounds()
	local y = PAD + 2 * ROW_PITCH

	self.signGround  = self:Ground(PAD, y, CELL_W, CELL_H, "5  SIGN / DEGREES")
	self.pivotGround = self:Ground(PAD + CELL_W + PAD, y, CELL_W, CELL_H, "6  PIVOT")

	y = y + ROW_PITCH
	self.clipGround   = self:Ground(PAD, y, CELL_W, CELL_H, "7  CLIP TO PARENT")
	self.strokeGround = self:Ground(PAD + CELL_W + PAD, y, CELL_W, CELL_H, "8  SHALLOW STROKE / EDGES")

	y = y + ROW_PITCH
	self.lineGround = self:Ground(PAD, y, WIDTH - 2 * PAD, WIDE_H, "9  REAL POLYLINE (ships as-is)")

	-- Cell 5's common origin. Built here, not per flavour, or re-running /reck probe would stack
	-- a second dot on the first.
	local sw, sh = self.signGround:GetSize()
	self.signCx, self.signCy = math.floor(sw / 2), math.floor(sh / 2)
	self:Dot(self.signGround, self.signCx, self.signCy, Theme.Hex.Text, 5)

	-- Cell 6's two candidate pivots, drawn under the bar so the bar's own path over them is what
	-- reads. Accent200 is the control's unrotated CENTRE, DamageFatal its unrotated TOP-LEFT.
	local cw, ch = self.pivotGround:GetSize()
	self.pivotCx, self.pivotCy = math.floor(cw / 2), math.floor(ch / 2)
	self.pivotLen = 100
	self:Dot(self.pivotGround, self.pivotCx, self.pivotCy, Theme.Hex.Accent200, 5)
	self:Dot(self.pivotGround,
		self.pivotCx - self.pivotLen / 2, self.pivotCy - STROKE / 2,
		Theme.Hex.DamageFatal, 5)

	-- Cell 7's inner box: a rotated bar longer than the box it sits in. If rotated controls clip
	-- to their parent, the bar stops at this box's edges; if they do not, it runs out over the
	-- cell ground and possibly past the window.
	self.clipBox = Turbine.UI.Control()
	self.clipBox:SetParent(self.clipGround)
	self.clipBox:SetSize(70, 70)
	self.clipBox:SetPosition(math.floor((CELL_W - 2 - 70) / 2), 2)
	self.clipBox:SetBackColor(Theme.Color(Theme.Hex.KpiFill))
	self.clipBox:SetMouseVisible(false)
	self.clipBox:SetZOrder(8)

	-- Cell 9's data: a fixed 9-point series, deliberately including a flat run, a steep rise and
	-- a steep fall -- the three shapes the L-step version renders worst.
	self.lineData = { 0.15, 0.62, 0.58, 0.95, 0.10, 0.12, 0.74, 0.30, 0.55 }
end

function RotationProbe:BuildSet(kind, paint)
	local set = { bars = {}, dots = {}, kind = kind, paint = paint }

	-- A combination this client refuses outright (Bar returns nil) must not land in the pool as
	-- a hole -- an array-style table with a nil in it has an undefined length in Lua, which is
	-- the exact footgun that once shifted every picker chip's filter off by one (CLAUDE.md).
	local function NewBar(parent, hex)
		local bar = Bar(parent, kind, paint, Theme.Color(hex))
		if bar ~= nil then
			set.bars[table.getn(set.bars) + 1] = bar
		else
			set.refused = (set.refused or 0) + 1
		end
		return bar
	end

	-- Cell 5: four bars from one centre. If positive z turns clockwise on a y-down screen, the
	-- 45 bar points DOWN-RIGHT and the 135 one UP-RIGHT; mirrored means ROT_SIGN is -1.
	local signHex = { Theme.Hex.Accent, Theme.Hex.DamageTaken, Theme.Hex.HealingDone, Theme.Hex.Morale }
	for i, deg in ipairs({ 0, 45, 90, 135 }) do
		PlaceAngle(NewBar(self.signGround, signHex[i]), self.signCx, self.signCy, 60, STROKE, deg)
	end

	-- Cell 6: one bar at 45 across the two candidate pivot markers.
	PlaceAngle(NewBar(self.pivotGround, Theme.Hex.Accent),
		self.pivotCx, self.pivotCy, self.pivotLen, STROKE, 45)

	-- Cell 7: a 120px bar at 30 degrees inside a 70x70 box.
	PlaceAngle(NewBar(self.clipBox, Theme.Hex.DamageSevere), 35, 35, 120, STROKE, 30)

	-- Cell 8: the same 2px stroke at three SHALLOW angles. Shallow is the point -- a
	-- nearest-neighbour (unantialiased) rotation shows as a visible staircase there, where a
	-- steep one just looks like a line. Steep angles are already on show in cells 1-4, 6 and 9.
	--
	-- 74px of cell height across three lanes leaves each bar about +/-12px of rise, which at
	-- length 150 caps the angle at ~9 degrees; anything steeper would climb out of its lane and
	-- overlap its neighbours, turning the one cell that is about EDGE QUALITY into a mess.
	local sw, sh = self.strokeGround:GetSize()
	for i, deg in ipairs({ 2, 5, 9 }) do
		PlaceAngle(NewBar(self.strokeGround, Theme.Hex.Accent),
			math.floor(sw / 2), math.floor(i * sh / 4), 150, STROKE, deg)
	end

	-- Cell 9: the acceptance test -- a real polyline, drawn by the real arithmetic.
	local lw, lh = self.lineGround:GetSize()
	local points = table.getn(self.lineData)
	local pitch = lw / points
	local xs, ys = {}, {}
	for i = 1, points do
		xs[i] = (i - 1) * pitch + pitch / 2
		ys[i] = lh - 6 - self.lineData[i] * (lh - 16)
	end
	-- Kept so the offline harness can reconstruct each segment's endpoints from its rendered
	-- (position, size, rotation) and check they land back on the data points -- the same check
	-- that will guard UI/AnalysisGraph.lua once this ships.
	set.linePoints, set.lineBars = {}, {}
	for i = 1, points - 1 do
		local bar = NewBar(self.lineGround, Theme.Hex.DamageTaken)
		PlaceSegment(bar, xs[i], ys[i], xs[i + 1], ys[i + 1], STROKE)
		set.lineBars[i] = bar
	end
	for i = 1, points do
		set.linePoints[i] = { x = xs[i], y = ys[i] }
		set.dots[i] = self:Dot(self.lineGround, xs[i], ys[i], Theme.Hex.DamageFatal, 5)
	end

	return set
end

-- Swap which flavour cells 5-9 are drawn in. Rotation is re-applied on every show: whether it
-- survives a SetVisible round-trip is itself unknown, and the shipping code re-specifies every
-- visible segment on each Redraw anyway, so this mirrors what it will do.
function RotationProbe:ShowFlavour(kind, paint)
	local key = kind .. ":" .. paint

	if self.activeSet ~= nil and self.activeSet ~= key then
		local old = self.sets[self.activeSet]
		for _, bar in ipairs(old.bars) do bar:SetVisible(false) end
		for _, dot in ipairs(old.dots) do dot:SetVisible(false) end
	end

	if self.sets[key] == nil then
		self.sets[key] = self:BuildSet(kind, paint)
	end

	local set = self.sets[key]
	for _, bar in ipairs(set.bars) do
		bar:SetVisible(true)
		Apply(bar)
	end
	for _, dot in ipairs(set.dots) do dot:SetVisible(true) end

	self.activeSet = key
	self:Report(set)
end

---------------------------------------------------------------------------------------------------
-- Chat report
---------------------------------------------------------------------------------------------------

-- Half the probe is in chat, not on screen: whether the method EXISTS is a fact the window cannot
-- show (a missing SetRotation and a SetRotation that silently no-ops both leave a flat bar), and
-- the expected angles have to be written down before the render is judged against them.
function RotationProbe:Report(set)
	local function Say(text) Turbine.Shell.WriteLine("  " .. text) end

	-- Read off the matrix's own bars rather than constructing throwaway instances: those are the
	-- real objects in play, and it costs nothing. A method that reads as present can still be a
	-- silent no-op, which is what the cells themselves are for.
	local function Present(bar)
		if bar == nil then return "n/a (construction refused)" end
		return (type(bar.SetRotation) == "function") and "present" or "ABSENT"
	end

	Turbine.Shell.WriteLine("Reckoning rotation probe -- cells 5-9 drawn as "
		.. string.upper(set.kind) .. " + " .. set.paint .. " (/reck probe <control|window> <plain|sprite>)")

	Say("SetRotation on Turbine.UI.Control: " .. Present(self.matrix[1].bar))
	Say("SetRotation on Turbine.UI.Window:  " .. Present(self.matrix[2].bar))

	local applied, total = 0, 0
	for _, bar in ipairs(set.bars) do
		total = total + 1
		if bar.applied then applied = applied + 1 end
	end
	Say(string.format("SetRotation calls that did not throw: %d/%d%s", applied, total,
		(set.refused ~= nil) and string.format("  (%d bars could not be built at all)", set.refused) or ""))

	Say("1-4 (fixed): each cell should show ONE clean diagonal joining its two grey dots.")
	Say("   A flat horizontal bar = that combination does not rotate. Cell 4 is the one")
	Say("   Gibberish3 proves; cell 1 working would mean line.tga is unnecessary.")
	Say("5: bars at z=0/45/90/135 -- accent / pink / green / yellow, from the white centre dot.")
	Say("   Clockwise (y down) puts the PINK one down-right. Mirrored means ROT_SIGN = -1.")
	Say("6: the bar should run through the PALE dot (control centre), not the PINK one (top-left).")
	Say("7: the bar should stop at the lighter inner box. Running past it = rotated controls")
	Say("   do NOT clip to their parent, and the plot needs an inset.")
	Say("8: one 2px stroke at z=2/5/9 -- shallow on purpose. Look for staircase edges.")
	Say("9: a 9-point polyline, drawn by the exact code UI/AnalysisGraph.lua would ship.")
	Say("   Every segment should meet its neighbours at the pink dots with no gap or overshoot.")
end
