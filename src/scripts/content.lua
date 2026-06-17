-- Muxlet — Content registry
--
-- Any Lua file — in this package or an external one — can register a named
-- content type that users can apply to any pane or tab from the context menu:
--
--   Mux.registerContent("my_widget", {
--       name        = "My Widget",
--       description = "Fills the pane with something cool",
--       singleton   = false,   -- set true to allow only one active instance
--       apply  = function(target) ... end,   -- REQUIRED
--       remove = function(target) ... end,   -- optional; called before a new apply
--   })
--
-- `target` has the same interface whether it is a pane or a tab:
--   target.id        — unique string id
--   target.name      — display name
--   target.content   — Geyser.Container; parent for your widgets
--   target.contentBg — Geyser.Label; clear this after attaching real content:
--                        target.contentBg:echo("")
--                        target.contentBg:hide()
--
-- Singleton content:
--   When singleton = true only one pane or tab may have the content active at
--   a time.  Attempting to open it in a second target shows a small dialog
--   naming where it is currently open; the apply is aborted.
--   Works for both panes and tabs because the tracking uses a direct object
--   reference (def._activeTargetRef) rather than a pane ID lookup.
--
-- The context menu reads Mux._content at open-time so entries registered
-- after startup appear automatically without restarting Mudlet.
--
-- Persistence:
--   Each registration is saved to Muxlet_persistent/content.json as a catalog
--   of {name, description, singleton} pairs.  The apply/remove Lua functions
--   are not serialisable; they are always re-registered at load time.

Mux._content     = Mux._content     or {}
Mux._contentFile = Mux._persistentDir .. "/content.json"

local function saveContentCatalog()
    local catalog = {}
    for id, def in pairs(Mux._content) do
        if not def.internal then
            catalog[id] = {
                name        = def.name        or id,
                description = def.description or "",
                singleton   = def.singleton   or false,
            }
        end
    end
    local ok, err = pcall(function()
        local f = io.open(Mux._contentFile, "w")
        f:write(yajl.to_string(catalog))
        f:close()
    end)
    if not ok then Mux._err("content catalog save failed: %s", tostring(err)) end
    Mux._log("content catalog saved to %s", Mux._contentFile)
end

-- Debounced: coalesce rapid registrations at startup into one write.
local _saveTimer = nil
local function scheduleSave()
    if _saveTimer then killTimer(_saveTimer) end
    _saveTimer = tempTimer(1, function()
        _saveTimer = nil
        saveContentCatalog()
    end)
end

local function showSingletonBlocked(contentName, def, existing)
    local targetName = (existing and existing.name) or "another pane"
    if not (Mux.createDialog and Mux.dialogCss) then
        Mux._warn("'%s' is a singleton already active in '%s'", contentName, targetName)
        return
    end
    Mux._pendingSingleton = { contentName = def.name or contentName, targetName = targetName }
    local d = Mux.createDialog({
        title = "Already Open", width = 360, minimizable = false, contextMenu = false,
    })
    Mux._applyContent(d, "mux_singleton_blocked")
    d:show()
    d:raise()
end

--- Register a named content type.
-- @param name  string identifier (used in API calls and menus)
-- @param def   table with at minimum an `apply(target)` function
function Mux.registerContent(name, def)
    assert(type(name)      == "string",   "content name must be a string")
    assert(type(def)       == "table",    "content definition must be a table")
    assert(type(def.apply) == "function", "content.apply must be a function")
    Mux._content[name] = def
    Mux._log("Registered content: %s", name)
    scheduleSave()
end

