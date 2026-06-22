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


-- ── Property definitions ──────────────────────────────────────────────────────

local function paneRows(pane)
    local rows = {}

    -- Read-only live geometry (kept first so the poll can refresh row 1).
    rows[#rows+1] = {
        label  = "Position & Size",
        desc   = "Live screen geometry — updates as you move/resize. Use it to find a snap target for a floating pane.",
        type   = "readOnly",
        readFn = function() return _geomString(pane) end,
    }

    rows[#rows+1] = {
        label      = "Anchorable",
        desc       = "Allow this pane to be anchored to other panes' edges. When on, right-click the pane → Anchor mode, then drag to an edge or corner. Independent of embedding.",
        type       = "toggle",
        trueLabel  = "Yes",
        falseLabel = "No",
        readFn     = function() return pane.anchorable ~= false end,
        writeFn    = function(v)
            pane.anchorable = v
            if not v then pane:removeAnchor() end
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
    return rows
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

    local dialogW = 380

    local contentH = Mux.ui.formHeight(rows)

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

    -- Live-refresh the geometry readout (row 1) every 0.5s while the dialog is
    -- open. Only for panes (tabs have no geometry row); refreshing a read-only
    -- row re-reads its value without disturbing any field being edited.
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
    closeExistingPropsDialogs(pane)
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