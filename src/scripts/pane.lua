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

MuxPane = Mux._class(MuxSurface)
Mux.Pane = MuxPane

local borderInset = 2   -- px gap so the 2px CSS border on frame is visible all around

function MuxPane:init(opts)
    opts = opts or {}
    local _t0 = Mux.debug and os.clock() or nil
    local theme = Mux.activeTheme()

    self.id               = opts.id   or Mux._newId("pane")
    self._gid             = Mux._newInternalId()   -- Geyser widget name prefix; never recycled
    self.name             = opts.name or self.id
    self.floating         = false
    self.minimized        = false
    self._overflowMode    = false

    -- overlay: always floating; never interacts with any PaneSpace or split.
    -- Drag-to-embed, double-click-to-embed, and Alt+A are all no-ops.
    -- Used for system overlays (settings window, dialogs) that must survive workspace changes.
    self.overlay          = opts.overlay or false

    -- resizable: when false, corner resize handles are never built; pane size is fixed.
    self.resizable        = opts.resizable ~= false
    -- titlebarHideable: when false, the titlebar is permanently visible; hide/toggle is blocked.
    self.titlebarHideable = opts.titlebarHideable ~= false
    -- renamable: when false, name cannot be changed via UI or the rename prompt.
    self.renamable        = opts.renamable ~= false
    -- contentable: Content Library button and menu item are available.
    self.contentable      = opts.contentable ~= false
    -- tabsLocked: when true, the tab bar is frozen (no add/close); set by the user.
    self.tabsLocked       = opts.tabsLocked or false
    -- closeable: close button is shown and close() works.
    self.closeable        = opts.closeable ~= false
    -- contextMenu: when false, right-click context menu on the titlebar is suppressed.
    self.contextMenu      = opts.contextMenu ~= false
    -- propertiesButton: when false, the Properties (≡) button and context menu item are hidden.
    self.propertiesButton = opts.propertiesButton ~= false
    -- zoomable: a zoom button is shown in the titlebar; clicking it expands
    -- this pane to fill the entire screen, above embedded panes and overlay
    -- floaters but below free floating panes.
    self.zoomable         = opts.zoomable ~= false
    self._zoomed          = false
    self._preZoomState    = nil
    self.splittable       = opts.splittable ~= false
    self.swappable        = opts.swappable  ~= false
    -- nameAlign: "left" (default), "center", or "right".
    -- Controls where the pane name text sits in the titlebar and how buttons arrange around it.
    self.nameAlign        = opts.nameAlign or "left"

    if opts.showTitlebar ~= nil then
        self.titlebarVisible = opts.showTitlebar
    else
        self.titlebarVisible = true
    end

    -- Saved pixel geometry used when the pane is floating.
    self.floatX = opts.floatX or 100
    self.floatY = opts.floatY or 100
    self.floatW = opts.floatW or 400
    self.floatH = opts.floatH or 300

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
        if Mux.raisePane then Mux.raisePane(self) end
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
        if Mux.raisePane then Mux.raisePane(self) end
    end)

    -- Composable behavioural flags. All of these can be passed directly, or set
    -- automatically by mainConsoleHost (see below).

    -- convertible: when false, float() / _detachToFloat() silently return; pane stays in its initial state.
    self.convertible      = opts.convertible ~= false
    -- minimizable: when false, the minimize (–) button is hidden regardless of float state.
    self.minimizable      = opts.minimizable ~= false
    -- movable: when false, a floating pane cannot be repositioned by dragging its titlebar.
    self.movable          = opts.movable ~= false
    -- transparentFrame: frame CSS is transparent + click-through, exposing the Qt
    -- surface behind Geyser (e.g. HUD overlays). contentBg is hidden.
    self.transparentFrame = opts.transparentFrame or false
    -- consoleBorders: pane manages setBorderSizes so the Mudlet native console is
    -- visible in the content area. contentBg is hidden; onReposition auto-wired.
    self.consoleBorders   = opts.consoleBorders or false
    -- insertable: when false, excluded from drag-to-split insertion zone detection.
    self.insertable         = opts.insertable ~= false
    -- showSettingsInMenu: context menu shows "Settings" instead of Properties/Close.
    self.showSettingsInMenu = opts.showSettingsInMenu or false
    -- onReposition: optional callback fired whenever the pane's geometry changes due
    -- to an external event (split rebalance, window resize, workspace restore, zoom).
    self.onReposition     = opts.onReposition

    -- mainConsoleHost: convenience bundle for the pane that hosts the Mudlet native
    -- console. Setting it true auto-applies all the composable flags above, so existing
    -- workspace JSON and call sites need no changes. The field is kept as metadata for
    -- workspace serialisation and focus-fallback identification.
    self.mainConsoleHost = opts.mainConsoleHost or false
    if self.mainConsoleHost then
        self.closeable        = false
        self.convertible      = false
        self.consoleBorders   = true
        self.showSettingsInMenu = true
        self.contentable      = false
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

    -- Chain _checkOverflow into every pane's onReposition so button overflow
    -- is re-evaluated whenever a split handle is dragged or the window resizes.
    local prevOnRepos = self.onReposition
    self.onReposition = function(p)
        if prevOnRepos then prevOnRepos(p) end
        if p.titlebar then p:_checkOverflow() end
    end

    Mux._panes[self.id] = self
    Mux._log("MuxPane created: %s", self.id)
    if _t0 then
        Mux._echo(string.format("\n<grey>[mux perf] pane create %s = %.1fms<reset>\n",
            self.id, (os.clock() - _t0) * 1000))
    end
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
    self.titlebar:setCursor("OpenHand")

    -- Per-pane drag state. Local closure means panes never interfere with each other.
    local drag = {
        active            = false,
        startX            = 0, startY = 0,
        paneX             = 0, paneY  = 0,
        lastHoverGhostKey = nil,   -- slotKey of the currently highlighted ghost slot
        insertTarget      = nil,   -- {pane, edge} of the currently previewed insertion zone
        dropTargets       = nil,   -- cached insertable-pane rects, snapshotted once per drag
        ghostRects        = nil,   -- cached ghost-slot rects, snapshotted once per drag
    }

    -- Snapshots the geometry of every drop target (insertable embedded panes and
    -- ghost slots) once per drag. These don't move while a pane is being dragged,
    -- so re-querying their positions every mouse-move frame is wasted work that
    -- grows with both pane count and nesting depth (absX/width walk the container
    -- constraint chain to the root). Rebuilt after _detachToFloat, which is the
    -- only point the embedded layout reflows during a drag.
    local function snapshotDropTargets()
        local targets = {}
        for _, tp in pairs(Mux._panes) do
            if not tp.floating and tp.insertable and tp ~= self then
                targets[#targets + 1] = {
                    pane = tp,
                    x = tp:absX(), y = tp:absY(),
                    w = tp:width(), h = tp:height(),
                }
            end
        end
        drag.dropTargets = targets

        local ghosts = {}
        for key, ghost in pairs(Mux._ghostSlots) do
            ghosts[#ghosts + 1] = {
                key = key,
                x = ghost.slot:get_x(), y = ghost.slot:get_y(),
                w = ghost.slot:get_width(), h = ghost.slot:get_height(),
            }
        end
        drag.ghostRects = ghosts
    end

    self.titlebar:setClickCallback(function(event)
        if event.button == "RightButton" then
            local compact = Mux.settings.get and Mux.settings.get("mux", "compact_titlebar")
            if (self._overflowMode or compact) and self.contextMenu then
                Mux._showContextMenu(self, event.globalX or 0, event.globalY or 0)
            end
            return
        end
        if event.button ~= "LeftButton" then return end
        if Mux.raisePane then Mux.raisePane(self) end
        if not self.convertible and not self.floating then return end
        if not self.movable then return end  -- block non-movable regardless of float state
        drag.active = true
        drag.startX = event.globalX
        drag.startY = event.globalY
        drag.paneX  = self.outer:get_x()
        drag.paneY  = self.outer:get_y()
        drag.dropTargets = nil  -- snapshot lazily on the first move frame
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
            drag.dropTargets = nil  -- layout reflowed on detach; re-snapshot below
        end
        local newX = drag.paneX + (event.globalX - drag.startX)
        local newY = drag.paneY + (event.globalY - drag.startY)
        self.outer:move(newX, newY)
        self.outer:reposition()
        self.floatX = newX
        self.floatY = newY

        if not self.convertible then return end
        local gx, gy = event.globalX, event.globalY
        if not drag.dropTargets then snapshotDropTargets() end

        -- Ghost slot hover: highlight whichever slot the cursor is over.
        local newHoverGhost = nil
        for _, g in ipairs(drag.ghostRects) do
            if gx >= g.x and gx <= g.x + g.w and gy >= g.y and gy <= g.y + g.h then
                newHoverGhost = g.key
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
            local insertPane, insertEdge, rect = nil, nil, nil
            for _, t in ipairs(drag.dropTargets) do
                if gx >= t.x and gx <= t.x + t.w and gy >= t.y and gy <= t.y + t.h then
                    local minPx, maxPx = 30, 80
                    local edgeH = Mux._clamp(t.h * 0.20, minPx, maxPx)
                    local edgeW = Mux._clamp(t.w * 0.20, minPx, maxPx)
                    if gy <= t.y + edgeH then
                        insertEdge = "top"
                    elseif gy >= t.y + t.h - edgeH then
                        insertEdge = "bottom"
                    elseif gx <= t.x + edgeW then
                        insertEdge = "left"
                    elseif gx >= t.x + t.w - edgeW then
                        insertEdge = "right"
                    end
                    if insertEdge then insertPane, rect = t.pane, t end
                    break
                end
            end
            if insertPane then
                Mux._showInsertionGhost(rect.x, rect.y, rect.w, rect.h, insertEdge)
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
        self.titlebar:setCursor(self:_titlebarCursor())
        if self.floating then Mux._scheduleAutoSave() end

        if drag.lastHoverGhostKey then
            local prev = Mux._ghostSlots[drag.lastHoverGhostKey]
            if prev then Mux._unhighlightGhostSlot(prev) end
        end
        Mux._hideInsertionGhost()

        if not self.floating or not self.convertible then
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
                self._paneSpace  = ghost.paneSpace
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

        -- Drop priority 3: normal PaneSpace drop.
        self:_tryEmbedAt(event.globalX, event.globalY)
    end)

    -- Double-click embeds a floating pane into the nearest ghost slot.
    -- For embedded panes, double-click just sets focus.
    self.titlebar:setDoubleClickCallback(function(event)
        if not self.convertible then return end
        if not self.floating then
            if Mux.raisePane then Mux.raisePane(self) end
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
        self._paneSpace  = target.paneSpace
        if target.split then
            if target.side == "a" then target.split.childA = self
            else                      target.split.childB = self
            end
        end
        self:embed()
    end)

    -- ── Titlebar buttons ──────────────────────────────────────────────────────
    -- Every titlebar button is an identically shaped Label in the header that
    -- swaps stylesheet + glyph colour on hover and runs a click handler.
    -- _makeTitlebarButton builds one from a spec and returns the Label plus its
    -- echo closure; the closure is stored on self so applyTheme(), lock/unlock,
    -- and zoom toggling can repaint the glyph. Qt ignores CSS `color:` on a
    -- QLabel containing rich text, so the glyph colour is set with <font color>.
    --
    -- spec fields:
    --   suffix    widget-name suffix appended to self._gid
    --   x         Geyser x (negative string = px from the header's right edge)
    --   icon      glyph string, or a function returning one (for dynamic icons)
    --   tooltip   hover tooltip (optional)
    --   hoverCss  theme key for the hover stylesheet (default "minHoverCss")
    --   onClick   click callback (optional)
    local function makeTitlebarButton(spec)
        local btn = Geyser.Label:new({
            name   = self._gid .. spec.suffix,
            x      = spec.x,
            y      = tostring(btnY),
            width  = tostring(theme.btnSize),
            height = tostring(btnH),
            fillBg = 1,
        }, self.header)
        btn:setStyleSheet(theme.btnCss or "")
        local hoverKey = spec.hoverCss or "minHoverCss"
        local function echo(hovered)
            local tc   = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
            local icon = (type(spec.icon) == "function") and spec.icon() or spec.icon
            btn:echo(string.format("<center><font color='%s'>%s</font></center>", tc, icon))
        end
        echo(false)
        if spec.tooltip then btn:setToolTip(spec.tooltip) end
        btn:setOnEnter(function()
            btn:setStyleSheet(Mux.activeTheme()[hoverKey] or Mux.activeTheme().btnCss)
            echo(true)
        end)
        btn:setOnLeave(function()
            btn:setStyleSheet(Mux.activeTheme().btnCss or "")
            echo(false)
        end)
        if spec.onClick then btn:setClickCallback(spec.onClick) end
        return btn, echo
    end

    -- infoBtn sits just after the pane name (x via _infoBtnX). Gear (⚙) for panes
    -- that own the Settings panel, list icon (≡) where Properties applies.
    -- Visibility is managed by _applyTitlebarVisibility.
    self.infoBtn, self._infoBtnEcho = makeTitlebarButton({
        suffix  = "_info",
        x       = tostring(self:_infoBtnX()),
        icon    = self.showSettingsInMenu and "⚙" or "≡",
        tooltip = self.showSettingsInMenu and "Settings" or "Properties",
        onClick = function(event)
            if event.button ~= "LeftButton" then return end
            if self.showSettingsInMenu then
                Mux.settings.toggle()
            else
                Mux.showPaneProperties(self)
            end
        end,
    })

    -- closeBtn: 20px from the right edge. Uses the dedicated close-hover style.
    self.closeBtn, self._closeBtnEcho = makeTitlebarButton({
        suffix   = "_close",
        x        = "-20",
        icon     = "✕",
        tooltip  = "Close pane",
        hoverCss = "closeHoverCss",
        onClick  = function(event)
            if event.button == "LeftButton" then self:_confirmClose() end
        end,
    })

    -- minBtn: x="-42" = btnSize(18) + gap(2) + close offset(20) + margin(2).
    self.minBtn, self._minBtnEcho = makeTitlebarButton({
        suffix  = "_min",
        x       = "-42",
        icon    = "–",
        tooltip = "Minimize pane",
        onClick = function(event)
            if event.button == "LeftButton" then self:toggleMinimize() end
        end,
    })

    -- zoomBtn: x="-70", left of minBtn with a clear gap. Icon reflects zoom state.
    self.zoomBtn, self._zoomBtnEcho = makeTitlebarButton({
        suffix  = "_zoom",
        x       = "-70",
        icon    = function()
            return self._zoomed and "⧉" or "<span style='font-size:12px;line-height:1;'>□</span>"
        end,
        tooltip = "Zoom",
        onClick = function(event)
            if event.button == "LeftButton" then self:zoom() end
        end,
    })
    self.zoomBtn:hide()  -- shown by _updateZoomBtn once embedded in a split

    -- swapBtn: x="-96" — 8px gap after zoomBtn before the split/action cluster.
    self.swapBtn, self._swapBtnEcho = makeTitlebarButton({
        suffix  = "_swap",
        x       = "-96",
        icon    = "⇔",
        tooltip = "Swap with sibling",
        onClick = function(event)
            if event.button == "LeftButton" and self._split then
                self._split:swapSlots()
            end
        end,
    })
    if not self.swappable then self.swapBtn:hide() end

    -- splitHBtn: x="-120" — horizontal split (one pane above the other; "v" internally).
    self.splitHBtn, self._splitHBtnEcho = makeTitlebarButton({
        suffix  = "_splitH",
        x       = "-120",
        icon    = "═",
        tooltip = "Split horizontally (top / bottom)",
        onClick = function(event)
            if event.button == "LeftButton" then
                self:split("v")
            end
        end,
    })
    if not self.splittable then self.splitHBtn:hide() end

    -- splitVBtn: x="-140" — vertical split (two panes side by side; "h" internally).
    self.splitVBtn, self._splitVBtnEcho = makeTitlebarButton({
        suffix  = "_splitV",
        x       = "-140",
        icon    = "║",
        tooltip = "Split vertically (side by side)",
        onClick = function(event)
            if event.button == "LeftButton" then
                self:split("h")
            end
        end,
    })
    if not self.splittable then self.splitVBtn:hide() end

    -- contentBtn: x="-210" — separated from the split cluster.
    self.contentBtn, self._contentBtnEcho = makeTitlebarButton({
        suffix  = "_cadd",
        x       = "-210",
        icon    = "▥",
        tooltip = "Content Library",
        onClick = function(event)
            if event.button ~= "LeftButton" then return end
            Mux._showContentLibrary(self)
        end,
    })
    if not self.contentable then self.contentBtn:hide() end

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

    self:_refreshTitlebarName()
    self:_applyTitlebarVisibility()
end

function MuxPane:setTitlebarVisible(visible)
    if not visible and not self.titlebarHideable then return end
    self.titlebarVisible = visible
    self:_applyTitlebarVisibility()
end

-- Pixel width of the rendered titlebar name. Counts UTF-8 characters (every
-- byte that is not a 0x80–0xBF continuation byte begins one character) times
-- the theme's per-character width. Shared by every alignment so the name is
-- measured one way everywhere.
function MuxPane:_titlebarNameWidth()
    local charW = (Mux.activeTheme and Mux.activeTheme().titlebarCharWidth) or 7
    local name  = self.name or ""
    -- Cache the result: the gsub runs once per rename / theme change rather than
    -- on every reposition frame during a resize.
    if self._nwName == name and self._nwCharW == charW then
        return self._nwVal
    end
    local _, chars = string.gsub(name, "[^\128-\191]", "")
    self._nwName  = name
    self._nwCharW = charW
    self._nwVal   = math.ceil(chars * charW)
    return self._nwVal
end

-- Pixel x where infoBtn starts in left-align: just past the pane name text.
-- ~8px for label left edge + 2 &nbsp; chars, then name width, then 4px gap.
function MuxPane:_infoBtnX()
    return 8 + self:_titlebarNameWidth() + 4
end

-- Moves the left-anchored cluster (Properties, then Content Library to its right)
-- to its correct position: trailing the name in left-align, parked at the far
-- left otherwise. Called on name changes and from _layoutTitlebarButtons.
function MuxPane:_updateInfoBtnPos()
    if not (self.infoBtn or self.contentBtn) then return end
    local theme = Mux.activeTheme and Mux.activeTheme() or {}
    local y     = theme.btnTopMargin or 2
    local btnSz = theme.btnSize or 22
    local x0    = ((self.nameAlign or "left") == "left") and self:_infoBtnX() or 2
    if self.infoBtn    then self.infoBtn:move(x0, y) end
    if self.contentBtn then self.contentBtn:move(x0 + btnSz + 4, y) end
end

-- Returns the HTML string for the titlebar name, styled for the current nameAlign.
-- The right-align margin-right matches namePad in _layoutTitlebarButtons so the
-- glyphs line up with the slot reserved for the name.
function MuxPane:_nameHtml()
    local theme = Mux.activeTheme and Mux.activeTheme() or {}
    local tbc   = theme.titlebarTextColor or theme.btnTextColor or "#aaaabb"
    local align = self.nameAlign or "left"
    if align == "center" then
        return string.format(
            "<center><span style='color:%s;'>%s</span></center>", tbc, self.name)
    elseif align == "right" then
        return string.format(
            "<div style='text-align:right;margin-right:6px;'><span style='color:%s;'>%s</span></div>",
            tbc, self.name)
    else
        return string.format(
            "<span style='color:%s;'>&nbsp;&nbsp;%s</span>", tbc, self.name)
    end
end

-- Re-echoes the titlebar label with the current alignment HTML.
function MuxPane:_refreshTitlebarName()
    if self.titlebar then self.titlebar:echo(self:_nameHtml()) end
end

-- Sets the titlebar button anchors and name-label layout for the current
-- nameAlign. The button positions depend only on alignment, the name width, and
-- the top margin — never on the header width — so each button is anchored a
-- constant distance from the header's right edge (via _fromEdgePx, exactly like
-- the corner handles). Geyser's reposition cascade then tracks them for free
-- whenever the pane resizes, so this does NOT need to run per resize frame.
--
-- A signature of those inputs gates the work: repeated calls with an unchanged
-- signature (the common case while a split handle is being dragged) return
-- immediately, which is what keeps embedded-pane resize cheap with many panes.
--
-- One model serves all three alignments. The titlebar Label always spans the
-- full header (a permanent "100%" anchor) and renders the name via CSS
-- (_nameHtml); the button cluster slides left by `nameSlot` so the name owns the
-- far-right edge in right-align. nameSlot is zero for left and center.
function MuxPane:_layoutTitlebarButtons()
    if not self.titlebar then return end

    local theme = Mux.activeTheme and Mux.activeTheme() or {}
    local btnY  = theme.btnTopMargin or 2
    local align = self.nameAlign or "left"
    local nameW = self:_titlebarNameWidth()

    -- nameW covers both the right-align cluster offset and the left-align infoBtn
    -- position; btnY is the only other input. Nothing here tracks header width.
    local sig = align .. ":" .. nameW .. ":" .. btnY
    if sig == self._btnLayoutSig then return end
    self._btnLayoutSig = sig

    -- namePad is the gap from the header's right edge to the name; clusterGap
    -- separates the button cluster from the name. namePad must match the
    -- margin-right in _nameHtml.
    local namePad, clusterGap = 6, 6
    local nameSlot = (align == "right") and (namePad + nameW + clusterGap) or 0

    local yPx = Mux._toPx(btnY)
    local function rightAnchor(btn, offset)
        if btn then btn:move(Mux._fromEdgePx(nameSlot + offset), yPx) end
    end
    rightAnchor(self.closeBtn,   20)
    rightAnchor(self.minBtn,     42)
    rightAnchor(self.zoomBtn,    70)
    rightAnchor(self.swapBtn,    96)
    rightAnchor(self.splitHBtn, 120)
    rightAnchor(self.splitVBtn, 140)

    -- Properties + Content Library anchor to the LEFT (Content sits just right of
    -- Properties), trailing the name in left-align and parked far-left otherwise.
    self:_updateInfoBtnPos()
