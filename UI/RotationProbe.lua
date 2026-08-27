--=================================================================================================
-- RotationProbe -- `/reck probe`, a throwaway diagnostic window.
--
-- Turbine has no canvas and no line primitive, so a diagonal can only be drawn by ROTATING an
-- axis-aligned Control. `SetRotation` is undocumented but real and in production: Gibberish3's
-- circular timer (UI_ELEMENTS/TIMER/CIRCEL/Element.lua) turns its leading sweep piece with it --
-- degrees, in an { x =, y =, z = } table, kept in Lua and re-applied after every `SetSize` or
-- `SetBackground` (both clear it), on a `Turbine.UI.Window` carrying a stretched background image.
--
-- ROUND 2. Round one drew a 45-degree segment in all four combinations of Control/Window x
-- back-colour/sprite and got four flat horizontal bars. That looked like a definitive "rotation
-- does nothing", and it is not, because every subject it drew was either a FLAT COLOUR or a
-- UNIFORM WHITE BLOCK -- rotate either one inside its own rectangle and it looks exactly the same.
-- Two very different engine behaviours produce identical flat bars:
--
--   (a) SetRotation does nothing at all; or
--   (b) SetRotation rotates the control's CONTENT inside a rect that stays axis-aligned.
--
-- (b) is not a stretch: every rotation subject in Gibberish3 is a SQUARE control fully covered by
-- a STRUCTURED image, which looks the same under both behaviours -- so that file, the only
-- production evidence anywhere, cannot distinguish them either. The difference decides the whole
-- rework: under (b) a 2px-tall segment can never draw a diagonal no matter what angle it is given,
-- and Option B is dead.
--
-- So this round asks with subjects that cannot hide it:
--
--   * a SQUARE OF SOLID COLOUR at 45 degrees -- a diamond if the RECT rotates, unchanged if not;
--   * an ASYMMETRIC ICON (search.tga, a lens with a handle) at 45 -- turns if the CONTENT rotates,
--     and gets its corners clipped to the original square if the rect did not rotate with it;
--   * a THIN BAR at z=90 -- the one angle Gibberish3 actually proves. If a 44x2 bar becomes a 2x44
--     vertical line, rects do rotate and only ARBITRARY angles are in question;
--   * the same icon at 15/30/60/75, which is what "arbitrary" means here;
--   * and the same icon parented straight into the Frame's own Window, because Gibberish3 only
--     ever parents its rotated Windows into other Windows and `Graph` is a Control.
--
-- Every cell carries an UNROTATED twin beside its subject (above it, in the thin-bar cell), so
-- "did it change?" is answerable without remembering what the last load looked like.
--
-- CLIPPING, corrected. Round one's clip cell was written up as "a control is not clipped to its
-- parent's bounds" -- wrong: that subject was built in the command's default flavour, which is
-- WINDOW. **Controls clip, Windows do not.** So round one showed only that a Window escapes its
-- parent's bounds, which is very likely the reason Gibberish3 makes every rotated piece a
-- `Turbine.UI.Window` in the first place: a rotated draw extends past the control's own
-- axis-aligned rect, and a Control would clip exactly that overflow away.
--
-- That has two consequences here. A Control at 45 degrees may render as an OCTAGON (the rotated
-- square clipped back to the unrotated one) rather than a diamond -- which still counts as "the
-- rect rotated", and the chat key says so. And the deciding cell parents its subjects straight
-- into the Frame's own Window, so nothing in the chain can clip the one answer that matters.
--
-- NOTHING ELSE IMPORTS THIS. It is built on demand by /reck probe and is meant to be deleted once
-- the answers are written into docs/redesign/GRAPH_RESEARCH.md section 7.
--=================================================================================================

RotationProbe = class(Frame)

local WIDTH  = 480
local HEIGHT = 546

local PAD       = 12
local LABEL_H   = 14
local CELL_W    = 222
local CELL_H    = 76
local ROW_PITCH = LABEL_H + CELL_H + 8

local STROKE  = 2
local DOT     = 3
local WIDE_H  = 96 -- the full-width polyline cell

local SUBJECT   = 36 -- the square subjects
local GHOST_CX  = 62 -- where the unrotated twin sits inside a cell
local SUBJECT_CX = 152

