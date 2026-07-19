-- Muxlet globals — shared state, utilities, ID management, and singleton UI components.

Mux = Mux or {}
local _pkgInfo = getPackageInfo("Muxlet")
Mux._version = (_pkgInfo and _pkgInfo.version) or "unknown"

-- Internal registries (never access directly; use Mux API)
Mux._panes    = Mux._panes    or {}   -- id → MuxPane instance
Mux._splits   = Mux._splits   or {}   -- id → MuxSplit instance
Mux._paneSpaces = Mux._paneSpaces or {}   -- id → MuxPaneSpace instance
Mux._running             = Mux._running             or false
Mux._activeWorkspaceName = Mux._activeWorkspaceName or nil
-- True once muxletReady has fired this session. A downstream package's own
-- bootstrap checks this (not just whether the Mux table exists) before
-- calling straight into Mux.* — the table is created by the line above
-- before the rest of Muxlet's scripts.json load order has run.
Mux._ready               = Mux._ready               or false

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

-- Re-assert floating panes' positions and relayout their content. Floating dialogs
-- (Settings/Properties) sit outside the split tree, so an embedded resize can leave
-- their content drifted out of the frame until the dialog is moved. Cheap (only
-- floating panes), so the localized ratio-drag path can call it without a full
-- all-pane reposition.
function Mux._reassertFloatingPanes()
    for _, p in pairs(Mux._panes) do
        if p.floating and p.outer then
            if p.floatX and p.floatY and p.outer.move then p.outer:move(p.floatX, p.floatY) end
            if p.outer.reposition then p.outer:reposition() end
            if Mux._relayoutContent then Mux._relayoutContent(p) end
        end
    end
end

-- Fires onReposition for every live pane. Used after structural or global
-- geometry changes (window resize, workspace restore, embed/remove/split/swap)
-- where panes across the whole workspace may have moved. For a localized ratio
-- change during a handle drag, use MuxSplit:_notifyReposition() instead, which
-- only walks the affected subtree.
function Mux._notifyAllReposition()
    for _, p in pairs(Mux._panes) do
        if p.onReposition then p.onReposition(p) end
        -- Floating dialogs/panes don't sit in the split tree, so a structural change
        -- below them can leave their content's geometry stale (it visibly drifts out
        -- of the frame until the dialog is moved). Re-assert the float position and
        -- reposition the container — the same path a manual move takes.
        if p.floating and p.outer then
            if p.floatX and p.floatY and p.outer.move then p.outer:move(p.floatX, p.floatY) end
            if p.outer.reposition then p.outer:reposition() end
        end
        if Mux._relayoutContent then Mux._relayoutContent(p) end
    end
    if Mux._reanchorAll then Mux._reanchorAll() end
    -- Keep floating panes above embedded ones after any structural layout change.
    -- raise() is z-order only; conditionally-hidden floating panes stay hidden.
    if Mux.raiseFloatingPanes then Mux.raiseFloatingPanes() end
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

-- Bumps the prefix's counter so a future _newId() call can never hand out a
-- number that collides with an explicit id passed in via opts.id (e.g. a
-- saved workspace restoring "pane_3"). Without this, explicit ids never
-- touch Mux._idCounters, so the counter stays behind and the next
-- auto-generated id can alias — and silently overwrite — an existing pane.
function Mux._reserveId(id)
    if not id then return end
    local prefix, numStr = id:match("^(.-)_(%d+)$")
    if not prefix or not numStr then return end
    local n = tonumber(numStr)
    if not n then return end
    if n > (Mux._idCounters[prefix] or 0) then
        Mux._idCounters[prefix] = n
    end
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

-- MuxSurface: common base for any content-bearing Muxlet surface (panes and tabs).
-- It owns only what both genuinely share — most importantly the tab-HOSTING
-- capability (addTab/activateTab/removeTab/enableTabs/serialize/…), so a pane can
-- host tabs and a tab can host sub-tabs through the same code. MuxPane adds chrome
-- and layout; MuxTab adds the tab surface. Tab-host methods are attached to
-- MuxSurface in tabs.lua. (Both subclasses resolve them via the __index chain, and
-- static MuxPane.x access falls through here too, so this move changes no behavior.)
MuxSurface = Mux._class()

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

