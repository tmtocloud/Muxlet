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
-- Structural tables are rebuilt from scratch on every load so hot-reloads
-- pick up tab-path changes. _data is preserved so user values survive reloads.
Mux.settings._registry  = {}
Mux.settings._order     = {}
Mux.settings._data      = Mux.settings._data      or {}
Mux.settings._onChange  = {}
-- Tab path per namespace — set via the optional `tab` field in register() cfg.
-- Format: "TopLabel" for a top-level tab, "TopLabel/SubLabel" for nested.
-- Drives UI tab hierarchy only; has no effect on get/set/clear.
Mux.settings._tabPaths  = {}
Mux.settings._tabOrder  = {}
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

-- Absolute screen position of a settings tab's content area, derived from the tab's
-- own nesting depth (number of tab bars above it) rather than a namespace path —
-- works for custom tabs (Theme > General/Panes/Tabs) that have no ns. Used so popup
-- overlays (theme dropdown, colour pickers) anchor at the widget, not the screen edge.
local function tabContentScreenPos(target)
    local win = settingsUi.window
    if not win then return 0, 0 end
    local theme   = Mux.activeTheme()
    local tabBarH = theme.tabBarHeight or 30
    local depth, h = 0, target
    while h and h.pane do depth = depth + 1; h = h.pane end   -- one tab bar per ancestor host
    local cx = (win.floatX or 0) + 2
    local cy = (win.floatY or 0) + 2 + (theme.titlebarHeight or 22) + depth * tabBarH
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

-- Re-read every settings form across all tabs so their widgets reflect the
-- current values. Used after a global change (e.g. "Reset all to theme") that
-- affects forms on tabs other than the one the user is looking at.
local function refreshAllForms()
    local win = settingsUi.window
    if not win then return end
    for _, tab in ipairs(win._tabs or {}) do
        if tab._settingsForm and tab._settingsForm.refreshAll then tab._settingsForm.refreshAll() end
        for _, subTab in ipairs(tab._tabs or {}) do
            if subTab._settingsForm and subTab._settingsForm.refreshAll then subTab._settingsForm.refreshAll() end
        end
    end
