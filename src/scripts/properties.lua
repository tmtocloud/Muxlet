-- Muxlet — Properties dialog
-- Floating editor for per-pane and per-tab properties.
-- Uses the content system so contentBg is properly suppressed.
--
-- Opened via:
--   Mux.showPaneProperties(pane)
--   Mux.showTabProperties(host, tab)
--
-- Requires: content.lua (Mux.registerContent, Mux._applyContent) loaded first.

local propsUi      = { window = nil }
local pendingRows  = nil   -- rows passed to the registered apply function
local _propsEpoch  = 0     -- incremented each open to avoid widget name collisions on ID reuse
local _pendingPrefix = nil -- set before _applyContent so apply() uses a unique prefix

-- ── CSS (re-derived from active theme on each open) ───────────────────────────

local function makeCss()
    local theme = Mux.activeTheme()
    local sui   = theme.settingsUi or {}

    local rowOdd   = sui.rowOdd          or "rgb(16,16,24)"
    local rowEven  = sui.rowEven         or "rgb(34,34,50)"
    local divider  = sui.rowDivider      or "rgba(255,255,255,0.12)"
    local text     = sui.textColor       or "rgba(215,215,230,0.92)"
    local widgetBg = sui.widgetBg        or "rgb(38,38,58)"
    local widgetFg = sui.widgetFg        or "#d8d8f0"
    local widgetBd = sui.widgetBorder    or "rgba(255,255,255,0.22)"
    local widgetHv = sui.widgetHoverBg   or "rgb(55,55,80)"
    local inputBg  = sui.inputBg         or "rgb(12,12,18)"
    local inputFg  = sui.inputFg         or "#c8c8d0"
    local inputBd  = sui.inputBorder     or "rgba(255,255,255,0.46)"
    local tOnBg    = sui.toggleOnBg       or "rgb(30,70,40)"
    local tOnFg    = sui.toggleOnFg       or "#88ee88"
    local tOnBd    = sui.toggleOnBorder   or "rgba(80,180,80,0.5)"
    local tOnHv    = sui.toggleOnHoverBg  or "rgb(40,90,50)"
    local tOffBg   = sui.toggleOffBg      or "rgb(65,30,30)"
    local tOffFg   = sui.toggleOffFg      or "rgba(220,120,120,0.9)"
    local tOffBd   = sui.toggleOffBorder  or "rgba(180,80,80,0.4)"
    local tOffHv   = sui.toggleOffHoverBg or "rgb(85,40,40)"
    local descText = sui.descTextColor    or "rgba(120,130,170,0.85)"
    local hiIconFg = sui.helpIconFg       or "rgba(120,160,255,0.85)"
    local hiIconBg = sui.helpIconBg       or "rgba(55,75,120,0.55)"
    local hiIconBd = sui.helpIconBorder   or "rgba(80,115,200,0.35)"

    return {
        bg       = sui.bg or "rgb(18,18,26)",
        odd      = string.format("background:%s;border:none;border-bottom:1px solid %s;", rowOdd,  divider),
        even     = string.format("background:%s;border:none;border-bottom:1px solid %s;", rowEven, divider),
        rowLabel = string.format("background:transparent;color:%s;font-size:11px;font-weight:bold;", text),
        rowDesc  = string.format("background:transparent;color:%s;font-size:10px;", descText),
        helpIcon = string.format(
            "QLabel{background:%s;color:%s;font-size:10px;font-weight:bold;border-radius:3px;border:1px solid %s;}"
            .. "QLabel::hover{background:%s;color:%s;}",
            hiIconBg, hiIconFg, hiIconBd, hiIconBg, hiIconFg),
        togOnFg  = tOnFg,
        togOffFg = tOffFg,
        widgetFg = widgetFg,
        toggleOn  = string.format(
            "QLabel{background:%s;color:%s;font-size:10px;font-weight:bold;border:1px solid %s;border-radius:3px;}"
            .. "QLabel::hover{background:%s;}",
            tOnBg, tOnFg, tOnBd, tOnHv),
        toggleOff = string.format(
            "QLabel{background:%s;color:%s;font-size:10px;font-weight:bold;border:1px solid %s;border-radius:3px;}"
            .. "QLabel::hover{background:%s;}",
            tOffBg, tOffFg, tOffBd, tOffHv),
        textInput = string.format(
            "background-color:%s;color:%s;font-size:12px;border:1px solid %s;border-radius:3px;"
            .. "padding-left:6px;padding-right:4px;",
            inputBg, inputFg, inputBd),
        applyBtn = string.format(
            "QLabel{background-color:%s;border:1px solid %s;border-radius:3px;color:%s;font-size:9px;"
            .. "font-weight:bold;}QLabel::hover{background-color:%s;border-color:rgba(120,180,255,200);color:%s;}",
            widgetBg, widgetBd, widgetFg, widgetHv, widgetFg),
    }
