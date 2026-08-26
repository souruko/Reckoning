--=================================================================================================
-- Options -- the Plugin Manager stub, returned via plugin.GetOptionsPanel.
--
-- Every real setting moved to UI/OptionsWindow.lua (/redbook options), which is a proper RedBook
-- window with the plugin's own chrome and grouping. The Plugin Manager still calls
-- GetOptionsPanel and still wants a Turbine.UI.ListBox back, so this stays -- reduced to a
-- one-line pointer plus a button that opens the real thing.
--
-- The old panel is gone rather than kept in parallel: it had two different commit models in one
-- place (checkboxes saved on change, the numeric box only on Accept), which is exactly the
-- problem the options window exists to remove. Two surfaces editing the same keys would put it
-- straight back.
--=================================================================================================

Options = class(Turbine.UI.ListBox)

function Options:Constructor()
	Turbine.UI.ListBox.Constructor(self)
	self:SetSize(420, 96)

	local body = Turbine.UI.Control()
	body:SetSize(420, 88)

	local title = Turbine.UI.Label()
	title:SetParent(body)
	title:SetFont(Font.TrajanPro16)
	title:SetText("RedBook v" .. RedBook.Version)
	title:SetForeColor(Theme.Color(Theme.Hex.Text))
	title:SetPosition(10, 6)
	title:SetSize(400, 26)
	title:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)

	local hint = Turbine.UI.Label()
	hint:SetParent(body)
	hint:SetFont(Font.Verdana12)
	hint:SetText("Settings live in RedBook's own window. Type /redbook options.")
	hint:SetForeColor(Theme.Color(Theme.Hex.MutedText))
	hint:SetPosition(10, 34)
	hint:SetSize(400, 20)
	hint:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)

	-- Turbine.UI.Lotro.Button, not a hand-built Control: this panel is drawn on the Plugin
	-- Manager's own ground, where RedBook's palette has nothing to sit against, so the stock
	-- widget is the one that looks right here (and it is the one thing this panel still does).
	local open = Turbine.UI.Lotro.Button()
	open:SetParent(body)
	open:SetPosition(10, 58)
	open:SetSize(120, 22)
	open:SetFont(Font.Verdana12)
	open:SetText("Open options")
	-- optionsWindow is a root-level global (Main.lua) constructed after this panel -- read at
	-- click time, never captured here, so construction order between the two does not matter.
	open.Click = function()
		if optionsWindow ~= nil then
			optionsWindow:Toggle()
		end
	end

	self:AddItem(body)
end

-- Kept as a no-op so anything still calling it (Main.lua's older ResetAll) stays valid. There is
-- nothing on this panel to re-read: it shows no setting.
function Options:Refresh()
end
