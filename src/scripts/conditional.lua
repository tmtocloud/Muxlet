-- conditional.lua — Rule engine for reactive panes/tabs.
--
-- A pane or tab carries subject.rules = { {id, cond, act, actElse, enabled}, … }.
-- A rule runs its action `act` when `cond` becomes met, and `actElse` (optional)
-- when it becomes not-met. `cond` is either an inline spec or a { ref = id }
-- pointing at a named condition (Mux.registerCondition — see below). Condition
-- types (the `type` field of an inline/named spec):
--   always        — always true
--   gmcp_exists   — gmcp value at `path` is non-nil and non-empty
--   gmcp_equals   — gmcp value at `path` equals `value`
--   gmcp_contains — gmcp value at `path` contains any of `values` (comma list or array)
--   event_fired   — true for `seconds` after the Mudlet event `event` fires
--   connected     — session is connected
--   disconnected  — session is not (fully) connected
--   line_match    — a managed Mudlet trigger pulses the rule's action on match
--
-- ACTIONS are reusable named objects in the action registry (Mux.registerAction /
-- runAction, action.lua). Built-ins (mux.showSelf/hideSelf, etc.) and named
-- conditions' built-ins (always/connected/…) both live in library/ (one file per
-- item, registered the same way a package registers its own); this file owns the
-- registry MECHANICS only — Mux.registerCondition, Mux.registerActionOp, and the
-- user/declarative CRUD (createDeclarativeCondition/Action, rules.json).
--
-- Embedded panes hide via the zero-weight split layout (split.lua
-- _applyConditionWeights). Floating panes simply hide/show.

Mux._eventFiredAt   = Mux._eventFiredAt   or {}   -- event name → os.time() of last fire
Mux._ruleSubjects   = Mux._ruleSubjects   or {}   -- uid → subject (pane/tab) carrying rules
Mux._condEventWired = Mux._condEventWired or {}   -- event name → true once wired
Mux._ruleUidSeq     = Mux._ruleUidSeq     or 0

-- The condition types offered by the Rules UI: the source of truth for evaluation
-- AND for the editors — each entry's `fields` describes the parameter inputs the
-- Conditions editor renders (via Mux._conditionParamRows below), so a new type
-- needs no per-editor wiring. connection_state is a VALUE condition (connected/
-- connecting/disconnected) — the engine re-fires its action on every value change,
-- so a tri-state signal is represented faithfully instead of collapsed to a boolean.
local gmcpPathField = { key = "path", label = "GMCP path",
    desc = "dotted path under gmcp, e.g. room.info.players (a leading 'gmcp.' is fine)" }
Mux.conditionTypes = {
    { value = "always",           label = "Always" },
    { value = "gmcp_exists",      label = "GMCP has value",
      fields = { gmcpPathField } },
    { value = "gmcp_equals",      label = "GMCP equals value",
      fields = { gmcpPathField,
        { key = "value", label = "Equals", desc = "value to match (text)" } } },
    { value = "gmcp_contains",    label = "GMCP contains one of",
      fields = { gmcpPathField,
        { key = "values", label = "Contains any of",
          desc = "comma-separated values; true when the GMCP value contains one (case-insensitive)" } } },
    { value = "event_fired",      label = "Event fired",
      fields = {
        { key = "event", label = "Event", desc = "Mudlet event name, e.g. gmcp.char.vitals" },
        { key = "seconds", label = "Seconds", kind = "number", default = 5,
          desc = "stays true this long after the event fires" } } },
    { value = "connected",        label = "Connected" },
    { value = "connecting",       label = "Connecting" },
    { value = "disconnected",     label = "Disconnected" },
    { value = "line_match",       label = "Line matches text",
      fields = {
        { key = "mode", label = "Match mode", kind = "choice", default = "substring",
          desc = "how to match each game line",
          options = { { value = "substring", label = "Contains text" },
                      { value = "exact",     label = "Whole line equals" },
                      { value = "regex",     label = "Regex (Perl)" } } },
        { key = "pattern", label = "Pattern",
          desc = "text/regex to look for in the game output" } } },
    -- connection_state is an internal value-condition used by the connection-screen
    -- preset (added via the Connection Awareness toggle); it isn't offered here.
}

