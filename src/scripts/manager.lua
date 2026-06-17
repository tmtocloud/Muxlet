-- Muxlet manager — public API for pane creation, focus, and workspace operations.

function Mux.newPane(opts)      return MuxPane:new(opts)    end
function Mux.newSplit(opts, a, b)
    local s = MuxSplit:new(opts)
    if a then s:place(a, "a") end
    if b then s:place(b, "b") end
    return s
end
function Mux.newPaneSet(opts)  return MuxPaneSet:new(opts) end

function Mux.getPane(id)     return Mux._panes[id]     end
function Mux.getPaneSet(id)  return Mux._paneSets[id]  end
function Mux.currentTheme()  return Mux._activeThemeName end

-- Mux._focusedPane is the pane targeted by mux commands and UI actions.
-- overlay panes (settings window, etc.) are excluded from the focus system:
-- they never receive the focus border, never displace workspace focus, and are
-- unaffected by split/zoom/close operations. setFocus() just raises them visually.
Mux._focusedPane = nil

function Mux.setFocus(pane)
    if pane and pane.overlay then
        if pane.floating then pane:raise() end
        return
    end
    if Mux._focusedPane and Mux._focusedPane ~= pane then
        local old = Mux._focusedPane
        if old._setFrameCss and old._baseFrameCss then
            old:_setFrameCss(old:_baseFrameCss())
        end
    end
    Mux._focusedPane = pane
    if not pane then return end
    if pane.floating then pane:raise() end
    Mux._lastFocusedPane = pane
    if pane.highlightable ~= false and pane._setFrameCss and pane._focusedFrameCss then
        pane:_setFrameCss(pane:_focusedFrameCss())
    end
    Mux._log("Focus → %s", pane.id)
end

function Mux.raiseFloatingPanes()
    for _, pane in pairs(Mux._panes) do
        if pane.floating then pane:raise() end
    end
end

