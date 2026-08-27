--=================================================================================================
-- RotationProbe -- `/reck probe`, a throwaway diagnostic window.
--
-- ROUND 6, and rounds four and five between them settled the mechanism completely.
--
-- WHAT IS KNOWN, all from real loads:
--
--   * `SetRotation` is ABSENT on `Turbine.UI.Control` (the call throws) and works on
--     `Turbine.UI.Window`, at ARBITRARY angles.
--   * **A rotation set before the control has ever painted is silently dropped**, which is what
--     three rounds of flat bars were. ONE apply on a later frame is enough and it sticks (round
--     five, cell C turned and stayed turned; cell D, applied in the constructor, never moved).
--     So the plot rotates each segment once per data change, not every frame.
--   * **Scaling needs the author's call order**: `SetSize(imageW, imageH)` -> `SetBackground` ->
--     `SetStretchMode(1)` -> `SetSize(target)`. With the target size set first, every stretch mode
--     tiles -- which is all rounds one to four were seeing.
--   * `SetBackColorBlendMode(Overlay)` + `SetBackColor` tints a white asset, so one sprite serves
--     every series colour.
--   * Controls clip to their parent, Windows do not.
--
-- AND THE ONE THAT DECIDES THE DESIGN: **the control's rect never rotates. The IMAGE is rotated
-- and then FITTED to the rect.** Round five, cell E: a 64x16 wedge at 90 came back still 64x16
-- with its content reoriented, not 16x64. Cells F, G and H confirm the consequence -- a 64x2
-- control carrying a uniform white bar shows nothing at any angle, because a rotated white
-- rectangle refitted into a 64x2 slot is still a 64x2 white bar.
--
-- So a thin control can never draw a diagonal, and Option B as written in GRAPH_RESEARCH.md is
-- dead. But rotate-then-fit hands back something better than the atlas Option C proposed:
--
--   **make the control SQUARE, with its side equal to the segment's LENGTH.**
--
-- A square rect makes the fit a uniform scale, so a rotated line stays a straight line at exactly
-- the angle asked for. Put a full-width horizontal stroke through a square sprite, rotate it to the
-- segment's angle, and the drawn line runs from one data point to the other -- a real diagonal, one
-- Window per segment, no slope atlas and no quantisation. The sprite is transparent outside the
-- band, so neighbouring segments' squares can overlap freely.
--
-- This round is that idea, and only that idea. If cell E reads as a line, the rework is a
-- mechanical port of `DrawStep` in UI/AnalysisGraph.lua.
--
-- NOTHING ELSE IMPORTS THIS. It is built on demand by /reck probe and is meant to be deleted once
-- the answers are written into docs/redesign/GRAPH_RESEARCH.md section 7.
--=================================================================================================

RotationProbe = class(Frame)

local WIDTH  = 480
local HEIGHT = 404

local PAD       = 12
local LABEL_H   = 14
local CELL_W    = 222
local CELL_H    = 76
local ROW_PITCH = LABEL_H + CELL_H + 8
local STATUS_H  = 30
local WIDE_H    = 110

-- Rotation is applied on the first Update tick after the control has painted, and once is enough
-- (round five, cell C). A couple of extra frames of margin costs nothing and covers a client that
-- wants more than one.
local ROTATE_AFTER_TICKS = 3

local DOT = 3

-- The stroke sprite and its native size. SQUARE, with a full-width band through the middle and
-- transparent elsewhere -- see the header for why square is the whole trick.
local STROKE_IMAGE, STROKE_N = "Reckoning/Resources/stroke.tga", 64

---------------------------------------------------------------------------------------------------
-- Primitives
---------------------------------------------------------------------------------------------------

local rotationOk, rotationCalls = 0, 0

local function Apply(bar)
	rotationCalls = rotationCalls + 1
	local ok = pcall(bar.SetRotation, bar, bar.rotation)
	bar.applied = ok
	if ok then rotationOk = rotationOk + 1 end
	return ok
end

-- The author's scaling sequence, and the only order that scales rather than tiling: the control
-- goes to the IMAGE's size first, then the background, then the stretch mode, and only then the
-- size actually wanted. Both SetSize calls clear any rotation, which is why rotation is never
-- applied in here -- it comes later, on a later frame.
local function Scale(bar, image, native, w, h)
	bar:SetSize(native, native)
	bar:SetBackground(image)
	bar:SetStretchMode(1)
	bar:SetSize(w, h)
end

