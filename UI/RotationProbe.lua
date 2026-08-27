--=================================================================================================
-- RotationProbe -- `/reck probe`, a throwaway diagnostic window.
--
-- Turbine has no canvas and no line primitive, so a diagonal can only be drawn by ROTATING an
-- axis-aligned control. `SetRotation` is undocumented but real and in production: Gibberish3's
-- circular timer (UI_ELEMENTS/TIMER/CIRCEL/Element.lua) turns its leading sweep piece with it --
-- degrees, in an { x =, y =, z = } table, kept in Lua and re-applied after every `SetSize` or
-- `SetBackground` (both clear it), on a `Turbine.UI.Window` carrying a background image.
--
-- ROUND 3, and rounds one and two are why this one is shaped the way it is.
--
-- Round one drew flat colours and uniform white blocks and got flat bars -- unreadable, because a
-- featureless subject looks the same whether the engine ignores rotation or rotates a control's
-- CONTENT inside a rect that stays axis-aligned.
--
-- Round two fixed the subjects and produced two results. The solid squares at 45 stayed square --
-- Control and Window alike -- and a 44x2 Window bar at z=90, parented straight into the frame with
-- nothing in the chain that could clip it, stayed horizontal. That is real evidence: **the
-- control's own rect does not rotate.** But every ICON cell came back completely blank, so the
-- content-rotation half of the question went unanswered -- and the reason those cells were blank
-- matters more than it first looks.
--
-- They used `SetStretchMode(2)` to scale a 16x16 `.tga` up to 36x36. **Nothing in this codebase
-- has ever rendered a stretched file-path image.** Every icon that works here -- the close button,
-- the search glyph, the session-rail pins -- is drawn at its asset's exact native size, and
-- `Icon.Apply` (Constants.lua) dropped `SetStretchMode` outright in round seven of the self-buff
-- icon saga precisely because stretching was what kept those tiles empty. Which means the sprite
-- subjects in rounds one and two never had a background image at all: they rendered their
-- `SetBackColor` and nothing else. **No probe cell so far has successfully drawn an image, so
-- "does a rotated image draw outside its rect" has never actually been asked.**
--
-- That is the whole of round three. Every image subject is drawn at its asset's NATIVE size with
-- no stretch -- the only image recipe confirmed working in this client. `line_long.tga` is 256x4
-- white so that Turbine's clip-to-the-control behaviour crops it to any segment length for free,
-- which is what a uniform stroke wants anyway.
--
-- CLIPPING, per the plugin's author: **Controls clip to their parent, Windows do not.** (Round
-- one's clip cell was misread as being about Controls; it was built in the default flavour, which
-- was window.) That is very likely why Gibberish3 makes every rotated piece a Window: a rotated
-- draw extends past the control's own axis-aligned rect by definition, and a Control would clip
-- exactly that overflow away. So cells E and G are Windows, and F is the same test as E on a
-- Control purely to see the difference.
--
-- The window prints its own API status in a header line rather than only to chat, so a screenshot
-- carries the whole answer.
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
local STATUS_H  = 30 -- the two API-status lines above the grid

local STROKE = 2
local ICON   = 16 -- search.tga's native size, and therefore the only size it can be drawn at
local BIG    = 36 -- the deliberately-too-big stretch case
local LINE_W = 64 -- the thin-bar subjects, cropped out of line_long.tga

local GHOST_CX   = 62
local SUBJECT_CX = 156

-- 256x4 white. Drawn with NO SetStretchMode, so Turbine clips it to the control -- which for a
-- uniform block is the same as scaling it, and unlike scaling it is confirmed to work here.
local LINE_IMAGE = "Reckoning/Resources/line_long.tga"
-- 16x16, asymmetric on purpose (a lens with a handle): distinct from itself at 45, 90 and 180,
-- which a white block is not. Drawn at native size only.
local ICON_IMAGE = "Reckoning/Resources/search.tga"

---------------------------------------------------------------------------------------------------
-- Primitives
---------------------------------------------------------------------------------------------------

local rotationOk, rotationCalls = 0, 0

-- Every SetRotation call goes through here: it is undocumented, so a client that does not have it
-- must leave an unrotated control behind rather than throw out of the constructor. pcall on the
-- method directly, not on a wrapper closure.
local function Apply(bar)
	rotationCalls = rotationCalls + 1
	local ok = pcall(bar.SetRotation, bar, bar.rotation)
	bar.applied = ok
	if ok then rotationOk = rotationOk + 1 end
	return ok
end