-- Auto-manages Main pane's highlightable flag based on whether it has siblings.
-- Called whenever the embedded pane count changes.
function Mux._updateMainHighlightable()
    local mainPane
    if Mux._panes then
        for _, p in pairs(Mux._panes) do
            if p.mainConsoleHost then mainPane = p; break end
        end
    end
    if not mainPane then return end
    local alone = (#orderedPanes() == 1)
    mainPane.highlightable = not alone
    if alone and mainPane._setFrameCss and mainPane._baseFrameCss then
        mainPane:_setFrameCss(mainPane:_baseFrameCss())
    end
end

-- Raise only "free" floating panes (not overlay).
-- Called after a zoom so that popup dialogs remain above the zoomed pane.
function Mux._raiseFreeFloatingPanes()
    for _, pane in pairs(Mux._panes) do
        if pane.floating and not pane.overlay then
            pane:raise()
        end
    end
end

function Mux.focusNext()
    local ordered = orderedPanes()
    if #ordered == 0 then return end
    local idx = focusIndex(ordered)
    local nextIdx = (idx % #ordered) + 1
    Mux.setFocus(ordered[nextIdx])
end

function Mux.focusPrev()
    local ordered = orderedPanes()
    if #ordered == 0 then return end
    local idx = focusIndex(ordered)
    local prevIdx = ((idx - 2) % #ordered) + 1
    Mux.setFocus(ordered[prevIdx])
end

-- Navigate to the adjacent pane in the given direction within the parent split.
-- When the split axis doesn't match the direction, falls back to focusNext/Prev.
function Mux.focusAdjacent(direction)
    local pane = Mux._focusedPane
    if not pane then Mux.focusNext(); return end

    local split = pane._split
    if not split then Mux.focusNext(); return end

    local side = pane._slotSide
    local dir  = split.direction   -- "v" = top/bottom, "h" = left/right

    local cross =
        (direction == "left"  and dir == "h" and side == "b") or
        (direction == "right" and dir == "h" and side == "a") or
        (direction == "up"    and dir == "v" and side == "b") or
        (direction == "down"  and dir == "v" and side == "a")

    if cross then
        local targetSide = (side == "a") and "b" or "a"
        focusSlotFirstPane(split, targetSide)
    else
        if direction == "left" or direction == "up" then
            Mux.focusPrev()
        else
            Mux.focusNext()
        end
    end
end

function Mux.splitFocused(direction, ratio)
    local pane = Mux._focusedPane
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No focused pane.\n"); return nil
    end
    if pane.floating then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Pane '<yellow>%s<reset>' is floating — use <cyan>mux pane embed<reset> first.\n",
            pane.name)); return nil
    end

    direction = direction or "v"
    if not ratio then
        local pct = Mux.settings and Mux.settings.get("mux", "default_split_ratio")
        ratio = pct and (pct / 100) or 0.5
    end

    if pane._split then
        local newSplit = pane._split:_splitPaneInSlot(pane, direction, ratio)
        if newSplit then
            tempTimer(0, function()
                if newSplit.childB then Mux.setFocus(newSplit.childB) end
                Mux.raiseFloatingPanes()
                Mux._scheduleAutoSave()
            end)
        end
        return newSplit
    else
        -- Pane is the direct root of a PaneSet — wrap it in a new split.
        local ps = pane._paneSet
        if not ps then
            Mux._err("splitFocused: pane '%s' has no PaneSet reference", pane.id)
            return nil
        end
        local newSplit = MuxSplit:new({
            direction = direction,
            ratio     = ratio,
            parent    = ps.outer,
        })
        newSplit:place(pane, "a")
        local newPane = MuxPane:new({ parent = newSplit.slotB })
        newSplit:place(newPane, "b")
        newPane._paneSet = ps
        ps.root = newSplit
        newSplit.box:organize()
        newSplit.box:reposition()
        for _, p in pairs(Mux._panes) do
            if p.onReposition then p.onReposition(p) end
        end
        tempTimer(0, function()
            Mux.setFocus(newPane)
            Mux.raiseFloatingPanes()
            Mux._scheduleAutoSave()
        end)
        return newSplit
    end
end

-- Zoom the focused pane to full screen (requires pane.zoomable = true).
-- Calling again while zoomed restores the pane to its previous state.
function Mux.zoomFocused()
    local pane = Mux._focusedPane
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No focused pane.\n"); return
    end
    if not pane.zoomable then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Pane '<yellow>%s<reset>' is not zoomable.\n",
            pane.name)); return
    end
    pane:zoom()
end

function Mux.swapFocused()
    local pane = Mux._focusedPane
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No focused pane.\n"); return
    end
    local split = pane._split
    if not split then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Pane '<yellow>%s<reset>' is not in a split.\n",
            pane.name)); return
    end
    split:swapSlots()
end

function Mux.closeFocused()
    local pane = Mux._focusedPane
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No focused pane.\n"); return
    end
    pane:_confirmClose()
end

function Mux.floatFocused()
    local pane = Mux._focusedPane
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No focused pane.\n"); return
    end
    if pane.floating then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Pane '<yellow>%s<reset>' is already floating.\n",
            pane.name)); return
    end
    pane:float()
end

function Mux.embedFocused()
    local pane = Mux._focusedPane
    if not pane then
        pane = Mux._lastFocusedPane
        if not pane or not pane.floating then
            for _, p in pairs(Mux._panes) do
                if p.floating then pane = p; break end
            end
        end
    end
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No floating pane to embed.\n"); return
    end
    if pane.overlay then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Pane '<yellow>%s<reset>' cannot be embedded.\n",
            pane.name)); return
    end
    pane:embed()
end

function Mux.toggleTitlebarFocused()
    local pane = Mux._focusedPane
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No focused pane.\n"); return
    end
    if not pane.titlebarHideable then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Pane '<yellow>%s<reset>' titlebar cannot be toggled.\n",
            pane.name)); return
    end
    pane:setTitlebarVisible(not pane.titlebarVisible)
end

function Mux.renameFocused(newName)
    local pane = Mux._focusedPane
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No focused pane.\n"); return
    end
    if not pane.renamable then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Pane '<yellow>%s<reset>' cannot be renamed.\n",
            pane.name)); return
    end
    if not newName or newName == "" then
        Mux._echo("\n<cyan>[Muxlet]<reset> Usage: mux rename <new name>\n")
        return
    end
    pane:setName(newName)
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Pane renamed to '<yellow>%s<reset>'\n", newName))
end


