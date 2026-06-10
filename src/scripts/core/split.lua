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
--   slotA gets (dynamic_space * r)  pixels
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

    -- ── Box container (VBox or HBox) ──────────────────────────────────────────
    -- This is what fills the parent space.  Children are added to it as:
    --   slotA (Dynamic)  → handle (Fixed)  → slotB (Dynamic)
    -- VBox.organize() / HBox.organize() lay them out automatically.
    local BoxClass = (self.direction == "v") and Geyser.VBox or Geyser.HBox
    self.box = BoxClass:new({
        name   = self.id .. "_box",
        x      = opts.x      or "0%",
        y      = opts.y      or "0%",
        width  = opts.width  or "100%",
        height = opts.height or "100%",
    }, parent)

    -- ── Slot A (top or left) ──────────────────────────────────────────────────
    self.slotA = Geyser.Container:new({
        name             = self.id .. "_slot_a",
        h_policy         = Geyser.Dynamic,
        v_policy         = Geyser.Dynamic,
        h_stretch_factor = (self.direction == "h") and self.ratio or 1.0,
        v_stretch_factor = (self.direction == "v") and self.ratio or 1.0,
    }, self.box)

    -- ── Resize handle ─────────────────────────────────────────────────────────
    -- A Label with Fixed policy in the constrained axis.
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

    -- ── Slot B (bottom or right) ──────────────────────────────────────────────
    self.slotB = Geyser.Container:new({
        name             = self.id .. "_slot_b",
        h_policy         = Geyser.Dynamic,
        v_policy         = Geyser.Dynamic,
        h_stretch_factor = (self.direction == "h") and (1 - self.ratio) or 1.0,
        v_stretch_factor = (self.direction == "v") and (1 - self.ratio) or 1.0,
    }, self.box)

    -- ── Handle drag callbacks ─────────────────────────────────────────────────
    self:_setupHandleDrag(theme, handlePx)

    -- Register globally
    Mux._splits[self.id] = self
    Mux._log("MuxSplit created: %s dir=%s ratio=%.2f", self.id, self.direction, self.ratio)
end

-- ── Handle drag mechanics ─────────────────────────────────────────────────────

function MuxSplit:_setupHandleDrag(theme, handlePx)
    -- Drag state: local per-split, no shared globals → multiple splits coexist.
    local drag = {
        active    = false,
        startPos  = 0,     -- globalX or globalY at mouse-down
        slotAPx   = 0,     -- slotA pixel size at mouse-down
        dynamicPx = 0,     -- total dynamic space at mouse-down
    }

    self.handle:setOnEnter(function()
        self.handle:setStyleSheet(theme.handleHoverCss or theme.handleCss)
    end)
    self.handle:setOnLeave(function()
        if not drag.active then
            self.handle:setStyleSheet(theme.handleCss or "")
        end
    end)

    self.handle:setClickCallback(function(event)
        if event.button ~= "LeftButton" then return end
        drag.active   = true
        -- Measure slotA and dynamic space NOW (after any prior organise call).
        if self.direction == "v" then
            drag.startPos  = event.globalY
            drag.slotAPx   = self.slotA:get_height()
            drag.dynamicPx = self.box:get_height() - handlePx
        else
            drag.startPos  = event.globalX
            drag.slotAPx   = self.slotA:get_width()
            drag.dynamicPx = self.box:get_width() - handlePx
        end
    end)

    self.handle:setMoveCallback(function(event)
        if not drag.active then return end
        local pos    = (self.direction == "v") and event.globalY or event.globalX
        local delta  = pos - drag.startPos
        local target = drag.slotAPx + delta
        -- Guard against zero dynamic space (layout not yet rendered)
        if drag.dynamicPx <= 0 then return end
        local newR = Mux._clamp(target / drag.dynamicPx, minRatio, 1 - minRatio)
        self:_setRatio(newR)
    end)

    self.handle:setReleaseCallback(function(event)
        if event.button ~= "LeftButton" then return end
        drag.active = false
        self.handle:setStyleSheet(theme.handleCss or "")
        Mux._scheduleAutoSave()
    end)
end

-- ── Ratio update ──────────────────────────────────────────────────────────────

