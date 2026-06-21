-- Muxlet — Button Grid content
--
-- A registered, user-addable content type: a configurable grid of buttons.  Each
-- button runs either a raw command string (send/expandAlias) or a registered
-- action (Mux.runAction).  Users add the content to a pane, enter edit mode to
-- add/configure buttons, then leave edit mode to use them.
--
-- PHASE 1 (this build): view mode, an edit mode with a per-button property editor
-- (label, colours, font, width, and action binding via a picker of registered
-- actions OR a raw command), grid settings (columns/gap/row height), and
-- per-instance persistence.  Layout is auto-flow: buttons fill left-to-right,
-- wrapping by column count, each spanning `width` columns.
-- PHASE 2 (next): drag-to-place / drag-to-span grid-snap editing.
--
-- PERSISTENCE: each grid's config is keyed by the host pane id in
-- Muxlet_persistent/mux_buttongrids.json.  A pane's id is stable once the
-- workspace is saved (the "lock it in place" step), so saved layouts round-trip
-- across reloads.  Config is written immediately on every edit.

local STATE_BY_TARGET = {}                                  -- target.id -> { editing, widgets, gen }
local STORE_FILE      = Mux._persistentDir .. "/mux_buttongrids.json"
local STORE           = nil                                 -- paneId -> config (lazy-loaded)

local DEFAULT_ROW_H = 44

-- ── Persistence ───────────────────────────────────────────────────────────────

local function loadStore()
    if STORE then return STORE end
    STORE = {}
    if io.exists(STORE_FILE) then
        local ok = pcall(function()
            local f = io.open(STORE_FILE, "r"); local raw = f:read("*all"); f:close()
            local data = yajl.to_value(raw)
            if type(data) == "table" then STORE = data end
        end)
        if not ok and Mux._err then Mux._err("button store load failed") end
    end
    return STORE
end

local function saveStore()
    loadStore()
    local ok, err = pcall(function()
        local f = io.open(STORE_FILE, "w"); f:write(yajl.to_string(STORE)); f:close()
    end)
    if not ok and Mux._err then Mux._err("button store save failed: %s", tostring(err)) end
end

local function defaultConfig()
    return {
        cols = 2, gap = 5, rowH = DEFAULT_ROW_H,
        buttons = {
            { label = "Edit me", width = 2, bg = "#1c2a4e", fg = "#96c8ff", fontSize = 12,
              action = { type = "command", text = "" } },
        },
    }
end

local function configFor(paneId)
    local store = loadStore()
    if not store[paneId] then store[paneId] = defaultConfig() end
    local c = store[paneId]
    c.cols    = c.cols    or 2
    c.gap     = c.gap     or 5
    c.rowH    = c.rowH    or DEFAULT_ROW_H
    c.buttons = c.buttons or {}
    return c
end

-- ── Layout (auto-flow) ──────────────────────────────────────────────────────────

local function layoutRects(cfg, W)
    local cols  = math.max(1, cfg.cols)
    local gap   = cfg.gap
    local rowH  = cfg.rowH
    local cellW = (W - gap * (cols + 1)) / cols
    if cellW < 1 then cellW = 1 end
    local rects, r, c = {}, 0, 0
    for i, btn in ipairs(cfg.buttons) do
        local span = math.max(1, math.min(btn.width or 1, cols))
        if c + span > cols then r = r + 1; c = 0 end
        rects[#rects + 1] = {
            index = i, btn = btn,
            x = math.floor(gap + c * (cellW + gap)),
            y = gap + r * (rowH + gap),
            w = math.floor(span * cellW + (span - 1) * gap),
            h = rowH,
        }
        c = c + span
        if c >= cols then r = r + 1; c = 0 end
    end
    local rowsUsed = r + (c > 0 and 1 or 0)
    local totalH   = gap + rowsUsed * (rowH + gap)
    return rects, totalH
end

-- ── Button appearance / behaviour ────────────────────────────────────────────────