end

-- Sets the name alignment and refreshes the titlebar layout.
function MuxPane:setNameAlign(align)
    self.nameAlign = align
    if not self.titlebar then return end
    self:_layoutTitlebarButtons()
    self:_refreshTitlebarName()
    self:_checkOverflow()
end

-- Checks whether visible buttons fit in the current header width and repositions them.
-- If too narrow: hides action buttons (overflow mode — right-click shows them as a menu).
-- If wide enough: restores button visibility without calling _applyTitlebarVisibility().
function MuxPane:_checkOverflow()
    if not self.titlebarVisible then return end
    -- During a live handle drag this is called for every pane on every reposition
    -- frame. Anchored titlebar buttons already track position via reposition, so
    -- only overflow *visibility* could change — and that can wait until the drag
    -- ends (MuxSplit:_flushRatio re-runs this once across the sub-tree). Skipping
    -- the per-frame width query keeps resize cheap with many panes.
    if Mux._resizing then return end
    local headerW = self.header:get_width()
    if headerW < 10 then return end  -- not yet laid out; skip

    -- Refresh button anchors if alignment / name width changed. This is gated
    -- internally, so during a live resize (where those inputs are stable) it is a
    -- no-op and the buttons track the header edge via Geyser's reposition cascade.
    self:_layoutTitlebarButtons()

    local compact = Mux.settings.get and Mux.settings.get("mux", "compact_titlebar")
    local align   = self.nameAlign or "left"

    local showInfo = self.infoBtn and self.contextMenu
        and (self.showSettingsInMenu or self.propertiesButton)
    local infoBtnW    = showInfo and 22 or 0
    local contentBtnW = self:_contentEnabled() and 26 or 0   -- now part of the left cluster
    local nameW       = self:_titlebarNameWidth()

    -- Always-visible close + min cluster.
    local closeMinW = 22
    if self.floating and self.minimizable then closeMinW = closeMinW + 22 end

    -- Width of the right-anchored action cluster in the current state.
    local rightW = closeMinW
    if self.zoomable and (self._split or self.floating or self._zoomed)          then rightW = rightW + 28 end
    if self.swappable and self._split and not self.floating      then rightW = rightW + 26 end
    if self.splittable and not self.floating                     then rightW = rightW + 44 end

    local newOverflow
    if align == "right" then
        -- Cluster stays on the right; the name reserves a slot to its right.
        -- Same shape as center plus the name slot. namePad / clusterGap match
        -- _layoutTitlebarButtons.
        local namePad, clusterGap = 6, 6
        local leftW = 6 + infoBtnW + contentBtnW
        newOverflow = compact
            or (headerW < leftW + rightW + namePad + nameW + clusterGap + 10)
    else
        if align == "center" then
            local leftW = 6 + infoBtnW + contentBtnW
            newOverflow = compact or (headerW < leftW + nameW + rightW + 10)
        else  -- left
            local leftW = 16 + nameW + 4 + infoBtnW + contentBtnW
            newOverflow = compact or (headerW < leftW + rightW + 10)
        end
    end

    if newOverflow == self._overflowMode then return end
    self._overflowMode = newOverflow

    if newOverflow then
        -- Secondary action buttons collapse into the right-click context menu.
        -- closeBtn and minBtn are primary window controls; they stay visible so
        -- panes without a context menu (dialogs, settings) always have a close target.
        if self.infoBtn    then self.infoBtn:hide()    end
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
        if not self.closeable then
            self.closeBtn:hide()
        else
            self.closeBtn:show()
        end
        if self:_minBtnVisible() then self.minBtn:show() else self.minBtn:hide() end
        if self.zoomable and (self._split or self.floating or self._zoomed) then self.zoomBtn:show() else self.zoomBtn:hide() end
        if self.splittable and not self.floating then
            self.splitVBtn:show(); self.splitHBtn:show()
        else
            self.splitVBtn:hide(); self.splitHBtn:hide()
        end
        if self.swappable and not self.floating and self._split then
            self.swapBtn:show()
        else
            self.swapBtn:hide()
        end
        if self.contentBtn then
            if self:_contentEnabled() then self.contentBtn:show() else self.contentBtn:hide() end
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
            local showInfo = self.contextMenu
                and (self.showSettingsInMenu or self.propertiesButton)
            if showInfo then self.infoBtn:show() else self.infoBtn:hide() end
        end
        if not self.closeable then
            self.closeBtn:hide()
        else
            self.closeBtn:show()
        end
        if self:_minBtnVisible() then self.minBtn:show() else self.minBtn:hide() end
        if self.zoomable and (self._split or self.floating or self._zoomed) then self.zoomBtn:show() else self.zoomBtn:hide() end
        if self.splittable and not self.floating then
            self.splitVBtn:show(); self.splitHBtn:show()
        else
            self.splitVBtn:hide(); self.splitHBtn:hide()
        end
        if self.swappable and not self.floating and self._split then
            self.swapBtn:show()
        else
            self.swapBtn:hide()
        end
        if self.contentBtn then
            if self:_contentEnabled() then self.contentBtn:show() else self.contentBtn:hide() end
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
            -- Restore resizability that was locked during collapse.
            self.resizable = self._preMinimizeResizable ~= nil and self._preMinimizeResizable or true
            self._preMinimizeResizable = nil
            self._split:_updateHandleResizability()
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
            -- Horizontal splits collapse along the titlebar axis; not supported.
            if self._split.direction ~= "v" then
                self.minimized = false
                return
            end
            local split    = self._split
            local handlePx = theme.handleSize or 3
            local boxH     = split.box:get_height()
            local minPx    = theme.titlebarHeight + borderInset * 2
            local dyn      = boxH - handlePx
            local minR     = (dyn > 0) and Mux._clamp(minPx / dyn, 0.01, 0.25) or 0.05
            self._savedMinimizeRatio   = split.ratio
            self._preMinimizeResizable = self.resizable
            self.resizable             = false
            local newR = (self._slotSide == "a") and minR or (1 - minR)
            split:_setRatio(Mux._clamp(newR, 0.01, 0.99))
            split:_updateHandleResizability()
        end
        -- Hide content after resize so nothing bleeds through the collapsed strip.
        if self.content then self.content:hide() end
        if self.onMinimize then self.onMinimize(self, true) end
    end
