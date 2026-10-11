-- capture.lua - "Capture / Redirect" content.
--
-- Watches the game output and shunts matching text into this pane/tab's capture
-- view, optionally hiding it from the main console. A pattern matches the text as
-- the game meant it, even when it arrives wrapped across several lines: one shared
-- line watcher tries each new line on its own, then joined to the few unmatched
-- lines just before it, and takes every line the match reaches into.
--
-- The content owns its settings, like the Button Grid: a wrench on the console
-- opens a dialog managing any number of captures. Config lives on
-- target._captureConfig = {
--     captures = { {name, pattern, mode, enabled, gag, attention, transformAction}, ... },
--     history  = { enabled, key },
-- }
-- and round-trips through Muxlet's content serialize/restore. With history on,
-- captured lines are saved under the current history scope
-- (Mux.setCaptureHistoryScope) and replayed when the content loads.

local BLANK_GAG_LINES   = 3
local MAX_SPAN          = 4      -- most physical lines one match may reach across
local JOIN_WINDOW       = 1.0    -- seconds; the pieces of one wrapped line arrive together
local HISTORY_DAYS      = 7
local HISTORY_MAX       = 2000
local SAVE_DEBOUNCE     = 10
local CONSOLE_FONT_SIZE = 10

local hosts       = {}   -- [target] = true for every live capture surface
local recentLines = {}   -- unmatched main-console lines: { text, lineNo, at }

Mux._captureHistoryScope = Mux._captureHistoryScope or ""

-- ── Blank-line gag ────────────────────────────────────────────────────────────
-- A gagged match often leaves a trailing blank line or two in the main console.
-- Pattern triggers never fire on an empty line, so a line-offset trigger inspects
-- the next few lines directly and stops at the first real content. Blanks that
-- arrived before the match are already rendered and stay.
local _bgTrig
local function _disarmBlankGag()
    if _bgTrig and killTrigger then pcall(killTrigger, _bgTrig) end
    _bgTrig = nil
end
local function _armBlankGag()
    if not tempLineTrigger then return end
    _disarmBlankGag()
    _bgTrig = tempLineTrigger(1, BLANK_GAG_LINES, function()
        local text = getCurrentLine and getCurrentLine() or ""
        if text:match("^%s*$") then
            if deleteLine then deleteLine() end
        else
            _disarmBlankGag()
        end
    end)
end

-- ── Config ────────────────────────────────────────────────────────────────────
local MODE_OPTS = {
    { value = "substring", label = "Contains text" },
    { value = "exact",     label = "Whole line equals" },
    { value = "regex",     label = "Regex (Perl)" },
}