-- ONE SEGMENT, drawn the way the plot would draw it. The control is a SQUARE whose side is the
-- segment's own length, centred on the segment's midpoint; the sprite's band runs the full width of
-- that square, so after the rotation it runs from one data point to the other and stops.
--
-- Square is not cosmetic. The engine rotates the image and then fits it to the rect, so a
-- non-square rect shears the line off its angle; a square one scales it uniformly and the angle
-- survives. The band's endpoints sit at half the width from the centre, well inside the square's
-- half-diagonal, so nothing is cropped at any angle.
local function PlaceSegment(bar, x0, y0, x1, y1)
	if bar == nil then return 0 end

	local dx, dy = x1 - x0, y1 - y0
	local len = math.max(4, math.floor(math.sqrt(dx * dx + dy * dy) + 0.5))

	Scale(bar, STROKE_IMAGE, STROKE_N, len, len)
	bar:SetPosition(math.floor((x0 + x1) / 2 - len / 2), math.floor((y0 + y1) / 2 - len / 2))
	bar.rotation.z = math.deg(math.atan2(dy, dx))
	return len
end

---------------------------------------------------------------------------------------------------
-- Chrome
---------------------------------------------------------------------------------------------------

function RotationProbe:Constructor()
	Frame.Constructor(self, {
		title = "ROTATION PROBE",
		key = "probe",
		width = WIDTH,
		height = HEIGHT,
	})

	rotationOk, rotationCalls = 0, 0

	self.segments = {}
	self.cells = {}
	self.ticks = 0
	self.rotated = false

	self.statusLine = self:Label(PAD, 6, WIDTH - 2 * PAD, "", Theme.Hex.Text)
	self.statusHint = self:Label(PAD, 20, WIDTH - 2 * PAD, "", Theme.Hex.DimText)

	self:BuildCells()
	self:RefreshStatus()
	self:Report()

	self:SetWantsUpdates(true)
end

-- The whole rotation pass, once, a few frames after everything has painted. This is exactly what
-- Graph:Redraw would do: re-specify every segment, then rotate them all on the next tick.
function RotationProbe:Update()
	-- Guarded before the counter, not only by SetWantsUpdates(false) below: whether the engine
	-- honours that is its decision, and "the pass runs exactly once" has to be true regardless.
	if self.rotated then
		return
	end

	self.ticks = self.ticks + 1
	if self.ticks < ROTATE_AFTER_TICKS then
		return
	end

	for _, bar in ipairs(self.segments) do
		Apply(bar)
	end

	self.rotated = true
	self:SetWantsUpdates(false)
	self:RefreshStatus()
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

function RotationProbe:Ground(index, text, wide)
	local col = (index - 1) % 2
	local row = math.floor((index - 1) / 2)
	local x = wide and PAD or (PAD + col * (CELL_W + PAD))
	local y = STATUS_H + PAD + row * ROW_PITCH
	local w = wide and (WIDTH - 2 * PAD) or CELL_W
	local h = wide and WIDE_H or CELL_H

	self:Label(x, y, w, text)

	local border = Turbine.UI.Control()
	border:SetParent(self.client)
	border:SetPosition(x, y + LABEL_H)
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

	self.cells[index] = fill
	return fill
end

-- A data point, drawn UNDER the segments so a segment that misses its endpoints is obvious.
function RotationProbe:Dot(cell, x, y, hex)
	local dot = Turbine.UI.Control()
	dot:SetParent(cell)
	dot:SetSize(DOT, DOT)
	dot:SetPosition(math.floor(x - DOT / 2), math.floor(y - DOT / 2))
	dot:SetBackColor(Theme.Color(hex or Theme.Hex.DimText))
	dot:SetMouseVisible(false)
	dot:SetZOrder(20)
	return dot
end

-- One rotated segment plus the two dots it must join. Colour comes from the Overlay tint, which is
-- what lets one white sprite serve every series.
function RotationProbe:Segment(cell, x0, y0, x1, y1, hex)
	self:Dot(cell, x0, y0)
	self:Dot(cell, x1, y1)

	local bar
	local ok = pcall(function()
		bar = Turbine.UI.Window()
		bar:SetParent(cell)
		bar:SetMouseVisible(false)
		bar:SetZOrder(50)
		bar:SetVisible(true)
	end)

	if not ok or bar == nil then
		self.refused = (self.refused or 0) + 1
		return nil
	end

	bar.rotation = { x = 0, y = 0, z = 0 }
	PlaceSegment(bar, x0, y0, x1, y1)
	bar:SetBackColorBlendMode(Turbine.UI.BlendMode.Overlay)
	bar:SetBackColor(Theme.Color(hex or Theme.Hex.DamageTaken))

	self.segments[table.getn(self.segments) + 1] = bar
	return bar
end

---------------------------------------------------------------------------------------------------
-- The cells
---------------------------------------------------------------------------------------------------

