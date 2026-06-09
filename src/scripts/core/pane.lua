-- Muxlet — MuxPane
--
-- A Pane is the fundamental UI container.  Structure (all children of outer):
--
--   outer  (Geyser.Container)  — logical pane boundary; NO native Mudlet window.
--                                 move()/reposition() cascades to all children.
--     frame  (Geyser.Label)    — VISUAL layer: border + background CSS.
--                                 First child → lowest z-order → rendered behind everything.
--                                 Fills outer 100%×100%.
--     header (Geyser.Container)— fixed-height strip at top (inset 2px from border).
--       titlebar (Geyser.Label)  — drag surface + title text, cursor=OpenHand.
--       minBtn   (Geyser.Label)  — minimize button, x="-42" (from right edge).
--       closeBtn (Geyser.Label)  — close button,    x="-20" (from right edge).
--       reveal   (Geyser.Label)  — thin strip shown when titlebar is hidden;
--                                   right-click to restore titlebar.
--     content(Geyser.Container)  — fills remainder; consumers attach content here.
--
-- Why Geyser.Container as outer (not Label):
--   Containers are purely logical (no native Mudlet window).  reposition() still
--   works by cascading through all children.  This lets the frame Label carry all
--   CSS without fighting the constraint system for border-visible positioning.
--
-- Inset convention (borderInset = 2):
--   header and content are offset 2px from outer's edges so the frame's 2px
--   CSS border is visible all around the pane.
--
-- Float / embed:
--   Float : outer:changeContainer(Geyser) → outer.move(px,py) → outer:reposition()
--           All children (including frame) cascade to their new absolute positions.
--   Embed : outer:changeContainer(slot) → outer.move("0%","0%") → outer:reposition()
--
-- Drag during float:
--   Titlebar MoveCallback calls outer:move(new_x, new_y) + outer:reposition()
--   (~14 Mudlet API calls per event; fast enough at interactive rates).
--
-- Negative-px constraints (Mudlet GeyserSetConstraints.lua):
--   width = "-4px" → parent_width - 4  (shows 2px border on each side)
--   height= "-26px"→ parent_height - 26 (shows 2px border top + 22px header + 2px bottom)
--   x = "-20"      → parent_width - 20  (closeBtn: 20px from right edge)
--   x = "-42"      → parent_width - 42  (minBtn: next to closeBtn)

MuxPane = Mux._class()
Mux.Pane = MuxPane

local borderInset = 2   -- px inset so 2px border CSS on frame is visible

