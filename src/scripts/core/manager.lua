-- Muxlet — Manager
--
-- Top-level API consumed by end-users and keybind handlers.
-- All pane/split/paneset creation, focus management, and action verbs live here.

-- ── Pane factory ──────────────────────────────────────────────────────────────

function Mux.newPane(opts)      return MuxPane:new(opts)    end
function Mux.newSplit(opts, a, b)
    local s = MuxSplit:new(opts)
    if a then s:place(a, "a") end
    if b then s:place(b, "b") end
    return s
end
function Mux.newPaneSet(opts)  return MuxPaneSet:new(opts) end

-- ── Lookup ────────────────────────────────────────────────────────────────────

function Mux.getPane(id)     return Mux._panes[id]     end
function Mux.getSplit(id)    return Mux._splits[id]    end
function Mux.getPaneSet(id)  return Mux._paneSets[id]  end
function Mux.currentTheme()  return Mux._activeThemeName end

-- ── Focus management ─────────────────────────────────────────────────────────
-- Mux._focusedPane tracks the "current" pane for all keybind actions.
-- Calling setFocus() visually highlights the pane's border.

Mux._focusedPane = nil

function Mux.setFocus(pane)
    -- Permanent floats (settings, etc.) don't participate in the focus system.
    -- They never get the blue border, never displace the workspace focus, and never
    -- appear in split/zoom/close keybind operations.  Just raise them visually.
    if pane and pane.permanentFloat then
        if pane.floating then pane:raise() end
        return
    end
    -- Clear highlight on the previously focused pane.
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
    -- Apply focus highlight; locked panes keep their base (unfocused) appearance.
    if not pane.locked and pane._setFrameCss and pane._focusedFrameCss then
        pane:_setFrameCss(pane:_focusedFrameCss())
    end
    Mux._log("Focus → %s", pane.id)
end

-- Raise every floating pane above all embedded panes.
function Mux.raiseFloatingPanes()
    for _, pane in pairs(Mux._panes) do
        if pane.floating then pane:raise() end
    end
end

-- Focus next/previous pane in creation order (cycles through all non-floating panes).
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

-- Directional focus: find the pane adjacent in the given direction within the
-- focused pane's parent split.  Falls back to focusNext/Prev when no split.
-- direction: "left" | "right" | "up" | "down"
function Mux.focusAdjacent(direction)
    local pane = Mux._focusedPane
    if not pane then Mux.focusNext(); return end

    local split = pane._split
    if not split then Mux.focusNext(); return end

    local side = pane._slotSide
    local dir  = split.direction   -- "v" = top/bottom, "h" = left/right

    -- Determine if this split axis matches the navigation direction
    local cross =
        (direction == "left"  and dir == "h" and side == "b") or
        (direction == "right" and dir == "h" and side == "a") or
        (direction == "up"    and dir == "v" and side == "b") or
        (direction == "down"  and dir == "v" and side == "a")

    if cross then
        local targetSide = (side == "a") and "b" or "a"
        focusSlotFirstPane(split, targetSide)
    else
        -- No match in immediate parent; cycle through all panes instead
        if direction == "left" or direction == "up" then
            Mux.focusPrev()
        else
            Mux.focusNext()
        end
    end
end

-- ── Split the focused pane ────────────────────────────────────────────────────
-- direction: "v" (top/bottom) or "h" (left/right)
-- ratio: split point, default 0.5
-- Returns the new MuxSplit, or nil on failure.

function Mux.splitFocused(direction, ratio)
    local pane = Mux._focusedPane
    if not pane then Mux._warn("splitFocused: no focused pane"); return nil end
    if pane.floating then
        Mux._warn("splitFocused: cannot split a floating pane — embed it first")
        return nil
    end

    direction = direction or "v"
    if not ratio then
        local pct = Mux.settings and Mux.settings.get("mux", "default_split_ratio")
        ratio = pct and (pct / 100) or 0.5
    end

    if pane._split then
        -- Pane is inside a split — subdivide its slot.
        local newSplit = pane._split:_splitPaneInSlot(pane, direction, ratio)
        if newSplit then
            -- Focus the new blank pane that opened.
            tempTimer(0, function()
                if newSplit.childB then Mux.setFocus(newSplit.childB) end
                Mux.raiseFloatingPanes()
                Mux._scheduleAutoSave()
            end)
        end
        return newSplit
    else
        -- Pane is the direct root of a PaneSet.
        local ps = pane._paneSet
        if not ps then
            Mux._warn("splitFocused: pane '%s' has no PaneSet reference", pane.id)
            return nil
        end
        -- Wrap in a new split that fills the PaneSet's outer container.
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
        -- Organize the new split so VBox/HBox lays out slot sizes immediately.
        newSplit.box:organize()
        newSplit.box:reposition()
        -- Sync main console borders now that pane geometry has changed.
        for _, p in pairs(Mux._panes) do
            if p.mainConsoleHost then p:updateConsoleBorders() end
        end
        tempTimer(0, function()
            Mux.setFocus(newPane)
            Mux.raiseFloatingPanes()
            Mux._scheduleAutoSave()
        end)
        return newSplit
    end
