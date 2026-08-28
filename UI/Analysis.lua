--=================================================================================================
-- Analysis -- window 3, 1080x820 resizable to 1440x880. The post-mortem, per fight and per
-- target. See docs/DESIGN.md "3. Post-combat analysis" and the redesign bundle's
-- REDESIGN_SPEC.md section 7.
--
-- The content column is 848px wide at the minimum window size (1080 - 208 rail - 2x12 padding),
-- which is exactly the width every number in the redesign mock was measured against. Blocks
-- stack: tab strip + goal line (30), picker chips (22 per row, 1-2 rows unless expanded -- see
-- RefreshPicker; every block below shifts down by whatever extra rows claim), 5 KPI cards (50),
-- the graph block
-- (plot + charted buff lanes + range slider + timeline + legend, see UI/AnalysisGraph.lua),
-- the skill table at full content width, then the SELF BUFFS table and the two side panels
-- sharing the bottom row.
--
-- Deliberate deviations from the literal mock numbers, since this is the one window meant to
-- resize:
--  - Every block stretches to fill the available content width instead of being pinned at 848 --
--    a fixed-width graph and table would get no benefit from resizing up to 1440px, which is the
--    whole point of the resize gripper existing on this window and not the other two. Bucket
--    COUNT stays fixed at 48 (docs/IMPLEMENTATION_PLAN.md); bucket width scales instead. The two
--    side panels keep their 233px so the buff table gets every pixel the window gains.
--  - The 5 KPIs are one uniform shape across all four views (rate+total, hits/heals+skill count,
--    crit/dev%, largest+skill, active-or-range time) rather than bespoke per view --
--    docs/DESIGN.md specifies "five KPIs" per view without dictating their exact content.
--
-- EVERYTHING IS RANGE-SCOPED. Dragging either handle on the range slider re-runs a single
-- Session:Slice for the selected seconds, and the KPIs, skill table, both side panels and the
-- buff table are all fed from that one result -- one recount per interaction, not one per
-- widget. A full-fight range takes Slice's aggregate path, so an unscoped window shows exactly
-- the same numbers it did before the slider existed.
--=================================================================================================

Analysis = class(Frame)

local MIN_WIDTH, MIN_HEIGHT = 1080, 600
local MAX_WIDTH = 1440
-- The redesign's own stack (2 lanes charted, 9 skill rows) comes to ~851px, so a new install
-- opens tall enough to show all of it. MIN_HEIGHT stays at 600 for anyone on a short screen --
-- the skill table shrinks and scrolls first, the buff table second.
local DEFAULT_HEIGHT = 820

-- Height used to be capped at a hardcoded 880, which is shorter than the screen this plugin
-- actually runs on -- the cap is the display's own height now, less a margin so the window can
-- never be dragged taller than the screen it lives on. Read through a pcall like every other
-- native read in this codebase, falling back to the old constant; Turbine.UI.Display.GetHeight
-- is confirmed-working precedent (FervourFocus/UI/SettingsPanel.lua, Darf/UI/framework.lua).
local FALLBACK_MAX_HEIGHT = 880
local SCREEN_MARGIN = 40

local function MaxHeight()
	local ok, height = pcall(function() return Turbine.UI.Display.GetHeight() end)
	if ok and type(height) == "number" and height > 0 then
		return math.max(MIN_HEIGHT, height - SCREEN_MARGIN)
	end
	return FALLBACK_MAX_HEIGHT
end

local RAIL_WIDTH = 208
local HEADER_HEIGHT = 32
local TAB_STRIP_HEIGHT = 30
local TAB_WIDTH = 140
local GAP = 11
local PAD = 12
local KPI_ROW_HEIGHT = 50
local PICKER_HEIGHT = 22
-- The picker wraps rather than running off the content column's right edge. Two rows is what it
-- shows unprompted; clicking the trailing "+N more" chip opens it up to PICKER_ROWS_EXPANDED,
-- which at the minimum window width is room for roughly 30 names -- past that the tail (always
-- the smallest contributors, since chips are sorted by total descending) is dropped rather than
-- pushing the graph off the bottom of the window.
local PICKER_ROW_GAP = 4
local PICKER_ROWS_COLLAPSED = 2
local PICKER_ROWS_EXPANDED = 5
local PICKER_CHIP_GAP = 6
local PICKER_MAX_CHARS = 16
local ROW_HEIGHT = 22
local RAIL_ROW_HEIGHT = 34
local PIN_SIZE = 12
local SCROLLBAR_WIDTH = 10
local RAIL_POOL = 20 -- generous: ring cap is 10 but pinned sessions are exempt from it
local PANEL_WIDTH = 233

-- The identity rotation Analysis:Update holds this window at while the graph's rotation pass runs.
-- One shared table because SetRotation reads it and never keeps it.
local ZERO_ROTATION = { x = 0, y = 0, z = 0 }

