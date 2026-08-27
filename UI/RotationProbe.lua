--=================================================================================================
-- RotationProbe -- `/reck probe`, a throwaway diagnostic window.
--
-- ROUND 4. Rounds one to three narrowed a broad question down to two specific ones, and this round
-- asks only those. What is settled, from real loads:
--
--   * `SetRotation` is **ABSENT on Turbine.UI.Control** and **present on Turbine.UI.Window**. On a
--     Control the call throws (round three: 4 of 5 applied, the one Control subject being the
--     miss); Gibberish3 only ever rotating Windows was not a style choice.
--   * On a Window it is callable and, so far, **has no visible effect at all** -- not on a solid
--     square, not on a native-size image, not at 45, not at 90, not on a thin bar, not through a
--     Control ancestry and not parented straight into the frame's own Window.
--   * `SetStretchMode(2)` **TILES** the image, it does not scale it. Round three's cell A drew a
--     16x16 lens repeated in a 3x3 grid across a 36x36 control. That, not "stretching renders
--     nothing", is why round two's icon cells looked wrong -- and combined with
--     `SetBlendMode(Overlay)` (which round two also set and this cell did not) it renders blank.
--   * A native-size image renders correctly (round three, cell B).
--   * **`SetBackColorBlendMode(Overlay)` + `SetBackColor` DOES tint a white image** (round three,
--     cell H: the same asset drew white on the left and accent-purple on the right). Whatever
--     happens to rotation, the plot can get every series colour out of one white asset.
--   * Controls clip to their parent, Windows do not (per the plugin's author).
--
-- So two hypotheses remain, and if both fail then `SetRotation` on this client is a no-op and the
-- line graph has to come from somewhere else.
--
--   1. **The exact Gibberish3 configuration.** Every rotated control there is a Window whose
--      background image is authored at the control's own size, drawn with `SetStretchMode(2)` and
--      tinted through `SetBackColorBlendMode(Overlay)`. Every probe subject so far has differed in
--      at least one of those (a 16x16 asset in a 36x36 control, or no tint, or no stretch).
--      `wedge.tga` is 36x36 for exactly this cell.
--   2. **Timing.** Every probe so far applied rotation once, in the constructor, before the control
--      had ever painted. Gibberish3 re-applies on every progress change, i.e. continuously after
--      the control is long since on screen. If the engine only honours a rotation set on an
--      already-rendered control, that difference alone explains three flat rounds.
--
-- Cells A-D also settle something worth more than rotation if rotation is dead: **which stretch
-- mode, if any, SCALES an image.** If one of them does, the slope-sprite atlas (Option C in
-- GRAPH_RESEARCH.md) is back on the table -- it needs a sprite stretched over each segment's
-- bounding box, and it draws real diagonals with no rotation at all.
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
local ICON   = 16 -- search.tga's native size
local BOX    = 48 -- the stretch-mode cells' control, deliberately 3x the asset
local WEDGE  = 36 -- wedge.tga's native size, and the control's size in the G3-exact cells
local LINE_W = 64

-- Frames of re-rotation before the deferred cells give up. Two seconds or so at any frame rate
-- is far past "the control has painted", which is the only thing this is testing.
local UPDATE_TICKS = 120

local GHOST_CX   = 62
local SUBJECT_CX = 156

local LINE_IMAGE  = "Reckoning/Resources/line_long.tga"
local ICON_IMAGE  = "Reckoning/Resources/search.tga"
-- 36x36, a filled upper-left triangle: unmistakable at 45, 90 and 180, and authored at exactly the
-- size of the control that draws it, which is the Gibberish3 property every earlier subject missed.
local WEDGE_IMAGE = "Reckoning/Resources/wedge.tga"

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

-- Gibberish3's configuration verbatim: a Window, an image authored at the control's own size,
-- SetStretchMode(2), and the tint through SetBackColorBlendMode(Overlay) + SetBackColor. `image`
-- nil means a plain back-colour fill; `stretch` nil means no SetStretchMode call at all.
--
-- pcall'd and nil on failure -- a probe whose failing case takes the window down answers nothing.
local function Subject(parent, kind, image, color, stretch, z)
	local bar

	local ok = pcall(function()
		bar = (kind == "window") and Turbine.UI.Window() or Turbine.UI.Control()
		bar:SetParent(parent)
		bar:SetMouseVisible(false)
		-- A parented Turbine.UI.Window starts hidden and draws BEHIND its parent (CLAUDE.md).
		bar:SetZOrder(z or 50)

		if image ~= nil then
			if stretch ~= nil then
				bar:SetStretchMode(stretch)
			end
			bar:SetBackground(image)
			if color ~= nil then
				bar:SetBackColorBlendMode(Turbine.UI.BlendMode.Overlay)
				bar:SetBackColor(color)
			end
		else
			bar:SetBackColor(color)
		end

		bar:SetVisible(true)
	end)

	if not ok then return nil end

	bar.rotation = { x = 0, y = 0, z = 0 }
	return bar
end

-- Size and centre, then rotate. Rotation LAST -- SetSize and SetBackground both clear it.
local function Place(bar, cx, cy, w, h, deg)
	if bar == nil then return end
	bar:SetSize(w, h)
	bar:SetPosition(math.floor(cx - w / 2), math.floor(cy - h / 2))
	bar.rotation.z = deg or 0
	if deg ~= nil and deg ~= 0 then
		Apply(bar)
	end
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
	self.deferred = {} -- re-rotated on every Update tick, see hypothesis 2
	self.cells = {}
	self.ticks = 0

	self.statusLine = self:Label(PAD, 6, WIDTH - 2 * PAD, "", Theme.Hex.Text)
	self.statusHint = self:Label(PAD, 20, WIDTH - 2 * PAD, "", Theme.Hex.DimText)

	self:BuildCells()
	self:RefreshStatus()
	self:Report()

	-- Hypothesis 2 lives or dies here: nothing in three rounds has ever set a rotation on a control
	-- that was already on screen. This keeps re-applying it, frame after frame, long after the
	-- first paint -- which is the situation Gibberish3's own timers are always in.
	self:SetWantsUpdates(true)
end

function RotationProbe:Update()
	-- Guarded on the counter, not only on SetWantsUpdates(false) below: a stopped window is the
	-- engine's decision to make and this has to be true regardless of whether it honours it.
	if self.ticks >= UPDATE_TICKS or table.getn(self.deferred) == 0 then
		return
	end

	self.ticks = self.ticks + 1
	for _, bar in ipairs(self.deferred) do
		Apply(bar)
	end

	-- The status line would otherwise scroll its applied-count forever; a couple of seconds of
	-- frames is plenty to prove the point, and the count is more readable if it stops somewhere.
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

function RotationProbe:Track(bar, deferredToo)
	if bar == nil then
		self.refused = (self.refused or 0) + 1
		return nil
	end
	self.subjects[table.getn(self.subjects) + 1] = bar
	if deferredToo then
		self.deferred[table.getn(self.deferred) + 1] = bar
	end
	return bar
end

---------------------------------------------------------------------------------------------------
-- The cells
---------------------------------------------------------------------------------------------------

function RotationProbe:BuildCells()
	-- A-D: which stretch mode, if any, SCALES? A 16x16 lens in a 48x48 control, no rotation, no
	-- blend mode. One big lens = that mode scales; a 3x3 grid of lenses = it tiles; one small lens
	-- in the corner = no scaling at all; blank = the mode is not valid here. This is worth more
	-- than the rotation cells if rotation is dead: a mode that scales brings back Option C, the
	-- slope-sprite atlas, which draws real diagonals with no rotation involved.
	for i, mode in ipairs({ 0, 1, 2, 3 }) do
		local cell = self:Ground(i, string.format("%s  SetStretchMode(%d) -- scales? tiles?",
			string.char(64 + i), mode))
		Place(Subject(cell, "window", ICON_IMAGE, nil, mode, 40), SUBJECT_CX, cell.cy, BOX, BOX, 0)
		-- The same asset at its native size, for scale reference.
		Place(Subject(cell, "window", ICON_IMAGE, nil, nil, 40), GHOST_CX, cell.cy, ICON, ICON, 0)
	end

	-- E: Gibberish3's configuration verbatim, for the first time -- a Window, an image authored at
	-- the control's own size, SetStretchMode(2), tinted through SetBackColorBlendMode(Overlay).
	-- Only the rotation is ours. If the wedge's flat edge moves, rotation works and every earlier
	-- round differed from Gibberish3 in something that mattered.
	local e = self:Ground(5, "E  G3-EXACT: 36x36 wedge @90, tinted")
	Place(Subject(e, "window", WEDGE_IMAGE, Theme.Color(Theme.Hex.Accent), 2, 40),
		GHOST_CX, e.cy, WEDGE, WEDGE, 0)
	Place(self:Track(Subject(e, "window", WEDGE_IMAGE, Theme.Color(Theme.Hex.Accent), 2)),
		SUBJECT_CX, e.cy, WEDGE, WEDGE, 90)

	-- F: the same, but re-rotated on every Update tick. Nothing in three rounds has set a rotation
	-- on a control that had already painted, and Gibberish3 is always in that situation.
	local f = self:Ground(6, "F  same, re-rotated every tick (timing)")
	Place(Subject(f, "window", WEDGE_IMAGE, Theme.Color(Theme.Hex.Accent), 2, 40),
		GHOST_CX, f.cy, WEDGE, WEDGE, 0)
	Place(self:Track(Subject(f, "window", WEDGE_IMAGE, Theme.Color(Theme.Hex.Accent), 2), true),
		SUBJECT_CX, f.cy, WEDGE, WEDGE, 90)

	-- G: the wedge at 45 with the deferred apply -- arbitrary angles, under the best configuration
	-- and the best timing this probe can produce.
	local g = self:Ground(7, "G  G3-exact wedge @45, re-rotated every tick")
	Place(Subject(g, "window", WEDGE_IMAGE, Theme.Color(Theme.Hex.Accent), 2, 40),
		GHOST_CX, g.cy, WEDGE, WEDGE, 0)
	Place(self:Track(Subject(g, "window", WEDGE_IMAGE, Theme.Color(Theme.Hex.Accent), 2), true),
		SUBJECT_CX, g.cy, WEDGE, WEDGE, 45)

	-- H: and the shape the plot actually needs -- a thin stroke -- under the same best-case
	-- treatment. Even if E-G turn, this is the one that says whether a 2px segment can be a
	-- diagonal, because a rotated thin control has to draw outside its own rect to do it.
	local h = self:Ground(8, "H  line 64x2 @45, re-rotated every tick")
	Place(Subject(h, "window", LINE_IMAGE, Theme.Color(Theme.Hex.Accent), nil, 40),
		GHOST_CX, h.cy, LINE_W, STROKE, 0)
	Place(self:Track(Subject(h, "window", LINE_IMAGE, Theme.Color(Theme.Hex.Accent), nil), true),
		SUBJECT_CX, h.cy, LINE_W, STROKE, 45)
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
		"A-D: which mode SCALES the 16px lens to 48px?   E-H: does the wedge's flat edge move?")
