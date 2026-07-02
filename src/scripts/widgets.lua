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
        descText    = descText,
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
        -- Apply button state styles: "done" = current text is applied — greyed out so
        -- it clearly reads as inactive/nothing-to-apply; "active" = text edited but not
        -- yet applied (accented, actionable).
        applyBtnDone = string.format(
            "QLabel{background-color:rgba(46,48,58,0.55);border:1px solid rgba(90,94,112,0.35);"
            .. "border-radius:3px;color:%s;font-size:9px;font-weight:bold;}", descText),
        applyBtnActive = string.format(
            "QLabel{background-color:%s;border:1px solid rgba(120,180,255,0.85);border-radius:3px;"
            .. "color:#cfe0ff;font-size:9px;font-weight:bold;}"
            .. "QLabel::hover{background-color:%s;color:#ffffff;}", widgetHv, widgetHv),
        dropdownBtn = string.format(
            "QLabel{background:%s;color:%s;border:1px solid %s;border-radius:4px;}"
            .. "QLabel::hover{background:%s;border:1px solid rgba(120,160,255,0.6);}",
            widgetBg, widgetFg, widgetBd, widgetHv),
        dropdownPanel = string.format(
            "background:%s;border:1px solid rgba(120,160,255,0.45);border-radius:5px;", inputBg),
        dropdownOpt = string.format(
            "QLabel{background:transparent;color:%s;font-size:12px;border-radius:3px;}"
            .. "QLabel::hover{background:%s;color:#ffffff;}", widgetFg, widgetHv),
        dropdownOptSel = string.format(
            "QLabel{background:%s;color:#cfe0ff;font-size:12px;border-radius:3px;}"
            .. "QLabel::hover{background:%s;color:#ffffff;}", widgetHv, widgetHv),
        resetIcon   = "QLabel{background:transparent;color:rgba(140,145,165,0.55);font-size:11px;"
            .. "border:1px solid rgba(140,145,165,0.25);border-radius:3px;}"
            .. "QLabel::hover{color:rgba(220,180,80,0.85);border-color:rgba(220,180,80,0.55);}",
        styleCss    = styleCssMap,
        styleFg     = styleFgMap,
        dividerRow   = "background:transparent;border:none;",
        dividerLabel = string.format("background:transparent;color:%s;font-size:10px;font-weight:bold;letter-spacing:1px;", descText),
        dividerLine  = string.format("background:%s;border:none;", divider),
        -- Icon cascade default button style (square glyph button, brightens on hover).
        iconBtn      = string.format(
            "QLabel{background:%s;color:%s;border:1px solid %s;border-radius:4px;"
            .. "qproperty-alignment:AlignCenter;font-size:13px;}"
            .. "QLabel::hover{background:%s;color:#ffffff;border:1px solid rgba(120,160,255,0.6);}",
            widgetBg, widgetFg, widgetBd, widgetHv),
        iconBtnActive = string.format(
            "QLabel{background:%s;color:#ffffff;border:1px solid rgba(120,160,255,0.7);border-radius:4px;"
            .. "qproperty-alignment:AlignCenter;font-size:13px;}", widgetHv),
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
    if spec.rowHeight then return spec.rowHeight end   -- explicit per-row override
    if spec.type == "divider" then return opts.dividerHeight or 24 end
    local cw = Mux.ui._widgets[spec.type]
    if cw then return cw.rowHeight or opts.rowHeight or 42 end
    if spec.type == "color" then return opts.colorRowHeight or 64 end
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

-- HSV (h 0–360, s/v 0–1) → "#rrggbb". Used to generate the colour-wheel cells.
local function hsvToHex(h, s, v)
    h = h % 360
    local c = v * s
    local xx = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b = 0, 0, 0
    if     h <  60 then r, g, b = c, xx, 0
    elseif h < 120 then r, g, b = xx, c, 0
    elseif h < 180 then r, g, b = 0, c, xx
    elseif h < 240 then r, g, b = 0, xx, c
    elseif h < 300 then r, g, b = xx, 0, c
    else                r, g, b = c, 0, xx end
    return string.format("#%02x%02x%02x",
        math.floor((r + m) * 255 + 0.5),
        math.floor((g + m) * 255 + 0.5),
        math.floor((b + m) * 255 + 0.5))
end