function MuxSplit:_setRatio(r)
    self.ratio = r
    if self.direction == "v" then
        self.slotA.v_stretch_factor = r
        self.slotB.v_stretch_factor = 1 - r
    else
        self.slotA.h_stretch_factor = r
        self.slotB.h_stretch_factor = 1 - r
    end
    -- organize() updates the constraint closures (get_x/y/w/h) for all children.
    -- reposition() then cascades moveWindow/resizeWindow to every native-window
    -- descendant (Labels, MiniConsoles, etc.) using those updated closures.
    -- VBox.reposition() calls Container.reposition first then organize internally,
    -- so we must call organize() before reposition() to ensure correct ordering.
    self.box:organize()
    self.box:reposition()
    -- Keep the main console clipped to its host pane after any ratio change.
    for _, p in pairs(Mux._panes) do
        if p.mainConsoleHost then p:updateConsoleBorders() end
    end
end

-- ── Place content in a slot ───────────────────────────────────────────────────
-- Accepts a MuxPane or a MuxSplit.  Reparents its root widget into the slot.

function MuxSplit:place(child, side)
    assert(side == "a" or side == "b", "side must be 'a' or 'b'")
    local slot = (side == "a") and self.slotA or self.slotB

    local rootWidget
    if child.outer then
        -- MuxPane: reparent outer Container into the slot
        rootWidget      = child.outer
        child._slot     = slot
        child._split    = self
        child._slotSide = side
    elseif child.box then
        -- Nested MuxSplit: reparent its box into the slot; record parent for collapse
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

    Mux._log("MuxSplit.place: %s → slot_%s of %s", child.id or "?", side, self.id)
end

-- ── Collapse a slot ───────────────────────────────────────────────────────────
-- Called when the pane in `closedSide` has been closed.
-- Promotes the sibling to fill this split's place in the hierarchy, then
-- removes the split from the registry.  The caller has already hidden its outer.

function MuxSplit:collapseSlot(closedSide)
    -- Clear split/slot refs on the closed-side child if it is a floating pane, so
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

    -- The sibling is a floating pane — not physically embedded in this split.
    if sibling and sibling.outer and sibling.floating then
        -- Find the ghost at the sibling's slot by slot-container lookup (no pane→ghost key).
        local siblingSlot = (siblingSide == "a") and self.slotA or self.slotB
        local sibGhost    = Mux._findGhostBySlot(siblingSlot)

        if sibGhost then
            -- Sibling still has a ghost slot.  Promote that ghost to fill this
            -- split's place in the parent so the column/row stays visible as a
            -- single ghost rather than vanishing entirely.
            sibGhost.label:changeContainer(parentContainer)
            sibGhost.label:move("0%", "0%")
            sibGhost.label:resize("100%", "100%")
            sibGhost.label:reposition()
            if sibGhost.dismissBtn then
                sibGhost.dismissBtn:raiseAll()
                Mux.raiseFloatingPanes()
            end

            -- Update the ghost record so its dismiss button calls the right split.
            sibGhost.slot  = parentContainer
            sibGhost.split = self._parentSplit
            sibGhost.side  = self._parentSide

            -- Re-wire the sibling pane's slot bookkeeping to the promoted location.
            sibling._slot     = parentContainer
            sibling._split    = self._parentSplit
            sibling._slotSide = self._parentSide

            -- Update the parent's child pointer (or PaneSet root) to the sibling.
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

            -- Retire this split (the promoted ghost already occupies the space).
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
            for _, p in pairs(Mux._panes) do
                if p.mainConsoleHost then p:updateConsoleBorders() end
            end
            return
        else
            -- No ghost — the sibling is truly absent; free its stale refs.
            sibling._split    = nil
            sibling._slot     = nil
            sibling._slotSide = nil
            sibling = nil
        end
    end

    -- No live embedded sibling — retire this split, sweep its ghost slots, and
    -- cascade upward so the parent fills the vacated space.
    if not sibling then
        self.box:hide()
        if parentContainer then parentContainer:remove(self.box) end
        Mux._splits[self.id] = nil
        -- Sweep ghost slots, freeing vacating-pane refs so those floaters can move freely.
        local keysToRemove = {}
        for key, ghost in pairs(Mux._ghostSlots) do
            if ghost.split == self then keysToRemove[#keysToRemove + 1] = key end
        end
        for _, key in ipairs(keysToRemove) do
            Mux._removeGhostSlot(key)
        end
        -- Cascade: collapse the slot we occupied in the parent split, or clear
        -- the PaneSet root reference if we were at the top of the tree.
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
    -- uses in organize()).  No manual eviction needed before this call.
    siblingWidget:changeContainer(parentContainer)
    siblingWidget:move("0%", "0%")
    siblingWidget:resize("100%", "100%")
    siblingWidget:reposition()

    -- Update sibling's parent-split bookkeeping to reflect new position.
    if sibling.outer then
        -- Sibling is a MuxPane.
        if self._parentSplit then
            -- Grandparent is another MuxSplit — update its child pointer.
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
            -- Grandparent is a PaneSet outer — clear split refs.
            sibling._split    = nil
            sibling._slot     = parentContainer
            sibling._slotSide = nil
        end
    elseif sibling.box then
        -- Sibling is a nested MuxSplit — propagate parent info.
        sibling._parentSplit = self._parentSplit
        sibling._parentSide  = self._parentSide
        if self._parentSplit then
            local gp = self._parentSplit
            if self._parentSide == "a" then gp.childA = sibling
            else                             gp.childB = sibling
            end
        end
    end

    -- Update PaneSet root reference if this split was the root.
    for _, ps in pairs(Mux._paneSets) do
        if ps.root == self then
            ps.root = sibling
            if sibling.outer then sibling._paneSet = ps end
            break
        end
    end

    -- Retire this split's box.  Use remove() which clears BOTH windowList AND
    -- the windows ordered array — VBox.organize() iterates windows, so simply
    -- clearing windowList (as done previously) left the retired split still
    -- consuming layout space.
    self.box:hide()
    parentContainer:remove(self.box)
    Mux._splits[self.id] = nil

    -- Re-layout from the grandparent's perspective so the promoted sibling fills
    -- its new space immediately.  For a nested case the grandparent is another
    -- MuxSplit whose VBox needs organize(); for the root case reposition() on the
    -- PaneSet outer is sufficient.
    if self._parentSplit then
        self._parentSplit.box:organize()
        self._parentSplit.box:reposition()
    else
        parentContainer:reposition()
    end

    -- Sync main console borders now that the layout has changed.
    for _, p in pairs(Mux._panes) do
        if p.mainConsoleHost then p:updateConsoleBorders() end
    end

    Mux._log("MuxSplit.collapseSlot: %s retired, sibling promoted", self.id)
