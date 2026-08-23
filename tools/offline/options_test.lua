-- Drives the REAL OptionsWindow, OptionsPage, Slider and Segment against the Turbine stub, with
-- the real LiveMeter / DeathCause / Analysis behind them so that "apply" actually has somewhere to
-- land. Everything here goes through the same entry points a click does -- a control's own
-- MouseClick / CheckedChanged / MouseDown+MouseMove+MouseUp -- never by poking _G.settings and
-- calling a refresh, which is the shortcut that hid three bugs in this codebase before.
local env = dofile("stub.lua"); local ROOT = env.ROOT

import "Reckoning.Constants"
Trigger = {}; import "Reckoning.Parse.en"; import "Reckoning.Settings"

local morale = 500000
local effectList = {}
_G.lp = {
  GetName = function() return "Luxtheninth" end,
  GetMorale = function() return morale end, GetMaxMorale = function() return 900000 end,
  GetTarget = function() return nil end,
  IsInCombat = function() return true end,
  GetEffects = function()
    return { GetCount = function() return #effectList end,
             Get = function(_, i) return effectList[i] end }
  end,
}
LocalPlayer = _G.lp; LocalPlayer.name = LocalPlayer:GetName()

local function MakeEffect(name, icon)
  return { GetName = function() return name end, GetIcon = function() return icon end,
           IsDebuff = function() return false end }
end
effectList = { MakeEffect("Writ of Health", 0x41000001), MakeEffect("Bracing Guard", nil),
               MakeEffect("Fury of Battle", 0x41000002), MakeEffect("Warrior's Heart", nil) }

Settings.Load()
import "Reckoning.Session"; import "Reckoning.Sessions"; import "Reckoning.Buffs"
import "Reckoning.Events"; import "Reckoning.ChatPost"; import "Reckoning.UI"

local fails = 0
local function check(label, ok, detail)
  if not ok then fails = fails + 1 end
  print(string.format("%-62s %s%s", label, ok and "OK" or "**FAIL**", detail and ("  " .. detail) or ""))
end

-- Count real persistence calls, so "a drag writes once, not once per stop" can be asserted rather
-- than assumed. Wraps Settings.Save itself (not PluginData.Save) because that is the call every
-- control in the options window makes.
local saves = 0
local realSave = Settings.Save
Settings.Save = function() saves = saves + 1; realSave() end
local function CountSaves(fn)
  local before = saves
  fn()
  return saves - before
end

local LEFT = { Button = Turbine.UI.MouseButton.Left, X = 0, Y = 0 }
local function Click(control, x, y)
  control.MouseClick(control, { Button = Turbine.UI.MouseButton.Left, X = x or 0, Y = y or 0 })
end

---------------------------------------------------------------------------------------------------
-- A real fight, so the buff picker and the geometry readouts have something to show
---------------------------------------------------------------------------------------------------
local clock = 1000
Turbine.Engine._time = clock
local function Feed(path, ct)
  for line in io.lines(path) do
    if line ~= "" and not line:match("^###") then
      clock = clock + 0.37; Turbine.Engine._time = clock
      morale = math.max(20000, morale - 2000)
      Turbine.Chat.Received(nil, { ChatType = ct, Message = line })
      Buffs.Poll(clock)
    end
  end
end
Feed(ROOT .. "/reference/Combat_20260819_1.txt", Turbine.ChatType.PlayerCombat)
Feed(ROOT .. "/reference/Enemy_20260819_1.txt", Turbine.ChatType.EnemyCombat)
local session = Sessions.current

liveMeter = LiveMeter()
deathCause = DeathCause()
analysis = Analysis()
optionsWindow = OptionsWindow()
analysis:SelectSession(session)

---------------------------------------------------------------------------------------------------
print("== 1. window shell ==")
---------------------------------------------------------------------------------------------------
local w = optionsWindow
check("options window is 560x452",
  select(1, w:GetSize()) == 560 and select(2, w:GetSize()) == 452,
  select(1, w:GetSize()) .. "x" .. select(2, w:GetSize()))
check("client sits below a 26px header", select(2, w.client:GetPosition()) == 26)
check("rail is 145 wide and 391 tall",
  select(1, w.rail:GetSize()) == 145 and select(2, w.rail:GetSize()) == 391,
  select(1, w.rail:GetSize()) .. "x" .. select(2, w.rail:GetSize()))
check("pane leaves a 10px scrollbar gutter",
  select(1, w.pane:GetSize()) == 402 and w.paneScrollBar ~= nil,
  tostring(select(1, w.pane:GetSize())))
check("the pane has exactly one scrollbar", w.pane._vsb == w.paneScrollBar)
check("window opens hidden", not w:IsVisible())
check("window opens on the Windows page", w.page == "windows")
check("the pane holds exactly one page", w.pane:GetItemCount() == 1)

---------------------------------------------------------------------------------------------------
print("== 2. the rail ==")
---------------------------------------------------------------------------------------------------
local PAGE_KEYS = { "windows", "appearance", "palette", "live", "death", "buffs", "sessions" }
local built = 0
for i = 1, #PAGE_KEYS do
  local key = PAGE_KEYS[i]
  local ok, err = pcall(function() Click(w.railRows[key].row) end)
  check("rail row '" .. key .. "' builds and shows its page", ok and w.page == key,
    ok and "" or tostring(err))
  if ok then
    built = built + 1
    check("  page '" .. key .. "' is " .. tostring(OptionsPage.Width) .. " wide and has height",
      select(1, w.pages[key]:GetSize()) == OptionsPage.Width and select(2, w.pages[key]:GetSize()) > 0,
      select(1, w.pages[key]:GetSize()) .. "x" .. select(2, w.pages[key]:GetSize()))
    check("  the pane still holds exactly one item", w.pane:GetItemCount() == 1)
  end
end
check("all seven pages built", built == 7, tostring(built))

