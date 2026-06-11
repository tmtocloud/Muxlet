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
-- (Mudlet sets Qt mouse-tracking on all labels).  Gate all drag logic behind
-- a `drag.clicked` flag that is true only while the left button is held.

-- ── Global move state ─────────────────────────────────────────────────────────
Mux._movingTab          = nil    -- {tab, fromPane}  while in "chosen" double-click mode
Mux._tabOverlayTimer    = nil    -- auto-cancel timer id (like ATW's overlayTimer)
Mux._tabInsertIndicator = nil    -- full-tab-sized ghost shown in the gap
Mux._tabDragGhost       = nil    -- floating cursor-tracking ghost during drag
Mux._tabGapPane         = nil    -- pane whose tabs are currently resized to show gap

-- ── Echo helper ───────────────────────────────────────────────────────────────

function MuxPane:_echoTabLabel(label, name, isActive, isChosen, theme)
    local tc
    if isChosen  then tc = theme.tabMovingTextColor   or "#ffaaaa"
    elseif isActive then tc = theme.tabActiveTextColor   or "#e1e1f2"
    else              tc = theme.tabInactiveTextColor or "#afb4cd"
    end
    -- Use <span style='color:...'> instead of <font color='...'> so rgba() values
    -- are parsed correctly by Qt's CSS engine (Qt ignores rgba in HTML color attr).
    label:echo(string.format(
        "<center><span style='color:%s;font-size:11px;font-weight:bold;'>%s</span></center>",
        tc, name))
end

-- Writes developer-facing placeholder HTML into a tab's contentBg label.
-- Extracted so both addTab and renameTab share the same copy.
-- paneId and tabId are included in the snippet so it is immediately copy-pasteable.
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
        .. "right-click tab label -> Add Content"
        .. "</span>"
        .. "</div>",
        ds, tabName,
        is, paneId or "pane_id", tabId or "tab_id",
        cs, paneId or "pane_id", tabId or "tab_id",
        ps))
end

function MuxPane:_findTab(tabId)
    for i, tab in ipairs(self._tabs or {}) do
        if tab.id == tabId then return tab, i end
    end
end

function MuxPane:getTab(tabId)
    return self:_findTab(tabId)
end

-- ── Insert ghost (washed-out tab preview at drop position) ────────────────────

local function ensureIndicator()
    if Mux._tabInsertIndicator then return end
    Mux._tabInsertIndicator = Geyser.Label:new({
        name = "mux_tab_insert_bar", x = 0, y = 0, width = 80, height = 22, fillBg = 1,
    }, Geyser)
    Mux._tabInsertIndicator:hide()
end