end

function RotationProbe:Report()
	local function Say(text) Turbine.Shell.WriteLine("  " .. text) end

	Turbine.Shell.WriteLine("Reckoning rotation probe (round 4) -- " .. self:Status())
	Say("Left of each cell is the reference; right is the subject.")
	Say("A-D: a 16x16 lens drawn in a 48x48 control under stretch modes 0/1/2/3, no rotation.")
	Say("   ONE BIG LENS = that mode scales -- which brings back the slope-sprite atlas (real")
	Say("   diagonals, no rotation needed). A 3x3 GRID = it tiles. Small corner lens = no effect.")
	Say("E: Gibberish3's configuration verbatim for the first time -- a Window, an image authored")
	Say("   at the control's own size, SetStretchMode(2), Overlay tint. Only the rotation is ours.")
	Say("F/G: the same at 90 and 45, but re-rotated on every frame. Every round so far set the")
	Say("   rotation once in the constructor, before the control had ever painted; Gibberish3 is")
	Say("   always re-applying to a control that is long since on screen.")
	Say("H: a 64x2 stroke at 45 under the same best-case treatment -- the shape the plot needs.")
	Say("If the wedge never moves in E-H, SetRotation is a no-op on this client and the line graph")
	Say("has to come from a stretch mode instead. That is what A-D are for.")
end