-- ── Colour parsing / formatting (format-agnostic, alpha-aware) ───────────────
-- Accept hex (#rgb / #rrggbb / #rrggbbaa), rgb()/rgba() (alpha as 0–1 or 0–255),
-- and a few names; emit hex when fully opaque, rgba(...) (alpha 0–1) otherwise.
-- Exposed publicly as the canonical converters used across the UI.
local COLOR_NAMES = {
    white = {255,255,255,1}, black = {0,0,0,1},
    transparent = {0,0,0,0}, none = {0,0,0,0},
}
function Mux.ui.parseColor(str)
    str = tostring(str or ""):gsub("%s+", ""):lower()
    local nm = COLOR_NAMES[str]
    if nm then return nm[1], nm[2], nm[3], nm[4] end
    local hx = str:match("^#(%x+)$")
    if hx then
        if #hx == 3 then
            local r,g,b = tonumber(hx:sub(1,1),16), tonumber(hx:sub(2,2),16), tonumber(hx:sub(3,3),16)
            return r*17, g*17, b*17, 1
        elseif #hx == 6 then
            return tonumber(hx:sub(1,2),16), tonumber(hx:sub(3,4),16), tonumber(hx:sub(5,6),16), 1
        elseif #hx == 8 then
            return tonumber(hx:sub(1,2),16), tonumber(hx:sub(3,4),16), tonumber(hx:sub(5,6),16),
                   (tonumber(hx:sub(7,8),16) or 255) / 255
        end
    end
    local r,g,b,a = str:match("^rgba?%((%d+),(%d+),(%d+),([%d%.]+)%)$")
    if r then
        local av = tonumber(a) or 1
        -- 0–1 float if it has a decimal point or is <= 1; otherwise a 0–255 integer.
        if not (a:find("%.") or av <= 1) then av = av / 255 end
        return tonumber(r), tonumber(g), tonumber(b), av
    end
    r,g,b = str:match("^rgb%((%d+),(%d+),(%d+)%)$")
    if r then return tonumber(r), tonumber(g), tonumber(b), 1 end
    return 0, 0, 0, 1
end

function Mux.ui.formatColor(r, g, b, a)
    local function clamp(v) v = math.floor((v or 0) + 0.5); return v < 0 and 0 or (v > 255 and 255 or v) end
    r, g, b = clamp(r), clamp(g), clamp(b)
    a = a or 1; if a < 0 then a = 0 elseif a > 1 then a = 1 end
    if a >= 0.999 then return string.format("#%02x%02x%02x", r, g, b) end
    local as = string.format("%.3f", a):gsub("0+$", ""):gsub("%.$", "")
    return string.format("rgba(%d,%d,%d,%s)", r, g, b, as)
end

-- r,g,b (0–255) → HSV (h 0–360, s/v 0–1). Pairs with hsvToHex for the hue/brightness UI.
local function rgbToHsv(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d = mx - mn
    local h = 0
    if d ~= 0 then
        if     mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else                h = (r - g) / d + 4 end
        h = h * 60
    end
    return h, (mx == 0) and 0 or (d / mx), mx
end

-- Closes whichever colour wheel is currently open (only one can be), if any.
-- Hosts that tear down (e.g. a dialog closing) call this so a wheel never lingers.
function Mux.ui.closeColorWheel()
    if Mux.ui._closeActiveWheel then Mux.ui._closeActiveWheel() end
end

-- Closes whichever dropdown overlay is currently open (only one can be), if any.
-- Called by pane and tab teardown so a floating dropdown panel never outlives its host.
function Mux.ui.closeDropdown()
    if Mux.ui._activeDropdownClose then Mux.ui._activeDropdownClose() end
end

-- A compact colour control: a swatch, a hex input (Enter commits), a colour
-- wheel popup (click the swatch) for choosing hue/saturation, and a brightness
-- strip for fine-tuning light/dark. The strip shows the current hue/saturation
-- from dark to light; clicking a cell sets that brightness (HSV value) while
-- keeping hue and saturation.
function Mux.ui.colorField(parent, opts)
    opts = opts or {}
    local value    = opts.value or "#000000"
    local onChange = opts.onChange or function() end
    local r, g, b, a = Mux.ui.parseColor(value)
    local x, y     = opts.x or 0, opts.y or 0
    local width    = opts.width or 240
    local prefix   = opts.prefix or ("muxcf_" .. tostring(math.random(1, 1000000000)))
    local getScreenPos = opts.getScreenPos
    local INPUTH   = 26
    local height   = INPUTH    -- inline = swatch + hex; the full picker lives in a popup

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

    -- Repaint from current r,g,b,a. render() never fires onChange; emit() does.
    local refreshPopup   -- set while the popup is open, nil otherwise
    local function render(skipInput)
        value = Mux.ui.formatColor(r, g, b, a)
        setPreview(value)
        if not skipInput then input:print(value) end
        if refreshPopup then refreshPopup() end
    end
    local function emit(fromInput)
        render(fromInput)
        onChange(value)
    end

    setPreview(value)
    input:print(value)
    input:setAction(function() r, g, b, a = Mux.ui.parseColor(input:getText()); emit(true) end)

    -- ── Picker popup (click the swatch) ─────────────────────────────────────────
    -- Hue/saturation cells pick a colour; a Brightness ramp tunes value and an
    -- Opacity ramp tunes alpha. Picks update in place and the popup stays open so
    -- value/opacity can be adjusted, then it closes via the ✕ or the backdrop.
    local POPW = 210
    local wheelCells, wheelPanel, wheelScrim = {}, nil, nil

    local function closeWheel()
        if not (wheelPanel or wheelScrim) then return end
        for _, w in ipairs(wheelCells) do if w.delete then w:delete() else w:hide() end end
        if wheelPanel then if wheelPanel.delete then wheelPanel:delete() else wheelPanel:hide() end end
        if wheelScrim then if wheelScrim.delete then wheelScrim:delete() else wheelScrim:hide() end end
        wheelCells, wheelPanel, wheelScrim = {}, nil, nil
        refreshPopup = nil
        if Mux.ui._closeActiveWheel == closeWheel then Mux.ui._closeActiveWheel = nil end
    end

    local function newCell(px, py, w2, h2, name)
        local c = Geyser.Label:new({ name = prefix..name,
            x = math.floor(px), y = math.floor(py), width = math.floor(w2), height = math.floor(h2) }, wheelPanel)
        c:show(); c:raise()
        wheelCells[#wheelCells + 1] = c
        return c
    end

    local function openWheel()
        if Mux.ui._closeActiveWheel then Mux.ui._closeActiveWheel() end   -- only one open anywhere
        local host = getScreenPos and Geyser or parent
        wheelScrim = Geyser.Label:new({ name = prefix .. "_wscrim", x = 0, y = 0, width = "100%", height = "100%" }, host)
        wheelScrim:setStyleSheet("background:rgba(0,0,0,0.01);border:none;")
        wheelScrim:show(); wheelScrim:raise()
        wheelScrim:setClickCallback(closeWheel)

        local px, py
        if getScreenPos then local ox, oy = getScreenPos(); px, py = ox + x, oy + y + INPUTH + 4
        else px, py = x, y + INPUTH + 4 end
        local POPH = 286
        wheelPanel = Geyser.Label:new({ name = prefix .. "_wheel",
            x = math.floor(px), y = math.floor(py), width = POPW, height = POPH }, host)
        wheelPanel:setStyleSheet("background:rgba(20,21,30,0.98);border:1px solid rgba(255,255,255,0.18);border-radius:6px;")
        wheelPanel:show(); wheelPanel:raise()

        local xb = newCell(POPW - 20, 4, 16, 16, "_wx")
        xb:setStyleSheet("background:transparent;color:rgba(210,210,225,0.85);qproperty-alignment:AlignCenter;font-size:12px;")
        xb:echo("<center>✕</center>")
        xb:setClickCallback(closeWheel)

        local function pickHsCell(cpx, cpy, sz, hex)
            local c = newCell(cpx, cpy, sz, sz, "_wc"..(#wheelCells+1))
            c:setStyleSheet(string.format("background:%s;border:1px solid rgba(0,0,0,0.35);border-radius:2px;", hex))
            c:setToolTip(hex)
            local cap = hex
            c:setClickCallback(function() r, g, b = Mux.ui.parseColor(cap); emit(false) end)
        end

        local cx, cy, cell = 100, 92, 14
        pickHsCell(cx - cell/2, cy - cell/2, cell, "#ffffff")
        local rings = { {r=20,s=0.30}, {r=38,s=0.55}, {r=56,s=0.78}, {r=74,s=1.0} }
        for _, ring in ipairs(rings) do
            local sectors = math.max(6, math.floor(2*math.pi*ring.r/(cell+2)))
            for j = 0, sectors-1 do
                local ang = (j/sectors)*2*math.pi
                pickHsCell(cx+ring.r*math.cos(ang)-cell/2, cy+ring.r*math.sin(ang)-cell/2, cell,
                           hsvToHex((j/sectors)*360, ring.s, 1))
            end
        end

        local STRIP_N = 14
        local sw = math.floor((POPW - 20) / STRIP_N)
        local vCells, aCells = {}, {}
        local function levelV(k) return 0.12 + (k/(STRIP_N-1))*0.88 end
        local function levelA(k) return k/(STRIP_N-1) end

        local vlabel = newCell(10, 178, 90, 12, "_vlab")
        vlabel:setStyleSheet("background:transparent;color:rgba(170,175,195,0.8);font-size:9px;")
        vlabel:echo("Brightness")
        for k = 0, STRIP_N-1 do
            local c = newCell(10 + k*sw, 192, sw-2, 16, "_v"..k)
            c:setToolTip("Brightness")
            local kk = k
            c:setClickCallback(function()
                local h, s = rgbToHsv(r, g, b)
                r, g, b = Mux.ui.parseColor(hsvToHex(h, s, levelV(kk))); emit(false)
            end)
            vCells[k+1] = c
        end

        local alabel = newCell(10, 214, 90, 12, "_alab")
        alabel:setStyleSheet("background:transparent;color:rgba(170,175,195,0.8);font-size:9px;")
        alabel:echo("Opacity")
        for k = 0, STRIP_N-1 do
            local c = newCell(10 + k*sw, 228, sw-2, 16, "_a"..k)
            c:setToolTip("Opacity")
            local kk = k
            c:setClickCallback(function() a = levelA(kk); emit(false) end)
            aCells[k+1] = c
        end

        local pv = newCell(10, 252, 24, 24, "_wpv")
        local hx = newCell(40, 256, POPW-50, 16, "_whex")
        hx:setStyleSheet("background:transparent;color:rgba(210,210,225,0.85);font-size:11px;")

        refreshPopup = function()
            local h, s = rgbToHsv(r, g, b)
            local v = math.max(r, g, b)/255
            local cv, cvd = 1, math.huge
            for k = 0, STRIP_N-1 do local d=math.abs(levelV(k)-v); if d<cvd then cvd=d; cv=k+1 end end
            for k = 0, STRIP_N-1 do local cc=vCells[k+1]; if cc then
                cc:setStyleSheet(string.format("background:%s;border:1px solid %s;border-radius:2px;",
                    hsvToHex(h, s, levelV(k)), (k+1)==cv and "rgba(255,255,255,0.9)" or "rgba(0,0,0,0.3)")) end end
            local ca, cad = 1, math.huge
            for k = 0, STRIP_N-1 do local d=math.abs(levelA(k)-a); if d<cad then cad=d; ca=k+1 end end
            for k = 0, STRIP_N-1 do local cc=aCells[k+1]; if cc then
                cc:setStyleSheet(string.format("background:rgba(%d,%d,%d,%.3f);border:1px solid %s;border-radius:2px;",
                    r, g, b, levelA(k), (k+1)==ca and "rgba(255,255,255,0.9)" or "rgba(255,255,255,0.18)")) end end
            pv:setStyleSheet(string.format("background:%s;border:1px solid rgba(255,255,255,0.25);border-radius:3px;",
                Mux.ui.formatColor(r,g,b,a)))
            hx:echo(Mux.ui.formatColor(r,g,b,a))
        end
        refreshPopup()
        Mux.ui._closeActiveWheel = closeWheel
    end

    preview:setToolTip("Click to open the colour picker")
    preview:setClickCallback(function()
        if wheelPanel then closeWheel() else openWheel() end
    end)

    return {
        container = cont,
        height    = height,
        read      = function() return value end,
        set       = function(str) r, g, b, a = Mux.ui.parseColor(str); emit(false) end,
        setSilent = function(str) r, g, b, a = Mux.ui.parseColor(str); render(false) end,
        commit    = function() r, g, b, a = Mux.ui.parseColor(input:getText()); emit(true) end,
        refresh   = function() render(false) end,
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
    Mux.ui._widgets[wtype] = { build = builder, rowHeight = opts and opts.rowHeight, layout = opts and opts.layout }
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
    local rsv = c.showReset and (c.resetW + c.resetGap) or 0
    local availW = c.formW - c.padL - c.padR - rsv
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
        getScreenPos = c.getScreenPos and function()
            local fx, fy = c.getScreenPos()
            return fx, fy + c.yPos     -- form-content origin + this row's offset = row top-left
        end,
    })
    if c.showReset and not c.spec._noReset then
        local ri = Geyser.Label:new({name=uid.."_rst", x=c.resetX, y=6, width=c.resetW, height=18}, row)
        ri:setStyleSheet(css.resetIcon)
        ri:echo("<center><span style='color:rgba(140,145,165,0.55);font-size:11px;'>↺</span></center>")
        if spec.desc then ri:setToolTip(c.resetTooltip or "Reset") end
        ri:setClickCallback(function() c.closeDropdown(); c.onReset(c.i, spec) end)
    end
    return { commit = cf.commit, refresh = function()
        cf.setSilent(tostring(spec.readFn() or "#000000"))
    end }
end

-- ── Wide text row (block) — full-width input, label above ─────────────────────

-- Wire an Apply button so it visually reflects whether the box text is in effect:
-- greyed ("done") when the current text equals the applied value, accented
-- ("active") when it's been edited but not yet applied. Geyser command lines expose
-- no text-changed event, so a light self-terminating poll keeps the state in sync;
-- it stops as soon as the widget is gone (any call on a dead widget errors). Returns
-- a repaint fn to call right after an explicit commit for an instant update.
local function wireApplyState(input, aBtn, getApplied, css)
    if not aBtn then return function() end end
    local activeCss = css.applyBtnActive or css.applyBtn
    local doneCss   = css.applyBtnDone   or css.applyBtn
    local brightCol = css.widgetFg or "#dfe6ff"
    local mutedCol  = css.descText or "rgba(120,130,170,0.85)"
    local function paint()
        local ok, cur = pcall(function() return input:getText() end)
        if not ok then return false end                     -- widget gone → stop
        local applied = tostring(getApplied() or "")
        local dirty   = (tostring(cur or "") ~= applied)
        local ok2 = pcall(function()
            aBtn:setStyleSheet(dirty and activeCss or doneCss)
            -- Re-echo the label too: the inline colour overrides the stylesheet, so the
            -- text itself must dim when applied for the button to read as inactive.
            aBtn:echo(string.format(
                "<center><span style='color:%s;font-size:9px;font-weight:bold;'>Apply</span></center>",
                dirty and brightCol or mutedCol))
        end)
        return ok2
    end
    paint()
    if tempTimer then
        local function loop() if paint() then tempTimer(0.3, loop) end end
        tempTimer(0.3, loop)
    end
    return paint
end

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

    local applyPaint = function() end
    local function commit()
        local text = input:getText() or ""
        -- Normally an empty box is ignored (avoids wiping a value by accident); fields
        -- that opt in with spec.allowEmpty can be cleared by blanking + Enter.
        if text == "" and not spec.allowEmpty then return end
        spec.writeFn(text)
        input:print(tostring(spec.readFn() or ""))
        applyPaint()                                  -- now applied → grey out
    end
    input:setAction(commit)

    if not hideApply then
        local aBtn = Geyser.Label:new({name=uid.."_a", x=c.padL+inputW+c.inputGap, y=36, width=c.applyW, height=c.height}, row)
        aBtn:echo(string.format(
            "<center><span style='color:%s;font-size:9px;font-weight:bold;'>Apply</span></center>",
            css.widgetFg))
        aBtn:setClickCallback(commit)
        applyPaint = wireApplyState(input, aBtn, function() return spec.readFn() end, css)
    end

    if c.showReset and not c.spec._noReset then
        local ri = Geyser.Label:new({name=uid.."_rst", x=c.resetX, y=6, width=c.resetW, height=c.height}, row)
        ri:setStyleSheet(css.resetIcon)
        ri:echo("<center><span style='color:rgba(140,145,165,0.55);font-size:11px;'>↺</span></center>")
        ri:setClickCallback(function() c.closeDropdown(); c.onReset(c.i, spec) end)
    end

    return { commit = commit, refresh = function() input:print(tostring(spec.readFn() or "")); applyPaint() end }
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
    local optH    = math.max(c.height, 26)   -- roomier rows than the trigger button

    local btn = Geyser.Label:new({name=uid.."_dd", x=c.x, y=c.y, width=c.width, height=c.height}, row)
    btn:setStyleSheet(css.dropdownBtn or css.widgetBtn)

    local function destroyOverlay()
        if overlay then
            overlay:hide()
            for ci = 1, #choices do
                local n = ovName .. "_o" .. ci
                if Geyser.windowList[n] then Geyser.windowList[n]:hide() end
            end
            if c.getActive() == overlay then c.setActive(nil) end
            overlay = nil
            if Mux.ui._activeDropdownClose == destroyOverlay then
                Mux.ui._activeDropdownClose = nil
            end
        end
    end

    local capturedRowY = c.yPos

    local function refresh()
        local v = spec.readFn()
        local dispLabel = tostring(v or "")
        for _, ch in ipairs(choices) do
            if ch.value == v then dispLabel = ch.label; break end
        end
        if #dispLabel > 22 then dispLabel = dispLabel:sub(1, 21) .. "…" end
        -- Label left, chevron pinned right (table keeps them apart at any width).
        btn:echo(string.format(
            "<table width='100%%' cellpadding='0' cellspacing='0' style='font-size:12px;'><tr>"
            .. "<td align='left' style='color:%s;padding-left:8px;'>%s</td>"
            .. "<td align='right' style='color:%s;padding-right:8px;'>▾</td>"
            .. "</tr></table>",
            css.widgetFg, dispLabel, css.widgetFg))
    end
    refresh()

    local function openOverlay()
        if not c.getScreenPos then return end
        -- Close any dropdown open in another form before creating this one.
        if Mux.ui._activeDropdownClose and Mux.ui._activeDropdownClose ~= destroyOverlay then
            Mux.ui._activeDropdownClose()
        end
        local cx, cy  = c.getScreenPos()
        local panelW  = math.max(c.width, 150)
        local absBtnX = cx + c.x
        local absBtnY = cy + capturedRowY + c.y + c.height + 2
        overlay = Geyser.Label:new({
            name=ovName, x=absBtnX, y=absBtnY,
            width=panelW, height=#choices * optH + 6,
        }, Geyser)
        overlay:setStyleSheet(css.dropdownPanel)
        overlay:show(); overlay:raise()
        local cur = spec.readFn()
        for ci, choice in ipairs(choices) do
            local selected = (choice.value == cur)
            local opt = Geyser.Label:new({
                name=ovName.."_o"..ci, x=4, y=3 + (ci-1)*optH,
                width=panelW-8, height=optH,
            }, overlay)
            opt:setStyleSheet(selected and (css.dropdownOptSel or css.dropdownOpt) or css.dropdownOpt)
            opt:echo(string.format(
                "<table width='100%%' cellpadding='0' cellspacing='0' style='font-size:12px;'><tr>"
                .. "<td align='left' style='padding-left:8px;'>%s</td>"
                .. "<td align='right' style='padding-right:8px;color:#cfe0ff;'>%s</td>"
                .. "</tr></table>",
                tostring(choice.label), selected and "✓" or ""))
            opt:setCursor("PointingHand")
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
        Mux.ui._activeDropdownClose = destroyOverlay
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
    aBtn:echo(string.format(
        "<center><span style='color:%s;font-size:9px;font-weight:bold;'>Apply</span></center>",
        css.widgetFg))

    local applyPaint = function() end
    local function commit()
        c.closeDropdown()
        local text = input:getText() or ""
        if text == "" and not spec.allowEmpty then return end
        spec.writeFn(text)
        input:print(tostring(spec.readFn() or ""))
        applyPaint()                                  -- now applied → grey out
    end
    input:setAction(commit)
    aBtn:setClickCallback(commit)
    applyPaint = wireApplyState(input, aBtn, function() return spec.readFn() end, css)
    return { commit = commit, refresh = function() input:print(tostring(spec.readFn() or "")); applyPaint() end }
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
                "QLabel{background:%s;color:%s;font-size:11px;font-weight:bold;border:1px solid %s;%s}"
                .. "QLabel::hover{background:%s;}",
                selBg, selFg, selBd, r, selHv)
        else
            return string.format(
                "QLabel{background:%s;color:%s;font-size:11px;border:1px solid %s;%s}"
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

-- ── Action button (block) — a full-width clickable button that fires onClick ──
local function w_button(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local h = 24
    local btn = Geyser.Label:new({
        name = uid.."_btn", x = c.padL, y = math.floor((c.rowH - h)/2),
        width = c.formW - c.padL - c.padR, height = h,
    }, row)
    btn:setStyleSheet(css.actionBtn or
        "QLabel{background:rgba(120,160,255,0.14);color:#cfe0ff;border:1px solid rgba(120,160,255,0.40);"
        .. "border-radius:4px;qproperty-alignment:'AlignCenter';font-size:11px;}"
        .. "QLabel::hover{background:rgba(120,160,255,0.24);}")
    btn:echo("<center>" .. (spec.label or "Button") .. "</center>")
    btn:setCursor("PointingHand")
    if spec.desc then btn:setToolTip(spec.desc) end
    btn:setClickCallback(function() c.closeDropdown(); if spec.onClick then spec.onClick() end end)
    return {}
end

-- Built-in render-key registry.  buildForm resolves each row to one of these (or
-- to a custom Mux.ui._widgets type).  Authors may override an entry to restyle a
-- control globally; `layout` is "inline" unless stated.
Mux.ui._builtins = {
    color     = { build = w_color,     layout = "block" },
    wideText  = { build = w_wideText,  layout = "block" },
    readOnly  = { build = w_readOnly,  layout = "block" },
    button    = { build = w_button,    layout = "block" },
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
    local colorH   = opts.colorRowHeight or 64
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

    -- Absolute screen position of the form's content area. Callers may override, but
    -- the default reads the parent's own geometry (Geyser get_x/get_y are absolute
    -- within the main window), so dropdown/colour popups position themselves with no
    -- per-caller code. This is what makes those popups work in any dialog.
    local getContentScreenPos = opts.getContentScreenPos or function()
        local ok, x = pcall(function() return parent.get_x and parent:get_x() or 0 end)
        local oky, y = pcall(function() return parent.get_y and parent:get_y() or 0 end)
        return (ok and x) or 0, (oky and y) or 0
    end

    local activeDropdown = nil
    local refreshFns     = {}
    local commitFns      = {}
    local yPos           = 0

    -- Collapsible sections: each divider opens a section; the rows that follow
    -- (until the next divider) belong to it and hide/show when it's toggled.
    local secLayout, sections, curSec = {}, {}, nil
    local relayout
    local formTotalHeight = 0

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
        if not showReset or spec._noReset then return end
        local ri = Geyser.Label:new({name=uid.."_rst", x=resetX, y=wy, width=resetW, height=widgetH}, row)
        ri:setStyleSheet(css.resetIcon)
        ri:echo("<center><span style='color:rgba(140,145,165,0.55);font-size:11px;'>↺</span></center>")
        if opts.resetTooltip then ri:setToolTip(opts.resetTooltip) end
        ri:setClickCallback(function() closeDropdown(); opts.onReset(i, spec) end)
    end

    local function wire(i, handle)
        if type(handle) == "table" then
            if handle.commit  then commitFns[i]  = handle.commit  end
            if handle.refresh then refreshFns[i] = handle.refresh end
        end
    end

    for i, spec in ipairs(specs) do
        local uid = prefix .. "_w" .. i

        -- ── Divider / section header ──────────────────────────────────────────
        if spec.type == "divider" then
            local divH = spec.rowHeight or opts.dividerHeight or 24
            local divRow = Geyser.Label:new({
                name=uid.."_row", x=0, y=yPos, width=formW, height=divH,
            }, parent)
            divRow:setStyleSheet(css.dividerRow)
            local secIdx = #sections + 1
            sections[secIdx] = { collapsed = spec._collapsed == true }
            curSec = secIdx
            local arrow
            if spec.label and spec.label ~= "" then
                arrow = Geyser.Label:new({
                    name=uid.."_ar", x=padL, y=math.floor((divH-14)/2), width=12, height=14,
                }, divRow)
                arrow:setStyleSheet("background:transparent;border:none;color:rgba(170,175,195,0.8);font-size:10px;")
                arrow:echo(sections[secIdx].collapsed and "▸" or "▾")
                local lblX  = padL + 14
                local textW = math.min(math.max(60, #spec.label * 8 + 8), formW - lblX - padR - 20)
                local nl = Geyser.Label:new({
                    name=uid.."_n", x=lblX, y=math.floor((divH-14)/2), width=textW, height=14,
                }, divRow)
                nl:setStyleSheet(css.dividerLabel)
                nl:rawEcho(spec.label)
                local lineX = lblX + textW + 6
                local lw    = formW - lineX - padR
                if lw > 4 then
                    local line = Geyser.Label:new({
                        name=uid.."_l", x=lineX, y=math.floor(divH/2), width=lw, height=1,
                    }, divRow)
                    line:setStyleSheet(css.dividerLine)
                end
                local function toggle()
                    local sec = sections[secIdx]
                    sec.collapsed = not sec.collapsed
                    arrow:echo(sec.collapsed and "▸" or "▾")
                    closeDropdown()
                    if relayout then relayout() end
                end
                divRow:setClickCallback(toggle)
                nl:setClickCallback(toggle)
                arrow:setClickCallback(toggle)
            else
                local line = Geyser.Label:new({
                    name=uid.."_l", x=padL, y=math.floor(divH/2), width=formW-padL-padR, height=1,
                }, divRow)
                line:setStyleSheet(css.dividerLine)
            end
            secLayout[#secLayout+1] = { kind="divider", obj=divRow, h=divH, secIdx=secIdx }
            yPos = yPos + divH
        else
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
            elseif specType == "button" then specDisplay = "button"
            else                             specDisplay = "text"
            end
        end

        local customW = Mux.ui._widgets[specType]
        local isColor = (specType == "color")
        local isWide  = (specType == "string") and (specDisplay == "text") and not isReadOnly
        local thisH   = spec.rowHeight or (customW and customW.rowHeight) or (isColor and colorH or (isWide and textH or rowH))

        -- Per-row widget width override (e.g. wider segmented controls).
        local thisWidgetW = resolveWidgetW(spec, opts)
        local thisWidgetX = formW - thisWidgetW - padR - resetW - resetGap

        -- ── Row container ─────────────────────────────────────────────────────
        local row = Geyser.Label:new({
            name=uid.."_row", x=0, y=yPos, width=formW, height=thisH,
        }, parent)
        row:setStyleSheet(i % 2 == 1 and css.odd or css.even)
        secLayout[#secLayout+1] = { kind="row", obj=row, h=thisH, secIdx=curSec }

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
            formW = formW, padL = padL, padR = padR, rowH = rowH, thisH = thisH,
            resetX = resetX, resetW = resetW, resetGap = resetGap,
            applyW = applyW, inputGap = inputGap, stepBtnW = stepBtnW,
            hasDesc = hasDesc, hideApply = opts.hideApply, thisNameW = thisNameW,
            -- data
            spec = spec, css = css, uid = uid, i = i, yPos = yPos,
            value = spec.readFn and spec.readFn() or nil,
            onChange = spec.writeFn or function() end,
            -- helpers
            closeDropdown = closeDropdown,
            getScreenPos = getContentScreenPos,
            getActive = function() return activeDropdown end,
            setActive = function(o) activeDropdown = o end,
            onReset = opts.onReset, showReset = showReset,
            resetTooltip = opts.resetTooltip,
        }

        if layout == "block" then
            if builder then wire(i, builder(row, ctx)) end
        else
            renderInlineLabel(row, uid, spec, hasDesc, thisNameW)
            if builder then wire(i, builder(row, ctx)) end
            renderInlineReset(row, uid, spec, i, wy)
        end

        -- Read-only lock: the widget still shows its state, but a dim scrim on top
        -- greys it, swallows clicks, and carries the reason on hover. The QToolTip
        -- rule is required — without it the tooltip inherits the scrim's dark
        -- background with no text colour and renders black-on-black.
        if spec.locked then
            local lk = Geyser.Label:new({
                name=uid.."_lk", x=0, y=0, width="100%", height="100%", fillBg=1,
            }, row)
            lk:setStyleSheet([[
                QLabel { background-color: rgba(16,17,24,0.55); border: none; }
                QToolTip {
                    background-color: #1d2030; color: #e8ebf5;
                    border: 1px solid rgba(255,255,255,0.18);
                    padding: 5px 8px; border-radius: 4px;
                }
            ]])
            if spec.lockedReason and spec.lockedReason ~= "" then lk:setToolTip(spec.lockedReason, 6) end
            lk:setClickCallback(function() end)  -- swallow clicks so the widget under it can't toggle
        end

        yPos = yPos + thisH
        end  -- divider else
    end

    -- Reposition every divider/row for the current collapsed state, hiding rows in
    -- collapsed sections and resizing the content host so the scrollbox + dialog fit.
    relayout = function()
        local y = 0
        for _, e in ipairs(secLayout) do
            if e.kind == "divider" then
                e.obj:move(0, y); e.obj:show(); y = y + e.h
            else
                local sec = e.secIdx and sections[e.secIdx]
                if sec and sec.collapsed then
                    e.obj:hide()
                else
                    e.obj:move(0, y); e.obj:show(); y = y + e.h
                end
            end
        end
        formTotalHeight = y
        local pw = (parent.get_width and parent:get_width()) or formW
        if pw < 50 then pw = formW end
        -- Keep the (dark) content label at least as tall as the viewport so the
        -- ScrollBox's white Qt background never shows below short/collapsed content.
        local minH = opts.minParentHeight
        if type(minH) == "function" then minH = minH() end
        minH = tonumber(minH) or 0
        if parent.resize then parent:resize(pw, math.max(y, minH, 1)) end
        if opts.onLayoutChange then opts.onLayoutChange(y) end
    end
    relayout()

    return {
        totalHeight   = formTotalHeight,
        closeDropdown = closeDropdown,
        relayout      = relayout,
        refresh       = function(idx) if refreshFns[idx] then refreshFns[idx]() end end,
        refreshAll    = function() for _, fn in pairs(refreshFns) do fn() end end,
        commitAll     = function() for _, fn in pairs(commitFns) do fn() end end,
    }
end
-- ── Multiline code/text editor (block) ────────────────────────────────────────
-- A tall CommandLine for entering longer text or Lua. Registered as the "code"
-- row type; set spec.rowHeight to grow it. Enter commits (Mudlet command lines
-- submit on Enter); pasting preserves newlines. Used by the Action editor's Lua step.
Mux.ui.registerWidget("code", function(row, c)
    local spec, css, uid = c.spec, c.css, c.uid
    local availW = c.formW - c.padL - c.padR
    local topH   = c.hasDesc and 34 or 20

    local nl = Geyser.Label:new({ name = uid.."_n", x = c.padL, y = 4, width = availW, height = 14 }, row)
    nl:setStyleSheet(css.rowLabel); nl:rawEcho(spec.label or "")
    if c.hasDesc then
        local dl = Geyser.Label:new({ name = uid.."_d", x = c.padL, y = 18, width = availW, height = 13 }, row)
        dl:setStyleSheet(css.rowDesc); dl:rawEcho(spec.desc or "")
    end

    local inH = math.max(40, (c.thisH or 150) - topH - 8)
    local input = Geyser.CommandLine:new({ name = uid.."_i", x = c.padL, y = topH, width = availW, height = inH }, row)
    input:setStyleSheet(css.textInput)
    input:print(tostring((spec.readFn and spec.readFn()) or ""))

    local function commit()
        local text = input:getText() or ""
        spec.writeFn(text)
    end
    input:setAction(commit)
    return { commit = commit, refresh = function() input:print(tostring((spec.readFn and spec.readFn()) or "")) end }
end, { rowHeight = 150, layout = "block" })

-- ── Icon cascade (standalone reusable component) ──────────────────────────────
-- A strip of small square icon buttons emanating from an origin in one of four
-- directions. Themed through theme.ui like the form widgets (css key "iconBtn"),
-- with per-cascade or per-item style overrides so it can be dressed to match
-- titlebar icons or anything else. Not a form row — place it anywhere (on content,
-- off an edge, inside a dialog).
--
--   local cas = Mux.ui.iconCascade(parent, {
--       x = 4, y = 4, direction = "down", size = 22, gap = 4,
--       items = {
--           { id="edit", icon="⚙", tooltip="Edit", onClick=function(item,event) ... end },
--           { id="add",  icon="＋", tooltip="Add",  onClick=function() ... end },
--       },
--   })
--   cas:show(); cas:hide(); cas:toggle()
--   cas:setItems({...}); cas:setDirection("left"); cas:setOrigin(x,y); cas:destroy()
--
-- opts: x,y origin px (first icon, default 0,0) · direction up|down|left|right
-- (default down) · size icon px (22) · gap px (4) · items {id?,icon,tooltip?,
-- onClick?,css?} · css override for all icons · name base Geyser name · visible ·
-- scrim (bool) draw a full-window click-catcher behind the icons that dismisses on
-- outside-click · dismissOnClick (bool) hide after an item is chosen · onDismiss fn.
local _cascadeSeq = 0
function Mux.ui.iconCascade(parent, opts)
    opts = opts or {}
    _cascadeSeq = _cascadeSeq + 1
    local base   = opts.name or ("mux_cascade_" .. _cascadeSeq)
    local theme  = Mux.activeTheme and Mux.activeTheme() or {}
    local css    = deriveCss(theme.ui or theme.settingsUi)
    local defCss = opts.css or css.iconBtn

    local S = {
        x = opts.x or 0, y = opts.y or 0,
        direction = opts.direction or "down",
        size = opts.size or 22, gap = opts.gap or 4,
        items = opts.items or {},
        visible = (opts.visible ~= false),
        scrim = opts.scrim and true or false,
        dismissOnClick = opts.dismissOnClick and true or false,
        onDismiss = opts.onDismiss,
        _labels = {}, _scrim = nil, _gen = 0,
    }

    local handle = {}

    local function clear()
        for _, lbl in ipairs(S._labels) do pcall(function() lbl:hide() end) end
        S._labels = {}
        if S._scrim then pcall(function() S._scrim:hide() end) end
    end

    local function place(i)
        local step = S.size + S.gap
        local d, ox, oy = S.direction, S.x, S.y
        if d == "up"    then return ox, oy - (i - 1) * step end
        if d == "left"  then return ox - (i - 1) * step, oy end
        if d == "right" then return ox + (i - 1) * step, oy end
        return ox, oy + (i - 1) * step                        -- down (default)
    end

    local function build()
        clear()
        S._gen = S._gen + 1
        if not S.visible then return end
        -- Optional full-window scrim behind the icons: catches outside clicks and
        -- dismisses. Attached to top-level Geyser so it covers everything.
        if S.scrim and getMainWindowSize then
            local sw, sh = getMainWindowSize()
            S._scrim = S._scrim or Geyser.Label:new(
                { name = base .. "_scrim", x = 0, y = 0, width = sw, height = sh, fillBg = 1 }, Geyser)
            pcall(function() resizeWindow(S._scrim.name, sw, sh) end)
            S._scrim:setStyleSheet("background-color: rgba(0,0,0,0); border: none;")
            S._scrim:setClickCallback(function() handle:hide(); if S.onDismiss then S.onDismiss() end end)
            S._scrim:show(); if S._scrim.raiseAll then S._scrim:raiseAll() end
        end
        for i, item in ipairs(S.items) do
            local ix, iy = place(i)
            local lbl = Geyser.Label:new({
                name = base .. "_" .. S._gen .. "_" .. tostring(item.id or i),
                x = ix, y = iy, width = S.size, height = S.size,
            }, parent)
            lbl:setStyleSheet(item.css or defCss)
            lbl:echo("<center>" .. tostring(item.icon or "") .. "</center>")
            if item.tooltip then pcall(function() lbl:setToolTip(item.tooltip, 6) end) end
            pcall(function() lbl:setCursor("PointingHand") end)
            local captured = item
            lbl:setClickCallback(function(event)
                if event and event.button and event.button ~= "LeftButton" then return end
                if S.dismissOnClick then handle:hide() end
                if captured.onClick then captured.onClick(captured, event) end
                if captured.fn then captured.fn() end   -- legacy item shape
            end)
            lbl:show(); if lbl.raiseAll then lbl:raiseAll() else lbl:raise() end
            S._labels[#S._labels + 1] = lbl
        end
    end
    build()

    function handle:show()      if not S.visible then S.visible = true; build() end end
    function handle:hide()      if S.visible then S.visible = false; clear() end end
    function handle:toggle()    if S.visible then handle:hide() else handle:show() end end
    function handle:isVisible() return S.visible end
    function handle:setItems(items)   S.items = items or {}; build() end
    function handle:setDirection(dir) S.direction = dir or "down"; build() end
    function handle:setOrigin(x, y)   S.x, S.y = x or S.x, y or S.y; build() end
    function handle:raise()     for _, l in ipairs(S._labels) do pcall(function() (l.raiseAll or l.raise)(l) end) end end
    function handle:destroy()   clear() end
    return handle
end