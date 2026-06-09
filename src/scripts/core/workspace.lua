-- Muxlet — Workspace registry
--
-- A workspace is a complete snapshot of the Muxlet UI state: pane arrangement,
-- split ratios, theme, tab structure, loaded content, all configuration flags
-- (noContent, locked, connectionAware, …), and floating pane positions.
--
-- API:
--   Mux.registerWorkspace("name", def)   register a static workspace definition
--   Mux.applyWorkspace("name")           build the UI from a named workspace
--   Mux.saveWorkspace("name")            capture the current full UI state
--   Mux.listWorkspaces()                 print workspace names
--   Mux.deleteWorkspace("name")          remove a saved workspace
--
-- Workspaces persist across sessions via Mux.settings.
-- Set mux.startup_workspace to auto-restore one on profile load.
--
-- Backward-compat aliases for existing workspace definition files:
--   Mux.registerLayout = Mux.registerWorkspace
--   Mux.applyLayout    = Mux.applyWorkspace
--
-- Static workspace node format:
--   Leaf  : { type="pane",  id="chat",  name="Chat",  showTitlebar=true }
--   Split : { type="split", direction="v", ratio=0.6, a=<node>, b=<node> }

Mux._workspaces = Mux._workspaces or {}
-- Alias so any code referencing _layouts still resolves correctly.
Mux._layouts    = Mux._workspaces

-- Forward declaration; assigned near the bottom after helpers are defined.
local buildNode

local function tableCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ── Register / apply ──────────────────────────────────────────────────────────

function Mux.registerWorkspace(name, def)
    assert(type(name) == "string", "workspace name must be a string")
    assert(type(def)  == "table",  "workspace definition must be a table")
    Mux._workspaces[name] = def
    Mux._log("Registered workspace: %s", name)
end

-- Backward-compat aliases for workspace definition files that still call registerLayout.
Mux.registerLayout = Mux.registerWorkspace

function Mux.applyWorkspace(name)
    local def = Mux._workspaces[name]
    if not def then
        Mux._err("applyWorkspace: unknown workspace '%s'", name)
        return {}
    end

    if Mux._clearLayout then Mux._clearLayout() end
    if def.theme then Mux.applyTheme(def.theme) end

    local paneMap     = {}
    local paneSetsArr = def.paneSets or def.pane_sets or {}

    for _, psDef in ipairs(paneSetsArr) do
        local ps = Mux.newPaneSet({
            id   = psDef.id,
            zone = psDef.zone,
            size = psDef.size,
        })
        if psDef.root then
            local rootObj = buildNode(psDef.root, ps.outer, paneMap, ps)
            if rootObj then
                ps:setRoot(rootObj)
                if rootObj._paneSet == nil and rootObj.outer then
                    rootObj._paneSet = ps
                end
            end
        end
        ps:show()
    end

    -- Restore floating panes after pane-set geometry resolves.
    local floatingPanes = def.floatingPanes or {}
    if #floatingPanes > 0 then
        tempTimer(0.2, function()
            for _, fd in ipairs(floatingPanes) do
                local p = buildNode(fd, Geyser, paneMap, nil)
                if p then
                    if fd.id then paneMap[fd.id] = p end
                    p:_detachToFloat()
                end
            end
            Mux.raiseFloatingPanes()
        end)
    end

    tempTimer(0, function()
        for _, p in pairs(Mux._panes) do
            if p.mainConsoleHost then p:updateConsoleBorders() end
        end
        if not Mux._focusedPane then
            local target
            for _, p in pairs(Mux._panes) do
                if p.mainConsoleHost then target = p; break end
            end
            if not target then
                for _, p in pairs(Mux._panes) do
                    if not p.floating then target = p; break end
                end
            end
            if target then Mux.setFocus(target) end
        end
        local sw = Mux._settings_ui
        if sw and sw.window and sw.visible then sw.window:raise() end
        Mux.raiseFloatingPanes()
    end)

    Mux._log("Applied workspace: %s (%d panes)", name, tableCount(paneMap))
    return paneMap
end

-- Backward-compat alias.
Mux.applyLayout = Mux.applyWorkspace

-- ── Serialization ─────────────────────────────────────────────────────────────
-- Captures the full pane/split tree including all flags, float positions,
-- and connection-awareness opt-ins.

