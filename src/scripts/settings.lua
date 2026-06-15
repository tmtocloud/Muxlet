-- Muxlet — Settings (data API + floating window UI)
--
-- Combines the settings registry/persistence layer with the floating settings
-- window UI.  External packages register their own namespaces; those namespaces
-- appear as tabs in the window (Mux.settings.toggle()).
--
-- Data API:
--   Mux.settings.register(ns, key, cfg)      — declare a setting
--   Mux.settings.registerTab(ns, list)        — bulk-register an ordered list
--   Mux.settings.get(ns, key)                — read current or default value
--   Mux.settings.set(ns, key, value)         — validate, persist, fire callback
--   Mux.settings.clear(ns, key)              — revert to default, persist, callback
--   Mux.settings.onChange(ns, key, fn)       — side-effect callback (fn(value))
--   Mux.settings.handleCommand(ns, argsStr)  — CLI handler ("get/set/clear …")
--   Mux.settings.save() / .load()            — explicit disk I/O (rarely needed)
--
-- UI:
--   Mux.settings.toggle()                    — show / hide floating window
--   Mux.settings.showTab(ns)                 — switch active tab programmatically
--
-- Widget type is inferred from the registration cfg:
--   choices table               → dropdown
--   boolean default             → toggle
--   number with min/max ≤ 100  → stepper
--   everything else             → text entry + Apply button
--
-- NOTE: Geyser.CommandLine does not support setStyleSheet() — Mudlet limitation.

Mux.settings = Mux.settings or {}
Mux.settings._registry  = Mux.settings._registry  or {}
Mux.settings._order     = Mux.settings._order     or {}
Mux.settings._data      = Mux.settings._data      or {}
Mux.settings._onChange  = Mux.settings._onChange  or {}
-- Tab path per namespace — set via the optional `tab` field in register() cfg.
-- Format: "TopLabel" for a top-level tab, "TopLabel/SubLabel" for nested.
-- Drives UI tab hierarchy only; has no effect on get/set/clear.
Mux.settings._tabPaths  = Mux.settings._tabPaths  or {}
Mux._persistentDir      = getMudletHomeDir() .. "/Muxlet_persistent"
lfs.mkdir(Mux._persistentDir)
Mux.settings._file      = Mux._persistentDir .. "/settings.json"

Mux._settings_ui = Mux._settings_ui or {
    window     = nil,
    visible    = false,
    rows       = {},
    drawEpoch  = 0,
    currentTab = nil,
    dropdown   = nil,
    tooltip    = nil,
}
local settingsUi = Mux._settings_ui

local rowH      = 56
local rowHWide  = 64
local widgetW   = 130
local widgetH   = 26
local padL      = 10
local padR      = 6
local resetW    = 20
local footerPad = 16

-- ALL echo() calls must use explicit <span style='color:...'> — Mudlet QLabels do
-- not reliably apply CSS color: to HTML content, so text falls back to Qt's palette
-- default (which can be white, making text invisible on light backgrounds).
local cssOdd, cssEven, cssName
local cssToggleOn, cssToggleOff
local cssWidgetBtn, cssStepperBtn, cssStepperVal
local cssTextInput, cssApplyBtn
local cssDropdownPanel, cssDropdownOpt
local cssResetIcon
local cssHelpIcon
-- Plain color strings used directly in HTML echo() spans.
local labelFgColor        -- setting name labels
local toggleOnFgColor     -- toggle TRUE state
local toggleOffFgColor    -- toggle FALSE state
local widgetFgColor       -- dropdown, stepper, apply-btn text

function Mux.settings.save()
    local ok, err = pcall(function()
        local json = yajl.to_string(Mux.settings._data)
        local f    = io.open(Mux.settings._file, "w")
        f:write(json)
        f:close()
    end)
    if not ok then Mux._err("settings.save failed: %s", tostring(err)) end
    Mux._log("settings saved to %s", Mux.settings._file)
    return ok
end

function Mux.settings.load()
    if not io.exists(Mux.settings._file) then return false end
    local ok, err = pcall(function()
        local f   = io.open(Mux.settings._file, "r")
        local raw = f:read("*all")
        f:close()
        local loaded = yajl.to_value(raw)
        if type(loaded) ~= "table" then return end
        for ns, keys in pairs(loaded) do
            Mux.settings._data[ns] = Mux.settings._data[ns] or {}
            for k, v in pairs(keys) do
                Mux.settings._data[ns][k] = v
            end
        end
    end)
    if not ok then
        Mux._err("settings.load failed: %s", tostring(err))
        return false
    end
    Mux._log("settings loaded from %s", Mux.settings._file)
    return true
end

