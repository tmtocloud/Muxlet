-- Muxlet v0.1.0
-- Game-agnostic tiling window manager for Mudlet, inspired by tmux.
--
-- Ground-truth references used in this implementation:
--   Mudlet/src/mudlet-lua/lua/geyser/GeyserGeyser.lua    — changeContainer, base_add, Geyser.Fixed/Dynamic
--   Mudlet/src/mudlet-lua/lua/geyser/GeyserContainer.lua — calculate_dynamic_window_size, reposition
--   Mudlet/src/mudlet-lua/lua/geyser/GeyserVBox.lua       — organize(), stretch-factor math
--   Mudlet/src/mudlet-lua/lua/geyser/GeyserHBox.lua       — organize() (horizontal mirror of VBox)
--   Mudlet/src/mudlet-lua/lua/geyser/GeyserLabel.lua      — mouse callbacks, setCursor, setStyleSheet
--   Mudlet/src/mudlet-lua/lua/geyser/GeyserAdjustableContainer.lua — drag/resize pattern reference

Mux = Mux or {}
local _pkgInfo = getPackageInfo("Muxlet")
Mux._version = (_pkgInfo and _pkgInfo.version) or "unknown"

-- Internal registries (never access directly; use Mux API)
Mux._panes    = Mux._panes    or {}   -- id → MuxPane instance
Mux._splits   = Mux._splits   or {}   -- id → MuxSplit instance
Mux._paneSets = Mux._paneSets or {}   -- id → MuxPaneSet instance
Mux._running             = Mux._running             or false
Mux._activeWorkspaceName = Mux._activeWorkspaceName or nil

-- panes: a global proxy that always delegates reads/writes to Mux._panes.
-- Users reference panes["pane_0001"].content from scripts and workspace files.
-- A metatable proxy is used instead of a direct alias so the global remains
-- valid after _clearWorkspace() replaces Mux._panes with a fresh empty table.
panes = setmetatable({}, {
    __index    = function(_, k)    return Mux._panes[k]     end,
    __newindex = function(_, k, v) Mux._panes[k] = v         end,
    __pairs    = function(_)       return pairs(Mux._panes)  end,
    __len      = function(_)
        local n = 0; for _ in pairs(Mux._panes) do n = n + 1 end; return n
    end,
})

-- ── ID generator ─────────────────────────────────────────────────────────────
-- User-facing IDs (pane, split, ps) use a per-prefix free pool so numbers are
-- reused after a pane is closed: close pane_0002, open a new one → pane_0002.
-- Internal Geyser widget names use _newInternalId() which never recycles,
-- preventing Qt window name conflicts with hidden old-pane widgets.
Mux._idCounters  = Mux._idCounters  or {}   -- prefix → highest assigned number
Mux._idFree      = Mux._idFree      or {}   -- prefix → list of freed numbers
Mux._internalSeq = Mux._internalSeq or 0   -- ever-increasing; never recycled

function Mux._newId(prefix)
    prefix = prefix or "mux"
    local free = Mux._idFree[prefix]
    if free and #free > 0 then
        table.sort(free)
        return string.format("%s_%d", prefix, table.remove(free, 1))
    end
    local n = (Mux._idCounters[prefix] or 0) + 1
    Mux._idCounters[prefix] = n
    return string.format("%s_%d", prefix, n)
end

-- Returns a unique internal ID for Geyser widget naming.  Never recycled so
-- reusing a pane number never creates a name clash with hidden old widgets.
function Mux._newInternalId()
    Mux._internalSeq = Mux._internalSeq + 1
    return string.format("mux_w_%04d", Mux._internalSeq)
end

-- Returns the numeric part of a generated ID to the free pool for reuse.
function Mux._freeId(id)
    if not id then return end
    local prefix, numStr = id:match("^(.-)_(%d+)$")
    if not prefix or not numStr then return end
    local n = tonumber(numStr)
    if not n then return end
    Mux._idFree[prefix] = Mux._idFree[prefix] or {}
    table.insert(Mux._idFree[prefix], n)
end

-- ── Class factory ─────────────────────────────────────────────────────────────
-- Creates a class table with optional single-parent inheritance.
-- Usage:
--   MyClass = Mux._class()           -- standalone class
--   Child   = Mux._class(MyClass)    -- inherits from MyClass
--
-- Every class gets a :new(opts) constructor that calls :init(opts) on the instance.
function Mux._class(parent)
    local cls = {}
    cls.__index = cls
    if parent then
        setmetatable(cls, { __index = parent })
    end
    function cls:new(opts)
        local inst = setmetatable({}, cls)
        if inst.init then inst:init(opts) end
        return inst
    end
    return cls
end

-- ── Shallow merge ─────────────────────────────────────────────────────────────
-- Returns a new table with all fields from base, overridden by override.
function Mux._merge(base, override)
    local t = {}
    for k, v in pairs(base)          do t[k] = v end
    for k, v in pairs(override or {}) do t[k] = v end
    return t
end

-- ── Numeric clamp ─────────────────────────────────────────────────────────────
function Mux._clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- ── Constraint helpers ────────────────────────────────────────────────────────
-- Geyser negative-pixel constraint: "-Npx" means (parent_size - N) pixels.
-- We use these helpers so the intent stays readable in calling code.

