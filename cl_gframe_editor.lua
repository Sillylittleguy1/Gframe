-- cl_gframe_editor.lua
-- Drop into lua/autorun/client/
-- GFrame editor: nested frames, images, property inspector, save/load/export JSON
-- Author: ChatGPT (example implementation) --YES THIS IS INTENTIONAL, I DID NOT MAKE THE OG CODE
print("init started -gframe")
if SERVER then return end

local PANEL = {}
local EDITOR = {}
EDITOR.instances = {}

-- Utility functions
local function ensureDataPath(path)
    file.CreateDir("gframe_editor")
    if path and path:find("/") then
        local prefix = path:match("(.*/)")
        if prefix then file.CreateDir("gframe_editor/" .. prefix) end
    end
end

local function writeJSON(name, tbl)
    ensureDataPath("")
    local json = util.TableToJSON(tbl, true)
    file.Write("gframe_editor/" .. name .. ".json", json)
end

local function readJSON(name)
    if not file.Exists("gframe_editor/" .. name .. ".json", "DATA") then return nil end
    local raw = file.Read("gframe_editor/" .. name .. ".json", "DATA")
    local ok, tbl = pcall(util.JSONToTable, raw)
    if not ok then return nil end
    return tbl
end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k,v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- Simple material loader for image URLs or raw data saved to data/
-- For URLs we fetch and write into data/gframe_editor/images/
local function loadImageFromURL(url, callback)
    local name = url:gsub("[^%w]", "_")
    local path = "gframe_editor/images/" .. name
    local fullPath = "data/" .. path
    if file.Exists(path, "DATA") then
        callback(Material("../data/" .. path))
        return
    end

    http.Fetch(url,
        function(body, len, headers, code)
            if code ~= 200 then
                callback(nil, "HTTP error: " .. code)
                return
            end
            ensureDataPath("images")
            file.Write(path, body)
            callback(Material("../data/" .. path))
        end,
        function(err)
            callback(nil, err)
        end
    )
end

-- Data model for a gframe node
local function newNode(class)
    class = class or "DPanel"
    local node = {
        name = "Panel",
        class = class,
        x = 0,
        y = 0,
        w = 200,
        h = 120,
        bgColor = {r=60,g=60,b=60,a=200},
        image = nil, -- {type="path"|"url", path="..."}
        children = {},
        props = {}, -- custom extra props
    }
    return node
end

-- VGUI: A node editor panel that represents a node visually and supports nesting
local NODE_PAN = {}
NODE_PAN.ClassName = "GFrameNode"
NODE_PAN.Base = "DPanel"

function NODE_PAN:Init()
    self:SetMouseInputEnabled(true)
    self:SetKeyboardInputEnabled(false)
    self.node = self.node or newNode()
    self.dragging = false
    self.resizing = false
    self.minSize = 20
    self.childrenPanels = {}
    self.material = nil
    self:DockPadding(4,4,4,4)

    -- title label
    self.title = vgui.Create("DLabel", self)
    self.title:SetText(self.node.name)
    self.title:Dock(TOP)
    self.title:SetTall(18)

    -- make selectable
    self.OnMousePressed = function(_,code)
        if code == MOUSE_LEFT then
            self.dragging = true
            self:MouseCapture(true)
            self.dragStart = {mousex = gui.MouseX(), mousey = gui.MouseY(), x = self.x, y = self.y}
            if self.ParentEditor then self.ParentEditor:SelectNode(self) end
        elseif code == MOUSE_RIGHT then
            local menu = DermaMenu()
            menu:AddOption("Add child", function()
                local child = newNode()
                child.name = "Child"
                table.insert(self.node.children, child)
                self:RebuildChildren()
                if self.ParentEditor then self.ParentEditor:RefreshTree() end
            end)
            menu:AddOption("Remove", function()
                if self.ParentEditor then self.ParentEditor:RemoveNode(self) end
            end)
            menu:Open()
        end
    end

    local resizeGrip = vgui.Create("DButton", self)
    resizeGrip:SetText("")
    resizeGrip:SetSize(12,12)
    resizeGrip:SetZPos(999)
    resizeGrip:SetCursor("sizens")
    resizeGrip.Paint = function() end
    resizeGrip.OnMousePressed = function()
        self.resizing = true
        self:MouseCapture(true)
        self.resizeStart = {mx = gui.MouseX(), my = gui.MouseY(), w = self:GetWide(), h = self:GetTall()}
    end
    resizeGrip.OnMouseReleased = function() self.resizing = false self:MouseCapture(false) end
    self.resizeGrip = resizeGrip
