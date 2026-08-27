-- Runs the REAL Graph class (constructor -> SetSeries -> SetData -> SetLanes -> SetRange) against
-- a real Session built from the repo's reference logs, on a Turbine stub that asserts on
-- non-numeric / negative SetSize args. Checks geometry invariants rather than pixels.
local env = dofile("stub.lua"); local ROOT = env.ROOT
import "Reckoning.Utils.Type"; import "Reckoning.Utils.Class"; import "Reckoning.Constants"
Trigger = {}; import "Reckoning.Parse.en"; import "Reckoning.Settings"
_G.lp = { GetName=function() return "Luxtheninth" end, GetMorale=function() return 5e5 end,
  GetMaxMorale=function() return 9e5 end, GetTarget=function() return nil end,
  IsInCombat=function() return true end }  -- heals only count in combat, see Sessions.lua
LocalPlayer = _G.lp; LocalPlayer.name = LocalPlayer:GetName()
Settings.Load()
import "Reckoning.Session"; import "Reckoning.Sessions"; import "Reckoning.Events"
import "Reckoning.UI.RangeSlider"; import "Reckoning.UI.AnalysisGraph"

local clock = 1000
local function Feed(path, ct)
  for line in io.lines(path) do
    if line ~= "" and not line:match("^###") then
      clock = clock + 0.37; Turbine.Engine._time = clock
      Turbine.Chat.Received(nil, { ChatType = ct, Message = line })
    end
  end
end
Turbine.Engine._time = clock
Feed(ROOT .. "/reference/Combat_20260819_1.txt", Turbine.ChatType.PlayerCombat)
Feed(ROOT .. "/reference/Enemy_20260819_1.txt", Turbine.ChatType.EnemyCombat)
local session = Sessions.current

local fails = 0
local function check(label, ok, detail)
  if not ok then fails = fails + 1 end
  print(string.format("%-58s %s%s", label, ok and "OK" or "**FAIL**", detail and ("  " .. detail) or ""))
end

local PLOT = 150
local W = 848
local g = Graph(W)
check("constructor: block height matches GraphHeightFor(0)",
  select(2, g:GetSize()) == GraphHeightFor(0), "h=" .. select(2, g:GetSize()))

g:SetSeriesWithMorale({
  { key = "taken", label = "Damage taken", colorHex = Theme.Hex.DamageTaken },
  { key = "healIn", label = "Healing in", colorHex = Theme.Hex.HealingTaken },
}, true)
g:SetData(session, true, nil)

-- 0. A segment is drawn HIDDEN and revealed only by the rotation pass. Between being sized (which
-- clears its rotation) and being rotated it would paint FLAT, which in-game read as the whole line
-- snapping to a horizontal bar on every redraw -- so this is the check that keeps it hidden.
local drawnEarly, rotatedEarly = 0, 0
for slot = 1, 2 do
  for i = 1, GraphBucketCount() - 1 do
    if g.seg[slot][i]:IsVisible() then drawnEarly = drawnEarly + 1 end
    if g.seg[slot][i]:GetRotation() ~= nil then rotatedEarly = rotatedEarly + 1 end
  end
end
check("plot: no segment is visible before it has been rotated", drawnEarly == 0,
  drawnEarly .. " shown flat")
check("plot: no segment is rotated in the same pass that sized it", rotatedEarly == 0,
  rotatedEarly .. " early")
check("plot: the rotation pass is still pending", g:FlushRotation())
check("plot: the pass completes on the next call", not g:FlushRotation())
check("plot: the pass does not re-arm itself", not g:FlushRotation())

-- Everything below reads what is on screen, so it runs after that pass. Settle() is the harness's
-- stand-in for Analysis:Update, and every later SetData/ToggleSeries needs one too.
local function Settle()
  while g:FlushRotation() do end
end

