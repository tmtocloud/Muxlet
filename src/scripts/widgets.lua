-- Muxlet — Unified widget toolkit (Mux.ui)
--
-- Provides a declarative, theme-aware form builder for use in properties dialogs,
-- settings panels, and downstream packages.
--
-- Public API:
--   Mux.ui.buildForm(parent, specs, opts)  → formHandle
--   Mux.ui.specHeight(spec)               → number  (pixel height of one spec row)
--   Mux.ui.formHeight(specs)              → number  (total pixel height of all rows)
--
-- Spec format:
--   {
--     label    = "Label",
--     desc     = "Tooltip / help icon text",
--     type     = "bool"|"string"|"number"|"array",
--                (aliases: "toggle"→bool, "text"→string, "choiceCycler"→array, "readOnly"→string+readOnly)
--     display  = "checkbox"|"cycler"|"dropdown"|"text"|"stepper",
--                (inferred from type when omitted)
--     options  = { { value=…, label="…", style="…" }, … },   -- for array; or bool+cycler/dropdown
--     trueLabel  = "TRUE",   falseLabel = "FALSE",            -- sugar for bool+checkbox
--     step     = 1,          -- for number+stepper
--     min      = 0,          -- for number+stepper
--     max      = 100,        -- for number+stepper
--     readOnly = true,       -- display value only, no interaction
--     readFn   = function() return value end,
--     writeFn  = function(v) ... end,
--   }
--
-- opts:
--   width              number   — form width (defaults to parent:get_width() or 400)
--   prefix             string   — unique widget-name prefix (required for same-parent reuse)
--   rowHeight          number   — height of toggle/cycler/dropdown rows (default 42)
--   textRowHeight      number   — height of string+text (wide) rows (default 64)
--   widgetWidth        number   — width of interactive widget area (default 110)
--   widgetHeight       number   — height of widgets within a row (default 24)
--   padLeft            number   — left padding (default 10)
--   padRight           number   — right padding (default 6)
--   showReset          bool     — show reset-to-default icon on each row
--   onReset            fn(i, spec) — called when reset icon clicked
--   getContentScreenPos fn()→cx,cy — returns absolute screen pos of content area top-left;
--                                    required for dropdown display to position the overlay
--
-- formHandle (return value):
--   .totalHeight       number
--   .closeDropdown()   — close any open dropdown overlay
--   .refresh(i)        — refresh widget at spec index i
--   .refreshAll()      — refresh all widgets

Mux.ui = Mux.ui or {}

-- ── Style defaults (used when theme.ui.styles[name] is absent) ────────────────

local defaultStyles = {
    on   = { bg = "rgb(30,70,40)",  fg = "#88ee88",               border = "rgba(80,180,80,0.5)",   hover = "rgb(40,90,50)"  },
    off  = { bg = "rgb(65,30,30)",  fg = "rgba(220,120,120,0.9)", border = "rgba(180,80,80,0.4)",   hover = "rgb(85,40,40)"  },
    warn = { bg = "rgb(58,50,18)",  fg = "rgba(220,190,80,0.9)",  border = "rgba(200,170,60,0.5)",  hover = "rgb(78,68,24)"  },
}

local function buildStyleCss(s)
    return string.format(
        "QLabel{background:%s;color:%s;font-size:10px;font-weight:bold;border:1px solid %s;border-radius:3px;}"
        .. "QLabel::hover{background:%s;}",
        s.bg, s.fg, s.border, s.hover)
end

-- ── CSS derivation from active theme ─────────────────────────────────────────

