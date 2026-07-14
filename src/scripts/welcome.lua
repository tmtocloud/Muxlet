-- Muxlet — First-run welcome dialog
--
-- Mux._checkWelcome() is called from a tempTimer(0.3) in settings.lua, after all
-- muxletReady consumers have run. Downstream packages suppress the popup by
-- calling Mux.settings.set("mux", "welcome_shown", true) in their own muxletReady
-- handler — no separate disable flag needed.
--
-- Body (intro/concepts/commands) scrolls via :mountForm; the mode choice and
-- Get Started button are pinned below it via :pinFooter so they're always
-- visible and never scroll out of reach. Both specs lists are built and
-- measured (Mux.ui.formHeight) BEFORE the dialog is created, so the initial
-- height guess handed to Mux.createDialog already matches what mountForm/
-- pinFooter will compute — no big post-mount resize, no reposition fighting a
-- user who grabs the titlebar in the first moment.

-- ── Palette (matches Muxlet's dark UI) ────────────────────────────────────────

local C_BODY  = "#c6d2ee"   -- body text
local C_MUTED = "#7e93c4"   -- secondary / captions
local C_TERM  = "#8fb8ff"   -- concept name / accent
local C_CODE  = "#7ab4ff"   -- command text

-- ── Copy ──────────────────────────────────────────────────────────────────────
-- Plain, factual, one line per concept. No taglines, no "you'll love this".

local _INTRO =
    "Muxlet replaces Mudlet's single console with a grid of resizable windows, "
 .. "each showing whatever you put in it — the console, a map, GMCP data, "
 .. "anything a package provides. Save an arrangement as a workspace to reload "
 .. "it by name later. Everything below is optional and also reachable from "
 .. "the command line."

-- Each entry becomes one "<b>Term</b> — description" line. Descriptions wrap.
local _CONCEPTS = {
    { "Panes",      "A resizable window. Dock it into the layout or float it free." },
    { "Tabs",       "Several panes stacked in one spot, switched like browser tabs." },
    { "Splits",     "One pane divided into two, side by side or stacked." },
    { "Content",    "What a pane shows — the console, a GMCP readout, a map, anything a package adds. "
                 .. "Change it from the pane's titlebar or right-click menu." },
    { "Workspaces", "A saved arrangement of panes, tabs, and content, reloaded by name." },
    { "Themes",     "Colors and style for every pane and tab. Switch between built-in themes or save your own." },
    { "Anchoring",  "Pin a floating pane to another pane's edge so it stays put when that pane moves or resizes." },
}

local _REACT = {
    { "Conditions", "A named test against game state — a GMCP field, a variable, more." },
    { "Actions",    "A sequence of steps that runs when a condition is met: show or hide a pane, "
                 .. "change its content, send a command." },
}

-- Same groups/commands as `mux help` (src/aliases/mux.lua), reformatted as a
-- collapsed-by-default reference rather than duplicated as its own tour section.
local _HELP_GROUPS = {
    { group = "Session", cmds = {
        { "mux",                        "start (restores your last session)" },
        { "mux stop",                   "disable, restore the normal Mudlet console" },
        { "mux reset",                  "re-apply the reset workspace" },
        { "mux status",                 "show status overview" },
    } },
    { group = "Workspaces", cmds = {
        { "mux workspace save <name>",  "save the full UI state as a named workspace" },
        { "mux workspace load <name>",  "restore a saved workspace" },
        { "mux workspace list",         "list all registered workspaces (mux workspaces)" },
        { "mux workspace delete <name>","remove a saved workspace" },
        { "mux workspace export <name>","write a workspace as ready-to-paste Lua" },
    } },
    { group = "Conditions &amp; Actions", cmds = {
        { "mux conditions list",        "list named conditions" },
        { "mux conditions export <id>|all", "write conditions as ready-to-paste Lua" },
        { "mux actions list",           "list named actions" },
        { "mux actions export <id>|all","write actions as ready-to-paste Lua" },
        { "mux export",                 "write every theme, condition, action, and workspace to one file" },
    } },
    { group = "Themes", cmds = {
        { "mux theme [name]",           "show or switch the active theme" },
        { "mux theme save <name>",      "save the current look as a named theme" },
        { "mux theme export <name>|all","re-export a saved theme" },
        { "mux themes",                 "list all registered themes" },
    } },
    { group = "Settings", cmds = {
        { "mux settings",               "toggle the Settings window (or click the ⚙ on the main pane's titlebar)" },
        { "mux settings list [ns|all]", "list settings namespaces or values" },
        { "mux settings get ns.key",    "show one setting" },
        { "mux settings set ns.key val","change a setting" },
    } },
    { group = "Recovery", cmds = {
        { "mux panes",                  "list every pane/tab with its id and hidden state" },
        { "mux reveal <id>|all",        "restore a hidden pane/tab, or every one, to the screen" },
    } },
    { group = "Diagnostics", cmds = {
        { "mux debug [on|off]",         "toggle debug output" },
        { "mux version",                "show version and check for updates" },
    } },
}

-- ── Rich-text form widget (block, word-wrapping) ──────────────────────────────
--
-- A self-contained wrapping paragraph widget so the welcome body never depends on
-- another file having registered one. Distinct name ("welcomeText") so it can't
-- collide with or perturb the updater's own rich-text widget.

local _APPROX_W = 500

-- Tuned tight (0.46 px/char, +3px leading) rather than generous — the previous,
-- looser constants overestimated wrapped-line count and left a visible gap at
-- the end of every section before the next divider.
local function estimateHeight(html, width, fontPx)
    width = width or _APPROX_W
    local perPx      = (fontPx or 13) * 0.46
    local charsPerLn = math.max(20, math.floor(width / perPx))
    local lines = 0
    for seg in (html .. "<br>"):gmatch("(.-)<br>") do
        local plain = seg:gsub("<[^>]->", "")
        plain = plain:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<")
                     :gsub("&gt;", ">"):gsub("&mdash;", "-"):gsub("\226\134\146", ">")
        lines = lines + math.max(1, math.ceil(math.max(1, #plain) / charsPerLn))
    end
    return lines * (fontPx and (fontPx + 3) or 16)
end

local function ensureWelcomeWidget()
    if not (Mux.ui and Mux.ui.registerWidget) then return end
    if Mux.ui._widgets and Mux.ui._widgets["welcomeText"] then return end
    Mux.ui.registerWidget("welcomeText", function(row, c)
        local spec = c.spec
        local fg   = spec.color or C_BODY
        local fs   = spec.fontSize or 13
        local w    = c.formW - c.padL - c.padR
        local lbl  = Geyser.Label:new({
            name = c.uid .. "_wt", x = c.padL, y = 4, width = w, height = math.max(16, (c.thisH or 30) - 8),
        }, row)
        lbl:setStyleSheet(string.format(
            "background:transparent; border:none; color:%s; font-size:%dpx; "
            .. "qproperty-alignment:'AlignLeft|AlignTop'; qproperty-wordWrap:true;", fg, fs))
        lbl:echo(spec.html or "")
        return {}
    end, { layout = "block", rowHeight = 30 })
end

-- Render a { term, desc } list into one HTML block, one line per entry.
local function defList(items)
    local parts = {}
    for _, e in ipairs(items) do
        parts[#parts + 1] = string.format(
            "<b><span style='color:%s'>%s</span></b>"
         .. "<span style='color:%s'> &mdash; %s</span>",
            C_TERM, e[1], C_BODY, e[2])
    end
    return table.concat(parts, "<br>")
end

-- _HELP_GROUPS commands use the same "<name>" placeholder syntax as the
-- terminal `mux help` text, but this renders as HTML (unlike the terminal),
-- where bare angle brackets read as unknown tags and get swallowed. Escape them.
local function escHelp(s)
    return (s:gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Render the full `mux help` reference (_HELP_GROUPS) as one HTML block: a
-- bold group heading per group, then its commands as aligned rows.
local function helpHtml()
    local parts = {}
    for _, g in ipairs(_HELP_GROUPS) do
        parts[#parts + 1] = string.format(
            "<span style='color:%s;font-size:11px;'><b>%s</b></span>", C_MUTED, g.group)
        for _, e in ipairs(g.cmds) do
            parts[#parts + 1] = string.format(
                "<span style='color:%s'><b>%s</b></span>"
             .. "<span style='color:%s'>&nbsp;&nbsp;&mdash;&nbsp;%s</span>",
                C_CODE, escHelp(e[1]), C_MUTED, e[2])
        end
    end
    return table.concat(parts, "<br>")
end

-- ── Spec builders ─────────────────────────────────────────────────────────────

local function para(specs, html, opts)
    opts = opts or {}
    specs[#specs + 1] = {
        type = "welcomeText", html = html,
        color = opts.color, fontSize = opts.fontSize,
        rowHeight = estimateHeight(html, opts.width or _APPROX_W, opts.fontSize or 13) + (opts.pad or 2),
    }
end

local function buildBodySpecs()
    local specs = {}
    para(specs, _INTRO)

    specs[#specs + 1] = { type = "divider", label = "The building blocks" }
    para(specs, defList(_CONCEPTS))

    specs[#specs + 1] = { type = "divider", label = "Conditions & Actions" }
    para(specs, defList(_REACT))

    -- Collapsed by default: this is a reference, not part of the tour.
    -- Extra safety margin here specifically: every command line packs a bold
    -- code span plus its description onto one line, which wraps more than the
    -- shorter, lighter concept/react lists above, and estimateHeight's char-count
    -- heuristic underestimates that wrapping enough to clip the tail of this
    -- block (it was getting cut off partway through the Diagnostics group).
    -- A narrower assumed width forces the estimate to assume more wraps.
    specs[#specs + 1] = { type = "divider", label = "Full command reference", _collapsed = true }
    para(specs, helpHtml(), { fontSize = 12, width = _APPROX_W * 0.8, pad = 20 })

    return specs
end

local function buildFooterSpecs(getMode, setMode, onStart)
    return {
        {
            type       = "segmentedControl",
            label      = "On Mudlet startup",
            widgetWidth = 230,
            options    = {
                { label = "Open automatically", value = "auto"   },
                { label = "Don't auto-open",     value = "manual" },
            },
            readFn  = function() return getMode() end,
            writeFn = function(v) setMode(v) end,
            _noReset = true,
        },
        {
            type = "button", label = "Get Started", style = "primary", _noReset = true,
            onClick = onStart,
        },
    }
end

-- ── Dialog ────────────────────────────────────────────────────────────────────

local _FORM_OPTS = { dividerHeight = 22 }

-- Mirrors buildForm's own initial relayout (widgets.lua): sums every row EXCEPT
-- those belonging to a section whose divider set _collapsed = true. Used only
-- for the pre-creation height guess — Mux.ui.formHeight would count the
-- collapsed help reference as fully expanded and open the dialog too tall.
local function visibleFormHeight(specs, opts)
    local total, collapsed = 0, false
    for _, spec in ipairs(specs) do
        if spec.type == "divider" then
            collapsed = spec._collapsed == true
            total = total + (spec.rowHeight or opts.dividerHeight or 24)
        elseif not collapsed then
            total = total + Mux.ui.specHeight(spec, opts)
        end
    end
    return total
end

local function buildWelcomeDialog()
    ensureWelcomeWidget()

    local selectedMode = "auto"

    local function markShown()
        if Mux.settings and Mux.settings.get and not Mux.settings.get("mux", "welcome_shown") then
            Mux.settings.set("mux", "welcome_shown", true)
        end
    end

    local function getMode() return selectedMode end
    local function setMode(v) selectedMode = v end

    local bodySpecs   = buildBodySpecs()
    local footerSpecs = buildFooterSpecs(getMode, setMode, function() end)   -- onClick wired after dialog exists
    local bodyH   = visibleFormHeight(bodySpecs, _FORM_OPTS)
    local footerH = Mux.ui.formHeight(footerSpecs, _FORM_OPTS)

    local dialog = Mux.createDialog({
        title     = "Welcome to Muxlet",
        width     = 520,
        height    = bodyH + footerH + 40,   -- +chrome estimate; fitContent/pinFooter correct this exactly
        maxHeightPct = 0.7,
        singleton = "mux_welcome",
        onClose   = markShown,
    })

    local function onStart()
        local autoStart = (selectedMode == "auto")
        markShown()
        Mux.settings.set("mux", "auto_start", autoStart)
        pcall(function() dialog:close() end)
        if autoStart and Mux.fullStart then Mux.fullStart() end
    end
    footerSpecs[#footerSpecs].onClick = onStart

    if dialog.contentBg then
        pcall(function() dialog.contentBg:hide() end)
    end

    dialog:mountForm(bodySpecs, { prefix = "mux_welcome_f", dividerHeight = 22 })
    dialog:pinFooter(footerSpecs, { prefix = "mux_welcome_ft" })
    dialog:show()
    dialog:raise()
    return dialog
end

-- ── Public entry point ────────────────────────────────────────────────────────

function Mux._checkWelcome()
    if Mux.settings and Mux.settings.get and Mux.settings.get("mux", "welcome_shown") then return end
    if not (Mux.createDialog and Mux.ui and Mux.ui.buildForm) then return end
    buildWelcomeDialog()
end

Mux._log("mux_welcome loaded")
