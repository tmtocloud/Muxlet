-- Muxlet — MuxSplit
--
-- A Split is an internal BSP-tree node that divides its container into two
-- slots separated by a draggable resize handle.
--
-- Direction:
--   "v"  vertical split   → slots stacked top / bottom   (Geyser.VBox)
--   "h"  horizontal split → slots side by side left/right (Geyser.HBox)
--
-- Layout is delegated entirely to Geyser's VBox/HBox engine:
--   slotA  : Geyser.Container  h/v_policy=Dynamic  stretch_factor = ratio
--   handle : Geyser.Label      h/v_policy=Fixed    fixed px thick
--   slotB  : Geyser.Container  h/v_policy=Dynamic  stretch_factor = 1-ratio
--
-- VBox/HBox calculate_dynamic_window_size() (GeyserContainer.lua):
--   dynamic_count = Σ(stretch_factor) for all Dynamic children
--   per_unit      = (total_size - Σfixed_sizes) / dynamic_count
--   child_size    = per_unit * child_stretch_factor
--
-- With slotA.sf = r and slotB.sf = (1-r):
--   dynamic_count = r + (1-r) = 1
--   slotA gets (dynamic_space * r)     pixels
--   slotB gets (dynamic_space * (1-r)) pixels
--
-- Drag resize:
--   At mouse-down: record dragStart (globalX/Y) and slotA pixel size.
--   On each move:  delta = globalPos - dragStart
--                  new_ratio = (slotAStart + delta) / dynamic_space
--                  clamp to [minRatio, 1-minRatio]
--                  update stretch factors → box:organize()

MuxSplit = Mux._class()
Mux.Split = MuxSplit

local minRatio = 0.05   -- neither slot may shrink below 5 % of dynamic space

function MuxSplit:init(opts)
    opts = opts or {}
    local theme = Mux.activeTheme()

    self.id        = opts.id or Mux._newId("split")
    self.direction = opts.direction or "v"   -- "v" = top/bottom, "h" = left/right
    self.ratio     = Mux._clamp(opts.ratio or 0.5, minRatio, 1 - minRatio)

    -- Children: each is a MuxPane or another MuxSplit, or nil (empty slot)
    self.childA = nil
    self.childB = nil

    local parent   = opts.parent or Geyser
    local handlePx = theme.handleSize

    local BoxClass = (self.direction == "v") and Geyser.VBox or Geyser.HBox
    self.box = BoxClass:new({
        name   = self.id .. "_box",
        x      = opts.x      or "0%",
        y      = opts.y      or "0%",
        width  = opts.width  or "100%",
        height = opts.height or "100%",
    }, parent)

    self.slotA = Geyser.Container:new({
        name             = self.id .. "_slot_a",
        h_policy         = Geyser.Dynamic,
        v_policy         = Geyser.Dynamic,
        h_stretch_factor = (self.direction == "h") and self.ratio or 1.0,
        v_stretch_factor = (self.direction == "v") and self.ratio or 1.0,
    }, self.box)

    -- For "v" split: Fixed height, Dynamic width (full-width horizontal bar).
    -- For "h" split: Fixed width, Dynamic height (full-height vertical bar).
    local handleCons
    if self.direction == "v" then
        handleCons = {
            name     = self.id .. "_handle",
            h_policy = Geyser.Dynamic,
            v_policy = Geyser.Fixed,
            height   = handlePx,
        }
    else
        handleCons = {
            name     = self.id .. "_handle",
            h_policy = Geyser.Fixed,
            v_policy = Geyser.Dynamic,
            width    = handlePx,
        }
    end
    self.handle = Geyser.Label:new(handleCons, self.box)
    self.handle:setStyleSheet(theme.handleCss or "")
    local cursor = (self.direction == "v")
        and (theme.handleCursorV or "ResizeVertical")
        or  (theme.handleCursorH or "ResizeHorizontal")
    self.handle:setCursor(cursor)

    self.slotB = Geyser.Container:new({
        name             = self.id .. "_slot_b",
        h_policy         = Geyser.Dynamic,
        v_policy         = Geyser.Dynamic,
        h_stretch_factor = (self.direction == "h") and (1 - self.ratio) or 1.0,
        v_stretch_factor = (self.direction == "v") and (1 - self.ratio) or 1.0,
    }, self.box)

    self:_setupHandleDrag(theme, handlePx)

    Mux._splits[self.id] = self
    Mux._log("MuxSplit created: %s dir=%s ratio=%.2f", self.id, self.direction, self.ratio)