end

function MuxPane:setName(text)
    self.name = text
    self:_refreshTitlebarName()
    self:_updateInfoBtnPos()
    self:_updatePlaceholder()
    self:_checkOverflow()
end

-- Returns true when the pane-level Content Library button and menu item should
-- be available. Hidden whenever tabs own the content slot:
--   • tabs enabled (content goes into individual tabs)
--   • tabs disabled but tab bar still has tabs being dragged out
-- Only restored when the bar has fully collapsed (no tabs, tabs disabled).
function MuxSurface:_contentEnabled()
    if not self.contentable then return false end
    if self._tabsEnabled then return false end
    if self._tabs and #self._tabs > 0 then return false end
    return true
end

-- Placeholder shown on contentBg until real content is attached.
-- Any user widget placed as a sibling naturally renders above it.
function MuxSurface:_updatePlaceholder()
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
        .. "≡ Properties button in the titlebar"
        .. "</span>"
        .. (self.contentable
            and "<br/><span style='color:rgba(100,165,255,0.4);font-size:9px;'>▥ Content Library via titlebar</span>"
            or  "")
        .. "</div>",
        ds, self.name, is, self.id, cs, self.id)
    self.contentBg:echo(html)
end

-- Re-evaluates the drag-lock state of every split handle from this pane up to
-- the root. A non-resizable pane must lock not only the handle it shares with
-- its immediate sibling but every ancestor handle that could change its size,
-- so none of its borders can be dragged. _childResizable already recurses; this
-- just makes sure each ancestor split re-checks after a resizable change.
function MuxPane:_refreshResizeHandles()
    local s = self._split
    while s do
        if s._updateHandleResizability then s:_updateHandleResizability() end
        s = s._parentSplit
    end
