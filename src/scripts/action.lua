-- Muxlet — Action Registry
--
-- A registry of named, invocable actions.  Any module — Muxlet core or a game
-- package — registers actions; UI surfaces (the Button Grid, context menus,
-- future command palettes) consume them by id.
--
-- This is the backbone of the "buttonable" idea: a package exposes capabilities
-- as actions (e.g. fed2-tools registers "fed2.galaxy.open"), and the button
-- editor lets the user bind a button to any registered action — or to a raw
-- command string — without either side knowing about the other.
--
-- Actions are referenced by id (a string), never by function value, so a button
-- binding can be persisted to disk and re-resolved on load.  An action whose
-- provider isn't loaded simply resolves to nil and is skipped (graceful
-- degradation), the same pattern used for optional cross-package features.
--
-- API:
--   Mux.registerAction(id, { name, group, run, icon, readOnly })
--   Mux.unregisterAction(id)
--   Mux.getAction(id)                       → def | nil
--   Mux.listActions()                       → array of { id, name, group, icon, readOnly } (sorted)
--   Mux.runAction(id [, ctx])               → bool ok   (ctx passed to run)
--
-- An action def:
--   id        string   unique key, e.g. "fed2.galaxy.open"  (dotted namespacing encouraged)
--   name      string   human label shown in pickers, e.g. "Open Galaxy"
--   group     string   optional grouping for pickers, e.g. "Fed2" / "Map" / "Window"
--   run       function run(ctx) — performs the action; ctx = { target=<pane>, source=<widget>, ... }
--   icon      string   optional glyph/emoji shown alongside the label
--   readOnly  bool     true = not editable/deletable in Settings → Actions. Same
--                      registration path either way — readOnly is just a flag, not
--                      a different mechanism, and not specific to Muxlet's own
--                      built-ins: any package can mark its own registered action
--                      readOnly the same way. A user-created action
--                      (Mux.createDeclarativeAction, conditional.lua) never sets
--                      it, so it's editable/deletable/exportable by default.

Mux.actions = Mux.actions or {}

function Mux.registerAction(id, def)
    assert(type(id) == "string" and id ~= "", "action id must be a non-empty string")
    assert(type(def) == "table", "action def must be a table")
    assert(type(def.run) == "function", "action '" .. id .. "' needs a run function")
    def.id    = id
    def.name  = def.name  or id
    def.group = def.group or "General"
    def.desc  = def.desc  or ""
    Mux.actions[id] = def
    if Mux._log then Mux._log("Registered action: %s (%s)", id, def.group) end
    raiseEvent("muxActionsChanged", id)
    return def
end

function Mux.unregisterAction(id)
    if Mux.actions[id] then
        Mux.actions[id] = nil
        raiseEvent("muxActionsChanged", id)
    end
end

function Mux.getAction(id)
    return id and Mux.actions[id] or nil
end

-- Sorted (by group, then name) list for pickers.
function Mux.listActions()
    local out = {}
    for id, def in pairs(Mux.actions) do
        out[#out + 1] = { id = id, name = def.name, group = def.group, icon = def.icon,
                          desc = def.desc, hidden = def.hidden, readOnly = def.readOnly or false }
    end
    table.sort(out, function(a, b)
        if a.group == b.group then return a.name:lower() < b.name:lower() end
        return a.group:lower() < b.group:lower()
    end)
    return out
end

-- Invoke an action by id.  Unknown ids are a no-op (returns false) so persisted
-- bindings to not-yet-loaded providers never error.
function Mux.runAction(id, ctx)
    local def = Mux.actions[id]
    if not def then
        if Mux.debug and Mux._echo then
            Mux._echo("\n<yellow>[Muxlet]<reset> action not found: " .. tostring(id) .. "\n")
        end
        return false
    end
    local ok, err = pcall(def.run, ctx or {})
    if not ok and Mux._err then Mux._err("action '%s' failed: %s", id, tostring(err)) end
    return ok
end

-- Built-in actions live in library/actions/ (see that folder for reconnect,
-- clearConsole, show/hide/toggle pane, and the step-op palette) — this file is
-- the registry mechanism only.

if Mux._log then Mux._log("action registry loaded") end