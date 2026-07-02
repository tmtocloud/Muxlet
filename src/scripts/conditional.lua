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
Mux._ruleSubjects   = Mux._ruleSubjects   or {}   -- uid → subject (pane/tab) carrying rules
Mux._condEventWired = Mux._condEventWired or {}   -- event name → true once wired
Mux._ruleUidSeq     = Mux._ruleUidSeq     or 0

-- The condition types offered by the Rules UI (also the source of truth for
-- evaluation). connection_state is a VALUE condition (connected/connecting/
-- disconnected) — the engine re-fires its action on every value change, so a
-- tri-state signal is represented faithfully instead of collapsed to a boolean.
Mux.conditionTypes = {
    { value = "always",           label = "Always" },
    { value = "gmcp_exists",      label = "GMCP has value" },
    { value = "gmcp_equals",      label = "GMCP equals value" },
    { value = "event_fired",      label = "Event fired" },
    { value = "connected",        label = "Connected" },
    { value = "connecting",       label = "Connecting" },
    { value = "disconnected",     label = "Disconnected" },
    { value = "line_match",       label = "Line matches text" },
    -- connection_state is an internal value-condition used by the connection-screen
    -- preset (added via the Connection Awareness toggle); it isn't offered here.
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

-- Events a condition must listen to so its rule re-evaluates at the right moments.
local function eventsForCond(cond)
    if not cond then return {} end
    if cond.ref and Mux._resolveCond then cond = Mux._resolveCond(cond) end
    local t = cond.type
    if t == "gmcp_exists" or t == "gmcp_equals" then
        local p = normPath(cond.path)
        local s1, s2 = p:match("^([^%.]+)%.?([^%.]*)")
        local evts = {}
        if s1 and s1 ~= "" then evts[#evts+1] = "gmcp." .. s1 end
        if s2 and s2 ~= "" then evts[#evts+1] = "gmcp." .. s1 .. "." .. s2 end
        return evts
    elseif t == "event_fired" then
        return cond.event and cond.event ~= "" and { cond.event } or {}
    elseif t == "connection_state" or t == "connected" or t == "disconnected" or t == "connecting" then
        return { "sysConnectionEvent", "sysDisconnectionEvent", "sysProtocolEnabled" }
    end
    return {}
end
Mux._eventsForCond = eventsForCond

-- Evaluate a condition to a VALUE: boolean for predicates, a string for state
-- conditions (connection_state), nil/false/"" meaning "not met".
local function conditionValue(cond, subject)
    if not cond then return true end
    if cond.ref and Mux._resolveCond then cond = Mux._resolveCond(cond) end
    local t = cond.type
    if t == nil or t == "always" then
        return true
    elseif t == "gmcp_exists" then
        local v = gmcpAt(cond.path)
        if v == nil then return false end
        if type(v) == "table" then return next(v) ~= nil end
        return true
    elseif t == "gmcp_equals" then
        return tostring(gmcpAt(cond.path)) == tostring(cond.value)
    elseif t == "event_fired" then
        local at = Mux._eventFiredAt[cond.event]
        return at ~= nil and (os.time() - at) <= (tonumber(cond.seconds) or 5)
    elseif t == "connection_state" then
        return Mux._connState or "connected"
    elseif t == "connected" then
        -- Query Mudlet's live socket status; the cached _connState is geared to the
        -- connecting/connected/disconnected SCREEN and defaults to "connected" at load,
        -- which made this read true while actually offline.
        if isConnected then return isConnected() and true or false end
        return Mux._connState == "connected"
    elseif t == "connecting" then
        return Mux._connState == "connecting"
    elseif t == "disconnected" then
        if isConnected then return not isConnected() end
        return Mux._connState ~= "connected"
    elseif Mux._customConditionValue then
        -- Phase 2 hook: line_match and any future condition kinds.
        return Mux._customConditionValue(cond, subject)
    end
    return true
end
Mux._conditionValue = conditionValue
-- Back-compat boolean view (used by the Rules live preview).
function Mux._conditionMet(cond, subject)
    local v = conditionValue(cond, subject)
    return v ~= nil and v ~= false and v ~= ""
end

-- ── Rule engine ───────────────────────────────────────────────────────────────
-- A subject (pane or tab) carries subject.rules = { {id, cond, act, actElse}, … }.
-- A rule runs its action `act` when the condition becomes met (truthy) OR while met
-- its value changes; `actElse` (optional) runs when it becomes not-met. Rules are
-- independent, so a subject can react to several signals at once.

local function subjectUid(s)
    if not s._ruleUid then
        Mux._ruleUidSeq = Mux._ruleUidSeq + 1
        s._ruleUid = "ru" .. Mux._ruleUidSeq
    end
    return s._ruleUid
end

-- Tabs hold a .pane back-reference; panes don't. The action ctx exposes both so an
-- action (e.g. the connection screen) can act on a tab via its host pane.
local function ctxFor(subject, value, met)
    if subject.pane then return { tab = subject, pane = subject.pane, value = value, met = met } end
    return { pane = subject, value = value, met = met }
end

-- Pulse conditions aren't polled — an external source (a Mudlet trigger) pushes a
-- value into the engine via _fireRulePulse, which runs the rule's action once per
-- pulse with the matched value/captures in ctx. line_match is the first such kind.
Mux._pulseConditions   = Mux._pulseConditions   or { line_match = true }
-- Per-condition-kind lifecycle: install when a rule is added, tear down when removed
-- (e.g. line_match creates/kills a managed Mudlet trigger). Populated by Phase-2+.
Mux._condInstallers    = Mux._condInstallers    or {}
Mux._condUninstallers  = Mux._condUninstallers  or {}

-- Fire a rule's action immediately with a pushed value (pulse). Bypasses change
-- detection; used by trigger-backed conditions.
function Mux._fireRulePulse(subject, rule, value, extra)
    if not (rule and rule.act and Mux.runAction) then return end
    local ctx = ctxFor(subject, value, true)
    ctx.rule = rule
    if extra then for k, v in pairs(extra) do ctx[k] = v end end
    Mux.runAction(rule.act, ctx)
end

local function installCond(subject, rule)
    if rule.enabled == false then return end   -- inactive rules arm nothing
    local c  = Mux._resolveCond and Mux._resolveCond(rule.cond) or rule.cond
    local fn = c and Mux._condInstallers[c.type]
    if fn then pcall(fn, subject, rule, c) end
end
local function uninstallCond(subject, rule)
    local c  = Mux._resolveCond and Mux._resolveCond(rule.cond) or rule.cond
    local fn = c and Mux._condUninstallers[c.type]
    if fn then pcall(fn, subject, rule, c) end
end

local function evalRule(subject, rule, force)
    if rule.enabled == false then return end   -- inactive: never fires
    -- Pulse conditions don't poll; their installer pushes values via _fireRulePulse.
    local rc = Mux._resolveCond and Mux._resolveCond(rule.cond) or rule.cond
    if rc and Mux._pulseConditions[rc.type] then return end
    local v   = conditionValue(rule.cond, subject)
    local met = (v ~= nil and v ~= false and v ~= "")
    local changed = force or (not rule._evaledOnce)
        or (rule._lastMet ~= met) or (met and rule._lastVal ~= v)
    if not changed then return end
    rule._lastMet, rule._lastVal, rule._evaledOnce = met, v, true
    if met then
        if rule.act and Mux.runAction then Mux.runAction(rule.act, ctxFor(subject, v, true)) end
    elseif rule.actElse and Mux.runAction then
        Mux.runAction(rule.actElse, ctxFor(subject, v, false))
    end
end

function Mux._evaluateRules(subject, force)
    if not (subject and subject.rules) then return end
    for _, rule in ipairs(subject.rules) do evalRule(subject, rule, force) end
end
Mux._evaluatePaneCondition = Mux._evaluateRules   -- back-compat alias

function Mux.evaluateAllRules(force)
    for _, s in pairs(Mux._ruleSubjects) do Mux._evaluateRules(s, force) end
end
Mux.evaluateAllPaneConditions = Mux.evaluateAllRules   -- back-compat alias

local function wireEvent(evt)
    if Mux._condEventWired[evt] then return end
    Mux._condEventWired[evt] = true
    registerAnonymousEventHandler(evt, function()
        Mux._eventFiredAt[evt] = os.time()
        Mux.evaluateAllRules(false)
    end)
end

-- Register a subject so its rules' events are wired and it re-evaluates on signals.
function Mux._registerRuleSubject(subject)
    if not (subject and subject.rules and #subject.rules > 0) then return end
    Mux._ruleSubjects[subjectUid(subject)] = subject
    for _, rule in ipairs(subject.rules) do
        for _, evt in ipairs(eventsForCond(rule.cond)) do wireEvent(evt) end
    end
end
function Mux._deregisterRuleSubject(subject)
    if subject and subject.rules then
        for _, r in ipairs(subject.rules) do uninstallCond(subject, r) end
    end
    if subject and subject._ruleUid then Mux._ruleSubjects[subject._ruleUid] = nil end
end
-- Back-compat aliases for the old per-pane registration names.
Mux._registerConditionUser   = Mux._registerRuleSubject
Mux._deregisterConditionUser = function(subject) Mux._deregisterRuleSubject(subject) end

function Mux._findRule(subject, id)
    if not (subject and subject.rules) then return nil end
    for _, r in ipairs(subject.rules) do if r.id == id then return r end end
    return nil
end

-- Add (or replace by id) a rule, wire it, and evaluate immediately.
function Mux._addRule(subject, rule)
    subject.rules = subject.rules or {}
    if rule.id then
        for i, r in ipairs(subject.rules) do
            if r.id == rule.id then table.remove(subject.rules, i); break end
        end
    else
        Mux._ruleUidSeq = Mux._ruleUidSeq + 1
        rule.id = "r" .. Mux._ruleUidSeq
    end
    subject.rules[#subject.rules + 1] = rule
    Mux._registerRuleSubject(subject)
    installCond(subject, rule)
    Mux._evaluateRules(subject, true)
    return rule
end

function Mux._removeRule(subject, id)
    if not (subject and subject.rules) then return end
    for i, r in ipairs(subject.rules) do
        if r.id == id then uninstallCond(subject, r); table.remove(subject.rules, i); break end
    end
    if #subject.rules == 0 then Mux._deregisterRuleSubject(subject) end
end

-- Re-apply a rule in place after its enabled flag or condition params change:
-- tear down its trigger, re-arm (respecting enabled), and re-evaluate — without
-- reordering the list (so the editor's rule numbering is stable).
function Mux._reapplyRule(subject, rule)
    uninstallCond(subject, rule)
    rule._evaledOnce, rule._lastMet, rule._lastVal = false, nil, nil
    Mux._registerRuleSubject(subject)
    installCond(subject, rule)
    evalRule(subject, rule, true)
end

-- Add/remove a named preset rule (used by the connection-awareness toggle, which is
-- itself just a rule: connection_state → connection-screen action).
function Mux._setRulePreset(subject, id, rule)
    Mux._removeRule(subject, id)
    if rule then rule.id = id; Mux._addRule(subject, rule) end
end

-- Build a subject's rule list from new-style `rules` and/or legacy fields
-- (condition/actionTrue/actionFalse, connectionAware). De-duplicated by id so a
-- round-trip that persists both forms doesn't double up.
function Mux._migrateLegacyRules(subject, src)
    subject.rules = subject.rules or {}
    if src.rules then
        for _, r in ipairs(src.rules) do
            subject.rules[#subject.rules + 1] = {
                id = r.id, cond = r.cond or r.condition, act = r.act, actElse = r.actElse,
                enabled = (r.enabled ~= false),   -- saved rules default active
            }
        end
    end
    if src.condition and src.condition.type and src.condition.type ~= "always"
       and not Mux._findRule(subject, "primary") then
        subject.rules[#subject.rules + 1] = {
            id = "primary", cond = src.condition, enabled = true,
            act = src.actionTrue or "mux.showSelf", actElse = src.actionFalse or "mux.hideSelf",
        }
    end
    if src.connectionAware then
        -- Old connection-awareness flag → the equivalent explicit rules (now that
        -- awareness is just rules over the built-in Connecting/Disconnected conditions).
        if not Mux._findRule(subject, "mux:disc") then
            subject.rules[#subject.rules + 1] = { id = "mux:disc", enabled = true,
                cond = { ref = "disconnected" },
                act = "mux.overlay.disconnected.show", actElse = "mux.overlay.disconnected.hide" }
        end
        if not Mux._findRule(subject, "mux:cxn") then
            subject.rules[#subject.rules + 1] = { id = "mux:cxn", enabled = true,
                cond = { ref = "connecting" },
                act = "mux.overlay.connecting.show", actElse = "mux.overlay.connecting.hide" }
        end
        subject._connectionAware = true
    end
    if #subject.rules > 0 then Mux._registerRuleSubject(subject) end
end

-- Serializable copy of a subject's rules (runtime fields stripped). Skips the
-- volatile preview/eval bookkeeping so saved workspaces stay clean.
function Mux._serializeRules(subject)
    if not (subject and subject.rules and #subject.rules > 0) then return nil end
    local out = {}
    for _, r in ipairs(subject.rules) do
        out[#out + 1] = { id = r.id, cond = r.cond, act = r.act, actElse = r.actElse, enabled = r.enabled }
    end
    return out
end

-- Visibility of a layout node for the zero-weight split layout.
function Mux._nodeVisible(node)
    if not node then return false end
    if node.slotA and node.slotB then
        return Mux._nodeVisible(node.childA) or Mux._nodeVisible(node.childB)
    end
    return not node._conditionHidden
end

-- ── line_match: condition backed by a managed Mudlet trigger ──────────────────
-- A rule with cond = { type="line_match", pattern=…, mode="substring"|"exact"|
-- "regex" } installs a temp trigger when added and kills it when removed. On match
-- it pulses the rule's action with the matched line as ctx.value and the regex
-- captures as ctx.matches — the action then decides what to do (e.g. redirect).
local function escapeRegex(s)
    return (tostring(s or ""):gsub("[%(%)%.%%%+%-%*%?%[%]%^%$\\]", "\\%0"))
end

Mux._condInstallers.line_match = function(subject, rule, cond)
    local c    = cond or rule.cond or {}
    local pat  = c.pattern or ""
    local mode = c.mode or "substring"
    if pat == "" then return end
    local function onMatch()
        -- `line` and `matches` are Mudlet globals inside trigger handlers.
        local matched = line
        Mux._fireRulePulse(subject, rule, matched or pat, { matches = matches })
    end
    local id
    if mode == "regex" then
        if tempRegexTrigger then id = tempRegexTrigger(pat, onMatch) end
    elseif mode == "exact" then
        if tempRegexTrigger then id = tempRegexTrigger("^" .. escapeRegex(pat) .. "$", onMatch) end
    else  -- substring (literal contains)
        if tempTrigger then id = tempTrigger(pat, onMatch) end
    end
    rule._triggerId = id
end

Mux._condUninstallers.line_match = function(subject, rule)
    if rule._triggerId and killTrigger then pcall(killTrigger, rule._triggerId) end
    rule._triggerId = nil
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
-- An action is an ordered list of STEPS, each a typed operation from the palette
-- below (send a command, show/hide/zoom this pane, set content, run Lua, …). This
-- replaces the old single-kind model; legacy kind-based specs are normalised to a
-- one-step list on the fly, so old saves keep working.

Mux._declActions = Mux._declActions or {}   -- id → spec  ({ id, label, steps })

local _rulesFile  = (Mux._persistentDir or ".") .. "/rules.json"
local _rulesDirty = false

-- ── Operation palette ─────────────────────────────────────────────────────────
-- Each op: { id, label, group, icon, desc, fields = { {key,label,kind,options?,desc?} },
--            run = function(step, ctx) }. `kind` of a field tells the editor which
-- control to show: text | lua | content | theme | choice. ctx = { pane, tab, value }.
Mux.actionOps     = Mux.actionOps     or {}
Mux.actionOpOrder = Mux.actionOpOrder or {}
local function registerOp(id, def)
    def.id = id
    if not Mux.actionOps[id] then Mux.actionOpOrder[#Mux.actionOpOrder + 1] = id end
    Mux.actionOps[id] = def
end
Mux.registerActionOp = registerOp   -- packages can add their own palette ops

local function paneOf(ctx)    return ctx and ctx.pane end
local function subjectOf(ctx) return ctx and (ctx.tab or ctx.pane) end

registerOp("send", { label = "Send command", group = "Game", icon = "⌨",
    desc = "Send a command to the game, as if you typed it.",
    fields = { { key = "command", label = "Command", kind = "text" } },
    run = function(s) if send then send(s.command or "") end end })
registerOp("echo", { label = "Echo to console", group = "Game", icon = "💬",
    fields = { { key = "text", label = "Text", kind = "text" } },
    run = function(s) if cecho then cecho("\n" .. (s.text or "") .. "\n") end end })
registerOp("raise", { label = "Raise event", group = "Game", icon = "📣",
    desc = "Raise a Mudlet event other scripts (or an 'Event fired' condition) can react to.",
    fields = { { key = "event", label = "Event name", kind = "text" } },
    run = function(s) if raiseEvent and s.event and s.event ~= "" then raiseEvent(s.event) end end })

registerOp("showPane", { label = "Show this pane", group = "Pane", icon = "👁",
    run = function(_, ctx) local p = paneOf(ctx); if p and p._conditionShow then p:_conditionShow() end end })
registerOp("hidePane", { label = "Hide this pane", group = "Pane", icon = "🚫",
    run = function(_, ctx) local p = paneOf(ctx); if p and p._conditionHide then p:_conditionHide() end end })
registerOp("zoomPane", { label = "Zoom this pane", group = "Pane", icon = "🔍",
    run = function(_, ctx) local p = paneOf(ctx); if p and p.zoom then p:zoom() end end })
registerOp("unzoomPane", { label = "Un-zoom this pane", group = "Pane", icon = "🔭",
    run = function(_, ctx) local p = paneOf(ctx); if p and p._unzoom then p:_unzoom() end end })
registerOp("removePane", { label = "Remove this pane", group = "Pane", icon = "✖",
    desc = "Close the pane this action runs on.",
    run = function(_, ctx) local p = paneOf(ctx); if p and p.close then p:close() end end })

registerOp("applyContent", { label = "Set content of this pane", group = "Content", icon = "▦",
    fields = { { key = "content", label = "Content", kind = "content" } },
    run = function(s, ctx) local subj = subjectOf(ctx)
        if subj and s.content and Mux._applyContent then Mux._applyContent(subj, s.content) end end })
registerOp("createPane", { label = "Create pane with content", group = "Content", icon = "➕",
    desc = "Split this pane and put the chosen content in the new one.",
    fields = {
        { key = "content",   label = "Content",   kind = "content" },
        { key = "direction", label = "Direction", kind = "choice",
          options = { { value = "v", label = "Right" }, { value = "h", label = "Below" } } },
    },
    run = function(s, ctx)
        local p = paneOf(ctx); if not (p and p.split) then return end
        local ns = p:split(s.direction or "v")
        if ns and ns.childB and s.content then
            tempTimer(0, function() pcall(Mux._applyContent, ns.childB, s.content) end)
        end
    end })

registerOp("switchTheme", { label = "Switch theme", group = "Appearance", icon = "🎨",
    fields = { { key = "theme", label = "Theme", kind = "theme" } },
    run = function(s) if s.theme and Mux.settings and Mux.settings.set then Mux.settings.set("mux", "theme", s.theme) end end })

registerOp("lua", { label = "Run Lua", group = "Advanced", icon = "⚙",
    desc = "Run custom Lua. The action context is the vararg — write: local ctx = ...  then use ctx.pane / ctx.tab / ctx.value.",
    fields = { { key = "code", label = "Lua code", kind = "lua" } },
    run = function(s, ctx)
        local fn, err = loadstring(s.code or "")
        if not fn then if Mux._warn then Mux._warn("action lua compile: %s", tostring(err)) end return end
        local ok, e2 = pcall(fn, ctx)
        if not ok and Mux._warn then Mux._warn("action lua run: %s", tostring(e2)) end
    end })

-- Normalise a spec to a step list (converts legacy kind-based specs).
function Mux._actionSteps(spec)
    if spec.steps then return spec.steps end
    if spec.kind == "send"  then return { { op = "send",  command = spec.command } } end
    if spec.kind == "raise" then return { { op = "raise", event   = spec.event   } } end
    if spec.kind == "lua"   then return { { op = "lua",   code    = spec.code    } } end
    return {}
end

local function buildActionRun(spec)
    return function(ctx)
        for _, step in ipairs(Mux._actionSteps(spec)) do
            local op = Mux.actionOps[step.op]
            if op and op.run then
                local ok, err = pcall(op.run, step, ctx or {})
                if not ok and Mux._warn then
                    Mux._warn("action '%s' step '%s' failed: %s", tostring(spec.id), tostring(step.op), tostring(err))
                end
            end
        end
    end
end

local function saveRules()
    _rulesDirty = true
    tempTimer(0.5, function()
        if not _rulesDirty then return end
        _rulesDirty = false
        local acts = {}
        for _, s in pairs(Mux._declActions) do acts[#acts+1] = s end
        local conds = {}
        for _, c in pairs(Mux._declConditions) do conds[#conds+1] = c end
        local ok, f = pcall(io.open, _rulesFile, "w")
        if not ok or not f then return end
        local ok2, str = pcall(yajl.to_string, { actions = acts, conditions = conds })
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

-- ── Named conditions (DATA; round-trip to rules.json) ─────────────────────────
-- A named condition wraps a primitive condition spec with an id + label so it can
-- populate the rule "When" dropdown and be reused across panes/tabs. Rules store a
-- reference { ref = id }; presets/content still use inline specs.
Mux._declConditions = Mux._declConditions or {}   -- id → { id, label, cond = {type,…} }

-- Built-in named conditions: always present, read-only, and a starting example.
Mux._builtinConditions = {
    { id = "always",       label = "Always",       cond = { type = "always" } },
    { id = "connected",    label = "Connected",    cond = { type = "connected" } },
    { id = "connecting",   label = "Connecting",   cond = { type = "connecting" } },
    { id = "disconnected", label = "Disconnected", cond = { type = "disconnected" } },
}
local _builtinCondById = {}
for _, c in ipairs(Mux._builtinConditions) do _builtinCondById[c.id] = c end

-- Resolve a rule's cond to a primitive spec, following { ref = id } to a named
-- (user or built-in) condition. Inline specs pass through unchanged.
function Mux._resolveCond(cond)
    if type(cond) ~= "table" then return cond end
    if cond.ref then
        local def = Mux._declConditions[cond.ref] or _builtinCondById[cond.ref]
        return (def and def.cond) or { type = "always" }
    end
    return cond
end

function Mux.getCondition(id) return Mux._declConditions[id] or _builtinCondById[id] end

-- Built-in + user named conditions, for the editor list and the When dropdown.
function Mux.listConditions()
    local out = {}
    for _, c in ipairs(Mux._builtinConditions) do
        out[#out+1] = { id = c.id, label = c.label, cond = c.cond, builtin = true }
    end
    local ids = {}
    for id in pairs(Mux._declConditions) do ids[#ids+1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local c = Mux._declConditions[id]
        out[#out+1] = { id = id, label = c.label or id, cond = c.cond, builtin = false }
    end
    return out
end

function Mux.createDeclarativeCondition(def, noSave)
    assert(type(def) == "table" and def.id and def.id ~= "", "condition needs an id")
    Mux._declConditions[def.id] = {
        id = def.id, label = def.label or def.id, cond = def.cond or { type = "always" },
    }
    if not noSave then saveRules() end
end
function Mux.deleteDeclarativeCondition(id) Mux._declConditions[id] = nil; saveRules() end
function Mux.getDeclarativeCondition(id) return Mux._declConditions[id] end

local function loadRules()
    local ok, f = pcall(io.open, _rulesFile, "r")
    if not ok or not f then return end
    local raw = f:read("*a"); f:close()
    if not raw or raw == "" then return end
    local ok2, data = pcall(yajl.to_value, raw)
    if not (ok2 and type(data) == "table") then return end
    for _, c in ipairs(data.conditions or {}) do pcall(Mux.createDeclarativeCondition, c, true) end
    for _, s in ipairs(data.actions or {}) do pcall(Mux.createDeclarativeAction, s, true) end
end
loadRules()

-- Re-evaluate once the workspace is up (covers panes restored from disk).
Mux._conditionStartHandler = registerAnonymousEventHandler("muxletStarted", function()
    tempTimer(0, function() Mux.evaluateAllPaneConditions() end)
end)