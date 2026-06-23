-- Muxlet — Properties dialog
-- Floating editor for per-pane and per-tab properties.
-- Uses the content system so contentBg is properly suppressed.
--
-- Opened via:
--   Mux.showPaneProperties(pane)
--   Mux.showTabProperties(host, tab)
--
-- Requires: content.lua (Mux.registerContent, Mux._applyContent) loaded first.

local propsUi        = {}
local pendingRows    = nil   -- rows passed to the registered apply function
local _propsEpoch    = 0     -- incremented each open to avoid widget name collisions on ID reuse
local _pendingPrefix = nil   -- set before _applyContent so apply() uses a unique prefix
local _pendingActiveGroup = nil   -- group label to re-activate after a grouped rebuild
local _pendingPropsConfirm = nil  -- {message, onProceed} for the close-confirm dialog
local _propsRebuildInProgress = false  -- true while refreshPaneProperties re-opens the dialog

-- Centered Apply button for use in form rows (Rules tab).  Registered once so
-- the form builder can dispatch to it by type name "mux_action_btn".
if not Mux.ui._widgets["mux_action_btn"] then
    Mux.ui.registerWidget("mux_action_btn", function(row, c)
        local dlgCss = Mux.dialogCss or {}
        local btnW, btnH = 120, 28
        local btnX = math.floor((c.formW - btnW) / 2)
        local btnY = math.floor((c.rowH - btnH) / 2)
        local btn = Geyser.Label:new({name=c.uid.."_btn", x=btnX, y=btnY, width=btnW, height=btnH}, row)
        btn:setStyleSheet(dlgCss.buttonPrimary or c.css.applyBtn)
        btn:echo("<center>" .. (c.spec.btnLabel or "Apply") .. "</center>")
        if dlgCss.buttonPrimary and dlgCss.buttonPrimaryHover then
            Mux.wireDialogButton(btn, dlgCss.buttonPrimary, dlgCss.buttonPrimaryHover)
        end
        btn:setClickCallback(function() c.onChange(true) end)
    end, { rowHeight = 44, layout = "block" })
end

-- Forward declarations needed because paneRows/tabRows reference these before their definitions.
local refreshPaneProperties
local refreshTabProperties

-- Live screen geometry of a pane, for the read-only Properties readout. Uses the
-- actual rendered container when present (reflects drags/resizes), else the
-- stored float geometry. Includes the id so a specific pane is easy to reference.
local function _geomString(pane)
    local x, y, w, h
    if pane.outer and pane.outer.get_x then
        x, y = pane.outer:get_x(), pane.outer:get_y()
        w, h = pane.outer:get_width(), pane.outer:get_height()
    else
        x, y, w, h = pane.floatX, pane.floatY, pane.floatW, pane.floatH
    end
    local idStr = pane.id and ("   ·   id " .. tostring(pane.id)) or ""
    if not (x and y and w and h) then return "—" .. idStr end
    return string.format("x %d, y %d   ·   %d × %d px%s",
        math.floor(x), math.floor(y), math.floor(w), math.floor(h), idStr)
end


