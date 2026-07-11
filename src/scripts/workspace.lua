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
-- Static workspace definition format:
--   { name="Default", theme="dark",
--     paneSpace     = { id="screen", zone="screen", root=<node> },
--     floatingPanes = { <node>, ... } }
--
-- Node format (used by paneSpace.root and floatingPanes entries):
--   Leaf  : { type="pane",  id="chat",  name="Chat",  showTitlebar=true,
--             activeContent="my_content" }
--   Split : { type="split", direction="v", ratio=0.6, a=<node>, b=<node> }
--
-- A workspace has exactly one paneSpace (a single object, not a list). Multiple
-- paneSpaces would create overlapping containers with no awareness of each
-- other's boundaries, breaking split operations and console border management.

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
    if def.paneSpace ~= nil then
        assert(type(def.paneSpace) == "table",
            "workspace definition: 'paneSpace' must be a table")
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

    local _dbg = Mux.debug
    local _tc = _dbg and os.clock() or nil
    if Mux._clearWorkspace then Mux._clearWorkspace() end
    local _clearMs = _tc and (os.clock() - _tc) * 1000 or 0
    if def.theme then Mux.applyTheme(def.theme) end

    local paneMap   = {}
    local psDef     = def.paneSpace
    Mux._pendingGhostLinks = {}   -- ghost→floating-owner re-links queued during buildNode

    -- Build the tree with Geyser's per-constraint-change reposition suppressed, so
    -- the organize() calls fired while assembling each split box are calc-only
    -- (otherwise construction fans out into the O(branches^depth) reposition storm).
    -- Then apply native geometry in one O(n) pass. _inResize is held so the
    -- console-border update doesn't echo into a second full reposition.
    local _tb = _dbg and os.clock() or nil
    local builtSpace  = nil
    local wasInResize = Mux._inResize
    Mux._inResize = true
    Mux._suppressReposition(function()
        if psDef then
            local ps = Mux.newPaneSpace({
                id   = psDef.id,
                zone = psDef.zone,
                size = psDef.size,
            })
            if psDef.root then
                local rootObj = buildNode(psDef.root, ps.outer, paneMap, ps)
                if rootObj then
                    ps:setRoot(rootObj)
                    if rootObj._paneSpace == nil and rootObj.outer then
                        rootObj._paneSpace = ps
                    end
                end
            end
            ps:show()
            builtSpace = ps
        end
    end)
    if builtSpace and builtSpace.outer then Mux._applyGeometry(builtSpace.outer) end
    Mux._inResize = wasInResize
    local _buildMs = _tb and (os.clock() - _tb) * 1000 or 0
    if _dbg then
        Mux._echo(string.format(
            "\n<grey>[mux perf] workspace '%s': clear=%.0fms  build+layout=%.0fms<reset>\n",
            name, _clearMs, _buildMs))
    end

    -- Restore floating panes after panespace geometry resolves.
    local floatingPanes = def.floatingPanes or {}
    local hasGhostLinks = Mux._pendingGhostLinks and #Mux._pendingGhostLinks > 0
    if #floatingPanes > 0 or hasGhostLinks then
        tempTimer(0.2, function()
            for _, fd in ipairs(floatingPanes) do
                local p = buildNode(fd, Geyser, paneMap, nil)
                if p then
                    if fd.id then paneMap[fd.id] = p end
                    -- Materializing a pane's saved floating=true state is not a user
                    -- "convert to floating" action -- convertible=false means "don't
                    -- let drag-to-embed/float interactions touch this pane," not
                    -- "don't ever let this pane become floating." Bypass the guard
                    -- for this one restore call, then put the saved value back so
                    -- interactive behavior (e.g. drag-to-embed) is unaffected.
                    local savedConvertible = p.convertible
                    p.convertible = true
                    p:_detachToFloat()
                    p.convertible = savedConvertible
                    -- Resolve this pane's rules (e.g. a "hide when condition unmet" rule)
                    -- BEFORE content is applied below. MuxPane:init already deferred its
                    -- own first evaluation by a tick (tempTimer(0,...), so the pane is
                    -- fully placed first) -- but content restoration here runs earlier,
                    -- in this same tick, and would otherwise render+show its content one
                    -- full tick before the hide takes effect. Evaluating now (rule wiring
                    -- from init already happened synchronously) lets _conditionHidden be
                    -- set before Mux._applyContent ever shows anything, so a pane whose
                    -- rule says "start hidden" never flashes/sticks visible first.
                    if p.rules and #p.rules > 0 and Mux._evaluateRules then
                        -- Diagnostic: echoes each rule's resolved condition and computed
                        -- value right before evaluation, so a fresh restore's rule state
                        -- is visible in the console.
                        for _, r in ipairs(p.rules) do
                            local rc = Mux._resolveCond and Mux._resolveCond(r.cond) or r.cond
                            local v  = Mux._conditionValue and Mux._conditionValue(r.cond, p)
                            Mux._echo(string.format(
                                "\n<yellow>[mux diag] pane %s rule %s type=%s path=%s value=%s\n",
                                tostring(p.id), tostring(r.id), tostring(rc and rc.type),
                                tostring(rc and rc.path), tostring(v)))
                        end
                        Mux._evaluateRules(p, true)
                    end
                    -- Apply restored content HERE: floating panes are rebuilt after
                    -- the embedded content-apply pass below has already run, so their
                    -- _pendingContent would otherwise never be applied.
                    if p._pendingContent then
                        if Mux._content and Mux._content[p._pendingContent] and Mux._applyContent then
                            Mux._applyContent(p, p._pendingContent, true)
                            if Mux._restoreContent then Mux._restoreContent(p, p._pendingContentState) end
                        elseif Mux._warn then
                            Mux._warn("applyWorkspace: content '%s' not registered for floating pane '%s'",
                                p._pendingContent, p.id)
                        end
                        p._pendingContent = nil
                        p._pendingContentState = nil
                    end
                end
            end
            -- Re-link each restored ghost to its now-built floating owner. With
            -- ownerless ghosts, this just means handing the floating pane the
            -- ghost's stable key as its home; the pane resolves the live home tile
            -- through it (return-to-ghost / drop-on-ghost work as in a live float).
            if Mux._pendingGhostLinks then
                for _, link in ipairs(Mux._pendingGhostLinks) do
                    local ghost = Mux._ghostSlots and Mux._ghostSlots[link.key]
                    local owner = paneMap[link.ownerId]
                    if ghost and owner then
                        owner._homeGhostKey = link.key
                        owner._slot     = ghost.slot
                        owner._split    = ghost.split
                        owner._slotSide = ghost.side
                    end
                end
                Mux._pendingGhostLinks = nil
            end
            -- Wire saved anchors for the floating panes just built. Must happen here,
            -- not in the tempTimer(0,...) below: that timer fires first (0 < 0.2) and
            -- would run _resolveSavedAnchors before any restored floating pane exists,
            -- silently orphaning every _pendingAnchor set above with nothing left to
            -- ever consume it.
            if Mux._resolveSavedAnchors then Mux._resolveSavedAnchors() end
            Mux.raiseFloatingPanes()
            if Mux._notifyAllReposition then Mux._notifyAllReposition() end
        end)
    end

    tempTimer(0, function()
        for _, p in pairs(Mux._panes) do
            if p._pendingContent then
                if not Mux._content or not Mux._content[p._pendingContent] then
                    Mux._warn("applyWorkspace: content '%s' not registered for pane '%s'",
                        p._pendingContent, p.id)
                elseif Mux._applyContent then
                    Mux._applyContent(p, p._pendingContent, true)
                    if Mux._restoreContent then Mux._restoreContent(p, p._pendingContentState) end
                end
                p._pendingContent = nil
                p._pendingContentState = nil
            end
        end
        local wasIR = Mux._inResize
        Mux._inResize = true
        Mux._notifyAllReposition()
        Mux._inResize = wasIR
        local sw = Mux._settings_ui
        if sw and sw.window and sw.visible then sw.window:raise() end
        Mux.raiseFloatingPanes()
        if Mux._restyleAllTabs then Mux._restyleAllTabs() end
        Mux._scheduleAutoSave()
    end)

    Mux._log("Applied workspace: %s (%d panes)", name, tableCount(paneMap))
    return paneMap