end

-- ── Split an existing pane ────────────────────────────────────────────────────
-- Replaces pane (which must currently be placed somewhere) with a new MuxSplit
-- that contains:  side "a" → the existing pane,  side "b" → a new empty pane.
-- Returns the new MuxSplit.
--
-- Usage:
--   local newSplit = Mux.splitPane(pane, "v", 0.5)
--   -- newSplit.slotB is now an empty pane ready for content
--
function MuxSplit:_splitPaneInSlot(pane, direction, ratio)
    local side = pane._slotSide
    if not side then
        Mux._warn("_splitPaneInSlot: pane '%s' is not in a slot", pane.id)
        return nil
    end
    local slot = (side == "a") and self.slotA or self.slotB

    -- Create the new inner split occupying the same slot
    local newSplit = MuxSplit:new({
        direction = direction or "v",
        ratio     = ratio or 0.5,
        parent    = slot,
    })

    -- Move the existing pane into newSplit slotA
    newSplit:place(pane, "a")

    -- Create a blank pane in newSplit slotB, inheriting the parent PaneSet reference
    -- so drag-to-float detection works correctly for nested splits.
    local newPane = MuxPane:new({ parent = newSplit.slotB })
    newSplit:place(newPane, "b")
    newPane._paneSet = pane._paneSet

    -- Record this split's slot as the new split's parent so collapseSlot can
    -- correctly re-wire bookkeeping when the inner split is later retired.
    newSplit._parentSplit = self
    newSplit._parentSide  = side

    if side == "a" then self.childA = newSplit
    else                self.childB = newSplit
    end

    -- Organize from the parent split downward so the new inner VBox/HBox gets
    -- its slot sizes calculated and all child native windows are positioned.
    self.box:organize()
    self.box:reposition()

    -- Sync main console borders in case Main pane geometry changed.
    for _, p in pairs(Mux._panes) do
        if p.mainConsoleHost then p:updateConsoleBorders() end
    end

    return newSplit
end

-- ── Split a slot and embed an incoming floating pane ─────────────────────────
-- Creates a new inner split replacing existingPane's slot.
-- floatOnSide: "a" | "b" — which new slot the floating pane occupies.
-- existingPane is placed on the opposite side.
-- ratio: fraction of the new split's space given to slotA.