-- Register a setting key.
--
-- Optional cfg.tab sets the UI tab path for this namespace, e.g.:
--   tab = "Muxlet"              → top-level "Muxlet" tab
--   tab = "Fed2-Tools/Map"      → "Map" sub-tab under top-level "Fed2-Tools"
-- The tab path is remembered on the first registration for each namespace and
-- ignored on subsequent ones (no need to repeat it on every key).
-- If no tab is ever specified for a namespace, the namespace key is used as-is
-- for a top-level tab label.
function Mux.settings.register(ns, key, cfg)
    assert(type(ns)  == "string", "settings.register: ns must be a string")
    assert(type(key) == "string", "settings.register: key must be a string")
    assert(type(cfg) == "table",  "settings.register: cfg must be a table")

    -- Store tab path on first registration for this namespace.
    if cfg.tab and not Mux.settings._tabPaths[ns] then
        Mux.settings._tabPaths[ns] = cfg.tab
    end

    Mux.settings._registry[ns] = Mux.settings._registry[ns] or {}
    Mux.settings._order[ns]    = Mux.settings._order[ns]    or {}

    Mux.settings._registry[ns][key] = {
        description = cfg.description or "",
        default     = cfg.default,
        validator   = cfg.validator,
        choices     = cfg.choices,
        min         = cfg.min,
        max         = cfg.max,
    }

    local found = false
    for _, n in ipairs(Mux.settings._order[ns]) do
        if n == key then found = true; break end
    end
    if not found then table.insert(Mux.settings._order[ns], key) end

    Mux._log("settings.register: %s.%s (default=%s)", ns, key, tostring(cfg.default))
end

function Mux.settings.get(ns, key)
    Mux.settings._data[ns] = Mux.settings._data[ns] or {}
    local v = Mux.settings._data[ns][key]
    if v ~= nil then return v end
    local reg = Mux.settings._registry[ns] and Mux.settings._registry[ns][key]
    return reg and reg.default or nil
end

function Mux.settings.set(ns, key, value)
    local reg = Mux.settings._registry[ns] and Mux.settings._registry[ns][key]
    if not reg then
        return false, string.format("Unknown setting '%s.%s'", ns, key)
    end

    local defType = type(reg.default)
    if type(value) == "string" then
        if defType == "number" then
            local n = tonumber(value)
            if n == nil then return false, "Expected a number" end
            value = n
        elseif defType == "boolean" then
            if     value == "true"  then value = true
            elseif value == "false" then value = false
            else   return false, "Expected true or false" end
        end
    end

    if reg.validator then
        local ok, err = reg.validator(value)
        if not ok then return false, (err or "invalid value") end
    end

    Mux.settings._data[ns] = Mux.settings._data[ns] or {}
    Mux.settings._data[ns][key] = value
    Mux.settings.save()

    local cb = Mux.settings._onChange[ns .. "." .. key]
    if cb then cb(value) end

    Mux._log("settings.set: %s.%s = %s", ns, key, tostring(value))
    return true
end

function Mux.settings.clear(ns, key)
    local reg = Mux.settings._registry[ns] and Mux.settings._registry[ns][key]
    if not reg then
        return false, string.format("Unknown setting '%s.%s'", ns, key)
    end
    Mux.settings._data[ns] = Mux.settings._data[ns] or {}
    Mux.settings._data[ns][key] = nil
    Mux.settings.save()
    local cb = Mux.settings._onChange[ns .. "." .. key]
    if cb then cb(reg.default) end
    Mux._log("settings.clear: %s.%s (default=%s)", ns, key, tostring(reg.default))
    return true
end

function Mux.settings.onChange(ns, key, fn)
    assert(type(fn) == "function", "settings.onChange: fn must be a function")
    Mux.settings._onChange[ns .. "." .. key] = fn
end

local function nsDisplay(ns)
    return ns == "mux" and "Muxlet" or ns
end

