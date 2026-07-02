-- Muxlet — First-run welcome dialog
--
-- Mux._checkWelcome() is called from a tempTimer(0.3) in settings.lua, after
-- all muxletReady consumers have run.  Downstream packages suppress the popup
-- by calling Mux.settings.set("mux", "welcome_shown", true) in their own
-- muxletReady handler — no separate disable flag needed.
--
-- Built as registered internal content so the pane placeholder is properly
-- cleared (same mechanism as all other content types).

-- ── Shared constants ──────────────────────────────────────────────────────────

local _INTRO_HTML =
    "<font color='#c6d2ee'>" ..
    "Muxlet is a workspace manager for Mudlet.<br>" ..
    "Divide your screen into panels, load game content into each, and save<br>" ..
    "the arrangement as a workspace. Changes persist between sessions<br>" ..
    "unless you load a different workspace. Everything is opt-in &mdash;<br>" ..
    "skip the panels entirely and work from the command line at any time." ..
    "</font>"

local _BASICS = {
    { name = "Panes",      desc = "Panels that hold game content; float freely or dock to the background" },
    { name = "Tabs",       desc = "Stack multiple views in one panel and switch between them"              },
    { name = "Splits",     desc = "Divide any pane into two, side by side or stacked"                     },
    { name = "Workspaces", desc = "Named arrangements; changes persist until you load a different one"     },
    { name = "Content",    desc = "Pre-loaded views you add to any pane via right-click"                   },
}

local _COMMANDS = {
    { cmd = "mux  /  mux start", desc = "Start Muxlet; your workspace picks up where it left off" },
    { cmd = "mux workspaces",    desc = "Browse and load saved workspaces"                         },
    { cmd = "mux help",          desc = "List all available commands"                              },
}

local _OPTIONS = {
    {
        id    = "auto",
        label = "Start automatically",
        badge = "recommended",
        desc  = "Muxlet opens with each session. You can also type  mux  at any time.",
    },
    {
        id    = "manual",
        label = "Start manually",
        badge = nil,
        desc  = "Type  mux  or  mux start  when you want to begin. Nothing opens on its own.",
    },
}

-- Card CSS — full border on unselected; left accent + highlight on selected.
local _CSS_CARD_OFF = [[
    background-color: rgba(16,20,36,85);
    border: 1px solid rgba(52,64,96,80);
    border-radius: 5px;
]]
local _CSS_CARD_ON = [[
    background-color: rgba(28,44,78,145);
    border-top: 1px solid rgba(85,132,212,120);
    border-right: 1px solid rgba(85,132,212,120);
    border-bottom: 1px solid rgba(85,132,212,120);
    border-left: 4px solid rgba(100,158,255,215);
    border-radius: 5px;
]]

local _CSS_LABEL_OFF = "background: transparent; font-size: 10px; color: rgba(95,115,165,215);"
local _CSS_LABEL_ON  = "background: transparent; font-size: 10px; font-weight: bold; color: rgba(215,228,255,255);"

-- ── Content apply function ────────────────────────────────────────────────────