end

-- ── Layout constants ──────────────────────────────────────────────────────────

local rowHToggle = 42
local rowHText   = 64
local padL       = 10
local padR       = 6
local widgetW    = 110
local widgetH    = 24
local applyW     = 42
local inputGap   = 3

local function rowHeight(propType)
    return propType == "text" and rowHText or rowHToggle
end

-- ── Widget builders ───────────────────────────────────────────────────────────

local function addToggle(parent, x, y, uid, css, readFn, writeFn, trueLabel, falseLabel)
    trueLabel  = trueLabel  or "TRUE"
    falseLabel = falseLabel or "FALSE"
    local w = Geyser.Label:new({ name=uid.."_t", x=x, y=y, width=widgetW, height=widgetH }, parent)
    local function refresh()
        local v = readFn()
        w:setStyleSheet(v and css.toggleOn or css.toggleOff)
        w:echo(string.format(
            "<center><span style='color:%s;font-size:10px;font-weight:bold;'>%s</span></center>",
            v and css.togOnFg or css.togOffFg, v and trueLabel or falseLabel))
    end
    refresh()
    w:setClickCallback(function() writeFn(not readFn()); refresh() end)
end

local function addTextInput(parent, x, y, uid, css, readFn, writeFn, availW)
    local inputW = availW - applyW - inputGap
    local input  = Geyser.CommandLine:new({ name=uid.."_i", x=x, y=y, width=inputW, height=widgetH }, parent)
    input:setStyleSheet(css.textInput)
    input:print(tostring(readFn() or ""))
    local btn = Geyser.Label:new({ name=uid.."_a", x=x+inputW+inputGap, y=y, width=applyW, height=widgetH }, parent)
    btn:setStyleSheet(css.applyBtn)
    btn:echo(string.format(
        "<center><span style='color:%s;font-size:9px;font-weight:bold;'>Apply</span></center>",
        css.widgetFg))
    local function commit()
        local text = input:getText()
        if not text or text == "" then return end
        writeFn(text)
        input:print(tostring(readFn() or ""))
    end
    input:setAction(commit)
    btn:setClickCallback(commit)
end

-- ── Row builder ───────────────────────────────────────────────────────────────
-- Each entry: { label, desc, type="toggle"|"text", readFn, writeFn }
-- Returns total height of all rows built.

local function buildRows(contentLbl, contentW, rows, css, prefix)
    local yPos    = 0
    local nameW   = contentW - padL - widgetW - 8 - padR
    local widgetX = contentW - widgetW - padR
    local inputAvail = contentW - padL - padR

    for idx, prop in ipairs(rows) do
        local isText = (prop.type == "text")
        local thisH  = rowHeight(prop.type)
        local uid    = prefix .. "_p" .. idx

        local rowLbl = Geyser.Label:new({
            name=uid.."_row", x=0, y=yPos, width=contentW, height=thisH,
        }, contentLbl)
        rowLbl:setStyleSheet(idx % 2 == 1 and css.odd or css.even)

        if isText then
            local nameLbl = Geyser.Label:new({
                name=uid.."_n", x=padL, y=6, width=inputAvail, height=14,
            }, rowLbl)
            nameLbl:setStyleSheet(css.rowLabel)
            nameLbl:rawEcho(prop.label)
            if prop.desc and prop.desc ~= "" then
                local descLbl = Geyser.Label:new({
                    name=uid.."_d", x=padL, y=21, width=inputAvail, height=13,
                }, rowLbl)
                descLbl:setStyleSheet(css.rowDesc)
                descLbl:rawEcho(prop.desc)
            end
            addTextInput(rowLbl, padL, 36, uid, css, prop.readFn, prop.writeFn, inputAvail)
        else
            local hasDesc = prop.desc and prop.desc ~= ""
            local nameX   = hasDesc and padL + 22 or padL
            local nameW2  = hasDesc and nameW - 22 or nameW
            local vCenter = math.floor((rowHToggle - 20) / 2)
            local nameLbl = Geyser.Label:new({
                name=uid.."_n", x=nameX, y=vCenter, width=nameW2, height=20,
            }, rowLbl)
            nameLbl:setStyleSheet(css.rowLabel)
            nameLbl:rawEcho(prop.label)
            if hasDesc then
                local hi = Geyser.Label:new({
                    name=uid.."_hi", x=padL, y=vCenter+2, width=16, height=16, fillBg=1,
                }, rowLbl)
                hi:setStyleSheet(css.helpIcon)
                hi:rawEcho("<center>i</center>")
                hi:setToolTip(prop.desc, 6)
            end
            addToggle(rowLbl, widgetX, math.floor((rowHToggle - widgetH) / 2), uid, css,
                prop.readFn, prop.writeFn, prop.trueLabel, prop.falseLabel)
        end

        yPos = yPos + thisH
    end
    return yPos
