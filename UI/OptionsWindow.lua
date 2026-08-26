--=================================================================================================
-- OptionsWindow -- window 4, 560x452. Opened by /redbook options (and by the Plugin Manager stub's
-- button). Frame chrome, a 146px category rail, seven pages in one reused ListBox, and a footer
-- with Defaults and Close. See design_handoff_options_panel/README.md (direction 1b) and
-- SETTINGS_KEYS.md, which is the authority for every key, range and label string.
--
-- NO ACCEPT. Every control writes _G.settings and persists on change -- that is the single most
-- important behavioural difference from the old Plugin Manager panel, which had two different
-- commit models in one place. UI/OptionsPage.lua's header covers the one exception (sliders save
-- on release, not per drag stop).
--
-- ONE ListBox for all seven pages: the pane must never show two scrollbars, and this codebase
-- never detaches a Control, so the ListBox's ITEM is swapped (ClearItems + AddItem) rather than
-- seven pages being shown and hidden. The pages themselves are built once and cached in
-- self.pages, so switching back to one is free and keeps whatever the user had scrolled to.
--=================================================================================================

OptionsWindow = class(Frame)

local W, H = 560, 452
local HEADER_H = 26
local CLIENT_H = H - HEADER_H          -- 426
local FOOTER_H = 34
local BODY_H = CLIENT_H - FOOTER_H - 1 -- 391
local RAIL_W = 145
local PANE_X = RAIL_W + 2              -- 147
local PANE_W = W - PANE_X - 1          -- 412
local RAIL_ROW_H = 28
local RAIL_NOTE_H = 40

local INSET = 12
local PAGE_W = OptionsPage.Width
local RIGHT = PAGE_W - INSET