function RotationProbe:BuildCells()
	-- A: one segment at 45, rising. The dots are the acceptance criterion -- a line that turns but
	-- misses its endpoints is a different bug from one that does not turn.
	local a = self:Ground(1, "A  one segment @45 -- does it join the dots?")
	self:Segment(a, 40, 60, 100, 14)

	-- B: the two extremes the plot actually produces. A near-flat second and a near-vertical spike
	-- are both common in real combat data, and they stress opposite ends of the same arithmetic.
	local b = self:Ground(2, "B  shallow and steep")
	self:Segment(b, 20, 40, 100, 30, Theme.Hex.HealingTaken)
	self:Segment(b, 130, 66, 160, 10, Theme.Hex.HealingTaken)

	-- C: stroke width against segment length. The sprite's band is a FRACTION of its width, so a
	-- longer segment scales to a thicker stroke -- 3/64 of the length. If the spread across real
	-- segment lengths is too visible, the fix is a few sprites at different band ratios picked by
	-- length, not a different mechanism.
	local c = self:Ground(3, "C  stroke vs length: 24 / 44 / 64 px")
	self:Segment(c, 16, 50, 33, 33, Theme.Hex.Accent)
	self:Segment(c, 60, 56, 91, 25, Theme.Hex.Accent)
	self:Segment(c, 120, 60, 165, 15, Theme.Hex.Accent)

	-- D: overlap. Each control is a square as wide as its segment is long, so neighbours overlap
	-- heavily -- which is only fine if the sprite's transparent region really is transparent and
	-- does not paint over the segment underneath.
	local d = self:Ground(4, "D  overlapping squares -- transparency holds?")
	self:Segment(d, 20, 60, 70, 16, Theme.Hex.DamageDone)
	self:Segment(d, 70, 16, 120, 60, Theme.Hex.DamageDone)
	self:Segment(d, 120, 60, 170, 16, Theme.Hex.DamageDone)

	-- E: the acceptance test -- a real 12-point series at the plot's own bucket density, with a dot
	-- on every point. If this reads as a line graph, the rework is a mechanical port.
	local e = self:Ground(5, "E  REAL POLYLINE, 12 points (ships as-is)", true)
	local data = { 0.30, 0.72, 0.55, 0.95, 0.12, 0.20, 0.68, 0.40, 0.85, 0.35, 0.60, 0.25 }
	local ew, eh = e:GetSize()
	local points = table.getn(data)
	local pitch = ew / points
	local xs, ys = {}, {}
	for i = 1, points do
		xs[i] = (i - 1) * pitch + pitch / 2
		ys[i] = eh - 8 - data[i] * (eh - 20)
	end

	self.linePoints, self.lineBars = {}, {}
	for i = 1, points do self.linePoints[i] = { x = xs[i], y = ys[i] } end
	for i = 1, points - 1 do
		self.lineBars[i] = self:Segment(e, xs[i], ys[i], xs[i + 1], ys[i + 1], Theme.Hex.DamageTaken)
	end
end

---------------------------------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------------------------------

function RotationProbe:Status()
	local function Present(factory)
		local ok, instance = pcall(factory)
		if not ok or instance == nil then return "?" end
		return (type(instance.SetRotation) == "function") and "present" or "ABSENT"
	end

	return string.format("SetRotation -- Control: %s | Window: %s | applied %d/%d | %s",
		Present(Turbine.UI.Control), Present(Turbine.UI.Window),
		rotationOk, rotationCalls,
		self.rotated and (self.ticks .. " ticks, rotated once") or "not rotated yet")
end

function RotationProbe:RefreshStatus()
	self.statusLine:SetText(self:Status())
	self.statusHint:SetText(
		"Square control, side = segment length, stroke sprite rotated to the angle. E is the test.")
end

function RotationProbe:Report()
	local function Say(text) Turbine.Shell.WriteLine("  " .. text) end

	Turbine.Shell.WriteLine("Reckoning rotation probe (round 6) -- " .. self:Status())
	Say("Rounds 4-5 settled the mechanism: the control's RECT never rotates -- the IMAGE is")
	Say("rotated and then FITTED to the rect (a 64x16 wedge at 90 came back 64x16, reoriented).")
	Say("So a thin control can never be a diagonal, but a SQUARE one can: side = the segment's")
	Say("length, a full-width stroke through a square sprite, rotated to the segment's angle.")
	Say("A: does the segment join its two dots?")
	Say("B: the shallow and steep extremes real combat data produces.")
	Say("C: stroke thickness is 3/64 of the segment length -- how visible is the spread?")
	Say("D: the squares overlap heavily by design; does the sprite's transparency hold?")
	Say("E: a real 12-point series. If this reads as a line graph, the rework is a port.")
end