function MuxSplit:_splitAndEmbed(existingPane, floatingPane, direction, floatOnSide, ratio)
    local existingSide       = existingPane._slotSide
    local existingGoesToSide = (floatOnSide == "a") and "b" or "a"
    local slot               = (existingSide == "a") and self.slotA or self.slotB

    local newSplit = MuxSplit:new({
        direction = direction, ratio = ratio or 0.5, parent = slot,
    })

    -- Move existing pane into its new side of the inner split.
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

    -- Embed floating pane into the other side.
    local floatSlot = (floatOnSide == "a") and newSplit.slotA or newSplit.slotB
    floatingPane._slot     = floatSlot
    floatingPane._split    = newSplit
    floatingPane._slotSide = floatOnSide
    floatingPane._paneSet  = existingPane._paneSet
    if floatOnSide == "a" then newSplit.childA = floatingPane
    else                       newSplit.childB = floatingPane
    end
    floatingPane:embed(floatSlot)

    -- Wire parent bookkeeping so collapseSlot works correctly up the tree.
    newSplit._parentSplit = self
    newSplit._parentSide  = existingSide
    if existingSide == "a" then self.childA = newSplit
    else                       self.childB = newSplit
    end

    self.box:organize()
    self.box:reposition()
    for _, p in pairs(Mux._panes) do
        if p.mainConsoleHost then p:updateConsoleBorders() end
    end
    Mux._log("MuxSplit._splitAndEmbed: new split %s in slot_%s of %s",
        newSplit.id, existingSide, self.id)
    return newSplit
end

-- ── Swap slots ────────────────────────────────────────────────────────────────
-- Swaps the content of slotA and slotB in place.  Updates all parent/slot
-- bookkeeping so focus, close, and collapse all still work correctly after swap.

function MuxSplit:swapSlots()
    local ca = self.childA
    local cb = self.childB
    if not ca or not cb then
        Mux._warn("swapSlots: split '%s' needs both slots filled to swap", self.id)
        return
    end

    local wa = ca.outer or ca.box
    local wb = cb.outer or cb.box

    -- Move a's widget into slotB, b's widget into slotA.
    wa:changeContainer(self.slotB)
    wa:move("0%", "0%"); wa:resize("100%", "100%"); wa:reposition()

    wb:changeContainer(self.slotA)
    wb:move("0%", "0%"); wb:resize("100%", "100%"); wb:reposition()

    -- Update MuxPane bookkeeping.
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

    -- Swap the split's own child pointers.
    self.childA = cb
    self.childB = ca

    -- Re-layout and sync main console borders.
    self.box:organize()
    self.box:reposition()
    for _, p in pairs(Mux._panes) do
        if p.mainConsoleHost then p:updateConsoleBorders() end
    end
    Mux._scheduleAutoSave()
    Mux._log("MuxSplit.swapSlots: %s swapped a↔b", self.id)
end

-- ── Zoom / unzoom ─────────────────────────────────────────────────────────────
-- Zoom: expand one slot to fill all dynamic space, collapsing the other.
-- Implemented by zeroing the non-zoomed slot's stretch factor and setting
-- the handle height to 0px so VBox/HBox allocates it no space.
--
-- Calling zoom() on an already-zoomed split toggles back (same as unzoom).

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

    -- Collapse the handle to 0px (removes its space contribution to VBox/HBox)
    if self.direction == "v" then
        self.handle:resize(nil, "0px")
    else
        self.handle:resize("0px", nil)
    end

    -- Give ALL dynamic space to the zoomed slot; zero the other
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
    -- Restore handle size
    local h = self._savedHandleH or (Mux.activeTheme().handleSize or 5)
    if self.direction == "v" then
        self.handle:resize(nil, Mux._px(h))
    else
        self.handle:resize(Mux._px(h), nil)
    end
    self.handle:show()
    -- Restore saved ratio
    self:_setRatio(self._savedRatio or 0.5)
    self._zoomed = nil
    Mux._scheduleAutoSave()
    Mux._log("MuxSplit unzoomed: %s", self.id)
end

-- ── Show / hide entire split tree ─────────────────────────────────────────────

function MuxSplit:show()
    self.box:show()
end

function MuxSplit:hide()
    self.box:hide()
end

-- ── Theme refresh ─────────────────────────────────────────────────────────────

function MuxSplit:applyTheme()
    local theme = Mux.activeTheme()
    self.handle:setStyleSheet(theme.handleCss or "")
    local cursor = (self.direction == "v")
        and (theme.handleCursorV or "ResizeVertical")
        or  (theme.handleCursorH or "ResizeHorizontal")
    self.handle:setCursor(cursor)
end

Mux._log("mux_split loaded")
