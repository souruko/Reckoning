--=================================================================================================
-- Options -- the in-game settings panel, returned via plugin.GetOptionsPanel. Same shape as
-- VitalSelf/UI/Settings.lua: a Turbine.UI.ListBox, table-driven numeric rows, Accept validates
-- before writing to _G.settings.
--
-- Scoped to what docs/DESIGN.md actually calls settable (deathAutoHide, window enable flags).
-- No colour rows: the palette is fixed design tokens (Constants.lua Theme.Hex), not a per-user
-- setting -- Settings.lua's COLOR_KEYS is deliberately empty for the same reason.
--=================================================================================================

Options = class(Turbine.UI.ListBox)

local ROW_HEIGHT = 26
local ROW_START = 10

local ROWS = {
	{ key = "deathAutoHide", label = "Death window auto-hide (5-30s)", low = 5, high = 30 },
}

function Options:Constructor()
	Turbine.UI.ListBox.Constructor(self)
	self:SetSize(420, 220)

	self:Header()
	self:Values()
end

function Options:Header()
	local title = Turbine.UI.Label()
	title:SetFont(Font.TrajanPro16)
	title:SetText("Reckoning v" .. Reckoning.Version)
	title:SetForeColor(Theme.Color(Theme.Hex.Text))
	title:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	title:SetSize(400, 30)
	self:AddItem(title)
end

function Options:AddRow(parent, y, labelText, text)
	local label = Turbine.UI.Label()
	label:SetParent(parent)
	label:SetSize(260, ROW_HEIGHT)
	label:SetPosition(10, y)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	label:SetFont(Font.Verdana12)
	label:SetText(labelText)
	label:SetForeColor(Theme.Color(Theme.Hex.Text))

	local box = Turbine.UI.Lotro.TextBox()
	box:SetParent(parent)
	box:SetSize(60, ROW_HEIGHT)
	box:SetPosition(280, y)
	box:SetFont(Font.Verdana12)
	box:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	box:SetText(text)

	return box
end

function Options:AddCheckbox(parent, y, text, checked, onChange)
	local box = Turbine.UI.Lotro.CheckBox()
	box:SetParent(parent)
	box:SetPosition(10, y)
	box:SetWidth(380)
	box:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	box:SetFont(Font.Verdana12)
	box:SetText(" " .. text)
	box:SetChecked(checked)
	box.CheckedChanged = function() onChange(box:IsChecked()) end
	return box
end

function Options:Values()
	local body = Turbine.UI.Control()
	body:SetSize(420, ROW_START + (table.getn(ROWS) + 5) * ROW_HEIGHT)

	self.boxes = {}
	local y = ROW_START

	for i = 1, table.getn(ROWS) do
		local row = ROWS[i]
		self.boxes[row.key] = self:AddRow(body, y, row.label, tostring(_G.settings[row.key]))
		y = y + ROW_HEIGHT
	end

	y = y + ROW_HEIGHT

	self.liveMeterCheck = self:AddCheckbox(body, y, "Show live meter", _G.settings.liveMeterEnabled, function(checked)
		_G.settings.liveMeterEnabled = checked
		if not checked then
			liveMeter:SetVisible(false)
		end
		Settings.Save()
	end)
	y = y + ROW_HEIGHT

	self.deathCauseCheck = self:AddCheckbox(body, y, "Show death cause window", _G.settings.deathCauseEnabled, function(checked)
		_G.settings.deathCauseEnabled = checked
		if not checked then
			deathCause:SetVisible(false)
		end
		Settings.Save()
	end)
	y = y + ROW_HEIGHT

	local accept = Turbine.UI.Lotro.Button()
	accept:SetParent(body)
	accept:SetSize(100, ROW_HEIGHT)
	accept:SetPosition(280, y)
	accept:SetFont(Font.Verdana12)
	accept:SetText("Accept")
	accept.Click = function() self:Accept() end

	self:AddItem(body)
end

-- Reads every box, validates and clamps, and only then writes to _G.settings -- a box that
-- doesn't parse is left as whatever was already stored (VitalSelf/UI/Settings.lua's pattern).
function Options:Accept()
	for i = 1, table.getn(ROWS) do
		local row = ROWS[i]
		local value = tonumber(self.boxes[row.key]:GetText())
		if value ~= nil then
			value = math.floor(value)
			if value < row.low then
				value = row.low
			elseif value > row.high then
				value = row.high
			end
			_G.settings[row.key] = value
		end
	end

	self:Refresh()
	Settings.Save()
end

-- Write the (possibly clamped) stored values back into the boxes so the panel always shows
-- what is actually in effect.
function Options:Refresh()
	for i = 1, table.getn(ROWS) do
		local row = ROWS[i]
		self.boxes[row.key]:SetText(tostring(_G.settings[row.key]))
	end
	self.liveMeterCheck:SetChecked(_G.settings.liveMeterEnabled)
	self.deathCauseCheck:SetChecked(_G.settings.deathCauseEnabled)
end
