-- Muxlet — Workspace registry
--
-- A workspace is a complete snapshot of the Muxlet UI state: pane arrangement,
-- split ratios, theme, tab structure, loaded content, all configuration flags
-- (contentable, locked, connectionAware, …), and floating pane positions.
--
-- API:
--   Mux.registerWorkspace("name", def)   register a static workspace definition
--   Mux.applyWorkspace("name")           build the UI from a named workspace
--   Mux.saveWorkspace("name")            capture the current full UI state
--   Mux.listWorkspaces()                 print workspace names
--   Mux.deleteWorkspace("name")          remove a saved workspace
--
-- Workspaces persist across sessions in Muxlet_persistent/workspaces.json.
--
-- Static workspace node format:
--   Leaf  : { type="pane",  id="chat",  name="Chat",  showTitlebar=true,
--             activeContent="my_content" }
--   Split : { type="split", direction="v", ratio=0.6, a=<node>, b=<node> }
--
-- Only one paneSet per workspace is supported. Multiple paneSets create
-- overlapping containers with no awareness of each other's boundaries,
-- which breaks split operations and console border management.

Mux._workspaces     = Mux._workspaces     or {}
Mux._userWorkspaces = Mux._userWorkspaces or {}  -- names explicitly saved by the user
Mux._wsFile         = Mux._persistentDir .. "/workspaces.json"

-- File format: { _userSaved = ["name", ...], name = {def}, ..., current = {def} }
-- _userSaved is the authoritative list of workspaces the user explicitly saved.
-- "current" (auto-save) and built-in/package workspaces are never in it.