local function applyWelcomeToPane(target)
    target.contentBg:echo("")
    target.contentBg:setStyleSheet("background-color:rgba(6,9,20,255);border:none;")

    local c   = target.content
    local pfx = target._gid .. "_wlc_"

    local INNER_X = "3%"
    local INNER_W = "94%"
    local y = 8

    -- ── Introduction ──────────────────────────────────────────────────────────

    local intro = Geyser.Label:new({
        name = pfx .. "intro", x = INNER_X, y = y, width = INNER_W, height = 100,
    }, c)
    intro:setStyleSheet([[
        background: transparent;
        color: rgba(198,210,238,255);
        font-size: 10px;
        padding: 4px 14px;
    ]])
    intro:rawEcho(_INTRO_HTML)
    y = y + 106

    local div1 = Geyser.Label:new({ name = pfx.."div1", x=0, y=y, width="100%", height=1 }, c)
    div1:setStyleSheet(Mux.dialogCss.divider)
    y = y + 8

    -- ── Basics ────────────────────────────────────────────────────────────────

    local basicsTitle = Geyser.Label:new({
        name = pfx.."basicsTitle", x=INNER_X, y=y, width=INNER_W, height=15,
    }, c)
    basicsTitle:setStyleSheet("background:transparent; color:rgba(115,222,148,255); font-size:9px; font-weight:bold; padding:0 14px;")
    basicsTitle:rawEcho("BASICS")
    y = y + 18

    for _, e in ipairs(_BASICS) do
        local row = Geyser.Label:new({ name=pfx.."b_"..e.name, x=INNER_X, y=y, width=INNER_W, height=17 }, c)
        row:setStyleSheet("background:transparent; font-size:9px; padding:0 14px;")
        row:echo(string.format(
            "<font color='#7ab4ff'>%-12s</font><font color='#c6d2ee'> &mdash; %s</font>",
            e.name, e.desc
        ))
        y = y + 17
    end

    local div2 = Geyser.Label:new({ name=pfx.."div2", x=0, y=y+2, width="100%", height=1 }, c)
    div2:setStyleSheet(Mux.dialogCss.divider)
    y = y + 11

    -- ── Commands ──────────────────────────────────────────────────────────────

    local cmdTitle = Geyser.Label:new({
        name=pfx.."cmdTitle", x=INNER_X, y=y, width=INNER_W, height=15,
    }, c)
    cmdTitle:setStyleSheet("background:transparent; color:rgba(115,222,148,255); font-size:9px; font-weight:bold; padding:0 14px;")
    cmdTitle:rawEcho("COMMANDS")
    y = y + 18

    for _, e in ipairs(_COMMANDS) do
        local row = Geyser.Label:new({ name=pfx.."c_"..e.cmd:gsub("[%s/]+","_"), x=INNER_X, y=y, width=INNER_W, height=17 }, c)
        row:setStyleSheet("background:transparent; font-size:9px; padding:0 14px;")
        row:echo(string.format(
            "<font color='#7ab4ff'>%-22s</font><font color='#c6d2ee'>%s</font>",
            e.cmd, e.desc
        ))
        y = y + 17
    end

    local div3 = Geyser.Label:new({ name=pfx.."div3", x=0, y=y+2, width="100%", height=1 }, c)
    div3:setStyleSheet(Mux.dialogCss.divider)
    y = y + 11

    -- ── Startup mode (card-style selection) ───────────────────────────────────

    local prompt = Geyser.Label:new({
        name=pfx.."prompt", x=INNER_X, y=y, width=INNER_W, height=18,
    }, c)
    prompt:setStyleSheet("background:transparent; color:rgba(198,210,238,200); font-size:10px; padding:0 14px;")
    prompt:rawEcho("How would you like to start?")
    y = y + 26

    local ROW_H   = 64
    local ROW_GAP = 6
    local ROW_Y0  = y

    local selectedMode = "auto"
    local cards        = {}   -- [id] = bg label
    local titleLabels  = {}   -- [id] = title label
    local checkLabels  = {}   -- [id] = check label

    local function updateSelection(chosenId)
        selectedMode = chosenId
        for _, opt in ipairs(_OPTIONS) do
            local sel = (opt.id == chosenId)
            cards[opt.id]:setStyleSheet(sel and _CSS_CARD_ON or _CSS_CARD_OFF)
            titleLabels[opt.id]:setStyleSheet(sel and _CSS_LABEL_ON or _CSS_LABEL_OFF)
            checkLabels[opt.id]:rawEcho(sel and "<center>✓</center>" or "")
        end
    end

    for i, opt in ipairs(_OPTIONS) do
        local ry = ROW_Y0 + (i - 1) * (ROW_H + ROW_GAP)

        -- Card background
        local card = Geyser.Label:new({
            name=pfx.."card_"..opt.id, x=INNER_X, y=ry, width=INNER_W, height=ROW_H,
        }, c)
        card:echo("")
        cards[opt.id] = card

        -- Title (with optional badge)
        local titleHtml = opt.label
        if opt.badge then
            titleHtml = titleHtml
                .. "  <span style='font-size:8px;font-weight:normal;"
                .. "color:rgba(130,165,230,180);font-style:italic;'>"
                .. opt.badge .. "</span>"
        end
        local title = Geyser.Label:new({
            name=pfx.."title_"..opt.id, x="8%", y=ry+10, width="78%", height=22,
        }, c)
        title:rawEcho(titleHtml)
        titleLabels[opt.id] = title

        -- Checkmark (right-aligned inside the card)
        local chk = Geyser.Label:new({
            name=pfx.."chk_"..opt.id, x="87%", y=ry+10, width=28, height=22,
        }, c)
        chk:setStyleSheet("background:transparent; color:rgba(110,168,255,240); font-size:14px; font-weight:bold;")
        checkLabels[opt.id] = chk

        -- Description
        local desc = Geyser.Label:new({
            name=pfx.."desc_"..opt.id, x="8%", y=ry+34, width="88%", height=26,
        }, c)
        desc:setStyleSheet("background:transparent; color:rgba(110,132,185,210); font-size:9px;")
        desc:rawEcho(opt.desc)

        -- Click on any part of the row selects this option
        local capturedId = opt.id
        local clickFn    = function() updateSelection(capturedId) end
        card:setClickCallback(clickFn)
        title:setClickCallback(clickFn)
        chk:setClickCallback(clickFn)
        desc:setClickCallback(clickFn)
    end

    updateSelection("auto")

    -- ── Confirm button ────────────────────────────────────────────────────────

    local btnY = ROW_Y0 + #_OPTIONS * (ROW_H + ROW_GAP) + 10
    local btn  = Geyser.Label:new({
        name=pfx.."btn", x="30%", y=btnY, width="40%", height=36,
    }, c)
    btn:setStyleSheet(Mux.dialogCss.buttonPrimary)
    btn:rawEcho("<center>Get Started</center>")
    btn:setClickCallback(function()
        local autoStart = (selectedMode == "auto")
        Mux.settings.set("mux", "welcome_shown", true)
        Mux.settings.set("mux", "auto_start",    autoStart)
        target:close()
        if autoStart and Mux.fullStart then
            Mux.fullStart()
        end
    end)