end

function NODE_PAN:PerformLayout(w,h)
    self.title:SetText(self.node.name or "Panel")
    self.resizeGrip:SetPos(w - 14, h - 14)
end

function NODE_PAN:Paint(w,h)
    local bg = self.node.bgColor or {r=60,g=60,b=60,a=200}
    surface.SetDrawColor(bg.r, bg.g, bg.b, bg.a)
    surface.DrawRect(0,0,w,h)

    if self.node.image then
        if self.material then
            surface.SetMaterial(self.material)
            surface.SetDrawColor(255,255,255,255)
            surface.DrawTexturedRect(0,0,w,h)
        else
            -- try to load
            if self.node.image.type == "url" then
                loadImageFromURL(self.node.image.path, function(mat, err)
                    if mat then 
                        self.material = mat 
                    else
                        print("Failed to load image: " .. tostring(err))
                    end
                end)
            else
                if file.Exists(self.node.image.path, "DATA") then
                    self.material = Material("../data/" .. self.node.image.path)
                end
            end
        end
    end

    -- border
    surface.SetDrawColor(0,0,0,200)
    surface.DrawOutlinedRect(0,0,w,h)
end

function NODE_PAN:Think()
    if self.dragging then
        local dx = gui.MouseX() - self.dragStart.mousex
        local dy = gui.MouseY() - self.dragStart.mousey
        local newx = self.dragStart.x + dx
        local newy = self.dragStart.y + dy
        self:SetPos(newx, newy)
        self.node.x = newx
        self.node.y = newy
        if self.ParentEditor then self.ParentEditor:UpdateInspector(self) end
    end
    if self.resizing then
        local dx = gui.MouseX() - self.resizeStart.mx
        local dy = gui.MouseY() - self.resizeStart.my
        local nw = math.max(self.minSize, self.resizeStart.w + dx)
        local nh = math.max(self.minSize, self.resizeStart.h + dy)
        self:SetSize(nw, nh)
        self.node.w = nw
        self.node.h = nh
        if self.ParentEditor then self.ParentEditor:UpdateInspector(self) end
    end
end

function NODE_PAN:RebuildChildren()
    -- remove old
    for _,c in pairs(self.childrenPanels) do if IsValid(c) then c:Remove() end end
    self.childrenPanels = {}
    for i,childNode in ipairs(self.node.children) do
        local child = vgui.Create("GFrameNode", self)
        child.node = childNode
        child:SetPos(childNode.x, childNode.y)
        child:SetSize(childNode.w, childNode.h)
        child.ParentEditor = self.ParentEditor
        child:RebuildChildren()
        table.insert(self.childrenPanels, child)
    end
end

vgui.Register("GFrameNode", NODE_PAN, "DPanel")


-- The main editor panel
local EDIT_PAN = {}
EDIT_PAN.ClassName = "GFrameEditor"
EDIT_PAN.Base = "DFrame"

function EDIT_PAN:Init()
    self:SetSize(1100, 650)
    self:Center()
    self:MakePopup()
    self:SetTitle("GFrame Editor")
    self:ShowCloseButton(true)

    -- root layout: left (tools), center (canvas), right (inspector)
    self.left = vgui.Create("DPanel", self)
    self.left:SetWide(200)
    self.left:Dock(LEFT)
    self.left:DockPadding(6,6,6,6)

    self.right = vgui.Create("DPanel", self)
    self.right:SetWide(300)
    self.right:Dock(RIGHT)
    self.right:DockPadding(6,6,6,6)

    self.canvasWrap = vgui.Create("DScrollPanel", self)
    self.canvasWrap:Dock(FILL)
    self.canvas = vgui.Create("DPanel", self.canvasWrap)
    self.canvas:SetSize(2000, 2000)
    self.canvas:DockPadding(0,0,0,0)
    self.canvasWrap:AddItem(self.canvas)
    self.canvas:SetBackgroundColor(Color(30,30,30))

    self.rootNode = newNode()
    self.rootNode.name = "Root"
    self.rootNode.w = 800
    self.rootNode.h = 600

    -- root visual node
    self.rootPanel = vgui.Create("GFrameNode", self.canvas)
    self.rootPanel.node = self.rootNode
    self.rootPanel:SetPos(50,50)
    self.rootPanel:SetSize(self.rootNode.w, self.rootNode.h)
    self.rootPanel.ParentEditor = self
    self.rootPanel:RebuildChildren()

    self.selected = self.rootPanel

    self:BuildLeft()
    self:BuildRight()
    self:BuildToolbar()

    self:RefreshTree()