local function serializeNode(obj)
    if not obj then return nil end
    -- Split node
    if obj.slotA and obj.slotB then
        return {
            type      = "split",
            direction = obj.direction or "v",
            ratio     = obj.ratio     or 0.5,
            a         = serializeNode(obj.childA),
            b         = serializeNode(obj.childB),
        }
    end
    -- Skip permanent-float system panes (settings window, etc.)
    if obj.permanentFloat then return nil end

    local node = {
        type            = "pane",
        id              = obj.id,
        name            = obj.name,
        showTitlebar    = obj.titlebarVisible,
        mainConsoleHost = obj.mainConsoleHost or false,
    }
    -- Non-default flags — omitted when false to keep hand-written defs readable.
    if obj.noContent        then node.noContent        = true end
    if obj.noResize         then node.noResize         = true end
    if obj.noTitlebarToggle then node.noTitlebarToggle = true end
    if obj.noRename         then node.noRename         = true end
    if obj.noTabs           then node.noTabs           = true end
    if obj.locked           then node.locked           = true end
    if obj._connectionAware then node.connectionAware  = true end
    -- Float position (floating panes only; populated by saveWorkspace caller)
    if obj.floating then
        node.floating = true
        node.floatX   = obj.floatX
        node.floatY   = obj.floatY
        node.floatW   = obj.floatW
        node.floatH   = obj.floatH
    end
    -- Tabs
    if obj._serializeTabs then
        local tabs, activeTabName = obj:_serializeTabs()
        if tabs then
            node.tabs          = tabs
            node.activeTabName = activeTabName
        end
    end
    return node
end

-- ── Save workspace ────────────────────────────────────────────────────────────

function Mux.saveWorkspace(name)
    if not name or name == "" then
        Mux._echo("\n<red>[Muxlet]<reset> Usage: mux workspace save <name>\n")
        return
    end

    local def = {
        name         = name,
        theme        = Mux._activeThemeName,
        paneSets     = {},
        floatingPanes = {},
    }

    local psCount = 0
    for _, ps in pairs(Mux._paneSets) do
        psCount = psCount + 1
        local psDef = { id = ps.id, zone = ps.zone, size = ps.size }
        if ps.root then psDef.root = serializeNode(ps.root) end
        table.insert(def.paneSets, psDef)
    end

    for _, pane in pairs(Mux._panes) do
        if pane.floating and not pane.permanentFloat then
            local node = serializeNode(pane)
            if node then table.insert(def.floatingPanes, node) end
        end
    end

    if psCount == 0 and #def.floatingPanes == 0 then
        Mux._echo("\n<red>[Muxlet]<reset> Nothing to save — no active workspace.\n")
        return
    end

    Mux._workspaces[name] = def
    Mux.settings._data["mux"] = Mux.settings._data["mux"] or {}
    Mux.settings._data["mux"]["saved_workspace_" .. name] = yajl.to_string(def)
    Mux.settings.save()

    Mux._echo(string.format(
        "\n<green>[Muxlet]<reset> Workspace '<cyan>%s<reset>' saved.\n"
        .. "  Restore: <white>mux workspace load %s<reset>"
        .. "  |  Auto-start: <white>mux settings set mux.startup_workspace %s<reset>\n",
        name, name, name))
end

-- ── List / delete ─────────────────────────────────────────────────────────────