end

-- Splits this pane in place, creating a sibling pane in a new split.
-- direction "v" = side-by-side, "h" = top/bottom (internal convention). Returns
-- the new MuxSplit, or nil if the pane can't be split. This is the operation the
-- titlebar split buttons invoke and the programmatic entry point for scripting.
function MuxPane:split(direction, ratio)
    if self.floating or not self.splittable then return nil end

    direction = direction or "v"
    if not ratio then
        ratio = 0.5
    end

    if self._split then
        local newSplit = self._split:_splitPaneInSlot(self, direction, ratio)
        if newSplit then
            tempTimer(0, function()
                Mux.raiseFloatingPanes()
                Mux._scheduleAutoSave()
            end)
        end
        return newSplit
    end

    -- Pane is the direct root of a PaneSpace — wrap it in a new split.
    local ps = self._paneSpace
    if not ps then
        Mux._err("MuxPane:split: pane '%s' has no PaneSpace reference", self.id)
        return nil
    end
    local newSplit = MuxSplit:new({
        direction = direction,
        ratio     = ratio,
        parent    = ps.outer,
    })
    newSplit:place(self, "a")
    local newPane = MuxPane:new({ parent = newSplit.slotB })
    newSplit:place(newPane, "b")
    newPane._paneSpace = ps
    ps.root = newSplit
    local wasInResize = Mux._inResize
    Mux._inResize = true
    Mux._suppressReposition(function() newSplit.box:organize() end)
    Mux._applyGeometry(newSplit.box)
    Mux._notifyAllReposition()
    Mux._inResize = wasInResize
    tempTimer(0, function()
        Mux.raiseFloatingPanes()
        Mux._scheduleAutoSave()
    end)
    return newSplit
