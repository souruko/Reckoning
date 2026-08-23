--=================================================================================================
-- Settings -- load/save via Turbine.PluginData, following the VitalSelf pattern.
--=================================================================================================

Settings = {}

-- Single source of truth for every setting key and its default. Anything added here is merged
-- into an existing save on load, so upgrading a character never leaves a key nil.
-- Pins are NOT here: docs/DESIGN.md decided pins are play-session-only (sessions themselves are
-- never persisted), so pin state lives directly on the in-memory Session object
-- (Sessions.TogglePin, in Sessions.lua) and never touches _G.settings at all.
DEFAULTS = {
	liveTab           = 1,     -- 1 Done / 2 Taken / 3 Heal out / 4 Heal in (docs/DESIGN.md "State")
	deathAutoHide     = 15,    -- seconds, 5-30
	liveMeterEnabled  = true,  -- Phase 6 options panel
	deathCauseEnabled = true,  -- Phase 6 options panel
	-- [windowKey] = { left, top, width?, height?, split? } -- persisted window geometry. `split`
	-- is analysis-only: how much height its bottom row (SELF BUFFS + side panels) was last
	-- dragged to, in pixels, re-clamped on load against the window's actual height.
	windows           = {},
	-- Analysis window's SELF BUFFS section. Strings only, never a Turbine.UI.Color: chartedBuffs
	-- is an ordered list of at most 3 buff NAMES (the lane colour is derived from its position
	-- in that list at render time, so no colour is ever serialised), and buffIgnore is a
	-- [name] = true set extended by `/reck buffs ignore <name>`.
	chartedBuffs      = {},
	buffIgnore        = {},
	-- Chat posting (ChatPost.lua, UI/PostButton.lua). All four are scalars, so none of them needs
	-- the fresh-{}-on-merge treatment the two tables above do.
	postChannel       = "say",     -- a ChatPost.Channels key; /reck post is the local preview
	postPreset        = "summary", -- "summary" | "death"
	-- No postRows: the summary posts the largest hit rather than a skill list, so there is
	-- nothing left to size. postColor governs the real post, budgeted against MAX_MESSAGE.
	postColor         = true,

	-- ---------------------------------------------------------------------------------------
	-- Options window (design_handoff_options_panel/SETTINGS_KEYS.md). Every key below is edited
	-- from UI/OptionsWindow.lua and written the moment its control changes -- there is no Accept.
	-- ---------------------------------------------------------------------------------------

	-- appearance
	palettePreset      = "Reckoning", -- a KEY into Theme.Presets; a name, never a colour
	opacityCombat      = 100,  -- 40-100
	opacityIdle        = 55,   -- 20-100
	idleFadeEnabled    = true,
	idleFadeAfter      = 20,   -- 5-120s
	clickThroughFaded  = false,
	density            = "Normal", -- "Compact" | "Normal"
	numberFont         = "Lucida", -- "Lucida" | "Verdana"
	abbreviateNumbers  = true,
	showBorders        = true,
	typeColoredBars    = false,

	-- windows
	lockWindows        = false,
	analysisAutoOpen   = false,

	-- live meter
	liveRows           = 5,    -- 3-10
	-- "Both" rather than the handoff's "Rate": Both is exactly today's shipped headline (rate
	-- prominent, total in the corner), which came from direct user feedback, so the feature
	-- landing changes nothing until it is asked to. See UI/LiveMeter.lua's Refresh.
	liveBarValue       = "Both", -- "Rate" | "Total" | "Both"
	sparkline          = true,
	sparklineWindow    = 30,   -- 10-60s
	refreshHz          = 10,   -- 2 | 5 | 10
	clockThroughAvoids = true,
	announceSummary    = false,
	-- Strips the meter down to the clock, the tab row and the headline number (260x76 instead of
	-- 260x186). A display mode on the same window -- nothing is torn down, see LiveMeter:ApplyMode.
	compactMode        = false,

	-- death window
	deathStayOpen      = false,
	deathRows          = 8,    -- 3-12
	deathLookback      = 10,   -- 5-30s
	deathMarkKill      = true,
	deathMarkMax       = true,
	deathMoraleTrack   = true,
	deathIncludeAvoids = false,
	deathShowType      = true,

	-- self buffs
	hideStaticBuffs    = true,

	-- sessions
	idleTimeout        = 8,    -- 3-30s
	minFightLength     = 3,    -- 0-15s
	sessionsKept       = 25,   -- 10 | 25 | 50
	mergeFights        = true,
	dropOnZoneChange   = false,
	bucketWidth        = 1,    -- 1 | 2 | 0 == Auto
}

