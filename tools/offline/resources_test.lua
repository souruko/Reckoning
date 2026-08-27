-- Every "<Package>/Resources/<file>" string the source hands to SetBackground has to resolve to a
-- real file, under a prefix that matches this plugin's own package name.
--
-- This check exists because that pair came apart for real and cost an in-game load. The plugin was
-- renamed Reckoning -> Basil; the Lua was updated to say "Basil/Resources/..." while the installed
-- folder was still named `Reckoning`, so EVERY image in the plugin silently failed to load. Nothing
-- throws -- `SetBackground` on a path the client cannot resolve only writes
--
--     ...\Plugins\Reckoning\UI\AnalysisGraph.lua:1028: Failed to load background image.
--
-- to Script.log, which the game never surfaces in chat. The visible symptom was the analysis
-- window's line graph drawing wrong (its stroke sprites are what a segment rotates), which reads
-- as a graph bug rather than a missing file, and every other icon in the plugin was gone too.
--
-- The prefix is derived from the .plugin file's own <Package>, not hardcoded, so a future rename
-- only has to touch the two places it already has to (the .plugin and the paths) and this catches
-- it if it touches only one.
local env = dofile("stub.lua"); local ROOT = env.ROOT

local fails = 0
local function check(label, ok, detail)
  if not ok then fails = fails + 1 end
  print(string.format("%-62s %s%s", label, ok and "OK" or "**FAIL**", detail and ("  " .. detail) or ""))
end

local function Slurp(path)
  local f = io.open(path, "r")
  if f == nil then return nil end
  local body = f:read("*a")
  f:close()
  return body
end

local function Exists(path)
  local f = io.open(path, "rb")
  if f == nil then return false end
  f:close()
  return true
end