function Mux.settings.handleCommand(component, argsStr)
    if not argsStr or argsStr == "" or argsStr == "list" then
        Mux.settings.showList(component); return true
    end
    local words = {}
    for w in argsStr:gmatch("%S+") do words[#words+1] = w end
    local sub = words[1]
    if sub == "list" then
        Mux.settings.showList(component); return true
    end
    local disp = nsDisplay(component)
    if sub == "get" then
        if not words[2] then
            cecho(string.format("\n<red>[%s]<reset> Usage: settings get <name>\n", disp))
            return false
        end
        Mux.settings.showSetting(component, words[2]); return true
    end
    if sub == "set" then
        if not words[2] or not words[3] then
            cecho(string.format("\n<red>[%s]<reset> Usage: settings set <name> <value>\n", disp))
            return false
        end
        local value = table.concat(words, " ", 3)
        local ok, err = Mux.settings.set(component, words[2], value)
        if ok then
            cecho(string.format("\n<green>[%s]<reset> <cyan>%s<reset> = <yellow>%s<reset>\n",
                disp, words[2], value))
        else
            cecho(string.format("\n<red>[%s]<reset> %s\n", disp, err or "unknown error"))
        end
        return ok
    end
    if sub == "clear" then
        if not words[2] then
            cecho(string.format("\n<red>[%s]<reset> Usage: settings clear <name>\n", disp))
            return false
        end
        local ok, err = Mux.settings.clear(component, words[2])
        if ok then
            cecho(string.format("\n<green>[%s]<reset> <cyan>%s<reset> cleared (default: <yellow>%s<reset>)\n",
                disp, words[2], tostring(Mux.settings.get(component, words[2]))))
        else
            cecho(string.format("\n<red>[%s]<reset> %s\n", disp, err or "error"))
        end
        return ok
    end
    cecho(string.format("\n<red>[%s]<reset> Unknown settings command: %s\n", disp, sub))
    cecho("<cyan>Available: list, get, set, clear<reset>\n")
    return false
end

function Mux.settings.showList(ns)
    local reg  = Mux.settings._registry[ns]
    local disp = nsDisplay(ns)
    if not reg then
        cecho(string.format("\n<yellow>[%s]<reset> No settings registered under '%s'\n", disp, ns))
        return
    end
    local order = Mux.settings._order[ns] or {}
    cecho(string.format("\n<green>[%s]<reset> Settings:\n\n", disp))
    for _, key in ipairs(order) do
        local cfg = reg[key]
        if cfg then
            local val   = Mux.settings.get(ns, key)
            local isDef = Mux.settings._data[ns] == nil or Mux.settings._data[ns][key] == nil
            local tag   = isDef and " <dim_grey>(default)<reset>" or ""
            cecho(string.format("  <cyan>%s<reset>: <yellow>%s<reset>%s\n", key, tostring(val), tag))
            if cfg.description and cfg.description ~= "" then
                cecho(string.format("    <dim_grey>%s<reset>\n", cfg.description))
            end
        end
    end
    cecho("\n")
end

function Mux.settings.showSetting(ns, key)
    local cfg  = Mux.settings._registry[ns] and Mux.settings._registry[ns][key]
    local disp = nsDisplay(ns)
    if not cfg then
        cecho(string.format("\n<red>[%s]<reset> Unknown setting '%s.%s'\n", disp, ns, key))
        return
    end
    local val   = Mux.settings.get(ns, key)
    local isDef = Mux.settings._data[ns] == nil or Mux.settings._data[ns][key] == nil
    local tag   = isDef and " <dim_grey>(default)<reset>" or ""
    cecho(string.format("\n<green>[%s]<reset> <cyan>%s<reset>: <yellow>%s<reset>%s\n",
        disp, key, tostring(val), tag))
    if cfg.description and cfg.description ~= "" then
        cecho(string.format("  <dim_grey>%s<reset>\n", cfg.description))
    end
    cecho("\n")
end

Mux.settings.load()

-- Returns the absolute console position of a namespace's content area.
-- ns is needed to determine whether this setting lives in a sub-tab (two
-- tab bars above the content) or a top-level tab (one tab bar above).
local function contentScreenPos(ns)
    local win = settingsUi.window
    if not win then return 0, 0 end
    local theme   = Mux.activeTheme()
    local tabBarH = theme.tabBarHeight or 22
    local bi      = 2
    local cx      = (win.floatX or 0) + bi
    local cy      = (win.floatY or 0) + bi + (theme.titlebarHeight or 22) + tabBarH
    -- Sub-tab namespaces have a second tab bar above the content.
    local path = Mux.settings._tabPaths[ns]
    if path and path:find("/", 1, true) then
        cy = cy + tabBarH
    end
    return cx, cy
end

local function closeDropdown()
    if settingsUi.dropdown then
        settingsUi.dropdown:hide()
        settingsUi.dropdown = nil
    end
end

local function showTooltip(text, absX, absY)
    if not settingsUi.tooltip then
        settingsUi.tooltip = Geyser.Label:new({
            name = "mux_set_tooltip", x = 0, y = 0, width = 300, height = 40,
        })
    end
    local w = math.max(200, math.min(450, #text * 6 + 24))
    settingsUi.tooltip:resize(w, 36)
    settingsUi.tooltip:move(absX + 20, absY - 10)
    settingsUi.tooltip:setStyleSheet([[
        background-color: rgb(30,32,46);
        color: rgba(210,215,230,0.95);
        font-size: 10px;
        border: 1px solid rgba(100,160,255,0.35);
        border-radius: 4px;
        padding: 4px 8px;
    ]])
    settingsUi.tooltip:echo(text)
    settingsUi.tooltip:show()
    settingsUi.tooltip:raise()
end

local function hideTooltip()
    if settingsUi.tooltip then settingsUi.tooltip:hide() end
end

local function applyValue(ns, key, value)
    local ok, err = Mux.settings.set(ns, key, value)
    if ok then
        Mux._echo(string.format("\n<green>[mux settings]<reset> <cyan>%s.%s<reset> = <yellow>%s<reset>\n",
            ns, key, tostring(Mux.settings.get(ns, key))))
    else
        Mux._echo(string.format("\n<red>[mux settings]<reset> %s.%s: %s\n",
            ns, key, err or "invalid"))
    end
    return ok
end

local function widgetType(cfg)
    if cfg.choices then return "dropdown" end
    if type(cfg.default) == "boolean" then return "toggle" end
    if type(cfg.default) == "number"
        and cfg.min ~= nil and cfg.max ~= nil
        and (cfg.max - cfg.min) <= 100
    then return "stepper" end
    return "textentry"
end

local function isWideRow(cfg)
    return widgetType(cfg) == "textentry" and type(cfg.default) == "string"
end

local function calcWidgetWidth(cfg, contentW)
    if isWideRow(cfg) then return contentW - padL * 2 - resetW - padR end
    return widgetW
end

local function makeToggle(parent, wx, wy, uid, ns, key, ww)
    local cssOn  = cssToggleOn
    local cssOff = cssToggleOff
    local w = Geyser.Label:new({ name=uid.."_tog", x=wx, y=wy, width=ww, height=widgetH }, parent)
    local function refresh()
        local v  = Mux.settings.get(ns, key)
        local tc = v and toggleOnFgColor or toggleOffFgColor
        w:setStyleSheet(v and cssOn or cssOff)
        w:echo(string.format("<center><span style='color:%s;font-size:10px;font-weight:bold;'>%s</span></center>",
            tc or "#d8d8f0", v and "TRUE" or "FALSE"))
    end
    refresh()
    w:setClickCallback(function()
        closeDropdown()
        applyValue(ns, key, not Mux.settings.get(ns, key))
        refresh()
    end)
    return refresh
end

local function makeDropdown(parent, wx, wy, uid, ns, key, choices, ww, rowY)
    local btn = Geyser.Label:new({ name=uid.."_dd_btn", x=wx, y=wy, width=ww, height=widgetH }, parent)
    btn:setStyleSheet(cssWidgetBtn)

    local function refresh()
        local v    = tostring(Mux.settings.get(ns, key) or "")
        local disp = #v > 16 and v:sub(1,15) .. "…" or v
        local tc   = widgetFgColor or "#d8d8f0"
        btn:echo(string.format("<center><span style='color:%s;font-size:10px;'>%s ▾</span></center>", tc, disp))
    end
    refresh()

    local ovName  = uid .. "_dd_ov"
    local overlay = nil

    local function destroyOverlay()
        if overlay then
            overlay:hide()
            for ci = 1, #choices do
                local n = ovName .. "_o" .. ci
                if Geyser.windowList[n] then Geyser.windowList[n]:hide() end
            end
            overlay = nil
        end
        if settingsUi.dropdown == overlay then settingsUi.dropdown = nil end
    end

    local function openOverlay()
        local cx, cy = contentScreenPos(ns)
        local absBtnX = cx + wx
        local absBtnY = cy + rowY + wy + widgetH
        overlay = Geyser.Label:new({
            name=ovName, x=absBtnX, y=absBtnY, width=ww, height=#choices * widgetH,
        }, Geyser)
        overlay:setStyleSheet(cssDropdownPanel)
        overlay:show(); overlay:raise()
        for ci, choice in ipairs(choices) do
            local opt = Geyser.Label:new({
                name=ovName.."_o"..ci, x=0, y=(ci-1)*widgetH, width=ww, height=widgetH,
            }, overlay)
            opt:setStyleSheet(cssDropdownOpt)
            local otc = widgetFgColor or "#d8d8f0"
            opt:echo(string.format("<span style='color:%s;font-size:10px;'>  %s</span>", otc, tostring(choice)))
            opt:show(); opt:raise()
            local captured = choice
            opt:setClickCallback(function()
                applyValue(ns, key, captured); refresh()
                destroyOverlay(); settingsUi.dropdown = nil
            end)
        end
        settingsUi.dropdown = overlay
    end

    btn:setClickCallback(function()
        if settingsUi.dropdown then
            local was = (settingsUi.dropdown == overlay)
            closeDropdown(); destroyOverlay()
            if was then return end
        end
        openOverlay()
    end)
    return refresh
end

local function makeStepper(parent, wx, wy, uid, ns, key, cfg, ww)
    local cssBtn = cssStepperBtn
    local cssVal = cssStepperVal
    local bw = 26
    local vw = ww - bw * 2 - 4
    local minus = Geyser.Label:new({name=uid.."_sm", x=wx,           y=wy, width=bw, height=widgetH}, parent)
    local vl    = Geyser.Label:new({name=uid.."_sv", x=wx+bw+2,     y=wy, width=vw, height=widgetH}, parent)
    local plus  = Geyser.Label:new({name=uid.."_sp", x=wx+bw+2+vw+2, y=wy, width=bw, height=widgetH}, parent)
    local sc = widgetFgColor or "#d8d8f0"
    minus:setStyleSheet(cssBtn)
    minus:echo(string.format("<center><span style='color:%s;font-size:13px;font-weight:bold;'>−</span></center>", sc))
    vl:setStyleSheet(cssVal)
    plus:setStyleSheet(cssBtn)
    plus:echo(string.format("<center><span style='color:%s;font-size:13px;font-weight:bold;'>+</span></center>", sc))
    local function refresh()
        vl:echo(string.format("<center><span style='color:%s;font-size:11px;font-weight:bold;'>%s</span></center>",
            sc, tostring(Mux.settings.get(ns, key))))
    end
    refresh()
    minus:setClickCallback(function()
        closeDropdown()
        applyValue(ns, key, math.max(cfg.min, (Mux.settings.get(ns, key) or cfg.min) - 1))
        refresh()
    end)
    plus:setClickCallback(function()
        closeDropdown()
        applyValue(ns, key, math.min(cfg.max, (Mux.settings.get(ns, key) or cfg.min) + 1))
        refresh()
    end)
    return refresh
end

local function makeTextEntry(parent, wx, wy, uid, ns, key, cfg, ww)
    local applyW = 46
    local gap    = 3
    local inputW = ww - applyW - gap
    local input = Geyser.CommandLine:new({ name=uid.."_input", x=wx, y=wy, width=inputW, height=widgetH }, parent)
    input:setStyleSheet(cssTextInput)
    input:print(tostring(Mux.settings.get(ns, key) or ""))
    local applyBtn = Geyser.Label:new({ name=uid.."_apply", x=wx+inputW+gap, y=wy, width=applyW, height=widgetH }, parent)
    applyBtn:setStyleSheet(cssApplyBtn)
    applyBtn:echo(string.format("<center><span style='color:%s;font-size:9px;font-weight:bold;'>Apply</span></center>",
        widgetFgColor or "#d8d8f0"))
    local function commit()
        closeDropdown()
        local text = input:getText()
        if text == nil or text == "" then return end
        local ok = applyValue(ns, key, text)
        if ok then input:print(tostring(Mux.settings.get(ns, key) or "")) end
    end
    input:setAction(commit)
    applyBtn:setClickCallback(commit)
    return function()
        input:print(tostring(Mux.settings.get(ns, key) or ""))
    end
end

-- Reset-to-default icon: subtle bordered button, glows amber on hover.
-- Plain text echo so CSS font-size / text-align apply directly.
local function makeResetIcon(parent, rx, ry, uid, ns, key, refreshFn, contentY)
    local icon = Geyser.Label:new({ name=uid.."_reset", x=rx, y=ry, width=resetW, height=widgetH }, parent)
    icon:setStyleSheet(cssResetIcon)
    icon:echo("<center><span style='color:rgba(140,145,165,0.55);font-size:11px;'>↺</span></center>")
    icon:setOnEnter(function()
        local cx, cy = contentScreenPos(ns)
        showTooltip("Reset to default", cx + rx + resetW + 4, cy + (contentY or 0) + ry)
    end)
    icon:setOnLeave(function() hideTooltip() end)
    icon:setClickCallback(function()
        closeDropdown()
        local ok, err = Mux.settings.clear(ns, key)
        if ok then
            Mux._echo(string.format("\n<green>[mux settings]<reset> <cyan>%s.%s<reset> reset to default: <yellow>%s<reset>\n",
                ns, key, tostring(Mux.settings.get(ns, key))))
            if refreshFn then refreshFn() end
        else
            Mux._echo(string.format("\n<red>[mux settings]<reset> %s\n", err or "error"))
        end
    end)
end

local function buildRows(ns, contentLbl)
    local contentW = contentLbl:get_width()
    if contentW < 50 then contentW = 400 end

    local order = Mux.settings._order[ns] or {}
    if #order == 0 then
        for k in pairs(Mux.settings._registry[ns] or {}) do table.insert(order, k) end
        table.sort(order)
    end

    local epoch = settingsUi.drawEpoch

    local y = 2
    for i, settingKey in ipairs(order) do
        local cfg = Mux.settings._registry[ns] and Mux.settings._registry[ns][settingKey]
        if cfg then
            local uid  = string.format("ms_%d_%s_%s", epoch, ns, settingKey):gsub("[^%w_]", "_")
            local wt   = widgetType(cfg)
            local wide = isWideRow(cfg)
            local ww   = calcWidgetWidth(cfg, contentW)
            local rh   = wide and rowHWide or rowH

            local row = Geyser.Label:new({ name=uid.."_row", x=0, y=y, width=contentW, height=rh }, contentLbl)
            row:setStyleSheet((i % 2 == 1) and cssOdd or cssEven)
            table.insert(settingsUi.rows, row)

            local wyWidget     = math.floor((rh - widgetH) / 2)
            local desc         = cfg.description or settingKey
            local resetX       = contentW - resetW - padR
            local refreshFn    = nil
            local capturedRowY = y

            if wide then
                local hi = Geyser.Label:new({name=uid.."_help", x=padL, y=6, width=16, height=16}, row)
                hi:setStyleSheet(cssHelpIcon)
                -- Explicit span color so Qt respects it regardless of default rendering mode.
                local hiColor = (Mux.activeTheme().settingsUi or {}).helpIconFg or "rgba(100,160,255,0.85)"
                hi:echo(string.format("<center><span style='color:%s;font-size:11px;font-weight:bold;'>i</span></center>", hiColor))
                hi:setOnEnter(function()
                    local cx, cy = contentScreenPos(ns)
                    showTooltip(desc, cx + padL + 16 + 4, cy + capturedRowY + 6)
                end)
                hi:setOnLeave(function() hideTooltip() end)

                local nl = Geyser.Label:new({name=uid.."_n", x=padL+20, y=4, width=contentW-padL-60, height=20}, row)
                nl:setStyleSheet(cssName)
                nl:echo(string.format("<span style='color:%s;font-size:11px;font-weight:bold;'>%s</span>",
                    labelFgColor, settingKey))

                refreshFn = makeTextEntry(row, padL, 32, uid, ns, settingKey, cfg, ww)
                makeResetIcon(row, resetX, 4, uid, ns, settingKey, refreshFn, capturedRowY)
            else
                local wx     = contentW - widgetW - resetW - padR - 10
                local labelW = wx - padL - 24
                local hiY    = math.floor((rh - 16) / 2)

                local hi = Geyser.Label:new({name=uid.."_help", x=padL, y=hiY, width=16, height=16}, row)
                hi:setStyleSheet(cssHelpIcon)
                local hiColor = (Mux.activeTheme().settingsUi or {}).helpIconFg or "rgba(100,160,255,0.85)"
                hi:echo(string.format("<center><span style='color:%s;font-size:11px;font-weight:bold;'>i</span></center>", hiColor))
                hi:setOnEnter(function()
                    local cx, cy = contentScreenPos(ns)
                    showTooltip(desc, cx + padL + 16 + 4, cy + capturedRowY + hiY)
                end)
                hi:setOnLeave(function() hideTooltip() end)

                local nl = Geyser.Label:new({name=uid.."_n", x=padL+20, y=math.floor((rh-20)/2), width=labelW, height=20}, row)
                nl:setStyleSheet(cssName)
                nl:echo(string.format("<span style='color:%s;font-size:11px;font-weight:bold;'>%s</span>",
                    labelFgColor, settingKey))

                if     wt == "toggle"   then refreshFn = makeToggle(row, wx, wyWidget, uid, ns, settingKey, widgetW)
                elseif wt == "dropdown" then refreshFn = makeDropdown(row, wx, wyWidget, uid, ns, settingKey, cfg.choices, widgetW, capturedRowY)
                elseif wt == "stepper"  then refreshFn = makeStepper(row, wx, wyWidget, uid, ns, settingKey, cfg, widgetW)
                else                         refreshFn = makeTextEntry(row, wx, wyWidget, uid, ns, settingKey, cfg, widgetW)
                end
                makeResetIcon(row, resetX, wyWidget, uid, ns, settingKey, refreshFn, capturedRowY)
            end
            y = y + rh
        end
    end
    return y
end

-- Builds the tab hierarchy from _tabPaths and the registered namespaces.
-- Returns a sorted list: { {label, ns, children={label,ns}...}, ... }
-- Entries without children are leaf tabs; entries with children are package tabs
-- whose sub-tabs hold the actual settings content.
local function tabHierarchy()
    local tops = {}   -- {topLabel → {ns=..., children={...}}}

    for ns in pairs(Mux.settings._registry) do
        local path    = Mux.settings._tabPaths[ns] or ns
        local parts   = {}
        for p in path:gmatch("[^/]+") do parts[#parts+1] = p end
        local topLabel = parts[1]
        tops[topLabel] = tops[topLabel] or {}
        if #parts == 1 then
            tops[topLabel].ns = ns
        else
            local subLabel = table.concat(parts, "/", 2)
            tops[topLabel].children = tops[topLabel].children or {}
            table.insert(tops[topLabel].children, {label = subLabel, ns = ns})
        end
    end

    local result = {}
    for label, info in pairs(tops) do
        table.insert(result, {label = label, ns = info.ns, children = info.children})
    end
    table.sort(result, function(a, b)
        -- "Muxlet" always first, then alphabetical
        if a.label == "Muxlet" then return true  end
        if b.label == "Muxlet" then return false end
        return a.label < b.label
    end)
    for _, entry in ipairs(result) do
        if entry.children then
            table.sort(entry.children, function(a, b) return a.label < b.label end)
        end
    end
    return result
end

-- Activate the tab (or sub-tab) that corresponds to namespace ns.
function Mux.settings.showTab(ns)
    closeDropdown(); hideTooltip()
    local pane = settingsUi.window
    if not pane then return end
    for _, tab in ipairs(pane._tabs or {}) do
        if tab._settingsNs == ns then
            pane:activateTab(tab.id)
            settingsUi.currentTab = ns
            return
        end
        -- Check one level of sub-tabs
        for _, subTab in ipairs(tab._tabs or {}) do
            if subTab._settingsNs == ns then
                pane:activateTab(tab.id)
                tab:activateTab(subTab.id)
                settingsUi.currentTab = ns
                return
            end
        end
    end
end

-- Builds a ScrollBox + form rows inside a leaf settings tab.
local function buildSettingsContent(targetTab, ns, bgCol)
    targetTab.contentBg:hide()
    local safeName = ns:gsub("[^%w_]", "_")
    local scrollBox = Geyser.ScrollBox:new({
        name = "mux_set_sb_" .. safeName,
        x = 0, y = 0, width = "100%", height = "100%",
    }, targetTab.content)
    local cw = targetTab.content:get_width()
    if cw < 50 then cw = 400 end
    local contentLbl = Geyser.Label:new({
        name = "mux_set_cl_" .. safeName,
        x = 0, y = 0, width = cw - 8, height = 500,
    }, scrollBox)
    contentLbl:setStyleSheet(string.format("background:%s; border:none;", bgCol))
    settingsUi.rows = settingsUi.rows or {}
    local totalH = buildRows(ns, contentLbl)
    local viewH  = scrollBox:get_height()
    local fitH   = math.max(viewH > 0 and viewH or 200, totalH + footerPad)
    resizeWindow("mux_set_cl_" .. safeName, cw - 8, fitH)
end

local function buildWindow()
    local sw, sh = getMainWindowSize()
    local w = math.floor(sw * 0.34)
    local h = math.floor(sh * 0.72)
    local x = math.floor((sw - w) / 2)
    local y = math.floor((sh - h) / 2)

    local pane = Mux.createDialog({
        title    = string.format("⚙  Settings  v%s", Mux._version),
        x=x, y=y, width=w, height=h,
        noTabs   = false,
    })
    local theme = Mux.activeTheme()
    local sui   = theme.settingsUi or {}

    local bgColor         = sui.bg              or "rgb(18, 18, 26)"
    local rowOddColor     = sui.rowOdd          or "rgb(16, 16, 24)"
    local rowEvenColor    = sui.rowEven         or "rgb(34, 34, 50)"
    local textColor       = sui.textColor       or "rgba(215, 215, 230, 0.92)"
    local rowDivider      = sui.rowDivider      or "rgba(255, 255, 255, 0.12)"

    local widgetBg      = sui.widgetBg          or "rgb(38,38,58)"
    local widgetFg      = sui.widgetFg          or "#d8d8f0"
    local widgetBorder  = sui.widgetBorder      or "rgba(255,255,255,0.22)"
    local widgetHoverBg = sui.widgetHoverBg     or "rgb(55,55,80)"
    local inputBg       = sui.inputBg           or "rgb(12,12,18)"
    local inputFg       = sui.inputFg           or "#c8c8d0"
    local inputBorder   = sui.inputBorder       or "rgba(255,255,255,0.46)"
    local togOnBg  = sui.toggleOnBg      or "rgb(30,70,40)"
    local togOnFg  = sui.toggleOnFg      or "#88ee88"
    local togOnBd  = sui.toggleOnBorder  or "rgba(80,180,80,0.5)"
    local togOnHov = sui.toggleOnHoverBg or "rgb(40,90,50)"
    local togOffBg  = sui.toggleOffBg      or "rgb(65,30,30)"
    local togOffFg  = sui.toggleOffFg      or "rgba(220,120,120,0.9)"
    local togOffBd  = sui.toggleOffBorder  or "rgba(180,80,80,0.4)"
    local togOffHov = sui.toggleOffHoverBg or "rgb(85,40,40)"

    cssToggleOn  = string.format("QLabel{background:%s;color:%s;font-size:10px;font-weight:bold;border:1px solid %s;border-radius:3px;}QLabel::hover{background:%s;}", togOnBg,  togOnFg,  togOnBd,  togOnHov)
    cssToggleOff = string.format("QLabel{background:%s;color:%s;font-size:10px;font-weight:bold;border:1px solid %s;border-radius:3px;}QLabel::hover{background:%s;}", togOffBg, togOffFg, togOffBd, togOffHov)
    cssWidgetBtn = string.format("QLabel{background:%s;color:%s;font-size:10px;border:1px solid %s;border-radius:3px;}QLabel::hover{background:%s;border-color:%s;}", widgetBg, widgetFg, widgetBorder, widgetHoverBg, widgetBorder)
    cssStepperBtn = string.format("QLabel{background:%s;color:%s;font-size:13px;font-weight:bold;border:1px solid %s;border-radius:2px;}QLabel::hover{background:%s;}", widgetBg, widgetFg, widgetBorder, widgetHoverBg)
    cssStepperVal = string.format("background:transparent;color:%s;font-size:11px;font-weight:bold;text-align:center;", widgetFg)
    cssTextInput  = string.format("background-color:%s;color:%s;font-size:12px;border:1px solid %s;border-radius:3px;padding-left:6px;padding-right:4px;", inputBg, inputFg, inputBorder)
    cssApplyBtn   = string.format("QLabel{background-color:%s;border:1px solid %s;border-radius:3px;color:%s;font-size:9px;font-weight:bold;}QLabel::hover{background-color:%s;border-color:rgba(120,180,255,200);color:%s;}", widgetBg, widgetBorder, widgetFg, widgetHoverBg, widgetFg)
    cssDropdownPanel = string.format("background:%s; border:1px solid %s; border-radius:3px;", widgetBg, widgetBorder)
    cssDropdownOpt   = string.format("QLabel{background:%s;color:%s;font-size:10px;border:none;border-bottom:1px solid %s;}QLabel::hover{background:%s;color:%s;}", inputBg, widgetFg, widgetBorder, widgetHoverBg, widgetFg)
    cssResetIcon  = "QLabel{background:transparent;color:rgba(140,145,165,0.48);font-size:11px;text-align:center;border:1px solid rgba(140,145,165,0.26);border-radius:3px;}QLabel::hover{color:rgba(225,178,100,0.95);border-color:rgba(225,178,100,0.55);background:rgba(225,178,100,0.10);}"

    labelFgColor = textColor
    local helpFg = sui.helpIconFg     or "rgba(100,160,255,0.85)"
    local helpBg = sui.helpIconBg     or "rgba(60,80,120,0.25)"
    local helpBd = sui.helpIconBorder or "rgba(100,140,200,0.35)"
    cssHelpIcon = string.format([[
        QLabel{
            background: %s;
            color: %s;
            font-size: 11px;
            font-weight: bold;
            border: 1px solid %s;
            border-radius: 3px;
        }
        QLabel::hover{
            color: rgba(180,210,255,1.0);
            border-color: rgba(150,200,255,0.7);
            background: rgba(60,80,120,0.5);
        }
    ]], helpBg, helpFg, helpBd)

    toggleOnFgColor  = togOnFg
    toggleOffFgColor = togOffFg
    widgetFgColor    = widgetFg

    cssOdd  = string.format("background:%s; border:none; border-bottom:1px solid %s;", rowOddColor,  rowDivider)
    cssEven = string.format("background:%s; border:none; border-bottom:1px solid %s;", rowEvenColor, rowDivider)
    cssName = string.format("background:transparent; color:%s; font-size:11px; font-weight:bold;", textColor)

    pane.floatX = x; pane.floatY = y
    pane.floatW = w; pane.floatH = h
    pane.onClose = function()
        closeDropdown(); hideTooltip()
        settingsUi.visible = false
        settingsUi.window  = nil
        settingsUi.rows    = {}
    end
    settingsUi.window = pane
    settingsUi.rows   = {}

    -- Lock the pane so the real tab system hides the + button and disables drag.
    -- closeable = true (set at construction) keeps the X button visible.
    pane:lock()
    pane:enableTabs({ noDefaultTab = true })

    -- Build tabs from the hierarchy derived from registered tab paths.
    local hierarchy = tabHierarchy()
    for _, entry in ipairs(hierarchy) do
        local tab = pane:addTab(entry.label)
        tab.locked        = true
        tab.noContextMenu = true
        tab._settingsNs   = entry.ns  -- nil for package-level grouper tabs

        if entry.children and #entry.children > 0 then
            -- Package tab: enable sub-tabs for each child namespace.
            tab:enableTabs({ noDefaultTab = true })
            for _, child in ipairs(entry.children) do
                local subTab = tab:addTab(child.label)
                subTab.locked        = true
                subTab.noContextMenu = true
                subTab._settingsNs   = child.ns
                buildSettingsContent(subTab, child.ns, bgColor)
            end
        elseif entry.ns then
            -- Leaf tab: settings content goes directly here.
            buildSettingsContent(tab, entry.ns, bgColor)
        end
    end

    -- Set the current tab namespace (first tab was already activated by addTab).
    if pane._tabs and #pane._tabs > 0 then
        settingsUi.currentTab = pane._tabs[1]._settingsNs
    end
    settingsUi.window:raise()
end

function Mux.settings.toggle()
    -- Tear down a stale window if new namespaces were registered since it was built.
    if settingsUi.window then
        local builtCount  = settingsUi.window._settingsNsCount or 0
        local currentCount = 0
        for _ in pairs(Mux.settings._registry) do currentCount = currentCount + 1 end
        if currentCount ~= builtCount then
            closeDropdown(); hideTooltip()
            settingsUi.window:close()
            -- onClose nulls settingsUi.window
        end
    end
    if not settingsUi.window then
        local count = 0
        for _ in pairs(Mux.settings._registry) do count = count + 1 end
        buildWindow()
        settingsUi.window._settingsNsCount = count
        settingsUi.visible = true
        return
    end
    if settingsUi.visible then
        closeDropdown(); hideTooltip()
        settingsUi.window:hide()
        settingsUi.visible = false
    else
        settingsUi.window:show()
        settingsUi.window:raise()
        settingsUi.visible = true
        if settingsUi.currentTab then Mux.settings.showTab(settingsUi.currentTab) end
    end
end

Mux.settings.register("mux", "theme", {
    tab         = "Muxlet",
    description = "Active color theme",
    default     = "dark",
    choices     = {"dark", "light"},
})

Mux.settings.register("mux", "debug", {
    description = "Verbose debug logging to the console",
    default     = false,
})

Mux.settings.register("mux", "default_titlebar", {
    description = "Show titlebars on newly created panes by default",
    default     = true,
})

Mux.settings.register("mux", "default_split_ratio", {
    description = "Default split point for new splits, as a percentage (10–90)",
    default     = 50,
    min         = 10,
    max         = 90,
})

Mux.settings.register("mux", "auto_start", {
    description = "Automatically run mux start on profile load using the configured workspace",
    default     = false,
})

-- Tracks whether the first-run welcome dialog has been dismissed.
-- Downstream packages (e.g. fed2-tools) set this to true in their muxletReady
-- handler to suppress the popup — no separate "disabled" flag is needed.
Mux.settings.register("mux", "welcome_shown", {
    description = "Whether the first-run welcome dialog has been shown",
    default     = false,
})

Mux.settings.onChange("mux", "theme", function(value)
    if Mux.applyTheme then Mux.applyTheme(value) end
    -- Rebuild the settings window immediately so its widgets reflect the new theme.
    if settingsUi.window then
        local wasVisible = settingsUi.visible
        local savedTab   = settingsUi.currentTab
        closeDropdown(); hideTooltip()
        settingsUi.rows = {}
        settingsUi.window:close()
        -- onClose nulled window/visible
        if wasVisible then
            local count = 0
            for _ in pairs(Mux.settings._registry) do count = count + 1 end
            buildWindow()
            settingsUi.window._settingsNsCount = count
            settingsUi.visible = true
            if savedTab then
                tempTimer(0.05, function()
                    if settingsUi.window then Mux.settings.showTab(savedTab) end
                end)
            end
        end
    end
end)

Mux.settings.register("mux", "compact_titlebar", {
    tab         = "Muxlet",
    description = "Hide all titlebar buttons — use right-click menu instead",
    default     = false,
})

Mux.settings.onChange("mux", "compact_titlebar", function()
    for _, pane in pairs(Mux._panes or {}) do
        if pane._checkOverflow then pane:_checkOverflow() end
    end
end)

Mux.settings.onChange("mux", "debug", function(value)
    Mux.debug = value
end)

-- tempTimer(0) defers past the synchronous script-loading stack so all Muxlet
-- functions are defined before this runs. raiseEvent("muxletReady") fires last
-- so downstream packages can register a handler and be guaranteed Muxlet's full
-- API is available when they receive it.

tempTimer(0, function()
    local savedTheme = Mux.settings.get("mux", "theme")
    if savedTheme and Mux.applyTheme and savedTheme ~= Mux._activeThemeName then
        Mux.applyTheme(savedTheme)
    end
    Mux.debug = Mux.settings.get("mux", "debug")
    raiseEvent("muxletReady")
end)

-- Fires after all muxletReady consumers have had a chance to set welcome_shown = true.
-- welcome.lua defines Mux._checkWelcome(); guard against load-order gaps.
tempTimer(0.3, function()
    if Mux._checkWelcome then Mux._checkWelcome() end
end)

tempTimer(1.5, function()
    if Mux._running then return end
    if Mux.settings.get("mux", "auto_start") then
        if not Mux.settings.get("mux", "welcome_shown") then return end
        if Mux.fullStart then Mux.fullStart() end
    else
        Mux._echo(
            "  <dim_grey>Type <cyan>mux start<reset><dim_grey> to begin"
            .. "  •  <cyan>mux workspaces<reset> to browse  •  <cyan>mux help<reset> for all commands<reset>\n")
    end
end)

Mux._log("mux_settings loaded — file: %s", Mux.settings._file)
