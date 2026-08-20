-- Shared offline harness support: a Turbine stub built on the repo's OWN class() shim (so
-- `class(Turbine.UI.Control)` in the real source works unchanged), plus an `import` that loads
-- files straight out of the working tree.
--
-- Runs under REAL Lua 5.1 -- the game's own version -- so unlike the original Phase 1 harness
-- there are no getfenv/setfenv/table.getn shims papering over a newer interpreter.
--
-- The stub asserts on non-numeric or negative SetSize/SetPosition arguments, and records
-- position/size/visibility/colour per instance, so a probe can check real layout arithmetic.

local ROOT = os.getenv("RECK_ROOT") or "/home/user/Reckoning"

local loaded = {}
_G.import = function(path)
	if loaded[path] then return end
	loaded[path] = true
	local rel = path:gsub("^Reckoning%.", ""):gsub("%.", "/")
	local file = ROOT .. "/" .. rel .. ".lua"
	local f = io.open(file, "r")
	if f == nil then
		file = ROOT .. "/" .. rel .. "/__init__.lua"
		f = io.open(file, "r")
		if f == nil then error("import: no such file for " .. path) end
	end
	f:close()
	assert(loadfile(file))()
end

_G.plugin = {}

-- The OOP shim has to exist before any Turbine class is declared with it.
import "Reckoning.Utils.Type"
import "Reckoning.Utils.Class"

------------------------------------------------------------------ Turbine.UI.Control
local Control = class()

function Control:Constructor()
	self._x, self._y, self._w, self._h = 0, 0, 0, 0
	self._visible = true
	self._mouse = false
	self._z = 0
	self._children = {}
	self._items = {}
end

local function num(v, what)
	assert(type(v) == "number", what .. " needs a number, got " .. type(v) .. " (" .. tostring(v) .. ")")
	assert(v == v, what .. " got NaN")
	return v
end

function Control:SetPosition(x, y)
	self._x, self._y = num(x, "SetPosition x"), num(y, "SetPosition y")
end
function Control:GetPosition() return self._x or 0, self._y or 0 end
function Control:SetSize(w, h)
	num(w, "SetSize w"); num(h, "SetSize h")
	assert(w >= 0 and h >= 0, "SetSize must be non-negative, got " .. w .. "x" .. h)
	self._w, self._h = w, h
end
function Control:GetSize() return self._w or 0, self._h or 0 end
function Control:SetWidth(w) self._w = num(w, "SetWidth") end
function Control:SetHeight(h) self._h = num(h, "SetHeight") end
function Control:GetWidth() return self._w or 0 end
function Control:GetHeight() return self._h or 0 end
function Control:SetVisible(v) self._visible = (v and true or false) end
function Control:IsVisible() return self._visible and true or false end
function Control:SetMouseVisible(v) self._mouse = v end
function Control:IsMouseVisible() return self._mouse end
function Control:SetBackColor(c) self._back = c end
function Control:GetBackColor() return self._back end
function Control:SetForeColor(c) self._fore = c end
function Control:GetForeColor() return self._fore end
function Control:SetZOrder(z) self._z = num(z, "SetZOrder") end
function Control:GetZOrder() return self._z or 0 end
function Control:SetParent(p)
	self._parent = p
	if p ~= nil and p._children ~= nil then p._children[#p._children + 1] = self end
end
function Control:GetParent() return self._parent end
function Control:SetText(t) self._text = t end
function Control:GetText() return self._text or "" end
function Control:SetFont(f) self._font = f end
function Control:SetTextAlignment(a) self._align = a end
function Control:SetWantsUpdates(v) self._updates = v end
function Control:SetBackground(b) self._bg = b end
function Control:SetBlendMode(b) self._blend = b end
function Control:SetStretchMode(m) self._stretch = m end
function Control:SetOpacity(o) error("SetOpacity does not blend in this engine -- use Theme.Mix") end
function Control:Activate() self._activated = true end
function Control:AddItem(x) self._items[#self._items + 1] = x end
function Control:ClearItems() self._items = {} end
function Control:GetItemCount() return #self._items end
function Control:SetVerticalScrollBar(b) self._vsb = b end
function Control:SetOrientation(o) self._orient = o end
function Control:SetChecked(v) self._checked = v end
function Control:IsChecked() return self._checked end
function Control:SetClipMode(m) self._clip = m end
function Control:SetMultiline(v) self._multiline = v end

local Window = class(Control)
function Window:Constructor() Control.Constructor(self) end
function Window:Close() self:SetVisible(false) end

local Label = class(Control)
function Label:Constructor() Control.Constructor(self) end

local ListBox = class(Control)
function ListBox:Constructor() Control.Constructor(self) end

Turbine = {
	UI = {
		Control = Control,
		Window = Window,
		Label = Label,
		ListBox = ListBox,
		TextBox = Control,
		Color = function(r, g, b, a) return { R = r, G = g, B = b, A = a } end,
		ContentAlignment = {
			TopLeft = 1, TopCenter = 2, TopRight = 3,
			MiddleLeft = 4, MiddleCenter = 5, MiddleRight = 6,
			BottomLeft = 7, BottomCenter = 8, BottomRight = 9,
		},
		MouseButton = { Left = 1, Right = 2, Middle = 3 },
		Orientation = { Horizontal = 1, Vertical = 2 },
		BlendMode = { Overlay = 5, AlphaBlend = 1 },
		Lotro = {
			Font = {
				Verdana10 = "Verdana10", Verdana12 = "Verdana12", Verdana20 = "Verdana20",
				Verdana22 = "Verdana22", TrajanPro13 = "TrajanPro13",
				TrajanPro16 = "TrajanPro16", LucidaConsole12 = "LucidaConsole12",
			},
			ScrollBar = Control, TextBox = Control, CheckBox = Control, Button = Control,
			Window = nil, -- deliberately absent: docs/DESIGN.md forbids it, nothing may use it
		},
	},
	Chat = {},
	ChatType = { PlayerCombat = 1, EnemyCombat = 2, Death = 3, Say = 4 },
	Engine = {
		_time = 0,
		GetGameTime = function() return Turbine.Engine._time end,
		GetDate = function() return { Hour = 0, Minute = 0 } end,
	},
	Shell = {
		WriteLine = function(...) print(...) end,
		AddCommand = function() end, RemoveCommand = function() end,
	},
	ShellCommand = function() return {} end,
	PluginData = { Load = function() return nil end, Save = function() end },
	DataScope = { Character = 1 },
	Gameplay = {},
}

return { ROOT = ROOT, Control = Control }
