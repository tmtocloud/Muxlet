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
    currentTab = nil,
}
local settingsUi = Mux._settings_ui

local footerPad = 16

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
    local win = settingsUi.window
    if not win then return end
    for _, tab in ipairs(win._tabs or {}) do
        if tab._settingsForm then tab._settingsForm.closeDropdown() end
        for _, subTab in ipairs(tab._tabs or {}) do
            if subTab._settingsForm then subTab._settingsForm.closeDropdown() end
        end
    end
end

local function hideTooltip() end  -- Qt native tooltips auto-dismiss; kept for call-site compat

-- Builds a widget spec array from a settings namespace registration.
local function buildNsSpecs(ns)
    local reg = Mux.settings._registry[ns]
    if not reg then return {} end

    local order = Mux.settings._order[ns] or {}
    if #order == 0 then
        for k in pairs(reg) do order[#order+1] = k end
        table.sort(order)
    end

    local specs = {}
    for _, key in ipairs(order) do
        local cfg = reg[key]
        if cfg then
            local spec = {
                label        = key,
                desc         = cfg.description,
                _settingsNs  = ns,
                _settingsKey = key,
                readFn  = function() return Mux.settings.get(ns, key) end,
                writeFn = function(v)
                    local ok, err = Mux.settings.set(ns, key, v)
                    if not ok then
                        Mux._warn("settings.set: %s.%s: %s", ns, key, err or "invalid")
                    end
                end,
            }

            if cfg.choices then
                spec.type    = "array"
                spec.display = "dropdown"
                spec.options = {}
                for _, c in ipairs(cfg.choices) do
                    spec.options[#spec.options+1] = { value = c, label = tostring(c) }
                end
            elseif type(cfg.default) == "boolean" then
                spec.type = "bool"
            elseif type(cfg.default) == "number"
                   and cfg.min ~= nil and cfg.max ~= nil
                   and (cfg.max - cfg.min) <= 100 then
                spec.type    = "number"
                spec.display = "stepper"
                spec.step    = 1
                spec.min     = cfg.min
                spec.max     = cfg.max
            else
                spec.type = "string"
            end

            specs[#specs+1] = spec
        end
    end
    return specs
end

local settingsFormOpts = {
    rowHeight     = 56,
    textRowHeight = 64,
    widgetWidth   = 130,
    widgetHeight  = 26,
}

local function buildRows(ns, contentLbl)
    local cw = contentLbl:get_width()
    if cw < 50 then cw = 400 end

    local specs = buildNsSpecs(ns)
    if #specs == 0 then return nil, 2 end

    local formHandle
    local safeNs = ns:gsub("[^%w_]", "_")
    local formOpts = {
        width         = cw,
        prefix        = "mxs_" .. safeNs,
        rowHeight     = settingsFormOpts.rowHeight,
        textRowHeight = settingsFormOpts.textRowHeight,
        widgetWidth   = settingsFormOpts.widgetWidth,
        widgetHeight  = settingsFormOpts.widgetHeight,
        showReset     = true,
        onReset       = function(i, spec)
            local ok, err = Mux.settings.clear(spec._settingsNs, spec._settingsKey)
            if ok then
                Mux._echo(string.format(
                    "\n<green>[mux settings]<reset> <cyan>%s.%s<reset> reset to default: <yellow>%s<reset>\n",
                    spec._settingsNs, spec._settingsKey,
                    tostring(Mux.settings.get(spec._settingsNs, spec._settingsKey))))
                if formHandle then formHandle.refresh(i) end
            else
                Mux._echo(string.format("\n<red>[mux settings]<reset> %s\n", err or "error"))
            end
        end,
        getContentScreenPos = function()
            return contentScreenPos(ns)
        end,
    }

    formHandle = Mux.ui.buildForm(contentLbl, specs, formOpts)
    return formHandle, formHandle.totalHeight + 2
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

local function measureNsHeight(ns)
    local specs = buildNsSpecs(ns)
    return Mux.ui.formHeight(specs, settingsFormOpts) + 2
end

-- Builds a ScrollBox + form rows inside a leaf settings tab.
-- The contentLbl is sized to the actual row content; ScrollBox handles overflow scrolling.
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
        x = 0, y = 0, width = cw - 8, height = 100,
    }, scrollBox)
    contentLbl:setStyleSheet(string.format("background:%s; border:none;", bgCol))
    local formHandle, totalH = buildRows(ns, contentLbl)
    targetTab._settingsForm = formHandle
    resizeWindow("mux_set_cl_" .. safeName, cw - 8, math.max(totalH or 1, 1))
end

local function buildMainPaneContent(targetTab, bgColor)
    targetTab.contentBg:hide()
    local mainPane
    if Mux._panes then
        for _, p in pairs(Mux._panes) do
            if p.mainConsoleHost then mainPane = p; break end
        end
    end
    local scrollBox = Geyser.ScrollBox:new({
        name = "mux_set_sb_mainpane",
        x = 0, y = 0, width = "100%", height = "100%",
    }, targetTab.content)
    local cw = targetTab.content:get_width()
    if cw < 50 then cw = 400 end
    local contentLbl = Geyser.Label:new({
        name = "mux_set_cl_mainpane",
        x = 0, y = 0, width = cw - 8, height = 100,
    }, scrollBox)
    contentLbl:setStyleSheet(string.format("background:%s; border:none;", bgColor))

    if not mainPane then
        contentLbl:echo("<center><i>No main pane found. Load a workspace first.</i></center>")
        return
    end

    local rows = {}

    if mainPane.titlebarHideable then
        rows[#rows+1] = {
            label      = "Titlebar",
            desc       = "Show or hide the titlebar strip",
            type       = "toggle",
            trueLabel  = "Visible",
            falseLabel = "Hidden",
            readFn     = function() return mainPane.titlebarVisible end,
            writeFn    = function(v) mainPane:setTitlebarVisible(v) end,
        }
    end

    rows[#rows+1] = {
        label      = "Settings",
        desc       = "Show the ⚙ button in the titlebar. If hidden, access Main properties here in Settings",
        type       = "toggle",
        trueLabel  = "Visible",
        falseLabel = "Hidden",
        readFn     = function() return mainPane.showSettingsInMenu ~= false end,
        writeFn    = function(v)
            mainPane.showSettingsInMenu = v
            mainPane.propertiesButton   = v
            mainPane:_applyTitlebarVisibility()
        end,
    }

    rows[#rows+1] = {
        label      = "Splittable",
        desc       = "Allow this pane to be split horizontally or vertically",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return mainPane.splittable end,
        writeFn    = function(v)
            mainPane.splittable = v
            mainPane:_applyTitlebarVisibility()
        end,
    }

    rows[#rows+1] = {
        label      = "Swappable",
        desc       = "Allow this pane to swap position with its sibling within a split",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return mainPane.swappable end,
        writeFn    = function(v)
            mainPane.swappable = v
            mainPane:_applyTitlebarVisibility()
        end,
    }

    rows[#rows+1] = {
        label      = "Zoomable",
        desc       = "Allow this pane to temporarily zoom to fill the window",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return mainPane.zoomable end,
        writeFn    = function(v)
            mainPane.zoomable = v
            mainPane:_applyTitlebarVisibility()
        end,
    }

    rows[#rows+1] = {
        label      = "Resizable",
        desc       = "Show drag handles to resize this pane's split slot",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return mainPane.resizable ~= false end,
        writeFn    = function(v)
            mainPane.resizable = v
            if not v then mainPane:_hideCornerHandles() end
            if mainPane._split then mainPane._split:_updateHandleResizability() end
        end,
    }

    rows[#rows+1] = {
        label   = "Width %",
        desc    = "Width as a percentage of screen width (applies when in a horizontal split)",
        type    = "text",
        readFn  = function()
            local sw = getMainWindowSize()
            if mainPane._split and mainPane._split.direction == "h" then
                local r = (mainPane._slotSide == "a") and mainPane._split.ratio or (1 - mainPane._split.ratio)
                return tostring(math.floor(r * 100))
            end
            return ""
        end,
        writeFn = function(v)
            local pct = tonumber(v:match("%d+"))
            if pct then Mux.resizePaneToWidth(mainPane, pct) end
        end,
    }

    rows[#rows+1] = {
        label   = "Height %",
        desc    = "Height as a percentage of screen height (applies when in a vertical split)",
        type    = "text",
        readFn  = function()
            local _, sh = getMainWindowSize()
            if mainPane._split and mainPane._split.direction == "v" then
                local r = (mainPane._slotSide == "a") and mainPane._split.ratio or (1 - mainPane._split.ratio)
                return tostring(math.floor(r * 100))
            end
            return ""
        end,
        writeFn = function(v)
            local pct = tonumber(v:match("%d+"))
            if pct then Mux.resizePaneToHeight(mainPane, pct) end
        end,
    }

    local formOpts = {
        width         = cw - 8,
        prefix        = "mux_main_prop",
        rowHeight     = settingsFormOpts.rowHeight,
        textRowHeight = settingsFormOpts.textRowHeight,
        widgetWidth   = settingsFormOpts.widgetWidth,
        widgetHeight  = settingsFormOpts.widgetHeight,
        getContentScreenPos = function()
            local win = settingsUi.window
            if not win then return 0, 0 end
            local theme = Mux.activeTheme()
            local tabBarH = theme.tabBarHeight or 22
            local bi = 2
            return (win.floatX or 0) + bi,
                   (win.floatY or 0) + bi + (theme.titlebarHeight or 22) + 2 * tabBarH
        end,
    }
    local formHandle, totalH = Mux.ui.buildForm(contentLbl, rows, formOpts)
    targetTab._mainPropForm = formHandle
    resizeWindow("mux_set_cl_mainpane", cw - 8, math.max(totalH or 1, 1))
end

local function buildWindow()
    local sw, sh = getMainWindowSize()
    local w = math.floor(sw * 0.34)

    -- Pre-compute required height before creating any widgets.
    -- Chrome = titlebar + 2×borderInset + N×tabBarHeight + footerPad
    -- N=1 for direct leaf tabs, N=2 for tabs with sub-tabs.
    local theme_pre  = Mux.activeTheme()
    local titleH_pre = theme_pre.titlebarHeight or 22
    local tabH_pre   = theme_pre.tabBarHeight   or 22
    local bi         = 2   -- borderInset (must match pane.lua constant)
    local hierarchy  = tabHierarchy()
    local maxNeeded  = 200
    for _, entry in ipairs(hierarchy) do
        local levels = (entry.children and #entry.children > 0) and 2 or 1
        local chrome = 2*bi + titleH_pre + levels*tabH_pre + footerPad
        if entry.ns then
            local needed = measureNsHeight(entry.ns) + chrome
            if needed > maxNeeded then maxNeeded = needed end
        end
        for _, child in ipairs(entry.children or {}) do
            local needed = measureNsHeight(child.ns) + chrome
            if needed > maxNeeded then maxNeeded = needed end
        end
    end
    local maxH = math.floor(sh * 0.80)
    local h    = math.max(200, math.min(maxH, maxNeeded))
    local x    = math.floor((sw - w) / 2)
    local y    = math.floor((sh - h) / 2)

    local pane = Mux.createDialog({
        title    = string.format("⚙  Settings  v%s", Mux._version),
        x=x, y=y, width=w, height=h,
        minimizable = true,
    })
    local theme   = Mux.activeTheme()
    local ui      = theme.ui or theme.settingsUi or {}
    local bgColor = ui.bg or "rgb(18, 18, 26)"

    pane.floatX = x; pane.floatY = y
    pane.floatW = w; pane.floatH = h
    pane.onClose = function()
        closeDropdown(); hideTooltip()
        settingsUi.visible = false
        settingsUi.window  = nil
    end
    settingsUi.window = pane

    -- Intercept close button: warn if the main pane's ⚙ button or titlebar is hidden,
    -- which would leave no UI path back to Settings.
    pane.closeBtn:setClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        local mainP
        if Mux._panes then
            for _, p in pairs(Mux._panes) do
                if p.mainConsoleHost then mainP = p; break end
            end
        end
        local reasons = {}
        if mainP then
            if not mainP.titlebarVisible           then reasons[#reasons+1] = "hidden titlebar" end
            if mainP.showSettingsInMenu == false   then reasons[#reasons+1] = "Settings button hidden" end
        end
        if #reasons > 0 then
            local reasonStr = table.concat(reasons, " and ")
            Mux._showPropsCloseConfirm(
                "The main pane has a <b>" .. reasonStr .. "</b>.<br/>"
             .. "To reopen Settings use: <tt style='color:#8ab4ff;'>mux settings</tt>",
                function() pane:close() end)
        else
            pane:close()
        end
    end)

    pane.highlightable = false
    pane.tabsLocked    = true
    if pane.titlebar then pane.titlebar:setCursor(pane:_titlebarCursor()) end
    pane:_applyTitlebarVisibility()
    pane:enableTabs({ noDefaultTab = true })

    -- Build tabs from the hierarchy (already computed above for height pre-sizing).
    for _, entry in ipairs(hierarchy) do
        local tab = pane:addTab(entry.label)
        tab.renamable   = false
        tab.closeable   = false
        tab.movable     = false
        tab.contentable = false
        tab.contextMenu = false
        tab._settingsNs   = entry.ns  -- nil for package-level grouper tabs

        if entry.children and #entry.children > 0 then
            -- Package tab: enable sub-tabs for each child namespace.
            tab.tabsLocked = true
            tab:enableTabs({ noDefaultTab = true })
            for _, child in ipairs(entry.children) do
                local subTab = tab:addTab(child.label)
                subTab.renamable   = false
                subTab.closeable   = false
                subTab.movable     = false
                subTab.contentable = false
                subTab.contextMenu = false
                subTab._settingsNs   = child.ns
                buildSettingsContent(subTab, child.ns, bgColor)
            end
            -- Muxlet package: append a Main sub-tab for main pane properties.
            if entry.label == "Muxlet" then
                local mainTab = tab:addTab("Main")
                mainTab.renamable   = false
                mainTab.closeable   = false
                mainTab.movable     = false
                mainTab.contentable = false
                mainTab.contextMenu = false
                buildMainPaneContent(mainTab, bgColor)
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
    tab         = "Muxlet/General",
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

Mux.settings.register("mux", "reset_workspace", {
    description = "Workspace applied by 'mux reset' — must be a registered workspace name",
    default     = "default",
})

Mux.settings.register("mux", "confirmPaneClose", {
    description = "Show a confirmation dialog before closing a pane",
    default     = true,
})

Mux.settings.register("mux", "confirmTabClose", {
    description = "Show a confirmation dialog before closing a tab",
    default     = true,
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
    tab         = "Muxlet/General",
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