end

-- ── Property definitions ──────────────────────────────────────────────────────

local function paneRows(pane)
    local rows = {
        {
            label   = "Name",
            desc    = "Display name shown in the titlebar",
            type    = "text",
            readFn  = function() return pane.name end,
            writeFn = function(v) if v ~= "" then pane:setName(v) end end,
        },
        {
            label      = "Locked",
            desc       = "Locked: prevents drag, split, resize, and rename",
            type       = "toggle",
            trueLabel  = "Locked",
            falseLabel = "Unlocked",
            readFn     = function() return pane.locked end,
            writeFn    = function(v) if v then pane:lock() else pane:unlock() end end,
        },
    }
    if not pane.noTitlebarToggle then
        rows[#rows+1] = {
            label      = "Titlebar",
            desc       = "Visible: shows titlebar strip. Hidden: collapses to thin reveal strip",
            type       = "toggle",
            trueLabel  = "Visible",
            falseLabel = "Hidden",
            readFn     = function() return pane.titlebarVisible end,
            writeFn    = function(v) pane:setTitlebarVisible(v) end,
        }
    end
    rows[#rows+1] = {
        label      = "Closeable",
        desc       = "Yes: show close button even when the pane is locked",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.closeable end,
        writeFn    = function(v)
            pane.closeable = v
            pane:_applyTitlebarVisibility()
        end,
    }
    if not pane.noTabs and not pane.permanentFloat then
        rows[#rows+1] = {
            label      = "Tabs",
            desc       = "Enabled: tab bar lets you host multiple views in one pane",
            type       = "toggle",
            trueLabel  = "Enabled",
            falseLabel = "Disabled",
            readFn     = function() return pane._tabsEnabled or false end,
            writeFn    = function(v)
                if v then pane:enableTabs() else pane:disableTabs() end
            end,
        }
    end
    return rows
end

local function tabRows(host, tab)
    return {
        {
            label   = "Name",
            desc    = "Display name shown on the tab label",
            type    = "text",
            readFn  = function() return tab.name end,
            writeFn = function(v) if v ~= "" then host:renameTab(tab.id, v) end end,
        },
        {
            label      = "Locked",
            desc       = "Locked: prevents renaming and closing this tab",
            type       = "toggle",
            trueLabel  = "Locked",
            falseLabel = "Unlocked",
            readFn     = function() return tab.locked end,
            writeFn    = function(v) tab.locked = v end,
        },
    }
end

-- ── Content type registration ─────────────────────────────────────────────────
-- Registering as content suppresses the pane placeholder and integrates cleanly
-- with the content lifecycle (singleton tracking, remove callbacks).