local LINE_IMAGE = "Reckoning/Resources/line.tga"
-- An ASYMMETRIC glyph on purpose: a lens with a handle pointing down-right, which is distinct
-- from itself at 45, 90 and 180. Round one's white block was not, and that is what made its
-- result unreadable. Drawn with the icon recipe this codebase has confirmed working in-game
-- (SetBlendMode(Overlay), no BackColor -- Frame's close button, visible in the round-one
-- screenshot), NOT Gibberish3's SetBackColorBlendMode tint: whether the tint recipe works is not
-- the question here, and a subject that fails to render answers nothing.
local ICON_IMAGE = "Reckoning/Resources/search.tga"

-- Positive z is ASSUMED to turn clockwise on screen (y grows downward, so a segment rising to the
-- right is a negative angle). Only meaningful once something visibly rotates at all.
local ROT_SIGN = 1

---------------------------------------------------------------------------------------------------
-- Primitives
---------------------------------------------------------------------------------------------------

-- Every SetRotation call in this file goes through here: it is undocumented, so a client that does
-- not have it at all must leave an unrotated control behind rather than throw out of the
-- constructor. pcall on the method directly, not on a wrapper closure.
local function Apply(bar)
	local ok = pcall(bar.SetRotation, bar, bar.rotation)
	bar.applied = ok
	return ok
end

-- kind: "control" | "window".  paint: "solid" | "icon" | "sprite".
--
--   solid  -- a plain SetBackColor fill, no image at all
--   icon   -- search.tga, the asymmetric subject
--   sprite -- line.tga, the uniform white block the polyline would actually be drawn from
--
-- The whole construction is pcall'd and returns nil on failure, because a probe whose failing case
-- takes the window down with it answers nothing: parenting a Turbine.UI.Window into a
-- Turbine.UI.Control has no precedent in this codebase either.
local function Subject(parent, kind, paint, color, z)
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
		bar:SetZOrder(z or 50)

		if paint == "solid" then
			bar:SetBackColor(color)
		else
			bar:SetStretchMode(2)
			bar:SetBackground((paint == "icon") and ICON_IMAGE or LINE_IMAGE)
			bar:SetBlendMode(Turbine.UI.BlendMode.Overlay)
			if paint == "sprite" then
				bar:SetBackColor(color)
			end
		end

		bar:SetVisible(true)
	end)

	if not ok then
		return nil
	end

	bar.rotation = { x = 0, y = 0, z = 0 }
	return bar
end

-- Size and centre a subject, then rotate it. Order is the same everywhere and rotation is LAST,
-- because SetSize is one of the two calls known to clear it.
local function Place(bar, cx, cy, w, h, deg)
	if bar == nil then return end
	bar:SetSize(w, h)
	bar:SetPosition(math.floor(cx - w / 2), math.floor(cy - h / 2))
	bar.rotation.z = deg
	if deg ~= 0 then
		Apply(bar)
	end
end