-- Human-readable path identifying a pane or tab, e.g. "Console › Logs › Errors".
-- Tabs carry .pane = their immediate host (a pane or another tab); panes have
-- none, so the walk terminates at the owning pane. Used in dialog titles so it's
-- always clear which element a Properties / Content / editor dialog acts on.
function Mux._targetPath(target)
    if not target then return "" end
    local parts, t, guard = {}, target, 0
    while t and guard < 8 do
        parts[#parts + 1] = t.name or t.id or "?"
        t = t.pane
        guard = guard + 1
    end
    local out = {}
    for i = #parts, 1, -1 do out[#out + 1] = parts[i] end
    return table.concat(out, " › ")
end

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

-- MuxPaneSpace instances write their pixel contributions here; _applyBorders()
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

-- Applies each window's computed geometry natively, depth-first, exactly once.
-- Mirrors the native moveWindow/resizeWindow that Geyser.Container.reposition
-- performs, but WITHOUT the organize()/set_constraints re-entrancy that makes the
-- stock path fan out into O(branches^depth) repositions. Safe because Geyser's
-- get_x/get_y/get_width/get_height are computed from the constraint chain (parent
-- getters × scale + offset), not native window state — so once constraints are
-- updated (e.g. inside Mux._suppressReposition), a single pass applies them.
function Mux._applyGeometry(win)
    if not win or not win.name then return end
    -- ScrollBox overwrites its own get_x/get_y to a constant 0 after its first
    -- reposition() (so its children measure relative to its internal window);
    -- reading that here would move the scrollbox itself to (0,0). Its own
    -- reposition() (already run by the caller) positions it correctly.
    if win.type ~= "userwindow" and win.type ~= "scrollBox" then
        moveWindow(win.name, win:get_x(), win:get_y())
        resizeWindow(win.name, win:get_width(), win:get_height())
    end
    if win.windowList then
        for k, child in pairs(win.windowList) do
            if child ~= win and k ~= win and not child.nestLabels then
                Mux._applyGeometry(child)
            end
        end
    end
    if win.redraw then win:redraw() end
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

-- A keep-open menu action (e.g. "Add button") can trigger a content render that
-- re-raises pane/floating widgets over the menu. Re-assert the menu's z-order so it
-- stays on top and clickable — backdrop, panel, rows, then the submenu on top.
local function raiseMenuChrome()
    local menu = Mux._contextMenu
    if not menu then return end
    if menu.backdrop then pcall(function() menu.backdrop:raiseAll() end) end
    if menu.panel    then pcall(function() menu.panel:raiseAll()    end) end
    for _, l in ipairs(menu.rowLabels or {}) do pcall(function() l:raiseAll() end) end
    local sm = menu.submenu
    if sm and sm.visible then
        if sm.panel then pcall(function() sm.panel:raiseAll() end) end
        for _, l in ipairs(sm.rowLabels or {}) do pcall(function() l:raiseAll() end) end
    end
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
        background-color: rgba(20, 22, 32, 0.985);
        border: 1px solid rgba(140, 160, 210, 0.16);
        border-radius: 11px;
    ]])
    submenu.panel:echo("")
    moveWindow("mux_submenu_panel", submenuX, submenuY)
    resizeWindow("mux_submenu_panel", menuWidth, submenuHeight)
    submenu.panel:show()
    submenu.panel:raiseAll()

    local itemCss      = theme.contextMenuItemCss        or "background-color:rgba(0,0,0,0);border:none;border-radius:7px;padding-left:14px;qproperty-alignment:'AlignVCenter|AlignLeft';"
    local itemHoverCss = theme.contextMenuItemHoverCss   or "background-color:rgba(120,160,255,0.18);border:none;border-radius:7px;padding-left:14px;qproperty-alignment:'AlignVCenter|AlignLeft';"
    local dangerCss    = theme.contextMenuDangerCss      or "background-color:rgba(0,0,0,0);border:none;border-radius:7px;padding-left:14px;qproperty-alignment:'AlignVCenter|AlignLeft';"
    local dangerHover  = theme.contextMenuDangerHoverCss or "background-color:rgba(216,72,72,0.26);border:none;border-radius:7px;padding-left:14px;qproperty-alignment:'AlignVCenter|AlignLeft';"
    local sepCss       = theme.contextMenuSepCss         or "background-color:transparent;border:none;border-top:1px solid rgba(255,255,255,0.07);"
    local textColor    = theme.contextMenuTextColor       or "rgba(220, 222, 235, 0.95)"
    local dangerColor  = theme.contextMenuDangerTextColor or "rgba(232, 120, 120, 0.95)"

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
            label:echo(string.format("<span style='color:%s;'>%s</span>", itemColor, item.text))
            label:setOnEnter(function() label:setStyleSheet(hoverCss) end)
            label:setOnLeave(function() label:setStyleSheet(normalCss) end)
            local action   = item.fn
            local keepOpen = item.keepOpen
            label:setClickCallback(function(event)
                if event.button ~= "LeftButton" then return end
                if not keepOpen then Mux._closeContextMenu() end
                if action then action() end
                if keepOpen then raiseMenuChrome() end
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
    local padX       = theme.contextMenuPadX or 7
    local padY       = theme.contextMenuPadY or 7

    local menuHeight = 2 * padY
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
        background-color: rgba(20, 22, 32, 0.985);
        border: 1px solid rgba(140, 160, 210, 0.16);
        border-radius: 11px;
    ]])
    menu.panel:echo("")
    moveWindow("mux_menu_panel", menuX, menuY)
    resizeWindow("mux_menu_panel", menuWidth, menuHeight)
    menu.panel:show()
    menu.panel:raiseAll()

    ensureMenuRows(#items)

    local itemCss      = theme.contextMenuItemCss        or "background-color:rgba(0,0,0,0);border:none;border-radius:7px;padding-left:14px;qproperty-alignment:'AlignVCenter|AlignLeft';"
    local itemHoverCss = theme.contextMenuItemHoverCss   or "background-color:rgba(120,160,255,0.18);border:none;border-radius:7px;padding-left:14px;qproperty-alignment:'AlignVCenter|AlignLeft';"
    local dangerCss    = theme.contextMenuDangerCss      or "background-color:rgba(0,0,0,0);border:none;border-radius:7px;padding-left:14px;qproperty-alignment:'AlignVCenter|AlignLeft';"
    local dangerHover  = theme.contextMenuDangerHoverCss or "background-color:rgba(216,72,72,0.26);border:none;border-radius:7px;padding-left:14px;qproperty-alignment:'AlignVCenter|AlignLeft';"
    local sepCss       = theme.contextMenuSepCss         or "background-color:transparent;border:none;border-top:1px solid rgba(255,255,255,0.07);"
    local textColor    = theme.contextMenuTextColor       or "rgba(220, 222, 235, 0.95)"
    local dangerColor  = theme.contextMenuDangerTextColor or "rgba(232, 120, 120, 0.95)"

    local rowY = menuY + padY
    for index, item in ipairs(items) do
        local label  = menu.rowLabels[index]
        local thisH  = item.sep and sepH or itemHeight
        moveWindow(label.name, menuX + padX, rowY)
        resizeWindow(label.name, menuWidth - 2 * padX, thisH)

        if item.sep then
            label:setStyleSheet(sepCss)
            label:echo("")
            label:setOnEnter(function() hideSubmenu() end)
            label:setOnLeave(function() end)
            label:setClickCallback(function() Mux._closeContextMenu() end)
        else
            local danger    = item.danger
            local normalCss = danger and dangerCss   or itemCss
            local hoverCss  = danger and dangerHover or itemHoverCss
            local itemColor = danger and dangerColor or textColor
            local capturedX, capturedRowY = menuX, rowY
            -- Text and submenu may depend on live state (e.g. edit mode), so resolve
            -- them on each interaction rather than once at build: dynText() is the
            -- current label, curSub() the current submenu items (nil = plain row). A
            -- row that has a submenu right now behaves as a submenu parent (click keeps
            -- the menu open); keepOpen keeps a plain row open too. This lets one row
            -- flip between "Edit buttons" (plain) and "Editing…" (+submenu) live,
            -- without rebuilding the menu.
            local function curText() return (item.dynText and item.dynText()) or item.text or "" end
            local function curSub()
                if item.submenu    then return item.submenu end
                if item.dynSubmenu then return item.dynSubmenu() end
                return nil
            end
            local function echoText()
                label:echo(string.format("<span style='color:%s;'>%s</span>", itemColor, curText()))
            end
            label:setStyleSheet(normalCss)
            echoText()
            label:setOnEnter(function()
                label:setStyleSheet(hoverCss)
                local sub = curSub()
                if sub then showSubmenu(sub, capturedX, capturedRowY) else hideSubmenu() end
            end)
            label:setOnLeave(function() label:setStyleSheet(normalCss) end)
            local action   = item.fn
            local keepOpen = item.keepOpen
            label:setClickCallback(function(event)
                if event.button ~= "LeftButton" then return end
                if not (curSub() or keepOpen) then
                    Mux._closeContextMenu()
                    if action then action() end
                    return
                end
                -- Stay open: run the action, then refresh this row's text + submenu to
                -- match the new state and re-assert menu z-order.
                if action then action() end
                echoText()
                local sub = curSub()
                if sub then showSubmenu(sub, capturedX, capturedRowY) else hideSubmenu() end
                raiseMenuChrome()
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

-- Cascade positioning for panes spawned by the Add Floating Pane button.
-- Uses the same 30px diagonal step as dialog cascade so new panes and open
-- dialogs don't pile on top of each other.
local function _floatingPaneCascadePos(w, h, sw, sh)
    local baseX = math.floor((sw - w) / 2)
    local baseY = math.floor((sh - h) / 2)
    local step, maxSteps = 30, 12
    local taken = {}
    for _, p in pairs(Mux._panes) do
        if (p._dialog or p._addedPane) and p.outer then
            local pw, ph = p.outer:get_width(), p.outer:get_height()
            local pcx = math.floor((sw - pw) / 2)
            local pcy = math.floor((sh - ph) / 2)
            local idxX = math.floor((p.outer:get_x() - pcx) / step + 0.5)
            local idxY = math.floor((p.outer:get_y() - pcy) / step + 0.5)
            if idxX == idxY and idxX >= 0 then taken[idxX] = true end
        end
    end
    local k = 0
    while taken[k] and k < maxSteps do k = k + 1 end
    local x = Mux._clamp(baseX + k * step, 0, math.max(0, sw - w))
    local y = Mux._clamp(baseY + k * step, 0, math.max(0, sh - h))
    return x, y
end

-- Spawns a new floating pane at 20%×20% of the screen, cascaded so multiple
-- panes don't stack on top of each other. The created pane is identical to one
-- produced by split + convert: all default capabilities, no special flags.
function Mux._addFloatingPane()
    local sw, sh = getMainWindowSize()
    local w = math.floor(sw * 0.20)
    local h = math.floor(sh * 0.20)
    local x, y = _floatingPaneCascadePos(w, h, sw, sh)
    local pane = MuxPane:new({
        parent = Geyser,
        x = x, y = y, width = w, height = h,
        floatX = x, floatY = y, floatW = w, floatH = h,
    })
    pane._addedPane = true
    pane:_detachToFloat()
    Mux._raiseSeq = (Mux._raiseSeq or 0) + 1
    pane._raiseSeq = Mux._raiseSeq
    Mux.raiseFloatingPanes()
end

-- Build a context-menu item from a titlebar element spec (builtin or content).
-- menuOnly = the element currently has no titlebar icon (a tab, or a pane where the
-- icon was folded off the bar / compact titlebars are on), so the right-click menu is
-- the only way to reach it — the element may then keep the menu open and offer a
-- submenu. Text and submenu are wrapped so _showItemMenu re-resolves them live (e.g.
-- an "Edit buttons" row that flips to "Editing…" + a submenu once edit mode is on).
-- Returns nil when the element has no menu text.
function Mux._contentMenuItem(spec, baseCtx, menuOnly)
    local ctx = setmetatable({ menuOnly = menuOnly and true or false }, { __index = baseCtx })
    local function dynText()
        local ok, t = pcall(function()
            return (type(spec.menuText) == "function") and spec.menuText(ctx) or spec.menuText
        end)
        return (ok and t) or nil
    end
    if not dynText() then return nil end
    local dynSubmenu
    if spec.menuSubmenu then
        dynSubmenu = function() local ok, s = pcall(spec.menuSubmenu, ctx); return ok and s or nil end
    elseif spec.submenu then
        dynSubmenu = function() local ok, s = pcall(spec.submenu, ctx); return ok and s or nil end
    end
    local keepOpen = spec.menuKeepOpen
    if type(keepOpen) == "function" then keepOpen = keepOpen(ctx) end
    local danger = spec.danger
    if type(danger) == "function" then danger = danger(ctx) end
    return {
        text       = dynText(),
        dynText    = dynText,
        dynSubmenu = dynSubmenu,
        keepOpen   = keepOpen and true or nil,
        danger     = danger,
        menuGroup  = spec.menuGroup,
        fn         = spec.run and function() spec.run(ctx) end or nil,
    }
end

-- Overflow context menu: active on titlebar right-click only when the titlebar
-- is too narrow to show all buttons, or compact_titlebar is on (self._overflowMode).
-- Items mirror what the buttons do, with the same show/hide conditions.
-- The menu is exactly the set of elements the placement engine folded off the
-- titlebar (plus any menu-only content elements). One definition per element
-- drives both its icon and this row, so they can never drift.
function Mux._showContextMenu(pane, globalX, globalY)
    if not pane or not pane.contextMenu then return end
    local menu  = Mux._contextMenu
    local theme = Mux.activeTheme()
    menu.itemHeight = theme.contextMenuItemHeight or 28
    menu.menuWidth  = theme.contextMenuWidth      or 188

    local ctx   = (pane._elementCtx and pane:_elementCtx()) or { pane = pane }
    local items = {}
    local lastGroup

    local function addSpec(spec, menuOnly)
        local it = Mux._contentMenuItem(spec, ctx, menuOnly)
        if not it then return end
        if lastGroup and it.menuGroup and it.menuGroup ~= lastGroup and #items > 0 then
            items[#items + 1] = { sep = true }
        end
        lastGroup = it.menuGroup or lastGroup
        items[#items + 1] = it
    end

    -- 1) Folded icon-elements (builtins + content), already ordered for the menu.
    -- These have no icon in the bar right now, so content among them is menu-only.
    for _, spec in ipairs(pane._foldedElements or {}) do addSpec(spec, true) end

    -- 2) Menu-only content elements (iconable=false): no titlebar icon exists for
    -- these, so the menu is their only path in and they always appear here (the
    -- menu is already forced open for them via hasMenuExtra in pane.lua). Iconable
    -- content elements are NOT repeated here — they fold into the menu the same
    -- way builtins do (item 1 above), so a visible icon never gets a redundant
    -- menu row alongside it.
    if ctx.content and ctx.content.titlebarElements then
        local extra = {}
        for _, s in ipairs(ctx.content.titlebarElements) do
            if s.menuText and s.iconable == false then
                local ok, vis = pcall(s.visible or function() return true end, ctx)
                if ok and vis then extra[#extra + 1] = s end
            end
        end
        table.sort(extra, function(a, b) return (a.menuOrder or 500) < (b.menuOrder or 500) end)
        if #extra > 0 and #items > 0 then items[#items + 1] = { sep = true } end
        lastGroup = nil
        for _, s in ipairs(extra) do addSpec(s, true) end
    end

    if #items > 0 then
        Mux._showItemMenu(globalX, globalY, items)
    end
end

local LIB_ROW_H = 52
local LIB_DIV_H = 24

-- Renders one content-library row (info icon, name, Add/Remove/Active button) as a
-- Mux.ui.buildForm block widget. All per-row state travels on the row's own spec
-- (pane, contentName, dlg, refresh) instead of closing over _showContentLibrary, so
-- one registered widget type serves every dialog instance.
local function _buildContentLibraryRow(row, c)
    local spec        = c.spec
    local pane        = spec.pane
    local contentName = spec.contentName
    local def         = Mux._content[contentName]
    local dispName     = (def and def.name)        or contentName
    local dispDesc     = (def and def.description) or ""
    local isEven       = spec._even
    local uid          = c.uid
    local rowW         = c.formW

    -- State for THIS pane: active here (removable), held by a singleton
    -- elsewhere (greyed/locked), or free to add.
    local isHere = (pane._activeContent == contentName)
    local isLocked = def and def.singleton
        and def._activeTargetRef and def._activeTargetRef ~= pane
        and def._activeTargetRef._activeContent == contentName

    -- Content may refuse to apply in this pane's current state (e.g. the console
    -- can't go in a floating pane). canApply returns ok, reason — checked even when
    -- singleton-locked so the state-specific reason takes precedence.
    local canAdd, blockReason = true, nil
    if not isHere and def and type(def.canApply) == "function" then
        local ok, reason = def.canApply(pane)
        if ok == false then canAdd, blockReason = false, reason end
    end
    -- Greyed: held by a singleton elsewhere, or not applicable here.
    local greyed = isLocked or (not canAdd)

    if greyed then
        row:setStyleSheet(isEven
            and "background:rgba(18,19,28,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.04);"
            or  "background:rgba(14,15,22,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.04);")
    else
        row:setStyleSheet(isEven
            and "background:rgba(22,25,40,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.05);"
            or  "background:rgba(16,18,30,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.05);")
    end

    -- ⓘ info icon — hover to see full description
    local icon = Geyser.Label:new({
        name=uid.."_ic", x=10, y=15, width=22, height=22, fillBg=1,
    }, row)
    if greyed then
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
        name=uid.."_nm", x=40, y=16, width=rowW-128, height=20,
    }, row)
    nameLbl:setStyleSheet(greyed
        and "background:transparent;color:#4a5568;font-size:11px;font-weight:bold;"
        or  "background:transparent;color:#c6d2ee;font-size:11px;font-weight:bold;")
    nameLbl:rawEcho(dispName)

    -- Add / Remove / Active button
    local addBtn = Geyser.Label:new({
        name=uid.."_ab", x=rowW-82, y=13, width=72, height=26, fillBg=1,
    }, row)
    local capName = contentName
    local dlg, refresh = spec.dlg, spec.refresh
    if isHere then
        addBtn:setStyleSheet([[
            QLabel{background:rgba(120,40,40,0.9);color:#fdd;font-size:9px;font-weight:bold;
                   border:1px solid rgba(180,80,80,0.55);border-radius:4px;}
            QLabel::hover{background:rgba(150,55,55,0.95);}
        ]])
        addBtn:rawEcho("<center>Remove</center>")
        addBtn:setClickCallback(function() Mux._removeContent(pane); refresh() end)
    elseif not canAdd then
        addBtn:setStyleSheet([[
            QLabel{background:rgba(22,24,34,0.80);color:#3a4458;font-size:9px;font-weight:bold;
                   border:1px solid rgba(40,45,60,0.45);border-radius:4px;}
            QToolTip{background-color:#1d2030;color:#e8ebf5;border:1px solid rgba(255,255,255,0.18);
                     padding:5px 8px;border-radius:4px;}
        ]])
        addBtn:rawEcho("<center>—</center>")
        addBtn:setToolTip(blockReason or "Can't be added here.", 6)
    elseif isLocked then
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
        local function applyAndClose()
            Mux._applyContent(pane, capName)
            dlg:close()
        end
        addBtn:setClickCallback(applyAndClose)
        nameLbl:setClickCallback(applyAndClose)
        row:setClickCallback(applyAndClose)
    end
end

-- Content library dialog — scrollable list of all registered non-internal content.
-- Called by contentBtn in the titlebar and by the context menu "Content Library…" item.
--
-- Content registered with a `group` (see Mux.registerContent) is bucketed under a
-- collapsible divider labelled with that group name — built on Mux.ui.buildForm's
-- divider/section mechanism, all collapsed by default. Content registered without
-- a group renders as a flat row above the groups: no separator, always visible,
-- nothing to collapse. Muxlet's own built-in content uses group = "Muxlet".
function Mux._showContentLibrary(pane)
    if not pane.contentable then return end
    local contentNames = Mux._listContent and Mux._listContent() or {}
    if #contentNames == 0 then
        Mux._echo("\n<yellow>[Muxlet]<reset> No content types registered.\n")
        return
    end

    -- Register the row widget lazily: widgets.lua (Mux.ui) loads after globals.lua
    -- in scripts.json, so Mux.ui.registerWidget isn't available at this file's own
    -- load time — only once something actually opens the dialog at runtime.
    if Mux.ui and Mux.ui.registerWidget and not (Mux.ui._widgets and Mux.ui._widgets["mux_contentLibraryRow"]) then
        Mux.ui.registerWidget("mux_contentLibraryRow", _buildContentLibraryRow, { layout = "block", rowHeight = LIB_ROW_H })
    end

    -- Bucket by group; sort content within each bucket alphabetically (matches
    -- Mux._listContent's own ordering) and sort groups alphabetically.
    local ungrouped, grouped, groupOrder = {}, {}, {}
    for _, n in ipairs(contentNames) do
        local g = Mux._content[n] and Mux._content[n].group
        if g and g ~= "" then
            if not grouped[g] then grouped[g] = {}; groupOrder[#groupOrder+1] = g end
            grouped[g][#grouped[g]+1] = n
        else
            ungrouped[#ungrouped+1] = n
        end
    end
    table.sort(groupOrder)

    -- If this pane's active content lives in a group, that group should open
    -- pre-expanded (instead of everything collapsed) so the user isn't hunting
    -- for what's already applied. It's also hoisted to the front of groupOrder —
    -- Geyser's ScrollBox has no scrollTo/ensureVisible hook to jump the viewport
    -- to an arbitrary row, so putting the expanded group first is the closest
    -- approximation of "scroll to it" available.
    local activeGroup = nil
    if pane._activeContent then
        local activeDef = Mux._content[pane._activeContent]
        local g = activeDef and activeDef.group
        if g and g ~= "" and grouped[g] then activeGroup = g end
    end
    if activeGroup then
        for i, g in ipairs(groupOrder) do
            if g == activeGroup then table.remove(groupOrder, i); break end
        end
        table.insert(groupOrder, 1, activeGroup)
    end

    local dlgW = 460
    -- All groups start collapsed except the active-content group (if any), so the
    -- initial dialog only needs room for the ungrouped rows, one header row per
    -- group, plus the expanded rows of the active group.
    local visibleH = #ungrouped * LIB_ROW_H + #groupOrder * LIB_DIV_H
        + (activeGroup and #grouped[activeGroup] * LIB_ROW_H or 0)
    local dlgH     = math.min(visibleH + 26, 500)
    local innerH   = dlgH - 26

    local paneLabel = Mux._targetPath(pane)
    local dlg = Mux.createDialog({
        title = "Content Library — " .. paneLabel,
        width = dlgW, height = dlgH,
        singleton = "mux_contentlib_" .. (pane.id or paneLabel),
        contextMenu = false,
    })
    if dlg.contentBg then dlg.contentBg:echo(""); dlg.contentBg:hide() end

    -- Track on the pane so MuxPane:close() / teardown closes us too — otherwise the
    -- library would be orphaned, listing content for a pane that no longer exists.
    pane._propertiesDialogs = pane._propertiesDialogs or {}
    pane._propertiesDialogs[dlg.id] = dlg
    local _prevOnClose = dlg.onClose
    dlg.onClose = function()
        if pane._propertiesDialogs then pane._propertiesDialogs[dlg.id] = nil end
        if _prevOnClose then _prevOnClose() end
    end

    local c   = dlg.content
    local pfx = dlg._gid .. "_cl_"

    -- Scroll area (explicit height so it doesn't overflow the dialog bottom border)
    local scroll = Geyser.ScrollBox:new({
        name=pfx.."sc", x=0, y=0, width="100%", height=innerH,
    }, c)
    local contentW = math.max(50, scroll:get_width() - 17)
    local list     = Geyser.Label:new({
        name=pfx.."lc", x=0, y=0, width=contentW, height=math.max(visibleH, 1), fillBg=1,
    }, scroll)
    list:setStyleSheet("background:rgba(10,12,22,0.97);border:none;")

    local function refresh() dlg:close(); Mux._showContentLibrary(pane) end

    local specs, zebra = {}, 0
    local function addRow(name)
        zebra = zebra + 1
        specs[#specs+1] = {
            type = "mux_contentLibraryRow",
            contentName = name, pane = pane, dlg = dlg, refresh = refresh,
            _even = (zebra % 2 == 0),
        }
    end
    for _, n in ipairs(ungrouped) do addRow(n) end
    for _, g in ipairs(groupOrder) do
        specs[#specs+1] = { type = "divider", label = g, _collapsed = (g ~= activeGroup) }
        for _, n in ipairs(grouped[g]) do addRow(n) end
    end

    -- Divider toggles call buildForm's relayout, which resizes the (dark) content
    -- label to fit but has no way to resize the dialog itself unless we hand it
    -- an onLayoutChange callback — mirrors MuxDialog:mountForm's own wiring, but
    -- inline since this dialog manages its own ScrollBox/list rather than using
    -- mountForm (needs the pane-fit height cap computed above, not fitContent's
    -- percent-of-screen one).
    Mux.ui.buildForm(list, specs, {
        width = contentW,
        dividerHeight = LIB_DIV_H,
        prefix = pfx .. "f",
        minParentHeight = innerH,
        onLayoutChange = function(h)
            local newDlgH   = math.max(math.min(h + 26, 500), 140)
            local newInnerH = newDlgH - 26
            scroll:resize(scroll:get_width(), newInnerH)
            if math.abs((dlg.floatH or 0) - newDlgH) >= 2 then
                dlg.floatH = newDlgH
                if dlg.outer then
                    dlg.outer:resize(dlg.floatW or dlg.outer:get_width(), newDlgH)
                    local _, sh = getMainWindowSize()
                    local y = dlg.floatY or 0
                    if y + newDlgH > (sh or 0) then dlg.floatY = math.max(0, (sh or 0) - newDlgH) end
                    if dlg.outer.reposition then dlg.outer:reposition() end
                end
            end
        end,
    })

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

-- The actual pane-space/reposition pass a native window resize triggers. Split
-- out from the event handler so both the per-frame coalesced call and the
-- trailing settle call below share one implementation.
function Mux._runWindowResizePass()
    -- setBorderSizes can itself fire sysWindowResizeEvent; guard against recursion.
    if Mux._inResize then return end
    Mux._inResize = true
    for _, ps in pairs(Mux._paneSpaces) do
        if ps._onWindowResize then ps:_onWindowResize() end
    end
    Mux._notifyAllReposition()
    Mux._inResize = false
end

function Mux._registerResizeHandler()
    if Mux._resizeHandler then return end
    Mux._resizeHandler = registerAnonymousEventHandler("sysWindowResizeEvent", function()
        if Mux._inResize then return end

        -- Dragging the real Mudlet window (or the maximize/restore animation) fires
        -- this once per frame, far faster than a full pane/content reposition can
        -- complete. Mux._resizing gates the same adaptive debounce split-handle and
        -- pane-corner drags already rely on (Mux._relayoutContent, MuxPane:_syncButtons),
        -- so per-frame work here gets just as cheap as those paths instead of running
        -- the full pipeline, uncapped, on every single event.
        Mux._resizing = true

        -- Coalesce same-frame duplicate events into one live pass per tick — same
        -- pattern as MuxSplit:_requestRatio — so cost is capped to "once per frame"
        -- no matter how many raw events land in that frame.
        if not Mux._resizeReposScheduled then
            Mux._resizeReposScheduled = true
            tempTimer(0, function()
                Mux._resizeReposScheduled = false
                Mux._runWindowResizePass()
            end)
        end

        -- There's no mouse-release to mark the end of a window resize, so settle on
        -- a trailing idle timer instead: each new event pushes it back, and once the
        -- drag/animation actually stops it fires once, clears Mux._resizing, and runs
        -- one final forced pass so anything skipped live (button overflow, deferred
        -- heavy content resize hooks) settles at the final geometry.
        if Mux._resizeSettleTimer then killTimer(Mux._resizeSettleTimer) end
        Mux._resizeSettleTimer = tempTimer(0.15, function()
            Mux._resizeSettleTimer = nil
            Mux._resizing = false
            Mux._runWindowResizePass()
        end)
    end)
end

Mux._registerResizeHandler()

-- When a pane floats and leaves an embedded sibling, a ghost label fills the vacated slot:
-- dashed border, "drop here" text, and an × dismiss button that collapses the split.
-- Keyed by internal gid; looked up slot→ghost (never pane→ghost) so ghost promotion
-- across split retirement works without back-referencing the original pane.
Mux._ghostSlots = Mux._ghostSlots or {}

function Mux._createGhostSlot(slot, split, side, paneSpace)
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
    local dropText = (Mux.settings and Mux.settings.get("mux", "ghostDropText")) or "Drop a pane here"
    bg:echo(string.format(
        "<div align='center' style='padding-top:22%%;color:%s;font-size:10px;"
        .. "font-family:Consolas,Monaco,monospace;'>"
        .. "<span style='font-size:18px;color:rgba(80,95,155,0.40);'>⬚</span>"
        .. "<br/><br/>%s</div>", tc, dropText))

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
        paneSpace  = paneSpace,
        -- Ghosts are ownerless empty tiles. A floating pane that left this ghost
        -- records the ghost's KEY (returned below) as its home; the ghost itself
        -- holds no pane reference, so promotion/dissolve need no owner fixup.
    }
    Mux._ghostSlots[slotKey] = record
    Mux._log("ghost slot created: %s (split=%s side=%s)", slotKey, split and split.id or "?", side or "?")
    return slotKey
end

function Mux._removeGhostSlot(slotKey)
    local ghost = Mux._ghostSlots[slotKey]
    if not ghost then return end
    -- Any floating pane anchored to this ghost tile must stop tracking it (ghost
    -- keys are used as anchor refs, so the standard helper catches them).
    if Mux._dropAnchorsReferencing then Mux._dropAnchorsReferencing(slotKey) end
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

-- Promote/move a ghost to a new home (slot/split/side), e.g. when an inner split
-- is retired and its lone ghost should rise to fill the parent slot. The ghost's
-- registry KEY is stable across this move, so a floating pane that recorded that
-- key as its home (`_homeGhostKey`) automatically follows the promotion with no
-- back-reference to maintain. Ghosts are ownerless empty tiles; nothing here
-- reaches into a pane.
function Mux._reassignGhost(ghost, newSlot, newSplit, newSide)
    if not ghost then return end
    ghost.slot  = newSlot
    ghost.split = newSplit
    ghost.side  = newSide
end

-- Dissolve a ghost whose home slot no longer exists (its split was retired with
-- no promotion). The empty tile simply disappears; any floating pane that recorded
-- this ghost's key as its home will, on its next return attempt, find the key
-- resolves to nothing and fall back to a fresh paneSpace embed. No owner fixup is
-- needed because the ghost owns no pane.
function Mux._dissolveGhost(ghostOrKey)
    local key, ghost
    if type(ghostOrKey) == "table" then
        ghost = ghostOrKey
        for k, g in pairs(Mux._ghostSlots) do if g == ghost then key = k; break end end
    else
        key, ghost = ghostOrKey, Mux._ghostSlots[ghostOrKey]
    end
    if not ghost then return end
    if key then Mux._removeGhostSlot(key) end
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
        -- Target is the root of its PaneSpace — create a new top-level split.
        local ps = targetPane._paneSpace
        if not ps then
            Mux._warn("doInsertAtEdge: target '%s' has no paneSpace", targetPane.id)
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
        floatingPane._paneSpace  = ps
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
-- ── Expanding titlebar icon stack ─────────────────────────────────────────────
-- Generalized "this titlebar button fans out into a column of sibling icons".
-- Given the origin button's screen rect and a list of { icon, tooltip, fn }, it
-- drops same-sized icon buttons straight down from the origin, styled to match
-- the titlebar, with a transparent full-screen scrim that dismisses on outside
-- click. Reusable by any titlebar button that needs sub-actions in its own
-- footprint (used by the anchor button for return / remove). Now a thin wrapper
-- over the shared Mux.ui.iconCascade widget (scrim + dismiss-on-pick).
Mux._iconStack = Mux._iconStack or {}

function Mux._hideTitlebarIconStack()
    if Mux._iconStack.cas then Mux._iconStack.cas:hide() end
end

function Mux._showTitlebarIconStack(x, y, w, h, items)
    local theme   = Mux.activeTheme()
    local btnCss  = theme.btnCss or "background-color: rgba(40,46,72,240); border: 1px solid rgba(100,160,255,0.35); border-radius: 3px;"
    local textCol = theme.btnTextColor or "#aaaabb"
    -- Colour each glyph to the titlebar resting colour; the cascade applies btnCss
    -- (which carries any :hover rule) as the box style.
    local mapped = {}
    for i, item in ipairs(items) do
        mapped[i] = {
            id = i, css = btnCss, tooltip = item.tooltip, fn = item.fn,
            icon = string.format("<font color='%s'>%s</font>", textCol, item.icon or "•"),
        }
    end
    if Mux._iconStack.cas then Mux._iconStack.cas:destroy() end
    Mux._iconStack.cas = Mux.ui.iconCascade(Geyser, {
        name = "mux_iconstack", x = math.floor(x), y = math.floor(y),
        direction = "down", size = w, gap = math.max(0, h - w),
        items = mapped, scrim = true, dismissOnClick = true,
    })
end

-- ── Lua source serializer ───────────────────────────────────────────────────
-- Turns a plain data value (nested tables/strings/numbers/booleans) into
-- ready-to-paste Lua source. Shared by every "export as static Lua" feature
-- (workspaces, declarative conditions/actions) so package developers get one
-- consistent, round-trippable output format wherever they export from.
local function isIdentifier(key)
    return type(key) == "string" and key:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function luaKey(key)
    if isIdentifier(key) then return key end
    if type(key) == "number" then return "[" .. tostring(key) .. "]" end
    return string.format("[%q]", key)
end

local function isArrayTable(t)
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        count = count + 1
    end
    return count == #t
end

function Mux._serializeLua(value, indent)
    local valueType = type(value)
    if value == nil then return "nil" end
    if valueType == "boolean" or valueType == "number" then return tostring(value) end
    if valueType == "string" then return string.format("%q", value) end
    if valueType ~= "table" then
        error("Mux._serializeLua: cannot serialize value of type " .. valueType)
    end

    if next(value) == nil then return "{}" end

    local pad   = string.rep("    ", indent)
    local padIn = string.rep("    ", indent + 1)
    local lines = {}

    if isArrayTable(value) then
        for _, v in ipairs(value) do
            lines[#lines + 1] = padIn .. Mux._serializeLua(v, indent + 1)
        end
    else
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            lines[#lines + 1] = padIn .. luaKey(k) .. " = " .. Mux._serializeLua(value[k], indent + 1)
        end
    end

    return "{\n" .. table.concat(lines, ",\n") .. "\n" .. pad .. "}"
end

-- Shared "write a generated Lua export file + echo the result" tail, used by
-- every export command (workspaces, conditions, actions) so output location,
-- error handling, and the success message all stay consistent.
function Mux._writeExportFile(filename, lua)
    local outPath = Mux._persistentDir .. "/" .. filename
    local f, err = io.open(outPath, "w")
    if not f then
        Mux._echo(string.format("\n<red>[Muxlet]<reset> Could not write export file: %s\n", tostring(err)))
        return nil
    end
    f:write(lua)
    f:close()
    return outPath
end