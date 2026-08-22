--=================================================================================================
-- PostButton -- the post control pair in the analysis window's header.
--
--     [ POST ][ FELL ]
--
-- POST is a themed button with an invisible quickslot floating exactly on top of it (the quickslot
-- is what actually fires the post -- see ChatPost.lua for why a click is unavoidable). FELL is a
-- plain Control naming the destination channel, which opens the channel/preset menu when clicked.
--
-- THE INVISIBLE QUICKSLOT, and the two ways this has already gone wrong:
--
-- A Quickslot cannot be restyled and cannot be faded -- SetOpacity does not apply to one, which a
-- previous attempt confirmed in-game (it rendered at full strength over the themed button and just
-- looked broken). CombatAnalysis's answer, which this now follows, is to put the quickslot inside
-- its OWN top-level Turbine.UI.Window sized 0x0 with SetOpacity(0) -- opacity DOES work on a
-- Window with no BackColor of its own -- and position that window in SCREEN coordinates directly
-- over the themed button (StatOverview/StatOverviewPanel.lua:213-247).
--
-- The catch, and the reason an earlier version of this file shipped a POST button that could not
-- be clicked at all: two top-level windows compete for z-order. Reckoning calls analysis:Activate()
-- when the window is shown, which raises it above the overlay and buries the quickslot.
-- CombatAnalysis survives that by re-calling chatSendWindow:Activate() from its **per-frame**
-- Update() (StatOverviewWindow.lua:133-152) -- and that is exactly why its own README has a line
-- about no longer "stealing focus away from the chat window", because Activate() takes focus.
--
-- So the overlay is re-raised on INTERACTION, not on a timer: whenever the analysis window is
-- shown, and whenever the user presses the mouse anywhere on it. Pressing the analysis window is
-- the only thing that realistically buries the overlay, and it is also what a user does
-- immediately before reaching for POST -- so this self-heals without ever grabbing focus while
-- the window simply sits open. The 4Hz heartbeat only re-POSITIONS the overlay (cheap, and no
-- Activate), as a backstop for the window being shown or hidden from any of the several places
-- that can do it.
--
-- If the button is ever dead again, Raise() is the thing to check first, and adding a call to it
-- is nearly always the fix -- not a timer.
--
-- NOT YET CONFIRMED IN-GAME: that Turbine.UI.ContextMenu / MenuItem behave as CombatAnalysis's
-- use implies (StatOverviewChatMenu.lua) -- nothing else in Reckoning had touched them.
--=================================================================================================

PostButton = class(Turbine.UI.Control)

local BTN_WIDTH = 54
local BTN_HEIGHT = 18
local CHAN_WIDTH = 52
local GAP = 4

PostButton.Width = BTN_WIDTH + GAP + CHAN_WIDTH

-- params: { parent, headerHeight, onNeedLine }
-- `onNeedLine` returns the post's single line for the current window state -- the button never
-- reaches into the analysis window itself, so this file stays independent of its internals.
function PostButton:Constructor(params)
	Turbine.UI.Control.Constructor(self)

	self.onNeedLine = params.onNeedLine
	self.headerHeight = params.headerHeight or 26
	self.line = nil
	self.enabled = false
	self.overlayShown = false
	self.overlayX, self.overlayY = -1, -1

	-- `self` is the themed POST button. The quickslot floats over it; the channel button is a
	-- separate sibling built below.
	self:SetParent(params.parent)
	self:SetSize(BTN_WIDTH, BTN_HEIGHT)
	self:SetBackColor(Theme.Color(Theme.Hex.ActiveTab))
	self:SetMouseVisible(false)

	self.label = Turbine.UI.Label()
	self.label:SetParent(self)
	self.label:SetFont(Font.Verdana10)
	self.label:SetSize(BTN_WIDTH, BTN_HEIGHT)
	self.label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	self.label:SetText("POST")
	self.label:SetMouseVisible(false)

	self:BuildChannelButton(params.parent)
	self:BuildOverlay()
	self:Refresh()
end

function PostButton:Channel()
	return (_G.settings and _G.settings.postChannel) or ChatPost.Channels[1].key
end

function PostButton:Preset()
	return (_G.settings and _G.settings.postPreset) or "summary"
end

---------------------------------------------------------------------------------------------------
-- The channel button
---------------------------------------------------------------------------------------------------