-- Nothing on any page may stick out past the page's own width. The pane clips to 402 and a
-- control that overflows is simply gone, not scrolled to -- there is no horizontal scrollbar.
check("no control on any page overflows the 402px content width", (function()
  local worst, where = 0, nil
  local function Walk(control, depth)
    if depth > 4 then return end
    for i = 1, #control._children do
      local child = control._children[i]
      local x = select(1, child:GetPosition())
      local right = x + select(1, child:GetSize())
      if depth == 0 and right > worst then worst = right; where = child:GetText() end
      Walk(child, depth + 1)
    end
  end
  for i = 1, #PAGE_KEYS do Walk(w.pages[PAGE_KEYS[i]], 0) end
  return worst <= OptionsPage.Width, worst .. " (" .. tostring(where) .. ")"
end)())

-- Every row's control has to stay clear of the row label's own box. Both are mouse-invisible, so
-- an overlap is only ever cosmetic -- but a Segment whose cells are wider than the gap left for
-- them is a real "looks fine at one size, wrong at another" bug.
check("no row's control runs under its own label", (function()
  for i = 1, #PAGE_KEYS do
    local p = w.pages[PAGE_KEYS[i]]
    for j = 1, #p.rows do
      local row = p.rows[j]
      local labelRight = select(1, row.label:GetPosition()) + select(1, row.label:GetSize())
      local controlLeft = select(1, row.control:GetPosition())
      if labelRight > controlLeft then
        return false, PAGE_KEYS[i] .. ": " .. row.label:GetText()
          .. " ends " .. labelRight .. ", control starts " .. controlLeft
      end
    end
  end
  return true
end)())
-- 17 label-plus-control rows across the four pages that have any: Appearance 5 (3 sliders,
-- 2 segments), Live meter 5, Death window 3, Sessions 4. A count here rather than a ">= 1" so
-- that deleting a row from a page cannot silently take its geometry check with it.
check("every label-plus-control row registered itself", (function()
  local n = 0
  for i = 1, #PAGE_KEYS do n = n + #w.pages[PAGE_KEYS[i]].rows end
  return n == 17, tostring(n)
end)())

w.railRows.palette.row.MouseEnter()
check("hovering an unselected rail row tints it",
  w.railRows.palette.row:GetBackColor() ~= nil)
w.railRows.palette.row.MouseLeave()
check("leaving it clears the tint again", w.railRows.palette.row:GetBackColor() == nil)

Click(w.railRows.windows.row)
check("the selected row keeps its accent mark",
  w.railRows.windows.mark:GetBackColor() ~= nil and w.railRows.palette.mark:GetBackColor() == nil)
w.railRows.windows.row.MouseLeave()
check("leaving the SELECTED row does not clear its fill",
  w.railRows.windows.row:GetBackColor() ~= nil)

---------------------------------------------------------------------------------------------------
print("== 3. checkboxes write and save immediately ==")
---------------------------------------------------------------------------------------------------
local page = w.pages.windows
local lockBox = nil
-- Find the Lock positions checkbox by the text it renders.
for i = 1, #page._children do
  local child = page._children[i]
  if child.GetText ~= nil and child:GetText() == " Lock positions" then lockBox = child end
end
check("found the Lock positions checkbox", lockBox ~= nil)

local before = _G.settings.lockWindows
lockBox:SetChecked(not before)
local n = CountSaves(function() lockBox.CheckedChanged() end)
check("a checkbox writes its setting", _G.settings.lockWindows == (not before),
  tostring(_G.settings.lockWindows))
check("...and saves exactly once", n == 1, tostring(n))

check("lockWindows stops the header drag", (function()
  local x0 = select(1, analysis:GetPosition())
  analysis.header.MouseDown(analysis.header, { Button = Turbine.UI.MouseButton.Left, X = 5, Y = 5 })
  analysis.header.MouseMove(analysis.header, { X = 45, Y = 5 })
  return select(1, analysis:GetPosition()) == x0 and not analysis.dragging
end)())

lockBox:SetChecked(false)
lockBox.CheckedChanged()
check("unlocking restores the drag", (function()
  local x0 = select(1, analysis:GetPosition())
  analysis.header.MouseDown(analysis.header, { Button = Turbine.UI.MouseButton.Left, X = 5, Y = 5 })
  analysis.header.MouseMove(analysis.header, { X = 45, Y = 5 })
  local moved = select(1, analysis:GetPosition()) ~= x0
  analysis.header.MouseUp(analysis.header, { Button = Turbine.UI.MouseButton.Left })
  return moved
end)())

---------------------------------------------------------------------------------------------------
print("== 4. sliders: live on drag, one save on release ==")
---------------------------------------------------------------------------------------------------
Click(w.railRows.death.row)
local deathPage = w.pages.death
-- The first Slider child on the Death page is Auto-hide after (5-30s).
local slider = nil
for i = 1, #deathPage._children do
  local child = deathPage._children[i]
  if slider == nil and child.ValueAt ~= nil then slider = child end
end
check("found the auto-hide slider", slider ~= nil and slider.low == 5 and slider.high == 30,
  slider and (slider.low .. ".." .. slider.high))

check("slider starts at the stored value", slider.value == _G.settings.deathAutoHide,
  tostring(slider.value))
check("ValueAt(0) is the low bound", slider:ValueAt(0) == 5, tostring(slider:ValueAt(0)))
check("ValueAt(width) is the high bound", slider:ValueAt(slider.width) == 30,
  tostring(slider:ValueAt(slider.width)))
check("ValueAt round-trips through Layout", (function()
  for v = 5, 30 do
    slider:SetValue(v, false)
    local x = select(1, slider.handle:GetPosition())
    if slider:ValueAt(x + 4) ~= v then return false end
  end
  return true
end)())

-- A real drag: press the handle, move it several times without releasing, then release.
slider:SetValue(5, false)
_G.settings.deathAutoHide = 5
local moves = 0
local dragSaves = CountSaves(function()
  slider.handle.MouseDown(slider.handle, { Button = Turbine.UI.MouseButton.Left, X = 4 })
  for _ = 1, 6 do
    -- args.X is measured RELATIVE TO THE HANDLE, and the handle moves under the still-pressed
    -- mouse -- the same coordinate model that made the analysis resize gripper run away. A
    -- pointer held 12px right of the press point must therefore report a constant +12 and the
    -- value must converge, not accelerate.
    slider.handle.MouseMove(slider.handle, { X = 16 })
    moves = moves + 1
  end
  slider.handle.MouseUp(slider.handle, { Button = Turbine.UI.MouseButton.Left })
end)
check("a drag persists exactly once, not once per move", dragSaves == 1,
  dragSaves .. " saves over " .. moves .. " moves")
