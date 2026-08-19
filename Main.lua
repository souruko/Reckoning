---------------------------------------------------------------------
--== Import ===--
---------------------------------------------------------------------

import "Turbine.Gameplay"
import "Turbine.UI"
import "Turbine.UI.Lotro"

import "Reckoning.Utils.Type"
import "Reckoning.Utils.Class"

import "Reckoning.Constants"

-- Trigger.ParseCombatChat (Parse/en.lua) is `function Trigger.ParseCombatChat(...)` --
-- it attaches to an existing table rather than declaring its own global, so Trigger must
-- exist before that file loads. Mirrors Gibberish3's Variables.lua, where the same table
-- is declared before UTILS/COMBATCHATPARSE/en.lua.
Trigger = {}

import "Reckoning.Parse.en"

import "Reckoning.Settings"

---------------------------------------------------------------------
--== Globals ===--
---------------------------------------------------------------------

_G.lp = Turbine.Gameplay.LocalPlayer:GetInstance()

-- Trigger.ParseCombatChat reads the bare global `LocalPlayer.name` directly. That is NOT a real
-- Turbine property -- confirmed in-game (an empty session every fight) and by grepping every
-- other plugin: nothing ever assigns `.name` on a Turbine.Gameplay instance, only `:GetName()`
-- exists. Even Gibberish3's own Variables.lua immediately calls `:GetName()` and stashes it
-- elsewhere (`LpData.name`) rather than trusting bare `.name` -- the parser's own `LocalPlayer.name`
-- reads were always dead code there too, just never exercised. CombatAnalysis hits this exact
-- same gap and fixes it the same way: monkey-patch a real `.name` field on once at load.
LocalPlayer = _G.lp
LocalPlayer.name = LocalPlayer:GetName()

---------------------------------------------------------------------
--== Settings ===--
---------------------------------------------------------------------

Settings.Load()

---------------------------------------------------------------------
--== Event pipeline ===--
---------------------------------------------------------------------
-- Session (the class) before Sessions (the manager, which instantiates it) before Events
-- (which dispatches into the manager and needs Sessions/LocalPlayer/Trigger already defined).

import "Reckoning.Session"
import "Reckoning.Sessions"
import "Reckoning.Events"

---------------------------------------------------------------------
--== UI ===--
---------------------------------------------------------------------
-- Frame/Bar/Row (chrome primitives) first, then each window module as it's built. Reads
-- Theme/Font (Constants.lua) and _G.settings.windows (Settings.lua), both already loaded above.

import "Reckoning.UI"

liveMeter = UI.LiveMeter()
deathCause = UI.DeathCause()
analysis = UI.Analysis()

optionsPanel = UI.Options()

plugin.GetOptionsPanel = function(self)
	return optionsPanel
end

---------------------------------------------------------------------
--== Shell command ===--
---------------------------------------------------------------------