end

function MuxPane:float()
    if self.floating then return end
    if not self.convertible then return end
    if not self.movable then return end
    self.floatX = self.outer:get_x()
    self.floatY = self.outer:get_y()
    self.floatW = self.outer:get_width()
    self.floatH = self.outer:get_height()
    self:_detachToFloat()
end

function MuxPane:_detachToFloat()
    if self.floating then return end
    if not self.convertible and not self.overlay then return end
    -- If minimized-in-split, restore before floating so sibling ratio isn't stuck.
    if self.minimized and self._split and self._savedMinimizeRatio then
        self._split:_setRatio(self._savedMinimizeRatio)
        self._savedMinimizeRatio  = nil
        self.resizable            = self._preMinimizeResizable ~= nil and self._preMinimizeResizable or true
        self._preMinimizeResizable = nil
        self._split:_updateHandleResizability()
    end
    self.minimized = false
    if self.content then self.content:show() end
    self.floating = true
    if self.titlebar then self.titlebar:setCursor(self:_titlebarCursor()) end
    self.outer:changeContainer(Geyser)
    self.outer:move(self.floatX, self.floatY)
    self.outer:resize(self.floatW, self.floatH)
    self.outer:reposition()
    self:raise()
    self.frame:setStyleSheet(self:_baseFrameCss())
    if self.resizable then self:_showCornerHandles() else self:_hideCornerHandles() end
    if self.titlebarVisible and self.minimizable then
        self.minBtn:show()
    end
    if self.splitVBtn then self.splitVBtn:hide() end
    if self.splitHBtn then self.splitHBtn:hide() end
    if self.swapBtn   then self.swapBtn:hide()   end
    -- Always leave a ghost slot in the vacated split slot. Ghosts persist until
    -- explicitly dismissed (×) or the pane is closed; they never auto-vanish.
    if self._split then
        Mux._createGhostSlot(self._slot, self._split, self._slotSide, self._paneSpace)
        -- Raise ALL floating panes so none are obscured by the new ghost.
        Mux.raiseFloatingPanes()
    end
    if self.onFloat then self.onFloat(self) end
    if not self.overlay then Mux._scheduleAutoSave() end
    Mux._log("MuxPane floated: %s (%.0f,%.0f %.0fx%.0f)",
        self.id, self.floatX, self.floatY, self.floatW, self.floatH)