-- A plain Control, because the menu cannot live on the quickslot's own right-click -- the client
-- uses that itself. A plain Control's MouseClick is proven all over this codebase (picker chips,
-- session rail rows, table headers). CombatAnalysis reached the same shape from the other
-- direction: its channel menu is on a separate speech-bubble icon, not on the send button.
function PostButton:BuildChannelButton(parent)
	local button = self

	self.channel = Turbine.UI.Control()
	self.channel:SetParent(parent)
	self.channel:SetSize(CHAN_WIDTH, BTN_HEIGHT)
	self.channel:SetBackColor(Theme.Color(Theme.Hex.ActiveTab))
	self.channel:SetMouseVisible(true)

	self.channelLabel = Turbine.UI.Label()
	self.channelLabel:SetParent(self.channel)
	self.channelLabel:SetFont(Font.Verdana10)
	self.channelLabel:SetSize(CHAN_WIDTH, BTN_HEIGHT)
	self.channelLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	self.channelLabel:SetForeColor(Theme.Color(Theme.Hex.Accent200))
	self.channelLabel:SetMouseVisible(false)

	self.channel.MouseClick = function() button:ShowMenu() end
	self.channel.MouseEnter = function()
		button.channel:SetBackColor(Theme.Color(Theme.Hex.Hover))
	end
	self.channel.MouseLeave = function()
		button.channel:SetBackColor(Theme.Color(Theme.Hex.ActiveTab))
	end
end

---------------------------------------------------------------------------------------------------
-- The invisible quickslot
---------------------------------------------------------------------------------------------------

function PostButton:BuildOverlay()
	local button = self

	-- Its own top-level Window, deliberately: a quickslot cannot be faded, but a Window with no
	-- BackColor of its own can. Do not give this window a BackColor -- that is precisely the case
	-- where SetOpacity is confirmed NOT to blend (see CLAUDE.md).
	self.overlay = Turbine.UI.Window()
	self.overlay:SetSize(0, 0)
	self.overlay:SetOpacity(0)
	self.overlay:SetMouseVisible(true)
	self.overlay:SetVisible(true)

	self.slot = Turbine.UI.Lotro.Quickslot()
	self.slot:SetParent(self.overlay)
	self.slot:SetSize(BTN_WIDTH, BTN_HEIGHT)
	self.slot:SetZOrder(2)
	self.slot:SetMouseVisible(true)

	self.shortcut = Turbine.UI.Lotro.Shortcut(Turbine.UI.Lotro.ShortcutType.Alias, nil)

	-- The quickslot is invisible, so every bit of hover feedback has to be forwarded by hand to
	-- the themed button underneath it.
	self.slot.MouseEnter = function() button:Tint(Theme.Hex.Hover, Theme.Hex.Accent200) end
	self.slot.MouseLeave = function() button:Refresh() end

	-- Without this, a user who drags the alias off the slot is left with a dead button until
	-- reload. Both CombatAnalysis and PrimePlugins/RaidTools guard the same way.
	self.slot.DragDrop = function()
		button.slot:SetShortcut(button.shortcut)
	end
end

-- Places the themed button and the channel button, both siblings in the header, and re-positions
-- the overlay to match. `Place` is deliberately not an override of the native SetPosition --
-- overriding native methods on a Turbine control has no confirmed precedent in this codebase.
function PostButton:Place(x, y)
	local top = y + math.floor((self.headerHeight - BTN_HEIGHT) / 2)
	self:SetPosition(x, top)
	self.channel:SetPosition(x + BTN_WIDTH + GAP, top)
	self:SyncOverlay(true)
end

-- The window whose screen position the overlay follows. Set once by Analysis after construction;
-- kept as a field rather than walking GetParent(), because the button is parented into the header
-- Control, not into the window itself.
function PostButton:Track(window)
	self.trackWindow = window
	self:SyncOverlay(true)
end

-- Keeps the invisible quickslot exactly over the themed button. `force` skips the no-op guard when
-- the caller knows geometry changed. Deliberately does NOT Activate -- see Raise().
--
-- The guard matters: this runs 4x a second forever, and SetPosition/SetSize on a Window are not
-- free. Only touching them when the numbers actually changed keeps the idle cost at two compares.
function PostButton:SyncOverlay(force)
	local parentWindow = self.trackWindow
	local visible = (parentWindow ~= nil) and parentWindow:IsVisible() or false
	local wantShown = visible and self.enabled

	if not wantShown then
		if self.overlayShown or force then
			self.overlayShown = false
			self.overlay:SetSize(0, 0)
		end
		return
	end

	local wx, wy = parentWindow:GetPosition()
	local bx, by = self:GetPosition()
	local x, y = wx + bx, wy + by

	local appearing = not self.overlayShown
	if appearing or force then
		self.overlayShown = true
		self.overlay:SetSize(BTN_WIDTH, BTN_HEIGHT)
	end
	if appearing or force or x ~= self.overlayX or y ~= self.overlayY then
		self.overlayX, self.overlayY = x, y
		self.overlay:SetPosition(x, y)
	end

	-- Raise on the transition into view only, never on every sync -- the heartbeat calls this
	-- continuously and Activate() takes keyboard focus.
	if appearing then
		self:Raise()
	end