end

-- Lazily-created overlay line shown during a preview drag. It's a plain Geyser
-- label parented to the root, reused across all splits; the real split handle is
-- never moved, so it keeps its cursor and clickability after a preview drag.
local function _ensureDragGuide()
    if Mux._dragGuide then return Mux._dragGuide end
    local theme = Mux.activeTheme()
    local g = Geyser.Label:new({ name = "mux_drag_guide", x = 0, y = 0, width = 4, height = 4 }, Geyser)
    g:setStyleSheet(theme.dragGuideCss
        or "background-color: rgba(120,170,255,0.55); border-radius: 2px;")
    if g.setClickThrough then pcall(function() g:setClickThrough(true) end) end
    g:hide()
    Mux._dragGuide = g
    return g
end

function MuxSplit:_setupHandleDrag(theme, handlePx)
    -- Drag state: local per-split so multiple splits can be dragged concurrently.
    local drag = {
        active    = false,
        startPos  = 0,     -- globalX or globalY at mouse-down
        slotAPx   = 0,     -- slotA pixel size at mouse-down
        dynamicPx = 0,     -- total dynamic space at mouse-down
    }

    self.handle:setOnEnter(function()
        if self._dragDisabled then return end
        self.handle:setStyleSheet(theme.handleHoverCss or theme.handleCss)
    end)
    self.handle:setOnLeave(function()
        if not drag.active then
            self.handle:setStyleSheet(theme.handleCss or "")
        end
    end)

    self.handle:setClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        if self._dragDisabled then return end
        drag.active = true
        -- Decide live vs preview: live resize stays smooth for a few panes, but
        -- each added content pane makes a single reposition heavier than a frame
        -- budget. Above the threshold, drag a cheap preview line and apply once
        -- on release so cost is independent of pane count.
        local maxLive = (Mux.settings and Mux.settings.get("mux", "live_resize_max_panes")) or 2
        drag.preview  = self:_leafCount() > maxLive
        -- Measure slotA and dynamic space NOW (after any prior organize call).
        if self.direction == "v" then
            drag.startPos  = event.globalY
            drag.slotAPx   = self.slotA:get_height()
            drag.dynamicPx = self.box:get_height() - handlePx
        else
            drag.startPos  = event.globalX
            drag.slotAPx   = self.slotA:get_width()
            drag.dynamicPx = self.box:get_width() - handlePx
        end
        if drag.preview then
            -- Overlay the guide on the handle's current spot, then let it track
            -- the cursor. The real handle stays put and fully interactive.
            local g = _ensureDragGuide()
            drag.guideX0 = self.handle:get_x()
            drag.guideY0 = self.handle:get_y()
            g:resize(self.handle:get_width(), self.handle:get_height())
            g:move(drag.guideX0, drag.guideY0)
            g:show()
            g:raise()
        end
    end)

    self.handle:setMoveCallback(function(event)
        if not drag.active then return end
        local pos    = (self.direction == "v") and event.globalY or event.globalX
        local delta  = pos - drag.startPos
        -- Guard against zero dynamic space (layout not yet rendered).
        if drag.dynamicPx <= 0 then return end
        local newSlotA = Mux._clamp(drag.slotAPx + delta,
            minRatio * drag.dynamicPx, (1 - minRatio) * drag.dynamicPx)
        if drag.preview then
            -- Move only the lightweight guide overlay — one cheap native op per
            -- frame, so it tracks the cursor live regardless of pane count.
            local shift = newSlotA - drag.slotAPx
            local g = Mux._dragGuide
            if g then
                if self.direction == "v" then g:move(drag.guideX0, drag.guideY0 + shift)
                else                          g:move(drag.guideX0 + shift, drag.guideY0) end
            end
        else
            -- Coalesced live resize: records the target and lets a single
            -- scheduled flush apply it, so fast events don't pile up repositions.
            self:_requestRatio(newSlotA / drag.dynamicPx)
        end
    end)

    self.handle:setReleaseCallback(function(event)
        if event.button ~= "LeftButton" then return end
        drag.active = false
        self.handle:setStyleSheet(theme.handleCss or "")
        if drag.preview then
            if Mux._dragGuide then Mux._dragGuide:hide() end
            -- Apply the previewed position once. Gate per-pane overflow checks
            -- during this single heavy reposition, then recheck once via flush.
            local pos   = (self.direction == "v") and event.globalY or event.globalX
            local delta = pos - drag.startPos
            if drag.dynamicPx > 0 then
                local ratio = Mux._clamp((drag.slotAPx + delta) / drag.dynamicPx, minRatio, 1 - minRatio)
                Mux._resizing = true
                self:_setRatio(ratio)
                self:_flushRatio()
            end
            drag.preview = false
        else
            self:_flushRatio()
        end
        Mux._scheduleAutoSave()
    end)