-- Every .lua in the tree, tools/ included: tools/icons/build_icons.py writes the sprites the graph
-- names, so the list there has to agree too (checked separately below).
--
-- The find runs FROM the root and matches relative paths. Matching absolute ones would exclude
-- everything whenever the root itself sits under a pruned directory -- which it does when this runs
-- inside a `.claude/worktrees/` checkout, and the whole scan then passes by finding nothing.
local function LuaFiles()
  local out = {}
  local pipe = io.popen("cd '" .. ROOT .. "' && find . -name '*.lua' -not -path './.git/*' -not -path './.claude/*'")
  for line in pipe:lines() do out[#out + 1] = (line:gsub("^%./", "")) end
  pipe:close()
  table.sort(out)
  return out
end

---------------------------------------------------------------------------------------------------
-- 1. The package name, from the one place the client reads it
---------------------------------------------------------------------------------------------------

local pluginFiles = {}
local pipe = io.popen("find '" .. ROOT .. "' -maxdepth 1 -name '*.plugin'")
for line in pipe:lines() do pluginFiles[#pluginFiles + 1] = line end
pipe:close()

check("exactly one .plugin manifest", #pluginFiles == 1, tostring(#pluginFiles))
local manifest = Slurp(pluginFiles[1] or "") or ""
local package = manifest:match("<Package>([%w_]+)%.")
check("the manifest names a package", package ~= nil, tostring(package))

-- The manifest's own <Name> and the .plugincompendium have to agree with it, since the installed
-- folder is what the client resolves "<prefix>/Resources/..." against.
local name = manifest:match("<Name>([^<]+)</Name>")
check("manifest <Name> matches its <Package> root", name == package,
  tostring(name) .. " vs " .. tostring(package))
check("the .plugin file is named after the package",
  (pluginFiles[1] or ""):match("([^/]+)%.plugin$") == package)
check("a matching .plugincompendium sits beside it",
  Exists(ROOT .. "/" .. tostring(package) .. ".plugincompendium"))

---------------------------------------------------------------------------------------------------
-- 2. Every resource path in the source resolves, under that prefix
---------------------------------------------------------------------------------------------------

local seen, paths = {}, {}
local wrongPrefix, missing = {}, {}

for _, file in ipairs(LuaFiles()) do
  local body = Slurp(ROOT .. "/" .. file) or ""
  -- Any quoted "<something>/Resources/<something>.tga" literal, whatever it is passed to. Anchored
  -- on the extension so prose in a comment cannot look like a path.
  for literal in body:gmatch('"([%w_]+/Resources/[%w_%-]+%.tga)"') do
    if not seen[literal] then
      seen[literal] = true
      paths[#paths + 1] = literal
      local prefix, rest = literal:match("^([%w_]+)/(.+)$")
      if prefix ~= package then
        wrongPrefix[#wrongPrefix + 1] = literal .. " (in " .. file .. ")"
      elseif not Exists(ROOT .. "/" .. rest) then
        missing[#missing + 1] = literal
      end
    end
  end
end

check("the source references resources at all", #paths > 0, #paths .. " distinct paths")
check("every resource path uses the plugin's own package prefix", #wrongPrefix == 0,
  wrongPrefix[1])
check("every referenced resource file exists on disk", #missing == 0,
  missing[1] and (#missing .. " missing, first: " .. missing[1]))

---------------------------------------------------------------------------------------------------
-- 3. The stroke ladder specifically: the graph picks a rung by segment length, so a rung that is
--    named but not built would draw the wrong stroke only at some angles -- the hardest kind of
--    graph bug to attribute. build_icons.py is the generator and has to list the same set.
---------------------------------------------------------------------------------------------------

local graphSource = Slurp(ROOT .. "/UI/AnalysisGraph.lua") or ""
local rungs = {}
for band, file in graphSource:gmatch(
    'band%s*=%s*([%d%.]+)%s*,%s*image%s*=%s*"' .. tostring(package) .. '/Resources/(stroke_[%w_]+)%.tga"') do
  rungs[#rungs + 1] = { band = tonumber(band), file = file }
end
check("the stroke ladder has rungs", #rungs >= 2, #rungs .. " rungs")

-- The generator names each rung after its own band times ten (`stroke_15` is the 1.5px band), so
-- the filename is not an independent fact -- it is derived. Checking the derivation both ways is
-- what makes a mismatched pair impossible: a rung renamed in one file and not the other would draw
-- the wrong stroke width only at the segment lengths that select it.
local misnamed = {}
for _, rung in ipairs(rungs) do
  local expected = string.format("stroke_%d", math.floor(rung.band * 10 + 0.5))
  if rung.file ~= expected then
    misnamed[#misnamed + 1] = rung.file .. " carries band " .. rung.band .. " (expected " .. expected .. ")"
  end
end
check("every rung's filename matches its own band", #misnamed == 0, misnamed[1])

-- build_icons.py's band tuple is the generator's authority; STROKE_SPRITES must be the same set.
local builder = Slurp(ROOT .. "/tools/icons/build_icons.py") or ""
local builtList = builder:match("for%s+_band%s+in%s+%(([^%)]+)%)")
check("build_icons.py declares a band list", builtList ~= nil)

local built, wanted = {}, {}
for band in tostring(builtList):gmatch("[%d%.]+") do built[tonumber(band)] = true end
for _, rung in ipairs(rungs) do wanted[rung.band] = true end

local unbuilt, unused = {}, {}
for band in pairs(wanted) do
  if not built[band] then unbuilt[#unbuilt + 1] = band end
end
for band in pairs(built) do
  if not wanted[band] then unused[#unused + 1] = band end
end
check("build_icons.py builds every rung the graph names", #unbuilt == 0, unbuilt[1])
check("build_icons.py builds no rung the graph does not name", #unused == 0, unused[1])

-- A stroke sprite is stretched from its own native size, and STROKE_NATIVE is what DrawSegment
-- passes to the first SetSize of the scale sequence. A sprite that is not actually that size would
-- scale to the wrong stroke width -- silently, since nothing throws.
local native = tonumber(graphSource:match("STROKE_NATIVE%s*=%s*(%d+)"))
check("STROKE_NATIVE is declared", native ~= nil, tostring(native))
local wrongSize = {}
for _, rung in ipairs(rungs) do
  local f = io.open(ROOT .. "/Resources/" .. rung.file .. ".tga", "rb")
  if f ~= nil then
    local header = f:read(18)
    f:close()
    -- TGA header: width at bytes 13-14, height at 15-16, both little-endian.
    local w = header:byte(13) + header:byte(14) * 256
    local h = header:byte(15) + header:byte(16) * 256
    if w ~= native or h ~= native then
      wrongSize[#wrongSize + 1] = rung.file .. " is " .. w .. "x" .. h
    end
  end
end
check("every stroke sprite is STROKE_NATIVE square", #wrongSize == 0, wrongSize[1])

print("")
if fails == 0 then print("ALL RESOURCE CHECKS PASSED") else print(fails .. " CHECK(S) FAILED"); os.exit(1) end
