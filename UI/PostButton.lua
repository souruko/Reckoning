--=================================================================================================
-- PostButton -- one post control in the analysis window's header.
--
--     [ DEATH ]  [ POST ][ FELL ]
--
-- POST is a themed button with an invisible quickslot floating exactly on top of it (the quickslot
-- is what actually fires the post -- see ChatPost.lua for why a click is unavoidable). FELL is a
-- plain Control naming the destination channel, which opens the channel + summary-parts menu when
-- clicked.
--
-- DEATH is a SECOND PostButton, armed with the death-report preset, and it exists only while the
-- selected fight actually ended in a death -- `hideWhenDisabled` takes it off the header entirely
-- rather than greying it. The two used to be one button with a preset toggle buried in the menu,
-- which meant a death report was three clicks away and, worse, that leaving the toggle on "death"
-- silently disarmed the button for every fight you survived. A button that is there or is not there
-- answers "did this fight kill me" on sight.
--
-- The channel is SHARED (one _G.settings.postChannel), so only the summary button carries the
-- channel control -- two of them naming the same setting would read as two independent
-- destinations. `showChannel` decides which button builds one.
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
-- The catch, and the reason two versions of this file shipped a POST button that could not be
-- clicked at all: two top-level windows compete for z-order. ANY click on the analysis window
-- raises it above the overlay and buries the quickslot -- and the client does that raise itself,
-- without routing through anything this code calls.
--
-- The first attempt hung the re-raise on the analysis window's own `self.MouseDown`. That does
-- not work, and the reason is worth knowing: Turbine mouse events do NOT bubble to a parent, so
-- a press that lands on any mouse-visible CHILD (a tab, a chip, a session row, a table header,
-- the header itself) never reaches the window's own handler -- while still raising the window.
-- Since a user always clicks something before reaching for POST, the overlay was buried more or
-- less permanently. That non-bubbling is also exactly why CombatAnalysis hand-forwards a
-- `WindowManager.MouseWasPressed(window)` call out of ~60 separate mouse handlers
-- (UI/WindowManager.lua:340) -- it walks up to the top-level window and calls Activate() on it.
--
-- CombatAnalysis's actual re-raise is that call landing in its OVERRIDDEN
-- StatOverviewWindow:Activate() (StatOverviewWindow.lua:56-68), which does the base activate and
-- then chatSendWindow:Activate(). (Its Update() does the same thing, but only on the last frame
-- of the minimize animation -- the body is gated on `not self:GetWantsUpdates()`. There is no
-- per-frame Activate; an earlier comment here said there was, and that was misread.)
--
-- Basil gets the same funnel without 60 forwarding calls, by hooking the window's real
-- `Activated` event instead: it fires however the window came to the front, including a client-
-- initiated raise from a click on a child. That is a confirmed-real Window event (Thurallor's
-- Common/Utils/Utils_13.lua:657 hooks it for exactly this "the window just became active"
-- meaning, alongside the Deactivated that several other installed plugins use).
--
-- Two backstops on top of it, because a dead POST button is a silent failure:
--   * the themed button underneath is mouse-visible, and its MouseEnter re-raises. If the overlay
--     is ever buried anyway, the hover that reaches the button *is* the proof of it -- when the
--     overlay is on top, the button cannot receive a MouseEnter at all -- so the pointer arriving
--     at POST fixes the z-order before the click that follows it.
--   * the 4Hz heartbeat still only re-POSITIONS (SyncOverlay), never activates.
--
-- Activate() takes keyboard focus, which is why it is on activation and hover rather than a
-- timer, and why the overlay forwards Escape back to the tracked window (Frame's own KeyDown
-- cannot fire while the overlay holds focus).
--
-- If the button is ever dead again, Raise() is the thing to check first, and adding a call to it
-- is nearly always the fix -- not a timer.
--
-- NOT YET CONFIRMED IN-GAME: that Turbine.UI.ContextMenu / MenuItem behave as CombatAnalysis's
-- use implies (StatOverviewChatMenu.lua) -- nothing else in Basil had touched them.
--=================================================================================================