end

-- Returns true if the child (MuxPane or nested MuxSplit) allows the handle to be dragged.
-- Recurses into nested splits: if any pane in the sub-tree is non-resizable, the
-- entire sub-tree is treated as non-resizable so ancestor handles also lock.
function MuxSplit:_childResizable(child)
    if not child then return true end
    if child.outer then return child.resizable ~= false end          -- MuxPane
    if child.childA ~= nil then                                      -- nested MuxSplit
        return child:_childResizable(child.childA)
           and child:_childResizable(child.childB)
    end
    return true
end

-- Rechecks both children's resizable flags and either enables or disables the handle.
-- Called whenever a child is placed, embedded, or its resizable flag changes.
function MuxSplit:_updateHandleResizability()
    local theme    = Mux.activeTheme()
    local canDrag  = self:_childResizable(self.childA) and self:_childResizable(self.childB)
    self._dragDisabled = not canDrag
    if canDrag then
        local cursor = (self.direction == "v")
            and (theme.handleCursorV or "ResizeVertical")
            or  (theme.handleCursorH or "ResizeHorizontal")
        self.handle:setCursor(cursor)
    else
        self.handle:setCursor("Arrow")
    end
end

-- Counts MuxPane leaves in this split's subtree. Used to decide whether a live
-- drag would resize few enough panes to stay smooth, or enough to warrant the
-- cheaper preview-line drag.
function MuxSplit:_leafCount()
    local n = 0
    local function walk(node)
        if not node then return end
        if node.outer then n = n + 1 else walk(node.childA); walk(node.childB) end
    end
    walk(self.childA)
    walk(self.childB)
    return n
end

-- Fires onReposition for every MuxPane leaf in this split's subtree. Used after
-- a ratio change: only descendants of this split change geometry, so notifying
-- the whole workspace (as a structural change does) would be wasted work. During
-- a live handle drag this runs every mouse-move frame, so keeping it scoped is
-- what keeps embedded-resize cheap regardless of how many other panes exist.
function MuxSplit:_notifyReposition()
    local function walk(node)
        if not node then return end
        if node.outer then                       -- MuxPane leaf
            if node.onReposition then node.onReposition(node) end
        else                                     -- nested MuxSplit
            walk(node.childA)
            walk(node.childB)
        end
    end
    walk(self.childA)
    walk(self.childB)
end

function MuxSplit:_setRatio(r)
    self.ratio = r
    if self.direction == "v" then
        self.slotA.v_stretch_factor = r
        self.slotB.v_stretch_factor = 1 - r
    else
        self.slotA.h_stretch_factor = r
        self.slotB.h_stretch_factor = 1 - r
    end
    -- Why not just box:reposition()? Geyser's set_constraints() repositions on every
    -- constraint change, and organize() updates each child via move()+resize() (two
    -- set_constraints each). Because our box holds a Fixed handle, reposition() also
    -- runs organize(), so one nested box:reposition() fans out into O(branches^depth)
    -- repositions — seconds for a handful of panes. Instead: update only the dragged
    -- box's slot constraints with reposition suppressed (nested boxes' percentages are
    -- unchanged and recompute automatically through the getter chain), then apply
    -- native geometry over the sub-tree in a single O(n) pass.
    --
    -- _inResize is held across the whole operation: updateConsoleBorders (in the notify
    -- below) calls setBorderSizes, which raises sysWindowResizeEvent; that handler would
    -- otherwise re-run a full all-pane reposition and a second console rewrap. We've
    -- already laid out the affected sub-tree, so the echo is pure duplication.
    local wasInResize = Mux._inResize
    Mux._inResize = true

    Mux._suppressReposition(function() self.box:organize() end)

    if Mux.debug then
        local t0 = os.clock()
        Mux._applyGeometry(self.box)
        local t1 = os.clock()
        self:_notifyReposition()
        local t2 = os.clock()
        Mux._echo(string.format(
            "\n<grey>[mux perf] %s leaves=%d  applyGeometry=%.0fms  notify=%.0fms<reset>\n",
            self.id, self:_leafCount(), (t1 - t0) * 1000, (t2 - t1) * 1000))
    else
        Mux._applyGeometry(self.box)
        self:_notifyReposition()
    end

    Mux._inResize = wasInResize
