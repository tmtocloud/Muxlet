-- Muxlet globals — shared state, utilities, ID management, and singleton UI components.

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

-- Fires onReposition for every live pane. Used after structural or global
-- geometry changes (window resize, workspace restore, embed/remove/split/swap)
-- where panes across the whole workspace may have moved. For a localized ratio
-- change during a handle drag, use MuxSplit:_notifyReposition() instead, which
-- only walks the affected subtree.
function Mux._notifyAllReposition()
    for _, p in pairs(Mux._panes) do
        if p.onReposition then p.onReposition(p) end
    end
end

-- User-facing IDs (pane_N, split_N, ps_N) recycle freed numbers via _idFree.
-- Internal widget names (mux_w_N) never recycle — Qt holds named widgets in
-- memory even when hidden, so recycled names would alias old destroyed widgets.
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

function Mux._newInternalId()
    Mux._internalSeq = Mux._internalSeq + 1
    return string.format("mux_w_%04d", Mux._internalSeq)
end

function Mux._freeId(id)
    if not id then return end
    local prefix, numStr = id:match("^(.-)_(%d+)$")
    if not prefix or not numStr then return end
    local n = tonumber(numStr)
    if not n then return end
    Mux._idFree[prefix] = Mux._idFree[prefix] or {}
    table.insert(Mux._idFree[prefix], n)
end

-- Single-parent inheritance class factory; :new(opts) calls :init(opts) on the instance.
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

-- Returns a new table with all fields from base, overridden by override.
function Mux._merge(base, override)
    local t = {}
    for k, v in pairs(base)          do t[k] = v end
    for k, v in pairs(override or {}) do t[k] = v end
    return t
end

function Mux._clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- Geyser constraint helpers.
-- _fromEdgePx(n) produces "-Npx". For SIZE constraints Geyser resolves this as
-- (parent_size - n - child_offset), so a child at offset p with size _fromEdgePx(n)
-- has its far edge at (parent_size - n). For POSITION constraints the formula
-- is (parent_size - n) directly (no child_offset subtracted).
function Mux._toPx(n)       return tostring(math.floor(n)) .. "px" end
function Mux._fromEdgePx(n) return "-" .. tostring(math.floor(n)) .. "px" end

Mux.debug = false

function Mux._log(fmt, ...)
    if not Mux.debug then return end
    cecho(string.format("\n<dim_grey>[Muxlet]<reset> %s\n", string.format(fmt, ...)))
end

function Mux._err(fmt, ...)
    printError(string.format("[Muxlet ERR] %s", string.format(fmt, ...)))
end

function Mux._warn(fmt, ...)
    cecho(string.format("\n<yellow>[Muxlet]<reset> %s\n", string.format(fmt, ...)))
end

-- MuxPaneSet instances write their pixel contributions here; _applyBorders()
-- commits all four sides in a single setBorderSizes call to avoid ordering issues.
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

-- Runs fn() with Geyser's per-constraint-change reposition suppressed. Geyser's
-- set_constraints() repositions on every change, and organize() changes constraints
-- via move()+resize() per child — so naive organize/reposition over a nested tree
-- fans out into O(branches^depth) repositions. Because get_x/get_width are computed
-- from the constraint chain (not native state), callers can update constraints inside
-- fn() and then apply native geometry once via Mux._applyGeometry. Always restores
-- set_constraints, even on error.
function Mux._suppressReposition(fn)
    local origSet = Geyser.set_constraints
    Geyser.set_constraints = function(w, c, cc) Geyser.calc_constraints(w, c, cc) end
    local ok, err = pcall(fn)
    Geyser.set_constraints = origSet
    if not ok then Mux._err("suppressReposition: %s", tostring(err)) end
    return ok
end

-- Singleton context menu. Each row is a reused Geyser.Label with its own callbacks;
-- pooling avoids widget allocation on every open.
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

-- Render items as a positioned context menu. items: array of {text, fn [, sep, danger, submenu]}.
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