function Mux.listWorkspaces()
    local names = {}
    for n in pairs(Mux._workspaces) do names[#names+1] = n end
    if #names == 0 then
        Mux._echo("\n<cyan>[Muxlet]<reset> No registered workspaces.\n")
        return
    end
    table.sort(names)
    Mux._echo("\n<cyan>[Muxlet]<reset> Workspaces:\n")
    local data = Mux.settings._data["mux"] or {}
    for _, n in ipairs(names) do
        local saved = data["saved_workspace_" .. n] ~= nil
        local tag   = saved and " <dim_grey>(saved)<reset>" or ""
        Mux._echo(string.format("  <white>%s<reset>%s\n", n, tag))
    end
end

function Mux.deleteWorkspace(name)
    if not name or name == "" then
        Mux._echo("\n<red>[Muxlet]<reset> Usage: mux workspace delete <name>\n")
        return
    end
    if not Mux._workspaces[name] then
        Mux._echo(string.format("\n<red>[Muxlet]<reset> No workspace named '%s'.\n", name))
        return
    end
    Mux._workspaces[name] = nil
    Mux.settings._data["mux"] = Mux.settings._data["mux"] or {}
    Mux.settings._data["mux"]["saved_workspace_" .. name] = nil
    Mux.settings.save()
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Workspace '<cyan>%s<reset>' deleted.\n", name))
end

-- ── Internal tree builder ─────────────────────────────────────────────────────

-- Tab restoration shared between embedded and floating panes.
-- Deferred 0.1 s so pane geometry resolves before tab widgets are built.
local function restoreTabsOnPane(p, node)
    local savedTabs     = node.tabs
    local activeTabName = node.activeTabName
    tempTimer(0.1, function()
        p:enableTabs({ noDefaultTab = true })
        for _, tabDef in ipairs(savedTabs) do
            local tab = p:addTab(tabDef.name)
            if tab then
                if tabDef.locked then tab.locked = true end
                local savedContent = tabDef.activeContent or tabDef._activeContent or tabDef.preset
                if savedContent and Mux._content and Mux._content[savedContent] then
                    local proxy = {
                        id        = p.id .. "_" .. tab.id,
                        name      = tab.name,
                        content   = tab.content,
                        contentBg = tab.contentBg,
                    }
                    if Mux._applyContent then
                        pcall(Mux._applyContent, proxy, savedContent)
                    end
                    tab._activeContent = savedContent
                end
                if tabDef.connectionAware and p.setTabConnectionAware then
                    p:setTabConnectionAware(tab.id, true)
                end
            end
        end
        if activeTabName then
            for _, tab in ipairs(p._tabs or {}) do
                if tab.name == activeTabName then
                    p:activateTab(tab.id)
                    break
                end
            end
        end
    end)
end

buildNode = function(node, parentContainer, paneMap, paneSet)
    if not node or not node.type then return nil end

    if node.type == "pane" then
        local showTitlebar = node.showTitlebar
        if showTitlebar == nil then showTitlebar = node.show_titlebar end
        local mainHost = node.mainConsoleHost
        if mainHost == nil then mainHost = node.main_console_host end

        local p = MuxPane:new({
            id               = node.id,
            name             = node.name or node.id or "Pane",
            show_titlebar    = showTitlebar,
            mainConsoleHost  = mainHost,
            parent           = parentContainer,
            noContent        = node.noContent        or false,
            noResize         = node.noResize         or false,
            noTitlebarToggle = node.noTitlebarToggle  or false,
            noRename         = node.noRename         or false,
            noTabs           = node.noTabs           or false,
            -- Float position saved by saveWorkspace; used when _detachToFloat() fires.
            floatX           = node.floatX or 100,
            floatY           = node.floatY or 100,
            floatW           = node.floatW or 400,
            floatH           = node.floatH or 300,
        })
        p._paneSet = paneSet
        if node.id then paneMap[node.id] = p end

        if node.locked then p:lock() end
        if node.connectionAware and p.setConnectionAware then
            p:setConnectionAware(true)
        end

        if node.tabs and #node.tabs > 0 then
            restoreTabsOnPane(p, node)
        end

        return p

    elseif node.type == "split" then
        local s = MuxSplit:new({
            direction = node.direction or "v",
            ratio     = node.ratio     or 0.5,
            parent    = parentContainer,
        })
        if node.a then
            local ca = buildNode(node.a, s.slotA, paneMap, paneSet)
            if ca then s:place(ca, "a") end
        end
        if node.b then
            local cb = buildNode(node.b, s.slotB, paneMap, paneSet)
            if cb then s:place(cb, "b") end
        end
        return s

    else
        Mux._warn("buildNode: unknown node type '%s'", tostring(node.type))
        return nil
    end
end

-- ── Startup persistence ───────────────────────────────────────────────────────
-- Re-register workspaces saved to settings on profile load.
-- Also migrates old "saved_layout_*" keys from the pre-rename era.

do
    local data = Mux.settings._data["mux"] or {}
    for k, v in pairs(data) do
        if type(v) == "string" then
            local wsName = k:match("^saved_workspace_(.+)$")
                        or k:match("^saved_layout_(.+)$")
            if wsName then
                local ok, def = pcall(yajl.to_value, v)
                if ok and type(def) == "table" then
                    Mux._workspaces[wsName] = def
                end
            end
        end
    end
end

Mux._log("mux_workspace loaded")
