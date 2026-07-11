-- capture.lua - "Capture / Redirect" content.
--
-- Watches the game output and shunts matching lines into this pane/tab's capture
-- view, optionally hiding them from the main console. Built on the rule engine:
-- each configured capture is a line_match condition → mux.capture.redirect action.
--
-- The content owns its settings, like the Button Grid: a ⚙ gear on the console
-- opens a settings dialog where you manage any number of captures (pattern, match
-- mode, and whether to hide the line from the main window). Config lives on
-- target._captureConfig = { captures = { {pattern, mode, gag}, … } } and round-trips
-- through Muxlet's content serialize/restore.

-- ── Redirect action ───────────────────────────────────────────────────────────
-- Runs inside the line_match trigger handler (synchronously), so the matched line
-- is the current selection: copy it with formatting into the capture console, then
-- gag it from the main window if this capture asked for it. The per-capture gag
-- flag rides on the firing rule (ctx.rule._capture).

-- Blank-line gag: after gagging a matched line, a command's output often leaves a
-- blank line (or a couple) right after it, so the command still visibly "does
-- something". When the capture asks for it, arm a short-lived trigger that gags
-- whitespace-only lines for the next few lines and stops at the first real content.
-- (Only trailing blanks can be removed - a blank that arrived *before* the match is
-- already rendered and can't be reactively deleted.)
local _bgTrig, _bgTimer
local function _disarmBlankGag()
    if _bgTrig  and killTrigger then pcall(killTrigger, _bgTrig)  end; _bgTrig  = nil
    if _bgTimer and killTimer   then pcall(killTimer,   _bgTimer) end; _bgTimer = nil
end
local function _armBlankGag()
    if not tempRegexTrigger then return end
    _disarmBlankGag()
    local gagged = 0
    _bgTrig = tempRegexTrigger("^\\s*$", function()
        if deleteLine then deleteLine() end
        gagged = gagged + 1
        if gagged >= 3 then _disarmBlankGag() end   -- never swallow more than a couple
    end)
    -- Safety net: disarm shortly after so we never gag unrelated later blank lines.
    if tempTimer then _bgTimer = tempTimer(0.3, _disarmBlankGag) end
end

if Mux.registerAction then
    Mux.registerAction("mux.capture.redirect", {
        name = "Redirect line here", group = "muxlet", icon = "📥", hidden = true,
        desc = "Copy the matched console line into this pane/tab's capture view; optionally remove it (and trailing blank lines) from the main console. Added automatically by the Capture content.",
        run  = function(ctx)
            local subj = ctx and (ctx.tab or ctx.pane)
            local mc   = subj and subj._captureConsole
            if not mc then return end
            local cap  = (ctx.rule and ctx.rule._capture) or {}
            if selectCurrentLine then selectCurrentLine() end
            if copy then copy() end
            if appendBuffer then appendBuffer(mc.name) end      -- formatted paste
            if cap.gag then
                if deleteLine then deleteLine() end             -- remove from main console
                if cap.gagBlank then _armBlankGag() end         -- and any trailing blank lines
            end
        end,
    })
end

-- ── Capture config + rule wiring ──────────────────────────────────────────────
local MODE_OPTS = {
    { value = "substring", label = "Contains text" },
    { value = "exact",     label = "Whole line equals" },
    { value = "regex",     label = "Regex (Perl)" },
}

local function normalizeConfig(target)
    local cfg = target._captureConfig
    if type(cfg) ~= "table" then cfg = {} end
    -- Back-compat: an old single-pattern config becomes the first capture.
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
        if cap.gagBlank == nil then cap.gagBlank = false end
    end
    target._captureConfig = cfg
    return cfg
end

-- Remove every capture rule currently on the target.
local function clearCaptureRules(target)
    if not target.rules then return end
    local ids = {}
    for _, r in ipairs(target.rules) do
        if type(r.id) == "string" and r.id:find("^mux:capture") then ids[#ids+1] = r.id end
    end
    for _, id in ipairs(ids) do Mux._removeRule(target, id) end
end

-- (Re)build one rule per configured capture. Empty patterns are skipped; disabled
-- captures are added inactive (so they persist but arm no trigger).
function Mux._rebuildCaptureRules(target)
    if not target then return end
    local cfg = normalizeConfig(target)
    clearCaptureRules(target)
    for i, cap in ipairs(cfg.captures) do
        if cap.pattern and cap.pattern ~= "" then
            Mux._addRule(target, {
                id       = "mux:capture:" .. i,
                cond     = { type = "line_match", pattern = cap.pattern, mode = cap.mode or "substring" },
                act      = "mux.capture.redirect",
                enabled  = (cap.enabled ~= false),
                _capture = cap,          -- carries name + gag flags to the redirect action
            })
        end
    end
    if Mux._scheduleAutoSave then Mux._scheduleAutoSave() end
end

-- Back-compat shim for older callers.
function Mux._rebuildCaptureRule(target) Mux._rebuildCaptureRules(target) end

-- ── Settings dialog (opened from the ⚙ gear) ──────────────────────────────────
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

    local function rebuild() Mux._rebuildCaptureRules(target) end   -- re-arms the line triggers
    -- For changes the match trigger doesn't depend on (gag flags, name): the redirect
    -- reads gag flags live from the shared capture table, so only a save is needed.
    -- Avoiding a trigger re-arm here keeps a stray newline out of the capture view.
    local function light()
        if Mux._scheduleAutoSave then Mux._scheduleAutoSave() end
    end
    local renderForm
    renderForm = function()
        if d._capForm then pcall(function() d._capForm:hide() end) end
        local rows = {}
        if #cfg.captures == 0 then
            rows[#rows+1] = { type = "divider", label = "No captures yet — add one below." }
        end
        for i, cap in ipairs(cfg.captures) do
            local idx = i
            rows[#rows+1] = { type = "divider", label = (cap.name and cap.name ~= "" and cap.name) or ("Capture " .. i) }
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
                desc = "text or regex to look for in the game output (clear it to disarm this capture)",
                readFn = function() return cap.pattern or "" end,
                writeFn = function(v) cap.pattern = v; rebuild() end }
            rows[#rows+1] = { label = "Match", type = "array", display = "dropdown",
                options = MODE_OPTS,
                readFn = function() return cap.mode or "substring" end,
                writeFn = function(v) cap.mode = v; rebuild() end }
            rows[#rows+1] = { label = "Hide from main", type = "toggle",
                desc = "also remove the matched line from the main console",
                readFn = function() return cap.gag or false end,
                writeFn = function(v) cap.gag = v; light() end }
            rows[#rows+1] = { label = "Gag blank lines", type = "toggle",
                desc = "when hiding, also swallow blank lines that follow the match, so the command shows nothing",
                readFn = function() return cap.gagBlank or false end,
                writeFn = function(v) cap.gagBlank = v; light() end }
            rows[#rows+1] = { type = "button", label = "✖ Remove capture", _noReset = true,
                onClick = function() table.remove(cfg.captures, idx); rebuild(); renderForm() end }
        end
        rows[#rows+1] = { type = "divider", label = "" }
        rows[#rows+1] = { type = "button", label = "+ Add capture", _noReset = true,
            onClick = function()
                -- New captures start inactive (like rules) so they can be set up first.
                cfg.captures[#cfg.captures+1] = { name = "Capture " .. (#cfg.captures + 1),
                    pattern = "", mode = "substring", gag = false, gagBlank = false, enabled = false }
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
    description = "Watch the game output for text (substring, exact line, or regex) and shunt matching lines into this pane/tab — optionally hiding them from the main console. Click the ⚙ to configure captures.",
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
    },

    apply = function(target)
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        normalizeConfig(target)
        local safe = tostring(target.id):gsub("[^%w]", "_")
        target._captureConsole = Geyser.MiniConsole:new({
            name     = "mux_cap_" .. safe,
            x = "0%", y = "0%", width = "100%", height = "100%",
            autoWrap = true, color = "black", fontSize = 10,
        }, target.content)
        pcall(function()
            target._captureConsole:setColor(0, 0, 0)
            if target._captureConsole.setColor then target._captureConsole:setColor(8, 8, 14) end
        end)
        Mux._rebuildCaptureRules(target)
    end,

    remove = function(target)
        clearCaptureRules(target)
        target._captureConsole = nil
    end,

    serialize = function(target)
        local cfg = normalizeConfig(target)
        local out = {}
        for _, c in ipairs(cfg.captures) do
            out[#out+1] = { name = c.name, pattern = c.pattern or "", mode = c.mode or "substring",
                            gag = c.gag or false, gagBlank = c.gagBlank or false,
                            enabled = c.enabled ~= false }
        end
        return { captures = out }
    end,

    restore = function(target, data)
        if type(data) ~= "table" then return end
        local caps = data.captures
        if not caps and data.pattern then   -- legacy single-pattern payload
            caps = { { pattern = data.pattern, mode = data.mode or "substring", gag = data.gag or false } }
        end
        target._captureConfig = { captures = caps or {} }
        Mux._rebuildCaptureRules(target)
    end,
})

Mux._log("mux_capture loaded")