-- Overflow context menu: appears on titlebar right-click ONLY when the titlebar
-- is too narrow to show all buttons (self._overflowMode == true).
-- Items mirror what the buttons do, with the same show/hide conditions.
function Mux._showContextMenu(pane, globalX, globalY)
    local menu  = Mux._contextMenu
    local theme = Mux.activeTheme()
    menu.itemHeight = theme.contextMenuItemHeight or 28
    menu.menuWidth  = theme.contextMenuWidth      or 188

    local items = {}

    -- Close (mirrors closeBtn)
    local showClose = pane.closeable
    if showClose then
        items[#items+1] = { text="✕  Close Pane", fn=function() pane:_confirmClose() end, danger=true }
    end

    -- Minimize (mirrors minBtn — floating only)
    if pane.floating and pane.minimizable then
        items[#items+1] = { text="–  Minimize", fn=function() pane:toggleMinimize() end }
    end

    -- Zoom/Unzoom (mirrors zoomBtn) — only meaningful when in a split or already zoomed
    if pane.zoomable and (pane._split or pane._zoomed) then
        local zText = pane._zoomed and "⧉  Unzoom" or "□  Zoom"
        items[#items+1] = { text=zText, fn=function() pane:zoom() end }
    end

    -- Embed (floating panes only)
    if pane.floating and pane.convertible then
        if #items > 0 then items[#items+1] = { sep=true } end
        items[#items+1] = { text="Embed Pane", fn=function() pane:embed() end }
    end

    -- Swap / Split (mirrors swapBtn, splitHBtn, splitVBtn)
    if not pane.floating then
        if (pane.swappable and pane._split) or pane.splittable then
            if #items > 0 then items[#items+1] = { sep=true } end
        end
        if pane.swappable and pane._split then
            items[#items+1] = { text="⇔  Swap with sibling", fn=function()
                pane._split:swapSlots()
            end }
        end
        if pane.splittable then
            items[#items+1] = { text="║  Split Vertically", fn=function()
                pane:split("h")
            end }
            items[#items+1] = { text="═  Split Horizontally", fn=function()
                pane:split("v")
            end }
        end
    end

    -- Settings / Properties (mirrors infoBtn: showSettingsInMenu → Settings, else → Properties)
    if pane.contextMenu then
        if pane.showSettingsInMenu then
            if #items > 0 then items[#items+1] = { sep=true } end
            items[#items+1] = { text="⚙  Settings", fn=function() Mux.settings.toggle() end }
        elseif pane.propertiesButton then
            if #items > 0 then items[#items+1] = { sep=true } end
            items[#items+1] = { text="≡  Properties", fn=function() Mux.showPaneProperties(pane) end }
        end
    end

    -- Content Library (opens library dialog) — hidden while tabs own the content slot.
    if pane._contentEnabled and pane:_contentEnabled() then
        if #items > 0 then items[#items+1] = { sep=true } end
        items[#items+1] = { text="▥  Content Library…", fn=function()
            Mux._showContentLibrary(pane)
        end }
    end

    if #items > 0 then
        Mux._showItemMenu(globalX, globalY, items)
    end
end

-- Content library dialog — scrollable list of all registered non-internal content.
-- Called by contentBtn in the titlebar and by the context menu "Content Library…" item.
function Mux._showContentLibrary(pane)
    if not pane.contentable then return end
    local contentNames = Mux._listContent and Mux._listContent() or {}
    if #contentNames == 0 then
        Mux._echo("\n<yellow>[Muxlet]<reset> No content types registered.\n")
        return
    end

    local LIB_ROW_H = 52
    local dlgW      = 460
    local dlgH      = math.min(#contentNames * LIB_ROW_H + 26, 500)
    local innerH    = dlgH - 26

    local dlg = Mux.createDialog({
        title = "Content Library",
        width = dlgW, height = dlgH,
        contextMenu = false,
    })
    if dlg.contentBg then dlg.contentBg:echo(""); dlg.contentBg:hide() end

    local c   = dlg.content
    local pfx = dlg._gid .. "_cl_"

    -- Scroll area (explicit height so it doesn't overflow the dialog bottom border)
    local scroll = Geyser.ScrollBox:new({
        name=pfx.."sc", x=0, y=0, width="100%", height=innerH,
    }, c)
    local contentW = math.max(50, scroll:get_width() - 17)
    local list     = Geyser.Label:new({
        name=pfx.."lc", x=0, y=0, width=contentW, height=#contentNames * LIB_ROW_H + 4, fillBg=1,
    }, scroll)
    list:setStyleSheet("background:rgba(10,12,22,0.97);border:none;")

    local rows = {}
    for i, contentName in ipairs(contentNames) do
        local def      = Mux._content[contentName]
        local dispName = (def and def.name)        or contentName
        local dispDesc = (def and def.description) or ""
        local isEven   = (i % 2 == 0)
        local yOff     = (i - 1) * LIB_ROW_H

        -- Singleton already deployed elsewhere — grey out the entire row.
        local isLocked = def and def.singleton
            and def._activeTargetRef
            and def._activeTargetRef._activeContent == contentName

        local rowBg = Geyser.Label:new({
            name=pfx.."r"..i.."bg", x=0, y=yOff, width="100%", height=LIB_ROW_H, fillBg=1,
        }, list)
        if isLocked then
            rowBg:setStyleSheet(isEven
                and "background:rgba(18,19,28,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.04);"
                or  "background:rgba(14,15,22,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.04);")
        else
            rowBg:setStyleSheet(isEven
                and "background:rgba(22,25,40,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.05);"
                or  "background:rgba(16,18,30,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.05);")
        end
        rows[i] = rowBg

        -- ⓘ info icon — hover to see full description
        local icon = Geyser.Label:new({
            name=pfx.."r"..i.."ic", x=10, y=yOff+15, width=22, height=22, fillBg=1,
        }, list)
        if isLocked then
            icon:setStyleSheet([[
                QLabel {
                    background: rgba(28,32,44,0.70);
                    border: 1px solid rgba(50,55,70,0.35);
                    border-radius: 4px;
                    color: #4a5568;
                    font-size: 11px;
                    font-weight: bold;
                }
            ]])
        else
            icon:setStyleSheet([[
                QLabel {
                    background: rgba(35,55,90,0.80);
                    border: 1px solid rgba(55,85,140,0.40);
                    border-radius: 4px;
                    color: #5888c8;
                    font-size: 11px;
                    font-weight: bold;
                }
                QLabel::hover {
                    background: rgba(48,72,118,0.90);
                    border-color: rgba(80,125,210,0.65);
                    color: #88b8ff;
                }
            ]])
        end
        icon:rawEcho("<center>i</center>")
        if dispDesc ~= "" then icon:setToolTip(dispDesc, 6) end

        -- Name label (vertically centered in row)
        local nameLbl = Geyser.Label:new({
            name=pfx.."r"..i.."nm", x=40, y=yOff+16, width=contentW-128, height=20,
        }, list)
        nameLbl:setStyleSheet(isLocked
            and "background:transparent;color:#4a5568;font-size:11px;font-weight:bold;"
            or  "background:transparent;color:#c6d2ee;font-size:11px;font-weight:bold;")
        nameLbl:rawEcho(dispName)

        -- Add / Active button
        local addBtn = Geyser.Label:new({
            name=pfx.."r"..i.."ab", x=contentW-82, y=yOff+13, width=72, height=26, fillBg=1,
        }, list)
        if isLocked then
            addBtn:setStyleSheet([[
                QLabel{background:rgba(22,24,34,0.80);color:#3a4458;font-size:9px;font-weight:bold;
                       border:1px solid rgba(40,45,60,0.45);border-radius:4px;}
            ]])
            addBtn:rawEcho("<center>Active</center>")
        else
            addBtn:setStyleSheet([[
                QLabel{background:rgba(28,70,44,0.9);color:#73de94;font-size:9px;font-weight:bold;
                       border:1px solid rgba(45,115,65,0.5);border-radius:4px;}
                QLabel::hover{background:rgba(38,90,55,0.95);border-color:rgba(60,145,80,0.7);}
            ]])
            addBtn:rawEcho("<center>+ Add</center>")

            local capName = contentName
            local function applyAndClose()
                Mux._applyContent(pane, capName)
                dlg:close()
            end
            addBtn:setClickCallback(applyAndClose)
            nameLbl:setClickCallback(applyAndClose)
            rowBg:setClickCallback(applyAndClose)
        end
    end

    dlg:show()
    dlg:raise()
    tempTimer(0, function()
        if dlg.outer then dlg.outer:reposition() end
    end)
end

-- Content registration API lives in content.lua.  Built-in examples in content_builtins.lua.

function Mux._closeContextMenu()
    local menu = Mux._contextMenu
    hideSubmenu()
    if menu.panel    then menu.panel:hide()    end
    if menu.backdrop then menu.backdrop:hide() end
    for _, label in ipairs(menu.rowLabels) do label:hide() end
end

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
        Mux._notifyAllReposition()
        Mux._inResize = false
    end)
end

Mux._registerResizeHandler()

-- When a pane floats and leaves an embedded sibling, a ghost label fills the vacated slot:
-- dashed border, "drop here" text, and an × dismiss button that collapses the split.
-- Keyed by internal gid; looked up slot→ghost (never pane→ghost) so ghost promotion
-- across split retirement works without back-referencing the original pane.
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

    -- When the cursor moves onto the × button, cancel the pending hide so the
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

function Mux._findGhostBySlot(slotContainer)
    if not slotContainer then return nil, nil end
    for key, ghost in pairs(Mux._ghostSlots) do
        if ghost.slot == slotContainer then return ghost, key end
    end
    return nil, nil
end

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

-- Singleton translucent strip previewing where a dragged floating pane will land.
Mux._insertionGhost      = Mux._insertionGhost      or nil
Mux._insertionGhostKey   = Mux._insertionGhostKey   or nil    -- last previewed strip
Mux._insertionGhostShown = Mux._insertionGhostShown or false

function Mux._showInsertionGhost(tx, ty, tw, th, edge)
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

    -- The move callback can ask for the same strip on many consecutive frames
    -- while the cursor sits in one zone. Re-parsing CSS and re-stacking the
    -- widget every frame is needless churn, so skip when nothing changed.
    local key = gx .. ":" .. gy .. ":" .. gw .. ":" .. gh .. ":" .. tostring(edge)
    if Mux._insertionGhostShown and Mux._insertionGhostKey == key then return end
    Mux._insertionGhostKey = key

    local theme = Mux.activeTheme()
    local css   = theme.insertionGhostCss or [[
        background-color: rgba(80, 130, 255, 0.22);
        border: 2px solid rgba(100, 160, 255, 0.75);
        border-radius: 2px;
    ]]

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
    Mux._insertionGhostShown = true
end

function Mux._hideInsertionGhost()
    if Mux._insertionGhost and Mux._insertionGhostShown then
        Mux._insertionGhost:hide()
        Mux._insertionGhostShown = false
        Mux._insertionGhostKey   = nil
    end
end

-- Embed a floating pane by splitting the target pane at the given edge.
-- Ratio is derived from the floater's current size, capped at 70% so neither half starves.
function Mux._doInsertAtEdge(floatingPane, targetPane, edge)
    local dir         = (edge == "top" or edge == "bottom") and "v" or "h"
    local floatOnSide = (edge == "top" or edge == "left")   and "a" or "b"

    local slotDim  = (dir == "v") and targetPane:height() or targetPane:width()
    local floatDim = (dir == "v") and floatingPane.floatH  or floatingPane.floatW
    local frac     = Mux._clamp(floatDim / math.max(slotDim, 1), 0.10, 0.70)
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
        Mux._notifyAllReposition()
    end
    Mux._log("doInsertAtEdge: %s → %s edge=%s", floatingPane.id, targetPane.id, edge)
end

Mux._log("Muxlet globals loaded (v%s)", Mux._version)