-- Tab operations — all resolve (pane, tab) then delegate to MuxPane methods.

local function focusedPaneForTab(op)
    local pane = Mux._focusedPane
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No focused pane.\n"); return
    end
    if not pane._tabsEnabled then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Pane '<yellow>%s<reset>' has no tabs — enable them first.\n",
            pane.name)); return
    end
    return pane
end

local function activeTab(pane, op)
    if not pane._activeTabId then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Pane '<yellow>%s<reset>' has no active tab.\n",
            pane.name)); return
    end
    return pane:_findTab(pane._activeTabId)
end

function Mux.tabAdd(name)
    local pane = Mux._focusedPane
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No focused pane.\n"); return
    end
    if not pane._tabsEnabled then pane:enableTabs({ noDefaultTab = true }) end
    pane:addTab(name or string.format("Tab %d", #(pane._tabs or {}) + 1))
end

function Mux.tabClose()
    local pane = focusedPaneForTab("tabClose"); if not pane then return end
    local tab  = activeTab(pane, "tabClose");  if not tab  then return end
    pane:removeTab(tab.id)
end

function Mux.tabRename(newName)
    local pane = focusedPaneForTab("tabRename"); if not pane then return end
    local tab  = activeTab(pane, "tabRename");  if not tab  then return end
    if not tab.renamable then
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Tab '<yellow>%s<reset>' cannot be renamed.\n",
            tab.name)); return
    end
    if not newName or newName == "" then
        Mux._showRenameDialog({
            currentName = tab.name,
            title       = "Rename Tab",
            onConfirm   = function(n) pane:renameTab(tab.id, n) end,
        })
        return
    end
    pane:renameTab(tab.id, newName)
    Mux._echo(string.format(
        "\n<green>[Muxlet]<reset> Tab renamed to '<yellow>%s<reset>'\n", newName))
end

function Mux.tabLock()
    local pane = focusedPaneForTab("tabLock"); if not pane then return end
    local tab  = activeTab(pane, "tabLock");  if not tab  then return end
    tab.renamable = false
    tab.closeable = false
    tab.movable   = false
    Mux._echo(string.format(
        "\n<green>[Muxlet]<reset> Tab '<yellow>%s<reset>' locked.\n", tab.name))
end

function Mux.tabUnlock()
    local pane = focusedPaneForTab("tabUnlock"); if not pane then return end
    local tab  = activeTab(pane, "tabUnlock");  if not tab  then return end
    tab.renamable = true
    tab.closeable = true
    tab.movable   = true
    Mux._echo(string.format(
        "\n<green>[Muxlet]<reset> Tab '<yellow>%s<reset>' unlocked.\n", tab.name))
end