local function deriveCss(uiTheme)
    local ui = uiTheme or {}

    local bg         = ui.bg             or "rgb(18,18,26)"
    local rowOdd     = ui.rowOdd         or "rgb(16,16,24)"
    local rowEven    = ui.rowEven        or "rgb(34,34,50)"
    local divider    = ui.rowDivider     or "rgba(255,255,255,0.12)"
    local text       = ui.textColor      or "rgba(215,215,230,0.92)"
    local descText   = ui.descTextColor  or "rgba(120,130,170,0.85)"
    local widgetBg   = ui.widgetBg       or "rgb(38,38,58)"
    local widgetFg   = ui.widgetFg       or "#d8d8f0"
    local widgetBd   = ui.widgetBorder   or "rgba(255,255,255,0.22)"
    local widgetHv   = ui.widgetHoverBg  or "rgb(55,55,80)"
    local inputBg    = ui.inputBg        or "rgb(12,12,18)"
    local inputFg    = ui.inputFg        or "#c8c8d0"
    local inputBd    = ui.inputBorder    or "rgba(255,255,255,0.46)"
    local hiIconFg   = ui.helpIconFg     or "rgba(100,160,255,0.85)"
    local hiIconBg   = ui.helpIconBg     or "rgba(60,80,120,0.25)"
    local hiIconBd   = ui.helpIconBorder or "rgba(100,140,200,0.35)"
    local hiIconHvBg = ui.helpIconHoverBg or "rgba(80,110,185,0.85)"

    -- Build style CSS/fg maps from theme.ui.styles, falling back to defaults.
    local themeStyles = ui.styles or {}
    local styleCssMap = {}
    local styleFgMap  = {}
    for name, def in pairs(defaultStyles) do
        local s = themeStyles[name] or def
        styleCssMap[name] = buildStyleCss(s)
        styleFgMap[name]  = s.fg
    end
    for name, s in pairs(themeStyles) do
        if not styleCssMap[name] then
            styleCssMap[name] = buildStyleCss(s)
            styleFgMap[name]  = s.fg
        end
    end

    return {
        bg          = bg,
        odd         = string.format("background:%s;border:none;border-bottom:1px solid %s;", rowOdd, divider),
        even        = string.format("background:%s;border:none;border-bottom:1px solid %s;", rowEven, divider),
        rowLabel    = string.format("background:transparent;color:%s;font-size:11px;font-weight:bold;", text),
        rowDesc     = string.format("background:transparent;color:%s;font-size:10px;", descText),
        helpIcon    = string.format(
            "QLabel{background:%s;color:%s;font-size:10px;font-weight:bold;border-radius:3px;border:1px solid %s;}",
            hiIconBg, hiIconFg, hiIconBd),
        helpIconHover = string.format(
            "QLabel{background:%s;color:%s;font-size:10px;font-weight:bold;border-radius:3px;border:1px solid %s;}",
            hiIconHvBg, hiIconFg, hiIconBd),
        widgetFg    = widgetFg,
        widgetBtn   = string.format(
            "QLabel{background:%s;color:%s;font-size:10px;border:1px solid %s;border-radius:3px;}"
            .. "QLabel::hover{background:%s;}",
            widgetBg, widgetFg, widgetBd, widgetHv),
        stepperBtn  = string.format(
            "QLabel{background:%s;border:1px solid %s;border-radius:3px;}"
            .. "QLabel::hover{background:%s;}",
            widgetBg, widgetBd, widgetHv),
        stepperVal  = string.format(
            "QLabel{background:%s;border:1px solid %s;border-radius:3px;}", widgetBg, widgetBd),
        textInput   = string.format(
            "background-color:%s;color:%s;font-size:12px;border:1px solid %s;"
            .. "border-radius:3px;padding-left:6px;padding-right:4px;",
            inputBg, inputFg, inputBd),
        applyBtn    = string.format(
            "QLabel{background-color:%s;border:1px solid %s;border-radius:3px;color:%s;font-size:9px;"
            .. "font-weight:bold;}QLabel::hover{background-color:%s;border-color:rgba(120,180,255,200);color:%s;}",
            widgetBg, widgetBd, widgetFg, widgetHv, widgetFg),
        dropdownPanel = string.format(
            "background:%s;border:1px solid %s;border-radius:3px;", widgetBg, widgetBd),
        dropdownOpt = string.format(
            "QLabel{background:transparent;color:%s;font-size:10px;}"
            .. "QLabel::hover{background:%s;}", widgetFg, widgetHv),
        resetIcon   = "QLabel{background:transparent;color:rgba(140,145,165,0.55);font-size:11px;"
            .. "border:1px solid rgba(140,145,165,0.25);border-radius:3px;}"
            .. "QLabel::hover{color:rgba(220,180,80,0.85);border-color:rgba(220,180,80,0.55);}",
        styleCss    = styleCssMap,
        styleFg     = styleFgMap,
    }