-- kind:  "control" | "window"
-- paint: "solid"   -- a plain SetBackColor fill, no image
--        "icon"    -- search.tga at native size
--        "line"    -- line_long.tga, clipped to the control (no stretch)
--        "stretch" -- search.tga with SetStretchMode(2), the recipe round two's blank cells used
--
-- The whole construction is pcall'd and returns nil on failure: a probe whose failing case takes
-- the window down with it answers nothing.
local function Subject(parent, kind, paint, color, z)
	local bar

	local ok = pcall(function()
		bar = (kind == "window") and Turbine.UI.Window() or Turbine.UI.Control()
		bar:SetParent(parent)
		bar:SetMouseVisible(false)
		-- A parented Turbine.UI.Window starts hidden and draws BEHIND its parent (CLAUDE.md's
		-- Turbine gotchas), so both of these are load-bearing for the "window" flavour.
		bar:SetZOrder(z or 50)

		if paint == "solid" then
			bar:SetBackColor(color)
		elseif paint == "stretch" then
			bar:SetStretchMode(2)
			bar:SetBackground(ICON_IMAGE)
		else
			-- No SetStretchMode, and no BackColor competing with the art unless the cell is
			-- specifically testing the tint -- Icon.Apply's sequence in Constants.lua, which is the
			-- only image recipe confirmed working in this client.
			bar:SetBackground((paint == "icon") and ICON_IMAGE or LINE_IMAGE)
			if color ~= nil then
				bar:SetBackColorBlendMode(Turbine.UI.BlendMode.Overlay)
				bar:SetBackColor(color)
			end
		end

		bar:SetVisible(true)
	end)

	if not ok then return nil end

	bar.rotation = { x = 0, y = 0, z = 0 }
	return bar
end

-- Size and centre a subject, then rotate it. Rotation is LAST because SetSize is one of the two
-- calls known to clear it; a zero angle is never applied at all, so a twin stays a clean control.
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
	self.cells = {}

	self.statusLine = self:Label(PAD, 6, WIDTH - 2 * PAD, "", Theme.Hex.Text)
	self.statusHint = self:Label(PAD, 20, WIDTH - 2 * PAD, "", Theme.Hex.DimText)

	self:BuildCells()
	self:RefreshStatus()
	self:Report()
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

-- A recessed, bordered box to draw inside: a 1px border Control with an inset fill on top, the same
-- two-Control shape the analysis plot's own ground uses. Returns the FILL, which is what everything
-- else parents into -- so a cell's coordinates are its own, starting at (0, 0).
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

function RotationProbe:Track(bar)
	if bar ~= nil then
		self.subjects[table.getn(self.subjects) + 1] = bar
	else
		self.refused = (self.refused or 0) + 1
	end
	return bar
end

-- Twin (left, never rotated) and subject (right, rotated) in one call -- the pairing every cell
-- needs, so "did it change?" never depends on remembering the previous load.
function RotationProbe:Pair(cell, kind, paint, w, h, deg, color)
	local twin = Subject(cell, kind, paint, color, 40)
	Place(twin, GHOST_CX, cell.cy, w, h, 0)

	local subject = self:Track(Subject(cell, kind, paint, color))
	Place(subject, SUBJECT_CX, cell.cy, w, h, deg)

	return twin, subject
end

---------------------------------------------------------------------------------------------------
-- The cells
---------------------------------------------------------------------------------------------------