end

-- ── Dialog builder ────────────────────────────────────────────────────────────
-- Running Y budget (content area = DIALOG_H - titlebar(22) - 2*border(2) = DIALOG_H-26):
--   intro(100) +gap+ div +gap
--   basicsTitle(15) + 5×17(85) +gap+ div +gap
--   cmdTitle(15)    + 3×17(51) +gap+ div +gap
--   prompt(18) +gap
--   2 cards × (64+6)(140) + gap(10) + button(36)
--   ≈ 530px → DIALOG_H 560

local function buildWelcomeDialog()
    local dialog = Mux.createDialog({
        title  = "Welcome to Muxlet",
        width  = 540,
        height = 560,
    })
    Mux._applyContent(dialog, "mux_welcome")
    dialog:show()
    dialog:raise()
end

-- ── Public entry point ────────────────────────────────────────────────────────

function Mux._checkWelcome()
    if Mux.settings.get("mux", "welcome_shown") then return end
    if not (Mux.createDialog and Mux.registerContent) then return end

    if not Mux._content["mux_welcome"] then
        Mux.registerContent("mux_welcome", {
            internal = true,
            name     = "Welcome",
            apply    = applyWelcomeToPane,
        })
    end

    buildWelcomeDialog()
end

Mux._log("mux_welcome loaded")