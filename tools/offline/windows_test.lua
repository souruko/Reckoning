-- Drives the REAL LiveMeter and DeathCause classes against the Turbine stub.
local env = dofile("stub.lua"); local ROOT = env.ROOT
import "Reckoning.Constants"
Trigger = {}; import "Reckoning.Parse.en"; import "Reckoning.Settings"
local morale = 900000
_G.lp = {
  GetName = function() return "Luxtheninth" end,
  GetMorale = function() return morale end, GetMaxMorale = function() return 900000 end,
  GetTarget = function() return { GetName = function() return "the Khardâmu Blood-sworn" end } end,
  IsInCombat = function() return true end,  -- heals only count in combat, see Sessions.lua
  GetEffects = function() return { GetCount = function() return 0 end, Get = function() return nil end } end,
}
LocalPlayer = _G.lp; LocalPlayer.name = LocalPlayer:GetName()
Settings.Load()
import "Reckoning.Session"; import "Reckoning.Sessions"; import "Reckoning.Buffs"
import "Reckoning.Events"; import "Reckoning.ChatPost"; import "Reckoning.UI"

local fails = 0
local function check(label, ok, detail)
  if not ok then fails = fails + 1 end
  print(string.format("%-60s %s%s", label, ok and "OK" or "**FAIL**", detail and ("  " .. detail) or ""))
end

local clock = 1000
local function Feed(path, ct)
  for line in io.lines(path) do
    if line ~= "" and not line:match("^###") then
      clock = clock + 0.37; Turbine.Engine._time = clock
      morale = math.max(20000, morale - 4000)
      Turbine.Chat.Received(nil, { ChatType = ct, Message = line })
    end
  end
end
Turbine.Engine._time = clock
Feed(ROOT .. "/reference/Combat_20260819_1.txt", Turbine.ChatType.PlayerCombat)
Feed(ROOT .. "/reference/Enemy_20260819_1.txt", Turbine.ChatType.EnemyCombat)
local session = Sessions.current

------------------------------------------------------------------ live meter
local m = LiveMeter()
check("live meter keeps its 260x186 footprint",
  select(1, m:GetSize()) == 260 and select(2, m:GetSize()) == 186,
  select(1, m:GetSize()) .. "x" .. select(2, m:GetSize()))
check("tab row is 22px", select(2, m.tabControls.done.control:GetSize()) == 22)
check("tabs are underlined, not filled",
  m.tabControls.done.underline ~= nil
  and m.tabControls.done.control:GetBackColor().R == Theme.Color(Theme.Hex.WindowFill).R)
check("active tab underline takes the accent",
  m.tabControls.done.underline:GetBackColor().R == Theme.Color(Theme.Hex.Accent).R)
check("inactive tab underline takes the border colour",
  m.tabControls.taken.underline:GetBackColor().R == Theme.Color(Theme.Hex.Border).R)
check("body starts under the 22px tab row", select(2, m.body:GetPosition()) == 22)
check("body still fits the client", 22 + select(2, m.body:GetSize()) <= 186 - 26,
  tostring(22 + select(2, m.body:GetSize())))

m:Refresh()
check("headline shows the fight's dps (swapped with the total per feedback)",
  m.valueLabel:GetText() == Format.Rate(session:Rate("done")), m.valueLabel:GetText())
check("headline corner shows the fight's damage total",
  m.rateLabel:GetText() == Format.Number(session:Total("done")), m.rateLabel:GetText())