end

-- ── Zoom the focused pane ─────────────────────────────────────────────────────
-- Expands the focused pane to fill its split (hides sibling + handle).
-- Calling again restores the split.

function Mux.zoomFocused()
    local pane = Mux._focusedPane
    if not pane then Mux._warn("zoomFocused: no focused pane"); return end

    local split = pane._split
    if not split then Mux._warn("zoomFocused: pane '%s' is not in a split", pane.id); return end

    split:zoom(pane._slotSide)
end

-- ── Swap focused pane with its sibling ───────────────────────────────────────

function Mux.swapFocused()
    local pane = Mux._focusedPane
    if not pane then Mux._warn("swapFocused: no focused pane"); return end
    local split = pane._split
    if not split then Mux._warn("swapFocused: pane '%s' is not in a split", pane.id); return end
    split:swapSlots()
end

-- ── Close the focused pane ────────────────────────────────────────────────────

function Mux.closeFocused()
    local pane = Mux._focusedPane
    if not pane then Mux._warn("closeFocused: no focused pane"); return end
    -- Shift focus before destroying
    Mux._focusedPane = nil
    pane:close()
    Mux.focusNext()
end

-- ── Float / embed the focused pane ───────────────────────────────────────────

function Mux.floatFocused()
    local pane = Mux._focusedPane
    if not pane then return end
    if not pane.floating then pane:float() end
end

function Mux.embedFocused()
    local pane = Mux._focusedPane
    if not pane then
        -- Try last floating pane
        pane = Mux._lastFocusedPane
        if not pane or not pane.floating then
            for _, p in pairs(Mux._panes) do
                if p.floating then pane = p; break end
            end
        end
    end
    if pane and pane.floating and not pane.permanentFloat then pane:embed() end
end

-- ── Lock / unlock the focused pane ───────────────────────────────────────────

function Mux.lockFocused()
    local pane = Mux._focusedPane
    if not pane then Mux._warn("lockFocused: no focused pane"); return end
    pane:lock()
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Pane '<yellow>%s<reset>' locked.\n", pane.name))
end

function Mux.unlockFocused()
    local pane = Mux._focusedPane
    if not pane then Mux._warn("unlockFocused: no focused pane"); return end
    pane:unlock()
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Pane '<yellow>%s<reset>' unlocked.\n", pane.name))
end

-- ── Toggle titlebar on focused pane ──────────────────────────────────────────

function Mux.toggleTitlebarFocused()
    local pane = Mux._focusedPane
    if not pane then return end
    pane:setTitlebarVisible(not pane.titlebarVisible)
end

-- ── Rename focused pane ───────────────────────────────────────────────────────

function Mux.renameFocused(newName)
    local pane = Mux._focusedPane
    if not pane then Mux._warn("renameFocused: no focused pane"); return end
    if pane.noRename then Mux._warn("renameFocused: pane '%s' cannot be renamed", pane.name); return end
    if not newName or newName == "" then
        Mux._echo("\n<cyan>[Muxlet]<reset> Usage: mux rename <new name>\n")
        return
    end
    pane:setName(newName)
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Pane renamed to '%s'\n", newName))
end

-- ── Rename a pane via command-line prompt ────────────────────────────────────
-- Installs a one-shot temp alias "!mux_r <name>", pre-fills the command input,
-- and cleans up the alias once the user submits or on next open.

function Mux._promptRename(pane)
    if pane.noRename then return end
    Mux.setFocus(pane)
    Mux._showRenameDialog({
        currentName = pane.name,
        title       = "Rename Pane",
        onConfirm   = function(newName)
            pane:setName(newName)
            Mux._echo(string.format(
                "\n<green>[Muxlet]<reset> Pane renamed to '<yellow>%s<reset>'\n", newName))
        end,
    })
end