end

function MuxPane:embed(slot)
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
    if self.titlebar then self.titlebar:setCursor(self:_titlebarCursor()) end
    self.outer:changeContainer(target)
    self.outer:move("0%", "0%")
    self.outer:resize("100%", "100%")
    self.outer:reposition()
    self.frame:setStyleSheet(self:_baseFrameCss())
    self:_hideCornerHandles()
    if self.titlebarVisible then
        -- _minBtnVisible checks self._split.direction which may not be set yet at
        -- embed() time (split.place() runs after embed()); _checkOverflow fixes it up.
        if self:_minBtnVisible() then self.minBtn:show() else self.minBtn:hide() end
        if self.splittable then
            if self.splitVBtn then self.splitVBtn:show() end
            if self.splitHBtn then self.splitHBtn:show() end
        end
        if self.swappable and self._split then
            if self.swapBtn then self.swapBtn:show() end
        end
    else
        self.minBtn:hide()
    end
    tempTimer(0, function() if self.titlebar then self:_checkOverflow() end end)
    if self.onEmbed then self.onEmbed(self) end
    self:_updateZoomBtn()
    if self._split then self._split:_updateHandleResizability() end
    Mux._scheduleAutoSave()
    Mux._log("MuxPane embedded: %s", self.id)
    Mux.raiseFloatingPanes()