-- Prints one aggregate category's rows to chat, most-total-first. Verification tool for
-- Phase 1: feed reference/*.txt through Trigger.ParseCombatChat by hand and compare against
-- this output. Not meant to survive into the analysis window UI (Phase 5 reads Session.agg
-- directly instead of formatting chat text).
local function DumpCategory(label, agg)
	local rows = {}
	for _, row in pairs(agg) do
		table.insert(rows, row)
	end
	table.sort(rows, function(a, b) return a.total > b.total end)

	if table.getn(rows) == 0 then
		return
	end

	Turbine.Shell.WriteLine("-- " .. label .. " --")
	for i = 1, table.getn(rows) do
		local row = rows[i]
		local who = row.who or "?"
		local crit = (row.crits or 0) .. "c/" .. (row.devs or 0) .. "d"
		Turbine.Shell.WriteLine(
			string.format("  %s -> %s: %d hits, %s, max %d, total %d",
				row.skill, who, row.hits or 0, crit, row.max or 0, row.total or 0))
	end
end

local function DumpSession(s)
	if s == nil then
		Turbine.Shell.WriteLine("Reckoning: no session data yet.")
		return
	end

	Turbine.Shell.WriteLine(string.format(
		"Reckoning session: %s, %.0fs (%ds active)%s",
		s.startClock, s:Duration(), s:ActiveSeconds(), s.died and ", died" or ""))

	DumpCategory("Damage done", s.agg.done)
	DumpCategory("Damage taken", s.agg.taken)
	DumpCategory("Healing done", s.agg.healOut)
	DumpCategory("Healing taken", s.agg.healIn)
end

-- "live"/"death" don't accept a forced show: both are driven entirely by combat events
-- (Sessions.current, Sessions.OnSelfDefeat) and would just re-hide themselves on the next
-- throttled Update() if shown with no active data. show/hide for those two only flips the
-- enable flag (same effect as the options panel checkboxes) -- "analysis" is the one window
-- that's genuinely opened/closed by hand.
local function UnknownWindow(name)
	Turbine.Shell.WriteLine("Reckoning: unknown window '" .. name .. "'. Use live | death | analysis.")
end

local function ShowWindow(name)
	if name == "" or name == "analysis" then
		analysis:SetVisible(true)
		analysis:Activate()
	elseif name == "live" then
		_G.settings.liveMeterEnabled = true
		Settings.Save()
		Turbine.Shell.WriteLine("Reckoning: live meter enabled.")
	elseif name == "death" then
		_G.settings.deathCauseEnabled = true
		Settings.Save()
		Turbine.Shell.WriteLine("Reckoning: death cause window enabled.")
	else
		UnknownWindow(name)
	end
end

local function HideWindow(name)
	if name == "" or name == "analysis" then
		analysis:SetVisible(false)
	elseif name == "live" then
		_G.settings.liveMeterEnabled = false
		liveMeter:SetVisible(false)
		Settings.Save()
	elseif name == "death" then
		_G.settings.deathCauseEnabled = false
		deathCause:SetVisible(false)
		Settings.Save()
	else
		UnknownWindow(name)
	end
end

-- Recovery command: resets one window to (200, 200) and shows it, for when it's dragged
-- off-screen (a resolution change, an accidental drag past the edge) and its header is no
-- longer reachable to drag back.
local function MoveWindow(name)
	local window = (name == "live" and liveMeter) or (name == "death" and deathCause) or (name == "analysis" and analysis) or nil
	if window == nil then
		UnknownWindow(name)
		return
	end

	window:SetPosition(200, 200)
	_G.settings.windows[window.windowKey] = { left = 200, top = 200 }
	Settings.Save()
	window:SetVisible(true)
end

local function ResetAll()
	Settings.ResetToDefaults()

	liveMeter:SetPosition(200, 200)
	deathCause:SetPosition(200, 200)
	analysis:Resize(1080, 600)
	analysis:SetPosition(200, 200)
	analysis:Layout()

	optionsPanel:Refresh()

	Turbine.Shell.WriteLine("Reckoning: settings reset to defaults.")
end

command = Turbine.ShellCommand()

function command:Execute(_, str)
	str = str or ""
	local cmd, arg = string.match(string.lower(str), "^%s*(%S*)%s*(%S*)")
	cmd = cmd or ""
	arg = arg or ""

	if cmd == "" or cmd == "help" then
		Turbine.Shell.WriteLine("Reckoning v" .. Reckoning.Version .. ": /reck help | dump | show [live|death|analysis] | hide [live|death|analysis] | move <live|death|analysis> | reset")
	elseif cmd == "dump" then
		DumpSession(Sessions.current or Sessions.list[1])
	elseif cmd == "show" then
		ShowWindow(arg)
	elseif cmd == "hide" then
		HideWindow(arg)
	elseif cmd == "move" then
		MoveWindow(arg)
	elseif cmd == "reset" then
		ResetAll()
	else
		Turbine.Shell.WriteLine("Reckoning: unknown command '" .. cmd .. "'. Try /reck help.")
	end
end

Turbine.Shell.AddCommand("reck", command)

---------------------------------------------------------------------
--== Lifecycle ===--
---------------------------------------------------------------------

plugin.Unload = function(self)
	Settings.Save()
	Turbine.Shell.RemoveCommand(command)
	Events.Shutdown()
end