function Mux.tabNext()
    local pane = focusedPaneForTab("tabNext"); if not pane then return end
    local tabs = pane._tabs
    if not tabs or #tabs == 0 then return end
    local _, idx = pane:_findTab(pane._activeTabId or "")
    local nextIdx = ((idx or 0) % #tabs) + 1
    pane:activateTab(tabs[nextIdx].id)
end

function Mux.tabPrev()
    local pane = focusedPaneForTab("tabPrev"); if not pane then return end
    local tabs = pane._tabs
    if not tabs or #tabs == 0 then return end
    local _, idx = pane:_findTab(pane._activeTabId or "")
    local prevIdx = ((( idx or 1) - 2) % #tabs) + 1
    pane:activateTab(tabs[prevIdx].id)
end

-- Resize the focused pane's width to a percentage of screen width.
-- Floating panes resize directly; embedded panes in a left/right split adjust their ratio.
function Mux.resizePaneToWidth(pane, pct)
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No pane specified.\n"); return
    end
    pct = tonumber(pct)
    if not pct or pct < 1 or pct > 99 then
        Mux._echo("\n<yellow>[Muxlet]<reset> Width percentage must be between 1 and 99.\n"); return
    end
    local sw = getMainWindowSize()
    local targetPx = math.floor(sw * pct / 100)
    if pane.floating then
        pane.floatW = targetPx
        pane.outer:resize(pane.floatW, pane.floatH)
        pane.outer:reposition()
        Mux._scheduleAutoSave()
        Mux._echo(string.format("\n<green>[Muxlet]<reset> Width set to %d%% (%dpx).\n", pct, targetPx))
    elseif pane._split then
        local split = pane._split
        if split.direction ~= "h" then
            Mux._echo("\n<yellow>[Muxlet]<reset> Pane is in a top/bottom split — use 'height' to resize it.\n"); return
        end
        local handlePx = Mux.activeTheme().handleSize or 3
        local boxW     = split.box:get_width()
        local dynW     = boxW - handlePx
        if dynW <= 0 then
            Mux._echo("\n<yellow>[Muxlet]<reset> Split not yet laid out — try again after startup.\n"); return
        end
        local ratio = Mux._clamp(targetPx / dynW, 0.05, 0.95)
        if pane._slotSide == "b" then ratio = 1 - ratio end
        split:_setRatio(ratio)
        Mux._scheduleAutoSave()
        Mux._echo(string.format("\n<green>[Muxlet]<reset> Width adjusted to ~%d%% (%dpx in %dpx split).\n",
            pct, targetPx, dynW))
    else
        Mux._echo("\n<yellow>[Muxlet]<reset> Pane has no parent split to resize.\n")
    end
end

-- Resize the focused pane's height to a percentage of screen height.
-- Floating panes resize directly; embedded panes in a top/bottom split adjust their ratio.
function Mux.resizePaneToHeight(pane, pct)
    if not pane then
        Mux._echo("\n<yellow>[Muxlet]<reset> No pane specified.\n"); return
    end
    pct = tonumber(pct)
    if not pct or pct < 1 or pct > 99 then
        Mux._echo("\n<yellow>[Muxlet]<reset> Height percentage must be between 1 and 99.\n"); return
    end
    local _, sh = getMainWindowSize()
    local targetPx = math.floor(sh * pct / 100)
    if pane.floating then
        pane.floatH = targetPx
        pane.outer:resize(pane.floatW, pane.floatH)
        pane.outer:reposition()
        Mux._scheduleAutoSave()
        Mux._echo(string.format("\n<green>[Muxlet]<reset> Height set to %d%% (%dpx).\n", pct, targetPx))
    elseif pane._split then
        local split = pane._split
        if split.direction ~= "v" then
            Mux._echo("\n<yellow>[Muxlet]<reset> Pane is in a left/right split — use 'width' to resize it.\n"); return
        end
        local handlePx = Mux.activeTheme().handleSize or 3
        local boxH     = split.box:get_height()
        local dynH     = boxH - handlePx
        if dynH <= 0 then
            Mux._echo("\n<yellow>[Muxlet]<reset> Split not yet laid out — try again after startup.\n"); return
        end
        local ratio = Mux._clamp(targetPx / dynH, 0.05, 0.95)
        if pane._slotSide == "b" then ratio = 1 - ratio end
        split:_setRatio(ratio)
        Mux._scheduleAutoSave()
        Mux._echo(string.format("\n<green>[Muxlet]<reset> Height adjusted to ~%d%% (%dpx in %dpx split).\n",
            pct, targetPx, dynH))
    else
        Mux._echo("\n<yellow>[Muxlet]<reset> Pane has no parent split to resize.\n")
    end
end

-- Creates a free-floating blank pane near the centre of the screen.
function Mux.newFloatingPane(opts)
    local w, h = getMainWindowSize()
    opts = Mux._merge({
        name   = "Pane",
        floatX = math.floor(w * 0.25),
        floatY = math.floor(h * 0.25),
        floatW = math.floor(w * 0.5),
        floatH = math.floor(h * 0.5),
    }, opts or {})
    local p = Mux.newPane(opts)
    p:float()
    Mux.setFocus(p)
    return p
end

function Mux.status()
    local pc, sc, ps = 0, 0, 0
    for _ in pairs(Mux._panes)    do pc = pc + 1 end
    for _ in pairs(Mux._splits)   do sc = sc + 1 end
    for _ in pairs(Mux._paneSets) do ps = ps + 1 end

    Mux._echo("\n<cyan>[Muxlet]<reset> v" .. Mux._version .. "\n")

    if Mux._running then
        local wsDisplay = Mux._activeWorkspaceName or "unknown"
        if wsDisplay == "current" then wsDisplay = "current (auto-restored)" end
        Mux._echo(string.format("  State     : <green>STARTED<reset>  workspace '<cyan>%s<reset>'\n", wsDisplay))
    else
        Mux._echo("  State     : <yellow>STOPPED<reset>  — type <cyan>mux start<reset> to begin\n")
    end

    Mux._echo(string.format("  PaneSets  : %d  Splits: %d  Panes: %d\n", ps, sc, pc))
    local fp = Mux._focusedPane
    Mux._echo(string.format("  Focused   : %s\n", fp and fp.name or "(none)"))
    Mux._echo(string.format("  Debug     : %s\n", tostring(Mux.debug)))
end

function Mux.setDebug(on)
    local value = on and true or false
    -- Route through settings so the choice persists across sessions.
    if Mux.settings and Mux.settings.set then
        Mux.settings.set("mux", "debug", value)
    else
        Mux.debug = value
    end
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Debug %s\n",
        Mux.debug and "ON" or "OFF"))