-- 1. every visible segment/dot stays inside the plot. A segment is a SQUARE the length of the
-- step it draws, centred on that step's midpoint, so its own rect is much larger than the stroke
-- it shows -- what has to stay inside the plot is the DRAWN LINE, i.e. the two endpoints, not the
-- square. (The squares overlap each other heavily by design; the sprite is transparent outside
-- its band.)
local N = GraphBucketCount()
local outside, visibleSegs, visibleDots = 0, 0, 0
for slot = 1, 2 do
  for i = 1, N - 1 do
    local seg = g.seg[slot][i]
    if seg:IsVisible() then
      visibleSegs = visibleSegs + 1
      local x, y = seg:GetPosition(); local side, h = seg:GetSize()
      if side ~= h then outside = outside + 1 end
      local rad = -math.rad(seg.rotation.z)
      local cx, cy = x + side / 2, y + side / 2
      local hx, hy = side / 2 * math.cos(rad), side / 2 * math.sin(rad)
      if math.min(cx - hx, cx + hx) < -1 or math.max(cx - hx, cx + hx) > W + 1
        or math.min(cy - hy, cy + hy) < -1 or math.max(cy - hy, cy + hy) > PLOT + 1 then
        outside = outside + 1
      end
    end
  end
  for i = 1, N do
    local d = g.dots[slot][i]
    if d:IsVisible() then
      visibleDots = visibleDots + 1
      local x, y = d:GetPosition(); local w, h = d:GetSize()
      if x < -2 or y < 0 or y + h > PLOT then outside = outside + 1 end
    end
  end
end
check("plot: no drawn segment or dot escapes the plot", outside == 0, "escapes=" .. outside)
check("plot: both series drew their segments", visibleSegs == 2 * (N - 1), "segs=" .. visibleSegs)
check("plot: dots on odd buckets only (+endpoints)", visibleDots > 0 and visibleDots <= 2 * N,
  "dots=" .. visibleDots)

-- 1b. THE joint check, and it is a different one now. The old L-step could leave a gap between a
-- riser and the next run; a rotated segment instead has one way to go wrong, and it is total:
-- if the angle's sign is inverted every segment is drawn mirrored about its own midpoint -- right
-- length, right centre, both ends on the wrong side -- so consecutive segments stop meeting. That
-- shipped once (probe round 6). Reconstruct both endpoints from what was handed to the engine and
-- check they land on the two data points, which no mirrored segment can.
local maxErr = 0
-- ONE maxValue across every visible series, exactly as Graph:Redraw computes it -- a per-series
-- scale would put the two lines on different axes and this check would be measuring the wrong y.
local maxValue = 0
for slot = 1, 2 do
  local key = g.seriesList[slot].key
  for i = 1, N do
    local v = g.slices[i][key] or 0
    if v > maxValue then maxValue = v end
  end
end
for slot = 1, 2 do
  local key = g.seriesList[slot].key
  for i = 1, N - 1 do
    local seg = g.seg[slot][i]
    if seg:IsVisible() then
      local x, y = seg:GetPosition(); local side = seg:GetSize()
      local rad = -math.rad(seg.rotation.z)
      local cx, cy = x + side / 2, y + side / 2
      local hx, hy = side / 2 * math.cos(rad), side / 2 * math.sin(rad)
      local x0, y0 = g:BucketX(i), g:ValueY(g.slices[i][key] or 0, maxValue)
      local x1, y1 = g:BucketX(i + 1), g:ValueY(g.slices[i + 1][key] or 0, maxValue)
      maxErr = math.max(maxErr,
        math.abs(cx - hx - x0), math.abs(cy - hy - y0),
        math.abs(cx + hx - x1), math.abs(cy + hy - y1))
    end
  end
end
check("plot: every segment's two ends land on its two data points", maxErr <= 1.5,
  string.format("worst %.2fpx", maxErr))

-- 1b-ii. The stroke ladder. The control is sized to the segment's own length and the sprite's band
-- is a FRACTION of the sprite, so a single sprite draws a stroke proportional to length -- about
-- 1px across a flat second and 6px up a steep spike, which is what the first version shipped and
-- what it was reported for. DrawSegment picks the rung nearest 2px instead; this checks the result
-- across every segment the real data produces, not just in principle.
local BANDS = { 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0 }
local thinnest, thickest = 99, 0
for slot = 1, 2 do
  for i = 1, N - 1 do
    local seg = g.seg[slot][i]
    if seg:IsVisible() then
      local side = seg:GetSize()
      local band = tonumber(seg:GetBackground():match("stroke_(%d+)%.tga")) / 10
      local drawn = band * side / 64
      thinnest = math.min(thinnest, drawn)
      thickest = math.max(thickest, drawn)
      -- the chosen rung must be the best available one, not merely a plausible one
      local bestErr = 99
      for _, b in ipairs(BANDS) do bestErr = math.min(bestErr, math.abs(b * side / 64 - 2)) end
      if math.abs(drawn - 2) > bestErr + 1e-9 then thinnest = -1 end
    end
  end
