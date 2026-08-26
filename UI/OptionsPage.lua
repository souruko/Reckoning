--=================================================================================================
-- OptionsPage -- one page of the options window: a y-cursor Control that lays out section
-- headers, checkbox / slider / segment rows, notes and buttons at the geometry in the design
-- handoff (design_handoff_options_panel/README.md, "Pages (shared row vocabulary)").
--
-- Pages are built once and cached by the window; switching pages swaps which one the pane's
-- ListBox holds. Nothing here is ever detached -- see UI/Row.lua's Reconfigure for why this
-- codebase never calls SetParent(nil).
--
-- THERE IS NO ACCEPT. Every Add* writes _G.settings the moment its control changes. Checkboxes,
-- segments and buttons also Settings.Save() immediately; sliders write live (so a preview can
-- follow the drag) but save only on release, because Settings.Save is a Turbine.PluginData write
-- and one drag crosses dozens of stops.
--
-- Anything a single page needs that isn't in this vocabulary (the palette preview, the buff
-- picker, the saved-geometry list, the ignore chips) is built by that page's own builder using
-- page.y / page:Grow(n) / page:Rule(), not by adding a one-off method here.
--=================================================================================================

OptionsPage = class(Turbine.UI.Control)

-- 412px pane minus a 10px gutter for the pane's scrollbar.
OptionsPage.Width = 402

local PAGE_W = OptionsPage.Width
local INSET = 12
local RIGHT = PAGE_W - INSET
local ROW_CHECK = 26
local ROW_SLIDER = 28
local ROW_TALL = 38 -- a slider/segment row carrying a sub-label
local ROW_SECTION = 24
local SECTION_PAD = 10
local SLIDER_WIDTH = 130
local READOUT_WIDTH = 40
local READOUT_GAP = 8

function OptionsPage:Constructor()
	Turbine.UI.Control.Constructor(self)
	self:SetSize(PAGE_W, 10)
	self:SetMouseVisible(false)

	self.y = 0
	self.first = true
	self.refreshers = {} -- functions that re-read _G.settings into their own control
	-- { label, control } per label-plus-control row. Bookkeeping only: nothing in the UI reads
	-- it, but it is what lets tools/offline/options_test.lua assert that a row's control never
	-- ends up under its own label's box, which is not something eyeballing the arithmetic catches.
	self.rows = {}
end

function OptionsPage:Grow(by)
	self.y = self.y + by
	self:SetSize(PAGE_W, self.y)
end

-- Adds a refresher, i.e. one control's "re-read the setting you edit". Run by Refresh() after
-- Defaults / /redbook reset, which change every value out from under the page.
function OptionsPage:OnRefresh(fn)
	self.refreshers[table.getn(self.refreshers) + 1] = fn
end

-- The 1px rule that closes a row. Drawn at the cursor's CURRENT position, so callers Grow() the
-- row's height first and then Rule() -- which puts the line on the row's own bottom edge.
function OptionsPage:Rule()
	local rule = Turbine.UI.Control()
	rule:SetParent(self)
	rule:SetPosition(INSET, self.y - 1)
	rule:SetSize(PAGE_W - INSET * 2, 1)
	rule:SetBackColor(Theme.Color(Theme.Hex.RowBorder))
	rule:SetMouseVisible(false)
	return rule
end

function OptionsPage:Section(text)
	if not self.first then
		self:Grow(SECTION_PAD)
	end
	self.first = false

	local label = Turbine.UI.Label()
	label:SetParent(self)
	label:SetFont(Font.Verdana10)
	label:SetForeColor(Theme.Color(Theme.Hex.MutedText))
	label:SetText(string.upper(text))
	label:SetPosition(INSET, self.y)
	label:SetSize(PAGE_W - INSET * 2, ROW_SECTION)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.BottomLeft)
	label:SetMouseVisible(false)

	self:Grow(ROW_SECTION)
	return label
end

function OptionsPage:Note(text)
	local label = Turbine.UI.Label()
	label:SetParent(self)
	label:SetFont(Font.Verdana10)
	label:SetForeColor(Theme.Color(Theme.Hex.DimText))
	label:SetText(text)
	label:SetPosition(INSET, self.y + 4)
	label:SetSize(PAGE_W - INSET * 2, 32)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.TopLeft)
	label:SetMultiline(true)
	label:SetMouseVisible(false)

	self:Grow(40)
	return label
end

---------------------------------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------------------------------

