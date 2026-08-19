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

-- Trigger.ParseCombatChat reads the bare global `LocalPlayer.name` directly (a property
-- Turbine exposes on the game object itself, not a method call) -- so the plugin instance
-- has to be reachable under that exact bare name, same as Gibberish3's Variables.lua.
LocalPlayer = _G.lp

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

command = Turbine.ShellCommand()

function command:Execute(_, str)
	local cmd = str and string.match(string.lower(str), "^%s*(%S*)") or ""

	if cmd == "" or cmd == "help" then
		Turbine.Shell.WriteLine("Reckoning v" .. Reckoning.Version .. ": /reck help | dump")
		-- Phase 5/6 add: show, hide, move, reset.
	elseif cmd == "dump" then
		DumpSession(Sessions.current or Sessions.list[1])
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
