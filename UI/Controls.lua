--=================================================================================================
-- Controls -- the options window's control vocabulary: a single-handle Slider and a Segment
-- strip. Both are plain Controls with fill-and-inset borders, since Turbine has no border
-- property (same idiom as RangeSlider:BuildHandle and the analysis window's picker chips).
--
-- Slider reuses RangeSlider's drag idiom EXACTLY -- MouseDown stores the press offset within the
-- handle, MouseMove re-reads args.X (relative to the handle, so it stays correct as the handle
-- moves under the still-pressed mouse), MouseUp clears it. That is confirmed-working precedent
-- here (Frame:WireDrag, RangeSlider:BuildHandle, the analysis resize gripper), and it obeys the
-- rule those three established the hard way: a handler that reads args.X off the dragged control
-- MUST move that control inside the same MouseMove, or every event re-applies the whole offset
-- from the press point and the value runs away from the pointer. SetValue -> Layout does exactly
-- that (see CLAUDE.md's resize-gripper note for the bug this prevents).
--=================================================================================================

Slider = class(Turbine.UI.Control)

local S_HEIGHT = 16
local S_TRACK_H = 4
local S_TRACK_Y = 6
local S_HANDLE_W = 8
local S_HANDLE_H = 12

-- low/high are inclusive integer bounds. OnChange(value) fires on every value change, for a live
-- preview; OnCommit(value) fires once on release. The caller saves in OnCommit and never in
-- OnChange -- Settings.Save() is a Turbine.PluginData write and a single drag crosses dozens of
-- stops.
function Slider:Constructor(width, low, high, value, fillHex)
	Turbine.UI.Control.Constructor(self)

	self.width = width
	self.low = low
	self.high = high
	self.step = 1
	self.value = value or low
	self.OnChange = nil
	self.OnCommit = nil

	self:SetSize(width, S_HEIGHT)
	self:SetMouseVisible(true) -- clicking the track jumps the handle to that value

	self.track = Turbine.UI.Control()
	self.track:SetParent(self)
	self.track:SetPosition(0, S_TRACK_Y)
	self.track:SetSize(width, S_TRACK_H)
	self.track:SetBackColor(Theme.Color(Theme.Hex.RowBorder))
	self.track:SetMouseVisible(false)

	self.fillHex = fillHex or Theme.Hex.Accent

	self.filled = Turbine.UI.Control()
	self.filled:SetParent(self)
	self.filled:SetPosition(0, S_TRACK_Y)
	self.filled:SetSize(0, S_TRACK_H)
	self.filled:SetBackColor(Theme.Color(self.fillHex))
	self.filled:SetMouseVisible(false)
	self.filled:SetZOrder(1)

	self.handle = Turbine.UI.Control()
	self.handle:SetParent(self)
	self.handle:SetSize(S_HANDLE_W, S_HANDLE_H)
	self.handle:SetPosition(0, 2)
	self.handle:SetBackColor(Theme.Color(Theme.Hex.AccentLight))
	self.handle:SetMouseVisible(true)
	self.handle:SetZOrder(2)

	local slider = self

	self.handle.MouseDown = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			slider.dragging = true
			slider.dragOffset = args.X
		end
	end

	self.handle.MouseMove = function(sender, args)
		if not slider.dragging then
			return
		end
		local left = select(1, slider.handle:GetPosition()) + (args.X - slider.dragOffset)
		slider:SetValue(slider:ValueAt(left + S_HANDLE_W / 2), true)
	end

	self.handle.MouseUp = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left and slider.dragging then
			slider.dragging = false
			if slider.OnCommit ~= nil then
				slider.OnCommit(slider.value)
			end
		end
	end

	-- A click on the track is a jump-and-commit in one: there is no drag to release, so the
	-- commit has to happen here or the new value would live in _G.settings unsaved until some
	-- other control happened to save.
	self.MouseClick = function(sender, args)
		slider:SetValue(slider:ValueAt(args.X), true)
		if slider.OnCommit ~= nil then
			slider.OnCommit(slider.value)
		end
	end

	self:Layout()
end

-- Pixel x (measured from the slider's left edge, at the handle's CENTRE) -> a value on the scale.
-- The travel is width - handle width, not width: the handle's own left edge never goes past
-- width - S_HANDLE_W, so using the full width would make the top of the range unreachable.
function Slider:ValueAt(x)
	local span = self.width - S_HANDLE_W
	if span <= 0 then
		return self.low
	end
	local fraction = (x - S_HANDLE_W / 2) / span
	if fraction < 0 then
		fraction = 0
	elseif fraction > 1 then
		fraction = 1
	end
	local raw = self.low + fraction * (self.high - self.low)
	return math.floor(raw / self.step + 0.5) * self.step
end

function Slider:SetValue(value, fire)
	if value < self.low then
		value = self.low
	elseif value > self.high then
		value = self.high
	end
	if value == self.value then
		return
	end
	self.value = value
	self:Layout()
	if fire and self.OnChange ~= nil then
		self.OnChange(value)
	end
end

function Slider:SetFillColor(hex)
	self.fillHex = hex
	self.filled:SetBackColor(Theme.Color(hex))
end

function Slider:Layout()
	local span = self.high - self.low
	local fraction = (span > 0) and ((self.value - self.low) / span) or 0
	local x = math.floor(fraction * (self.width - S_HANDLE_W) + 0.5)
	self.handle:SetPosition(x, 2)
	self.filled:SetSize(x + math.floor(S_HANDLE_W / 2), S_TRACK_H)
end

---------------------------------------------------------------------------------------------------

Segment = class(Turbine.UI.Control)

local SEG_H = 20
local SEG_PAD = 20 -- horizontal padding around a cell's text

-- Cell width. Label:GetWidth() returning a MEASURED width after SetText on a never-sized Label is
-- not established anywhere in this codebase -- there is no text-measurement API in use here at
-- all, which is exactly why UI/Analysis.lua's picker chips estimate their width by character
-- count instead. So this tries the measurement and sanity-checks it against that same estimate:
-- if GetWidth() comes back at 0 (an unsized Control's default) or absurdly small for the string,
-- the estimate wins. Either way the cell is wide enough for its text, and if the measurement does
-- turn out to work in-game the cells are tighter than an estimate could make them.
--
-- 7px per character matches ChipWidth's own Verdana10 estimate in UI/Analysis.lua; Format.CharCount
-- is used rather than string.len so a multi-byte character is counted once (no segment label
-- currently has one, but the two width paths must agree on what "a character" is).
local function CellWidth(label, text)
	local estimate = Format.CharCount(text) * 7 + SEG_PAD
	local measured = 0
	local ok, value = pcall(function() return label:GetWidth() end)
	if ok and type(value) == "number" then
		measured = value + SEG_PAD
	end
	if measured >= estimate then
		return measured
	end
	return estimate
end

-- options: { { label = , value = }, ... }. Cells share edges (no gap) and lay out left to right
-- from x = 0; the caller positions the whole strip, typically right-aligned.
function Segment:Constructor(options, value, font)
	Turbine.UI.Control.Constructor(self)

	self.options = options
	self.value = value
	self.cells = {}
	self.OnChange = nil

	local seg = self
	local x = 0

	for i = 1, table.getn(options) do
		local option = options[i]

		local cell = Turbine.UI.Control()
		cell:SetParent(self)
		cell:SetSize(10, SEG_H)
		cell:SetMouseVisible(true)

		-- Fill-plus-inset: `cell` is the 1px border, `inner` is everything inside it.
		local inner = Turbine.UI.Control()
		inner:SetParent(cell)
		inner:SetPosition(1, 1)
		inner:SetMouseVisible(false)

		local label = Turbine.UI.Label()
		label:SetParent(inner)
		label:SetFont(font or Font.Verdana10)
		label:SetText(option.label)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
		label:SetMouseVisible(false)

		local cellWidth = CellWidth(label, option.label)
		cell:SetSize(cellWidth, SEG_H)
		cell:SetPosition(x, 0)
		inner:SetSize(cellWidth - 2, SEG_H - 2)
		label:SetPosition(0, 0)
		label:SetSize(cellWidth - 2, SEG_H - 2)

		cell.MouseClick = function()
			seg:SetValue(option.value, true)
		end
		cell.MouseEnter = function()
			if seg.value ~= option.value then
				inner:SetBackColor(Theme.Color(Theme.Hex.Hover))
			end
		end
		cell.MouseLeave = function()
			if seg.value ~= option.value then
				inner:SetBackColor(nil)
			end
		end

		self.cells[i] = { cell = cell, inner = inner, label = label, value = option.value }
		x = x + cellWidth - 1 -- -1: adjacent cells share their 1px border
	end

	self:SetSize(x + 1, SEG_H)
	self:SetMouseVisible(false)
	self:Paint()
end

function Segment:SetValue(value, fire)
	if value == self.value then
		return
	end
	self.value = value
	self:Paint()
	if fire and self.OnChange ~= nil then
		self.OnChange(value)
	end
end

function Segment:Paint()
	for i = 1, table.getn(self.cells) do
		local cell = self.cells[i]
		local selected = (cell.value == self.value)
		cell.cell:SetBackColor(Theme.Color(selected and Theme.Hex.Accent700 or Theme.Hex.Border))
		cell.inner:SetBackColor(selected and Theme.Color(Theme.Hex.ActiveTab) or nil)
		cell.label:SetForeColor(Theme.Color(selected and Theme.Hex.Accent200 or Theme.Hex.MutedText))
	end
end
