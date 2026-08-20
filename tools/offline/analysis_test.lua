-- Constructs the REAL Analysis window against the Turbine stub and drives every interaction the
-- redesign added: view tabs, picker chips, range handles, legend toggles, buff charting and the
-- collapse toggle -- checking that the block stack stays consistent and the numbers agree with
-- what Session:Slice says they should be.
local env = dofile("stub.lua"); local ROOT = env.ROOT
import "Reckoning.Constants"
Trigger = {}; import "Reckoning.Parse.en"; import "Reckoning.Settings"

local effectSet = {}
local function MakeEffect(name, icon)
  return { GetName = function() return name end, GetIcon = function() return icon end,
           IsDebuff = function() return false end }
end
_G.lp = {
  GetName = function() return "Luxtheninth" end,
  GetMorale = function() return 5e5 end, GetMaxMorale = function() return 9e5 end,
  GetTarget = function() return nil end,
  GetEffects = function()
    local o = effectSet
    return { GetCount = function() return #o end,
             Get = function(_, i) return o[i] end }
  end,
}
LocalPlayer = _G.lp; LocalPlayer.name = LocalPlayer:GetName()
Settings.Load()
import "Reckoning.Session"; import "Reckoning.Sessions"; import "Reckoning.Buffs"
import "Reckoning.Events"; import "Reckoning.UI"

local fails = 0
local function check(label, ok, detail)
  if not ok then fails = fails + 1 end
  print(string.format("%-60s %s%s", label, ok and "OK" or "**FAIL**", detail and ("  " .. detail) or ""))
end

-- Build a real fight from the reference logs, with buffs polled through the real path.
effectSet = { MakeEffect("Writ of Health", "icon:writ"), MakeEffect("Bracing Guard", nil),
              MakeEffect("Mending Verse", "icon:verse") }
local clock = 1000
local function Feed(path, ct)
  for line in io.lines(path) do
    if line ~= "" and not line:match("^###") then
      clock = clock + 0.37; Turbine.Engine._time = clock
      Turbine.Chat.Received(nil, { ChatType = ct, Message = line })
      Buffs.Poll(clock)
    end
  end
end
Turbine.Engine._time = clock
Feed(ROOT .. "/reference/Combat_20260819_1.txt", Turbine.ChatType.PlayerCombat)
effectSet = { MakeEffect("Writ of Health", "icon:writ") }  -- two drop mid-fight
Feed(ROOT .. "/reference/Enemy_20260819_1.txt", Turbine.ChatType.EnemyCombat)

local session = Sessions.current
Sessions.Close()
check("session archived", Sessions.list[1] == session)

-- The stub loads every file into _G rather than emulating Turbine's per-directory package
-- environments, so UI classes are bare globals here (in-game it is UI.Analysis()).
local w = Analysis()
check("window constructed at the shipped size",
  select(1, w:GetSize()) == 1080 and select(2, w:GetSize()) == 820,
  select(1, w:GetSize()) .. "x" .. select(2, w:GetSize()))
check("session auto-selected on close", w.selectedSession == session)
check("range starts at full fight", w:IsFullRange())

-- 1. tab order and centring
local order = {}
for k, t in pairs(w.viewTabs) do order[select(1, t.control:GetPosition())] = k end
check("tab order is done / taken / healOut / healIn",
  order[12] == "done" and order[152] == "taken" and order[292] == "healOut" and order[432] == "healIn")
check("tab labels are centred", w.viewTabs.done.label._align == Turbine.UI.ContentAlignment.MiddleCenter)

-- 2. content column is the mock's 848 at the minimum window width
check("content column is 848px wide", select(1, w.graphHolder:GetSize()) == 848,
  tostring(select(1, w.graphHolder:GetSize())))
check("graph holder is sized, not just positioned",
  select(2, w.graphHolder:GetSize()) == GraphHeightFor(w.layoutLanes))

-- 3. block stack matches the redesign's y offsets
check("picker at y=40", select(2, w.pickerRow:GetPosition()) == 40)
check("KPI row at y=72", select(2, w.kpiRow:GetPosition()) == 72)
check("graph at y=133", select(2, w.graphHolder:GetPosition()) == 133)
check("skill table is full content width", select(1, w.tableHolder:GetSize()) == 848)

-- 4. KPI cards no longer collide (value 16..36, sub starts at 36)
local card = w.kpiCards[1]
local vy = select(2, card.value:GetPosition()); local vh = select(2, card.value:GetSize())
local sy = select(2, card.sub:GetPosition())
check("KPI value and sub no longer overlap", vy + vh <= sy, vy .. "+" .. vh .. " vs " .. sy)