-- Any registered action can be picked as a capture's transform: it gets
-- ctx.value (the matched text, wrapped pieces joined with a space), ctx.matches,
-- ctx.console (the capture console to write to) and ctx.tab/ctx.pane, and returns
-- true once it has written its own output.
local function transformActionOptions()
    local out = { { value = "", label = "None (copy line as-is)" } }
    if Mux.listActions then
        for _, a in ipairs(Mux.listActions()) do
            if not a.hidden then out[#out+1] = { value = a.id, label = (a.group or "") .. " · " .. (a.name or a.id) } end
        end
    end
    return out
end

local function normalizeConfig(target)
    local cfg = target._captureConfig
    if type(cfg) ~= "table" then cfg = {} end
    -- An old single-pattern config becomes the first capture.
    if not cfg.captures then
        if cfg.pattern and cfg.pattern ~= "" then
            cfg = { captures = { { pattern = cfg.pattern, mode = cfg.mode or "substring", gag = cfg.gag or false } } }
        else
            cfg = { captures = {} }
        end
    end
    for i, cap in ipairs(cfg.captures) do
        if cap.name == nil    then cap.name = "Capture " .. i end
        if cap.enabled == nil then cap.enabled = true end
    end
    if type(cfg.history) ~= "table" then cfg.history = { enabled = false } end
    target._captureConfig = cfg
    return cfg
end

local function isArmed(cap)
    return cap.enabled ~= false and type(cap.pattern) == "string" and cap.pattern ~= ""
end

-- ── Matching ──────────────────────────────────────────────────────────────────
local regexCache = {}
local function compiledRegex(pattern)
    local cached = regexCache[pattern]
    if cached == nil then
        local ok, re = pcall(function() return rex.new(pattern) end)
        cached = (ok and re) or false
        if not cached and Mux._warn then Mux._warn("capture: invalid regex '%s'", pattern) end
        regexCache[pattern] = cached
    end
    return cached or nil
end

-- Returns start, end and a Mudlet-style matches table (whole match, then groups).
local function findMatch(cap, text)
    local pattern = cap.pattern
    if cap.mode == "regex" then
        local re = compiledRegex(pattern)
        if not re then return nil end
        local found = { re:find(text) }
        if not found[1] then return nil end
        local matches = { text:sub(found[1], found[2]) }
        for i = 3, #found do matches[#matches + 1] = found[i] end
        return found[1], found[2], matches
    elseif cap.mode == "exact" then
        if text == pattern then return 1, #text, { text } end
        return nil
    end
    local s, e = text:find(pattern, 1, true)
    if s then return s, e, { pattern } end
    return nil
end

-- Unmatched lines directly above lineNo that arrived in the same burst.
local function contiguousChain(lineNo, now)
    local chain, expect, later = {}, lineNo - 1, now
    for i = #recentLines, 1, -1 do
        local r = recentLines[i]
        if r.lineNo ~= expect or later - r.at > JOIN_WINDOW then break end
        table.insert(chain, 1, r)
        expect, later = expect - 1, r.at
    end
    return chain
end

-- Tries cap on the current line alone, then joined with each earlier chain line.
-- A joined match must reach into both its first and last line; otherwise a
-- shorter span already accounts for it.
local function matchCapture(cap, chain, current)
    local pieces = { current }
    for span = 1, #chain + 1 do
        if span > 1 then table.insert(pieces, 1, chain[#chain - span + 2].text) end
        local text = table.concat(pieces, " ")
        local s, e, matches = findMatch(cap, text)
        if s and (span == 1 or (s <= #pieces[1] and e > #text - #current)) then
            return span, text, matches
        end
    end
end

-- copy2decho reads the line under the user cursor, so earlier lines are reached
-- by moving the cursor there and back. A line that no longer holds the text it
-- was recorded with yields nil.
local function dechoOfLines(entries, lineNo)
    local out = {}
    for i, entry in ipairs(entries) do
        moveCursor("main", 0, entry.lineNo)
        if getCurrentLine() == entry.text then out[i] = copy2decho() end
    end
    moveCursor("main", 0, lineNo)
    return out
end

-- ── Rendering ─────────────────────────────────────────────────────────────────
local function transformContext(target, text, matches, console)
    local ctx = { value = text, matches = matches or { text }, console = console }
    if target.pane then ctx.tab, ctx.pane = target, target.pane else ctx.pane = target end
    return ctx
end

-- Writes one captured line to the "All" console and its capture's own console.
-- cap is nil for a history record whose capture no longer exists.
local function render(target, cap, text, matches, decho)
    local consoles = target._captureConsoles
    if not (consoles and consoles.all) then return end
    local outputs = { consoles.all }
    local capConsole = cap and consoles[cap]
    if capConsole and capConsole ~= consoles.all then outputs[#outputs + 1] = capConsole end
    for _, mc in ipairs(outputs) do
        local handled = false
        if cap and cap.transformAction and cap.transformAction ~= "" and Mux.runAction then
            local ok, result = Mux.runAction(cap.transformAction, transformContext(target, text, matches, mc))
            handled = ok and result and true or false
        end
        if not handled then
            if decho then mc:decho(decho .. "\n") else mc:echo(text .. "\n") end
        end
    end
end

-- ── History ───────────────────────────────────────────────────────────────────
local function safeName(s)
    return (tostring(s or ""):gsub("[^%w_%-]", "_"))
end

local function historyDirs(scope)
    local root = Mux._persistentDir .. "/capture_history"
    local dir  = root .. "/" .. (scope ~= "" and safeName(scope) or "_shared")
    return root, dir
end

local function historyEnabled(target)
    local hist = target._captureConfig and target._captureConfig.history
    return (hist and hist.enabled and hist.key) and true or false
end

local function pruneHistory(records)
    local cutoff = os.time() - HISTORY_DAYS * 86400
    local kept = {}
    for _, r in ipairs(records) do
        if type(r) == "table" and (r.t or 0) >= cutoff and type(r.text) == "string" then kept[#kept + 1] = r end
    end
    if #kept > HISTORY_MAX then
        local trimmed = {}
        for i = #kept - HISTORY_MAX + 1, #kept do trimmed[#trimmed + 1] = kept[i] end
        kept = trimmed
    end
    return kept
end

-- Records are tied to the scope they were loaded under, so a scope change saves
-- them back where they came from before switching.
local function loadHistory(target)
    target._historyRecords, target._historyScope = {}, Mux._captureHistoryScope
    if not historyEnabled(target) then return end
    local _, dir = historyDirs(target._historyScope)
    local path = dir .. "/" .. safeName(target._captureConfig.history.key) .. ".lua"
    local loaded = {}
    if io.exists(path) then pcall(table.load, path, loaded) end
    target._historyRecords = pruneHistory(loaded)
end

local function saveHistory(target)
    if target._historySaveTimer then killTimer(target._historySaveTimer); target._historySaveTimer = nil end
    if not (historyEnabled(target) and target._historyRecords) then return end
    target._historyRecords = pruneHistory(target._historyRecords)
    local root, dir = historyDirs(target._historyScope or Mux._captureHistoryScope)
    pcall(lfs.mkdir, root)
    pcall(lfs.mkdir, dir)
    local path = dir .. "/" .. safeName(target._captureConfig.history.key) .. ".lua"
    local ok, err = pcall(table.save, path, target._historyRecords)
    if not ok and Mux._warn then Mux._warn("capture history save failed: %s", tostring(err)) end
end

-- The disk write is debounced so a busy capture doesn't rewrite the file per line.
local function scheduleSave(target)
    if target._historySaveTimer then return end
    target._historySaveTimer = tempTimer(SAVE_DEBOUNCE, function()
        target._historySaveTimer = nil
        saveHistory(target)
    end)
end

local function appendHistory(target, cap, text, matches, decho)
    if not historyEnabled(target) then return end
    if not target._historyRecords then loadHistory(target) end
    local records = target._historyRecords
    records[#records + 1] = { t = os.time(), cap = cap.name, text = text, matches = matches, decho = decho }
    scheduleSave(target)
end

local function replayHistory(target)
    target._replayTimer = nil
    if not (target._captureConsoles and historyEnabled(target)) then return end
    for _, mc in pairs(target._captureConsoles) do pcall(function() mc:clear() end) end
    if not target._historyRecords then loadHistory(target) end
    local byName = {}
    for _, cap in ipairs(normalizeConfig(target).captures) do
        if cap.name and not byName[cap.name] then byName[cap.name] = cap end
    end
    for _, r in ipairs(target._historyRecords) do
        render(target, byName[r.cap], r.text, r.matches, r.decho)
    end
end

-- apply and restore both land here on load; defer so replay runs once, after both.
local function scheduleReplay(target)
    if target._replayTimer then return end
    target._replayTimer = tempTimer(0, function() replayHistory(target) end)
end

-- Packages that serve several characters from one profile set this (e.g. to the
-- character name) so each keeps its own capture history. "" shares one history.
function Mux.setCaptureHistoryScope(scope)
    scope = scope or ""
    if scope == Mux._captureHistoryScope then return end
    for target in pairs(hosts) do saveHistory(target) end
    Mux._captureHistoryScope = scope
    for target in pairs(hosts) do
        target._historyRecords = nil
        if historyEnabled(target) then scheduleReplay(target) end
    end
end

function Mux._flushCaptureHistory()
    for target in pairs(hosts) do saveHistory(target) end
end

-- ── Line watcher ──────────────────────────────────────────────────────────────
local function onLine()
    local current = line or ""
    local lineNo  = getLineNumber()
    local now     = getEpoch()
    local chain   = contiguousChain(lineNo, now)

    -- First armed capture per surface wins; every surface gets its own copy.
    local hits, widest, widestGag = {}, 0, 0
    for target in pairs(hosts) do
        for _, cap in ipairs(normalizeConfig(target).captures) do
            if isArmed(cap) then
                local span, text, matches = matchCapture(cap, chain, current)
                if span then
                    hits[#hits + 1] = { target = target, cap = cap, span = span, text = text, matches = matches }
                    widest = math.max(widest, span)
                    if cap.gag then widestGag = math.max(widestGag, span) end
                    break
                end
            end
        end
    end

    if #hits == 0 then
        recentLines[#recentLines + 1] = { text = current, lineNo = lineNo, at = now }
        while #recentLines > MAX_SPAN - 1 do table.remove(recentLines, 1) end
        return
    end
    recentLines = {}

    local entries = {}
    for i = #chain - widest + 2, #chain do entries[#entries + 1] = chain[i] end
    entries[#entries + 1] = { text = current, lineNo = lineNo }
    local dechos = dechoOfLines(entries, lineNo)

    for _, hit in ipairs(hits) do
        local first, decho = #entries - hit.span + 1, nil
        local pieces = {}
        for i = first, #entries do pieces[#pieces + 1] = dechos[i] end
        if #pieces == hit.span then decho = table.concat(pieces, " ") end
        render(hit.target, hit.cap, hit.text, hit.matches, decho)
        appendHistory(hit.target, hit.cap, hit.text, hit.matches, decho)
        if hit.cap.attention and Mux.setAttention then Mux.setAttention(hit.target, true) end
    end

    if widestGag > 0 then
        -- Earlier lines go first, bottom-up, so each deletion leaves the rest in place.
        local deleted = 0
        for i = #entries - 1, #entries - widestGag + 1, -1 do
            local entry = entries[i]
            moveCursor("main", 0, entry.lineNo)
            if getCurrentLine() == entry.text then
                deleteLine()
                deleted = deleted + 1
            end
        end
        moveCursor("main", 0, lineNo - deleted)
        deleteLine()
        _armBlankGag()
    end
end

if Mux._captureWatcher then pcall(killTrigger, Mux._captureWatcher); Mux._captureWatcher = nil end

local function updateWatcher()
    local armed = false
    for target in pairs(hosts) do
        for _, cap in ipairs(normalizeConfig(target).captures) do
            if isArmed(cap) then armed = true; break end
        end
        if armed then break end
    end
    if armed and not Mux._captureWatcher and tempRegexTrigger then
        Mux._captureWatcher = tempRegexTrigger("^", onLine)
    elseif not armed and Mux._captureWatcher then
        pcall(killTrigger, Mux._captureWatcher)
        Mux._captureWatcher = nil
        recentLines = {}
    end
end

function Mux._captureShutdown()
    Mux._flushCaptureHistory()
    if Mux._captureWatcher then pcall(killTrigger, Mux._captureWatcher); Mux._captureWatcher = nil end
end

if not Mux._captureExitHandler then
    Mux._captureExitHandler = registerAnonymousEventHandler("sysExitEvent", function() Mux._flushCaptureHistory() end)
end
if not Mux._captureDiscHandler then
    Mux._captureDiscHandler = registerAnonymousEventHandler("sysDisconnectionEvent", function()
        Mux._flushCaptureHistory()
    end)
end

-- ── Per-capture consoles + filter switcher ────────────────────────────────────
-- target._captureConsoles = { all = MiniConsole, [capTable] = MiniConsole, ... }
-- keyed by the capture entry's own table identity (stable across renames/reorders,
-- only invalidated when a capture is actually removed), so consoles never need
-- rebuilding just because a capture was renamed. target._captureFilter is ""
-- (show the "all" console) or a capture's current name.

local function _ensureCaptureConsole(target, cap)
    local map = target._captureConsoles
    if map[cap] then return map[cap] end
    target._captureConsoleSeq = (target._captureConsoleSeq or 0) + 1
    local safe = tostring(target.id):gsub("[^%w]", "_")
    local mc = Geyser.MiniConsole:new({
        name     = "mux_cap_" .. safe .. "_" .. target._captureConsoleSeq,
        x = "0%", y = "0%", width = "100%", height = "100%",
        autoWrap = true, color = "black", fontSize = Mux.scaledFontSize(target, CONSOLE_FONT_SIZE),
    }, target.content)
    pcall(function()
        mc:setColor(0, 0, 0)
        if mc.setColor then mc:setColor(8, 8, 14) end
    end)
    if mc.hide then mc:hide() end
    map[cap] = mc
    return mc
end

-- Show only the console for the given filter ("" = all), hiding the rest.
-- Content persists in hidden MiniConsoles, so switching back later still shows
-- everything that arrived while it was hidden.
function Mux._showCaptureFilter(target, name)
    if not (target and target._captureConsoles) then return end
    target._captureFilter = name or ""
    local map = target._captureConsoles
    for _, mc in pairs(map) do
        if mc and mc.hide then mc:hide() end
    end
    local activeMc
    if target._captureFilter ~= "" then
        local cfg = normalizeConfig(target)
        for _, cap in ipairs(cfg.captures) do
            if cap.name == target._captureFilter then activeMc = map[cap]; break end
        end
    end
    activeMc = activeMc or map.all
    if activeMc and activeMc.show then activeMc:show() end
end

-- Create/destroy per-capture consoles to match the current capture list, then
-- re-apply whatever filter is currently selected (its console may be new, or may
-- have just been removed out from under it).
local function _syncCaptureConsoles(target)
    if not target._captureConsoles then return end
    local cfg  = normalizeConfig(target)
    local map  = target._captureConsoles
    local live = { all = true }
    for _, cap in ipairs(cfg.captures) do
        _ensureCaptureConsole(target, cap)
        live[cap] = true
    end
    for key, mc in pairs(map) do
        if key ~= "all" and not live[key] then
            if mc and mc.hide then pcall(function() mc:hide() end) end
            map[key] = nil
        end
    end
    Mux._showCaptureFilter(target, target._captureFilter or "")
end

-- Cycle target._captureFilter through "" (All) then each configured capture's
-- current name, in list order.
function Mux._cycleCaptureFilter(target)
    if not target then return end
    local cfg   = normalizeConfig(target)
    local names = { "" }
    for _, cap in ipairs(cfg.captures) do names[#names+1] = cap.name or "" end
    local cur, idx = target._captureFilter or "", 1
    for i, n in ipairs(names) do
        if n == cur then idx = i; break end
    end
    idx = (idx % #names) + 1
    Mux._showCaptureFilter(target, names[idx])
    if Mux._scheduleAutoSave then Mux._scheduleAutoSave() end
end

-- Re-sync after the capture list or a pattern changed.
function Mux._rebuildCaptures(target)
    if not target then return end
    normalizeConfig(target)
    if target._captureConsoles then _syncCaptureConsoles(target) end
    updateWatcher()
    if Mux._scheduleAutoSave then Mux._scheduleAutoSave() end
end

-- ── Settings dialog (opened from the wrench) ──────────────────────────────────
local function openCaptureSettings(target)
    local cfg = normalizeConfig(target)
    local key = "mux_capture_settings_" .. tostring(target.id)
    local d = Mux.createDialog({
        title = "Capture — " .. (Mux._targetPath and Mux._targetPath(target) or tostring(target.id)),
        width = 440, height = 420, singleton = key, contextMenu = false,
    })
    if not d then return end
    if d.contentBg then d.contentBg:echo(""); d.contentBg:hide() end
    d._capGen = 0

    local function rebuild() Mux._rebuildCaptures(target) end
    -- For changes matching doesn't depend on (gag, highlight, name, transform): the
    -- watcher reads them live from the shared capture table, so only a save is needed.
    local function light()
        if Mux._scheduleAutoSave then Mux._scheduleAutoSave() end
    end
    local renderForm
    renderForm = function()
        if d._capForm then pcall(function() d._capForm:hide() end) end
        local rows = {}
        rows[#rows+1] = { type = "divider", label = "History" }
        rows[#rows+1] = { label = "Keep history", type = "toggle",
            desc = "save captured lines and show them again next session (kept " .. HISTORY_DAYS
                .. " days, up to " .. HISTORY_MAX .. " lines)",
            readFn = function() return cfg.history.enabled or false end,
            writeFn = function(v)
                if v and not cfg.history.key then
                    cfg.history.key = safeName(target.name or "capture") .. "_" .. os.time()
                end
                if not v then saveHistory(target) end
                cfg.history.enabled = v and true or false
                target._historyRecords = nil
                light()
            end }
        rows[#rows+1] = { type = "button", label = "Clear history", _noReset = true,
            onClick = function()
                target._historyRecords = {}
                target._historyScope = Mux._captureHistoryScope
                saveHistory(target)
                for _, mc in pairs(target._captureConsoles or {}) do pcall(function() mc:clear() end) end
            end }
        if #cfg.captures == 0 then
            rows[#rows+1] = { type = "divider", label = "No captures yet. Add one below." }
        end
        for i, cap in ipairs(cfg.captures) do
            local idx = i
            rows[#rows+1] = { type = "divider",
                label = (cap.name and cap.name ~= "" and cap.name) or ("Capture " .. i) }
            rows[#rows+1] = { label = "Name", type = "text",
                desc = "a label for this capture",
                readFn = function() return cap.name or "" end,
                writeFn = function(v) cap.name = v; light(); renderForm() end }
            rows[#rows+1] = { label = "Status", type = "choiceCycler",
                options = {
                    { value = false, label = "Inactive", style = "off" },
                    { value = true,  label = "Active",    style = "on"  },
                },
                readFn = function() return cap.enabled ~= false end,
                writeFn = function(v) cap.enabled = v and true or false; rebuild() end }
            rows[#rows+1] = { label = "Pattern", type = "text", allowEmpty = true,
                desc = "text or regex to look for in the game output, matched even when the game wraps "
                    .. "it across lines (clear it to disarm this capture)",
                readFn = function() return cap.pattern or "" end,
                writeFn = function(v) cap.pattern = v; rebuild() end }
            rows[#rows+1] = { label = "Match", type = "array", display = "dropdown",
                options = MODE_OPTS,
                readFn = function() return cap.mode or "substring" end,
                writeFn = function(v) cap.mode = v; rebuild() end }
            rows[#rows+1] = { label = "Hide from main", type = "toggle",
                desc = "also remove the matched lines (and any blank lines they leave behind) from the main console",
                readFn = function() return cap.gag or false end,
                writeFn = function(v) cap.gag = v; light() end }
            rows[#rows+1] = { label = "Highlight tab", type = "toggle",
                desc = "mark this tab when a line matches while the tab isn't showing",
                readFn = function() return cap.attention or false end,
                writeFn = function(v) cap.attention = v and true or nil; light() end }
            rows[#rows+1] = { label = "Transform", type = "array", display = "dropdown",
                desc = "run an action on the matched text instead of copying it verbatim (Settings → Muxlet → "
                    .. "Actions to build one: a \"Run Lua\" step gets ctx.value=the text, ctx.console=this "
                    .. "capture's console, and should return true once it has written its own output)",
                options = transformActionOptions(),
                readFn = function() return cap.transformAction or "" end,
                writeFn = function(v) cap.transformAction = (v ~= "" and v) or nil; light() end }
            rows[#rows+1] = { type = "button", label = "✖ Remove capture", _noReset = true,
                onClick = function() table.remove(cfg.captures, idx); rebuild(); renderForm() end }
        end
        rows[#rows+1] = { type = "divider", label = "" }
        rows[#rows+1] = { type = "button", label = "+ Add capture", _noReset = true,
            onClick = function()
                -- New captures start inactive (like rules) so they can be set up first.
                cfg.captures[#cfg.captures+1] = { name = "Capture " .. (#cfg.captures + 1),
                    pattern = "", mode = "substring", gag = false, enabled = false }
                rebuild(); renderForm()
            end }

        -- The dialog handles scroll + grow-to-content + snap-back centrally.
        d:mountForm(rows, { prefix = d._gid .. "_capf" })
    end
    renderForm()
    d.onClose = function() if Mux._scheduleAutoSave then Mux._scheduleAutoSave() end end
end
Mux._openCaptureSettings = openCaptureSettings

-- Resolve which host (pane or active tab) actually carries the capture console, so
-- the published titlebar gear opens the right instance's settings.
local function captureHost(ctx)
    if ctx.tab  and ctx.tab._captureConsole  then return ctx.tab  end
    if ctx.pane and ctx.pane._captureConsole  then return ctx.pane end
    return ctx.tab or ctx.pane
end

-- ── Content definition ────────────────────────────────────────────────────────
Mux.registerContent("mux_capture", {
    name        = "Capture / Redirect",
    description = "Watch the game output for text (substring, exact line, or regex) and shunt matching lines "
        .. "into this pane/tab, optionally hiding them from the main console, keeping a history and "
        .. "highlighting the tab. Click the 🔧 to configure captures.",
    group       = "Muxlet",
    singleton   = false,

    -- Publish the settings control into the pane/tab titlebar + right-click menu,
    -- the same way the console content does. A wrench (not the gear) distinguishes
    -- per-content settings from the main Muxlet settings gear.
    titlebarElements = {
        {
            id = "capture.settings", side = "left", group = "content", order = 0, priority = 105,
            icon = "🔧", tooltip = "Capture settings",
            visible = function() return true end,
            onClick = function(ctx, event)
                if not event or event.button == "LeftButton" then Mux._openCaptureSettings(captureHost(ctx)) end
            end,
            menuText = "🔧  Capture settings…", menuGroup = "info", menuOrder = 95,
            run = function(ctx) Mux._openCaptureSettings(captureHost(ctx)) end,
        },
        {
            id = "capture.filter", side = "left", group = "content", order = 1, priority = 104,
            icon = "🔎", tooltip = "Cycle capture filter (All / one capture at a time)",
            hideable = true, hideLabel = "Filter Icon",
            visible = function(ctx)
                local host = captureHost(ctx)
                local cfg  = host and normalizeConfig(host)
                return (cfg and #cfg.captures > 0) and true or false
            end,
            onClick = function(ctx, event)
                if event and event.button ~= "LeftButton" then return end
                local host = captureHost(ctx)
                if host then Mux._cycleCaptureFilter(host) end
            end,
            menuText = function(ctx)
                local host = captureHost(ctx)
                local f    = host and host._captureFilter
                return "🔎  Filter: " .. ((f and f ~= "") and f or "All")
            end,
            menuGroup = "info", menuOrder = 94,
            run = function(ctx)
                local host = captureHost(ctx)
                if host then Mux._cycleCaptureFilter(host) end
            end,
        },
    },

    apply = function(target)
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        normalizeConfig(target)
        local safe = tostring(target.id):gsub("[^%w]", "_")
        target._captureConsole = Geyser.MiniConsole:new({
            name     = "mux_cap_" .. safe,
            x = "0%", y = "0%", width = "100%", height = "100%",
            autoWrap = true, color = "black", fontSize = Mux.scaledFontSize(target, CONSOLE_FONT_SIZE),
        }, target.content)
        pcall(function()
            target._captureConsole:setColor(0, 0, 0)
            if target._captureConsole.setColor then target._captureConsole:setColor(8, 8, 14) end
        end)
        target._captureConsoles = { all = target._captureConsole }
        target._captureFilter   = target._captureFilter or ""
        hosts[target] = true
        Mux._rebuildCaptures(target)
        scheduleReplay(target)
    end,

    remove = function(target)
        saveHistory(target)
        if target._replayTimer then killTimer(target._replayTimer); target._replayTimer = nil end
        hosts[target] = nil
        updateWatcher()
        target._captureConsoles = nil
        target._captureConsole  = nil
        target._historyRecords  = nil
    end,

    onTextScale = function(target)
        local size = Mux.scaledFontSize(target, CONSOLE_FONT_SIZE)
        for _, mc in pairs(target._captureConsoles or {}) do
            pcall(function() mc:setFontSize(size) end)
        end
    end,

    serialize = function(target)
        local cfg = normalizeConfig(target)
        local out = {}
        for _, c in ipairs(cfg.captures) do
            out[#out+1] = { name = c.name, pattern = c.pattern or "", mode = c.mode or "substring",
                            gag = c.gag or false, enabled = c.enabled ~= false,
                            attention = c.attention or nil, transformAction = c.transformAction }
        end
        local hist = cfg.history
        return { captures = out, filter = target._captureFilter or "",
                 history = hist.key and { enabled = hist.enabled and true or false, key = hist.key } or nil }
    end,

    restore = function(target, data)
        if type(data) ~= "table" then return end
        local caps = data.captures
        if not caps and data.pattern then   -- legacy single-pattern payload
            caps = { { pattern = data.pattern, mode = data.mode or "substring", gag = data.gag or false } }
        end
        local hist = type(data.history) == "table" and data.history or nil
        target._captureConfig = { captures = caps or {},
            history = hist and { enabled = hist.enabled and true or false, key = hist.key } or nil }
        target._captureFilter = (type(data.filter) == "string") and data.filter or ""
        target._historyRecords = nil
        Mux._rebuildCaptures(target)
        scheduleReplay(target)
    end,
})

Mux._log("mux_capture loaded")