-- Charted-buff picker. MAX_CHARTED mirrors UI/Analysis.lua's own cap, which exists because
-- Theme.BuffLane has exactly three colours.
local MAX_CHARTED = 3
local BUFF_SLOTS = 8   -- pooled picker rows; the list is worst-uptime-first (Buffs.Stats' order)
local BUFF_ROW_H = 26
local CHIP_SLOTS = 12  -- pooled ignore-list chips
local CHIP_H = 22
local CHIP_GAP = 5
local CHIP_ROWS = 2

local CLEAR_ARM_SECONDS = 3

local PAGES = {
	{ key = "windows",    label = "Windows" },
	{ key = "appearance", label = "Appearance" },
	{ key = "palette",    label = "Palette" },
	{ key = "live",       label = "Live meter" },
	{ key = "death",      label = "Death window" },
	{ key = "buffs",      label = "Self buffs" },
	{ key = "sessions",   label = "Sessions" },
}

-- [pageKey] = function(window) -> OptionsPage. Filled at the bottom of this file; SelectPage
-- calls one lazily the first time its page is opened.
local BUILDERS = {}

---------------------------------------------------------------------------------------------------
-- One place that pushes the current settings into every live window.
--
-- A plain function, not a method: most handlers want "tell everything" and passing the window
-- around for that is noise. Every read is guarded -- a handler can fire before a window exists
-- (the options window is constructed alongside the other three) and a window built by an older
-- version may not have the method at all.
---------------------------------------------------------------------------------------------------
function OptionsWindow.ApplyAll()
	if liveMeter ~= nil and liveMeter.ApplySettings ~= nil then liveMeter:ApplySettings() end
	if deathCause ~= nil and deathCause.ApplySettings ~= nil then deathCause:ApplySettings() end
	if analysis ~= nil and analysis.ApplySettings ~= nil then analysis:ApplySettings() end
	if optionsWindow ~= nil and optionsWindow.ApplySettings ~= nil then optionsWindow:ApplySettings() end
end

local function ApplyLive()
	if liveMeter ~= nil and liveMeter.ApplySettings ~= nil then liveMeter:ApplySettings() end
end

local function ApplyDeath()
	if deathCause ~= nil and deathCause.ApplySettings ~= nil then deathCause:ApplySettings() end
end

local function ApplyAnalysis()
	if analysis ~= nil and analysis.ApplySettings ~= nil then analysis:ApplySettings() end
end

---------------------------------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------------------------------

function OptionsWindow:Constructor()
	Frame.Constructor(self, {
		-- ASCII hyphen, not an em dash: every questionable glyph this codebase has shipped has
		-- eventually come back as a "?" (the session rail's pin diamonds), and the title bar is
		-- not worth another round of that. The dim version tag is the same inline <rgb=> trick
		-- the analysis window's title uses -- Frame turns markup on for every title it renders.
		key = "options", closable = true,
		title = "RedBook - Options  <rgb=" .. Theme.Hex.DimText .. ">v" .. RedBook.Version .. "</rgb>",
		width = W, height = H, headerHeight = HEADER_H,
	})

	self.pages = {}
	self.page = nil

	self:BuildRail()
	self:BuildPane()
	self:BuildFooter()

	self:SelectPage("windows")

	-- Only needed for the Sessions page's armed Clear data button, which disarms itself after
	-- CLEAR_ARM_SECONDS. Update() returns immediately when the window is hidden or nothing is
	-- armed, so this costs nothing the rest of the time.
	self:SetWantsUpdates(true)
	self:SetVisible(false)
end

function OptionsWindow:BuildRail()
	local rail = Turbine.UI.Control()
	rail:SetParent(self.client)
	rail:SetPosition(1, 0)
	rail:SetSize(RAIL_W, BODY_H)
	rail:SetBackColor(Theme.Color(Theme.Hex.RailFill))
	rail:SetMouseVisible(false)
	self.rail = rail

	local divider = Turbine.UI.Control()
	divider:SetParent(self.client)
	divider:SetPosition(RAIL_W + 1, 0)
	divider:SetSize(1, BODY_H)
	divider:SetBackColor(Theme.Color(Theme.Hex.Border))
	divider:SetMouseVisible(false)

	self.railRows = {}
	local window = self

	for i = 1, table.getn(PAGES) do
		local entry = PAGES[i]

		-- Mouse-visible rows inside a mouse-invisible rail: the same shape the analysis window's
		-- session rail and picker chips already use in-game, so nothing new is assumed about how
		-- clicks reach a child of a click-through parent.
		local row = Turbine.UI.Control()
		row:SetParent(rail)
		row:SetPosition(0, 6 + (i - 1) * RAIL_ROW_H)
		row:SetSize(RAIL_W, RAIL_ROW_H)
		row:SetMouseVisible(true)

		local mark = Turbine.UI.Control()
		mark:SetParent(row)
		mark:SetPosition(0, 0)
		mark:SetSize(2, RAIL_ROW_H)
		mark:SetMouseVisible(false)

		local label = Turbine.UI.Label()
		label:SetParent(row)
		label:SetFont(Font.Verdana12)
		label:SetText(entry.label)
		label:SetPosition(12, 0)
		label:SetSize(120, RAIL_ROW_H)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)

		row.MouseClick = function() window:SelectPage(entry.key) end
		row.MouseEnter = function()
			if window.page ~= entry.key then
				row:SetBackColor(Theme.Color(Theme.Hex.Hover))
			end
		end
		row.MouseLeave = function()
			if window.page ~= entry.key then
				row:SetBackColor(nil)
			end
		end

		self.railRows[entry.key] = { row = row, mark = mark, label = label }
	end

	local noteRule = Turbine.UI.Control()
	noteRule:SetParent(rail)
	noteRule:SetPosition(0, BODY_H - RAIL_NOTE_H)
	noteRule:SetSize(RAIL_W, 1)
	noteRule:SetBackColor(Theme.Color(Theme.Hex.Border))
	noteRule:SetMouseVisible(false)

	local note = Turbine.UI.Label()
	note:SetParent(rail)
	note:SetFont(Font.Verdana10)
	note:SetForeColor(Theme.Color(Theme.Hex.Disabled))
	note:SetText("Saved per character\non every change")
	note:SetMultiline(true)
	note:SetPosition(12, BODY_H - RAIL_NOTE_H + 8)
	note:SetSize(RAIL_W - 24, 28)
	note:SetMouseVisible(false)
end

function OptionsWindow:BuildPane()
	-- Turbine.UI.ListBox as the scroll host plus a separate Lotro.ScrollBar wired in with
	-- SetVerticalScrollBar -- the confirmed-working pattern from UI/Analysis.lua's skill table
	-- (Turbine.UI.ScrollView does not exist; see CLAUDE.md).
	self.pane = Turbine.UI.ListBox()
	self.pane:SetParent(self.client)
	self.pane:SetPosition(PANE_X, 0)
	self.pane:SetSize(PANE_W - 10, BODY_H)

	self.paneScrollBar = Turbine.UI.Lotro.ScrollBar()
	self.paneScrollBar:SetParent(self.client)
	self.paneScrollBar:SetOrientation(Turbine.UI.Orientation.Vertical)
	self.paneScrollBar:SetPosition(PANE_X + PANE_W - 10, 0)
	self.paneScrollBar:SetSize(10, BODY_H)
	self.pane:SetVerticalScrollBar(self.paneScrollBar)

	local rule = Turbine.UI.Control()
	rule:SetParent(self.client)
	rule:SetPosition(0, BODY_H)
	rule:SetSize(W, 1)
	rule:SetBackColor(Theme.Color(Theme.Hex.Border))
	rule:SetMouseVisible(false)
end

function OptionsWindow:BuildFooter()
	local footer = Turbine.UI.Control()
	footer:SetParent(self.client)
	footer:SetPosition(0, BODY_H + 1)
	footer:SetSize(W, FOOTER_H)
	footer:SetMouseVisible(false)

	local hint = Turbine.UI.Label()
	hint:SetParent(footer)
	hint:SetFont(Font.LucidaConsole12)
	hint:SetForeColor(Theme.Color(Theme.Hex.Disabled))
	hint:SetText("/redbook options  ·  /redbook reset")
	hint:SetPosition(10, 0)
	hint:SetSize(280, FOOTER_H)
	hint:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	hint:SetMouseVisible(false)

	local window = self
	-- Close is the rightmost, primary button (the mockup's order); Defaults sits to its left.
	self:FooterButton(footer, W - 10 - 70, 70, "Close", true, function() window:Close() end)
	self:FooterButton(footer, W - 10 - 70 - 8 - 80, 80, "Defaults", false,
		function() window:ApplyDefaults() end)
end

function OptionsWindow:FooterButton(parent, x, width, text, primary, onClick)
	local button = Turbine.UI.Control()
	button:SetParent(parent)
	button:SetPosition(x, 4)
	button:SetSize(width, 26)
	button:SetBackColor(Theme.Color(primary and Theme.Hex.Accent700 or Theme.Hex.Border))
	button:SetMouseVisible(true)

	local restHex = primary and Theme.Hex.ActiveTab or Theme.Hex.HeaderFill

	local inner = Turbine.UI.Control()
	inner:SetParent(button)
	inner:SetPosition(1, 1)
	inner:SetSize(width - 2, 24)
	inner:SetBackColor(Theme.Color(restHex))
	inner:SetMouseVisible(false)

	local label = Turbine.UI.Label()
	label:SetParent(inner)
	label:SetFont(Font.TrajanPro13)
	label:SetForeColor(Theme.Color(primary and Theme.Hex.Accent200 or Theme.Hex.MutedText))
	label:SetText(text)
	label:SetPosition(0, 0)
	label:SetSize(width - 2, 24)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	label:SetMouseVisible(false)

	button.MouseEnter = function() inner:SetBackColor(Theme.Color(Theme.Hex.Hover)) end
	button.MouseLeave = function() inner:SetBackColor(Theme.Color(restHex)) end
	button.MouseClick = function() onClick() end

	return button
end

---------------------------------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------------------------------

-- The selected page is remembered in memory only, never persisted -- the window always opens on
-- Windows (design handoff, "Interactions & behaviour").
function OptionsWindow:SelectPage(key)
	self.page = key

	for i = 1, table.getn(PAGES) do
		local entry = PAGES[i]
		local row = self.railRows[entry.key]
		local selected = (entry.key == key)
		row.row:SetBackColor(selected and Theme.Color(Theme.Hex.ActiveTab) or nil)
		row.mark:SetBackColor(selected and Theme.Color(Theme.Hex.Accent) or nil)
		row.label:SetForeColor(Theme.Color(selected and Theme.Hex.Accent200 or Theme.Hex.MutedText))
	end

	if self.pages[key] == nil then
		self.pages[key] = BUILDERS[key](self)
	end

	local page = self.pages[key]
	-- Pages whose content comes from live data rather than from _G.settings (the saved-geometry
	-- readouts, the buff picker) re-read it every time they are opened -- a cached page must not
	-- show the session list or the window positions as they were when it was first built.
	if page.Repaint ~= nil then
		page.Repaint()
	end

	self.pane:ClearItems()
	self.pane:AddItem(page)
end

-- Defaults: reset every setting, then re-read every page that has been built and push the new
-- values into all three windows. No confirmation -- the mockup shows none, and the destructive
-- one (Clear data, Sessions page) is two-step instead.
function OptionsWindow:ApplyDefaults()
	Settings.ResetToDefaults()
	self:RefreshPages()
	OptionsWindow.ApplyAll()
end

function OptionsWindow:RefreshPages()
	for _, page in pairs(self.pages) do
		page:Refresh()
		if page.Repaint ~= nil then
			page.Repaint()
		end
	end
end

-- The options window's own response to a settings change: only the border, which the Appearance
-- page's "Window borders" toggle governs for every window alike.
function OptionsWindow:ApplySettings()
	self:ApplyBorders()
end

function OptionsWindow:Toggle()
	if self:IsVisible() then
		self:SetVisible(false)
	else
		self:SetVisible(true)
		self:Activate()
	end
end

-- Disarms the Sessions page's Clear data button once its window has passed. Cheap enough to run
-- unconditionally, but gated on visibility anyway: an armed button cannot be clicked while the
-- window is hidden, and this is the only reason the window wants updates at all.
function OptionsWindow:Update()
	if not self:IsVisible() or self.disarmAt == nil then
		return
	end
	if Turbine.Engine.GetGameTime() >= self.disarmAt then
		self.disarmAt = nil
		if self.disarm ~= nil then
			self.disarm()
			self.disarm = nil
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Page 1 -- Windows
---------------------------------------------------------------------------------------------------

BUILDERS["windows"] = function(window)
	local page = OptionsPage()

	page:Section("Windows")
	page:Check("liveMeterEnabled", "Live meter", { hint = "shows in combat", apply = ApplyLive })
	page:Check("deathCauseEnabled", "Death cause window", { hint = "on defeat", apply = ApplyDeath })
	page:Check("analysisAutoOpen", "Open analysis after every fight", { hint = "/redbook" })
	page:Check("lockWindows", "Lock positions",
		{ hint = "headers stop dragging", apply = OptionsWindow.ApplyAll })

	page:Section("Saved geometry")

	-- Each row reads _G.settings.windows[key] for its own readout, so it is always the real saved
	-- entry rather than a copy that could drift. Reset goes through Main.lua's own MoveWindow so
	-- there is exactly one definition of "put this window back at 200, 200".
	local readouts = {}

	local function GeometryRow(key, label, detail)
		local rowY = page.y

		local name = Turbine.UI.Label()
		name:SetParent(page)
		name:SetFont(Font.Verdana12)
		name:SetForeColor(Theme.Color(Theme.Hex.Text))
		name:SetText(label)
		name:SetPosition(INSET, rowY)
		name:SetSize(150, 26)
		name:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		name:SetMouseVisible(false)

		local extra = nil
		if detail then
			extra = Turbine.UI.Label()
			extra:SetParent(page)
			extra:SetFont(Font.Verdana10)
			extra:SetForeColor(Theme.Color(Theme.Hex.DimText))
			extra:SetPosition(INSET + 70, rowY)
			extra:SetSize(130, 26)
			extra:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
			extra:SetMouseVisible(false)
		end

		local readout = Turbine.UI.Label()
		readout:SetParent(page)
		readout:SetFont(Font.LucidaConsole12)
		readout:SetForeColor(Theme.Color(Theme.Hex.Accent300))
		readout:SetPosition(RIGHT - 74 - 100, rowY)
		readout:SetSize(100, 26)
		readout:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		readout:SetMouseVisible(false)

		page:Button(RIGHT - 60, rowY + 3, 60, 20, "Reset", false, function()
			Settings.ResetWindow(key)
			page.Repaint()
		end)

		readouts[table.getn(readouts) + 1] = { key = key, readout = readout, extra = extra }

		page:Grow(26)
		page:Rule()
	end

	GeometryRow("liveMeter", "Live meter", false)
	GeometryRow("deathCause", "Death cause", false)
	GeometryRow("analysis", "Analysis", true)

	page:Note("Reset all positions returns every window to 200, 200 and clears saved sizes.")

	page.Repaint = function()
		for i = 1, table.getn(readouts) do
			local entry = readouts[i]
			local saved = _G.settings.windows and _G.settings.windows[entry.key] or nil
			if saved == nil or saved.left == nil then
				entry.readout:SetText("--")
			else
				entry.readout:SetText(math.floor(saved.left) .. ", " .. math.floor(saved.top))
			end
			if entry.extra ~= nil then
				if saved ~= nil and saved.width ~= nil then
					entry.extra:SetText(math.floor(saved.width) .. "x" .. math.floor(saved.height)
						.. (saved.split and (", split " .. math.floor(saved.split)) or ""))
				else
					entry.extra:SetText("")
				end
			end
		end
	end

	return page
end

---------------------------------------------------------------------------------------------------
-- Page 2 -- Appearance
---------------------------------------------------------------------------------------------------

BUILDERS["appearance"] = function(window)
	local page = OptionsPage()

	page:Section("Opacity")
	page:Slider("opacityCombat", "In combat", 40, 100, "%", { apply = OptionsWindow.ApplyAll })
	page:Slider("opacityIdle", "Out of combat", 20, 100, "%", { apply = OptionsWindow.ApplyAll })
	page:Check("idleFadeEnabled", "Fade out entirely when idle", { apply = OptionsWindow.ApplyAll })
	page:Slider("idleFadeAfter", "Fade after", 5, 120, "s",
		{ indent = 21, apply = OptionsWindow.ApplyAll })
	page:Check("clickThroughFaded", "Click-through when faded", { apply = OptionsWindow.ApplyAll })

	page:Section("Density and type")
	-- STORED AND CLAMPED, BUT NOTHING READS IT YET, and the sub-label says so rather than the
	-- control quietly doing nothing. Theme.RowHeight() (Constants.lua) is the single place a
	-- consumer would read it. The three windows each have their own row pitch tuned to their own
	-- content (22px skill/buff rows, 24px death rows), none of them 16 or 20, and the analysis
	-- window's splitter snaps to whole buff rows -- a shared, variable row height is a layout
	-- change to window 3, not an options-panel change. See CLAUDE.md.
	page:Segment("density", "Row density", {
		{ label = "Compact 16px", value = "Compact" },
		{ label = "Normal 20px", value = "Normal" },
	}, { sub = "not wired to the tables yet", apply = OptionsWindow.ApplyAll })
	page:Segment("numberFont", "Number font", {
		{ label = "Lucida 12", value = "Lucida" },
		{ label = "Verdana 12", value = "Verdana" },
	}, { sub = "Verdana aligns badly in columns", apply = OptionsWindow.ApplyAll })
	page:Check("abbreviateNumbers", "Abbreviate big numbers (12.4k)", { apply = OptionsWindow.ApplyAll })
	page:Check("showBorders", "Window borders", { apply = OptionsWindow.ApplyAll })
	-- The handoff's own copy here describes a shared row-height system this plugin does not have
	-- ("Density changes bar height in the live meter and row height everywhere else"). Saying that
	-- to a player who then sees nothing change is worse than an accurate note, so this one states
	-- what is actually true today; the row's own sub-label repeats it.
	page:Note("Opacity applies to the live meter, the one window that is always on screen. "
		.. "Row density is saved but nothing reads it yet.")

	return page
end

---------------------------------------------------------------------------------------------------
-- Page 3 -- Palette
---------------------------------------------------------------------------------------------------

BUILDERS["palette"] = function(window)
	local page = OptionsPage()

	page:Section("Series palette")
	page:Note("Presets only -- four fixed sets, so a saved colour is always a name, never a "
		.. "serialised Turbine.UI.Color.")

	-- Swatch rows. Built here rather than in OptionsPage: nothing else in the window needs them.
	local rows = {}

	local function PaintSwatches()
		for i = 1, table.getn(rows) do
			local selected = (Theme.PresetOrder[i] == _G.settings.palettePreset)
			rows[i].dot:SetBackColor(selected and Theme.Color(Theme.Hex.AccentLight) or nil)
			rows[i].row:SetBackColor(selected and Theme.Color(Theme.Hex.ActiveTab) or nil)
		end
	end

	for i = 1, table.getn(Theme.PresetOrder) do
		local name = Theme.PresetOrder[i]
		local preset = Theme.Presets[name]

		local row = Turbine.UI.Control()
		row:SetParent(page)
		row:SetPosition(0, page.y)
		row:SetSize(PAGE_W, 30)
		row:SetMouseVisible(true)

		-- Radio "dot": a filled ring (border by inset, the only way to draw one here) whose
		-- centre is coloured when selected and cleared when not.
		local ring = Turbine.UI.Control()
		ring:SetParent(row)
		ring:SetPosition(INSET, 10)
		ring:SetSize(11, 11)
		ring:SetBackColor(Theme.Color(Theme.Hex.Accent700))
		ring:SetMouseVisible(false)

		local dot = Turbine.UI.Control()
		dot:SetParent(ring)
		dot:SetPosition(3, 3)
		dot:SetSize(5, 5)
		dot:SetMouseVisible(false)

		local label = Turbine.UI.Label()
		label:SetParent(row)
		label:SetFont(Font.Verdana12)
		label:SetForeColor(Theme.Color(Theme.Hex.Text))
		label:SetText(name .. ((i == 1) and "  (default)" or ""))
		label:SetPosition(32, 0)
		label:SetSize(200, 30)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)

		-- Four 22x11 chips, 3px apart, right-aligned so the last one ends at RIGHT.
		local order = { "done", "taken", "healOut", "morale" }
		for j = 1, 4 do
			local chip = Turbine.UI.Control()
			chip:SetParent(row)
			chip:SetPosition(RIGHT - (4 - j + 1) * 25 + 3, 10)
			chip:SetSize(22, 11)
			chip:SetBackColor(Theme.Color(preset[order[j]]))
			chip:SetMouseVisible(false)
		end

		row.MouseClick = function()
			_G.settings.palettePreset = name
			Settings.Save()
			PaintSwatches()
			page.RepaintPreview()
			OptionsWindow.ApplyAll()
		end
		row.MouseEnter = function()
			if _G.settings.palettePreset ~= name then
				row:SetBackColor(Theme.Color(Theme.Hex.Hover))
			end
		end
		row.MouseLeave = function() PaintSwatches() end

		rows[i] = { row = row, dot = dot }
		page:Grow(30)
		page:Rule()
	end

	-- Preview: four pooled Bars on the recessed PlotFill ground, so a preset is judged against
	-- something that looks like the real meter rather than against four bare swatches. The sample
	-- data is fixed, not live -- a preview that changes while you compare presets is useless.
	page:Section("Preview")

	local plot = Turbine.UI.Control()
	plot:SetParent(page)
	plot:SetPosition(INSET, page.y)
	plot:SetSize(PAGE_W - INSET * 2, 84)
	plot:SetBackColor(Theme.Color(Theme.Hex.PlotFill))
	plot:SetMouseVisible(false)

	local sample = {
		{ role = "done",    label = "Damage done",  pct = 0.88, text = "1,204/s" },
		{ role = "taken",   label = "Damage taken", pct = 0.54, text = "742/s" },
		{ role = "healOut", label = "Healing",      pct = 0.31, text = "418/s" },
		{ role = "morale",  label = "Morale",       pct = 0.66, text = "66%" },
	}

	local bars = {}
	for i = 1, 4 do
		local y = 8 + (i - 1) * 18

		local caption = Turbine.UI.Label()
		caption:SetParent(plot)
		caption:SetFont(Font.Verdana10)
		caption:SetForeColor(Theme.Color(Theme.Hex.MutedText))
		caption:SetText(sample[i].label)
		caption:SetPosition(8, y)
		caption:SetSize(80, 14)
		caption:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		caption:SetMouseVisible(false)

		local bar = Bar(180, 8, Theme.Series(sample[i].role), Theme.Hex.RowBorder)
		bar:SetParent(plot)
		bar:SetPosition(94, y + 3)
		bar:SetPercent(sample[i].pct)

		local value = Turbine.UI.Label()
		value:SetParent(plot)
		value:SetFont(Font.LucidaConsole12)
		value:SetForeColor(Theme.Color(Theme.Hex.Text))
		value:SetText(sample[i].text)
		value:SetPosition(282, y)
		value:SetSize(86, 14)
		value:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		value:SetMouseVisible(false)

		bars[i] = bar
	end

	page.RepaintPreview = function()
		for i = 1, 4 do
			bars[i]:SetFillColor(Theme.Series(sample[i].role))
		end
	end

	page:Grow(92)
	page:Check("typeColoredBars", "Colour damage bars by damage type", { apply = ApplyAnalysis })

	-- Not in the design handoff's own key table, but it was a real control on the panel this
	-- window replaces, and dropping it would have left the setting stranded with no way to change
	-- it. It sits here because it is a colour decision; the budget note matters because a post has
	-- a hard 240-character limit and each tinted run costs 19 of them (see ChatPost.lua).
	page:Check("postColor", "Colour chat posts", {
		hint = "costs post length",
		apply = function()
			if analysis ~= nil and analysis.postButton ~= nil then
				analysis.postButton:Rebuild()
			end
		end,
	})

	PaintSwatches()
	page:OnRefresh(function()
		PaintSwatches()
		page.RepaintPreview()
	end)

	return page
end

---------------------------------------------------------------------------------------------------
-- Page 4 -- Live meter
---------------------------------------------------------------------------------------------------

local LIVE_TABS = { "done", "taken", "healOut", "healIn" }

BUILDERS["live"] = function(window)
	local page = OptionsPage()

	page:Section("Live meter")

	-- First on the page because it changes the shape of everything under it: compact mode hides
	-- the sparkline and the three stat rows, so the sparkline settings below are inert while it is
	-- on. LiveMeter:ApplyMode does the whole switch, reached through ApplyLive.
	page:Check("compactMode", "Compact mode",
		{ hint = "clock, tabs and the number only", apply = ApplyLive })

	-- liveTab is stored as an INDEX (1-4), matching LiveMeter's own TABS order -- so these
	-- segment values are numbers, not the tab keys.
	page:Segment("liveTab", "Tab on open", {
		{ label = "Done", value = 1 },
		{ label = "Taken", value = 2 },
		{ label = "Heal out", value = 3 },
		{ label = "Heal in", value = 4 },
	}, { apply = function(value)
		if liveMeter ~= nil then
			liveMeter:SelectTab(LIVE_TABS[value] or "done", true)
		end
	end })

	-- NOT WIRED TO ANYTHING YET, and deliberately labelled as such. The design's live meter has a
	-- per-skill row list (it is drawn in the mockup's direction-1c preview strip); the live meter
	-- as built has a fixed headline plus three stat lines and no row list at all. The setting is
	-- stored, clamped and shipped so the control exists where the design puts it, but nothing
	-- reads it -- see CLAUDE.md. Do not quietly drop the sub-label without also building the list.
	page:Slider("liveRows", "Rows shown", 3, 10, "",
		{ sub = "for the skill list the meter does not have yet", apply = ApplyLive })

	page:Segment("liveBarValue", "Bar value", {
		{ label = "Per second", value = "Rate" },
		{ label = "Total", value = "Total" },
		{ label = "Both", value = "Both" },
	}, { apply = ApplyLive })

	page:Check("sparkline", "Sparkline in the header", { apply = ApplyLive })
	page:Slider("sparklineWindow", "Sparkline window", 10, 60, "s",
		{ indent = 21, apply = ApplyLive })

	page:Segment("refreshHz", "Refresh rate", {
		{ label = "2 Hz", value = 2 },
		{ label = "5 Hz", value = 5 },
		{ label = "10 Hz", value = 10 },
	}, { sub = "Lower is cheaper in raids", apply = ApplyLive })

	page:Check("clockThroughAvoids", "Keep the fight clock running through avoids")
	page:Check("announceSummary", "Announce the fight summary to a chat channel")

	page:Note("A plugin cannot send to a chat channel on its own, so the summary is written to "
		.. "your own chat window. Use POST in the analysis window to send one for real.")

	return page
end

---------------------------------------------------------------------------------------------------
-- Page 5 -- Death window
---------------------------------------------------------------------------------------------------

BUILDERS["death"] = function(window)
	local page = OptionsPage()

	page:Section("Death window")
	page:Slider("deathAutoHide", "Auto-hide after", 5, 30, "s",
		{ fillHex = Theme.Hex.DamageSevere, apply = ApplyDeath })
	page:Check("deathStayOpen", "Stay open until dismissed",
		{ hint = "ignores the timer", apply = ApplyDeath })
	page:Slider("deathRows", "Hits listed", 3, 12, "", { apply = ApplyDeath })
	page:Slider("deathLookback", "Look back", 5, 30, "s", { apply = ApplyDeath })

	page:Section("Rows show")
	page:Check("deathMarkKill", "Mark the killing blow",
		{ swatchHex = Theme.Hex.DeathKillFill, apply = ApplyDeath })
	page:Check("deathMarkMax", "Mark the biggest single hit",
		{ swatchHex = Theme.Hex.DeathMaxFill, apply = ApplyDeath })
	page:Check("deathMoraleTrack", "Morale track behind each row", { apply = ApplyDeath })
	page:Check("deathIncludeAvoids", "Include avoided and partial hits", { apply = ApplyDeath })
	page:Check("deathShowType", "Damage type after the skill name", { apply = ApplyDeath })

	page:Note("The window keeps its own darker ground (" .. Theme.Hex.DeathFill .. ") whatever "
		.. "the palette preset is -- it is the one window that should not look like the rest.")

	return page
end

---------------------------------------------------------------------------------------------------
-- Page 6 -- Self buffs
---------------------------------------------------------------------------------------------------

local function ChartedIndex(name)
	local list = _G.settings.chartedBuffs or {}
	for i = 1, table.getn(list) do
		if list[i] == name then
			return i
		end
	end
	return nil
end

BUILDERS["buffs"] = function(window)
	local page = OptionsPage()

	local header = page:Section("Charted buffs")
	page:Note("Lane colour comes from position in this list, so reordering recolours the graph.")

	-- BUFF_SLOTS pooled rows, filled from Buffs.Stats and hidden when unused. Pooled rather than
	-- rebuilt because this codebase never detaches a Control, and the ROW COUNT IS FIXED so the
	-- rest of the page can sit at a constant y -- the alternative (re-laying out everything below
	-- on every repaint) buys nothing on a page whose list is worst-uptime-first and rarely long.
	local slots = {}
	local pickerTop = page.y

	for i = 1, BUFF_SLOTS do
		local y = pickerTop + (i - 1) * BUFF_ROW_H

		local box = Turbine.UI.Lotro.CheckBox()
		box:SetParent(page)
		box:SetPosition(INSET, y + 5)
		box:SetSize(16, 16)
		box:SetFont(Font.Verdana12)
		box:SetText("")

		-- Initials tile, not the real effect art. Icon.Apply renders at the image's NATIVE size
		-- with no stretch (Constants.lua, round seven of the icon investigation), which is
		-- commonly 32x32 -- it would overflow a 26px row here. The analysis window's buff table
		-- and graph lanes are the two places that carry that risk; this page does not add a
		-- third until the icon path is confirmed in-game.
		local tile = Turbine.UI.Control()
		tile:SetParent(page)
		tile:SetPosition(INSET + 22, y + 6)
		tile:SetSize(14, 14)
		tile:SetMouseVisible(false)

		local initials = Turbine.UI.Label()
		initials:SetParent(tile)
		initials:SetFont(Font.Verdana10)
		initials:SetPosition(0, 0)
		initials:SetSize(14, 14)
		initials:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
		initials:SetMouseVisible(false)

		local name = Turbine.UI.Label()
		name:SetParent(page)
		name:SetFont(Font.Verdana12)
		name:SetPosition(INSET + 42, y)
		name:SetSize(210, BUFF_ROW_H)
		name:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		name:SetMouseVisible(false)

		local lane = Turbine.UI.Label()
		lane:SetParent(page)
		lane:SetFont(Font.Verdana10)
		lane:SetPosition(RIGHT - 110, y)
		lane:SetSize(70, BUFF_ROW_H)
		lane:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		lane:SetMouseVisible(false)

		-- ASCII arrows, not the mockup's Unicode ones: this client has already been caught
		-- missing Geometric Shapes glyphs (the session rail's pin diamonds rendered as "?").
		local up = Turbine.UI.Label()
		up:SetParent(page)
		up:SetFont(Font.Verdana12)
		up:SetForeColor(Theme.Color(Theme.Hex.DimText))
		up:SetText("^")
		up:SetPosition(RIGHT - 34, y)
		up:SetSize(16, BUFF_ROW_H)
		up:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)

		local down = Turbine.UI.Label()
		down:SetParent(page)
		down:SetFont(Font.Verdana12)
		down:SetForeColor(Theme.Color(Theme.Hex.DimText))
		down:SetText("v")
		down:SetPosition(RIGHT - 16, y)
		down:SetSize(16, BUFF_ROW_H)
		down:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)

		local rule = Turbine.UI.Control()
		rule:SetParent(page)
		rule:SetPosition(INSET, y + BUFF_ROW_H - 1)
		rule:SetSize(PAGE_W - INSET * 2, 1)
		rule:SetBackColor(Theme.Color(Theme.Hex.RowBorder))
		rule:SetMouseVisible(false)

		slots[i] = { box = box, tile = tile, initials = initials, name = name,
			lane = lane, up = up, down = down, rule = rule, buffName = nil }
	end

	page:Grow(BUFF_SLOTS * BUFF_ROW_H)

	-- Writes the charted list back and re-renders everything that depends on it, in one place:
	-- the picker itself, the analysis window's lanes and buff table, and the persisted setting.
	local function CommitCharted(list)
		_G.settings.chartedBuffs = list
		Settings.Save()
		if analysis ~= nil and analysis.AdoptChartedBuffs ~= nil then
			analysis:AdoptChartedBuffs()
		end
		page.Repaint()
	end

	local function Move(name, delta)
		local list = _G.settings.chartedBuffs or {}
		local index = ChartedIndex(name)
		if index == nil then
			return
		end
		local target = index + delta
		if target < 1 or target > table.getn(list) then
			return
		end
		list[index], list[target] = list[target], list[index]
		CommitCharted(list)
	end

	-- The cap REFUSES a fourth rather than dropping the oldest (design handoff, page 6). The
	-- refusal is visible: an unchecked box goes Disabled-grey the moment three are charted, and
	-- a click on one puts the tick straight back. This deliberately differs from the analysis
	-- window's own buff table, which drops the oldest instead -- there the row list is long and
	-- greying every unchecked box would read as the table being broken.
	local function Toggle(slot)
		if slot.buffName == nil or slot.suppress then
			return
		end

		local list = _G.settings.chartedBuffs or {}
		local index = ChartedIndex(slot.buffName)

		if index ~= nil then
			table.remove(list, index)
		elseif table.getn(list) >= MAX_CHARTED then
			slot.suppress = true
			slot.box:SetChecked(false)
			slot.suppress = false
			return
		else
			list[table.getn(list) + 1] = slot.buffName
		end

		CommitCharted(list)
	end

	for i = 1, BUFF_SLOTS do
		local slot = slots[i]
		slot.box.CheckedChanged = function() Toggle(slot) end
		slot.up.MouseClick = function() if slot.buffName then Move(slot.buffName, -1) end end
		slot.down.MouseClick = function() if slot.buffName then Move(slot.buffName, 1) end end
	end

	---------------------------------------------------------------------------------------------
	-- Ignore list. Its own OptionsPage nested inside this one, so its cursor arithmetic does not
	-- have to know where the fixed-height picker above it ended.
	---------------------------------------------------------------------------------------------
	local tail = OptionsPage()
	tail:SetParent(page)
	tail:SetPosition(0, page.y)

	tail:Section("Ignore list")

	local entryY = tail.y

	-- First use of Turbine.UI.TextBox outside UI/Analysis.lua's search boxes, which were
	-- themselves ported from LootLogs' sidebar search -- same shape: SetMultiline(false), text
	-- read on demand rather than on every keystroke.
	local entry = Turbine.UI.TextBox()
	entry:SetParent(tail)
	entry:SetPosition(INSET, entryY + 2)
	entry:SetSize(PAGE_W - INSET * 2 - 80, 22)
	entry:SetFont(Font.Verdana12)
	entry:SetMultiline(false)
	entry:SetBackColor(Theme.Color(Theme.Hex.AppGround))
	entry:SetForeColor(Theme.Color(Theme.Hex.Text))

	tail:Button(RIGHT - 72, entryY + 2, 72, 22, "Ignore", false, function()
		local name = entry:GetText()
		name = string.gsub(name or "", "^%s*(.-)%s*$", "%1")
		if name == "" then
			return
		end
		Buffs.AddIgnore(name)
		entry:SetText("")
		page.Repaint()
	end)

	tail:Grow(28)

	-- Pooled chips, two rows' worth. Overflow is reported as a count rather than silently
	-- dropped -- the list is editable from /redbook buffs too, so it can grow past what fits here.
	local chips = {}
	local chipTop = tail.y

	for i = 1, CHIP_SLOTS do
		local chip = Turbine.UI.Control()
		chip:SetParent(tail)
		chip:SetSize(40, 18)
		chip:SetBackColor(Theme.Color(Theme.Hex.ActiveTab))
		chip:SetVisible(false)
		chip:SetMouseVisible(false)

		local inset = Turbine.UI.Control()
		inset:SetParent(chip)
		inset:SetPosition(1, 1)
		inset:SetSize(38, 16)
		inset:SetBackColor(Theme.Color(Theme.Hex.RailFill))
		inset:SetMouseVisible(false)

		local label = Turbine.UI.Label()
		label:SetParent(inset)
		label:SetFont(Font.Verdana10)
		label:SetForeColor(Theme.Color(Theme.Hex.MutedText))
		label:SetPosition(6, 0)
		label:SetSize(28, 16)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)

		local cross = Turbine.UI.Control()
		cross:SetParent(chip)
		cross:SetSize(12, 12)
		cross:SetMouseVisible(true)

		local crossIcon = Turbine.UI.Control()
		crossIcon:SetParent(cross)
		crossIcon:SetPosition(0, 0)
		crossIcon:SetSize(12, 12)
		crossIcon:SetBlendMode(Turbine.UI.BlendMode.Overlay)
		crossIcon:SetBackground("RedBook/Resources/cross.tga")
		crossIcon:SetMouseVisible(false)

		chips[i] = { chip = chip, inset = inset, label = label, cross = cross, name = nil }
	end

	local overflowLabel = Turbine.UI.Label()
	overflowLabel:SetParent(tail)
	overflowLabel:SetFont(Font.Verdana10)
	overflowLabel:SetForeColor(Theme.Color(Theme.Hex.Disabled))
	overflowLabel:SetPosition(INSET, chipTop + CHIP_ROWS * (CHIP_H + 2))
	overflowLabel:SetSize(PAGE_W - INSET * 2, 14)
	overflowLabel:SetMouseVisible(false)

	for i = 1, CHIP_SLOTS do
		local entryChip = chips[i]
		entryChip.cross.MouseClick = function()
			if entryChip.name ~= nil then
				Buffs.RemoveIgnore(entryChip.name)
				page.Repaint()
			end
		end
	end

	tail:Grow(CHIP_ROWS * (CHIP_H + 2) + 16)
	tail:Check("hideStaticBuffs", "Hide buffs that never change during a fight",
		{ apply = ApplyAnalysis })

	page:Grow(tail:GetHeight())
	page:OnRefresh(function() tail:Refresh() end)

	---------------------------------------------------------------------------------------------

	page.Repaint = function()
		local session = Sessions.current or Sessions.list[1]
		local stats = Buffs.Stats(session, nil, nil)
		local charted = _G.settings.chartedBuffs or {}
		local chartedCount = table.getn(charted)
		local full = (chartedCount >= MAX_CHARTED)

		header:SetText(string.upper("Charted buffs") .. "   " .. chartedCount .. " of " .. MAX_CHARTED)

		-- Charted buffs first, in lane order, then whatever else the session tracked. A buff the
		-- current session has not seen still has to be listed if it is charted, or it could never
		-- be un-charted from here.
		local listed, seen = {}, {}
		for i = 1, chartedCount do
			listed[table.getn(listed) + 1] = { name = charted[i], initials = Buffs.Initials(charted[i]) }
			seen[charted[i]] = true
		end
		for i = 1, table.getn(stats) do
			local row = stats[i]
			if not seen[row.name] then
				listed[table.getn(listed) + 1] = { name = row.name, initials = row.initials }
				seen[row.name] = true
			end
		end

		for i = 1, BUFF_SLOTS do
			local slot = slots[i]
			local row = listed[i]

			if row == nil then
				slot.buffName = nil
				slot.box:SetVisible(false)
				slot.tile:SetVisible(false)
				slot.name:SetText("")
				slot.lane:SetText("")
				slot.up:SetVisible(false)
				slot.down:SetVisible(false)
				slot.rule:SetVisible(false)
			else
				local index = ChartedIndex(row.name)
				local laneHex = index and Theme.BuffLane[index] or Theme.Hex.Text

				slot.buffName = row.name
				slot.box:SetVisible(true)
				-- suppress: SetChecked fires CheckedChanged, and a repaint must never be mistaken
				-- for the user clicking the box.
				slot.suppress = true
				slot.box:SetChecked(index ~= nil)
				slot.suppress = false
				slot.box:SetForeColor(Theme.Color((index == nil and full) and Theme.Hex.Disabled or Theme.Hex.Text))

				slot.tile:SetVisible(true)
				slot.tile:SetBackColor(Theme.Color(index and laneHex or Theme.Hex.Border))
				slot.initials:SetText(row.initials or "")
				slot.initials:SetForeColor(Theme.Color(Theme.Hex.AppGround))

				slot.name:SetText(row.name)
				slot.name:SetForeColor(Theme.Color(index and laneHex or Theme.Hex.Text))

				if index ~= nil then
					slot.lane:SetText("lane " .. index)
					slot.lane:SetForeColor(Theme.Color(Theme.Hex.DimText))
				elseif not full then
					slot.lane:SetText("lane " .. (chartedCount + 1) .. " free")
					slot.lane:SetForeColor(Theme.Color(Theme.Hex.Disabled))
				else
					slot.lane:SetText("")
				end

				slot.up:SetVisible(index ~= nil and index > 1)
				slot.down:SetVisible(index ~= nil and index < chartedCount)
				slot.rule:SetVisible(true)
			end
		end

		-- Ignore chips. Buffs.Ignore's built-in defaults are not editable and get no chip, but a
		-- default the player explicitly UN-ignored is stored as `false` and must not appear
		-- either -- which is what routing through Buffs.IsIgnored gives for free.
		local names = {}
		local user = _G.settings.buffIgnore or {}
		for name, value in pairs(user) do
			if value == true and Buffs.IsIgnored(name) then
				names[table.getn(names) + 1] = name
			end
		end
		table.sort(names)

		local x, y, rowIndex, shown = INSET, chipTop, 1, 0
		for i = 1, CHIP_SLOTS do
			local chipEntry = chips[i]
			local name = names[i]

			if name == nil or rowIndex > CHIP_ROWS then
				chipEntry.name = nil
				chipEntry.chip:SetVisible(false)
			else
				local text = Format.Truncate(name, 18)
				local width = Format.CharCount(text) * 7 + 32

				if x + width > RIGHT and x > INSET then
					rowIndex = rowIndex + 1
					x = INSET
					y = chipTop + (rowIndex - 1) * (CHIP_H + 2)
				end

				if rowIndex > CHIP_ROWS then
					chipEntry.name = nil
					chipEntry.chip:SetVisible(false)
				else
					chipEntry.name = name
					chipEntry.chip:SetPosition(x, y)
					chipEntry.chip:SetSize(width, 18)
					chipEntry.inset:SetSize(width - 2, 16)
					chipEntry.label:SetText(text)
					chipEntry.label:SetSize(width - 24, 16)
					chipEntry.cross:SetPosition(width - 15, 3)
					chipEntry.chip:SetVisible(true)
					shown = shown + 1
					x = x + width + CHIP_GAP
				end
			end
		end

		local total = table.getn(names)
		if total == 0 then
			overflowLabel:SetText("Nothing ignored. /redbook buffs list shows what is being tracked.")
		elseif total > shown then
			overflowLabel:SetText("+" .. (total - shown) .. " more -- see /redbook buffs list")
		else
			overflowLabel:SetText("")
		end
	end

	page.Repaint()
	return page
