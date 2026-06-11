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
--                        target.contentBg:hide()
--
-- The context menu reads Mux._content at open-time so entries registered
-- after startup appear automatically without restarting Mudlet.
--
-- Persistence:
--   Each registration is saved to Muxlet_persistent/content.json as a catalog
--   of {name, description} pairs.  The apply/remove Lua functions are not
--   serialisable; they are always re-registered at load time by package code.

Mux._content     = Mux._content     or {}
Mux._contentFile = Mux._persistentDir .. "/content.json"

-- ── Catalog persistence ───────────────────────────────────────────────────────

local function saveContentCatalog()
    local catalog = {}
    for id, def in pairs(Mux._content) do
        catalog[id] = {
            name        = def.name        or id,
            description = def.description or "",
        }
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

-- ── Public API ────────────────────────────────────────────────────────────────

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

-- Backward-compat alias for external packages that used the old name.
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
    Mux._scheduleAutoSave()
end

--- Return an alphabetically sorted list of registered content names.
function Mux._listContent()
    local names = {}
    for name in pairs(Mux._content) do names[#names+1] = name end
    table.sort(names)
    return names
end

Mux._log("content loaded")