end
check("plot: every segment picks the best rung of the stroke ladder", thinnest >= 0)
check("plot: drawn stroke stays near 2px at every segment length",
  thinnest >= 1.5 and thickest <= 2.5,
  string.format("%.2f..%.2fpx", thinnest, thickest))

-- 1b-iii. An unchanged redraw must not disturb anything. Because a redrawn segment goes hidden
-- until the rotation pass catches up, re-specifying one that has not moved would blink it -- and
-- dragging the range slider redraws on every bucket it crosses without moving the series at all.
g:SetData(session, true, nil)
local blinked = 0
for slot = 1, 2 do
  for i = 1, N - 1 do
    if not g.seg[slot][i]:IsVisible() then blinked = blinked + 1 end
  end
end
check("plot: a redraw that changes nothing leaves every segment on screen", blinked == 0,
  blinked .. " blinked")

-- 1c. Every segment that IS on screen carries its rotation -- the other half of the check above.
local unrotated = 0
for slot = 1, 2 do
  for i = 1, N - 1 do
    if g.seg[slot][i]:IsVisible() and g.seg[slot][i]:GetRotation() == nil then
      unrotated = unrotated + 1
    end
  end
end
check("plot: every visible segment carries its rotation", unrotated == 0, unrotated .. " unrotated")

-- 2. morale bars fill the plot, never overflow, never fall below 1px
local barsVisible, barBad = 0, 0
for i = 1, N do
  local b = g.moraleBars[i]
  if b:IsVisible() then
    barsVisible = barsVisible + 1
    local x, y = b:GetPosition(); local w, h = b:GetSize()
    if h < 1 or y < 0 or y + h > PLOT - 1 or x < 0 or x + w > W then barBad = barBad + 1 end
    local ex, ey = g.moraleEdges[i]:GetPosition()
    if ey ~= y then barBad = barBad + 1 end
  end
end
check("morale: every bucket carries a bar (carry-forward works)", barsVisible == N,
  "bars=" .. barsVisible .. "/" .. N)
check("morale: no bar overflows the plot, edges sit on top", barBad == 0, "bad=" .. barBad)
-- "MORALE 500,000" with settings.abbreviateNumbers off, "MORALE 500.0k" with it on (the
-- default) -- Format.Number gained that branch with the options panel.
check("morale: axis label shows peak in points",
  g.moraleAxisLabel:GetText():match("^MORALE [%d,%.]+k?m?$") ~= nil,
  g.moraleAxisLabel:GetText())

-- 3. views without morale hide the whole morale apparatus
g:SetSeriesWithMorale({ { key = "done", label = "Damage", colorHex = Theme.Hex.DamageDone } }, false)
g:SetData(session, false, nil)
Settle()
local anyBar = false
for i = 1, N do if g.moraleBars[i]:IsVisible() then anyBar = true end end
check("no-morale view: bars, guides and axis label all hidden",
  (not anyBar) and (not g.moraleGuideTop:IsVisible()) and (not g.moraleAxisLabel:IsVisible()))
check("no-morale view: second series slot fully hidden",
  not g.seg[2][1]:IsVisible() and not g.dots[2][1]:IsVisible())
check("no-morale view: peak/low readout is blank", g.peakLabel:GetText() == "")

-- 4. hiding a series via the legend hides both of its pools
g:SetSeriesWithMorale({
  { key = "taken", label = "Damage taken", colorHex = Theme.Hex.DamageTaken },
  { key = "healIn", label = "Healing in", colorHex = Theme.Hex.HealingTaken },
}, true)
g:SetData(session, true, nil)
g:ToggleSeries("healIn")
Settle()
local hidOk = true
for i = 1, N - 1 do
  if g.seg[2][i]:IsVisible() then hidOk = false end
end
for i = 1, N do if g.dots[2][i]:IsVisible() then hidOk = false end end
check("legend toggle hides both pools of that series", hidOk)
check("legend toggle leaves the other series drawn", g.seg[1][1]:IsVisible())
g:ToggleSeries("healIn")
Settle()

