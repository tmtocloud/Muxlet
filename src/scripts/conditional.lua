-- conditional.lua — Condition engine for reactive panes (#4, inline model).
--
-- A pane may carry an inline CONDITION SPEC plus two action ids:
--   pane.condition   = { type=..., path=..., value=..., event=..., seconds=... } | nil
--   pane.actionTrue  = action id run when the condition becomes true  (default mux.showSelf)
--   pane.actionFalse = action id run when the condition becomes false (default mux.hideSelf)
--
-- The condition lives ON THE PANE, defined where it is used — there is no named
-- condition registry and no separate "conditions" management screen. nil (or type
-- "always") means always visible. Condition types:
--   always        — always true
--   gmcp_exists   — gmcp value at `path` is non-nil and non-empty
--   gmcp_equals   — gmcp value at `path` equals `value`
--   event_fired   — true for `seconds` after the Mudlet event `event` fires
--   connected     — session is connected
--   disconnected  — session is not (fully) connected
--
-- ACTIONS, by contrast, are reusable named objects in the normal action registry
-- (Mux.registerAction / runAction). Built-ins (mux.showSelf / mux.hideSelf, etc.)
-- are code-defined; user actions (send / raise / lua) are DATA, created from
-- Settings → Actions and persisted to rules.json. This file owns the user-action
-- store and the built-in reactive actions; the registry itself lives in actions.lua.
--
-- Embedded panes hide via the zero-weight split layout (split.lua
-- _applyConditionWeights). Floating panes simply hide/show.

Mux._eventFiredAt   = Mux._eventFiredAt   or {}   -- event name → os.time() of last fire
Mux._condEventUsers = Mux._condEventUsers or {}   -- event name → { [paneId] = pane }
Mux._condEventWired = Mux._condEventWired or {}   -- event name → true once wired

-- The condition types offered by the pane Rules builder (also the source of truth
-- for evaluation). Exposed so the UI and engine never drift apart.
Mux.conditionTypes = {
    { value = "always",       label = "Always (always visible)" },
    { value = "gmcp_exists",  label = "GMCP has value" },
    { value = "gmcp_equals",  label = "GMCP equals value" },
    { value = "event_fired",  label = "Event fired" },
    { value = "connected",    label = "Connected" },
    { value = "disconnected", label = "Disconnected" },
}

-- Normalise a GMCP path: tolerate a leading "gmcp." (people copy it straight from
-- `lua gmcp.room.info.players`), since paths are resolved relative to the gmcp table.
local function normPath(path)
    return (tostring(path or ""):gsub("^[Gg][Mm][Cc][Pp]%.", ""))
end

local function gmcpAt(path)
    local node = gmcp
    for seg in string.gmatch(normPath(path), "[^%.]+") do
        if type(node) ~= "table" then return nil end
        node = node[seg]
    end
    return node
end
local function firstSeg(path) return (string.match(normPath(path), "^[^%.]+")) or "" end

-- Events a spec must listen to so the pane re-evaluates at the right moments.
local function eventsForSpec(spec)
    if not spec then return {} end
    local t = spec.type
    if t == "gmcp_exists" or t == "gmcp_equals" then
        -- Mudlet raises an event for the received package and each parent, but
        -- servers differ on which level carries the payload. Wire the first and
        -- first-two segments (e.g. gmcp.room and gmcp.room.info) to be safe.
        local p = normPath(spec.path)
        local s1, s2 = p:match("^([^%.]+)%.?([^%.]*)")
        local evts = {}
        if s1 and s1 ~= "" then evts[#evts+1] = "gmcp." .. s1 end
        if s2 and s2 ~= "" then evts[#evts+1] = "gmcp." .. s1 .. "." .. s2 end
        return evts
    elseif t == "event_fired" then
        return spec.event and spec.event ~= "" and { spec.event } or {}
    elseif t == "connected" or t == "disconnected" then
        return { "sysConnectionEvent", "sysDisconnectionEvent", "sysProtocolEnabled" }
    end
    return {}
end

-- Evaluate a spec to a boolean.
local function conditionMet(spec)
    if not spec then return true end
    local t = spec.type
    if t == nil or t == "always" then
        return true
    elseif t == "gmcp_exists" then
        local v = gmcpAt(spec.path)
        if v == nil then return false end
        if type(v) == "table" then return next(v) ~= nil end
        return true
    elseif t == "gmcp_equals" then
        return tostring(gmcpAt(spec.path)) == tostring(spec.value)
    elseif t == "event_fired" then
        local at = Mux._eventFiredAt[spec.event]
        return at ~= nil and (os.time() - at) <= (tonumber(spec.seconds) or 5)
    elseif t == "connected" then
        return Mux._connState == "connected"
    elseif t == "disconnected" then
        return Mux._connState ~= "connected"
    end
    return true
end
Mux._conditionMet = conditionMet   -- exposed for the Rules builder's live preview

local function wireEvent(evt)
    if Mux._condEventWired[evt] then return end
    Mux._condEventWired[evt] = true
    registerAnonymousEventHandler(evt, function()
        Mux._eventFiredAt[evt] = os.time()      -- also feeds event_fired conditions
        local users = Mux._condEventUsers[evt]
        if users then for _, p in pairs(users) do Mux._evaluatePaneCondition(p) end end
    end)
end

-- Register/deregister a pane under the events its condition needs.
function Mux._registerConditionUser(pane)
    local spec = pane and pane.condition
    if not spec then return end
    for _, evt in ipairs(eventsForSpec(spec)) do
        Mux._condEventUsers[evt] = Mux._condEventUsers[evt] or {}
        Mux._condEventUsers[evt][pane.id] = pane
        wireEvent(evt)
    end
end

function Mux._deregisterConditionUser(pane, spec)
    spec = spec or (pane and pane.condition)
    if not (spec and pane) then return end
    for _, evt in ipairs(eventsForSpec(spec)) do
        local users = Mux._condEventUsers[evt]
        if users then users[pane.id] = nil end
    end
end

function Mux._evaluatePaneCondition(pane)
    if not pane or not pane.condition then return end   -- no condition → always visible
    local met = conditionMet(pane.condition) and true or false
    if pane._conditionMet == met then return end        -- no change since last evaluation
    pane._conditionMet = met
    local actId = met and (pane.actionTrue or "mux.showSelf")
                       or (pane.actionFalse or "mux.hideSelf")
    if Mux.runAction then Mux.runAction(actId, { pane = pane, met = met }) end
end

function Mux.evaluateAllPaneConditions()
    if not Mux._panes then return end
    for _, pane in pairs(Mux._panes) do
        if pane.condition then Mux._evaluatePaneCondition(pane) end
    end
end

-- Visibility of a layout node for the zero-weight split layout.
function Mux._nodeVisible(node)
    if not node then return false end
    if node.slotA and node.slotB then
        return Mux._nodeVisible(node.childA) or Mux._nodeVisible(node.childB)
    end
    return not node._conditionHidden
end

-- ── Built-in reactive actions ─────────────────────────────────────────────────
if Mux.registerAction then
    Mux.registerAction("mux.showSelf", {
        name = "Show pane", group = "muxlet", icon = "👁",
        desc = "Show the pane. The default action when a condition becomes true.",
        run  = function(ctx) if ctx and ctx.pane and ctx.pane._conditionShow then ctx.pane:_conditionShow() end end,
    })
    Mux.registerAction("mux.hideSelf", {
        name = "Hide pane", group = "muxlet", icon = "🚫",
        desc = "Hide the pane. The default action when a condition becomes false.",
        run  = function(ctx) if ctx and ctx.pane and ctx.pane._conditionHide then ctx.pane:_conditionHide() end end,
    })
end

-- ── User-defined actions (DATA; round-trip to rules.json) ─────────────────────
-- Action kinds: send (send command), raise (raiseEvent), lua (run a Lua snippet;
-- the snippet receives the action ctx as its vararg, so `local ctx = ...` yields
-- { pane = <pane>, met = <bool> } when run from a pane rule).

Mux._declActions = Mux._declActions or {}   -- id → spec

local _rulesFile  = (Mux._persistentDir or ".") .. "/rules.json"
local _rulesDirty = false

local function buildActionRun(spec)
    local kind = spec.kind
    if kind == "send" then
        return function(_ctx) if send then send(spec.command or "") end end
    elseif kind == "raise" then
        return function(_ctx) if raiseEvent then raiseEvent(spec.event or "") end end
    elseif kind == "lua" then
        return function(ctx)
            local fn, err = loadstring(spec.code or "")
            if not fn then
                if Mux._warn then Mux._warn("action '%s' lua compile error: %s", tostring(spec.id), tostring(err)) end
                return
            end
            local ok, e2 = pcall(fn, ctx)
            if not ok and Mux._warn then Mux._warn("action '%s' lua error: %s", tostring(spec.id), tostring(e2)) end
        end
    end
    return function() end
end

local function saveRules()
    _rulesDirty = true
    tempTimer(0.5, function()
        if not _rulesDirty then return end
        _rulesDirty = false
        local acts = {}
        for _, s in pairs(Mux._declActions) do acts[#acts+1] = s end
        local ok, f = pcall(io.open, _rulesFile, "w")
        if not ok or not f then return end
        local ok2, str = pcall(yajl.to_string, { actions = acts })
        if ok2 then f:write(str) end
        f:close()
    end)
end

function Mux.createDeclarativeAction(spec, noSave)
    assert(type(spec) == "table" and spec.id and spec.id ~= "", "action needs an id")
    Mux.registerAction(spec.id, {
        name = spec.label or spec.id, group = "user", icon = "⚙",
        desc = spec.desc or "User-defined action", run = buildActionRun(spec),
    })
    Mux._declActions[spec.id] = spec
    if not noSave then saveRules() end
end

function Mux.deleteDeclarativeAction(id)
    if Mux.unregisterAction then Mux.unregisterAction(id) end
    Mux._declActions[id] = nil
    saveRules()
end

function Mux.getDeclarativeAction(id) return Mux._declActions[id] end

local function loadRules()
    local ok, f = pcall(io.open, _rulesFile, "r")
    if not ok or not f then return end
    local raw = f:read("*a"); f:close()
    if not raw or raw == "" then return end
    local ok2, data = pcall(yajl.to_value, raw)
    if not (ok2 and type(data) == "table") then return end
    for _, s in ipairs(data.actions or {}) do pcall(Mux.createDeclarativeAction, s, true) end
end
loadRules()

-- Re-evaluate once the workspace is up (covers panes restored from disk).
Mux._conditionStartHandler = registerAnonymousEventHandler("muxletStarted", function()
    tempTimer(0, function() Mux.evaluateAllPaneConditions() end)
end)