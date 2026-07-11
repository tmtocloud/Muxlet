-- Muxlet — First-run welcome dialog
--
-- Mux._checkWelcome() is called from a tempTimer(0.3) in settings.lua, after all
-- muxletReady consumers have run. Downstream packages suppress the popup by
-- calling Mux.settings.set("mux", "welcome_shown", true) in their own muxletReady
-- handler — no separate disable flag needed.
--
-- Built as a first-class MuxDialog whose body is a widget form mounted with
-- :mountForm (ScrollBox + buildForm). That gives clean text wrapping, a real
-- titlebar close button, and automatic sizing/scrolling for free — the dialog
-- grows to fit its content up to a fraction of the screen height, then scrolls.
-- welcome.lua loads after dialog.lua and widgets.lua, so createDialog / buildForm
-- / registerWidget are all available at load time.

-- ── Palette (matches Muxlet's dark UI) ────────────────────────────────────────

local C_BODY  = "#c6d2ee"   -- body text
local C_MUTED = "#7e93c4"   -- secondary / captions
local C_TERM  = "#8fb8ff"   -- concept name / accent
local C_CODE  = "#7ab4ff"   -- command text

-- ── Copy ──────────────────────────────────────────────────────────────────────

local _INTRO =
    "Muxlet turns Mudlet into a tiling workspace. Divide the screen into panes, "
 .. "load game content into each, and arrange them however you like. Save an "
 .. "arrangement as a <i>workspace</i> and it comes back exactly as you left it "
 .. "next session. Everything is opt-in — skip the panels entirely and drive it "
 .. "all from the command line whenever you prefer."

-- Each entry becomes one "<b>Term</b> — description" line. Descriptions wrap.
local _CONCEPTS = {
    { "Panes",      "Resizable panels that hold content. Dock them to the background or let them float freely." },
    { "Tabs",       "Stack several views inside one pane and switch between them, just like a browser." },
    { "Splits",     "Divide any pane in two — side by side or stacked — to build the layout you want." },
    { "Content",    "Ready-made views you drop into a pane by right-click: the command console, GMCP readouts, and anything downstream packages provide." },
    { "Workspaces", "Named layouts you can save and reload. Your live arrangement is remembered automatically between sessions." },
}

local _REACT = {
    { "Conditions", "Named tests against live game state — GMCP fields, variables, and more." },
    { "Actions",    "Sequences of steps that fire when a condition is met: show or hide a pane, swap its content, send a command. Together they let your layout react to what happens in-game." },
}

local _CUSTOM = {
    { "Themes",   "Switch the entire look between dark, light, and your own saved palettes. Fine-tune panes and tabs under Settings \226\134\146 Design." },
    { "Settings", "Every option lives in the Settings window — open it any time with <span style='color:" .. C_CODE .. "'>mux settings</span>. Automatic update checks live on its Update tab." },
}

local _DRIVE =
    "Panes and tabs are edited straight from the UI — titlebar buttons, right-click "
 .. "menus, and the Properties panel. Session control, themes, workspaces, and "
 .. "conditions/actions are managed from the command line (or baked into a package). "
 .. "Conditions and Actions each have their own editor under the Settings window."

local _COMMANDS = {
    { "mux",             "Start Muxlet — restores your last session" },
    { "mux help",        "The full command reference" },
    { "mux settings",    "Open the Settings window" },
    { "mux workspaces",  "Browse and load saved layouts" },
    { "mux theme [name]","Show or switch the active theme" },
    { "mux version",     "Show the version and check for updates" },
}

-- ── Rich-text form widget (block, word-wrapping) ──────────────────────────────
--
-- A self-contained wrapping paragraph widget so the welcome body never depends on
-- another file having registered one. Distinct name ("welcomeText") so it can't
-- collide with or perturb the updater's own rich-text widget.

local _APPROX_W = 520

local function estimateHeight(html, width, fontPx)
    width = width or _APPROX_W
    local perPx      = (fontPx or 13) * 0.52          -- rough average glyph advance
    local charsPerLn = math.max(20, math.floor(width / perPx))
    local lines = 0
    for seg in (html .. "<br>"):gmatch("(.-)<br>") do
        local plain = seg:gsub("<[^>]->", "")
        plain = plain:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<")
                     :gsub("&gt;", ">"):gsub("&mdash;", "-"):gsub("\226\134\146", ">")
        lines = lines + math.max(1, math.ceil(math.max(1, #plain) / charsPerLn))
    end
    return lines * (fontPx and (fontPx + 7) or 20)
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
            name = c.uid .. "_wt", x = c.padL, y = 6,
            width = w, height = math.max(16, (c.thisH or 30) - 12),
        }, row)
        lbl:setStyleSheet(string.format(
            "background:transparent; border:none; color:%s; font-size:%dpx; "
            .. "qproperty-alignment:'AlignLeft|AlignTop'; qproperty-wordWrap:true;", fg, fs))
        lbl:echo(spec.html or "")
        return {}
    end, { layout = "block", rowHeight = 30 })
end

-- Render a { term, desc } list into one HTML block with hanging lines.
local function defList(items, fontPx)
    local parts = {}
    for _, e in ipairs(items) do
        parts[#parts + 1] = string.format(
            "<b><span style='color:%s'>%s</span></b>"
         .. "<span style='color:%s'> &mdash; %s</span>",
            C_TERM, e[1], C_BODY, e[2])
    end
    return table.concat(parts, "<br><br>")
end

-- Render the command list as aligned, monospaced-looking rows.
local function cmdList()
    local parts = {}
    for _, e in ipairs(_COMMANDS) do
        parts[#parts + 1] = string.format(
            "<span style='color:%s'><b>%s</b></span>"
         .. "<span style='color:%s'>&nbsp;&nbsp;&mdash;&nbsp;%s</span>",
            C_CODE, e[1], C_MUTED, e[2])
    end
    return table.concat(parts, "<br>")
end

-- ── Spec builder ──────────────────────────────────────────────────────────────

local function buildSpecs(getMode, setMode, onStart)
    local specs = {}

    local function para(html, opts)
        opts = opts or {}
        specs[#specs + 1] = {
            type = "welcomeText", html = html,
            color = opts.color, fontSize = opts.fontSize,
            rowHeight = estimateHeight(html, _APPROX_W, opts.fontSize or 13) + (opts.pad or 8),
        }
    end
    local function section(label) specs[#specs + 1] = { type = "divider", label = label } end

    para(_INTRO)

    section("The building blocks")
    para(defList(_CONCEPTS))

    section("Make it react")
    para(defList(_REACT))

    section("Make it yours")
    para(defList(_CUSTOM))

    section("Two ways to drive it")
    para(_DRIVE)

    section("Handy commands")
    para(cmdList())

    section("Getting started")
    para("Muxlet can open automatically each session, or stay out of the way until "
      .. "you ask for it. You can change this any time in Settings.",
      { color = C_MUTED })

    specs[#specs + 1] = {
        type       = "segmentedControl",
        label      = "When Mudlet opens",
        widgetWidth = 230,
        options    = {
            { label = "Open Muxlet", value = "auto"   },
            { label = "Wait for me", value = "manual" },
        },
        readFn  = function() return getMode() end,
        writeFn = function(v) setMode(v) end,
        _noReset = true,
    }

    specs[#specs + 1] = {
        type = "button", label = "Get Started", style = "primary", _noReset = true,
        onClick = onStart,
    }

    return specs
end

-- ── Dialog ──────────────────────────────────────────────────────────────────

local function buildWelcomeDialog()
    ensureWelcomeWidget()

    local selectedMode = "auto"
    local committed    = false   -- true once the user has made an explicit choice

    -- Mark the welcome as shown on ANY close (button or titlebar ×) so it never
    -- nags again; only apply the auto-start preference when the user actually
    -- confirmed a choice via Get Started.
    local function markShown()
        if Mux.settings and Mux.settings.get and not Mux.settings.get("mux", "welcome_shown") then
            Mux.settings.set("mux", "welcome_shown", true)
        end
    end

    local dialog = Mux.createDialog({
        title     = "Welcome to Muxlet",
        width     = 560,
        singleton = "mux_welcome",
        onClose   = markShown,
    })

    local function getMode() return selectedMode end
    local function setMode(v) selectedMode = v end

    local function onStart()
        committed = true
        local autoStart = (selectedMode == "auto")
        markShown()
        Mux.settings.set("mux", "auto_start", autoStart)
        pcall(function() dialog:close() end)
        if autoStart and Mux.fullStart then Mux.fullStart() end
    end

    if dialog.contentBg then
        pcall(function() dialog.contentBg:hide() end)
    end

    dialog:mountForm(buildSpecs(getMode, setMode, onStart), { prefix = "mux_welcome_f" })
    -- Refit once Geyser settles geometry (see the same note in update.lua).
    tempTimer(0, function()
        if dialog._muxRelayout then pcall(dialog._muxRelayout) end
    end)
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