function RotationProbe:BuildCells()
	-- A and B are not about rotation at all -- they are the control for everything else. Round
	-- two's icon cells came back blank and that was read as "the icon failed", when what it
	-- actually shows is that a STRETCHED file-path image does not render in this client. A is that
	-- recipe on its own, with no rotation to confuse it; B is the same art at its native size. If A
	-- is empty and B is not, every sprite subject in rounds one and two was drawing nothing but its
	-- back colour, and the image question was never asked.
	local a = self:Ground(1, "A  STRETCHED image, NO rotation  (renders?)")
	Place(Subject(a, "window", "stretch", nil, 40), SUBJECT_CX, a.cy, BIG, BIG, 0)

	local b = self:Ground(2, "B  NATIVE image, NO rotation  (renders?)")
	Place(Subject(b, "window", "icon", nil, 40), SUBJECT_CX, b.cy, ICON, ICON, 0)

	-- C and D: does the CONTENT turn? A lens with a handle is distinct from itself at both angles.
	-- 90 gets its own cell because it is the only angle Gibberish3 ever uses -- turning there but
	-- not at 45 would mean right angles only, which is no use to a plot.
	local c = self:Ground(3, "C  native icon @45  (does the art turn?)")
	self:Pair(c, "window", "icon", ICON, ICON, 45)

	local d = self:Ground(4, "D  native icon @90  (90 is all G3 uses)")
	self:Pair(d, "window", "icon", ICON, ICON, 90)

	-- E: THE DECIDING CELL. A 64x2 Window carrying a real image, at the one angle Gibberish3
	-- proves. Vertical means a rotated draw escapes its own axis-aligned rect, which is the only
	-- mechanism by which a thin control can ever draw a diagonal. Still horizontal means it cannot,
	-- and Option B is finished.
	local e = self:Ground(5, "E  native line 64x2 @90, WINDOW  <- decides it")
	self:Pair(e, "window", "line", LINE_W, STROKE, 90)

	-- F: the same test on a Control. Controls clip to their parent, Windows do not -- so if E turns
	-- and F does not, the segment pool has to be Windows.
	local f = self:Ground(6, "F  native line 64x2 @90, CONTROL  (clipped?)")
	self:Pair(f, "control", "line", LINE_W, STROKE, 90)

	-- G: the angle the plot actually needs. 90 is a special case in every graphics API ever
	-- written; 45 is the one that says whether arbitrary angles work.
	local g = self:Ground(7, "G  native line 64x2 @45, WINDOW")
	self:Pair(g, "window", "line", LINE_W, STROKE, 45)

	-- H: not about rotation either. The plot needs two series colours out of one white asset, which
	-- is Gibberish3's SetBackColorBlendMode(Overlay) + SetBackColor trick. Tinted accent means it
	-- works; plain white means the tint is ignored; nothing at all means a BackColor and an image
	-- cannot share a control here, which is what round three of the self-buff icon saga suspected.
	local h = self:Ground(8, "H  native line, Overlay TINT, no rotation")
	Place(Subject(h, "window", "line", nil, 40), GHOST_CX, h.cy, LINE_W, STROKE, 0)
	Place(Subject(h, "window", "line", Theme.Color(Theme.Hex.Accent), 41),
		SUBJECT_CX, h.cy, LINE_W, STROKE, 0)
end

---------------------------------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------------------------------

-- In the WINDOW, not only in chat: whether the method exists is a fact no cell can show (a missing
-- SetRotation and one that silently no-ops look identical), and screenshots are how this gets read.
function RotationProbe:Status()
	local function Present(factory)
		local ok, instance = pcall(factory)
		if not ok or instance == nil then return "?" end
		return (type(instance.SetRotation) == "function") and "present" or "ABSENT"
	end

	return string.format("SetRotation -- Control: %s | Window: %s | applied %d/%d%s",
		Present(Turbine.UI.Control), Present(Turbine.UI.Window),
		rotationOk, rotationCalls,
		(self.refused ~= nil) and string.format(" | %d subjects refused", self.refused) or "")
end

function RotationProbe:RefreshStatus()
	self.statusLine:SetText(self:Status())
	self.statusHint:SetText(
		"A/B render at all?  C-D art turns?  E decides: 64x2 @90 vertical or not.  H: tint works?")
end

function RotationProbe:Report()
	local function Say(text) Turbine.Shell.WriteLine("  " .. text) end

	Turbine.Shell.WriteLine("Reckoning rotation probe (round 3) -- " .. self:Status())
	Say("Left of each cell is an UNROTATED twin; right is the subject.")
	Say("A: a stretched .tga, no rotation. Blank here explains round two's empty icon cells --")
	Say("   it would mean no probe so far ever drew an image, only a back colour.")
	Say("B: the same art at native size, no rotation. This one must render or nothing below means")
	Say("   anything.")
	Say("C/D: native icon at 45 and 90. If the lens turns, the engine rotates a control's CONTENT.")
	Say("E: THE DECIDING CELL -- a 64x2 Window with a real image at 90. VERTICAL means a rotated")
	Say("   draw escapes its own rect, which is the only way a thin control can draw a diagonal.")
	Say("   Still horizontal means it cannot, and the line graph needs a different approach.")
	Say("F: same as E on a Control. Controls clip and Windows do not, so E turning while F does")
	Say("   not means the segment pool has to be Windows.")
	Say("G: 45 rather than 90 -- whether arbitrary angles work, not just right angles.")
	Say("H: one white asset tinted by SetBackColorBlendMode(Overlay) + SetBackColor, no rotation.")
	Say("   The plot needs two series colours out of one asset. Accent = works, white = tint")
	Say("   ignored, nothing = a BackColor and an image cannot share a control here.")
end