check("headline number dropped to Verdana20", m.valueLabel._font == "Verdana20")
-- The pool is built at settings.sparklineWindow's upper bound (60), never at the current
-- window: growing it later would mean creating Controls at refresh time.
check("sparkline pool is built at the 60s maximum", #m.sparkColumns == 60)
check("sparkline draws only the current 30s window", (function()
  for i = 31, 60 do if m.sparkColumns[i]:IsVisible() then return false end end
  return true
end)())
local lit, tallest = 0, 0
for i = 1, 60 do
  local c = m.sparkColumns[i]
  if c:IsVisible() then
    lit = lit + 1
    local _, h = c:GetSize(); local _, y = c:GetPosition()
    if h > tallest then tallest = h end
    if y < m.sparkY or y + h > m.sparkY + 16 then check("spark column inside its band", false) end
  end
end
check("sparkline drew columns for the last 30s", lit > 0, "lit=" .. lit)
check("tallest spark column fills the 16px band", tallest == 16, "tallest=" .. tallest)
check("spark columns stay inside their 16px band", true)

local doneColor = m.sparkColumns[30]:GetBackColor() or m.sparkColumns[1]:GetBackColor()
m:SelectTab("healOut"); m:Refresh()
check("sparkline recolours with the tab", (function()
  for i = 1, 60 do
    local c = m.sparkColumns[i]
    if c:IsVisible() then
      return math.abs(c:GetBackColor().G - Theme.Color(Theme.Hex.HealingDone).G) < 1e-9
    end
  end
  return true
end)())
m:SelectTab("done")

check("max-hit sub-line is its own label, not appended to the number",
  m.lineLabels[3].sub ~= nil and m.lineLabels[3].sub:GetText() ~= ""
  and not m.lineLabels[3].value:GetText():find(" ", 1, true),
  m.lineLabels[3].value:GetText() .. " / " .. m.lineLabels[3].sub:GetText())
check("three stat rows, none overlapping the sub-line",
  select(2, m.lineLabels[3].label:GetPosition()) + 16 <= select(2, m.lineLabels[3].sub:GetPosition()))

------------------------------------------------------- live meter, compact mode
-- settings.compactMode keeps only the clock, the tab row and the headline number. Everything is
-- hidden rather than destroyed, so this section flips the setting back at the end and re-checks
-- the full shape -- the death-cause section below runs against a restored meter either way.
_G.settings.compactMode = true
m:ApplySettings()

check("compact mode is 160x76",
  select(1, m:GetSize()) == 160 and select(2, m:GetSize()) == 76,
  select(1, m:GetSize()) .. "x" .. select(2, m:GetSize()))
check("compact body is 28px and still fits the client",
  select(2, m.body:GetSize()) == 28 and 22 + select(2, m.body:GetSize()) <= 76 - 26,
  tostring(select(2, m.body:GetSize())))
-- Only the number moves: the corner cell is hidden in compact, so LayoutBody leaves it at its
-- full-mode coordinates rather than laying out something nobody can see.
check("compact headline moved up out of the caption's row",
  select(2, m.valueLabel:GetPosition()) == 2)

-- The tab strip is what sets the window's minimum width, so the short label set is load-bearing:
-- these four cells have to span 180px exactly and each hold its own label.
check("compact tabs span the narrower window, four to a row", (function()
  local total = 0
  local keys = { "done", "taken", "healOut", "healIn" }
  for i = 1, 4 do
    local t = m.tabControls[keys[i]]
    local w = select(1, t.control:GetSize())
    if w ~= 40 then return false end
    if select(1, t.label:GetSize()) ~= w then return false end
    if select(1, t.underline:GetSize()) ~= w then return false end
    if select(1, t.control:GetPosition()) ~= (i - 1) * 40 then return false end
    total = total + w
  end
  return total == 160
end)())
check("compact tabs use the short heading set",
  m.tabControls.healOut.label:GetText() == "H OUT"
  and m.tabControls.healIn.label:GetText() == "H IN"
  and m.tabControls.done.label:GetText() == "DONE",
  m.tabControls.healOut.label:GetText() .. " / " .. m.tabControls.healIn.label:GetText())
-- ~7px per character is this codebase's own estimate (Analysis's ChipWidth, Controls' CellWidth).
-- Every compact heading has to clear it inside a 40px cell -- the tab strip, not the header or the
-- body, is what sets the 160px floor, so this is the check that would catch going too narrow.
check("every compact heading fits its 40px cell", (function()
  local keys = { "done", "taken", "healOut", "healIn" }
  for i = 1, 4 do
    if #m.tabControls[keys[i]].label:GetText() * 7 > 40 then return false end
  end
  return true
end)())
check("compact header drops the IN COMBAT text and moves Details to the right edge",
  not m.combatLabel:IsVisible()
  and select(1, m.analysisButton:GetPosition()) == 160 - 8 - 55
  and select(1, m.clockLabel:GetPosition()) == 16)
check("the compact clock does not run into the Details button",
  16 + select(1, m.clockLabel:GetSize()) <= select(1, m.analysisButton:GetPosition()),
  tostring(16 + select(1, m.clockLabel:GetSize())))
check("compact drops the corner total and gives the row to the one number",
  not m.rateLabel:IsVisible()
  and select(1, m.valueLabel:GetPosition()) == 8
  and select(1, m.valueLabel:GetSize()) == 160 - 16,
  tostring(select(1, m.valueLabel:GetSize())))
check("compact hides the caption, divider, stat rows and sub-line", (function()
  if m.captionLabel:IsVisible() or m.divider:IsVisible() then return false end
  for i = 1, 3 do
    if m.lineLabels[i].label:IsVisible() or m.lineLabels[i].value:IsVisible() then return false end
  end
  return not m.lineLabels[3].sub:IsVisible()
end)())
check("compact hides every spark column", (function()
  for i = 1, 60 do if m.sparkColumns[i]:IsVisible() then return false end end
  return true
end)())
-- The guard that matters: Refresh runs at up to 10Hz, so without RefreshSparkline's own compact
-- check every tick would redraw the band straight over the headline number in the 28px body.
m:Refresh()
check("a compact refresh does not bring the sparkline back", (function()
  for i = 1, 60 do if m.sparkColumns[i]:IsVisible() then return false end end
  return true
end)())
check("compact keeps the clock, the tabs and the headline",
  m.clockLabel:IsVisible() and m.valueLabel:IsVisible()
  and m.tabControls.done.control:IsVisible())
-- liveBarValue still decides WHICH number, there is just only one of them: "Both" puts the rate in
-- the big slot, so that is what compact shows, and the total it would have put in the corner is
-- gone rather than being squeezed in somewhere.
check("compact keeps liveBarValue's big-slot pick and shows only that",
  m.valueLabel:GetText() == Format.Rate(session:Rate("done")),
  m.valueLabel:GetText())
check("...and switching to Total swaps which number survives", (function()
  _G.settings.liveBarValue = "Total"
  m:Refresh()
  local total = (m.valueLabel:GetText() == Format.Number(session:Total("done")))
  _G.settings.liveBarValue = "Both"
  m:Refresh()
  return total and m.valueLabel:GetText() == Format.Rate(session:Rate("done"))
end)())
check("the headline row is a click target in compact",
  m.valueHit:IsVisible() and m.valueHit.MouseClick ~= nil)

_G.settings.compactMode = false
m:ApplySettings()
check("leaving compact restores the 260x186 footprint",
  select(1, m:GetSize()) == 260 and select(2, m:GetSize()) == 186,
  select(1, m:GetSize()) .. "x" .. select(2, m:GetSize()))
check("...and the caption, stat rows and sparkline come back", (function()
  if not m.captionLabel:IsVisible() or not m.divider:IsVisible() then return false end
  for i = 1, 3 do
    if not m.lineLabels[i].label:IsVisible() then return false end
  end
  if m.valueHit:IsVisible() then return false end
  for i = 1, 60 do if m.sparkColumns[i]:IsVisible() then return true end end
  return false
end)())
check("...and the corner total comes back with its full-width geometry",
  m.rateLabel:IsVisible() and select(2, m.valueLabel:GetPosition()) == 18
  and select(1, m.valueLabel:GetSize()) == 150 and select(1, m.rateLabel:GetPosition()) == 160
  and m.rateLabel:GetText() == Format.Number(session:Total("done")),
  m.rateLabel:GetText())
check("...and the tabs go back to 65px and their full headings",
  select(1, m.tabControls.done.control:GetSize()) == 65
  and m.tabControls.healOut.label:GetText() == "HEAL OUT",
  m.tabControls.healOut.label:GetText())
check("...and the header text and mid-header Details slot come back",
  m.combatLabel:IsVisible() and select(1, m.analysisButton:GetPosition()) == 95
  and select(1, m.clockLabel:GetPosition()) == 160)

------------------------------------------------------------------ death cause
session.died = true
session.endTime = clock
local d = DeathCause()
-- 28 header + 50 cause block + deathRows * 24 + 2 countdown rule. The default deathRows is 8,
-- so the window is taller than the fixed 380x200 it used to be; the ROW POOL is 12 deep and the
-- window is resized down to whatever the setting asks for.
check("death window is sized for settings.deathRows",
  select(1, d:GetSize()) == 380 and select(2, d:GetSize()) == 28 + 50 + 8 * 24 + 2,
  select(1, d:GetSize()) .. "x" .. select(2, d:GetSize()))

-- craft a lastTaken ring where the biggest hit is NOT the killing blow
session.lastTaken = {}
session:PushLastTaken({ time = clock - 8, kind = "damage", skill = "Serrated Slash",
  dmgType = DamageType.Common, amount = 51355, initiator = "Khardâmu", moralePct = 0.42 })
session:PushLastTaken({ time = clock - 6, kind = "damage", skill = "Harrowing Slash",
  dmgType = DamageType.Shadow, amount = 201386, initiator = "Khardâmu", moralePct = 0.30 })
session:PushLastTaken({ time = clock - 4, kind = "tempMorale", amount = 178749, moralePct = 0.18 })
session:PushLastTaken({ time = clock - 2, kind = "damage", skill = "Deadly Presence",
  dmgType = DamageType.Shadow, amount = 44798, initiator = "Khardâmu", moralePct = 0.09 })
session:PushLastTaken({ time = clock, kind = "damage", skill = "a minor melee attack",
  dmgType = DamageType.Common, amount = 15482, initiator = "Khardâmu", moralePct = 0 })

d:Show(session)
check("death window shown", d:IsVisible())
check("killing blow is the last damage row (row 5)", d.killIndex == 5, tostring(d.killIndex))
check("killing blow row is tinted", d.rows[5].tint:IsVisible()
  and math.abs(d.rows[5].tint:GetBackColor().R - Theme.Color(Theme.Hex.DeathKillFill).R) < 1e-9)
check("killing blow row has a fatal-coloured left mark", d.rows[5].mark:IsVisible()
  and math.abs(d.rows[5].mark:GetBackColor().R - Theme.Color(Theme.Hex.DamageFatal).R) < 1e-9)
check("biggest hit (row 2) is marked separately", d.rows[2].tint:IsVisible()
  and math.abs(d.rows[2].mark:GetBackColor().R - Theme.Color(Theme.Hex.AccentLight).R) < 1e-9)
check("biggest hit carries the MAX tag", d.rows[2].maxTag:GetText() == "MAX")
check("killing blow does NOT also carry a MAX tag", d.rows[5].maxTag:GetText() == "")
check("the temp-morale row is not marked",
  not d.rows[3].tint:IsVisible() and d.rows[3].maxTag:GetText() == "")
check("unmarked ordinary rows stay clean",
  not d.rows[1].tint:IsVisible() and not d.rows[4].tint:IsVisible())

check("every row shows its morale percentage",
  d.rows[1].pct:GetText() == "42%" and d.rows[5].pct:GetText() == "0%",
  d.rows[1].pct:GetText() .. " / " .. d.rows[5].pct:GetText())
check("low-morale rows switch the bar to the severe colour",
  math.abs(d.rows[5].bar.fill:GetBackColor().R - Theme.Color(Theme.Hex.DamageSevere).R) < 1e-9)
check("healthy rows keep the morale colour",
  math.abs(d.rows[1].bar.fill:GetBackColor().R - Theme.Color(Theme.Hex.Morale).R) < 1e-9)

-- columns must not run past the window's inner edge
local right = 344 + 26
check("columns end inside the 380px window", right <= 379, tostring(right))
check("MAX tag sits between skill and amount", 214 + 28 <= 242)

-- when the biggest hit IS the killing blow, only one mark
session.lastTaken = {}
session:PushLastTaken({ time = clock - 2, kind = "damage", skill = "Small", dmgType = 1,
  amount = 100, initiator = "X", moralePct = 0.5 })
session:PushLastTaken({ time = clock, kind = "damage", skill = "Huge", dmgType = 1,
  amount = 999999, initiator = "X", moralePct = 0 })
d:Show(session)
check("when the killing blow IS the biggest hit, it is marked once as the kill",
  d.rows[2].maxTag:GetText() == ""
  and math.abs(d.rows[2].mark:GetBackColor().R - Theme.Color(Theme.Hex.DamageFatal).R) < 1e-9)

-- a ring with only a temp-morale row must not crash or mark anything
session.lastTaken = {}
session:PushLastTaken({ time = clock, kind = "tempMorale", amount = 500, moralePct = 0.3 })
d:Show(session)
check("a temp-morale-only ring marks nothing and does not crash",
  not d.rows[1].tint:IsVisible() and d.rows[1].maxTag:GetText() == "")

print("")
if fails == 0 then print("ALL WINDOW CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
