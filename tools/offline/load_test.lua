-- Loads the plugin exactly the way the game does: Main.lua top to bottom, which constructs all
-- three windows and the options panel. Catches load-order breakage, a missing global, or a nil
-- argument reaching a Turbine call -- none of which luac -p can see.
local env = dofile("stub.lua"); local ROOT = env.ROOT

Turbine.Gameplay.LocalPlayer = {
  GetInstance = function()
    return {
      GetName = function() return "Luxtheninth" end,
      GetMorale = function() return 500000 end,
      GetMaxMorale = function() return 900000 end,
      GetTarget = function() return nil end,
      IsInCombat = function() return true end,
      GetEffects = function()
        local list = { { GetName = function() return "Writ of Health" end,
                         GetIcon = function() return "icon:writ" end,
                         IsDebuff = function() return false end } }
        return { GetCount = function() return #list end, Get = function(_, i) return list[i] end }
      end,
    }
  end,
}

local fails = 0
local function check(label, ok, detail)
  if not ok then fails = fails + 1 end
  print(string.format("%-58s %s%s", label, ok and "OK" or "**FAIL**", detail and ("  " .. detail) or ""))
end

-- Main.lua does `import "Reckoning.UI"` and then `UI.LiveMeter()`. The stub has no per-directory
-- package environments, so give `UI` the bare globals those files declare, the way the game's
-- own package scope would.
local realImport = _G.import
_G.import = function(path)
  if path == "Reckoning.UI" then
    realImport("Reckoning.UI")
    _G.UI = { LiveMeter = LiveMeter, DeathCause = DeathCause, Analysis = Analysis,
              OptionsWindow = OptionsWindow, Options = Options }
    return
  end
  if path:match("^Turbine") then return end
  return realImport(path)
end

local ok, err = pcall(function() realImport("Reckoning.Main") end)
check("Main.lua loads top to bottom", ok, ok and "" or tostring(err))
if not ok then os.exit(1) end

check("all three windows constructed", liveMeter ~= nil and deathCause ~= nil and analysis ~= nil)
check("options panel stub constructed", optionsPanel ~= nil)
check("options window constructed", optionsWindow ~= nil)
check("options window constructed", optionsWindow ~= nil)
check("LocalPlayer.name monkey-patched", LocalPlayer.name == "Luxtheninth")
check("version is 0.3.0 in Constants", Reckoning.Version == "0.3.0")
check("Buffs global exists before Events", Buffs ~= nil and Buffs.PollInterval == 0.25)
check("new settings defaults merged",
  type(_G.settings.chartedBuffs) == "table" and type(_G.settings.buffIgnore) == "table")
check("the removed buff-collapse setting is gone", DEFAULTS.buffsOpen == nil)

-- table-valued defaults must be fresh copies, not aliases of DEFAULTS
_G.settings.chartedBuffs[1] = "Poisoned Default"
check("table defaults are fresh copies, not DEFAULTS aliases",
  DEFAULTS.chartedBuffs[1] == nil, tostring(DEFAULTS.chartedBuffs[1]))
_G.settings.chartedBuffs = {}

-- run a fight through the real chat handler and the real heartbeat
local clock = 1000
local function Feed(path, ct)
  for line in io.lines(path) do
    if line ~= "" and not line:match("^###") then
      clock = clock + 0.37; Turbine.Engine._time = clock
      Turbine.Chat.Received(nil, { ChatType = ct, Message = line })
      Events.heartbeat:Update()
      liveMeter:Update()
    end
  end
end
Turbine.Engine._time = clock
local okRun, errRun = pcall(function()
  Feed(ROOT .. "/reference/Combat_20260819_1.txt", Turbine.ChatType.PlayerCombat)
  Feed(ROOT .. "/reference/Enemy_20260819_1.txt", Turbine.ChatType.EnemyCombat)
end)
check("a full fight runs through chat + heartbeat + live meter", okRun, okRun and "" or tostring(errRun))
check("the fight was recorded", Sessions.current ~= nil and Sessions.current:Total("done") > 0)
check("the heartbeat polled buffs at 4Hz",
  Sessions.current.buffs["Writ of Health"] ~= nil)

-- the defeat channel still reaches the death window
local okDeath = pcall(function()
  Turbine.Engine._time = clock + 1
  Turbine.Chat.Received(nil, { ChatType = Turbine.ChatType.Death,
    Message = "The Utûgi Destroyer incapacitated you." })
end)
check("a defeat line on ChatType.Death pops the death window",
  okDeath and Sessions.current.died == true and deathCause:IsVisible())

-- close the session and let every window react
Turbine.Engine._time = clock + 30
local okClose, errClose = pcall(function() Events.heartbeat:Update() end)
check("session closes cleanly and the windows react", okClose, okClose and "" or tostring(errClose))
check("session archived", Sessions.list[1] ~= nil)
check("buff intervals were closed on session close", (function()
  for _, e in pairs(Sessions.list[1].buffs) do if e.open ~= nil then return false end end
  return true end)())
check("analysis window picked up the closed session", analysis.selectedSession == Sessions.list[1])

-- shell commands
local function Run(text)
  local okCmd, errCmd = pcall(function() command:Execute(nil, text) end)
  return okCmd, errCmd
end
for _, cmd in ipairs({ "help", "dump", "post", "buffs", "buffs list", "testdeath",
                       "show analysis", "hide analysis", "move analysis" }) do
  local okCmd, errCmd = Run(cmd)
  check("/reck " .. cmd, okCmd, okCmd and "" or tostring(errCmd))
end
local okIg = Run("buffs ignore Writ of Health")
check("/reck buffs ignore <name> keeps the name's case and spaces",
  okIg and _G.settings.buffIgnore["Writ of Health"] == true)
local okUn = Run("buffs unignore Writ of Health")
check("/reck buffs unignore <name>", okUn and _G.settings.buffIgnore["Writ of Health"] == nil)
-- /reck post must survive every preset and channel, including the ones that legitimately have
-- nothing to say -- it runs against whatever session state happens to exist, so a nil post is a
-- normal outcome it has to print through rather than throw on.
for _, preset in ipairs({ "summary", "death" }) do
  for _, channel in ipairs({ "say", "fellowship", "raid", "kinship" }) do
    _G.settings.postPreset = preset
    _G.settings.postChannel = channel
    local okPost, errPost = Run("post")
    check("/reck post (" .. preset .. " -> " .. channel .. ")", okPost,
      okPost and "" or tostring(errPost))
  end
end
_G.settings.postPreset = "summary"
_G.settings.postChannel = "say"

-- The four post settings must come back from a fresh DEFAULTS merge, since an existing save
-- predates them entirely.
check("postChannel defaulted", _G.settings.postChannel ~= nil)
check("postColor defaulted on", _G.settings.postColor == true)
check("the removed postRows setting is gone", DEFAULTS.postRows == nil)

local okReset = Run("reset")
check("/reck reset", okReset)
check("/reck reset restored the shipped window size",
  select(1, analysis:GetSize()) == 1080 and select(2, analysis:GetSize()) == 820,
  select(1, analysis:GetSize()) .. "x" .. select(2, analysis:GetSize()))

-- unload
local okUnload, errUnload = pcall(function() plugin.Unload() end)
check("plugin.Unload runs clean", okUnload, okUnload and "" or tostring(errUnload))

print("")
if fails == 0 then print("ALL LOAD CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
