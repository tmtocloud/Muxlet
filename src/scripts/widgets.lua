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

-- Registry of custom form-row widget types (see Mux.ui.registerWidget below).
Mux.ui._widgets = Mux.ui._widgets or {}

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
    local cw = Mux.ui._widgets[spec.type]
    if cw then return cw.rowHeight or opts.rowHeight or 42 end
    if spec.type == "color" then return opts.colorRowHeight or 92 end
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

-- ── Standalone widget: colour field ───────────────────────────────────────────
-- Reusable on its own (Mux.ui.colorField) or as a buildForm row (type="color").
-- Renders a live preview swatch + hex entry + a strip of clickable presets.
-- Returns a handle: container/height/read/set/commit/refresh.  This is the model
-- for buildForm's widgets generally — self-contained components a package author
-- can drop into their own dialogs, which buildForm merely lays out in rows.
Mux.ui.COLOR_PRESETS = {
    "#1c2a4e", "#23395d", "#2e7d32", "#7b1fa2", "#b71c1c", "#e65100",
    "#f9a825", "#00838f", "#455a64", "#e0e0e0", "#0b0d14", "#96c8ff",
}

function Mux.ui.colorField(parent, opts)
    opts = opts or {}
    local value    = opts.value or "#000000"
    local onChange = opts.onChange or function() end
    local swatches = opts.swatches or Mux.ui.COLOR_PRESETS
    local x, y     = opts.x or 0, opts.y or 0
    local width    = opts.width or 240
    local prefix   = opts.prefix or ("muxcf_" .. tostring(math.random(1, 1000000000)))
    local SW, GAP, INPUTH = 18, 4, 26
    local perRow   = math.max(1, math.floor((width + GAP) / (SW + GAP)))
    local rows     = math.max(1, math.ceil(#swatches / perRow))
    local height   = INPUTH + 6 + rows * (SW + GAP)

    local cont = Geyser.Label:new({ name = prefix.."_c", x = x, y = y, width = width, height = height }, parent)
    cont:setStyleSheet("background:transparent;border:none;")

    local preview = Geyser.Label:new({ name = prefix.."_pv", x = 0, y = 0, width = INPUTH, height = INPUTH }, cont)
    local function setPreview(hex)
        preview:setStyleSheet(string.format(
            "background:%s;border:1px solid rgba(255,255,255,0.25);border-radius:3px;", hex))
    end

    local input = Geyser.CommandLine:new({ name = prefix.."_i", x = INPUTH + 6, y = 0,
        width = math.max(40, width - INPUTH - 6), height = INPUTH }, cont)
    input:setStyleSheet("background:rgba(0,0,0,0.35);color:#dde;border:1px solid rgba(255,255,255,0.15);border-radius:3px;")

    local function apply(hex, fromInput)
        if not hex or hex == "" then return end
        value = hex
        setPreview(hex)
        if not fromInput then input:print(hex) end
        onChange(hex)
    end

    setPreview(value)
    input:print(value)
    input:setAction(function() apply(input:getText(), true) end)

    local sy = INPUTH + 6
    for i, hex in ipairs(swatches) do
        local r, c = math.floor((i - 1) / perRow), (i - 1) % perRow
        local s = Geyser.Label:new({ name = prefix.."_s"..i,
            x = c * (SW + GAP), y = sy + r * (SW + GAP), width = SW, height = SW }, cont)
        s:setStyleSheet(string.format(
            "background:%s;border:1px solid rgba(255,255,255,0.18);border-radius:3px;", hex))
        s:setToolTip(hex)
        local captured = hex
        s:setClickCallback(function() apply(captured, false) end)
    end

    return {
        container = cont,
        height    = height,
        read      = function() return value end,
        set       = function(hex) apply(hex, false) end,
        commit    = function() apply(input:getText(), true) end,
        refresh   = function() input:print(value); setPreview(value) end,
    }
end

-- ── Custom widget registry ────────────────────────────────────────────────────
-- Register a custom form-row widget type.  Once registered, any buildForm spec
-- whose `type` matches `wtype` renders via your builder instead of a built-in.
--
--   Mux.ui.registerWidget("slider", function(parent, o) ... end, { rowHeight = 50 })
--
-- The builder is called as builder(parent, o) where `o` carries:
--   x, y, width, height   widget area on the right of the row.  The row label is
--                         already drawn to the left and (if enabled) a reset icon
--                         to the right — you only fill this rectangle.
--   value                 current value (spec.readFn() result, or nil)
--   onChange              call with a new value to persist it (wraps spec.writeFn)
--   spec                  the original row spec (label, desc, options, min, max…)
--   css                   resolved theme style table (widgetBg, widgetFg, styleCss…)
--   uid                   unique id base for naming child widgets ("..._w3")
--   closeDropdown         closes any open form dropdown overlay (call before opening
--                         your own popup so only one floats at a time)
--   getScreenPos          opts.getContentScreenPos passthrough — returns the form's
--                         absolute (x,y); needed to position floating overlays
--
-- The builder MAY return { commit = fn, refresh = fn } (either optional); both get
-- wired into the form handle's commitAll()/refreshAll().
--
-- opts.rowHeight sets the row height for this type (defaults to the form rowHeight).
-- Use a unique type name; this is for adding new widgets, not overriding built-ins.
function Mux.ui.registerWidget(wtype, builder, opts)
    assert(type(wtype)   == "string",   "registerWidget: type must be a string")
    assert(type(builder) == "function", "registerWidget: builder must be a function")
    Mux.ui._widgets[wtype] = { build = builder, rowHeight = opts and opts.rowHeight }
end

function Mux.ui.unregisterWidget(wtype)
    Mux.ui._widgets[wtype] = nil
end

-- ── Built-in widget builders ──────────────────────────────────────────────────
-- Each form control is a discrete builder rather than an inline branch, so the
-- set is open: buildForm dispatches to one of these by render key, custom types
-- registered via Mux.ui.registerWidget slot in beside them, and any single
-- control can be swapped without touching the others.
--
-- A builder is build(parent, c) -> { commit?, refresh? } where `c` carries the
-- row geometry, data (spec/value/onChange), themed `css`, and helpers. There are
-- two layout classes:
--   "inline"  buildForm draws the label (+ help icon) and the reset icon; the
--             builder only fills the widget rectangle at c.x / c.y / c.width / c.height.
--   "block"   the builder owns the whole row (label, widget, and its own reset if any).
-- Custom widgets are always inline (see Mux.ui.registerWidget).

-- ── Colour field (block) — delegates to the standalone Mux.ui.colorField ──────
local function w_color(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local availW = c.formW - c.padL - c.padR
    local nl = Geyser.Label:new({name=uid.."_n", x=c.padL, y=6, width=availW, height=14}, row)
    nl:setStyleSheet(css.rowLabel)
    nl:rawEcho(spec.label)
    local topY = 22
    if c.hasDesc then
        local dl = Geyser.Label:new({name=uid.."_d", x=c.padL, y=20, width=availW, height=13}, row)
        dl:setStyleSheet(css.rowDesc)
        dl:rawEcho(spec.desc)
        topY = 34
    end
    local cf = Mux.ui.colorField(row, {
        x = c.padL, y = topY, width = availW,
        value = tostring(spec.readFn() or "#000000"),
        onChange = function(hex) spec.writeFn(hex) end,
        prefix = uid.."_cf",
    })
    return { commit = cf.commit, refresh = cf.refresh }
end

-- ── Wide text row (block) — full-width input, label above ─────────────────────
local function w_wideText(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local availW    = c.formW - c.padL - c.padR - c.resetW - c.resetGap
    local hideApply = c.hideApply
    local inputW    = hideApply and availW or (availW - c.applyW - c.inputGap)

    local nl = Geyser.Label:new({name=uid.."_n", x=c.padL, y=6, width=availW, height=14}, row)
    nl:setStyleSheet(css.rowLabel)
    nl:rawEcho(spec.label)

    if c.hasDesc then
        local dl = Geyser.Label:new({name=uid.."_d", x=c.padL, y=20, width=availW, height=13}, row)
        dl:setStyleSheet(css.rowDesc)
        dl:rawEcho(spec.desc)
    end

    local input = Geyser.CommandLine:new({name=uid.."_i", x=c.padL, y=36, width=inputW, height=c.height}, row)
    input:setStyleSheet(css.textInput)
    input:print(tostring(spec.readFn() or ""))

    local function commit()
        local text = input:getText()
        if not text or text == "" then return end
        spec.writeFn(text)
        input:print(tostring(spec.readFn() or ""))
    end
    input:setAction(commit)

    if not hideApply then
        local aBtn = Geyser.Label:new({name=uid.."_a", x=c.padL+inputW+c.inputGap, y=36, width=c.applyW, height=c.height}, row)
        aBtn:setStyleSheet(css.applyBtn)
        aBtn:echo(string.format(
            "<center><span style='color:%s;font-size:9px;font-weight:bold;'>Apply</span></center>",
            css.widgetFg))
        aBtn:setClickCallback(commit)
    end

    if c.showReset then
        local ri = Geyser.Label:new({name=uid.."_rst", x=c.resetX, y=6, width=c.resetW, height=c.height}, row)
        ri:setStyleSheet(css.resetIcon)
        ri:echo("<center><span style='color:rgba(140,145,165,0.55);font-size:11px;'>↺</span></center>")
        ri:setClickCallback(function() c.closeDropdown(); c.onReset(c.i, spec) end)
    end

    return { commit = commit, refresh = function() input:print(tostring(spec.readFn() or "")) end }
end

-- ── Read-only row (block) — label left, value right ───────────────────────────
local function w_readOnly(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local vCenter = math.floor((c.rowH - 20) / 2)
    local nl = Geyser.Label:new({name=uid.."_n", x=c.padL, y=vCenter, width=c.thisNameW+24, height=20}, row)
    nl:setStyleSheet(css.rowLabel)
    nl:rawEcho(spec.label)

    local valW = c.width + c.resetW + c.resetGap
    local vl = Geyser.Label:new({name=uid.."_v", x=c.x, y=vCenter, width=valW, height=20}, row)
    vl:setStyleSheet(css.rowDesc)
    vl:rawEcho(string.format("<center>%s</center>", tostring(spec.readFn() or "")))
    return { refresh = function()
        vl:rawEcho(string.format("<center>%s</center>", tostring(spec.readFn() or "")))
    end }
end

-- ── Checkbox (inline) — bool, two-state toggle ────────────────────────────────
local function w_checkbox(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local trueOpt  = { value = true,  label = spec.trueLabel  or "TRUE",  style = "on"  }
    local falseOpt = { value = false, label = spec.falseLabel or "FALSE", style = "off" }
    local choices  = spec.options or { trueOpt, falseOpt }

    local btn = Geyser.Label:new({name=uid.."_cb", x=c.x, y=c.y, width=c.width, height=c.height}, row)
    local function refresh()
        local v = spec.readFn()
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
        c.closeDropdown()
        spec.writeFn(not spec.readFn())
        refresh()
    end)
    return { refresh = refresh }
end

-- ── Cycler (inline) — array/bool, N-state cycling button ──────────────────────
local function w_cycler(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local choices = spec.options or {
        { value = true,  label = "TRUE",  style = "on"  },
        { value = false, label = "FALSE", style = "off" },
    }
    local btn = Geyser.Label:new({name=uid.."_cyc", x=c.x, y=c.y, width=c.width, height=c.height}, row)
    local function refresh()
        local v = spec.readFn()
        local chosen = choices[1]
        for _, ch in ipairs(choices) do
            if ch.value == v then chosen = ch; break end
        end
        local s = chosen.style or "on"
        btn:setStyleSheet(css.styleCss[s] or css.styleCss.on)
        btn:echo(string.format(
            "<center><span style='color:%s;font-size:10px;font-weight:bold;'>%s</span></center>",
            css.styleFg[s] or css.styleFg.on, chosen.label))
    end
    refresh()
    btn:setClickCallback(function()
        c.closeDropdown()
        local v = spec.readFn()
        local curIdx = 1
        for ci, ch in ipairs(choices) do
            if ch.value == v then curIdx = ci; break end
        end
        spec.writeFn(choices[(curIdx % #choices) + 1].value)
        refresh()
    end)
    return { refresh = refresh }
end

-- ── Dropdown (inline) — array, floating overlay panel ─────────────────────────
local function w_dropdown(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local choices = spec.options or {}
    local ovName  = uid .. "_dov"
    local overlay = nil

    local btn = Geyser.Label:new({name=uid.."_dd", x=c.x, y=c.y, width=c.width, height=c.height}, row)
    btn:setStyleSheet(css.widgetBtn)

    local function destroyOverlay()
        if overlay then
            overlay:hide()
            for ci = 1, #choices do
                local n = ovName .. "_o" .. ci
                if Geyser.windowList[n] then Geyser.windowList[n]:hide() end
            end
            if c.getActive() == overlay then c.setActive(nil) end
            overlay = nil
        end
    end

    local capturedRowY = c.yPos

    local function refresh()
        local v = spec.readFn()
        local dispLabel = tostring(v or "")
        for _, ch in ipairs(choices) do
            if ch.value == v then dispLabel = ch.label; break end
        end
        if #dispLabel > 16 then dispLabel = dispLabel:sub(1, 15) .. "…" end
        btn:echo(string.format(
            "<center><span style='color:%s;font-size:10px;'>%s ▾</span></center>",
            css.widgetFg, dispLabel))
    end
    refresh()

    local function openOverlay()
        if not c.getScreenPos then return end
        local cx, cy  = c.getScreenPos()
        local absBtnX = cx + c.x
        local absBtnY = cy + capturedRowY + c.y + c.height
        overlay = Geyser.Label:new({
            name=ovName, x=absBtnX, y=absBtnY,
            width=c.width, height=#choices * c.height,
        }, Geyser)
        overlay:setStyleSheet(css.dropdownPanel)
        overlay:show(); overlay:raise()
        for ci, choice in ipairs(choices) do
            local opt = Geyser.Label:new({
                name=ovName.."_o"..ci, x=0, y=(ci-1)*c.height,
                width=c.width, height=c.height,
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
        c.setActive(overlay)
    end

    btn:setClickCallback(function()
        if c.getActive() then
            local was = (c.getActive() == overlay)
            c.closeDropdown()
            destroyOverlay()
            if was then return end
        end
        openOverlay()
    end)
    return { refresh = refresh }
end

-- ── Stepper (inline) — number, − value + ──────────────────────────────────────
local function w_stepper(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local step = spec.step or 1
    local minV = spec.min  or 0
    local maxV = spec.max  or 100
    local bw   = c.stepBtnW
    local vw   = c.width - bw * 2 - 4
    local sc   = css.widgetFg

    local minus = Geyser.Label:new({name=uid.."_sm", x=c.x,             y=c.y, width=bw, height=c.height}, row)
    local vl    = Geyser.Label:new({name=uid.."_sv", x=c.x+bw+2,        y=c.y, width=vw, height=c.height}, row)
    local plus  = Geyser.Label:new({name=uid.."_sp", x=c.x+bw+2+vw+2,   y=c.y, width=bw, height=c.height}, row)

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
        c.closeDropdown()
        spec.writeFn(math.max(minV, (spec.readFn() or minV) - step))
        refresh()
    end)
    plus:setClickCallback(function()
        c.closeDropdown()
        spec.writeFn(math.min(maxV, (spec.readFn() or minV) + step))
        refresh()
    end)
    return { refresh = refresh }
end

-- ── Inline text (inline) — number/string without wide layout ──────────────────
local function w_text(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local inW = c.width - c.applyW - c.inputGap
    local input = Geyser.CommandLine:new({name=uid.."_i", x=c.x, y=c.y, width=inW, height=c.height}, row)
    input:setStyleSheet(css.textInput)
    input:print(tostring(spec.readFn() or ""))

    local aBtn = Geyser.Label:new({name=uid.."_a", x=c.x+inW+c.inputGap, y=c.y, width=c.applyW, height=c.height}, row)
    aBtn:setStyleSheet(css.applyBtn)
    aBtn:echo(string.format(
        "<center><span style='color:%s;font-size:9px;font-weight:bold;'>Apply</span></center>",
        css.widgetFg))

    local function commit()
        c.closeDropdown()
        local text = input:getText()
        if not text or text == "" then return end
        spec.writeFn(text)
        input:print(tostring(spec.readFn() or ""))
    end
    input:setAction(commit)
    aBtn:setClickCallback(commit)
    return { commit = commit, refresh = function() input:print(tostring(spec.readFn() or "")) end }
end

-- ── Segmented control (inline) — N connected buttons, one highlighted ─────────
local function w_segmented(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local choices = spec.options or {}
    local n       = #choices
    if n == 0 then return {} end

    local segW  = math.floor(c.width / n)
    local lastW = c.width - segW * (n - 1)  -- last segment absorbs rounding remainder
    local ui    = (Mux.activeTheme and Mux.activeTheme() or {}).ui or {}
    local wBg   = ui.widgetBg     or "rgb(38,38,58)"
    local wFg   = ui.widgetFg     or "#d8d8f0"
    local wBd   = ui.widgetBorder or "rgba(255,255,255,0.22)"
    local wHv   = ui.widgetHoverBg or "rgb(55,55,80)"
    local selBg = (ui.styles and ui.styles.on and ui.styles.on.bg)     or "rgb(30,70,40)"
    local selFg = (ui.styles and ui.styles.on and ui.styles.on.fg)     or "#88ee88"
    local selBd = (ui.styles and ui.styles.on and ui.styles.on.border) or "rgba(80,180,80,0.5)"
    local selHv = (ui.styles and ui.styles.on and ui.styles.on.hover)  or "rgb(40,90,50)"

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
        local sx = c.x + (ci - 1) * segW
        local sw = (ci == n) and lastW or segW
        local seg = Geyser.Label:new({
            name=uid.."_sg"..ci, x=sx, y=c.y, width=sw, height=c.height, fillBg=1,
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
            c.closeDropdown()
            spec.writeFn(captured.value)
            refresh()
        end)
    end
    return { refresh = refresh }
end

-- Built-in render-key registry.  buildForm resolves each row to one of these (or
-- to a custom Mux.ui._widgets type).  Authors may override an entry to restyle a
-- control globally; `layout` is "inline" unless stated.
Mux.ui._builtins = {
    color     = { build = w_color,     layout = "block" },
    wideText  = { build = w_wideText,  layout = "block" },
    readOnly  = { build = w_readOnly,  layout = "block" },
    checkbox  = { build = w_checkbox },
    cycler    = { build = w_cycler },
    dropdown  = { build = w_dropdown },
    stepper   = { build = w_stepper },
    text      = { build = w_text },
    segmented = { build = w_segmented },
}

-- ── buildForm ─────────────────────────────────────────────────────────────────
-- A thin layout shell: per row it resolves a builder (built-in or custom),
-- renders the shared chrome for inline rows, and delegates control creation.

function Mux.ui.buildForm(parent, specs, opts)
    opts = opts or {}

    local theme    = Mux.activeTheme() or {}
    local css      = deriveCss(theme.ui or theme.settingsUi)

    local formW    = opts.width        or (parent:get_width() > 50 and parent:get_width() or 400)
    local prefix   = opts.prefix       or "muxui"
    local rowH     = opts.rowHeight    or 42
    local textH    = opts.textRowHeight or 64
    local colorH   = opts.colorRowHeight or 92
    local widgetH  = opts.widgetHeight or 24
    local padL     = opts.padLeft      or 10
    local padR     = opts.padRight     or 6
    local applyW   = 42
    local inputGap = 3
    local stepBtnW = 26

    local showReset = opts.showReset and opts.onReset
    local resetW    = showReset and 20 or 0
    local resetGap  = showReset and 8  or 0
    local resetX    = formW - resetW - padR

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

    -- Shared chrome for inline rows: label (+ help icon) on the left.
    local function renderInlineLabel(row, uid, spec, hasDesc, thisNameW)
        local vCenter = math.floor((rowH - 20) / 2)
        local nameX   = hasDesc and padL + 22 or padL
        local nameW2  = hasDesc and thisNameW or thisNameW + 22
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
    end

    -- Shared chrome for inline rows: reset-to-default icon on the right.
    local function renderInlineReset(row, uid, spec, i, wy)
        if not showReset then return end
        local ri = Geyser.Label:new({name=uid.."_rst", x=resetX, y=wy, width=resetW, height=widgetH}, row)
        ri:setStyleSheet(css.resetIcon)
        ri:echo("<center><span style='color:rgba(140,145,165,0.55);font-size:11px;'>↺</span></center>")
        ri:setClickCallback(function() closeDropdown(); opts.onReset(i, spec) end)
    end

    local function wire(i, handle)
        if type(handle) == "table" then
            if handle.commit  then commitFns[i]  = handle.commit  end
            if handle.refresh then refreshFns[i] = handle.refresh end
        end
    end

    for i, spec in ipairs(specs) do
        -- ── Resolve type aliases ──────────────────────────────────────────────
        local specType    = spec.type
        local specDisplay = spec.display
        local isReadOnly  = spec.readOnly

        if specType == "toggle"            then specType = "bool";   specDisplay = specDisplay or "checkbox"
        elseif specType == "choiceCycler"  then specType = "array";  specDisplay = specDisplay or "cycler"
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

        local customW = Mux.ui._widgets[specType]
        local isColor = (specType == "color")
        local isWide  = (specType == "string") and (specDisplay == "text") and not isReadOnly
        local thisH   = (customW and customW.rowHeight) or (isColor and colorH or (isWide and textH or rowH))
        local uid     = prefix .. "_w" .. i

        -- Per-row widget width override (e.g. wider segmented controls).
        local thisWidgetW = resolveWidgetW(spec, opts)
        local thisWidgetX = formW - thisWidgetW - padR - resetW - resetGap

        -- ── Row container ─────────────────────────────────────────────────────
        local row = Geyser.Label:new({
            name=uid.."_row", x=0, y=yPos, width=formW, height=thisH,
        }, parent)
        row:setStyleSheet(i % 2 == 1 and css.odd or css.even)

        local wy        = math.floor((thisH - widgetH) / 2)
        local thisNameW = thisWidgetX - padL - 24
        local hasDesc   = spec.desc and spec.desc ~= ""

        -- ── Resolve builder + layout ──────────────────────────────────────────
        local def
        if     isColor     then def = Mux.ui._builtins.color
        elseif isWide      then def = Mux.ui._builtins.wideText
        elseif isReadOnly  then def = Mux.ui._builtins.readOnly
        elseif customW     then def = customW                 -- custom: inline
        else                    def = Mux.ui._builtins[specDisplay]
        end
        local builder = def and def.build
        local layout  = (def and def.layout) or "inline"

        local ctx = {
            -- widget rectangle (inline) / row reference points (block)
            x = thisWidgetX, y = wy, width = thisWidgetW, height = widgetH, wy = wy,
            -- full-row geometry for block builders
            formW = formW, padL = padL, padR = padR, rowH = rowH,
            resetX = resetX, resetW = resetW, resetGap = resetGap,
            applyW = applyW, inputGap = inputGap, stepBtnW = stepBtnW,
            hasDesc = hasDesc, hideApply = opts.hideApply, thisNameW = thisNameW,
            -- data
            spec = spec, css = css, uid = uid, i = i, yPos = yPos,
            value = spec.readFn and spec.readFn() or nil,
            onChange = spec.writeFn or function() end,
            -- helpers
            closeDropdown = closeDropdown,
            getScreenPos = opts.getContentScreenPos,
            getActive = function() return activeDropdown end,
            setActive = function(o) activeDropdown = o end,
            onReset = opts.onReset, showReset = showReset,
        }

        if layout == "block" then
            if builder then wire(i, builder(row, ctx)) end
        else
            renderInlineLabel(row, uid, spec, hasDesc, thisNameW)
            if builder then wire(i, builder(row, ctx)) end
            renderInlineReset(row, uid, spec, i, wy)
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