-- Muxlet — MuxPane
--
-- A pane is the leaf UI container in the tiling tree. Widget structure:
--
--   outer  (Geyser.Container)   — logical boundary; no native Qt window.
--                                  move()/reposition() cascades to all children.
--     frame  (Geyser.Label)     — CSS border + background. Added first so it
--                                  sits at the lowest z-order, behind everything.
--     header (Geyser.Container) — fixed-height strip inset 2px from the border.
--       titlebar (Geyser.Label) — drag surface and title text.
--       minBtn   (Geyser.Label) — minimize button (floating only).
--       closeBtn (Geyser.Label) — close button.
--       reveal   (Geyser.Label) — thin strip shown when titlebar is hidden.
--     content(Geyser.Container) — fills the remainder; consumers attach widgets here.
--
-- outer is a Container (not a Label) because Containers are purely logical —
-- no native Qt window — so frame carries all CSS without conflicting with
-- the constraint system for border-visible positioning.
--
-- Float / embed:
--   Float: outer:changeContainer(Geyser) → absolute pixel move → reposition()
--   Embed: outer:changeContainer(slot)   → "0%","0%" move      → reposition()
--   All children cascade automatically via Geyser's reposition() chain.

MuxPane = Mux._class()
Mux.Pane = MuxPane

local borderInset = 2   -- px gap so the 2px CSS border on frame is visible all around

function MuxPane:init(opts)
    opts = opts or {}
    local theme = Mux.activeTheme()

    self.id               = opts.id   or Mux._newId("pane")
    self._gid             = Mux._newInternalId()   -- Geyser widget name prefix; never recycled
    self.name             = opts.name or self.id
    self.floating         = false
    self.minimized        = false
    self.locked           = false
    self._overflowMode    = false

    -- permanentFloat: always floating; never interacts with any PaneSet or split.
    -- Drag-to-embed, double-click-to-embed, and Alt+A are all no-ops.
    -- Used for system overlays (settings window) that must survive workspace changes.
    self.permanentFloat   = opts.permanentFloat or opts.permanent_float or false

    -- noResize: corner resize handles are never built; size is fixed after creation.
    self.noResize         = opts.noResize or opts.no_resize or false
    -- noTitlebarToggle: titlebar is permanently visible; hide/toggle is blocked.
    self.noTitlebarToggle = opts.noTitlebarToggle or opts.no_titlebar_toggle or false
    -- noRename: name cannot be changed via UI or the rename prompt.
    self.noRename         = opts.noRename or opts.no_rename or false
    -- noContent: "Add Content" submenu is suppressed in the context menu.
    self.noContent        = opts.noContent or opts.no_content or opts.noPresets or opts.no_presets or false
    -- noTabs: "Enable Tabs" is suppressed; enableTabs() is a no-op.
    self.noTabs           = opts.noTabs or opts.no_tabs or false
    -- closeable: close button is shown and close() works even when locked.
    self.closeable        = opts.closeable or false
    -- noContextMenu: right-click context menu on the titlebar is suppressed.
    self.noContextMenu    = opts.noContextMenu or opts.no_context_menu or false
    -- zoomable: a zoom button is shown in the titlebar; clicking it expands
    -- this pane to fill the entire screen, above embedded panes and locked
    -- floaters but below free floating panes.
    self.zoomable         = opts.zoomable ~= false
    self._zoomed          = false
    self._preZoomState    = nil
    self.splittable       = opts.splittable ~= false
    self.swappable        = opts.swappable  ~= false

    if opts.show_titlebar ~= nil then
        self.titlebarVisible = opts.show_titlebar
    else
        local def = Mux.settings and Mux.settings.get("mux", "default_titlebar")
        self.titlebarVisible = (def ~= false)
    end

    -- Saved pixel geometry used when the pane is floating.
    self.floatX = opts.floatX or opts.float_x or 100
    self.floatY = opts.floatY or opts.float_y or 100
    self.floatW = opts.floatW or opts.float_w or 400
    self.floatH = opts.floatH or opts.float_h or 300

    -- Back-references to the MuxSplit slot that owns this pane when embedded.
    self._slot     = nil   -- Geyser.Container (slot inside the split)
    self._split    = nil   -- MuxSplit instance
    self._slotSide = nil   -- "a" or "b"

    -- User callbacks
    self.onClose    = opts.onClose
    self.onMinimize = opts.onMinimize
    self.onFloat    = opts.onFloat
    self.onEmbed    = opts.onEmbed

    local tbH    = theme.titlebarHeight
    local rvH    = theme.revealStripHeight
    local parent = opts.parent or Geyser

    self.outer = Geyser.Container:new({
        name   = self._gid .. "_outer",
        x      = opts.x      or "0%",
        y      = opts.y      or "0%",
        width  = opts.width  or "100%",
        height = opts.height or "100%",
    }, parent)

    -- frame is added FIRST so it has the lowest z-order (rendered behind header/content).
    -- clickthrough=true so it doesn't steal mouse events from siblings.
    self.frame = Geyser.Label:new({
        name    = self._gid .. "_frame",
        x       = "0%",
        y       = "0%",
        width   = "100%",
        height  = "100%",
        fillBg  = 1,
    }, self.outer)
    self.frame:setStyleSheet(theme.paneOuterCss or "")
    self.frame:setClickCallback(function(event)
        if Mux._movingTab then Mux._cancelTabMove(); return end
        if not self.locked and Mux.setFocus then Mux.setFocus(self) end
    end)

    local hdrH = self.titlebarVisible and tbH or rvH
    self.header = Geyser.Container:new({
        name   = self._gid .. "_header",
        x      = tostring(borderInset) .. "px",
        y      = tostring(borderInset) .. "px",
        width  = Mux._fromEdgePx(borderInset),
        height = Mux._toPx(hdrH),
    }, self.outer)

    local contentY = borderInset + hdrH
    self.content = Geyser.Container:new({
        name   = self._gid .. "_content",
        x      = tostring(borderInset) .. "px",
        y      = Mux._toPx(contentY),
        width  = Mux._fromEdgePx(borderInset),
        height = Mux._fromEdgePx(borderInset),
    }, self.outer)
    -- Geyser.Container has no setStyleSheet (no native Qt widget).
    -- Use a background Label as the first child (lowest z-order) for the fill.
    self.contentBg = Geyser.Label:new({
        name   = self._gid .. "_content_bg",
        x      = "0%", y = "0%",
        width  = "100%", height = "100%",
        fillBg = 1,
    }, self.content)
    self.contentBg:setStyleSheet(theme.contentCss or "")
    self.contentBg:setClickCallback(function(event)
        if Mux._movingTab then Mux._cancelTabMove(); return end
        if not self.locked and Mux.setFocus then Mux.setFocus(self) end
    end)

    -- Composable behavioural flags. All of these can be passed directly, or set
    -- automatically by mainConsoleHost (see below).

    -- noClose: close button is suppressed and close() is a no-op.
    self.noClose          = opts.noClose or opts.no_close or false
    -- noFloat: float() / _detachToFloat() silently return; pane is always embedded.
    self.noFloat          = opts.noFloat or opts.no_float or false
    -- transparentFrame: frame CSS is transparent + click-through, exposing the Qt
    -- surface behind Geyser (e.g. HUD overlays). contentBg is hidden.
    self.transparentFrame = opts.transparentFrame or opts.transparent_frame or false
    -- consoleBorders: pane manages setBorderSizes so the Mudlet native console is
    -- visible in the content area. contentBg is hidden; onReposition auto-wired.
    self.consoleBorders   = opts.consoleBorders or opts.console_borders or false
    -- noInsertTarget: excluded from drag-to-split insertion zone detection.
    self.noInsertTarget   = opts.noInsertTarget or opts.no_insert_target or false
    -- showSettingsInMenu: context menu shows "Settings" instead of Properties/Close.
    self.showSettingsInMenu = opts.showSettingsInMenu or opts.show_settings_in_menu or false
    -- onReposition: optional callback fired whenever the pane's geometry changes due
    -- to an external event (split rebalance, window resize, workspace restore, zoom).
    self.onReposition     = opts.onReposition

    -- mainConsoleHost: convenience bundle for the pane that hosts the Mudlet native
    -- console. Setting it true auto-applies all the composable flags above, so existing
    -- workspace JSON and call sites need no changes. The field is kept as metadata for
    -- workspace serialisation and focus-fallback identification.
    self.mainConsoleHost = opts.mainConsoleHost or opts.main_console_host or false
    if self.mainConsoleHost then
        self.noClose          = true
        self.noFloat          = true
        self.consoleBorders   = true
        self.noInsertTarget   = true
        self.showSettingsInMenu = true
        self.noContent        = true
        self.noTabs           = true
    end

    if self.consoleBorders then
        -- Native console is only visible where the Geyser overlay has no paint.
        -- The frame must be transparent so the console shows through the content area.
        self.frame:setStyleSheet([[
            background-color: transparent;
            border: 2px solid rgba(255, 255, 255, 0.38);
            border-radius: 3px;
        ]])
        enableClickthrough(self.frame.name)
        self.contentBg:hide()
        if not self.onReposition then
            self.onReposition = function(p) p:updateConsoleBorders() end
        end
    end

    if self.transparentFrame then
        self.frame:setStyleSheet([[
            background-color: transparent;
            border: 2px solid rgba(255, 255, 255, 0.38);
            border-radius: 3px;
        ]])
        enableClickthrough(self.frame.name)
        self.contentBg:hide()
    end

    self:_buildTitlebar(theme)
    self:_buildCornerHandles(theme)
    self:_updatePlaceholder()

    Mux._panes[self.id] = self
    Mux._log("MuxPane created: %s", self.id)