end

-- Zoom this pane to fill the full screen, floating above embedded panes and
-- overlay floaters but below free floating panes.
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
        paneSpace     = self._paneSpace,
    }
    if not self.floating then
        -- Detach from the split tree into the Geyser root, leaving a ghost slot
        -- behind so the layout does not collapse while we are zoomed.
        self.floating = true
        self.outer:changeContainer(Geyser)
        self.frame:setStyleSheet(self:_baseFrameCss())
        if self._split then
            Mux._createGhostSlot(self._slot, self._split, self._slotSide, self._paneSpace)
        end
        -- consoleBorders panes have a transparent frame; hiding the pane space
        -- prevents other panes from showing through while zoomed.
        if self.consoleBorders and self._paneSpace then
            self._paneSpace.outer:hide()
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
        if self.resizable then self:_showCornerHandles() else self:_hideCornerHandles() end
        if self.titlebarVisible and self.minimizable then
            self.minBtn:show()
        end
    else
        -- Re-embed into the original slot and remove the ghost we left behind.
        if state.slot then
            Mux._removeGhostSlotBySlot(state.slot)
            if state.split then state.split.box:show() end
        end
        self.floating = false
        local target = state.slot or (state.paneSpace and state.paneSpace.outer)
        if target then self.outer:changeContainer(target) end
        self.outer:move("0%", "0%")
        self.outer:resize("100%", "100%")
        self.outer:reposition()
        self.frame:setStyleSheet(self:_baseFrameCss())
        self:_hideCornerHandles()
        self.minBtn:hide()
        if self.consoleBorders and self._paneSpace then
            self._paneSpace.outer:show()
        end
        if self.titlebarVisible then
            if self.splittable then
                if self.splitVBtn then self.splitVBtn:show() end
                if self.splitHBtn then self.splitHBtn:show() end
            end
            if self.swappable and self._split then
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
    if self.zoomable and (self._split or self.floating or self._zoomed) then
        self.zoomBtn:show()
    else
        self.zoomBtn:hide()
    end
end

function MuxPane:_updateSwapBtn()
    if not self.swapBtn then return end
    if self.swappable and not self.floating and self._split then
        self.swapBtn:show()
    else
        self.swapBtn:hide()
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

-- Returns the cursor name the titlebar should display based on current drag capability.
-- Whether the minimize button should be visible for this pane right now.
-- Horizontal-split embedded collapse is not supported (titlebar would be squashed),
-- so minBtn only shows when floating or in a vertical (top/bottom) split.
function MuxPane:_minBtnVisible()
    if not self.minimizable then return false end
    if self.floating then return true end
    return self._split ~= nil and self._split.direction == "v"
end

function MuxPane:_titlebarCursor()
    if self.floating then
        return (self.movable ~= false) and "OpenHand" or "Arrow"
    else
        return (self.convertible ~= false and self.movable ~= false) and "OpenHand" or "Arrow"
    end
end

function MuxPane:_confirmClose()
    if not self.closeable then return end
    if self.overlay then self:close(); return end  -- dialogs: no confirm needed
    local doConfirm = Mux.settings.get("mux", "confirmPaneClose")
    if doConfirm == nil then doConfirm = true end
    if not doConfirm then
        self:close()
        return
    end
    local sw    = getMainWindowSize()
    local cw    = 340
    local pane  = self
    local key   = "confirm:close:" .. self.id
    local existing = Mux.getDialog(key)
    if existing then existing:show(); existing:raise(); return end
    local confirmD = Mux.createDialog({
        title         = "Close Pane?",
        x             = math.floor((sw - cw) / 2),
        y             = 0,
        width         = cw, height = 140,
        closeable     = false,
        minimizable   = false,
        contextMenu   = false,
        singleton     = key,
    })
    Mux._pendingPaneClose = { paneName = self.name, onProceed = function() pane:close() end }
    Mux._applyContent(confirmD, "mux_pane_close_confirm")
    confirmD:show()
    confirmD:raise()
end

function MuxPane:close()
    local _t0 = Mux.debug and os.clock() or nil
    if self._propertiesDialogs then
        for _, dlg in pairs(self._propertiesDialogs) do
            pcall(function() dlg:close() end)
        end
        self._propertiesDialogs = nil
    end
    Mux._closeContextMenu()
    if self.onClose then self.onClose(self) end

    -- Call remove callback so content can tear down event handlers and widgets.
    if self._activeContent and Mux._content then
        local def = Mux._content[self._activeContent]
        if def then
            if def.singleton and def._activeTargetRef == self then
                def._activeTargetRef = nil
            end
            if type(def.remove) == "function" then pcall(def.remove, self) end
        end
        self._activeContent = nil
    end
    -- Clean up content on any tabs this pane owns.
    if self._tabs then
        for _, tab in ipairs(self._tabs) do
            if tab._activeContent and Mux._content then
                local def = Mux._content[tab._activeContent]
                if def then
                    if def.singleton and def._activeTargetRef == tab then
                        def._activeTargetRef = nil
                    end
                    if type(def.remove) == "function" then pcall(def.remove, tab) end
                end
            end
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

    Mux._panes[self.id] = nil
    if self._gid then Mux._tabHosts[self._gid] = nil end
    if self._singletonKey and Mux._singletonDialogs then
        Mux._singletonDialogs[self._singletonKey] = nil
    end
    Mux._freeId(self.id)
    Mux._scheduleAutoSave()
    Mux._log("MuxPane closed: %s", self.id)
    if _t0 then
        Mux._echo(string.format("\n<grey>[mux perf] pane destroy %s = %.1fms<reset>\n",
            self.id, (os.clock() - _t0) * 1000))
    end