end

-- All Muxlet output goes to the main Mudlet console.
function Mux._echo(text)
    cecho(text)
end

-- Destroys all current panes/splits/panesets and resets borders without
-- killing persistent event handlers or the command console pane.
function Mux._clearWorkspace()
    -- Cancel any pending auto-save so it doesn't write an empty/transitional state.
    if Mux._autoSaveTimer then
        killTimer(Mux._autoSaveTimer)
        Mux._autoSaveTimer = nil
    end
    if Mux._outputCapture then
        killTrigger(Mux._outputCapture)
        Mux._outputCapture = nil
        Mux._outputConsole = nil
    end
    Mux._closeContextMenu()
    -- Close any open properties dialogs so content refs are properly released.
    for _, pane in pairs(Mux._panes) do
        if pane._propertiesDialogs then
            for _, dlg in pairs(pane._propertiesDialogs) do
                pcall(function() dlg:close() end)
            end
            pane._propertiesDialogs = nil
        end
    end
    for _, ps in pairs(Mux._paneSets) do
        if ps.destroy then ps:destroy() end
    end
    -- Floating panes are reparented to the Geyser root and are not owned by any
    -- PaneSet, so ps:destroy() misses them. Hide them explicitly before the wipe.
    for _, pane in pairs(Mux._panes) do
        if pane.floating and pane.outer then pane.outer:hide() end
    end
    -- Preserve the settings UI pane across registry wipes.
    local savedSet = Mux._settings_ui and Mux._settings_ui.window or nil
    Mux._panes    = {}
    Mux._splits   = {}
    Mux._paneSets = {}
    Mux._connAware = {}
    if Mux._settings_ui then Mux._settings_ui.window = savedSet end
    Mux._focusedPane = nil
    -- Reset user-facing ID pools so new workspaces start numbering from 1.
    -- _internalSeq is intentionally NOT reset to keep Geyser widget names unique.
    for _, prefix in ipairs({"pane", "split", "ps"}) do
        Mux._idCounters[prefix] = 0
        Mux._idFree[prefix]     = {}
    end
    Mux._borders = { top = 0, right = 0, bottom = 0, left = 0 }
    Mux._applyBorders()
    Mux._log("_clearWorkspace: cleared")
end

-- Creates a MiniConsole inside the named pane's content area and installs a
-- catch-all trigger that appends every game output line to it.
Mux._outputCapture = nil    -- tempTrigger ID
Mux._outputConsole = nil    -- Geyser.MiniConsole name (string)

