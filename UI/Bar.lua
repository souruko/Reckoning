--=================================================================================================
-- Bar -- a 1px-border track Control whose fill child's width is set on refresh. Used for the
-- analysis window's share bars (docs/DESIGN.md skill table, side panels) and anywhere else a
-- flat percent-fill bar is needed. No animation -- widths are set directly, never tweened
-- (docs/DESIGN.md "Interactions": "the engine has no tweening and a combat meter should not
-- move on its own").
--=================================================================================================

Bar = class(Turbine.UI.Control)

-- trackHex defaults to the design's generic bar track (docs/DESIGN.md "Border" role); fillHex
-- is required -- callers pass the series/role colour (e.g. Theme.Hex.DamageDone).
function Bar:Constructor(width, height, fillHex, trackHex)
	Turbine.UI.Control.Constructor(self)

	self:SetSize(width, height)
	self:SetBackColor(Theme.Color(trackHex or Theme.Hex.Border))
	self:SetMouseVisible(false)

	self.maxWidth = width

	self.fill = Turbine.UI.Control()
	self.fill:SetParent(self)
	self.fill:SetPosition(0, 0)
	self.fill:SetSize(0, height)
	self.fill:SetBackColor(Theme.Color(fillHex))
	self.fill:SetMouseVisible(false)
	self.fill:SetZOrder(1)
end

-- pct is clamped to [0, 1]; the pixel width is rounded, not truncated, so small percentages
-- still round up to a visible sliver rather than disappearing at 0px.
function Bar:SetPercent(pct)
	if pct == nil or pct < 0 then
		pct = 0
	elseif pct > 1 then
		pct = 1
	end

	local _, height = self.fill:GetSize()
	self.fill:SetSize(math.floor(self.maxWidth * pct + 0.5), height)
end

function Bar:SetFillColor(hex)
	self.fill:SetBackColor(Theme.Color(hex))
end
