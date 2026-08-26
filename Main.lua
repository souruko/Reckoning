---------------------------------------------------------------------
--== Import ===--
---------------------------------------------------------------------

import "Turbine.Gameplay"
import "Turbine.UI"
import "Turbine.UI.Lotro"

import "RedBook.Utils.Type"
import "RedBook.Utils.Class"

import "RedBook.Constants"

-- Trigger.ParseCombatChat (Parse/en.lua) is `function Trigger.ParseCombatChat(...)` --
-- it attaches to an existing table rather than declaring its own global, so Trigger must
-- exist before that file loads. Mirrors Gibberish3's Variables.lua, where the same table
-- is declared before UTILS/COMBATCHATPARSE/en.lua.
Trigger = {}

import "RedBook.Parse.en"

import "RedBook.Settings"

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

import "RedBook.Session"
import "RedBook.Sessions"
import "RedBook.Buffs"
import "RedBook.Events"

-- Root level, not UI/: both Main.lua (for /redbook post) and UI/PostButton.lua need it, and only a
-- root-package global is visible from both (see CLAUDE.md's package-scope note). Pure string
-- building -- it imports nothing and touches no Turbine.UI.
import "RedBook.ChatPost"

-- Close every still-open buff interval the moment a session closes. Registered here, before any
-- window is constructed, so it runs ahead of the windows' own OnClosed callbacks and none of
-- them can render a closed session with a dangling interval.
Sessions.OnClosed(function(s) Buffs.CloseSession(s) end)

---------------------------------------------------------------------
--== UI ===--
---------------------------------------------------------------------
-- Frame/Bar/Row (chrome primitives) first, then each window module as it's built. Reads
-- Theme/Font (Constants.lua) and _G.settings.windows (Settings.lua), both already loaded above.

import "RedBook.UI"

liveMeter = UI.LiveMeter()
deathCause = UI.DeathCause()
analysis = UI.Analysis()

-- Last of the four: its Defaults button and its handlers reach into all three of the above, and
-- its Windows page reads their saved geometry.
optionsWindow = UI.OptionsWindow()

-- The Plugin Manager still calls GetOptionsPanel and still wants a ListBox. UI/Options.lua is a
-- one-line stub pointing at /redbook options now -- every real setting lives in optionsWindow.
optionsPanel = UI.Options()

plugin.GetOptionsPanel = function(self)
	return optionsPanel
end

---------------------------------------------------------------------
--== Post-fight hooks ===--
---------------------------------------------------------------------

-- settings.analysisAutoOpen (options window, Windows page). Registered after the windows exist so
-- the callback never has to guard for them.
Sessions.OnClosed(function(s)
	if _G.settings.analysisAutoOpen == true and not analysis:IsVisible() then
		analysis:SetVisible(true)
		analysis:Activate()
		-- Activating the window puts it above the post button's overlay; put the overlay back.
		analysis.postButton:Raise()
	end
end)

-- settings.announceSummary. A plugin CANNOT send to a chat channel on its own -- that needs a
-- Quickslot alias fired by a real user click (see ChatPost.lua's header for how that was
-- established, and the analysis window's POST button for the one mechanism that does it). So the
-- setting's label promises more than the engine allows, and this writes the same line to your own
-- chat window instead; the Live meter page says so directly under the checkbox.
Sessions.OnClosed(function(s)
	if _G.settings.announceSummary ~= true then
		return
	end
	local line = ChatPost.BuildLine(s, "summary", "done", nil, nil, nil)
	if line ~= nil then
		Turbine.Shell.WriteLine(line)
	end
end)

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
	-- Memory readout first, session data or not -- lets a lag report be checked against real
	-- numbers ("does Lua-side memory climb fight over fight?") instead of just going by feel.
	-- collectgarbage("count") returns KB and is cheap enough to call from a shell command.
	Turbine.Shell.WriteLine(string.format("RedBook: Lua memory in use: %.0f KB", collectgarbage("count")))

	if s == nil then
		Turbine.Shell.WriteLine("RedBook: no session data yet.")
		return
	end

	Turbine.Shell.WriteLine(string.format(
		"RedBook session: %s, %.0fs (%ds active)%s",
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
	Turbine.Shell.WriteLine("RedBook: unknown window '" .. name .. "'. Use live | death | analysis | options.")
end

local function ShowWindow(name)
	if name == "options" then
		optionsWindow:SetVisible(true)
		optionsWindow:Activate()
	elseif name == "" or name == "analysis" then
		analysis:SetVisible(true)
		analysis:Activate()
		-- Activating the window puts it above the post button's overlay; put the overlay back.
		analysis.postButton:Raise()
	elseif name == "live" then
		_G.settings.liveMeterEnabled = true
		Settings.Save()
		-- Same path the options window's own checkbox takes, so the meter reappears now rather
		-- than on its next throttled Update().
		liveMeter:ApplySettings()
		Turbine.Shell.WriteLine("RedBook: live meter enabled.")
	elseif name == "death" then
		_G.settings.deathCauseEnabled = true
		Settings.Save()
		deathCause:ApplySettings()
		Turbine.Shell.WriteLine("RedBook: death cause window enabled.")
	else
		UnknownWindow(name)
	end
end

local function HideWindow(name)
	if name == "options" then
		optionsWindow:SetVisible(false)
	elseif name == "" or name == "analysis" then
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
-- longer reachable to drag back. The reset itself is Settings.ResetWindow -- shared with the
-- options window's own per-window Reset buttons, so there is one definition of what it does.
local WINDOW_KEYS = { live = "liveMeter", death = "deathCause", analysis = "analysis",
	options = "options" }

local function MoveWindow(name)
	local key = WINDOW_KEYS[name]
	if key == nil or not Settings.ResetWindow(key) then
		UnknownWindow(name)
		return
	end
	Settings.Window(key):SetVisible(true)
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
	Turbine.Shell.WriteLine("RedBook: triggered a test death popup.")
end

-- `/redbook buffs` -- what self-effect tracking is currently seeing, and the ignore list that shapes
-- it. The default Buffs.Ignore entries are a best guess at the client's own effect names and are
-- not verified against a running game, so this command (not that table) is the real mechanism for
-- keeping mounts and travel skills out of the uptime table.
local function BuffsCommand(action, name)
	if action == "" or action == "list" then
		local session = Sessions.current or Sessions.list[1]
		local rows = Buffs.Stats(session, nil, nil)

		if table.getn(rows) == 0 then
			Turbine.Shell.WriteLine("RedBook: no self-effects tracked yet (nothing fought, or every effect is ignored).")
		else
			Turbine.Shell.WriteLine("RedBook: self-effects in the most recent fight --")
			for i = 1, table.getn(rows) do
				local row = rows[i]
				Turbine.Shell.WriteLine(string.format("  %s [%s]: %s uptime (%s), %d applied, longest gap %ds, icon=%s(%s)",
					row.name, tostring(row.kind), Format.Percent(row.uptimePct), Format.Clock(row.uptime),
					row.apps, math.floor(row.longestGap + 0.5),
					tostring(row.icon), type(row.icon)))
			end
		end

		-- Both lists go through Buffs.IsIgnored rather than being concatenated raw: a default
		-- the player un-ignored is stored as an explicit `false` in settings, so it must not be
		-- listed from either table.
		local ignored, seen = {}, {}
		for key in pairs(Buffs.Ignore) do
			if Buffs.IsIgnored(key) then
				seen[key] = true
				table.insert(ignored, key)
			end
		end
		if _G.settings.buffIgnore ~= nil then
			for key in pairs(_G.settings.buffIgnore) do
				if not seen[key] and Buffs.IsIgnored(key) then
					seen[key] = true
					table.insert(ignored, key)
				end
			end
		end
		table.sort(ignored)
		if table.getn(ignored) > 0 then
			Turbine.Shell.WriteLine("  ignored: " .. table.concat(ignored, ", "))
		end
		return
	end

	if name == "" then
		Turbine.Shell.WriteLine("RedBook: /redbook buffs ignore <name> | unignore <name> | list")
		return
	end

	if action == "ignore" then
		Buffs.AddIgnore(name)
		Turbine.Shell.WriteLine("RedBook: ignoring self-effect '" .. name .. "'.")
	elseif action == "unignore" then
		Buffs.RemoveIgnore(name)
		Turbine.Shell.WriteLine("RedBook: no longer ignoring '" .. name .. "'.")
	else
		Turbine.Shell.WriteLine("RedBook: /redbook buffs ignore <name> | unignore <name> | list")
	end
end

local function ResetAll()
	Settings.ResetToDefaults()

	liveMeter:SetPosition(200, 200)
	deathCause:SetPosition(200, 200)
	analysis:ResetGeometry()
	optionsWindow:SetPosition(200, 200)

	-- Every built page re-reads _G.settings, then every window is told about the new values --
	-- the same two steps the options window's own Defaults button takes, which is why they live
	-- there rather than being spelled out twice.
	optionsWindow:RefreshPages()
	OptionsWindow.ApplyAll()

	Turbine.Shell.WriteLine("RedBook: settings reset to defaults.")
end

-- Prints the post the analysis window currently has armed, to YOUR chat window only.
--
-- This command cannot send to a channel, and no command can: posting to a channel requires a
-- Quickslot alias fired by a real user click (see ChatPost.lua's header for how that was
-- established). So this is a preview -- the way to check the wording and the row count before
-- clicking POST for real -- and it also still works if the quickslot mechanism turns out to
-- misbehave in-game.
local function PostPreview()
	local session = analysis and analysis.selectedSession or (Sessions.current or Sessions.list[1])
	if session == nil then
		Turbine.Shell.WriteLine("RedBook: no session data yet.")
		return
	end

	-- Read the window's live scoping if it exists, so the preview matches what POST would send.
	local preset = _G.settings.postPreset or "summary"
	local view, who, fromSec, toSec = "done", nil, nil, nil
	if analysis ~= nil then
		view = analysis.viewTab or view
		who = analysis.filter and analysis.filter[view] or nil
		fromSec, toSec = analysis:RangeSeconds()
	end

	local line = ChatPost.BuildLine(session, preset, view, who, fromSec, toSec)
	if line == nil then
		Turbine.Shell.WriteLine("RedBook: nothing to post for the current view"
			.. (preset == "death" and " (this fight had no death)." or "."))
		return
	end

	-- Exactly what the quickslot would send, with its length. There is no separate, prettier
	-- preview form on purpose: an earlier draft had one and it drifted from the real post
	-- immediately. The character count stays because it is what diagnosed the "prohibited because
	-- of a content, size, or mixed-alphabet restriction" refusal in the first place.
	Turbine.Shell.WriteLine(string.format(
		"RedBook: %s -> %s, %d chars (limit %d):",
		ChatPost.PresetLabel(preset), ChatPost.ChannelLabel(_G.settings.postChannel),
		string.len(line), ChatPost.MAX_MESSAGE))
	Turbine.Shell.WriteLine(line)
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
		Turbine.Shell.WriteLine("RedBook v" .. RedBook.Version .. ": /redbook help | options | dump | post | buffs [list|ignore <name>|unignore <name>] | testdeath | show [live|death|analysis|options] | hide [live|death|analysis|options] | move <live|death|analysis|options> | reset")
	elseif cmd == "options" or cmd == "config" then
		optionsWindow:Toggle()
	elseif cmd == "dump" then
		DumpSession(Sessions.current or Sessions.list[1])
	elseif cmd == "post" then
		PostPreview()
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
		Turbine.Shell.WriteLine("RedBook: unknown command '" .. cmd .. "'. Try /redbook help.")
	end
end

-- Two registrations of the SAME command object: the full name and a short alias. Turbine's
-- AddCommand may or may not accept a semicolon-separated alias list -- nothing in the plugin
-- source this codebase checks its assumptions against uses that form, so this takes the shape
-- with no unknown in it and registers twice instead. RemoveCommand is then called once per
-- registration in plugin.Unload (see the note there).
Turbine.Shell.AddCommand("redbook", command)
Turbine.Shell.AddCommand("rb", command)

---------------------------------------------------------------------
--== Lifecycle ===--
---------------------------------------------------------------------

plugin.Unload = function(self)
	Settings.Save()
	-- Once per AddCommand above. Whether RemoveCommand drops every registration of an object or
	-- just one is not established here, so both calls are made and both are pcall'd: a second
	-- removal that finds nothing left must not abort the rest of this teardown.
	pcall(Turbine.Shell.RemoveCommand, command)
	pcall(Turbine.Shell.RemoveCommand, command)
	Events.Shutdown()
	Session.ShutdownMorale()
	UI.LiveMeter.ShutdownTarget()
	-- The post button's quickslot overlay is its OWN top-level Window, not a child of the analysis
	-- window, so nothing else tears it down -- without this it would survive a /plugins refresh as
	-- an invisible click target parked over the screen.
	if analysis ~= nil and analysis.postButton ~= nil then
		analysis.postButton:Shutdown()
	end
end