end

-- A split slot can be occupied by a ghost (the placeholder left behind when its
-- pane floats) rather than a child node. Such a slot has a nil childA/childB, so
-- the recursive serialize would drop it and the slot would reload as an empty
-- void. Emit a ghost marker instead, recording the owning floating pane's id so
-- the ghost↔owner link can be rebuilt on restore.
local function ghostNodeForSlot(slot)
    if not slot or not Mux._ghostSlots then return nil end
    local ghostKey
    for key, ghost in pairs(Mux._ghostSlots) do
        if ghost.slot == slot then ghostKey = key; break end
    end
    if not ghostKey then return nil end
    -- Ghosts are ownerless; the home link lives on the floating pane. Find the
    -- floating pane (if any) whose home is this ghost, so restore can re-link it.
    local ownerId
    if Mux._panes then
        for _, p in pairs(Mux._panes) do
            if p.floating and p._homeGhostKey == ghostKey then ownerId = p.id; break end
        end
    end
    return { type = "ghost", owner = ownerId }
end

local function serializeNode(obj)
    if not obj then return nil end
    if obj.slotA and obj.slotB then
        return {
            type      = "split",
            direction = obj.direction or "v",
            ratio     = obj.ratio     or 0.5,
            a         = serializeNode(obj.childA) or ghostNodeForSlot(obj.slotA),
            b         = serializeNode(obj.childB) or ghostNodeForSlot(obj.slotB),
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
    if not obj.movable           then node.movable            = false end
    if not obj.closeable         then node.closeable          = false end
    if not obj.minimizable       then node.minimizable        = false end
    if not obj.splittable        then node.splittable         = false end
    if not obj.swappable         then node.swappable          = false end
    if not obj.zoomable          then node.zoomable           = false end
    if not obj.contextMenu       then node.contextMenu        = false end
    if not obj.insertable        then node.insertable         = false end
    if not obj.autoFit           then node.autoFit            = false end
    if not obj.bordered          then node.bordered           = false end
    if obj.borderColor           then node.borderColor        = obj.borderColor end
    -- Per-pane local style-token overrides (pane.border.color etc.).
    if obj._tokens then
        local tk, any = {}, false
        for k, v in pairs(obj._tokens) do tk[k] = v; any = true end
        if any then node.tokens = tk end
    end
    if obj.showSettingsInMenu    then node.showSettingsInMenu = true  end
    -- addable defaults to true for the main console host, false otherwise; only
    -- persist it when the user has flipped it away from that default (in either
    -- direction -- e.g. exposing the + button on a non-host pane).
    local addableDefault = obj.mainConsoleHost and true or false
    if (obj.addable and true or false) ~= addableDefault then
        node.addable = obj.addable and true or false
    end
    if obj.nameAlign and obj.nameAlign ~= "left" then node.nameAlign = obj.nameAlign end
    if obj._connectionAware then node.connectionAware  = true end
    -- Persist non-preset rules; the connection preset round-trips via the flag above.
    if Mux._serializeRules then
        local rs = Mux._serializeRules(obj)
        if rs then
            local keep = {}
            for _, r in ipairs(rs) do
                -- Capture rules are rebuilt from the content's own config on restore.
                local skip = type(r.id) == "string" and r.id:find("^mux:capture")
                if not skip then keep[#keep + 1] = r end
            end
            if #keep > 0 then node.rules = keep end
        end
    end
    if obj._activeContent   then node.activeContent   = obj._activeContent end
    -- Persist pre-lock natural values for any content-locked params, so removing the
    -- content later reverts to the true original rather than the forced value (which
    -- would otherwise be the only thing serialized).
    if obj._lockSnapshot then
        local snap, any = {}, false
        for prop, val in pairs(obj._lockSnapshot) do snap[prop] = val; any = true end
        if any then node.lockSnapshot = snap end
    end
    if obj.hiddenTbElements then
        local hidden = {}
        for id, on in pairs(obj.hiddenTbElements) do if on then hidden[#hidden+1] = id end end
        if #hidden > 0 then table.sort(hidden); node.hiddenTbElements = hidden end
    end
    local cstate = Mux._serializeContent and Mux._serializeContent(obj)
    if cstate then node.contentState = cstate end
    if obj.floating then
        node.floating = true
        node.floatX   = obj.floatX
        node.floatY   = obj.floatY
        node.floatW   = obj.floatW
        node.floatH   = obj.floatH
    end
    node.anchorable = obj.anchorable
    if obj.showAnchorElement == false then node.showAnchorElement = false end
    if obj.anchor then
        node.anchor   = obj.anchor
        node.atAnchor = obj._atAnchor and true or false
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
        floatingPanes = {},
    }

    local psCount = 0
    for _, ps in pairs(Mux._paneSpaces) do
        psCount = psCount + 1
        local psDef = { id = ps.id, zone = ps.zone, size = ps.size }
        if ps.root then psDef.root = serializeNode(ps.root) end
        def.paneSpace = psDef   -- single paneSpace per workspace
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

-- Write a pending debounced save immediately. Called on session exit so a move,
-- resize, or other change made inside the 1s debounce window isn't lost.
function Mux._flushAutoSave()
    if Mux._autoSaveTimer then
        killTimer(Mux._autoSaveTimer)
        Mux._autoSaveTimer = nil
        Mux._doAutoSave()
    end
end

if not Mux._exitSaveHandler then
    Mux._exitSaveHandler = registerAnonymousEventHandler("sysExitEvent", function()
        if Mux._flushAutoSave then Mux._flushAutoSave() end
    end)
end

function Mux._doAutoSave()
    local def = {
        name          = "current",
        theme         = Mux._activeThemeName,
        floatingPanes = {},
    }

    local psCount = 0
    for _, ps in pairs(Mux._paneSpaces) do
        psCount = psCount + 1
        local psDef = { id = ps.id, zone = ps.zone, size = ps.size }
        if ps.root then psDef.root = serializeNode(ps.root) end
        def.paneSpace = psDef   -- single paneSpace per workspace
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

-- ── Export ─────────────────────────────────────────────────────────────────────
-- Serializes a registered workspace into ready-to-paste Lua source that calls
-- Mux.registerWorkspace(name, def). Lets package authors design a layout live
-- (mux workspace save <name>), then bake it into their package's own source
-- as a static, built-in workspace rather than depending on the runtime save
-- file, which only exists in the profile that produced it.
--
-- A workspace's panes/tabs can carry rules referencing a NAMED condition/action
-- ({ ref = id } / act = id) — those only live in rules.json (conditional.lua),
-- so exporting the workspace alone would ship a broken reference (silently
-- falls back to an "always" condition on a profile that never created that
-- id). collectRuleDeps walks the def for every such reference so the export
-- can bundle their registration calls alongside it, self-contained.

-- Recursively collects condition/action ids referenced by rules anywhere in
-- `node` (a workspace def, or any sub-tree of one), restricted to ids that are
-- actually declarative (non-builtin) — built-in refs (e.g. ref="always",
-- act="mux.showSelf") are excluded via the builtin flag, so they fall out
-- naturally with no separate "is this built-in" table to check.
local function collectRuleDeps(node, condIds, actIds, seen)
    if type(node) ~= "table" or seen[node] then return end
    seen[node] = true
    if type(node.cond) == "table" and node.cond.ref then
        local c = Mux._conditions[node.cond.ref]
        if c and not c.readOnly then condIds[node.cond.ref] = true end
    end
    if type(node.act) == "string" and Mux._declActions[node.act] then actIds[node.act] = true end
    if type(node.actElse) == "string" and Mux._declActions[node.actElse] then actIds[node.actElse] = true end
    for _, v in pairs(node) do
        if type(v) == "table" then collectRuleDeps(v, condIds, actIds, seen) end
    end
end

-- Sorted-keys array from a { id = true, ... } set, for stable export output.
local function sortedIds(set)
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    table.sort(out)
    return out
end

-- Registration lines for a set of condition/action ids, e.g.
--   Mux._conditionRegisterLua(Mux._conditions["lowhp"])
-- for every id in `condIds`, under a section comment — only emitted when the
-- set is non-empty, so a workspace with no rule dependencies exports exactly
-- as before (just the Mux.registerWorkspace call).
local function depLines(sectionLabel, ids, byId, registerFn)
    if #ids == 0 then return {} end
    local lines = { "-- " .. sectionLabel }
    for _, id in ipairs(ids) do lines[#lines + 1] = registerFn(byId[id]) end
    lines[#lines + 1] = ""
    return lines
end

function Mux.exportWorkspace(name)
    if not name or name == "" then
        Mux._echo("\n<red>[Muxlet]<reset> Usage: mux workspace export <name>\n")
        return
    end

    local def = Mux._workspaces[name]
    if not def then
        Mux._echo(string.format(
            "\n<red>[Muxlet]<reset> No workspace named '%s' is registered.\n"
            .. "  Build the layout, then run: <cyan>mux workspace save %s<reset>\n",
            name, name))
        return
    end

    local condIds, actIds = {}, {}
    collectRuleDeps(def, condIds, actIds, {})
    -- def.theme names a theme (built-in or user-saved); only bundle it if it's
    -- actually user data (Mux._userThemes) — built-ins are code, not exportable,
    -- and never need bundling since they're already wherever Muxlet itself is.
    local themeName = type(def.theme) == "string" and Mux._userThemes[def.theme] and def.theme or nil

    local lines = {
        "-- Registers a Muxlet workspace, plus the declarative conditions/actions/theme",
        "-- its rules and layout depend on, as static, built-in Lua source.",
        "-- Generated by `mux workspace export " .. name .. "`; re-run after",
        "-- changing the layout/rules in-game and re-saving with `mux workspace save " .. name .. "`.",
        "",
    }
    if themeName then
        lines[#lines + 1] = "-- Theme used by this workspace"
        lines[#lines + 1] = Mux._themeRegisterLua(themeName, Mux._userThemes[themeName])
        lines[#lines + 1] = ""
    end
    for _, l in ipairs(depLines("Conditions used by this workspace", sortedIds(condIds), Mux._conditions, Mux._conditionRegisterLua)) do
        lines[#lines + 1] = l
    end
    for _, l in ipairs(depLines("Actions used by this workspace", sortedIds(actIds), Mux._declActions, Mux._actionRegisterLua)) do
        lines[#lines + 1] = l
    end
    lines[#lines + 1] = "Mux.registerWorkspace(" .. string.format("%q", name) .. ", " .. Mux._serializeLua(def, 0) .. ")"
    lines[#lines + 1] = ""

    local outPath = Mux._writeExportFile(name .. "-workspace-export.lua", table.concat(lines, "\n"))
    if outPath then
        Mux._echo(string.format(
            "\n<green>[Muxlet]<reset> Exported workspace '<cyan>%s<reset>' to:\n  <white>%s<reset>\n",
            name, outPath))
    end
end

-- Dumps everything non-built-in currently registered — every user theme,
-- declarative condition, declarative action, and workspace — into one file.
-- Unlike Mux.exportWorkspace, this does NOT filter by dependency: it's for
-- the "offer users a menu of possibilities" case (e.g. fed2-tools' Build
-- Your Own Workspace mode), where a package ships its whole library and lets
-- the end user pick and choose, not just one self-contained workspace.
function Mux.exportAll()
    local declConditions = {}
    for id, c in pairs(Mux._conditions) do
        if not c.readOnly then declConditions[id] = c end
    end
    local themeNames = sortedIds(Mux._userThemes)
    local condIds    = sortedIds(declConditions)
    local actIds     = sortedIds(Mux._declActions)
    local wsNames    = sortedIds(Mux._workspaces)

    local lines = {
        "-- Registers every non-built-in theme, condition, action, and workspace",
        "-- currently in this profile, as static, built-in Lua source.",
        "-- Generated by `mux export`.",
        "",
    }
    if #themeNames > 0 then
        lines[#lines + 1] = "-- Themes"
        for _, tname in ipairs(themeNames) do
            lines[#lines + 1] = Mux._themeRegisterLua(tname, Mux._userThemes[tname])
        end
        lines[#lines + 1] = ""
    end
    for _, l in ipairs(depLines("Conditions", condIds, declConditions, Mux._conditionRegisterLua)) do
        lines[#lines + 1] = l
    end
    for _, l in ipairs(depLines("Actions", actIds, Mux._declActions, Mux._actionRegisterLua)) do
        lines[#lines + 1] = l
    end
    if #wsNames > 0 then
        lines[#lines + 1] = "-- Workspaces"
        for _, wname in ipairs(wsNames) do
            lines[#lines + 1] = "Mux.registerWorkspace(" .. string.format("%q", wname) .. ", "
                .. Mux._serializeLua(Mux._workspaces[wname], 0) .. ")"
        end
        lines[#lines + 1] = ""
    end

    if #themeNames == 0 and #condIds == 0 and #actIds == 0 and #wsNames == 0 then
        Mux._echo("\n<yellow>[Muxlet]<reset> Nothing to export — no themes, declarative conditions, actions, or workspaces are registered.\n")
        return
    end

    local outPath = Mux._writeExportFile("muxlet-export-all.lua", table.concat(lines, "\n"))
    if outPath then
        Mux._echo(string.format(
            "\n<green>[Muxlet]<reset> Exported %d theme(s), %d condition(s), %d action(s), %d workspace(s) to:\n  <white>%s<reset>\n",
            #themeNames, #condIds, #actIds, #wsNames, outPath))
    end
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

    Mux._echo("\n<cyan>[Muxlet]<reset> Workspaces\n")

    for _, n in ipairs(names) do
        local def  = Mux._workspaces[n]
        local note = ""
        if def and def.description and def.description ~= "" then
            note = "  <dim_grey>— " .. def.description .. "<reset>"
        end
        if n == "current" then note = "  <dim_grey>— auto-saved session state<reset>" end
        if n == "default"  then note = "  <dim_grey>— clean Muxlet baseline<reset>"   end

        Mux._echo(string.format("  <white>%s<reset>%s\n", n, note))
    end

    Mux._echo("  <dim_grey>Use: <cyan>mux workspace load <name><reset><dim_grey> to apply<reset>\n")
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
                -- Restore condition-hidden state (MuxTab:_conditionHide, tabs.lua). If the
                -- tab also carries rules (restored below), evaluating them immediately
                -- re-derives this from current live conditions and may override it — this
                -- is just the correct starting point for a tab hidden with no rule driving it.
                if tabDef.visible == false and tab._conditionHide then
                    tab:_conditionHide()
                end
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
                if tabDef.nameAlign                 then tab.nameAlign        = tabDef.nameAlign end
                if tabDef.tokens then
                    tab._tokens = {}
                    for k, v in pairs(tabDef.tokens) do tab._tokens[k] = v end
                    if tab.applyTheme then pcall(function() tab:applyTheme() end) end
                end
                local savedContent = tabDef.activeContent or tabDef._activeContent
                if savedContent and Mux._content and Mux._content[savedContent] then
                    if Mux._applyContent then
                        pcall(Mux._applyContent, tab, savedContent, true)
                        if Mux._restoreContent then Mux._restoreContent(tab, tabDef.contentState) end
                    end
                end
                -- Restore persisted (non-preset) rules; migrate legacy connection
                -- awareness into the overlay-rule pair.
                if (tabDef.rules or tabDef.connectionAware) and Mux._migrateLegacyRules then
                    Mux._migrateLegacyRules(tab, { rules = tabDef.rules, connectionAware = tabDef.connectionAware })
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

buildNode = function(node, parentContainer, paneMap, paneSpace)
    if not node or not node.type then return nil end

    if node.type == "pane" then
        local showTitlebar = node.showTitlebar
        local mainHost     = node.mainConsoleHost
        local floatX = node.floatX or 100
        local floatY = node.floatY or 100
        local floatW = node.floatW or 400
        local floatH = node.floatH or 300

        local p = MuxPane:new({
            id               = node.id,
            name             = node.name or node.id or "Pane",
            showTitlebar     = showTitlebar,
            mainConsoleHost  = mainHost,
            parent           = parentContainer,
            -- A pane restored as floating is parented directly under Geyser and would
            -- otherwise start at the Container default (100%x100% of its parent, i.e.
            -- the whole screen) until _detachToFloat() resizes it moments later. Seed
            -- its real geometry immediately so it's never even transiently full-screen
            -- if that resize is ever skipped, delayed, or blocked (e.g. by a guard).
            x                = node.floating and floatX or nil,
            y                = node.floating and floatY or nil,
            width            = node.floating and floatW or nil,
            height           = node.floating and floatH or nil,
            contentable      = node.contentable ~= false,
            resizable        = node.resizable ~= false,
            titlebarHideable = node.titlebarHideable ~= false,
            renamable        = node.renamable ~= false,
            propertiesButton = node.propertiesButton ~= false,
            tabsLocked       = node.tabsLocked or false,
            convertible      = node.convertible ~= false,
            movable          = node.movable ~= false,
            closeable        = node.closeable ~= false,
            minimizable      = node.minimizable ~= false,
            zoomable         = node.zoomable ~= false,
            contextMenu      = node.contextMenu ~= false,
            insertable       = node.insertable ~= false,
            autoFit          = node.autoFit ~= false,
            bordered         = node.bordered ~= false,
            borderColor      = node.borderColor,
            tokens           = node.tokens,
            anchorable       = node.anchorable ~= false,
            showAnchorElement = node.showAnchorElement ~= false,
            showSettingsInMenu = node.showSettingsInMenu or false,
            hiddenTbElements = node.hiddenTbElements,
            lockSnapshot     = node.lockSnapshot,
            nameAlign        = node.nameAlign or "left",
            floatX           = floatX,
            floatY           = floatY,
            floatW           = floatW,
            floatH           = floatH,
            splittable       = node.splittable ~= false,
            swappable        = node.swappable ~= false,
            condition        = node.condition,
            actionTrue       = node.actionTrue  or "mux.showSelf",
            actionFalse      = node.actionFalse or "mux.hideSelf",
            rules            = node.rules,
            connectionAware  = node.connectionAware,
        })
        p._paneSpace = paneSpace
        if node.addable ~= nil then p.addable = node.addable end
        if node.id then paneMap[node.id] = p end
        if node.anchor then
            p._pendingAnchor   = node.anchor
            p._pendingAtAnchor = node.atAnchor
        end

        -- Queue content application; resolved in applyWorkspace's deferred timer
        -- so all pane geometry is settled before the content apply() function runs.
        if node.activeContent then
            p._pendingContent = node.activeContent
            p._pendingContentState = node.contentState
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
        -- Restore one side: a ghost marker re-creates the placeholder (so the slot
        -- isn't a void) and queues an owner re-link; anything else is a real child.
        local function restoreSide(childNode, slot, side)
            if not childNode then return end
            if childNode.type == "ghost" then
                local key = Mux._createGhostSlot(slot, s, side, paneSpace, nil)
                if childNode.owner and key then
                    Mux._pendingGhostLinks = Mux._pendingGhostLinks or {}
                    Mux._pendingGhostLinks[#Mux._pendingGhostLinks + 1] =
                        { key = key, ownerId = childNode.owner }
                end
            else
                local c = buildNode(childNode, slot, paneMap, paneSpace)
                if c then s:place(c, side) end
            end
        end
        restoreSide(node.a, s.slotA, "a")
        restoreSide(node.b, s.slotB, "b")
        return s

    else
        Mux._warn("buildNode: unknown node type '%s'", tostring(node.type))
        return nil
    end
end

-- The built-in "default" workspace lives in library/workspaces/default.lua —
-- this file is the registry mechanism only.

loadWorkspacesFile()

Mux._log("mux_workspace loaded")