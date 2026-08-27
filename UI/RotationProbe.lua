--=================================================================================================
-- RotationProbe -- `/reck probe`, a throwaway diagnostic window.
--
-- ROUND 5. Round four found the thing three rounds had missed, and it was timing:
--
--   * cell E rotated a wedge ONCE, in the constructor -> nothing happened;
--   * cells F and G rotated the same wedge on every `Update` tick -> **it turned**, at 90 and at
--     45 both.
--
-- So `SetRotation` works on a `Turbine.UI.Window` (it is ABSENT on `Turbine.UI.Control` -- the call
-- throws), at arbitrary angles, and **a rotation set before the control has ever painted is
-- silently dropped.** Gibberish3 never hit this because its timers re-apply on every progress
-- change, to a control long since on screen. Nothing here did, for three rounds.
--
-- The second half came from the plugin's author: **scaling an image needs a specific sequence** --
-- size the control to the IMAGE's own size, `SetBackground`, `SetStretchMode(1)`, and only THEN
-- size it to the target. Rounds one to four set the size first and the background after, which is
-- why every stretch mode looked like it tiled: the mode had no native-sized control to scale from.
-- (`Icon.Size` in Constants.lua already leans on the same ordering quirk from the other direction,
-- using `SetStretchMode(2)` to snap a control to its image's native size so it can read it back.)
--
-- Which leaves exactly what a line graph needs to know, and this round asks only that:
--
--   1. Does the author's scaling sequence actually scale? (A)
--   2. Does a scaled image still rotate? (B)
--   3. Does ONE deferred apply stick, or must every segment be re-rotated on every frame? (C, D)
--      This decides whether the plot can rotate 94 segments once per data change or has to touch
--      them all every tick, which is the difference between free and unaffordable.
--   4. **Does a rotated draw escape the control's own rect?** (E, F, G) Every subject that has
--      rotated so far was SQUARE, and a square's rotation fits inside its own bounds. A 2px-tall
--      segment's does not -- it has to draw outside the rect or it cannot be a diagonal at all.
--      Windows do not clip to their parent, but nothing yet says a rotated draw is not clipped to
--      the control ITSELF.
--   5. And the whole thing at once: a real polyline (H).
--
-- NOTHING ELSE IMPORTS THIS. It is built on demand by /reck probe and is meant to be deleted once
-- the answers are written into docs/redesign/GRAPH_RESEARCH.md section 7.
--=================================================================================================

RotationProbe = class(Frame)

local WIDTH  = 480
local HEIGHT = 462

local PAD       = 12
local LABEL_H   = 14
local CELL_W    = 222
local CELL_H    = 76
local ROW_PITCH = LABEL_H + CELL_H + 8
local STATUS_H  = 30

local STROKE = 2
local BOX    = 48 -- the scale target for a 16x16 asset
local WEDGE  = 36
local LINE_W = 64
local WIDE_W, WIDE_H = 64, 16 -- the deliberately not-square rotation subject

-- Frames of re-rotation before the "every tick" cells give up. Two seconds or so at any frame rate
-- is far past "the control has painted", which is all this is testing.
local UPDATE_TICKS = 120

local GHOST_CX   = 62
local SUBJECT_CX = 156

-- image, and its NATIVE size -- which the scaling sequence needs and which is a constant for our
-- own assets, so the shipping code never has to probe for it the way Icon.Size does.
local ICON_IMAGE,  ICON_W,  ICON_H  = "Reckoning/Resources/search.tga", 16, 16
local WEDGE_IMAGE, WEDGE_W, WEDGE_H = "Reckoning/Resources/wedge.tga", 36, 36
local LINE_IMAGE,  LINE_NW, LINE_NH = "Reckoning/Resources/line_long.tga", 256, 4

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

-- THE AUTHOR'S SCALING SEQUENCE, and the only one that scales rather than tiling: size the control
-- to the image's own size FIRST, set the background, THEN SetStretchMode(1), and only then size it
-- to what you actually want. Order is the whole trick -- with the target size set first, every
-- stretch mode tiles (rounds one to four).
--
-- Both SetSize calls clear any rotation, which is why rotation is never applied in here.
local function Scale(bar, image, nativeW, nativeH, w, h)
	bar:SetSize(nativeW, nativeH)
	bar:SetBackground(image)
	bar:SetStretchMode(1)
	bar:SetSize(w, h)
end

-- A Window (Control has no SetRotation at all), optionally image-backed and scaled, optionally
-- tinted through the Overlay trick round three confirmed. pcall'd and nil on failure.
local function Subject(parent, spec)
	local bar

	local ok = pcall(function()
		bar = Turbine.UI.Window()
		bar:SetParent(parent)
		bar:SetMouseVisible(false)
		-- A parented Turbine.UI.Window starts hidden and draws BEHIND its parent (CLAUDE.md).
		bar:SetZOrder(spec.z or 50)

		if spec.image ~= nil then
			if spec.scale then
				Scale(bar, spec.image, spec.nativeW, spec.nativeH, spec.w, spec.h)
			else
				bar:SetBackground(spec.image)
				bar:SetSize(spec.w, spec.h)
			end
			if spec.color ~= nil then
				bar:SetBackColorBlendMode(Turbine.UI.BlendMode.Overlay)
				bar:SetBackColor(spec.color)
			end
		else
			bar:SetSize(spec.w, spec.h)
			bar:SetBackColor(spec.color)
		end

		bar:SetPosition(math.floor(spec.cx - spec.w / 2), math.floor(spec.cy - spec.h / 2))
		bar:SetVisible(true)
	end)

	if not ok then return nil end

	bar.rotation = { x = 0, y = 0, z = spec.deg or 0 }
	bar.mode = spec.mode
	-- "now" reproduces the round-four failure deliberately; the deferred modes are the fix.
	if spec.deg ~= nil and spec.deg ~= 0 and spec.mode == "now" then
		Apply(bar)
	end
	return bar
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

	self.subjects = {}
	self.deferred = {}
	self.cells = {}
	self.ticks = 0

	self.statusLine = self:Label(PAD, 6, WIDTH - 2 * PAD, "", Theme.Hex.Text)
	self.statusHint = self:Label(PAD, 20, WIDTH - 2 * PAD, "", Theme.Hex.DimText)

	self:BuildCells()
	self:RefreshStatus()
	self:Report()

	self:SetWantsUpdates(true)
end

-- Where round four's finding gets turned into a question with a cost attached: "once" applies the
-- rotation on the first tick and never again, "every" keeps re-applying. If once is enough, the
-- plot rotates its segments one frame after a data change and forgets about them; if not, it has
-- to touch every visible segment on every frame, which at 94 segments is a different feature.
function RotationProbe:Update()
	if self.ticks >= UPDATE_TICKS then
		return
	end

	self.ticks = self.ticks + 1
	for _, bar in ipairs(self.deferred) do
		if bar.mode == "every" or self.ticks == 1 then
			Apply(bar)
		end
	end

	if self.ticks >= UPDATE_TICKS then
		self:SetWantsUpdates(false)
		self:RefreshStatus()
	elseif self.ticks % 20 == 0 then
		self:RefreshStatus()
	end
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

function RotationProbe:Ground(index, text)
	local col = (index - 1) % 2
	local row = math.floor((index - 1) / 2)
	local x = PAD + col * (CELL_W + PAD)
	local y = STATUS_H + PAD + row * ROW_PITCH

	self:Label(x, y, CELL_W, text)

	local border = Turbine.UI.Control()
	border:SetParent(self.client)
	border:SetPosition(x, y + LABEL_H)
	border:SetSize(CELL_W, CELL_H)
	border:SetBackColor(Theme.Color(Theme.Hex.PlotBorder))
	border:SetMouseVisible(false)
	border:SetZOrder(6)

	local fill = Turbine.UI.Control()
	fill:SetParent(border)
	fill:SetPosition(1, 1)
	fill:SetSize(CELL_W - 2, CELL_H - 2)
	fill:SetBackColor(Theme.Color(Theme.Hex.PlotFill))
	fill:SetMouseVisible(false)
	fill:SetZOrder(7)

	fill.cy = math.floor((CELL_H - 2) / 2)
	self.cells[index] = fill
	return fill
end

function RotationProbe:Add(cell, spec)
	spec.cy = spec.cy or cell.cy
	local bar = Subject(cell, spec)

	if bar == nil then
		self.refused = (self.refused or 0) + 1
		return nil
	end

	if spec.deg ~= nil and spec.deg ~= 0 then
		self.subjects[table.getn(self.subjects) + 1] = bar
		if spec.mode ~= "now" then
			self.deferred[table.getn(self.deferred) + 1] = bar
		end
	end
	return bar
end

-- The unrotated reference every cell carries, so "did it change?" never depends on memory.
function RotationProbe:Reference(cell, spec)
	spec.cx = GHOST_CX
	spec.deg = nil
	spec.z = 40
	return self:Add(cell, spec)
end

---------------------------------------------------------------------------------------------------
-- The cells
---------------------------------------------------------------------------------------------------

function RotationProbe:BuildCells()
	local accent = Theme.Color(Theme.Hex.Accent)

	local function Lens(scale)
		return { image = ICON_IMAGE, nativeW = ICON_W, nativeH = ICON_H,
			w = BOX, h = BOX, scale = scale }
	end
	local function Wedge(w, h)
		return { image = WEDGE_IMAGE, nativeW = WEDGE_W, nativeH = WEDGE_H,
			w = w or WEDGE, h = h or WEDGE, scale = true, color = accent }
	end
	local function Line(w, h)
		return { image = LINE_IMAGE, nativeW = LINE_NW, nativeH = LINE_NH,
			w = w, h = h, scale = true, color = accent }
	end

	local function Spec(base, extra)
		local out = {}
		for k, v in pairs(base) do out[k] = v end
		for k, v in pairs(extra) do out[k] = v end
		return out
	end

	-- A: does the author's sequence scale? One big lens = yes. A 3x3 grid = still tiling, and
	-- everything below is moot. No rotation involved.
	local a = self:Ground(1, "A  SCALE 16->48, author's sequence  (one lens?)")
	self:Reference(a, Lens(false))
	self:Add(a, Spec(Lens(true), { cx = SUBJECT_CX }))

	-- B: and does a SCALED image still rotate? Scaling ends in a SetSize, which clears rotation --
	-- so this is really "is the re-apply ordering still right once scaling is in the mix".
	local b = self:Ground(2, "B  scaled lens @45, every tick")
	self:Reference(b, Lens(true))
	self:Add(b, Spec(Lens(true), { cx = SUBJECT_CX, deg = 45, mode = "every", color = accent }))

	-- C and D: the cost question. Round four only proved that re-rotating EVERY frame works. If one
	-- apply after the first paint is enough, the plot rotates its segments once per data change; if
	-- not, it has to touch all 94 every frame, which is a different feature entirely.
	local c = self:Ground(3, "C  wedge @90, ONE apply after first paint")
	self:Reference(c, Wedge())
	self:Add(c, Spec(Wedge(), { cx = SUBJECT_CX, deg = 90, mode = "once" }))

	local d = self:Ground(4, "D  wedge @90, applied in constructor (control)")
	self:Reference(d, Wedge())
	self:Add(d, Spec(Wedge(), { cx = SUBJECT_CX, deg = 90, mode = "now" }))

	-- E: THE ONE THAT MATTERS NOW. Every subject that has rotated so far was square, and a square's
	-- rotation fits inside its own bounds -- so nothing yet says a rotated draw is not clipped to
	-- the control itself. A 64x16 wedge at 90 has to become 16x64 to be visible, which means
	-- drawing well outside its own rect. A 2px segment needs exactly that and much more of it.
	local e = self:Ground(5, "E  64x16 wedge @90 -- draws outside its rect?")
	self:Reference(e, Wedge(WIDE_W, WIDE_H))
	self:Add(e, Spec(Wedge(WIDE_W, WIDE_H), { cx = SUBJECT_CX, deg = 90, mode = "every" }))

	-- F and G: the actual shape the plot draws, at the proven angle and at an arbitrary one.
	local f = self:Ground(6, "F  line 64x2 @90 -- vertical?")
	self:Reference(f, Line(LINE_W, STROKE))
	self:Add(f, Spec(Line(LINE_W, STROKE), { cx = SUBJECT_CX, deg = 90, mode = "every" }))

	local g = self:Ground(7, "G  line 64x2 @45 -- diagonal?")
	self:Reference(g, Line(LINE_W, STROKE))
	self:Add(g, Spec(Line(LINE_W, STROKE), { cx = SUBJECT_CX, deg = 45, mode = "every" }))

	-- H: all of it at once -- a real 8-point polyline, one rotated segment per step, drawn with the
	-- arithmetic UI/AnalysisGraph.lua would ship.
	local h = self:Ground(8, "H  REAL POLYLINE (ships as-is)")
	local data = { 0.2, 0.75, 0.55, 0.95, 0.1, 0.6, 0.35, 0.8 }
	local hw, hh = h:GetSize()
	local points = table.getn(data)
	local pitch = hw / points
	local xs, ys = {}, {}
	for i = 1, points do
		xs[i] = (i - 1) * pitch + pitch / 2
		ys[i] = hh - 6 - data[i] * (hh - 14)
	end
	self.linePoints, self.lineBars = {}, {}
	for i = 1, points do self.linePoints[i] = { x = xs[i], y = ys[i] } end
	for i = 1, points - 1 do
		local dx, dy = xs[i + 1] - xs[i], ys[i + 1] - ys[i]
		local len = math.sqrt(dx * dx + dy * dy)
		self.lineBars[i] = self:Add(h, Spec(Line(math.floor(len + STROKE), STROKE), {
			cx = (xs[i] + xs[i + 1]) / 2,
			cy = (ys[i] + ys[i + 1]) / 2,
			deg = math.deg(math.atan2(dy, dx)),
			mode = "every",
		}))
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

	return string.format("SetRotation -- Control: %s | Window: %s | applied %d/%d | %d ticks",
		Present(Turbine.UI.Control), Present(Turbine.UI.Window),
		rotationOk, rotationCalls, self.ticks)
end

function RotationProbe:RefreshStatus()
	self.statusLine:SetText(self:Status())
	self.statusHint:SetText(
		"A: one lens or nine?   C vs D: does ONE apply stick?   E-G: does the draw leave the rect?")
end

function RotationProbe:Report()
	local function Say(text) Turbine.Shell.WriteLine("  " .. text) end

	Turbine.Shell.WriteLine("Reckoning rotation probe (round 5) -- " .. self:Status())
	Say("Round four settled it: rotation works on a Window at any angle, but a rotation set")
	Say("BEFORE the control has ever painted is silently dropped. Scaling needs the author's")
	Say("sequence: size to the IMAGE, SetBackground, SetStretchMode(1), then size to the target.")
	Say("A: does that sequence scale? ONE big lens = yes. A 3x3 grid = still tiling.")
	Say("B: a scaled image rotated -- scaling ends in a SetSize, which clears rotation.")
	Say("C vs D: C applies the rotation ONCE after the first paint, D in the constructor. If C")
	Say("   turned and D did not, the plot rotates each segment once per data change instead of")
	Say("   re-rotating all 94 every frame -- the difference between free and unaffordable.")
	Say("E: a 64x16 wedge at 90 must become 16x64, i.e. draw well OUTSIDE its own rect. Every")
	Say("   subject that has rotated so far was square, so this has never actually been asked.")
	Say("F/G: the real shape -- a 64x2 stroke at 90 and at 45.")
	Say("H: a real 8-point polyline. If this reads as a line, the rework is a mechanical port.")
end