-- ── Tab operations on the active pane / active tab ───────────────────────────
-- All helpers resolve (pane, tab) then delegate to MuxPane methods.

local function focusedPaneForTab(op)
    local pane = Mux._focusedPane
    if not pane then Mux._warn("%s: no focused pane", op); return end
    if not pane._tabsEnabled then
        Mux._warn("%s: focused pane '%s' has no tabs", op, pane.name); return
    end
    return pane
end

local function activeTab(pane, op)
    if not pane._activeTabId then
        Mux._warn("%s: pane '%s' has no active tab", op, pane.name); return
    end
    return pane:_findTab(pane._activeTabId)
end

function Mux.tabAdd(name)
    local pane = Mux._focusedPane
    if not pane then Mux._warn("tabAdd: no focused pane"); return end
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
    tab.locked = true
    Mux._echo(string.format(
        "\n<green>[Muxlet]<reset> Tab '<yellow>%s<reset>' locked.\n", tab.name))
end

function Mux.tabUnlock()
    local pane = focusedPaneForTab("tabUnlock"); if not pane then return end
    local tab  = activeTab(pane, "tabUnlock");  if not tab  then return end
    tab.locked = false
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

-- ── New blank pane (floating) ─────────────────────────────────────────────────
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

-- ── Status ────────────────────────────────────────────────────────────────────

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

-- ── Debug toggle ─────────────────────────────────────────────────────────────

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

-- ── Output routing ────────────────────────────────────────────────────────────
-- All Muxlet output goes to the main Mudlet console.

function Mux._echo(text)
    cecho(text)
end

-- ── Workspace clear (called before every applyWorkspace) ─────────────────────
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
    for _, ps in pairs(Mux._paneSets) do
        if ps.destroy then ps:destroy() end
    end
    -- Floating panes are reparented to the Geyser root and are not owned by any
    -- PaneSet, so ps:destroy() misses them.  Hide them explicitly before the wipe.
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
    -- Reset user-facing ID pools so new workspaces start numbering from 1 again.
    -- _internalSeq is intentionally NOT reset to keep Geyser names unique.
    for _, prefix in ipairs({"pane", "split", "ps"}) do
        Mux._idCounters[prefix] = 0
        Mux._idFree[prefix]     = {}
    end
    Mux._borders = { top = 0, right = 0, bottom = 0, left = 0 }
    Mux._applyBorders()
    Mux._log("_clearWorkspace: cleared")
end

-- ── Output capture (fullscreen) ───────────────────────────────────────────────
-- Creates a MiniConsole inside the named pane's content area and installs a
-- catch-all trigger that appends every game output line to it.
-- Called automatically by `mux fullscreen`; call again to retarget a different pane.

Mux._outputCapture = nil    -- tempTrigger ID
Mux._outputConsole = nil    -- Geyser.MiniConsole name (string)

function Mux.setupOutputCapture(paneId)
    paneId = paneId or "output"
    local pane = Mux._panes[paneId]
    if not pane then
        Mux._warn("setupOutputCapture: pane '%s' not found", paneId)
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

    -- Catch-all trigger: mirror every game line to the output MiniConsole.
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

-- ── Full stop / full start ────────────────────────────────────────────────────
-- Equivalent to closing and reopening the profile:
--   fullStop  — destroys all visible widgets, kills the resize handler, reloads
--               settings from disk so theme, debug, etc. are fresh.
--   fullStart — re-registers the resize handler, applies saved theme, restores
--               the current session workspace (or 'default' on first run).