-- Every numeric setting a slider edits, with the range that slider offers. A save can carry a
-- value outside its range -- hand-edited, or written by a version whose range was wider -- and a
-- number the UI cannot represent is worse than a clamped one: the slider would show its own
-- clamped position while the rest of the plugin acted on the stored value. ClampSettings() runs
-- on load AND on reset, so every consumer can read these without re-checking.
local CLAMPS = {
	opacityCombat = { 40, 100 }, opacityIdle = { 20, 100 }, idleFadeAfter = { 5, 120 },
	liveRows = { 3, 10 }, sparklineWindow = { 10, 60 },
	deathAutoHide = { 5, 30 }, deathRows = { 3, 12 }, deathLookback = { 5, 30 },
	idleTimeout = { 3, 30 }, minFightLength = { 0, 15 },
}

-- Enum-valued settings: the allowed set, and what an unrecognised value falls back to. A bad
-- string here is not a cosmetic problem -- `Theme.Presets[name]` returning nil would put a nil
-- hex into Theme.Color, and a nil font into SetFont.
local ENUMS = {
	density      = { Compact = true, Normal = true },
	numberFont   = { Lucida = true, Verdana = true },
	liveBarValue = { Rate = true, Total = true, Both = true },
	refreshHz    = { [2] = true, [5] = true, [10] = true },
	sessionsKept = { [10] = true, [25] = true, [50] = true },
	bucketWidth  = { [0] = true, [1] = true, [2] = true },
	liveTab      = { [1] = true, [2] = true, [3] = true, [4] = true },
}

local function ClampSettings()
	for key, range in pairs(CLAMPS) do
		local value = tonumber(_G.settings[key])
		if value == nil then
			value = DEFAULTS[key]
		end
		value = math.floor(value)
		if value < range[1] then value = range[1] end
		if value > range[2] then value = range[2] end
		_G.settings[key] = value
	end

	for key, allowed in pairs(ENUMS) do
		local value = _G.settings[key]
		-- The numeric enums (refreshHz, sessionsKept, bucketWidth, liveTab) come back from
		-- PluginData as numbers, but a hand-edited save can hold the string "10" -- tonumber
		-- first so `allowed[value]` looks the value up under the type the table is keyed by.
		if type(DEFAULTS[key]) == "number" then
			value = tonumber(value)
		end
		if value == nil or allowed[value] ~= true then
			value = DEFAULTS[key]
		end
		_G.settings[key] = value
	end

	-- Theme.Presets is the authority for palettePreset, not a list duplicated here -- adding a
	-- preset in Constants.lua must not also need an edit in this file. Constants.lua is imported
	-- before Settings.Load() runs (Main.lua), so the table exists by now; the type check keeps
	-- this honest if that import order is ever changed.
	if type(Theme) ~= "table" or type(Theme.Presets) ~= "table"
		or Theme.Presets[_G.settings.palettePreset] == nil then
		_G.settings.palettePreset = DEFAULTS.palettePreset
	end
end

Settings.Clamp = ClampSettings

-- Every colour setting must be listed here. Turbine.UI.Color objects do not survive
-- serialization -- they come back as plain {R,G,B} tables and have to be rebuilt. Empty for now:
-- the palette in Constants.lua is fixed design tokens, not user settings. A future options-panel
-- colour override (docs/IMPLEMENTATION_PLAN.md Phase 6) would add its key here and to DEFAULTS.
COLOR_KEYS = {}