PostButton = class(Turbine.UI.Control)

local BTN_WIDTH = 54
local BTN_HEIGHT = 18
local CHAN_WIDTH = 52
local GAP = 4

-- The width Analysis:LayoutHeaderExtras reserves for each flavour. The summary button carries the
-- channel control beside it; the death button is the button alone.
PostButton.Width = BTN_WIDTH + GAP + CHAN_WIDTH
PostButton.SoloWidth = BTN_WIDTH

-- params: { parent, headerHeight, onNeedLine, preset, showChannel, hideWhenDisabled }
-- `onNeedLine(preset)` returns the post's single line for the current window state -- the button
-- never reaches into the analysis window itself, so this file stays independent of its internals.
function PostButton:Constructor(params)
	Turbine.UI.Control.Constructor(self)

	self.onNeedLine = params.onNeedLine
	self.headerHeight = params.headerHeight or 26
	self.preset = params.preset or "summary"
	self.hideWhenDisabled = (params.hideWhenDisabled == true)
	self.line = nil
	self.enabled = false
	self.overlayShown = false
	self.overlayX, self.overlayY = -1, -1

	-- `self` is the themed button. The quickslot floats over it; the channel button, when this
	-- flavour has one, is a separate sibling built below.
	self:SetParent(params.parent)
	self:SetSize(BTN_WIDTH, BTN_HEIGHT)
	self:SetBackColor(Theme.Color(Theme.Hex.ActiveTab))
	-- Mouse-visible, even though the quickslot on top is what actually fires the post: a hover
	-- that reaches THIS control means the overlay is buried (when it is not, the quickslot eats
	-- the event), so it is both the detector and the fix. See the header note.
	self:SetMouseVisible(true)
	self.MouseEnter = function()
		self:Raise()
		self:Tint(Theme.Hex.Hover, Theme.Hex.Accent200)
	end
	self.MouseLeave = function() self:Refresh() end
	-- Also stops a press on POST reaching the header underneath and starting a window drag.
	self.MouseDown = function() self:Raise() end

	self.label = Turbine.UI.Label()
	self.label:SetParent(self)
	self.label:SetFont(Font.Verdana10)
	self.label:SetSize(BTN_WIDTH, BTN_HEIGHT)
	self.label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	self.label:SetText(ChatPost.PresetCaption(self.preset))
	self.label:SetMouseVisible(false)

	if params.showChannel ~= false then
		self:BuildChannelButton(params.parent)
	end
	self:BuildOverlay()
	self:Refresh()
end

function PostButton:Channel()
	return (_G.settings and _G.settings.postChannel) or ChatPost.Channels[1].key
end

-- Fixed at construction, not read from settings. Which shape this button posts is what the button
-- IS -- see the header note on why that stopped being a mode.
function PostButton:Preset()
	return self.preset
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

	-- Raising the overlay takes keyboard focus off the analysis window, so Frame's own Escape
	-- handler cannot fire while POST is on top. Forward it, or Escape silently stops closing the
	-- window after the first hover.
	self.overlay:SetWantsKeyEvents(true)
	self.overlay.KeyDown = function(sender, args)
		if args.Action == Turbine.UI.Lotro.Action.Escape
			and button.trackWindow ~= nil and button.trackWindow.Close ~= nil then
			button.trackWindow:Close()
		end
	end

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

	-- CombatAnalysis's own quickslot MouseDown forwards to WindowManager.MouseWasPressed, which
	-- ends up back in its Activate() override re-raising the send window (StatOverviewPanel.lua:233
	-- -> StatOverviewWindow.lua:67) -- i.e. the slot stays on top across its own click. Same thing,
	-- one call.
	self.slot.MouseDown = function() button:Raise() end

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
	if self.channel ~= nil then
		self.channel:SetPosition(x + BTN_WIDTH + GAP, top)
	end
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
	-- continuously and Activate() takes keyboard focus. Activate directly rather than through
	-- Raise(), which would come straight back in here.
	if appearing then
		self.overlay:Activate()
	end
