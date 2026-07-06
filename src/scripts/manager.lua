-- Muxlet manager — public API for pane creation, focus, and workspace operations.

function Mux.newPane(opts)      return MuxPane:new(opts)    end
function Mux.newPaneSpace(opts)  return MuxPaneSpace:new(opts) end

function Mux.getPane(id)     return Mux._panes[id]     end
function Mux.getPaneSpace(id)  return Mux._paneSpaces[id]  end
function Mux.currentTheme()  return Mux._activeThemeName end

-- Brings a floating pane or dialog to the front of the z-order. Embedded panes
-- never overlap, so this is a no-op for them. There is no "focused" pane concept:
-- panes are styled by their resting frame (grey panes, gold dialogs) and edited
-- directly from the UI.
function Mux.raisePane(pane)
    if pane and pane.floating then
        Mux._raiseSeq = (Mux._raiseSeq or 0) + 1
        pane._raiseSeq = Mux._raiseSeq
        pane:raise()
    end
end

function Mux.raiseFloatingPanes()
    -- Raise non-dialog floats first, then dialogs, so dialog overlays (incl.
    -- close confirmations) always sit above ordinary floats and a zoomed pane.
    -- Within each group, raise in ascending _raiseSeq order so the most recently
    -- created/activated window ends up on top. (Iterating Mux._panes with pairs()
    -- has no defined order, which is why a newly opened dialog could otherwise land
    -- beneath an older one.)
    local floats, dialogs = {}, {}
    for _, pane in pairs(Mux._panes) do
        if pane.floating then
            if pane.overlay then dialogs[#dialogs + 1] = pane
            else                 floats[#floats + 1]   = pane end
        end
    end
    local function bySeq(a, b) return (a._raiseSeq or 0) < (b._raiseSeq or 0) end
    table.sort(floats,  bySeq)
    table.sort(dialogs, bySeq)
    for _, p in ipairs(floats)  do p:raise() end
    for _, p in ipairs(dialogs) do p:raise() end
end

-- Called after a zoom so that popup dialogs remain above the zoomed pane.
function Mux._raiseFreeFloatingPanes()
    for _, pane in pairs(Mux._panes) do
        if pane.floating and not pane.overlay then
            pane:raise()
        end
    end
end



-- Zoom the focused pane to full screen (requires pane.zoomable = true).
-- Calling again while zoomed restores the pane to its previous state.

-- ── Recovery: inspect & reveal ────────────────────────────────────────────────
--
-- Hiding a pane's titlebar or its Properties affordance is done from the UI, but
-- once both are hidden there is no on-screen way back. These three give a power
-- user a way to recover any workspace without editing Lua or resetting, while
-- staying obscure enough that a casual user won't stumble into them:
--   Mux.listPanespace()   — enumerate every pane/tab with id + hidden state
--   Mux.revealUI(id)      — restore titlebar + Properties on one pane/tab
--   Mux.revealUI("all")   — restore across the whole workspace (explicit)
-- A hidden titlebar means you can't read an id off the screen, so the lister is
-- the way you learn the id to target.

-- Recursively searches a list of tabs (and each tab's own nested sub-tabs, both
-- visible and condition-hidden) for a given id.
local function _findTabRecursive(tabs, id)
    if not tabs then return nil end
    for _, t in ipairs(tabs) do
        if t.id == id then return t end
        local found = _findTabRecursive(t._tabs, id) or _findTabRecursive(t._hiddenTabs, id)
        if found then return found end
    end
    return nil
end

-- Finds any pane or tab (visible or condition-hidden, see MuxTab:_conditionHide
-- in tabs.lua) in the workspace by id. Returns (obj, "pane"|"tab") or nil.
-- Public so consumers outside this file (e.g. the Button Grid's target picker,
-- contentLibrary/buttons.lua) can resolve a persisted target id back to a
-- live object without duplicating the pane/tab tree walk.
function Mux.findTarget(id)
    if not id then return nil end
    local p = Mux._panes[id]
    if p and not p._dialog then return p, "pane" end
    for _, pane in pairs(Mux._panes) do
        if not pane._dialog then
            local t = _findTabRecursive(pane._tabs, id) or _findTabRecursive(pane._hiddenTabs, id)
            if t then return t, "tab" end
        end
    end
    return nil
end

-- Every non-dialog pane and tab (including condition-hidden tabs) as flat,
-- pickable entries — the source list for any "choose a pane/tab" UI.
function Mux.listTargets()
    local out = {}
    local function addTab(t, hidden)
        out[#out+1] = { id = t.id, name = t.name, path = Mux._targetPath(t), kind = "tab", hidden = hidden }
        for _, sub in ipairs(t._tabs or {})       do addTab(sub, false) end
        for _, sub in ipairs(t._hiddenTabs or {}) do addTab(sub, true)  end
    end
    for _, p in pairs(Mux._panes) do
        if not p._dialog then
            out[#out+1] = { id = p.id, name = p.name, path = Mux._targetPath(p), kind = "pane" }
            for _, t in ipairs(p._tabs or {})       do addTab(t, false) end
            for _, t in ipairs(p._hiddenTabs or {}) do addTab(t, true)  end
        end
    end
    table.sort(out, function(a, b) return (a.path or ""):lower() < (b.path or ""):lower() end)
    return out
end

-- Finds a workspace pane or tab by id. Returns (pane) or (tab, hostPane), or nil.
local function _findByIdForReveal(id)
    local obj, kind = Mux.findTarget(id)
    if kind == "pane" then return obj end
    if kind == "tab"  then return obj, obj.pane end
    return nil
end

-- Restores titlebar + Properties affordance on a single pane.
local function _revealPane(p)
    p.propertiesButton = true
    if p.titlebarHideable and not p.titlebarVisible then
        p:setTitlebarVisible(true)
    end
    if p._applyTitlebarVisibility then p:_applyTitlebarVisibility() end
    if Mux._revealContent then Mux._revealContent(p) end
end

function Mux.listPanespace()
    Mux._echo("\n<cyan>[Muxlet]<reset> Panespace:\n")
    local any = false
    for _, p in pairs(Mux._panes) do
        if not p._dialog then
            any = true
            local flags = {}
            if not p.titlebarVisible       then flags[#flags+1] = "<red>titlebar hidden<reset>" end
            if p.propertiesButton == false then flags[#flags+1] = "<red>props hidden<reset>"    end
            if p.locked                    then flags[#flags+1] = "locked"   end
            if p.floating                  then flags[#flags+1] = "floating" end
            if p.mainConsoleHost           then flags[#flags+1] = "main console" end
            local tag = (#flags > 0) and ("  [" .. table.concat(flags, ", ") .. "]") or ""
            Mux._echo(string.format("  <white>%s<reset>  \"%s\"%s\n", p.id, p.name or "", tag))
            if p._tabs then
                for _, t in ipairs(p._tabs) do
                    local tf = {}
                    if t.propertiesButton == false then tf[#tf+1] = "<red>props hidden<reset>" end
                    if t.locked                    then tf[#tf+1] = "locked" end
                    local ttag = (#tf > 0) and ("  [" .. table.concat(tf, ", ") .. "]") or ""
                    Mux._echo(string.format("      <grey>tab<reset> <white>%s<reset>  \"%s\"%s\n",
                        t.id, t.name or "", ttag))
                end
            end
            if p._hiddenTabs then
                for _, t in ipairs(p._hiddenTabs) do
                    Mux._echo(string.format("      <grey>tab<reset> <white>%s<reset>  \"%s\"  [<yellow>condition-hidden<reset>]\n",
                        t.id, t.name or ""))
                end
            end
        end
    end
    if not any then Mux._echo("  (no panes)\n") end
    Mux._echo("\n  Reveal hidden controls with <cyan>mux reveal <id><reset>"
           .. " or <cyan>mux reveal all<reset>.\n")
end

function Mux.revealUI(id)
    if not id or id == "" then
        -- Non-destructive: show what's hidden and how to target it.
        Mux.listPanespace()
        return
    end

    if id:lower() == "all" then
        local n = 0
        for _, p in pairs(Mux._panes) do
            if not p._dialog then
                _revealPane(p)
                if p._tabs then
                    for _, t in ipairs(p._tabs) do
                        t.propertiesButton = true
                        if Mux._revealContent then Mux._revealContent(t) end
                    end
                end
                n = n + 1
            end
        end
        Mux.raiseFloatingPanes()
        Mux._echo(string.format(
            "\n<green>[Muxlet]<reset> Revealed controls on all %d pane(s); floating panes raised.\n", n))
        return
    end

    local target, host = _findByIdForReveal(id)
    if not target then
        Mux._echo(string.format(
            "\n<red>[Muxlet]<reset> No pane or tab '<cyan>%s<reset>'. "
            .. "Use <cyan>mux panes<reset> to list ids.\n", id))
        return
    end

    if host then
        -- target is a tab; restore its Properties affordance (and ensure the host
        -- pane's titlebar is reachable so the tab is operable).
        target.propertiesButton = true
        if Mux._revealContent then Mux._revealContent(target) end
        _revealPane(host)
        Mux.raiseFloatingPanes()
        Mux._echo(string.format(
            "\n<green>[Muxlet]<reset> Revealed controls on tab '<white>%s<reset>'.\n", id))
    else
        _revealPane(target)
        Mux.raiseFloatingPanes()
        Mux._echo(string.format(
            "\n<green>[Muxlet]<reset> Revealed controls on pane '<white>%s<reset>'%s.\n",
            id, target.floating and "; pane raised" or ""))
    end
end


-- Finds the nearest ancestor split (including the pane's immediate split) whose
-- orientation matches `direction` ("h" = side-by-side, controls width; "v" =
-- top/bottom, controls height). Returns (split, side) where `side` is which
-- slot ("a"/"b") the pane's subtree occupies in that split, or nil if none.
function Mux._ancestorSplitOfDirection(pane, direction)
    local split = pane._split
    local side  = pane._slotSide
    while split do
        if split.direction == direction then return split, side end
        side  = split._parentSide
        split = split._parentSplit
    end
    return nil
end

-- Adjusts `split`'s ratio so the pane-side measures ~targetPx along `dim`
-- ("width"/"height"). Used by both resize functions.
local function _setSplitForPx(split, side, targetPx, dim)
    local handlePx = Mux.activeTheme().handleSize or 3
    local box      = (dim == "width") and split.box:get_width() or split.box:get_height()
    local dyn      = box - handlePx
    if dyn <= 0 then return false end
    local ratio = Mux._clamp(targetPx / dyn, 0.05, 0.95)
    if side == "b" then ratio = 1 - ratio end
    split:_setRatio(ratio)
    return true
end

-- Resize a pane's width to a percentage of screen width. Floating panes resize
-- directly; embedded panes adjust the nearest side-by-side split above them
-- (which may be an ancestor, resizing the whole sub-tree).
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
        if Mux._relayoutContent then Mux._relayoutContent(pane) end
        Mux._scheduleAutoSave()
        Mux._echo(string.format("\n<green>[Muxlet]<reset> Width set to %d%% (%dpx).\n", pct, targetPx))
        return
    end
    local split, side = Mux._ancestorSplitOfDirection(pane, "h")
    if not split then
        Mux._echo("\n<yellow>[Muxlet]<reset> This pane spans the full width — nothing to its left or right to resize against.\n")
        return
    end
    if not _setSplitForPx(split, side, targetPx, "width") then
        Mux._echo("\n<yellow>[Muxlet]<reset> Split not yet laid out — try again after startup.\n"); return
    end
    Mux._scheduleAutoSave()
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Width set to ~%d%% of screen.\n", pct))
end

-- Resize a pane's height to a percentage of screen height. Floating panes resize
-- directly; embedded panes adjust the nearest top/bottom split above them (which
-- may be an ancestor, resizing the whole sub-tree the pane belongs to).
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
        if Mux._relayoutContent then Mux._relayoutContent(pane) end
        Mux._scheduleAutoSave()
        Mux._echo(string.format("\n<green>[Muxlet]<reset> Height set to %d%% (%dpx).\n", pct, targetPx))
        return
    end
    local split, side = Mux._ancestorSplitOfDirection(pane, "v")
    if not split then
        Mux._echo("\n<yellow>[Muxlet]<reset> This pane spans the full height — nothing above or below to resize against.\n")
        return
    end
    if not _setSplitForPx(split, side, targetPx, "height") then
        Mux._echo("\n<yellow>[Muxlet]<reset> Split not yet laid out — try again after startup.\n"); return
    end
    Mux._scheduleAutoSave()
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Height set to ~%d%% of screen.\n", pct))
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
    -- float() captures self.outer's current geometry as the float geometry
    -- (right for converting an already-embedded pane) — build outer at the
    -- requested float geometry up front so that capture is a no-op here.
    opts.x, opts.y, opts.width, opts.height = opts.floatX, opts.floatY, opts.floatW, opts.floatH
    local p = Mux.newPane(opts)
    p:float()
    Mux.raisePane(p)
    return p
end

function Mux.status()
    local pc, sc, ps = 0, 0, 0
    for _ in pairs(Mux._panes)    do pc = pc + 1 end
    for _ in pairs(Mux._splits)   do sc = sc + 1 end
    for _ in pairs(Mux._paneSpaces) do ps = ps + 1 end

    Mux._echo("\n<cyan>[Muxlet]<reset> v" .. Mux._version .. "\n")

    if Mux._running then
        local wsDisplay = Mux._activeWorkspaceName or "unknown"
        if wsDisplay == "current" then wsDisplay = "current (auto-restored)" end
        Mux._echo(string.format("  State     : <green>STARTED<reset>  workspace '<cyan>%s<reset>'\n", wsDisplay))
    else
        Mux._echo("  State     : <yellow>STOPPED<reset>  — type <cyan>mux start<reset> to begin\n")
    end

    Mux._echo(string.format("  PaneSpaces  : %d  Splits: %d  Panes: %d\n", ps, sc, pc))
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

-- Destroys all current panes/splits/panespaces and resets borders without
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
    -- Tear down active content on every pane and tab before destroying PaneSpace
    -- containers or wiping the registry.  This fires remove() callbacks (event
    -- handler / timer cleanup) and deletes slot containers so native widgets such
    -- as the embedded mapper are properly closed before the Geyser tree is torn down.
    -- The settings overlay pane is excluded — it persists across workspace changes.
    local savedSet    = Mux._settings_ui and Mux._settings_ui.window or nil
    local function _teardownContent(target)
        if not target._activeContent then return end
        local cDef = Mux._content and Mux._content[target._activeContent]
        if cDef and type(cDef.remove) == "function" then pcall(cDef.remove, target) end
        if Mux._destroyContentWidgets then Mux._destroyContentWidgets(target) end
        target._activeContent = nil
    end
    for _, pane in pairs(Mux._panes) do
        if pane ~= savedSet then
            for _, tab in ipairs(pane._tabs or {}) do
                for _, subTab in ipairs(tab._tabs or {}) do _teardownContent(subTab) end
                _teardownContent(tab)
            end
            _teardownContent(pane)
        end
    end
    for _, ps in pairs(Mux._paneSpaces) do
        if ps.destroy then ps:destroy() end
    end
    -- Floating panes are reparented to the Geyser root and are not owned by any
    -- PaneSpace, so ps:destroy() misses them. Hide them explicitly before the wipe.
    for _, pane in pairs(Mux._panes) do
        if pane.floating and pane.outer then pane.outer:hide() end
    end
    -- Tear down every reactive subject's rules first (kills any managed triggers,
    -- e.g. capture line triggers) so they don't leak across a workspace wipe. The
    -- engine registry holds both panes and tabs.
    if Mux._deregisterRuleSubject and Mux._ruleSubjects then
        for _, subj in pairs(Mux._ruleSubjects) do pcall(Mux._deregisterRuleSubject, subj) end
    end
    -- Preserve the settings UI pane across registry wipes.
    Mux._panes    = {}
    Mux._splits   = {}
    Mux._paneSpaces = {}
    Mux._ruleSubjects = {}
    if Mux._settings_ui then Mux._settings_ui.window = savedSet end
    -- Panes are gone; release singleton locks so the next workspace can apply the
    -- same content without hitting the "already open" block.
    for _, def in pairs(Mux._content or {}) do
        if def.singleton then def._activeTargetRef = nil end
    end
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

-- fullStop  — destroys all visible widgets, kills the resize handler, reloads
--             settings from disk so theme and debug flag are fresh.
-- fullStart — re-registers the resize handler, applies saved theme, restores
--             the session workspace ("current") or "default" on first run.

function Mux.fullStop()
    if Mux._resizeHandler then
        killAnonymousEventHandler(Mux._resizeHandler)
        Mux._resizeHandler = nil
    end
    -- Hide and release the settings window; buildWindow() creates a fresh one on
    -- the next toggle(). Must happen BEFORE _clearWorkspace so the savedSet guard
    -- inside it sees nil.
    if Mux._settings_ui and Mux._settings_ui.window then
        Mux._settings_ui.window:hide()
        Mux._settings_ui.window     = nil
        Mux._settings_ui.visible    = false
        Mux._settings_ui.currentTab = nil
    end

    Mux._closeContextMenu()
    Mux._clearWorkspace()
    setBorderSizes(0, 0, 0, 0)


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

    local savedTheme = Mux.settings.get("muxtheme", "active") or Mux.settings.get("mux", "theme")
    if savedTheme and savedTheme ~= "" and Mux.applyTheme then
        Mux.applyTheme(savedTheme)
    end
    Mux.debug = Mux.settings.get("mux", "debug") or false

    -- Restore the most recent auto-saved session; otherwise fall back to
    -- reset_workspace (a hosting package's chosen baseline via
    -- Mux.configureHost, or "default" if none was configured).
    local wsName = "current"
    if not Mux._workspaces[wsName] then
        wsName = Mux.settings.get("mux", "reset_workspace") or "default"
    end
    if not Mux._workspaces[wsName] then
        wsName = "default"
    end

    if not Mux._workspaces[wsName] then
        Mux._echo("\n<red>[Muxlet]<reset> No workspace found. Use 'mux workspaces' to list available.\n")
        return
    end

    Mux.applyWorkspace(wsName)
    Mux._running = true
    tempTimer(2, function()
        if not Mux.settings.get("mux", "quietStart") then
            Mux._echo("\n<cyan>[Muxlet]<reset> Started — type <cyan>mux help<reset> for commands.\n")
        end
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

Mux._log("v%s loaded", Mux._version)