end
Mux._settings_ui._refreshAllForms = refreshAllForms

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
        -- Accumulate all namespaces sharing this path into nsList.
        -- ns order values control section sequence within the form, not the
        -- tab's position in its parent bar — do not propagate to node.order.
        node.nsList = node.nsList or {}
        table.insert(node.nsList, ns)
    end

    -- Convert single-namespace leaves to ns for backward compatibility.
    -- Sort multi-namespace leaves by (_tabOrder or 99) then name.
    local function consolidateNs(node)
        if node.nsList then
            if #node.nsList == 1 then
                node.ns     = node.nsList[1]
                node.nsList = nil
                if not node.order then node.order = Mux.settings._tabOrder[node.ns] end
            else
                table.sort(node.nsList, function(a, b)
                    local ao = Mux.settings._tabOrder[a] or 99
                    local bo = Mux.settings._tabOrder[b] or 99
                    if ao ~= bo then return ao < bo end
                    return a < b
                end)
            end
        end
        for _, c in ipairs(node.children or {}) do consolidateNs(c) end
    end
    consolidateNs(root)

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

    -- Muxlet top level: General | Design | Actions. Design is built from the
    -- muxtheme (picker) namespace; we add the spec-driven Pane, Tabs and Interface
    -- token editors as custom children here.
    local muxNode = root._map["Muxlet"]
    if muxNode then
        local themeNode = muxNode._map["Design"]
        if themeNode then
            -- Ensure a "General" child holds the theme picker + Interface colours.
            -- promote() only adds one when Design had children at that point; now that
            -- Panes/Tabs are injected here (after promote), create it explicitly so the
            -- picker ns isn't orphaned on Design itself.
            local generalNode
            for _, c in ipairs(themeNode.children) do
                if c.label == "General" then generalNode = c; break end
            end
            if not generalNode then
                generalNode = { label = "General", children = {}, _map = {} }
                table.insert(themeNode.children, 1, generalNode)
            end
            generalNode.order = 1; generalNode.ns = nil; generalNode.custom = "themegeneral"
            themeNode.ns = nil   -- picker now lives inside the General custom tab
            -- Panes: one tab with Style + Colors separator sections (no sub-tabs).
            local panesNode = { label = "Panes", order = 2,
                custom = "tok|Pane,Titlebar,Buttons,Slot,Drag,Handle|all", children = {}, _map = {} }
            -- Tabs: same token editor as Panes, editing the tab.* tokens (global layer).
            local tabsNode = { label = "Tabs", order = 3,
                custom = "tok|Tab|all", children = {}, _map = {} }
            table.insert(themeNode.children, panesNode)
            table.insert(themeNode.children, tabsNode)
        end

        muxNode.children[#muxNode.children + 1] =
            { label = "Conditions", custom = "conditions", children = {}, _map = {} }
        muxNode.children[#muxNode.children + 1] =
            { label = "Actions", custom = "actions", children = {}, _map = {} }
        local DESIRED = { General = 1, Design = 2, Conditions = 3, Actions = 4 }
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
            local match = tab._settingsNs == ns
            if not match and tab._settingsNsList then
                for _, n in ipairs(tab._settingsNsList) do
                    if n == ns then match = true; break end
                end
            end
            if match then return c2 end
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
    targetTab._muxRelayout   = formHandle and formHandle.relayout
    targetTab._muxContentH = totalH
    resizeWindow("mux_set_cl_" .. safeName, cw - 8, math.max(totalH or 1, 1))
end

-- Builds a single scrollable form for a list of namespaces, inserting a labelled
-- divider before each group so the sections remain visually distinct.
local function buildMultiNsContent(targetTab, nsList, bgCol)
    targetTab.contentBg:hide()
    local firstNs  = nsList[1]
    local safeName = "multi_" .. firstNs:gsub("[^%w_]", "_")

    -- Build allSpecs first so we can pre-size contentLbl correctly.
    -- Transparent divider rows must sit within contentLbl's painted area or they
    -- fall through to the ScrollBox's white Qt background and appear white.
    -- A multi-namespace tab gets one collapsible divider per namespace, labelled
    -- from the namespace name.
    local allSpecs = {}
    for _, ns in ipairs(nsList) do
        local divLabel = prettifySettingKey(ns)
        allSpecs[#allSpecs+1] = { type = "divider", label = divLabel }
        for _, spec in ipairs(buildNsSpecs(ns)) do
            allSpecs[#allSpecs+1] = spec
        end
    end

    if #allSpecs == 0 then return end

    local scrollBox = Geyser.ScrollBox:new({
        name = "mux_set_sb_" .. safeName,
        x = 0, y = 0, width = "100%", height = "100%",
    }, targetTab.content)
    local cw = targetTab.content:get_width()
    if cw < 50 then cw = 400 end
    local totalH = Mux.ui.formHeight(allSpecs, settingsFormOpts) + 2
    local contentLbl = Geyser.Label:new({
        name = "mux_set_cl_" .. safeName,
        x = 0, y = 0, width = cw - 8, height = math.max(totalH, 10),
    }, scrollBox)
    contentLbl:setStyleSheet(string.format("background:%s; border:none;", bgCol))
    targetTab._muxContentH = totalH

    local formHandle
    local formOpts = {
        width         = cw - 8,
        prefix        = "mxs_" .. safeName,
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
            return contentScreenPos(firstNs)
        end,
        onLayoutChange = function(h)
            targetTab._muxContentH = h
            Mux._scheduleFit(Mux._ownerDialog(targetTab))
        end,
    }
    formHandle = Mux.ui.buildForm(contentLbl, allSpecs, formOpts)
    targetTab._settingsForm = formHandle
    targetTab._muxRelayout   = formHandle and formHandle.relayout
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

-- ── Action editor (Settings → Muxlet → Actions) ───────────────────────────────
-- A layman-friendly designer: an action is a NAME plus an ordered list of STEPS,
-- each chosen from the operation palette (Mux.actionOps in conditional.lua). The
-- whole thing is one scrolling form — identity, the steps with their own fields,
-- an "add step" picker, save/delete, and the list of saved actions to click into.
local function _aeContentOpts()
    local out = {}
    for _, n in ipairs(Mux._listContent and Mux._listContent() or {}) do
        out[#out+1] = { value = n, label = (Mux._content[n] and Mux._content[n].name) or n }
    end
    if #out == 0 then out[1] = { value = "", label = "(no content registered)" } end
    return out
end
local function _aeThemeOpts()
    local out = {}
    for name in pairs(Mux._themes or {}) do out[#out+1] = { value = name, label = name } end
    table.sort(out, function(a, b) return a.label < b.label end)
    if #out == 0 then out[1] = { value = "", label = "(no themes)" } end
    return out
end
local function _aeOpPickerOpts()
    local out = { { value = "", label = "+ Add step…" } }
    for _, id in ipairs(Mux.actionOpOrder or {}) do
        local op = Mux.actionOps[id]
        if op then out[#out+1] = { value = id, label = (op.group or "").." · "..(op.label or id), desc = op.desc } end
    end
    return out
end
local function _aeFieldRow(step, field)
    local function rd() return step[field.key] end
    local function wr(v) step[field.key] = v end
    if field.kind == "lua" then
        return { label = field.label, type = "code", rowHeight = 150, desc = field.desc,
            readFn = function() return rd() or "" end, writeFn = wr }
    elseif field.kind == "content" then
        return { label = field.label, type = "array", display = "dropdown", desc = field.desc,
            options = _aeContentOpts(), readFn = function() return rd() or "" end, writeFn = wr }
    elseif field.kind == "theme" then
        return { label = field.label, type = "array", display = "dropdown", desc = field.desc,
            options = _aeThemeOpts(), readFn = function() return rd() or "" end, writeFn = wr }
    elseif field.kind == "choice" then
        return { label = field.label, type = "array", display = "dropdown", desc = field.desc,
            options = field.options or {},
            readFn = function() return rd() or (field.options and field.options[1] and field.options[1].value) end,
            writeFn = wr }
    else
        return { label = field.label, type = "text", desc = field.desc,
            readFn = function() return rd() or "" end, writeFn = wr }
    end
end

-- readOnly=true (built-ins) shows ID/Name/Group/Description — built-in actions
-- are code (an arbitrary `run` function), not a step list, so there's nothing
-- to show/edit as steps. A single Close button, no Save/Cancel/Delete.
local function _buildActionDialogSpecs(d, editId, readOnly, rebuild)
    local specs = {}
    if editId then
        specs[#specs+1] = { label = "ID", type = "readOnly", readFn = function() return d.id end }
    else
        specs[#specs+1] = { label = "ID", type = "text", desc = "short unique id, e.g. open_map",
            readFn = function() return d.id or "" end, writeFn = function(v) d.id = (v or ""):gsub("%s+", "") end }
    end

    if readOnly then
        specs[#specs+1] = { label = "Name", type = "readOnly", readFn = function() return d.label end }
        specs[#specs+1] = { label = "Group", type = "readOnly", readFn = function() return d.group or "" end }
        if d.desc and d.desc ~= "" then
            specs[#specs+1] = { label = "What it does", type = "readOnly", readFn = function() return d.desc end }
        end
        return specs
    end

    specs[#specs+1] = { label = "Name", type = "text", desc = "shown in pickers",
        readFn = function() return d.label or "" end, writeFn = function(v) d.label = v end }

    specs[#specs+1] = { type = "divider", label = "Steps (run top to bottom)" }
    if #d.steps == 0 then specs[#specs+1] = { type = "divider", label = "— no steps yet —" } end
    for i, step in ipairs(d.steps) do
        local op = Mux.actionOps[step.op]
        specs[#specs+1] = { type = "divider", label = i .. ".  " .. ((op and op.label) or step.op) }
        if op and op.fields then for _, f in ipairs(op.fields) do specs[#specs+1] = _aeFieldRow(step, f) end end
        local idx = i
        if i > 1 then
            specs[#specs+1] = { type = "button", label = "↑ Move up", _noReset = true,
                onClick = function() d.steps[idx], d.steps[idx-1] = d.steps[idx-1], d.steps[idx]; rebuild() end }
        end
        specs[#specs+1] = { type = "button", style = "danger", label = "✖ Remove step " .. i, _noReset = true,
            onClick = function() table.remove(d.steps, idx); rebuild() end }
    end
    specs[#specs+1] = { label = "Add step", type = "array", display = "dropdown",
        desc = "pick an operation to append", options = _aeOpPickerOpts(),
        readFn = function() return "" end,
        writeFn = function(opId) if opId and opId ~= "" then d.steps[#d.steps+1] = { op = opId }; rebuild() end end }

    return specs
end

-- New/Edit Action dialog — mirrors openConditionDialog (settings.lua): a
-- focused popup instead of the old inline "add" form mixed into the endless
-- settings scroll, no per-field Apply/Enter (hideApply + commitAll() on
-- Save), and built-ins open the same dialog read-only rather than a separate
-- view mode bolted onto the panel.
local function openActionDialog(editId, onDone, readOnly)
    local dlg = Mux.createDialog({
        title = readOnly and "Action (built-in)" or (editId and "Edit Action" or "New Action"),
        width = 460, height = 320, resizable = true, contextMenu = false,
    })
    if not dlg then return end
    if dlg.contentBg then dlg.contentBg:echo(""); dlg.contentBg:hide() end

    local d
    if readOnly then
        local v = Mux.getAction and Mux.getAction(editId)
        d = { id = editId, label = (v and v.name) or editId, group = v and v.group, desc = v and v.desc }
    elseif editId then
        local s = Mux.getDeclarativeAction and Mux.getDeclarativeAction(editId)
        local steps = {}
        if s then
            for _, st in ipairs(Mux._actionSteps(s)) do
                local c = {}; for k, v in pairs(st) do c[k] = v end; steps[#steps+1] = c
            end
        end
        d = { id = editId, label = (s and s.label) or editId, steps = steps }
    else
        d = { id = "", label = "", steps = {} }
    end

    local rebuild
    local formHandle
    -- Same fix as openConditionDialog: step add/move/remove and a step's own
    -- type dropdown rebuild the form immediately, so pending ID/Name edits
    -- must be flushed into d first or they get discarded by the rebuild.
    local function commitAndRebuild()
        if formHandle and formHandle.commitAll then formHandle.commitAll() end
        rebuild()
    end
    rebuild = function()
        local specs = _buildActionDialogSpecs(d, editId, readOnly, commitAndRebuild)
        specs[#specs+1] = { type = "divider", label = "" }
        if readOnly then
            specs[#specs+1] = { type = "button", label = "Close", _noReset = true,
                onClick = function() dlg:close() end }
        else
            specs[#specs+1] = { type = "button", style = "primary", _noReset = true,
                label = editId and "Save changes" or "Create action",
                onClick = function()
                    -- Force any not-yet-committed field edits into the draft first —
                    -- Save/Create is the only commit point this dialog needs.
                    if formHandle and formHandle.commitAll then formHandle.commitAll() end
                    local id = (editId or d.id or ""):gsub("%s+", "")
                    if id == "" then cecho("\n<red>[mux]<reset> Give the action an ID first.\n"); return end
                    if not editId and Mux.getAction and Mux.getAction(id) then
                        cecho("\n<red>[mux]<reset> An action with that ID already exists (including built-ins).\n"); return
                    end
                    Mux.createDeclarativeAction({ id = id, label = (d.label ~= "" and d.label or id), steps = d.steps })
                    dlg:close()
                    if onDone then onDone() end
                end }
            specs[#specs+1] = { type = "button", label = "Cancel", _noReset = true,
                onClick = function() dlg:close() end }
            if editId then
                specs[#specs+1] = { type = "divider", label = "" }
                specs[#specs+1] = { type = "button", style = "danger", label = "Delete this action", _noReset = true,
                    onClick = function()
                        if Mux.deleteDeclarativeAction then Mux.deleteDeclarativeAction(editId) end
                        dlg:close()
                        if onDone then onDone() end
                    end }
            end
        end
        formHandle = dlg:mountForm(specs, { prefix = dlg._gid .. "_aed", showReset = false, hideApply = true })
    end
    rebuild()
end

-- ── Actions panel (the Settings tab body) ──────────────────────────────────
-- A header action plus one unified list — user-created actions (clickable to
-- edit, with a delete icon) and built-ins (dimmed, no delete icon) together.
-- Clicking any row opens the same New/Edit dialog; built-ins open it
-- read-only. Mirrors buildConditionEditor's structure exactly.
local function buildActionEditor(target, bg)
  local ok, err = pcall(function()
    if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
    local function refresh() customRefresh(target) end

    -- User actions first (most actionable), built-ins after, in one list.
    local userActions, builtinActions = {}, {}
    if Mux.listActions then
        for _, a in ipairs(Mux.listActions()) do
            if Mux._declActions and Mux._declActions[a.id] then userActions[#userActions+1] = a
            elseif not a.hidden then builtinActions[#builtinActions+1] = a end
        end
    end
    local allActions = {}
    for _, a in ipairs(userActions)    do allActions[#allActions+1] = a end
    for _, a in ipairs(builtinActions) do allActions[#allActions+1] = a end

    local specs = {
        { type = "divider", label = "Actions run a sequence of steps — pick one in a rule's \"Do\"/\"Else\" dropdown." },
        { type = "button", style = "primary", label = "+ New Action", _noReset = true,
          onClick = function() openActionDialog(nil, refresh) end },
        { type = "divider", label = "Actions" },
    }
    if #allActions == 0 then
        specs[#specs+1] = { type = "divider", label = "— none yet — click \"+ New Action\" to add one —" }
    else
        for _, a in ipairs(allActions) do
            local aid = a.id
            local isBuiltin = not (Mux._declActions and Mux._declActions[aid])
            local subtitle
            if isBuiltin then
                subtitle = string.format("%s   ·   %s   ·   built-in", aid, a.group or "")
            else
                local n = #Mux._actionSteps(Mux._declActions[aid])
                subtitle = string.format("%s   ·   %d step%s", aid, n, n == 1 and "" or "s")
            end
            specs[#specs+1] = { type = "listRow", rowHeight = 44, dim = isBuiltin,
                title    = a.name or aid,
                subtitle = subtitle,
                accent   = isBuiltin and "rgba(140,145,165,140)" or "rgba(100,160,255,191)",
                onClick  = function() openActionDialog(aid, refresh, isBuiltin) end,
                onDelete = (not isBuiltin) and function()
                    if Mux.deleteDeclarativeAction then Mux.deleteDeclarativeAction(aid) end
                    refresh()
                end or nil,
                deleteTooltip = (not isBuiltin) and "Delete this action" or nil,
            }
        end
    end

    local scrollBox = Geyser.ScrollBox:new({ name = "mux_ae_sb", x = 0, y = 0, width = "100%", height = "100%" }, target.content)
    local cw = target.content:get_width(); if cw < 50 then cw = 400 end
    local totalH = Mux.ui.formHeight(specs, settingsFormOpts) + 2
    local contentLbl = Geyser.Label:new({ name = "mux_ae_cl", x = 0, y = 0, width = cw - 8, height = math.max(totalH, 10) }, scrollBox)
    contentLbl:setStyleSheet(string.format("background:%s; border:none;", bg))
    target._muxContentH = totalH
    local formHandle
    formHandle = Mux.ui.buildForm(contentLbl, specs, {
        width = cw - 8, prefix = "mxae",
        rowHeight = settingsFormOpts.rowHeight,
        widgetWidth = settingsFormOpts.widgetWidth, widgetHeight = settingsFormOpts.widgetHeight,
        showReset = false,
        onLayoutChange = function(h) target._muxContentH = h; Mux._scheduleFit(Mux._ownerDialog(target)) end,
        getContentScreenPos = function() return tabContentScreenPos(target) end,
        minParentHeight = function() return (target.content and target.content.get_height and target.content:get_height()) or 0 end,
    })
    target._settingsForm = formHandle
    target._muxRelayout  = formHandle and formHandle.relayout
  end)
  if not ok then Mux._err("buildActionEditor failed: %s", tostring(err)) end
end

-- ── Condition editor (Settings → Muxlet → Conditions) ─────────────────────────
-- Named conditions wrap a base type (the primitives in Mux.conditionTypes) plus
-- its parameters, and populate the rule "When" dropdown. The panel (below) shows
-- a compact, recognizable list of saved + built-in conditions; creating or
-- editing one happens in a focused popup (openConditionDialog) that only
-- persists when Save is clicked — Cancel discards the draft with no side effects.
-- Parameter rows come from each condition type's `fields` spec (conditional.lua),
-- so new types need no editor changes here.

-- Per-type accent colour for the list's left edge stripe — a quick visual cue
-- for what kind of signal a condition watches, at a glance. Alpha is 0-255
-- (Qt stylesheet rgba(), NOT CSS3's 0.0-1.0 — a fractional alpha fails to parse
-- and the widget falls back to Qt's default white background).
local _condTypeAccent = {
    always        = "rgba(140,145,165,140)",
    gmcp_exists   = "rgba(100,160,255,191)",
    gmcp_equals   = "rgba(100,160,255,191)",
    gmcp_contains = "rgba(100,160,255,191)",
    event_fired   = "rgba(210,180,70,191)",
    connected     = "rgba(80,180,80,191)",
    connecting    = "rgba(220,190,80,191)",
    disconnected  = "rgba(210,90,90,191)",
    line_match    = "rgba(90,200,190,191)",
}

local function _condTypeLabel(t)
    for _, entry in ipairs(Mux.conditionTypes) do
        if entry.value == t then return entry.label end
    end
    return t or "?"
end


-- ── New/Edit Condition dialog ──────────────────────────────────────────────────
-- A focused popup: identity + base type + type-specific parameters, with Save
-- (persists), Cancel (discards the draft), and — when editing — Delete. Nothing
-- is registered (Mux.registerCondition) until Save is clicked.
--
-- Built directly on d:mountForm (no Mux.registerContent/_applyContent) — matching
-- library/content/buttons.lua and library/content/capture.lua, the two existing
-- mountForm-based dialogs. _applyContent briefly swaps target.content for a slot
-- container sized to the dialog's PRE-fitContent geometry; mountForm's internal
-- ScrollBox is built against that stale small size and never catches up when
-- fitContent grows the outer frame afterward, leaving most of the dialog blank
-- (Qt's bare white showing through past the undersized content widget).
-- readOnly=true renders every field (including a built-in's fixed base type)
-- as plain text via the "readOnly" display, so a built-in condition can be
-- inspected in the exact same dialog without exposing any editable control.
local function _buildConditionDialogSpecs(d, editId, rebuild, readOnly)
    local specs = {}
    if editId then
        specs[#specs+1] = { label = "ID", type = "readOnly", readFn = function() return d.id end }
    else
        specs[#specs+1] = { label = "ID", type = "text", desc = "short unique id, e.g. in_combat",
            readFn = function() return d.id or "" end, writeFn = function(v) d.id = (v or ""):gsub("%s+", "") end }
    end
    if readOnly then
        specs[#specs+1] = { label = "Name", type = "readOnly", readFn = function() return d.label end }
        specs[#specs+1] = { label = "Base type", type = "readOnly", readFn = function() return _condTypeLabel(d.cond.type) end }
    else
        specs[#specs+1] = { label = "Name", type = "text", desc = "shown in the When dropdown",
            readFn = function() return d.label or "" end, writeFn = function(v) d.label = v end }
        specs[#specs+1] = { label = "Base type", type = "array", display = "dropdown",
            desc = "what kind of signal this watches", options = Mux.conditionTypes,
            readFn = function() return d.cond.type or "gmcp_exists" end,
            writeFn = function(t) d.cond = { type = t }; rebuild() end }
    end
    local prs = Mux._conditionParamRows(d.cond)
    if #prs > 0 then
        specs[#specs+1] = { type = "divider", label = "Parameters" }
        for _, r in ipairs(prs) do
            if readOnly then r.readOnly = true end
            specs[#specs+1] = r
        end
    end
    return specs
end

-- readOnly=true (built-ins) shows the same layout with a single Close button —
-- no Save/Cancel/Delete, since nothing here is editable.
local function openConditionDialog(editId, onDone, readOnly)
    local dlg = Mux.createDialog({
        title = readOnly and "Condition (built-in)" or (editId and "Edit Condition" or "New Condition"),
        width = 420, height = 260, resizable = true, contextMenu = false,
    })
    if not dlg then return end
    if dlg.contentBg then dlg.contentBg:echo(""); dlg.contentBg:hide() end

    local d
    if editId then
        -- Mux.getCondition covers both declarative and built-in entries alike.
        local s = Mux.getCondition and Mux.getCondition(editId)
        local cond = {}
        if s then for k, v in pairs(s.cond or {}) do cond[k] = v end end
        d = { id = editId, label = (s and s.label) or editId, cond = next(cond) and cond or { type = "gmcp_exists" } }
    else
        d = { id = "", label = "", cond = { type = "gmcp_exists" } }
    end

    local rebuild
    local formHandle
    -- Base type changes rebuild the whole form immediately (unlike text fields,
    -- which only commit on blur/Enter or Save). Without flushing first, an
    -- uncommitted ID/Name edit gets discarded by the rebuild before it ever
    -- reaches d, which looks like the boxes were blanked out.
    local function commitAndRebuild()
        if formHandle and formHandle.commitAll then formHandle.commitAll() end
        rebuild()
    end
    rebuild = function()
        local specs = _buildConditionDialogSpecs(d, editId, commitAndRebuild, readOnly)
        specs[#specs+1] = { type = "divider", label = "" }
        if readOnly then
            specs[#specs+1] = { type = "button", label = "Close", _noReset = true,
                onClick = function() dlg:close() end }
        else
            specs[#specs+1] = { type = "button", style = "primary", _noReset = true,
                label = editId and "Save changes" or "Create condition",
                onClick = function()
                    -- Force any not-yet-committed field edits (typed but not Enter'd/
                    -- Applied) into the draft before validating — Save/Create is the
                    -- only commit point users should need in a one-shot create/edit
                    -- dialog like this one.
                    if formHandle and formHandle.commitAll then formHandle.commitAll() end
                    local id = (editId or d.id or ""):gsub("%s+", "")
                    if id == "" then cecho("\n<red>[mux]<reset> Give the condition an ID first.\n"); return end
                    if not editId and Mux.getCondition and Mux.getCondition(id) then
                        cecho("\n<red>[mux]<reset> A condition with that ID already exists (including built-ins).\n"); return
                    end
                    Mux.createDeclarativeCondition({ id = id, label = (d.label ~= "" and d.label or id), cond = d.cond })
                    dlg:close()
                    if onDone then onDone() end
                end }
            specs[#specs+1] = { type = "button", label = "Cancel", _noReset = true,
                onClick = function() dlg:close() end }
            if editId then
                specs[#specs+1] = { type = "divider", label = "" }
                specs[#specs+1] = { type = "button", style = "danger", label = "Delete this condition", _noReset = true,
                    onClick = function()
                        if Mux.deleteDeclarativeCondition then Mux.deleteDeclarativeCondition(editId) end
                        dlg:close()
                        if onDone then onDone() end
                    end }
            end
        end
        -- hideApply: no per-field Apply button — typing plus Save/Create is the
        -- only commit path (commitAll() above forces the current text in on click).
        formHandle = dlg:mountForm(specs, { prefix = dlg._gid .. "_ced", showReset = false, hideApply = true })
    end
    rebuild()
end

-- ── Conditions panel (the Settings tab body) ───────────────────────────────────
-- A header action plus one unified list — user-created conditions (clickable to
-- edit, with a delete icon) and built-ins (dimmed, no delete icon) side by side.
-- Clicking any row opens the same New/Edit dialog; built-ins open it read-only.
local function buildConditionEditor(target, bg)
  local ok, err = pcall(function()
    if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
    local function refresh() customRefresh(target) end

    -- User conditions first (most actionable), built-ins after, in one list.
    local userConds, builtinConds = {}, {}
    for _, c in ipairs(Mux.listConditions and Mux.listConditions() or {}) do
        if c.readOnly then builtinConds[#builtinConds+1] = c else userConds[#userConds+1] = c end
    end
    local allConds = {}
    for _, c in ipairs(userConds)    do allConds[#allConds+1] = c end
    for _, c in ipairs(builtinConds) do allConds[#allConds+1] = c end

    -- Every row — header controls AND condition rows — is a real spec in this
    -- one list, so Mux.ui.buildForm's own relayout (collapse/expand, dialog
    -- auto-fit) accounts for all of it automatically, exactly like every other
    -- Settings tab. A previous version hand-rendered the list rows outside the
    -- spec system for a custom look; buildForm's relayout only ever knew about
    -- the header specs, so every resize/collapse silently clobbered it back
    -- down. listRow (widgets.lua) gives the same visual result as a normal spec.
    local specs = {
        { type = "divider", label = "Named conditions are reusable signals — pick one in a rule's \"When\" dropdown." },
        { type = "button", style = "primary", label = "+ New Condition", _noReset = true,
          onClick = function() openConditionDialog(nil, refresh) end },
        { type = "divider", label = "Conditions" },
    }
    if #allConds == 0 then
        specs[#specs+1] = { type = "divider", label = "— none yet — click \"+ New Condition\" to add one —" }
    else
        for _, c in ipairs(allConds) do
            local cid, isBuiltin = c.id, c.readOnly
            specs[#specs+1] = { type = "listRow", rowHeight = 44, dim = isBuiltin,
                title    = c.label,
                subtitle = string.format("%s   ·   %s%s", c.id, _condTypeLabel(c.cond and c.cond.type),
                    isBuiltin and "   ·   built-in" or ""),
                accent   = _condTypeAccent[c.cond and c.cond.type] or "rgba(140,145,165,128)",
                onClick  = function() openConditionDialog(cid, refresh, isBuiltin) end,
                onDelete = (not isBuiltin) and function()
                    if Mux.deleteDeclarativeCondition then Mux.deleteDeclarativeCondition(cid) end
                    refresh()
                end or nil,
                deleteTooltip = (not isBuiltin) and "Delete this condition" or nil,
            }
        end
    end

    local scrollBox = Geyser.ScrollBox:new({ name = "mux_ce_sb", x = 0, y = 0, width = "100%", height = "100%" }, target.content)
    local cw = target.content:get_width(); if cw < 50 then cw = 400 end
    local totalH = Mux.ui.formHeight(specs, settingsFormOpts) + 2
    local contentLbl = Geyser.Label:new({ name = "mux_ce_cl", x = 0, y = 0, width = cw - 8, height = math.max(totalH, 10) }, scrollBox)
    contentLbl:setStyleSheet(string.format("background:%s; border:none;", bg))
    target._muxContentH = totalH
    local formHandle = Mux.ui.buildForm(contentLbl, specs, {
        width = cw - 8, prefix = "mxce",
        rowHeight = settingsFormOpts.rowHeight,
        widgetWidth = settingsFormOpts.widgetWidth, widgetHeight = settingsFormOpts.widgetHeight,
        showReset = false,
        onLayoutChange = function(h) target._muxContentH = h; Mux._scheduleFit(Mux._ownerDialog(target)) end,
        getContentScreenPos = function() return tabContentScreenPos(target) end,
        minParentHeight = function() return (target.content and target.content.get_height and target.content:get_height()) or 0 end,
    })
    target._settingsForm = formHandle
    target._muxRelayout  = formHandle and formHandle.relayout
  end)
  if not ok then Mux._err("buildConditionEditor failed: %s", tostring(err)) end
end

-- ── Token editor (Settings → Design → Pane/Interface) ────────────────────────
-- Spec-driven editor for the global token overrides, filtered by group + kind so
-- it can back split Style (sizes) / Colors sub-tabs. target._settingsCustom looks
-- like "tok|Pane,Titlebar,Buttons|color". Each row shows the resolved (inherited
-- or overridden) value and writes a global override; reset reverts to the theme.
-- Wrapped so any error blanks this tab only and never breaks the dialog.
local function buildTokenEditor(target, bg)
    local ok, err = pcall(function()
        target.contentBg:hide()
        local groupsCsv, kind = target._settingsCustom:match("^tok|(.*)|(%a+)$")
        local want = {}
        for grp in (groupsCsv or ""):gmatch("[^,]+") do want[grp] = true end

        -- Collect rows for one kind ("size" or "color") across the wanted groups.
        local GROUP_LABELS = {
            Titlebar = "Titlebar", Buttons = "Buttons", Slot = "Empty Slot",
            Drag = "Pane Insertion Preview", Handle = "Embedded Pane Separator",
        }
        local function rowsForKind(k)
            local out = {}
            for _, grp in ipairs(Mux.tokens.specGroups) do
                if want[grp] then
                    for _, s in ipairs(Mux.tokens.spec) do
                        if s.group == grp and s.type == k then
                            local key = s.key
                            local label = s.label
                            if k == "color" and grp ~= "Pane" then
                                label = (GROUP_LABELS[grp] or grp) .. ": " .. label
                            end
                            local row = {
                                label = label, _tokenKey = key,
                                readFn  = function() return Mux.tok(key, nil) end,
                                writeFn = function(v) Mux.setGlobalToken(key, v) end,
                            }
                            if k == "size" then row.type, row.min, row.max = "number", s.min, s.max
                            else row.type = "color" end
                            out[#out+1] = row
                        end
                    end
                end
            end
            return out
        end

        local specs = {}
        local function addSection(label, rows, collapsed)
            if #rows == 0 then return end
            specs[#specs+1] = { type = "divider", label = label, _collapsed = collapsed }
            for _, r in ipairs(rows) do specs[#specs+1] = r end
        end
        if kind == "all" then
            addSection("Style",  rowsForKind("size"),  false)
            addSection("Colors", rowsForKind("color"), true)   -- colours start collapsed
        elseif kind == "size" or kind == "color" then
            -- single-kind: keep per-group dividers
            for _, grp in ipairs(Mux.tokens.specGroups) do
                if want[grp] then
                    local rows = {}
                    for _, s in ipairs(Mux.tokens.spec) do
                        if s.group == grp and s.type == kind then
                            local key = s.key
                            local row = {
                                label = s.label, _tokenKey = key,
                                readFn  = function() return Mux.tok(key, nil) end,
                                writeFn = function(v) Mux.setGlobalToken(key, v) end,
                            }
                            if kind == "size" then row.type, row.min, row.max = "number", s.min, s.max
                            else row.type = "color" end
                            rows[#rows+1] = row
                        end
                    end
                    addSection(grp, rows)
                end
            end
        end
        if #specs == 0 then return end

        local safe = target._settingsCustom:gsub("[^%w]", "_")
        local scrollBox = Geyser.ScrollBox:new({
            name = "mux_set_sb_" .. safe, x = 0, y = 0, width = "100%", height = "100%",
        }, target.content)
        local cw = target.content:get_width(); if cw < 50 then cw = 400 end
        local totalH = Mux.ui.formHeight(specs, settingsFormOpts) + 2
        local contentLbl = Geyser.Label:new({
            name = "mux_set_cl_" .. safe, x = 0, y = 0, width = cw - 8, height = math.max(totalH, 10),
        }, scrollBox)
        contentLbl:setStyleSheet(string.format("background:%s; border:none;", bg))
        target._muxContentH = totalH

        local formHandle
        formHandle = Mux.ui.buildForm(contentLbl, specs, {
            width = cw - 8, prefix = "mxs_" .. safe,
            rowHeight = settingsFormOpts.rowHeight,
            widgetWidth = settingsFormOpts.widgetWidth, widgetHeight = settingsFormOpts.widgetHeight,
            showReset = true,
            resetTooltip = "Revert to theme",
            onReset = function(i, spec)
                if spec._tokenKey then
                    Mux.clearGlobalToken(spec._tokenKey)
                    if formHandle then formHandle.refresh(i) end
                end
            end,
            onLayoutChange = function(h)
                target._muxContentH = h
                Mux._scheduleFit(Mux._ownerDialog(target))
            end,
            getContentScreenPos = function() return tabContentScreenPos(target) end,
            minParentHeight = function()
                return (target.content and target.content.get_height and target.content:get_height()) or 0
            end,
        })
        target._settingsForm = formHandle
        target._muxRelayout   = formHandle and formHandle.relayout
    end)
    if not ok then Mux._err("buildTokenEditor failed: %s", tostring(err)) end
end

-- Settings → Design → General: the theme picker plus the global "Interface" chrome
-- colours (context menu, ghosts, scrollbar) — folded in here so there's no separate
-- Interface tab. Picker rows don't get a reset icon; colour rows revert to theme.
local function buildThemeGeneral(target, bg)
    local ok, err = pcall(function()
        target.contentBg:hide()
        local formHandle   -- referenced by the reset button's onClick (assigned below)
        local specs = {}
        specs[#specs+1] = { type = "divider", label = "Theme" }
        -- Dropdown of every registered theme (not a static dark/light list).
        local themeNames = {}
        for name in pairs(Mux._themes or {}) do themeNames[#themeNames+1] = name end
        table.sort(themeNames)
        if #themeNames == 0 then themeNames = { "dark", "light" } end
        local themeOptions = {}
        for _, n in ipairs(themeNames) do themeOptions[#themeOptions+1] = { value = n, label = n } end
        specs[#specs+1] = {
            label = "Theme", type = "array", display = "dropdown", options = themeOptions, _noReset = true,
            readFn  = function() return Mux.settings.get("muxtheme", "active") end,
            writeFn = function(v) Mux.settings.set("muxtheme", "active", v) end,
        }
        specs[#specs+1] = {
            type = "button", label = "Reset all colors to theme", _noReset = true,
            desc = "Clear every global colour override so the selected theme shows through.",
            onClick = function()
                Mux.resetGlobalTokens()
                -- Refresh widgets on every settings tab, not just this form, so the
                -- Panes tab's colour pickers also snap back to the theme values.
                if Mux._settings_ui and Mux._settings_ui._refreshAllForms then
                    Mux._settings_ui._refreshAllForms()
                elseif formHandle then formHandle.refreshAll() end
            end,
        }
        -- Global "chrome" colours, one collapsible section per concept so each is
        -- self-explanatory rather than a single opaque "Interface" lump.
        local ifaceOrder  = { "Menu", "Scrollbar" }
        local ifaceLabels = {
            Menu = "Right-Click Menu", Scrollbar = "Scrollbar",
        }
        for _, grp in ipairs(ifaceOrder) do
            local rows = {}
            for _, s in ipairs(Mux.tokens.spec) do
                if s.group == grp and s.type == "color" then
                    local key = s.key
                    rows[#rows+1] = {
                        label = s.label, type = "color", _tokenKey = key,
                        readFn  = function() return Mux.tok(key, nil) end,
                        writeFn = function(v) Mux.setGlobalToken(key, v) end,
                    }
                end
            end
            if #rows > 0 then
                specs[#specs+1] = { type = "divider", label = ifaceLabels[grp] or grp, _collapsed = true }
                for _, r in ipairs(rows) do specs[#specs+1] = r end
            end
        end

        local scrollBox = Geyser.ScrollBox:new({
            name = "mux_set_sb_themegen", x = 0, y = 0, width = "100%", height = "100%",
        }, target.content)
        local cw = target.content:get_width(); if cw < 50 then cw = 400 end
        local totalH = Mux.ui.formHeight(specs, settingsFormOpts) + 2
        local contentLbl = Geyser.Label:new({
            name = "mux_set_cl_themegen", x = 0, y = 0, width = cw - 8, height = math.max(totalH, 10),
        }, scrollBox)
        contentLbl:setStyleSheet(string.format("background:%s; border:none;", bg))
        target._muxContentH = totalH

        local formHandle
        formHandle = Mux.ui.buildForm(contentLbl, specs, {
            width = cw - 8, prefix = "mxs_themegen",
            rowHeight = settingsFormOpts.rowHeight,
            widgetWidth = settingsFormOpts.widgetWidth, widgetHeight = settingsFormOpts.widgetHeight,
            showReset = true, resetTooltip = "Revert to theme",
            onReset = function(i, spec)
                if spec._tokenKey then
                    Mux.clearGlobalToken(spec._tokenKey)
                    if formHandle then formHandle.refresh(i) end
                end
            end,
            onLayoutChange = function(h)
                target._muxContentH = h
                Mux._scheduleFit(Mux._ownerDialog(target))
            end,
            getContentScreenPos = function() return tabContentScreenPos(target) end,
            minParentHeight = function()
                return (target.content and target.content.get_height and target.content:get_height()) or 0
            end,
        })
        target._settingsForm = formHandle
        target._muxRelayout   = formHandle and formHandle.relayout
    end)
    if not ok then Mux._err("buildThemeGeneral failed: %s", tostring(err)) end
end

local muxSettingsContentDef = {
    name     = "Settings",
    internal = true,
    apply = function(target)
        local theme = Mux.activeTheme() or {}
        local ui    = theme.ui or theme.settingsUi or {}
        local bg    = ui.bg or "rgb(18, 18, 26)"
        if target._settingsCustom == "actions" then
            local ok, err = pcall(buildActionEditor, target, bg)
            if not ok and Mux._warn then Mux._warn("actions manager failed: %s", tostring(err)) end
        elseif target._settingsCustom == "conditions" then
            local ok, err = pcall(buildConditionEditor, target, bg)
            if not ok and Mux._warn then Mux._warn("conditions manager failed: %s", tostring(err)) end
        elseif target._settingsCustom == "themegeneral" then
            buildThemeGeneral(target, bg)
        elseif target._settingsCustom and target._settingsCustom:match("^tok|") then
            buildTokenEditor(target, bg)
        elseif target._settingsNsList then
            buildMultiNsContent(target, target._settingsNsList, bg)
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
        elseif node.nsList then
            local chrome = 2*bi + titleH_pre + depth*tabH_pre + footerPad
            local allSpecs = {}
            for _, ns in ipairs(node.nsList) do
                allSpecs[#allSpecs+1] = { type = "divider" }
                for _, spec in ipairs(buildNsSpecs(ns)) do allSpecs[#allSpecs+1] = spec end
            end
            local needed = Mux.ui.formHeight(allSpecs, settingsFormOpts) + 2 + chrome
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
    Mux._fitDialog = pane   -- auto-fit height to the active tab as the user navigates
    pane.onClose = function()
        closeDropdown(); hideTooltip()
        settingsUi.visible = false
        settingsUi.window  = nil
        if Mux._fitDialog == pane then Mux._fitDialog = nil end
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
            if not mainP.titlebarVisible then reasons[#reasons+1] = "hidden titlebar" end
            if Mux.settings.get("mux", "showConsoleGear") == false then
                reasons[#reasons+1] = "hidden Settings gear"
            end
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
    pane.receivable = false   -- workspace tabs can't be dropped into the dialog
    pane._isDialogRoot = true -- per-dialog auto-fit resolves to this surface
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
        elseif node.nsList then
            tab._settingsNsList = node.nsList
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
    if tempTimer then tempTimer(0, function() pcall(Mux._fitDialogToActiveTab, pane) end) end
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

Mux.settings.register("muxtheme", "active", {
    tab         = "Muxlet/Design",
    label       = "Theme",
    description = "Active color theme",
    default     = "dark",
    choices     = {"dark", "light"},
})

Mux.settings.register("mux", "debug", {
    tab         = "Muxlet/General",   -- anchors the mux namespace to the General tab
    description = "Verbose debug logging to the console",
    default     = false,
})

Mux.settings.register("mux", "ghostDropText", {
    tab         = "Muxlet/General",
    label       = "Empty slot text",
    description = "Text shown inside an empty pane slot prompting a drop.",
    default     = "Drop a pane here",
})

Mux.settings.register("mux", "live_resize_max_panes", {
    description = "Live-resize panes while dragging a split handle only when the affected area holds at most this many panes; above it, drag a preview line and apply on release (instant regardless of pane count). Set high to always resize live, or 1 to always preview",
    default     = 2,
    min         = 1,
    max         = 99,
})

Mux.settings.register("mux", "resize_live_budget_ms", {
    description = "While dragging a resize, content whose relayout took longer than this many milliseconds is redrawn once at the end of the drag instead of every frame. Lower = more coalescing; raise to force more content to redraw live",
    default     = 8,
    min         = 1,
    max         = 200,
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

Mux.settings.onChange("muxtheme", "active", function(value)
    if Mux.applyTheme then Mux.applyTheme(value) end
    if Mux._restyleAllTabs then Mux._restyleAllTabs() end   -- restyle tabs on top of the new theme
    -- Rebuild the settings window so its widgets reflect the new theme. Deferred a
    -- tick so the originating click (e.g. the theme dropdown option) finishes before
    -- its host dialog is closed and rebuilt.
    if settingsUi.window then
        local wasVisible = settingsUi.visible
        local savedTab   = settingsUi.currentTab
        local function rebuild()
            if not settingsUi.window then return end
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
        if tempTimer then tempTimer(0, rebuild) else rebuild() end
    end
end)

Mux.settings.register("mux", "compact_titlebar", {
    tab         = "Muxlet/General",
    description = "Hide all titlebar buttons — use right-click menu instead",
    default     = false,
})

-- The ⚙ Settings gear on the Mudlet console pane. Lives here (not just in the
-- pane's Properties) so it is always recoverable: `mux settings` opens this dialog
-- even when the gear and titlebar are hidden, giving a guaranteed way back.
Mux.settings.register("mux", "showConsoleGear", {
    tab         = "Muxlet/General",
    description = "Show the ⚙ Settings gear on the Mudlet console pane",
    default     = true,
})
Mux.settings.onChange("mux", "showConsoleGear", function()
    if not Mux._panes then return end
    for _, p in pairs(Mux._panes) do
        if p._activeContent == "mux_console" and p._syncButtons then
            p:_syncButtons(true)
        end
    end
end)

-- Downstream packages (e.g. fed2-tools) set this to true in their muxletReady
-- handler to suppress the "Started — type mux help" message.
Mux.settings.register("mux", "quietStart", {
    tab         = "Muxlet/General",
    description = "Suppress the 'Started' message printed after mux start",
    default     = false,
})

-- Explicit display order for the Muxlet/General tab.  Registration order would
-- otherwise decide this; listing it here keeps the tab curated.  update_* are
-- registered later (update.lua) — pre-listing them positions them without
-- duplicating (register() skips keys already present in the order list).
Mux.settings._order["mux"] = {
    "welcome_shown",
    "auto_start",
    "quietStart",
    "compact_titlebar",
    "showConsoleGear",
    "confirmPaneClose",
    "confirmTabClose",
    "live_resize_max_panes",
    "resize_live_budget_ms",
    "reset_workspace",
    "update_check_enabled",
    "update_check_remind_skip",
    "theme",
    "debug",
}

Mux.settings.onChange("mux", "compact_titlebar", function()
    for _, pane in pairs(Mux._panes or {}) do
        if pane._syncButtons then pcall(function() pane:_syncButtons(true) end) end
    end
end)

Mux.settings.onChange("mux", "debug", function(value)
    Mux.debug = value
end)

-- Tabs use the same token element templates as panes (Mux.css "tab*"), edited
-- globally via Design > Tabs and per-tab via Properties; MuxSurface:_restyleTabBar
-- applies them.

-- tempTimer(0) defers past the synchronous script-loading stack so all Muxlet
-- functions are defined before this runs. raiseEvent("muxletReady") fires last
-- so downstream packages can register a handler and be guaranteed Muxlet's full
-- API is available when they receive it.

tempTimer(0, function()
    -- content.lua is loaded by now, so the content registry exists.
    if Mux.registerContent then
        Mux.registerContent("mux_settings", muxSettingsContentDef)
    end
    local savedTheme = Mux.settings.get("muxtheme", "active") or Mux.settings.get("mux", "theme")
    if savedTheme and Mux.applyTheme and savedTheme ~= Mux._activeThemeName then
        Mux.applyTheme(savedTheme)
    end
    Mux.debug = Mux.settings.get("mux", "debug")
    Mux._ready = true
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