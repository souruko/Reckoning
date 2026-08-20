--=================================================================================================
-- Constants -- fonts, theme palette, parser enums.
--=================================================================================================

Reckoning = Reckoning or {}
Reckoning.Version = "0.2.0"

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

-- Full avoids (amount 0, dmgType 13) vs. partials (8-10, on a real hit). Deflected (11) is a
-- full avoid despite sorting numerically after the partials -- do not derive this with a
-- numeric range check.
AvoidType.FullSet = {
	[AvoidType.Missed]   = true,
	[AvoidType.Immune]   = true,
	[AvoidType.Resisted] = true,
	[AvoidType.Blocked]  = true,
	[AvoidType.Parried]  = true,
	[AvoidType.Evaded]   = true,
	[AvoidType.Deflected]= true,
}

function AvoidType.IsFull(avoidType)
	return AvoidType.FullSet[avoidType] == true
end

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

-- Display names, for the death window's "skill · type" column and any future type-split UI.
DamageType.Names = {
	[DamageType.Common]           = "Common",
	[DamageType.Fire]              = "Fire",
	[DamageType.Lightning]         = "Lightning",
	[DamageType.Frost]             = "Frost",
	[DamageType.Acid]              = "Acid",
	[DamageType.Shadow]            = "Shadow",
	[DamageType.Light]             = "Light",
	[DamageType.Beleriand]         = "Beleriand",
	[DamageType.Westernesse]       = "Westernesse",
	[DamageType.AncientDwarfMake]  = "Ancient Dwarf-make",
	[DamageType.OrcCraft]          = "Orc-craft",
	[DamageType.FellWrought]       = "Fell-wrought",
	[DamageType.Unknown]           = "Unknown",
}

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
	-- Accent tint scale -- pulled from the mockup's own CSS custom properties
	-- (--color-accent-NNN), since docs/DESIGN.md names these without giving hex. 200 is
	-- selected-tab/chip text, 300 is the "text-safe" rate/clock tint, 500 is the death-window
	-- countdown fill, 700 is the pinned/selected border.
	Accent200    = "#e7e5fe",
	Accent300    = "#d2cefd",
	Accent500    = "#968ae0",
	Accent700    = "#5d5294",
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
	-- Death window row marks: the killing blow and the biggest single hit are the two rows
	-- worth calling out, and they are often not the same row -- see UI/DeathCause.lua.
	DeathKillFill  = "#33222e",
	DeathMaxFill   = "#2b2438",
	DeathMoraleTrack = "#3a2b3c",
	-- damage-type colours
	TypeCommon   = "#9184d9",
	TypeBeleriand= "#b5abfc",
	TypeFire     = "#e3a3ba",
	TypeLight    = "#a7a1db",
	TypeShadow   = "#c98fa8",
	-- shared interaction/role tokens named directly in docs/DESIGN.md prose
	Hover        = "#2b2e3e", -- "Hover on any clickable row/chip/tab" (docs/DESIGN.md "Interactions")
	MeterDivider = "#33364a", -- live meter's own divider, distinct from the generic Border token
	ActiveTab    = "#282a3d", -- selected tab / selected chip fill
	KpiFill      = "#222534", -- KPI card ground, one step up from WindowFill
	Disabled     = "#5c5f70", -- inert control text (an unpinned pin, a spent RESET RANGE)

	-- The plot gets its own recessed ground, so the line and the morale bars read against
	-- something darker than the window fill rather than floating on it.
	PlotFill     = "#1d1f2d",
	PlotBorder   = "#262939", -- also the buff lanes' rail colour
	RangeDim     = "#161826", -- out-of-range plot wash, mixed at ~0.72 over PlotFill

	-- Morale as a background bar graph (UI/AnalysisGraph.lua): a fill plus a brighter 1px top
	-- edge, so a bar reads as a bar and not as a flat wash. Two pairs -- normal, and below the
	-- MORALE_DANGER threshold -- plus the two guide lines at 100% and 50%.
	MoraleBg        = "#302e21",
	MoraleBgEdge    = "#5f5936",
	MoraleBgLow     = "#3f2a30",
	MoraleBgLowEdge = "#7d5563",
	MoraleGuide     = "#3b3722", -- 100% guide line
	MoraleGuideMid  = "#302f26", -- 50% guide line
	MoraleLegend    = "#3d3a26", -- the legend's non-interactive morale swatch
	MoraleLegendText = "#8a8468",
}