end

-- ── Row height helpers ────────────────────────────────────────────────────────

local function isWideSpec(spec)
    local t = spec.type
    return t == "string" or t == "text"
end

-- Per-row widgetWidth override: spec.widgetWidth takes precedence over opts.widgetWidth.
local function resolveWidgetW(spec, opts)
    return spec.widgetWidth or opts.widgetWidth or 110
end

function Mux.ui.specHeight(spec, opts)
    opts = opts or {}
    if isWideSpec(spec) then
        return opts.textRowHeight or 64
    end
    return opts.rowHeight or 42
end

function Mux.ui.formHeight(specs, opts)
    local total = 0
    for _, spec in ipairs(specs) do
        total = total + Mux.ui.specHeight(spec, opts)
    end
    return total
end

-- ── buildForm ─────────────────────────────────────────────────────────────────

function Mux.ui.buildForm(parent, specs, opts)
    opts = opts or {}

    local theme    = Mux.activeTheme() or {}
    local css      = deriveCss(theme.ui or theme.settingsUi)

    local formW    = opts.width       or (parent:get_width() > 50 and parent:get_width() or 400)
    local prefix   = opts.prefix      or "muxui"
    local rowH     = opts.rowHeight   or 42
    local textH    = opts.textRowHeight or 64
    local widgetW  = opts.widgetWidth  or 110
    local widgetH  = opts.widgetHeight or 24
    local padL     = opts.padLeft      or 10
    local padR     = opts.padRight     or 6
    local applyW   = 42
    local inputGap = 3
    local stepBtnW = 26

    local showReset   = opts.showReset and opts.onReset
    local resetW      = showReset and 20 or 0
    local resetGap    = showReset and 8  or 0

    local widgetX = formW - widgetW - padR - resetW - resetGap
    local resetX  = formW - resetW - padR
    local nameW   = widgetX - padL - 24  -- 24 reserved for help-icon slot

    local activeDropdown = nil
    local refreshFns     = {}
    local commitFns      = {}
    local yPos           = 0

    local function closeDropdown()
        if activeDropdown then
            activeDropdown:hide()
            activeDropdown = nil
        end
    end

    for i, spec in ipairs(specs) do
        -- ── Resolve type aliases ──────────────────────────────────────────────
        local specType    = spec.type
        local specDisplay = spec.display
        local isReadOnly  = spec.readOnly

        if specType == "toggle"           then specType = "bool";   specDisplay = specDisplay or "checkbox"
        elseif specType == "choiceCycler"  then specType = "array"; specDisplay = specDisplay or "cycler"
        elseif specType == "segmentedControl" then specType = "array"; specDisplay = specDisplay or "segmented"
        elseif specType == "readOnly"      then specType = "string"; isReadOnly  = true
        elseif specType == "text"          then specType = "string"
        end

        -- ── Infer display when not set ────────────────────────────────────────
        if not specDisplay then
            if     specType == "bool"   then specDisplay = "checkbox"
            elseif specType == "array"  then specDisplay = "cycler"
            elseif specType == "number" then specDisplay = "stepper"
            else                             specDisplay = "text"
            end
        end

        local isWide = (specType == "string") and (specDisplay == "text") and not isReadOnly
        local thisH  = isWide and textH or rowH
        local uid    = prefix .. "_w" .. i

        -- Per-row widget width override (e.g. wider segmented controls).
        local thisWidgetW = resolveWidgetW(spec, opts)
        local thisWidgetX = formW - thisWidgetW - padR - resetW - resetGap

        -- ── Row container ─────────────────────────────────────────────────────
        local row = Geyser.Label:new({
            name=uid.."_row", x=0, y=yPos, width=formW, height=thisH,
        }, parent)
        row:setStyleSheet(i % 2 == 1 and css.odd or css.even)

        local wy       = math.floor((thisH - widgetH) / 2)
        local thisNameW = thisWidgetX - padL - 24
        local hasDesc  = spec.desc and spec.desc ~= ""

        -- ── Wide text row ─────────────────────────────────────────────────────
        if isWide then
            local availW    = formW - padL - padR - resetW - resetGap
            local hideApply = opts.hideApply
            local inputW    = hideApply and availW or (availW - applyW - inputGap)

            local nl = Geyser.Label:new({name=uid.."_n", x=padL, y=6, width=availW, height=14}, row)
            nl:setStyleSheet(css.rowLabel)
            nl:rawEcho(spec.label)

            if hasDesc then
                local dl = Geyser.Label:new({name=uid.."_d", x=padL, y=20, width=availW, height=13}, row)
                dl:setStyleSheet(css.rowDesc)
                dl:rawEcho(spec.desc)
            end

            local input = Geyser.CommandLine:new({name=uid.."_i", x=padL, y=36, width=inputW, height=widgetH}, row)
            input:setStyleSheet(css.textInput)
            input:print(tostring(spec.readFn() or ""))

            local function commit()
                local text = input:getText()
                if not text or text == "" then return end
                spec.writeFn(text)
                input:print(tostring(spec.readFn() or ""))
            end
            input:setAction(commit)
            commitFns[i] = commit
            if not hideApply then
                local aBtn = Geyser.Label:new({name=uid.."_a", x=padL+inputW+inputGap, y=36, width=applyW, height=widgetH}, row)
                aBtn:setStyleSheet(css.applyBtn)
                aBtn:echo(string.format(
                    "<center><span style='color:%s;font-size:9px;font-weight:bold;'>Apply</span></center>",
                    css.widgetFg))
                aBtn:setClickCallback(commit)
            end
            refreshFns[i] = function() input:print(tostring(spec.readFn() or "")) end

            if showReset then
                local ri = Geyser.Label:new({name=uid.."_rst", x=resetX, y=6, width=resetW, height=widgetH}, row)
                ri:setStyleSheet(css.resetIcon)
                ri:echo("<center><span style='color:rgba(140,145,165,0.55);font-size:11px;'>↺</span></center>")
                ri:setClickCallback(function() closeDropdown(); opts.onReset(i, spec) end)
            end

        -- ── Read-only row ─────────────────────────────────────────────────────
        elseif isReadOnly then
            local vCenter = math.floor((rowH - 20) / 2)
            local nl = Geyser.Label:new({name=uid.."_n", x=padL, y=vCenter, width=thisNameW+24, height=20}, row)
            nl:setStyleSheet(css.rowLabel)
            nl:rawEcho(spec.label)

            local valW = thisWidgetW + resetW + resetGap
            local vl = Geyser.Label:new({name=uid.."_v", x=thisWidgetX, y=vCenter, width=valW, height=20}, row)
            vl:setStyleSheet(css.rowDesc)
            vl:rawEcho(string.format("<center>%s</center>", tostring(spec.readFn() or "")))
            refreshFns[i] = function()
                vl:rawEcho(string.format("<center>%s</center>", tostring(spec.readFn() or "")))
            end

        -- ── Standard interactive row ──────────────────────────────────────────
        else
            local vCenter = math.floor((rowH - 20) / 2)
            local nameX   = hasDesc and padL + 22 or padL
            local nameW2   = hasDesc and thisNameW or thisNameW + 22

            local nl = Geyser.Label:new({name=uid.."_n", x=nameX, y=vCenter, width=nameW2, height=20}, row)
            nl:setStyleSheet(css.rowLabel)
            nl:rawEcho(spec.label)

            if hasDesc then
                local hi = Geyser.Label:new({
                    name=uid.."_hi", x=padL, y=vCenter+2, width=16, height=16, fillBg=1,
                }, row)
                hi:setStyleSheet(css.helpIcon)
                hi:rawEcho("<center>i</center>")
                hi:setToolTip(spec.desc, 6)
                hi:setOnEnter(function() hi:setStyleSheet(css.helpIconHover) end)
                hi:setOnLeave(function() hi:setStyleSheet(css.helpIcon) end)
            end

            -- ── Checkbox (bool, two-state toggle) ─────────────────────────────
            if specDisplay == "checkbox" then
                local trueOpt  = { value = true,  label = spec.trueLabel  or "TRUE",  style = "on"  }
                local falseOpt = { value = false,  label = spec.falseLabel or "FALSE", style = "off" }
                local choices  = spec.options or { trueOpt, falseOpt }

                local btn = Geyser.Label:new({name=uid.."_cb", x=thisWidgetX, y=wy, width=thisWidgetW, height=widgetH}, row)
                local function refresh()
                    local v   = spec.readFn()
                    local chosen = choices[1]
                    for _, o in ipairs(choices) do
                        if o.value == v then chosen = o; break end
                    end
                    local s = chosen.style or "on"
                    btn:setStyleSheet(css.styleCss[s] or css.styleCss.on)
                    btn:echo(string.format(
                        "<center><span style='color:%s;font-size:10px;font-weight:bold;'>%s</span></center>",
                        css.styleFg[s] or css.styleFg.on, chosen.label))
                end
                refresh()
                btn:setClickCallback(function()
                    closeDropdown()
                    spec.writeFn(not spec.readFn())
                    refresh()
                end)
                refreshFns[i] = refresh

            -- ── Cycler (array or bool, N-state cycling button) ────────────────
            elseif specDisplay == "cycler" then
                local choices = spec.options or {
                    { value = true,  label = "TRUE",  style = "on"  },
                    { value = false, label = "FALSE", style = "off" },
                }
                local btn = Geyser.Label:new({name=uid.."_cyc", x=thisWidgetX, y=wy, width=thisWidgetW, height=widgetH}, row)
                local function refresh()
                    local v      = spec.readFn()
                    local chosen = choices[1]
                    for _, c in ipairs(choices) do
                        if c.value == v then chosen = c; break end
                    end
                    local s = chosen.style or "on"
                    btn:setStyleSheet(css.styleCss[s] or css.styleCss.on)
                    btn:echo(string.format(
                        "<center><span style='color:%s;font-size:10px;font-weight:bold;'>%s</span></center>",
                        css.styleFg[s] or css.styleFg.on, chosen.label))
                end
                refresh()
                btn:setClickCallback(function()
                    closeDropdown()
                    local v      = spec.readFn()
                    local curIdx = 1
                    for ci, c in ipairs(choices) do
                        if c.value == v then curIdx = ci; break end
                    end
                    spec.writeFn(choices[(curIdx % #choices) + 1].value)
                    refresh()
                end)
                refreshFns[i] = refresh

            -- ── Dropdown (array, floating overlay panel) ──────────────────────
            elseif specDisplay == "dropdown" then
                local choices = spec.options or {}
                local ovName  = uid .. "_dov"
                local overlay = nil

                local btn = Geyser.Label:new({name=uid.."_dd", x=thisWidgetX, y=wy, width=thisWidgetW, height=widgetH}, row)
                btn:setStyleSheet(css.widgetBtn)

                local function destroyOverlay()
                    if overlay then
                        overlay:hide()
                        for ci = 1, #choices do
                            local n = ovName .. "_o" .. ci
                            if Geyser.windowList[n] then Geyser.windowList[n]:hide() end
                        end
                        if activeDropdown == overlay then activeDropdown = nil end
                        overlay = nil
                    end
                end

                local capturedRowY = yPos

                local function refresh()
                    local v = spec.readFn()
                    local dispLabel = tostring(v or "")
                    for _, c in ipairs(choices) do
                        if c.value == v then dispLabel = c.label; break end
                    end
                    if #dispLabel > 16 then dispLabel = dispLabel:sub(1, 15) .. "…" end
                    btn:echo(string.format(
                        "<center><span style='color:%s;font-size:10px;'>%s ▾</span></center>",
                        css.widgetFg, dispLabel))
                end
                refresh()

                local function openOverlay()
                    if not opts.getContentScreenPos then return end
                    local cx, cy    = opts.getContentScreenPos()
                    local absBtnX   = cx + thisWidgetX
                    local absBtnY   = cy + capturedRowY + wy + widgetH
                    overlay = Geyser.Label:new({
                        name=ovName, x=absBtnX, y=absBtnY,
                        width=thisWidgetW, height=#choices * widgetH,
                    }, Geyser)
                    overlay:setStyleSheet(css.dropdownPanel)
                    overlay:show(); overlay:raise()
                    for ci, choice in ipairs(choices) do
                        local opt = Geyser.Label:new({
                            name=ovName.."_o"..ci, x=0, y=(ci-1)*widgetH,
                            width=thisWidgetW, height=widgetH,
                        }, overlay)
                        opt:setStyleSheet(css.dropdownOpt)
                        opt:echo(string.format(
                            "<span style='color:%s;font-size:10px;'>  %s</span>",
                            css.widgetFg, tostring(choice.label)))
                        opt:show(); opt:raise()
                        local captured = choice
                        if choice.desc and choice.desc ~= "" then opt:setToolTip(choice.desc, 6) end
                        opt:setClickCallback(function()
                            spec.writeFn(captured.value)
                            refresh()
                            destroyOverlay()
                        end)
                    end
                    activeDropdown = overlay
                end

                btn:setClickCallback(function()
                    if activeDropdown then
                        local was = (activeDropdown == overlay)
                        closeDropdown()
                        destroyOverlay()
                        if was then return end
                    end
                    openOverlay()
                end)
                refreshFns[i] = refresh

            -- ── Stepper (number, − value +) ───────────────────────────────────
            elseif specDisplay == "stepper" then
                local step = spec.step or 1
                local minV = spec.min  or 0
                local maxV = spec.max  or 100
                local bw   = stepBtnW
                local vw   = thisWidgetW - bw * 2 - 4
                local sc   = css.widgetFg

                local minus = Geyser.Label:new({name=uid.."_sm", x=thisWidgetX,              y=wy, width=bw, height=widgetH}, row)
                local vl    = Geyser.Label:new({name=uid.."_sv", x=thisWidgetX+bw+2,         y=wy, width=vw, height=widgetH}, row)
                local plus  = Geyser.Label:new({name=uid.."_sp", x=thisWidgetX+bw+2+vw+2,   y=wy, width=bw, height=widgetH}, row)

                minus:setStyleSheet(css.stepperBtn)
                minus:echo(string.format("<center><span style='color:%s;font-size:13px;font-weight:bold;'>−</span></center>", sc))
                vl:setStyleSheet(css.stepperVal)
                plus:setStyleSheet(css.stepperBtn)
                plus:echo(string.format("<center><span style='color:%s;font-size:13px;font-weight:bold;'>+</span></center>", sc))

                local function refresh()
                    vl:echo(string.format(
                        "<center><span style='color:%s;font-size:11px;font-weight:bold;'>%s</span></center>",
                        sc, tostring(spec.readFn())))
                end
                refresh()

                minus:setClickCallback(function()
                    closeDropdown()
                    spec.writeFn(math.max(minV, (spec.readFn() or minV) - step))
                    refresh()
                end)
                plus:setClickCallback(function()
                    closeDropdown()
                    spec.writeFn(math.min(maxV, (spec.readFn() or minV) + step))
                    refresh()
                end)
                refreshFns[i] = refresh

            -- ── Inline text (number or string without wide layout) ────────────
            elseif specDisplay == "text" then
                local inW = thisWidgetW - applyW - inputGap
                local input = Geyser.CommandLine:new({name=uid.."_i", x=thisWidgetX, y=wy, width=inW, height=widgetH}, row)
                input:setStyleSheet(css.textInput)
                input:print(tostring(spec.readFn() or ""))

                local aBtn = Geyser.Label:new({name=uid.."_a", x=thisWidgetX+inW+inputGap, y=wy, width=applyW, height=widgetH}, row)
                aBtn:setStyleSheet(css.applyBtn)
                aBtn:echo(string.format(
                    "<center><span style='color:%s;font-size:9px;font-weight:bold;'>Apply</span></center>",
                    css.widgetFg))

                local function commit()
                    closeDropdown()
                    local text = input:getText()
                    if not text or text == "" then return end
                    spec.writeFn(text)
                    input:print(tostring(spec.readFn() or ""))
                end
                input:setAction(commit)
                aBtn:setClickCallback(commit)
                commitFns[i] = commit
                refreshFns[i] = function() input:print(tostring(spec.readFn() or "")) end

            -- ── Segmented control (N connected buttons, one highlighted) ──────
            elseif specDisplay == "segmented" then
                local choices = spec.options or {}
                local n       = #choices
                if n > 0 then
                local segW    = math.floor(thisWidgetW / n)
                -- Last segment absorbs rounding remainder.
                local lastW   = thisWidgetW - segW * (n - 1)
                local ui      = (Mux.activeTheme and Mux.activeTheme() or {}).ui or {}
                local wBg     = ui.widgetBg    or "rgb(38,38,58)"
                local wFg     = ui.widgetFg    or "#d8d8f0"
                local wBd     = ui.widgetBorder or "rgba(255,255,255,0.22)"
                local wHv     = ui.widgetHoverBg or "rgb(55,55,80)"
                local selBg   = (ui.styles and ui.styles.on and ui.styles.on.bg) or "rgb(30,70,40)"
                local selFg   = (ui.styles and ui.styles.on and ui.styles.on.fg) or "#88ee88"
                local selBd   = (ui.styles and ui.styles.on and ui.styles.on.border) or "rgba(80,180,80,0.5)"
                local selHv   = (ui.styles and ui.styles.on and ui.styles.on.hover) or "rgb(40,90,50)"

                local function segCss(isSelected, pos)
                    local r = pos == 1 and "border-radius:3px 0 0 3px;"
                           or pos == n and "border-radius:0 3px 3px 0;"
                           or              "border-radius:0;"
                    if isSelected then
                        return string.format(
                            "QLabel{background:%s;color:%s;font-size:10px;font-weight:bold;border:1px solid %s;%s}"
                            .. "QLabel::hover{background:%s;}",
                            selBg, selFg, selBd, r, selHv)
                    else
                        return string.format(
                            "QLabel{background:%s;color:%s;font-size:10px;border:1px solid %s;%s}"
                            .. "QLabel::hover{background:%s;}",
                            wBg, wFg, wBd, r, wHv)
                    end
                end

                local segs = {}
                for ci, choice in ipairs(choices) do
                    local sx = thisWidgetX + (ci - 1) * segW
                    local sw = (ci == n) and lastW or segW
                    local seg = Geyser.Label:new({
                        name=uid.."_sg"..ci, x=sx, y=wy, width=sw, height=widgetH, fillBg=1,
                    }, row)
                    segs[ci] = { widget = seg, choice = choice, pos = ci }
                end

                local function refresh()
                    local v = spec.readFn()
                    for _, s in ipairs(segs) do
                        local isSel = (s.choice.value == v)
                        s.widget:setStyleSheet(segCss(isSel, s.pos))
                        s.widget:echo(string.format(
                            "<center><span style='color:%s;font-size:10px;font-weight:bold;'>%s</span></center>",
                            isSel and selFg or wFg, s.choice.label))
                    end
                end
                refresh()

                for _, s in ipairs(segs) do
                    local captured = s.choice
                    s.widget:setClickCallback(function()
                        closeDropdown()
                        spec.writeFn(captured.value)
                        refresh()
                    end)
                end
                refreshFns[i] = refresh
                end  -- n > 0
            end

            -- ── Reset icon (non-wide rows) ────────────────────────────────────
            if showReset then
                local ri = Geyser.Label:new({name=uid.."_rst", x=resetX, y=wy, width=resetW, height=widgetH}, row)
                ri:setStyleSheet(css.resetIcon)
                ri:echo("<center><span style='color:rgba(140,145,165,0.55);font-size:11px;'>↺</span></center>")
                ri:setClickCallback(function() closeDropdown(); opts.onReset(i, spec) end)
            end
        end

        yPos = yPos + thisH
    end

    return {
        totalHeight   = yPos,
        closeDropdown = closeDropdown,
        refresh       = function(idx) if refreshFns[idx] then refreshFns[idx]() end end,
        refreshAll    = function() for _, fn in pairs(refreshFns) do fn() end end,
        commitAll     = function() for _, fn in pairs(commitFns) do fn() end end,
    }
end