-- y or x from top/left edge (pixels)
function Mux._px(n)     return tostring(math.floor(n)) .. "px" end
-- y or x measured from bottom/right edge (negative pixel constraint)
function Mux._pxNeg(n)  return "-" .. tostring(math.floor(n)) .. "px" end
-- percentage string
function Mux._pct(n)    return tostring(n) .. "%" end

-- ── Logging ───────────────────────────────────────────────────────────────────
Mux.debug = false

function Mux._log(fmt, ...)
    if not Mux.debug then return end
    cecho(string.format("\n<dim_grey>[Muxlet]<reset> %s\n", string.format(fmt, ...)))
end

function Mux._err(fmt, ...)
    cecho(string.format("\n<red>[Muxlet ERR]<reset> %s\n", string.format(fmt, ...)))
end

function Mux._warn(fmt, ...)
    cecho(string.format("\n<orange>[Muxlet]<reset> %s\n", string.format(fmt, ...)))
end

-- ── Border tracker ────────────────────────────────────────────────────────────
-- Central state for the four Mudlet main-console borders.
-- MuxPaneSet updates these and calls _applyBorders() whenever a border zone
-- changes visibility or size.  Using setBorderSizes (single call) rather than
-- four individual setBorderLeft/Right/Top/Bottom calls to avoid ordering issues.
Mux._borders = Mux._borders or { top = 0, right = 0, bottom = 0, left = 0 }

function Mux._applyBorders()
    setBorderSizes(
        Mux._borders.top,
        Mux._borders.right,
        Mux._borders.bottom,
        Mux._borders.left
    )
    Mux._log("setBorderSizes(t=%d r=%d b=%d l=%d)",
        Mux._borders.top, Mux._borders.right,
        Mux._borders.bottom, Mux._borders.left)
end

-- ── Context menu ─────────────────────────────────────────────────────────────
-- Per-item Label approach: each row is its own Label with its own click and
-- hover callbacks.  No y-offset math needed — each label knows exactly what
-- it is.  Labels are pooled and reused across opens.

Mux._contextMenu = Mux._contextMenu or {
    backdrop   = nil,   -- full-screen transparent click-blocker
    panel      = nil,   -- dark background panel behind the rows
    rowLabels  = {},    -- pool of per-row Labels
    itemHeight = 28,    -- px per row; overwritten from theme at each open
    menuWidth  = 188,   -- px; overwritten from theme at each open
    submenu = {
        panel      = nil,
        rowLabels  = {},
        visible    = false,
    },
}

local function ensureMenuRows(count)
    local menu = Mux._contextMenu
    while #menu.rowLabels < count do
        local index = #menu.rowLabels + 1
        local label = Geyser.Label:new({
            name = "mux_menu_row_" .. index,
            x = 0, y = 0, width = menu.menuWidth, height = menu.itemHeight, fillBg = 1,
        }, Geyser)
        label:hide()
        menu.rowLabels[index] = label
    end
end

local function ensureSubmenuRows(count)
    local menu    = Mux._contextMenu
    local submenu = menu.submenu
    while #submenu.rowLabels < count do
        local index = #submenu.rowLabels + 1
        local label = Geyser.Label:new({
            name = "mux_submenu_row_" .. index,
            x = 0, y = 0, width = menu.menuWidth, height = menu.itemHeight, fillBg = 1,
        }, Geyser)
        label:hide()
        submenu.rowLabels[index] = label
    end
end

local function hideSubmenu()
    local submenu = Mux._contextMenu.submenu
    if submenu.panel then submenu.panel:hide() end
    for _, label in ipairs(submenu.rowLabels) do label:hide() end
    submenu.visible = false
end