end

-- Brings the overlay back above the analysis window. Called from the window's Activated event
-- (however it came to the front), from a hover or press on the themed button underneath, and from
-- the handful of places that show the window explicitly.
--
-- It syncs geometry FIRST. Raise() is often called at the very moment the window becomes visible,
-- before any SyncOverlay has run for that state -- the old version tested self.overlayShown and
-- silently did nothing in exactly that case, leaving the raise to the next heartbeat tick.
function PostButton:Raise()
	self:SyncOverlay(false)
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
	self.line = self.onNeedLine and self.onNeedLine(self.preset) or nil
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
	-- The death button is taken off the header rather than greyed: an always-present DEATH button
	-- that is dead nine fights out of ten teaches people to ignore it, where one that appears only
	-- after a death is itself the report that there was one. The summary button stays visible and
	-- greys, because "nothing to post in this view" is a state worth showing.
	if self.hideWhenDisabled then
		self:SetVisible(self.enabled)
		if self.channel ~= nil then
			self.channel:SetVisible(self.enabled)
		end
		if not self.enabled then
			return
		end
	end

	if self.enabled then
		self:Tint(Theme.Hex.ActiveTab, Theme.Hex.Accent200)
	else
		self:Tint(Theme.Hex.WindowFill, Theme.Hex.Disabled)
	end

	if self.channel ~= nil then
		self.channelLabel:SetText(ChatPost.ChannelShort(self:Channel()))
		self.channelLabel:SetForeColor(Theme.Color(
			self.enabled and Theme.Hex.Accent200 or Theme.Hex.Disabled))
	end
end

---------------------------------------------------------------------------------------------------
-- Channel / preset menu
---------------------------------------------------------------------------------------------------

-- Radio-check pattern from CombatAnalysis/StatOverview/StatOverviewChatMenu.lua, with one
-- difference: the whole menu is rebuilt each time it opens rather than being built once and
-- re-checked. Every check mark in here reflects live settings, and rebuilding is simpler than
-- keeping a long-lived item list in sync with them.
--
-- Two groups, separated: WHERE the post goes (a radio set -- one channel), and WHAT is in it (a
-- check set -- any subset of ChatPost.Parts). Deliberately FLAT rather than a channel submenu plus
-- a parts submenu: nothing in this codebase has ever nested a Turbine.UI.MenuItem, and this whole
-- menu is still on the "not confirmed in-game" list as it is (see the file header). Thirteen flat
-- items is a known quantity; a nested one is a guess.
--
-- A menu item closes the menu when clicked, so switching several parts off means reopening the
-- menu each time. That is the client's behaviour, not a choice here -- and part switching is a
-- set-it-once thing, unlike the channel.
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
			-- The channel is shared by every post button in the header, so one of them changing it
			-- has to re-arm all of them -- an alias is a static string and the verb is baked into
			-- it. `onChanged` is the window's own "re-arm everything" hook.
			button:Changed()
		end
		items:Add(item)
	end

	items:Add(Turbine.UI.MenuItem("-", false, false))

	-- The parts govern the SUMMARY line only (ChatPost.Parts' own comment says why the death report
	-- has none), which is also the only flavour that builds this menu.
	for i = 1, table.getn(ChatPost.Parts) do
		local part = ChatPost.Parts[i]
		local item = Turbine.UI.MenuItem(part.label, true, ChatPost.PartEnabled(part.key))
		item.Click = function()
			ChatPost.SetPartEnabled(part.key, not ChatPost.PartEnabled(part.key))
			Settings.Save()
			button:Changed()
		end
		items:Add(item)
	end

	self.menu = menu
	menu:ShowMenu()
end

-- Something this menu edits is shared with the other buttons in the header. Falls back to re-arming
-- just this one if nobody wired the hook, so the button is never left holding a stale alias.
function PostButton:Changed()
	if self.onChanged ~= nil then
		self.onChanged()
	else
		self:Rebuild()
	end
end