--- Apply the named content to a pane or tab target.
-- If the target already has different content applied, calls that content's
-- remove() first so it can tear down event handlers, hide widgets, etc.
-- Singleton content is blocked if already active on another pane or tab;
-- a dialog tells the user where it is currently open.
-- Tracking uses a direct object reference (def._activeTargetRef) so it works
-- correctly for both panes and tabs without a registry lookup.
function Mux._applyContent(target, contentName)
    local def = Mux._content[contentName]
    if not def then
        Mux._warn("_applyContent: unknown content '%s'", contentName)
        return
    end

    -- Block non-internal content on targets where contentable is false.
    if target.contentable == false and not def.internal then
        return
    end

    -- Singleton check: block if another target still actively holds this content.
    if def.singleton and def._activeTargetRef and def._activeTargetRef ~= target then
        local existing = def._activeTargetRef
        if existing._activeContent == contentName then
            showSingletonBlocked(contentName, def, existing)
            return
        end
        -- Target no longer holds this content (destroyed or replaced); clear stale ref.
        def._activeTargetRef = nil
    end

    -- Remove whatever content is currently on this target before applying the new one.
    if target._activeContent then
        local old = Mux._content[target._activeContent]
        if old then
            if old.singleton and old._activeTargetRef == target then
                old._activeTargetRef = nil
            end
            if type(old.remove) == "function" then
                pcall(old.remove, target)
            end
        end
    end

    target._activeContent = contentName
    if def.singleton then def._activeTargetRef = target end

    local ok, err = pcall(def.apply, target)
    if not ok then
        Mux._err("content '%s' apply error: %s", contentName, tostring(err))
    end

    -- Auto-fit: if apply set _autoFitHeight and the pane is floating, resize to fit content.
    if ok and target.floating and target._autoFitHeight and target.outer then
        local theme  = Mux.activeTheme and Mux.activeTheme() or {}
        local chrome = (theme.titlebarHeight or 22) + 4
        local sw, sh = getMainWindowSize()
        local newH   = math.min(target._autoFitHeight + chrome, math.floor(sh * 0.85))
        local newW   = math.min(target._autoFitWidth or target.floatW or 380, math.floor(sw * 0.85))
        local newX   = math.floor((sw - newW) / 2)
        local newY   = math.floor((sh - newH) / 2)
        target.floatX, target.floatY = newX, newY
        target.floatW, target.floatH = newW, newH
        target._autoFitHeight = nil
        target._autoFitWidth  = nil
        target.outer:move(newX, newY)
        target.outer:resize(newW, newH)
        tempTimer(0, function()
            if target.outer then target.outer:reposition() end
        end)
    end

    Mux._scheduleAutoSave()
end

--- Return an alphabetically sorted list of user-visible registered content names.
-- Content registered with internal=true is excluded; it is used by Muxlet
-- system UI and should not appear in the Content Library context menu.
function Mux._listContent()
    local names = {}
    for name, def in pairs(Mux._content) do
        if not def.internal then names[#names+1] = name end
    end
    table.sort(names)
    return names
end

Mux.registerContent("mux_singleton_blocked", {
    internal = true,
    apply = function(target)
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        local p = Mux._pendingSingleton
        Mux._pendingSingleton = nil
        if not p then return end
        local cw = target.content:get_width()
        if cw < 50 then cw = (target.floatW or 360) - 4 end
        local msg = Geyser.Label:new({
            name=target._gid.."_msg", x=10, y=10, width=cw-20, height=50,
        }, target.content)
        msg:setStyleSheet(Mux.dialogCss.subtext)
        msg:echo(string.format(
            "<b>%s</b> is already open in <b>%s</b>.<br>Only one instance can be active at a time.",
            p.contentName, p.targetName))
        local btnW = 120
        local btn = Geyser.Label:new({
            name=target._gid.."_ok", x=math.floor((cw - btnW) / 2), y=68, width=btnW, height=32,
        }, target.content)
        btn:setStyleSheet(Mux.dialogCss.button)
        btn:echo("<center>OK</center>")
        Mux.wireDialogButton(btn, Mux.dialogCss.button, Mux.dialogCss.buttonHover)
        btn:setClickCallback(function() target:close() end)
        target._autoFitHeight = 110
    end,
    remove = function(_) end,
})

Mux._log("content loaded")