local function IsColorKey(key)
	for i = 1, table.getn(COLOR_KEYS) do
		if COLOR_KEYS[i] == key then
			return true
		end
	end
	return false
end

-- Rebuilds every colour key from its plain {R,G,B} save-table into a real Turbine.UI.Color.
-- Must run after the DEFAULTS merge below, and after any future settings migration.
function Settings.FixColors()
	for i = 1, table.getn(COLOR_KEYS) do
		local key = COLOR_KEYS[i]
		local c = _G.settings[key]
		if type(c) == "table" and c["R"] ~= nil and c["G"] ~= nil and c["B"] ~= nil then
			_G.settings[key] = Turbine.UI.Color(c["R"], c["G"], c["B"])
		else
			local d = DEFAULTS[key]
			_G.settings[key] = Turbine.UI.Color(d["R"], d["G"], d["B"])
		end
	end
end

function Settings.Load()
	local saved = Turbine.PluginData.Load(Turbine.DataScope.Character, "Reckoning")

	if type(saved) == "table" then
		_G.settings = saved
	else
		_G.settings = {}
	end

	-- Read unknown keys defensively: merge in anything the save predates. Table-valued defaults
	-- (currently just `windows`) get a *fresh* empty table, never DEFAULTS' own table object --
	-- aliasing it would mean every mutation of _G.settings.windows (every drag, every resize)
	-- silently corrupts DEFAULTS.windows too, which Options.ResetToDefaults() then reads.
	for key, value in pairs(DEFAULTS) do
		if _G.settings[key] == nil then
			if IsColorKey(key) then
				_G.settings[key] = { R = value["R"], G = value["G"], B = value["B"] }
			elseif type(value) == "table" then
				_G.settings[key] = {}
			else
				_G.settings[key] = value
			end
		end
	end

	Settings.FixColors()
	ClampSettings()
end

-- Resets every setting to DEFAULTS (see the table-copy note above -- table-valued defaults get
-- a fresh table, not DEFAULTS' own). Used by /reck reset.
function Settings.ResetToDefaults()
	_G.settings = {}
	for key, value in pairs(DEFAULTS) do
		if type(value) == "table" then
			_G.settings[key] = {}
		else
			_G.settings[key] = value
		end
	end
	Settings.FixColors()
	ClampSettings()
	Settings.Save()
end

function Settings.Save()
	Turbine.PluginData.Save(Turbine.DataScope.Character, "Reckoning", _G.settings)
end

---------------------------------------------------------------------------------------------------
-- Window geometry
---------------------------------------------------------------------------------------------------

-- Which root-level global owns each _G.settings.windows key. Lives here rather than in Main.lua
-- because both callers of the reset below are elsewhere: /reck move <name> and the options
-- window's per-window Reset buttons.
local WINDOW_GLOBALS = {
	liveMeter = "liveMeter", deathCause = "deathCause",
	analysis = "analysis", options = "optionsWindow",
}

function Settings.Window(windowKey)
	local name = WINDOW_GLOBALS[windowKey]
	return name and _G[name] or nil
end

-- Puts one window back at (200, 200) and clears whatever size and splitter position it had saved.
-- There must be exactly one definition of what "Reset" does to a window, because two surfaces
-- offer it (/reck move, and a button per row on the options window's Windows page).
--
-- Returns false for an unknown key or a window that does not exist yet, so a caller can tell a
-- typo apart from a successful reset.
function Settings.ResetWindow(windowKey)
	local window = Settings.Window(windowKey)
	if window == nil then
		return false
	end

	-- The analysis window owns its own reset: it has a size and a splitter position to restore,
	-- not just a position, and it has to re-lay out afterwards.
	if window.ResetGeometry ~= nil then
		window:ResetGeometry()
	else
		window:SetPosition(200, 200)
	end

	-- Replacing the table rather than mutating it is right HERE and only here -- clearing the
	-- saved size and split IS the point of a reset. Everywhere else must mutate it (see Frame's
	-- drag handler, which used to throw the analysis window's size away on every single drag).
	_G.settings.windows[windowKey] = { left = 200, top = 200 }
	Settings.Save()
	return true
end
