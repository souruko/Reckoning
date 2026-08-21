-- Constructs the REAL Analysis window against the Turbine stub and drives every interaction the
-- redesign added: view tabs, picker chips, range handles, legend toggles, buff charting, column
-- sorting and the skill/buff splitter -- checking that the block stack stays consistent and the
-- numbers agree with what Session:Slice says they should be.
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
  IsInCombat = function() return true end,  -- heals only count in combat, see Sessions.lua
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

-- 6. KPI totals agree with Session:Slice for the full fight.
-- The first card leads with the rate; the running total is its sub-line ("12,345 total").
local function KpiTotal() return (w.kpiCards[1].sub:GetText():gsub(" total$", "")) end
w:SelectView("taken")
local kpiTotal = KpiTotal()
check("TOTAL KPI matches Session:Total for the full fight",
  kpiTotal == Format.Number(session:Total("taken")), kpiTotal)
check("first KPI leads with the rate", w.kpiCards[1].label:GetText() == "DPS"
  and w.kpiCards[1].value:GetText():find("/s", 1, true) ~= nil,
  w.kpiCards[1].label:GetText() .. " " .. w.kpiCards[1].value:GetText())
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
  KpiTotal() == Format.Number(scopedTotal),
  KpiTotal() .. " vs " .. Format.Number(scopedTotal))
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
  KpiTotal() == Format.Number(session:Total("taken")))

-- 9. picker filter still works, and combines with a range
local who = session:TopCounterpart("taken")
w:SelectFilter(who)
check("filtering by a source rescopes the total",
  KpiTotal() == Format.Number(session:Total("taken", who)),
  KpiTotal())
w:OnRangeChanged(8, 40)
local f2, t2 = w:RangeSeconds()
check("filter and range combine",
  KpiTotal() == Format.Number(session:Total("taken", who, f2, t2)),
  KpiTotal())
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
check("buff table shows a row per tracked buff -- as ListBox items, not just pooled Controls",
  w.buffScrollView:GetItemCount() == 3, tostring(w.buffScrollView:GetItemCount()))
check("buff summary names the count and scope",
  w.buffHeader.summary:GetText():find("3 tracked", 1, true) ~= nil,
  w.buffHeader.summary:GetText())
check("buff section is 604px wide next to the 233px panels",
  select(1, w.buffHolder:GetSize()) == 604, tostring(select(1, w.buffHolder:GetSize())))
check("buff row content is narrower than the section -- SCROLLBAR_WIDTH reserved for the scrollbar",
  w.buffWidth == 594, tostring(w.buffWidth))
check("the buff section header is a plain label, not a collapse toggle",
  w.buffHeader.caret == nil and w.ToggleBuffSection == nil and w.buffsOpen == nil)

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

check("the buff table is always listed now that it cannot be collapsed",
  w.buffTableHeader:IsVisible() and w.buffScrollView:GetItemCount() == 3,
  tostring(w.buffScrollView:GetItemCount()))

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

-- 14. picker overflow: a fight with far more targets than fit on one row.
-- 20 targets with long names is well past the ~5 chips a single 848px row holds, so this
-- exercises the wrap, the truncation and the "+N more" chip in one go.
local crowd = Session(2000)
Turbine.Engine._time = 2000
for i = 1, 20 do
  -- Deliberately multi-byte: truncation must cut on a character boundary, not mid-sequence.
  crowd:AddDone("Blade-storm", 1, "Angmarim Standard-bearer \195\187" .. i, 100 + i, nil, nil, 2000 + i)
end
crowd.endTime = 2030
w:SelectSession(crowd)
w:SelectView("done")

