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
import "Reckoning.Buffs"
import "Reckoning.Events"

-- Close every still-open buff interval the moment a session closes. Registered here, before any
-- window is constructed, so it runs ahead of the windows' own OnClosed callbacks and none of
-- them can render a closed session with a dangling interval.
Sessions.OnClosed(function(s) Buffs.CloseSession(s) end)

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

-- Debug helper: pops the death window directly, bypassing Sessions.OnSelfDefeat entirely --
-- lets you tell "the window itself is broken" apart from "a real death was never actually
-- detected" (e.g. because nothing you've fought so far can actually kill you) without needing to
-- die for real. Synthesizes two lastTaken rows if the session has none to show.
local function TestDeath()
	local session = Sessions.current or Sessions.list[1]
	if session == nil then
		session = Session(Turbine.Engine.GetGameTime(), "test")
	end

	if table.getn(session.lastTaken) == 0 then
		local now = Turbine.Engine.GetGameTime()
		session:PushLastTaken({
			time = now - 2, kind = "damage", skill = "Test Strike", dmgType = DamageType.Shadow,
			amount = 12345, initiator = "Test Dummy", moralePct = 0.4,
		})
		session:PushLastTaken({
			time = now, kind = "damage", skill = "Test Strike", dmgType = DamageType.Shadow,
			amount = 54321, initiator = "Test Dummy", moralePct = 0,
		})
	end
	session.died = true
	session.endTime = Turbine.Engine.GetGameTime()

	deathCause:Show(session)
	Turbine.Shell.WriteLine("Reckoning: triggered a test death popup.")
end

-- `/reck buffs` -- what self-buff tracking is currently seeing, and the ignore list that shapes
-- it. The default Buffs.Ignore entries are a best guess at the client's own effect names and are
-- not verified against a running game, so this command (not that table) is the real mechanism for
-- keeping mounts and travel skills out of the uptime table.
local function BuffsCommand(action, name)
	if action == "" or action == "list" then
		local session = Sessions.current or Sessions.list[1]
		local rows = Buffs.Stats(session, nil, nil)

		if table.getn(rows) == 0 then
			Turbine.Shell.WriteLine("Reckoning: no self-buffs tracked yet (nothing fought, or every effect is ignored).")
		else
			Turbine.Shell.WriteLine("Reckoning: self-buffs in the most recent fight --")
			for i = 1, table.getn(rows) do
				local row = rows[i]
				Turbine.Shell.WriteLine(string.format("  %s: %s uptime (%s), %d applied, longest gap %ds",
					row.name, Format.Percent(row.uptimePct), Format.Clock(row.uptime),
					row.apps, math.floor(row.longestGap + 0.5)))
			end
		end

		local ignored = {}
		for key in pairs(Buffs.Ignore) do
			table.insert(ignored, key)
		end
		if _G.settings.buffIgnore ~= nil then
			for key in pairs(_G.settings.buffIgnore) do
				table.insert(ignored, key)
			end
		end
		table.sort(ignored)
		if table.getn(ignored) > 0 then
			Turbine.Shell.WriteLine("  ignored: " .. table.concat(ignored, ", "))
		end
		return
	end

	if name == "" then
		Turbine.Shell.WriteLine("Reckoning: /reck buffs ignore <name> | unignore <name> | list")
		return
	end

	if action == "ignore" then
		Buffs.AddIgnore(name)
		Turbine.Shell.WriteLine("Reckoning: ignoring self-buff '" .. name .. "'.")
	elseif action == "unignore" then
		Buffs.RemoveIgnore(name)
		Turbine.Shell.WriteLine("Reckoning: no longer ignoring '" .. name .. "'.")
	else
		Turbine.Shell.WriteLine("Reckoning: /reck buffs ignore <name> | unignore <name> | list")
	end
end

local function ResetAll()
	Settings.ResetToDefaults()

	liveMeter:SetPosition(200, 200)
	deathCause:SetPosition(200, 200)
	analysis:ResetGeometry()

	optionsPanel:Refresh()

	Turbine.Shell.WriteLine("Reckoning: settings reset to defaults.")
end

command = Turbine.ShellCommand()

function command:Execute(_, str)
	str = str or ""
	local cmd, arg = string.match(string.lower(str), "^%s*(%S*)%s*(%S*)")
	cmd = cmd or ""
	arg = arg or ""

	-- Buff names are case-sensitive and contain spaces ("Writ of Health"), so `buffs` re-reads
	-- its arguments from the RAW string rather than the lower-cased, single-token parse above.
	if cmd == "buffs" then
		local action, name = string.match(str, "^%s*%S+%s*(%S*)%s*(.-)%s*$")
		BuffsCommand(string.lower(action or ""), name or "")
		return
	end

	if cmd == "" or cmd == "help" then
		Turbine.Shell.WriteLine("Reckoning v" .. Reckoning.Version .. ": /reck help | dump | buffs [list|ignore <name>|unignore <name>] | testdeath | show [live|death|analysis] | hide [live|death|analysis] | move <live|death|analysis> | reset")
	elseif cmd == "dump" then
		DumpSession(Sessions.current or Sessions.list[1])
	elseif cmd == "testdeath" then
		TestDeath()
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