end

-- Coalesced ratio update for live handle drags. Mudlet emits mouse-move events
-- far faster than a full reposition (organize + reposition + per-pane notify)
-- can complete, especially with many panes in the sub-tree. Calling _setRatio on
-- every event lets repositions queue up faster than they finish, so the drag
-- lags seconds behind the cursor while the backlog drains. Instead, we record
-- only the latest target ratio and schedule a single pending flush; any events
-- that arrive before it fires just overwrite the target. This caps reposition
-- frequency to how fast one can actually complete, regardless of pane count or
-- event rate. _flushRatio() applies the final value precisely on mouse release.
function MuxSplit:_requestRatio(r)
    self._pendingRatio = r
    if self._reposScheduled then return end
    self._reposScheduled = true
    Mux._resizing = true
    tempTimer(0, function()
        self._reposScheduled = false
        local pr = self._pendingRatio
        self._pendingRatio = nil
        if pr ~= nil then self:_setRatio(pr) end
    end)
end

-- Applies any still-pending ratio immediately and ends the resize, then runs the
-- titlebar overflow check (skipped during the drag) once across the sub-tree.
function MuxSplit:_flushRatio()
    if self._pendingRatio ~= nil then
        local pr = self._pendingRatio
        self._pendingRatio = nil
        self:_setRatio(pr)
    end
    Mux._resizing = false
    local function recheck(node)
        if not node then return end
        if node.outer then
            if node.titlebar and node._checkOverflow then node:_checkOverflow() end
        else
            recheck(node.childA)
            recheck(node.childB)
        end
    end
    recheck(self.childA)
    recheck(self.childB)
end

-- Accepts a MuxPane or a MuxSplit. Reparents its root widget into the slot.
function MuxSplit:place(child, side)
    assert(side == "a" or side == "b", "side must be 'a' or 'b'")
    local slot = (side == "a") and self.slotA or self.slotB

    local rootWidget
    if child.outer then
        rootWidget      = child.outer
        child._slot     = slot
        child._split    = self
        child._slotSide = side
        if child._updateZoomBtn then child:_updateZoomBtn() end
        if child._updateSwapBtn then child:_updateSwapBtn() end
    elseif child.box then
        rootWidget          = child.box
        child._parentSlot   = slot
        child._parentSplit  = self
        child._parentSide   = side
    else
        Mux._err("place: child must be a MuxPane or MuxSplit")
        return
    end

    rootWidget:changeContainer(slot)
    moveWindow(rootWidget.name, 0, 0)
    resizeWindow(rootWidget.name, slot:get_width(), slot:get_height())

    if side == "a" then self.childA = child
    else                self.childB = child
    end

    self:_updateHandleResizability()
    Mux._log("MuxSplit.place: %s → slot_%s of %s", child.id or "?", side, self.id)
end