local function saveWorkspacesFile()
    local userSavedList = {}
    for name in pairs(Mux._userWorkspaces) do
        userSavedList[#userSavedList + 1] = name
    end
    local data = { _userSaved = userSavedList }
    for name, def in pairs(Mux._workspaces) do
        if name ~= "default" then data[name] = def end
    end
    local ok, err = pcall(function()
        local f = io.open(Mux._wsFile, "w")
        f:write(yajl.to_string(data))
        f:close()
    end)
    if not ok then Mux._err("workspace file save failed: %s", tostring(err)) end
end

local function loadWorkspacesFile()
    if not io.exists(Mux._wsFile) then return end
    local ok, err = pcall(function()
        local f    = io.open(Mux._wsFile, "r")
        local raw  = f:read("*all")
        f:close()
        local data = yajl.to_value(raw)
        if type(data) ~= "table" then return end
        local saved = data._userSaved
        if type(saved) == "table" then
            for _, name in ipairs(saved) do
                Mux._userWorkspaces[name] = true
            end
        end
        for name, def in pairs(data) do
            if name ~= "_userSaved" and type(def) == "table" then
                Mux._workspaces[name] = def
            end
        end
    end)
    if not ok then Mux._err("workspace file load failed: %s", tostring(err)) end
end

-- Reset on package reload; old ID is stale after a reload.
if Mux._autoSaveTimer then killTimer(Mux._autoSaveTimer) end
Mux._autoSaveTimer = nil

-- Forward declaration; assigned near the bottom after helpers are defined.
local buildNode

local function tableCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function Mux.registerWorkspace(name, def)
    assert(type(name) == "string", "workspace name must be a string")
    assert(type(def)  == "table",  "workspace definition must be a table")
    local paneSets = def.paneSets or def.pane_sets or {}
    if #paneSets > 1 then
        error(string.format(
            "workspace '%s': only one paneSet is supported (got %d). "
            .. "Use splits within a single paneSet to arrange multiple panels.",
            name, #paneSets), 2)
    end
    Mux._workspaces[name] = def
    Mux._log("Registered workspace: %s", name)
end

function Mux.applyWorkspace(name)
    local def = Mux._workspaces[name]
    if not def then
        Mux._err("applyWorkspace: unknown workspace '%s'", name)
        return {}
    end
    Mux._activeWorkspaceName = name
    Mux._running = true

    if Mux._clearWorkspace then Mux._clearWorkspace() end
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
            if p._pendingContent then
                if not Mux._content or not Mux._content[p._pendingContent] then
                    Mux._warn("applyWorkspace: content '%s' not registered for pane '%s'",
                        p._pendingContent, p.id)
                elseif Mux._applyContent then
                    Mux._applyContent(p, p._pendingContent)
                end
                p._pendingContent = nil
            end
        end
        for _, p in pairs(Mux._panes) do
            if p.onReposition then p.onReposition(p) end
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
        Mux._scheduleAutoSave()
    end)

    Mux._log("Applied workspace: %s (%d panes)", name, tableCount(paneMap))
    return paneMap
end

local function serializeNode(obj)
    if not obj then return nil end
    if obj.slotA and obj.slotB then
        return {
            type      = "split",
            direction = obj.direction or "v",
            ratio     = obj.ratio     or 0.5,
            a         = serializeNode(obj.childA),
            b         = serializeNode(obj.childB),
        }
    end
    if obj.overlay then return nil end

    local node = {
        type            = "pane",
        id              = obj.id,
        name            = obj.name,
        showTitlebar    = obj.titlebarVisible,
        mainConsoleHost = obj.mainConsoleHost or false,
    }
    if not obj.contentable       then node.contentable       = false end
    if not obj.resizable         then node.resizable         = false end
    if not obj.titlebarHideable  then node.titlebarHideable  = false end
    if not obj.renamable         then node.renamable         = false end
    if not obj.propertiesButton  then node.propertiesButton  = false end
    if obj.tabsLocked            then node.tabsLocked         = true  end
    if not obj.convertible       then node.convertible       = false end
    if not obj.movable        then node.movable            = false end
    if obj._connectionAware then node.connectionAware  = true end
    if obj._activeContent   then node.activeContent   = obj._activeContent end
    if obj.floating then
        node.floating = true
        node.floatX   = obj.floatX
        node.floatY   = obj.floatY
        node.floatW   = obj.floatW
        node.floatH   = obj.floatH
    end
    if obj._serializeTabs then
        local tabs, activeTabName = obj:_serializeTabs()
        if tabs then
            node.tabs          = tabs
            node.activeTabName = activeTabName
        end
    end
    return node
end

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
        if pane.floating and not pane.overlay then
            local node = serializeNode(pane)
            if node then table.insert(def.floatingPanes, node) end
        end
    end

    if psCount == 0 and #def.floatingPanes == 0 then
        Mux._echo("\n<red>[Muxlet]<reset> Nothing to save — no active workspace.\n")
        return
    end

    Mux._workspaces[name] = def
    Mux._userWorkspaces[name] = true
    saveWorkspacesFile()

    Mux._echo(string.format(
        "\n<green>[Muxlet]<reset> Workspace '<cyan>%s<reset>' saved.\n"
        .. "  Restore: <white>mux workspace load %s<reset>\n",
        name, name))
end

-- Every structural change (float, embed, close, split resize, content applied)
-- calls _scheduleAutoSave(). A 1-second debounce prevents write storms during
-- rapid operations (e.g. drag-resizing). The saved workspace is named "current"
-- and is restored automatically on the next session, so users never lose
-- workspace changes without an explicit save step.
function Mux._scheduleAutoSave()
    if Mux._autoSaveTimer then killTimer(Mux._autoSaveTimer) end
    Mux._autoSaveTimer = tempTimer(1.0, function()
        Mux._autoSaveTimer = nil
        Mux._doAutoSave()
    end)
end

function Mux._doAutoSave()
    local def = {
        name          = "current",
        theme         = Mux._activeThemeName,
        paneSets      = {},
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
        if pane.floating and not pane.overlay then
            local node = serializeNode(pane)
            if node then table.insert(def.floatingPanes, node) end
        end
    end

    if psCount == 0 and #def.floatingPanes == 0 then return end

    Mux._workspaces["current"] = def
    saveWorkspacesFile()
    Mux._log("auto-saved workspace to 'current'")
end

function Mux.listWorkspaces()
    local names = {}
    for n in pairs(Mux._workspaces) do names[#names+1] = n end
    if #names == 0 then
        Mux._echo("\n<cyan>[Muxlet]<reset> No registered workspaces.\n")
        return
    end
    table.sort(names, function(a, b)
        if a == "current" then return true  end
        if b == "current" then return false end
        if a == "default" then return true  end
        if b == "default" then return false end
        return a < b
    end)

    if Mux._running then
        local active = Mux._activeWorkspaceName or "current"
        Mux._echo(string.format(
            "\n<cyan>[Muxlet]<reset> Workspaces  <dim_grey>(running — active: <cyan>%s<reset><dim_grey>)<reset>\n",
            active))
    else
        Mux._echo("\n<cyan>[Muxlet]<reset> Workspaces  <dim_grey>(stopped — type <cyan>mux start<reset><dim_grey> to begin)<reset>\n")
    end

    for _, n in ipairs(names) do
        local def  = Mux._workspaces[n]
        local note = ""
        if def and def.description and def.description ~= "" then
            note = "  <dim_grey>— " .. def.description .. "<reset>"
        end
        if n == "current" then note = "  <dim_grey>— auto-saved session state<reset>" end
        if n == "default"  then note = "  <dim_grey>— clean Muxlet baseline<reset>"   end

        local active = Mux._running and (n == Mux._activeWorkspaceName)
        local marker = active and "<green>▶ <reset>" or "  "
        Mux._echo(string.format("  %s<white>%s<reset>%s\n", marker, n, note))
    end

    if not Mux._running then
        Mux._echo("  <dim_grey>Use: <cyan>mux workspace load <name><reset><dim_grey> to apply<reset>\n")
    end
end

function Mux.deleteWorkspace(name)
    if not name or name == "" then
        Mux._echo("\n<red>[Muxlet]<reset> Usage: mux workspace delete <name>\n")
        return
    end
    if name == "default" or name == "current" then
        Mux._echo(string.format("\n<red>[Muxlet]<reset> '%s' cannot be deleted.\n", name))
        return
    end
    if not Mux._userWorkspaces[name] then
        Mux._echo(string.format(
            "\n<red>[Muxlet]<reset> '%s' was not saved by you and cannot be deleted.\n", name))
        return
    end
    Mux._workspaces[name] = nil
    Mux._userWorkspaces[name] = nil
    saveWorkspacesFile()
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Workspace '<cyan>%s<reset>' deleted.\n", name))
end

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
                -- Individual capability flags; backward-compat: old saves only have `locked`.
                -- If the new flags are present use them; otherwise derive from old locked field.
                if tabDef.renamable ~= nil or tabDef.closeable ~= nil or tabDef.movable ~= nil then
                    tab.renamable   = tabDef.renamable   ~= false
                    tab.closeable   = tabDef.closeable   ~= false
                    tab.movable     = tabDef.movable     ~= false
                    if tabDef.contentable ~= nil then
                        tab.contentable = tabDef.contentable ~= false
                    end
                elseif tabDef.locked then
                    tab.renamable   = false
                    tab.closeable   = false
                    tab.movable     = false
                    tab.contentable = false
                end
                if tabDef.tabsLocked                then tab.tabsLocked       = true  end
                if tabDef.propertiesButton == false then tab.propertiesButton = false end
                local savedContent = tabDef.activeContent or tabDef._activeContent
                if savedContent and Mux._content and Mux._content[savedContent] then
                    if Mux._applyContent then
                        pcall(Mux._applyContent, tab, savedContent)
                    end
                end
                if tabDef.connectionAware and p.setTabConnectionAware then
                    p:setTabConnectionAware(tab.id, true)
                end
                if tabDef.tabs and #tabDef.tabs > 0 then
                    restoreTabsOnPane(tab, tabDef)
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
        local mainHost     = node.mainConsoleHost

        local p = MuxPane:new({
            id               = node.id,
            name             = node.name or node.id or "Pane",
            showTitlebar     = showTitlebar,
            mainConsoleHost  = mainHost,
            parent           = parentContainer,
            contentable      = node.contentable ~= false,
            resizable        = node.resizable ~= false,
            titlebarHideable = node.titlebarHideable ~= false,
            renamable        = node.renamable ~= false,
            propertiesButton = node.propertiesButton ~= false,
            tabsLocked       = node.tabsLocked or false,
            convertible      = node.convertible ~= false,
            movable          = node.movable ~= false,
            floatX           = node.floatX or 100,
            floatY           = node.floatY or 100,
            floatW           = node.floatW or 400,
            floatH           = node.floatH or 300,
            splittable       = node.splittable,
            swappable        = node.swappable,
        })
        p._paneSet = paneSet
        if node.id then paneMap[node.id] = p end

        if node.connectionAware and p.setConnectionAware then
            p:setConnectionAware(true)
        end

        -- Queue content application; resolved in applyWorkspace's deferred timer
        -- so all pane geometry is settled before the content apply() function runs.
        if node.activeContent then
            p._pendingContent = node.activeContent
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

Mux.registerWorkspace("default", {
    name     = "Default",
    theme    = "dark",
    paneSets = {
        {
            id   = "screen",
            zone = "screen",
            root = {
                type            = "pane",
                id              = "output",
                name            = "Main",
                mainConsoleHost = true,
            },
        },
    },
})

loadWorkspacesFile()

Mux._log("mux_workspace loaded")
