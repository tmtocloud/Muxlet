-- Muxlet — Button Grid content
--
-- A registered, user-addable content type: a configurable grid of buttons.  Each
-- button runs a raw command string (expandAlias) or a registered action
-- (Mux.runAction).  Add it to a pane, click ⚙ to edit, configure buttons, click
-- ⚙ again to use them.  Config persists through Muxlet's content serialize/restore
-- hook, so each grid travels inside the workspace that owns its pane.
--
-- Layout is auto-flow: buttons fill left-to-right, wrapping by column count, each
-- spanning `width` columns.  Independent horizontal/vertical gaps.  Buttons
-- reflow to fit their container on resize.

local STATE_BY_TARGET = {}
local CONFIG          = {}     -- per-pane config (by pane id); persisted via the workspace
local DEFAULT_ROW_H   = 44
local MIN_ROW_H       = 18    -- floor when filling vertically

-- ── Persistence ───────────────────────────────────────────────────────────────
-- No side file: config lives in memory and is persisted through the content
-- serialize/restore hook (see the registration block below).  Mutations call
-- scheduleSave() to debounce a workspace autosave.

local function scheduleSave()
    if Mux._scheduleAutoSave then Mux._scheduleAutoSave() end
end

local function defaultConfig()
    return {
        cols = 1, gapX = 5, gapY = 5, rowH = DEFAULT_ROW_H, vsizing = "fill",
        buttons = {
            { label = "Hello World", width = 1, bg = "#1c2a4e", fg = "#96c8ff", fontSize = 12,
              shape = "rounded", action = { type = "command", text = "Hello World" } },
        },
    }
end

local function configFor(paneId)
    local c = CONFIG[paneId]
    if not c then c = defaultConfig(); CONFIG[paneId] = c end
    c.cols = c.cols or 1
    if c.gap and not c.gapX then c.gapX = c.gap; c.gapY = c.gap end
    c.gapX = c.gapX or 5
    c.gapY = c.gapY or 5
    c.rowH = c.rowH or DEFAULT_ROW_H
    c.vsizing = c.vsizing or "fill"
    c.buttons = c.buttons or {}
    return c
end

-- ── Layout (auto-flow) ──────────────────────────────────────────────────────────

