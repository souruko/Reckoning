--=================================================================================================
-- Settings -- load/save via Turbine.PluginData, following the VitalSelf pattern.
--=================================================================================================

Settings = {}

-- Single source of truth for every setting key and its default. Anything added here is merged
-- into an existing save on load, so upgrading a character never leaves a key nil.
DEFAULTS = {
	liveTab       = 1,   -- 1 Done / 2 Taken / 3 Heal out / 4 Heal in (docs/DESIGN.md "State")
	deathAutoHide = 15,  -- seconds, 5-30
	windows       = {},  -- [windowKey] = { left, top } -- persisted window positions
	pinned        = {},  -- [sessionKey] = true -- for-the-play-session pin flags
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

	-- Read unknown keys defensively: merge in anything the save predates.
	for key, value in pairs(DEFAULTS) do
		if _G.settings[key] == nil then
			if IsColorKey(key) then
				_G.settings[key] = { R = value["R"], G = value["G"], B = value["B"] }
			else
				_G.settings[key] = value
			end
		end
	end

	Settings.FixColors()
end

function Settings.Save()
	Turbine.PluginData.Save(Turbine.DataScope.Character, "Reckoning", _G.settings)
end