-- Called when the pane in `closedSide` has been closed.
-- Promotes the sibling to fill this split's place in the hierarchy, then
-- removes the split from the registry.
function MuxSplit:collapseSlot(closedSide)
    -- Clear split/slot refs on the closed-side child if it is a floating pane so
    -- it can re-embed anywhere once this split is retired.
    local closedChild = (closedSide == "a") and self.childA or self.childB
    if closedChild and closedChild.outer and closedChild.floating then
        closedChild._split    = nil
        closedChild._slot     = nil
        closedChild._slotSide = nil
    end

    local parentContainer = self.box.container

    local siblingSide = (closedSide == "a") and "b" or "a"
    local sibling = (siblingSide == "a") and self.childA or self.childB

    if sibling and sibling.outer and sibling.floating then
        -- Ghost slot lookup is by slot container (not pane→ghost) so promotion
        -- works correctly regardless of which pane left the ghost.
        local siblingSlot = (siblingSide == "a") and self.slotA or self.slotB
        local sibGhost    = Mux._findGhostBySlot(siblingSlot)

        if sibGhost then
            -- Promote the sibling's ghost to fill this split's space in the parent
            -- so the column/row stays visible as a single ghost rather than vanishing.
            sibGhost.label:changeContainer(parentContainer)
            sibGhost.label:move("0%", "0%")
            sibGhost.label:resize("100%", "100%")
            sibGhost.label:reposition()
            if sibGhost.dismissBtn then
                sibGhost.dismissBtn:raiseAll()
                Mux.raiseFloatingPanes()
            end

            sibGhost.slot  = parentContainer
            sibGhost.split = self._parentSplit
            sibGhost.side  = self._parentSide

            sibling._slot     = parentContainer
            sibling._split    = self._parentSplit
            sibling._slotSide = self._parentSide
            if sibling._updateZoomBtn then sibling:_updateZoomBtn() end
            if sibling._updateSwapBtn then sibling:_updateSwapBtn() end

            if self._parentSplit then
                if self._parentSide == "a" then self._parentSplit.childA = sibling
                else                           self._parentSplit.childB = sibling
                end
            else
                for _, ps in pairs(Mux._paneSets) do
                    if ps.root == self then
                        ps.root          = sibling
                        sibling._paneSet = ps
                        break
                    end
                end
            end

            self.box:hide()
            if parentContainer then
                pcall(function() parentContainer:remove(self.box) end)
            end
            Mux._splits[self.id] = nil

            if self._parentSplit then
                self._parentSplit.box:organize()
                self._parentSplit.box:reposition()
            else
                parentContainer:reposition()
            end
            Mux._notifyAllReposition()
            return
        else
            sibling._split    = nil
            sibling._slot     = nil
            sibling._slotSide = nil
            if sibling._updateZoomBtn then sibling:_updateZoomBtn() end
            if sibling._updateSwapBtn then sibling:_updateSwapBtn() end
            sibling = nil
        end
    end

    -- No live embedded sibling — retire this split, sweep its ghost slots, and
    -- cascade upward so the parent fills the vacated space.
    if not sibling then
        self.box:hide()
        if parentContainer then parentContainer:remove(self.box) end
        Mux._splits[self.id] = nil
        local keysToRemove = {}
        for key, ghost in pairs(Mux._ghostSlots) do
            if ghost.split == self then keysToRemove[#keysToRemove + 1] = key end
        end
        for _, key in ipairs(keysToRemove) do
            Mux._removeGhostSlot(key)
        end
        if self._parentSplit then
            self._parentSplit:collapseSlot(self._parentSide)
        else
            for _, ps in pairs(Mux._paneSets) do
                if ps.root == self then ps.root = nil; break end
            end
        end
        return
    end

    local siblingWidget = sibling.box or sibling.outer
    if not parentContainer or not siblingWidget then
        Mux._warn("collapseSlot: cannot determine parent container for %s", self.id)
        self.box:hide()
        if parentContainer then parentContainer:remove(self.box) end
        Mux._splits[self.id] = nil
        return
    end

    -- changeContainer internally calls self.container:remove(self) on the old slot,
    -- which removes from BOTH windowList AND the windows ordered array (what VBox
    -- uses in organize()). No manual eviction needed before this call.
    siblingWidget:changeContainer(parentContainer)
    siblingWidget:move("0%", "0%")
    siblingWidget:resize("100%", "100%")
    siblingWidget:reposition()

    if sibling.outer then
        if self._parentSplit then
            local gp = self._parentSplit
            if self._parentSide == "a" then
                gp.childA         = sibling
                sibling._split    = gp
                sibling._slot     = gp.slotA
                sibling._slotSide = "a"
            else
                gp.childB         = sibling
                sibling._split    = gp
                sibling._slot     = gp.slotB
                sibling._slotSide = "b"
            end
        else
            sibling._split    = nil
            sibling._slot     = parentContainer
            sibling._slotSide = nil
        end
        if sibling._updateZoomBtn then sibling:_updateZoomBtn() end
        if sibling._updateSwapBtn then sibling:_updateSwapBtn() end
    elseif sibling.box then
        sibling._parentSplit = self._parentSplit
        sibling._parentSide  = self._parentSide
        if self._parentSplit then
            local gp = self._parentSplit
            if self._parentSide == "a" then gp.childA = sibling
            else                             gp.childB = sibling
            end
        end
    end

    for _, ps in pairs(Mux._paneSets) do
        if ps.root == self then
            ps.root = sibling
            if sibling.outer then sibling._paneSet = ps end
            break
        end
    end

    -- Use remove() which clears BOTH windowList AND the windows ordered array —
    -- VBox.organize() iterates windows, so simply clearing windowList (as done
    -- previously) left the retired split still consuming layout space.
    self.box:hide()
    parentContainer:remove(self.box)
    Mux._splits[self.id] = nil

    -- Re-layout from the grandparent's perspective so the promoted sibling fills
    -- its new space immediately. For a nested case the grandparent is another
    -- MuxSplit whose VBox needs organize(); for the root case reposition() on the
    -- PaneSet outer is sufficient.
    if self._parentSplit then
        self._parentSplit.box:organize()
        self._parentSplit.box:reposition()
    else
        parentContainer:reposition()
    end

    Mux._notifyAllReposition()

    Mux._log("MuxSplit.collapseSlot: %s retired, sibling promoted", self.id)
end

-- Replaces `pane`'s slot with a new inner MuxSplit containing the existing pane
-- in slot "a" and a new blank pane in slot "b". Returns the new MuxSplit.
function MuxSplit:_splitPaneInSlot(pane, direction, ratio)
    local side = pane._slotSide
    if not side then
        Mux._warn("_splitPaneInSlot: pane '%s' is not in a slot", pane.id)
        return nil
    end
    local slot = (side == "a") and self.slotA or self.slotB

    local newSplit = MuxSplit:new({
        direction = direction or "v",
        ratio     = ratio or 0.5,
        parent    = slot,
    })

    newSplit:place(pane, "a")

    local newPane = MuxPane:new({ parent = newSplit.slotB })
    newSplit:place(newPane, "b")
    newPane._paneSet = pane._paneSet

    newSplit._parentSplit = self
    newSplit._parentSide  = side

    if side == "a" then self.childA = newSplit
    else                self.childB = newSplit
    end

    -- Lay out the new sub-tree without Geyser's set_constraints→reposition
    -- re-entrancy (which made each split cost more as the tree grew). Update the
    -- constraints with reposition suppressed, then apply native geometry once.
    local wasInResize = Mux._inResize
    Mux._inResize = true
    Mux._suppressReposition(function()
        self.box:organize()
        newSplit.box:organize()
    end)
    Mux._applyGeometry(self.box)
    Mux._notifyAllReposition()
    Mux._inResize = wasInResize

    return newSplit
end

-- Creates a new inner split replacing existingPane's slot.
-- floatOnSide: "a"|"b" — which new slot the floating pane occupies.
-- existingPane is placed on the opposite side.
function MuxSplit:_splitAndEmbed(existingPane, floatingPane, direction, floatOnSide, ratio)
    local existingSide       = existingPane._slotSide
    local existingGoesToSide = (floatOnSide == "a") and "b" or "a"
    local slot               = (existingSide == "a") and self.slotA or self.slotB

    local newSplit = MuxSplit:new({
        direction = direction, ratio = ratio or 0.5, parent = slot,
    })

    local existingSlot = (existingGoesToSide == "a") and newSplit.slotA or newSplit.slotB
    existingPane.outer:changeContainer(existingSlot)
    moveWindow(existingPane.outer.name, 0, 0)
    resizeWindow(existingPane.outer.name,
        existingSlot:get_width(), existingSlot:get_height())
    existingPane._slot     = existingSlot
    existingPane._split    = newSplit
    existingPane._slotSide = existingGoesToSide
    if existingGoesToSide == "a" then newSplit.childA = existingPane
    else                             newSplit.childB = existingPane
    end
    if existingPane._updateZoomBtn then existingPane:_updateZoomBtn() end
    if existingPane._updateSwapBtn then existingPane:_updateSwapBtn() end

    local floatSlot = (floatOnSide == "a") and newSplit.slotA or newSplit.slotB
    floatingPane._slot     = floatSlot
    floatingPane._split    = newSplit
    floatingPane._slotSide = floatOnSide
    floatingPane._paneSet  = existingPane._paneSet
    if floatOnSide == "a" then newSplit.childA = floatingPane
    else                       newSplit.childB = floatingPane
    end
    floatingPane:embed(floatSlot)

    newSplit._parentSplit = self
    newSplit._parentSide  = existingSide
    if existingSide == "a" then self.childA = newSplit
    else                       self.childB = newSplit
    end

    self.box:organize()
    self.box:reposition()
    Mux._notifyAllReposition()
    Mux._log("MuxSplit._splitAndEmbed: new split %s in slot_%s of %s",
        newSplit.id, existingSide, self.id)
    return newSplit
end

-- Swaps the content of slotA and slotB. Updates all parent/slot bookkeeping
-- so focus, close, and collapse all still work correctly after the swap.
function MuxSplit:swapSlots()
    local ca = self.childA
    local cb = self.childB
    if not ca or not cb then
        Mux._warn("swapSlots: split '%s' needs both slots filled to swap", self.id)
        return
    end

    local wa = ca.outer or ca.box
    local wb = cb.outer or cb.box

    wa:changeContainer(self.slotB)
    wa:move("0%", "0%"); wa:resize("100%", "100%"); wa:reposition()

    wb:changeContainer(self.slotA)
    wb:move("0%", "0%"); wb:resize("100%", "100%"); wb:reposition()

    if ca.outer then
        ca._slot     = self.slotB
        ca._slotSide = "b"
    else
        ca._parentSlot = self.slotB
        ca._parentSide = "b"
    end
    if cb.outer then
        cb._slot     = self.slotA
        cb._slotSide = "a"
    else
        cb._parentSlot = self.slotA
        cb._parentSide = "a"
    end

    self.childA = cb
    self.childB = ca

    self.box:organize()
    self.box:reposition()
    Mux._notifyAllReposition()
    Mux._scheduleAutoSave()
    Mux._log("MuxSplit.swapSlots: %s swapped a↔b", self.id)
end

-- Zoom: expand one slot to fill all dynamic space, collapsing the other.
-- Implemented by zeroing the non-zoomed slot's stretch factor and setting
-- the handle size to 0px so VBox/HBox allocates it no space.
-- Calling zoom() again on the same split toggles back (same as unzoom).
function MuxSplit:zoom(side)
    assert(side == "a" or side == "b", "zoom: side must be 'a' or 'b'")
    if self._zoomed then
        self:unzoom()
        return
    end
    self._zoomed       = side
    self._savedRatio   = self.ratio
    self._savedHandleH = (self.direction == "v")
        and self.handle:get_height()
        or  self.handle:get_width()

    if self.direction == "v" then
        self.handle:resize(nil, "0px")
    else
        self.handle:resize("0px", nil)
    end

    if self.direction == "v" then
        self.slotA.v_stretch_factor = (side == "a") and 1.0 or 0.0
        self.slotB.v_stretch_factor = (side == "b") and 1.0 or 0.0
    else
        self.slotA.h_stretch_factor = (side == "a") and 1.0 or 0.0
        self.slotB.h_stretch_factor = (side == "b") and 1.0 or 0.0
    end
    self.box:organize()
    self.box:reposition()
    self.handle:hide()
    Mux._scheduleAutoSave()
    Mux._log("MuxSplit zoomed: %s slot_%s", self.id, side)
end

function MuxSplit:unzoom()
    if not self._zoomed then return end
    local h = self._savedHandleH or (Mux.activeTheme().handleSize or 5)
    if self.direction == "v" then
        self.handle:resize(nil, Mux._toPx(h))
    else
        self.handle:resize(Mux._toPx(h), nil)
    end
    self.handle:show()
    self:_setRatio(self._savedRatio or 0.5)
    self._zoomed = nil
    Mux._scheduleAutoSave()
    Mux._log("MuxSplit unzoomed: %s", self.id)
end

function MuxSplit:show()
    self.box:show()
end

function MuxSplit:hide()
    self.box:hide()
end

function MuxSplit:applyTheme()
    local theme = Mux.activeTheme()
    self.handle:setStyleSheet(theme.handleCss or "")
    self:_updateHandleResizability()
end

Mux._log("mux_split loaded")