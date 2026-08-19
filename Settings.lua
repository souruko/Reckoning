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
	windows           = {},    -- [windowKey] = { left, top, width?, height? } -- persisted window geometry
}

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
	Settings.Save()
end

function Settings.Save()
	Turbine.PluginData.Save(Turbine.DataScope.Character, "Reckoning", _G.settings)
end