function MuxPane:init(opts)
    opts = opts or {}
    local theme = Mux.activeTheme()

    self.id               = opts.id   or Mux._newId("pane")
    self._gid             = Mux._newInternalId()   -- Geyser widget name prefix; never recycled
    self.name             = opts.name or self.id
    self.floating         = false
    self.minimized        = false
    self.locked           = false
    -- permanentFloat: pane is always floating and never interacts with any PaneSet.
    -- Drag-to-embed, double-click-to-embed, and Alt+A all become no-ops.
    -- Used for system overlays (settings window, etc.) that must never replace layout content.
    self.permanentFloat   = opts.permanentFloat or opts.permanent_float or false
    -- noResize: corner resize handles are never built; pane size is fixed after creation.
    self.noResize         = opts.noResize or opts.no_resize or false
    -- noTitlebarToggle: titlebar is permanently visible; hide/toggle is blocked.
    self.noTitlebarToggle = opts.noTitlebarToggle or opts.no_titlebar_toggle or false
    -- noRename: the pane name cannot be changed via the UI or prompt.
    self.noRename         = opts.noRename or opts.no_rename or false
    -- noContent: the "Add Content" submenu is suppressed in the context menu.
    self.noContent        = opts.noContent or opts.no_content or opts.noPresets or opts.no_presets or false
    -- noTabs: "Enable Tabs" is suppressed in the context menu; enableTabs() is a no-op.
    -- Set automatically for permanentFloat panes; can also be set explicitly.
    self.noTabs           = opts.noTabs or opts.no_tabs or false
    if opts.show_titlebar ~= nil then
        self.titlebarVisible = opts.show_titlebar
    else
        -- Respect the persisted default; fall back to true if setting unavailable.
        local def = Mux.settings and Mux.settings.get("mux", "default_titlebar")
        self.titlebarVisible = (def ~= false)
    end

    -- Saved pixel geometry for when the pane is floating
    self.floatX = opts.floatX or opts.float_x or 100
    self.floatY = opts.floatY or opts.float_y or 100
    self.floatW = opts.floatW or opts.float_w or 400
    self.floatH = opts.floatH or opts.float_h or 300

    -- Back-reference to the MuxSplit slot that owns this pane
    self._slot     = nil   -- Geyser.Container (the slot inside the split)
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

    -- ── Outer container ───────────────────────────────────────────────────────
    -- Plain Container: no native Mudlet window, but move()/resize()/reposition()
    -- cascade correctly to all children.
    self.outer = Geyser.Container:new({
        name   = self._gid .. "_outer",
        x      = opts.x      or "0%",
        y      = opts.y      or "0%",
        width  = opts.width  or "100%",
        height = opts.height or "100%",
    }, parent)

    -- ── Frame (visual background + border) ───────────────────────────────────
    -- Added FIRST so it has the lowest z-order (rendered behind header/content).
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
    -- Clicking the frame border area focuses this pane (no visual change).
    self.frame:setClickCallback(function(event)
        if Mux._movingTab then Mux._cancelTabMove(); return end
        if not self.locked and Mux.setFocus then Mux.setFocus(self) end
    end)

    -- ── Header strip ─────────────────────────────────────────────────────────
    -- Inset borderInset from all edges.  Height is fixed.
    local hdrH = self.titlebarVisible and tbH or rvH
    self.header = Geyser.Container:new({
        name   = self._gid .. "_header",
        x      = tostring(borderInset) .. "px",
        y      = tostring(borderInset) .. "px",
        width  = Mux._pxNeg(borderInset * 2),
        height = Mux._px(hdrH),
    }, self.outer)

    -- ── Content area ──────────────────────────────────────────────────────────
    -- Fills from below header to borderInset from the bottom.
    local contentY = borderInset + hdrH
    self.content = Geyser.Container:new({
        name   = self._gid .. "_content",
        x      = tostring(borderInset) .. "px",
        y      = Mux._px(contentY),
        width  = Mux._pxNeg(borderInset * 2),
        height = Mux._pxNeg(contentY + borderInset),
    }, self.outer)
    -- Geyser.Container has no setStyleSheet (no native Qt widget).
    -- Use a background Label as the first child (lowest z-order) instead.
    -- Same pattern as self.frame for the outer border.
    self.contentBg = Geyser.Label:new({
        name   = self._gid .. "_content_bg",
        x      = "0%", y = "0%",
        width  = "100%", height = "100%",
        fillBg = 1,
    }, self.content)
    self.contentBg:setStyleSheet(theme.contentCss or "")
    -- Clicking the empty content area focuses this pane (no visual change).
    self.contentBg:setClickCallback(function(event)
        if Mux._movingTab then Mux._cancelTabMove(); return end
        if not self.locked and Mux.setFocus then Mux.setFocus(self) end
    end)

    -- ── Main console host mode ────────────────────────────────────────────────
    -- When mainConsoleHost=true, the Mudlet main console is displayed inside
    -- this pane via setBorderSizes rather than a Geyser MiniConsole.
    -- The frame is made transparent so the console shows through; borders are
    -- set to place the console in the content area after the pane is positioned.
    self.mainConsoleHost = opts.mainConsoleHost or opts.main_console_host or false
    if self.mainConsoleHost then
        -- Transparent frame: CSS border still draws the pane outline.
        self.frame:setStyleSheet([[
            background-color: transparent;
            border: 2px solid rgba(255, 255, 255, 0.38);
            border-radius: 3px;
        ]])
        -- Frame must be fully transparent to mouse events so scroll wheel and
        -- clicks reach the native game console underneath instead of being eaten
        -- by the Label widget.
        enableClickthrough(self.frame.name)
        -- Content background hidden — main console shows through.
        self.contentBg:hide()
    end

    -- ── Build titlebar widgets ────────────────────────────────────────────────
    self:_buildTitlebar(theme)

    -- ── Corner resize handles (shown only when floating) ──────────────────────
    self:_buildCornerHandles(theme)

    -- ── Placeholder (shown until real content is attached) ────────────────────
    self:_updatePlaceholder()

    Mux._panes[self.id] = self
    Mux._log("MuxPane created: %s", self.id)