function Mux.setupOutputCapture(paneId)
    paneId = paneId or "output"
    local pane = Mux._panes[paneId]
    if not pane then
        Mux._err("setupOutputCapture: pane '%s' not found", paneId)
        return
    end

    if Mux._outputCapture then
        killTrigger(Mux._outputCapture)
        Mux._outputCapture = nil
    end

    local conName = "mux_output_" .. paneId

    if not Geyser.windowList[conName] then
        Geyser.MiniConsole:new({
            name      = conName,
            x = "0%", y = "0%", width = "100%", height = "100%",
            fontSize  = 12, color = "black",
            scrollBar = true, autoWrap = true,
        }, pane.content)
    end
    Mux._outputConsole = conName

    -- appendBuffer preserves ANSI colour; echo adds the required trailing newline.
    Mux._outputCapture = tempTrigger(".*", function()
        selectCurrentLine()
        appendBuffer(conName)
        echo(conName, "\n")
    end)

    Mux._echo(string.format(
        "\n<green>[Muxlet]<reset> Game output → pane '%s' (console: %s)\n",
        paneId, conName))
end

-- fullStop  — destroys all visible widgets, kills the resize handler, reloads
--             settings from disk so theme and debug flag are fresh.
-- fullStart — re-registers the resize handler, applies saved theme, restores
--             the session workspace ("current") or "default" on first run.

function Mux.fullStop()
    if Mux._resizeHandler then
        killAnonymousEventHandler(Mux._resizeHandler)
        Mux._resizeHandler = nil
    end
    -- Hide and release the settings window. buildWindow() creates a fresh one
    -- on the next toggle(), so we just abandon the old one.
    -- Must happen BEFORE _clearWorkspace so the savedSet guard inside it sees nil.
    if Mux._settings_ui and Mux._settings_ui.window then
        Mux._settings_ui.window:hide()
        Mux._settings_ui.window     = nil
        Mux._settings_ui.visible    = false
        Mux._settings_ui.currentTab = nil
    end

    Mux._closeContextMenu()
    Mux._clearWorkspace()
    setBorderSizes(0, 0, 0, 0)

    Mux._lastFocusedPane = nil

    Mux.settings.load()

    Mux._running = false
    Mux._echo("\n<yellow>[Muxlet]<reset> Stopped. Run <cyan>mux start<reset> to reinitialize.\n")
end

function Mux.fullStart()
    if Mux._running then
        Mux._echo("\n<yellow>[Muxlet]<reset> Already running. Use <cyan>mux stop<reset> first.\n")
        return
    end

    Mux._registerResizeHandler()

    local savedTheme = Mux.settings.get("mux", "theme")
    if savedTheme and savedTheme ~= "" and Mux.applyTheme then
        Mux.applyTheme(savedTheme)
    end
    Mux.debug = Mux.settings.get("mux", "debug") or false

    -- Restore the most recent auto-saved session; fall back to the built-in default.
    local wsName = Mux._workspaces["current"] and "current" or "default"

    if not Mux._workspaces[wsName] then
        Mux._echo("\n<red>[Muxlet]<reset> No workspace found. Use 'mux workspaces' to list available.\n")
        return
    end

    Mux.applyWorkspace(wsName)
    Mux._running = true
    tempTimer(2, function()
        Mux._echo("\n<cyan>[Muxlet]<reset> Started — type <cyan>mux help<reset> for commands.\n")
    end)
    raiseEvent("muxletStarted")
end


-- Resets borders when the package is uninstalled so the main console is fully visible.
if not Mux._unloadHandler then
    Mux._unloadHandler = registerAnonymousEventHandler(
        "sysUninstallPackage",
        function(_, pkg)
            if pkg ~= "Muxlet" then return end
            setBorderSizes(0, 0, 0, 0)
        end
    )
end

-- All non-floating panes sorted by creation order (ID alphabetically).
function orderedPanes()
    local list = {}
    for _, p in pairs(Mux._panes) do
        if not p.floating then list[#list+1] = p end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function focusIndex(ordered)
    local fp = Mux._focusedPane
    if not fp then return 0 end
    for i, p in ipairs(ordered) do
        if p == fp then return i end
    end
    return 0
end

-- Focus the first pane found within a split slot (depth-first).
function focusSlotFirstPane(split, side)
    local child = (side == "a") and split.childA or split.childB
    if not child then return end
    if child.outer then
        Mux.setFocus(child)
    elseif child.box then
        focusSlotFirstPane(child, "a")
    end
end

Mux._log("v%s loaded", Mux._version)