-- Morale fraction below which a bucket's background bar switches to the "low" pair above.
MORALE_DANGER = 0.30

-- Buff lane colours, in pick order -- a charted self-buff takes the next free one for its lane,
-- its row checkbox, its icon border and its name (UI/Analysis.lua's buff table). Max 3 charted
-- at once, which is exactly why this list has three entries.
Theme.BuffLane = { "#9184d9", "#b5abfc", "#7fb3a6" }

---------------------------------------------------------------------------------------------------
-- Formatting -- shared across every window that prints a number to a Label.
---------------------------------------------------------------------------------------------------
Format = {}

-- "4812" -> "4,812". Mirrors VitalSelf/Main.lua's format_number: never call this from a
-- per-frame Update() with anything heavier than the throttled refreshes these windows use.
function Format.Number(value)
	if value == nil then
		return "0"
	end
	local text = string.format("%.0f", value)
	local sign, int = string.match(text, "^(%-?)(%d+)$")
	if int == nil then
		return text
	end
	local count = 1
	while count > 0 do
		int, count = string.gsub(int, "^(%d+)(%d%d%d)", "%1,%2")
	end
	return sign .. int
end

function Format.Percent(fraction)
	if fraction == nil then
		return "0%"
	end
	return string.format("%.0f%%", fraction * 100)
end

function Format.Rate(perSecond)
	return Format.Number(perSecond) .. "/s"
end

-- Elapsed seconds -> "MM:SS", for the live meter's header clock and session durations.
function Format.Clock(seconds)
	seconds = math.floor(seconds or 0)
	local m = math.floor(seconds / 60)
	local s = seconds % 60
	return string.format("%02d:%02d", m, s)
end

-- "#RRGGBB..." -> r, g, b floats in [0,1]. Reads only the first 6 hex digits -- alpha (an 8th
-- and 9th digit on the mockup's CSS tokens) is handled separately by Theme.Mix, never by Color.
function Theme.RGB(hex)
	local r = tonumber(string.sub(hex, 2, 3), 16)
	local g = tonumber(string.sub(hex, 4, 5), 16)
	local b = tonumber(string.sub(hex, 6, 7), 16)
	return r / 255, g / 255, b / 255
end

function Theme.Color(hex)
	local r, g, b = Theme.RGB(hex)
	return Turbine.UI.Color(r, g, b)
end

-- Blends fgHex over bgHex at ratio t (0 = all bg, 1 = all fg) and returns a solid
-- Turbine.UI.Color. This is how the mockup's alpha-hex tint tokens (e.g. "#9184d91c", a
-- selected-row wash) get approximated -- NOT SetOpacity. Confirmed in-game:
-- Turbine.UI.Control:SetOpacity() on a Control with its own solid BackColor does not blend --
-- it renders the BackColor at full strength regardless of the opacity value. Real plugins never
-- use SetOpacity that way either (grepped across VitalSelf/Gibberish3/CombatAnalysis/LootLogs);
-- the working, repeated pattern is exactly this precomputed-blend approach (LootLogs calls its
-- version MixColor). SetOpacity stays legitimate for whole-window fades (VitalSelf's
-- incombat/outcombat opacity on a Window) -- just never for a tint over a solid fill.
function Theme.Mix(fgHex, bgHex, t)
	local fr, fg, fb = Theme.RGB(fgHex)
	local br, bg, bb = Theme.RGB(bgHex)
	return Turbine.UI.Color(
		fr * t + br * (1 - t),
		fg * t + bg * (1 - t),
		fb * t + bb * (1 - t))
end

-- Accepts either a plain "#RRGGBB" token or an 8-digit "#RRGGBBAA" alpha token (as the mockup's
-- CSS uses) and always returns a solid Turbine.UI.Color -- alpha tokens are blended against
-- bgHex (default WindowFill) via Theme.Mix. Use this instead of Theme.Color wherever an
-- arbitrary hex string flows through as a parameter (e.g. Bar's trackHex) and might be either
-- kind -- a bare Theme.Color would silently truncate an alpha token to its RGB, which reads as
-- solid white for anything built on "#ffffffXX" (this is exactly how the KPI card background
-- bug happened -- see git history).
function Theme.AlphaColor(hex, bgHex)
	if string.len(hex) > 7 then
		local a = tonumber(string.sub(hex, 8, 9), 16) / 255
		return Theme.Mix(string.sub(hex, 1, 7), bgHex or Theme.Hex.WindowFill, a)
	end
	return Theme.Color(hex)
end
