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
-- SetOpacity used to be banned outright here, which encoded the lesson slightly too broadly. The
-- real rule (CLAUDE.md, the long note): it does NOT blend over a Control that already has a solid
-- BackColor -- it draws the BackColor at full strength and the opacity is ignored. A whole-window
-- fade on a Window with no BackColor of its own is the one case it IS confirmed to work
-- (VitalSelf's incombat/outcombat fade; CombatAnalysis's invisible quickslot host, which is what
-- UI/PostButton.lua fades its quickslot with). So the guard checks that condition, not the call.
function Control:SetOpacity(o)
	assert(self._back == nil,
		"SetOpacity on a Control with a solid BackColor does not blend in this engine -- use Theme.Mix")
	self._opacity = o
end
function Control:GetOpacity() return self._opacity end
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
function Control:SetMarkupEnabled(v) self._markup = v end
function Control:SetWantsKeyEvents(v) self._keyEvents = v end

local Window = class(Control)
function Window:Constructor() Control.Constructor(self) end
function Window:Close() self:SetVisible(false) end

local Label = class(Control)
function Label:Constructor() Control.Constructor(self) end

local ListBox = class(Control)
function ListBox:Constructor() Control.Constructor(self) end

-- Chat-posting types (UI/PostButton.lua). None of these existed before -- nothing in this
-- codebase had touched a Quickslot, a Shortcut or a ContextMenu.
local Quickslot = class(Control)
function Quickslot:Constructor() Control.Constructor(self) end
function Quickslot:SetShortcut(s) self._shortcut = s end
function Quickslot:GetShortcut() return self._shortcut end

local Shortcut = class()
function Shortcut:Constructor(shortcutType, data)
	self._type, self._data = shortcutType, data
end
function Shortcut:SetData(d) self._data = d end
function Shortcut:GetData() return self._data end

-- MenuItem(text, enabled, checked) -- the three-argument form CombatAnalysis uses.
local MenuItem = class()
function MenuItem:Constructor(text, enabled, checked)
	self._text, self._enabled, self._checked = text, enabled, checked
end
function MenuItem:GetText() return self._text end
function MenuItem:IsEnabled() return self._enabled end
function MenuItem:SetChecked(v) self._checked = v end
function MenuItem:IsChecked() return self._checked end

local ItemList = class()
function ItemList:Constructor() self._list = {} end
function ItemList:Add(item) self._list[#self._list + 1] = item end
function ItemList:GetCount() return #self._list end
function ItemList:Get(i) return self._list[i] end
function ItemList:RemoveAt(i) table.remove(self._list, i) end

local ContextMenu = class()
function ContextMenu:Constructor() self._items = ItemList() end
function ContextMenu:GetItems() return self._items end
function ContextMenu:ShowMenu() self._shown = true end

Turbine = {
	UI = {
		Control = Control,
		Window = Window,
		Label = Label,
		ListBox = ListBox,
		TextBox = Control,
		ContextMenu = ContextMenu,
		MenuItem = MenuItem,
		Color = function(r, g, b, a) return { R = r, G = g, B = b, A = a } end,
		-- A 1920x1080 screen, so Analysis's MaxHeight() (which reads GetHeight through a pcall)
		-- has something real to clamp against instead of falling back to its old constant.
		Display = {
			GetWidth = function() return 1920 end,
			GetHeight = function() return 1080 end,
			GetSize = function() return 1920, 1080 end,
		},
		ContentAlignment = {
			TopLeft = 1, TopCenter = 2, TopRight = 3,
			MiddleLeft = 4, MiddleCenter = 5, MiddleRight = 6,
			BottomLeft = 7, BottomCenter = 8, BottomRight = 9,
		},
		MouseButton = { Left = 1, Right = 2, Middle = 3 },
		Orientation = { Horizontal = 1, Vertical = 2 },
		BlendMode = { Overlay = 5, AlphaBlend = 1 },
		Lotro = {
			Action = { Escape = "Escape" },
			Font = {
				Verdana10 = "Verdana10", Verdana12 = "Verdana12", Verdana20 = "Verdana20",
				Verdana22 = "Verdana22", TrajanPro13 = "TrajanPro13",
				TrajanPro16 = "TrajanPro16", LucidaConsole12 = "LucidaConsole12",
			},
			ScrollBar = Control, TextBox = Control, CheckBox = Control, Button = Control,
			Quickslot = Quickslot,
			Shortcut = Shortcut,
			ShortcutType = { Alias = 6, Skill = 1, Item = 2 },
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
