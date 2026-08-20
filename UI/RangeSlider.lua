--=================================================================================================
-- RangeSlider -- the two-handle time-range control under the analysis plot. Dragging either
-- handle rescopes the whole window (KPIs, skill table, both side panels, the buff table) to that
-- slice of the fight; see UI/Analysis.lua's OnRangeChanged and Session:Slice.
--
-- Snaps to bucket stops, not pixels. That is not a cosmetic choice: the plot has a fixed
-- BUCKET_COUNT of columns, and snapping to the same stops is what makes the numbers in the
-- window agree with the marks on the plot exactly, instead of "close enough" -- and it keeps
-- re-aggregation cheap, since only 48 distinct ranges per endpoint can ever be asked for.
--
-- Drag uses the same shape as Frame:WireDrag and Analysis's resize gripper: MouseDown stores
-- the press offset within the handle, MouseMove re-reads args.X (which is relative to the
-- handle, so it stays correct as the handle moves under the still-pressed mouse) and MouseUp
-- clears it. Those two are confirmed-working precedent in this codebase; this file adds no new
-- assumption about how Turbine delivers mouse events.
--=================================================================================================

RangeSlider = class(Turbine.UI.Control)

local HEIGHT = 16
local TRACK_HEIGHT = 2
local TRACK_Y = 7
local HANDLE_WIDTH = 9

function RangeSlider:Constructor(width, bucketCount)
	Turbine.UI.Control.Constructor(self)

	self.plotWidth = width
	self.bucketCount = bucketCount
	self.rangeFrom = 1
	self.rangeTo = bucketCount
	self.OnChange = nil

	self:SetSize(width, HEIGHT)
	self:SetMouseVisible(false)

	self.track = Turbine.UI.Control()
	self.track:SetParent(self)
	self.track:SetPosition(0, TRACK_Y)
	self.track:SetSize(width, TRACK_HEIGHT)
	self.track:SetBackColor(Theme.Color(Theme.Hex.Border))
	self.track:SetMouseVisible(false)

	self.selected = Turbine.UI.Control()
	self.selected:SetParent(self)
	self.selected:SetPosition(0, TRACK_Y)
	self.selected:SetSize(width, TRACK_HEIGHT)
	self.selected:SetBackColor(Theme.Color(Theme.Hex.Accent))
	self.selected:SetMouseVisible(false)
	self.selected:SetZOrder(1)

	self.handleA = self:BuildHandle("from")
	self.handleB = self:BuildHandle("to")

	self:LayoutHandles()
end

-- A handle is an accent-coloured Control with a WindowFill inset one pixel in -- the same
-- border-by-inset idiom the picker chips use, since Turbine has no border property.
function RangeSlider:BuildHandle(which)
	local handle = Turbine.UI.Control()
	handle:SetParent(self)
	handle:SetSize(HANDLE_WIDTH, HEIGHT)
	handle:SetBackColor(Theme.Color(Theme.Hex.Accent))
	handle:SetMouseVisible(true)
	handle:SetZOrder(2)

	local inset = Turbine.UI.Control()
	inset:SetParent(handle)
	inset:SetPosition(1, 1)
	inset:SetSize(HANDLE_WIDTH - 2, HEIGHT - 2)
	inset:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	inset:SetMouseVisible(false)

	local slider = self

	handle.MouseDown = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			slider.dragging = which
			slider.dragOffset = args.X
		end
	end

	handle.MouseMove = function(sender, args)
		if slider.dragging ~= which then
			return
		end
		local left = select(1, handle:GetPosition()) + (args.X - slider.dragOffset)
		slider:DragTo(which, left + HANDLE_WIDTH / 2)
	end

	handle.MouseUp = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			slider.dragging = nil
		end
	end

	handle.MouseEnter = function() inset:SetBackColor(Theme.Color(Theme.Hex.Hover)) end
	handle.MouseLeave = function() inset:SetBackColor(Theme.Color(Theme.Hex.WindowFill)) end

	return handle
end

-- Pixel x (the handle's centre) -> bucket stop, clamped so the two handles can never cross or
-- meet: a zero-width range would divide by zero everywhere downstream and show nothing.
function RangeSlider:DragTo(which, centreX)
	local bucket = self:BucketAt(centreX)

	if which == "from" then
		if bucket > self.rangeTo - 1 then
			bucket = self.rangeTo - 1
		end
		if bucket < 1 then
			bucket = 1
		end
		if bucket == self.rangeFrom then
			return
		end
		self.rangeFrom = bucket
	else
		if bucket < self.rangeFrom + 1 then
			bucket = self.rangeFrom + 1
		end
		if bucket > self.bucketCount then
			bucket = self.bucketCount
		end
		if bucket == self.rangeTo then
			return
		end
		self.rangeTo = bucket
	end

	self:LayoutHandles()
	if self.OnChange ~= nil then
		self.OnChange(self.rangeFrom, self.rangeTo)
	end
end

function RangeSlider:BucketAt(x)
	if self.bucketCount <= 1 or self.plotWidth <= 0 then
		return 1
	end
	local fraction = x / self.plotWidth
	if fraction < 0 then
		fraction = 0
	elseif fraction > 1 then
		fraction = 1
	end
	return math.floor(fraction * (self.bucketCount - 1) + 0.5) + 1
end

function RangeSlider:BucketX(bucket)
	if self.bucketCount <= 1 then
		return 0
	end
	return math.floor((bucket - 1) / (self.bucketCount - 1) * self.plotWidth)
end

function RangeSlider:LayoutHandles()
	local ax = self:BucketX(self.rangeFrom)
	local bx = self:BucketX(self.rangeTo)

	self.selected:SetPosition(ax, TRACK_Y)
	self.selected:SetSize(math.max(0, bx - ax), TRACK_HEIGHT)

	-- Handles are centred on their stop, then pulled back inside the track's own bounds so
	-- neither end handle hangs off the plot.
	local function Place(handle, x)
		local left = x - math.floor(HANDLE_WIDTH / 2)
		if left < 0 then
			left = 0
		elseif left > self.plotWidth - HANDLE_WIDTH then
			left = self.plotWidth - HANDLE_WIDTH
		end
		handle:SetPosition(left, 0)
	end

	Place(self.handleA, ax)
	Place(self.handleB, bx)
end

-- Sets the range without firing OnChange -- for the caller resetting to full fight, or
-- restoring a range after a session/view switch.
function RangeSlider:SetRange(from, to)
	self.rangeFrom = from
	self.rangeTo = to
	self:LayoutHandles()
end

function RangeSlider:IsFullRange()
	return self.rangeFrom == 1 and self.rangeTo == self.bucketCount
end

-- Re-widths in place; never rebuilds or reparents a child (see UI/Row.lua's Reconfigure for
-- why nothing in this codebase detaches a Control).
function RangeSlider:Resize(width)
	self.plotWidth = width
	self:SetSize(width, HEIGHT)
	self.track:SetSize(width, TRACK_HEIGHT)
	self:LayoutHandles()
end