local function VisibleChips()
  local out = {}
  for i = 1, #w.pickerChips do
    local c = w.pickerChips[i]
    if c.control:IsVisible() then
      local x, y = c.control:GetPosition()
      out[#out + 1] = { chip = c, x = x, y = y, w = select(1, c.control:GetSize()) }
    end
  end
  return out
end

local shown = VisibleChips()
check("picker wraps instead of running off the content column", #shown > 1 and (function()
  for i = 1, #shown do
    if shown[i].x + shown[i].w > 848 then return false end
  end
  return true
end)(), "#chips=" .. #shown)
check("collapsed picker is capped at two rows", w.pickerRowsWanted == 2,
  tostring(w.pickerRowsWanted))
check("picker row is sized for both rows",
  select(2, w.pickerRow:GetSize()) == 2 * 22 + 4, tostring(select(2, w.pickerRow:GetSize())))
check("blocks below the picker shifted down by the extra row",
  select(2, w.kpiRow:GetPosition()) == 72 + 26 and select(2, w.graphHolder:GetPosition()) == 133 + 26,
  select(2, w.kpiRow:GetPosition()) .. " / " .. select(2, w.graphHolder:GetPosition()))

local more = shown[#shown]
check("last chip is the '+N more' overflow chip",
  more.chip.isMore == true and more.chip.label:GetText():find("^%+%d+ more$") ~= nil,
  more.chip.label:GetText())
check("overflow count plus shown chips accounts for every name",
  tonumber(more.chip.label:GetText():match("%d+")) + (#shown - 1) == 21,
  more.chip.label:GetText() .. " + " .. (#shown - 1))
check("long names are truncated with ASCII dots, not a Unicode ellipsis", (function()
  for i = 2, #shown - 1 do
    local t = shown[i].chip.label:GetText()
    if t:find("%.%.$") then return t:byte(#t - 2) < 128 or true end
  end
  return false
end)())
check("truncated labels never split a UTF-8 character", (function()
  for i = 1, #shown - 1 do
    local t = shown[i].chip.label:GetText():gsub("%.%.$", "")
    local n = #t
    if n > 0 then
      local last = t:byte(n)
      -- a trailing lead byte (>= 0xC0) would be the first half of a cut-in-two character
      if last >= 192 then return false end
    end
  end
  return true
end)())
check("chips still carry the FULL name as their filter value", (function()
  for i = 2, #shown - 1 do
    local c = shown[i].chip
    if type(c.value) ~= "string" or c.value:find("%.%.$") then return false end
  end
  return true
end)())

-- filtering by a truncated chip must still hit the real target
local probe = shown[2].chip
w:SelectFilter(probe.value)
check("a truncated chip filters by its real target",
  KpiTotal() == Format.Number(crowd:Total("done", probe.value)),
  KpiTotal())
w:SelectFilter(nil)

-- expanding
more.chip.control.MouseClick()
check("clicking '+N more' expands the picker", w.pickerExpanded == true)
local expanded = VisibleChips()
check("expanding shows every chip", #expanded == 22, "#chips=" .. #expanded)
check("expanded picker grew past two rows", w.pickerRowsWanted > 2,
  tostring(w.pickerRowsWanted))
check("expanded blocks shifted down further",
  select(2, w.graphHolder:GetPosition()) == 133 + (w.pickerRowsWanted - 1) * 26,
  tostring(select(2, w.graphHolder:GetPosition())))
local last = expanded[#expanded]
check("expanded picker ends with a 'less' chip",
  last.chip.isMore == true and last.chip.label:GetText() == "less", last.chip.label:GetText())
-- The trailing chip carries a nil value, which is also the "no filter" state -- it must not end
-- up painted as though "All targets" were selected.
check("the 'less' chip never renders as the selected filter", (function()
  w:SelectFilter(nil)
  return last.chip.inset:GetBackColor() == Theme.Color(Theme.Hex.WindowFill)
    and w.pickerChips[1].inset:GetBackColor() == Theme.Color(Theme.Hex.ActiveTab)
end)())

last.chip.control.MouseClick()
check("clicking 'less' folds the picker back", w.pickerExpanded == false)
check("folding restores the two-row stack",
  select(2, w.graphHolder:GetPosition()) == 133 + 26,
  tostring(select(2, w.graphHolder:GetPosition())))

-- the tallest picker at the shortest window is the worst case for the stack below it
w.pickerExpanded = true
w:RefreshContent()
w:Resize(1080, 600); w:Layout()
check("an expanded picker at minimum height still lays out without a negative size", (function()
  local blocks = { w.pickerRow, w.kpiRow, w.graphHolder, w.tableHolder, w.buffHolder, w.panelsHolder }
  for i = 1, #blocks do
    local bw, bh = blocks[i]:GetSize()
    if bw < 0 or bh < 0 then return false end
  end
  return true
end)())
check("the skill table still has rows at minimum height with the picker expanded",
  select(2, w.tableHolder:GetSize()) >= 44, tostring(select(2, w.tableHolder:GetSize())))
w:Resize(1080, 820); w:Layout()
w.pickerExpanded = false
w:RefreshContent()

-- a wider window fits more chips per row, and the stack follows
w:Resize(1440, 820); w:Layout()
check("a wider window puts more chips on each row", (function()
  local wide = VisibleChips()
  local firstRow = 0
  for i = 1, #wide do if wide[i].y == 0 then firstRow = firstRow + 1 end end
  return firstRow > 5
end)())
w:Resize(1080, 820); w:Layout()

-- switching view or session forgets the expansion
more = VisibleChips()[#VisibleChips()]
more.chip.control.MouseClick()
check("re-expanded before the reset check", w.pickerExpanded == true)
w:SelectView("taken")
check("switching views collapses the picker again", w.pickerExpanded == false)
w:SelectSession(session)
check("a single-row picker reports one row", w.pickerRowsWanted == 1,
  tostring(w.pickerRowsWanted))
check("a single-row picker restores the original y offsets",
  select(2, w.kpiRow:GetPosition()) == 72 and select(2, w.graphHolder:GetPosition()) == 133)

-- 15. column sorting: every header is a click target, second click reverses.
w:SelectSession(session)
w:SelectView("done")

local function TableCol(col)
  local out = {}
  for i = 1, w.scrollView:GetItemCount() do
    out[i] = w.tableRowPool[i].row.labels[col]:GetText()
  end
  return out
end
local function AsNumbers(list)
  local out = {}
  for i = 1, #list do out[i] = tonumber((list[i]:gsub(",", ""))) or 0 end
  return out
end
-- Names sort case-insensitively (Analysis lowercases both sides), so compare the same way here.
local function Ordered(list, ascending)
  for i = 1, #list do
    if type(list[i]) == "string" then list[i] = list[i]:lower() end
  end
  for i = 2, #list do
    if ascending and list[i] < list[i - 1] then return false end
    if not ascending and list[i] > list[i - 1] then return false end
  end
  return true
end

check("more than one skill row to sort", w.scrollView:GetItemCount() > 1,
  tostring(w.scrollView:GetItemCount()))
check("skill table defaults to TOTAL descending",
  Ordered(AsNumbers(TableCol(7)), false) and w.tableHeaderLabels[7]:GetText() == "TOTAL v",
  w.tableHeaderLabels[7]:GetText())

local rowCount = w.scrollView:GetItemCount()
w.tableHeaderCells[7].MouseClick()
check("second click on TOTAL reverses to ascending",
  Ordered(AsNumbers(TableCol(7)), true) and w.tableHeaderLabels[7]:GetText() == "TOTAL ^",
  w.tableHeaderLabels[7]:GetText())
check("reversing does not change how many rows are listed",
  w.scrollView:GetItemCount() == rowCount)

w.tableHeaderCells[1].MouseClick()
check("clicking SKILL sorts names A-Z first (text columns start ascending)",
  Ordered(TableCol(1), true), table.concat(TableCol(1), " | "))
check("the direction marker moved to the new column",
  w.tableHeaderLabels[1]:GetText():find("%^$") ~= nil
    and w.tableHeaderLabels[7]:GetText() == "TOTAL",
  w.tableHeaderLabels[1]:GetText() .. " / " .. w.tableHeaderLabels[7]:GetText())
w.tableHeaderCells[1].MouseClick()
check("second click on SKILL reverses to Z-A", Ordered(TableCol(1), false),
  table.concat(TableCol(1), " | "))

w.tableHeaderCells[3].MouseClick()
check("clicking HITS starts descending (numeric column)",
  Ordered(AsNumbers(TableCol(3)), false), table.concat(TableCol(3), " | "))
w.tableHeaderCells[6].MouseClick()
check("clicking MAX sorts by the largest hit",
  Ordered(AsNumbers(TableCol(6)), false), table.concat(TableCol(6), " | "))

-- the sort survives a range drag and a filter, and applies in the heal views' own column set
w:OnRangeChanged(1, 30)
check("sort survives a range change", Ordered(AsNumbers(TableCol(6)), false))
w.resetButton.MouseClick()
w:SelectView("healIn")
check("the heal views' 6-column set sorts too", (function()
  w.tableHeaderCells[6].MouseClick()   -- TOTAL is column 6 in the heal spec, not column 7
  return w.tableHeaderLabels[6]:GetText() == "TOTAL v" and Ordered(AsNumbers(TableCol(6)), false)
end)(), w.tableHeaderLabels[6]:GetText())
w:SelectView("done")

-- AVOID is damage-only: sorting by it and then switching to a heal view has to fall back
w.tableHeaderCells[5].MouseClick()
check("AVOID is sortable in the damage views",
  w.tableHeaderLabels[5]:GetText() == "AVOID v", w.tableHeaderLabels[5]:GetText())
w:SelectView("healOut")
check("a heal view drops the AVOID sort back to TOTAL descending",
  w.tableSort.key == "total" and w.tableSort.ascending == false
    and w.tableHeaderLabels[6]:GetText() == "TOTAL v",
  w.tableSort.key .. " / " .. w.tableHeaderLabels[6]:GetText())
w:SelectView("done")

-- buff table
local function BuffCol(col)
  local out = {}
  for i = 1, w.buffScrollView:GetItemCount() do
    out[i] = w.buffRows[i].cells[col]:GetText()
  end
  return out
end

check("buff table defaults to UPTIME % ascending",
  w.buffHeaderLabels[4]:GetText() == "UPTIME % ^", w.buffHeaderLabels[4]:GetText())
w.buffHeaderCells[4].MouseClick()
check("clicking UPTIME % reverses it",
  w.buffHeaderLabels[4]:GetText() == "UPTIME % v", w.buffHeaderLabels[4]:GetText())

w.buffHeaderCells[3].MouseClick()
check("clicking BUFF sorts buff names A-Z", Ordered(BuffCol(3), true),
  table.concat(BuffCol(3), " | "))
w.buffHeaderCells[3].MouseClick()
check("second click on BUFF reverses to Z-A", Ordered(BuffCol(3), false),
  table.concat(BuffCol(3), " | "))
check("only the sorted buff column carries a marker",
  w.buffHeaderLabels[4]:GetText() == "UPTIME %" and w.buffHeaderLabels[3]:GetText() == "BUFF v",
  w.buffHeaderLabels[3]:GetText() .. " / " .. w.buffHeaderLabels[4]:GetText())
check("sorting the buff table keeps every row listed",
  w.buffScrollView:GetItemCount() == #Buffs.Stats(session, nil, nil),
  tostring(w.buffScrollView:GetItemCount()))
check("sorting the buff table does not disturb the charted lanes",
  w.graph.laneCount == #w.charted, w.graph.laneCount .. " vs " .. #w.charted)

w.buffHeaderCells[6].MouseClick()
check("clicking APPS starts descending", Ordered(AsNumbers(BuffCol(6)), false),
  table.concat(BuffCol(6), " | "))

-- the BUFF header's click target spans the checkbox/icon gutter, matching its label
check("the BUFF header cell spans the icon column", (function()
  local x, width = select(1, w.buffHeaderCells[3]:GetPosition()), select(1, w.buffHeaderCells[3]:GetSize())
  return x == w.buffColumnX[2].x and width == w.buffColumnX[2].width + w.buffColumnX[3].width
end)())
check("skill header cells cover the full column, padding included", (function()
  for i = 1, #w.tableColumns do
    local cx, cw = select(1, w.tableHeaderCells[i]:GetPosition()), select(1, w.tableHeaderCells[i]:GetSize())
    if cx ~= w.tableColumns[i].x or cw ~= w.tableColumns[i].width then return false end
  end
  return true
end)())

-- 16. the skill-table / buff-table splitter, and vertical resize past the old 880 cap.
-- Layout constants repeated here on purpose (they are file-locals in UI/Analysis.lua): a buff
-- row is 22px, the bottom row's own chrome is 26 + 1 + 20 + 20 = 67, and the skill table's floor
-- is 20 + 3 * 22 = 86.
local BUFF_ROW, BOTTOM_MIN, TABLE_MIN = 22, 67, 86
local LEFT = Turbine.UI.MouseButton.Left

w:Resize(1080, 820); w:Layout()

local function Stack()
  local tableY, tableH = select(2, w.tableHolder:GetPosition()), select(2, w.tableHolder:GetSize())
  local splitY, splitH = select(2, w.splitter:GetPosition()), select(2, w.splitter:GetSize())
  local buffY, buffH = select(2, w.buffHolder:GetPosition()), select(2, w.buffHolder:GetSize())
  return tableY, tableH, splitY, splitH, buffY, buffH
end

local tableY, tableH, splitY, splitH, buffY, buffH = Stack()
check("the splitter sits directly under the skill table", splitY == tableY + tableH,
  splitY .. " vs " .. (tableY + tableH))
check("the bottom row starts directly under the splitter", buffY == splitY + splitH,
  buffY .. " vs " .. (splitY + splitH))
check("the splitter spans the whole content column",
  select(1, w.splitter:GetSize()) == select(1, w.tableHolder:GetSize()))
check("the side panels share the bottom row's height",
  select(2, w.panelsHolder:GetSize()) == buffH)

-- Mouse coordinates in a MouseMove are relative to the CONTROL, so as the splitter moves under
-- a still-pressed mouse the same physical mouse position reports a different args.Y. These two
-- helpers reproduce that: SplitDrag(d) says "the mouse is now d pixels from where it was
-- pressed", and converts that to whatever args.Y the client would report given where the
-- splitter has since moved to. Dragging with raw, unadjusted args.Y would test a mouse model
-- the real one isn't.
local pressY, pressSplitY = 5, 0
local function SplitPress()
  pressSplitY = select(2, w.splitter:GetPosition())
  w.splitter.MouseDown(w.splitter, { Button = LEFT, Y = pressY })
end
local function SplitDrag(d)
  local nowSplitY = select(2, w.splitter:GetPosition())
  w.splitter.MouseMove(w.splitter, { Y = pressY + d + (pressSplitY - nowSplitY) })
end

-- drag one buff row's worth upward: the bottom row grows, the skill table gives up the same
local before = w.splitBottom
SplitPress()
SplitDrag(-BUFF_ROW)
check("dragging the splitter up grows the buff section by one row",
  w.splitBottom == before + BUFF_ROW, w.splitBottom .. " vs " .. (before + BUFF_ROW))
local _, newTableH = Stack()
check("the skill table gave up exactly what the buff section gained",
  newTableH == tableH - BUFF_ROW, newTableH .. " vs " .. (tableH - BUFF_ROW))

-- sub-row movement snaps to nothing rather than drifting the layout a pixel at a time
local held = w.splitBottom
SplitDrag(-BUFF_ROW + 4)
check("a sub-row drag snaps back to the same split", w.splitBottom == held,
  w.splitBottom .. " vs " .. held)

w.splitter.MouseUp(w.splitter, { Button = LEFT })
check("the split persisted to the window's saved geometry",
  _G.settings.windows.analysis.split == w.splitBottom,
  tostring(_G.settings.windows.analysis.split))
check("saving the split did not disturb the saved size",
  _G.settings.windows.analysis.width == nil or _G.settings.windows.analysis.width >= 1080)

-- clamps: all the way down leaves the buff section at its own chrome height, all the way up
-- still leaves the skill table its floor
SplitPress()
SplitDrag(4000)
check("dragging the splitter to the bottom leaves the buff chrome, not zero",
  w.splitBottom == BOTTOM_MIN, tostring(w.splitBottom))
check("the skill table takes the freed space",
  select(2, w.tableHolder:GetSize()) > tableH,
  select(2, w.tableHolder:GetSize()) .. " vs " .. tableH)
SplitDrag(-4000)
check("dragging the splitter to the top still leaves the skill table its floor",
  select(2, w.tableHolder:GetSize()) >= TABLE_MIN,
  tostring(select(2, w.tableHolder:GetSize())))
check("the blocks still do not overlap at the extreme", (function()
  local ty, th, sy, sh, by = Stack()
  return sy == ty + th and by == sy + sh
end)())
w.splitter.MouseUp(w.splitter, { Button = LEFT })

-- everything still inside the window after the extremes
check("the bottom row still ends inside the window", (function()
  local _, _, _, _, by, bh = Stack()
  return by + bh <= 820 - 32
end)(), tostring(select(5, Stack()) + select(6, Stack())))

SplitPress()
SplitDrag(-6 * BUFF_ROW)
w.splitter.MouseUp(w.splitter, { Button = LEFT })

-- vertical resize: the old hardcoded 880 ceiling is gone -- the cap is the display's height
-- (the stub reports 1080) less a margin
w:Resize(1080, 1000); w:Layout()
check("a 1000px-tall window lays out", (function()
  local blocks = { w.pickerRow, w.kpiRow, w.graphHolder, w.tableHolder, w.buffHolder, w.panelsHolder }
  for i = 1, #blocks do
    local bw, bh = blocks[i]:GetSize()
    if bw < 0 or bh < 0 then return false end
  end
  return true
end)())
check("the extra height went to the skill table, not off the bottom",
  select(2, w.tableHolder:GetSize()) > tableH and (function()
    local _, _, _, _, by, bh = Stack()
    return by + bh <= 1000 - 32
  end)(), tostring(select(2, w.tableHolder:GetSize())))
check("the split itself is unchanged by a taller window",
  select(2, w.buffHolder:GetSize()) == w.splitBottom,
  select(2, w.buffHolder:GetSize()) .. " vs " .. w.splitBottom)

-- a window too short to honour the split must clamp it for that pass WITHOUT overwriting the
-- preference, or growing the window back would not restore it
local preference = w.splitBottom
w:Resize(1080, 600); w:Layout()
check("a short window clamps the split without forgetting it",
  w.splitBottom == preference and w.splitEffective < preference,
  w.splitBottom .. " / " .. w.splitEffective)
check("the skill table keeps its floor at the minimum height",
  select(2, w.tableHolder:GetSize()) >= TABLE_MIN,
  tostring(select(2, w.tableHolder:GetSize())))
w:Resize(1080, 1000); w:Layout()
check("growing the window restores the dragged split",
  select(2, w.buffHolder:GetSize()) == preference,
  select(2, w.buffHolder:GetSize()) .. " vs " .. preference)

-- 17. the resize gripper. Same mouse model as the splitter: args are relative to the gripper,
-- which follows the corner it resizes, so GripDrag(dx, dy) says "the mouse is now dx/dy from
-- where it was pressed" and converts that to the args the client would report. Feeding raw
-- unadjusted args here would hide exactly the bug this section exists to catch -- the window
-- growing by the FULL offset on every move event instead of by the change since the last one.
local gripPressX, gripPressY, gripGX, gripGY = 5, 5, 0, 0
local function GripPress()
  gripGX, gripGY = w.gripper:GetPosition()
  w.gripper.MouseDown(w.gripper, { Button = LEFT, X = gripPressX, Y = gripPressY })
end
local function GripDrag(dx, dy)
  local nowX, nowY = w.gripper:GetPosition()
  w.gripper.MouseMove(w.gripper, {
    X = gripPressX + dx + (gripGX - nowX),
    Y = gripPressY + dy + (gripGY - nowY),
  })
end

w:Resize(1080, 820); w:Layout()
check("the gripper sits in the window's bottom-right corner", (function()
  local gx, gy = w.gripper:GetPosition()
  return gx == 1080 - 12 and gy == 820 - 12
end)())

GripPress()
GripDrag(0, 100)
check("dragging the gripper 100px down grows the window by 100px",
  select(2, w:GetSize()) == 920, tostring(select(2, w:GetSize())))
check("the gripper followed the corner", select(2, w.gripper:GetPosition()) == 920 - 12,
  tostring(select(2, w.gripper:GetPosition())))

-- the regression: further move events with the mouse held still must not keep growing it
GripDrag(0, 100)
GripDrag(0, 100)
check("holding the mouse still does not keep resizing the window",
  select(2, w:GetSize()) == 920, tostring(select(2, w:GetSize())))

GripDrag(60, 160)
check("continuing the same drag tracks the mouse one-to-one",
  select(1, w:GetSize()) == 1140 and select(2, w:GetSize()) == 980,
  select(1, w:GetSize()) .. "x" .. select(2, w:GetSize()))
GripDrag(0, 0)
check("dragging back to the press point restores the original size",
  select(1, w:GetSize()) == 1080 and select(2, w:GetSize()) == 820,
  select(1, w:GetSize()) .. "x" .. select(2, w:GetSize()))
w.gripper.MouseUp(w.gripper, { Button = LEFT })

-- clamps: the ceiling is the display height (the stub reports 1080) less the margin, not 880
GripPress()
GripDrag(0, 4000)
check("the gripper drags past the old 880 cap", select(2, w:GetSize()) > 880,
  tostring(select(2, w:GetSize())))
check("the gripper stops at the display height less the margin",
  select(2, w:GetSize()) == 1080 - 40, tostring(select(2, w:GetSize())))
check("width clamps at its own maximum", (function()
  GripDrag(4000, 4000)
  return select(1, w:GetSize()) == 1440
end)(), tostring(select(1, w:GetSize())))
w.gripper.MouseUp(w.gripper, { Button = LEFT })

GripPress()
GripDrag(-4000, -4000)
check("the gripper still refuses to go below the minimum size",
  select(1, w:GetSize()) == 1080 and select(2, w:GetSize()) == 600,
  select(1, w:GetSize()) .. "x" .. select(2, w:GetSize()))
w.gripper.MouseUp(w.gripper, { Button = LEFT })
check("MouseUp persisted the size", _G.settings.windows.analysis.height == 600,
  tostring(_G.settings.windows.analysis.height))
check("persisting the size did not disturb the saved split",
  _G.settings.windows.analysis.split ~= nil)

w:Resize(1080, 820); w:Layout()

print("")
if fails == 0 then print("ALL ANALYSIS CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