end

---------------------------------------------------------------------------------------------------
-- Page 7 -- Sessions
---------------------------------------------------------------------------------------------------

BUILDERS["sessions"] = function(window)
	local page = OptionsPage()

	page:Section("What counts as a fight")
	page:Slider("idleTimeout", "Idle timeout", 3, 30, "s",
		{ sub = "Silence that ends the session" })
	page:Slider("minFightLength", "Discard fights shorter than", 0, 15, "s")
	page:Segment("sessionsKept", "Sessions kept", {
		{ label = "10", value = 10 },
		{ label = "25", value = 25 },
		{ label = "50", value = 50 },
	}, { sub = "Ring buffer, never saved to disk" })
	page:Check("mergeFights", "Merge fights separated by less than the timeout")
	page:Check("dropOnZoneChange", "Drop unpinned sessions on zone change")
	page:Segment("bucketWidth", "Graph buckets", {
		{ label = "1s", value = 1 },
		{ label = "2s", value = 2 },
		{ label = "Auto", value = 0 },
	}, { apply = ApplyAnalysis })

	page:Section("Danger")

	local note = Turbine.UI.Label()
	note:SetParent(page)
	note:SetFont(Font.Verdana10)
	note:SetForeColor(Theme.Color(Theme.Hex.DimText))
	note:SetText("Clears every session and pin held in memory. Settings are untouched.")
	note:SetPosition(INSET, page.y)
	note:SetSize(PAGE_W - INSET * 2 - 110, 34)
	note:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	note:SetMultiline(true)
	note:SetMouseVisible(false)

	-- Two-step rather than a modal: this codebase has no dialog primitive and should not grow one
	-- for a single button. The first click relabels and arms for CLEAR_ARM_SECONDS (the window's
	-- Update disarms it); the second inside that window actually clears.
	local clearLabel
	local armed = false

	local function Disarm()
		armed = false
		clearLabel:SetText("Clear data")
	end

	local _, label = page:Button(RIGHT - 100, page.y + 4, 100, 26, "Clear data", true, function()
		if not armed then
			armed = true
			clearLabel:SetText("Clear data?")
			window.disarm = Disarm
			window.disarmAt = Turbine.Engine.GetGameTime() + CLEAR_ARM_SECONDS
			return
		end

		Disarm()
		window.disarm = nil
		window.disarmAt = nil
		Sessions.ClearAll()
	end)
	clearLabel = label

	page:Grow(34)
	page:OnRefresh(Disarm)

	return page
end