end

function EDIT_PAN:Paint(w,h)
    surface.SetDrawColor(48,48,48,255)
    surface.DrawRect(0,0,w,h)
end

function EDIT_PAN:BuildLeft()
    local lbl = vgui.Create("DLabel", self.left)
    lbl:Dock(TOP)
    lbl:SetText("Hierarchy")
    lbl:SetTall(20)

    self.tree = vgui.Create("DTree", self.left)
    self.tree:Dock(FILL)

    self.tree.OnNodeSelected = function(_, node)
        if not node then return end
        if node._panel and IsValid(node._panel) then
            self:SelectNode(node._panel)
        end
    end

    local btnNew = vgui.Create("DButton", self.left)
    btnNew:Dock(BOTTOM)
    btnNew:SetText("Add root child")
    btnNew.DoClick = function()
        local n = newNode()
        n.name = "New"
        table.insert(self.rootNode.children, n)
        self.rootPanel:RebuildChildren()
        self:RefreshTree()
    end
end

function EDIT_PAN:BuildRight()
    local lbl = vgui.Create("DLabel", self.right)
    lbl:Dock(TOP)
    lbl:SetText("Inspector")
    lbl:SetTall(20)

    self.inspector = vgui.Create("DPanel", self.right)
    self.inspector:Dock(FILL)
    self.inspector:DockPadding(6,6,6,6)
    self.inspector.Paint = function() end

    self.propScroll = vgui.Create("DScrollPanel", self.inspector)
    self.propScroll:Dock(FILL)

    self:UpdateInspector(self.selected)
end

function EDIT_PAN:BuildToolbar()
    local toolbar = vgui.Create("DPanel", self)
    toolbar:SetTall(26)
    toolbar:Dock(TOP)
    toolbar:DockMargin(4,4,4,0)
    toolbar.Paint = function(s,w,h) surface.SetDrawColor(40,40,40,255) surface.DrawRect(0,0,w,h) end

    local btnSave = vgui.Create("DButton", toolbar)
    btnSave:SetText("Save")
    btnSave:SetPos(6,4)
    btnSave:SetSize(60,18)
    btnSave.DoClick = function()
        Derma_StringRequest("Save layout", "Name to save as:", "default", function(name)
            if not name or name == "" then return end
            local tbl = self:SerializeRoot()
            writeJSON(name, tbl)
            notification.AddLegacy("Saved to data/gframe_editor/" .. name .. ".json", NOTIFY_GENERIC, 4)
        end)
    end

    local btnLoad = vgui.Create("DButton", toolbar)
    btnLoad:SetText("Load")
    btnLoad:SetPos(72,4)
    btnLoad:SetSize(60,18)
    btnLoad.DoClick = function()
        local list = file.Find("gframe_editor/*.json", "DATA")
        local menu = DermaMenu()
        for _,f in ipairs(list) do
            local name = f:match("(.+)%.json$")
            menu:AddOption(name, function()
                local tbl = readJSON(name)
                if not tbl then notification.AddLegacy("Failed to load "..name, NOTIFY_ERROR, 4) return end
                self:LoadFromTable(tbl)
                notification.AddLegacy("Loaded "..name, NOTIFY_GENERIC, 4)
            end)
        end
        menu:Open()
    end

    local btnExport = vgui.Create("DButton", toolbar)
    btnExport:SetText("Export Lua")
    btnExport:SetPos(138,4)
    btnExport:SetSize(80,18)
    btnExport.DoClick = function()
        local tbl = self:SerializeRoot()
        local str = "local layout = " .. util.TableToJSON(tbl, true)
        file.Write("gframe_editor/export.lua", str)
        notification.AddLegacy("Exported Lua to data/gframe_editor/export.lua", NOTIFY_GENERIC, 4)
    end

    local btnAddImage = vgui.Create("DButton", toolbar)
    btnAddImage:SetText("Add image to selected")
    btnAddImage:SetPos(228,4)
    btnAddImage:SetSize(160,18)
    btnAddImage.DoClick = function()
        Derma_StringRequest("Image URL", "Paste image URL:", "", function(url)
            if url == "" then return end
            if not IsValid(self.selected) then notification.AddLegacy("No selection", NOTIFY_ERROR, 4) return end
            self.selected.node.image = {type="url", path=url}
            -- attempt load immediately
            loadImageFromURL(url, function(mat, err)
                if mat then 
                    self.selected.material = mat 
                else
                    notification.AddLegacy("Image load failed: " .. tostring(err), NOTIFY_ERROR, 4) 
                end
            end)
        end)
    end