-- The segment arithmetic UI/AnalysisGraph.lua would ship: the control is sized to the segment's
-- own length and centred on its midpoint (rotation pivots on the centre), with +stroke of length
-- so consecutive segments overlap at their joints instead of leaving a wedge-shaped gap.
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

	-- The polyline cell is built per flavour on first request and kept, so re-running /reck probe
	-- with different arguments swaps visibility instead of leaking a second set of Controls (there
	-- is no confirmed-safe way to destroy one -- see UI/Row.lua's Reconfigure).
	self.sets = {}
	self.activeSet = nil

	self:BuildMatrix()
	self:BuildAngleCells()
	self:BuildLineGround()

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

	fill.originX, fill.originY = x + 1, top + 1 -- client coords, for the ancestry cell
	return fill
end

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

-- The dim, unrotated twin every cell carries beside its subject. Without it "did anything change?"
-- depends on remembering what the previous load looked like, which is exactly the kind of judgement
-- that made round one's result unreadable.
function RotationProbe:Ghost(parent, kind, paint, cx, cy, w, h)
	-- Theme.Mix already returns a Turbine.UI.Color; wrapping it in Theme.Color again would hand
	-- a Color to a function expecting a hex string.
	local ghost = Subject(parent, kind, paint,
		Theme.Mix(Theme.Hex.Accent, Theme.Hex.PlotFill, 0.35), 40)
	Place(ghost, cx, cy, w, h, 0)
	return ghost
end

---------------------------------------------------------------------------------------------------
-- Cells 1-4 -- does the RECT rotate, or only its content?
---------------------------------------------------------------------------------------------------

-- A SOLID SQUARE at 45 degrees is a diamond if the control's own rectangle is transformed, and
-- completely unchanged if it is not -- there is no content inside it to turn. The ICON square is
-- the other half: it turns if the content is transformed, whatever the rect does. Read as a pair:
--
--   solid unchanged + icon unchanged -> SetRotation does nothing. Option B is dead.
--   solid unchanged + icon turned    -> content-only rotation. A 2px segment can never be a
--                                       diagonal. Option B is dead, but for a different reason,
--                                       and the icon's corners will be clipped square.
--   solid is a diamond               -> rects do rotate, and something else was wrong in round one.
function RotationProbe:BuildMatrix()
	local combos = {
		{ kind = "control", paint = "solid", text = "1  CONTROL + solid square @45  (diamond?)" },
		{ kind = "window",  paint = "solid", text = "2  WINDOW + solid square @45  (diamond?)" },
		{ kind = "control", paint = "icon",  text = "3  CONTROL + icon @45  (does it turn?)" },
		{ kind = "window",  paint = "icon",  text = "4  WINDOW + icon @45  (does it turn?)" },
	}

	self.matrix = {}

	for i, combo in ipairs(combos) do
		local col = (i - 1) % 2
		local row = math.floor((i - 1) / 2)
		local ground = self:Ground(PAD + col * (CELL_W + PAD), PAD + row * ROW_PITCH,
			CELL_W, CELL_H, combo.text)

		local _, ch = ground:GetSize()
		local cy = math.floor(ch / 2)

		self:Ghost(ground, combo.kind, combo.paint, GHOST_CX, cy, SUBJECT, SUBJECT)

		local bar = Subject(ground, combo.kind, combo.paint, Theme.Color(Theme.Hex.Accent))
		Place(bar, SUBJECT_CX, cy, SUBJECT, SUBJECT, 45)

		self.matrix[i] = { combo = combo, bar = bar }
	end
end

---------------------------------------------------------------------------------------------------
-- Cells 5-8 -- the angle, the ancestry and the thin bar
---------------------------------------------------------------------------------------------------

function RotationProbe:BuildAngleCells()
	self.angleBars = {}
	local function Track(bar)
		if bar ~= nil then
			self.angleBars[table.getn(self.angleBars) + 1] = bar
		end
		return bar
	end

	local y = PAD + 2 * ROW_PITCH

	-- Cell 5: z=90, the ONLY kind of angle Gibberish3 ever uses. If the icon turns here but not at
	-- 45 in cells 3-4, the engine only honours right angles and no diagonal is reachable.
	local ninety = self:Ground(PAD, y, CELL_W, CELL_H, "5  WINDOW + icon @90  (90 is all G3 uses)")
	local _, ch = ninety:GetSize()
	local cy = math.floor(ch / 2)
	self:Ghost(ninety, "window", "icon", GHOST_CX, cy, SUBJECT, SUBJECT)
	Place(Track(Subject(ninety, "window", "icon", Theme.Color(Theme.Hex.Accent))),
		SUBJECT_CX, cy, SUBJECT, SUBJECT, 90)

	-- Cell 6: the same subject at 45, but parented straight into the Frame's own Window instead of
	-- through three nested Controls. Gibberish3 only ever parents its rotated Windows into other
	-- Windows, and Graph is a Control -- if the ancestry is what matters, this is the cell that
	-- shows it. Positioned in WINDOW coordinates, hence the ground's recorded origin plus the
	-- header height.
	local ancestry = self:Ground(PAD + CELL_W + PAD, y, CELL_W, CELL_H,
		"6  icon @45, parented to the WINDOW")
	self:Ghost(ancestry, "window", "icon", GHOST_CX, cy, SUBJECT, SUBJECT)
	Place(Track(Subject(self, "window", "icon", Theme.Color(Theme.Hex.Accent), 60)),
		ancestry.originX + SUBJECT_CX, ancestry.originY + cy + self.headerHeight,
		SUBJECT, SUBJECT, 45)

	y = y + ROW_PITCH

	-- Cell 7: what "arbitrary" actually means -- four angles that are not multiples of 90.
	local arbitrary = self:Ground(PAD, y, CELL_W, CELL_H, "7  icon @15 / 30 / 60 / 75")
	local aw, ah = arbitrary:GetSize()
	for i, deg in ipairs({ 15, 30, 60, 75 }) do
		Place(Track(Subject(arbitrary, "window", "icon", Theme.Color(Theme.Hex.Accent))),
			math.floor(i * aw / 5), math.floor(ah / 2), 24, 24, deg)
	end

	-- Cell 8: THE ONE THE PLOT ACTUALLY DEPENDS ON. A 60x2 bar at z=90 must become a 2x60 vertical
	-- line if the control's rect is transformed. A uniform white sprite has no content to turn, so
	-- this cell cannot be fooled the way round one was: vertical means rects rotate, still
	-- horizontal means they do not, and no third reading exists.
	local thin = self:Ground(PAD + CELL_W + PAD, y, CELL_W, CELL_H,
		"8  THIN BAR @90 -- vertical or not")
	local tw = thin:GetSize()

	-- Twins go in a lane ABOVE their subjects rather than beside them: side by side, a bar that
	-- failed to rotate would overlap its own reference and read as one long smear.
	local GHOST_Y, SUBJECT_Y, THIN_LEN = 16, 46, 44
	local left, right = math.floor(tw / 4), math.floor(3 * tw / 4)

	-- The subjects are parented into the FRAME'S OWN WINDOW, not into this cell's Control ground,
	-- and so are positioned in window coordinates. This is the one cell whose answer decides the
	-- rework, so it runs under the most favourable configuration available: an all-Window
	-- ancestry like Gibberish3's, with nothing in the chain that clips. A rotated bar's draw
	-- extends past its own axis-aligned rect by definition, and a Control ancestor would clip
	-- precisely that overflow -- which would make a working rotation look like a failed one.
	self.thinCell = { ghosts = {}, subjects = {}, ghostY = GHOST_Y, subjectY = SUBJECT_Y }
	local originY = thin.originY + self.headerHeight

	for i, spec in ipairs({
		{ paint = "sprite", cx = left,  hex = Theme.Hex.Accent },
		{ paint = "solid",  cx = right, hex = Theme.Hex.DamageTaken },
	}) do
		self.thinCell.ghosts[i] =
			self:Ghost(thin, "window", spec.paint, spec.cx, GHOST_Y, THIN_LEN, STROKE)

		local subject = Track(Subject(self, "window", spec.paint, Theme.Color(spec.hex), 60))
		Place(subject, thin.originX + spec.cx, originY + SUBJECT_Y, THIN_LEN, STROKE, 90)
		self.thinCell.subjects[i] = subject
	end
end

---------------------------------------------------------------------------------------------------
-- Cell 9 -- the real polyline, in whichever flavour was asked for
---------------------------------------------------------------------------------------------------

function RotationProbe:BuildLineGround()
	self.lineGround = self:Ground(PAD, PAD + 4 * ROW_PITCH, WIDTH - 2 * PAD, WIDE_H,
		"9  REAL POLYLINE (ships as-is)")

	-- A fixed 9-point series, deliberately including a flat run, a steep rise and a steep fall --
	-- the three shapes the L-step version renders worst.
	self.lineData = { 0.15, 0.62, 0.58, 0.95, 0.10, 0.12, 0.74, 0.30, 0.55 }
end

function RotationProbe:BuildSet(kind, paint)
	local set = { bars = {}, dots = {}, kind = kind, paint = paint }

	-- A combination this client refuses (Subject returns nil) must not land in the pool as a hole
	-- -- an array-style table with a nil in it has an undefined length in Lua, which is the exact
	-- footgun that once shifted every picker chip's filter off by one (CLAUDE.md).
	local function NewBar()
		local bar = Subject(self.lineGround, kind, paint, Theme.Color(Theme.Hex.DamageTaken))
		if bar ~= nil then
			set.bars[table.getn(set.bars) + 1] = bar
		else
			set.refused = (set.refused or 0) + 1
		end
		return bar
	end

	local lw, lh = self.lineGround:GetSize()
	local points = table.getn(self.lineData)
	local pitch = lw / points
	local xs, ys = {}, {}
	for i = 1, points do
		xs[i] = (i - 1) * pitch + pitch / 2
		ys[i] = lh - 6 - self.lineData[i] * (lh - 16)
	end

	-- Kept so the offline harness can reconstruct each segment's endpoints from its rendered
	-- (position, size, rotation) and check they land back on the data points -- the same check that
	-- will guard UI/AnalysisGraph.lua once this ships.
	set.linePoints, set.lineBars = {}, {}
	for i = 1, points - 1 do
		local bar = NewBar()
		PlaceSegment(bar, xs[i], ys[i], xs[i + 1], ys[i + 1], STROKE)
		set.lineBars[i] = bar
	end
	for i = 1, points do
		set.linePoints[i] = { x = xs[i], y = ys[i] }
		set.dots[i] = self:Dot(self.lineGround, xs[i], ys[i], Theme.Hex.DamageFatal, 5)
	end

	return set
end

-- Swap which flavour the polyline is drawn in. Rotation is re-applied on every show: whether it
-- survives a SetVisible round-trip is itself unknown, and the shipping code re-specifies every
-- visible segment on each Redraw anyway, so this mirrors what it will do.
function RotationProbe:ShowFlavour(kind, paint)
	if paint ~= "plain" and paint ~= "sprite" then paint = "sprite" end
	local key = kind .. ":" .. paint

	if self.activeSet ~= nil and self.activeSet ~= key then
		local old = self.sets[self.activeSet]
		for _, bar in ipairs(old.bars) do bar:SetVisible(false) end
		for _, dot in ipairs(old.dots) do dot:SetVisible(false) end
	end

	if self.sets[key] == nil then
		-- The polyline's "plain" flavour is a bare SetBackColor fill; "sprite" is line.tga.
		self.sets[key] = self:BuildSet(kind, (paint == "plain") and "solid" or "sprite")
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
-- show (a missing SetRotation and one that silently no-ops look identical), and what each cell
-- means has to be written down before the render is judged against it.
function RotationProbe:Report(set)
	local function Say(text) Turbine.Shell.WriteLine("  " .. text) end

	-- Read off the matrix's own subjects rather than constructing throwaway instances: those are
	-- the real objects in play. A method that reads as present can still be a silent no-op.
	local function Present(bar)
		if bar == nil then return "n/a (construction refused)" end
		return (type(bar.SetRotation) == "function") and "present" or "ABSENT"
	end

	Turbine.Shell.WriteLine("Reckoning rotation probe (round 2) -- cell 9 drawn as "
		.. string.upper(set.kind) .. " + " .. set.paint
		.. " (/reck probe <control|window> <plain|sprite>)")

	Say("SetRotation on Turbine.UI.Control: " .. Present(self.matrix[1].bar))
	Say("SetRotation on Turbine.UI.Window:  " .. Present(self.matrix[2].bar))

	local applied, total = 0, 0
	for _, bar in ipairs(self.angleBars) do
		total = total + 1
		if bar.applied then applied = applied + 1 end
	end
	for _, bar in ipairs(set.bars) do
		total = total + 1
		if bar.applied then applied = applied + 1 end
	end
	Say(string.format("SetRotation calls that did not throw: %d/%d%s", applied, total,
		(set.refused ~= nil) and string.format("  (%d subjects could not be built)", set.refused) or ""))

	Say("Every cell carries an UNROTATED TWIN beside (cells 1-6) or above (cell 8) its subject.")
	Say("1-2: a solid square at 45. A DIAMOND means the control's own rect rotates -- which is the")
	Say("   only way a 2px segment can ever be a diagonal. Unchanged means it does not. Cell 1 is")
	Say("   a CONTROL and controls clip, so an OCTAGON there (the diamond cut back to the square)")
	Say("   still counts as the rect having rotated.")
	Say("3-4: an asymmetric icon at 45 (lens + handle). If it TURNS while 1-2 stayed square, the")
	Say("   engine rotates a control's CONTENT inside an axis-aligned rect -- look for the corners")
	Say("   being cut off square. That kills the line graph as surely as no rotation at all.")
	Say("5: the same icon at 90, the only angle Gibberish3 ever uses. Turning here but not at 45")
	Say("   means right angles only.")
	Say("6: the same icon at 45 parented straight into the window, not through nested Controls.")
	Say("7: 15/30/60/75 -- what 'arbitrary angle' actually means.")
	Say("8: THE DECIDING CELL. Two 44x2 bars at 90, sprite and solid, parented into the window")
	Say("   itself so nothing in the chain can clip them. VERTICAL means rects rotate and the plot")
	Say("   can be a real line; still horizontal means it cannot, full stop.")
	Say("9: the polyline, drawn by the exact code UI/AnalysisGraph.lua would ship. Only worth")
	Say("   reading if cell 8 came out vertical.")
end