Mux.registerContent("mux_properties", {
    name      = "Properties",
    singleton = true,
    internal  = true,
    apply = function(target)
        if target.contentBg then
            target.contentBg:echo("")
            target.contentBg:hide()
        end
        local rows = pendingRows
        if not rows or #rows == 0 then return end

        local css      = makeCss()
        local contentH = 0
        for _, row in ipairs(rows) do contentH = contentH + rowHeight(row.type) end

        local cw = target.content:get_width()
        if cw < 50 then cw = 376 end

        local prefix     = _pendingPrefix or ("mux_prop_" .. target.id)
        _pendingPrefix   = nil
        local contentLbl = Geyser.Label:new({
            name=prefix.."_cl", x=0, y=0, width=cw, height=contentH,
        }, target.content)
        contentLbl:setStyleSheet("background:" .. css.bg .. "; border:none;")

        buildRows(contentLbl, cw, rows, css, prefix)
        -- Force geometry pass so content paints immediately instead of on first drag.
        tempTimer(0, function()
            if target.outer then target.outer:reposition() end
        end)
    end,
    remove = function(_target)
        -- Widgets are children of the dialog pane's content container and are
        -- torn down when that pane closes; nothing to clean up here.
    end,
})

-- ── Dialog builder ────────────────────────────────────────────────────────────

-- targetPane (optional): when provided and titlebar is hidden, the close button
-- shows a confirmation dialog warning that Properties can't be reopened from the UI.
local function openPropsDialog(title, rows, targetPane)
    if propsUi.window then
        propsUi.window:close()
        propsUi.window = nil
    end
    _propsEpoch    = _propsEpoch + 1
    _pendingPrefix = "mux_prop_e" .. _propsEpoch

    local sw, sh  = getMainWindowSize()
    local dialogW = 380

    local contentH = 0
    for _, row in ipairs(rows) do contentH = contentH + rowHeight(row.type) end

    -- chrome: titlebar (22) + outer border top+bottom (4)
    local dialogH = contentH + 26
    local px = math.floor((sw - dialogW) / 2)
    local py = math.floor((sh - dialogH) / 2)

    local d = Mux.createDialog({
        title         = title,
        x=px, y=py, width=dialogW, height=dialogH,
        noContextMenu = true,
        noTabs        = true,
    })
    propsUi.window = d
    d.onClose = function() propsUi.window = nil end

    -- Intercept close button when watching for the locked+hidden-titlebar trap.
    if targetPane then
        d.closeBtn:setClickCallback(function(event)
            if event.button ~= "LeftButton" then return end
            if not targetPane.titlebarVisible then
                -- Warn: closing properties will leave no UI way to reopen it.
                local confirmD = Mux.createDialog({
                    title  = "Confirm Close",
                    width  = 420, height = 160,
                })
                if confirmD.contentBg then
                    confirmD.contentBg:echo("")
                    confirmD.contentBg:hide()
                end
                local body = Geyser.Label:new({
                    name=confirmD._gid.."_body", x=10, y=8, width=400, height=60,
                }, confirmD.content)
                body:setStyleSheet(Mux.dialogCss.body)
                body:rawEcho("This pane has a <b>hidden titlebar</b>.<br/>"
                    .. "The only way to reopen Properties will be a console command:<br/>"
                    .. "<tt style='color:#8ab4ff;'>mux pane properties</tt>")
                local btnKeep = Geyser.Label:new({
                    name=confirmD._gid.."_keep", x=20, y=90, width=180, height=34,
                }, confirmD.content)
                btnKeep:setStyleSheet(Mux.dialogCss.button)
                btnKeep:rawEcho("<center>Cancel</center>")
                btnKeep:setClickCallback(function() confirmD:close() end)
                local btnClose = Geyser.Label:new({
                    name=confirmD._gid.."_close", x=220, y=90, width=180, height=34,
                }, confirmD.content)
                btnClose:setStyleSheet(Mux.dialogCss.buttonDanger)
                btnClose:rawEcho("<center>OK</center>")
                btnClose:setClickCallback(function()
                    confirmD:close()
                    d:close()
                end)
                confirmD:show()
                confirmD:raise()
                tempTimer(0, function()
                    if confirmD.outer then confirmD.outer:reposition() end
                end)
            else
                d:close()
            end
        end)
    end

    pendingRows = rows
    Mux._applyContent(d, "mux_properties")
    pendingRows = nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

function Mux.showPaneProperties(pane)
    openPropsDialog(
        string.format("Properties: %s", pane.name),
        paneRows(pane),
        pane
    )
end

function Mux.showTabProperties(host, tab)
    openPropsDialog(
        string.format("Tab: %s", tab.name),
        tabRows(host, tab)
    )
end

Mux._log("mux_properties loaded")