function Mux.fullStop()
    -- Kill the resize handler; fullStart() will re-register it.
    if Mux._resizeHandler then
        killAnonymousEventHandler(Mux._resizeHandler)
        Mux._resizeHandler = nil
    end
    if Mux._keybindHandler then
        killAnonymousEventHandler(Mux._keybindHandler)
        Mux._keybindHandler = nil
    end

    -- Hide and release the settings window.  buildWindow() creates a fresh one
    -- the next time Mux.settings.toggle() is called, so we just abandon the old one.
    -- This must happen BEFORE _clearWorkspace so the savedSet guard inside _clearWorkspace
    -- sees nil and does not re-save the stale reference.
    if Mux._settings_ui and Mux._settings_ui.window then
        Mux._settings_ui.window:hide()
        Mux._settings_ui.window     = nil
        Mux._settings_ui.visible    = false
        Mux._settings_ui.content    = nil
        Mux._settings_ui.contentBox = nil
        Mux._settings_ui.tabs       = {}
        Mux._settings_ui.rows       = {}
        Mux._settings_ui.dropdown   = nil
        Mux._settings_ui.tooltip    = nil
        Mux._settings_ui.currentTab = nil
        Mux._settings_ui.drawEpoch  = (Mux._settings_ui.drawEpoch or 0) + 1
    end

    -- Hide the keybind hint overlay (widget stays in Qt pool, gets reused).
    if Mux._hintLabel then Mux._hintLabel:hide() end
    if Mux._hintTimerId then killTimer(Mux._hintTimerId); Mux._hintTimerId = nil end

    -- Close the context menu (hides backdrop, panel, all row labels).
    Mux._closeContextMenu()

    -- Destroy all panes, splits, paneSets, and reset borders.
    Mux._clearWorkspace()
    setBorderSizes(0, 0, 0, 0)

    -- Clear any stale last-focused reference surviving _clearWorkspace.
    Mux._lastFocusedPane = nil

    -- Reload settings from disk so theme, debug, etc. reflect the
    -- last saved state (including any edits made while Muxlet was running).
    Mux.settings.load()

    Mux._running = false
    Mux._echo("\n<yellow>[Muxlet]<reset> Stopped. Run <cyan>mux start<reset> to reinitialize.\n")
end

function Mux.fullStart()
    if Mux._running then
        Mux._echo("\n<yellow>[Muxlet]<reset> Already running. Use <cyan>mux stop<reset> first.\n")
        return
    end

    -- Re-register the resize handler (killed by fullStop, no-op if already live).
    Mux._registerResizeHandler()

    -- Apply saved theme and debug flag, same as settings.lua's tempTimer(0) on load.
    local savedTheme = Mux.settings.get("mux", "theme")
    if savedTheme and savedTheme ~= "" and Mux.applyTheme then
        Mux.applyTheme(savedTheme)
    end
    Mux.debug = Mux.settings.get("mux", "debug") or false

    -- Startup priority: current (auto-restored session) → default.
    -- "current" is written by _doAutoSave() on every structural change.
    local wsName = Mux._workspaces["current"] and "current" or "default"

    if not Mux._workspaces[wsName] then
        Mux._echo("\n<red>[Muxlet]<reset> No workspace found. Use 'mux workspaces' to list available.\n")
        return
    end

    Mux.applyWorkspace(wsName)
    Mux._running = true
    local displayName = (wsName == "current") and "current (restored)" or wsName
    Mux._echo(string.format(
        "\n<green>[Muxlet]<reset> Started with workspace '<cyan>%s<reset>'.\n"
        .. "  Alt+\\ / Alt+- to split  •  Alt+Z to zoom  •  Alt+B for help\n",
        displayName))
end

-- ── Teardown ──────────────────────────────────────────────────────────────────

function Mux.teardown()
    -- fullStop handles everything; skip the settings reload since we're uninstalling.
    if Mux._resizeHandler then
        killAnonymousEventHandler(Mux._resizeHandler)
        Mux._resizeHandler = nil
    end
    if Mux._keybindHandler then
        killAnonymousEventHandler(Mux._keybindHandler)
        Mux._keybindHandler = nil
    end
    Mux._clearWorkspace()
    setBorderSizes(0, 0, 0, 0)
    cecho("\n<yellow>[Muxlet]<reset> Torn down. Main console restored.\n")
end

-- ── Package unload handler ────────────────────────────────────────────────────
-- Fires when the package is uninstalled or Mudlet closes.
-- Resets borders so the main console is fully visible after removal.
if not Mux._unloadHandler then
    Mux._unloadHandler = registerAnonymousEventHandler(
        "sysUninstallPackage",
        function(_, pkg)
            if pkg ~= "Muxlet" then return end
            setBorderSizes(0, 0, 0, 0)
        end
    )
end

-- ── Internal helpers ──────────────────────────────────────────────────────────

-- Return all non-floating panes sorted by creation order (ID alphabetically).
function orderedPanes()
    local list = {}
    for _, p in pairs(Mux._panes) do
        if not p.floating then list[#list+1] = p end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- Return the index of the focused pane within ordered list (or 0).
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
        -- It's a MuxPane
        Mux.setFocus(child)
    elseif child.box then
        -- It's a nested MuxSplit — recurse into slotA
        focusSlotFirstPane(child, "a")
    end
end

cecho("\n<green>[Muxlet]<reset> v" .. Mux._version .. " loaded.\n")