end

-- Serialize the tree into a table for saving
function EDIT_PAN:SerializeNode(panel)
    local n = panel.node
    local copy = {
        name = n.name,
        class = n.class,
        x = panel.x or n.x,
        y = panel.y or n.y,
        w = panel:GetWide() or n.w,
        h = panel:GetTall() or n.h,
        bgColor = n.bgColor,
        image = n.image,
        children = {},
        props = n.props or {},
    }
    for _,childPanel in ipairs(panel.childrenPanels or {}) do
        table.insert(copy.children, self:SerializeNode(childPanel))
    end
    return copy
end

function EDIT_PAN:SerializeRoot()
    return self:SerializeNode(self.rootPanel)
end

-- Load structure from table
function EDIT_PAN:LoadFromTable(tbl)
    -- convert table to node structures and rebuild
    local function applyToNode(panel, t)
        panel.node.name = t.name or panel.node.name
        panel.node.class = t.class or panel.node.class
        panel.node.bgColor = t.bgColor or panel.node.bgColor
        panel.node.image = t.image or panel.node.image
        panel.node.props = t.props or panel.node.props
        panel:SetPos(t.x or panel.x)
        panel:SetSize(t.w or panel:GetWide(), t.h or panel:GetTall())
        panel.node.x = panel.x
        panel.node.y = panel.y
        panel.node.w = panel:GetWide()
        panel.node.h = panel:GetTall()
        panel.node.children = {}
        for _,childtbl in ipairs(t.children or {}) do
            local childNode = newNode(childtbl.class)
            childNode.name = childtbl.name or childNode.name
            childNode.bgColor = childtbl.bgColor or childNode.bgColor
            childNode.image = childtbl.image or childNode.image
            childNode.props = childtbl.props or {}
            table.insert(panel.node.children, childNode)
        end
        panel:RebuildChildren()
        for i,child in ipairs(panel.childrenPanels) do
            applyToNode(child, t.children[i] or {})
        end
    end

    applyToNode(self.rootPanel, tbl)
    self:RefreshTree()
end

-- Hierarchy tree builder
function EDIT_PAN:RefreshTree()
    self.tree:Clear()
    local function addNodeToTree(treenode, panel)
        local n = treenode:AddNode(panel.node.name)
        n._panel = panel
        for _,child in ipairs(panel.childrenPanels or {}) do
            addNodeToTree(n, child)
        end
    end
    addNodeToTree(self.tree, self.rootPanel)
    self.tree:ExpandAll()
end

function EDIT_PAN:SelectNode(panel)
    self.selected = panel
    -- bring to front visually
    panel:MoveToFront()
    self:UpdateInspector(panel)
end

function EDIT_PAN:RemoveNode(panel)
    -- attempt to remove panel from its parent node
    local parent = panel:GetParent()
    if not IsValid(parent) or not parent.node then return end
    for i,child in ipairs(parent.node.children) do
        if child == panel.node then
            table.remove(parent.node.children, i)
            break
        end
    end
    panel:Remove()
    parent:RebuildChildren()
    self:RefreshTree()
end