-- Expandable "Position & Size" section. Collapsed: a clickable heading. Expanded:
-- a larger-font readout the user can highlight and copy. Uses a MiniConsole
-- (Geyser.Labels aren't text-selectable) but blends it with the dialog and keeps
-- it to a single line so it reads like plain text. It updates live, repainting
-- only when the value actually changes so a selection isn't wiped mid-copy.
if Mux.ui and Mux.ui.registerWidget and not (Mux.ui._widgets and Mux.ui._widgets["geomSection"]) then
    Mux.ui.registerWidget("geomSection", function(row, c)
        local spec, uid, css = c.spec, c.uid, c.css
        local pane   = spec.pane
        local availW = c.formW - c.padL - c.padR

        -- Clickable heading with a disclosure chevron.
        local head = Geyser.Label:new(
            { name = uid .. "_h", x = c.padL, y = 8, width = availW, height = 18 }, row)
        head:setStyleSheet(css.rowLabel)
        head:rawEcho((spec.expanded and "▾  " or "▸  ") .. (spec.label or "Position & Size"))
        head:setCursor("PointingHand")
        head:setClickCallback(function() if spec.onToggle then spec.onToggle() end end)

        if not spec.expanded then
            return {}   -- collapsed: heading only
        end

        -- Styled, larger-font readout. Mudlet has no selectable-text widget other
        -- than a console, and the MiniConsole proved unreliable here, so this is a
        -- plain label: not selectable, but always renders the full value, live.
        local lbl = Geyser.Label:new(
            { name = uid .. "_v", x = c.padL + 2, y = 28, width = availW - 4, height = 24 }, row)
        lbl:setStyleSheet("background: transparent; border: none;")

        local last
        local function paint()
            local x, y, w, h
            if pane and pane.outer and pane.outer.get_x then
                x, y = pane.outer:get_x(), pane.outer:get_y()
                w, h = pane.outer:get_width(), pane.outer:get_height()
            else
                x, y, w, h = pane.floatX, pane.floatY, pane.floatW, pane.floatH
            end
            local function n(v) return v and tostring(math.floor(v)) or "—" end
            local s = string.format(
                "<div style='font-size:14px;line-height:19px;color:#dfe3f4;'>"
                .. "<b>x</b> %s&nbsp;&nbsp;&nbsp;<b>y</b> %s&nbsp;&nbsp;&nbsp;"
                .. "<b>w</b> %s&nbsp;&nbsp;&nbsp;<b>h</b> %s</div>",
                n(x), n(y), n(w), n(h))
            if s == last then return end
            last = s
            lbl:echo(s)
        end
        paint()

        return { refresh = paint }   -- live; repaints only on change
    end, { rowHeight = 56, layout = "block" })
end


-- ── Property definitions ──────────────────────────────────────────────────────

local function paneRows(pane)
    local rows = {}

    -- Expandable, copyable geometry readout (kept first).
    local geomExpanded = pane._geomExpanded or false
    rows[#rows+1] = {
        label     = "Position & Size",
        type      = "geomSection",
        pane      = pane,
        expanded  = geomExpanded,
        rowHeight = geomExpanded and 72 or 34,
        onToggle  = function()
            pane._geomExpanded = not pane._geomExpanded
            if refreshPaneProperties then refreshPaneProperties(pane) end
        end,
    }

    -- Group 1: Tabs, Locked, Titlebar, Properties Button
    rows[#rows+1] = {
        label   = "Tabs",
        desc    = "Enabled: host multiple views in a tab bar; Locked: tab bar frozen, no add/close",
        type    = "choiceCycler",
        options = {
            { value = false,    label = "Disabled", style = "off"  },
            { value = true,     label = "Enabled",  style = "on"   },
            { value = "locked", label = "NoAdd",    style = "warn" },
        },
        readFn  = function()
            if pane.tabsLocked then return "locked" end
            return pane._tabsEnabled and true or false
        end,
        writeFn = function(v)
            if v == true then
                pane.tabsLocked = false
                if not pane._tabsEnabled then pane:enableTabs() end
                if pane._addTabBtn then pane:_setAddTabBtnVisible(true) end
            elseif v == false then
                pane.tabsLocked = false
                if pane._tabsEnabled then pane:disableTabs() end
            elseif v == "locked" then
                pane.tabsLocked = true
                if pane._addTabBtn then pane:_setAddTabBtnVisible(false) end
            end
        end,
    }
    if pane.titlebarHideable then
        rows[#rows+1] = {
            label      = "Titlebar",
            desc       = "Visible: shows the titlebar strip. Hidden: collapses to a thin reveal strip",
            type       = "toggle",
            trueLabel  = "Visible",
            falseLabel = "Hidden",
            readFn     = function() return pane.titlebarVisible end,
            writeFn    = function(v) pane:setTitlebarVisible(v) end,
        }
    end
    rows[#rows+1] = {
        label      = "Properties Button",
        desc       = "Show the ≡ button in the titlebar. If hidden (and the titlebar too), run 'mux reveal <id>' to restore it",
        type       = "toggle",
        trueLabel  = "Visible",
        falseLabel = "Hidden",
        readFn     = function() return pane.propertiesButton end,
        writeFn    = function(v)
            pane.propertiesButton = v
            pane:_applyTitlebarVisibility()
        end,
    }
    -- Group 2: Behavior toggles
    rows[#rows+1] = {
        label      = "Minimizable",
        desc       = "Show the minimize button. Floating: collapses to titlebar strip. Embedded: collapses the pane's split slot",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.minimizable end,
        writeFn    = function(v)
            pane.minimizable = v
            pane:_applyTitlebarVisibility()
        end,
    }
    rows[#rows+1] = {
        label      = "Closeable",
        desc       = "Show the close button and allow this pane to be closed",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.closeable end,
        writeFn    = function(v)
            pane.closeable = v
            pane:_applyTitlebarVisibility()
        end,
    }
    rows[#rows+1] = {
        label      = "Splittable",
        desc       = "Allow this pane to be split horizontally or vertically by drag or command",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.splittable end,
        writeFn    = function(v)
            pane.splittable = v
            pane:_applyTitlebarVisibility()
        end,
    }
    rows[#rows+1] = {
        label      = "Swappable",
        desc       = "Allow this pane to swap position with its sibling within a split",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.swappable end,
        writeFn    = function(v)
            pane.swappable = v
            pane:_applyTitlebarVisibility()
        end,
    }
    rows[#rows+1] = {
        label      = "Zoomable",
        desc       = "Allow this pane to temporarily zoom to fill the window",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.zoomable end,
        writeFn    = function(v)
            pane.zoomable = v
            pane:_applyTitlebarVisibility()
        end,
    }
    rows[#rows+1] = {
        label      = "Convertible",
        desc       = "Allow switching between embedded (in split) and floating. Also requires Movable to drag-float from the titlebar",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.convertible end,
        writeFn    = function(v)
            pane.convertible = v
            pane:_applyTitlebarVisibility()
            if pane.titlebar then pane.titlebar:setCursor(pane:_titlebarCursor()) end
        end,
    }
    rows[#rows+1] = {
        label      = "Anchorable",
        desc       = "Allow this floating pane to be anchored to other panes' edges. When on, right-click the pane → Anchor (or use the ⚓ titlebar button) → Set anchor, then drag to an edge or corner. Independent of Convertible.",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.anchorable ~= false end,
        writeFn    = function(v)
            pane.anchorable = v
            if not v then pane:removeAnchor() end
            pane:_applyTitlebarVisibility()
        end,
    }
    rows[#rows+1] = {
        label      = "Bordered",
        desc       = "Draw the pane's frame border. When off, the border is hidden and content fills edge-to-edge.",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.bordered ~= false end,
        writeFn    = function(v) pane:setBordered(v) end,
    }
    rows[#rows+1] = {
        label      = "Movable",
        desc       = "Floating: drag titlebar to reposition. Embedded: required together with Convertible to drag-float",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.movable end,
        writeFn    = function(v)
            pane.movable = v
            if pane.titlebar then pane.titlebar:setCursor(pane:_titlebarCursor()) end
        end,
    }
    rows[#rows+1] = {
        label      = "Contentable",
        desc       = "Show the Content Library button and allow content to be assigned to this pane",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.contentable end,
        writeFn    = function(v)
            pane.contentable = v
            pane:_applyTitlebarVisibility()
        end,
    }

    -- Group 3: Resizable, then Renamable + optional Name input together
    rows[#rows+1] = {
        label      = "Resizable",
        desc       = "Allow this pane to be resized. When off, no border of the pane can be dragged — its corner handles (when floating) and every split handle that would change its size are locked",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.resizable end,
        writeFn    = function(v)
            pane.resizable = v
            if v then
                if pane._cornerHandles and pane.floating then pane:_showCornerHandles() end
            else
                pane:_hideCornerHandles()
            end
            pane:_refreshResizeHandles()
        end,
    }
    rows[#rows+1] = {
        label      = "Renamable",
        desc       = "Allow renaming via command or double-click. When enabled, a Name field appears below",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.renamable ~= false end,
        writeFn    = function(v)
            pane.renamable = v
            refreshPaneProperties(pane)
        end,
    }
    if pane.renamable ~= false then
        rows[#rows+1] = {
            label   = "Name",
            desc    = "Display name shown in the titlebar",
            type    = "text",
            readFn  = function() return pane.name end,
            writeFn = function(v)
                if v == "" then return end
                pane:setName(v)
                -- Keep the open Properties dialog's own titlebar in sync.
                if pane._propertiesDialogs then
                    for _, dlg in pairs(pane._propertiesDialogs) do
                        if dlg.setName then dlg:setName("Properties: " .. Mux._targetPath(pane)) end
                    end
                end
            end,
        }
    end
    rows[#rows+1] = {
        label      = "Name Align",
        desc       = "Where the pane name sits in the titlebar. Left: name then Properties button. Center/Right: Properties button moves to far left",
        type       = "segmentedControl",
        widgetWidth = 138,
        options    = {
            { value = "left",   label = "Left"   },
            { value = "center", label = "Center" },
            { value = "right",  label = "Right"  },
        },
        readFn     = function() return pane.nameAlign or "left" end,
        writeFn    = function(v) pane:setNameAlign(v) end,
    }

    -- Connection Awareness
    rows[#rows+1] = {
        label      = "Connection Awareness",
        desc       = "Cover this pane (including tab bar) with a disconnected/connecting screen. Suppresses per-tab awareness while active",
        type       = "toggle",
        trueLabel  = "On",
        falseLabel = "Off",
        readFn     = function() return pane._connectionAware or false end,
        writeFn    = function(v) pane:setConnectionAware(v) end,
    }

    -- Group 4: Size inputs. Width applies to floating panes or when some
    -- side-by-side split exists above the pane; height likewise for top/bottom.
    -- The displayed value is the pane's actual size as a percentage of the
    -- screen, regardless of which split controls it.
    local canWidth  = pane.floating or Mux._ancestorSplitOfDirection(pane, "h") ~= nil
    local canHeight = pane.floating or Mux._ancestorSplitOfDirection(pane, "v") ~= nil

    if canWidth then
        rows[#rows+1] = {
            label   = "Width %",
            desc    = "Set width as a percentage of the screen (1–99)",
            type    = "text",
            readFn  = function()
                local sw = getMainWindowSize()
                local w  = pane.floating and pane.floatW or (pane.width and pane:width())
                if not w or w <= 0 or not sw or sw <= 0 then return "" end
                return tostring(math.floor(w / sw * 100))
            end,
            writeFn = function(v)
                local pct = tonumber(v:match("%d+"))
                if pct then Mux.resizePaneToWidth(pane, pct) end
            end,
        }
    end
    if canHeight then
        rows[#rows+1] = {
            label   = "Height %",
            desc    = "Set height as a percentage of the screen (1–99)",
            type    = "text",
            readFn  = function()
                local _, sh = getMainWindowSize()
                local h     = pane.floating and pane.floatH or (pane.height and pane:height())
                if not h or h <= 0 or not sh or sh <= 0 then return "" end
                return tostring(math.floor(h / sh * 100))
            end,
            writeFn = function(v)
                local pct = tonumber(v:match("%d+"))
                if pct then Mux.resizePaneToHeight(pane, pct) end
            end,
        }
    end
    -- ── Rules (inline "show when" condition + reactive actions) ───────────────
    -- Condition parameters are buffered in pane._pendingCondition until Apply is
    -- clicked, so selecting a type or editing a field does not call setCondition
    -- immediately. This prevents the content area from reacting mid-edit.
    -- "Always" is the only type that auto-applies on selection (no parameters).
    if not pane._pendingCondition then
        pane._pendingCondition = {}
        if pane.condition then
            for k, v in pairs(pane.condition) do pane._pendingCondition[k] = v end
        end
    end
    local cspec = pane._pendingCondition
    local ctype = cspec.type or "always"

    local function setType(t)
        pane._propsActiveGroup = "Rules"
        cspec.type = (t == "always") and nil or t
        if not cspec.type then
            pane:setCondition(nil)
            pane._pendingCondition = {}
        end
        refreshPaneProperties(pane)
    end
    local function setField(k, v)
        cspec[k] = v
    end
    local function doApply()
        if not cspec.type or cspec.type == "always" then
            pane:setCondition(nil)
        else
            pane:setCondition(cspec)
        end
        pane._pendingCondition = {}
        if pane.condition then
            for k, v in pairs(pane.condition) do pane._pendingCondition[k] = v end
        end
    end

    local actOpts = {}
    for _, a in ipairs(Mux.listActions and Mux.listActions() or {}) do
        actOpts[#actOpts+1] = { value = a.id, label = a.name or a.id }
    end

    local rules = {}
    rules[#rules+1] = {
        label = "Show when", type = "array", display = "dropdown",
        desc  = "When this pane is visible. Always = no condition.",
        options = Mux.conditionTypes,
        readFn  = function() return ctype end,
        writeFn = setType,
    }
    if ctype == "gmcp_exists" or ctype == "gmcp_equals" then
        rules[#rules+1] = { label = "GMCP path", type = "text",
            desc = "dotted path under gmcp, e.g. room.info.players (a leading 'gmcp.' is fine)",
            readFn = function() return cspec.path or "" end,
            writeFn = function(v) setField("path", v) end }
    end
    if ctype == "gmcp_equals" then
        rules[#rules+1] = { label = "Equals", type = "text", desc = "value to match (text)",
            readFn = function() return cspec.value or "" end,
            writeFn = function(v) setField("value", v) end }
    end
    if ctype == "event_fired" then
        rules[#rules+1] = { label = "Event", type = "text",
            desc = "Mudlet event name, e.g. gmcp.char.vitals",
            readFn = function() return cspec.event or "" end,
            writeFn = function(v) setField("event", v) end }
        rules[#rules+1] = { label = "Seconds", type = "text",
            desc = "stays true this long after the event fires",
            readFn = function() return tostring(cspec.seconds or 5) end,
            writeFn = function(v) setField("seconds", tonumber(v) or 5) end }
    end
    if ctype ~= "always" then
        rules[#rules+1] = { label = "When true", type = "array", display = "dropdown",
            desc = "action when the condition becomes true (default: show pane)",
            options = actOpts, readFn = function() return pane.actionTrue or "mux.showSelf" end,
            writeFn = function(v) pane:setReactiveActions(v, nil) end }
        rules[#rules+1] = { label = "When false", type = "array", display = "dropdown",
            desc = "action when the condition becomes false (default: hide pane)",
            options = actOpts, readFn = function() return pane.actionFalse or "mux.hideSelf" end,
            writeFn = function(v) pane:setReactiveActions(nil, v) end }
        rules[#rules+1] = {
            btnLabel = "Apply",
            type     = "mux_action_btn",
            writeFn  = function() doApply() end,
        }
    end

    -- Partition the flat rows above into the General / Behavior tabs by label.
    local GENERAL = {
        ["Position & Size"] = true, ["Tabs"] = true, ["Renamable"] = true,
        ["Name"] = true, ["Name Align"] = true, ["Width %"] = true,
        ["Height %"] = true, ["Connection Awareness"] = true,
    }
    local general, behavior = {}, {}
    for _, r in ipairs(rows) do
        if GENERAL[r.label] then general[#general+1] = r else behavior[#behavior+1] = r end
    end

    return {
        _grouped = true,
        { label = "General",  rows = general, _geomTab = true },
        { label = "Behavior", rows = behavior },
        { label = "Rules",    rows = rules },
    }
end

local function tabRows(host, tab)
    local rows = {}

    -- Tab nesting is capped at three levels. A tab's depth is how many tab hosts
    -- sit above it (its host chain via .pane up to the owning pane). At depth 3 we
    -- omit the Tabs row, so a fourth level can't be created from the UI.
    local depth = 1
    local h = host
    while h and h.pane do depth = depth + 1; h = h.pane end

    if depth < 3 then
        rows[#rows+1] = {
            label   = "Tabs",
            desc    = "Enabled: host nested tabs inside this tab; NoAdd: tab bar shown but no new tabs can be added",
            type    = "choiceCycler",
            options = {
                { value = false,    label = "Disabled", style = "off"  },
                { value = true,     label = "Enabled",  style = "on"   },
                { value = "locked", label = "NoAdd",    style = "warn" },
            },
            readFn  = function()
                if tab.tabsLocked then return "locked" end
                return tab._tabsEnabled and true or false
            end,
            writeFn = function(v)
                if v == true then
                    tab.tabsLocked = false
                    if not tab._tabsEnabled then tab:enableTabs() end
                    if tab._addTabBtn then tab:_setAddTabBtnVisible(true) end
                elseif v == false then
                    tab.tabsLocked = false
                    if tab._tabsEnabled then tab:disableTabs() end
                elseif v == "locked" then
                    tab.tabsLocked = true
                    if tab._addTabBtn then tab:_setAddTabBtnVisible(false) end
                end
            end,
        }
    end

    rows[#rows+1] = {
        label      = "Properties",
        desc       = "Show or hide the Properties item in this tab's right-click menu",
        type       = "toggle",
        trueLabel  = "Visible",
        falseLabel = "Hidden",
        readFn     = function() return tab.propertiesButton ~= false end,
        writeFn    = function(v) tab.propertiesButton = v end,
    }

    rows[#rows+1] = {
        label      = "Closeable",
        desc       = "Allow this tab to be closed",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return tab.closeable ~= false end,
        writeFn    = function(v) tab.closeable = v end,
    }

    rows[#rows+1] = {
        label      = "Movable",
        desc       = "Allow this tab to be dragged to reorder or moved to another pane",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return tab.movable ~= false end,
        writeFn    = function(v) tab.movable = v end,
    }

    rows[#rows+1] = {
        label      = "Contentable",
        desc       = "Allow content from the Content Library to be applied to this tab",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return tab.contentable ~= false end,
        writeFn    = function(v) tab.contentable = v end,
    }

    rows[#rows+1] = {
        label      = "Renamable",
        desc       = "Allow this tab to be renamed",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return tab.renamable ~= false end,
        writeFn    = function(v)
            tab.renamable = v
            refreshTabProperties(host, tab)
        end,
    }

    if tab.renamable ~= false then
        rows[#rows+1] = {
            label   = "Name",
            desc    = "Display name shown on the tab label",
            type    = "text",
            readFn  = function() return tab.name end,
            writeFn = function(v)
                if v == "" then return end
                host:renameTab(tab.id, v)
                -- Keep the open Properties dialog's own titlebar in sync.
                if tab._propertiesDialogs then
                    for _, dlg in pairs(tab._propertiesDialogs) do
                        if dlg.setName then dlg:setName("Properties: " .. Mux._targetPath(tab)) end
                    end
                end
            end,
        }
    end
    rows[#rows+1] = {
        label      = "Name Align",
        desc       = "Text alignment of the tab label",
        type       = "segmentedControl",
        widgetWidth = 138,
        options    = {
            { value = "left",   label = "Left"   },
            { value = "center", label = "Center" },
            { value = "right",  label = "Right"  },
        },
        readFn     = function() return tab.nameAlign or "center" end,
        writeFn    = function(v) host:setTabNameAlign(tab.id, v) end,
    }

    -- Connection Awareness
    rows[#rows+1] = {
        label      = "Connection Awareness",
        desc       = "Cover this tab's content with a disconnected/connecting screen. Has no effect if the parent pane has Connection Awareness enabled",
        type       = "toggle",
        trueLabel  = "On",
        falseLabel = "Off",
        readFn     = function() return tab._connectionAware or false end,
        writeFn    = function(v) host:setTabConnectionAware(tab.id, v) end,
    }

    return rows
end

-- ── Content type registration ─────────────────────────────────────────────────
-- Registering as content suppresses the pane placeholder and integrates cleanly
-- with the content lifecycle (singleton tracking, remove callbacks).

Mux.registerContent("mux_properties", {
    name     = "Properties",
    internal = true,
    apply = function(target)
        if target.contentBg then
            target.contentBg:echo("")
            target.contentBg:hide()
        end
        local rows = pendingRows
        if not rows then return end

        local prefix   = _pendingPrefix or ("mux_prop_" .. target.id)
        _pendingPrefix = nil
        local theme    = Mux.activeTheme() or {}
        local uiTheme  = theme.ui or theme.settingsUi or {}
        local bg       = uiTheme.bg or "rgb(18,18,26)"
        local cw       = target.content:get_width()
        if cw < 50 then cw = 376 end

        if rows._grouped then
            -- Tabbed properties (e.g. panes: General | Behavior | Rules). Build the
            -- dialog's own tab bar (regular pane styling) and a form per group.
            if not target._tabsEnabled then
                target.tabsLocked = true   -- NoAdd: no "+" on the properties tab bar
                target:enableTabs({ noDefaultTab = true })
            end
            local groupTabs = {}
            for gi, grp in ipairs(rows) do
                local tab = target:addTab(grp.label)
                tab.renamable = false; tab.closeable = false; tab.movable = false
                tab.contentable = false; tab.contextMenu = false
                groupTabs[grp.label] = tab
                -- Hide this tab's empty-content placeholder (its text/background
                -- would otherwise show through behind the form).
                if tab.contentBg then tab.contentBg:echo(""); tab.contentBg:hide() end
                local tcw = tab.content:get_width(); if tcw < 50 then tcw = cw end
                local lbl = Geyser.Label:new({
                    name = prefix .. "_g" .. gi, x = 0, y = 0, width = tcw, height = Mux.ui.formHeight(grp.rows),
                }, tab.content)
                lbl:setStyleSheet("background:" .. bg .. "; border:none;")
                local fh = Mux.ui.buildForm(lbl, grp.rows, {
                    width = tcw, prefix = prefix .. "_g" .. gi,
                    getContentScreenPos = function() return tab.content:get_x(), tab.content:get_y() end,
                })
                -- The geom readout lives on the General tab; expose its handle for the live poll.
                if grp._geomTab then target._propsFormHandle = fh end
            end
            -- Restore the previously-active tab (a rebuild from, e.g., changing the
            -- Rules "Show when" type would otherwise snap back to the first tab).
            if _pendingActiveGroup and groupTabs[_pendingActiveGroup]
               and target._activeTabId ~= groupTabs[_pendingActiveGroup].id then
                target:_activateTabObj(groupTabs[_pendingActiveGroup])
            end
            _pendingActiveGroup = nil
            -- Hide every non-active tab's content (tab infra is added after the
            -- dialog's own hide pass, so stale tabs would draw over the active one).
            if target._tabs then
                for _, t in ipairs(target._tabs) do
                    if t.content then
                        if t.id == target._activeTabId then t.content:show() else t.content:hide() end
                    end
                    if t.contentBg then t.contentBg:hide() end   -- after show: keep placeholder hidden
                end
            end
            tempTimer(0, function() if target.outer then target.outer:reposition() end end)
            return
        end

        if #rows == 0 then return end
        local contentH = Mux.ui.formHeight(rows)
        local contentLbl = Geyser.Label:new({
            name=prefix.."_cl", x=0, y=0, width=cw, height=contentH,
        }, target.content)
        contentLbl:setStyleSheet("background:" .. bg .. "; border:none;")

        target._propsFormHandle = Mux.ui.buildForm(contentLbl, rows, { width = cw, prefix = prefix })
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
-- posX/posY (optional): reopen at a specific position instead of screen-center.
local function openPropsDialog(title, rows, targetPane, posX, posY)
    _propsEpoch    = _propsEpoch + 1
    _pendingPrefix = "mux_prop_e" .. _propsEpoch
    -- One-shot: a rebuild triggered from a specific tab asks to land back on it.
    _pendingActiveGroup = targetPane and targetPane._propsActiveGroup or nil
    if targetPane then targetPane._propsActiveGroup = nil end

    local dialogW = 380

    -- Grouped (tabbed) rows: height = tab bar + the tallest group's form. Flat
    -- rows: height = the single form.
    local contentH
    if rows._grouped then
        local theme   = Mux.activeTheme() or {}
        local tabBarH = theme.tabBarHeight or 30
        local maxH    = 0
        for _, grp in ipairs(rows) do
            local h = Mux.ui.formHeight(grp.rows)
            if h > maxH then maxH = h end
        end
        contentH = tabBarH + maxH
    else
        contentH = Mux.ui.formHeight(rows)
    end

    -- chrome: titlebar (22) + outer border top+bottom (4)
    local dialogH = contentH + 26

    -- posX/posY are set only when reopening at a remembered position (a row
    -- toggle that rebuilds the dialog). On a fresh open they are nil, so
    -- createDialog centers and cascades off any dialogs already on screen.
    local d = Mux.createDialog({
        title         = title,
        x = posX, y = posY, width = dialogW, height = dialogH,
        contextMenu   = false,
        singleton     = targetPane and ("muxprops:" .. tostring(targetPane.id)) or nil,
    })

    -- Track on the target so close() / removeTab() can clean us up.
    if targetPane then
        targetPane._propertiesDialogs = targetPane._propertiesDialogs or {}
        targetPane._propertiesDialogs[d.id] = d
    end

    d.onClose = function()
        d._geomPollActive = false
        if targetPane and targetPane._propertiesDialogs then
            targetPane._propertiesDialogs[d.id] = nil
        end
        if targetPane and not _propsRebuildInProgress then
            targetPane._pendingCondition = nil
        end
    end

    -- Intercept close button: warn when closing would leave no UI path back to Properties.
    -- Pane: triggered by hidden titlebar or hidden Properties button.
    -- Tab: triggered by hidden Properties item in right-click menu.
    if targetPane then
        d.closeBtn:setClickCallback(function(event)
            if event.button ~= "LeftButton" then return end
            local message
            if targetPane.titlebarVisible ~= nil then
                -- Pane target
                local reasons = {}
                if not targetPane.titlebarVisible  then reasons[#reasons+1] = "hidden titlebar" end
                if not targetPane.propertiesButton then reasons[#reasons+1] = "Properties button hidden" end
                if #reasons > 0 then
                    local reasonStr = table.concat(reasons, " and ")
                    message = "This pane has a <b>" .. reasonStr .. "</b>.<br/>"
                           .. "To restore its controls, run: "
                           .. "<tt style='color:#8ab4ff;'>mux reveal " .. (targetPane.id or "&lt;id&gt;") .. "</tt>"
                end
            elseif targetPane.propertiesButton == false then
                -- Tab target
                message = "This tab's <b>Properties is hidden</b> from its right-click menu.<br/>"
                       .. "To restore it, run: "
                       .. "<tt style='color:#8ab4ff;'>mux reveal " .. (targetPane.id or "&lt;id&gt;") .. "</tt>"
            end
            if message then
                Mux._showPropsCloseConfirm(message, function() d:close() end)
            else
                d:close()
            end
        end)
    end

    pendingRows = rows
    Mux._applyContent(d, "mux_properties")
    pendingRows = nil

    -- Live geometry: re-read the readout (row 1) every 0.5s while open. The
    -- geomSection's refresh only repaints when the value changes, so an idle
    -- selection in the readout is never wiped. Panes only (tabs have no geometry).
    if targetPane and targetPane.titlebarVisible ~= nil then
        d._geomPollActive = true
        local function poll()
            if not d._geomPollActive then return end
            local h = d._propsFormHandle
            if h and h.refresh then pcall(h.refresh, 1) end
            tempTimer(0.5, poll)
        end
        tempTimer(0.5, poll)
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Close any existing properties dialogs for a target (used when structural row
-- changes mean the dialog must be rebuilt, e.g. Renamable or Tab Locked toggle).
local function closeExistingPropsDialogs(target)
    if not target._propertiesDialogs then return end
    local toClose = {}
    for _, dlg in pairs(target._propertiesDialogs) do toClose[#toClose+1] = dlg end
    for _, dlg in ipairs(toClose) do pcall(function() dlg:close() end) end
end

function Mux.showPaneProperties(pane)
    -- Singleton: raise the existing dialog rather than opening a duplicate.
    local existing = Mux.getDialog("muxprops:" .. tostring(pane.id))
    if existing then existing:show(); existing:raise(); return end
    openPropsDialog(string.format("Properties: %s", Mux._targetPath(pane)), paneRows(pane), pane)
end

function Mux.showTabProperties(host, tab)
    local existing = Mux.getDialog("muxprops:" .. tostring(tab.id))
    if existing then existing:show(); existing:raise(); return end
    openPropsDialog(string.format("Properties: %s", Mux._targetPath(tab)), tabRows(host, tab), tab)
end

-- Internal refresh: close existing dialogs for the target then reopen at the same position.
-- Used by writeFns that cause structural row changes (Renamable, Tab Locked).
local function _captureDialogPos(target)
    if not target._propertiesDialogs then return nil, nil end
    for _, dlg in pairs(target._propertiesDialogs) do
        if dlg.outer then return dlg.outer:get_x(), dlg.outer:get_y() end
    end
    return nil, nil
end

refreshPaneProperties = function(pane)
    local px, py = _captureDialogPos(pane)
    _propsRebuildInProgress = true
    closeExistingPropsDialogs(pane)
    _propsRebuildInProgress = false
    openPropsDialog(string.format("Properties: %s", pane.name), paneRows(pane), pane, px, py)
end

refreshTabProperties = function(host, tab)
    local px, py = _captureDialogPos(tab)
    closeExistingPropsDialogs(tab)
    openPropsDialog(string.format("Tab: %s", tab.name), tabRows(host, tab), tab, px, py)
end

function Mux._showPropsCloseConfirm(message, onProceed)
    local key = "confirm:propsclose"
    local existing = Mux.getDialog(key)
    if existing then existing:show(); existing:raise(); return end
    local confirmD = Mux.createDialog({
        title       = "Confirm Close",
        width       = 380, height = 140,
        closeable   = false,
        minimizable = false,
        contextMenu = false,
        singleton   = key,
    })
    _pendingPropsConfirm = { message = message, onProceed = onProceed }
    Mux._applyContent(confirmD, "mux_props_close_confirm")
    confirmD:show()
    confirmD:raise()
end

Mux.registerContent("mux_props_close_confirm", {
    internal = true,
    apply = function(target)
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        local p = _pendingPropsConfirm
        _pendingPropsConfirm = nil
        if not p then return end
        local cw = target.content:get_width()
        if cw < 50 then cw = (target.floatW or 380) - 4 end
        local body = Geyser.Label:new({
            name=target._gid.."_body", x=10, y=10, width=cw-20, height=68,
        }, target.content)
        body:setStyleSheet(Mux.dialogCss.body)
        body:rawEcho(p.message)
        local btnProceed = Geyser.Label:new({
            name=target._gid.."_proceed", x=20, y=86, width=155, height=34,
        }, target.content)
        btnProceed:setStyleSheet(Mux.dialogCss.buttonDanger)
        btnProceed:rawEcho("<center>Proceed</center>")
        Mux.wireDialogButton(btnProceed, Mux.dialogCss.buttonDanger, Mux.dialogCss.buttonDangerHover)
        btnProceed:setClickCallback(function() target:close(); p.onProceed() end)
        local btnCancel = Geyser.Label:new({
            name=target._gid.."_cancel", x=205, y=86, width=155, height=34,
        }, target.content)
        btnCancel:setStyleSheet(Mux.dialogCss.buttonPrimary)
        btnCancel:rawEcho("<center>Cancel</center>")
        Mux.wireDialogButton(btnCancel, Mux.dialogCss.buttonPrimary, Mux.dialogCss.buttonPrimaryHover)
        btnCancel:setClickCallback(function() target:close() end)
        target._autoFitHeight = 130
    end,
    remove = function(_) end,
})

Mux._log("mux_properties loaded")