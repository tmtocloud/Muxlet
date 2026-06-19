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
local _pendingPropsConfirm = nil  -- {message, onProceed} for the close-confirm dialog

-- Forward declarations needed because paneRows/tabRows reference these before their definitions.
local refreshPaneProperties
local refreshTabProperties


-- ── Property definitions ──────────────────────────────────────────────────────

local function paneRows(pane)
    local rows = {}

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
        desc       = "Show the ≡ button in the titlebar. If hidden, use 'mux pane properties' to reopen",
        type       = "toggle",
        trueLabel  = "Visible",
        falseLabel = "Hidden",
        readFn     = function() return pane.propertiesButton end,
        writeFn    = function(v)
            pane.propertiesButton = v
            pane:_applyTitlebarVisibility()
        end,
    }
    rows[#rows+1] = {
        label      = "Highlightable",
        desc       = "Show a focus border when this pane is active",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.highlightable ~= false end,
        writeFn    = function(v)
            pane.highlightable = v
            if v and Mux._focusedPane == pane and pane._setFrameCss and pane._focusedFrameCss then
                pane:_setFrameCss(pane:_focusedFrameCss())
            elseif not v and pane._setFrameCss and pane._baseFrameCss then
                pane:_setFrameCss(pane:_baseFrameCss())
            end
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
        desc       = "Show corner and edge drag handles for resizing (applies to floating panes)",
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
            if pane._split then pane._split:_updateHandleResizability() end
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
                        if dlg.setName then dlg:setName("Properties: " .. v) end
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

    -- Group 4: Size inputs
    rows[#rows+1] = {
        label   = "Width %",
        desc    = "Set width as a percentage of screen width (1–99). Applies to floating panes or horizontal splits",
        type    = "text",
        readFn  = function()
            local sw = getMainWindowSize()
            if pane.floating then
                return tostring(math.floor(pane.floatW / sw * 100))
            elseif pane._split and pane._split.direction == "h" then
                local r = (pane._slotSide == "a") and pane._split.ratio or (1 - pane._split.ratio)
                return tostring(math.floor(r * 100))
            end
            return ""
        end,
        writeFn = function(v)
            local pct = tonumber(v:match("%d+"))
            if pct then Mux.resizePaneToWidth(pane, pct) end
        end,
    }
    rows[#rows+1] = {
        label   = "Height %",
        desc    = "Set height as a percentage of screen height (1–99). Applies to floating panes or vertical splits",
        type    = "text",
        readFn  = function()
            local _, sh = getMainWindowSize()
            if pane.floating then
                return tostring(math.floor(pane.floatH / sh * 100))
            elseif pane._split and pane._split.direction == "v" then
                local r = (pane._slotSide == "a") and pane._split.ratio or (1 - pane._split.ratio)
                return tostring(math.floor(r * 100))
            end
            return ""
        end,
        writeFn = function(v)
            local pct = tonumber(v:match("%d+"))
            if pct then Mux.resizePaneToHeight(pane, pct) end
        end,
    }
    return rows
end

local function tabRows(host, tab)
    local rows = {}

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
                        if dlg.setName then dlg:setName("Tab: " .. v) end
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
        if not rows or #rows == 0 then return end

        local contentH = Mux.ui.formHeight(rows)
        local cw = target.content:get_width()
        if cw < 50 then cw = 376 end

        local prefix     = _pendingPrefix or ("mux_prop_" .. target.id)
        _pendingPrefix   = nil

        local theme    = Mux.activeTheme() or {}
        local uiTheme  = theme.ui or theme.settingsUi or {}
        local bg       = uiTheme.bg or "rgb(18,18,26)"

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

    local sw, sh  = getMainWindowSize()
    local dialogW = 380

    local contentH = Mux.ui.formHeight(rows)

    -- chrome: titlebar (22) + outer border top+bottom (4)
    local dialogH = contentH + 26
    local px = posX or math.floor((sw - dialogW) / 2)
    local py = posY or math.floor((sh - dialogH) / 2)

    local d = Mux.createDialog({
        title         = title,
        x=px, y=py, width=dialogW, height=dialogH,
        contextMenu   = false,
    })

    -- Track on the target so close() / removeTab() can clean us up.
    if targetPane then
        targetPane._propertiesDialogs = targetPane._propertiesDialogs or {}
        targetPane._propertiesDialogs[d.id] = d
    end

    d.onClose = function()
        if targetPane and targetPane._propertiesDialogs then
            targetPane._propertiesDialogs[d.id] = nil
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
                           .. "To reopen Properties use: "
                           .. "<tt style='color:#8ab4ff;'>mux pane properties</tt>"
                end
            elseif targetPane.propertiesButton == false then
                -- Tab target
                message = "This tab's <b>Properties is hidden</b> from its right-click menu.<br/>"
                       .. "There is no other UI path to reopen this dialog."
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
    -- Raise existing dialog rather than opening a duplicate.
    if pane._propertiesDialogs then
        for _, dlg in pairs(pane._propertiesDialogs) do
            if dlg.show  then dlg:show()  end
            if dlg.raise then dlg:raise() end
            return
        end
    end
    openPropsDialog(string.format("Properties: %s", pane.name), paneRows(pane), pane)
end

function Mux.showTabProperties(host, tab)
    -- Raise existing dialog rather than opening a duplicate.
    if tab._propertiesDialogs then
        for _, dlg in pairs(tab._propertiesDialogs) do
            if dlg.show  then dlg:show()  end
            if dlg.raise then dlg:raise() end
            return
        end
    end
    openPropsDialog(string.format("Tab: %s", tab.name), tabRows(host, tab), tab)
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
    closeExistingPropsDialogs(pane)
    openPropsDialog(string.format("Properties: %s", pane.name), paneRows(pane), pane, px, py)
end

refreshTabProperties = function(host, tab)
    local px, py = _captureDialogPos(tab)
    closeExistingPropsDialogs(tab)
    openPropsDialog(string.format("Tab: %s", tab.name), tabRows(host, tab), tab, px, py)
end

function Mux._showPropsCloseConfirm(message, onProceed)
    local confirmD = Mux.createDialog({
        title       = "Confirm Close",
        width       = 380, height = 140,
        closeable   = false,
        minimizable = false,
        contextMenu = false,
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