-- Muxlet — Content registry
--
-- Any Lua file — in this package or an external one — can register a named
-- content type that users can apply to any pane or tab from the context menu:
--
--   Mux.registerContent("my_widget", {
--       name        = "My Widget",
--       description = "Fills the pane with something cool",
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
--                        target.contentBg:setStyleSheet(
--                            "background-color:rgba(0,0,0,0);border:none;")
--
-- The context menu reads Mux._content at open-time so entries registered
-- after startup appear automatically without restarting Mudlet.

Mux._content = Mux._content or {}

--- Register a named content type.
-- @param name  string identifier (used in API calls and menus)
-- @param def   table with at minimum an `apply(target)` function
function Mux.registerContent(name, def)
    assert(type(name)       == "string",   "content name must be a string")
    assert(type(def)        == "table",    "content definition must be a table")
    assert(type(def.apply)  == "function", "content.apply must be a function")
    Mux._content[name] = def
    Mux._log("Registered content: %s", name)
end

-- Backward-compat alias.
Mux.registerPreset = Mux.registerContent

--- Apply the named content to a pane or tab target.
-- If the target already has content applied, calls that content's remove()
-- first so it can tear down event handlers, hide widgets, etc.
function Mux._applyContent(target, contentName)
    local def = Mux._content[contentName]
    if not def then
        Mux._warn("_applyContent: unknown content '%s'", contentName)
        return
    end
    if target._activeContent and target._activeContent ~= contentName then
        local old = Mux._content[target._activeContent]
        if old and type(old.remove) == "function" then
            pcall(old.remove, target)
        end
    end
    target._activeContent = contentName
    local ok, err = pcall(def.apply, target)
    if not ok then
        Mux._err("content '%s' apply error: %s", contentName, tostring(err))
    end
end

-- Backward-compat alias.
Mux._applyPreset = Mux._applyContent

--- Return an alphabetically sorted list of registered content names.
function Mux._listContent()
    local names = {}
    for name in pairs(Mux._content) do names[#names+1] = name end
    table.sort(names)
    return names
end

-- Backward-compat alias.
Mux._listPresets = Mux._listContent

Mux._log("mux_content loaded")