end

-- ── Titlebar construction ─────────────────────────────────────────────────────

function MuxPane:_buildTitlebar(theme)
    local btnH = theme.btnSize
    local btnY = theme.btnTopMargin

    -- Drag surface: fills header, renders title text.
    -- Added BEFORE buttons so buttons (added after) have higher z-order and
    -- receive clicks on their area before this label does.
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
    self.titlebar:echo(string.format("<span style='color:%s;'>  %s</span>", tbc, self.name))
    self.titlebar:setCursor("OpenHand")

    -- Per-pane drag state (local; no global state → panes never interfere).
    -- lastHoverGhostKey: slotKey of the ghost slot currently highlighted, or nil.
    -- insertTarget: { pane, edge } of the insertion zone currently previewed, or nil.
    local drag = {
        active            = false,
        startX            = 0, startY = 0,
        paneX             = 0, paneY  = 0,
        lastHoverGhostKey = nil,
        insertTarget      = nil,
    }

    self.titlebar:setClickCallback(function(event)
        if event.button == "RightButton" then
            -- Right-click: show context menu.
            Mux._showContextMenu(self, event.globalX or 0, event.globalY or 0)
            return
        end
        if event.button ~= "LeftButton" then return end
        if not self.locked and Mux.setFocus then Mux.setFocus(self) end
        if self.locked then return end
        if self.mainConsoleHost then return end   -- Main pane cannot be dragged
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

        -- ── Ghost slot hover detection ────────────────────────────────────────
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

        -- ── Insertion zone detection (only when not over a ghost slot) ────────
        if not newHoverGhost then
            local insertPane, insertEdge = nil, nil
            for _, tp in pairs(Mux._panes) do
                if not tp.floating and not tp.mainConsoleHost and tp ~= self then
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

        -- Clean up drag visuals regardless of outcome.
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
                -- Update this pane's slot references to the ghost's slot.
                self._slot     = ghost.slot
                self._split    = ghost.split
                self._slotSide = ghost.side
                self._paneSet  = ghost.paneSet
                -- Update the split's child pointer.
                if ghost.split then
                    if ghost.side == "a" then ghost.split.childA = self
                    else                     ghost.split.childB = self
                    end
                end
                -- embed() (no arg) will use self._slot, show the split box,
                -- and remove any remaining ghost slot in the target.
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

    -- Double-click embeds a floating pane. For embedded panes it just sets focus.
    -- Home slot (self._slot) is tried first; if that ghost was already dismissed,
    -- falls back to the nearest available ghost by screen distance.
    self.titlebar:setDoubleClickCallback(function(event)
        if self.mainConsoleHost then return end
        if self.permanentFloat   then return end
        if not self.floating then
            if Mux.setFocus then Mux.setFocus(self) end
            return
        end

        -- Find target ghost: home first, then nearest.
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

        if not target then return end  -- no ghost slots available

        -- Update this pane's slot bookkeeping to the target ghost's location.
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

    -- ── Close button (rightmost) ──────────────────────────────────────────────
    -- x = "-20" → 20px from the RIGHT edge of header (negative px constraint).
    self.closeBtn = Geyser.Label:new({
        name    = self._gid .. "_close",
        x       = "-20",
        y       = tostring(btnY),
        width   = tostring(theme.btnSize),
        height  = tostring(btnH),
        fillBg  = 1,
    }, self.header)
    -- Qt ignores a QLabel stylesheet's color: when the label contains rich text
    -- (anything with HTML tags).  Echo explicit <font color> to force the right colour.
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

    -- ── Minimize button (second from right) ───────────────────────────────────
    -- x = "-42": btnSize(18) + gap(2) + close_right_offset(20) + margin(2) = 42.
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

    -- ── Reveal strip ──────────────────────────────────────────────────────────
    -- Shown when titlebar is hidden.  Right-click restores titlebar.
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
    -- Mouse clicks on the reveal strip intentionally do nothing; use Alt+[ or
    -- mux titlebar to restore the titlebar so it cannot be accidentally re-shown.
    self.reveal:setClickCallback(function() end)

    -- Apply initial visibility
    self:_applyTitlebarVisibility()
end

-- ── Titlebar visibility ───────────────────────────────────────────────────────

function MuxPane:setTitlebarVisible(visible)
    if not visible and self.noTitlebarToggle then return end  -- titlebar is locked visible
    self.titlebarVisible = visible
    self:_applyTitlebarVisibility()
end

function MuxPane:_applyTitlebarVisibility()
    local theme = Mux.activeTheme()
    local bi    = borderInset
    if self.titlebarVisible then
        local h = theme.titlebarHeight
        self.header:resize(nil, Mux._px(h))
        self.content:move(nil, Mux._px(bi + h))
        self.content:resize(nil, Mux._pxNeg(bi + h + bi))
        self.header:reposition()
        self.content:reposition()
        if self._syncConnScreenGeometry then self:_syncConnScreenGeometry() end
        self.titlebar:show()
        -- Main pane has no close or minimize.
        if not self.mainConsoleHost then
            self.closeBtn:show()
            -- Minimize only makes sense when floating.
            if self.floating then self.minBtn:show() else self.minBtn:hide() end
        else
            self.closeBtn:hide()
            self.minBtn:hide()
        end
        self.reveal:hide()
    else
        local h = theme.revealStripHeight
        self.header:resize(nil, Mux._px(h))
        self.content:move(nil, Mux._px(bi + h))
        self.content:resize(nil, Mux._pxNeg(bi + h + bi))
        self.header:reposition()
        self.content:reposition()
        if self._syncConnScreenGeometry then self:_syncConnScreenGeometry() end
        self.titlebar:hide()
        self.closeBtn:hide()
        self.minBtn:hide()
        self.reveal:show()
    end
end

-- ── Minimize / restore ────────────────────────────────────────────────────────
-- Floating panes collapse to titlebar-height-only strip.
-- Embedded panes collapse their split slot to a thin titlebar strip by
-- adjusting the parent split's ratio, then restore on unminimize.

function MuxPane:toggleMinimize()
    local theme = Mux.activeTheme()
    if self.minimized then
        self.minimized = false
        -- Restore content visibility before resizing so it repaints correctly.
        if self.content then self.content:show() end
        -- Re-hide content and re-show conn screen if we are still disconnected.
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

-- ── Title text ────────────────────────────────────────────────────────────────

function MuxPane:setName(text)
    self.name = text
    if self.titlebar then
        local tbc = Mux.activeTheme().titlebarTextColor or Mux.activeTheme().btnTextColor or "#aaaabb"
        self.titlebar:echo(string.format("<span style='color:%s;'>  %s</span>", tbc, text))
    end
    self:_updatePlaceholder()
end

-- ── Placeholder content ───────────────────────────────────────────────────────
-- Shown on contentBg (lowest z-order in content area) so any real widget
-- placed as a sibling naturally covers it.

function MuxPane:_updatePlaceholder()
    if not self.contentBg then return end
    if self._activeContent  then return end  -- content system owns contentBg; leave it hidden
    if self.mainConsoleHost then return end  -- main console shows through contentBg; never placeholder
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
        .. "right-click titlebar -> Add Content"
        .. "</span>"
        .. "</div>",
        ds, self.name, is, self.id, cs, self.id)
    self.contentBg:echo(html)
end

-- ── Float ─────────────────────────────────────────────────────────────────────

function MuxPane:float()
    if self.floating then return end
    if self.mainConsoleHost then
        Mux._warn("The '%s' pane is the main console — it cannot be floated.", self.name)
        return
    end
    self.floatX = self.outer:get_x()
    self.floatY = self.outer:get_y()
    self.floatW = self.outer:get_width()
    self.floatH = self.outer:get_height()
    self:_detachToFloat()
end

function MuxPane:_detachToFloat()
    if self.floating then return end
    if self.mainConsoleHost then return end
    self.floating = true
    self.outer:changeContainer(Geyser)
    self.outer:move(self.floatX, self.floatY)
    self.outer:resize(self.floatW, self.floatH)
    self.outer:reposition()
    self:raise()
    self.frame:setStyleSheet(self:_baseFrameCss())
    self:_showCornerHandles()
    -- Show min button now that pane is floating (was hidden while embedded).
    if self.titlebarVisible and not self.mainConsoleHost then
        self.minBtn:show()
    end
    -- Always leave the split visible and create a ghost slot in the vacated space.
    -- The split box is never hidden on float — every slot is always either a real
    -- pane or a ghost.  Ghosts persist until explicitly dismissed (×) or until the
    -- associated pane is closed; they never vanish just because other panes float.
    if self._split then
        Mux._createGhostSlot(self._slot, self._split, self._slotSide, self._paneSet)
        -- Ghost label is created after raise(), so it lands z-above this pane.
        -- Re-raise to ensure the float stays on top of its own ghost.
        self:raise()
    end
    if not self.permanentFloat then Mux._lastFocusedPane = self end
    if self.onFloat then self.onFloat(self) end
    Mux._log("MuxPane floated: %s (%.0f,%.0f %.0fx%.0f)",
        self.id, self.floatX, self.floatY, self.floatW, self.floatH)
end

-- ── Embed ─────────────────────────────────────────────────────────────────────

function MuxPane:embed(slot)
    if self.permanentFloat then return end   -- permanent floats can never be embedded
    if not self.floating then return end
    local target = slot or self._slot
    if not target then
        Mux._warn("embed: pane '%s' has no slot to return to", self.id)
        return
    end
    -- Remove any ghost occupying the target slot (our own or a foreign one).
    Mux._removeGhostSlotBySlot(target)
    -- If returning to the original split slot, restore the split box first so
    -- the VBox/HBox layout (and its resize handle) becomes visible again.
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
    -- Hide min button when embedded (only meaningful when floating).
    self.minBtn:hide()
    if self.onEmbed then self.onEmbed(self) end
    Mux._log("MuxPane embedded: %s", self.id)
    Mux.raiseFloatingPanes()
end

-- ── Raise / lower ─────────────────────────────────────────────────────────────

function MuxPane:raise()
    -- raiseAll on a Container iterates windowList and raises each native child.
    -- Since Container is purely logical, the children (frame, header, content) are raised.
    if self.outer and self.outer.raiseAll then self.outer:raiseAll() end
end

function MuxPane:lower()
    if self.outer and self.outer.lowerAll then self.outer:lowerAll() end
end

-- ── Main console border positioning ──────────────────────────────────────────
-- When mainConsoleHost=true, call this after the pane is shown to position
-- the Mudlet main console inside the pane's content area via setBorderSizes.
-- Also call on window resize and whenever the pane geometry changes.

function MuxPane:updateConsoleBorders()
    if not self.mainConsoleHost then return end
    local theme = Mux.activeTheme()
    local bi = 2   -- borderInset (must match constant in MuxPane:init)
    local tb = self.titlebarVisible and theme.titlebarHeight or theme.revealStripHeight
    local sw, sh = getMainWindowSize()
    -- Use get_x/y/width/height which return absolute pixel positions after reposition.
    local px = self.outer:get_x()
    local py = self.outer:get_y()
    local pw = self.outer:get_width()
    local ph = self.outer:get_height()
    -- setBorderSizes(top, right, bottom, left)
    -- Top border = pane top edge + frame inset + titlebar height
    -- Other borders = distance from pane edge to screen edge + frame inset
    local top    = py + bi + tb
    local left   = px + bi
    local right  = sw - (px + pw) + bi
    local bottom = sh - (py + ph) + bi
    setBorderSizes(math.max(0, top), math.max(0, right), math.max(0, bottom), math.max(0, left))
    Mux._log("updateConsoleBorders: t=%d r=%d b=%d l=%d", top, right, bottom, left)
end

-- ── Show / hide ───────────────────────────────────────────────────────────────

function MuxPane:show()
    -- Container.show() cascades to all children.
    self.outer:show()
end

function MuxPane:hide()
    self.outer:hide()
end

-- ── Lock / unlock ─────────────────────────────────────────────────────────────

function MuxPane:lock()
    self.locked = true
    if self.titlebar   then self.titlebar:setCursor("Arrow") end
    -- _setAddTabBtnVisible is defined in tabs.lua (loaded after pane.lua).
    if self._addTabBtn then self:_setAddTabBtnVisible(false) end
    self:_setFrameCss(self:_baseFrameCss())
    Mux._log("MuxPane locked: %s", self.id)
end

function MuxPane:unlock()
    self.locked = false
    if self.titlebar   then self.titlebar:setCursor("OpenHand") end
    -- Only show the button if tabs are enabled (disabled-tab panes keep button hidden).
    if self._addTabBtn and self._tabsEnabled then self:_setAddTabBtnVisible(true) end
    if Mux._focusedPane == self then
        self:_setFrameCss(self:_focusedFrameCss())
    end
    Mux._log("MuxPane unlocked: %s", self.id)
end

-- ── Close ─────────────────────────────────────────────────────────────────────

function MuxPane:close()
    if self.locked then
        Mux._warn("MuxPane '%s' is locked — unlock before closing", self.name)
        return
    end
    Mux._closeContextMenu()
    if self.onClose then self.onClose(self) end

    if self.floating then
        -- Find and clean up the ghost this pane left behind, then collapse the
        -- slot so the layout fills the dead space.  Ghost lookup by slot (not by
        -- a pane→ghost key) so promotion scenarios are handled transparently.
        if self._slot then
            local ghost, gKey = Mux._findGhostBySlot(self._slot)
            if ghost then
                local gSplit = ghost.split
                local gSide  = ghost.side
                Mux._removeGhostSlot(gKey)
                if gSplit then gSplit:collapseSlot(gSide) end
            end
        end
        -- Outer is in the Geyser root when floating; nothing to remove from a slot.
        self.outer:hide()
    else
        -- Embedded: remove from slot, then collapse the parent split.
        if self._slot then self._slot:remove(self.outer) end
        self.outer:hide()
        if self._split then self._split:collapseSlot(self._slotSide) end
    end

    -- Clear stale focus reference and auto-focus the remaining pane.
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
    Mux._freeId(self.id)
    Mux._log("MuxPane closed: %s", self.id)
end

-- ── Theme refresh ─────────────────────────────────────────────────────────────

function MuxPane:applyTheme()
    local theme = Mux.activeTheme()
    -- Preserve focus highlight state after a theme change.
    if Mux._focusedPane == self and not self.locked then
        self.frame:setStyleSheet(self:_focusedFrameCss())
    else
        self.frame:setStyleSheet(self:_baseFrameCss())
    end
    if self.contentBg  then self.contentBg:setStyleSheet(theme.contentCss or "")       end
    if self.titlebar   then
        self.titlebar:setStyleSheet(theme.titlebarCss or "")
        local tbc = theme.titlebarTextColor or theme.btnTextColor or "#aaaabb"
        self.titlebar:echo(string.format("<span style='color:%s;'>  %s</span>", tbc, self.name))
    end
    local tc = theme.btnTextColor or "#aaaabb"
    if self.closeBtn   then
        self.closeBtn:setStyleSheet(theme.btnCss or "")
        self.closeBtn:echo(string.format("<center><font color='%s'>✕</font></center>", tc))
    end
    if self.minBtn     then
        self.minBtn:setStyleSheet(theme.btnCss or "")
        self.minBtn:echo(string.format("<center><font color='%s'>–</font></center>", tc))
    end
    if self.reveal     then self.reveal:setStyleSheet(theme.revealStripCss or "")       end
    if self._cornerHandles then
        local css = theme.cornerHandleCss or ""
        for _, lbl in ipairs(self._cornerHandles) do lbl:setStyleSheet(css) end
    end
    -- Refresh tab bar if tabs are enabled (delegated to tabs.lua).
    if self._applyTabTheme then self:_applyTabTheme() end
    self:_applyTitlebarVisibility()
    -- Refresh connection screen colours if one exists (delegated to connection.lua).
    if self._refreshConnScreen then self:_refreshConnScreen() end
end

-- ── Drop-to-embed ─────────────────────────────────────────────────────────────
-- Called on titlebar mouse-release while floating.  If the cursor is inside any
-- visible PaneSet's outer area:
--   • If the pane has a remembered slot (it was floated from that PaneSet),
--     return it to the exact original slot so the split and resize handle remain.
--   • Otherwise embed at PaneSet level as the new root (pane has never been in
--     a split here).

function MuxPane:_tryEmbedAt(gx, gy)
    for _, ps in pairs(Mux._paneSets) do
        if ps.visible then
            local px = ps.outer:get_x()
            local py = ps.outer:get_y()
            local pw = ps.outer:get_width()
            local ph = ps.outer:get_height()
            if gx >= px and gx <= px + pw and gy >= py and gy <= py + ph then
                -- Don't re-embed into the PaneSet the pane was just floated from,
                -- UNLESS the pane's original split was retired (both sides floated).
                -- In that case _slot is nil and the pane needs a new home in any zone.
                if self._slot and self._paneSet and ps == self._paneSet then return end

                if self._slot then
                    -- Return to original split slot — restores geometry and resize handle.
                    self:embed()
                else
                    -- No previous slot; embed fresh as PaneSet root.
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

-- ── Resize handles (floating panes) ──────────────────────────────────────────
-- Eight labels: four corner squares + four edge strips.  Only shown while
-- floating.  Each handle records drag start + pane geometry, then adjusts
-- x/y/w/h on move.  dx/dy controls which axes are affected:
--   dx = -1 → moves left edge   dx = 1 → moves right edge   dx = 0 → no x change
--   dy = -1 → moves top edge    dy = 1 → moves bottom edge  dy = 0 → no y change

function MuxPane:_buildCornerHandles(theme)
    if self.noResize then return end   -- fixed-size panes have no resize handles
    local ch       = (theme.cornerHandleSize or 10)
    local css      = theme.cornerHandleCss      or ""
    local hoverCss = theme.cornerHandleHoverCss or css

    -- Mudlet cursor names (its own table, not Qt enum names):
    --   "ResizeTopLeft"  = \ diagonal (NW/SE corners)
    --   "ResizeTopRight" = / diagonal (NE/SW corners)
    --   5                = SizeVer    (top/bottom edges)
    --   6                = SizeHor    (left/right edges)
    local handles = {
        -- Corners (ch×ch squares at outer corners)
        { id="nw", x="0px",           y="0px",           w=ch, h=ch,
          cur="ResizeTopLeft",  dx=-1, dy=-1 },
        { id="ne", x=Mux._pxNeg(ch),  y="0px",           w=ch, h=ch,
          cur="ResizeTopRight", dx= 1, dy=-1 },
        { id="sw", x="0px",           y=Mux._pxNeg(ch),  w=ch, h=ch,
          cur="ResizeTopRight", dx=-1, dy= 1 },
        { id="se", x=Mux._pxNeg(ch),  y=Mux._pxNeg(ch),  w=ch, h=ch,
          cur="ResizeTopLeft",  dx= 1, dy= 1 },
        -- Edges (strips between corners, resize one axis only)
        { id="n",  x=Mux._px(ch),     y="0px",           w=Mux._pxNeg(ch*2), h=ch,
          cur=5,    dx= 0, dy=-1 },
        { id="s",  x=Mux._px(ch),     y=Mux._pxNeg(ch),  w=Mux._pxNeg(ch*2), h=ch,
          cur=5,    dx= 0, dy= 1 },
        { id="w",  x="0px",           y=Mux._px(ch),     w=ch, h=Mux._pxNeg(ch*2),
          cur=6,    dx=-1, dy= 0 },
        { id="e",  x=Mux._pxNeg(ch),  y=Mux._px(ch),     w=ch, h=Mux._pxNeg(ch*2),
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

        -- Per-handle drag state (local closure, no shared state).
        local drag = { active=false, startX=0, startY=0, paneX=0, paneY=0, paneW=0, paneH=0 }
        local pane = self
        local dx, dy = c.dx, c.dy

        -- Edge handles (n/s/w/e) stay invisible on hover — the cursor change is
        -- sufficient; showing a thick coloured bar along the side intrudes on content.
        -- Corner handles (nw/ne/sw/se) keep their hover highlight for discoverability.
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
                -- Left edge moves: x changes, width shrinks
                local clampedDx = math.min(deltaX, drag.paneW - minW)
                newX = drag.paneX + clampedDx
                newW = drag.paneW - clampedDx
            else
                -- Right edge moves: width grows
                newW = math.max(minW, drag.paneW + deltaX)
            end

            if dy < 0 then
                -- Top edge moves: y changes, height shrinks
                local clampedDy = math.min(deltaY, drag.paneH - minH)
                newY = drag.paneY + clampedDy
                newH = drag.paneH - clampedDy
            else
                -- Bottom edge moves: height grows
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
            lbl:setStyleSheet(css)   -- always transparent after release
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

-- ── Geometry helpers ──────────────────────────────────────────────────────────

-- Called by Mux.setFocus / Mux.clearFocus to change the frame's border CSS
-- without a full applyTheme() refresh.
function MuxPane:_setFrameCss(css)
    if self.frame then self.frame:setStyleSheet(css) end
end

-- Returns the "resting" (unfocused) frame CSS for this pane.
-- mainConsoleHost uses a transparent background so the game console shows through.
function MuxPane:_baseFrameCss()
    if self.mainConsoleHost then
        return [[
            background-color: transparent;
            border: 2px solid rgba(255, 255, 255, 0.38);
            border-radius: 3px;
        ]]
    end
    local theme = Mux.activeTheme()
    -- Permanent floats always carry the accent border so they're visually distinct
    -- from layout panes and clearly identifiable as system-level overlays.
    if self.permanentFloat then
        return (theme.paneOuterCss or "") .. "\n" .. (theme.floatingExtraCss or "")
    end
    return (theme.paneOuterCss or "")
end

-- Returns the focused-highlight frame CSS for this pane.
-- mainConsoleHost keeps the transparent background, changes only the border colour.
function MuxPane:_focusedFrameCss()
    -- Permanent floats never take the blue focus border — always stay gold.
    if self.permanentFloat then return self:_baseFrameCss() end
    -- With only one non-floating pane focus is implicit — no border needed.
    local paneCount = 0
    for _, p in pairs(Mux._panes) do
        if not p.floating then
            paneCount = paneCount + 1
            if paneCount > 1 then break end
        end
    end
    if paneCount <= 1 then return self:_baseFrameCss() end
    if self.mainConsoleHost then
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