local function showSubmenu(submenuItems, parentMenuX, parentRowY)
    local menu       = Mux._contextMenu
    local submenu    = menu.submenu
    local theme      = Mux.activeTheme()
    local itemHeight = menu.itemHeight
    local menuWidth  = menu.menuWidth
    local sepH       = theme.contextMenuSepHeight or 8
    local screenWidth, screenHeight = getMainWindowSize()

    local submenuHeight = 0
    for _, item in ipairs(submenuItems) do
        submenuHeight = submenuHeight + (item.sep and sepH or itemHeight)
    end
    local submenuX = parentMenuX + menuWidth + 2
    if submenuX + menuWidth > screenWidth - 4 then
        submenuX = parentMenuX - menuWidth - 2
    end
    local submenuY = math.max(4, math.min(parentRowY, screenHeight - submenuHeight - 4))

    ensureSubmenuRows(#submenuItems)

    if not submenu.panel then
        submenu.panel = Geyser.Label:new({
            name = "mux_submenu_panel",
            x = submenuX, y = submenuY,
            width = menuWidth, height = submenuHeight, fillBg = 1,
        }, Geyser)
    end
    submenu.panel:setStyleSheet(theme.contextMenuCss or [[
        background-color: rgba(18,18,28,252);
        border: 1px solid rgba(100,160,255,0.50);
        border-radius: 4px;
    ]])
    submenu.panel:echo("")
    moveWindow("mux_submenu_panel", submenuX, submenuY)
    resizeWindow("mux_submenu_panel", menuWidth, submenuHeight)
    submenu.panel:show()
    submenu.panel:raiseAll()

    local itemCss      = theme.contextMenuItemCss        or "background-color:rgba(0,0,0,0);border:none;"
    local itemHoverCss = theme.contextMenuItemHoverCss   or "background-color:rgba(100,160,255,0.18);border:none;"
    local dangerCss    = theme.contextMenuDangerCss      or "background-color:rgba(0,0,0,0);border:none;"
    local dangerHover  = theme.contextMenuDangerHoverCss or "background-color:rgba(180,40,40,0.30);border:none;"
    local sepCss       = theme.contextMenuSepCss         or "background-color:transparent;border:none;border-top:1px solid rgba(255,255,255,0.12);"
    local textColor    = theme.contextMenuTextColor       or "rgba(215, 215, 230, 0.95)"
    local dangerColor  = theme.contextMenuDangerTextColor or "rgba(230, 100, 100, 0.95)"

    local rowY = submenuY
    for index, item in ipairs(submenuItems) do
        local label = submenu.rowLabels[index]
        local thisH = item.sep and sepH or itemHeight
        moveWindow(label.name, submenuX, rowY)
        resizeWindow(label.name, menuWidth, thisH)

        if item.sep then
            label:setStyleSheet(sepCss)
            label:echo("")
            label:setOnEnter(function() end)
            label:setOnLeave(function() end)
            label:setClickCallback(function() Mux._closeContextMenu() end)
        else
            local normalCss   = item.danger and dangerCss   or itemCss
            local hoverCss    = item.danger and dangerHover or itemHoverCss
            local itemColor   = item.danger and dangerColor or textColor
            label:setStyleSheet(normalCss)
            label:echo(string.format(
                "<table width='100%%' height='%d'><tr>"
                .. "<td style='padding:0 14px;vertical-align:middle;color:%s;'>%s</td>"
                .. "</tr></table>", thisH, itemColor, item.text))
            label:setOnEnter(function() label:setStyleSheet(hoverCss) end)
            label:setOnLeave(function() label:setStyleSheet(normalCss) end)
            local action = item.fn
            label:setClickCallback(function(event)
                if event.button ~= "LeftButton" then return end
                Mux._closeContextMenu()
                if action then action() end
            end)
        end
        label:show()
        label:raiseAll()
        rowY = rowY + thisH
    end

    for index = #submenuItems + 1, #submenu.rowLabels do
        submenu.rowLabels[index]:hide()
    end
    submenu.visible = true
end

-- ── _showItemMenu: render any item list as a context menu ────────────────────
-- Called by _showContextMenu (pane menus) and _showTabContextMenu (tab menus).
-- items: array of { text, fn, sep, danger, submenu } tables.
function Mux._showItemMenu(globalX, globalY, items)
    local menu   = Mux._contextMenu
    local theme  = Mux.activeTheme()
    local screenWidth, screenHeight = getMainWindowSize()
    local itemHeight = menu.itemHeight
    local menuWidth  = menu.menuWidth
    local sepH       = theme.contextMenuSepHeight or 8

    local menuHeight = 0
    for _, item in ipairs(items) do
        menuHeight = menuHeight + (item.sep and sepH or itemHeight)
    end
    local menuX = math.max(4, math.min(globalX, screenWidth  - menuWidth - 4))
    local menuY = math.max(4, math.min(globalY, screenHeight - menuHeight - 4))

    -- ── Backdrop ──────────────────────────────────────────────────────────────
    if not menu.backdrop then
        menu.backdrop = Geyser.Label:new({
            name = "mux_menu_backdrop",
            x = 0, y = 0, width = screenWidth, height = screenHeight, fillBg = 1,
        }, Geyser)
        menu.backdrop:setStyleSheet("background-color: rgba(0,0,0,0); border: none;")
        menu.backdrop:setClickCallback(function() Mux._closeContextMenu() end)
    end
    resizeWindow("mux_menu_backdrop", screenWidth, screenHeight)
    menu.backdrop:show()
    menu.backdrop:raiseAll()

    -- ── Panel ─────────────────────────────────────────────────────────────────
    if not menu.panel then
        menu.panel = Geyser.Label:new({
            name = "mux_menu_panel",
            x = menuX, y = menuY, width = menuWidth, height = menuHeight, fillBg = 1,
        }, Geyser)
    end
    menu.panel:setStyleSheet(theme.contextMenuCss or [[
        background-color: rgba(18,18,28,252);
        border: 1px solid rgba(100,160,255,0.50);
        border-radius: 4px;
    ]])
    menu.panel:echo("")
    moveWindow("mux_menu_panel", menuX, menuY)
    resizeWindow("mux_menu_panel", menuWidth, menuHeight)
    menu.panel:show()
    menu.panel:raiseAll()

    -- ── Per-row labels ────────────────────────────────────────────────────────
    ensureMenuRows(#items)

    local itemCss      = theme.contextMenuItemCss        or "background-color:rgba(0,0,0,0);border:none;"
    local itemHoverCss = theme.contextMenuItemHoverCss   or "background-color:rgba(100,160,255,0.18);border:none;"
    local dangerCss    = theme.contextMenuDangerCss      or "background-color:rgba(0,0,0,0);border:none;"
    local dangerHover  = theme.contextMenuDangerHoverCss or "background-color:rgba(180,40,40,0.30);border:none;"
    local sepCss       = theme.contextMenuSepCss         or "background-color:transparent;border:none;border-top:1px solid rgba(255,255,255,0.12);"
    local textColor    = theme.contextMenuTextColor       or "rgba(215, 215, 230, 0.95)"
    local dangerColor  = theme.contextMenuDangerTextColor or "rgba(230, 100, 100, 0.95)"

    local rowY = menuY
    for index, item in ipairs(items) do
        local label  = menu.rowLabels[index]
        local thisH  = item.sep and sepH or itemHeight
        moveWindow(label.name, menuX, rowY)
        resizeWindow(label.name, menuWidth, thisH)

        if item.sep then
            label:setStyleSheet(sepCss)
            label:echo("")
            label:setOnEnter(function() hideSubmenu() end)
            label:setOnLeave(function() end)
            label:setClickCallback(function() Mux._closeContextMenu() end)
        elseif item.submenu then
            label:setStyleSheet(itemCss)
            label:echo(string.format(
                "<table width='100%%' height='%d'><tr>"
                .. "<td style='padding:0 14px;vertical-align:middle;color:%s;'>%s</td>"
                .. "</tr></table>", thisH, textColor, item.text))
            local capturedSubmenuItems = item.submenu
            local capturedMenuX, capturedRowY = menuX, rowY
            label:setOnEnter(function()
                label:setStyleSheet(itemHoverCss)
                showSubmenu(capturedSubmenuItems, capturedMenuX, capturedRowY)
            end)
            label:setOnLeave(function() label:setStyleSheet(itemCss) end)
            label:setClickCallback(function(event)
                if event.button ~= "LeftButton" then return end
                showSubmenu(capturedSubmenuItems, capturedMenuX, capturedRowY)
            end)
        else
            local normalCss   = item.danger and dangerCss   or itemCss
            local hoverCss    = item.danger and dangerHover or itemHoverCss
            local itemColor   = item.danger and dangerColor or textColor
            label:setStyleSheet(normalCss)
            label:echo(string.format(
                "<table width='100%%' height='%d'><tr>"
                .. "<td style='padding:0 14px;vertical-align:middle;color:%s;'>%s</td>"
                .. "</tr></table>", thisH, itemColor, item.text))
            label:setOnEnter(function() hideSubmenu(); label:setStyleSheet(hoverCss) end)
            label:setOnLeave(function() label:setStyleSheet(normalCss) end)
            local action = item.fn
            label:setClickCallback(function(event)
                if event.button ~= "LeftButton" then return end
                Mux._closeContextMenu()
                if action then action() end
            end)
        end
        label:show()
        label:raiseAll()
        rowY = rowY + thisH
    end

    for index = #items + 1, #menu.rowLabels do
        menu.rowLabels[index]:hide()
    end
end

function Mux._showContextMenu(pane, globalX, globalY)
    local menu  = Mux._contextMenu
    local theme = Mux.activeTheme()
    menu.itemHeight = theme.contextMenuItemHeight or 28
    menu.menuWidth  = theme.contextMenuWidth      or 188

    -- ── Build item list ───────────────────────────────────────────────────────
    local items = {}
    if not pane.locked then
        if not pane.floating then
            items[#items+1] = { text="Split Vertically", fn=function()
                Mux.setFocus(pane); Mux.splitFocused("h") end }
            items[#items+1] = { text="Split Horizontally", fn=function()
                Mux.setFocus(pane); Mux.splitFocused("v") end }
            if pane._split then
                local siblingSide = (pane._slotSide == "a") and "b" or "a"
                local sibling = (siblingSide == "a") and pane._split.childA or pane._split.childB
                local siblingName = (sibling and sibling.name) or "Sibling"
                items[#items+1] = { text=string.format('⇔  Swap with "%s"', siblingName), fn=function()
                    pane._split:swapSlots() end }
            end
            items[#items+1] = { sep=true }
            items[#items+1] = { text="Zoom Pane", fn=function()
                Mux.setFocus(pane); Mux.zoomFocused() end }
        elseif not pane.permanentFloat then
            items[#items+1] = { text="Embed Pane", fn=function() pane:embed() end }
        end
        if not pane.mainConsoleHost then
            if not pane.noTitlebarToggle then
                local titlebarLabel = pane.titlebarVisible and "Hide Titlebar" or "Show Titlebar"
                items[#items+1] = { text=titlebarLabel, fn=function()
                    pane:setTitlebarVisible(not pane.titlebarVisible) end }
            end
            if not pane.noRename then
                items[#items+1] = { text="✎  Rename Pane", fn=function()
                    Mux._promptRename(pane) end }
            end
        end
        -- ── Tabs section ──────────────────────────────────────────────────────
        if not pane.mainConsoleHost and not pane.noTabs and not pane.permanentFloat then
            items[#items+1] = { sep=true }
            if pane._tabsEnabled then
                items[#items+1] = { text="⊞  Add Tab", fn=function() pane:addTab() end }
                items[#items+1] = { text="⊟  Disable Tabs", fn=function() pane:disableTabs() end }
            else
                items[#items+1] = { text="⊞  Enable Tabs", fn=function() pane:enableTabs() end }
            end
        end
        if not pane.mainConsoleHost and not pane.noContent then
            local contentNames = Mux._listContent and Mux._listContent() or {}
            if #contentNames > 0 then
                local contentItems = {}
                for _, contentName in ipairs(contentNames) do
                    local def     = Mux._content[contentName]
                    local capture = contentName
                    contentItems[#contentItems+1] = {
                        text = (def and def.name) or contentName,
                        fn   = function() Mux._applyContent(pane, capture) end,
                    }
                end
                items[#items+1] = { sep=true }
                items[#items+1] = { text="◈  Add Content  ▶", submenu=contentItems }
            end
        end
        if pane.mainConsoleHost then
            items[#items+1] = { sep=true }
            items[#items+1] = { text="⚙  Settings", fn=function() Mux.settings.toggle() end }
        end
        items[#items+1] = { sep=true }
        items[#items+1] = { text="⊘  Lock Pane", fn=function() pane:lock() end }
        if not pane.mainConsoleHost then
            items[#items+1] = { sep=true }
            items[#items+1] = { text="✕  Close Pane", fn=function() pane:close() end, danger=true }
        end
    else
        items[#items+1] = { text="⊙  Unlock Pane", fn=function() pane:unlock() end }
        if pane.mainConsoleHost then
            items[#items+1] = { sep=true }
            items[#items+1] = { text="⚙  Settings", fn=function() Mux.settings.toggle() end }
        end
    end

    Mux._showItemMenu(globalX, globalY, items)
end

-- ── Rename dialog ─────────────────────────────────────────────────────────────
-- A centred floating panel with a Geyser.CommandLine text-entry field,
-- OK and Cancel buttons, and a dimming backdrop.
--
-- opts: { currentName, title, onConfirm }
--   currentName     — pre-filled into the text field
--   title           — dialog heading ("Rename Pane", "Rename Tab", …)
--   onConfirm(name) — called with the trimmed name when user confirms

local _renameDialog = {}  -- widget cache; created once, repositioned on each open

function Mux._showRenameDialog(opts)
    opts = opts or {}
    local currentName = opts.currentName or ""
    local title       = opts.title       or "Rename"
    local onConfirm   = opts.onConfirm   or function() end

    local sw, sh = getMainWindowSize()
    local dw, dh = 360, 148
    local dx = math.floor((sw - dw) / 2)
    local dy = math.floor((sh - dh) / 2)

    local theme = Mux.activeTheme()
    local bg    = "rgba(22, 22, 34, 252)"
    local tc    = theme.titlebarTextColor  or "rgba(215,215,230,0.92)"
    local hint  = "rgba(140,145,168,0.85)"
    local btnCss = [[
        QLabel { background-color: rgba(38,38,52,200);
                 border: 1px solid rgba(255,255,255,0.16);
                 border-radius: 3px; color: rgba(175,175,190,225); font-size:10px; }
        QLabel::hover { background-color: rgba(65,65,85,220); color: white; }
    ]]
    local okCss = [[
        QLabel { background-color: rgba(30,55,90,220);
                 border: 1px solid rgba(100,160,255,0.45);
                 border-radius: 3px; color: rgba(140,190,255,0.95); font-size:10px; }
        QLabel::hover { background-color: rgba(45,80,130,240); color: white; }
    ]]
    local inputCss = [[
        background-color: rgb(10,10,18);
        color: #d0d2e2;
        font-size: 12px;
        border: 1px solid rgba(100,160,255,0.45);
        border-radius: 3px;
        padding-left: 6px;
        padding-right: 4px;
    ]]

    -- ── Build widgets (once) ──────────────────────────────────────────────────
    if not _renameDialog.backdrop then
        _renameDialog.backdrop = Geyser.Label:new({
            name = "mux_rename_backdrop",
            x = 0, y = 0, width = sw, height = sh, fillBg = 1,
        }, Geyser)
        _renameDialog.backdrop:setStyleSheet(
            "background-color: rgba(0,0,0,0.40); border: none;")
    end

    if not _renameDialog.panel then
        _renameDialog.panel = Geyser.Label:new({
            name = "mux_rename_panel",
            x = dx, y = dy, width = dw, height = dh, fillBg = 1,
        }, Geyser)
    end

    if not _renameDialog.titleLbl then
        _renameDialog.titleLbl = Geyser.Label:new({
            name = "mux_rename_title",
            x = 14, y = 12, width = dw - 28, height = 20,
        }, _renameDialog.panel)
    end

    if not _renameDialog.hintLbl then
        _renameDialog.hintLbl = Geyser.Label:new({
            name = "mux_rename_hint",
            x = 14, y = 36, width = dw - 28, height = 18,
        }, _renameDialog.panel)
    end

    -- CommandLine: the actual editable text field.
    if not _renameDialog.input then
        _renameDialog.input = Geyser.CommandLine:new({
            name = "mux_rename_input",
            x = 14, y = 62, width = dw - 28, height = 26,
        }, _renameDialog.panel)
        _renameDialog.input:setStyleSheet(inputCss)
    end

    -- Separator above buttons.
    if not _renameDialog.sep then
        _renameDialog.sep = Geyser.Label:new({
            name = "mux_rename_sep",
            x = 0, y = 100, width = dw, height = 1, fillBg = 1,
        }, _renameDialog.panel)
        _renameDialog.sep:setStyleSheet(
            "background-color: rgba(255,255,255,0.10); border: none;")
    end

    if not _renameDialog.okBtn then
        _renameDialog.okBtn = Geyser.Label:new({
            name = "mux_rename_ok",
            x = dw - 168, y = 112, width = 72, height = 24, fillBg = 1,
        }, _renameDialog.panel)
    end

    if not _renameDialog.cancelBtn then
        _renameDialog.cancelBtn = Geyser.Label:new({
            name = "mux_rename_cancel",
            x = dw - 88, y = 112, width = 72, height = 24, fillBg = 1,
        }, _renameDialog.panel)
    end

    -- ── Restyle for current theme (safe to call every open) ──────────────────
    _renameDialog.panel:setStyleSheet(string.format([[
        background-color: %s;
        border: 1px solid rgba(100,160,255,0.50);
        border-radius: 5px;
    ]], bg))
    _renameDialog.titleLbl:setStyleSheet(string.format(
        "background:transparent; color:%s; font-size:12px; font-weight:bold;", tc))
    _renameDialog.hintLbl:setStyleSheet(string.format(
        "background:transparent; color:%s; font-size:10px;", hint))
    _renameDialog.okBtn:setStyleSheet(okCss)
    _renameDialog.okBtn:echo("<center>OK</center>")
    _renameDialog.cancelBtn:setStyleSheet(btnCss)
    _renameDialog.cancelBtn:echo("<center>Cancel</center>")

    -- ── Per-open content ──────────────────────────────────────────────────────
    _renameDialog.titleLbl:echo(title)
    _renameDialog.hintLbl:echo(string.format(
        "Renaming: <b>%s</b>", currentName))
    _renameDialog.input:print(currentName)

    -- ── Position and show ─────────────────────────────────────────────────────
    resizeWindow("mux_rename_backdrop", sw, sh)
    moveWindow("mux_rename_panel", dx, dy)
    resizeWindow("mux_rename_panel", dw, dh)
    _renameDialog.backdrop:show()
    _renameDialog.backdrop:raiseAll()
    _renameDialog.panel:show()
    _renameDialog.panel:raiseAll()

    -- ── Confirm / cancel logic ────────────────────────────────────────────────
    local function closeDialog()
        _renameDialog.backdrop:hide()
        _renameDialog.panel:hide()
        -- Detach live callbacks so stale closures don't fire on later opens.
        _renameDialog.input:setAction(function() end)
        _renameDialog.okBtn:setClickCallback(function() end)
        _renameDialog.cancelBtn:setClickCallback(function() end)
        _renameDialog.backdrop:setClickCallback(function() end)
    end

    local function confirm()
        local newName = _renameDialog.input:getText()
        newName = newName and newName:match("^%s*(.-)%s*$")
        closeDialog()
        if newName and newName ~= "" then onConfirm(newName) end
    end

    -- Enter key in the CommandLine.
    _renameDialog.input:setAction(confirm)
    _renameDialog.okBtn:setClickCallback(function(e)
        if e.button == "LeftButton" then confirm() end
    end)
    _renameDialog.cancelBtn:setClickCallback(function(e)
        if e.button == "LeftButton" then closeDialog() end
    end)
    _renameDialog.backdrop:setClickCallback(function() closeDialog() end)
end

-- Content registration API lives in content.lua.  Built-in examples in content_builtins.lua.

function Mux._closeContextMenu()
    local menu = Mux._contextMenu
    hideSubmenu()
    if menu.panel    then menu.panel:hide()    end
    if menu.backdrop then menu.backdrop:hide() end
    for _, label in ipairs(menu.rowLabels) do label:hide() end
end

-- ── Window-resize event handler ───────────────────────────────────────────────
-- Wrapped in a named function so fullStart() can re-register after fullStop() kills it.
Mux._inResize = Mux._inResize or false

function Mux._registerResizeHandler()
    if Mux._resizeHandler then return end
    Mux._resizeHandler = registerAnonymousEventHandler("sysWindowResizeEvent", function()
        -- setBorderSizes can itself fire sysWindowResizeEvent; guard against recursion.
        if Mux._inResize then return end
        Mux._inResize = true
        for _, ps in pairs(Mux._paneSets) do
            if ps._onWindowResize then ps:_onWindowResize() end
        end
        for _, p in pairs(Mux._panes) do
            if p.mainConsoleHost and p.updateConsoleBorders then
                p:updateConsoleBorders()
            end
        end
        Mux._inResize = false
    end)
end

-- Register immediately at load time.
Mux._registerResizeHandler()

-- ── Ghost slot system ─────────────────────────────────────────────────────────
-- When a pane floats from a split and leaves a sibling still embedded, a ghost
-- slot visual fills the vacated slot: dashed border, "drop here" label, and a
-- hover-visible × button that collapses the split to clean up the empty space.
--
-- Registry: slotKey (internal gid string) → ghost record:
--   { label, dismissBtn, slot, split, side, paneSet }
-- Ghosts are NOT linked back to the pane that vacated them.  Simpler and more
-- robust: lookups go slot→ghost (via _findGhostBySlot), never pane→ghost.
Mux._ghostSlots = Mux._ghostSlots or {}

function Mux._createGhostSlot(slot, split, side, paneSet)
    local theme = Mux.activeTheme()
    local gid   = Mux._newInternalId()

    local bg = Geyser.Label:new({
        name   = gid .. "_ghost",
        x      = "0%", y = "0%",
        width  = "100%", height = "100%",
        fillBg = 1,
    }, slot)
    bg:setStyleSheet(theme.ghostSlotCss or [[
        background-color: rgba(20, 24, 40, 180);
        border: 2px dashed rgba(100, 120, 200, 0.45);
        border-radius: 3px;
    ]])
    local tc = "rgba(80, 95, 155, 0.65)"
    bg:echo(string.format(
        "<div align='center' style='padding-top:22%%;color:%s;font-size:10px;"
        .. "font-family:Consolas,Monaco,monospace;'>"
        .. "<span style='font-size:18px;color:rgba(80,95,155,0.40);'>⬚</span>"
        .. "<br/><br/>Drop a pane here</div>", tc))

    local dismissBtn = Geyser.Label:new({
        name   = gid .. "_ghost_x",
        x      = "-20", y = "2px",
        width  = "18px", height = "18px",
        fillBg = 1,
    }, bg)
    dismissBtn:setStyleSheet(theme.btnCss or "")
    local tc2 = theme.btnTextColor or "#aaaabb"
    dismissBtn:echo(string.format(
        "<center><font color='%s'>✕</font></center>", tc2))
    dismissBtn:hide()

    local slotKey   = gid
    local hideTimer = nil   -- debounce: prevent bg.setOnLeave firing when cursor
                            -- transitions to the dismissBtn child widget

    local function cancelHide()
        if hideTimer then killTimer(hideTimer); hideTimer = nil end
        dismissBtn:show()
        dismissBtn:raiseAll()
        Mux.raiseFloatingPanes()
        bg:setStyleSheet(Mux.activeTheme().ghostSlotHoverCss or [[
            background-color: rgba(25, 30, 55, 200);
            border: 2px dashed rgba(120, 150, 255, 0.65);
            border-radius: 3px;
        ]])
    end

    local function startHide()
        if hideTimer then killTimer(hideTimer) end
        -- Short delay so dismissBtn:setOnEnter can cancel before we hide.
        hideTimer = tempTimer(0.06, function()
            hideTimer = nil
            dismissBtn:hide()
            bg:setStyleSheet(Mux.activeTheme().ghostSlotCss or [[
                background-color: rgba(20, 24, 40, 180);
                border: 2px dashed rgba(100, 120, 200, 0.45);
                border-radius: 3px;
            ]])
        end)
    end

    bg:setOnEnter(function() cancelHide() end)
    bg:setOnLeave(function()  startHide()  end)

    -- When the cursor moves onto the X button, cancel the pending hide so the
    -- button stays visible and clickable.
    dismissBtn:setOnEnter(function() cancelHide() end)

    dismissBtn:setClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        local ghost = Mux._ghostSlots[slotKey]
        if not ghost then return end
        -- Read split/side from the live record — they may have been updated by a
        -- promotion (e.g. inner split retired, ghost moved to parent slot).
        local currentSplit = ghost.split
        local currentSide  = ghost.side
        Mux._removeGhostSlot(slotKey)
        if currentSplit then currentSplit:collapseSlot(currentSide) end
    end)

    local record = {
        label      = bg,
        dismissBtn = dismissBtn,
        slot       = slot,
        split      = split,
        side       = side,
        paneSet    = paneSet,
    }
    Mux._ghostSlots[slotKey] = record
    Mux._log("ghost slot created: %s (split=%s side=%s)", slotKey, split and split.id or "?", side or "?")
    return slotKey
end

function Mux._removeGhostSlot(slotKey)
    local ghost = Mux._ghostSlots[slotKey]
    if not ghost then return end
    ghost.label:hide()
    pcall(function() ghost.slot:remove(ghost.label) end)
    Mux._ghostSlots[slotKey] = nil
    Mux._log("ghost slot removed: %s", slotKey)
end

-- Find the ghost occupying a given slot container (returns ghost, key or nil).
function Mux._findGhostBySlot(slotContainer)
    if not slotContainer then return nil, nil end
    for key, ghost in pairs(Mux._ghostSlots) do
        if ghost.slot == slotContainer then return ghost, key end
    end
    return nil, nil
end

-- Safety catch: remove any ghost whose slot matches the given container.
function Mux._removeGhostSlotBySlot(slotContainer)
    for key, ghost in pairs(Mux._ghostSlots) do
        if ghost.slot == slotContainer then
            Mux._removeGhostSlot(key)
            return
        end
    end
end

function Mux._highlightGhostSlot(ghost)
    ghost.label:setStyleSheet(Mux.activeTheme().ghostSlotDropHighlightCss or [[
        background-color: rgba(30, 40, 80, 220);
        border: 2px solid rgba(100, 160, 255, 0.85);
        border-radius: 3px;
    ]])
end

function Mux._unhighlightGhostSlot(ghost)
    ghost.label:setStyleSheet(Mux.activeTheme().ghostSlotCss or [[
        background-color: rgba(20, 24, 40, 180);
        border: 2px dashed rgba(100, 120, 200, 0.45);
        border-radius: 3px;
    ]])
end

-- ── Insertion ghost ───────────────────────────────────────────────────────────
-- A singleton translucent strip that previews where a dragged floating pane
-- will be inserted when dropped at a pane edge.
Mux._insertionGhost = Mux._insertionGhost or nil

function Mux._showInsertionGhost(tx, ty, tw, th, edge)
    local theme   = Mux.activeTheme()
    local css     = theme.insertionGhostCss or [[
        background-color: rgba(80, 130, 255, 0.22);
        border: 2px solid rgba(100, 160, 255, 0.75);
        border-radius: 2px;
    ]]
    local stripPx = 6
    local gx, gy, gw, gh
    if edge == "top" then
        gx, gy, gw, gh = tx, ty, tw, stripPx
    elseif edge == "bottom" then
        gx, gy, gw, gh = tx, ty + th - stripPx, tw, stripPx
    elseif edge == "left" then
        gx, gy, gw, gh = tx, ty, stripPx, th
    else
        gx, gy, gw, gh = tx + tw - stripPx, ty, stripPx, th
    end

    if not Mux._insertionGhost then
        Mux._insertionGhost = Geyser.Label:new({
            name   = "mux_insertion_ghost",
            x = gx, y = gy, width = gw, height = gh,
            fillBg = 1,
        }, Geyser)
    else
        moveWindow("mux_insertion_ghost", gx, gy)
        resizeWindow("mux_insertion_ghost", gw, gh)
    end
    Mux._insertionGhost:setStyleSheet(css)
    Mux._insertionGhost:show()
    Mux._insertionGhost:raiseAll()
end

function Mux._hideInsertionGhost()
    if Mux._insertionGhost then
        Mux._insertionGhost:hide()
    end
end

-- ── Insert floating pane at an embedded pane's edge ──────────────────────────
-- edge: "top" | "bottom" | "left" | "right"
-- Ratio along the split axis is derived from the floating pane's current size,
-- capped at 70 % of the target slot so neither half starves.

function Mux._doInsertAtEdge(floatingPane, targetPane, edge)
    local dir         = (edge == "top" or edge == "bottom") and "v" or "h"
    local floatOnSide = (edge == "top" or edge == "left")   and "a" or "b"

    local slotDim  = (dir == "v") and targetPane:height() or targetPane:width()
    local floatDim = (dir == "v") and floatingPane.floatH  or floatingPane.floatW
    local frac     = Mux._clamp(floatDim / math.max(slotDim, 1), 0.10, 0.70)
    -- ratio is slotA's share; adjust based on which side the floater lands on.
    local ratio = (floatOnSide == "a") and frac or Mux._clamp(1 - frac, 0.30, 0.90)

    if targetPane._split then
        targetPane._split:_splitAndEmbed(targetPane, floatingPane, dir, floatOnSide, ratio)
    else
        -- Target is the root of its PaneSet — create a new top-level split.
        local ps = targetPane._paneSet
        if not ps then
            Mux._warn("doInsertAtEdge: target '%s' has no paneSet", targetPane.id)
            return
        end
        local newSplit = MuxSplit:new({
            direction = dir, ratio = ratio, parent = ps.outer,
        })
        local existingGoesToSide = (floatOnSide == "a") and "b" or "a"
        local existingSlot = (existingGoesToSide == "a") and newSplit.slotA or newSplit.slotB
        targetPane.outer:changeContainer(existingSlot)
        moveWindow(targetPane.outer.name, 0, 0)
        resizeWindow(targetPane.outer.name,
            existingSlot:get_width(), existingSlot:get_height())
        targetPane._slot     = existingSlot
        targetPane._split    = newSplit
        targetPane._slotSide = existingGoesToSide
        if existingGoesToSide == "a" then newSplit.childA = targetPane
        else                             newSplit.childB = targetPane
        end

        local floatSlot = (floatOnSide == "a") and newSplit.slotA or newSplit.slotB
        floatingPane._slot     = floatSlot
        floatingPane._split    = newSplit
        floatingPane._slotSide = floatOnSide
        floatingPane._paneSet  = ps
        if floatOnSide == "a" then newSplit.childA = floatingPane
        else                       newSplit.childB = floatingPane
        end
        floatingPane:embed(floatSlot)

        ps.root              = newSplit
        newSplit._parentSplit = nil
        newSplit._parentSide  = nil

        moveWindow(newSplit.box.name, 0, 0)
        resizeWindow(newSplit.box.name, ps.outer:get_width(), ps.outer:get_height())
        newSplit.box:organize()
        newSplit.box:reposition()
        for _, p in pairs(Mux._panes) do
            if p.mainConsoleHost then p:updateConsoleBorders() end
        end
    end
    Mux._log("doInsertAtEdge: %s → %s edge=%s", floatingPane.id, targetPane.id, edge)
end

Mux._log("Muxlet globals loaded (v%s)", Mux._version)