-- ── ATW-style gap: resize tabs in a bar to leave a slot at insertIdx ─────────
-- Mirrors ATW's makeSpace().  excludeId skips the dragged tab so the other n-1
-- visible tabs fill n slots (preserving tab width), giving a clean same-bar preview.
-- Caller must call _clearDragSpace() to restore via organize() when done.
function MuxPane:_makeDragSpace(insertIdx, excludeId)
    local box  = self._tabBarBox
    local barW = box:get_width()

    -- Collect tabs that will be visible in the bar (exclude the dragged one).
    local visible = {}
    for _, t in ipairs(self._tabs) do
        if t.id ~= excludeId then visible[#visible+1] = t end
    end

    local total = #visible + 1      -- n visible + 1 gap = n+1 slots
    if total < 1 then return end
    local slotW = math.floor(barW / total)
    if slotW < 1 then slotW = 1 end

    local x    = 0
    local slot = 1
    for _, t in ipairs(visible) do
        if slot == insertIdx then x = x + slotW end  -- leave gap here
        t.label:resize(slotW)
        t.label:move(x)
        x    = x + slotW
        slot = slot + 1
    end
    Mux._tabGapPane = self
end

-- Restore equal tab sizing in this pane's bar after a drag/move operation.
-- Also re-echoes all tab labels because resize()/move() calls can clear label
-- HTML in some Mudlet builds.
function MuxPane:_clearDragSpace()
    if not self._tabBarBox then return end
    self._tabBarBox:organize()
    if Mux._tabGapPane == self then Mux._tabGapPane = nil end
    local theme = Mux.activeTheme()
    for _, tab in ipairs(self._tabs or {}) do
        if tab.label then
            local isActive = (self._activeTabId == tab.id)
            self:_echoTabLabel(tab.label, tab.name, isActive, false, theme)
        end
    end
end

-- Position the insert-indicator ghost in the gap created by _makeDragSpace.
-- excludeId: the dragged tab's id (used to compute the correct slot width).
function Mux._showTabInsertIndicator(targetPane, insertIdx, tabName, excludeId)
    ensureIndicator()
    -- If the gap was in a different pane, restore it first.
    if Mux._tabGapPane and Mux._tabGapPane ~= targetPane then
        Mux._tabGapPane:_clearDragSpace()
    end
    -- Build the gap in the target bar.
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

-- ── Drag ghost ────────────────────────────────────────────────────────────────

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

-- ── Insertion-index calculation ───────────────────────────────────────────────

-- excludeId: skip this tab when counting slots (same-pane drag: dragged tab excluded).
-- Uses ATW-style round-to-nearest so the gap tracks the cursor midpoint, not edge.
function MuxPane:_calcInsertIdx(gx, excludeId)
    local box  = self._tabBarBox
    local bx   = box:get_x()
    local bw   = box:get_width()
    local n    = 0
    for _, t in ipairs(self._tabs) do
        if t.id ~= excludeId then n = n + 1 end
    end
    if n == 0 then return 1 end
    local slotW = bw / (n + 1)   -- n visible + 1 gap
    local relX  = gx - bx
    -- Round to nearest (ATW: gap jumps when cursor crosses midpoint of each slot)
    local raw = relX / slotW
    return math.max(1, math.min(n + 1, math.floor(raw + 0.5) + 1))
end

-- ── Hit-test: which tab bar is under the cursor? ──────────────────────────────

local function tabBarAtCursor(gx, gy)
    for _, p in pairs(Mux._panes) do
        if p._tabsEnabled and p._tabBar then
            local bx = p._tabBar:get_x();  local bw = p._tabBar:get_width()
            local by = p._tabBar:get_y();  local bh = p._tabBar:get_height()
            if gx >= bx and gx <= bx + bw and gy >= by and gy <= by + bh then
                return p
            end
        end
    end
end

-- ── Overlay per pane (for double-click "chosen" mode) ────────────────────────
-- Created once per pane.  Hidden normally; shown on ALL bars when a tab is
-- double-clicked (same as ATW showing overlay on all TabWindows).
-- The overlay sits above all tab labels in z-order so it intercepts clicks/moves.

local function getOrCreateOverlay(pane)
    if pane._tabMoveOverlay then return pane._tabMoveOverlay end

    pane._tabMoveOverlay = Geyser.Label:new({
        name = pane._gid .. "_tab_ovl",
        x = "0px", y = "0px", width = "100%", height = "100%", fillBg = 1,
    }, pane._tabBar)
    pane._tabMoveOverlay:setStyleSheet("background-color: rgba(0,0,0,0); border: none;")
    pane._tabMoveOverlay:hide()

    -- Hover over this overlay → create gap + position indicator at insertion point.
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

    -- Cursor leaves overlay → clear gap and hide indicator for this bar.
    pane._tabMoveOverlay:setOnLeave(function()
        if not Mux._movingTab then return end
        if Mux._movingTab.currentTarget == pane then
            Mux._movingTab.currentTarget = nil
            Mux._movingTab.currentIdx    = nil
            Mux._hideTabInsertIndicator()
        end
    end)

    -- Click on overlay → place the chosen tab at the current gap position.
    pane._tabMoveOverlay:setClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        if not Mux._movingTab then return end
        local mt  = Mux._movingTab
        local idx = mt.currentIdx or (#pane._tabs + 1)
        Mux._resetOverlay()   -- clears gap + overlays before mutating _tabs
        if mt.fromPane == pane then
            local _, fromIdx = pane:_findTab(mt.tab.id)
            -- idx is already in the excludeId-reduced context, so no (idx-1) correction.
            if fromIdx and idx ~= fromIdx then
                pane:_reorderTab(fromIdx, idx)
            end
        else
            pane:_receiveTab(mt.tab, mt.fromPane, idx)
        end
    end)

    return pane._tabMoveOverlay
end

-- ── Add-button visibility helper ─────────────────────────────────────────────
-- Hides or shows the add-tab button AND resizes the HBox to reclaim the space.

function MuxPane:_setAddTabBtnVisible(visible)
    if not self._addTabBtn or not self._tabBarBox then return end
    local theme = Mux.activeTheme()
    local addW  = theme.tabAddBtnWidth or 24
    if visible then
        self._addTabBtn:show()
        self._tabBarBox:resize(Mux._pxNeg(addW), nil)
    else
        self._addTabBtn:hide()
        -- "-0px" = parent_width - 0: fills the full tab bar.
        self._tabBarBox:resize(Mux._pxNeg(0), nil)
    end
    self._tabBarBox:organize()
end

-- ── Tab bar construction ──────────────────────────────────────────────────────

local function buildTabInfrastructure(pane)
    local theme = Mux.activeTheme()
    local tabH  = theme.tabBarHeight   or 22
    local addW  = theme.tabAddBtnWidth or 24

    pane._tabBar = Geyser.Label:new({
        name = pane._gid .. "_tab_bar",
        x = "0px", y = "0px", width = "100%", height = Mux._px(tabH), fillBg = 1,
    }, pane.content)
    pane._tabBar:setStyleSheet(theme.tabBarCss or "")
    -- Clicking anywhere on the tab bar (including empty space) focuses the pane.
    pane._tabBar:setClickCallback(function()
        if Mux.setFocus then Mux.setFocus(pane) end
    end)

    pane._tabBarBox = Geyser.HBox:new({
        name = pane._gid .. "_tab_hbox",
        x = "0px", y = "0px", width = Mux._pxNeg(addW), height = "100%",
    }, pane._tabBar)

    pane._addTabBtn = Geyser.Label:new({
        name = pane._gid .. "_tab_add",
        x = Mux._pxNeg(addW), y = "0px", width = Mux._px(addW), height = "100%", fillBg = 1,
    }, pane._tabBar)
    pane._addTabBtn:setStyleSheet(theme.tabAddBtnCss or "")
    local addTc = theme.tabAddBtnTextColor or "#b9c0dc"
    pane._addTabBtn:echo(string.format(
        "<center><span style='color:%s;font-size:15px;font-weight:bold;'>+</span></center>",
        addTc))
    pane._addTabBtn:setClickCallback(function(event)
        if event.button == "LeftButton" and not pane.locked then pane:addTab() end
    end)
    -- If the pane is locked, hide button and expand tab area from the start.
    if pane.locked then pane:_setAddTabBtnVisible(false) end

    pane._tabViewport = Geyser.Container:new({
        name = pane._gid .. "_tab_vp",
        x = "0px", y = Mux._px(tabH), width = "100%", height = Mux._pxNeg(tabH),
    }, pane.content)

    pane.contentBg:hide()

    -- Pre-create overlay so it is z-above all tab labels (created last).
    getOrCreateOverlay(pane)
end

-- ── Enable / disable ──────────────────────────────────────────────────────────

function MuxPane:enableTabs(opts)
    opts = opts or {}
    if self._tabsEnabled then return end
    if self.mainConsoleHost or self.permanentFloat or self.noTabs then
        Mux._warn("MuxPane '%s': this pane cannot use tabs", self.name)
        return
    end
    self._tabsEnabled = true
    self._tabs        = self._tabs or {}
    self._activeTabId = nil
    buildTabInfrastructure(self)
    if not opts.noDefaultTab and #self._tabs == 0 then
        self:addTab("Tab 1")
    end
    Mux._log("MuxPane tabs enabled: %s", self.id)
end

function MuxPane:disableTabs()
    if not self._tabsEnabled then return end
    self._tabsEnabled = false
    if self._tabs and #self._tabs > 0 then
        -- Keep the tab bar visible so existing tabs can be dragged out.
        -- Hide only the add button (and reclaim its space, same as locked).
        self:_setAddTabBtnVisible(false)
    else
        self:_hideTabBar()
    end
    Mux._log("MuxPane tabs disabled: %s", self.id)
end

-- Fully hide the tab bar infrastructure and restore the placeholder.
-- Called once no tabs remain after disableTabs().
function MuxPane:_hideTabBar()
    if self._tabBar      then self._tabBar:hide()      end
    if self._tabViewport then self._tabViewport:hide() end
    self.contentBg:show()
    self:_updatePlaceholder()
end

-- After a tab is moved out, collapse the bar if tabs are disabled and none remain.
function MuxPane:_collapseIfDone()
    if self._tabsEnabled then return end
    if self._tabs and #self._tabs > 0 then return end
    self:_hideTabBar()
end

-- ── Add / remove ─────────────────────────────────────────────────────────────

function MuxPane:addTab(name, pos)
    if not self._tabsEnabled then self:enableTabs(); return end

    local theme = Mux.activeTheme()
    local tabId = Mux._newId("tab")
    name = name or string.format("Tab %d", #self._tabs + 1)
    pos  = pos  or (#self._tabs + 1)

    local content = Geyser.Container:new({
        name = self._gid .. "_tc_" .. tabId,
        x = "0%", y = "0%", width = "100%", height = "100%",
    }, self._tabViewport)

    local contentBg = Geyser.Label:new({
        name = self._gid .. "_tcbg_" .. tabId,
        x = "0%", y = "0%", width = "100%", height = "100%", fillBg = 1,
    }, content)
    contentBg:setStyleSheet(theme.contentCss or "")
    MuxPane._echoTabPlaceholder(contentBg, name, self.id, tabId)
    content:hide()

    local label = Geyser.Label:new({
        name = self._gid .. "_tl_" .. tabId,
        sizePolicy = "Dynamic",
        x = "0%", y = "0%", width = "50%", height = "100%", fillBg = 1,
    }, self._tabBarBox)
    label:setStyleSheet(theme.tabInactiveCss or "")
    self:_echoTabLabel(label, name, false, false, theme)
    self._tabBarBox:organize()

    local tab = {
        id = tabId, name = name, locked = false, pane = self,
        label = label, content = content, contentBg = contentBg,
    }
    table.insert(self._tabs, pos, tab)
    if pos < #self._tabs then self:_syncHBoxOrder() end
    self:_wireTabLabel(tab)
    if not self._activeTabId then self:_activateTabObj(tab) end
    Mux._scheduleAutoSave()
    Mux._log("addTab: %s '%s' pane=%s pos=%d", tabId, name, self.id, pos)
    return tab
end

function MuxPane:removeTab(tabId)
    local tab, idx = self:_findTab(tabId)
    if not tab then return end
    if tab.locked then Mux._warn("Tab '%s' is locked", tab.name); return end
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
    self._tabBarBox:organize()
    if not (self._activeTabId == tabId) then tab.content:hide() end
    if tab._connScreen then tab._connScreen:hide() end
    if tab._connectionAware then
        local key = "tab_" .. self.id .. "_" .. tab.id
        Mux._connAware[key] = nil
    end
    -- Clear singleton content tracking if this tab held singleton content.
    if tab._activeContent and Mux._content then
        local def = Mux._content[tab._activeContent]
        if def and def.singleton and def._activeTargetRef == tab then
            def._activeTargetRef = nil
        end
    end

    table.remove(self._tabs, idx)
    Mux._freeId(tabId)
    -- After removing the last tab, show the pane-level placeholder.
    if isLast then
        self.contentBg:show()
        self:_updatePlaceholder()
    end
    Mux._scheduleAutoSave()
end

-- ── Activate ─────────────────────────────────────────────────────────────────

function MuxPane:activateTab(tabId)
    local tab = self:_findTab(tabId)
    if tab then self:_activateTabObj(tab) end
end

function MuxPane:_activateTabObj(tab)
    local theme = Mux.activeTheme()
    if self._activeTabId and self._activeTabId ~= tab.id then
        local cur = self:_findTab(self._activeTabId)
        if cur then
            cur.label:setStyleSheet(theme.tabInactiveCss or "")
            self:_echoTabLabel(cur.label, cur.name, false, false, theme)
            cur.content:hide()
        end
    end
    self._activeTabId = tab.id
    tab.label:setStyleSheet(theme.tabActiveCss or "")
    self:_echoTabLabel(tab.label, tab.name, true, false, theme)
    tab.content:show()
    Mux._scheduleAutoSave()
end

-- ── Rename ────────────────────────────────────────────────────────────────────

function MuxPane:renameTab(tabId, newName)
    local tab = self:_findTab(tabId)
    if not tab then return end
    tab.name = newName
    local theme    = Mux.activeTheme()
    local isActive = (self._activeTabId == tabId)
    tab.label:setStyleSheet(isActive and (theme.tabActiveCss or "") or (theme.tabInactiveCss or ""))
    self:_echoTabLabel(tab.label, newName, isActive, false, theme)
    if tab.contentBg and not tab._activeContent then
        MuxPane._echoTabPlaceholder(tab.contentBg, newName, self.id, tabId)
        tab.contentBg:show()
    end
    Mux._scheduleAutoSave()
end

-- ── Wire tab label interactions ───────────────────────────────────────────────
-- CRITICAL: setMoveCallback fires on ANY mouse movement (Mudlet has mouse-tracking
-- on all labels).  Use drag.clicked (set true only on mousedown, false on mouseup)
-- to distinguish hover from drag.  This is the same pattern ATW uses with
-- Adjustable.TabWindow.clicked.

function MuxPane:_wireTabLabel(tab)
    local pane = self
    local drag = { clicked = false, active = false, startX = 0, startY = 0 }

    -- ── onClick (mousedown) ───────────────────────────────────────────────────
    tab.label:setClickCallback(function(event)
        if event.button == "RightButton" then
            pane:_showTabContextMenu(tab, event.globalX, event.globalY)
            return
        end
        if event.button ~= "LeftButton" then return end

        -- Gate: if overlay is active (double-click mode), clicks go to the overlay,
        -- not here.  But just in case: if somehow we get a click while _movingTab
        -- is set, ignore it and let the overlay handle it.
        if Mux._movingTab then return end

        -- Record drag-start position (needed for threshold check in setMoveCallback).
        drag.clicked = true
        drag.active  = false
        drag.startX  = event.globalX
        drag.startY  = event.globalY

        -- Activate tab on press (same as ATW's onClick activating immediately).
        pane:_activateTabObj(tab)
        -- Clicking a tab also focuses the pane (needed when titlebar is hidden).
        if Mux.setFocus then Mux.setFocus(pane) end
    end)

    -- ── onMove (mousemove while button held OR hover — gated by drag.clicked) ──
    tab.label:setMoveCallback(function(event)
        -- GATE: only run when button is physically held (drag.clicked).
        if not drag.clicked then return end
        if pane.locked then return end
        if Mux._movingTab then return end  -- already in double-click mode

        local dx = math.abs(event.globalX - drag.startX)
        local dy = math.abs(event.globalY - drag.startY)

        if not drag.active then
            if dx < 5 and dy < 5 then return end   -- threshold not yet crossed
            drag.active = true
            -- Light drop-target highlight on other bars.
            local dropCss = Mux.activeTheme().tabDropTargetBarCss
                         or Mux.activeTheme().tabBarCss or ""
            for _, p in pairs(Mux._panes) do
                if p ~= pane and p._tabsEnabled and p._tabBar then
                    p._tabBar:setStyleSheet(dropCss)
                end
            end
        end

        -- Convert screen coords to console coords via label-local + label-absolute.
        local cursorConsX = event.x + tab.label:get_x()
        local cursorConsY = event.y + tab.label:get_y()

        -- Floating cursor ghost — keeps dragging visually obvious.
        Mux._showTabDragGhost(tab.name, cursorConsX, cursorConsY)

        local targetPane = tabBarAtCursor(cursorConsX, cursorConsY)
        if targetPane then
            -- For same-pane drag, exclude the dragged tab so the gap is sized correctly.
            local excludeId = (targetPane == pane) and tab.id or nil
            local idx = targetPane:_calcInsertIdx(cursorConsX, excludeId)
            Mux._showTabInsertIndicator(targetPane, idx, tab.name, excludeId)
            drag.currentTarget = targetPane
            drag.currentIdx    = idx
        else
            Mux._hideTabInsertIndicator()   -- also clears gap via _clearDragSpace
            drag.currentTarget = nil
            drag.currentIdx    = nil
        end
    end)

    -- ── onRelease (mouseup) ───────────────────────────────────────────────────
    tab.label:setReleaseCallback(function(event)
        if event.button ~= "LeftButton" then return end
        local wasDragging = drag.active
        drag.clicked = false
        drag.active  = false

        if not wasDragging then return end   -- was just a click; tab already activated above

        -- Clean up all drag visuals (gap restored via _hideTabInsertIndicator).
        Mux._hideTabDragGhost()
        Mux._hideTabInsertIndicator()
        local theme = Mux.activeTheme()
        for _, p in pairs(Mux._panes) do
            if p._tabsEnabled and p._tabBar then
                p._tabBar:setStyleSheet(theme.tabBarCss or "")
            end
        end

        local targetPane = drag.currentTarget
        local idx        = drag.currentIdx
        drag.currentTarget = nil
        drag.currentIdx    = nil
        if not targetPane then return end   -- released outside any tab bar

        idx = idx or (#targetPane._tabs + 1)
        if targetPane == pane then
            local _, fromIdx = pane:_findTab(tab.id)
            -- idx is already in the excludeId-reduced context, so no (idx-1) correction.
            if fromIdx and idx ~= fromIdx then
                pane:_reorderTab(fromIdx, idx)
            end
        else
            targetPane:_receiveTab(tab, pane, idx)
        end
    end)

    -- ── onDoubleClick ─────────────────────────────────────────────────────────
    -- Mirrors ATW's onDoubleClick: mark tab as "chosen" (red), show overlay on
    -- ALL bars (including this pane's own bar), set a 10-second auto-cancel.
    tab.label:setDoubleClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        if tab.locked or pane.locked then return end

        -- Double-click while already in chosen mode → cancel (ATW behaviour when
        -- double-clicking the chosen tab a second time isn't standard, but we
        -- treat it as toggle-off for convenience).
        if Mux._movingTab and Mux._movingTab.tab == tab then
            Mux._resetOverlay(); return
        end
        if Mux._movingTab then Mux._resetOverlay() end

        -- Cancel any in-progress drag.
        drag.clicked = false
        drag.active  = false

        Mux._movingTab = { tab = tab, fromPane = pane }

        -- Apply "chosen" (red) style.
        local theme = Mux.activeTheme()
        tab.label:setStyleSheet(theme.tabMovingCss or "")
        pane:_echoTabLabel(tab.label, tab.name, false, true, theme)

        -- Show overlay on ALL bars (ATW shows overlay on all TabWindows).
        for _, p in pairs(Mux._panes) do
            if p._tabsEnabled and p._tabBar then
                p._tabBar:setStyleSheet(
                    theme.tabDropTargetBarCss or theme.tabBarCss or "")
                local ovl = getOrCreateOverlay(p)
                ovl:show()
                ovl:raiseAll()
            end
        end

        -- 10-second auto-cancel, same as ATW's overlayTimer.
        if Mux._tabOverlayTimer then killTimer(Mux._tabOverlayTimer) end
        Mux._tabOverlayTimer = tempTimer(10, function()
            Mux._tabOverlayTimer = nil
            if Mux._movingTab and Mux._movingTab.tab == tab then
                Mux._resetOverlay()
            end
        end)
    end)
end

-- ── resetOverlay (mirrors ATW's resetOverlay) ─────────────────────────────────
-- Hides all overlays, restores tab bar styles, restores the chosen tab's
-- appearance, clears Mux._movingTab and the auto-cancel timer.

function Mux._resetOverlay()
    if Mux._tabOverlayTimer then
        killTimer(Mux._tabOverlayTimer)
        Mux._tabOverlayTimer = nil
    end

    -- Clear any active drag gap before hiding overlays.
    if Mux._tabGapPane then Mux._tabGapPane:_clearDragSpace() end
    Mux._hideTabInsertIndicator()

    local mt       = Mux._movingTab
    Mux._movingTab = nil

    local theme = Mux.activeTheme()
    for _, p in pairs(Mux._panes) do
        if p._tabsEnabled then
            if p._tabBar         then p._tabBar:setStyleSheet(theme.tabBarCss or "") end
            if p._tabMoveOverlay then p._tabMoveOverlay:hide() end
        end
    end

    -- Restore the chosen tab's label style.
    if mt and mt.tab and mt.fromPane then
        local isActive = (mt.fromPane._activeTabId == mt.tab.id)
        mt.tab.label:setStyleSheet(isActive
            and (theme.tabActiveCss or "")
            or  (theme.tabInactiveCss or ""))
        mt.fromPane:_echoTabLabel(mt.tab.label, mt.tab.name, isActive, false, theme)
    end
end

-- Keep the old name as an alias so pane.lua's cancel-guard still works.
Mux._cancelTabMove = Mux._resetOverlay

-- ── HBox order sync ───────────────────────────────────────────────────────────

function MuxPane:_reorderTab(fromIdx, toIdx)
    if fromIdx == toIdx then return end
    local tab = table.remove(self._tabs, fromIdx)
    table.insert(self._tabs, toIdx, tab)
    self:_syncHBoxOrder()
    self._tabBarBox:organize()
    Mux._scheduleAutoSave()
end

function MuxPane:_syncHBoxOrder()
    local box = self._tabBarBox
    for i = #box.windows, 1, -1 do box.windows[i] = nil end
    for i, tab in ipairs(self._tabs) do box.windows[i] = tab.label.name end
end

-- ── Cross-pane receive ────────────────────────────────────────────────────────

function MuxPane:_receiveTab(tab, fromPane, insertPos)
    if self.permanentFloat or self.noTabs then return end
    if not self._tabsEnabled then self:enableTabs({ noDefaultTab = true }) end

    local _, srcIdx = fromPane:_findTab(tab.id)
    if not srcIdx then return end

    local srcNextTab = nil
    if fromPane._activeTabId == tab.id and #fromPane._tabs > 1 then
        local ni = (srcIdx < #fromPane._tabs) and (srcIdx + 1) or (srcIdx - 1)
        srcNextTab = fromPane._tabs[ni]
    end

    fromPane._tabBarBox:remove(tab.label)
    tab.label:hide()
    fromPane._tabBarBox:organize()
    table.remove(fromPane._tabs, srcIdx)

    if fromPane._activeTabId == tab.id then
        fromPane._activeTabId = nil
        if srcNextTab then fromPane:_activateTabObj(srcNextTab) end
    end

    -- If source pane had tabs disabled, check whether to collapse its bar now.
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
    self:_echoTabLabel(newLabel, tab.name, false, false, theme)
    self._tabBarBox:organize()
    tab.label = newLabel

    insertPos = insertPos or (#self._tabs + 1)
    table.insert(self._tabs, insertPos, tab)
    self:_syncHBoxOrder()
    self._tabBarBox:organize()

    self:_wireTabLabel(tab)
    self:_activateTabObj(tab)

    -- Re-apply active content after the cross-pane move.  Geyser's auto_hidden
    -- flags on child widgets can survive the changeContainer/show cycle in an
    -- inconsistent state, leaving the content area blank.  Calling remove then
    -- apply kills the old event handler and recreates the widget fresh so it
    -- is guaranteed to be visible and correctly positioned in the new pane.
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

-- ── Tab context menu ──────────────────────────────────────────────────────────

function MuxPane:_showTabContextMenu(tab, gx, gy)
    local menu  = Mux._contextMenu
    local theme = Mux.activeTheme()
    menu.itemHeight = theme.contextMenuItemHeight or 28
    menu.menuWidth  = theme.contextMenuWidth      or 188

    local items = {}

    if not tab.locked then
        items[#items+1] = { text = "✎  Rename Tab", fn = function()
            Mux._showRenameDialog({
                currentName = tab.name,
                title       = "Rename Tab",
                onConfirm   = function(newName) self:renameTab(tab.id, newName) end,
            })
        end }
    end

    items[#items+1] = { text = tab.locked and "⊙  Unlock Tab" or "⊘  Lock Tab",
        fn = function() tab.locked = not tab.locked end }

    local contentNames = Mux._listContent and Mux._listContent() or {}
    if #contentNames > 0 then
        local pane        = self
        local contentItems = {}
        for _, contentName in ipairs(contentNames) do
            local def        = Mux._content[contentName]
            local capture    = contentName
            local captureTab = tab
            contentItems[#contentItems+1] = {
                text = (def and def.name) or contentName,
                fn   = function()
                    if Mux._applyContent then Mux._applyContent(captureTab, capture) end
                end,
            }
        end
        items[#items+1] = { sep = true }
        items[#items+1] = { text = "◈  Add Content  ▶", submenu = contentItems }
    end

    if not tab.locked then
        items[#items+1] = { sep = true }
        items[#items+1] = { text = "✕  Close Tab", danger = true,
            fn = function() self:removeTab(tab.id) end }
    end

    Mux._showItemMenu(gx, gy, items)
end

-- ── Layout serialization helpers ──────────────────────────────────────────────

function MuxPane:_serializeTabs()
    if not self._tabsEnabled or not self._tabs or #self._tabs == 0 then return nil end
    local tabs = {}
    for _, tab in ipairs(self._tabs) do
        local tabEntry = { name = tab.name, locked = tab.locked or false, _activeContent = tab._activeContent }
        if tab._connectionAware then tabEntry.connectionAware = true end
        tabs[#tabs+1] = tabEntry
    end
    local activeTabName
    if self._activeTabId then
        local at = self:_findTab(self._activeTabId)
        activeTabName = at and at.name
    end
    return tabs, activeTabName
end

-- applyTheme refresh (called from MuxPane:applyTheme in pane.lua)
function MuxPane:_applyTabTheme()
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
        self:_echoTabLabel(tab.label, tab.name, isActive, false, theme)
        if tab.contentBg then tab.contentBg:setStyleSheet(theme.contentCss or "") end
        if self._refreshTabConnScreen then self:_refreshTabConnScreen(tab) end
    end
end

Mux._log("mux_tabs loaded")
