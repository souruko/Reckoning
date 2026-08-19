--=================================================================================================
-- Row -- a row of Labels at fixed x offsets, for tables (docs/DESIGN.md "Skill table") and any
-- other fixed-column list. Number columns should be given Font.LucidaConsole12 -- the only
-- fixed-width face the client ships, so digits align without measuring text width per row.
--
-- Rows are meant to be pooled and reused across refreshes (docs/IMPLEMENTATION_PLAN.md
-- "Performance notes": never rebuild a ScrollView's children per refresh) -- construct once per
-- visible slot, then call SetValues()/SetVisible() on the pooled instance instead of creating a
-- new Row per redraw.
--=================================================================================================

Row = class(Turbine.UI.Control)

-- columns: { {x, width, font, align, colorHex}, ... }, left to right. Every field but x/width
-- is optional and falls back to a plain body-text label (Verdana12, MiddleLeft, Theme.Text).
function Row:Constructor(width, height, columns)
	Turbine.UI.Control.Constructor(self)

	self:SetSize(width, height)
	self:SetMouseVisible(true)

	self.columns = columns
	self.labels = {}

	for i = 1, table.getn(columns) do
		local col = columns[i]

		local label = Turbine.UI.Label()
		label:SetParent(self)
		label:SetFont(col.font or Font.Verdana12)
		label:SetPosition(col.x, 0)
		label:SetSize(col.width, height)
		label:SetTextAlignment(col.align or Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetForeColor(Theme.Color(col.colorHex or Theme.Hex.Text))
		label:SetMouseVisible(false)

		self.labels[i] = label
	end
end

-- values: one string per column, same order as the `columns` spec passed to the constructor.
-- Missing trailing values clear that column's text rather than leaving stale text on screen.
function Row:SetValues(values)
	for i = 1, table.getn(self.labels) do
		self.labels[i]:SetText(values[i] or "")
	end
end

function Row:SetColumnColor(index, hex)
	local label = self.labels[index]
	if label ~= nil then
		label:SetForeColor(Theme.Color(hex))
	end
end