end

function MuxPane:_buildTitlebar(theme)
    local btnH = theme.btnSize
    local btnY = theme.btnTopMargin

    -- titlebar is added BEFORE the buttons so the buttons (added after) sit
    -- at a higher z-order and receive clicks before the drag surface does.
    self.titlebar = Geyser.Label:new({
        name    = self._gid .. "_titlebar",
        x       = "0%",
        y       = "0%",
        width   = "100%",
        height  = "100%",
        fillBg  = 1,
    }, self.header)
    self.titlebar:setStyleSheet(theme.titlebarCss or "")
    local tbc = theme.titlebarTextColor or theme.btnTextColor or "#aaaabb"
    self.titlebar:echo(string.format("<span style='color:%s;'>&nbsp;&nbsp;%s</span>", tbc, self.name))
    self.titlebar:setCursor("OpenHand")

    -- Per-pane drag state. Local closure means panes never interfere with each other.
    local drag = {
        active            = false,
        startX            = 0, startY = 0,
        paneX             = 0, paneY  = 0,
        lastHoverGhostKey = nil,   -- slotKey of the currently highlighted ghost slot
        insertTarget      = nil,   -- {pane, edge} of the currently previewed insertion zone
    }

    self.titlebar:setClickCallback(function(event)
        if event.button == "RightButton" then
            local compact = Mux.settings.get and Mux.settings.get("mux", "compact_titlebar")
            if (self._overflowMode or compact) and not self.noContextMenu then
                Mux._showContextMenu(self, event.globalX or 0, event.globalY or 0)
            end
            return
        end
        if event.button ~= "LeftButton" then return end
        if not self.locked and Mux.setFocus then Mux.setFocus(self) end
        if self.locked then return end
        if self.noFloat then return end
        drag.active = true
        drag.startX = event.globalX
        drag.startY = event.globalY
        drag.paneX  = self.outer:get_x()
        drag.paneY  = self.outer:get_y()
        self.titlebar:setCursor("ClosedHand")
        if self.floating then self:raise() end
    end)

    self.titlebar:setMoveCallback(function(event)
        if not drag.active then return end
        if not self.floating then
            self.floatX = self.outer:get_x()
            self.floatY = self.outer:get_y()
            self.floatW = self.outer:get_width()
            self.floatH = self.outer:get_height()
            self:_detachToFloat()
            drag.paneX = self.floatX
            drag.paneY = self.floatY
        end
        local newX = drag.paneX + (event.globalX - drag.startX)
        local newY = drag.paneY + (event.globalY - drag.startY)
        self.outer:move(newX, newY)
        self.outer:reposition()
        self.floatX = newX
        self.floatY = newY

        local gx, gy = event.globalX, event.globalY

        -- Ghost slot hover: highlight whichever slot the cursor is over.
        local newHoverGhost = nil
        for key, ghost in pairs(Mux._ghostSlots) do
            local sx = ghost.slot:get_x()
            local sy = ghost.slot:get_y()
            local sw = ghost.slot:get_width()
            local sh = ghost.slot:get_height()
            if gx >= sx and gx <= sx + sw and gy >= sy and gy <= sy + sh then
                newHoverGhost = key
                break
            end
        end
        if newHoverGhost ~= drag.lastHoverGhostKey then
            if drag.lastHoverGhostKey then
                local prev = Mux._ghostSlots[drag.lastHoverGhostKey]
                if prev then Mux._unhighlightGhostSlot(prev) end
            end
            if newHoverGhost then
                Mux._highlightGhostSlot(Mux._ghostSlots[newHoverGhost])
            end
            drag.lastHoverGhostKey = newHoverGhost
        end

        -- Insertion zone detection (only when not over a ghost slot).
        if not newHoverGhost then
            local insertPane, insertEdge = nil, nil
            for _, tp in pairs(Mux._panes) do
                if not tp.floating and not tp.noInsertTarget and tp ~= self then
                    local tx = tp:absX()
                    local ty = tp:absY()
                    local tw = tp:width()
                    local th = tp:height()
                    if gx >= tx and gx <= tx + tw and gy >= ty and gy <= ty + th then
                        local minPx, maxPx = 30, 80
                        local edgeH = Mux._clamp(th * 0.20, minPx, maxPx)
                        local edgeW = Mux._clamp(tw * 0.20, minPx, maxPx)
                        if gy <= ty + edgeH then
                            insertPane, insertEdge = tp, "top"
                        elseif gy >= ty + th - edgeH then
                            insertPane, insertEdge = tp, "bottom"
                        elseif gx <= tx + edgeW then
                            insertPane, insertEdge = tp, "left"
                        elseif gx >= tx + tw - edgeW then
                            insertPane, insertEdge = tp, "right"
                        end
                        break
                    end
                end
            end
            if insertPane then
                local tx = insertPane:absX()
                local ty = insertPane:absY()
                local tw = insertPane:width()
                local th = insertPane:height()
                Mux._showInsertionGhost(tx, ty, tw, th, insertEdge)
                drag.insertTarget = { pane = insertPane, edge = insertEdge }
            else
                Mux._hideInsertionGhost()
                drag.insertTarget = nil
            end
        else
            Mux._hideInsertionGhost()
            drag.insertTarget = nil
        end
    end)

    self.titlebar:setReleaseCallback(function(event)
        if event.button ~= "LeftButton" then return end
        drag.active = false
        self.titlebar:setCursor("OpenHand")

        if drag.lastHoverGhostKey then
            local prev = Mux._ghostSlots[drag.lastHoverGhostKey]
            if prev then Mux._unhighlightGhostSlot(prev) end
        end
        Mux._hideInsertionGhost()

        if not self.floating or self.permanentFloat then
            drag.lastHoverGhostKey = nil
            drag.insertTarget      = nil
            return
        end

        -- Drop priority 1: ghost slot.
        local ghostKey = drag.lastHoverGhostKey
        drag.lastHoverGhostKey = nil
        if ghostKey then
            local ghost = Mux._ghostSlots[ghostKey]
            if ghost then
                self._slot     = ghost.slot
                self._split    = ghost.split
                self._slotSide = ghost.side
                self._paneSet  = ghost.paneSet
                if ghost.split then
                    if ghost.side == "a" then ghost.split.childA = self
                    else                     ghost.split.childB = self
                    end
                end
                self:embed()
                drag.insertTarget = nil
                return
            end
        end

        -- Drop priority 2: insertion between embedded panes.
        local it = drag.insertTarget
        drag.insertTarget = nil
        if it and it.pane and not it.pane.floating then
            Mux._doInsertAtEdge(self, it.pane, it.edge)
            return
        end

        -- Drop priority 3: normal PaneSet drop.
        self:_tryEmbedAt(event.globalX, event.globalY)
    end)

    -- Double-click embeds a floating pane into the nearest ghost slot.
    -- For embedded panes, double-click just sets focus.
    self.titlebar:setDoubleClickCallback(function(event)
        if self.noFloat        then return end
        if self.permanentFloat then return end
        if not self.floating then
            if Mux.setFocus then Mux.setFocus(self) end
            return
        end

        -- Home slot first; then find the nearest ghost by screen distance.
        local homeGhost = Mux._findGhostBySlot(self._slot)
        local target    = homeGhost

        if not target then
            local px = self.outer:get_x() + self.outer:get_width()  / 2
            local py = self.outer:get_y() + self.outer:get_height() / 2
            local best = math.huge
            for _, g in pairs(Mux._ghostSlots) do
                local gx = g.label:get_x() + g.label:get_width()  / 2
                local gy = g.label:get_y() + g.label:get_height() / 2
                local d  = (px - gx)^2 + (py - gy)^2
                if d < best then best = d; target = g end
            end
        end

        if not target then return end

        self._slot     = target.slot
        self._split    = target.split
        self._slotSide = target.side
        self._paneSet  = target.paneSet
        if target.split then
            if target.side == "a" then target.split.childA = self
            else                      target.split.childB = self
            end
        end
        self:embed()
    end)

    -- infoBtn: positioned dynamically just after the pane name text ends.
    -- Shows a gear (⚙) for panes that own the Settings panel, or a list
    -- icon (≡) for panes where Properties is available. Hidden otherwise.
    self.infoBtn = Geyser.Label:new({
        name   = self._gid .. "_info",
        x      = tostring(self:_infoBtnX()),
        y      = tostring(btnY),
        width  = tostring(theme.btnSize),
        height = tostring(btnH),
        fillBg = 1,
    }, self.header)
    self.infoBtn:setStyleSheet(theme.btnCss or "")
    local infoBtnIcon = self.showSettingsInMenu and "⚙" or "≡"
    local function infoBtnEcho(hovered)
        local tc = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
        self.infoBtn:echo(string.format("<center><font color='%s'>%s</font></center>", tc, infoBtnIcon))
    end
    self._infoBtnEcho = infoBtnEcho
    infoBtnEcho(false)
    self.infoBtn:setToolTip(self.showSettingsInMenu and "Settings" or "Properties")
    self.infoBtn:setOnEnter(function()
        self.infoBtn:setStyleSheet(Mux.activeTheme().minHoverCss or Mux.activeTheme().btnCss)
        infoBtnEcho(true)
    end)
    self.infoBtn:setOnLeave(function()
        self.infoBtn:setStyleSheet(Mux.activeTheme().btnCss or "")
        infoBtnEcho(false)
    end)
    self.infoBtn:setClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        if self.showSettingsInMenu then
            Mux.settings.toggle()
        else
            Mux.showPaneProperties(self)
        end
    end)
    -- Visibility is managed by _applyTitlebarVisibility.

    -- closeBtn: x="-20" places it 20px from the right edge of header.
    self.closeBtn = Geyser.Label:new({
        name    = self._gid .. "_close",
        x       = "-20",
        y       = tostring(btnY),
        width   = tostring(theme.btnSize),
        height  = tostring(btnH),
        fillBg  = 1,
    }, self.header)
    -- Qt ignores CSS color: on a QLabel containing rich text; use <font color> instead.
    local function closeBtnEcho(hovered)
        local tc = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
        self.closeBtn:echo(string.format("<center><font color='%s'>✕</font></center>", tc))
    end
    self.closeBtn:setStyleSheet(theme.btnCss or "")
    closeBtnEcho(false)
    self.closeBtn:setToolTip("Close pane")
    self.closeBtn:setOnEnter(function()
        self.closeBtn:setStyleSheet(Mux.activeTheme().closeHoverCss or Mux.activeTheme().btnCss)
        closeBtnEcho(true)
    end)
    self.closeBtn:setOnLeave(function()
        self.closeBtn:setStyleSheet(Mux.activeTheme().btnCss or "")
        closeBtnEcho(false)
    end)
    self.closeBtn:setClickCallback(function(event)
        if event.button == "LeftButton" then self:close() end
    end)

    -- minBtn: x="-42" = btnSize(18) + gap(2) + close_offset(20) + margin(2)
    self.minBtn = Geyser.Label:new({
        name    = self._gid .. "_min",
        x       = "-42",
        y       = tostring(btnY),
        width   = tostring(theme.btnSize),
        height  = tostring(btnH),
        fillBg  = 1,
    }, self.header)
    local function minBtnEcho(hovered)
        local tc = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
        self.minBtn:echo(string.format("<center><font color='%s'>–</font></center>", tc))
    end
    self.minBtn:setStyleSheet(theme.btnCss or "")
    minBtnEcho(false)
    self.minBtn:setToolTip("Minimize pane")
    self.minBtn:setOnEnter(function()
        self.minBtn:setStyleSheet(Mux.activeTheme().minHoverCss or Mux.activeTheme().btnCss)
        minBtnEcho(true)
    end)
    self.minBtn:setOnLeave(function()
        self.minBtn:setStyleSheet(Mux.activeTheme().btnCss or "")
        minBtnEcho(false)
    end)
    self.minBtn:setClickCallback(function(event)
        if event.button == "LeftButton" then self:toggleMinimize() end
    end)

    -- zoomBtn: x="-70" places it left of minBtn with a clear visual gap.
    -- Close occupies [-20,-2], min occupies [-42,-24]; zoom occupies [-70,-52]
    -- giving a 10px gap to minBtn and 32px gap to close when minBtn is hidden.
    self.zoomBtn = Geyser.Label:new({
        name   = self._gid .. "_zoom",
        x      = "-70",
        y      = tostring(btnY),
        width  = tostring(theme.btnSize),
        height = tostring(btnH),
        fillBg = 1,
    }, self.header)
    self.zoomBtn:setStyleSheet(theme.btnCss or "")
    local function zoomBtnEcho(hovered)
        local tc   = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
        local icon = self._zoomed and "⧉" or "<span style='font-size:12px;line-height:1;'>□</span>"
        self.zoomBtn:echo(string.format("<center><font color='%s'>%s</font></center>", tc, icon))
    end
    self._zoomBtnEcho = zoomBtnEcho
    zoomBtnEcho(false)
    self.zoomBtn:setToolTip("Zoom")
    self.zoomBtn:setOnEnter(function()
        self.zoomBtn:setStyleSheet(Mux.activeTheme().minHoverCss or Mux.activeTheme().btnCss)
        zoomBtnEcho(true)
    end)
    self.zoomBtn:setOnLeave(function()
        self.zoomBtn:setStyleSheet(Mux.activeTheme().btnCss or "")
        zoomBtnEcho(false)
    end)
    self.zoomBtn:setClickCallback(function(event)
        if event.button == "LeftButton" then self:zoom() end
    end)
    self.zoomBtn:hide()  -- shown by _updateZoomBtn once embedded in a split

    -- swapBtn: x="-96" — 8px gap after zoomBtn, a clear visual break before the action cluster.
    -- splitHBtn at "-120" — 6px gap from swap. splitVBtn at "-140" — 2px gap from splitH.
    self.swapBtn = Geyser.Label:new({
        name   = self._gid .. "_swap",
        x      = "-96",
        y      = tostring(btnY),
        width  = tostring(theme.btnSize),
        height = tostring(btnH),
        fillBg = 1,
    }, self.header)
    self.swapBtn:setStyleSheet(theme.btnCss or "")
    local function swapBtnEcho(hovered)
        local tc = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
        self.swapBtn:echo(string.format("<center><font color='%s'>⇔</font></center>", tc))
    end
    self._swapBtnEcho = swapBtnEcho
    swapBtnEcho(false)
    self.swapBtn:setToolTip("Swap with sibling")
    self.swapBtn:setOnEnter(function()
        self.swapBtn:setStyleSheet(Mux.activeTheme().minHoverCss or Mux.activeTheme().btnCss)
        swapBtnEcho(true)
    end)
    self.swapBtn:setOnLeave(function()
        self.swapBtn:setStyleSheet(Mux.activeTheme().btnCss or "")
        swapBtnEcho(false)
    end)
    self.swapBtn:setClickCallback(function(event)
        if event.button == "LeftButton" and self._split then
            self._split:swapSlots()
        end
    end)
    if not self.swappable then self.swapBtn:hide() end

    -- splitHBtn: horizontal split — one pane above the other (direction "v" internally).
    -- Icon ═ (double horizontal bar) is distinct from the minimize – glyph.
    self.splitHBtn = Geyser.Label:new({
        name   = self._gid .. "_splitH",
        x      = "-120",
        y      = tostring(btnY),
        width  = tostring(theme.btnSize),
        height = tostring(btnH),
        fillBg = 1,
    }, self.header)
    self.splitHBtn:setStyleSheet(theme.btnCss or "")
    local function splitHBtnEcho(hovered)
        local tc = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
        self.splitHBtn:echo(string.format("<center><font color='%s'>═</font></center>", tc))
    end
    self._splitHBtnEcho = splitHBtnEcho
    splitHBtnEcho(false)
    self.splitHBtn:setToolTip("Split horizontally (top / bottom)")
    self.splitHBtn:setOnEnter(function()
        self.splitHBtn:setStyleSheet(Mux.activeTheme().minHoverCss or Mux.activeTheme().btnCss)
        splitHBtnEcho(true)
    end)
    self.splitHBtn:setOnLeave(function()
        self.splitHBtn:setStyleSheet(Mux.activeTheme().btnCss or "")
        splitHBtnEcho(false)
    end)
    self.splitHBtn:setClickCallback(function(event)
        if event.button == "LeftButton" then
            Mux.setFocus(self)
            Mux.splitFocused("v")
        end
    end)
    if not self.splittable then self.splitHBtn:hide() end

    -- splitVBtn: vertical split — two panes side by side (direction "h" internally).
    -- Icon ║ (double vertical bar) represents the divider between left and right panes.
    self.splitVBtn = Geyser.Label:new({
        name   = self._gid .. "_splitV",
        x      = "-140",
        y      = tostring(btnY),
        width  = tostring(theme.btnSize),
        height = tostring(btnH),
        fillBg = 1,
    }, self.header)
    self.splitVBtn:setStyleSheet(theme.btnCss or "")
    local function splitVBtnEcho(hovered)
        local tc = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
        self.splitVBtn:echo(string.format("<center><font color='%s'>║</font></center>", tc))
    end
    self._splitVBtnEcho = splitVBtnEcho
    splitVBtnEcho(false)
    self.splitVBtn:setToolTip("Split vertically (side by side)")
    self.splitVBtn:setOnEnter(function()
        self.splitVBtn:setStyleSheet(Mux.activeTheme().minHoverCss or Mux.activeTheme().btnCss)
        splitVBtnEcho(true)
    end)
    self.splitVBtn:setOnLeave(function()
        self.splitVBtn:setStyleSheet(Mux.activeTheme().btnCss or "")
        splitVBtnEcho(false)
    end)
    self.splitVBtn:setClickCallback(function(event)
        if event.button == "LeftButton" then
            Mux.setFocus(self)
            Mux.splitFocused("h")
        end
    end)
    if not self.splittable then self.splitVBtn:hide() end

    -- contentBtn: x="-210" — ~52px gap left of the split cluster, clearly separated from split buttons.
    self.contentBtn = Geyser.Label:new({
        name   = self._gid .. "_cadd",
        x      = "-210",
        y      = tostring(btnY),
        width  = tostring(theme.btnSize),
        height = tostring(btnH),
        fillBg = 1,
    }, self.header)
    self.contentBtn:setStyleSheet(theme.btnCss or "")
    local function contentBtnEcho(hovered)
        local tc = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
        self.contentBtn:echo(string.format("<center><font color='%s'>◈</font></center>", tc))
    end
    self._contentBtnEcho = contentBtnEcho
    contentBtnEcho(false)
    self.contentBtn:setToolTip("Add Content")
    self.contentBtn:setOnEnter(function()
        self.contentBtn:setStyleSheet(Mux.activeTheme().minHoverCss or Mux.activeTheme().btnCss)
        contentBtnEcho(true)
    end)
    self.contentBtn:setOnLeave(function()
        self.contentBtn:setStyleSheet(Mux.activeTheme().btnCss or "")
        contentBtnEcho(false)
    end)
    self.contentBtn:setClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        Mux._showContentLibrary(self)
    end)
    if self.noContent then self.contentBtn:hide() end

    -- reveal strip: shown when titlebar is hidden; right-click only via Alt+[ or mux titlebar
    -- to prevent accidental re-show.
    self.reveal = Geyser.Label:new({
        name    = self._gid .. "_reveal",
        x       = "0%",
        y       = "0%",
        width   = "100%",
        height  = "100%",
        fillBg  = 1,
    }, self.header)
    self.reveal:setStyleSheet(theme.revealStripCss or "")
    self.reveal:setToolTip("Press Alt+[ to restore titlebar")
    self.reveal:setOnEnter(function()
        self.reveal:setStyleSheet(theme.revealStripHoverCss or theme.revealStripCss)
    end)
    self.reveal:setOnLeave(function()
        self.reveal:setStyleSheet(theme.revealStripCss or "")
    end)
    self.reveal:setClickCallback(function() end)

    self:_applyTitlebarVisibility()
end

function MuxPane:setTitlebarVisible(visible)
    if not visible and self.noTitlebarToggle then return end
    self.titlebarVisible = visible
    self:_applyTitlebarVisibility()
end

-- Returns the pixel x position where infoBtn should start: just after the pane name text.
function MuxPane:_infoBtnX()
    local charW = (Mux.activeTheme and Mux.activeTheme().titlebarCharWidth or 7)
    -- ~8px for label left edge + 2 &nbsp; chars, then name width, then 4px gap.
    return 8 + math.ceil(#self.name * charW) + 4
end

-- Moves infoBtn to its correct position based on current name length.
function MuxPane:_updateInfoBtnPos()
    if not self.infoBtn then return end
    local theme = Mux.activeTheme and Mux.activeTheme() or {}
    self.infoBtn:move(self:_infoBtnX(), theme.btnTopMargin or 2)
end

-- Checks whether visible right-side buttons fit in the current header width.
-- If too narrow: hides all buttons (overflow mode — right-click shows them as a menu).
-- If wide enough: restores button visibility without calling _applyTitlebarVisibility().
function MuxPane:_checkOverflow()
    if not self.titlebarVisible then return end
    local headerW = self.header:get_width()
    if headerW < 10 then return end  -- not yet laid out; skip

    local theme   = Mux.activeTheme and Mux.activeTheme() or {}
    local charW   = theme.titlebarCharWidth or 7
    local compact = Mux.settings.get and Mux.settings.get("mux", "compact_titlebar")

    -- Right-side: close=22, min=22(floating), zoom=28, swap=26, content=70 (btn+52px gap), splitH+V=44
    local rightW = 22
    if self.floating and not self.noFloat then rightW = rightW + 22 end
    if self.zoomable                      then rightW = rightW + 28 end
    if self.swappable and self._split and not self.floating and not self.locked then rightW = rightW + 26 end
    if self.splittable and not self.floating and not self.locked then rightW = rightW + 44 end
    if not self.noContent                 then rightW = rightW + 70 end

    -- Left-side: 8px start + nbsp(8) + text + gap(4) + infoBtn(22 when visible)
    local showInfo = self.infoBtn and not self.noContextMenu
        and (self.showSettingsInMenu or not self.noClose)
    local leftW = 16 + math.ceil(#self.name * charW) + 4 + (showInfo and 22 or 0)

    local newOverflow = compact or (headerW < leftW + rightW + 10)

    if newOverflow == self._overflowMode then return end
    self._overflowMode = newOverflow

    if newOverflow then
        if self.infoBtn    then self.infoBtn:hide()    end
        if self.closeBtn   then self.closeBtn:hide()   end
        if self.minBtn     then self.minBtn:hide()     end
        if self.zoomBtn    then self.zoomBtn:hide()    end
        if self.swapBtn    then self.swapBtn:hide()    end
        if self.splitHBtn  then self.splitHBtn:hide()  end
        if self.splitVBtn  then self.splitVBtn:hide()  end
        if self.contentBtn then self.contentBtn:hide() end
    else
        -- Restore ideal visibility without recursing into _applyTitlebarVisibility.
        if self.infoBtn then
            if showInfo then self.infoBtn:show() else self.infoBtn:hide() end
        end
        if self.noClose or (self.locked and not self.closeable) then
            self.closeBtn:hide()
        else
            self.closeBtn:show()
        end
        if self.floating and not self.noFloat then self.minBtn:show() else self.minBtn:hide() end
        if self.zoomable then self.zoomBtn:show() else self.zoomBtn:hide() end
        if self.splittable and not self.floating and not self.locked then
            self.splitVBtn:show(); self.splitHBtn:show()
        else
            self.splitVBtn:hide(); self.splitHBtn:hide()
        end
        if self.swappable and not self.floating and not self.locked and self._split then
            self.swapBtn:show()
        else
            self.swapBtn:hide()
        end
        if not self.noContent and self.contentBtn then
            self.contentBtn:show()
        elseif self.contentBtn then
            self.contentBtn:hide()
        end
    end
end

function MuxPane:_applyTitlebarVisibility()
    local theme = Mux.activeTheme()
    local bi    = borderInset
    if self.titlebarVisible then
        local h = theme.titlebarHeight
        self.header:resize(nil, Mux._toPx(h))
        self.content:move(nil, Mux._toPx(bi + h))
        self.content:resize(nil, Mux._fromEdgePx(bi))
        self.header:reposition()
        self.content:reposition()
        if self._syncConnScreenGeometry then self:_syncConnScreenGeometry() end
        self.titlebar:show()
        if self.infoBtn then
            local showInfo = not self.noContextMenu
                and (self.showSettingsInMenu or not self.noClose)
            if showInfo then self.infoBtn:show() else self.infoBtn:hide() end
        end
        if self.noClose or (self.locked and not self.closeable) then
            self.closeBtn:hide()
        else
            self.closeBtn:show()
        end
        if self.floating and not self.noFloat then self.minBtn:show() else self.minBtn:hide() end
        if self.zoomable then self.zoomBtn:show() else self.zoomBtn:hide() end
        if self.splittable and not self.floating and not self.locked then
            self.splitVBtn:show(); self.splitHBtn:show()
        else
            self.splitVBtn:hide(); self.splitHBtn:hide()
        end
        if self.swappable and not self.floating and not self.locked and self._split then
            self.swapBtn:show()
        else
            self.swapBtn:hide()
        end
        if not self.noContent and self.contentBtn then
            self.contentBtn:show()
        elseif self.contentBtn then
            self.contentBtn:hide()
        end
        self:_checkOverflow()
        self.reveal:hide()
    else
        local h = theme.revealStripHeight
        self.header:resize(nil, Mux._toPx(h))
        self.content:move(nil, Mux._toPx(bi + h))
        self.content:resize(nil, Mux._fromEdgePx(bi))
        self.header:reposition()
        self.content:reposition()
        if self._syncConnScreenGeometry then self:_syncConnScreenGeometry() end
        self.titlebar:hide()
        if self.infoBtn    then self.infoBtn:hide()    end
        self.closeBtn:hide()
        self.minBtn:hide()
        self.zoomBtn:hide()
        if self.splitVBtn  then self.splitVBtn:hide()  end
        if self.splitHBtn  then self.splitHBtn:hide()  end
        if self.swapBtn    then self.swapBtn:hide()    end
        if self.contentBtn then self.contentBtn:hide() end
        self.reveal:show()
    end
end

-- Floating panes collapse to a titlebar-height strip.
-- Embedded panes collapse their split slot to a thin strip by adjusting the
-- parent split's ratio, restoring the saved ratio on unminimize.
function MuxPane:toggleMinimize()
    local theme = Mux.activeTheme()
    if self.minimized then
        self.minimized = false
        if self.content then self.content:show() end
        if self._onRestoreContent then self:_onRestoreContent() end
        if self.floating then
            local h = self._savedFloatH or self.floatH
            self.floatH = h
            self.outer:resize(self.floatW, h)
            self.outer:reposition()
        elseif self._split and self._savedMinimizeRatio then
            self._split:_setRatio(self._savedMinimizeRatio)
            self._savedMinimizeRatio = nil
        end
        if self.onMinimize then self.onMinimize(self, false) end
    else
        self.minimized = true
        if self.floating then
            self._savedFloatH = self.floatH
            local minH = theme.titlebarHeight + borderInset * 2
            self.floatH = minH
            self.outer:resize(self.floatW, minH)
            self.outer:reposition()
        elseif self._split then
            local split    = self._split
            local handlePx = theme.handleSize or 3
            local boxSize  = (split.direction == "v")
                and split.box:get_height()
                or  split.box:get_width()
            local minPx  = theme.titlebarHeight + borderInset * 2
            local dyn    = boxSize - handlePx
            local minR   = (dyn > 0) and Mux._clamp(minPx / dyn, 0.01, 0.25) or 0.05
            self._savedMinimizeRatio = split.ratio
            local newR = (self._slotSide == "a") and minR or (1 - minR)
            split:_setRatio(Mux._clamp(newR, 0.01, 0.99))
        end
        -- Hide content after resize so nothing bleeds through the collapsed strip.
        if self.content then self.content:hide() end
        if self.onMinimize then self.onMinimize(self, true) end
    end
end

function MuxPane:setName(text)
    self.name = text
    if self.titlebar then
        local tbc = Mux.activeTheme().titlebarTextColor or Mux.activeTheme().btnTextColor or "#aaaabb"
        self.titlebar:echo(string.format("<span style='color:%s;'>&nbsp;&nbsp;%s</span>", tbc, text))
    end
    self:_updateInfoBtnPos()
    self:_updatePlaceholder()
end

-- Placeholder shown on contentBg until real content is attached.
-- Any user widget placed as a sibling naturally renders above it.
function MuxPane:_updatePlaceholder()
    if not self.contentBg then return end
    if self._activeContent  then return end
    if self.consoleBorders then return end
    self.contentBg:show()
    local ds = "color:rgba(75,82,115,0.75);font-size:10px;font-family:'Consolas','Monaco',monospace;"
    local cs = "color:rgba(110,155,215,0.65);font-size:9px;font-family:'Consolas','Monaco',monospace;"
    local is = "color:rgba(140,185,255,0.55);font-size:9px;font-family:'Consolas','Monaco',monospace;"
    local html = string.format(
        "<div align='center' style='padding-top:15%%;%s'>"
        .. "<span style='font-size:12px;color:rgba(90,98,138,0.85);font-weight:bold;'>%s</span>"
        .. "<br/>"
        .. "<span style='%s'>id: %s</span>"
        .. "<br/><br/>"
        .. "<span style='%s'>"
        .. "local con = Geyser.MiniConsole:new({<br/>"
        .. "&nbsp;&nbsp;name = 'my_con',<br/>"
        .. "&nbsp;&nbsp;x = '0%%', y = '0%%',<br/>"
        .. "&nbsp;&nbsp;width = '100%%', height = '100%%'<br/>"
        .. "}, panes['%s'].content)<br/><br/>"
        .. "cecho('my_con', 'Hello!\\n')"
        .. "</span>"
        .. "<br/><br/>"
        .. "<span style='font-size:9px;color:rgba(90,98,138,0.5);'>"
        .. "≡ Properties or use mux pane properties"
        .. "</span>"
        .. (not self.noContent
            and "<br/><span style='color:rgba(100,165,255,0.4);font-size:9px;'>◈ Add Content via titlebar</span>"
            or  "")
        .. "</div>",
        ds, self.name, is, self.id, cs, self.id)
    self.contentBg:echo(html)
end

function MuxPane:float()
    if self.floating then return end
    if self.noFloat   then return end
    self.floatX = self.outer:get_x()
    self.floatY = self.outer:get_y()
    self.floatW = self.outer:get_width()
    self.floatH = self.outer:get_height()
    self:_detachToFloat()
end

function MuxPane:_detachToFloat()
    if self.floating then return end
    if self.noFloat  then return end
    self.floating = true
    self.outer:changeContainer(Geyser)
    self.outer:move(self.floatX, self.floatY)
    self.outer:resize(self.floatW, self.floatH)
    self.outer:reposition()
    self:raise()
    self.frame:setStyleSheet(self:_baseFrameCss())
    self:_showCornerHandles()
    if self.titlebarVisible and not self.noFloat then
        self.minBtn:show()
    end
    if self.splitVBtn then self.splitVBtn:hide() end
    if self.splitHBtn then self.splitHBtn:hide() end
    if self.swapBtn   then self.swapBtn:hide()   end
    -- Always leave a ghost slot in the vacated split slot. Ghosts persist until
    -- explicitly dismissed (×) or the pane is closed; they never auto-vanish.
    if self._split then
        Mux._createGhostSlot(self._slot, self._split, self._slotSide, self._paneSet)
        -- Re-raise after ghost creation so the float stays above its own ghost.
        self:raise()
    end
    if not self.permanentFloat then Mux._lastFocusedPane = self end
    if self.onFloat then self.onFloat(self) end
    if not self.permanentFloat then Mux._scheduleAutoSave() end
    Mux._log("MuxPane floated: %s (%.0f,%.0f %.0fx%.0f)",
        self.id, self.floatX, self.floatY, self.floatW, self.floatH)
end

function MuxPane:embed(slot)
    if self.permanentFloat then return end
    if not self.floating then return end
    local target = slot or self._slot
    if not target then
        Mux._warn("embed: pane '%s' has no slot to return to", self.id)
        return
    end
    Mux._removeGhostSlotBySlot(target)
    -- Restore the split box so VBox/HBox layout and resize handle are visible again.
    if not slot and self._split then
        self._split.box:show()
    end
    self.floating = false
    self.outer:changeContainer(target)
    self.outer:move("0%", "0%")
    self.outer:resize("100%", "100%")
    self.outer:reposition()
    self.frame:setStyleSheet(self:_baseFrameCss())
    self:_hideCornerHandles()
    self.minBtn:hide()
    if self.titlebarVisible then
        if self.splittable and not self.locked then
            if self.splitVBtn then self.splitVBtn:show() end
            if self.splitHBtn then self.splitHBtn:show() end
        end
        if self.swappable and not self.locked and self._split then
            if self.swapBtn then self.swapBtn:show() end
        end
    end
    tempTimer(0, function() if self.titlebar then self:_checkOverflow() end end)
    if self.onEmbed then self.onEmbed(self) end
    self:_updateZoomBtn()
    Mux._scheduleAutoSave()
    Mux._log("MuxPane embedded: %s", self.id)
    Mux.raiseFloatingPanes()
end

-- Zoom this pane to fill the full screen, floating above embedded panes and
-- immobilized floaters (locked/permanentFloat) but below free floating panes.
-- Calling again while zoomed restores the pane to its previous state.
function MuxPane:zoom()
    if not self.zoomable then return end
    if self._zoomed then
        self:_unzoom()
        return
    end
    self._preZoomState = {
        wasFloating = self.floating,
        floatX      = self.floatX,
        floatY      = self.floatY,
        floatW      = self.floatW,
        floatH      = self.floatH,
        slot        = self._slot,
        split       = self._split,
        slotSide    = self._slotSide,
        paneSet     = self._paneSet,
    }
    if not self.floating then
        -- Detach from the split tree into the Geyser root, leaving a ghost slot
        -- behind so the layout does not collapse while we are zoomed.
        self.floating = true
        self.outer:changeContainer(Geyser)
        self.frame:setStyleSheet(self:_baseFrameCss())
        if self._split then
            Mux._createGhostSlot(self._slot, self._split, self._slotSide, self._paneSet)
        end
        -- consoleBorders panes have a transparent frame; hiding the pane set
        -- prevents other panes from showing through while zoomed.
        if self.consoleBorders and self._paneSet then
            self._paneSet.outer:hide()
        end
        if self.splitVBtn then self.splitVBtn:hide() end
        if self.splitHBtn then self.splitHBtn:hide() end
        if self.swapBtn   then self.swapBtn:hide()   end
        tempTimer(0, function() if self.titlebar then self:_checkOverflow() end end)
    end
    self.outer:move(0, 0)
    self.outer:resize("100%", "100%")
    self.outer:reposition()
    if self.onReposition then self.onReposition(self) end
    self._zoomed = true
    -- Raise above everything, then let free floaters come back on top so that
    -- popup dialogs (free floating panes) are never obscured by the zoom.
    self:raise()
    Mux._raiseFreeFloatingPanes()
    self:_updateZoomBtn()
    Mux._log("MuxPane zoomed: %s", self.id)
end

function MuxPane:_unzoom()
    if not self._zoomed then return end
    local state    = self._preZoomState
    self._zoomed   = false
    self._preZoomState = nil
    if state.wasFloating then
        -- Restore to previous floating position and re-show resize/minimize UI.
        self.outer:move(state.floatX, state.floatY)
        self.outer:resize(state.floatW, state.floatH)
        self.outer:reposition()
        self:_showCornerHandles()
        if self.titlebarVisible and not self.noFloat then
            self.minBtn:show()
        end
    else
        -- Re-embed into the original slot and remove the ghost we left behind.
        if state.slot then
            Mux._removeGhostSlotBySlot(state.slot)
            if state.split then state.split.box:show() end
        end
        self.floating = false
        local target = state.slot or (state.paneSet and state.paneSet.outer)
        if target then self.outer:changeContainer(target) end
        self.outer:move("0%", "0%")
        self.outer:resize("100%", "100%")
        self.outer:reposition()
        self.frame:setStyleSheet(self:_baseFrameCss())
        self:_hideCornerHandles()
        self.minBtn:hide()
        if self.consoleBorders and self._paneSet then
            self._paneSet.outer:show()
        end
        if self.titlebarVisible then
            if self.splittable and not self.locked then
                if self.splitVBtn then self.splitVBtn:show() end
                if self.splitHBtn then self.splitHBtn:show() end
            end
            if self.swappable and not self.locked and self._split then
                if self.swapBtn then self.swapBtn:show() end
            end
        end
        tempTimer(0, function() if self.titlebar then self:_checkOverflow() end end)
    end
    if self.onReposition then self.onReposition(self) end
    Mux.raiseFloatingPanes()
    self:_updateZoomBtn()
    Mux._log("MuxPane unzoomed: %s", self.id)
end

function MuxPane:_updateZoomBtn()
    if not self.zoomBtn then return end
    if self._zoomBtnEcho then self._zoomBtnEcho(false) end
    self.zoomBtn:setToolTip(self._zoomed and "UnZoom" or "Zoom")
    if self.zoomable and (self._split or self._zoomed) then
        self.zoomBtn:show()
    else
        self.zoomBtn:hide()
    end
end

function MuxPane:raise()
    -- raiseAll on a Container iterates windowList and raises each native child.
    if self.outer and self.outer.raiseAll then self.outer:raiseAll() end
end

function MuxPane:lower()
    if self.outer and self.outer.lowerAll then self.outer:lowerAll() end
end

-- Recalculates setBorderSizes so the Mudlet native console tracks the content area.
-- Called automatically via onReposition for consoleBorders panes.
function MuxPane:updateConsoleBorders()
    if not self.consoleBorders then return end
    local theme = Mux.activeTheme()
    local bi = 2
    local tb = self.titlebarVisible and theme.titlebarHeight or theme.revealStripHeight
    local sw, sh = getMainWindowSize()
    local px = self.outer:get_x()
    local py = self.outer:get_y()
    local pw = self.outer:get_width()
    local ph = self.outer:get_height()
    local top    = py + bi + tb
    local left   = px + bi
    local right  = sw - (px + pw) + bi
    local bottom = sh - (py + ph) + bi
    setBorderSizes(math.max(0, top), math.max(0, right), math.max(0, bottom), math.max(0, left))
    Mux._log("updateConsoleBorders: t=%d r=%d b=%d l=%d", top, right, bottom, left)
end

function MuxPane:show()
    self.outer:show()
end

function MuxPane:hide()
    self.outer:hide()
end

function MuxPane:lock()
    self.locked = true
    if self.titlebar   then self.titlebar:setCursor("Arrow") end
    -- _setAddTabBtnVisible is defined in tabs.lua (loaded after pane.lua).
    if self._addTabBtn then self:_setAddTabBtnVisible(false) end
    if self.closeBtn and not self.closeable then self.closeBtn:hide() end
    if self.splitVBtn then self.splitVBtn:hide() end
    if self.splitHBtn then self.splitHBtn:hide() end
    if self.swapBtn   then self.swapBtn:hide()   end
    self:_setFrameCss(self:_baseFrameCss())
    Mux._log("MuxPane locked: %s", self.id)
end

function MuxPane:unlock()
    self.locked = false
    if self.titlebar   then self.titlebar:setCursor("OpenHand") end
    if self._addTabBtn and self._tabsEnabled then self:_setAddTabBtnVisible(true) end
    if self.closeBtn and not self.noClose and self.titlebarVisible then
        self.closeBtn:show()
    end
    if self.titlebarVisible and not self.floating then
        if self.splittable then
            if self.splitVBtn then self.splitVBtn:show() end
            if self.splitHBtn then self.splitHBtn:show() end
        end
        if self.swappable and self.swapBtn and self._split then self.swapBtn:show() end
    end
    if Mux._focusedPane == self then
        self:_setFrameCss(self:_focusedFrameCss())
    end
    Mux._log("MuxPane unlocked: %s", self.id)
end

function MuxPane:close()
    if self.locked and not self.closeable then
        return
    end
    Mux._closeContextMenu()
    if self.onClose then self.onClose(self) end

    -- Clear singleton content tracking if this pane held singleton content.
    if self._activeContent and Mux._content then
        local def = Mux._content[self._activeContent]
        if def and def.singleton and def._activeTargetRef == self then
            def._activeTargetRef = nil
        end
    end

    if self.floating then
        -- Find and clean up the ghost this pane left behind, then collapse the
        -- slot. Ghost lookup is by slot (not pane→ghost) so promotion scenarios
        -- are handled transparently.
        if self._slot then
            local ghost, gKey = Mux._findGhostBySlot(self._slot)
            if ghost then
                local gSplit = ghost.split
                local gSide  = ghost.side
                Mux._removeGhostSlot(gKey)
                if gSplit then gSplit:collapseSlot(gSide) end
            end
        end
        self.outer:hide()
    else
        if self._slot then self._slot:remove(self.outer) end
        self.outer:hide()
        if self._split then self._split:collapseSlot(self._slotSide) end
    end

    if Mux._focusedPane == self then
        Mux._focusedPane = nil
        tempTimer(0, function()
            if not Mux._focusedPane then
                local ordered = orderedPanes()
                if #ordered > 0 then Mux.setFocus(ordered[1]) end
            end
        end)
    end

    Mux._panes[self.id] = nil
    if self._gid then Mux._tabHosts[self._gid] = nil end
    Mux._freeId(self.id)
    Mux._scheduleAutoSave()
    Mux._log("MuxPane closed: %s", self.id)
end

function MuxPane:applyTheme()
    local theme = Mux.activeTheme()
    if Mux._focusedPane == self and not self.locked then
        self.frame:setStyleSheet(self:_focusedFrameCss())
    else
        self.frame:setStyleSheet(self:_baseFrameCss())
    end
    if self.contentBg  then self.contentBg:setStyleSheet(theme.contentCss or "")       end
    if self.titlebar   then
        self.titlebar:setStyleSheet(theme.titlebarCss or "")
        local tbc = theme.titlebarTextColor or theme.btnTextColor or "#aaaabb"
        self.titlebar:echo(string.format("<span style='color:%s;'>&nbsp;&nbsp;%s</span>", tbc, self.name))
        self:_updateInfoBtnPos()
    end
    local tc = theme.btnTextColor or "#aaaabb"
    if self.infoBtn then
        self.infoBtn:setStyleSheet(theme.btnCss or "")
        if self._infoBtnEcho then self._infoBtnEcho(false) end
    end
    if self.closeBtn   then
        self.closeBtn:setStyleSheet(theme.btnCss or "")
        self.closeBtn:echo(string.format("<center><font color='%s'>✕</font></center>", tc))
    end
    if self.minBtn     then
        self.minBtn:setStyleSheet(theme.btnCss or "")
        self.minBtn:echo(string.format("<center><font color='%s'>–</font></center>", tc))
    end
    if self.zoomBtn    then
        self.zoomBtn:setStyleSheet(theme.btnCss or "")
        self:_updateZoomBtn()
    end
    if self.swapBtn then
        self.swapBtn:setStyleSheet(theme.btnCss or "")
        if self._swapBtnEcho then self._swapBtnEcho(false) end
    end
    if self.splitHBtn then
        self.splitHBtn:setStyleSheet(theme.btnCss or "")
        if self._splitHBtnEcho then self._splitHBtnEcho(false) end
    end
    if self.splitVBtn then
        self.splitVBtn:setStyleSheet(theme.btnCss or "")
        if self._splitVBtnEcho then self._splitVBtnEcho(false) end
    end
    if self.contentBtn then
        self.contentBtn:setStyleSheet(theme.btnCss or "")
        if self._contentBtnEcho then self._contentBtnEcho(false) end
    end
    if self.reveal     then self.reveal:setStyleSheet(theme.revealStripCss or "")       end
    if self._cornerHandles then
        local css = theme.cornerHandleCss or ""
        for _, lbl in ipairs(self._cornerHandles) do lbl:setStyleSheet(css) end
    end
    if self._applyTabTheme then self:_applyTabTheme() end
    self:_applyTitlebarVisibility()
    if self._refreshConnScreen then self:_refreshConnScreen() end
    -- Force Qt to flush pending style repaints. CSS updates set via setStyleSheet
    -- are batched and may not paint until a geometry pass runs; reposition() triggers
    -- that pass without changing any sizes.
    if self.outer then self.outer:reposition() end
end

-- On titlebar release while floating: if the cursor is inside a visible PaneSet,
-- return the pane to its original split slot (if remembered) or embed at PaneSet
-- root level (if the pane has never been in a split here).
function MuxPane:_tryEmbedAt(gx, gy)
    for _, ps in pairs(Mux._paneSets) do
        if ps.visible then
            local px = ps.outer:get_x()
            local py = ps.outer:get_y()
            local pw = ps.outer:get_width()
            local ph = ps.outer:get_height()
            if gx >= px and gx <= px + pw and gy >= py and gy <= py + ph then
                -- Don't re-embed into the same PaneSet unless the original split was
                -- retired (both sides floated), in which case _slot is nil.
                if self._slot and self._paneSet and ps == self._paneSet then return end

                if self._slot then
                    self:embed()
                else
                    self._slot     = ps.outer
                    self._split    = nil
                    self._slotSide = nil
                    self._paneSet  = ps
                    self:embed(ps.outer)
                    ps.root = self
                end
                return
            end
        end
    end
end

-- Eight resize handles on floating panes: four corner squares + four edge strips.
-- Each handle controls which axes move (dx/dy):
--   dx = -1 → move left edge    dx = 1 → move right edge   dx = 0 → no x change
--   dy = -1 → move top edge     dy = 1 → move bottom edge  dy = 0 → no y change
function MuxPane:_buildCornerHandles(theme)
    if self.noResize then return end
    local ch       = (theme.cornerHandleSize or 10)
    local css      = theme.cornerHandleCss      or ""
    local hoverCss = theme.cornerHandleHoverCss or css

    local handles = {
        -- Corners (ch×ch squares)
        { id="nw", x="0px",           y="0px",           w=ch, h=ch,
          cur="ResizeTopLeft",  dx=-1, dy=-1 },
        { id="ne", x=Mux._fromEdgePx(ch),  y="0px",           w=ch, h=ch,
          cur="ResizeTopRight", dx= 1, dy=-1 },
        { id="sw", x="0px",           y=Mux._fromEdgePx(ch),  w=ch, h=ch,
          cur="ResizeTopRight", dx=-1, dy= 1 },
        { id="se", x=Mux._fromEdgePx(ch),  y=Mux._fromEdgePx(ch),  w=ch, h=ch,
          cur="ResizeTopLeft",  dx= 1, dy= 1 },
        -- Edges (strips between corners)
        { id="n",  x=Mux._toPx(ch),     y="0px",           w=Mux._fromEdgePx(ch), h=ch,
          cur=5,    dx= 0, dy=-1 },
        { id="s",  x=Mux._toPx(ch),     y=Mux._fromEdgePx(ch),  w=Mux._fromEdgePx(ch), h=ch,
          cur=5,    dx= 0, dy= 1 },
        { id="w",  x="0px",           y=Mux._toPx(ch),     w=ch, h=Mux._fromEdgePx(ch),
          cur=6,    dx=-1, dy= 0 },
        { id="e",  x=Mux._fromEdgePx(ch),  y=Mux._toPx(ch),     w=ch, h=Mux._fromEdgePx(ch),
          cur=6,    dx= 1, dy= 0 },
    }

    self._cornerHandles = {}

    for _, c in ipairs(handles) do
        local lbl = Geyser.Label:new({
            name    = self._gid .. "_corner_" .. c.id,
            x       = c.x,
            y       = c.y,
            width   = c.w,
            height  = c.h,
            fillBg  = 1,
        }, self.outer)
        lbl:setStyleSheet(css)
        lbl:setCursor(c.cur)
        lbl:hide()

        local drag = { active=false, startX=0, startY=0, paneX=0, paneY=0, paneW=0, paneH=0 }
        local pane = self
        local dx, dy = c.dx, c.dy

        -- Edge handles (n/s/w/e) stay invisible on hover — the cursor change is sufficient.
        -- Corner handles show a highlight for discoverability.
        local isEdge = (#c.id == 1)
        local activeHoverCss = isEdge and css or hoverCss
        lbl:setOnEnter(function() lbl:setStyleSheet(activeHoverCss) end)
        lbl:setOnLeave(function()
            if not drag.active then lbl:setStyleSheet(css) end
        end)

        lbl:setClickCallback(function(event)
            if event.button ~= "LeftButton" then return end
            drag.active = true
            drag.startX = event.globalX
            drag.startY = event.globalY
            drag.paneX  = pane.floatX
            drag.paneY  = pane.floatY
            drag.paneW  = pane.floatW
            drag.paneH  = pane.floatH
        end)

        lbl:setMoveCallback(function(event)
            if not drag.active then return end
            local deltaX = event.globalX - drag.startX
            local deltaY = event.globalY - drag.startY
            local minW, minH = 120, 60

            local newX, newY, newW, newH = drag.paneX, drag.paneY, drag.paneW, drag.paneH

            if dx < 0 then
                local clampedDx = math.min(deltaX, drag.paneW - minW)
                newX = drag.paneX + clampedDx
                newW = drag.paneW - clampedDx
            else
                newW = math.max(minW, drag.paneW + deltaX)
            end

            if dy < 0 then
                local clampedDy = math.min(deltaY, drag.paneH - minH)
                newY = drag.paneY + clampedDy
                newH = drag.paneH - clampedDy
            else
                newH = math.max(minH, drag.paneH + deltaY)
            end

            pane.floatX = newX
            pane.floatY = newY
            pane.floatW = newW
            pane.floatH = newH
            pane.outer:move(newX, newY)
            pane.outer:resize(newW, newH)
            pane.outer:reposition()
        end)

        lbl:setReleaseCallback(function(event)
            if event.button ~= "LeftButton" then return end
            drag.active = false
            lbl:setStyleSheet(css)
        end)

        self._cornerHandles[#self._cornerHandles + 1] = lbl
    end
end

function MuxPane:_showCornerHandles()
    if not self._cornerHandles then return end
    for _, lbl in ipairs(self._cornerHandles) do lbl:show() end
end

function MuxPane:_hideCornerHandles()
    if not self._cornerHandles then return end
    for _, lbl in ipairs(self._cornerHandles) do lbl:hide() end
end

-- Called by Mux.setFocus to change the frame's border CSS without a full applyTheme().
function MuxPane:_setFrameCss(css)
    if self.frame then self.frame:setStyleSheet(css) end
end

-- Unfocused frame CSS. transparentFrame panes pass clicks through to the native
-- console underneath. permanentFloat carries the accent border.
function MuxPane:_baseFrameCss()
    if self.transparentFrame or self.consoleBorders then
        return [[
            background-color: transparent;
            border: 2px solid rgba(255, 255, 255, 0.38);
            border-radius: 3px;
        ]]
    end
    local theme = Mux.activeTheme()
    if self.permanentFloat then
        return (theme.paneOuterCss or "") .. "\n" .. (theme.floatingExtraCss or "")
    end
    return (theme.paneOuterCss or "")
end

-- Focused-highlight frame CSS. permanentFloat panes never take the focus border.
-- With only one embedded pane, focus is implicit — no border highlight needed.
function MuxPane:_focusedFrameCss()
    if self.permanentFloat then return self:_baseFrameCss() end
    local paneCount = 0
    for _, p in pairs(Mux._panes) do
        if not p.floating then
            paneCount = paneCount + 1
            if paneCount > 1 then break end
        end
    end
    if paneCount <= 1 then return self:_baseFrameCss() end
    if self.transparentFrame or self.consoleBorders then
        return [[
            background-color: transparent;
            border: 2px solid rgba(100, 180, 255, 0.85);
            border-radius: 3px;
        ]]
    end
    local theme = Mux.activeTheme()
    return (theme.focusedFrameCss or theme.paneOuterCss or "")
end

function MuxPane:absX()   return self.outer:get_x()      end
function MuxPane:absY()   return self.outer:get_y()      end
function MuxPane:width()  return self.outer:get_width()  end
function MuxPane:height() return self.outer:get_height() end

Mux._log("mux_pane loaded")
