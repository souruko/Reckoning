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
--== Shell command ===--
---------------------------------------------------------------------

command = Turbine.ShellCommand()

function command:Execute(_, str)
	local cmd = str and string.match(string.lower(str), "^%s*(%S*)") or ""

	if cmd == "" or cmd == "help" then
		Turbine.Shell.WriteLine("Reckoning v" .. Reckoning.Version .. ": /reck help")
		-- Phase 1 adds: dump. Phase 5/6 add: show, hide, move, reset.
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
end