local function layoutRects(cfg, W, H, editing)
    local cols = math.max(1, cfg.cols)
    local gapX, gapY = cfg.gapX, cfg.gapY
    -- Pass 1: assign each button a grid cell (col/row/span) — independent of rowH.
    local cells, r, c = {}, 0, 0
    for i, btn in ipairs(cfg.buttons) do
        local span = math.max(1, math.min(btn.width or 1, cols))
        if c + span > cols then r = r + 1; c = 0 end
        cells[#cells + 1] = { index = i, btn = btn, col = c, row = r, span = span }
        c = c + span
        if c >= cols then r = r + 1; c = 0 end
    end
    local rowsUsed = math.max(1, r + (c > 0 and 1 or 0))
    -- Vertical sizing: "fill" derives row height from the container (mirrors how
    -- columns fill width); "fixed" keeps the configured rowH.
    local rowH
    if cfg.vsizing == "fixed" then
        rowH = cfg.rowH or DEFAULT_ROW_H
    else
        local availH = (H or 0)
        rowH = math.floor((availH - gapY * (rowsUsed + 1)) / rowsUsed)
        if rowH < MIN_ROW_H then rowH = MIN_ROW_H end
    end
    local cellW = (W - gapX * (cols + 1)) / cols
    if cellW < 1 then cellW = 1 end
    local rects = {}
    for _, cell in ipairs(cells) do
        rects[#rects + 1] = {
            index = cell.index, btn = cell.btn,
            x = math.floor(gapX + cell.col * (cellW + gapX)),
            y = math.floor(gapY + cell.row * (rowH + gapY)),
            w = math.floor(cell.span * cellW + (cell.span - 1) * gapX),
            h = rowH,
        }
    end
    return rects, gapY + rowsUsed * (rowH + gapY), rowsUsed
end

-- ── Button appearance / behaviour ────────────────────────────────────────────────

local function buttonCss(btn, editing, w, h)
    local bg = btn.bg or "#1c2a4e"
    local fg = btn.fg or "#96c8ff"
    local shape = btn.shape or "rounded"
    local radius
    if shape == "square" then
        radius = 0
    elseif shape == "pill" or shape == "circle" then
        -- Half the shorter side gives true capsule ends (and a full circle when the
        -- cell is square, as the circle shape forces). A fixed huge radius like 999
        -- is what rendered square: Qt ignores an un-clampable radius instead of
        -- capping it, so the corners stayed sharp.
        radius = math.floor(math.min(w or 0, h or 0) / 2)
    else
        radius = 6  -- rounded
    end
    local border = editing and "border:1px dashed rgba(255,210,90,0.9);"
                            or "border:1px solid rgba(255,255,255,0.10);"
    return string.format([[
        QLabel { background:%s; color:%s; %s border-radius:%dpx;
                 font-size:%dpx; font-weight:bold; qproperty-alignment:AlignCenter;
                 font-family:"Segoe UI","Helvetica",sans-serif; }
        QLabel::hover { background:%s; }
    ]], bg, fg, border, radius, btn.fontSize or 12, bg)
end

local function runButton(btn)
    local a = btn.action or {}
    if a.type == "action" and a.actionId then
        Mux.runAction(a.actionId, { source = "button" })
    elseif a.type == "command" and a.text and a.text ~= "" then
        expandAlias(a.text)
    end
end

-- ── Render ───────────────────────────────────────────────────────────────────────

local clearWidgets, render, openButtonEditor, openGridSettings

clearWidgets = function(st)
    for _, w in ipairs(st.widgets or {}) do
        if w then if w.delete then w:delete() else w:hide() end end
    end
    st.widgets = {}
end

render = function(target)
    local st = STATE_BY_TARGET[target.id]
    if not st then return end
    local C = target.content
    if not (C and C.get_width) then return end
    local cfg = configFor(target.id)
    local g   = target._gid
    local W   = C:get_width();  if W < 50 then W = 300 end
    local H   = C:get_height(); if H < 30 then H = 120 end
    clearWidgets(st)
    st.gen = (st.gen or 0) + 1
    local gen = st.gen

    -- Locked grids never enter edit mode: the gear/edit chrome is hidden and the
    -- buttons simply run. Unlock with `mux reveal <pane id>` (content onReveal hook).
    local editing = st.editing and not cfg.locked
    local rects = layoutRects(cfg, W, H, editing)
    for _, rc in ipairs(rects) do
        local btn = rc.btn
        local lx, ly, lw, lh = rc.x, rc.y, rc.w, rc.h
        if btn.shape == "circle" then
            -- Centre a square inside the cell so the half-side radius is a true circle.
            local side = math.min(rc.w, rc.h)
            lx = rc.x + math.floor((rc.w - side) / 2)
            ly = rc.y + math.floor((rc.h - side) / 2)
            lw, lh = side, side
        end
        local lbl = Geyser.Label:new({ name = string.format("%s_bg%d_%d", g, gen, rc.index),
            x = lx, y = ly, width = lw, height = lh }, C)
        -- The button currently open in the editor previews in its final style so
        -- the user sees exactly what it will look like; the rest keep the edit border.
        local isEdited = editing and st.editingIdx == rc.index
        lbl:setStyleSheet(buttonCss(btn, editing and not isEdited, lw, lh))
        lbl:echo(string.format('<center><span style="color:%s;font-size:%dpx;font-weight:bold;">%s</span></center>',
            btn.fg or "#96c8ff", btn.fontSize or 12, btn.label or ""))
        local idx = rc.index
        if editing then
            lbl:setToolTip("Click to edit this button")
            lbl:setClickCallback(function() openButtonEditor(target, idx) end)
        else
            local b = btn
            lbl:setClickCallback(function() runButton(b) end)
            local a = btn.action or {}
            if a.type == "command" and a.text and a.text ~= "" then lbl:setToolTip(a.text)
            elseif a.type == "action" and a.actionId then
                local def = Mux.getAction(a.actionId)
                lbl:setToolTip(def and def.name or a.actionId)
            end
        end
        st.widgets[#st.widgets + 1] = lbl
    end

    -- Edit affordances live on the titlebar, not the content: the wrench toggles
    -- edit mode and fans out Add + Grid-Settings as a titlebar cascade (see the
    -- content's titlebarElements). Grid buttons themselves become editable while
    -- st.editing is on.

    -- Re-creating the button labels above puts them at the top of the local
    -- stacking order, which would cover an open editor / grid-settings dialog
    -- (those re-render on every live-preview keystroke).  Re-assert dialog z-order
    -- so dialogs always draw above the grid they are editing.
    if Mux.raiseFloatingPanes then Mux.raiseFloatingPanes() end
    -- raiseFloatingPanes lifts pane frames back above the titlebar edit cascade;
    -- re-raise it so titlebar-spawned content stays above pane/tab content.
    local st2 = STATE_BY_TARGET[target.id]
    if st2 and st2.editCascade then st2.editCascade:raise() end
end

-- ── Button editor (dialog) ────────────────────────────────────────────────────────
-- Live preview on every change (no disk write); persisted on Done / close.
-- Action is a dropdown with hover descriptions; text fields have no per-field
-- Apply button (Enter commits, Done saves).  Dialog sizes to fit — no scrolling.

openButtonEditor = function(target, idx)
    local cfg = configFor(target.id)
    local btn = cfg.buttons[idx]
    if not btn then return end
    btn.action = btn.action or { type = "command", text = "" }
    local snapshot = yajl.to_value(yajl.to_string(btn))   -- deep copy; ✕ reverts to this
    local function clearEdit()
        local s = STATE_BY_TARGET[target.id]; if s then s.editingIdx = nil end
    end
    do
        local s = STATE_BY_TARGET[target.id]
        if s then s.editingIdx = idx; render(target) end   -- preview this one in its final look
    end

    local W   = 400
    local BAR = 40
    local key = "mux_btn_editor_" .. target.id
    local d = Mux.createDialog({ title = "Edit Button — " .. Mux._targetPath(target), width = W, height = 480, singleton = key, contextMenu = false })
    if not d then return end
    if d.contentBg then d.contentBg:echo(""); d.contentBg:hide() end

    local cw = d.content:get_width(); if cw < 50 then cw = W end
    local function getContentPos() return d.content:get_x(), d.content:get_y() end
    local function preview() render(target) end   -- live, no save (item 5)

    local function actionOptions()
        local opts = { { value = "", label = "— pick an action —", desc = "No action bound." } }
        for _, a in ipairs(Mux.listActions()) do
            opts[#opts + 1] = { value = a.id, label = string.format("[%s] %s", a.group, a.name), desc = a.desc }
        end
        return opts
    end

    local function buildRows()
        local rows = {
            { label = "Label", type = "text",
              readFn = function() return btn.label or "" end,
              writeFn = function(v) btn.label = v; preview() end },
            { label = "Action Type", type = "segmentedControl",
              options = { { value = "command", label = "Command" }, { value = "action", label = "Action" } },
              readFn = function() return btn.action.type or "command" end,
              writeFn = function(v) btn.action.type = v; preview(); d._beRebuild() end },
        }
        if (btn.action.type or "command") == "command" then
            rows[#rows + 1] = { label = "Command", type = "text",
                desc = "Sent as if typed (and echoed to the console). Press Enter to apply.",
                readFn = function() return btn.action.text or "" end,
                writeFn = function(v) btn.action.text = v; preview() end }
        else
            rows[#rows + 1] = { label = "Action", type = "array", display = "dropdown",
                desc = "Runs a registered action. Hover an option for what it does. Packages "
                    .. "register actions (e.g. fed2-tools' Open Galaxy); see Mux.registerAction.",
                options = actionOptions(),
                readFn = function() return btn.action.actionId or "" end,
                writeFn = function(v) btn.action.actionId = (v ~= "" and v or nil); preview() end }
        end
        rows[#rows + 1] = { label = "Shape", type = "segmentedControl", widgetWidth = 240,
            options = { { value = "square", label = "Square" }, { value = "rounded", label = "Rounded" }, { value = "pill", label = "Pill" }, { value = "circle", label = "Circle" } },
            readFn = function() return btn.shape or "rounded" end,
            writeFn = function(v) btn.shape = v; preview() end }
        rows[#rows + 1] = { label = "Width (columns)", type = "number", min = 1, max = math.max(1, cfg.cols),
            readFn = function() return btn.width or 1 end,
            writeFn = function(v) btn.width = v; preview() end }
        rows[#rows + 1] = { label = "Font Size", type = "number", min = 6, max = 32,
            readFn = function() return btn.fontSize or 12 end,
            writeFn = function(v) btn.fontSize = v; preview() end }
        rows[#rows + 1] = { label = "Background", type = "color", desc = "Button background colour",
            readFn = function() return btn.bg or "#1c2a4e" end,
            writeFn = function(v) btn.bg = v; preview() end }
        rows[#rows + 1] = { label = "Text Colour", type = "color", desc = "Button text colour",
            readFn = function() return btn.fg or "#96c8ff" end,
            writeFn = function(v) btn.fg = v; preview() end }
        return rows
    end

    local function fitDialog(formH)
        local contentH = formH + BAR
        d.floatH = contentH + 30                      -- + titlebar allowance
        if d.outer then d.outer:resize(d.floatW or W, d.floatH) end
    end

    local formGen, formHost = 0, nil
    d._beRebuild = function()
        if formHost then if formHost.delete then formHost:delete() else formHost:hide() end end
        formGen = formGen + 1
        local rows = buildRows()
        local fh   = Mux.ui.formHeight(rows)
        formHost = Geyser.Label:new({ name = d._gid .. "_be_form" .. formGen, x = 0, y = 0, width = cw, height = fh }, d.content)
        formHost:setStyleSheet("background:rgba(18,18,26,1);border:none;")
        d._beForm = Mux.ui.buildForm(formHost, rows, {
            width = cw, prefix = d._gid .. "_be" .. formGen,
            hideApply = true, getContentScreenPos = getContentPos,
        })
        fitDialog(fh)
    end
    d._beRebuild()

    -- Fixed bottom bar (anchored to dialog bottom).
    local bar = Geyser.Label:new({ name = d._gid .. "_be_bar", x = 0, y = "-40", width = "100%", height = BAR }, d.content)
    bar:setStyleSheet("background:rgba(14,15,22,1);border:none;border-top:1px solid rgba(255,255,255,0.08);")
    local del = Geyser.Label:new({ name = d._gid .. "_be_del", x = 8, y = 7, width = 80, height = 26 }, bar)
    del:setStyleSheet([[QLabel{background:rgba(120,40,40,0.9);color:#fdd;border:1px solid rgba(180,80,80,0.6);
        border-radius:4px;qproperty-alignment:AlignCenter;font-size:11px;}QLabel::hover{background:rgba(150,55,55,0.95);}]])
    del:echo("<center>🗑 Delete</center>")
    del:setClickCallback(function() table.remove(cfg.buttons, idx); clearEdit(); scheduleSave(); render(target); d.onClose = nil; Mux.ui.closeColorWheel(); d:close() end)

    local test = Geyser.Label:new({ name = d._gid .. "_be_test", x = 94, y = 7, width = 70, height = 26 }, bar)
    test:setStyleSheet([[QLabel{background:rgba(40,50,80,0.9);color:#cde;border:1px solid rgba(90,110,170,0.6);
        border-radius:4px;qproperty-alignment:AlignCenter;font-size:11px;}QLabel::hover{background:rgba(55,68,110,0.95);}]])
    test:echo("<center>▶ Test</center>")
    test:setToolTip("Run this button's action now, using the current values above "
        .. "(the grid is in edit mode, so clicking the real button won't fire it)")
    test:setClickCallback(function()
        if d._beForm and d._beForm.commitAll then d._beForm.commitAll() end
        runButton(btn)
    end)

    local done = Geyser.Label:new({ name = d._gid .. "_be_done", x = "-88", y = 7, width = 80, height = 26 }, bar)
    done:setStyleSheet([[QLabel{background:rgba(40,90,50,0.9);color:#cfe;border:1px solid rgba(90,170,110,0.6);
        border-radius:4px;qproperty-alignment:AlignCenter;font-size:11px;}QLabel::hover{background:rgba(55,115,65,0.95);}]])
    done:echo("<center>Done</center>")
    done:setClickCallback(function()
        if d._beForm and d._beForm.commitAll then d._beForm.commitAll() end
        scheduleSave(); clearEdit(); d.onClose = nil; Mux.ui.closeColorWheel(); d:close(); render(target)
    end)

    d.onClose = function()                       -- ✕ discards every edit made since opening
        Mux.ui.closeColorWheel()
        cfg.buttons[idx] = snapshot
        clearEdit()
        scheduleSave()                           -- persist the revert so no in-progress state survives
        render(target)
    end
end

openGridSettings = function(target)
    local cfg = configFor(target.id)
    local key = "mux_grid_settings_" .. target.id
    local d = Mux.createDialog({ title = "Grid Settings — " .. Mux._targetPath(target), width = 360, height = 340, singleton = key, contextMenu = false })
    if not d then return end
    if d.contentBg then d.contentBg:echo(""); d.contentBg:hide() end
    local function preview() render(target) end
    local rows = {
        { label = "Columns", type = "number", min = 1, max = 8,
          readFn = function() return cfg.cols end, writeFn = function(v) cfg.cols = v; preview() end },
        { label = "Horizontal Gap (px)", type = "number", min = 0, max = 24,
          readFn = function() return cfg.gapX end, writeFn = function(v) cfg.gapX = v; preview() end },
        { label = "Vertical Gap (px)", type = "number", min = 0, max = 24,
          readFn = function() return cfg.gapY end, writeFn = function(v) cfg.gapY = v; preview() end },
        { label = "Vertical Sizing", type = "segmentedControl",
          options = { { value = "fill", label = "Fill" }, { value = "fixed", label = "Fixed" } },
          desc = "Fill stretches rows to the pane height; Fixed uses the row height below.",
          readFn = function() return cfg.vsizing or "fill" end, writeFn = function(v) cfg.vsizing = v; preview() end },
        { label = "Row Height (px, when Fixed)", type = "number", min = 20, max = 120, step = 2,
          readFn = function() return cfg.rowH end, writeFn = function(v) cfg.rowH = v; preview() end },
        { label = "Lock (hide editor)", type = "toggle",
          desc = "Hide the edit wrench so the grid looks final. Bring it back with:  mux reveal <pane id>",
          readFn = function() return cfg.locked or false end,
          writeFn = function(v)
              cfg.locked = v; scheduleSave()
              if v then
                  local st = STATE_BY_TARGET[target.id]
                  if st then
                      st.editing = false
                      if st.editCascade then st.editCascade:destroy(); st.editCascade = nil end
                  end
              end
              preview()
              local p = target.pane or target      -- refresh the owning pane's titlebar
              if p._layoutTitlebarButtons then p:_layoutTitlebarButtons() end
          end },
    }
    d:mountForm(rows, { prefix = d._gid .. "_gs", hideApply = true })
    d.onClose = function() scheduleSave() end
    -- Locking hides the edit wrench, so warn before closing — pointing at
    -- `mux reveal` as the way back.
    if d.closeBtn then
        d.closeBtn:setClickCallback(function(event)
            if event.button ~= "LeftButton" then return end
            if cfg.locked then
                local msg = "This grid is <b>locked</b> — the edit wrench is now hidden.<br/>"
                         .. "To bring the editor back, run: "
                         .. "<tt style='color:#8ab4ff;'>mux reveal " .. (target.id or "&lt;id&gt;") .. "</tt>"
                Mux._showPropsCloseConfirm(msg, function() d:close() end)
            else
                d:close()
            end
        end)
    end
end

-- ── Content registration ──────────────────────────────────────────────────────────

-- ── Edit mode driven from the titlebar wrench ─────────────────────────────────
-- The wrench toggles edit mode. Entering edit mode fans out a titlebar cascade
-- (Add button, Grid settings) anchored under the wrench; leaving edit mode
-- collapses it. Nothing is drawn on the content itself.
local function buttonsHost(ctx) return ctx.tab or ctx.pane end

local function showEditCascade(ctx, host, st)
    local theme  = Mux.activeTheme() or {}
    local btnCss = theme.btnCss or "background-color: rgba(40,46,72,240); border: 1px solid rgba(100,160,255,0.35); border-radius: 3px;"
    local txt    = theme.btnTextColor or "#cfe"
    local size   = theme.btnSize or 22
    -- Anchor under the pane's wrench label if we can find it; else a sane fallback.
    local wl = ctx.pane and ctx.pane._contentTbBtns and ctx.pane._contentTbBtns["buttons.settings"]
    local label = wl and wl.label
    local sx, sy = 40, 40
    if label and label.get_x then
        sx = label:get_x()
        sy = label:get_y() + (label:get_height() or size)
    end
    if st.editCascade then st.editCascade:destroy() end
    st.editCascade = Mux.ui.iconCascade(Geyser, {
        name = "mux_btnedit_" .. tostring(host.id),
        x = math.floor(sx), y = math.floor(sy), direction = "down", size = size, gap = 4,
        items = {
            { id = "add", css = btnCss, tooltip = "Add button",
              icon = string.format("<font color='%s'>＋</font>", txt),
              onClick = function()
                  local cfg = configFor(host.id)
                  cfg.buttons[#cfg.buttons + 1] = { label = "Button", width = 1, bg = "#1c2a4e",
                      fg = "#96c8ff", fontSize = 12, shape = "rounded", action = { type = "command", text = "" } }
                  scheduleSave(); render(host)
              end },
            { id = "grid", css = btnCss, tooltip = "Grid settings",
              icon = string.format("<font color='%s'>⊞</font>", txt),
              onClick = function() openGridSettings(host) end },
        },
    })
end

local function toggleButtonsEdit(ctx)
    local host = buttonsHost(ctx)
    local st   = STATE_BY_TARGET[host.id]; if not st then return end
    st.editing = not st.editing
    if not st.editing and st.editCascade then
        st.editCascade:destroy(); st.editCascade = nil
    end
    render(host)                     -- redraw grid (edit visuals) + raise panes first
    -- Fan the titlebar cascade only when there's a visible wrench icon to anchor it.
    -- When the element is menu-only (a tab, or a pane whose icon is folded / compact
    -- titlebars), Add / Grid-settings come from the right-click submenu instead.
    if st.editing and not (ctx.menuOnly or ctx.isTab) then
        showEditCascade(ctx, host, st)
    end
end

-- Are we editing this ctx's grid? (drives the tab-menu-only Add / Grid rows)
local function editingHere(ctx)
    local host = ctx and (ctx.tab or ctx.pane)
    local st   = host and STATE_BY_TARGET[host.id]
    return st and st.editing and true or false
end
local function addButtonTo(host)
    local st = STATE_BY_TARGET[host.id]
    if st then st.editing = true end   -- adding implies editing, so the new button is editable
    local cfg = configFor(host.id)
    cfg.buttons[#cfg.buttons + 1] = { label = "Button", width = 1, bg = "#1c2a4e",
        fg = "#96c8ff", fontSize = 12, shape = "rounded", action = { type = "command", text = "" } }
    scheduleSave(); render(host)
end

Mux.registerContent("mux_buttons", {
    name        = "Button Grid",
    description = "A configurable grid of buttons bound to commands or registered actions",
    singleton   = false,

    -- The wrench toggles edit mode; entering fans out Add + Grid-Settings as a
    -- titlebar cascade, leaving collapses it. A wrench (not the gear) marks
    -- per-content settings apart from the main Muxlet gear.
    titlebarElements = {
        {
            id = "buttons.settings", side = "left", group = "content", order = 0, priority = 105,
            icon = "🔧", tooltip = "Edit buttons",
            visible = function(ctx)
                local host = ctx and (ctx.tab or ctx.pane)
                if not host then return true end
                local cfg = configFor(host.id)
                return not (cfg and cfg.locked)     -- Lock hides the wrench; `mux reveal` restores it
            end,
            onClick = function(ctx, event)
                if not event or event.button == "LeftButton" then toggleButtonsEdit(ctx) end
            end,
            menuText = function(ctx)
                return editingHere(ctx) and "🔧  Editing — click to finish" or "🔧  Edit buttons"
            end,
            menuGroup = "info", menuOrder = 95,
            run = function(ctx) toggleButtonsEdit(ctx) end,
            -- On a tab there is no titlebar cascade, so Add / Grid-settings live in a
            -- right-click SUBMENU off this row, and clicking the row toggles edit mode
            -- WITHOUT closing the menu (menuKeepOpen) so the submenu stays reachable
            -- during edit mode. On a pane, menuSubmenu returns nil and keepOpen is
            -- false, so the row keeps its plain behaviour (toggle edit → titlebar
            -- cascade fans out).
            menuKeepOpen = function(ctx) return ctx and ctx.menuOnly or false end,
            menuSubmenu  = function(ctx)
                -- The menu equivalent of the titlebar cascade: only when the menu is
                -- the only way in (tab, or a pane whose icon is folded / compact) AND
                -- we are actually in edit mode. Otherwise the row is a plain toggle.
                if not (ctx and ctx.menuOnly and editingHere(ctx)) then return nil end
                local host = ctx.tab or ctx.pane
                return {
                    { text = "＋  Add button", keepOpen = true,
                      fn = function() addButtonTo(host) end },
                    { text = "⊞  Grid settings…",
                      fn = function() openGridSettings(host) end },
                }
            end,
        },
    },

    apply = function(target)
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        local st = STATE_BY_TARGET[target.id] or { editing = false, widgets = {}, gen = 0 }
        st.target = target
        STATE_BY_TARGET[target.id] = st
        render(target)
    end,
    remove = function(target)
        -- Editor and Grid-Settings are top-level dialogs, so they outlive the pane
        -- unless we close them here. remove() runs on manual removal and on pane
        -- close (MuxPane:close calls def.remove), covering the killed-pane case.
        Mux.ui.closeColorWheel()
        for _, key in ipairs({ "mux_btn_editor_" .. target.id, "mux_grid_settings_" .. target.id }) do
            local dlg = Mux.getDialog and Mux.getDialog(key)
            if dlg then dlg.onClose = nil; if dlg.close then dlg:close() end end
        end
        local st = STATE_BY_TARGET[target.id]
        if st then
            if st.editCascade then st.editCascade:destroy(); st.editCascade = nil end
            clearWidgets(st)
        end
        STATE_BY_TARGET[target.id] = nil
        CONFIG[target.id] = nil       -- a manual remove resets config; restore re-seeds it on load
    end,
    resize = function(target)        -- framework calls this when the container resizes
        render(target)
    end,
    serialize = function(target)      -- persist this grid inside the workspace
        return configFor(target.id)
    end,
    restore = function(target, data)  -- reapply saved grid on workspace load
        if type(data) == "table" then
            CONFIG[target.id] = data
            render(target)
        end
    end,
    onReveal = function(target)       -- `mux reveal <id>` clears the lock so the wrench returns
        local cfg = configFor(target.id)
        if cfg.locked then
            cfg.locked = false
            scheduleSave()
            render(target)
            local p = target.pane or target
            if p._layoutTitlebarButtons then p:_layoutTitlebarButtons() end
        end
    end,
})

if Mux._log then Mux._log("button grid content loaded") end