-- opts: { hint = right-aligned Verdana10 note, apply = function(value), swatchHex = a 22x11
-- colour chip in place of the hint (the death page's row marks) }.
function OptionsPage:Check(key, text, opts)
	opts = opts or {}

	local box = Turbine.UI.Lotro.CheckBox()
	box:SetParent(self)
	box:SetPosition(INSET, self.y + 4)
	box:SetSize(300, 18)
	box:SetFont(Font.Verdana12)
	box:SetText(" " .. text) -- leading space matches the old panel's checkbox spacing
	box:SetForeColor(Theme.Color(Theme.Hex.Text))
	box:SetChecked(_G.settings[key] == true)

	box.CheckedChanged = function()
		_G.settings[key] = box:IsChecked()
		Settings.Save()
		if opts.apply ~= nil then
			opts.apply(_G.settings[key])
		end
	end

	if opts.swatchHex ~= nil then
		local swatch = Turbine.UI.Control()
		swatch:SetParent(self)
		swatch:SetPosition(RIGHT - 22, self.y + math.floor((ROW_CHECK - 11) / 2))
		swatch:SetSize(22, 11)
		swatch:SetBackColor(Theme.Color(opts.swatchHex))
		swatch:SetMouseVisible(false)
	elseif opts.hint ~= nil then
		local note = Turbine.UI.Label()
		note:SetParent(self)
		note:SetFont(Font.Verdana10)
		note:SetForeColor(Theme.Color(Theme.Hex.DimText))
		note:SetText(opts.hint)
		note:SetPosition(INSET + 240, self.y)
		note:SetSize(RIGHT - INSET - 240, ROW_CHECK)
		note:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		note:SetMouseVisible(false)
	end

	self:Grow(ROW_CHECK)
	self:Rule()
	self:OnRefresh(function() box:SetChecked(_G.settings[key] == true) end)

	self.lastCheck = box
	return box
end

-- Shared geometry for the two "label on the left, control on the right" rows.
--
-- `width` is the space the caller has left over after its own control, and an indent comes OUT of
-- it rather than pushing the label into the control: an indented row is a subordinate one (the
-- sparkline window under the sparkline toggle), and its label has less room, not the same room
-- shifted right. Nothing here is mouse-visible, so an overlap would only ever be a visual one --
-- but a Label whose box runs under a Segment strip is exactly the kind of thing that looks fine at
-- one window size and wrong at another.
function OptionsPage:RowLabel(text, width, sub, indent)
	local height = (sub ~= nil) and ROW_TALL or ROW_SLIDER
	local x = INSET + (indent or 0)
	width = math.max(60, width - (indent or 0))

	local label = Turbine.UI.Label()
	label:SetParent(self)
	label:SetFont(Font.Verdana12)
	label:SetForeColor(Theme.Color(Theme.Hex.Text))
	label:SetText(text)
	label:SetPosition(x, self.y)
	label:SetSize(width, (sub ~= nil) and 20 or height)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	label:SetMouseVisible(false)

	if sub ~= nil then
		-- The sub-line is allowed a little more width than the main label, since it is Verdana10
		-- against Verdana12 and always a short phrase. Its BOX can end up under the row's control
		-- on the widest strips; that is fine and only that, because both are mouse-invisible and
		-- the rendered text is well short of the box -- but keep new sub-strings short, because
		-- nothing here clips them.
		local subLabel = Turbine.UI.Label()
		subLabel:SetParent(self)
		subLabel:SetFont(Font.Verdana10)
		subLabel:SetForeColor(Theme.Color(Theme.Hex.DimText))
		subLabel:SetText(sub)
		subLabel:SetPosition(x, self.y + 18)
		subLabel:SetSize(width + 30, 14)
		subLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		subLabel:SetMouseVisible(false)
	end

	return height, label
end

-- suffix is appended to the readout ("s", "%", or "" for a bare count).
-- opts: { sub, apply = function(value), indent = px, fillHex = the track's fill colour }.
function OptionsPage:Slider(key, text, low, high, suffix, opts)
	opts = opts or {}
	local height, label = self:RowLabel(text, 200, opts.sub, opts.indent)

	local readout = Turbine.UI.Label()
	readout:SetParent(self)
	readout:SetFont(Font.LucidaConsole12)
	readout:SetForeColor(Theme.Color(Theme.Hex.Accent300))
	readout:SetPosition(RIGHT - READOUT_WIDTH, self.y)
	readout:SetSize(READOUT_WIDTH, height)
	readout:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
	readout:SetMouseVisible(false)

	local slider = Slider(SLIDER_WIDTH, low, high, _G.settings[key], opts.fillHex)
	slider:SetParent(self)
	slider:SetPosition(RIGHT - READOUT_WIDTH - READOUT_GAP - SLIDER_WIDTH,
		self.y + math.floor((height - 16) / 2))
	self.rows[table.getn(self.rows) + 1] = { label = label, control = slider }

	local function Paint(value)
		readout:SetText(tostring(value) .. (suffix or ""))
	end
	Paint(_G.settings[key])

	-- Live on drag, PERSISTED ON RELEASE ONLY -- see this file's header.
	slider.OnChange = function(value)
		_G.settings[key] = value
		Paint(value)
		if opts.apply ~= nil then
			opts.apply(value)
		end
	end
	slider.OnCommit = function() Settings.Save() end

	self:Grow(height)
	self:Rule()
	self:OnRefresh(function()
		slider:SetValue(_G.settings[key], false)
		Paint(_G.settings[key])
	end)

	return slider
end

-- options: { { label = , value = }, ... }. opts: { sub, apply = function(value) }.
--
-- The Segment is built BEFORE the label, deliberately: its width comes from its own cells' text
-- (see UI/Controls.lua) and is not known until it exists, and the label has to be sized against
-- what is actually left. A four-cell strip like the live meter's tab picker is wide enough to run
-- under a fixed 180px label.
function OptionsPage:Segment(key, text, options, opts)
	opts = opts or {}

	local seg = Segment(options, _G.settings[key])
	seg:SetParent(self)

	local labelWidth = math.min(180, RIGHT - seg:GetWidth() - INSET - 8)
	local height, label = self:RowLabel(text, labelWidth, opts.sub, opts.indent)

	seg:SetPosition(RIGHT - seg:GetWidth(), self.y + math.floor((height - 20) / 2))
	self.rows[table.getn(self.rows) + 1] = { label = label, control = seg }

	seg.OnChange = function(value)
		_G.settings[key] = value
		Settings.Save()
		if opts.apply ~= nil then
			opts.apply(value)
		end
	end

	self:Grow(height)
	self:Rule()
	self:OnRefresh(function() seg:SetValue(_G.settings[key], false) end)

	return seg
end

---------------------------------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------------------------------

-- A small text button. `dangerous` gives it the DeathFill / DamageFatal treatment the mockup's
-- Sessions page uses for Clear data. Positioned by the caller (x, y are absolute within the page)
-- because buttons sit inside other rows as often as they sit on their own.
function OptionsPage:Button(x, y, width, height, text, dangerous, onClick)
	local button = Turbine.UI.Control()
	button:SetParent(self)
	button:SetPosition(x, y)
	button:SetSize(width, height)
	button:SetBackColor(Theme.Color(dangerous and Theme.Hex.DeathBorder or Theme.Hex.Border))
	button:SetMouseVisible(true)

	local restHex = dangerous and Theme.Hex.DeathFill or Theme.Hex.HeaderFill
	local hoverHex = dangerous and Theme.Hex.DeathKillFill or Theme.Hex.Hover

	local inner = Turbine.UI.Control()
	inner:SetParent(button)
	inner:SetPosition(1, 1)
	inner:SetSize(width - 2, height - 2)
	inner:SetBackColor(Theme.Color(restHex))
	inner:SetMouseVisible(false)

	local label = Turbine.UI.Label()
	label:SetParent(inner)
	label:SetFont(Font.Verdana10)
	label:SetForeColor(Theme.Color(dangerous and Theme.Hex.DamageFatal or Theme.Hex.MutedText))
	label:SetText(text)
	label:SetPosition(0, 0)
	label:SetSize(width - 2, height - 2)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	label:SetMouseVisible(false)

	button.MouseEnter = function() inner:SetBackColor(Theme.Color(hoverHex)) end
	button.MouseLeave = function() inner:SetBackColor(Theme.Color(restHex)) end
	button.MouseClick = function() onClick() end

	return button, label
end

-- A right-aligned button occupying a whole row of its own.
function OptionsPage:ButtonRow(text, width, dangerous, onClick)
	local button, label = self:Button(RIGHT - width, self.y, width, 26, text, dangerous, onClick)
	self:Grow(26)
	return button, label
end

---------------------------------------------------------------------------------------------------

-- Re-reads every control on this page from _G.settings. Called after Defaults and /redbook reset.
function OptionsPage:Refresh()
	for i = 1, table.getn(self.refreshers) do
		self.refreshers[i]()
	end
end
