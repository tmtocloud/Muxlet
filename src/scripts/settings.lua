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
Mux.settings._tabOrder  = Mux.settings._tabOrder  or {}
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
    if cfg.order and not Mux.settings._tabOrder[ns] then
        Mux.settings._tabOrder[ns] = cfg.order
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
        widget      = cfg.widget,   -- optional UI hint, e.g. "color" / "segmented"
        label       = cfg.label,    -- optional pretty display name (else derived from key)
        order       = cfg.order,    -- optional sub-tab ordering hint
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
    if reg then return reg.default end
    return nil
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
    -- Each extra path segment is another nested tab bar above the content.
    local path = Mux.settings._tabPaths[ns]
    if path then
        local _, slashes = path:gsub("/", "")
        cy = cy + slashes * tabBarH
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
-- snake_case setting key → Title Case display label ("tab_shape" → "Tab Shape").
-- The raw key is still used for the command line; this is display-only.
local function prettifySettingKey(key)
    local words = {}
    for w in tostring(key):gmatch("[^_%s]+") do
        words[#words+1] = w:sub(1, 1):upper() .. w:sub(2)
    end
    return table.concat(words, " ")
end

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
                label        = cfg.label or prettifySettingKey(key),
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

            if cfg.widget == "color" then
                spec.type = "color"
            elseif cfg.choices and (cfg.widget == "segmented" or #cfg.choices <= 4) then
                -- Small choice sets render as side-by-side buttons (no popup).
                spec.type    = "array"
                spec.display = "segmented"
                spec.options = {}
                for _, c in ipairs(cfg.choices) do
                    spec.options[#spec.options+1] = { value = c, label = tostring(c) }
                end
                -- Give each button room for its label rather than splitting a
                -- narrow default width across all options.
                spec.widgetWidth = math.max(120, #cfg.choices * 58)
            elseif cfg.choices then
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

-- Match the pane/tab properties windows, which use buildForm's defaults — keep
-- this empty so settings rows get the same row heights and widget sizing.
local settingsFormOpts = {}

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

-- Builds the tab hierarchy as a tree from _tabPaths and the registered namespaces.
-- A node is { label, ns?, main?, children? }. Leaf nodes carry a settings ns (or
-- the `main` flag for the Muxlet main-pane tab); nodes with children render as a
-- (sub-)tab bar. Supports arbitrary depth (e.g. Muxlet → Tabs → Style/Colors).
local function tabHierarchy()
    local root = { children = {}, _map = {} }

    -- Descend the slash-path, creating intermediate nodes, attaching ns at the leaf.
    for ns in pairs(Mux.settings._registry) do
        local path = Mux.settings._tabPaths[ns] or ns
        local node = root
        for part in path:gmatch("[^/]+") do
            node._map[part] = node._map[part] or { label = part, children = {}, _map = {} }
            local child = node._map[part]
            -- track insertion into the parent's children list once
            if not child._linked then
                child._linked = true
                node.children[#node.children + 1] = child
            end
            node = child
        end
        node.ns    = ns
        node.order = Mux.settings._tabOrder[ns]
    end

    -- A node with both a direct ns AND children: promote the ns to a "General" child.
    local function promote(node)
        if node.ns and node.children and #node.children > 0 then
            local gen = { label = "General", ns = node.ns, children = {}, _map = {} }
            table.insert(node.children, 1, gen)
            node.ns = nil
        end
        for _, c in ipairs(node.children or {}) do promote(c) end
    end
    promote(root)

    -- Muxlet gets a "Main" tab (main-pane properties) plus an Actions management
    -- tab. Conditions are set per-pane (Rules), so there is no Conditions tab.
    -- Final order is forced below: General | Main | Tabs | Actions.
    local muxNode = root._map["Muxlet"]
    if muxNode then
        muxNode.children[#muxNode.children + 1] =
            { label = "Main", main = true, children = {}, _map = {} }
        muxNode.children[#muxNode.children + 1] =
            { label = "Actions", custom = "actions", children = {}, _map = {} }
        local DESIRED = { General = 1, Main = 2, Tabs = 3, Actions = 4 }
        for _, c in ipairs(muxNode.children) do
            if DESIRED[c.label] then c.order = DESIRED[c.label] end
        end
    end

    -- Order children by (order or 99) then label; "Muxlet" pinned first at top level.
    local function sortNode(node, top)
        table.sort(node.children, function(a, b)
            if top then
                if a.label == "Muxlet" then return true  end
                if b.label == "Muxlet" then return false end
            end
            local ao, bo = a.order or 99, b.order or 99
            if ao ~= bo then return ao < bo end
            return a.label < b.label
        end)
        for _, c in ipairs(node.children) do sortNode(c, false) end
    end
    sortNode(root, true)

    return root.children
end

-- Activate the tab (or sub-tab) that corresponds to namespace ns.
function Mux.settings.showTab(ns)
    closeDropdown(); hideTooltip()
    local pane = settingsUi.window
    if not pane then return end
    -- Depth-first search for the (sub-)tab whose namespace matches, recording the
    -- ancestor chain so each level can be activated in turn (supports any depth).
    local function find(host, chain)
        for _, tab in ipairs(host._tabs or {}) do
            local c2 = {}
            for i = 1, #chain do c2[i] = chain[i] end
            c2[#c2 + 1] = { host = host, tab = tab }
            if tab._settingsNs == ns then return c2 end
            if tab._tabs then
                local r = find(tab, c2)
                if r then return r end
            end
        end
        return nil
    end
    local chain = find(pane, {})
    if not chain then return end
    for _, link in ipairs(chain) do link.host:activateTab(link.tab.id) end
    settingsUi.currentTab = ns
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
        label      = "addPane",
        desc       = "Show a + button in the titlebar (and right-click menu when compact) to add a new floating pane",
        type       = "toggle",
        trueLabel  = "Visible",
        falseLabel = "Hidden",
        readFn     = function() return mainPane.addable end,
        writeFn    = function(v)
            mainPane.addable = v
            mainPane:_syncButtons(true)
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

-- Settings content is registered the same way pane/tab properties are
-- (mux_properties): an internal content def applied to each settings (sub-)tab via
-- Mux._applyContent, rather than built ad-hoc. This gives the settings forms the
-- same managed lifecycle as any other pane content — _applyContent owns
-- attach/detach and child-cleanup, and the reposition/relayout cascade treats them
-- like every other content target instead of free-floating widgets.
--
-- Which body to build is selected by flags set on the tab before apply:
--   target._settingsMain → the Main pane's live property form
--   target._settingsNs    → the settings form for that namespace
-- internal=true lets it apply onto the settings tabs even though they set
-- contentable=false (same exemption mux_properties relies on).
-- NOTE: settings.lua loads before content.lua, so Mux.registerContent doesn't
-- exist yet here. The def is defined now (capturing the builder locals) and
-- registered in the deferred muxletReady timer at the bottom of this file.
-- ── Conditions / Actions management UIs (Settings → Conditions / Actions) ─────
-- List every registered condition/action (code ones read-only, declarative ones
-- editable) and create/delete declarative ones via a minimal builder that
-- round-trips to rules.json (see conditional.lua).

local function customRefresh(target)
    if target and not target._closed then
        target._lastContentW, target._lastContentH = nil, nil
        Mux._applyContent(target, "mux_settings", true)
    end
end

local function okBtnCss()
    return "QLabel{ background:rgb(40,90,50); color:#bff0c0; border:1px solid rgba(90,180,90,0.5); border-radius:4px; font-weight:bold; }"
        .. "QLabel::hover{ background:rgb(50,110,60); }"
end
local function delBtnCss()
    return "QLabel{ background:rgb(70,30,30); color:#f0c0c0; border:1px solid rgba(180,90,90,0.5); border-radius:4px; font-weight:bold; }"
        .. "QLabel::hover{ background:rgb(110,40,40); }"
end

local function neutralBtnCss()
    return "QLabel{ background:rgb(45,45,66); color:#cdd2f0; border:1px solid rgba(255,255,255,0.18); border-radius:4px; }"
        .. "QLabel::hover{ background:rgb(58,58,84); }"
end

-- Shared builder for the Conditions and Actions managers. `cfg` supplies the
-- entity-specific bits (labels, registries, kind options, per-kind fields,
-- create/delete, listing). Clicking a registered entry selects it: declarative
-- entries load into the editable form, built-ins show read-only info. The Kind
-- control is a segmented multi-button that rebuilds the form so only the fields
-- relevant to the chosen kind are shown.
local function buildEntityManager(target, bg, cfg)
    if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
    target._customEpoch = (target._customEpoch or 0) + 1
    local gid   = target._gid .. "e" .. target._customEpoch
    local P     = cfg.prefix                      -- widget-name prefix, e.g. "mux_condm"
    local cw    = target.content:get_width();  if cw    < 50 then cw    = 420 end
    local fullH = target.content:get_height(); if fullH < 50 then fullH = 360 end

    local root = Geyser.Label:new({ name = P.."_"..gid, x=0, y=0, width=cw, height="100%" }, target.content)
    root:setStyleSheet("background:"..bg.."; border:none;")

    local selKey   = target[cfg.selField]                 -- selected name/id (or nil = new)
    local declSpec = selKey and cfg.getDecl(selKey) or nil
    local builtin  = selKey ~= nil and declSpec == nil and cfg.builtinInfo ~= nil

    -- Bind the editor to a draft, reloading it from the spec when the selection
    -- changes (so typing persists while a kind switch rebuilds the form).
    local draft
    if declSpec then
        if target[cfg.draftForField] ~= selKey then
            draft = cfg.draftFromSpec(declSpec)
            target[cfg.draftField], target[cfg.draftForField] = draft, selKey
        else
            draft = target[cfg.draftField]
        end
    else
        if target[cfg.draftForField] ~= false then
            target[cfg.draftField]    = cfg.blankDraft()
            target[cfg.draftForField] = false
        end
        draft = target[cfg.draftField]
    end

    local y = 6
    local hdr = Geyser.Label:new({ name=P.."_h_"..gid, x=8, y=y, width=cw-16, height=22 }, root)
    hdr:setStyleSheet("background:transparent;border:none;")
    if declSpec then
        hdr:echo("<span style='color:#cdd2f0;font-size:13px;font-weight:bold;'>Editing</span>"
              .. "<span style='color:#7f8bbf;font-size:11px;'>  "..selKey.."</span>")
    elseif builtin then
        hdr:echo("<span style='color:#cdd2f0;font-size:13px;font-weight:bold;'>Viewing</span>"
              .. "<span style='color:#7f8bbf;font-size:11px;'>  "..selKey.." (built-in)</span>")
    else
        hdr:echo("<span style='color:#cdd2f0;font-size:13px;font-weight:bold;'>New "..cfg.noun.."</span>")
    end
    y = y + 28

    if builtin then
        local info = Geyser.Label:new({ name=P.."_i_"..gid, x=8, y=y, width=cw-16, height=70 }, root)
        info:setStyleSheet("background:rgba(255,255,255,0.04);border:none;border-radius:4px;")
        info:echo(cfg.builtinInfo(selKey))
        y = y + 78

        local dupBtn = Geyser.Label:new({ name=P.."_dup_"..gid, x=8, y=y, width=150, height=28 }, root)
        dupBtn:setStyleSheet(okBtnCss())
        dupBtn:echo("<center><span style='font-size:12px;'>Duplicate as editable</span></center>")
        dupBtn:setClickCallback(function()
            target[cfg.draftField]    = cfg.duplicateDraft(selKey)
            target[cfg.draftForField] = false        -- keep this seeded draft
            target[cfg.selField]      = nil           -- drop into "new" editing mode
            customRefresh(target)
        end)
        local newBtnB = Geyser.Label:new({ name=P.."_newb_"..gid, x=cw-92, y=y, width=84, height=28 }, root)
        newBtnB:setStyleSheet(neutralBtnCss())
        newBtnB:echo("<center><span style='font-size:11px;'>+ New</span></center>")
        newBtnB:setClickCallback(function()
            target[cfg.selField], target[cfg.draftForField] = nil, nil
            target[cfg.draftField] = cfg.blankDraft()
            customRefresh(target)
        end)
        y = y + 34
    else
        local specs = {}
        specs[#specs+1] = (declSpec and cfg.idRowReadOnly or cfg.idRowEditable)(draft)
        specs[#specs+1] = { key="label", label="Label", type="string", display="text",
            readFn=function() return draft.label or "" end, writeFn=function(v) draft.label=v end }
        specs[#specs+1] = { key="kind", label="Kind", type="segmentedControl",
            widgetWidth=cfg.kindWidth or 200, options=cfg.kindOpts,
            readFn=function() return draft.kind end,
            writeFn=function(v) draft.kind=v; customRefresh(target) end }
        for _, mk in ipairs(cfg.fieldsForKind(draft.kind)) do
            specs[#specs+1] = mk(draft)
        end

        local fh = Mux.ui.formHeight(specs)
        local formLbl = Geyser.Label:new({ name=P.."_f_"..gid, x=0, y=y, width=cw, height=fh }, root)
        Mux.ui.buildForm(formLbl, specs, { width=cw, prefix=P.."_x_"..gid })
        y = y + fh + 4

        -- Plain-language explanation of the selected kind.
        local helpTxt = cfg.kindHelp and cfg.kindHelp(draft.kind)
        if helpTxt then
            local help = Geyser.Label:new({ name=P.."_help_"..gid, x=8, y=y, width=cw-16, height=34 }, root)
            help:setStyleSheet("background:transparent;border:none;")
            help:echo("<span style='color:#8b93c4;font-size:10px;'>"..helpTxt.."</span>")
            y = y + 38
        end

        local btnY = y
        local saveBtn = Geyser.Label:new({ name=P.."_save_"..gid, x=8, y=btnY, width=110, height=28 }, root)
        saveBtn:setStyleSheet(okBtnCss())
        saveBtn:echo("<center><span style='font-size:12px;'>"..(declSpec and "Save" or ("+ Add "..cfg.noun)).."</span></center>")
        saveBtn:setClickCallback(function()
            local key, err = cfg.save(draft, declSpec and selKey or nil)
            if key then
                target[cfg.selField]      = key
                target[cfg.draftForField] = nil
                customRefresh(target)
            elseif err then cecho("\n<red>[mux]<reset> "..tostring(err).."\n") end
        end)
        if declSpec then
            local delBtn = Geyser.Label:new({ name=P.."_del_"..gid, x=124, y=btnY, width=90, height=28 }, root)
            delBtn:setStyleSheet(delBtnCss())
            delBtn:echo("<center><span style='font-size:12px;'>Delete</span></center>")
            delBtn:setClickCallback(function()
                cfg.del(selKey)
                target[cfg.selField], target[cfg.draftForField] = nil, nil
                customRefresh(target)
            end)
        end
        local newBtn = Geyser.Label:new({ name=P.."_new_"..gid, x=cw-92, y=btnY, width=84, height=28 }, root)
        newBtn:setStyleSheet(neutralBtnCss())
        newBtn:echo("<center><span style='font-size:11px;'>New</span></center>")
        newBtn:setClickCallback(function()
            target[cfg.selField], target[cfg.draftForField] = nil, nil
            target[cfg.draftField] = cfg.blankDraft()
            customRefresh(target)
        end)
        y = btnY + 34
    end

    local sep = Geyser.Label:new({ name=P.."_s_"..gid, x=8, y=y, width=cw-16, height=18 }, root)
    sep:setStyleSheet("background:transparent;border:none;")
    sep:echo("<span style='color:#7f8bbf;font-size:11px;font-weight:bold;'>Registered  "
          .. "<span style='color:#5a6090;'>(click to select)</span></span>")
    y = y + 20

    local entries = cfg.list()
    if #entries == 0 then
        local none = Geyser.Label:new({ name=P.."_none_"..gid, x=8, y=y, width=cw-16, height=20 }, root)
        none:setStyleSheet("background:transparent;border:none;")
        none:echo("<span style='color:#7f8bbf;font-size:11px;'>None yet.</span>")
        return
    end
    local rowH   = 22
    local bottom = fullH - 4
    for i, e in ipairs(entries) do
        local ry = y + (i - 1) * rowH
        if ry + rowH - 2 > bottom then break end   -- clip rows that would overflow
        local key      = e.key
        local selected  = (key == selKey)
        local row = Geyser.Label:new({ name=P.."_le"..i.."_"..gid, x=8, y=ry, width=cw-16, height=rowH-2 }, root)
        row:setStyleSheet(selected
            and "QLabel{background:rgba(120,140,220,0.22);border:none;border-radius:3px;} QLabel::hover{background:rgba(120,140,220,0.30);}"
            or  "QLabel{background:rgba(255,255,255,0.03);border:none;border-radius:3px;} QLabel::hover{background:rgba(120,140,220,0.16);}")
        row:setCursor("PointingHand")
        row:echo(string.format(
            "<span style='color:%s;font-size:11px;'>&nbsp;%s</span>"
            .. "<span style='color:#7f8bbf;font-size:10px;'>&nbsp;&nbsp;%s</span>"
            .. "<span style='color:%s;font-size:10px;'>&nbsp;&nbsp;%s</span>",
            selected and "#cfe0ff" or "#e0e3f4", key, e.label or "",
            e.editable and "#c9b06a" or "#5a6090", e.editable and "editable" or "built-in"))
        row:setClickCallback(function()
            target[cfg.selField] = key; target[cfg.draftForField] = nil; customRefresh(target)
        end)
    end
end

local function buildActionsManager(target, bg)
    buildEntityManager(target, bg, {
        prefix = "mux_actm", noun = "action",
        selField = "_actSel", draftField = "_actDraft", draftForField = "_actDraftFor",
        getDecl = function(id) return Mux.getDeclarativeAction(id) end,
        blankDraft = function() return { kind="send" } end,
        draftFromSpec = function(s) return { id=s.id, label=s.label, kind=s.kind, command=s.command, event=s.event, code=s.code } end,
        kindWidth = 220,
        kindOpts = {
            { value="send",  label="send" },
            { value="raise", label="raise" },
            { value="lua",   label="run Lua" },
        },
        idRowEditable = function(draft) return { key="id", label="ID", type="string", display="text",
            readFn=function() return draft.id or "" end, writeFn=function(v) draft.id=v end } end,
        idRowReadOnly = function(draft) return { key="id", label="ID", type="readOnly",
            readFn=function() return draft.id or "" end } end,
        fieldsForKind = function(kind)
            local f = {}
            if kind=="send" then
                f[#f+1] = function(draft) return { key="command", label="Command", type="string", display="text",
                    desc="text sent to the game", readFn=function() return draft.command or "" end, writeFn=function(v) draft.command=v end } end
            end
            if kind=="raise" then
                f[#f+1] = function(draft) return { key="event", label="Event", type="string", display="text",
                    desc="Mudlet event to raise", readFn=function() return draft.event or "" end, writeFn=function(v) draft.event=v end } end
            end
            if kind=="lua" then
                f[#f+1] = function(draft) return { key="code", label="Lua", type="string", display="text",
                    desc="Lua run when fired; the action context is the vararg, e.g. local ctx=... (ctx.pane)",
                    readFn=function() return draft.code or "" end, writeFn=function(v) draft.code=v end } end
            end
            return f
        end,
        kindHelp = function(kind)
            if kind == "send" then
                return "Sends the command text to the game, exactly as if you typed it at the input line."
            elseif kind == "raise" then
                return "Raises a named Mudlet event. Other scripts — or a condition's <i>event fired</i> test — can react to it."
            elseif kind == "lua" then
                return "Runs the Lua you enter. It receives the action context as its vararg — write <i>local ctx = ...</i> to read <i>ctx.pane</i>. Call your own functions for anything longer."
            end
            return nil
        end,
        save = function(draft, editingKey)
            local id = editingKey or ((draft.id or ""):gsub("%s+",""))
            if id == "" then return nil, "Action needs an id." end
            local ok, err = pcall(Mux.createDeclarativeAction, {
                id=id, label=(draft.label and draft.label~="") and draft.label or id, kind=draft.kind,
                command=draft.command, event=draft.event, code=draft.code })
            if ok then cecho(string.format("\n<green>[mux]<reset> Action '<cyan>%s<reset>' saved.\n", id)); return id end
            return nil, err
        end,
        del = function(id) Mux.deleteDeclarativeAction(id) end,
        list = function()
            -- Only YOUR actions are managed here. Built-ins still appear in the
            -- action pickers (pane Rules, buttons) but aren't listed/edited here.
            local out = {}
            for _, a in ipairs(Mux.listActions and Mux.listActions() or {}) do
                if Mux._declActions and Mux._declActions[a.id] then
                    out[#out+1] = { key=a.id, label=a.name, editable=true }
                end
            end
            return out
        end,
    })
end

local muxSettingsContentDef = {
    name     = "Settings",
    internal = true,
    apply = function(target)
        local theme = Mux.activeTheme() or {}
        local ui    = theme.ui or theme.settingsUi or {}
        local bg    = ui.bg or "rgb(18, 18, 26)"
        if target._settingsMain then
            buildMainPaneContent(target, bg)
        elseif target._settingsCustom == "actions" then
            buildActionsManager(target, bg)
        elseif target._settingsNs then
            buildSettingsContent(target, target._settingsNs, bg)
        end
    end,
    remove = function(_target)
        -- Form widgets are children of the (sub-)tab's content container and are
        -- torn down with the Settings pane; _applyContent hides them on swap. The
        -- Settings window is fixed-size, so no resize() is needed — its absence
        -- means the reposition cascade leaves the form untouched.
    end,
}

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
    -- Each leaf settings tab sits under `depth` tab bars (pane bar + sub-tab bars).
    local function measureNode(node, depth)
        if node.ns then
            local chrome = 2*bi + titleH_pre + depth*tabH_pre + footerPad
            local needed = measureNsHeight(node.ns) + chrome
            if needed > maxNeeded then maxNeeded = needed end
        elseif node.custom or node.main then
            -- Managers (Actions/Conditions) and Main need a workable height.
            local chrome = 2*bi + titleH_pre + depth*tabH_pre + footerPad
            local needed = 440 + chrome
            if needed > maxNeeded then maxNeeded = needed end
        end
        for _, child in ipairs(node.children or {}) do
            measureNode(child, depth + 1)
        end
    end
    for _, entry in ipairs(hierarchy) do measureNode(entry, 1) end
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
    -- Recurses for arbitrary depth (e.g. Muxlet → Tabs → Style / Colors).
    -- Settings tab bars use the SAME styling as a regular pane's tab bar (the dark
    -- background with the thin grey line), not a translucent sub-bar.
    local subTabBarCss = Mux.activeTheme().tabBarCss
        or "background-color: #000000; border: none; border-bottom: 1px solid rgba(255,255,255,0.10);"
    local function buildNode(parent, node)
        local tab = parent:addTab(node.label)
        tab.renamable   = false
        tab.closeable   = false
        tab.movable     = false
        tab.contentable = false
        tab.contextMenu = false
        tab._settingsNs = node.ns
        if node.children and #node.children > 0 then
            tab.tabsLocked = true
            tab:enableTabs({ noDefaultTab = true })
            if tab._tabBar then tab._tabBar:setStyleSheet(subTabBarCss) end
            for _, child in ipairs(node.children) do buildNode(tab, child) end
        elseif node.main then
            tab._settingsMain = true
            Mux._applyContent(tab, "mux_settings")
        elseif node.custom then
            tab._settingsCustom = node.custom
            Mux._applyContent(tab, "mux_settings")
        elseif node.ns then
            -- tab._settingsNs already set above.
            Mux._applyContent(tab, "mux_settings")
        end
        return tab
    end
    for _, entry in ipairs(hierarchy) do buildNode(pane, entry) end

    -- Geyser's hide() only covers children that existed when hide() was called; tab
    -- infrastructure is added afterwards, so re-hide every non-active (sub-)tab at
    -- all depths now that content is built, or stale tabs draw over the active one.
    local function hideInactive(host)
        for _, t in ipairs(host._tabs or {}) do
            if t.id ~= host._activeTabId and t.content then t.content:hide() end
            if t._tabs then hideInactive(t) end
        end
    end
    hideInactive(pane)

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

Mux.settings.register("mux", "live_resize_max_panes", {
    description = "Live-resize panes while dragging a split handle only when the affected area holds at most this many panes; above it, drag a preview line and apply on release (instant regardless of pane count). Set high to always resize live, or 1 to always preview",
    default     = 2,
    min         = 1,
    max         = 99,
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
    if Mux._applyTabStyle then Mux._applyTabStyle() end   -- re-apply tab styling on top of the new theme
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

-- Explicit display order for the Muxlet/General tab.  Registration order would
-- otherwise decide this; listing it here keeps the tab curated.  update_* are
-- registered later (update.lua) — pre-listing them positions them without
-- duplicating (register() skips keys already present in the order list).
Mux.settings._order["mux"] = {
    "welcome_shown",
    "auto_start",
    "compact_titlebar",
    "confirmPaneClose",
    "confirmTabClose",
    "live_resize_max_panes",
    "reset_workspace",
    "update_check_enabled",
    "update_check_remind_skip",
    "theme",
    "debug",
}

Mux.settings.onChange("mux", "compact_titlebar", function()
    for _, pane in pairs(Mux._panes or {}) do
        if pane._syncButtons then pane:_syncButtons(true) end
    end
end)

Mux.settings.onChange("mux", "debug", function(value)
    Mux.debug = value
end)

-- ── Tab styling (Settings → Muxlet → Tabs → Style / Colors) ───────────────────
-- Look-and-feel knobs applied to every tab on the workspace at once. Values write
-- immediately and live-apply. Split across two sub-tabs: Style (dimensions, shape,
-- borders, hover behaviour, bar chrome) and Colors (all colour pickers). Tab text
-- colours are set inline by _echoTabLabel (hover included) so they always apply.

-- Style sub-tab.
Mux.settings.register("muxtab", "tab_height", {
    tab = "Muxlet/Tabs/Style", order = 1, label = "Bar Height",
    description = "Tab bar height in pixels", default = 30, min = 16, max = 48,
})
Mux.settings.register("muxtab", "tab_font_size", {
    label = "Font Size", description = "Tab label font size in pixels", default = 12, min = 6, max = 24,
})
Mux.settings.register("muxtab", "tab_shape", {
    widget = "segmented", label = "Shape", description = "Tab shape",
    default = "Round", choices = { "Square", "Round", "Pill", "Circle" },
})
Mux.settings.register("muxtab", "tab_h_gap", {
    label = "Horizontal Gap", description = "Space between tabs and at the ends of the bar (px)",
    default = 0, min = 0, max = 40,
})
Mux.settings.register("muxtab", "tab_v_gap", {
    label = "Vertical Gap", description = "Space above/below each tab within the bar (px)",
    default = 1, min = 0, max = 16,
})
Mux.settings.register("muxtab", "tab_border_width", {
    label = "Border Width", description = "Inactive tab border thickness (px)", default = 1, min = 0, max = 6,
})
Mux.settings.register("muxtab", "tab_active_border_width", {
    label = "Active Border Width", description = "Active tab border thickness (px)", default = 1, min = 0, max = 6,
})
Mux.settings.register("muxtab", "tab_hover_mode", {
    widget = "segmented", label = "Hover Mode",
    description = "Hover highlights the whole tab (Fill) or just its border (Border)",
    default = "Border", choices = { "Fill", "Border" },
})
Mux.settings.register("muxtab", "tab_bar_background", {
    label = "Tab Bar Background",
    description = "Show the tab bar's own (black) background. Off makes the bar invisible (only tabs + the + button show)",
    default = true,
})

-- Colors sub-tab.
Mux.settings.register("muxtabc", "tab_text_color", {
    tab = "Muxlet/Tabs/Colors", order = 2, widget = "color", label = "Text", default = "#ffffff",
    description = "Inactive tab text color",
})
Mux.settings.register("muxtabc", "tab_active_text_color", {
    widget = "color", label = "Active Text", description = "Active tab text color", default = "#ffffff",
})
Mux.settings.register("muxtabc", "tab_bg_color", {
    widget = "color", label = "Background", description = "Inactive tab background", default = "#1c1c1c",
})
Mux.settings.register("muxtabc", "tab_active_bg_color", {
    widget = "color", label = "Active Background", description = "Active tab background", default = "#373737",
})
Mux.settings.register("muxtabc", "tab_border_color", {
    widget = "color", label = "Border", description = "Inactive tab border color", default = "#484848",
})
Mux.settings.register("muxtabc", "tab_active_border_color", {
    widget = "color", label = "Active Border", description = "Active tab border color", default = "#9b9b9b",
})
Mux.settings.register("muxtabc", "tab_hover_bg_color", {
    widget = "color", label = "Hover Highlight",
    description = "Tab hover highlight color (fills the tab, or its border in Border mode)", default = "#ffffff",
})
Mux.settings.register("muxtabc", "tab_hover_text_color", {
    widget = "color", label = "Hover Text", description = "Tab hover text color", default = "#ffffff",
})

-- Compose tab CSS from the Style + Colors settings, write it into the active theme
-- so new tabs and activations pick it up, then restyle/resize every live tab host.
-- Tab text colour is applied inline by _echoTabLabel, not via CSS.
function Mux._applyTabStyle()
    local theme = Mux.activeTheme and Mux.activeTheme() or nil
    if not theme then return end
    local function g(ns, k, d) local v = Mux.settings.get(ns, k); if v == nil then return d end; return v end
    local h     = g("muxtab",  "tab_height", 30)
    local fs    = g("muxtab",  "tab_font_size", 12)
    local shape = g("muxtab",  "tab_shape", "Round")
    local hg    = g("muxtab",  "tab_h_gap", 0)
    local vg    = g("muxtab",  "tab_v_gap", 1)
    local bw    = g("muxtab",  "tab_border_width", 1)
    local abw   = g("muxtab",  "tab_active_border_width", 1)
    local hmode = g("muxtab",  "tab_hover_mode", "Border")
    local barBg = g("muxtab",  "tab_bar_background", true)
    local tcol  = g("muxtabc", "tab_text_color", "#ffffff")
    local atc   = g("muxtabc", "tab_active_text_color", "#ffffff")
    local bg    = g("muxtabc", "tab_bg_color", "#1c1c1c")
    local abg   = g("muxtabc", "tab_active_bg_color", "#373737")
    local bc    = g("muxtabc", "tab_border_color", "#484848")
    local abc   = g("muxtabc", "tab_active_border_color", "#9b9b9b")
    local hbg   = g("muxtabc", "tab_hover_bg_color", "#ffffff")
    local htc   = g("muxtabc", "tab_hover_text_color", "#ffffff")

    -- border-radius only renders when a border is present; the default border
    -- width of 1 keeps Pill/Circle visibly rounded.
    local radius
    if     shape == "Square" then radius = "0px"
    elseif shape == "Pill"   then radius = tostring(math.floor(h / 2)) .. "px"
    elseif shape == "Circle" then radius = tostring(math.floor(h / 2)) .. "px"
    else                          radius = "6px" end   -- Round

    -- Hover honours the mode (text colour is handled by _echoTabLabel re-echo):
    local function hover(borderW, bcol)
        if hmode == "Border" then
            return string.format("QLabel::hover{ border:%dpx solid %s; }", (borderW > 0 and borderW or 1), hbg)
        end
        return string.format("QLabel::hover{ background-color:%s; }", hbg)
    end

    theme.tabInactiveCss = string.format(
        "QLabel{ background-color:%s; border:%dpx solid %s; border-radius:%s; margin:%dpx %dpx; padding:0 4px; } %s",
        bg, bw, bc, radius, vg, hg, hover(bw, bc))
    theme.tabActiveCss = string.format(
        "QLabel{ background-color:%s; border:%dpx solid %s; border-radius:%s; margin:%dpx %dpx; padding:0 4px; } %s",
        abg, abw, abc, radius, vg, hg, hover(abw, abc))
    theme.tabActiveParentCss   = theme.tabActiveCss
    theme.tabInactiveTextColor = tcol
    theme.tabActiveTextColor   = atc
    theme.tabHoverTextColor    = htc
    theme.tabFontSize          = fs
    theme.tabBarHeight         = h
    -- Tab bar's own chrome: black background plus the thin grey separator line
    -- when shown; fully transparent (no line) when the toggle is off.
    theme.tabBarCss = barBg
        and "background-color: #000000; border: none; border-bottom: 1px solid rgba(255,255,255,0.10);"
        or  "background-color: transparent; border: none;"

    for _, host in pairs(Mux._tabHosts or {}) do
        if host._tabsEnabled then
            pcall(function()
                if host._tabBar then
                    host._tabBar:resize(nil, Mux._toPx(h)); host._tabBar:reposition()
                    host._tabBar:setStyleSheet(theme.tabBarCss)
                end
                if host._tabViewport then
                    host._tabViewport:move(nil, Mux._toPx(h)); host._tabViewport:reposition()
                end
                for _, tab in ipairs(host._tabs or {}) do
                    if tab.label then
                        local isActive = (host._activeTabId == tab.id)
                        tab.label:setStyleSheet(isActive and theme.tabActiveCss or theme.tabInactiveCss)
                        host:_echoTabLabel(tab.label, tab.name, isActive, false, theme, tab.nameAlign)
                    end
                end
                if host._tabBarBox then host._tabBarBox:organize() end
                if host.content   then Mux._relayoutContent(host) end
            end)
        end
    end
end

for _, k in ipairs({
    "tab_height", "tab_font_size", "tab_shape", "tab_h_gap", "tab_v_gap",
    "tab_border_width", "tab_active_border_width", "tab_hover_mode", "tab_bar_background",
}) do
    Mux.settings.onChange("muxtab", k, function() Mux._applyTabStyle() end)
end
for _, k in ipairs({
    "tab_text_color", "tab_active_text_color", "tab_bg_color", "tab_active_bg_color",
    "tab_border_color", "tab_active_border_color", "tab_hover_bg_color", "tab_hover_text_color",
}) do
    Mux.settings.onChange("muxtabc", k, function() Mux._applyTabStyle() end)
end

-- tempTimer(0) defers past the synchronous script-loading stack so all Muxlet
-- functions are defined before this runs. raiseEvent("muxletReady") fires last
-- so downstream packages can register a handler and be guaranteed Muxlet's full
-- API is available when they receive it.

tempTimer(0, function()
    -- content.lua is loaded by now, so the content registry exists.
    if Mux.registerContent then
        Mux.registerContent("mux_settings", muxSettingsContentDef)
    end
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

    local function _doStartOrHint()
        if Mux._running then return end
        if Mux.settings.get("mux", "auto_start") then
            if not Mux.settings.get("mux", "welcome_shown") then return end
            if Mux.fullStart then Mux.fullStart() end
        else
            Mux._echo(
                "  <dim_grey>Type <cyan>mux start<reset><dim_grey> to begin"
                .. "  •  <cyan>mux workspaces<reset> to browse  •  <cyan>mux help<reset> for all commands<reset>\n")
        end
    end

    -- If a connection attempt is in progress, defer until the game signals it is
    -- ready (GMCP negotiated) so the hint does not clutter the login sequence.
    if Mux._connState == "connecting" then
        local hId
        hId = registerAnonymousEventHandler("sysProtocolEnabled", function(_, protocol)
            if protocol ~= "GMCP" then return end
            killAnonymousEventHandler(hId)
            _doStartOrHint()
        end)
    else
        _doStartOrHint()
    end
end)

Mux._log("mux_settings loaded — file: %s", Mux.settings._file)