-- 5. range overlay + slider
g:SetRange(13, 36)
local dl_x, dl_y = g.dimLeft:GetPosition(); local dl_w = select(1, g.dimLeft:GetSize())
local dr_x = select(1, g.dimRight:GetPosition())
check("range: left wash starts at 0 and ends at handle A", dl_x == 0 and dl_w > 0)
check("range: right wash starts at handle B", dr_x > dl_w and dr_x < W)
check("range: both markers visible when scoped", g.markerA:IsVisible() and g.markerB:IsVisible())
check("range: peak/low readout is range-scoped", g.peakLabel:GetText():match("peak morale") ~= nil,
  g.peakLabel:GetText())
g:SetRange(1, N)
check("range: full fight hides both washes and markers",
  not g.dimLeft:IsVisible() and not g.dimRight:IsVisible() and not g.markerA:IsVisible())

-- slider clamping: handles can never cross
g.slider:DragTo("from", W)          -- shove A all the way right
check("slider: handle A clamps to (B - 1)", g.slider.rangeFrom == g.slider.rangeTo - 1,
  g.slider.rangeFrom .. ".." .. g.slider.rangeTo)
g.slider:DragTo("to", -500)         -- shove B all the way left
check("slider: handle B clamps to (A + 1)", g.slider.rangeTo == g.slider.rangeFrom + 1,
  g.slider.rangeFrom .. ".." .. g.slider.rangeTo)
g.slider:SetRange(1, N)
local hx = select(1, g.slider.handleB:GetPosition())
check("slider: last handle stays inside the track", hx + 9 <= W, "x=" .. hx)

-- 6. buff lanes change the block height and stay on their rails
check("lanes: height with 0 lanes", select(2, g:GetSize()) == GraphHeightFor(0))
g:SetLanes({
  { name = "Writ of Health", colorHex = Theme.BuffLane[1], initials = "WH",
    intervals = { {s=0,e=12}, {s=20,e=33}, {s=40,e=46} } },
  { name = "Bracing Guard", colorHex = Theme.BuffLane[2], initials = "BG",
    intervals = { {s=5,e=25} } },
})
check("lanes: height grows for 2 lanes", select(2, g:GetSize()) == GraphHeightFor(2),
  select(2, g:GetSize()) .. " vs " .. GraphHeightFor(2))
local segBad, segSeen = 0, 0
for i = 1, 2 do
  for k = 1, 24 do
    local s = g.lanes[i].segments[k]
    if s:IsVisible() then
      segSeen = segSeen + 1
      local x, y = s:GetPosition(); local w = select(1, s:GetSize())
      if x < 0 or x + w > g.laneRailWidth then segBad = segBad + 1 end
    end
  end
end
check("lanes: 4 interval segments drawn, all on the rail", segSeen == 4 and segBad == 0,
  "seen=" .. segSeen .. " bad=" .. segBad)
check("lanes: unused third lane hidden", not g.lanes[3].rail:IsVisible())
g:SetLanes({})
check("lanes: clearing returns to the 0-lane height", select(2, g:GetSize()) == GraphHeightFor(0))

-- 7. resize keeps everything consistent
g:SetLanes({ { name = "X", colorHex = Theme.BuffLane[1], initials = "X", intervals = { {s=1,e=9} } } })
g:Resize(1200)
check("resize: block resized to the new width", select(1, g:GetSize()) == 1200)
check("resize: plot ground followed", select(1, g.plotGround:GetSize()) == 1200)
check("resize: slider followed", g.slider.plotWidth == 1200)
check("resize: height still matches the lane count", select(2, g:GetSize()) == GraphHeightFor(1))

-- 8. tooltip
g:SetData(session, true, nil)
g:ShowTooltip(20)
check("tooltip: shows and fills its first line", g.tooltip.box:IsVisible()
  and g.tooltip.lines[1]:GetText() ~= "", g.tooltip.lines[1]:GetText())
local tx = select(1, g.tooltip.box:GetPosition())
check("tooltip: stays inside the plot", tx >= 0 and tx + 160 <= 1200, "x=" .. tx)
g:ShowTooltip(48)
local tx2 = select(1, g.tooltip.box:GetPosition())
check("tooltip: last bucket does not push it off the right edge", tx2 + 160 <= 1200, "x=" .. tx2)
g:HideTooltip()
check("tooltip: hides", not g.tooltip.box:IsVisible())