end

function MuxPane:applyTheme()
    local theme = Mux.activeTheme()
    if self.frame then self.frame:setStyleSheet(self:_baseFrameCss()) end
    if self.contentBg  then self.contentBg:setStyleSheet(theme.contentCss or "")       end
    if self.titlebar   then
        self.titlebar:setStyleSheet(theme.titlebarCss or "")
        local tbc = theme.titlebarTextColor or theme.btnTextColor or "#aaaabb"
        self.titlebar:echo(string.format("<span style='color:%s;'>&nbsp;&nbsp;%s</span>", tbc, self.name))
        self:_updateInfoBtnPos()
    end
    if self.infoBtn then
        self.infoBtn:setStyleSheet(theme.btnCss or "")
        if self._infoBtnEcho then self._infoBtnEcho(false) end
    end
    if self.closeBtn   then
        self.closeBtn:setStyleSheet(theme.btnCss or "")
        if self._closeBtnEcho then self._closeBtnEcho(false) end
    end
    if self.minBtn     then
        self.minBtn:setStyleSheet(theme.btnCss or "")
        if self._minBtnEcho then self._minBtnEcho(false) end
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

-- On titlebar release while floating: if the cursor is inside a visible PaneSpace,
-- return the pane to its original split slot (if remembered) or embed at PaneSpace
-- root level (if the pane has never been in a split here).
function MuxPane:_tryEmbedAt(gx, gy)
    for _, ps in pairs(Mux._paneSpaces) do
        if ps.visible then
            local px = ps.outer:get_x()
            local py = ps.outer:get_y()
            local pw = ps.outer:get_width()
            local ph = ps.outer:get_height()
            if gx >= px and gx <= px + pw and gy >= py and gy <= py + ph then
                -- Don't re-embed into the same PaneSpace unless the original split was
                -- retired (both sides floated), in which case _slot is nil.
                if self._slot and self._paneSpace and ps == self._paneSpace then return end

                if self._slot then
                    self:embed()
                elseif not ps.root then
                    self._slot     = ps.outer
                    self._split    = nil
                    self._slotSide = nil
                    self._paneSpace  = ps
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
    if not self.resizable then return end
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
            pane:_checkOverflow()
            if Mux._relayoutContent then Mux._relayoutContent(pane) end
        end)

        lbl:setReleaseCallback(function(event)
            if event.button ~= "LeftButton" then return end
            drag.active = false
            lbl:setStyleSheet(css)
            Mux._scheduleAutoSave()
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

-- Sets the frame's border CSS without a full applyTheme() pass.
function MuxPane:_setFrameCss(css)
    if self.frame then self.frame:setStyleSheet(css) end
end

-- Resting frame CSS. transparentFrame panes pass clicks through to the native
-- console underneath. overlay panes (dialogs) carry the gold accent border;
-- regular panes are grey. This is the only frame style — there is no focus
-- highlight.
function MuxPane:_baseFrameCss()
    if self.transparentFrame or self.consoleBorders then
        return [[
            background-color: transparent;
            border: 2px solid rgba(255, 255, 255, 0.38);
            border-radius: 3px;
        ]]
    end
    local theme = Mux.activeTheme()
    if self.overlay then
        return (theme.paneOuterCss or "") .. "\n" .. (theme.floatingExtraCss or "")
    end
    return (theme.paneOuterCss or "")
end

function MuxPane:absX()   return self.outer:get_x()      end
function MuxPane:absY()   return self.outer:get_y()      end
function MuxPane:width()  return self.outer:get_width()  end
function MuxPane:height() return self.outer:get_height() end

Mux.registerContent("mux_pane_close_confirm", {
    internal = true,
    apply = function(target)
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        local p = Mux._pendingPaneClose
        Mux._pendingPaneClose = nil
        if not p then return end
        local cw = target.content:get_width()
        if cw < 50 then cw = (target.floatW or 340) - 4 end
        local body = Geyser.Label:new({
            name=target._gid.."_body", x=10, y=10, width=cw-20, height=36,
        }, target.content)
        body:setStyleSheet(Mux.dialogCss.body)
        body:rawEcho(string.format("Close pane <b>%s</b>?", p.paneName))
        local btnProceed = Geyser.Label:new({
            name=target._gid.."_proceed", x=20, y=54, width=135, height=34,
        }, target.content)
        btnProceed:setStyleSheet(Mux.dialogCss.buttonDanger)
        btnProceed:rawEcho("<center>Proceed</center>")
        Mux.wireDialogButton(btnProceed, Mux.dialogCss.buttonDanger, Mux.dialogCss.buttonDangerHover)
        btnProceed:setClickCallback(function() target:close(); p.onProceed() end)
        local btnCancel = Geyser.Label:new({
            name=target._gid.."_cancel", x=185, y=54, width=135, height=34,
        }, target.content)
        btnCancel:setStyleSheet(Mux.dialogCss.buttonPrimary)
        btnCancel:rawEcho("<center>Cancel</center>")
        Mux.wireDialogButton(btnCancel, Mux.dialogCss.buttonPrimary, Mux.dialogCss.buttonPrimaryHover)
        btnCancel:setClickCallback(function() target:close() end)
        target._autoFitHeight = 98
    end,
    remove = function(_) end,
})

Mux._log("mux_pane loaded")