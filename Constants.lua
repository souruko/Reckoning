--=================================================================================================
-- Constants -- fonts, theme palette, parser enums.
--=================================================================================================

Reckoning = Reckoning or {}
Reckoning.Version = "0.1.0"

---------------------------------------------------------------------------------------------------
-- Localisation
---------------------------------------------------------------------------------------------------
-- Only English is wired up so far. Trigger.ParseCombatChat (Parse/en.lua, ported verbatim from
-- Gibberish3) falls back to L.DirectDamage as the skill name for a hit with no named skill.
-- Gibberish3 itself never defines this key -- it is dead in the source this was ported from --
-- so it is defined directly here instead of leaving skillName nil.
L = {}
L.DirectDamage = "Direct Damage"

---------------------------------------------------------------------------------------------------
-- Trigger.ParseCombatChat event codes (docs/DESIGN.md "The parser")
---------------------------------------------------------------------------------------------------
EventCode = {}
EventCode.Damage         = 1
EventCode.Heal           = 3
EventCode.PowerHeal      = 4   -- ignored: power is not tracked
EventCode.Interrupt      = 7   -- ignored
EventCode.Dispel         = 8   -- ignored
EventCode.Defeat         = 9
EventCode.Revive         = 10
EventCode.TempMoraleLoss = 14
EventCode.StateBreak     = 16  -- ignored
EventCode.Buff           = 17  -- ignored

---------------------------------------------------------------------------------------------------
-- avoidType -- full avoids (2-7, 11) arrive as event 1 with amount == 0 and dmgType == 13;
-- partials (8-10) arrive on a real hit with a real amount. Both come down the damage stream.
---------------------------------------------------------------------------------------------------
AvoidType = {}
AvoidType.None         = 1  -- a clean hit
AvoidType.Missed       = 2
AvoidType.Immune       = 3
AvoidType.Resisted     = 4
AvoidType.Blocked      = 5
AvoidType.Parried      = 6
AvoidType.Evaded       = 7
AvoidType.PartialBlock = 8
AvoidType.PartialParry = 9
AvoidType.PartialEvade = 10
AvoidType.Deflected    = 11

---------------------------------------------------------------------------------------------------
-- critType -- present on both damage and heal lines. Keep 2 and 3 in separate counters; never sum.
---------------------------------------------------------------------------------------------------
CritType = {}
CritType.Normal      = 1
CritType.Critical    = 2
CritType.Devastating = 3

---------------------------------------------------------------------------------------------------
-- dmgType -- 13 covers absorbs and any line with no stated type; exclude it from the type split.
---------------------------------------------------------------------------------------------------
DamageType = {}
DamageType.Common           = 1
DamageType.Fire             = 2
DamageType.Lightning        = 3
DamageType.Frost            = 4
DamageType.Acid             = 5
DamageType.Shadow           = 6
DamageType.Light            = 7
DamageType.Beleriand        = 8
DamageType.Westernesse      = 9
DamageType.AncientDwarfMake = 10
DamageType.OrcCraft         = 11
DamageType.FellWrought      = 12
DamageType.Unknown          = 13

---------------------------------------------------------------------------------------------------
-- Fonts -- only the faces/sizes docs/DESIGN.md "Type" actually uses. The client has no
-- Verdana 11 or 13 -- do not interpolate.
---------------------------------------------------------------------------------------------------
Font = {}
Font.Verdana10       = Turbine.UI.Lotro.Font.Verdana10
Font.Verdana12       = Turbine.UI.Lotro.Font.Verdana12
Font.Verdana20       = Turbine.UI.Lotro.Font.Verdana20
Font.Verdana22       = Turbine.UI.Lotro.Font.Verdana22
Font.TrajanPro13     = Turbine.UI.Lotro.Font.TrajanPro13
Font.TrajanPro16     = Turbine.UI.Lotro.Font.TrajanPro16
Font.LucidaConsole12 = Turbine.UI.Lotro.Font.LucidaConsole12

---------------------------------------------------------------------------------------------------
-- Theme palette (docs/DESIGN.md "Design tokens") -- fixed design tokens, not user settings.
-- Plain "#RRGGBB"/"#RRGGBBAA" strings so they can be dropped straight into UI code next to the
-- mockup's own values; Theme.Color() turns one into a real Turbine.UI.Color on demand. Never cache
-- that result in _G.settings -- Turbine.UI.Color does not survive PluginData serialization
-- (see Settings.lua).
---------------------------------------------------------------------------------------------------
Theme = {}
Theme.Hex = {
	AppGround    = "#161826",
	WindowFill   = "#212433",
	RailFill     = "#1e202d",
	HeaderFill   = "#20222f",
	PanelFill    = "#ffffff05",
	Border       = "#2e3140",
	RowBorder    = "#2a2c3a",
	Text         = "#e9e9ed",
	MutedText    = "#a9abb8",
	DimText      = "#8b8d9b",
	Accent       = "#9184d9",
	AccentLight  = "#b5abfc",
	DamageDone   = "#9184d9",
	DamageTaken  = "#c98fa8",
	DamageSevere = "#e3a3ba",
	DamageFatal  = "#f0b7c9",
	HealingDone  = "#7fb3a6",
	HealingTaken = "#9dc7bc",
	Morale       = "#e6d98f",
	DeathFill    = "#251e2c",
	DeathBorder  = "#4a3348",
	DeathRule    = "#453042",
	-- damage-type colours
	TypeCommon   = "#9184d9",
	TypeBeleriand= "#b5abfc",
	TypeFire     = "#e3a3ba",
	TypeLight    = "#a7a1db",
	TypeShadow   = "#c98fa8",
}

-- "#RRGGBB..." -> Turbine.UI.Color. Reads only the first 6 hex digits; the mockup's 8-digit
-- values carry a CSS alpha that has no Color equivalent here and is applied separately
-- (SetOpacity or a dedicated fill) wherever a token with alpha is actually used.
function Theme.Color(hex)
	local r = tonumber(string.sub(hex, 2, 3), 16)
	local g = tonumber(string.sub(hex, 4, 5), 16)
	local b = tonumber(string.sub(hex, 6, 7), 16)
	return Turbine.UI.Color(r / 255, g / 255, b / 255)
end