local BUFF_HEADER_HEIGHT = 26
local BUFF_TABLE_HEADER_HEIGHT = 20
local BUFF_ROW_HEIGHT = 22
local BUFF_POOL = 40 -- generous, matching tableRowPool's 30: the section already scrolls
                      -- (BuildBuffSection's ListBox+ScrollBar) and Layout() already clamps
                      -- bottomHeight to available window space, so this only bounds how many
                      -- distinct buffs can ever be listed, not how many are visible at once.
local MAX_CHARTED = 3

-- Tab order is damage pair then healing pair, so the two views a reader actually compares sit
-- next to each other. This drives tab ORDER only -- VIEW_META, the filter table and the graph's
-- series map are all keyed, never indexed.
local VIEWS = { "done", "taken", "healOut", "healIn" }

local VIEW_META = {
	done = {
		label = "Damage done", question = "Which skills carried it, against whom",
		pickerLabel = "targets", hitWord = "hits", rateWord = "DPS", role = "done",
		shape = "damage", counterpartHeader = "TYPE",
	},
	taken = {
		label = "Damage taken", question = "What hit you, what got through",
		pickerLabel = "sources", hitWord = "hits", rateWord = "DPS", role = "taken",
		shape = "damage", counterpartHeader = "TYPE",
	},
	healOut = {
		label = "Healing done", question = "Self-sustain and group contribution",
		pickerLabel = "recipients", hitWord = "heals", rateWord = "HPS", role = "healOut",
		shape = "heal", counterpartHeader = "TO",
	},
	healIn = {
		label = "Healing taken", question = "Did healers keep pace",
		pickerLabel = "casters", hitWord = "heals", rateWord = "HPS", role = "healIn",
		shape = "heal", counterpartHeader = "FROM",
	},
}

-- A view's series colour, resolved AT CALL TIME from the active palette preset. VIEW_META used
-- to carry a `color` hex read straight out of Theme.Hex, which is a module-level table built once
-- at load -- it could never see the options window's Palette page change anything. Every read of
-- it now goes through here (Constants.lua's Theme.Series).
local function MetaColor(meta)
	return Theme.Series(meta.role)
end

-- Damage-type tints for settings.typeColoredBars (options window, Palette page). These are ROLE
-- colours, not series colours, so they are read straight from Theme.Hex and are deliberately NOT
-- presettable -- a preset changes what "damage taken" looks like, not what "fire" means.
--
-- Only the five types Theme.Hex actually names have a tint. Everything else -- and
-- DamageType.Unknown (13), which covers absorbs and any line with no stated type -- falls back to
-- the view's own series colour rather than being given an invented sixth colour.
local TYPE_HEX = {
	[DamageType.Common]     = Theme.Hex.TypeCommon,
	[DamageType.Beleriand]  = Theme.Hex.TypeBeleriand,
	[DamageType.Fire]       = Theme.Hex.TypeFire,
	[DamageType.Light]      = Theme.Hex.TypeLight,
	[DamageType.Shadow]     = Theme.Hex.TypeShadow,
}

-- Column specs, replacing the old derive-widths-from-header-names approach. Crit and Dev are one
-- CRIT / DEV percentage column now: two separate 60px counter columns were what pushed the
-- `taken` view's 8 columns past its own viewport and clipped TOTAL off the right-hand edge, and
-- percentages are what a reader wants from those two anyway (the raw counters stay separate in
-- the data, per docs/DESIGN.md). MAX and TOTAL are deliberately wide -- a 7-figure comma-formatted
-- number at LucidaConsole12 needs ~80px inside 8px padding, and a clipped total is the one number
-- in this table nobody can afford to lose. `width = nil` means "take whatever is left over".
local COLUMN_SETS = {
	damage = {
		{ key = "skill",   label = "SKILL",      width = nil },
		{ key = "type",    label = nil,          width = 110 },
		{ key = "hits",    label = nil,          width = 58,  numeric = true },
		{ key = "critdev", label = "CRIT / DEV", width = 106, numeric = true },
		{ key = "avoid",   label = "AVOID",      width = 68,  numeric = true },
		{ key = "max",     label = "MAX",        width = 88,  numeric = true },
		{ key = "total",   label = "TOTAL",      width = 104, numeric = true, accent = true },
	},
	heal = {
		{ key = "skill",   label = "SKILL",      width = nil },
		{ key = "type",    label = nil,          width = 156 },
		{ key = "hits",    label = nil,          width = 58,  numeric = true },
		{ key = "critdev", label = "CRIT / DEV", width = 106, numeric = true },
		{ key = "max",     label = "MAX",        width = 88,  numeric = true },
		{ key = "total",   label = "TOTAL",      width = 104, numeric = true, accent = true },
	},
}

local SKILL_COLUMN_MIN = 150
local MAX_TABLE_COLUMNS = 7

-- [chart box 22][icon 24][name 190][type 66][uptime % 98][uptime 90][apps 74][longest gap 106],
-- against the mock's 604 content width (content minus the two side panels and their gap). TYPE
-- is not in the mock -- it arrived with tracking every effect rather than only buffs, since
-- "Wound" and "Writ of Health" in one list need telling apart -- so its 66px comes out of the
-- name column, which is the one that absorbs slack in LayoutBuffColumns either way.
--
-- `sortable` marks the six real data columns; the checkbox and icon gutters are not data and
-- get no click target (the EFFECT header already spans the icon column, so clicking there sorts
-- by name).
local BUFF_COLUMNS = {
	{ key = "check", width = 22,  label = "" },
	{ key = "icon",  width = 24,  label = "" },
	{ key = "name",  width = 190, label = "EFFECT",                     sortable = true },
	{ key = "kind",  width = 66,  label = "TYPE",                       sortable = true },
	{ key = "pct",   width = 98,  label = "UPTIME %",    numeric = true, sortable = true },
	{ key = "up",    width = 90,  label = "UPTIME",      numeric = true, sortable = true },
	{ key = "apps",  width = 74,  label = "APPS",        numeric = true, sortable = true },
	{ key = "gap",   width = 106, label = "LONGEST GAP", numeric = true, sortable = true },
}

-- What the TYPE column shows, and what the buff search box matches against. Keyed by
-- Buffs.Kind.*; anything unrecognised falls back to the Unknown row, so a future kind can never
-- render as an empty cell. "Unknown" is a real, honest state here -- see Buffs.Kinds' own note.
local BUFF_KIND_TEXT = {
	[Buffs.Kind.Buff]    = "Buff",
	[Buffs.Kind.Debuff]  = "Debuff",
	[Buffs.Kind.Unknown] = "Unknown",
}
local BUFF_KIND_HEX = {
	[Buffs.Kind.Buff]    = Theme.Hex.HealingTaken,
	[Buffs.Kind.Debuff]  = Theme.Hex.DamageTaken,
	[Buffs.Kind.Unknown] = Theme.Hex.DimText,
}

local function BuffKindText(row)
	return BUFF_KIND_TEXT[row.kind] or BUFF_KIND_TEXT[Buffs.Kind.Unknown]
end

-- Appended to the header text of whichever column the table is currently sorted by. ASCII, not
-- the mock's Unicode triangles -- the session rail's pin diamonds already proved this (this
-- client's fonts render U+25B4/25BE as "?").
local SORT_ASC = " ^"
local SORT_DESC = " v"

local BUFF_GOOD_UPTIME = 0.75
local BUFF_POOR_UPTIME = 0.35
local BUFF_LONG_GAP = 12 -- seconds

local AVOID_NAMES = {
	[AvoidType.Missed] = "Missed", [AvoidType.Immune] = "Immune", [AvoidType.Resisted] = "Resisted",
	[AvoidType.Blocked] = "Blocked", [AvoidType.Parried] = "Parried", [AvoidType.Evaded] = "Evaded",
	[AvoidType.Deflected] = "Deflected",
}

-- Search box geometry, shared by the skill table and the buff table.
local SEARCH_HEIGHT = 20
local SEARCH_WIDTH = 190
local SEARCH_ICON = 16

-- The draggable split between the skill table and the bottom row (SELF BUFFS + the two side
-- panels). BOTTOM_MIN is the bottom row's own chrome -- section header, search box, column
-- header -- with no buff rows showing at all; everything above that is whole buff rows, which
-- is what a drag snaps to. Same reasoning as RangeSlider snapping to bucket stops rather than
-- pixels: it keeps the row grid aligned and bounds how many distinct splits one drag can ask
-- Layout() for. TABLE_MIN is the skill table's own floor, so the splitter can never be dragged
-- far enough down to leave no skill rows at all.
local BOTTOM_MIN = BUFF_HEADER_HEIGHT + 1 + SEARCH_HEIGHT + BUFF_TABLE_HEADER_HEIGHT
local DEFAULT_SPLIT = BOTTOM_MIN + 6 * BUFF_ROW_HEIGHT
local TABLE_MIN = SEARCH_HEIGHT + ROW_HEIGHT * 3
local SPLITTER_HEIGHT = GAP -- the band between the two blocks, which the handle now occupies
local SPLITTER_GRIP = 2     -- the visible rule inside it

-- Plain substring match, case-insensitive -- `string.find(..., true)` (plain mode) so a name
-- with pattern-magic characters in it (unlikely in a skill/buff name, but free to guard) can't
-- break the search.
local function MatchesFilter(text, query)
	if query == nil or query == "" then
		return true
	end
	return string.find(string.lower(text or ""), string.lower(query), 1, true) ~= nil
end

---------------------------------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------------------------------

function Analysis:Constructor()
	Frame.Constructor(self, {
		-- Version rendered dim via an inline <rgb=> tag, not a second Label/Font -- matches
		-- Gibberish3's own title-bar version text (OPTIONS2/WINDOW/BaseWindow.lua's
		-- _RefreshTexts, "Brand  <rgb=#5C6076>3.8.0</rgb>"), the only confirmed-working
		-- precedent anywhere in these plugins for a de-emphasized run of text inside one
		-- Turbine.UI.Label. Uses Theme.Hex.DimText rather than Gibberish's own hex so it stays
		-- inside Basil's own palette.
		key = "analysis", closable = true,
		title = "Basil  <rgb=" .. Theme.Hex.DimText .. ">" .. Basil.Version .. "</rgb>",
		width = MIN_WIDTH, height = DEFAULT_HEIGHT, headerHeight = HEADER_HEIGHT,
	})

	self.viewTab = "done"
	self.filter = { done = nil, taken = nil, healOut = nil, healIn = nil }
	self.selectedSession = nil

	-- Search text for the skill table and the buff table, independent of each other and of the
	-- target/source picker filter above -- not persisted, same as viewTab/filter (ephemeral UI
	-- state, resets to blank when the window is next built).
	self.tableFilterText = ""
	self.buffFilterText = ""

	-- Column sort, one state per table, also ephemeral. The defaults reproduce exactly what
	-- each table used to hardcode: the skill table by TOTAL descending, the buff table by
	-- UPTIME % ascending (Buffs.Stats' own "worst uptime first" order -- see Buffs.lua).
	self.tableSort = { key = "total", ascending = false }
	self.buffSort = { key = "pct", ascending = true }

	self.bucketCount = GraphBucketCount()
	self.rangeFrom = 1
	self.rangeTo = self.bucketCount

	-- Restored from settings, then re-validated against whatever buffs the selected session
	-- actually has (a name list is safe to persist; a Turbine.UI.Color never is -- Settings.lua).
	self.charted = {}
	local savedCharted = _G.settings.chartedBuffs
	if type(savedCharted) == "table" then
		for i = 1, table.getn(savedCharted) do
			if i <= MAX_CHARTED and type(savedCharted[i]) == "string" then
				self.charted[table.getn(self.charted) + 1] = savedCharted[i]
			end
		end
	end
	-- How much height the bottom row (SELF BUFFS + the two side panels) gets; the skill table
	-- takes what is left. The user drags the splitter between them to change it, so it is a real
	-- persisted preference rather than something derived from how many buffs a fight tracked.
	-- Overwritten below if this window has a saved split. Snapped to whole buff rows -- see
	-- SnapSplit.
	self.splitBottom = DEFAULT_SPLIT

	-- What the last Layout() sized the variable-height blocks for. RefreshContent compares
	-- against these and re-runs Layout only when the shape actually changed, which is what stops
	-- the two from calling each other forever. The buff table is no longer in this set: its
	-- height is the splitter's now, not its row count's, so listing more buffs only ever means
	-- more scrolling, never a re-layout.
	self.layoutLanes = -1
	self.layoutPickerRows = -1
	self.laneCountWanted = 0
	self.pickerRowsWanted = 1

	-- Whether the picker is showing every chip or just the first two rows' worth. Ephemeral like
	-- viewTab/filter, and reset whenever the view or session changes -- "show me all 14 sources"
	-- is an answer to one question, not a standing preference.
	self.pickerExpanded = false

	self:BuildHeaderExtras()
	self:BuildSessionRail()
	self:BuildContentArea()
	self:BuildResizeGripper()

	-- Adopt whatever the manager already has. Sessions.OnClosed only fires for fights that
	-- close AFTER this window exists, so without this the window would sit empty for anything
	-- already in the ring -- which is exactly the state a /plugins refresh mid-session leaves.
	self.selectedSession = Sessions.selected or Sessions.list[1]

	local saved = _G.settings.windows[self.windowKey]
	if saved ~= nil and saved.width ~= nil and saved.height ~= nil then
		-- Re-clamped rather than restored verbatim: a size saved on a bigger screen (or before
		-- the cap moved) must not open taller than the display it is being restored onto.
		local w = math.max(MIN_WIDTH, math.min(MAX_WIDTH, saved.width))
		local h = math.max(MIN_HEIGHT, math.min(MaxHeight(), saved.height))
		self:Resize(w, h)
	end
	if saved ~= nil and type(saved.split) == "number" then
		self.splitBottom = saved.split
	end

	-- SelectView before Layout: it only needs self.viewTab/self.filter (already set above) and
	-- tolerates self.graph not existing yet (Layout's LayoutGraph creates it). Layout runs last
	-- so its own trailing RefreshContent() is the one that sees real, non-zero widths.
	self:SelectView("done", true)
	self:Layout()

	local window = self
	Sessions.OnClosed(function(s) window:OnSessionsChanged(s) end)

	-- Permanently on, and deliberately not armed and disarmed around each redraw. The graph's
	-- rotation pass has to run after ANY path that reaches Graph:Redraw, and those are not all
	-- inside this file -- the legend's own swatches call Graph:ToggleSeries directly, for one. An
	-- arm-per-caller scheme would grow exactly the "a thing exists but nothing triggers it" bug
	-- this codebase has already collected several of. Update below is a nil check and one call
	-- that returns immediately when there is nothing pending.
	self:SetWantsUpdates(true)

	self:SetVisible(false)
end

function Analysis:OnSessionsChanged(newSession)
	if self.selectedSession == nil then
		self.selectedSession = newSession
		self:ResetRange()
	end
	self:RefreshRail()
	if self.selectedSession == newSession then
		self:RefreshContent()
	end
end

---------------------------------------------------------------------------------------------------
-- Header extras: the range chip and RESET RANGE
---------------------------------------------------------------------------------------------------

-- Both live in Frame's own header bar, to the left of the close glyph. The chip states what the
-- window is currently showing, which matters most exactly when it is NOT showing the whole fight
-- -- an unnoticed range would make every number on screen quietly wrong to a reader who looked
-- away and back.
function Analysis:BuildHeaderExtras()
	self.rangeChip = Turbine.UI.Label()
	self.rangeChip:SetParent(self.header)
	self.rangeChip:SetFont(Font.LucidaConsole12)
	self.rangeChip:SetForeColor(Theme.Color(Theme.Hex.DimText))
	self.rangeChip:SetSize(220, HEADER_HEIGHT)
	self.rangeChip:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
	self.rangeChip:SetMouseVisible(false)

	local button = Turbine.UI.Label()
	button:SetParent(self.header)
	button:SetFont(Font.Verdana10)
	button:SetText("RESET RANGE")
	button:SetForeColor(Theme.Color(Theme.Hex.Disabled))
	button:SetSize(90, HEADER_HEIGHT)
	button:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)

	local window = self
	button.MouseClick = function()
		if not window:IsFullRange() then
			window:ResetRange()
			window:RefreshContent()
		end
	end
	button.MouseEnter = function()
		if not window:IsFullRange() then
			button:SetForeColor(Theme.Color(Theme.Hex.Accent200))
		end
	end
	button.MouseLeave = function() window:RefreshHeaderExtras() end

	self.resetButton = button

	-- The title label was sized by Frame to run the full width; pull it in so it cannot collide
	-- with the chip.
	if self.titleLabel ~= nil then
		self.titleLabel:SetSize(200, HEADER_HEIGHT)
	end

	self:BuildPostButton()

	self:LayoutHeaderExtras()
end

-- The post buttons read the window's live state at rebuild time through this closure rather than
-- being handed a snapshot, so they can never post numbers from a previous refresh. See
-- UI/PostButton.lua for why a click is unavoidable and ChatPost.lua for the text itself.
--
-- TWO buttons, one per post shape: POST (fight summary, always present, greys when the current
-- view has nothing to say) and DEATH (death report, present only while the selected fight ended in
-- one -- ChatPost.BuildLine returns nil for the death preset otherwise, which is what takes the
-- button off the header). They share the channel, and only POST carries the control that sets it.
function Analysis:BuildPostButton()
	local window = self

	-- BuildLine, not Build: what a channel accepts is one plain line (see ChatPost's header).
	local function LineFor(preset)
		local session = window.selectedSession
		if session == nil then
			return nil
		end
		local fromSec, toSec = window:RangeSeconds()
		return ChatPost.BuildLine(session, preset, window.viewTab,
			window.filter[window.viewTab], fromSec, toSec)
	end

	self.postButton = PostButton({
		parent = self.header,
		headerHeight = HEADER_HEIGHT,
		preset = "summary",
		showChannel = true,
		onNeedLine = LineFor,
	})

	self.deathButton = PostButton({
		parent = self.header,
		headerHeight = HEADER_HEIGHT,
		preset = "death",
		showChannel = false,
		hideWhenDisabled = true,
		onNeedLine = LineFor,
	})

	-- The channel and the summary parts both live on POST's menu and both change what DEATH would
	-- send (the channel bakes the slash verb into the alias), so one edit re-arms both buttons.
	self.postButton.onChanged = function()
		window:RearmPostButtons()
	end

	-- The quickslot lives in its own top-level window positioned in screen coordinates, so it has
	-- to follow this window rather than being a child of it.
	self.postButton:Track(self)
	self.deathButton:Track(self)

	-- Fired by Frame's header drag on every MouseMove, so the invisible click targets stay glued
	-- to the visible buttons while the window is being dragged.
	self.OnMoved = function()
		window:SyncPostOverlay(true)
	end

	-- Anything that brings this window to the front buries the overlays, so put them back on top in
	-- the same gesture. This is CombatAnalysis's StatOverviewWindow:Activate() override
	-- (StatOverviewWindow.lua:56-68), hooked to the real `Activated` event instead of an override:
	-- the client raises the window itself on a click, without routing through any method call
	-- here, and mouse events do not bubble, so the window's own MouseDown only sees presses that
	-- miss every child. The event sees them all. See UI/PostButton.lua's header for the full story.
	--
	-- Both overlays are raised, and the order does not matter: they never overlap each other (they
	-- sit at different x in the header), so all that has to hold is that each ends up above this
	-- window -- raising one brings it to the front without pushing the other back down past it.
	self.Activated = function()
		window:RaisePostButtons()
	end

	-- Kept as well: a press that lands on the window's own bare area. Harmless overlap, and it is
	-- the one path that still works if `Activated` turns out not to fire the way Thurallor's use
	-- of it implies.
	self.MouseDown = function()
		window:RaisePostButtons()
	end
end

-- The three fan-outs over both post buttons. They exist as methods rather than being inlined
-- because Main.lua, Events.lua and Frame's drag handler all reach one of them from outside.
function Analysis:RaisePostButtons()
	if self.postButton ~= nil then self.postButton:Raise() end
	if self.deathButton ~= nil then self.deathButton:Raise() end
end

function Analysis:RearmPostButtons()
	if self.postButton ~= nil then self.postButton:Rebuild() end
	if self.deathButton ~= nil then self.deathButton:Rebuild() end
end

function Analysis:ShutdownPostButtons()
	if self.postButton ~= nil then self.postButton:Shutdown() end
	if self.deathButton ~= nil then self.deathButton:Shutdown() end
end

function Analysis:LayoutHeaderExtras()
	local width = select(1, self:GetSize())
	self.resetButton:SetPosition(width - 22 - 96, 0)
	self.rangeChip:SetPosition(width - 22 - 96 - 6 - 220, 0)

	if self.postButton ~= nil then
		-- Place() moves the themed button, the channel button and the overlay together.
		local postX = width - 22 - 96 - 6 - 220 - 6 - PostButton.Width
		self.postButton:Place(postX, 0)
		-- DEATH sits to POST's left, so the POST/channel pair stays anchored at the same x whether
		-- or not the fight had a death -- a header whose buttons shuffle sideways between sessions
		-- would be worse than one with an occasional gap in it. The slot is reserved either way;
		-- when there was no death it is simply empty header.
		if self.deathButton ~= nil then
			self.deathButton:Place(postX - 6 - PostButton.SoloWidth, 0)
		end
	end
end

function Analysis:RefreshHeaderExtras()
	local full = self:IsFullRange()
	local session = self.selectedSession

	if session == nil then
		self.rangeChip:SetText("")
	elseif full then
		self.rangeChip:SetText("FULL FIGHT · " .. Format.Clock(session:Duration()))
	else
		local fromSec, toSec = self:RangeSeconds()
		self.rangeChip:SetText("RANGE " .. Format.Clock(fromSec) .. " - " .. Format.Clock(toSec)
			.. " · " .. math.floor(toSec - fromSec + 0.5) .. "s")
	end

	self.rangeChip:SetForeColor(Theme.Color(full and Theme.Hex.DimText or Theme.Hex.Accent300))
	self.resetButton:SetForeColor(Theme.Color(full and Theme.Hex.Disabled or Theme.Hex.Accent200))
end

-- Chrome resize plus the two header widgets Frame knows nothing about, and the gripper.
function Analysis:Resize(width, height)
	Frame.Resize(self, width, height)
	if self.titleLabel ~= nil then
		self.titleLabel:SetSize(200, HEADER_HEIGHT)
	end
	if self.resetButton ~= nil then
		self:LayoutHeaderExtras()
	end
	-- The gripper has to follow the corner on EVERY resize, not just in Layout(): a drag reads
	-- mouse coordinates relative to the gripper, so leaving it behind while the window grows
	-- makes every move event re-apply the whole offset from the press point. See the long note
	-- in BuildResizeGripper.
	if self.gripper ~= nil then
		self.gripper:SetPosition(width - 12, height - 12)
	end
	-- Same reasoning as the gripper: the post buttons' overlays are positioned in screen
	-- coordinates, so they must be re-placed on every resize, not only when Layout() runs.
	self:SyncPostOverlay(true)
end

-- Each overlay quickslot is a separate top-level Window, so it does not inherit this window's
-- position, size or visibility. Called from the drag handler and the resize path (instant) and
-- from Events.lua's 4Hz heartbeat (the backstop for show/hide, which happens from several places).
function Analysis:SyncPostOverlay(force)
	if self.postButton ~= nil then
		self.postButton:SyncOverlay(force)
	end
	if self.deathButton ~= nil then
		self.deathButton:SyncOverlay(force)
	end
end

---------------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------------

-- Re-reads everything this window takes from _G.settings and repaints. Nothing here rebuilds a
-- Control: the palette, the number font, the graph's bucket width and the charted-buff set all
-- flow through the refresh path that already exists.
--
-- The palette needs one extra step. RefreshContent only re-declares the graph's series when the
-- VIEW changes (SetSeries clears the hidden set, so doing it every refresh would silently un-hide
-- a series the reader toggled off) -- which means a preset change alone would leave the plot on
-- its old colours. Clearing graphSeriesView forces exactly one re-declaration.
function Analysis:ApplySettings()
	self.graphSeriesView = nil

	if self.graph ~= nil then
		self.graph:ApplySettings()
	end

	self:AdoptChartedBuffs(true)
	self:ApplyBorders()
	self:Layout()
end

-- Re-reads settings.chartedBuffs into self.charted. Called when the options window's buff picker
-- writes it -- the two surfaces edit the same list, and the analysis window caches it. `quiet`
-- suppresses the refresh for callers that are about to do a full Layout anyway.
function Analysis:AdoptChartedBuffs(quiet)
	self.charted = {}
	local saved = _G.settings.chartedBuffs
	if type(saved) == "table" then
		for i = 1, table.getn(saved) do
			if i <= MAX_CHARTED and type(saved[i]) == "string" then
				self.charted[table.getn(self.charted) + 1] = saved[i]
			end
		end
	end

	if not quiet then
		self:RefreshContent()
	end
end

-- Sessions.DropUnpinned / Sessions.ClearAll removed sessions out from under this window.
function Analysis:OnSessionsDropped()
	local kept = self.selectedSession
	local stillThere = false
	for i = 1, table.getn(Sessions.list) do
		if Sessions.list[i] == kept then
			stillThere = true
			break
		end
	end

	if not stillThere then
		self.selectedSession = Sessions.current or Sessions.list[1]
		self:ResetRange()
	end

	self:RefreshRail()
	self:RefreshContent()
end

-- Back to the shipped size and position, for /basil reset.
function Analysis:ResetGeometry()
	self:Resize(MIN_WIDTH, DEFAULT_HEIGHT)
	self:SetPosition(200, 200)
	self.splitBottom = DEFAULT_SPLIT
	self:Layout()
end

---------------------------------------------------------------------------------------------------
-- Range
---------------------------------------------------------------------------------------------------

function Analysis:IsFullRange()
	return self.rangeFrom == 1 and self.rangeTo == self.bucketCount
end

-- Bucket stops -> real seconds into the fight. Returns nil, nil for the whole fight, which is
-- Session:Slice's signal to take its aggregate path -- so an unscoped window is provably showing
-- the same numbers it always did rather than a re-count that might disagree at the edges.
function Analysis:RangeSeconds()
	local session = self.selectedSession
	if session == nil or self:IsFullRange() then
		return nil, nil
	end

	local duration = session:Duration()
	if duration <= 0 then
		return nil, nil
	end

	local span = self.bucketCount - 1
	local fromSec = math.floor((self.rangeFrom - 1) / span * duration)
	local toSec = math.ceil((self.rangeTo - 1) / span * duration)
	if toSec <= fromSec then
		toSec = fromSec + 1
	end
	return fromSec, toSec
end

-- The plot's bucket count is not a constant any more: settings.bucketWidth (options window,
-- Sessions page) can pin a bucket to 1 or 2 real seconds, which for a short fight means fewer
-- than the pool's 48. It therefore depends on the SELECTED SESSION and has to be re-derived
-- whenever that or the setting changes -- the range is clamped rather than reset, so narrowing
-- the plot keeps as much of the reader's selection as still exists.
--
-- self.bucketCount and the Graph's own self.buckets are computed from the same function on the
-- same session, so they always agree; if they ever did not, the range slider's stops and the
-- seconds RangeSeconds() hands to Session:Slice would silently disagree with the plot.
function Analysis:SyncBucketCount()
	local count = GraphBucketCount(self.selectedSession)
	if count == self.bucketCount then
		return false
	end

	self.bucketCount = count
	if self.rangeTo > count then
		self.rangeTo = count
	end
	if self.rangeFrom >= self.rangeTo then
		self.rangeFrom = math.max(1, self.rangeTo - 1)
	end
	return true
end

function Analysis:ResetRange()
	self:SyncBucketCount()
	self.rangeFrom = 1
	self.rangeTo = self.bucketCount
	if self.graph ~= nil then
		self.graph:SetRange(self.rangeFrom, self.rangeTo)
	end
end

function Analysis:OnRangeChanged(from, to)
	self.rangeFrom = from
	self.rangeTo = to
	self:RefreshContent()
end

---------------------------------------------------------------------------------------------------
-- Session rail
---------------------------------------------------------------------------------------------------

function Analysis:BuildSessionRail()
	self.rail = Turbine.UI.Control()
	self.rail:SetParent(self.client)
	self.rail:SetPosition(0, 0)
	self.rail:SetBackColor(Theme.Color(Theme.Hex.RailFill))
	self.rail:SetMouseVisible(false)

	self.railBorder = Turbine.UI.Control()
	self.railBorder:SetParent(self.client)
	self.railBorder:SetBackColor(Theme.Color(Theme.Hex.Border))
	self.railBorder:SetMouseVisible(false)

	self.railRows = {}
	for i = 1, RAIL_POOL do
		self.railRows[i] = self:BuildSessionRow()
	end

	self:RefreshRail()
end

function Analysis:BuildSessionRow()
	local row = Turbine.UI.Control()
	row:SetParent(self.rail)
	row:SetSize(RAIL_WIDTH, RAIL_ROW_HEIGHT)
	row:SetBackColor(Theme.Color(Theme.Hex.RailFill))
	row:SetVisible(false)

	local leftBorder = Turbine.UI.Control()
	leftBorder:SetParent(row)
	leftBorder:SetPosition(0, 0)
	leftBorder:SetSize(0, RAIL_ROW_HEIGHT)
	leftBorder:SetMouseVisible(false)

	-- Pin glyph: a real icon, not a text glyph -- the Unicode diamonds (U+25C6/25C7) the mockup
	-- uses aren't in this client's fonts and render as "?" (docs/DESIGN.md / CLAUDE.md "Build
	-- status"). Resources/pin_on.tga / pin_off.tga (Phosphor "push-pin-simple", fill/regular,
	-- 12x12 -- see Resources/ICONS.md) swap by state, same technique as Gibberish3's own pin
	-- toggle (OPTIONS2/WINDOW/LIBRARY/LibraryItem.lua): BlendMode.Overlay over the row's own
	-- themed fill, no colour baked into the asset.
	local pin = Turbine.UI.Control()
	pin:SetParent(row)
	pin:SetPosition(8, math.floor((RAIL_ROW_HEIGHT - PIN_SIZE) / 2))
	pin:SetSize(PIN_SIZE, PIN_SIZE)
	pin:SetBlendMode(Turbine.UI.BlendMode.Overlay)
	pin:SetMouseVisible(true)

	local name = Turbine.UI.Label()
	name:SetParent(row)
	name:SetFont(Font.Verdana12)
	name:SetForeColor(Theme.Color(Theme.Hex.Text))
	name:SetPosition(24, 2)
	name:SetSize(RAIL_WIDTH - 32, 16)
	name:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	name:SetMouseVisible(false)

	local meta = Turbine.UI.Label()
	meta:SetParent(row)
	meta:SetFont(Font.LucidaConsole12)
	meta:SetForeColor(Theme.Color(Theme.Hex.DimText))
	meta:SetPosition(24, 18)
	meta:SetSize(RAIL_WIDTH - 32, 14)
	meta:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	meta:SetMouseVisible(false)

	local widgets = { control = row, leftBorder = leftBorder, pin = pin, name = name, meta = meta, session = nil }

	local window = self
	row.MouseClick = function() window:SelectSession(widgets.session) end
	row.MouseEnter = function()
		if widgets.session ~= window.selectedSession then
			row:SetBackColor(Theme.Mix(Theme.Hex.Accent, Theme.Hex.RailFill, 0.05))
		end
	end
	row.MouseLeave = function() window:RefreshRailRow(widgets) end
	pin.MouseClick = function()
		if widgets.session ~= nil then
			Sessions.TogglePin(widgets.session)
			window:RefreshRail()
		end
	end

	return widgets
end

function Analysis:SortedSessions()
	local pinned, normal = {}, {}
	for i = 1, table.getn(Sessions.list) do
		local s = Sessions.list[i]
		if s.pinned then
			table.insert(pinned, s)
		else
			table.insert(normal, s)
		end
	end
	for i = 1, table.getn(normal) do
		table.insert(pinned, normal[i])
	end
	return pinned
end

function Analysis:RefreshRail()
	local sessions = self:SortedSessions()

	for i = 1, RAIL_POOL do
		local widgets = self.railRows[i]
		local s = sessions[i]
		widgets.session = s

		if s == nil then
			widgets.control:SetVisible(false)
		else
			widgets.control:SetVisible(true)
			widgets.control:SetPosition(0, (i - 1) * RAIL_ROW_HEIGHT)
			widgets.name:SetText(s:DisplayName() .. (s.died and " · died" or ""))
			widgets.meta:SetText(s.startClock .. " · " .. Format.Clock(s:Duration()) .. " · " .. Format.Rate(s:Rate("done")))
			widgets.pin:SetBackground(s.pinned and "Basil/Resources/pin_on.tga" or "Basil/Resources/pin_off.tga")
			self:RefreshRailRow(widgets)
		end
	end
end

function Analysis:RefreshRailRow(widgets)
	local s = widgets.session
	if s == nil then
		return
	end
	local selected = (s == self.selectedSession)

	widgets.control:SetBackColor(selected and Theme.Mix(Theme.Hex.Accent, Theme.Hex.RailFill, 0.11) or Theme.Color(Theme.Hex.RailFill))
	if selected then
		widgets.leftBorder:SetBackColor(Theme.Color(Theme.Hex.Accent))
		widgets.leftBorder:SetSize(2, RAIL_ROW_HEIGHT)
	elseif s.pinned then
		widgets.leftBorder:SetBackColor(Theme.Color(Theme.Hex.Accent700))
		widgets.leftBorder:SetSize(2, RAIL_ROW_HEIGHT)
	else
		widgets.leftBorder:SetSize(0, RAIL_ROW_HEIGHT)
	end
end

-- Selecting a session always resets the range to the full fight: the bucket COUNT is the same
-- for every session but the seconds behind each stop are not, so carrying a range across would
-- silently mean a different slice of a different fight.
function Analysis:SelectSession(session)
	if session == nil then
		return
	end
	self.selectedSession = session
	self.pickerExpanded = false
	self:ResetRange()
	self:RefreshRail()
	self:RefreshContent()
end

---------------------------------------------------------------------------------------------------
-- Content area: tab strip, goal line, picker, KPI row, graph, table, buff section, side panels
---------------------------------------------------------------------------------------------------

function Analysis:BuildContentArea()
	self.contentArea = Turbine.UI.Control()
	self.contentArea:SetParent(self.client)
	self.contentArea:SetMouseVisible(false)

	self:BuildTabStrip()
	self:BuildGoalLine()
	self:BuildPicker()
	self:BuildKpiRow()
	self:BuildGraphArea()
	self:BuildTable()
	self:BuildSplitter()
	self:BuildBuffSection()
	self:BuildPanels()
end

function Analysis:BuildTabStrip()
	self.viewTabs = {}
	local x = PAD
	local window = self

	for i = 1, table.getn(VIEWS) do
		local key = VIEWS[i]
		local meta = VIEW_META[key]

		local tab = Turbine.UI.Control()
		tab:SetParent(self.contentArea)
		tab:SetPosition(x, 0)
		tab:SetSize(TAB_WIDTH, TAB_STRIP_HEIGHT)
		tab:SetBackColor(Theme.Color(Theme.Hex.WindowFill))

		-- Centred in its cell, not flush left: four equal 140px cells read as a tab strip only
		-- when their labels are centred in them.
		local label = Turbine.UI.Label()
		label:SetParent(tab)
		label:SetFont(Font.Verdana12)
		label:SetText(meta.label)
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetPosition(0, 0)
		label:SetSize(TAB_WIDTH, TAB_STRIP_HEIGHT - 2)
		label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
		label:SetMouseVisible(false)

		local underline = Turbine.UI.Control()
		underline:SetParent(tab)
		underline:SetPosition(0, TAB_STRIP_HEIGHT - 2)
		underline:SetSize(TAB_WIDTH, 2)
		underline:SetMouseVisible(false)

		tab.MouseClick = function() window:SelectView(key) end
		tab.MouseEnter = function()
			if window.viewTab ~= key then
				tab:SetBackColor(Theme.Color(Theme.Hex.Hover))
			end
		end
		tab.MouseLeave = function()
			if window.viewTab ~= key then
				tab:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
			end
		end

		self.viewTabs[key] = { control = tab, label = label, underline = underline }
		x = x + TAB_WIDTH
	end
end

-- The goal line shares the tab strip's row now, right-aligned in whatever the tabs leave over,
-- with a 1px rule under it that continues the inactive tabs' baseline across to the window edge.
function Analysis:BuildGoalLine()
	self.goalLine = Turbine.UI.Label()
	self.goalLine:SetParent(self.contentArea)
	self.goalLine:SetFont(Font.Verdana10)
	self.goalLine:SetForeColor(Theme.Color(Theme.Hex.DimText))
	self.goalLine:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
	self.goalLine:SetMouseVisible(false)

	self.goalRule = Turbine.UI.Control()
	self.goalRule:SetParent(self.contentArea)
	self.goalRule:SetBackColor(Theme.Color(Theme.Hex.Border))
	self.goalRule:SetMouseVisible(false)
end

-- Picker chips are rebuilt on session/view change (a handful of controls, not a hot path) since
-- the distinct-name set differs per session and view. Width is a rough per-character estimate --
-- Turbine.UI exposes no text-measurement call used anywhere in this codebase.
--
-- The chip set is deliberately SESSION-wide, not range-scoped: a chip vanishing mid-drag because
-- that target happened not to be hit inside the current range would be the opposite of useful.
function Analysis:BuildPicker()
	self.pickerRow = Turbine.UI.Control()
	self.pickerRow:SetParent(self.contentArea)
	self.pickerRow:SetMouseVisible(false)
	self.pickerChips = {}
end

-- Both of these are UTF-8-aware character counts rather than byte counts -- see Format.CharCount /
-- Format.Truncate in Constants.lua for why. They used to be hand-written here; ChatPost.lua needs
-- the identical logic for its line-length cap, so it moved to Format and these are thin wrappers
-- rather than a second copy that drifts.
local function TruncateChip(text)
	return Format.Truncate(text, PICKER_MAX_CHARS)
end

local function ChipWidth(text)
	return 16 + Format.CharCount(text) * 7
end

-- Greedy left-to-right flow into at most `maxRows` rows, `reserve` px kept free at the end of the
-- last row for the "+N more"/"less" chip. Returns one { x, row, w } per chip that fit, how many
-- did not, and where the last row left off (so the trailing chip can be placed there).
--
-- A chip wider than the whole row is placed anyway rather than dropped -- a clipped name is still
-- clickable and still says which target it is; a missing one is just gone.
local function FlowChips(labels, width, maxRows, reserve)
	local placed = {}
	local x, row = 0, 1
	for i = 1, table.getn(labels) do
		local w = ChipWidth(labels[i])
		local limit = width
		if row == maxRows then limit = width - reserve end

		if x > 0 and x + w > limit then
			if row >= maxRows then
				return placed, table.getn(labels) - (i - 1), x, row
			end
			row = row + 1
			x = 0
		end

		placed[i] = { x = x, row = row, w = w }
		x = x + w + PICKER_CHIP_GAP
	end
	return placed, 0, x, row
end

function Analysis:RefreshPicker()
	for i = 1, table.getn(self.pickerChips) do
		self.pickerChips[i].control:SetVisible(false)
		self.pickerChips[i].isMore = false
	end

	self.pickerRowsWanted = 1

	local session = self.selectedSession
	if session == nil then
		return
	end

	local meta = VIEW_META[self.viewTab]
	local names = {}
	local totals = {}
	for _, row in pairs(session.agg[self.viewTab]) do
		if not totals[row.who] then
			table.insert(names, row.who)
		end
		totals[row.who] = (totals[row.who] or 0) + row.total
	end
	table.sort(names, function(a, b) return totals[a] > totals[b] end)

	-- Built with direct indexing, not table.insert -- `values[1]` is a deliberate nil (the "All
	-- X" chip's filter value), and table.insert(t, v) on a table whose length is ambiguous
	-- because of a leading nil hole silently overwrites that slot instead of appending after
	-- it (confirmed live: it shifted every chip's filter value one position off from its
	-- label, so clicking a chip filtered by a *different* target than the one shown).
	-- The label is what the chip shows (truncated to fit); the value is the real, untruncated name
	-- the filter matches on. They are deliberately separate -- filtering by a shortened name would
	-- match nothing at all.
	local labels = { "All " .. meta.pickerLabel }
	local values = {}
	for i = 1, table.getn(names) do
		labels[i + 1] = TruncateChip(names[i])
		values[i + 1] = names[i]
	end

	local width = self.pickerWidth or (MIN_WIDTH - RAIL_WIDTH - PAD * 2)
	local maxRows = self.pickerExpanded and PICKER_ROWS_EXPANDED or PICKER_ROWS_COLLAPSED

	-- Flow once to find out whether everything fits; if it does not, flow again with room kept for
	-- the trailing chip. The reserve is sized off the total name count, so it is always at least as
	-- wide as the "+N more" the second pass ends up needing -- one re-flow, never a loop.
	local placed, overflow, endX, endRow = FlowChips(labels, width, maxRows, 0)
	local wantsTrailing = (overflow > 0) or self.pickerExpanded
	if wantsTrailing then
		local reserve = ChipWidth("+" .. table.getn(names) .. " more") + PICKER_CHIP_GAP
		placed, overflow, endX, endRow = FlowChips(labels, width, maxRows, reserve)
	end

	local rows = 1
	local count = table.getn(placed)
	for i = 1, count do
		local p = placed[i]
		if p.row > rows then rows = p.row end
		self:PlaceChip(i, labels[i], values[i], p.x, p.row, p.w, false)
	end

	-- Trailing chip: "+N more" opens the picker up, "less" folds it back. Expanded shows "less"
	-- even when nothing overflowed, so there is always a way back out of the taller layout.
	if wantsTrailing then
		local text = (overflow > 0) and ("+" .. overflow .. " more") or "less"
		if endRow > rows then rows = endRow end
		self:PlaceChip(count + 1, text, nil, endX, endRow, ChipWidth(text), true)
	end

	self.pickerRowsWanted = rows
	self:RefreshPickerSelection()
end

-- Position and fill pooled chip `index`, growing the pool if this refresh needs more chips than
-- any previous one did.
function Analysis:PlaceChip(index, text, value, x, row, w, isMore)
	local chip = self.pickerChips[index]
	if chip == nil then
		chip = self:BuildPickerChip()
		self.pickerChips[index] = chip
	end

	chip.control:SetPosition(x, (row - 1) * (PICKER_HEIGHT + PICKER_ROW_GAP))
	chip.control:SetSize(w, PICKER_HEIGHT)
	chip.border:SetSize(w, PICKER_HEIGHT)
	chip.label:SetSize(w, PICKER_HEIGHT)
	chip.label:SetText(text)
	chip.value = value
	chip.isMore = isMore
	chip.control:SetVisible(true)
end

function Analysis:BuildPickerChip()
	local control = Turbine.UI.Control()
	control:SetParent(self.pickerRow)

	local border = Turbine.UI.Control()
	border:SetParent(control)
	border:SetPosition(0, 0)
	border:SetBackColor(Theme.Color(Theme.Hex.Border))
	border:SetMouseVisible(false)

	-- Fills the 1px-inset interior; also doubles as the selected/hover tint target (a
	-- precomputed blend, not SetOpacity -- see Theme.Mix).
	local inset = Turbine.UI.Control()
	inset:SetParent(control)
	inset:SetPosition(1, 1)
	inset:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	inset:SetMouseVisible(false)

	local label = Turbine.UI.Label()
	label:SetParent(control)
	label:SetFont(Font.Verdana10)
	label:SetForeColor(Theme.Color(Theme.Hex.DimText))
	label:SetPosition(0, 0)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	label:SetMouseVisible(false)

	local chip = { control = control, border = border, inset = inset, label = label, value = nil,
		isMore = false }

	local window = self
	control.MouseClick = function()
		if chip.isMore then
			window:TogglePickerExpanded()
		else
			window:SelectFilter(chip.value)
		end
	end
	control.MouseEnter = function()
		-- The "+N more"/"less" chip is never the selected one, so it always takes the hover tint;
		-- a real chip only takes it when it is not already selected.
		if chip.isMore or window.filter[window.viewTab] ~= chip.value then
			inset:SetBackColor(Theme.Color(Theme.Hex.Hover))
		end
	end
	control.MouseLeave = function() window:RefreshPickerSelection() end

	return chip
end

function Analysis:RefreshPickerSelection()
	local selected = self.filter[self.viewTab]
	for i = 1, table.getn(self.pickerChips) do
		local chip = self.pickerChips[i]
		if chip.control:IsVisible() then
			-- isMore matters here: the trailing chip carries a nil value, which would otherwise
			-- compare equal to the unfiltered state and render as if "All X" were selected.
			local isSelected = (not chip.isMore and chip.value == selected)
			chip.inset:SetBackColor(Theme.Color(isSelected and Theme.Hex.ActiveTab or Theme.Hex.WindowFill))
			chip.border:SetBackColor(Theme.Color(isSelected and Theme.Hex.Accent700 or Theme.Hex.Border))
			chip.label:SetForeColor(Theme.Color(isSelected and Theme.Hex.Accent200 or Theme.Hex.DimText))

			local w, h = chip.control:GetSize()
			chip.inset:SetSize(w - 2, h - 2)
		end
	end
end

function Analysis:SelectFilter(who)
	self.filter[self.viewTab] = who
	self:RefreshPickerSelection()
	self:RefreshContent()
end

-- Changes the picker's row count, which changes where every block below it sits -- so this goes
-- through RefreshContent (which detects the shape change and re-runs Layout), never straight to
-- RefreshPicker.
function Analysis:TogglePickerExpanded()
	self.pickerExpanded = not self.pickerExpanded
	self:RefreshContent()
end

---------------------------------------------------------------------------------------------------
-- KPI cards
---------------------------------------------------------------------------------------------------

function Analysis:BuildKpiRow()
	self.kpiRow = Turbine.UI.Control()
	self.kpiRow:SetParent(self.contentArea)
	self.kpiRow:SetMouseVisible(false)

	self.kpiCards = {}
	for i = 1, 5 do
		self.kpiCards[i] = self:BuildKpiCard()
	end
end

-- Card content stacks label 12 / value 20 / sub 12 inside 50px with 4px of top padding. The old
-- card put the value at y=18 with height 24 and the sub at y=36 -- a 6px collision that clipped
-- the bottom of every value against the top of its own sub-label.
function Analysis:BuildKpiCard()
	local card = Turbine.UI.Control()
	card:SetParent(self.kpiRow)
	card:SetBackColor(Theme.Color(Theme.Hex.KpiFill))
	card:SetMouseVisible(false)

	local border = Turbine.UI.Control()
	border:SetParent(card)
	border:SetPosition(0, 0)
	border:SetBackColor(Theme.Color(Theme.Hex.Border))
	border:SetMouseVisible(false)

	local label = Turbine.UI.Label()
	label:SetParent(card)
	label:SetFont(Font.Verdana10)
	label:SetForeColor(Theme.Color(Theme.Hex.DimText))
	label:SetPosition(8, 4)
	label:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	label:SetMouseVisible(false)

	local value = Turbine.UI.Label()
	value:SetParent(card)
	value:SetFont(Font.Verdana20)
	value:SetForeColor(Theme.Color(Theme.Hex.Text))
	value:SetPosition(8, 16)
	value:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	value:SetMouseVisible(false)

	local sub = Turbine.UI.Label()
	sub:SetParent(card)
	sub:SetFont(Font.Verdana10)
	sub:SetPosition(8, 36)
	sub:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	sub:SetMouseVisible(false)

	return { control = card, border = border, label = label, value = value, sub = sub }
end

---------------------------------------------------------------------------------------------------
-- Graph area
---------------------------------------------------------------------------------------------------

function Analysis:BuildGraphArea()
	self.graphHolder = Turbine.UI.Control()
	self.graphHolder:SetParent(self.contentArea)
	self.graphHolder:SetMouseVisible(false)
end

---------------------------------------------------------------------------------------------------
-- Search boxes -- shared shape for the skill table and the buff table below; the pattern (border
-- + inset + TextBox + placeholder Label + clear glyph) matches LootLogs' own sidebar search
-- (Turbine.UI.TextBox, TextChanged/FocusGained/FocusLost, SetText not firing TextChanged so a
-- clear button has to update the filter itself) -- the only confirmed-working TextBox precedent
-- anywhere in this environment's installed plugins.
---------------------------------------------------------------------------------------------------

function Analysis:BuildSearchBox(parent, placeholderText)
	local control = Turbine.UI.Control()
	control:SetParent(parent)
	control:SetPosition(0, 0)
	control:SetSize(SEARCH_WIDTH, SEARCH_HEIGHT)
	control:SetBackColor(Theme.Color(Theme.Hex.Border))

	local inset = Turbine.UI.Control()
	inset:SetParent(control)
	inset:SetPosition(1, 1)
	inset:SetSize(SEARCH_WIDTH - 2, SEARCH_HEIGHT - 2)
	inset:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	inset:SetMouseVisible(false)

	-- Magnifying-glass icon, left of the field -- matches LootLogs' own sidebar search
	-- (UI/Window/Sidebar.lua: searchIcon, Resources/search.tga, BlendMode.Overlay), the same
	-- same-shape precedent this box's TextBox itself is already built from (see this
	-- function's header comment).
	local searchIcon = Turbine.UI.Control()
	searchIcon:SetParent(inset)
	searchIcon:SetPosition(6, math.floor((SEARCH_HEIGHT - 2 - SEARCH_ICON) / 2))
	searchIcon:SetSize(SEARCH_ICON, SEARCH_ICON)
	searchIcon:SetBlendMode(Turbine.UI.BlendMode.Overlay)
	searchIcon:SetBackground("Basil/Resources/search.tga")
	searchIcon:SetMouseVisible(false)

	local fieldLeft = 6 + SEARCH_ICON + 4
	local fieldWidth = SEARCH_WIDTH - 2 - fieldLeft - 18

	local textbox = Turbine.UI.TextBox()
	textbox:SetParent(inset)
	textbox:SetPosition(fieldLeft, 0)
	textbox:SetSize(fieldWidth, SEARCH_HEIGHT - 2)
	textbox:SetMultiline(false)
	textbox:SetFont(Font.Verdana10)
	textbox:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	textbox:SetForeColor(Theme.Color(Theme.Hex.Text))
	textbox:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	textbox:SetText("")

	-- A real placeholder Label, not seeded prompt text left in the field -- matching LootLogs'
	-- own comment on why (a seeded value would have to be filtered back out of every search).
	local placeholder = Turbine.UI.Label()
	placeholder:SetParent(inset)
	placeholder:SetPosition(fieldLeft + 2, 0)
	placeholder:SetSize(fieldWidth, SEARCH_HEIGHT - 2)
	placeholder:SetFont(Font.Verdana10)
	placeholder:SetForeColor(Theme.Color(Theme.Hex.DimText))
	placeholder:SetText(placeholderText)
	placeholder:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	placeholder:SetMouseVisible(false)

	-- Clear button: a real Resources/cross.tga icon (same asset Frame's close button uses),
	-- not a text "x" -- wrapped in its own Theme.Hex.Hover-on-MouseEnter Control rather than
	-- recoloured directly, since a .tga's BlendMode.Overlay tint comes from what sits behind
	-- it, not from its own ForeColor (there isn't one -- see UI/Frame.lua's close button for
	-- the same reasoning).
	local clear = Turbine.UI.Control()
	clear:SetParent(control)
	clear:SetPosition(SEARCH_WIDTH - 2 - 16, 1)
	clear:SetSize(16, SEARCH_HEIGHT - 2)
	clear:SetMouseVisible(true)
	clear:SetVisible(false)

	local clearIcon = Turbine.UI.Control()
	clearIcon:SetParent(clear)
	clearIcon:SetSize(SEARCH_ICON, SEARCH_ICON)
	clearIcon:SetPosition(math.floor((16 - SEARCH_ICON) / 2), math.floor(((SEARCH_HEIGHT - 2) - SEARCH_ICON) / 2))
	clearIcon:SetBlendMode(Turbine.UI.BlendMode.Overlay)
	clearIcon:SetBackground("Basil/Resources/cross.tga")
	clearIcon:SetMouseVisible(false)

	clear.MouseEnter = function() clear:SetBackColor(Theme.Color(Theme.Hex.Hover)) end
	clear.MouseLeave = function() clear:SetBackColor(nil) end

	return { control = control, textbox = textbox, placeholder = placeholder, clear = clear, focused = false }
end

-- Placeholder shows only while empty and unfocused; the clear glyph only while there's something
-- to clear. Called after every text/focus change on either search box.
function Analysis:RefreshSearchBox(widgets)
	local filtering = widgets.textbox:GetText() ~= ""
	widgets.placeholder:SetVisible(not filtering and not widgets.focused)
	widgets.clear:SetVisible(filtering)
end

---------------------------------------------------------------------------------------------------
-- Skill table
---------------------------------------------------------------------------------------------------

function Analysis:BuildTable()
	self.tableHolder = Turbine.UI.Control()
	self.tableHolder:SetParent(self.contentArea)
	self.tableHolder:SetMouseVisible(false)

	self.tableSearch = self:BuildSearchBox(self.tableHolder, "Search skills...")
	local window = self
	self.tableSearch.textbox.TextChanged = function()
		window.tableFilterText = window.tableSearch.textbox:GetText()
		window:RefreshSearchBox(window.tableSearch)
		window:RefreshContent()
	end
	self.tableSearch.textbox.FocusGained = function()
		window.tableSearch.focused = true
		window:RefreshSearchBox(window.tableSearch)
	end
	self.tableSearch.textbox.FocusLost = function()
		window.tableSearch.focused = false
		window:RefreshSearchBox(window.tableSearch)
	end
	self.tableSearch.clear.MouseClick = function()
		window.tableSearch.textbox:SetText("")
		window.tableFilterText = ""
		window:RefreshSearchBox(window.tableSearch)
		window:RefreshContent()
	end

	self.tableHeaderRow = Turbine.UI.Control()
	self.tableHeaderRow:SetParent(self.tableHolder)
	self.tableHeaderRow:SetPosition(0, SEARCH_HEIGHT)
	self.tableHeaderRow:SetSize(1, ROW_HEIGHT)
	self.tableHeaderRow:SetBackColor(Theme.Color(Theme.Hex.HeaderFill))
	self.tableHeaderRow:SetMouseVisible(false)

	-- One mouse-visible cell per column, with the header Label parented inside it -- the same
	-- hover-fill-wrapper-around-a-mouse-invisible-child shape as Frame's close button and the
	-- search box's clear glyph. The cell, not the Label, is the click target so the column's
	-- 8px padding is clickable too. A mouse-visible child inside a mouse-invisible parent
	-- (tableHeaderRow) does receive clicks: the picker chips and the session-rail rows already
	-- work exactly this way in-game.
	self.tableHeaderCells = {}
	self.tableHeaderLabels = {}
	for i = 1, MAX_TABLE_COLUMNS do
		local cell = Turbine.UI.Control()
		cell:SetParent(self.tableHeaderRow)
		cell:SetPosition(0, 0)
		cell:SetSize(0, ROW_HEIGHT)
		cell:SetVisible(false)

		local label = Turbine.UI.Label()
		label:SetParent(cell)
		label:SetFont(Font.Verdana10)
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetPosition(8, 0)
		label:SetSize(0, ROW_HEIGHT)
		label:SetVisible(false)
		label:SetMouseVisible(false)

		cell.MouseEnter = function() cell:SetBackColor(Theme.Color(Theme.Hex.Hover)) end
		cell.MouseLeave = function() cell:SetBackColor(nil) end
		-- The column at index i changes with the view, so the sort key is read from the active
		-- spec at click time rather than captured here.
		cell.MouseClick = function()
			local spec = window.tableColumnSpec
			local column = spec and spec[i]
			if column ~= nil then
				window:SortTableBy(column.key, column.numeric)
			end
		end

		self.tableHeaderCells[i] = cell
		self.tableHeaderLabels[i] = label
	end

	-- Turbine.UI has no ScrollView -- the real pattern (confirmed against LootLogs, a real
	-- distributed plugin) is a ListBox as the scrolling host plus a separate Lotro.ScrollBar
	-- wired to it. Items are Controls added via AddItem, not manually positioned/parented.
	self.scrollView = Turbine.UI.ListBox()
	self.scrollView:SetParent(self.tableHolder)
	self.scrollView:SetPosition(0, SEARCH_HEIGHT + ROW_HEIGHT)
	self.scrollView:SetBackColor(Theme.Color(Theme.Hex.WindowFill))

	self.tableScrollBar = Turbine.UI.Lotro.ScrollBar()
	self.tableScrollBar:SetParent(self.tableHolder)
	self.tableScrollBar:SetOrientation(Turbine.UI.Orientation.Vertical)
	self.tableScrollBar:SetWidth(SCROLLBAR_WIDTH)
	self.scrollView:SetVerticalScrollBar(self.tableScrollBar)

	self.tableRowPool = {}
	for i = 1, 30 do
		self.tableRowPool[i] = self:BuildTableRowSlot()
	end
end

-- Not parented here -- AddItem (called from RefreshTable, every data refresh) does that. A row
-- never sits in the ListBox until it actually has data for the current view/filter/range.
function Analysis:BuildTableRowSlot()
	local container = Turbine.UI.Control()
	container:SetSize(1, ROW_HEIGHT)

	local divider = Turbine.UI.Control()
	divider:SetParent(container)
	divider:SetPosition(0, ROW_HEIGHT - 1)
	divider:SetSize(1, 1)
	divider:SetBackColor(Theme.Color(Theme.Hex.RowBorder))
	divider:SetMouseVisible(false)

	-- Colour is set per-view in RefreshTableColumns (Theme.Mix'd to an 8% tint there, since
	-- SetOpacity does not blend -- see Theme.Mix's comment); only width changes per refresh.
	local shareBar = Turbine.UI.Control()
	shareBar:SetParent(container)
	shareBar:SetPosition(0, 0)
	shareBar:SetSize(0, ROW_HEIGHT - 1)
	shareBar:SetMouseVisible(false)

	local row = nil -- built lazily once column geometry is known, see RefreshTableColumns

	return { container = container, divider = divider, shareBar = shareBar, row = row }
end

-- Header text for a column, given the active view. Only three of them vary.
local function ColumnLabel(column, meta)
	if column.key == "type" then
		return meta.counterpartHeader
	elseif column.key == "hits" then
		return string.upper(meta.hitWord)
	end
	return column.label
end

-- (Re)builds the header labels and the pooled rows' column geometry for the active view. Called
-- on view change and on resize -- not per data refresh.
function Analysis:RefreshTableColumns(tableWidth)
	local meta = VIEW_META[self.viewTab]
	local spec = COLUMN_SETS[meta.shape]

	local fixedTotal = 0
	for i = 1, table.getn(spec) do
		fixedTotal = fixedTotal + (spec[i].width or 0)
	end

	local flexWidth = tableWidth - fixedTotal
	if flexWidth < SKILL_COLUMN_MIN then
		flexWidth = SKILL_COLUMN_MIN
	end

	local columns = {}
	local x = 0
	for i = 1, table.getn(spec) do
		local column = spec[i]
		local width = column.width or flexWidth
		local colorHex = Theme.Hex.MutedText
		if column.key == "skill" then
			colorHex = Theme.Hex.Text
		elseif column.accent then
			colorHex = MetaColor(meta)
		end

		columns[i] = {
			x = x, width = width,
			font = column.numeric and Font.LucidaConsole12 or Font.Verdana12,
			align = column.numeric and Turbine.UI.ContentAlignment.MiddleRight or Turbine.UI.ContentAlignment.MiddleLeft,
			colorHex = colorHex,
		}
		x = x + width
	end

	self.tableColumns = columns
	self.tableWidth = x
	self.tableColumnSpec = spec

	-- AVOID exists only in the damage views, so a view switch can leave the sort pointing at a
	-- column this view doesn't have. Fall back to the default rather than ordering the table by
	-- something the reader can't see (and can't click again to reverse).
	local sortable = false
	for i = 1, table.getn(spec) do
		if spec[i].key == self.tableSort.key then
			sortable = true
		end
	end
	if not sortable then
		self.tableSort.key = "total"
		self.tableSort.ascending = false
	end

	for i = 1, MAX_TABLE_COLUMNS do
		local cell = self.tableHeaderCells[i]
		local label = self.tableHeaderLabels[i]
		local column = spec[i]
		if column == nil then
			cell:SetVisible(false)
			label:SetVisible(false)
		else
			local col = columns[i]
			-- 8px cell padding on both sides, so a right-aligned header sits directly over the
			-- right-aligned number underneath it.
			cell:SetPosition(col.x, 0)
			cell:SetSize(col.width, ROW_HEIGHT)
			label:SetPosition(8, 0)
			label:SetSize(math.max(0, col.width - 16), ROW_HEIGHT)
			label:SetTextAlignment(col.align)
			label:SetVisible(true)
			cell:SetVisible(true)
		end
	end
	self:RefreshTableHeaderText()
	self.tableHeaderRow:SetSize(x, ROW_HEIGHT)

	-- The same 8px padding on the cells themselves.
	local padded = {}
	for i = 1, table.getn(columns) do
		padded[i] = {
			x = columns[i].x + 8, width = math.max(0, columns[i].width - 16),
			font = columns[i].font, align = columns[i].align, colorHex = columns[i].colorHex,
		}
	end

	for i = 1, table.getn(self.tableRowPool) do
		local slot = self.tableRowPool[i]
		slot.container:SetSize(x, ROW_HEIGHT)
		slot.divider:SetSize(x, 1)
		slot.shareBar:SetBackColor(Theme.Mix(MetaColor(meta), Theme.Hex.WindowFill, 0.08))

		if slot.row == nil then
			slot.row = Row(x, ROW_HEIGHT, padded)
			slot.row:SetParent(slot.container)
			slot.row:SetPosition(0, 0)
		else
			slot.row:Reconfigure(x, padded)
		end
	end
end

-- Header text and colour only -- no geometry -- so a sort click doesn't have to rebuild every
-- pooled row's column spec just to move the direction marker.
function Analysis:RefreshTableHeaderText()
	local meta = VIEW_META[self.viewTab]
	local spec = self.tableColumnSpec
	if spec == nil then
		return
	end

	for i = 1, table.getn(spec) do
		local column = spec[i]
		local sorted = (column.key == self.tableSort.key)
		local text = ColumnLabel(column, meta)
		if sorted then
			text = text .. (self.tableSort.ascending and SORT_ASC or SORT_DESC)
		end
		self.tableHeaderLabels[i]:SetText(text)
		self.tableHeaderLabels[i]:SetForeColor(
			Theme.Color(sorted and Theme.Hex.Accent200 or Theme.Hex.DimText))
	end
end

-- First click on a column sorts by it -- descending for numbers (the big contributors are what
-- a reader is looking for), ascending for names; clicking the same column again reverses.
function Analysis:SortTableBy(key, numeric)
	if key == nil then
		return
	end
	if self.tableSort.key == key then
		self.tableSort.ascending = not self.tableSort.ascending
	else
		self.tableSort.key = key
		self.tableSort.ascending = not numeric
	end
	self:RefreshTableHeaderText()
	self:RefreshContent()
end

-- The value a column sorts on -- always the number (or name) the cell actually displays, so the
-- resulting order matches what the reader can see in that column. CRIT / DEV is one column
-- showing two percentages, so it sorts on the combined crit+devastate rate.
local function TableSortValue(row, key, shape)
	if key == "skill" then
		return string.lower(row.skill or "")
	elseif key == "type" then
		if shape == "heal" then
			return string.lower(row.who or "")
		end
		return string.lower(DamageType.Names[row.type] or "")
	elseif key == "hits" then
		return row.hits or 0
	elseif key == "critdev" then
		if (row.hits or 0) <= 0 then
			return 0
		end
		return ((row.crits or 0) + (row.devs or 0)) / row.hits
	elseif key == "avoid" then
		local swings = (row.hits or 0) + (row.avoided or 0)
		if swings <= 0 then
			return 0
		end
		return (row.avoided or 0) / swings
	elseif key == "max" then
		return row.max or 0
	end
	return row.total or 0
end

-- Sorts in place. The skill-name/total tiebreak is not cosmetic: table.sort needs a strict weak
-- ordering or it can raise "invalid order function for sorting", and several of these columns
-- (AVOID, CRIT / DEV, HITS) tie constantly.
function Analysis:SortTableRows(list, shape)
	local key = self.tableSort.key
	local ascending = self.tableSort.ascending

	table.sort(list, function(a, b)
		local va = TableSortValue(a, key, shape)
		local vb = TableSortValue(b, key, shape)
		if va ~= vb then
			if ascending then
				return va < vb
			end
			return va > vb
		end
		local na = string.lower(a.skill or "")
		local nb = string.lower(b.skill or "")
		if na ~= nb then
			return na < nb
		end
		return (a.total or 0) > (b.total or 0)
	end)
	return list
end

-- Damage views group across counterparts by skill+type; heal views keep one row per
-- skill+counterpart, since "who healed you" is the interesting axis there. `rows` is whatever
-- Session:Slice returned for the current category/range/filter, so this is the same code path
-- whether or not a range is active.
function Analysis:TableRows(rows, view)
	local meta = VIEW_META[view]

	if meta.shape == "heal" then
		local list = {}
		for i = 1, table.getn(rows) do
			list[i] = rows[i]
		end
		return self:SortTableRows(list, meta.shape)
	end

	local grouped = {}
	local order = {}
	for i = 1, table.getn(rows) do
		local row = rows[i]
		local key = row.skill .. "\1" .. row.type
		local g = grouped[key]
		if g == nil then
			g = { skill = row.skill, type = row.type, hits = 0, total = 0, max = 0, crits = 0, devs = 0, avoided = 0 }
			grouped[key] = g
			table.insert(order, g)
		end
		g.hits = g.hits + row.hits
		g.total = g.total + row.total
		g.crits = g.crits + row.crits
		g.devs = g.devs + row.devs
		g.avoided = g.avoided + (row.avoided or 0)
		if row.max > g.max then
			g.max = row.max
		end
	end
	return self:SortTableRows(order, meta.shape)
end

local function CritDevText(row)
	if row.hits <= 0 then
		return "0% / 0%"
	end
	return Format.Percent(row.crits / row.hits) .. " / " .. Format.Percent(row.devs / row.hits)
end

function Analysis:RowValues(view, row)
	local meta = VIEW_META[view]

	if meta.shape == "heal" then
		return {
			row.skill, row.who, Format.Number(row.hits), CritDevText(row),
			Format.Number(row.max), Format.Number(row.total),
		}
	end

	local swings = row.hits + (row.avoided or 0)
	local avoidedPct = swings > 0 and Format.Percent((row.avoided or 0) / swings) or "0%"
	return {
		row.skill, DamageType.Names[row.type] or "?", Format.Number(row.hits), CritDevText(row),
		avoidedPct, Format.Number(row.max), Format.Number(row.total),
	}
end

-- Matches the search text against the skill name plus whichever counterpart column the active
-- view shows (type for damage views, who for heal views), so "regen" finds a heal named that and
-- "orc" finds anything sourced from an orc, not only a skill literally named "orc".
function Analysis:FilterTableRows(list)
	local query = self.tableFilterText
	if query == nil or query == "" then
		return list
	end

	local filtered = {}
	for i = 1, table.getn(list) do
		local row = list[i]
		local haystack = row.skill or ""
		if row.who ~= nil then
			haystack = haystack .. " " .. row.who
		elseif row.type ~= nil then
			haystack = haystack .. " " .. (DamageType.Names[row.type] or "")
		end
		if MatchesFilter(haystack, query) then
			table.insert(filtered, row)
		end
	end
	return filtered
end

function Analysis:RefreshTable(rows)
	local view = self.viewTab
	local meta = VIEW_META[view]
	local list = self:TableRows(rows, view)
	list = self:FilterTableRows(list)

	local maxTotal = 0
	for i = 1, table.getn(list) do
		if list[i].total > maxTotal then
			maxTotal = list[i].total
		end
	end

	-- ListBox is item-list based, not freeform positioning: clear and re-add each refresh, but
	-- reuse the same pooled container/Row/shareBar objects every time -- only the ListBox's
	-- membership list is rebuilt, never the Controls themselves.
	self.scrollView:ClearItems()

	local n = table.getn(list)
	local poolSize = table.getn(self.tableRowPool)
	if n > poolSize then
		n = poolSize
	end

	-- settings.typeColoredBars (options window, Palette page): tint each row's share bar by the
	-- hit's own DAMAGE TYPE rather than by the view's series colour, so a fight's fire/shadow/
	-- common split reads off the table without a column for it. Only the damage views have a type
	-- at all -- a heal row's `type` is nil, and DamageType.Unknown (13, which covers absorbs and
	-- any line with no stated type) is not a colour worth claiming either, so both fall back to
	-- the series colour rather than to some fifth "other" tint.
	local typed = (_G.settings.typeColoredBars == true) and (meta.shape == "damage")
	local seriesMix = Theme.Mix(MetaColor(meta), Theme.Hex.WindowFill, 0.08)

	for i = 1, n do
		local slot = self.tableRowPool[i]
		local row = list[i]

		slot.row:SetValues(self:RowValues(view, row))
		local share = (maxTotal > 0) and (row.total / maxTotal) or 0
		slot.shareBar:SetSize(math.floor(self.tableWidth * share), ROW_HEIGHT - 1)

		if typed then
			local hex = TYPE_HEX[row.type]
			slot.shareBar:SetBackColor(hex and Theme.Mix(hex, Theme.Hex.WindowFill, 0.08) or seriesMix)
		else
			slot.shareBar:SetBackColor(seriesMix)
		end

		self.scrollView:AddItem(slot.container)
	end
end

---------------------------------------------------------------------------------------------------
-- Self-buff section
---------------------------------------------------------------------------------------------------

function Analysis:BuildBuffSection()
	self.buffHolder = Turbine.UI.Control()
	self.buffHolder:SetParent(self.contentArea)
	self.buffHolder:SetMouseVisible(false)

	self.buffTopRule = Turbine.UI.Control()
	self.buffTopRule:SetParent(self.buffHolder)
	self.buffTopRule:SetPosition(0, 0)
	self.buffTopRule:SetSize(1, 1)
	self.buffTopRule:SetBackColor(Theme.Color(Theme.Hex.Border))
	self.buffTopRule:SetMouseVisible(false)

	-- A plain section label now, not a collapse toggle: the splitter above it does the same job
	-- better (drag it to the bottom and the buff table is one row tall; a collapse button on top
	-- of that is a second way to say the same thing), so nothing here is clickable.
	local header = Turbine.UI.Control()
	header:SetParent(self.buffHolder)
	header:SetPosition(0, 1)
	header:SetSize(1, BUFF_HEADER_HEIGHT)
	header:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	header:SetMouseVisible(false)

	local title = Turbine.UI.Label()
	title:SetParent(header)
	title:SetFont(Font.Verdana10)
	title:SetText("SELF EFFECTS")
	title:SetForeColor(Theme.Color(Theme.Hex.MutedText))
	title:SetPosition(0, 0)
	title:SetSize(92, BUFF_HEADER_HEIGHT)
	title:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	title:SetMouseVisible(false)

	local summary = Turbine.UI.Label()
	summary:SetParent(header)
	summary:SetFont(Font.Verdana10)
	summary:SetForeColor(Theme.Color(Theme.Hex.DimText))
	summary:SetPosition(96, 0)
	summary:SetSize(1, BUFF_HEADER_HEIGHT)
	summary:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	summary:SetMouseVisible(false)

	local window = self

	self.buffHeader = { control = header, title = title, summary = summary }

	self.buffSearch = self:BuildSearchBox(self.buffHolder, "Search effects...")
	self.buffSearch.control:SetPosition(0, BUFF_HEADER_HEIGHT + 1)
	self.buffSearch.textbox.TextChanged = function()
		window.buffFilterText = window.buffSearch.textbox:GetText()
		window:RefreshSearchBox(window.buffSearch)
		window:RefreshContent()
	end
	self.buffSearch.textbox.FocusGained = function()
		window.buffSearch.focused = true
		window:RefreshSearchBox(window.buffSearch)
	end
	self.buffSearch.textbox.FocusLost = function()
		window.buffSearch.focused = false
		window:RefreshSearchBox(window.buffSearch)
	end
	self.buffSearch.clear.MouseClick = function()
		window.buffSearch.textbox:SetText("")
		window.buffFilterText = ""
		window:RefreshSearchBox(window.buffSearch)
		window:RefreshContent()
	end

	self.buffTableHeader = Turbine.UI.Control()
	self.buffTableHeader:SetParent(self.buffHolder)
	self.buffTableHeader:SetSize(1, BUFF_TABLE_HEADER_HEIGHT)
	self.buffTableHeader:SetBackColor(Theme.Color(Theme.Hex.HeaderFill))
	self.buffTableHeader:SetMouseVisible(false)

	-- Sortable columns get the same clickable hover cell as the skill table's header (see
	-- BuildTable); the checkbox/icon gutters keep a plain Label parented straight to the header.
	self.buffHeaderLabels = {}
	self.buffHeaderCells = {}
	for i = 1, table.getn(BUFF_COLUMNS) do
		local column = BUFF_COLUMNS[i]
		local host = self.buffTableHeader

		if column.sortable then
			local cell = Turbine.UI.Control()
			cell:SetParent(self.buffTableHeader)
			cell:SetPosition(0, 0)
			cell:SetSize(0, BUFF_TABLE_HEADER_HEIGHT)
			cell.MouseEnter = function() cell:SetBackColor(Theme.Color(Theme.Hex.Hover)) end
			cell.MouseLeave = function() cell:SetBackColor(nil) end
			cell.MouseClick = function() window:SortBuffsBy(column.key, column.numeric) end
			self.buffHeaderCells[i] = cell
			host = cell
		end

		local label = Turbine.UI.Label()
		label:SetParent(host)
		label:SetFont(Font.Verdana10)
		label:SetForeColor(Theme.Color(Theme.Hex.DimText))
		label:SetText(column.label)
		label:SetSize(math.max(0, column.width - 16), BUFF_TABLE_HEADER_HEIGHT)
		label:SetTextAlignment(column.numeric and Turbine.UI.ContentAlignment.MiddleRight
			or Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)
		self.buffHeaderLabels[i] = label
	end

	-- Same ListBox + Lotro.ScrollBar host as the skill table (see BuildTable's comment) -- rows
	-- are pooled Controls added via AddItem, not manually positioned/parented, so overflow past
	-- whatever height Layout() gives the buff section scrolls instead of being silently dropped.
	self.buffScrollView = Turbine.UI.ListBox()
	self.buffScrollView:SetParent(self.buffHolder)
	self.buffScrollView:SetBackColor(Theme.Color(Theme.Hex.WindowFill))

	self.buffScrollBar = Turbine.UI.Lotro.ScrollBar()
	self.buffScrollBar:SetParent(self.buffHolder)
	self.buffScrollBar:SetOrientation(Turbine.UI.Orientation.Vertical)
	self.buffScrollBar:SetWidth(SCROLLBAR_WIDTH)
	self.buffScrollView:SetVerticalScrollBar(self.buffScrollBar)

	self.buffRows = {}
	for i = 1, BUFF_POOL do
		self.buffRows[i] = self:BuildBuffRow()
	end

	self:LayoutBuffColumns(604)
end

-- Not parented here -- AddItem (called from RefreshBuffSection, every data refresh) does that,
-- matching BuildTableRowSlot's own comment: a row never sits in the ListBox until it actually
-- has data for the current session/range.
function Analysis:BuildBuffRow()
	local container = Turbine.UI.Control()
	container:SetSize(1, BUFF_ROW_HEIGHT)

	local shareBar = Turbine.UI.Control()
	shareBar:SetParent(container)
	shareBar:SetPosition(0, 0)
	shareBar:SetSize(0, BUFF_ROW_HEIGHT - 1)
	shareBar:SetMouseVisible(false)

	local divider = Turbine.UI.Control()
	divider:SetParent(container)
	divider:SetPosition(0, BUFF_ROW_HEIGHT - 1)
	divider:SetSize(1, 1)
	divider:SetBackColor(Theme.Color(Theme.Hex.RowBorder))
	divider:SetMouseVisible(false)

	-- The charted checkbox: an 8x8 border square whose inset fills with the lane colour when
	-- this buff is charted, empty when it is not.
	local box = Turbine.UI.Control()
	box:SetParent(container)
	box:SetPosition(8, math.floor((BUFF_ROW_HEIGHT - 8) / 2))
	box:SetSize(8, 8)
	box:SetMouseVisible(false)

	local boxInset = Turbine.UI.Control()
	boxInset:SetParent(box)
	boxInset:SetPosition(1, 1)
	boxInset:SetSize(6, 6)
	boxInset:SetMouseVisible(false)

	local icon = Turbine.UI.Control()
	icon:SetParent(container)
	icon:SetPosition(22, math.floor((BUFF_ROW_HEIGHT - 16) / 2))
	icon:SetSize(16, 16)
	icon:SetMouseVisible(false)

	local iconInset = Turbine.UI.Control()
	iconInset:SetParent(icon)
	iconInset:SetPosition(1, 1)
	iconInset:SetSize(14, 14)
	iconInset:SetMouseVisible(false)
	-- Real art is applied by Icon.Apply (Constants.lua) at fill time, following Gibberish3's own
	-- timer icon element's exact call sequence -- nothing else is set here at construction.

	local iconLabel = Turbine.UI.Label()
	iconLabel:SetParent(icon)
	iconLabel:SetFont(Font.Verdana10)
	iconLabel:SetPosition(0, 0)
	iconLabel:SetSize(16, 16)
	iconLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter)
	iconLabel:SetMouseVisible(false)

	local cells = {}
	for i = 3, table.getn(BUFF_COLUMNS) do
		local column = BUFF_COLUMNS[i]
		local label = Turbine.UI.Label()
		label:SetParent(container)
		label:SetFont(column.numeric and Font.LucidaConsole12 or Font.Verdana12)
		label:SetForeColor(Theme.Color(Theme.Hex.MutedText))
		label:SetSize(math.max(0, column.width - 16), BUFF_ROW_HEIGHT - 1)
		label:SetTextAlignment(column.numeric and Turbine.UI.ContentAlignment.MiddleRight
			or Turbine.UI.ContentAlignment.MiddleLeft)
		label:SetMouseVisible(false)
		cells[i] = label
	end

	local widgets = {
		container = container, shareBar = shareBar, divider = divider,
		box = box, boxInset = boxInset,
		icon = icon, iconInset = iconInset, iconLabel = iconLabel,
		cells = cells, name = nil,
	}

	local window = self
	container.MouseClick = function()
		if widgets.name ~= nil then
			window:ToggleCharted(widgets.name)
		end
	end
	container.MouseEnter = function()
		container:SetBackColor(Theme.Color(Theme.Hex.Hover))
	end
	container.MouseLeave = function()
		container:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
	end

	return widgets
end

function Analysis:LayoutBuffColumns(width)
	-- The name column absorbs the slack when the window is wider than the mock's 604.
	local fixed = 0
	for i = 1, table.getn(BUFF_COLUMNS) do
		if BUFF_COLUMNS[i].key ~= "name" then
			fixed = fixed + BUFF_COLUMNS[i].width
		end
	end
	-- 100, not the 120 this floor used to be: TYPE took 66px out of the name column, and at the
	-- window's minimum width the old floor made the columns sum WIDER than the section they sit
	-- in, which clips the last column instead of shortening the name. The floor only ever binds
	-- below the minimum window size now.
	local nameWidth = math.max(100, width - fixed)

	local x = 0
	self.buffColumnX = {}
	for i = 1, table.getn(BUFF_COLUMNS) do
		local column = BUFF_COLUMNS[i]
		local w = (column.key == "name") and nameWidth or column.width
		self.buffColumnX[i] = { x = x, width = w }
		x = x + w
	end

	self.buffWidth = x

	for i = 1, table.getn(BUFF_COLUMNS) do
		local geo = self.buffColumnX[i]
		local label = self.buffHeaderLabels[i]
		local cell = self.buffHeaderCells[i]
		if cell ~= nil then
			cell:SetPosition(geo.x, 0)
			cell:SetSize(geo.width, BUFF_TABLE_HEADER_HEIGHT)
			label:SetPosition(8, 0)
		else
			label:SetPosition(geo.x + 8, 0)
		end
		label:SetSize(math.max(0, geo.width - 16), BUFF_TABLE_HEADER_HEIGHT)
	end
	-- The BUFF header spans the checkbox+icon gutter as well as the name column, matching the
	-- mock's single 214px heading over the three of them -- so its click target does too.
	local nameSpan = self.buffColumnX[2].width + self.buffColumnX[3].width
	self.buffHeaderCells[3]:SetPosition(self.buffColumnX[2].x, 0)
	self.buffHeaderCells[3]:SetSize(nameSpan, BUFF_TABLE_HEADER_HEIGHT)
	self.buffHeaderLabels[3]:SetPosition(8, 0)
	self.buffHeaderLabels[3]:SetSize(math.max(0, nameSpan - 16), BUFF_TABLE_HEADER_HEIGHT)

	self:RefreshBuffHeaderText()

	self.buffTableHeader:SetSize(x, BUFF_TABLE_HEADER_HEIGHT)

	for r = 1, BUFF_POOL do
		local widgets = self.buffRows[r]
		widgets.container:SetSize(x, BUFF_ROW_HEIGHT)
		widgets.divider:SetSize(x, 1)
		for i = 3, table.getn(BUFF_COLUMNS) do
			local geo = self.buffColumnX[i]
			widgets.cells[i]:SetPosition(geo.x + 8, 0)
			widgets.cells[i]:SetSize(math.max(0, geo.width - 16), BUFF_ROW_HEIGHT - 1)
		end
	end
end

function Analysis:IsCharted(name)
	for i = 1, table.getn(self.charted) do
		if self.charted[i] == name then
			return i
		end
	end
	return nil
end

-- Charted buffs are capped at MAX_CHARTED because there are exactly that many lane colours, and
-- because more than three interval rails under one plot stops being readable. The fourth click
-- drops the OLDEST rather than refusing: a click that appears to do nothing reads as a bug.
function Analysis:ToggleCharted(name)
	local index = self:IsCharted(name)
	if index ~= nil then
		table.remove(self.charted, index)
	else
		table.insert(self.charted, name)
		while table.getn(self.charted) > MAX_CHARTED do
			table.remove(self.charted, 1)
		end
	end

	local names = {}
	for i = 1, table.getn(self.charted) do
		names[i] = self.charted[i]
	end
	_G.settings.chartedBuffs = names
	Settings.Save()

	self:RefreshContent()
end

function Analysis:RefreshBuffHeaderText()
	for i = 1, table.getn(BUFF_COLUMNS) do
		local column = BUFF_COLUMNS[i]
		if column.sortable then
			local sorted = (column.key == self.buffSort.key)
			local text = column.label
			if sorted then
				text = text .. (self.buffSort.ascending and SORT_ASC or SORT_DESC)
			end
			self.buffHeaderLabels[i]:SetText(text)
			self.buffHeaderLabels[i]:SetForeColor(
				Theme.Color(sorted and Theme.Hex.Accent200 or Theme.Hex.DimText))
		end
	end
end

-- Same first-click rule as the skill table: numbers descending, the name column ascending.
function Analysis:SortBuffsBy(key, numeric)
	if key == nil then
		return
	end
	if self.buffSort.key == key then
		self.buffSort.ascending = not self.buffSort.ascending
	else
		self.buffSort.key = key
		self.buffSort.ascending = not numeric
	end
	self:RefreshBuffHeaderText()
	self:RefreshContent()
end

local function BuffSortValue(row, key)
	if key == "name" then
		return string.lower(row.name or "")
	elseif key == "kind" then
		-- The rendered word, so the order on screen is the order the column reads: Buff,
		-- Debuff, Unknown.
		return string.lower(BuffKindText(row))
	elseif key == "up" then
		return row.uptime or 0
	elseif key == "apps" then
		return row.apps or 0
	elseif key == "gap" then
		return row.longestGap or 0
	end
	return row.uptimePct or 0
end

-- Sorts a COPY: `stats` is what Buffs.Stats handed back and what ChartedLanes still reads, and
-- the unsorted-in-place contract there is not worth relying on a shared table's order for.
-- Name is the tiebreak for the same strict-weak-ordering reason as SortTableRows.
function Analysis:SortBuffStats(stats)
	local key = self.buffSort.key
	local ascending = self.buffSort.ascending

	local list = {}
	for i = 1, table.getn(stats) do
		list[i] = stats[i]
	end

	table.sort(list, function(a, b)
		local va = BuffSortValue(a, key)
		local vb = BuffSortValue(b, key)
		if va ~= vb then
			if ascending then
				return va < vb
			end
			return va > vb
		end
		return string.lower(a.name or "") < string.lower(b.name or "")
	end)
	return list
end

-- Matches the search text against the effect's name or its TYPE word, so "debuff" narrows the
-- list to debuffs -- the same "any text column" rule the skill table's own search follows.
-- settings.hideStaticBuffs (options window, Self buffs page): drop rows that were simply up for
-- the whole fight and applied once. Those are the class passives and the food buff -- true, but
-- never the answer to a question, and they crowd out the ones with real gaps. A charted buff is
-- never hidden: it has a lane on the graph, and a lane with no matching table row reads as a fault.
--
-- The test is uptime AND applications, not uptime alone: a buff that dropped and was re-applied
-- inside the same second can still round to 100% uptime, and that one is exactly the kind of gap
-- this table exists to show.
local BUFF_STATIC_UPTIME = 0.999

function Analysis:IsStaticBuff(row)
	return row.uptimePct >= BUFF_STATIC_UPTIME and row.apps <= 1
end

function Analysis:FilterBuffStats(stats)
	local query = self.buffFilterText
	local hideStatic = (_G.settings.hideStaticBuffs == true)

	if (query == nil or query == "") and not hideStatic then
		return stats
	end

	local filtered = {}
	for i = 1, table.getn(stats) do
		local row = stats[i]
		local matches = (query == nil or query == "")
			or MatchesFilter(row.name, query)
			or MatchesFilter(BuffKindText(row), query)
		local hidden = hideStatic and self:IsStaticBuff(row) and (self:IsCharted(row.name) == nil)

		if matches and not hidden then
			table.insert(filtered, row)
		end
	end
	return filtered
end

-- `stats` is the full tracked set (drives the "N tracked" summary count); `filtered` is what the
-- search box narrowed it to and is what's actually listed. Kept separate so typing a search
-- doesn't make the summary lie about how many buffs the session tracks in total.
function Analysis:RefreshBuffSection(stats, filtered, fromSec, toSec)
	local tracked = table.getn(stats)
	local shownCount = table.getn(filtered)

	local scope
	if fromSec == nil then
		scope = "full fight"
	else
		scope = Format.Clock(fromSec) .. "-" .. Format.Clock(toSec)
	end
	self.buffHeader.summary:SetText(
		"· " .. tracked .. " tracked · " .. table.getn(self.charted) .. " charted · " .. scope)

	-- ListBox is item-list based, not freeform positioning: clear and re-add each refresh, but
	-- reuse the same pooled container/Row objects every time -- only the ListBox's membership
	-- list is rebuilt, never the Controls themselves (matching RefreshTable's own comment).
	-- Every matching buff is added regardless of how much height the splitter left this block:
	-- the ListBox scrolls, so a short bottom row means scrolling, never dropped rows.
	self.buffScrollView:ClearItems()

	local shown = math.min(shownCount, BUFF_POOL)
	for i = 1, shown do
		local widgets = self.buffRows[i]
		local row = filtered[i]

		widgets.name = row.name
		widgets.container:SetBackColor(Theme.Color(Theme.Hex.WindowFill))
		self:FillBuffRow(widgets, row)

		self.buffScrollView:AddItem(widgets.container)
	end
end

function Analysis:FillBuffRow(widgets, row)
	local chartIndex = self:IsCharted(row.name)
	local laneHex = chartIndex and Theme.BuffLane[chartIndex] or nil

	widgets.shareBar:SetBackColor(Theme.Mix(laneHex or Theme.Hex.Accent, Theme.Hex.WindowFill, 0.08))
	widgets.shareBar:SetSize(
		math.floor(math.min(1, row.uptimePct) * self.buffWidth), BUFF_ROW_HEIGHT - 1)

	widgets.box:SetBackColor(Theme.Color(laneHex or Theme.Hex.Disabled))
	widgets.boxInset:SetBackColor(Theme.Color(laneHex or Theme.Hex.WindowFill))

	widgets.icon:SetBackColor(Theme.Color(laneHex or "#3a3d4e"))
	if row.icon ~= nil and row.icon ~= false then
		-- Clears whatever the initials-fallback branch left behind (a pooled row can flip
		-- between the two across refreshes) -- Icon.Apply itself never touches BackColor, and a
		-- leftover opaque one is a real, previously-confirmed way to hide the art underneath.
		-- widgets.iconInset:SetBackColor(Turbine.UI.Color(0, 0, 0, 0))
		-- No stretch, native size -- per direct instruction after stretching to a fixed tile
		-- also failed to show anything. May overflow the 14x14 slot; that's expected for now.

		Icon.Apply(widgets.iconInset, row.icon)
		widgets.iconInset:SetPosition(1, 1)
		widgets.iconLabel:SetText("")
	else
		-- widgets.iconInset:SetBackColor(Theme.Color(Theme.Hex.RailFill))
		widgets.iconInset:SetVisible(true)
		widgets.iconLabel:SetText(row.initials or "")
		widgets.iconLabel:SetForeColor(Theme.Color(laneHex or Theme.Hex.DimText))
	end

	local pctHex = Theme.Hex.Text
	if row.uptimePct >= BUFF_GOOD_UPTIME then
		pctHex = Theme.Series("healOut")
	elseif row.uptimePct < BUFF_POOR_UPTIME then
		pctHex = Theme.Hex.DamageSevere
	end

	local gapHex = (row.longestGap > BUFF_LONG_GAP) and Theme.Hex.DamageSevere or Theme.Hex.MutedText

	local texts = {
		[3] = row.name,
		[4] = BuffKindText(row),
		[5] = Format.Percent(row.uptimePct),
		[6] = Format.Clock(row.uptime),
		[7] = Format.Number(row.apps),
		[8] = math.floor(row.longestGap + 0.5) .. "s",
	}
	local colors = {
		[3] = chartIndex and Theme.Hex.Accent200 or Theme.Hex.Text,
		[4] = BUFF_KIND_HEX[row.kind] or BUFF_KIND_HEX[Buffs.Kind.Unknown],
		[5] = pctHex,
		[6] = Theme.Hex.MutedText,
		[7] = Theme.Hex.MutedText,
		[8] = gapHex,
	}

	for i = 3, table.getn(BUFF_COLUMNS) do
		widgets.cells[i]:SetText(texts[i] or "")
		widgets.cells[i]:SetForeColor(Theme.Color(colors[i] or Theme.Hex.MutedText))
	end
end

-- Lane descriptors for the graph, in charted order so lane 1 always keeps lane colour 1. A
-- charted name with no stats row (a buff from a different session) is skipped rather than
-- dropped from self.charted -- reselecting the session it came from brings its lane back.
function Analysis:ChartedLanes(stats)
	local byName = {}
	for i = 1, table.getn(stats) do
		byName[stats[i].name] = stats[i]
	end

	local lanes = {}
	for i = 1, table.getn(self.charted) do
		local row = byName[self.charted[i]]
		if row ~= nil then
			lanes[table.getn(lanes) + 1] = {
				name = row.name,
				colorHex = Theme.BuffLane[i] or Theme.BuffLane[1],
				initials = row.initials,
				icon = (row.icon ~= false) and row.icon or nil,
				intervals = row.intervals,
			}
		end
	end
	return lanes
end

---------------------------------------------------------------------------------------------------
-- Side panels
---------------------------------------------------------------------------------------------------

function Analysis:BuildPanels()
	self.panelsHolder = Turbine.UI.Control()
	self.panelsHolder:SetParent(self.contentArea)
	self.panelsHolder:SetMouseVisible(false)

	self.panelA = self:BuildPanel()
	self.panelB = self:BuildPanel()
end

function Analysis:BuildPanel()
	local holder = Turbine.UI.Control()
	holder:SetParent(self.panelsHolder)
	holder:SetMouseVisible(false)

	local title = Turbine.UI.Label()
	title:SetParent(holder)
	title:SetFont(Font.Verdana10)
	title:SetForeColor(Theme.Color(Theme.Hex.DimText))
	title:SetPosition(0, 0)
	title:SetSize(200, 14)
	title:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
	title:SetMouseVisible(false)

	local rows = {}
	for i = 1, 5 do
		local nameLabel = Turbine.UI.Label()
		nameLabel:SetParent(holder)
		nameLabel:SetFont(Font.Verdana10)
		nameLabel:SetForeColor(Theme.Color(Theme.Hex.Text))
		nameLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft)
		nameLabel:SetMouseVisible(false)
		nameLabel:SetVisible(false)

		local valueLabel = Turbine.UI.Label()
		valueLabel:SetParent(holder)
		valueLabel:SetFont(Font.LucidaConsole12)
		valueLabel:SetForeColor(Theme.Color(Theme.Hex.MutedText))
		valueLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight)
		valueLabel:SetMouseVisible(false)
		valueLabel:SetVisible(false)

		local bar = Bar(1, 3, Theme.Hex.Accent, Theme.Hex.RowBorder)
		bar:SetParent(holder)
		bar:SetVisible(false)

		rows[i] = { name = nameLabel, value = valueLabel, bar = bar }
	end

	return { holder = holder, title = title, rows = rows }
end

-- Both panels are fed from the same sliced rows as everything else, so they follow the range
-- and the picker without a second recount.
function Analysis:PanelData(rows, view, filterWho)
	local meta = VIEW_META[view]
	local isHeal = (meta.shape == "heal")

	local function totalsBy(field)
		local totals = {}
		for i = 1, table.getn(rows) do
			local row = rows[i]
			local key = (field == "type") and (DamageType.Names[row.type] or "Unknown") or row[field]
			totals[key] = (totals[key] or 0) + row.total
		end
		return totals
	end

	local function toItems(totals)
		local items = {}
		for name, value in pairs(totals) do
			table.insert(items, { name = name, value = value })
		end
		table.sort(items, function(a, b) return a.value > b.value end)
		return items
	end

	if filterWho == nil then
		local panelA = { title = string.upper(meta.pickerLabel), items = toItems(totalsBy("who")) }
		local panelB = { title = isHeal and "BY SKILL" or "BY TYPE", items = toItems(totalsBy(isHeal and "skill" or "type")) }
		return panelA, panelB
	end

	local panelA = { title = isHeal and "BY SKILL" or "BY TYPE", items = toItems(totalsBy(isHeal and "skill" or "type")) }

	if isHeal then
		local crit, normal = 0, 0
		for i = 1, table.getn(rows) do
			crit = crit + rows[i].crits + rows[i].devs
			normal = normal + (rows[i].hits - rows[i].crits - rows[i].devs)
		end
		local items = {}
		if crit > 0 then table.insert(items, { name = "Critical", value = crit }) end
		if normal > 0 then table.insert(items, { name = "Normal", value = normal }) end
		return panelA, { title = "CRIT SPLIT", items = items }
	end

	local avoidTotals = {}
	for i = 1, table.getn(rows) do
		local breakdown = rows[i].avoidBreakdown
		if breakdown ~= nil then
			for avoidType, count in pairs(breakdown) do
				local name = AVOID_NAMES[avoidType] or "Other"
				avoidTotals[name] = (avoidTotals[name] or 0) + count
			end
		end
	end
	return panelA, { title = "AVOIDANCE", items = toItems(avoidTotals) }
end

function Analysis:RefreshPanel(panel, data, colorHex)
	panel.title:SetText(data.title)

	local maxValue = 0
	for i = 1, table.getn(data.items) do
		if data.items[i].value > maxValue then
			maxValue = data.items[i].value
		end
	end

	local panelWidth = select(1, panel.holder:GetSize())

	for i = 1, 5 do
		local widgets = panel.rows[i]
		local item = data.items[i]

		if item == nil then
			widgets.name:SetVisible(false)
			widgets.value:SetVisible(false)
			widgets.bar:SetVisible(false)
		else
			local y = 16 + (i - 1) * 20
			widgets.name:SetPosition(0, y)
			widgets.name:SetSize(math.max(0, panelWidth - 70), 12)
			widgets.name:SetText(item.name)
			widgets.name:SetVisible(true)

			widgets.value:SetPosition(panelWidth - 66, y)
			widgets.value:SetSize(66, 12)
			widgets.value:SetText(Format.Number(item.value))
			widgets.value:SetVisible(true)

			widgets.bar:SetPosition(0, y + 14)
			widgets.bar.maxWidth = panelWidth
			widgets.bar:SetSize(panelWidth, 3)
			widgets.bar:SetFillColor(colorHex)
			widgets.bar:SetPercent(maxValue > 0 and (item.value / maxValue) or 0)
			widgets.bar:SetVisible(true)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- View / data refresh
---------------------------------------------------------------------------------------------------

function Analysis:SelectView(key, skipRefresh)
	self.viewTab = key
	self.pickerExpanded = false

	for i = 1, table.getn(VIEWS) do
		local k = VIEWS[i]
		local t = self.viewTabs[k]
		local selected = (k == key)
		t.label:SetForeColor(Theme.Color(selected and Theme.Hex.Accent200 or Theme.Hex.DimText))
		t.underline:SetBackColor(Theme.Color(selected and Theme.Hex.Accent or Theme.Hex.Border))
		t.control:SetBackColor(Theme.Color(selected and Theme.Hex.ActiveTab or Theme.Hex.WindowFill))
	end

	self:RefreshTableColumns(self.tableListWidth or 400)

	if not skipRefresh then
		self:RefreshContent()
	end
end

-- Which series each view plots. The two "incoming" views carry both sides of the exchange, since
-- damage taken only means something next to the healing that did or didn't cover it -- but the
-- second one starts HIDDEN (`hidden = true`, seeded into Graph.hidden by SetSeries). It is the
-- companion line, not the subject: on "Damage taken" the reader is reading damage, and a healing
-- line sharing the same y-scale rescales the plot around whichever of the two happens to be
-- bigger. Its legend entry is still there in the "off" colours, so one click brings it back.
--
-- Colours are NOT stored here -- only the role key. This table is a module-level local built once
-- at load, so a hex baked into it could never follow a palette-preset change; SeriesForView()
-- resolves each entry's colorHex through Theme.Series on the way out. It builds a fresh list per
-- call, which is fine: it is only called when the view actually changes (RefreshContent guards
-- SetSeriesWithMorale on self.graphSeriesView), not on every refresh.
local SERIES_FOR_VIEW = {
	done = { { key = "done", label = "Damage", role = "done" } },
	healOut = { { key = "healOut", label = "Healing out", role = "healOut" } },
	taken = {
		{ key = "taken", label = "Damage taken", role = "taken" },
		{ key = "healIn", label = "Healing in", role = "healIn", hidden = true },
	},
	healIn = {
		{ key = "healIn", label = "Healing in", role = "healIn" },
		{ key = "taken", label = "Damage taken", role = "taken", hidden = true },
	},
}

local function SeriesForView(view)
	local spec = SERIES_FOR_VIEW[view]
	local out = {}
	for i = 1, table.getn(spec) do
		out[i] = {
			key = spec[i].key,
			label = spec[i].label,
			colorHex = Theme.Series(spec[i].role),
			hidden = spec[i].hidden,
		}
	end
	return out
end

-- One recount per interaction. Every widget below is fed from `rows` (a single Session:Slice)
-- and `stats` (a single Buffs.Stats), never from its own separate pass over the session.
--
-- skipRelayout is set only by Layout()'s own trailing call: this function can discover that the
-- number of charted lanes or visible buff rows changed, which changes the window's block
-- geometry, and asks Layout() to run again -- but Layout() ends by calling back here, so the
-- second pass must not be allowed to bounce back.
function Analysis:RefreshContent(skipRelayout)
	local session = self.selectedSession
	local view = self.viewTab
	local filterWho = self.filter[view]
	local meta = VIEW_META[view]
	local showMorale = (view == "taken" or view == "healIn")

	-- Before RangeSeconds(), which divides by it: a different session (or a change to
	-- settings.bucketWidth) can change how many buckets this fight's plot has.
	self:SyncBucketCount()

	self.goalLine:SetText(meta.question)
	self:RefreshPicker()
	self:RefreshHeaderExtras()

	local fromSec, toSec = self:RangeSeconds()
	local rows = session and session:Slice(view, fromSec, toSec, filterWho) or {}
	local stats = Buffs.Stats(session, fromSec, toSec)

	-- Re-run the layout if the variable-height blocks changed shape, then let that pass do the
	-- drawing (it calls back in with skipRelayout set). Lanes come from the UNFILTERED stats --
	-- the buff search narrows which rows the table lists, not what's plotted on the graph, so a
	-- charted buff the search doesn't match still keeps its lane.
	local lanes = self:ChartedLanes(stats)
	local laneCount = table.getn(lanes)
	local buffStats = self:SortBuffStats(self:FilterBuffStats(stats))

	-- RefreshPicker (above) has already decided how many rows the chips wrap onto for this
	-- session/view/expanded state; a change there moves everything below it, same as a lane
	-- change does. The buff row count is deliberately NOT in this set any more -- the splitter
	-- fixes that block's height, so more buffs means more scrolling, not a re-layout.
	local pickerRows = self.pickerRowsWanted or 1

	if not skipRelayout and (laneCount ~= self.layoutLanes or pickerRows ~= self.layoutPickerRows) then
		self.laneCountWanted = laneCount
		self:Layout()
		return
	end
	self.laneCountWanted = laneCount

	self:RefreshKpis(session, view, filterWho, meta, rows, fromSec, toSec)

	if self.graph ~= nil then
		-- Only re-declare the series when the VIEW changed: SetSeries clears the hidden set, so
		-- doing it on every refresh would silently un-hide a series the reader had toggled off
		-- the moment they dragged a range handle or picked a different target.
		if self.graphSeriesView ~= view then
			self.graphSeriesView = view
			self.graph:SetSeriesWithMorale(SeriesForView(view), showMorale)
		end
		self.graph:SetData(session, showMorale, filterWho)
		self.graph:SetRange(self.rangeFrom, self.rangeTo)
		self.graph:SetLanes(lanes)
	end

	self:RefreshTable(rows)
	self:RefreshBuffSection(stats, buffStats, fromSec, toSec)

	if session == nil then
		self:RefreshPanel(self.panelA, { title = "", items = {} }, MetaColor(meta))
		self:RefreshPanel(self.panelB, { title = "", items = {} }, MetaColor(meta))
	else
		local dataA, dataB = self:PanelData(rows, view, filterWho)
		self:RefreshPanel(self.panelA, dataA, MetaColor(meta))
		self:RefreshPanel(self.panelB, dataB, Theme.Hex.Accent)
	end

	-- Last, and unconditionally: a chat post is a static alias string, so it goes stale the
	-- instant any of view/filter/range/session changes. Every one of those changes funnels
	-- through this function, which makes it the one correct place to rebuild -- CombatAnalysis
	-- calls its own equivalent from six scattered sites for want of a single funnel like this.
	-- This is also what shows and hides the DEATH button: its line is nil for a fight nobody died
	-- in, and a nil line is what disables it.
	self:RearmPostButtons()
end

function Analysis:RefreshKpis(session, view, filterWho, meta, rows, fromSec, toSec)
	local kpis
	if session == nil then
		kpis = {}
		for i = 1, 5 do
			kpis[i] = { label = "--", value = "--", sub = "", subColor = Theme.Hex.DimText }
		end
	else
		kpis = self:ComputeKpis(session, view, filterWho, meta, rows, fromSec, toSec)
	end

	for i = 1, 5 do
		local card = self.kpiCards[i]
		card.label:SetText(kpis[i].label)
		card.value:SetText(kpis[i].value)
		card.sub:SetText(kpis[i].sub)
		card.sub:SetForeColor(Theme.Color(kpis[i].subColor))
	end
end

function Analysis:ComputeKpis(session, category, filterWho, meta, rows, fromSec, toSec)
	local total, hits, crits, devs, max, maxSkill = 0, 0, 0, 0, 0, nil
	for i = 1, table.getn(rows) do
		local row = rows[i]
		total = total + row.total
		hits = hits + row.hits
		crits = crits + row.crits
		devs = devs + row.devs
		if row.max > max then
			max = row.max
			maxSkill = row.skill
		end
	end

	local activeSeconds = session:ActiveSeconds(fromSec, toSec)
	local rate = (activeSeconds > 0) and (total / activeSeconds) or 0

	local critPct = hits > 0 and (crits / hits) or 0
	local devPct = hits > 0 and (devs / hits) or 0

	-- The fifth card swaps role with the range: unscoped it reports how much of the fight you
	-- were actually acting in, scoped it reports which slice you are looking at -- which is the
	-- thing you most need confirmed while dragging a handle.
	local timeCard
	if fromSec == nil then
		timeCard = {
			label = "ACTIVE", value = Format.Clock(activeSeconds),
			sub = "of " .. Format.Clock(session:Duration()), subColor = Theme.Hex.DimText,
		}
	else
		timeCard = {
			label = "RANGE", value = Format.Clock(toSec - fromSec),
			sub = Format.Clock(fromSec) .. "-" .. Format.Clock(toSec), subColor = Theme.Hex.Accent300,
		}
	end

	return {
		-- Rate is the headline number and the running total is the sub-line, not the other way
		-- round -- per direct user request, in every view.
		{ label = meta.rateWord, value = Format.Rate(rate),
		  sub = Format.Number(total) .. " total", subColor = Theme.Hex.Accent300 },
		{ label = string.upper(meta.hitWord), value = Format.Number(hits),
		  sub = table.getn(rows) .. " skills", subColor = Theme.Hex.DimText },
		{ label = "CRIT / DEV", value = Format.Percent(critPct) .. " / " .. Format.Percent(devPct),
		  sub = "of " .. meta.hitWord, subColor = Theme.Hex.DimText },
		{ label = "LARGEST", value = max > 0 and Format.Number(max) or "--",
		  sub = maxSkill or "--", subColor = Theme.Hex.DimText },
		timeCard,
	}
end

---------------------------------------------------------------------------------------------------
-- Layout / resize
---------------------------------------------------------------------------------------------------

function Analysis:BuildResizeGripper()
	local gripper = Turbine.UI.Control()
	gripper:SetParent(self)
	gripper:SetSize(12, 12)
	gripper:SetBackColor(Theme.Mix(Theme.Hex.Border, Theme.Hex.WindowFill, 0.6))
	gripper:SetZOrder(5)

	local window = self
	gripper.MouseDown = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			window.resizing = true
			-- Where inside the 12x12 gripper the press landed, NOT a screen coordinate. Every
			-- MouseMove below re-reads args relative to the gripper, and Analysis:Resize keeps
			-- the gripper pinned to the corner it is dragging, so this offset is what the args
			-- return to once the window has caught up with the mouse.
			window.resizeOffsetX = args.X
			window.resizeOffsetY = args.Y
		end
	end
	-- Chrome only during the drag itself (Frame:Resize -- background/border/header/client);
	-- content stays where it was and just gets clipped/exposed by the growing/shrinking client
	-- area. Full re-layout (Analysis:Layout, which also rebuilds table columns and resizes the
	-- graph) happens once on MouseUp, not on every drag tick -- rebuilding pooled table rows and
	-- the 48-bucket graph continuously while dragging would be needless churn for a value nobody
	-- reads until the mouse comes up anyway.
	--
	-- This used to feel wildly oversensitive, and the reason was a mismatch between the two
	-- halves of that trade: the size grew by (args - press offset) every tick, which is only an
	-- INCREMENT if the gripper itself moves to match. It didn't -- the gripper's position was
	-- only ever set in Layout(), which is deferred to MouseUp -- so a mouse held 40px from the
	-- press point reported the same 40px offset on every single move event, and each one added
	-- another 40px to the window. Analysis:Resize now repositions the gripper on every call, so
	-- args really is an increment and a stationary mouse adds nothing. This is exactly what the
	-- splitter (and RangeSlider before it) already does -- both move their handle inside the
	-- MouseMove that changed the value, which is why those two track the mouse one-to-one.
	gripper.MouseMove = function(sender, args)
		if window.resizing then
			local w, h = window:GetSize()
			w = w + (args.X - window.resizeOffsetX)
			h = h + (args.Y - window.resizeOffsetY)
			local maxHeight = MaxHeight()
			if w < MIN_WIDTH then w = MIN_WIDTH elseif w > MAX_WIDTH then w = MAX_WIDTH end
			if h < MIN_HEIGHT then h = MIN_HEIGHT elseif h > maxHeight then h = maxHeight end
			window:Resize(w, h)
		end
	end
	gripper.MouseUp = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			window.resizing = false
			window:Layout()

			local w, h = window:GetSize()
			local saved = _G.settings.windows[window.windowKey]
			saved.width = w
			saved.height = h
			Settings.Save()
		end
	end

	self.gripper = gripper
end

---------------------------------------------------------------------------------------------------
-- The skill-table / buff-table splitter
---------------------------------------------------------------------------------------------------

-- The handle occupies the gap that already sat between the two blocks, so it costs no vertical
-- space. Drag shape is RangeSlider's: MouseDown records the press offset inside the handle,
-- MouseMove re-reads args.Y (relative to the handle, so it stays correct as the handle moves
-- under a still-pressed mouse) and MouseUp clears it and persists.
function Analysis:BuildSplitter()
	local splitter = Turbine.UI.Control()
	splitter:SetParent(self.contentArea)
	splitter:SetSize(1, SPLITTER_HEIGHT)
	splitter:SetMouseVisible(true)

	local grip = Turbine.UI.Control()
	grip:SetParent(splitter)
	grip:SetPosition(0, math.floor((SPLITTER_HEIGHT - SPLITTER_GRIP) / 2))
	grip:SetSize(1, SPLITTER_GRIP)
	grip:SetBackColor(Theme.Color(Theme.Hex.Border))
	grip:SetMouseVisible(false)

	local window = self

	splitter.MouseDown = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			window.splitDragging = true
			window.splitDragOffset = args.Y
			grip:SetBackColor(Theme.Color(Theme.Hex.Accent))
		end
	end

	-- Dragging DOWN grows the skill table and shrinks the bottom row, which is why the delta is
	-- subtracted. DragSplit snaps to whole buff rows and returns early when the snapped value
	-- did not change, so a full Layout() runs once per row crossed, not once per mouse pixel.
	splitter.MouseMove = function(sender, args)
		if window.splitDragging then
			window:DragSplit(args.Y - window.splitDragOffset)
		end
	end

	splitter.MouseUp = function(sender, args)
		if args.Button == Turbine.UI.MouseButton.Left then
			window.splitDragging = false
			grip:SetBackColor(Theme.Color(Theme.Hex.Border))

			local saved = _G.settings.windows[window.windowKey]
			if saved ~= nil then
				saved.split = window.splitBottom
				Settings.Save()
			end
		end
	end

	splitter.MouseEnter = function()
		if not window.splitDragging then
			grip:SetBackColor(Theme.Color(Theme.Hex.Accent200))
		end
	end
	splitter.MouseLeave = function()
		if not window.splitDragging then
			grip:SetBackColor(Theme.Color(Theme.Hex.Border))
		end
	end

	self.splitter = splitter
	self.splitterGrip = grip
end

-- Snap a bottom-row height to whole buff rows above BOTTOM_MIN, then clamp it to what the window
-- can actually give: never below its own chrome, never so tall that the skill table drops under
-- TABLE_MIN. `available` is the content height the two blocks and the gap between them share.
-- Everything here is in whole rows, including the clamp: a clamp that landed on an arbitrary
-- pixel height would not survive being snapped again on the next pass (it would round to a
-- neighbouring row), so a window that shrank and grew back would not return to the split it
-- started from.
function Analysis:SnapSplit(height, available)
	local rows = math.floor((height - BOTTOM_MIN) / BUFF_ROW_HEIGHT + 0.5)
	local maxRows = math.floor((available - SPLITTER_HEIGHT - TABLE_MIN - BOTTOM_MIN) / BUFF_ROW_HEIGHT)

	if rows > maxRows then
		rows = maxRows
	end
	if rows < 0 then
		rows = 0
	end
	return BOTTOM_MIN + rows * BUFF_ROW_HEIGHT
end

-- self.splitBottom is the user's PREFERENCE and self.splitEffective is what the window could
-- actually give it last Layout. A drag works from the effective value (that is the edge under
-- the mouse) but writes the preference, and Layout never writes the preference back -- otherwise
-- one pass at a short window height would silently overwrite the split for good, and growing the
-- window again would not restore it.
function Analysis:DragSplit(delta)
	local current = self.splitEffective or self.splitBottom
	local wanted = self:SnapSplit(current - delta, self.splitAvailable or 0)
	if wanted == current then
		return
	end
	self.splitBottom = wanted
	self:Layout()
end

function Analysis:Layout()
	local w, h = self:GetSize()
	local contentWidth = w - RAIL_WIDTH
	local contentHeight = h - self.headerHeight

	self.rail:SetSize(RAIL_WIDTH, contentHeight)
	self.railBorder:SetPosition(RAIL_WIDTH - 1, 0)
	self.railBorder:SetSize(1, contentHeight)

	self.contentArea:SetPosition(RAIL_WIDTH, 0)
	self.contentArea:SetSize(contentWidth, contentHeight)

	local innerX = PAD
	local innerWidth = math.max(200, contentWidth - PAD * 2)

	-- Tab strip: four 140px tabs from the left, the goal line filling whatever is left, and a
	-- 1px rule under the goal line continuing the inactive tabs' baseline to the window edge.
	local tabsWidth = table.getn(VIEWS) * TAB_WIDTH
	local goalX = innerX + tabsWidth
	local goalWidth = math.max(0, contentWidth - PAD - goalX)
	self.goalLine:SetPosition(goalX, 0)
	self.goalLine:SetSize(goalWidth, TAB_STRIP_HEIGHT - 3)
	self.goalRule:SetPosition(goalX, TAB_STRIP_HEIGHT - 1)
	self.goalRule:SetSize(goalWidth, 1)

	-- The picker's height depends on how many rows its chips wrap onto AT THIS WIDTH, so re-flow
	-- them here rather than trusting the count from whatever width the last pass ran at (a resize
	-- changes it). RefreshContent's trailing pass re-runs the identical flow and lands on the same
	-- number, so this and the geometry below can't disagree. RefreshPicker never calls back into
	-- Layout, so there is no bounce to guard against here.
	local pickerY = 40
	self.pickerWidth = innerWidth
	self:RefreshPicker()
	local pickerRows = math.max(1, self.pickerRowsWanted or 1)
	local pickerHeight = pickerRows * PICKER_HEIGHT + (pickerRows - 1) * PICKER_ROW_GAP
	local pickerExtra = pickerHeight - PICKER_HEIGHT

	self.pickerRow:SetPosition(innerX, pickerY)
	self.pickerRow:SetSize(innerWidth, pickerHeight)

	-- Every block below the picker shifts down by whatever the extra chip rows claimed.
	local kpiY = 72 + pickerExtra
	self.kpiRow:SetPosition(innerX, kpiY)
	self.kpiRow:SetSize(innerWidth, KPI_ROW_HEIGHT)
	self:LayoutKpiCards(innerWidth)

	-- The graph's own height depends on how many buff lanes are charted, so ask it rather than
	-- keeping a second copy of that arithmetic here.
	local graphHeight = GraphHeightFor(self.laneCountWanted or 0)

	local graphY = 133 + pickerExtra
	self.graphHolder:SetPosition(innerX, graphY)
	self.graphHolder:SetSize(innerWidth, graphHeight)
	self:LayoutGraph(innerWidth)

	local tableY = graphY + graphHeight + GAP

	-- How the leftover height is split between the skill table and the bottom row (buff table on
	-- the left, side panels on the right) is the user's call now, not the buff list's row count:
	-- self.splitBottom is what the splitter was last dragged to, re-clamped here against whatever
	-- height this window currently is. Both lists scroll, so neither ever drops rows for want of
	-- space -- shrinking one just means scrolling it (REDESIGN_SPEC.md section 7).
	local available = math.max(0, contentHeight - tableY - PAD)
	self.splitAvailable = available

	local bottomHeight = self:SnapSplit(self.splitBottom, available)
	self.splitEffective = bottomHeight

	local tableHeight = available - SPLITTER_HEIGHT - bottomHeight
	if tableHeight < TABLE_MIN then
		tableHeight = TABLE_MIN
	end

	local listWidth = innerWidth - SCROLLBAR_WIDTH
	self.tableListWidth = listWidth

	self.tableHolder:SetPosition(innerX, tableY)
	self.tableHolder:SetSize(innerWidth, tableHeight)
	self.scrollView:SetPosition(0, SEARCH_HEIGHT + ROW_HEIGHT)
	self.scrollView:SetSize(listWidth, math.max(0, tableHeight - SEARCH_HEIGHT - ROW_HEIGHT))
	self.tableScrollBar:SetPosition(listWidth, SEARCH_HEIGHT + ROW_HEIGHT)
	self.tableScrollBar:SetHeight(math.max(0, tableHeight - SEARCH_HEIGHT - ROW_HEIGHT))
	self:RefreshTableColumns(listWidth)

	-- The splitter sits in the band between the two blocks, spanning the full content column so
	-- it reads as one continuous edge rather than a widget parked over one of them.
	self.splitter:SetPosition(innerX, tableY + tableHeight)
	self.splitter:SetSize(innerWidth, SPLITTER_HEIGHT)
	self.splitterGrip:SetSize(innerWidth, SPLITTER_GRIP)

	local bottomY = tableY + tableHeight + SPLITTER_HEIGHT
	local panelsWidth = PANEL_WIDTH
	local buffWidth = math.max(200, innerWidth - GAP - panelsWidth)

	self.buffHolder:SetPosition(innerX, bottomY)
	self.buffHolder:SetSize(buffWidth, bottomHeight)
	self.buffTopRule:SetSize(buffWidth, 1)
	self.buffHeader.control:SetSize(buffWidth, BUFF_HEADER_HEIGHT)
	self.buffHeader.summary:SetSize(math.max(0, buffWidth - 96), BUFF_HEADER_HEIGHT)
	self.buffTableHeader:SetPosition(0, BUFF_HEADER_HEIGHT + 1 + SEARCH_HEIGHT)

	local buffListWidth = math.max(0, buffWidth - SCROLLBAR_WIDTH)
	self:LayoutBuffColumns(buffListWidth)

	local buffListY = BUFF_HEADER_HEIGHT + 1 + SEARCH_HEIGHT + BUFF_TABLE_HEADER_HEIGHT
	local buffListHeight = math.max(0, bottomHeight - buffListY)
	self.buffScrollView:SetPosition(0, buffListY)
	self.buffScrollView:SetSize(buffListWidth, buffListHeight)
	self.buffScrollBar:SetPosition(buffListWidth, buffListY)
	self.buffScrollBar:SetHeight(buffListHeight)

	self.panelsHolder:SetPosition(innerX + buffWidth + GAP, bottomY)
	self.panelsHolder:SetSize(panelsWidth, bottomHeight)
	local panelHeight = math.max(20, math.floor((bottomHeight - GAP) / 2))
	self.panelA.holder:SetPosition(0, 0)
	self.panelA.holder:SetSize(panelsWidth, panelHeight)
	self.panelB.holder:SetPosition(0, panelHeight + GAP)
	self.panelB.holder:SetSize(panelsWidth, panelHeight)

	self.gripper:SetPosition(w - 12, h - 12)

	-- Record what this pass sized things for, so RefreshContent can tell whether the shape
	-- changed and skip re-entering here when it did not.
	self.layoutLanes = self.laneCountWanted or 0
	self.layoutPickerRows = pickerRows

	self:RefreshContent(true)
end

function Analysis:LayoutKpiCards(innerWidth)
	local cardWidth = math.floor((innerWidth - 4 * 8) / 5)
	local x = 0
	for i = 1, 5 do
		local card = self.kpiCards[i]
		card.control:SetPosition(x, 0)
		card.control:SetSize(cardWidth, KPI_ROW_HEIGHT)
		card.border:SetSize(cardWidth, KPI_ROW_HEIGHT)
		card.label:SetSize(cardWidth - 16, 12)
		card.value:SetSize(cardWidth - 16, 20)
		card.sub:SetSize(cardWidth - 16, 12)
		x = x + cardWidth + 8
	end
end

-- The graph's rotation pass, and the ONLY thing this window wants per-frame updates for.
--
-- Every polyline segment is a rotated Window, and the fact six in-game rounds of probing cost most
-- to establish is that **a rotation applied before the control has painted is silently dropped**. So
-- Graph:Redraw sizes and positions the segments and arms a pass, and this runs it a couple of
-- frames later, once. FlushRotation returns immediately when nothing is pending, which is the
-- common case by a very long way.
-- Drives the graph's rotation pass -- but only while this window is actually on screen. A redraw
-- can happen with the window closed (a fight ending reaches RefreshContent through
-- Sessions.OnClosed, and every settings change does too), and a rotation applied to a control
-- that is not being drawn is the "set before it painted" case the engine silently drops -- which
-- would then reveal those segments FLAT, staying that way until some later redraw ran a fresh
-- pass. That is the reported "sometimes the lines are not rotated, moving the range fixes it".
--
-- So: hold the pass while hidden, and arm a fresh one on the way back in, which covers every path
-- that shows this window without any of them having to know about it.
-- The visible/hidden edge, split out of Update because **Update does not run while this window is
-- hidden** -- a Turbine.UI.Window only receives per-frame Update() once it is shown (Events.lua's
-- heartbeat is a bare Window kept visible for exactly that reason). Left inside Update, the
-- `wasVisible = false` line below could therefore never actually execute: the flag stayed true
-- across a close/reopen, no pass was armed on the way back in, and the plot came up carrying
-- whatever the engine had left on those segments while they were off screen. That is the reported
-- "the first line graph after opening the window is broken, and any later redraw fixes it".
--
-- So the falling edge is watched by Events.lua's 4Hz heartbeat, which runs whatever this window is
-- doing, and the rising edge by Update itself, which is prompt. Being up to 250ms late noticing a
-- close costs nothing -- nothing is drawn in that time either.
function Analysis:TrackVisibility()
	if self.graph == nil then
		return
	end

	if not self:IsVisible() then
		self.wasVisible = false
		return
	end

	if not self.wasVisible then
		self.wasVisible = true
		self.graph:ArmRotation()
	end
end

function Analysis:Update()
	if self.graph == nil then
		return
	end

	self:TrackVisibility()

	if not self:IsVisible() then
		return
	end

	local pending = self.graph:FlushRotation()

	-- Backstop: hold this window's own rotation at zero for as long as a pass is running, and for
	-- one frame after it finishes. The graph's pass is the only SetRotation caller in the plugin
	-- and it has been seen to turn THIS window rather than a segment (reported as the analysis
	-- window coming up rotated after a session change). Graph:FlushRotation now never hands a
	-- hidden control to SetRotation, which is the condition that caused it -- this is the second
	-- line of defence, so that if it ever happens again it self-corrects in a frame instead of
	-- leaving the window sideways until a reload. Identity rotation on a window that is on screen
	-- is a no-op, and outside a pass this costs nothing at all.
	if pending or self.rotationPass then
		pcall(self.SetRotation, self, ZERO_ROTATION)
	end
	self.rotationPass = pending
end

function Analysis:LayoutGraph(innerWidth)
	if self.graph == nil then
		local window = self
		self.graph = Graph(innerWidth)
		self.graph:SetParent(self.graphHolder)
		self.graph:SetPosition(0, 0)
		self.graph.OnRangeChanged = function(from, to) window:OnRangeChanged(from, to) end
		-- Clicking a lane icon un-charts that buff -- the same toggle the buff table's checkbox
		-- calls, so the table's checkbox clears in the same refresh.
		self.graph.OnLaneRemoved = function(name) window:ToggleCharted(name) end
	elseif self.graph.plotWidth ~= innerWidth then
		self.graph:Resize(innerWidth)
	end
end
