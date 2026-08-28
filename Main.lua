---------------------------------------------------------------------
--== Import ===--
---------------------------------------------------------------------

import "Turbine.Gameplay"
import "Turbine.UI"
import "Turbine.UI.Lotro"

import "Basil.Utils.Type"
import "Basil.Utils.Class"

import "Basil.Constants"

-- Trigger.ParseCombatChat (Parse/en.lua) is `function Trigger.ParseCombatChat(...)` --
-- it attaches to an existing table rather than declaring its own global, so Trigger must
-- exist before that file loads. Mirrors Gibberish3's Variables.lua, where the same table
-- is declared before UTILS/COMBATCHATPARSE/en.lua.
Trigger = {}

import "Basil.Parse.en"

import "Basil.Settings"

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

import "Basil.Session"
import "Basil.Sessions"
import "Basil.Buffs"
import "Basil.Events"

-- Root level, not UI/: both Main.lua (for /basil post) and UI/PostButton.lua need it, and only a
-- root-package global is visible from both (see CLAUDE.md's package-scope note). Pure string
-- building -- it imports nothing and touches no Turbine.UI.
import "Basil.ChatPost"

-- Close every still-open buff interval the moment a session closes. Registered here, before any
-- window is constructed, so it runs ahead of the windows' own OnClosed callbacks and none of
-- them can render a closed session with a dangling interval.
Sessions.OnClosed(function(s) Buffs.CloseSession(s) end)

---------------------------------------------------------------------
--== UI ===--
---------------------------------------------------------------------
-- Frame/Bar/Row (chrome primitives) first, then each window module as it's built. Reads
-- Theme/Font (Constants.lua) and _G.settings.windows (Settings.lua), both already loaded above.

import "Basil.UI"

liveMeter = UI.LiveMeter()
deathCause = UI.DeathCause()
analysis = UI.Analysis()

-- Last of the four: its Defaults button and its handlers reach into all three of the above, and
-- its Windows page reads their saved geometry.
optionsWindow = UI.OptionsWindow()

-- The Plugin Manager still calls GetOptionsPanel and still wants a ListBox. UI/Options.lua is a
-- one-line stub pointing at /basil options now -- every real setting lives in optionsWindow.
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
		-- Activating the window puts it above the post buttons' overlays; put them back.
		analysis:RaisePostButtons()
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

-- "live"/"death" don't accept a forced show: both are driven entirely by combat events
-- (Sessions.current, Sessions.OnSelfDefeat) and would just re-hide themselves on the next
-- throttled Update() if shown with no active data. show/hide for those two only flips the
-- enable flag (same effect as the options panel checkboxes) -- "analysis" is the one window
-- that's genuinely opened/closed by hand.
local function UnknownWindow(name)
	Turbine.Shell.WriteLine("Basil: unknown window '" .. name .. "'. Use live | death | analysis | options.")
end

local function ShowWindow(name)
	if name == "options" then
		optionsWindow:SetVisible(true)
		optionsWindow:Activate()
	elseif name == "" or name == "analysis" then
		analysis:SetVisible(true)
		analysis:Activate()
		-- Activating the window puts it above the post buttons' overlays; put them back.
		analysis:RaisePostButtons()
	elseif name == "live" then
		_G.settings.liveMeterEnabled = true
		Settings.Save()
		-- Same path the options window's own checkbox takes, so the meter reappears now rather
		-- than on its next throttled Update().
		liveMeter:ApplySettings()
		Turbine.Shell.WriteLine("Basil: live meter enabled.")
	elseif name == "death" then
		_G.settings.deathCauseEnabled = true
		Settings.Save()
		deathCause:ApplySettings()
		Turbine.Shell.WriteLine("Basil: death cause window enabled.")
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

	Turbine.Shell.WriteLine("Basil: settings reset to defaults.")
end

-- Prints the post the analysis window currently has armed, to YOUR chat window only.
--
-- This command cannot send to a channel, and no command can: posting to a channel requires a
-- Quickslot alias fired by a real user click (see ChatPost.lua's header for how that was
-- established). So this is a preview -- the way to check the wording and the row count before
-- clicking POST for real -- and it also still works if the quickslot mechanism turns out to
-- misbehave in-game.
--
-- `/basil post` previews the summary; `/basil post death` previews the death report -- the two
-- shapes are two separate buttons in the window (see UI/PostButton.lua), so the command names them
-- the same way rather than reading a mode setting that no longer exists.
local function PostPreview(which)
	local session = analysis and analysis.selectedSession or (Sessions.current or Sessions.list[1])
	if session == nil then
		Turbine.Shell.WriteLine("Basil: no session data yet.")
		return
	end

	-- Read the window's live scoping if it exists, so the preview matches what POST would send.
	local preset = (which == "death") and "death" or "summary"
	local view, who, fromSec, toSec = "done", nil, nil, nil
	if analysis ~= nil then
		view = analysis.viewTab or view
		who = analysis.filter and analysis.filter[view] or nil
		fromSec, toSec = analysis:RangeSeconds()
	end

	local line = ChatPost.BuildLine(session, preset, view, who, fromSec, toSec)
	if line == nil then
		-- Two reasons a summary can come back nil now: the view genuinely has no data, or every
		-- part was switched off in the POST button's menu. Say which, or the second one reads as
		-- the plugin being broken.
		local why = "."
		if preset == "death" then
			why = " (this fight had no death)."
		elseif not ChatPost.AnyPartEnabled() then
			why = " (every part is switched off -- see the channel button's menu)."
		end
		Turbine.Shell.WriteLine("Basil: nothing to post for the current view" .. why)
		return
	end

	-- Exactly what the quickslot would send, with its length. There is no separate, prettier
	-- preview form on purpose: an earlier draft had one and it drifted from the real post
	-- immediately. The character count stays because it is what diagnosed the "prohibited because
	-- of a content, size, or mixed-alphabet restriction" refusal in the first place.
	Turbine.Shell.WriteLine(string.format(
		"Basil: %s -> %s, %d chars (limit %d):",
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

	if cmd == "" or cmd == "help" then
		Turbine.Shell.WriteLine("Basil v" .. Basil.Version .. ": /basil help | options | post [death] | show [live|death|analysis|options] | hide [live|death|analysis|options] | move <live|death|analysis|options> | reset")
	elseif cmd == "options" or cmd == "config" then
		optionsWindow:Toggle()
	elseif cmd == "post" then
		PostPreview(arg)
	elseif cmd == "show" then
		ShowWindow(arg)
	elseif cmd == "hide" then
		HideWindow(arg)
	elseif cmd == "move" then
		MoveWindow(arg)
	elseif cmd == "reset" then
		ResetAll()
	else
		Turbine.Shell.WriteLine("Basil: unknown command '" .. cmd .. "'. Try /basil help.")
	end
end

Turbine.Shell.AddCommand("basil", command)

---------------------------------------------------------------------
--== Lifecycle ===--
---------------------------------------------------------------------

plugin.Unload = function(self)
	Settings.Save()
	Turbine.Shell.RemoveCommand(command)
	Events.Shutdown()
	Session.ShutdownMorale()
	UI.LiveMeter.ShutdownTarget()
	-- Each post button's quickslot overlay is its OWN top-level Window, not a child of the analysis
	-- window, so nothing else tears them down -- without this they would survive a /plugins refresh
	-- as invisible click targets parked over the screen.
	if analysis ~= nil and analysis.ShutdownPostButtons ~= nil then
		analysis:ShutdownPostButtons()
	end
end