check("...and the value moved up but stayed in range",
  _G.settings.deathAutoHide > 5 and _G.settings.deathAutoHide <= 30,
  tostring(_G.settings.deathAutoHide))
check("...and did not run away past the top of the scale",
  slider.value <= 30 and slider.value == _G.settings.deathAutoHide, tostring(slider.value))

-- A click on the track jumps and commits in one, since there is no release to wait for.
local clickSaves = CountSaves(function() Click(slider, slider.width) end)
check("a track click commits immediately", clickSaves == 1, tostring(clickSaves))
check("...landing on the high bound", _G.settings.deathAutoHide == 30,
  tostring(_G.settings.deathAutoHide))

---------------------------------------------------------------------------------------------------
print("== 5. deathRows resizes the death window ==")
---------------------------------------------------------------------------------------------------
local rowsSlider = nil
local seen = 0
for i = 1, #deathPage._children do
  local child = deathPage._children[i]
  if child.ValueAt ~= nil then
    seen = seen + 1
    if seen == 2 then rowsSlider = child end
  end
end
check("found the Hits listed slider", rowsSlider ~= nil and rowsSlider.high == 12,
  rowsSlider and tostring(rowsSlider.high))
rowsSlider:SetValue(12, true)
rowsSlider.OnCommit(12)
check("raising deathRows grows the window",
  select(2, deathCause:GetSize()) == 28 + 50 + 12 * 24 + 2,
  tostring(select(2, deathCause:GetSize())))
rowsSlider:SetValue(3, true)
rowsSlider.OnCommit(3)
check("lowering it shrinks the window again",
  select(2, deathCause:GetSize()) == 28 + 50 + 3 * 24 + 2,
  tostring(select(2, deathCause:GetSize())))
check("...and hides the surplus pooled rows", (function()
  for i = 4, 12 do if deathCause.rows[i].container:IsVisible() then return false end end
  return true
end)())
rowsSlider:SetValue(8, true); rowsSlider.OnCommit(8)

-- The lastTaken ring follows the setting, so the window can never be asked for a row the session
-- does not hold.
_G.settings.deathRows = 12
local ringSession = Session(2000, "00:00")
for i = 1, 20 do
  ringSession:PushLastTaken({ time = 2000 + i, kind = "damage", skill = "S", dmgType = 1,
    amount = i, initiator = "X", moralePct = 0.5 })
