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
--   Mux.registerAction(id, { name, group, run, icon })
--   Mux.unregisterAction(id)
--   Mux.getAction(id)                       → def | nil
--   Mux.listActions()                       → array of { id, name, group, icon } (sorted)
--   Mux.runAction(id [, ctx])               → bool ok   (ctx passed to run)
--
-- An action def:
--   id     string   unique key, e.g. "fed2.galaxy.open"  (dotted namespacing encouraged)
--   name   string   human label shown in pickers, e.g. "Open Galaxy"
--   group  string   optional grouping for pickers, e.g. "Fed2" / "Map" / "Window"
--   run    function run(ctx) — performs the action; ctx = { target=<pane>, source=<widget>, ... }
--   icon   string   optional glyph/emoji shown alongside the label

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
        out[#out + 1] = { id = id, name = def.name, group = def.group, icon = def.icon, desc = def.desc }
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

-- ── Built-in actions ──────────────────────────────────────────────────────────
-- A small generic set so the action picker is populated out of the box and the
-- end-to-end path is demonstrable before any package registers its own.  Each
-- carries a `desc` shown on hover in the action picker.
Mux.registerAction("mux.reconnect", {
    name = "Reconnect", group = "Muxlet", icon = "🔌",
    desc = "Reconnect to the current game server.",
    run = function() reconnect() end,
})
Mux.registerAction("mux.clearConsole", {
    name = "Clear Console", group = "Muxlet", icon = "🧹",
    desc = "Clear the main console window.",
    run = function() clearWindow() end,
})
Mux.registerAction("mux.demoEcho", {
    name = "Demo — Echo to Console", group = "Muxlet", icon = "💬",
    desc = "Example action. Prints a line to the console to show a button is wired "
        .. "to a registered action (vs a raw command). Safe to ignore or rebind.",
    run = function() Mux._echo("\n<cyan>[Muxlet]<reset> Demo action ran — a button is bound to a registered action.\n") end,
})

if Mux._log then Mux._log("action registry loaded") end