end

-- Brings the overlay back above the analysis window. Called when the window is shown and when the
-- mouse is pressed on it -- pressing the window is what buries the overlay, and it is also what a
-- user does immediately before reaching for POST, so the button self-heals.
function PostButton:Raise()
	if self.overlayShown then
		self.overlay:Activate()
	end
end

function PostButton:Shutdown()
	if self.overlay ~= nil then
		self.overlay:SetSize(0, 0)
		self.overlay:SetVisible(false)
	end
end

---------------------------------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------------------------------

-- Rebuilds the alias from the window's current state. This has to run on EVERY change of view,
-- filter, range, session, channel or preset -- an alias is a static string, so a stale one posts
-- stale numbers. Analysis calls it from RefreshContent, which is the one function all of those
-- changes already funnel through.
function PostButton:Rebuild()
	self.line = self.onNeedLine and self.onNeedLine() or nil
	self.enabled = (self.line ~= nil and self.line ~= "")

	if self.enabled then
		local alias = ChatPost.Alias(self:Channel(), self.line)
		if alias ~= nil then
			self.shortcut:SetData(alias)
			self.slot:SetShortcut(self.shortcut)
		else
			self.enabled = false
		end
	end

	self:SyncOverlay(true)
	self:Refresh()
end

function PostButton:Tint(fillHex, textHex)
	self:SetBackColor(Theme.Color(fillHex))
	self.label:SetForeColor(Theme.Color(textHex))
end

function PostButton:Refresh()
	if self.enabled then
		self:Tint(Theme.Hex.ActiveTab, Theme.Hex.Accent200)
	else
		self:Tint(Theme.Hex.WindowFill, Theme.Hex.Disabled)
	end
	self.channelLabel:SetText(ChatPost.ChannelShort(self:Channel()))
	self.channelLabel:SetForeColor(Theme.Color(
		self.enabled and Theme.Hex.Accent200 or Theme.Hex.Disabled))
end

---------------------------------------------------------------------------------------------------
-- Channel / preset menu
---------------------------------------------------------------------------------------------------

-- Radio-check pattern from CombatAnalysis/StatOverview/StatOverviewChatMenu.lua, with one
-- difference: the whole menu is rebuilt each time it opens rather than being built once and
-- re-checked. The death preset's availability depends on which session is selected *now*, and
-- rebuilding is simpler than keeping a long-lived item list in sync with that.
--
-- `self.menu` is kept only so the menu object outlives this function -- letting it be collected
-- while the client still has it open is not a risk worth taking for one table.
function PostButton:ShowMenu()
	local button = self
	local menu = Turbine.UI.ContextMenu()
	local items = menu:GetItems()

	for i = 1, table.getn(ChatPost.Channels) do
		local channel = ChatPost.Channels[i]
		local item = Turbine.UI.MenuItem(channel.label, true, channel.key == self:Channel())
		item.Click = function()
			_G.settings.postChannel = channel.key
			Settings.Save()
			button:Rebuild()
		end
		items:Add(item)
	end

	items:Add(Turbine.UI.MenuItem("-", false, false))

	-- The death preset is offered but disabled when the selected session did not end in a death,
	-- rather than hidden -- a missing menu entry reads as a bug, a greyed one explains itself.
	local canDie = (self.onCanDeath == nil) or self.onCanDeath()
	for i = 1, table.getn(ChatPost.Presets) do
		local preset = ChatPost.Presets[i]
		local enabled = (preset.key ~= "death") or canDie
		local item = Turbine.UI.MenuItem(preset.label, enabled, preset.key == self:Preset())
		item.Click = function()
			if not enabled then
				return
			end
			_G.settings.postPreset = preset.key
			Settings.Save()
			button:Rebuild()
		end
		items:Add(item)
	end

	self.menu = menu
	menu:ShowMenu()
end
