--=================================================================================================
-- Frame -- shared window chrome. No Turbine.UI.Lotro.Window anywhere (docs/DESIGN.md
-- "Controls") -- every Reckoning window hand-builds its frame from this base class instead:
-- a solid background Control, 1px border Controls, a header with a title and close glyph, and
-- manual drag (MouseDown/MouseMove/MouseUp storing the offset, VitalSelf/UI/Vital.lua's
-- move-overlay pattern, applied directly to the header instead of a separate move-mode toggle).
--=================================================================================================

Frame = class(Turbine.UI.Window)

-- params: { title, key, width, height, headerHeight, fillHex, borderHex, headerRuleHex, closable }
-- `key` indexes _G.settings.windows for the persisted position. `closable` defaults to true.
-- `headerRuleHex` defaults to `borderHex` -- only the death window (docs/DESIGN.md) uses a
-- header rule distinct from its outer border.
function Frame:Constructor(params)
	Turbine.UI.Window.Constructor(self)

	self.windowKey = params.key
	self.headerHeight = params.headerHeight or 26
	self.closable = (params.closable ~= false)

	local width, height = params.width, params.height
	self:SetSize(width, height)

	local pos = _G.settings.windows[self.windowKey]
	if pos == nil then
		pos = { left = 200, top = 200 }
		_G.settings.windows[self.windowKey] = pos
	end
	self:SetPosition(pos.left, pos.top)

	local fill = Theme.Color(params.fillHex or Theme.Hex.WindowFill)
	local border = Theme.Color(params.borderHex or Theme.Hex.Border)

	self.background = Turbine.UI.Control()
	self.background:SetParent(self)
	self.background:SetPosition(0, 0)
	self.background:SetSize(width, height)
	self.background:SetBackColor(fill)
	self.background:SetMouseVisible(false)
	self.background:SetZOrder(0)

	local headerRule = Theme.Color(params.headerRuleHex or params.borderHex or Theme.Hex.Border)

	self:BuildBorder(width, height, border)
	self:BuildHeader(params.title, width, headerRule)

	-- Content area below the header. Subclasses add their own children under this, not
	-- directly under self, so header/border z-ordering never has to be revisited.
	self.client = Turbine.UI.Control()
	self.client:SetParent(self)
	self.client:SetPosition(0, self.headerHeight)
	self.client:SetSize(width, height - self.headerHeight)
	self.client:SetMouseVisible(false)
	self.client:SetZOrder(1)
end

function Frame:BuildBorder(width, height, color)
	local function Edge(x, y, w, h)
		local edge = Turbine.UI.Control()
		edge:SetParent(self)
		edge:SetPosition(x, y)
		edge:SetSize(w, h)
		edge:SetBackColor(color)
		edge:SetMouseVisible(false)
		edge:SetZOrder(2)
		return edge
	end

	-- Kept for Resize() -- only the analysis window (Phase 5) resizes after construction.
	self.borderEdges = {
		top = Edge(0, 0, width, 1),
		bottom = Edge(0, height - 1, width, 1),
		left = Edge(0, 0, 1, height),
		right = Edge(width - 1, 0, 1, height),
	}
end

-- Resizes the chrome (background, 4 border edges, header width, client) to a new size.
-- Fixed-size windows (live meter, death cause) never call this; only a resizable subclass
-- (the analysis window) does, after the user drags its resize gripper.
function Frame:Resize(width, height)
	self:SetSize(width, height)
	self.background:SetSize(width, height)

	self.borderEdges.top:SetSize(width, 1)
	self.borderEdges.bottom:SetPosition(0, height - 1)
	self.borderEdges.bottom:SetSize(width, 1)
	self.borderEdges.left:SetSize(1, height)
	self.borderEdges.right:SetPosition(width - 1, 0)
	self.borderEdges.right:SetSize(1, height)

	self.header:SetSize(width, self.headerHeight)
	self.headerRule:SetSize(width, 1)
	if self.titleLabel ~= nil then
		self.titleLabel:SetSize(width - (self.closable and 30 or 16), self.headerHeight)
	end
	if self.closeLabel ~= nil then
		self.closeLabel:SetPosition(width - 22, 0)
	end

	self.client:SetSize(width, height - self.headerHeight)
end

function Frame:BuildHeader(title, width, ruleColor)
	self.header = Turbine.UI.Control()
	self.header:SetParent(self)
	self.header:SetPosition(0, 0)
	self.header:SetSize(width, self.headerHeight)
	self.header:SetZOrder(3)

	-- Only the analysis window (Phase 5) uses a plain title + close bar. The live meter and
	-- death cause headers are bespoke content (accent tick + clock; "You were defeated" +
	-- countdown) -- passing no title skips this label and leaves self.header empty for the
	-- subclass to fill after Constructor runs.
	if title ~= nil then
		self.titleLabel = Turbine.UI.Label()
		self.titleLabel:SetParent(self.header)
		self.titleLabel:SetFont(Font.TrajanPro13)
		self.titleLabel:SetText(title)
		self.titleLabel:SetForeColor(Theme.Color(Theme.Hex.Text))
		self.titleLabel:SetPosition(10, 0)
		self.titleLabel:SetSize(width - (self.closable and 30 or 16), self.headerHeight)
		self.titleLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		self.titleLabel:SetMouseVisible(false)
	end

	if self.closable then
		self.closeLabel = Turbine.UI.Label()
		self.closeLabel:SetParent(self.header)
		self.closeLabel:SetFont(Font.Verdana10)
		self.closeLabel:SetText("x")
		self.closeLabel:SetForeColor(Theme.Color(Theme.Hex.MutedText))
		self.closeLabel:SetSize(20, self.headerHeight)
		self.closeLabel:SetPosition(width - 22, 0)
		self.closeLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)

		local frame = self
		self.closeLabel.MouseClick = function()
			frame:Close()
		end
	end

	self.headerRule = Turbine.UI.Control()
	self.headerRule:SetParent(self)
	self.headerRule:SetPosition(0, self.headerHeight - 1)
	self.headerRule:SetSize(width, 1)
	self.headerRule:SetBackColor(ruleColor)
	self.headerRule:SetMouseVisible(false)
	self.headerRule:SetZOrder(3)

	self:WireDrag()
end

-- Manual drag on the header. args.X/args.Y are mouse-relative-to-control coordinates, so
-- re-reading them every MouseMove (rather than the window's own position) keeps the offset
-- correct as the window itself moves underneath the still-pressed mouse.
function Frame:WireDrag()
	local frame = self

	self.header.MouseDown = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			frame.dragging = true
			frame.dragStartX = args.X
			frame.dragStartY = args.Y
		end
	end

	self.header.MouseMove = function(sender, args)
		if frame.dragging then
			local x, y = frame:GetPosition()
			x = x + (args.X - frame.dragStartX)
			y = y + (args.Y - frame.dragStartY)
			frame:SetPosition(x, y)
		end
	end

	self.header.MouseUp = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			frame.dragging = false
			local left, top = frame:GetPosition()
			_G.settings.windows[frame.windowKey] = { left = left, top = top }
			Settings.Save()
		end
	end
end

-- Default: just hide. Subclasses (none yet) can override for different close semantics.
function Frame:Close()
	self:SetVisible(false)
end