-- 5. merged CRIT / DEV column, and every column fits the viewport
local function ColumnsFit()
  local total = 0
  for i = 1, #w.tableColumns do total = total + w.tableColumns[i].width end
  return total, w.tableListWidth
end
for _, view in ipairs({ "done", "taken", "healOut", "healIn" }) do
  w:SelectView(view)
  local total, viewport = ColumnsFit()
  check("columns fit the viewport in the '" .. view .. "' view", total <= viewport,
    total .. " vs " .. viewport)
  local headers = {}
  for i = 1, 7 do
    local l = w.tableHeaderLabels[i]
    if l:IsVisible() then headers[#headers + 1] = l:GetText() end
  end
  check("'" .. view .. "' header row has a single CRIT / DEV column",
    table.concat(headers, "|"):find("CRIT / DEV", 1, true) ~= nil, table.concat(headers, " "))
  check("'" .. view .. "' has no separate DEV column",
    table.concat(headers, "|"):find("|DEV", 1, true) == nil)
end
w:SelectView("taken")
check("damage views carry an AVOID column",
  w.tableHeaderLabels[5]:GetText() == "AVOID", w.tableHeaderLabels[5]:GetText())
w:SelectView("healIn")
check("heal views drop AVOID and name the counterpart column FROM",
  w.tableHeaderLabels[2]:GetText() == "FROM" and not w.tableHeaderLabels[7]:IsVisible())

-- 6. KPI totals agree with Session:Slice for the full fight
w:SelectView("taken")
local kpiTotal = w.kpiCards[1].value:GetText()
check("TOTAL KPI matches Session:Total for the full fight",
  kpiTotal == Format.Number(session:Total("taken")), kpiTotal)
check("fifth KPI reads ACTIVE while unscoped", w.kpiCards[5].label:GetText() == "ACTIVE")
check("header chip says FULL FIGHT", w.rangeChip:GetText():find("FULL FIGHT", 1, true) ~= nil,
  w.rangeChip:GetText())

-- 7. dragging a range handle rescopes everything
w:OnRangeChanged(10, 30)
check("range is no longer full", not w:IsFullRange())
local fromSec, toSec = w:RangeSeconds()
check("range maps to real seconds", fromSec ~= nil and toSec > fromSec,
  tostring(fromSec) .. ".." .. tostring(toSec))
local scopedTotal = session:Total("taken", nil, fromSec, toSec)
check("TOTAL KPI followed the range",
  w.kpiCards[1].value:GetText() == Format.Number(scopedTotal),
  w.kpiCards[1].value:GetText() .. " vs " .. Format.Number(scopedTotal))
check("scoped total is strictly less than the whole fight",
  scopedTotal < session:Total("taken"))
check("fifth KPI switches to RANGE", w.kpiCards[5].label:GetText() == "RANGE")
check("header chip switches to RANGE", w.rangeChip:GetText():find("RANGE", 1, true) ~= nil,
  w.rangeChip:GetText())
check("graph shows the range overlay", w.graph.dimLeft:IsVisible() and w.graph.dimRight:IsVisible())
check("side panels followed the range", (function()
  local sum = 0
  for i = 1, 5 do
    if w.panelA.rows[i].value:IsVisible() then
      sum = sum + tonumber((w.panelA.rows[i].value:GetText():gsub(",", "")))
    end
  end
  return sum > 0 and sum <= scopedTotal + 1
end)())

-- 8. RESET RANGE
w.resetButton.MouseClick()
check("RESET RANGE returns to the full fight", w:IsFullRange())
check("TOTAL KPI back to the whole fight",
  w.kpiCards[1].value:GetText() == Format.Number(session:Total("taken")))

-- 9. picker filter still works, and combines with a range
local who = session:TopCounterpart("taken")
w:SelectFilter(who)
check("filtering by a source rescopes the total",
  w.kpiCards[1].value:GetText() == Format.Number(session:Total("taken", who)),
  w.kpiCards[1].value:GetText())
w:OnRangeChanged(8, 40)
local f2, t2 = w:RangeSeconds()
check("filter and range combine",
  w.kpiCards[1].value:GetText() == Format.Number(session:Total("taken", who, f2, t2)),
  w.kpiCards[1].value:GetText())
w:SelectFilter(nil)
w.resetButton.MouseClick()

-- 10. a hidden series survives a range drag (SetSeries must not fire per refresh)
w:SelectView("taken")
w.graph:ToggleSeries("healIn")
check("series hidden by the legend", w.graph.hidden.healIn == true)
w:OnRangeChanged(5, 44)
check("still hidden after a range drag", w.graph.hidden.healIn == true)
w:SelectView("healOut"); w:SelectView("taken")
check("switching views clears the hidden set", w.graph.hidden.healIn ~= true)
w.resetButton.MouseClick()

-- 11. buff section
local stats = Buffs.Stats(session, nil, nil)
check("buffs were tracked through the real poll path", #stats == 3, "#stats=" .. #stats)
check("buff table shows a row per tracked buff",
  (function() local n = 0
     for i = 1, 12 do if w.buffRows[i].container:IsVisible() then n = n + 1 end end
     return n end)() == 3)
check("buff summary names the count and scope",
  w.buffHeader.summary:GetText():find("3 tracked", 1, true) ~= nil,
  w.buffHeader.summary:GetText())
check("buff table is 604px wide next to the 233px panels",
  w.buffWidth == 604, tostring(w.buffWidth))
check("buff caret is ASCII, not a Unicode triangle",
  w.buffHeader.caret:GetText() == "v", w.buffHeader.caret:GetText())

local first = stats[1].name
w:ToggleCharted(first)
check("charting a buff records it", w:IsCharted(first) == 1)
check("charting adds a lane to the graph", w.graph.laneCount == 1)
check("graph block grew by one lane",
  select(2, w.graphHolder:GetSize()) == GraphHeightFor(1),
  select(2, w.graphHolder:GetSize()) .. " vs " .. GraphHeightFor(1))
check("charted state persisted to settings", _G.settings.chartedBuffs[1] == first)

w:ToggleCharted(stats[2].name); w:ToggleCharted(stats[3].name)
check("three buffs charted", #w.charted == 3)
check("graph shows three lanes", w.graph.laneCount == 3)
-- a fourth charts by dropping the oldest
effectSet = {}
w:ToggleCharted(first)   -- un-chart the first
w:ToggleCharted(first)   -- re-chart it: now 3 again, oldest dropped
check("charted stays capped at three", #w.charted == 3, tostring(#w.charted))
check("the re-charted buff is the newest entry", w.charted[3] == first)

w:ToggleBuffSection()
check("collapsing hides the buff table header", not w.buffTableHeader:IsVisible())
check("collapse persisted", _G.settings.buffsOpen == false)
check("collapsing hides every buff row",
  (function() for i = 1, 12 do if w.buffRows[i].container:IsVisible() then return false end end
     return true end)())
w:ToggleBuffSection()
check("re-opening brings the rows back", w.buffTableHeader:IsVisible())

-- 12. resize keeps the stack consistent
w:Resize(1440, 880); w:Layout()
check("resize widens the content column", select(1, w.graphHolder:GetSize()) == 1440 - 208 - 24,
  tostring(select(1, w.graphHolder:GetSize())))
check("graph followed the resize", w.graph.plotWidth == 1440 - 208 - 24)
check("table columns still fit after resize", (function()
  local total = 0
  for i = 1, #w.tableColumns do total = total + w.tableColumns[i].width end
  return total <= w.tableListWidth end)())
check("header chip repositioned on resize",
  select(1, w.resetButton:GetPosition()) == 1440 - 22 - 96)
check("everything still fits vertically", (function()
  local bottom = select(2, w.buffHolder:GetPosition()) + select(2, w.buffHolder:GetSize())
  return bottom <= 880 - 32 end)(),
  tostring(select(2, w.buffHolder:GetPosition()) + select(2, w.buffHolder:GetSize())))

-- at the minimum height everything must still be laid out without a negative size
w:Resize(1080, 600); w:Layout()
check("minimum height still lays out", select(2, w.tableHolder:GetSize()) >= 44,
  tostring(select(2, w.tableHolder:GetSize())))
check("buff section survives the squeeze", select(2, w.buffHolder:GetSize()) >= 27,
  tostring(select(2, w.buffHolder:GetSize())))
w:Resize(1080, 820); w:Layout()

-- 13. selecting a session resets the range
w:OnRangeChanged(20, 30)
w:SelectSession(session)
check("selecting a session resets the range to full fight", w:IsFullRange())

print("")
if fails == 0 then print("ALL ANALYSIS CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