local function buttonCss(btn, editing)
    local bg = btn.bg or "#1c2a4e"
    local fg = btn.fg or "#96c8ff"
    local border = editing and "border:1px dashed rgba(255,210,90,0.9);"
                            or "border:1px solid rgba(255,255,255,0.10);"
    return string.format([[
        QLabel { background:%s; color:%s; %s border-radius:5px;
                 font-size:%dpx; font-weight:bold; qproperty-alignment:AlignCenter;
                 font-family:"Segoe UI","Helvetica",sans-serif; }
        QLabel::hover { background:%s; }
    ]], bg, fg, border, btn.fontSize or 12, bg)
end

local function runButton(btn, target)
    local a = btn.action or {}
    if a.type == "action" and a.actionId then
        Mux.runAction(a.actionId, { target = target, source = "button" })
    elseif a.type == "command" and a.text and a.text ~= "" then
        expandAlias(a.text, false)
    end
end

-- ── Render ───────────────────────────────────────────────────────────────────────

local clearWidgets, render, openButtonEditor, openGridSettings   -- forward decls

clearWidgets = function(st)
    for _, w in ipairs(st.widgets or {}) do
        if w then if w.delete then w:delete() else w:hide() end end
    end
    st.widgets = {}
end

render = function(target)
    local st  = STATE_BY_TARGET[target.id]
    if not st then return end
    local cfg = configFor(target.id)
    local C   = target.content
    local g   = target._gid
    local W   = C:get_width(); if W < 50 then W = 300 end
    clearWidgets(st)
    st.gen = (st.gen or 0) + 1
    local gen = st.gen

    local rects = layoutRects(cfg, W)
    for _, rc in ipairs(rects) do
        local btn = rc.btn
        local lbl = Geyser.Label:new({ name = string.format("%s_bg%d_%d", g, gen, rc.index),
            x = rc.x, y = rc.y, width = rc.w, height = rc.h }, C)
        lbl:setStyleSheet(buttonCss(btn, st.editing))
        lbl:echo("<center>" .. (btn.label or "") .. "</center>")
        local idx = rc.index
        if st.editing then
            lbl:setToolTip("Click to edit this button")
            lbl:setClickCallback(function() openButtonEditor(target, idx) end)
        else
            local b = btn
            lbl:setClickCallback(function() runButton(b, target) end)
            local a = btn.action or {}
            if a.type == "command" and a.text and a.text ~= "" then lbl:setToolTip(a.text)
            elseif a.type == "action" and a.actionId then
                local def = Mux.getAction(a.actionId)
                lbl:setToolTip(def and def.name or a.actionId)
            end
        end
        st.widgets[#st.widgets + 1] = lbl
    end

    -- Edit-mode toggle (always present, top-right corner).
    local gear = Geyser.Label:new({ name = g .. "_bgear_" .. gen, x = "-26", y = 2, width = 22, height = 22 }, C)
    gear:setStyleSheet(st.editing
        and [[QLabel{background:rgba(255,210,90,0.92);color:#222;border-radius:4px;qproperty-alignment:AlignCenter;font-size:13px;}]]
        or  [[QLabel{background:rgba(40,44,60,0.7);color:rgba(200,205,225,0.9);border-radius:4px;qproperty-alignment:AlignCenter;font-size:13px;}QLabel::hover{background:rgba(60,66,88,0.9);}]])
    gear:echo("<center>⚙</center>")
    gear:setToolTip(st.editing and "Exit edit mode" or "Edit buttons")
    gear:setClickCallback(function()
        st.editing = not st.editing
        render(target)
    end)
    st.widgets[#st.widgets + 1] = gear

    if st.editing then
        local _, usedH = layoutRects(cfg, W)
        local by = usedH + 4
        local add = Geyser.Label:new({ name = g .. "_badd_" .. gen, x = cfg.gap, y = by, width = 120, height = 26 }, C)
        add:setStyleSheet([[QLabel{background:rgba(40,90,50,0.9);color:#cfe;border:1px solid rgba(90,170,110,0.6);
            border-radius:4px;qproperty-alignment:AlignCenter;font-size:11px;}QLabel::hover{background:rgba(55,115,65,0.95);}]])
        add:echo("<center>＋ Add Button</center>")
        add:setClickCallback(function()
            cfg.buttons[#cfg.buttons + 1] = { label = "Button", width = 1, bg = "#1c2a4e", fg = "#96c8ff",
                fontSize = 12, action = { type = "command", text = "" } }
            saveStore()
            render(target)
            openButtonEditor(target, #cfg.buttons)
        end)
        st.widgets[#st.widgets + 1] = add

        local gset = Geyser.Label:new({ name = g .. "_bgset_" .. gen, x = cfg.gap + 128, y = by, width = 120, height = 26 }, C)
        gset:setStyleSheet([[QLabel{background:rgba(40,50,80,0.9);color:#cde;border:1px solid rgba(90,110,170,0.6);
            border-radius:4px;qproperty-alignment:AlignCenter;font-size:11px;}QLabel::hover{background:rgba(55,68,110,0.95);}]])
        gset:echo("<center>⚙ Grid Settings</center>")
        gset:setClickCallback(function() openGridSettings(target) end)
        st.widgets[#st.widgets + 1] = gset
    end
end

-- ── Editors (dialogs) ─────────────────────────────────────────────────────────────

openButtonEditor = function(target, idx)
    local cfg = configFor(target.id)
    local btn = cfg.buttons[idx]
    if not btn then return end
    btn.action = btn.action or { type = "command", text = "" }

    local key = "mux_btn_editor_" .. target.id
    local d = Mux.createDialog({ title = "Edit Button", width = 380, height = 430, singleton = key, contextMenu = false })
    if not d then return end
    if d.contentBg then d.contentBg:echo(""); d.contentBg:hide() end

    -- Action options: registered actions, presented as "[group] name".
    local actionOpts = { { value = "", label = "— pick an action —" } }
    for _, a in ipairs(Mux.listActions()) do
        actionOpts[#actionOpts + 1] = { value = a.id, label = string.format("[%s] %s", a.group, a.name) }
    end

    local function persist() saveStore(); render(target) end

    local rows = {
        { label = "Label", type = "text",
          readFn = function() return btn.label or "" end,
          writeFn = function(v) btn.label = v; persist() end },
        { label = "Action Type", type = "segmentedControl",
          options = { { value = "command", label = "Command" }, { value = "action", label = "Action" } },
          readFn = function() return btn.action.type or "command" end,
          writeFn = function(v) btn.action.type = v; persist() end },
        { label = "Command", type = "text", desc = "Sent as if typed (used when Action Type = Command)",
          readFn = function() return btn.action.text or "" end,
          writeFn = function(v) btn.action.text = v; persist() end },
        { label = "Action", type = "choiceCycler", desc = "Registered action (used when Action Type = Action)",
          options = actionOpts, widgetWidth = 200,
          readFn = function() return btn.action.actionId or "" end,
          writeFn = function(v) btn.action.actionId = (v ~= "" and v or nil); persist() end },
        { label = "Width (columns)", type = "number", min = 1, max = 8,
          readFn = function() return btn.width or 1 end,
          writeFn = function(v) btn.width = v; persist() end },
        { label = "Font Size", type = "number", min = 6, max = 32,
          readFn = function() return btn.fontSize or 12 end,
          writeFn = function(v) btn.fontSize = v; persist() end },
        { label = "Background", type = "text", desc = "CSS colour, e.g. #1c2a4e",
          readFn = function() return btn.bg or "#1c2a4e" end,
          writeFn = function(v) btn.bg = v; persist() end },
        { label = "Text Colour", type = "text", desc = "CSS colour, e.g. #96c8ff",
          readFn = function() return btn.fg or "#96c8ff" end,
          writeFn = function(v) btn.fg = v; persist() end },
    }

    local cw = d.content:get_width(); if cw < 50 then cw = 376 end
    local formH = Mux.ui.formHeight(rows)
    local form = Geyser.Label:new({ name = d._gid .. "_be_form", x = 0, y = 0, width = cw, height = formH }, d.content)
    form:setStyleSheet("background:rgba(18,18,26,1);border:none;")
    Mux.ui.buildForm(form, rows, { width = cw, prefix = d._gid .. "_be" })

    local del = Geyser.Label:new({ name = d._gid .. "_be_del", x = 8, y = "-32", width = 100, height = 26 }, d.content)
    del:setStyleSheet([[QLabel{background:rgba(120,40,40,0.9);color:#fdd;border:1px solid rgba(180,80,80,0.6);
        border-radius:4px;qproperty-alignment:AlignCenter;font-size:11px;}QLabel::hover{background:rgba(150,55,55,0.95);}]])
    del:echo("<center>🗑 Delete</center>")
    del:setClickCallback(function()
        table.remove(cfg.buttons, idx)
        saveStore(); render(target); d:close()
    end)

    local done = Geyser.Label:new({ name = d._gid .. "_be_done", x = "-108", y = "-32", width = 100, height = 26 }, d.content)
    done:setStyleSheet([[QLabel{background:rgba(40,90,50,0.9);color:#cfe;border:1px solid rgba(90,170,110,0.6);
        border-radius:4px;qproperty-alignment:AlignCenter;font-size:11px;}QLabel::hover{background:rgba(55,115,65,0.95);}]])
    done:echo("<center>Done</center>")
    done:setClickCallback(function() d:close() end)
end

openGridSettings = function(target)
    local cfg = configFor(target.id)
    local key = "mux_grid_settings_" .. target.id
    local d = Mux.createDialog({ title = "Grid Settings", width = 360, height = 200, singleton = key, contextMenu = false })
    if not d then return end
    if d.contentBg then d.contentBg:echo(""); d.contentBg:hide() end

    local function persist() saveStore(); render(target) end
    local rows = {
        { label = "Columns", type = "number", min = 1, max = 8,
          readFn = function() return cfg.cols end,  writeFn = function(v) cfg.cols = v; persist() end },
        { label = "Gap (px)", type = "number", min = 0, max = 24,
          readFn = function() return cfg.gap end,   writeFn = function(v) cfg.gap = v; persist() end },
        { label = "Row Height (px)", type = "number", min = 20, max = 120, step = 2,
          readFn = function() return cfg.rowH end,  writeFn = function(v) cfg.rowH = v; persist() end },
    }
    local cw = d.content:get_width(); if cw < 50 then cw = 356 end
    local form = Geyser.Label:new({ name = d._gid .. "_gs_form", x = 0, y = 0, width = cw, height = Mux.ui.formHeight(rows) }, d.content)
    form:setStyleSheet("background:rgba(18,18,26,1);border:none;")
    Mux.ui.buildForm(form, rows, { width = cw, prefix = d._gid .. "_gs" })
end

-- ── Content registration ──────────────────────────────────────────────────────────

Mux.registerContent("mux_buttons", {
    name        = "Button Grid",
    description = "A configurable grid of buttons bound to commands or registered actions",
    singleton   = false,
    apply = function(target)
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        STATE_BY_TARGET[target.id] = STATE_BY_TARGET[target.id] or { editing = false, widgets = {}, gen = 0 }
        -- Defer so target.content has its final width before we size buttons.
        tempTimer(0.05, function() render(target) end)
    end,
    remove = function(target)
        local st = STATE_BY_TARGET[target.id]
        if st then clearWidgets(st) end
        STATE_BY_TARGET[target.id] = nil
    end,
})

if Mux._log then Mux._log("button grid content loaded") end