-- Editor rows for a condition's parameters, generated from its type's `fields`
-- spec. onWrite (optional) runs after any field is written (e.g. to re-arm a rule).
function Mux._conditionParamRows(cond, onWrite)
    local fields
    for _, entry in ipairs(Mux.conditionTypes) do
        if entry.value == cond.type then fields = entry.fields break end
    end
    local rows = {}
    for _, field in ipairs(fields or {}) do
        local row = { label = field.label, desc = field.desc, type = "text" }
        if field.kind == "choice" then
            row.type, row.display, row.options = "array", "dropdown", field.options
        end
        row.readFn = function()
            local v = cond[field.key]
            if v == nil then v = field.default end
            if v == nil then return "" end
            if type(v) == "table" then
                local parts = {}
                for _, item in ipairs(v) do parts[#parts+1] = tostring(item) end
                return table.concat(parts, ", ")
            end
            return tostring(v)
        end
        row.writeFn = function(v)
            if field.kind == "number" then v = tonumber(v) or field.default end
            cond[field.key] = v
            if onWrite then onWrite() end
        end
        rows[#rows+1] = row
    end
    return rows
end

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

-- Candidate list for gmcp_contains: accepts an array or a comma-separated string.
local function containsCandidates(values)
    local out = {}
    if type(values) == "table" then
        for _, candidate in ipairs(values) do out[#out+1] = tostring(candidate) end
    else
        for candidate in tostring(values or ""):gmatch("[^,]+") do
            candidate = candidate:match("^%s*(.-)%s*$")
            if candidate ~= "" then out[#out+1] = candidate end
        end
    end
    return out
end

-- Events a condition must listen to so its rule re-evaluates at the right moments.
local function eventsForCond(cond)
    if not cond then return {} end
    if cond.ref and Mux._resolveCond then cond = Mux._resolveCond(cond) end
    local t = cond.type
    if t == "gmcp_exists" or t == "gmcp_equals" or t == "gmcp_contains" then
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
        if cond.path == "gmcp.room.info.players" and Mux._echo then
            local extra = ""
            if type(v) == "table" then
                extra = string.format(" #v=%d next=%s", #v, tostring(next(v)))
            end
            Mux._echo(string.format(
                "\n<yellow>[mux diag] gmcp_exists check: v=%s type=%s%s\n",
                tostring(v), type(v), extra))
        end
        if v == nil then return false end
        if type(v) == "table" then return next(v) ~= nil end
        return true
    elseif t == "gmcp_equals" then
        return tostring(gmcpAt(cond.path)) == tostring(cond.value)
    elseif t == "gmcp_contains" then
        -- True when the value (or, for tables, any entry) contains one of the
        -- candidates, case-insensitive. Returns the matched candidate as the value.
        local v = gmcpAt(cond.path)
        if v == nil then return false end
        local candidates = containsCandidates(cond.values)
        local function matchIn(haystack)
            haystack = tostring(haystack):lower()
            for _, candidate in ipairs(candidates) do
                if haystack:find(candidate:lower(), 1, true) then return candidate end
            end
            return nil
        end
        if type(v) == "table" then
            for _, entry in pairs(v) do
                if type(entry) ~= "table" then
                    local hit = matchIn(entry)
                    if hit then return hit end
                end
            end
            return false
        end
        return matchIn(v) or false
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
        -- Extension point for a condition kind evaluated by custom logic instead of
        -- an inline branch here; unset by default. Pulse conditions (line_match)
        -- never reach this - they skip conditionValue entirely (see evalRule).
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

-- Reverse a rule's held effect when it stops being able to fire (removed, or
-- disabled/reconfigured via _reapplyRule): if it was last "met", its actElse
-- (if any) is exactly the "condition just became false" action, so run it once
-- — otherwise whatever act last fired (e.g. Hide) would linger forever with
-- nothing left to undo it. A rule with no actElse has no defined "unmet" state
-- to fall back to, so there's nothing to retire.
local function retireRule(subject, rule)
    if rule._lastMet and rule.actElse and Mux.runAction then
        Mux.runAction(rule.actElse, ctxFor(subject, rule._lastVal, false))
    end
    rule._evaledOnce, rule._lastMet, rule._lastVal = false, nil, nil
end

-- True if any of the subject's rules can still fire.
local function anyRuleEnabled(subject)
    if not subject.rules then return false end
    for _, r in ipairs(subject.rules) do
        if r.enabled ~= false then return true end
    end
    return false
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
    Mux._log("rule %s on %s: met %s -> %s (force=%s)", tostring(rule.id),
        tostring(subject.id or subject.name or subject), tostring(rule._lastMet), tostring(met), tostring(force))
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
        if r.id == id then
            retireRule(subject, r)
            uninstallCond(subject, r)
            table.remove(subject.rules, i)
            break
        end
    end
    if #subject.rules == 0 then Mux._deregisterRuleSubject(subject) end
    -- No enabled rule left to govern this subject — fall back to the engine's
    -- own default resting state (mirrors MuxPane:setCondition's legacy "no
    -- condition → visible", generalized here for the multi-rule model and for
    -- tabs too), rather than leaving it stuck in whatever the last rule set.
    if not anyRuleEnabled(subject) and subject._conditionHidden and subject._conditionShow then
        subject:_conditionShow()
    end
end

-- Re-apply a rule in place after its enabled flag or condition params change:
-- retire its held effect (see retireRule), tear down its trigger, re-arm
-- (respecting enabled), and re-evaluate — without reordering the list (so the
-- editor's rule numbering is stable).
function Mux._reapplyRule(subject, rule)
    retireRule(subject, rule)
    uninstallCond(subject, rule)
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

-- ── Rule-subject lookup ────────────────────────────────────────────────────────
-- Dispatch to whichever subject a rule actually lives on: a tab (ctx.tab) if
-- the rule was added to a tab, else its host pane (ctx.pane). ctxFor (above)
-- always sets ctx.pane = the tab's host, so ctx.tab must be checked first or a
-- tab's own rule would show/hide its host pane instead of the tab itself.
-- Exported (not local) because the show/hide/toggle actions that use it live in
-- library/actions/, outside the rule engine.
function Mux._ruleSubject(ctx) return ctx and (ctx.tab or ctx.pane) end

-- ── User-defined actions (DATA; round-trip to rules.json) ─────────────────────
-- An action is an ordered list of STEPS, each a typed operation from the palette
-- (send a command, show/hide/zoom this pane, set content, run Lua, … — see
-- library/actions/ for the built-in ops). Legacy single-kind specs are
-- normalised to a one-step list on the fly, so older saves keep working.

Mux._declActions = Mux._declActions or {}   -- id → spec  ({ id, label, steps })

local _rulesFile  = (Mux._persistentDir or ".") .. "/rules.json"
local _rulesDirty = false

-- ── Operation palette registry ──────────────────────────────────────────────────
-- Each op: { id, label, group, icon, desc, fields = { {key,label,kind,options?,desc?} },
--            run = function(step, ctx) }. `kind` of a field tells the editor which
-- control to show: text | lua | content | theme | choice. ctx = { pane, tab, value }.
Mux.actionOps     = Mux.actionOps     or {}
Mux.actionOpOrder = Mux.actionOpOrder or {}
function Mux.registerActionOp(id, def)
    def.id = id
    if not Mux.actionOps[id] then Mux.actionOpOrder[#Mux.actionOpOrder + 1] = id end
    Mux.actionOps[id] = def
end

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
        for _, c in pairs(Mux._conditions) do
            if not c.readOnly then conds[#conds+1] = c end
        end
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
    local def = Mux.getAction and Mux.getAction(id)
    if def and def.readOnly then return end   -- read-only entries aren't deletable
    if Mux.unregisterAction then Mux.unregisterAction(id) end
    Mux._declActions[id] = nil
    saveRules()
end

function Mux.getDeclarativeAction(id) return Mux._declActions[id] end

-- ── Named conditions ────────────────────────────────────────────────────────
-- A named condition wraps a primitive condition spec with an id + label so it can
-- populate the rule "When" dropdown and be reused across panes/tabs. Rules store a
-- reference { ref = id }; presets/content still use inline specs.
--
-- One registry, one registration function, for both code-defined (built-in) and
-- user-created (declarative, via Settings → Conditions) entries — same shape as
-- Mux.registerAction/registerContent/registerTheme/registerWorkspace. The only
-- difference is `readOnly = true`: not editable/deletable in the editor, and
-- excluded from the rules.json round-trip (see saveRules above) since it's code,
-- not user data. Not specific to Muxlet's own built-ins — any package can mark
-- its own registered condition readOnly the same way.
--
-- API:
--   Mux.registerCondition(id, { label, cond, readOnly })
--   Mux.unregisterCondition(id)
--   Mux.getCondition(id)                    → def | nil
--   Mux.listConditions()                    → array of { id, label, cond, readOnly } (read-only first, then alpha)
Mux._conditions = Mux._conditions or {}   -- id → { id, label, cond = {type,…}, readOnly }

function Mux.registerCondition(id, def)
    assert(type(id) == "string" and id ~= "", "condition id must be a non-empty string")
    assert(type(def) == "table", "condition def must be a table")
    def.id    = id
    def.label = def.label or id
    def.cond  = def.cond or { type = "always" }
    Mux._conditions[id] = def
    return def
end

function Mux.unregisterCondition(id) Mux._conditions[id] = nil end

-- Resolve a rule's cond to a primitive spec, following { ref = id } to a named
-- (user or built-in) condition. Inline specs pass through unchanged.
function Mux._resolveCond(cond)
    if type(cond) ~= "table" then return cond end
    if cond.ref then
        local def = Mux._conditions[cond.ref]
        return (def and def.cond) or { type = "always" }
    end
    return cond
end

function Mux.getCondition(id) return id and Mux._conditions[id] or nil end

-- Read-only + editable named conditions, for the editor list and the When
-- dropdown. Read-only entries sort first, then everything else alphabetically.
function Mux.listConditions()
    local out = {}
    for id, c in pairs(Mux._conditions) do
        out[#out+1] = { id = id, label = c.label or id, cond = c.cond, readOnly = c.readOnly or false }
    end
    table.sort(out, function(a, b)
        if a.readOnly ~= b.readOnly then return a.readOnly end
        return a.label:lower() < b.label:lower()
    end)
    return out
end

-- Editing a named condition changes what any rule referencing it ({ref=id})
-- should react to — but a rule's event wiring and cached met/value state were
-- captured when the rule was added, and don't auto-update just because the
-- condition definition changed underneath them. Re-apply every rule that
-- references this id (across every registered pane/tab) so they pick up the
-- new logic immediately instead of needing an inactive/active toggle or a
-- reload to re-sync.
function Mux._reapplyNamedCondition(id)
    if not (id and Mux._ruleSubjects and Mux._reapplyRule) then return end
    for _, subject in pairs(Mux._ruleSubjects) do
        if subject.rules then
            for _, rule in ipairs(subject.rules) do
                local c = rule.cond
                if type(c) == "table" and c.ref == id then
                    Mux._reapplyRule(subject, rule)
                end
            end
        end
    end
end

-- Thin wrapper over Mux.registerCondition for the user-facing Settings →
-- Conditions editor: registers (without readOnly=true, so it's editable/
-- deletable/exported) and persists to rules.json.
function Mux.createDeclarativeCondition(def, noSave)
    assert(type(def) == "table" and def.id and def.id ~= "", "condition needs an id")
    Mux.registerCondition(def.id, { label = def.label or def.id, cond = def.cond or { type = "always" } })
    if not noSave then saveRules() end
    Mux._reapplyNamedCondition(def.id)
end
function Mux.deleteDeclarativeCondition(id)
    local c = Mux._conditions[id]
    if not c or c.readOnly then return end   -- read-only entries aren't deletable
    Mux.unregisterCondition(id)
    saveRules()
end

-- ── Export (conditions & actions) ──────────────────────────────────────────
-- Serializes a single condition/action definition into one
-- Mux.createDeclarativeXxx(...) line — the shared building block for
-- single-item export, "export all", and Mux.exportWorkspace's dependency
-- bundling (workspace.lua), so every export path stays in sync.
function Mux._conditionRegisterLua(c)
    return "Mux.createDeclarativeCondition(" .. Mux._serializeLua({ id = c.id, label = c.label, cond = c.cond }, 0) .. ")"
end

function Mux._actionRegisterLua(a)
    return "Mux.createDeclarativeAction(" .. Mux._serializeLua({ id = a.id, label = a.label, steps = a.steps }, 0) .. ")"
end

function Mux.exportCondition(id)
    if not id or id == "" then
        Mux._echo("\n<red>[mux]<reset> Usage: mux conditions export <id>|all\n")
        return
    end
    local c = Mux._conditions[id]
    if not c or c.readOnly then
        Mux._echo(string.format(
            "\n<red>[mux]<reset> No declarative condition named '%s'.\n"
            .. "  (Built-ins can't be exported — they're already code. Use `mux conditions list`.)\n",
            id))
        return
    end
    local lua = "-- Generated by `mux conditions export " .. id .. "`.\n\n" .. Mux._conditionRegisterLua(c) .. "\n"
    local safe = id:gsub("[^%w_%-]", "_")
    local outPath = Mux._writeExportFile(safe .. "-condition-export.lua", lua)
    if outPath then
        Mux._echo(string.format(
            "\n<green>[mux]<reset> Exported condition '<cyan>%s<reset>' to:\n  <white>%s<reset>\n", id, outPath))
    end
end

function Mux.exportAllConditions()
    local ids = {}
    for cid, c in pairs(Mux._conditions) do
        if not c.readOnly then ids[#ids + 1] = cid end
    end
    table.sort(ids)
    if #ids == 0 then
        Mux._echo("\n<yellow>[mux]<reset> No declarative conditions to export.\n")
        return
    end
    local lines = { "-- Generated by `mux conditions export all`.", "" }
    for _, cid in ipairs(ids) do lines[#lines + 1] = Mux._conditionRegisterLua(Mux._conditions[cid]) end
    lines[#lines + 1] = ""
    local outPath = Mux._writeExportFile("conditions-export.lua", table.concat(lines, "\n"))
    if outPath then
        Mux._echo(string.format("\n<green>[mux]<reset> Exported %d condition(s) to:\n  <white>%s<reset>\n", #ids, outPath))
    end
end

function Mux.exportAction(id)
    if not id or id == "" then
        Mux._echo("\n<red>[mux]<reset> Usage: mux actions export <id>|all\n")
        return
    end
    local a = Mux._declActions[id]
    if not a then
        Mux._echo(string.format(
            "\n<red>[mux]<reset> No declarative action named '%s'.\n"
            .. "  (Built-ins can't be exported — they're already code. Use `mux actions list`.)\n",
            id))
        return
    end
    local lua = "-- Generated by `mux actions export " .. id .. "`.\n\n" .. Mux._actionRegisterLua(a) .. "\n"
    local safe = id:gsub("[^%w_%-]", "_")
    local outPath = Mux._writeExportFile(safe .. "-action-export.lua", lua)
    if outPath then
        Mux._echo(string.format(
            "\n<green>[mux]<reset> Exported action '<cyan>%s<reset>' to:\n  <white>%s<reset>\n", id, outPath))
    end
end

function Mux.exportAllActions()
    local ids = {}
    for aid in pairs(Mux._declActions) do ids[#ids + 1] = aid end
    table.sort(ids)
    if #ids == 0 then
        Mux._echo("\n<yellow>[mux]<reset> No declarative actions to export.\n")
        return
    end
    local lines = { "-- Generated by `mux actions export all`.", "" }
    for _, aid in ipairs(ids) do lines[#lines + 1] = Mux._actionRegisterLua(Mux._declActions[aid]) end
    lines[#lines + 1] = ""
    local outPath = Mux._writeExportFile("actions-export.lua", table.concat(lines, "\n"))
    if outPath then
        Mux._echo(string.format("\n<green>[mux]<reset> Exported %d action(s) to:\n  <white>%s<reset>\n", #ids, outPath))
    end
end

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