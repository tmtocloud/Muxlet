-- Muxlet — Native tab system
--
-- Tab label interaction model (mirrors AdjustableTabWindow exactly):
--
--   Single click  → activate tab content (onClick)
--   Click + drag  → drag tab; ghost follows cursor; release over a bar moves it
--   Double-click  → "chosen" mode: tab turns red, overlays appear on ALL bars.
--                   Hovering an overlay shows an insertion indicator (makeSpace).
--                   Clicking any overlay places the tab there.
--                   10-second timeout auto-cancels (like ATW's overlayTimer).
--
-- Key lesson from ATW: setMoveCallback fires on ANY mouse movement over a label
-- (Mudlet sets Qt mouse-tracking on all labels). Gate all drag logic behind
-- a `drag.clicked` flag that is true only while the left button is held.

local _closeTabPending = nil   -- {tab, pane, dlg} set before _applyContent for close-confirm dialog

Mux._movingTab          = nil    -- {tab, fromPane}  while in "chosen" double-click mode
Mux._tabOverlayTimer    = nil    -- auto-cancel timer id (like ATW's overlayTimer)
Mux._tabInsertIndicator = nil    -- full-tab-sized ghost shown in the gap
Mux._tabDragGhost       = nil    -- floating cursor-tracking ghost during drag
Mux._tabGapPane         = nil    -- pane whose tabs are currently resized to show gap

-- Registry of all tab-enabled hosts: both panes (keyed by pane.id) and sub-tab
-- host objects (keyed by their ._gid). Used so drag/overlay code reaches nested
-- tab bars without iterating only Mux._panes.
Mux._tabHosts = Mux._tabHosts or {}

-- MuxTab: a content surface that lives inside a host's tab viewport. Sibling of
-- MuxPane under MuxSurface — it has content/name/lifecycle and can host sub-tabs,
-- but none of a pane's chrome (no frame, titlebar, handles, or own placement).
-- init builds the three widgets a tab owns (content container, its background, and
-- the tab-bar label) and sets the shared surface fields. Host bookkeeping (inserting
-- into _tabs, wiring the label, activating) stays in MuxSurface:addTab.
MuxTab = Mux._class(MuxSurface)
Mux.Tab = MuxTab

function MuxTab:init(opts)
    opts = opts or {}
    local host  = opts.host
    local tabId = opts.id
    local theme = Mux.activeTheme()

    self.id          = tabId
    self.name        = opts.name
    self.pane        = host        -- back-reference to the hosting surface
    self.renamable   = true
    self.closeable   = true
    self.movable     = true
    self.contentable = true
    self.nameAlign   = "center"
    -- As a host, this flag gates whether right-click context menus appear on the
    -- tabs it contains (the same gate MuxPane:init sets). Without it, right-clicking
    -- a sub-tab does nothing, since the sub-tab's host is a MuxTab, not a pane.
    self.contextMenu = (opts.contextMenu ~= false)
    -- _gid gives unique widget-name prefixes if this tab later hosts sub-tabs.
    self._gid        = host._gid .. "_st" .. tabId

    local content = Geyser.Container:new({
        name = host._gid .. "_tc_" .. tabId,
        x = "0%", y = "0%", width = "100%", height = "100%",
    }, host._tabViewport)

    local contentBg = Geyser.Label:new({
        name = host._gid .. "_tcbg_" .. tabId,
        x = "0%", y = "0%", width = "100%", height = "100%", fillBg = 1,
    }, content)
    contentBg:setStyleSheet(theme.contentCss or "")
    MuxPane._echoTabPlaceholder(contentBg, self.name, host.id, tabId)
    content:hide()

    local label = Geyser.Label:new({
        name = host._gid .. "_tl_" .. tabId,
        sizePolicy = "Dynamic",
        -- fillBg = 0: don't autofill a square palette background. The tab CSS
        -- (background-color + border-radius) is the sole painter, so large radii
        -- (Pill/Circle) clip cleanly instead of showing a square fill underneath.
        x = "0%", y = "0%", width = "50%", height = "100%", fillBg = 0,
    }, host._tabBarBox)
    label:setStyleSheet(theme.tabInactiveCss or "")
    host:_echoTabLabel(label, self.name, false, false, theme)
    -- Re-echo with the hover text colour on enter/leave (Qt won't recolour rich
    -- text via ::hover). Reads live state so it tracks active + theme changes.
    local tabObj = self
    label:setOnEnter(function()
        local th = Mux.activeTheme()
        host:_echoTabLabel(label, tabObj.name, host._activeTabId == tabObj.id, false, th, tabObj.nameAlign, true)
    end)
    label:setOnLeave(function()
        local th = Mux.activeTheme()
        host:_echoTabLabel(label, tabObj.name, host._activeTabId == tabObj.id, false, th, tabObj.nameAlign, false)
    end)
    self.label     = label
    self.content   = content
    self.contentBg = contentBg
end

-- nameAlign is an optional 6th arg ("left", "center", "right"); defaults to "center".
function MuxSurface:_echoTabLabel(label, name, isActive, isChosen, theme, nameAlign, hovered)
    local fs = theme.tabFontSize or 11
    -- Text colour is set inline: Qt's QLabel::hover{color} doesn't recolour rich
    -- text, so hover is handled by re-echoing with the hover colour (see addTab).
    local tc
    if     isChosen then tc = theme.tabMovingTextColor   or "#ffaaaa"
    elseif hovered  then tc = theme.tabHoverTextColor     or "#ffffff"
    elseif isActive then tc = theme.tabActiveTextColor    or "#ffffff"
    else                 tc = theme.tabInactiveTextColor  or "#ffffff"
    end
    local spanFmt = "<span style='color:" .. tc .. ";font-size:" .. tostring(fs) .. "px;font-weight:bold;'>%s</span>"
    local span    = string.format(spanFmt, name)
    local align   = nameAlign or "center"
    if align == "left" then
        label:echo(string.format("<span style='margin-left:4px;'>%s</span>", span))
    elseif align == "right" then
        label:echo(string.format("<div style='text-align:right;margin-right:4px;'>%s</div>", span))
    else
        label:echo(string.format("<center>%s</center>", span))
    end
end

function MuxPane._echoTabPlaceholder(contentBg, tabName, paneId, tabId)
    local ds = "color:rgba(75,82,115,0.75);font-size:10px;font-family:'Consolas','Monaco',monospace;"
    local cs = "color:rgba(110,155,215,0.65);font-size:9px;font-family:'Consolas','Monaco',monospace;"
    local is = "color:rgba(140,185,255,0.55);font-size:9px;font-family:'Consolas','Monaco',monospace;"
    local ps = "color:rgba(90,98,138,0.5);font-size:9px;font-family:'Consolas','Monaco',monospace;"
    contentBg:echo(string.format(
        "<div align='center' style='padding-top:14%%;%s'>"
        .. "<span style='font-size:11px;color:rgba(90,98,138,0.85);font-weight:bold;'>%s</span>"
        .. "<br/>"
        .. "<span style='%s'>pane: %s &nbsp; tab: %s</span>"
        .. "<br/><br/>"
        .. "<span style='%s'>"
        .. "local t = panes['%s']:getTab('%s')<br/>"
        .. "-- attach content to t.content"
        .. "</span>"
        .. "<br/><br/>"
        .. "<span style='%s'>"
        .. "right-click tab label -> Content Library"
        .. "</span>"
        .. "</div>",
        ds, tabName,
        is, paneId or "pane_id", tabId or "tab_id",
        cs, paneId or "pane_id", tabId or "tab_id",
        ps))
end

function MuxSurface:_findTab(tabId)
    for i, tab in ipairs(self._tabs or {}) do
        if tab.id == tabId then return tab, i end
    end
end

function MuxSurface:getTab(tabId)
    return self:_findTab(tabId)
end

local function ensureIndicator()
    if Mux._tabInsertIndicator then return end
    Mux._tabInsertIndicator = Geyser.Label:new({
        name = "mux_tab_insert_bar", x = 0, y = 0, width = 80, height = 22, fillBg = 1,
    }, Geyser)
    Mux._tabInsertIndicator:hide()
end

-- Mirrors ATW's makeSpace(). excludeId skips the dragged tab so the other n-1
-- visible tabs fill n slots (preserving tab width), giving a clean same-bar preview.
-- Caller must call _clearDragSpace() to restore via organize() when done.
function MuxSurface:_makeDragSpace(insertIdx, excludeId)
    local box  = self._tabBarBox
    local barW = box:get_width()

    local visible = {}
    for _, t in ipairs(self._tabs) do
        if t.id ~= excludeId then visible[#visible+1] = t end
    end

    local total = #visible + 1
    if total < 1 then return end
    local slotW = math.floor(barW / total)
    if slotW < 1 then slotW = 1 end

    local x    = 0
    local slot = 1
    for _, t in ipairs(visible) do
        if slot == insertIdx then x = x + slotW end
        t.label:resize(slotW)
        t.label:move(x)
        x    = x + slotW
        slot = slot + 1
    end
    Mux._tabGapPane = self
end

-- Also re-echoes all tab labels because resize()/move() calls can clear label
-- HTML in some Mudlet builds.
function MuxSurface:_clearDragSpace()
    if not self._tabBarBox then return end
    self:_relayoutTabLabels()
    if Mux._tabGapPane == self then Mux._tabGapPane = nil end
    local theme = Mux.activeTheme()
    for _, tab in ipairs(self._tabs or {}) do
        if tab.label then
            local isActive = (self._activeTabId == tab.id)
            self:_echoTabLabel(tab.label, tab.name, isActive, false, theme, tab.nameAlign)
        end
    end
end

function Mux._showTabInsertIndicator(targetPane, insertIdx, tabName, excludeId)
    ensureIndicator()
    if Mux._tabGapPane and Mux._tabGapPane ~= targetPane then
        Mux._tabGapPane:_clearDragSpace()
    end
    targetPane:_makeDragSpace(insertIdx, excludeId)

    local theme = Mux.activeTheme()
    local tabH  = theme.tabBarHeight or 22
    local box   = targetPane._tabBarBox
    local bx    = box:get_x()
    local by    = targetPane._tabBar:get_y()
    local barW  = box:get_width()

    local n = 0
    for _, t in ipairs(targetPane._tabs) do
        if t.id ~= excludeId then n = n + 1 end
    end
    local slotW = math.floor(barW / (n + 1))
    local gapX  = bx + (insertIdx - 1) * slotW

    local ghostCss = theme.tabInsertGhostCss or [[
        QLabel {
            background-color: rgba(80, 140, 255, 0.18);
            border: 2px dashed rgba(100, 165, 255, 0.55);
            border-radius: 2px;
        }
    ]]
    -- Position and size first, then echo — resizeWindow can clear label HTML in
    -- some Mudlet builds, so the echo must be the last write before show().
    Mux._tabInsertIndicator:setStyleSheet(ghostCss)
    moveWindow("mux_tab_insert_bar", gapX, by)
    resizeWindow("mux_tab_insert_bar", math.max(20, slotW), tabH)
    local tc   = theme.tabInsertGhostTextColor or "rgba(130, 195, 255, 0.80)"
    local name = tabName or (Mux._movingTab and Mux._movingTab.tab.name) or "…"
    Mux._tabInsertIndicator:echo(string.format(
        "<center><span style='color:%s;font-size:11px;font-weight:bold;'>%s</span></center>",
        tc, name))
    Mux._tabInsertIndicator:show()
    Mux._tabInsertIndicator:raiseAll()
    Mux.raiseFloatingPanes()
end

function Mux._hideTabInsertIndicator()
    if Mux._tabInsertIndicator then Mux._tabInsertIndicator:hide() end
    if Mux._tabGapPane then Mux._tabGapPane:_clearDragSpace() end
end

local function ensureGhost()
    if Mux._tabDragGhost then return end
    Mux._tabDragGhost = Geyser.Label:new({
        name = "mux_tab_drag_ghost", x = 0, y = 0, width = 90, height = 22, fillBg = 1,
    }, Geyser)
    Mux._tabDragGhost:setStyleSheet([[
        background-color: rgba(38, 38, 58, 210);
        border: 1px solid rgba(100, 180, 255, 0.65);
        border-radius: 3px;
    ]])
    Mux._tabDragGhost:hide()
end

function Mux._showTabDragGhost(tabName, gx, gy)
    ensureGhost()
    local theme = Mux.activeTheme()
    local tabH  = theme.tabBarHeight or 22
    local tc    = theme.tabActiveTextColor or "#e1e1f2"
    Mux._tabDragGhost:echo(string.format(
        "<center><span style='color:%s;font-size:11px;font-weight:bold;'>%s</span></center>",
        tc, tabName))
    -- gx/gy are the ghost's top-left, computed by the caller as (globalX - grabLocalX/Y)
    -- so the cursor stays at the same position within the ghost as where the drag started.
    moveWindow("mux_tab_drag_ghost", gx, gy)
    resizeWindow("mux_tab_drag_ghost", 90, tabH)
    Mux._tabDragGhost:show()
    Mux._tabDragGhost:raiseAll()
end

function Mux._hideTabDragGhost()
    if Mux._tabDragGhost then Mux._tabDragGhost:hide() end
end

-- excludeId: skip this tab when counting slots (same-pane drag: dragged tab excluded).
-- Uses ATW-style round-to-nearest so the gap tracks the cursor midpoint, not edge.
function MuxSurface:_calcInsertIdx(gx, excludeId)
    local box  = self._tabBarBox
    local bx   = box:get_x()
    local bw   = box:get_width()
    local n    = 0
    for _, t in ipairs(self._tabs) do
        if t.id ~= excludeId then n = n + 1 end
    end
    if n == 0 then return 1 end
    local slotW = bw / (n + 1)
    local relX  = gx - bx
    local raw = relX / slotW
    return math.max(1, math.min(n + 1, math.floor(raw + 0.5) + 1))
end

local function tabBarAtCursor(gx, gy)
    for _, p in pairs(Mux._tabHosts) do
        if p._tabsEnabled and p._tabBar then
            local bx = p._tabBar:get_x();  local bw = p._tabBar:get_width()
            local by = p._tabBar:get_y();  local bh = p._tabBar:get_height()
            if gx >= bx and gx <= bx + bw and gy >= by and gy <= by + bh then
                return p
            end
        end
    end
end

-- Created once per pane. Hidden normally; shown on ALL bars when a tab is
-- double-clicked. The overlay sits above all tab labels in z-order so it
-- intercepts clicks/moves (same pattern as ATW showing overlay on all TabWindows).
local function getOrCreateOverlay(pane)
    if pane._tabMoveOverlay then return pane._tabMoveOverlay end

    pane._tabMoveOverlay = Geyser.Label:new({
        name = pane._gid .. "_tab_ovl",
        x = "0px", y = "0px", width = "100%", height = "100%", fillBg = 1,
    }, pane._tabBar)
    pane._tabMoveOverlay:setStyleSheet("background-color: rgba(0,0,0,0); border: none;")
    pane._tabMoveOverlay:hide()

    pane._tabMoveOverlay:setMoveCallback(function(event)
        if not Mux._movingTab then return end
        local mt        = Mux._movingTab
        local consX     = event.x + pane._tabMoveOverlay:get_x()
        local excludeId = (pane == mt.fromPane) and mt.tab.id or nil
        local idx       = pane:_calcInsertIdx(consX, excludeId)
        Mux._showTabInsertIndicator(pane, idx, mt.tab.name, excludeId)
        mt.currentTarget = pane
        mt.currentIdx    = idx
    end)

    pane._tabMoveOverlay:setOnLeave(function()
        if not Mux._movingTab then return end
        if Mux._movingTab.currentTarget == pane then
            Mux._movingTab.currentTarget = nil
            Mux._movingTab.currentIdx    = nil
            Mux._hideTabInsertIndicator()
        end
    end)

    pane._tabMoveOverlay:setClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        if not Mux._movingTab then return end
        local mt  = Mux._movingTab
        local idx = mt.currentIdx or (#pane._tabs + 1)
        Mux._resetOverlay()
        if mt.fromPane == pane then
            local _, fromIdx = pane:_findTab(mt.tab.id)
            if fromIdx and idx ~= fromIdx then
                pane:_reorderTab(fromIdx, idx)
            end
        else
            pane:_receiveTab(mt.tab, mt.fromPane, idx)
        end
    end)

    return pane._tabMoveOverlay
end

-- Hides or shows the add-tab button AND resizes the HBox to reclaim the space.
function MuxSurface:_setAddTabBtnVisible(visible)
    if not self._addTabBtn or not self._tabBarBox then return end
    if self._isSubTabHost then
        -- Sub-tab bars manage their own HBox width via _resizeSubTabBar;
        -- just show or hide the button without touching the HBox geometry.
        if visible then self._addTabBtn:show() else self._addTabBtn:hide() end
        return
    end
    local theme = Mux.activeTheme()
    local addW  = theme.tabAddBtnWidth or 24
    if visible then
        self._addTabBtn:show()
        self._tabBarBox:resize(Mux._fromEdgePx(addW), nil)
    else
        self._addTabBtn:hide()
        -- "-0px" = parent_width - 0: fills the full tab bar.
        self._tabBarBox:resize(Mux._fromEdgePx(0), nil)
    end
    self:_relayoutTabLabels()
end

-- Resize the HBox for a sub-tab host to be exactly numTabs×subTabWidth pixels
-- wide and then re-organize so each tab gets a fixed pixel width.  Sub-tab
-- dividers land at absolute pixel positions unrelated to the parent bar's
-- percentage-based dividers, so they never form a visual grid.
function MuxSurface:_resizeSubTabBar()
    if not self._isSubTabHost or not self._tabBarBox then return end
    local theme = Mux.activeTheme()
    local tabW  = theme.subTabWidth or 80
    local n     = #(self._tabs or {})
    if n > 0 then
        self._tabBarBox:resize(Mux._toPx(n * tabW), nil)
        self._tabBarBox:organize()
    end
end

-- Layout tab labels in the bar.  Sub-tab hosts delegate to _resizeSubTabBar
-- (fixed-width per tab).  Regular panes fill the full bar width while
-- guaranteeing each tab is at least as wide as its text: natural widths are
-- computed from the name length, any bar space beyond the natural total is
-- shared equally, and when the total natural width exceeds the bar the tabs
-- shrink proportionally down to minTabWidth.
function MuxSurface:_relayoutTabLabels()
    if not self._tabBarBox then return end
    if self._isSubTabHost then self:_resizeSubTabBar(); return end
    local tabs = self._tabs
    if not tabs or #tabs == 0 then return end
    local theme  = Mux.activeTheme()
    local charPx = theme.tabCharWidth or 8
    local minW   = theme.minTabWidth  or 50
    local padW   = theme.tabLabelPad  or 20
    local barW   = self._tabBarBox:get_width()
    local n      = #tabs
    local nats, total = {}, 0
    for _, tab in ipairs(tabs) do
        local w = math.max(minW, #(tab.name or "") * charPx + padW)
        nats[#nats + 1] = w
        total = total + w
    end
    local widths = {}
    if total <= barW then
        local extra  = barW - total
        local perTab = math.floor(extra / n)
        local rem    = barW - (total + perTab * n)
        for idx = 1, n do
            widths[idx] = nats[idx] + perTab + (idx <= rem and 1 or 0)
        end
    else
        for idx = 1, n do
            widths[idx] = math.max(minW, math.floor(nats[idx] / total * barW))
        end
    end
    local x = 0
    for idx, tab in ipairs(tabs) do
        tab.label:resize(widths[idx])
        tab.label:move(x)
        x = x + widths[idx]
    end
end

-- host may be a MuxPane or a tab object acting as a sub-tab host.
-- Both have .content and ._gid; sub-tab hosts also have ._isSubTabHost = true.
local function buildTabInfrastructure(host)
    local theme = Mux.activeTheme()
    local tabH  = theme.tabBarHeight   or 22
    local addW  = theme.tabAddBtnWidth or 24

    host._tabBar = Geyser.Label:new({
        name = host._gid .. "_tab_bar",
        x = "0px", y = "0px", width = "100%", height = Mux._toPx(tabH), fillBg = 1,
    }, host.content)
    host._tabBar:setStyleSheet(theme.tabBarCss or "")
    if not host._isSubTabHost then
        host._tabBar:setClickCallback(function(event)
            if Mux.raisePane then Mux.raisePane(host) end
        end)
    end

    host._tabBarBox = Geyser.HBox:new({
        name = host._gid .. "_tab_hbox",
        x = "0px", y = "0px", width = Mux._fromEdgePx(addW), height = "100%",
    }, host._tabBar)

    host._addTabBtn = Geyser.Label:new({
        name = host._gid .. "_tab_add",
        x = Mux._fromEdgePx(addW), y = "0px", width = Mux._toPx(addW), height = "100%", fillBg = 1,
    }, host._tabBar)
    host._addTabBtn:setStyleSheet(theme.tabAddBtnCss or "")
    local addTc = theme.tabAddBtnTextColor or "#b9c0dc"
    host._addTabBtn:echo(string.format(
        "<center><span style='color:%s;font-size:15px;font-weight:bold;'>+</span></center>",
        addTc))
    host._addTabBtn:setClickCallback(function(event)
        if event.button == "LeftButton" and not host.tabsLocked then
            host:addTab()
        end
    end)
    if host.tabsLocked then host:_setAddTabBtnVisible(false) end

    host._tabViewport = Geyser.Container:new({
        name = host._gid .. "_tab_vp",
        x = "0px", y = Mux._toPx(tabH), width = "100%", height = Mux._fromEdgePx(0),
    }, host.content)

    host.contentBg:hide()

    getOrCreateOverlay(host)
end

function MuxSurface:enableTabs(opts)
    opts = opts or {}
    -- Tab objects (sub-tab hosts) have a .pane back-reference; panes do not.
    -- Sub-tab hosts use a different code path for infrastructure setup.
    local isSubTabHost = (self.pane ~= nil)
    if self._tabsEnabled then return end
    -- Capture and fully remove existing pane content before building tab infrastructure.
    -- The inline partial teardown used to run after buildTabInfrastructure, leaving the
    -- old content widgets as live siblings of the new tab bar and viewport inside
    -- self.content — the tab infrastructure would cover them but they'd reappear when
    -- tabs were later removed.  Removing first keeps self.content clean.
    local priorContent = self._activeContent
    if priorContent then Mux._removeContent(self) end
    self._tabsEnabled  = true
    self._tabs         = self._tabs or {}
    self._activeTabId  = nil
    self._isSubTabHost = isSubTabHost
    Mux._tabHosts[self._gid] = self
    if self._tabBar then
        -- Infrastructure exists from a prior enableTabs(); just show it and restore the + button.
        self._tabBar:show()
        if self._tabViewport then self._tabViewport:show() end
        self.contentBg:hide()
    else
        buildTabInfrastructure(self)
    end
    -- Content now belongs in tabs; update button visibility (hides contentBtn via _contentEnabled).
    if self._syncButtons then self:_syncButtons(true) end
    if self._tabBar and not self.tabsLocked then self:_setAddTabBtnVisible(true) end
    if not opts.noDefaultTab and #self._tabs == 0 then
        local tab1 = self:addTab("Tab 1")
        if tab1 and priorContent then
            Mux._applyContent(tab1, priorContent)
        end
    end
    -- New tab-bar widgets must not appear above floating panes / dialogs.
    Mux.raiseFloatingPanes()
    Mux._log("MuxPane tabs enabled: %s (subHost=%s)", self.id or self._gid, tostring(isSubTabHost))
end

function MuxSurface:disableTabs()
    if not self._tabsEnabled then return end
    self._tabsEnabled = false
    Mux._tabHosts[self._gid] = nil
    if self._tabs and #self._tabs > 0 then
        -- Keep the tab bar visible so existing tabs can be dragged out.
        self:_setAddTabBtnVisible(false)
    else
        self:_hideTabBar()
    end
    Mux._log("MuxPane tabs disabled: %s", self.id or self._gid)
end

function MuxSurface:_hideTabBar()
    if self._tabBar      then self._tabBar:hide()      end
    if self._tabViewport then self._tabViewport:hide() end
    self.contentBg:show()
    self:_updatePlaceholder()
    -- Restore button visibility; _contentEnabled() now returns true so _syncButtons
    -- will show contentBtn if appropriate (respects compact_titlebar mode).
    if self._syncButtons then self:_syncButtons(true) end
end

function MuxSurface:_collapseIfDone()
    if self._tabsEnabled then return end
    if self._tabs and #self._tabs > 0 then return end
    self:_hideTabBar()
end

function MuxSurface:addTab(name, pos)
    if not self._tabsEnabled then self:enableTabs(); return end

    local tabId = Mux._newId("tab")
    name = name or string.format("Tab %d", #self._tabs + 1)
    pos  = pos  or (#self._tabs + 1)

    local tab = MuxTab:new({ host = self, id = tabId, name = name })

    table.insert(self._tabs, pos, tab)
    if pos < #self._tabs then self:_syncHBoxOrder() end
    self:_relayoutTabLabels()
    self:_wireTabLabel(tab)
    if not self._activeTabId then self:_activateTabObj(tab) end
    -- New tab content widgets must not appear above floating panes / dialogs.
    Mux.raiseFloatingPanes()
    Mux._scheduleAutoSave()
    Mux._log("addTab: %s '%s' pane=%s pos=%d", tabId, name, self.id, pos)
    return tab
end

function MuxSurface:removeTab(tabId)
    local tab, idx = self:_findTab(tabId)
    if not tab then return end
    if tab.closeable == false then Mux._warn("Tab '%s' is not closeable", tab.name); return end
    local isLast = (#self._tabs <= 1)
    if self._activeTabId == tabId then
        if not isLast then
            local ni = (idx < #self._tabs) and (idx + 1) or (idx - 1)
            self:_activateTabObj(self._tabs[ni])
        else
            self._activeTabId = nil
            tab.content:hide()
        end
    end
    self._tabBarBox:remove(tab.label)
    tab.label:hide()
    self:_relayoutTabLabels()
    if not (self._activeTabId == tabId) then tab.content:hide() end
    if tab._connScreen then tab._connScreen:hide() end
    if tab._connectionAware then
        local key = "tab_" .. self.id .. "_" .. tab.id
        Mux._connAware[key] = nil
    end
    if tab._activeContent and Mux._content then
        local def = Mux._content[tab._activeContent]
        if def and def.singleton and def._activeTargetRef == tab then
            def._activeTargetRef = nil
        end
    end
    if tab._tabsEnabled and tab._gid then
        Mux._tabHosts[tab._gid] = nil
    end
    -- Close any open properties dialogs for this tab.
    if tab._propertiesDialogs then
        for _, dlg in pairs(tab._propertiesDialogs) do
            pcall(function() dlg:close() end)
        end
        tab._propertiesDialogs = nil
    end
    if Mux.ui and Mux.ui.closeDropdown then Mux.ui.closeDropdown() end
    table.remove(self._tabs, idx)
    if self._isSubTabHost then self:_resizeSubTabBar() end
    Mux._freeId(tabId)
    if isLast and not self._tabsEnabled then
        -- Only collapse the tab bar when tabs have been fully disabled;
        -- with tabs still enabled the empty bar remains so the user can add more.
        self:_hideTabBar()
    end
    Mux._scheduleAutoSave()
end

-- Shows a confirmation popup before closing a tab.
-- Silently ignores non-closeable tabs. Calls removeTab on confirm.
function MuxSurface:_confirmCloseTab(tab)
    if not tab or tab.closeable == false then return end
    local doConfirm = Mux.settings.get("mux", "confirmTabClose")
    if doConfirm == nil then doConfirm = true end
    if not doConfirm then
        self:removeTab(tab.id)
        return
    end
    local confirmD = Mux.createDialog({
        title         = "Close Tab?",
        width         = 340, height = 140,
        closeable     = false,
        minimizable   = false,
        contextMenu   = false,
    })
    _closeTabPending = { tab = tab, pane = self, dlg = confirmD }
    Mux._applyContent(confirmD, "mux_close_tab_confirm")
end

function MuxSurface:activateTab(tabId)
    local tab = self:_findTab(tabId)
    if tab then self:_activateTabObj(tab) end
end

function MuxSurface:_activateTabObj(tab)
    local theme = Mux.activeTheme()
    if self._activeTabId and self._activeTabId ~= tab.id then
        local cur = self:_findTab(self._activeTabId)
        if cur then
            cur.label:setStyleSheet(theme.tabInactiveCss or "")
            self:_echoTabLabel(cur.label, cur.name, false, false, theme, cur.nameAlign)
            cur.content:hide()
        end
    end
    self._activeTabId = tab.id
    -- When the activated tab itself hosts sub-tabs, use a borderless-bottom style so
    -- the tab visually merges with the child tab bar below it (visual continuity).
    if tab._isSubTabHost or tab._tabsEnabled then
        tab.label:setStyleSheet(theme.tabActiveParentCss or theme.tabActiveCss or "")
        if tab._tabBar then
            tab._tabBar:setStyleSheet(theme.subTabBarCss or theme.tabBarCss or "")
        end
    else
        tab.label:setStyleSheet(theme.tabActiveCss or "")
    end
    self:_echoTabLabel(tab.label, tab.name, true, false, theme, tab.nameAlign)
    tab.content:show()
    if Mux._relayoutContent then Mux._relayoutContent(tab) end
    Mux._scheduleAutoSave()
end

function MuxSurface:renameTab(tabId, newName)
    local tab = self:_findTab(tabId)
    if not tab then return end
    if not tab.renamable then return end
    tab.name = newName
    local theme    = Mux.activeTheme()
    local isActive = (self._activeTabId == tabId)
    tab.label:setStyleSheet(isActive and (theme.tabActiveCss or "") or (theme.tabInactiveCss or ""))
    self:_echoTabLabel(tab.label, newName, isActive, false, theme, tab.nameAlign)
    if tab.contentBg and not tab._activeContent then
        MuxPane._echoTabPlaceholder(tab.contentBg, newName, self.id, tabId)
        tab.contentBg:show()
    end
    Mux._scheduleAutoSave()
end

-- Sets the name alignment for a tab and immediately refreshes its label.
function MuxSurface:setTabNameAlign(tabId, align)
    local tab = self:_findTab(tabId)
    if not tab then return end
    tab.nameAlign = align
    local theme    = Mux.activeTheme()
    local isActive = (self._activeTabId == tabId)
    self:_echoTabLabel(tab.label, tab.name, isActive, false, theme, align)
    Mux._scheduleAutoSave()
end

-- CRITICAL: setMoveCallback fires on ANY mouse movement (Mudlet has mouse-tracking
-- on all labels). Use drag.clicked (set true only on mousedown, false on mouseup)
-- to distinguish hover from drag. This is the same pattern ATW uses with
-- Adjustable.TabWindow.clicked.
function MuxSurface:_wireTabLabel(tab)
    local pane = self
    local drag = { clicked = false, active = false, startX = 0, startY = 0, middleCloseFired = false }

    tab.label:setClickCallback(function(event)
        if event.button == "RightButton" then
            if pane.contextMenu and tab.contextMenu ~= false then
                pane:_showTabContextMenu(tab, event.globalX, event.globalY)
            end
            return
        end
        if event.button == "MidButton" then
            drag.middleCloseFired = true
            pane:_confirmCloseTab(tab)
            return
        end
        if event.button ~= "LeftButton" then return end

        -- If overlay is active (double-click mode), clicks go to the overlay.
        if Mux._movingTab then return end

        drag.clicked = true
        drag.active  = false
        drag.startX  = event.globalX
        drag.startY  = event.globalY

        pane:_activateTabObj(tab)
        if Mux.raisePane then Mux.raisePane(pane) end
    end)

    tab.label:setMoveCallback(function(event)
        -- GATE: only run when button is physically held (drag.clicked).
        if not drag.clicked then return end
        if not tab.movable then return end
        if Mux._movingTab then return end

        local dx = math.abs(event.globalX - drag.startX)
        local dy = math.abs(event.globalY - drag.startY)

        if not drag.active then
            if dx < 5 and dy < 5 then return end
            drag.active = true
            local dropCss = Mux.activeTheme().tabDropTargetBarCss
                         or Mux.activeTheme().tabBarCss or ""
            for _, p in pairs(Mux._tabHosts) do
                if p ~= pane and p._tabsEnabled and p._tabBar then
                    p._tabBar:setStyleSheet(dropCss)
                end
            end
        end

        local cursorConsX = event.x + tab.label:get_x()
        local cursorConsY = event.y + tab.label:get_y()

        Mux._showTabDragGhost(tab.name, cursorConsX, cursorConsY)

        local targetPane = tabBarAtCursor(cursorConsX, cursorConsY)
        if targetPane then
            local excludeId = (targetPane == pane) and tab.id or nil
            local idx = targetPane:_calcInsertIdx(cursorConsX, excludeId)
            Mux._showTabInsertIndicator(targetPane, idx, tab.name, excludeId)
            drag.currentTarget = targetPane
            drag.currentIdx    = idx
        else
            Mux._hideTabInsertIndicator()
            drag.currentTarget = nil
            drag.currentIdx    = nil
        end
    end)

    tab.label:setReleaseCallback(function(event)
        if event.button == "MidButton" then
            if not drag.middleCloseFired then
                pane:_confirmCloseTab(tab)
            end
            drag.middleCloseFired = false
            return
        end
        if event.button ~= "LeftButton" then return end
        local wasDragging = drag.active
        drag.clicked = false
        drag.active  = false

        if not wasDragging then return end

        Mux._hideTabDragGhost()
        Mux._hideTabInsertIndicator()
        local theme = Mux.activeTheme()
        for _, p in pairs(Mux._tabHosts) do
            if p._tabsEnabled and p._tabBar then
                p._tabBar:setStyleSheet(theme.tabBarCss or "")
            end
        end

        local targetPane = drag.currentTarget
        local idx        = drag.currentIdx
        drag.currentTarget = nil
        drag.currentIdx    = nil
        if not targetPane then return end

        idx = idx or (#targetPane._tabs + 1)
        if targetPane == pane then
            local _, fromIdx = pane:_findTab(tab.id)
            if fromIdx and idx ~= fromIdx then
                pane:_reorderTab(fromIdx, idx)
            end
        else
            targetPane:_receiveTab(tab, pane, idx)
        end
    end)

    -- Mirrors ATW's onDoubleClick: mark tab as "chosen" (red), show overlay on
    -- ALL bars, set a 10-second auto-cancel.
    tab.label:setDoubleClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        if not tab.movable then return end

        if Mux._movingTab and Mux._movingTab.tab == tab then
            Mux._resetOverlay(); return
        end
        if Mux._movingTab then Mux._resetOverlay() end

        drag.clicked = false
        drag.active  = false

        Mux._movingTab = { tab = tab, fromPane = pane }

        local theme = Mux.activeTheme()
        tab.label:setStyleSheet(theme.tabMovingCss or "")
        pane:_echoTabLabel(tab.label, tab.name, false, true, theme, tab.nameAlign)

        for _, p in pairs(Mux._tabHosts) do
            if p._tabsEnabled and p._tabBar then
                p._tabBar:setStyleSheet(
                    theme.tabDropTargetBarCss or theme.tabBarCss or "")
                local ovl = getOrCreateOverlay(p)
                ovl:show()
                ovl:raiseAll()
            end
        end

        if Mux._tabOverlayTimer then killTimer(Mux._tabOverlayTimer) end
        Mux._tabOverlayTimer = tempTimer(10, function()
            Mux._tabOverlayTimer = nil
            if Mux._movingTab and Mux._movingTab.tab == tab then
                Mux._resetOverlay()
            end
        end)
    end)
end

-- Hides all overlays, restores tab bar styles, restores the chosen tab's
-- appearance, clears Mux._movingTab and the auto-cancel timer.
-- Mirrors ATW's resetOverlay.
function Mux._resetOverlay()
    if Mux._tabOverlayTimer then
        killTimer(Mux._tabOverlayTimer)
        Mux._tabOverlayTimer = nil
    end

    if Mux._tabGapPane then Mux._tabGapPane:_clearDragSpace() end
    Mux._hideTabInsertIndicator()

    local mt       = Mux._movingTab
    Mux._movingTab = nil

    local theme = Mux.activeTheme()
    for _, p in pairs(Mux._tabHosts) do
        if p._tabsEnabled then
            if p._tabBar         then p._tabBar:setStyleSheet(theme.tabBarCss or "") end
            if p._tabMoveOverlay then p._tabMoveOverlay:hide() end
        end
    end

    if mt and mt.tab and mt.fromPane then
        local isActive = (mt.fromPane._activeTabId == mt.tab.id)
        mt.tab.label:setStyleSheet(isActive
            and (theme.tabActiveCss or "")
            or  (theme.tabInactiveCss or ""))
        mt.fromPane:_echoTabLabel(mt.tab.label, mt.tab.name, isActive, false, theme, mt.tab.nameAlign)
    end
end

Mux._cancelTabMove = Mux._resetOverlay

function MuxSurface:_reorderTab(fromIdx, toIdx)
    if fromIdx == toIdx then return end
    local tab = table.remove(self._tabs, fromIdx)
    table.insert(self._tabs, toIdx, tab)
    self:_syncHBoxOrder()
    self:_relayoutTabLabels()
    Mux._scheduleAutoSave()
end

function MuxSurface:_syncHBoxOrder()
    local box = self._tabBarBox
    for i = #box.windows, 1, -1 do box.windows[i] = nil end
    for i, tab in ipairs(self._tabs) do box.windows[i] = tab.label.name end
end

function MuxSurface:_receiveTab(tab, fromPane, insertPos)
    if not tab.movable then return end
    if not self._tabsEnabled then self:enableTabs({ noDefaultTab = true }) end

    -- A tab's properties dialog binds to its host at open time; moving the tab to a
    -- new host would leave those bindings stale (toggles act on the old host). Close
    -- any open properties dialog for this tab so the user gets a correctly-bound one
    -- when they reopen it from the new host.
    if tab._propertiesDialogs then
        for _, dlg in pairs(tab._propertiesDialogs) do
            if dlg and dlg.close then dlg:close() end
        end
        tab._propertiesDialogs = nil
    end

    local _, srcIdx = fromPane:_findTab(tab.id)
    if not srcIdx then return end

    local srcNextTab = nil
    if fromPane._activeTabId == tab.id and #fromPane._tabs > 1 then
        local ni = (srcIdx < #fromPane._tabs) and (srcIdx + 1) or (srcIdx - 1)
        srcNextTab = fromPane._tabs[ni]
    end

    fromPane._tabBarBox:remove(tab.label)
    tab.label:hide()
    table.remove(fromPane._tabs, srcIdx)
    fromPane:_relayoutTabLabels()

    if fromPane._activeTabId == tab.id then
        fromPane._activeTabId = nil
        if srcNextTab then fromPane:_activateTabObj(srcNextTab) end
    end

    fromPane:_collapseIfDone()

    tab.content:changeContainer(self._tabViewport)
    tab.content:move("0%", "0%")
    tab.content:resize("100%", "100%")
    tab.pane = self
    if tab.contentBg and not tab._activeContent then
        MuxPane._echoTabPlaceholder(tab.contentBg, tab.name, self.id, tab.id)
        tab.contentBg:show()
    end

    local theme    = Mux.activeTheme()
    local newLabel = Geyser.Label:new({
        name = self._gid .. "_tl_" .. tab.id,
        sizePolicy = "Dynamic",
        x = "0%", y = "0%", width = "50%", height = "100%", fillBg = 1,
    }, self._tabBarBox)
    newLabel:setStyleSheet(theme.tabInactiveCss or "")
    self:_echoTabLabel(newLabel, tab.name, false, false, theme, tab.nameAlign)
    self._tabBarBox:organize()
    tab.label = newLabel

    insertPos = insertPos or (#self._tabs + 1)
    table.insert(self._tabs, insertPos, tab)
    self:_syncHBoxOrder()
    self:_relayoutTabLabels()

    self:_wireTabLabel(tab)
    self:_activateTabObj(tab)

    -- Re-apply active content after the cross-pane move. Geyser's auto_hidden
    -- flags on child widgets can survive the changeContainer/show cycle in an
    -- inconsistent state, leaving the content area blank. Calling remove then
    -- apply kills the old event handler and recreates the widget fresh so it is
    -- guaranteed visible and correctly positioned in the new pane.
    if tab._activeContent and Mux._content then
        local savedContent = tab._activeContent
        local def = Mux._content[savedContent]
        if def then
            if type(def.remove) == "function" then
                pcall(def.remove, tab)
            end
            tab._activeContent = nil
            if Mux._applyContent then
                Mux._applyContent(tab, savedContent)
            end
        end
    end

    Mux._scheduleAutoSave()
    Mux._log("_receiveTab: '%s' → '%s' pos=%d", tab.name, self.id, insertPos)
end

function MuxSurface:_showTabContextMenu(tab, gx, gy)
    local menu  = Mux._contextMenu
    local theme = Mux.activeTheme()
    menu.itemHeight = theme.contextMenuItemHeight or 28
    menu.menuWidth  = theme.contextMenuWidth      or 188

    local items = {}

    if tab.propertiesButton ~= false then
        items[#items+1] = { text = "⚙  Properties", fn = function()
            Mux.showTabProperties(self, tab)
        end }
    end

    local contentNames = Mux._listContent and Mux._listContent() or {}
    if #contentNames > 0 and tab.contentable ~= false then
        if #items > 0 then items[#items+1] = { sep = true } end
        local captureTab = tab
        items[#items+1] = { text = "▥  Content Library…", fn = function()
            Mux._showContentLibrary(captureTab)
        end }
    end

    if tab.closeable ~= false then
        if #items > 0 then items[#items+1] = { sep = true } end
        items[#items+1] = { text = "✕  Close Tab", danger = true,
            fn = function() self:_confirmCloseTab(tab) end }
    end

    if #items > 0 then
        Mux._showItemMenu(gx, gy, items)
    end
end

function MuxSurface:_serializeTabs()
    if not self._tabsEnabled or not self._tabs or #self._tabs == 0 then return nil end
    local tabs = {}
    for _, tab in ipairs(self._tabs) do
        local tabEntry = {
            name        = tab.name,
            renamable   = tab.renamable   ~= false,
            closeable   = tab.closeable   ~= false,
            movable     = tab.movable     ~= false,
            contentable = tab.contentable ~= false,
            nameAlign      = tab.nameAlign,
            _activeContent = tab._activeContent,
            contentState   = Mux._serializeContent and Mux._serializeContent(tab) or nil,
        }
        if tab._connectionAware          then tabEntry.connectionAware  = true  end
        if tab.tabsLocked                then tabEntry.tabsLocked       = true  end
        if tab.propertiesButton == false then tabEntry.propertiesButton = false end
        if tab._tabsEnabled then
            local subTabs, subActiveName = tab:_serializeTabs()
            if subTabs then
                tabEntry.tabs          = subTabs
                tabEntry.activeTabName = subActiveName
            end
        end
        tabs[#tabs+1] = tabEntry
    end
    local activeTabName
    if self._activeTabId then
        local at = self:_findTab(self._activeTabId)
        activeTabName = at and at.name
    end
    return tabs, activeTabName
end

-- Returns this surface's transferable state (name, active content, capability
-- flags, and any sub-tabs) as a plain table. This is the seam for a future
-- "tear a tab out into a real pane" feature: capture a tab's state, build a
-- MuxPane from it, and discard the tab. Not used yet — kept minimal on purpose.
function MuxSurface:_captureState()
    local state = {
        name           = self.name,
        _activeContent = self._activeContent,
        renamable      = self.renamable   ~= false,
        closeable      = self.closeable    ~= false,
        movable        = self.movable      ~= false,
        contentable    = self.contentable  ~= false,
        nameAlign      = self.nameAlign,
    }
    if self._tabsEnabled then
        state.tabs, state.activeTabName = self:_serializeTabs()
    end
    return state
end

function MuxSurface:_applyTabTheme()
    if not self._tabsEnabled or not self._tabs then return end
    local theme = Mux.activeTheme()
    if self._tabBar    then self._tabBar:setStyleSheet(theme.tabBarCss or "") end
    if self._addTabBtn then
        self._addTabBtn:setStyleSheet(theme.tabAddBtnCss or "")
        local tc = theme.tabAddBtnTextColor or "#b9c0dc"
        self._addTabBtn:echo(string.format(
            "<center><span style='color:%s;font-size:15px;font-weight:bold;'>+</span></center>", tc))
    end
    for _, tab in ipairs(self._tabs) do
        local isActive = (self._activeTabId == tab.id)
        tab.label:setStyleSheet(isActive and (theme.tabActiveCss or "") or (theme.tabInactiveCss or ""))
        self:_echoTabLabel(tab.label, tab.name, isActive, false, theme, tab.nameAlign)
        if tab.contentBg then tab.contentBg:setStyleSheet(theme.contentCss or "") end
        if self._refreshTabConnScreen then self:_refreshTabConnScreen(tab) end
    end
    self:_relayoutTabLabels()
end

Mux.registerContent("mux_close_tab_confirm", {
    name     = "Close Tab Confirm",
    internal = true,
    apply = function(target)
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        if not _closeTabPending then return end
        local pending = _closeTabPending
        _closeTabPending = nil
        local tab, pane, dlg = pending.tab, pending.pane, pending.dlg

        local cw = target.content:get_width()
        if cw < 50 then cw = (target.floatW or 340) - 4 end
        local body = Geyser.Label:new({
            name=target._gid.."_body", x=10, y=10, width=cw-20, height=36,
        }, target.content)
        body:setStyleSheet(Mux.dialogCss.body)
        body:rawEcho(string.format("Close tab <b>%s</b>?", tab.name))

        local btnProceed = Geyser.Label:new({
            name=target._gid.."_proceed", x=20, y=54, width=135, height=34,
        }, target.content)
        btnProceed:setStyleSheet(Mux.dialogCss.buttonDanger)
        btnProceed:rawEcho("<center>Proceed</center>")
        Mux.wireDialogButton(btnProceed, Mux.dialogCss.buttonDanger, Mux.dialogCss.buttonDangerHover)
        btnProceed:setClickCallback(function()
            dlg:close()
            pane:removeTab(tab.id)
        end)

        local btnCancel = Geyser.Label:new({
            name=target._gid.."_cancel", x=185, y=54, width=135, height=34,
        }, target.content)
        btnCancel:setStyleSheet(Mux.dialogCss.buttonPrimary)
        btnCancel:rawEcho("<center>Cancel</center>")
        Mux.wireDialogButton(btnCancel, Mux.dialogCss.buttonPrimary, Mux.dialogCss.buttonPrimaryHover)
        btnCancel:setClickCallback(function() dlg:close() end)
        target._autoFitHeight = 98
    end,
    remove = function(_) end,
})

Mux._log("mux_tabs loaded")