-- Inspector: show properties and allow edits
function EDIT_PAN:UpdateInspector(panel)
    self.propScroll:Clear()
    if not panel or not panel.node then return end

    local n = panel.node

    local function addTextField(label, text, onChange)
        local pnl = vgui.Create("DPanel", self.propScroll)
        pnl:Dock(TOP); pnl:SetTall(28)
        pnl.Paint = function() end
        local lbl = vgui.Create("DLabel", pnl)
        lbl:Dock(LEFT); lbl:SetWide(80); lbl:SetText(label)
        local txt = vgui.Create("DTextEntry", pnl)
        txt:Dock(FILL); txt:SetText(text or "")
        txt.OnEnter = function()
            onChange(txt:GetValue())
        end
        txt.OnLoseFocus = function() onChange(txt:GetValue()) end
        return pnl
    end

    local function addNumberField(label, num, onChange)
        return addTextField(label, tostring(num or 0), function(v) local nv = tonumber(v) or 0 onChange(nv) end)
    end

    addTextField("Name", n.name, function(v) n.name = v; panel.node.name = v; panel.title:SetText(v); self:RefreshTree() end)
    addNumberField("X", panel.x or n.x, function(v) n.x = v; panel:SetPos(v, panel.y or n.y) end)
    addNumberField("Y", panel.y or n.y, function(v) n.y = v; panel:SetPos(panel.x or n.x, v) end)
    addNumberField("W", panel:GetWide() or n.w, function(v) n.w = v; panel:SetWide(v) end)
    addNumberField("H", panel:GetTall() or n.h, function(v) n.h = v; panel:SetTall(v) end)

    -- background color picker
    local colBtn = vgui.Create("DButton", self.propScroll)
    colBtn:Dock(TOP); colBtn:SetTall(26)
    local function colorText(c) return string.format("BG: %d %d %d %d", c.r, c.g, c.b, c.a) end
    colBtn:SetText(colorText(n.bgColor or {r=60,g=60,b=60,a=200}))
    colBtn.DoClick = function()
        local cp = vgui.Create("DColorMixer")
        cp:SetParent(vgui.GetWorldPanel())
        cp:SetSize(300, 200)
        cp:Center()
        cp:MakePopup()
        cp:SetColor(Color(n.bgColor.r, n.bgColor.g, n.bgColor.b, n.bgColor.a or 255))
        cp.ValueChanged = function(s, col)
            n.bgColor = {r = col.r, g = col.g, b = col.b, a = col.a or 255}
            panel.node.bgColor = n.bgColor
            colBtn:SetText(colorText(n.bgColor))
        end
    end

    -- image controls
    local imgLbl = vgui.Create("DLabel", self.propScroll)
    imgLbl:Dock(TOP); imgLbl:SetTall(18)
    imgLbl:SetText("Image:")
    local imgPanel = vgui.Create("DPanel", self.propScroll)
    imgPanel:Dock(TOP); imgPanel:SetTall(26)
    imgPanel.Paint = function() end

    local btnSetURL = vgui.Create("DButton", imgPanel)
    btnSetURL:Dock(LEFT); btnSetURL:SetWide(120)
    btnSetURL:SetText("Set URL")
    btnSetURL.DoClick = function()
        Derma_StringRequest("Image URL", "Enter image URL:", "", function(url)
            if not url or url == "" then return end
            n.image = {type="url", path=url}
            panel.material = nil
            loadImageFromURL(url, function(mat, err)
                if mat then 
                    panel.material = mat 
                else
                    print("Failed to load image: " .. tostring(err))
                end
            end)
        end)
    end

    local btnClear = vgui.Create("DButton", imgPanel)
    btnClear:Dock(RIGHT); btnClear:SetWide(80)
    btnClear:SetText("Clear")
    btnClear.DoClick = function()
        n.image = nil
        panel.material = nil
    end

    -- custom props: key/value list
    local lblProps = vgui.Create("DLabel", self.propScroll)
    lblProps:Dock(TOP); lblProps:SetText("Custom props (key=value)")

    local addPropBtn = vgui.Create("DButton", self.propScroll)
    addPropBtn:Dock(TOP); addPropBtn:SetTall(22)
    addPropBtn:SetText("Add prop")
    addPropBtn.DoClick = function()
        Derma_StringRequest("Prop Key", "Key:", "", function(key)
            if not key or key == "" then return end
            Derma_StringRequest("Prop Value", "Value:", "", function(val)
                n.props[key] = val
                self:UpdateInspector(panel)
            end)
        end)
    end

    for k,v in pairs(n.props or {}) do
        local p = vgui.Create("DPanel", self.propScroll); p:Dock(TOP); p:SetTall(22)
        p.Paint = function() end
        local kLabel = vgui.Create("DLabel", p); kLabel:Dock(LEFT); kLabel:SetWide(80); kLabel:SetText(k)
        local vEntry = vgui.Create("DTextEntry", p); vEntry:Dock(FILL); vEntry:SetText(tostring(v))
        vEntry.OnEnter = function() n.props[k] = vEntry:GetValue() end
        local del = vgui.Create("DButton", p); del:Dock(RIGHT); del:SetWide(24); del:SetText("x")
        del.DoClick = function() n.props[k] = nil; self:UpdateInspector(panel) end
    end
end

-- Register editor
vgui.Register("GFrameEditor", EDIT_PAN, "DFrame")

-- Create console command to open editor
concommand.Add("gframe_editor_open", function()
    local ed = vgui.Create("GFrameEditor")
    table.insert(EDITOR.instances, ed)
end)

-- make available in Q menu (spawnmenu)
hook.Add("PopulateToolMenu", "GFrameEditor_Tools", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "GFrame Editor", "GFrame Editor", "", "", function(panel)
        panel:Clear()
        local btn = vgui.Create("DButton", panel)
        btn:Dock(TOP)
        btn:SetText("Open GFrame Editor")
        btn.DoClick = function()
            RunConsoleCommand("gframe_editor_open")
        end
    end)
end)