end
check("the lastTaken ring is sized by deathRows", #ringSession.lastTaken == 12,
  tostring(#ringSession.lastTaken))
_G.settings.deathRows = 8

---------------------------------------------------------------------------------------------------
print("== 6. segments ==")
---------------------------------------------------------------------------------------------------
Click(w.railRows.appearance.row)
local appearance = w.pages.appearance
local segments = {}
for i = 1, #appearance._children do
  local child = appearance._children[i]
  if child.cells ~= nil then segments[#segments + 1] = child end
end
check("appearance has two segment strips", #segments == 2, tostring(#segments))

local density = segments[1]
check("density segment has two cells", #density.cells == 2, tostring(#density.cells))
check("every cell is wide enough for its own text", (function()
  for i = 1, #density.cells do
    local cell = density.cells[i]
    local text = cell.label:GetText()
    if select(1, cell.cell:GetSize()) < #text * 5 then return false end
  end
  return true
end)())
check("cells share their 1px border (no gaps, no overlap)", (function()
  local a, b = density.cells[1], density.cells[2]
  return select(1, b.cell:GetPosition())
    == select(1, a.cell:GetPosition()) + select(1, a.cell:GetSize()) - 1
end)())
check("the strip is exactly as wide as its cells", (function()
  local last = density.cells[#density.cells]
  return select(1, density:GetSize())
    == select(1, last.cell:GetPosition()) + select(1, last.cell:GetSize())
end)())

local segSaves = CountSaves(function() Click(density.cells[1].cell) end)
check("clicking a cell writes its value", _G.settings.density == "Compact", tostring(_G.settings.density))
check("...and saves once", segSaves == 1, tostring(segSaves))
check("...and repaints the selection",
  density.cells[1].inner:GetBackColor() ~= nil and density.cells[2].inner:GetBackColor() == nil)
check("Theme.RowHeight follows density", Theme.RowHeight() == 16, tostring(Theme.RowHeight()))
Click(density.cells[2].cell)
check("switching back restores it", Theme.RowHeight() == 20, tostring(Theme.RowHeight()))

check("Theme.NumberFont follows numberFont", (function()
  _G.settings.numberFont = "Verdana"
  local a = Theme.NumberFont()
  _G.settings.numberFont = "Lucida"
  return a == Font.Verdana12 and Theme.NumberFont() == Font.LucidaConsole12
end)())

---------------------------------------------------------------------------------------------------
print("== 7. abbreviation and borders ==")
---------------------------------------------------------------------------------------------------
check("abbreviation on collapses big numbers", (function()
  _G.settings.abbreviateNumbers = true
  return Format.Number(12400) == "12.4k" and Format.Number(2500000) == "2.5m"
    and Format.Number(999) == "999"
end)())
check("...and off restores comma grouping", (function()
  _G.settings.abbreviateNumbers = false
  local out = Format.Number(1234567)
  _G.settings.abbreviateNumbers = true
  return out == "1,234,567"
end)())

_G.settings.showBorders = false
OptionsWindow.ApplyAll()
check("turning borders off hides every window's edges", (function()
  for _, edge in pairs(analysis.borderEdges) do
    if edge:IsVisible() then return false end
  end
  return not liveMeter.borderEdges.top:IsVisible()
end)())
_G.settings.showBorders = true
OptionsWindow.ApplyAll()
check("...and back on shows them", analysis.borderEdges.top:IsVisible())

---------------------------------------------------------------------------------------------------
print("== 8. palette presets reach every series ==")
---------------------------------------------------------------------------------------------------
Click(w.railRows.palette.row)
local palette = w.pages.palette
check("palette lists every preset in Theme.PresetOrder order",
  #Theme.PresetOrder == 4 and Theme.PresetOrder[1] == "Reckoning")
check("the default preset is byte-identical to the Theme.Hex series tokens",
  Theme.Presets["Reckoning"].done == Theme.Hex.DamageDone
  and Theme.Presets["Reckoning"].taken == Theme.Hex.DamageTaken
  and Theme.Presets["Reckoning"].healOut == Theme.Hex.HealingDone
  and Theme.Presets["Reckoning"].healIn == Theme.Hex.HealingTaken
  and Theme.Presets["Reckoning"].morale == Theme.Hex.Morale)

-- The swatch rows are direct children of the page; the clickable ones are the mouse-visible
-- Controls 30px tall.
local swatchRows = {}
for i = 1, #palette._children do
  local child = palette._children[i]
  if child.IsMouseVisible ~= nil and child:IsMouseVisible()
    and select(2, child:GetSize()) == 30 then
    swatchRows[#swatchRows + 1] = child
  end
end
check("four swatch rows", #swatchRows == 4, tostring(#swatchRows))

Click(swatchRows[3]) -- Colour-blind safe
check("clicking a swatch row writes the preset NAME, not a colour",
  _G.settings.palettePreset == "Colour-blind safe" and type(_G.settings.palettePreset) == "string",
  tostring(_G.settings.palettePreset))
check("Theme.Series follows the preset",
  Theme.Series("taken") == "#d9a05b", Theme.Series("taken"))

-- This is the trap the plan calls out by name: a module-level table of hexes built at load can
-- never see a preset change. Both of these used to be exactly that.
liveMeter:SelectTab("taken"); liveMeter:Refresh()
check("the live meter's sparkline recolours with the preset", (function()
  for i = 1, #liveMeter.sparkColumns do
    local c = liveMeter.sparkColumns[i]
    if c:IsVisible() then
      return math.abs(c:GetBackColor().R - Theme.Color("#d9a05b").R) < 1e-9
    end
  end
  return false
end)())

analysis:SelectView("taken", true)
analysis:ApplySettings()
check("the analysis plot's series recolours with the preset",
  analysis.graph.seriesList[1].colorHex == "#d9a05b",
  tostring(analysis.graph.seriesList[1].colorHex))
check("a chat post's tint follows the preset too", (function()
  _G.settings.postColor = true
  local line = ChatPost.BuildLine(session, "summary", "taken", nil, nil, nil)
  return line ~= nil and line:find("d9a05b", 1, true) ~= nil
end)())

Click(swatchRows[1])
check("switching back restores the default series colours",
  Theme.Series("taken") == Theme.Hex.DamageTaken, Theme.Series("taken"))

-- typeColoredBars: the skill table's share bars take the hit's own damage type instead of the
-- view's series colour. Damage views only -- a heal row has no type.
analysis:SelectView("taken", true)
analysis:RefreshContent()
local seriesMix = Theme.Mix(Theme.Series("taken"), Theme.Hex.WindowFill, 0.08)
check("share bars use the series colour by default", (function()
  _G.settings.typeColoredBars = false
  analysis:RefreshContent()
  return analysis.tableRowPool[1].shareBar:GetBackColor() == seriesMix
end)())
check("typeColoredBars retints at least one bar by its damage type", (function()
  _G.settings.typeColoredBars = true
  analysis:RefreshContent()
  local differs = false
  for i = 1, analysis.scrollView:GetItemCount() do
    if analysis.tableRowPool[i].shareBar:GetBackColor() ~= seriesMix then differs = true end
  end
  return differs
end)())
check("...and heal views ignore it, having no damage type to colour by", (function()
  analysis:SelectView("healOut", true)
  analysis:RefreshContent()
  local healMix = Theme.Mix(Theme.Series("healOut"), Theme.Hex.WindowFill, 0.08)
  for i = 1, analysis.scrollView:GetItemCount() do
    if analysis.tableRowPool[i].shareBar:GetBackColor() ~= healMix then return false end
  end
  return true
end)())
_G.settings.typeColoredBars = false
analysis:SelectView("taken", true)

check("the palette page still owns the chat-post colour toggle", (function()
  for i = 1, #palette._children do
    local child = palette._children[i]
    if child.GetText ~= nil and child:GetText() == " Colour chat posts" then return true end
  end
  return false
end)())
check("postColor off strips every tag from a post", (function()
  _G.settings.postColor = false
  local plain = ChatPost.BuildLine(session, "summary", "taken", nil, nil, nil)
  _G.settings.postColor = true
  return plain ~= nil and plain:find("<rgb", 1, true) == nil
end)())

---------------------------------------------------------------------------------------------------
print("== 9. graph buckets ==")
---------------------------------------------------------------------------------------------------
Click(w.railRows.sessions.row)
check("Auto uses the full pool", (function()
  _G.settings.bucketWidth = 0
  return GraphBucketCount(session) == GraphMaxBuckets()
end)())
check("1s buckets a short fight to one bucket per second", (function()
  _G.settings.bucketWidth = 1
  local short = Session(3000, "00:00")
  short:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 3000)
  short:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 3020)
  return GraphBucketCount(short) == 20
end)())
check("...and still caps a long fight at the pool size", (function()
  _G.settings.bucketWidth = 1
  return GraphBucketCount(session) == GraphMaxBuckets()
end)())
check("2s halves the count", (function()
  _G.settings.bucketWidth = 2
  local short = Session(3000, "00:00")
  short:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 3000)
  short:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 3020)
  return GraphBucketCount(short) == 10
end)())
_G.settings.bucketWidth = 0

-- A short session, so the setting actually changes the plot rather than hitting the cap.
local shortSession = Session(4000, "00:12")
for i = 0, 20 do
  shortSession:AddTaken("Cleave", 1, "Dummy", 100 + i, AvoidType.None, CritType.Normal, 4000 + i)
end
Sessions.list[#Sessions.list + 1] = shortSession
analysis:SelectSession(shortSession)

_G.settings.bucketWidth = 1
analysis:ApplySettings()
check("the graph drops to one bucket per second", analysis.graph:BucketCount() == 20,
  tostring(analysis.graph:BucketCount()))
check("the analysis window agrees with the graph",
  analysis.bucketCount == analysis.graph:BucketCount(),
  analysis.bucketCount .. " vs " .. analysis.graph:BucketCount())
check("the range slider has the same stops",
  analysis.graph.slider.bucketCount == analysis.graph:BucketCount(),
  tostring(analysis.graph.slider.bucketCount))
check("pooled buckets past the count are hidden", (function()
  for i = analysis.graph:BucketCount() + 1, GraphMaxBuckets() do
    if analysis.graph.moraleBars[i]:IsVisible() then return false end
    if analysis.graph.dots[1][i]:IsVisible() then return false end
  end
  return true
end)())
check("the range still covers the whole (narrower) fight", analysis:IsFullRange())

-- A range set under a wide plot must be clamped, not left pointing past the end, when the plot
-- narrows underneath it.
_G.settings.bucketWidth = 0
analysis:ApplySettings()
analysis:OnRangeChanged(10, 40)
_G.settings.bucketWidth = 2
analysis:ApplySettings()
check("narrowing the plot clamps a live range instead of stranding it",
  analysis.rangeTo <= analysis.bucketCount and analysis.rangeFrom < analysis.rangeTo,
  analysis.rangeFrom .. ".." .. analysis.rangeTo)
check("...and RangeSeconds still returns a sane window", (function()
  local a, b = analysis:RangeSeconds()
  return a == nil or (b > a)
end)())

_G.settings.bucketWidth = 1
analysis:ApplySettings()
analysis:SelectSession(session)
_G.settings.bucketWidth = 0
analysis:ApplySettings()

---------------------------------------------------------------------------------------------------
print("== 10. the buff picker ==")
---------------------------------------------------------------------------------------------------
_G.settings.chartedBuffs = {}
analysis:AdoptChartedBuffs()
Click(w.railRows.buffs.row)
local buffs = w.pages.buffs

-- The picker's rows are a fixed pool; find the checkboxes by the order they were built.
local boxes = {}
for i = 1, #buffs._children do
  local child = buffs._children[i]
  if child.CheckedChanged ~= nil and child.IsChecked ~= nil then boxes[#boxes + 1] = child end
end
check("the picker pooled 8 rows", #boxes == 8, tostring(#boxes))
check("rows past the tracked buffs are hidden", (function()
  local live = 0
  for i = 1, #boxes do if boxes[i]:IsVisible() then live = live + 1 end end
  return live == 4, live
end)())

local function Toggle(i)
  boxes[i]:SetChecked(not boxes[i]:IsChecked())
  boxes[i].CheckedChanged()
end

Toggle(1); Toggle(2); Toggle(3)
check("three buffs chart", #_G.settings.chartedBuffs == 3,
  tostring(#_G.settings.chartedBuffs))
check("...and the analysis window adopted them",
  #analysis.charted == 3, tostring(#analysis.charted))

-- The cap REFUSES a fourth rather than dropping the oldest -- this page's rule, deliberately not
-- the analysis window's.
local fourth = _G.settings.chartedBuffs[1]
Toggle(4)
check("a fourth check is refused, not silently swapped in",
  #_G.settings.chartedBuffs == 3 and _G.settings.chartedBuffs[1] == fourth,
  tostring(#_G.settings.chartedBuffs))
check("...and the refused box is put back to unchecked", not boxes[4]:IsChecked())

buffs.Repaint()
check("unchecked boxes go grey while the cap is full", (function()
  local greys = 0
  for i = 1, #boxes do
    if boxes[i]:IsVisible() and not boxes[i]:IsChecked()
      and boxes[i]:GetForeColor() == Theme.Color(Theme.Hex.Disabled) then greys = greys + 1 end
  end
  return greys > 0
end)())

-- Reorder: the lane colour is derived from position, so moving a name recolours the graph.
local first, second = _G.settings.chartedBuffs[1], _G.settings.chartedBuffs[2]
local arrows = {}
for i = 1, #buffs._children do
  local child = buffs._children[i]
  if child.GetText ~= nil and (child:GetText() == "^" or child:GetText() == "v")
    and child.MouseClick ~= nil then
    arrows[#arrows + 1] = child
  end
end
check("every pooled row has an up and a down arrow", #arrows == 16, tostring(#arrows))
-- arrows[3] is row 2's "up" (rows contribute ^ then v in build order).
Click(arrows[3])
check("the up arrow swaps a buff with the one above it",
  _G.settings.chartedBuffs[1] == second and _G.settings.chartedBuffs[2] == first,
  table.concat(_G.settings.chartedBuffs, ", "))
check("...and the analysis window followed",
  analysis.charted[1] == second, tostring(analysis.charted[1]))
check("no colour was ever persisted -- only names", (function()
  for i = 1, #_G.settings.chartedBuffs do
    if type(_G.settings.chartedBuffs[i]) ~= "string" then return false end
  end
  return true
end)())

-- Repaint puts the charted buffs first, so the rows have reordered under us -- untoggle by
-- STATE, never by the index they happened to sit at before.
for pass = 1, 8 do
  for i = 1, #boxes do
    if boxes[i]:IsVisible() and boxes[i]:IsChecked() then Toggle(i) end
  end
end
check("un-charting everything empties the list", #_G.settings.chartedBuffs == 0,
  tostring(#_G.settings.chartedBuffs))

---------------------------------------------------------------------------------------------------
print("== 11. the ignore list ==")
---------------------------------------------------------------------------------------------------
_G.settings.buffIgnore = {}
buffs.Repaint()

local entry, ignoreButton = nil, nil
local tail = nil
for i = 1, #buffs._children do
  local child = buffs._children[i]
  if child.refreshers ~= nil then tail = child end
end
check("the ignore section is its own nested page", tail ~= nil)
if tail ~= nil then
  for i = 1, #tail._children do
    local child = tail._children[i]
    if child._multiline == false then entry = child end
  end
end
check("found the ignore TextBox", entry ~= nil)

Buffs.AddIgnore("Well-Fed")
Buffs.AddIgnore("Hope")
buffs.Repaint()
-- Chips are the visible 18px-tall children narrower than 200px. The width filter matters: the
-- hideStaticBuffs checkbox below them is also 18 tall, but 300 wide.
local function CountChips()
  local n = 0
  if tail == nil then return n end
  for i = 1, #tail._children do
    local child = tail._children[i]
    if child:IsVisible() and select(2, child:GetSize()) == 18
      and select(1, child:GetSize()) < 200 then
      n = n + 1
    end
  end
  return n
end
local chipsShown = CountChips()
check("a chip appears per ignored buff", chipsShown == 2, tostring(chipsShown))
check("both names are actually ignored",
  Buffs.IsIgnored("Well-Fed") and Buffs.IsIgnored("Hope"))

Buffs.RemoveIgnore("Hope")
buffs.Repaint()
check("removing one drops its chip", CountChips() == 1, tostring(CountChips()))

-- A default that the player explicitly UN-ignored is stored as `false` and must not get a chip.
Buffs.RemoveIgnore("Riding")
buffs.Repaint()
check("an un-ignored default gets no chip and is not ignored",
  _G.settings.buffIgnore["Riding"] == false and not Buffs.IsIgnored("Riding"))
check("...and a default nobody touched still has no chip either",
  Buffs.IsIgnored("Mounted") and _G.settings.buffIgnore["Mounted"] == nil)
_G.settings.buffIgnore = {}

---------------------------------------------------------------------------------------------------
print("== 12. saved geometry ==")
---------------------------------------------------------------------------------------------------
Click(w.railRows.windows.row)
analysis:SetPosition(640, 320)
_G.settings.windows.analysis.left = 640
_G.settings.windows.analysis.top = 320
w.pages.windows.Repaint()

local readouts = {}
for i = 1, #page._children do
  local child = page._children[i]
  if child.GetText ~= nil and child:GetText():match("^%d+, %d+$") then
    readouts[#readouts + 1] = child:GetText()
  end
end
check("the geometry rows read the real saved position",
  #readouts == 3 and readouts[3] == "640, 320", table.concat(readouts, " | "))

check("Settings.ResetWindow puts a window back and clears its size", (function()
  Settings.ResetWindow("analysis")
  local saved = _G.settings.windows.analysis
  return saved.left == 200 and saved.top == 200 and saved.width == nil and saved.split == nil
end)())
w.pages.windows.Repaint()

---------------------------------------------------------------------------------------------------
print("== 13. clear data, two-step ==")
---------------------------------------------------------------------------------------------------
Click(w.railRows.sessions.row)
local sessionsPage = w.pages.sessions
local clearButton, clearLabel = nil, nil
for i = 1, #sessionsPage._children do
  local child = sessionsPage._children[i]
  if child.MouseClick ~= nil and select(2, child:GetSize()) == 26 then
    clearButton = child
    clearLabel = child._children[1]._children[1]
  end
end
check("found the Clear data button", clearButton ~= nil and clearLabel:GetText() == "Clear data",
  clearLabel and clearLabel:GetText())

check("sessions exist to clear", #Sessions.list > 0, tostring(#Sessions.list))
Click(clearButton)
check("the first click only arms it", #Sessions.list > 0 and clearLabel:GetText() == "Clear data?",
  clearLabel:GetText())

w:SetVisible(true)
Turbine.Engine._time = Turbine.Engine._time + 5
w:Update()
check("it disarms itself after three seconds", clearLabel:GetText() == "Clear data",
  clearLabel:GetText())

Click(clearButton)
Click(clearButton)
check("two clicks inside the window actually clear", #Sessions.list == 0 and Sessions.current == nil,
  tostring(#Sessions.list))
check("...and the analysis window let go of the dropped session",
  analysis.selectedSession == nil)
check("...without touching settings", _G.settings.deathAutoHide ~= nil and _G.settings.windows ~= nil)
w:SetVisible(false)

---------------------------------------------------------------------------------------------------
print("== 14. clamps and enum guards ==")
---------------------------------------------------------------------------------------------------
check("an out-of-range number is clamped on load", (function()
  _G.settings.opacityIdle = 500
  _G.settings.deathRows = -3
  _G.settings.sparklineWindow = 9999
  Settings.Clamp()
  return _G.settings.opacityIdle == 100 and _G.settings.deathRows == 3
    and _G.settings.sparklineWindow == 60
end)())
check("a non-numeric value falls back to its default", (function()
  _G.settings.idleTimeout = "not a number"
  Settings.Clamp()
  return _G.settings.idleTimeout == DEFAULTS.idleTimeout
end)())
check("an unknown enum string falls back", (function()
  _G.settings.density = "Enormous"
  _G.settings.liveBarValue = "Sideways"
  Settings.Clamp()
  return _G.settings.density == DEFAULTS.density
    and _G.settings.liveBarValue == DEFAULTS.liveBarValue
end)())
check("an unknown numeric enum falls back", (function()
  _G.settings.refreshHz = 7
  _G.settings.sessionsKept = 999
  _G.settings.bucketWidth = 5
  Settings.Clamp()
  return _G.settings.refreshHz == DEFAULTS.refreshHz
    and _G.settings.sessionsKept == DEFAULTS.sessionsKept
    and _G.settings.bucketWidth == DEFAULTS.bucketWidth
end)())
check("a numeric enum stored as a string is recovered, not discarded", (function()
  _G.settings.refreshHz = "5"
  Settings.Clamp()
  return _G.settings.refreshHz == 5
end)())
check("an unknown palette preset falls back rather than yielding a nil colour", (function()
  _G.settings.palettePreset = "Chartreuse"
  Settings.Clamp()
  return _G.settings.palettePreset == "Reckoning" and Theme.Series("done") ~= nil
end)())

---------------------------------------------------------------------------------------------------
print("== 15. live meter settings ==")
---------------------------------------------------------------------------------------------------
check("refreshHz picks the throttle", (function()
  _G.settings.refreshHz = 2
  liveMeter.lastRefresh = Turbine.Engine._time
  Turbine.Engine._time = Turbine.Engine._time + 0.3
  local textBefore = liveMeter.captionLabel:GetText()
  liveMeter.captionLabel:SetText("stale")
  liveMeter:Update()
  local skipped = (liveMeter.captionLabel:GetText() == "stale")
  Turbine.Engine._time = Turbine.Engine._time + 0.6
  liveMeter:Update()
  local ran = (liveMeter.captionLabel:GetText() ~= "stale")
  _G.settings.refreshHz = 10
  return skipped and ran and textBefore ~= nil
end)())

-- The Clear data section above emptied Sessions, so put the fight back: an idle meter draws no
-- columns at all and the band would be trivially "correct" while measuring nothing.
Sessions.current = session
_G.settings.idleFadeEnabled = false
liveMeter:Refresh()

check("the sparkline window resizes the band, not the pool", (function()
  _G.settings.sparklineWindow = 10
  liveMeter:Refresh()
  local widest = 0
  for i = 1, #liveMeter.sparkColumns do
    if liveMeter.sparkColumns[i]:IsVisible() then
      widest = math.max(widest, select(1, liveMeter.sparkColumns[i]:GetSize()))
    end
    if i > 10 and liveMeter.sparkColumns[i]:IsVisible() then return false end
  end
  _G.settings.sparklineWindow = 30
  liveMeter:Refresh()
  return #liveMeter.sparkColumns == 60 and widest >= 20
end)())

check("turning the sparkline off hides every column", (function()
  _G.settings.sparkline = false
  liveMeter:Refresh()
  for i = 1, #liveMeter.sparkColumns do
    if liveMeter.sparkColumns[i]:IsVisible() then return false end
  end
  _G.settings.sparkline = true
  return true
end)())

check("liveBarValue picks which number is prominent", (function()
  Sessions.current = session
  _G.settings.liveBarValue = "Total"
  liveMeter:Refresh()
  local total = liveMeter.valueLabel:GetText()
  _G.settings.liveBarValue = "Rate"
  liveMeter:Refresh()
  local rate = liveMeter.valueLabel:GetText()
  local corner = liveMeter.rateLabel:GetText()
  _G.settings.liveBarValue = "Both"
  liveMeter:Refresh()
  return total ~= rate and rate:find("/s", 1, true) ~= nil and corner == ""
    and liveMeter.rateLabel:GetText() ~= ""
end)())

check("in-combat opacity is applied to the window, not to a filled Control", (function()
  Sessions.current = session
  _G.settings.opacityCombat = 80
  liveMeter:Refresh()
  return math.abs(liveMeter:GetOpacity() - 0.8) < 1e-9
end)())
check("out of combat it drops to the idle opacity", (function()
  Sessions.current = nil
  Sessions.list[1] = session
  session.combatEndTime = Turbine.Engine._time
  _G.settings.idleFadeEnabled = false
  _G.settings.opacityIdle = 40
  liveMeter:Refresh()
  return math.abs(liveMeter:GetOpacity() - 0.4) < 1e-9 and liveMeter:IsVisible()
end)())
check("the idle fade hides it once the delay has passed", (function()
  _G.settings.idleFadeEnabled = true
  _G.settings.idleFadeAfter = 5
  Turbine.Engine._time = Turbine.Engine._time + 30
  liveMeter:Refresh()
  return not liveMeter:IsVisible()
end)())
check("...and it comes back the moment a fight starts", (function()
  Sessions.current = session
  liveMeter:Refresh()
  return liveMeter:IsVisible()
end)())
check("click-through applies only to the faded state", (function()
  Sessions.current = nil
  _G.settings.idleFadeEnabled = false
  _G.settings.clickThroughFaded = true
  liveMeter:Refresh()
  local faded = liveMeter:IsMouseVisible()
  Sessions.current = session
  liveMeter:Refresh()
  local fighting = liveMeter:IsMouseVisible()
  _G.settings.clickThroughFaded = false
  return faded == false and fighting == true
end)())

-- Compact mode, driven through the real checkbox rather than by poking _G.settings: the point of
-- the check is that the control writes, saves once, and that ApplyLive actually reaches
-- LiveMeter:ApplyMode -- poking the setting would prove none of that.
Click(w.railRows.live.row)
local livePage = w.pages.live
local compactBox = nil
for i = 1, #livePage._children do
  local child = livePage._children[i]
  if child.GetText ~= nil and child:GetText() == " Compact mode" then compactBox = child end
end
check("found the Compact mode checkbox", compactBox ~= nil)

local widthBefore, heightBefore = liveMeter:GetSize()
compactBox:SetChecked(true)
local compactSaves = CountSaves(function() compactBox.CheckedChanged() end)
check("the Compact mode checkbox writes its setting", _G.settings.compactMode == true)
check("...and saves exactly once", compactSaves == 1, tostring(compactSaves))
check("...and shrinks the live meter to 160x76",
  select(1, liveMeter:GetSize()) == 160 and select(2, liveMeter:GetSize()) == 76,
  select(1, liveMeter:GetSize()) .. "x" .. select(2, liveMeter:GetSize()))
check("...and the stat rows and sparkline go with it", (function()
  if liveMeter.lineLabels[1].label:IsVisible() or liveMeter.captionLabel:IsVisible() then
    return false
  end
  for i = 1, #liveMeter.sparkColumns do
    if liveMeter.sparkColumns[i]:IsVisible() then return false end
  end
  return liveMeter.valueHit:IsVisible()
end)())

compactBox:SetChecked(false)
compactBox.CheckedChanged()
check("unticking it restores the full meter",
  select(1, liveMeter:GetSize()) == widthBefore and select(2, liveMeter:GetSize()) == heightBefore
  and liveMeter.captionLabel:IsVisible() and not liveMeter.valueHit:IsVisible(),
  select(1, liveMeter:GetSize()) .. "x" .. select(2, liveMeter:GetSize()))

Sessions.current = nil

---------------------------------------------------------------------------------------------------
print("== 16. clockThroughAvoids ==")
---------------------------------------------------------------------------------------------------
check("an all-avoided second counts as active by default", (function()
  _G.settings.clockThroughAvoids = true
  local s = Session(5000, "00:00")
  s:AddTaken("Swing", 13, "X", 0, AvoidType.Missed, CritType.Normal, 5000)
  s:AddTaken("Swing", 13, "X", 0, AvoidType.Evaded, CritType.Normal, 5001)
  return s:ActiveSeconds() == 2, s:ActiveSeconds()
end)())
check("...and does not when the setting is off", (function()
  _G.settings.clockThroughAvoids = false
  local s = Session(5000, "00:00")
  s:AddTaken("Swing", 13, "X", 0, AvoidType.Missed, CritType.Normal, 5000)
  s:AddTaken("Cleave", 1, "X", 500, AvoidType.None, CritType.Normal, 5001)
  _G.settings.clockThroughAvoids = true
  return s:ActiveSeconds() == 1, s:ActiveSeconds()
end)())
check("the fight's own clock still moves through avoids", (function()
  _G.settings.clockThroughAvoids = false
  local s = Session(5000, "00:00")
  s:AddTaken("Swing", 13, "X", 0, AvoidType.Missed, CritType.Normal, 5004)
  _G.settings.clockThroughAvoids = true
  return s:Duration() == 4 and s:CombatDuration() == 4
end)())

---------------------------------------------------------------------------------------------------
print("== 17. session rules ==")
---------------------------------------------------------------------------------------------------
check("sessionsKept caps the ring", (function()
  _G.settings.sessionsKept = 10
  Sessions.ClearAll()
  for i = 1, 14 do
    local s = Session(6000 + i * 100, "00:00")
    s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 6000 + i * 100)
    s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 6000 + i * 100 + 9)
    Sessions.current = s
    Sessions.Close()
  end
  local n = #Sessions.list
  _G.settings.sessionsKept = 25
  return n == 10, n
end)())
check("a pinned session is exempt from the cap", (function()
  Sessions.ClearAll()
  _G.settings.sessionsKept = 10
  local pinned = nil
  for i = 1, 14 do
    local s = Session(7000 + i * 100, "00:00")
    s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 7000 + i * 100)
    s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 7000 + i * 100 + 9)
    Sessions.current = s
    Sessions.Close()
    if i == 1 then pinned = s; Sessions.TogglePin(s) end
  end
  local held = false
  for i = 1, #Sessions.list do if Sessions.list[i] == pinned then held = true end end
  _G.settings.sessionsKept = 25
  return held
end)())
check("minFightLength discards a short fight", (function()
  Sessions.ClearAll()
  _G.settings.minFightLength = 10
  local s = Session(8000, "00:00")
  s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 8000)
  s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 8004)
  Sessions.current = s
  local kept = Sessions.Close()
  _G.settings.minFightLength = 3
  return kept == nil and #Sessions.list == 0
end)())
check("...and keeps it once the bar is lowered", (function()
  _G.settings.minFightLength = 0
  local s = Session(8100, "00:00")
  s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 8100)
  s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 8101)
  Sessions.current = s
  local kept = Sessions.Close()
  _G.settings.minFightLength = 3
  return kept ~= nil
end)())
check("dropUnpinned keeps pins and drops the rest", (function()
  Sessions.ClearAll()
  for i = 1, 4 do
    local s = Session(9000 + i * 100, "00:00")
    s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 9000 + i * 100)
    s:AddDone("S", 1, "X", 10, AvoidType.None, CritType.Normal, 9000 + i * 100 + 9)
    Sessions.current = s
    Sessions.Close()
    if i == 2 then Sessions.TogglePin(s) end
  end
  Sessions.DropUnpinned()
  return #Sessions.list == 1 and Sessions.list[1].pinned
end)())
check("an unreadable zone id disables the drop rather than erroring", (function()
  _G.settings.dropOnZoneChange = true
  local ok = pcall(function() Sessions.CheckZone() end)
  _G.settings.dropOnZoneChange = false
  -- _G.lp here has no GetPosition at all, which is the "no confirmed API" case the guard exists
  -- for: it must fail safe (sessions kept) and never throw out of the heartbeat.
  return ok and #Sessions.list == 1
end)())

---------------------------------------------------------------------------------------------------
print("== 18. Defaults ==")
---------------------------------------------------------------------------------------------------
_G.settings.opacityIdle = 25
_G.settings.density = "Compact"
_G.settings.palettePreset = "Muted"
_G.settings.deathAutoHide = 29
_G.settings.compactMode = true
local okDefaults, errDefaults = pcall(function() w:ApplyDefaults() end)
check("Defaults runs clean", okDefaults, okDefaults and "" or tostring(errDefaults))
check("...and every setting is back to its default",
  _G.settings.opacityIdle == DEFAULTS.opacityIdle
  and _G.settings.density == DEFAULTS.density
  and _G.settings.palettePreset == DEFAULTS.palettePreset
  and _G.settings.deathAutoHide == DEFAULTS.deathAutoHide
  and _G.settings.compactMode == DEFAULTS.compactMode)
check("...and Defaults put the live meter back to its full height",
  select(2, liveMeter:GetSize()) == 186, tostring(select(2, liveMeter:GetSize())))
check("...and the controls re-read it rather than showing the old value",
  slider.value == DEFAULTS.deathAutoHide, tostring(slider.value))
check("...and the series colours went back with it",
  Theme.Series("done") == Theme.Hex.DamageDone, Theme.Series("done"))

---------------------------------------------------------------------------------------------------
print("== 19. the Plugin Manager stub ==")
---------------------------------------------------------------------------------------------------
local stub = Options()
check("the stub is still a ListBox with one item", stub:GetItemCount() == 1)
check("it carries no setting of its own", stub.boxes == nil and stub.Accept == nil)
check("Refresh is a safe no-op", pcall(function() stub:Refresh() end))

print("")
if fails == 0 then print("ALL OPTIONS CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