-- 8b. SliceSecondRange (SetData's own slice-index formula, inverted) partitions the whole
-- session contiguously and without overlap -- if these two formulas ever drift apart, a
-- bucket's tooltip would show skills from the wrong seconds.
do
  local prevTo = -1
  local partitionOk = true
  for i = 1, N do
    local from, to = g:SliceSecondRange(i)
    if from ~= prevTo + 1 or to < from then
      partitionOk = false
    end
    prevTo = to
  end
  check("skills: SliceSecondRange partitions seconds contiguously, no gaps/overlaps", partitionOk)
end

-- 8c. per-bucket skill breakdown backs the tooltip (the actual feature: hovering a bucket lists
-- which skills hit inside its second range)
g:SetSeriesWithMorale({
  { key = "taken", label = "Damage taken", colorHex = Theme.Hex.DamageTaken },
}, true)
g:SetData(session, true, nil)

local bucketWithHits, bucketNoHits = nil, nil
for i = 1, N do
  if (g.slices[i].taken or 0) > 0 and bucketWithHits == nil then
    bucketWithHits = i
  elseif (g.slices[i].taken or 0) == 0 and bucketNoHits == nil then
    bucketNoHits = i
  end
end
check("skills: found a bucket with damage taken to test against", bucketWithHits ~= nil)

if bucketWithHits ~= nil then
  local skills = g:SkillsAt(bucketWithHits)
  local sum = 0
  for i = 1, table.getn(skills) do sum = sum + skills[i].total end
  check("skills: SkillsAt total matches the bucket's own pooled value",
    math.abs(sum - g.slices[bucketWithHits].taken) < 1e-6,
    sum .. " vs " .. g.slices[bucketWithHits].taken)

  local allHits = true
  for i = 1, table.getn(skills) do
    if skills[i].hits <= 0 then allHits = false end
  end
  check("skills: every entry has at least one real hit (avoided-only rows dropped)", allHits)

  g:ShowTooltip(bucketWithHits)
  check("skills: tooltip shows at least one skill line", g.tooltip.skillLines[1]:IsVisible()
    and g.tooltip.skillLines[1]:GetText() ~= "")
  local _, hitHeight = g.tooltip.box:GetSize()

  if bucketNoHits ~= nil then
    g:ShowTooltip(bucketNoHits)
    check("skills: a quiet bucket shows no skill lines", not g.tooltip.skillLines[1]:IsVisible())
    local _, quietHeight = g.tooltip.box:GetSize()
    check("skills: tooltip box grows to fit the skill lines", hitHeight > quietHeight,
      hitHeight .. " vs " .. quietHeight)
  end

  -- filtered agrees with the filtered bucket value the same way the pooled case does
  local who = session:TopCounterpart("taken")
  g:SetData(session, true, who)
  local filteredSkills = g:SkillsAt(bucketWithHits)
  local filteredSum = 0
  for i = 1, table.getn(filteredSkills) do filteredSum = filteredSum + filteredSkills[i].total end
  check("skills: filtered SkillsAt matches the filtered bucket value",
    math.abs(filteredSum - (g.slices[bucketWithHits].taken or 0)) < 1e-6,
    filteredSum .. " vs " .. (g.slices[bucketWithHits].taken or 0))
  g:SetData(session, true, nil)
end

-- 9. filtered graph agrees with the session's own per-counterpart totals
local who = session:TopCounterpart("taken")
g:SetSeriesWithMorale({ { key = "taken", label = "Damage taken", colorHex = Theme.Hex.DamageTaken } }, true)
g:SetData(session, true, who)
local sliceSum = 0
for i = 1, N do sliceSum = sliceSum + (g.slices[i].taken or 0) end
check("filtered plot sums to Session:Total(cat, who)",
  math.abs(sliceSum - session:Total("taken", who)) < 1e-6,
  sliceSum .. " vs " .. session:Total("taken", who))
g:SetData(session, true, nil)
local pooled = 0
for i = 1, N do pooled = pooled + (g.slices[i].taken or 0) end
check("pooled plot sums to Session:Total(cat)",
  math.abs(pooled - session:Total("taken")) < 1e-6, pooled .. " vs " .. session:Total("taken"))

print("")
if fails == 0 then print("ALL GRAPH CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
