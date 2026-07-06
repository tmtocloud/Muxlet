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
    -- confirmClose: when false, close() skips the confirmation prompt for this
    -- pane regardless of the mux.confirmPaneClose setting.
    self.confirmClose     = opts.confirmClose ~= false
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
    -- When floating, the registry key of the ghost marking this pane's home tile.
    -- Stable across ghost promotion, so it resolves to the live home even after a
    -- sibling collapse moves the ghost. nil while embedded.
    self._homeGhostKey = nil

    -- User callbacks
    self.onClose    = opts.onClose
    self.onMinimize = opts.onMinimize
    self.onFloat    = opts.onFloat
    self.onEmbed    = opts.onEmbed

    local tbH    = theme.titlebarHeight
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

    local hdrH = self.titlebarVisible and tbH or 0
    -- bordered: when false, the pane has no visible frame border and content fills
    -- edge-to-edge (the inset that normally reveals the 2px border collapses to 0).
    self.bordered     = opts.bordered ~= false
    self.borderColor  = opts.borderColor or nil
    -- Local style-token overrides (per-pane). Seeded from a restored workspace via
    -- opts.tokens; the legacy borderColor opt maps onto the pane.border.color token.
    self._tokens = {}
    if opts.tokens then
        for k, v in pairs(opts.tokens) do self._tokens[k] = v end
    end
    if opts.borderColor then self._tokens["pane.border.color"] = opts.borderColor end
    -- Reactive rules (see conditional.lua): a list of {cond, act, actElse}. Legacy
    -- single-condition fields and connectionAware are migrated into the list. The
    -- `condition`/`actionTrue`/`actionFalse` fields are kept as a synced view of the
    -- "primary" rule so the existing single-rule UI keeps working.
    self.condition   = opts.condition
    if self.condition and (not self.condition.type or self.condition.type == "always") then
        self.condition = nil
    end
    self.actionTrue  = opts.actionTrue  or "mux.showSelf"
    self.actionFalse = opts.actionFalse or "mux.hideSelf"
    self.rules = {}
    if Mux._migrateLegacyRules then
        Mux._migrateLegacyRules(self, {
            rules = opts.rules, condition = self.condition,
            actionTrue = opts.actionTrue, actionFalse = opts.actionFalse,
            connectionAware = opts.connectionAware,
        })
    end
    local inset   = self.bordered and borderInset or 0
    self.header = Geyser.Container:new({
        name   = self._gid .. "_header",
        x      = tostring(inset) .. "px",
        y      = tostring(inset) .. "px",
        width  = Mux._fromEdgePx(inset),
        height = Mux._toPx(hdrH),
    }, self.outer)

    local contentY = inset + hdrH
    self.content = Geyser.Container:new({
        name   = self._gid .. "_content",
        x      = tostring(inset) .. "px",
        y      = Mux._toPx(contentY),
        width  = Mux._fromEdgePx(inset),
        height = Mux._fromEdgePx(inset),
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
    -- autoFit: when false, Mux.requestAutoFit(target, ...) is a no-op for this
    -- pane -- content may still compute/report a size, but the pane itself
    -- will not resize to it (initial post-apply fit and any later live re-fit
    -- both respect this). When true (default), floating panes whose content
    -- opts in via _autoFitHeight/_autoFitWidth track it automatically.
    self.autoFit            = opts.autoFit ~= false
    -- anchorable: when true, this floating pane can be anchored to other panes'
    -- edges (graphically via anchor mode, or programmatically). Independent of
    -- convertible/insertable — nothing ever auto-anchors. self.anchor holds the
    -- spec (see anchor.lua); _atAnchor tracks whether it's currently snapped to it.
    self.anchorable         = opts.anchorable ~= false
    -- showAnchorElement: display-only. When false the anchor icon AND menu element
    -- are hidden, but any existing anchor relationship is preserved (the pane still
    -- snaps). Independent of anchorable, which is a permission (turning anchorable
    -- off still drops the anchor). Lives on the Style tab.
    self.showAnchorElement  = opts.showAnchorElement ~= false
    self.anchor             = opts.anchor
    self._atAnchor          = false
    self._anchorArming      = false
    -- showSettingsInMenu: context menu shows "Settings" instead of Properties/Close.
    self.showSettingsInMenu = opts.showSettingsInMenu or false
    -- onReposition: optional callback fired whenever the pane's geometry changes due
    -- to an external event (split rebalance, window resize, workspace restore, zoom).
    self.onReposition     = opts.onReposition

    -- mainConsoleHost: marks the pre-configured, locked pane that hosts the Mudlet
    -- native console. It only locks the native pane settings (the "special pane"
    -- pattern — pre-configured + locked, like a dialog). The console DISPLAY (border
    -- driving) and the ⚙ Settings gear are supplied by the registered `mux_console`
    -- content applied to this pane, not by the flag.
    self.mainConsoleHost = opts.mainConsoleHost or false
    -- addable: shows the + / Add Floating Pane button. Auto-set for the console host.
    self.addable = false
    if self.mainConsoleHost then
        self.closeable        = false
        self.convertible      = false
        self.contentable      = true    -- a normal content host: console is content, swappable/testable
        self.addable          = true
    end

    if self.consoleBorders then
        self:_enableConsoleBorders()
    end

    -- Per-element titlebar visibility. A set of element ids (builtin or content)
    -- the user has explicitly hidden via Properties; the placement engine skips
    -- them entirely (icon AND menu). Persisted in the workspace.
    self.hiddenTbElements = {}
    if opts.hiddenTbElements then
        for _, id in ipairs(opts.hiddenTbElements) do self.hiddenTbElements[id] = true end
    end

    -- Read-only parameter locks. _paramLocks[prop] = reason string means the property
    -- is read-only (shown greyed in Properties with the reason on hover). Derived only —
    -- rebuilt by _recomputeLocks() from the active content's paramLocks and the
    -- last-embedded-pane rule. Never hand-set elsewhere.
    self._paramLocks    = {}
    self._lockSnapshot  = {}   -- pre-apply values for content-locked params, for revert
    if opts.lockSnapshot then
        for prop, val in pairs(opts.lockSnapshot) do self._lockSnapshot[prop] = val end
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

    -- Chain _syncButtons into every pane's onReposition so button visibility
    -- is re-evaluated whenever a split handle is dragged or the window resizes.
    local prevOnRepos = self.onReposition
    self.onReposition = function(p)
        if prevOnRepos then prevOnRepos(p) end
        if p.titlebar then p:_syncButtons() end
        if p._tabBarBox then p:_relayoutTabLabels() end
    end

    Mux._panes[self.id] = self
    Mux._log("MuxPane created: %s", self.id)
    -- Reactive rules: register + evaluate once (deferred a tick so the pane is fully
    -- built and any embedding has happened). Migration already registered the subject;
    -- this just forces the initial evaluation against current signals.
    if self.rules and #self.rules > 0 then
        if Mux._registerRuleSubject then Mux._registerRuleSubject(self) end
        tempTimer(0, function()
            if Mux._evaluateRules then Mux._evaluateRules(self, true) end
        end)
    end
    if _t0 then
        Mux._echo(string.format("\n<grey>[mux perf] pane create %s = %.1fms<reset>\n",
            self.id, (os.clock() - _t0) * 1000))
    end
end

-- ── Reactive condition (see conditional.lua) ──────────────────────────────────

-- Set (or clear, with nil) the pane's "primary" rule condition. A spec with type
-- "always" (or no type) clears it (always visible). Other rules (e.g. connection)
-- are unaffected. `condition` mirrors the primary rule for the single-rule UI.
function MuxPane:setCondition(spec)
    if type(spec) == "table" and (not spec.type or spec.type == "always") then spec = nil end
    self.condition = spec
    if spec then
        Mux._addRule(self, { id = "primary", cond = spec,
            act = self.actionTrue or "mux.showSelf", actElse = self.actionFalse or "mux.hideSelf" })
    else
        Mux._removeRule(self, "primary")
        if self._conditionHidden then self:_conditionShow() end   -- no condition → visible
    end
    Mux._scheduleAutoSave()
end

function MuxPane:setReactiveActions(trueId, falseId)
    self.actionTrue  = trueId  or self.actionTrue  or "mux.showSelf"
    self.actionFalse = falseId or self.actionFalse or "mux.hideSelf"
    local r = Mux._findRule(self, "primary")
    if r then
        r.act, r.actElse = self.actionTrue, self.actionFalse
        Mux._evaluateRules(self, true)
    end
    Mux._scheduleAutoSave()
end

-- "Show self" reactive action: reveal the pane; if embedded, restore its slot's
-- weight so the layout returns to normal.
function MuxPane:_conditionShow()
    if not self._conditionHidden and self.outer and self.outer.get_x then
        -- already visible; still ensure layout is consistent
    end
    self._conditionHidden = false
    self:show()
    self:_reflowConditionLayout()
end

-- "Hide self" reactive action: hide the pane; if embedded, collapse its slot so the
-- sibling reclaims the space (as if closed); if floating, just hide.
function MuxPane:_conditionHide()
    self._conditionHidden = true
    self:hide()
    self:_reflowConditionLayout()
end

-- Re-weight every ancestor split from this pane to the tree root so collapsed
-- (condition-hidden) slots take zero space, then lay out the sub-tree once.
function MuxPane:_reflowConditionLayout()
    local s = self._split
    if not s then return end           -- floating / root pane: hide/show is enough
    local top = s
    while s do
        if s._applyConditionWeights then s:_applyConditionWeights() end
        top = s
        s = s._parentSplit
    end
    if top and top.box then
        if Mux._suppressReposition then
            Mux._suppressReposition(function() top.box:organize() end)
        else
            top.box:organize()
        end
    end
    if Mux._notifyAllReposition then Mux._notifyAllReposition() end
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
        drag.anchorSpec  = nil
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
        -- Keep the pane on-screen. Mudlet/Geyser interpret a negative window
        -- coordinate as an offset measured from the opposite edge (the convention
        -- Mux._fromEdgePx relies on), so a left/top overrun teleports the pane to
        -- the far side — clamping x/y >= 0 prevents that. A right/bottom overrun
        -- does not teleport but slides the pane off-screen with no way to grab it
        -- back, so the far edges are clamped too. A pane larger than the screen on
        -- an axis pins to 0 on that axis (max becomes 0).
        local sw, sh = getMainWindowSize()
        local pw, ph = self.outer:get_width(), self.outer:get_height()
        local maxX = math.max(0, sw - pw)
        local maxY = math.max(0, sh - ph)
        if newX < 0 then newX = 0 elseif newX > maxX then newX = maxX end
        if newY < 0 then newY = 0 elseif newY > maxY then newY = maxY end
        self.outer:move(newX, newY)
        self.outer:reposition()
        self.floatX = newX
        self.floatY = newY

        -- A plain drag moves the pane off its anchor (the spec is kept for return).
        if self._atAnchor and not self._anchorArming then self._atAnchor = false end

        -- Anchor mode: preview an anchor target (edge/corner) instead of insertion.
        if self._anchorArming and self.anchorable then
            local agx, agy = event.globalX, event.globalY
            if not drag.dropTargets then snapshotDropTargets() end
            local aw, ah = self.outer:get_width(), self.outer:get_height()
            local spec, ax, ay, aw2, ah2 = Mux._anchorHitTest(drag.dropTargets, drag.ghostRects, agx, agy, aw, ah)
            if spec then
                local corner = (spec.v and spec.h)
                    and { vx = spec.v.myEdge, hy = spec.h.myEdge } or nil
                Mux._showAnchorIndicator(ax, ay, aw2, ah2, corner)
                drag.anchorSpec = spec
            else
                Mux._hideAnchorIndicator()
                drag.anchorSpec = nil
            end
            return
        end

        if not self.convertible then return end
        local gx, gy = event.globalX, event.globalY
        if not drag.dropTargets then snapshotDropTargets() end

        -- Detection order matters. Insertion zones live on the 20% edges of real,
        -- embedded panes; a ghost slot can be large (especially after promotion)
        -- and may overlap a neighbouring pane's edge zone. So test pane-edge
        -- insertion FIRST: if the cursor is in a pane's edge zone, that wins (and we
        -- clear any ghost highlight). Only when no insertion edge is found do we
        -- treat the position as a ghost hover (return-home into the ghost's
        -- interior). The two states are kept mutually exclusive so the preview and
        -- the drop always agree.
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
            -- Insertion wins: clear any ghost highlight so the two are exclusive.
            if drag.lastHoverGhostKey then
                local prev = Mux._ghostSlots[drag.lastHoverGhostKey]
                if prev then Mux._unhighlightGhostSlot(prev) end
                drag.lastHoverGhostKey = nil
            end
            Mux._showInsertionGhost(rect.x, rect.y, rect.w, rect.h, insertEdge)
            drag.insertTarget = { pane = insertPane, edge = insertEdge }
        else
            -- No insertion edge under the cursor — fall back to ghost-slot hover
            -- (return-home / drop-into-ghost) for whichever slot the cursor is over.
            Mux._hideInsertionGhost()
            drag.insertTarget = nil

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
        Mux._hideAnchorIndicator()

        -- Anchor-mode release: set the anchor (snaps + marks at-anchor, stays
        -- floating) or, if no target, just keep floating where dropped. Either
        -- way we never embed.
        if self._anchorArming then
            self._anchorArming = false
            local spec = drag.anchorSpec
            drag.anchorSpec = nil
            if spec then self:setAnchor(spec) end
            if self._refreshAnchorBtn then self._refreshAnchorBtn() end
            if self.titlebar then self.titlebar:setCursor(self:_titlebarCursor()) end
            Mux._scheduleAutoSave()
            return
        end

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
        -- An anchored pane double-clicks back to its anchor, ahead of any dock
        -- behaviour — applies whether or not the pane is convertible.
        if self.anchor then self:returnToAnchor(); return end
        if not self.convertible then
            return
        end
        if not self.floating then
            if Mux.raisePane then Mux.raisePane(self) end
            return
        end

        -- Home tile first (resolved by stable key, so a promoted ghost still
        -- matches); then fall back to the nearest ghost by screen distance.
        local homeGhost = (self._homeGhostKey and Mux._ghostSlots[self._homeGhostKey])
                          or Mux._findGhostBySlot(self._slot)
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
        -- Only close/min carry a dedicated hover sheet (red / gold). Generic buttons
        -- keep btnCss so its own QLabel::hover (btn.hover.bg) drives the hover colour
        -- instead of being forced to the minimise button's gold.
        local hoverKey = spec.hoverCss
        local function echo(hovered)
            -- Scope-aware glyph colour: a per-pane Button Icon override (local token)
            -- now wins over the global default, and updates on every applyTheme.
            local tc   = hovered and "white" or (Mux.tok("btn.text.glyphColor", self) or "#aaaabb")
            local icon = (type(spec.icon) == "function") and spec.icon() or spec.icon
            btn:echo(string.format("<center><font color='%s'>%s</font></center>", tc, icon))
        end
        echo(false)
        if spec.tooltip then btn:setToolTip(spec.tooltip) end
        btn:setOnEnter(function()
            if hoverKey then btn:setStyleSheet(Mux.activeTheme()[hoverKey] or Mux.activeTheme().btnCss) end
            echo(true)
        end)
        btn:setOnLeave(function()
            if hoverKey then btn:setStyleSheet(Mux.activeTheme().btnCss or "") end
            echo(false)
        end)
        if spec.onClick then btn:setClickCallback(spec.onClick) end
        -- Track every titlebar button so applyTheme can restyle + re-echo them all
        -- uniformly (otherwise some icons only refresh on hover).
        self._btnEchos = self._btnEchos or {}
        self._btnEchos[#self._btnEchos + 1] = { btn = btn, echo = echo, hoverKey = hoverKey }
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

    -- addPaneBtn: far-right slot (same offset as close; addable panes are not closeable).
    -- Spawns a new floating pane. Only ever visible on the main console host pane.
    self.addPaneBtn, self._addPaneBtnEcho = makeTitlebarButton({
        suffix  = "_addpane",
        x       = "-20",
        icon    = "+",
        tooltip = "Add floating pane",
        onClick = function(event)
            if event.button == "LeftButton" then Mux._addFloatingPane() end
        end,
    })
    if not self.addable then self.addPaneBtn:hide() end

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

    -- anchorBtn: right cluster (shares the swap/split slot at -96, which is only
    -- used by embedded panes, so it never collides with the floating-only anchor
    -- button). Only shown for a floating, anchorable pane when the titlebar isn't
    -- compact. Background lights up while anchor mode is armed or an anchor is set.
    self.anchorBtn, self._anchorBtnEcho = makeTitlebarButton({
        suffix  = "_anchor",
        x       = "-96",
        icon    = "⚓",
        tooltip = "Anchor",
        onClick = function(event)
            if event.button ~= "LeftButton" then return end
            if self._anchorArming then
                self:armAnchorMode(false)        -- click again to leave anchor mode
            elseif not self.anchor then
                self:armAnchorMode(true)         -- not anchored: just enter anchor mode (drag to set)
            else
                -- Anchored: fan out a downward stack of same-sized icon buttons.
                -- get_x/get_y already return absolute screen coords in Geyser.
                local bw, bh = self.anchorBtn:get_width(), self.anchorBtn:get_height()
                local sx = self.anchorBtn:get_x()
                local sy = self.anchorBtn:get_y() + bh
                if Mux._showTitlebarIconStack then
                    Mux._showTitlebarIconStack(sx, sy, bw, bh, {
                        { icon = "⤺", tooltip = "Return to anchor", fn = function() self:returnToAnchor() end },
                        { icon = "✕", tooltip = "Remove anchor",    fn = function() self:removeAnchor() end },
                    })
                end
            end
        end,
    })
    -- ⚓ renders as a wide colour-emoji; btnCss already forces AlignCenter, so keep
    -- the box model identical between states — change only the border COLOUR for the
    -- armed/anchored cue. Swapping width (1px↔2px) shifted the glyph off-centre.
    local alignRule  = " QLabel{ qproperty-alignment:'AlignCenter'; }"
    local activeRule = " QLabel{ border-color:#ffffff; qproperty-alignment:'AlignCenter'; }"
    self._refreshAnchorBtn = function()
        if not self.anchorBtn then return end
        local active = self._anchorArming or (self.anchor ~= nil)
        self.anchorBtn:setStyleSheet((Mux.activeTheme().btnCss or "") .. (active and activeRule or alignRule))
    end
    self.anchorBtn:setOnEnter(function()
        local hoverCss = Mux.activeTheme().minHoverCss or Mux.activeTheme().btnCss or ""
        if self._anchorArming or self.anchor then
            self.anchorBtn:setStyleSheet(hoverCss .. activeRule)
        else
            self.anchorBtn:setStyleSheet(hoverCss .. alignRule)
        end
        if self._anchorBtnEcho then self._anchorBtnEcho(true) end
    end)
    self.anchorBtn:setOnLeave(function()
        self._refreshAnchorBtn()
        if self._anchorBtnEcho then self._anchorBtnEcho(false) end
    end)
    self.anchorBtn:hide()   -- shown by _applyTitlebarVisibility / _checkOverflow when eligible

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
-- Name/alignment changed: the placement engine recomputes the whole bar (left
-- cluster position depends on the name width; right cluster too in right-align).
function MuxPane:_updateInfoBtnPos()
    if self.titlebar then self:_syncButtons(true) end
end

-- Returns the HTML string for the titlebar name, styled for the current nameAlign.
-- The right-align margin-right matches namePad in _layoutTitlebarButtons so the
-- glyphs line up with the slot reserved for the name.
function MuxPane:_nameHtml()
    local tbc = Mux.tok("titlebar.text.color", self) or Mux.tok("btn.text.glyphColor", self) or "#aaaabb"
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

-- ── Titlebar element placement system ───────────────────────────────────────────
-- A single ordered model governs every titlebar element AND the right-click menu.
-- Each element has ONE definition carrying both forms: an icon (titlebar) and a
-- menu row (glyph + label + action, optional submenu). The engine places what
-- fits as icons and folds the lowest-priority remainder into the menu — so the
-- menu is exactly the complement of the visible icons, never a second hand-kept
-- list. Nothing folded (and not compact) → no menu. A ⋯ overflow button appears
-- only when something is folded, as the visible handle for the menu.
--
-- Builtins are referenced by a resolver to their existing Label; content
-- contributes its own and may "play in" any side/group/order but cannot remove or
-- override a builtin (builtin ids are reserved).
--
-- Spec fields:
--   id, side ("left"|"right"), group (cluster), order (pack order within side)
--   priority   overflow fold order — lowest folds into the menu first; close is
--              highest so it folds last (no hard exemption)
--   visible(ctx) -> bool
--   get(pane)  (builtins) -> existing Label   | icon/tooltip/onClick (content)
--   menuText   string | function(ctx) -> string   (row glyph + label)
--   run(ctx)             menu-row action (defaults to the icon onClick)
--   submenu(ctx) -> items | nil                   (dynamic submenu)
--   danger     bool                               (destructive styling)
--   menuOrder  sequence within the menu; menuGroup keys separator insertion
--   iconable   default true; false = menu-only, always in the menu, forces it
--   menuFallbackOnly  default false; true = this element's menuText does NOT
--              by itself force the right-click menu open (see hasMenuExtra
--              below) — its row is only reachable once the menu is already
--              showing for another reason (overflow, compact, or a sibling
--              element). Use this when a titlebar icon already reaches the
--              same action directly, so right-click doesn't offer a
--              permanent redundant path to it.
local TB_GROUP_RANK = { window = 1, tiling = 2, info = 1, content = 2, console = 3 }  -- right: lower = nearer edge

-- Builtin pane elements. Each definition is the single source of truth for both
-- the titlebar icon and the matching menu row.
local BUILTIN_TB = {
    -- right · window cluster
    { id="close",  side="right", group="window", order=1, priority=100,
      get=function(p) return p.closeBtn end,    visible=function(c) return c.pane.closeable and not Mux._isLastEmbeddedPane(c.pane) end,
      menuText="✕  Close Pane", danger=true, menuGroup="window", menuOrder=10,
      run=function(c) c.pane:_confirmClose() end },
    { id="add",    side="right", group="window", order=1, priority=100,
      get=function(p) return p.addPaneBtn end,  visible=function(c) return c.pane.addable end,
      menuText="+  Add Floating Pane", menuGroup="window", menuOrder=15,
      run=function(c) Mux._addFloatingPane() end },
    { id="min",    side="right", group="window", order=2, priority=90,
      get=function(p) return p.minBtn end,       visible=function(c) return c.pane:_minBtnVisible() end,
      menuText="–  Minimize", menuGroup="window", menuOrder=20,
      run=function(c) c.pane:toggleMinimize() end },
    { id="zoom",   side="right", group="window", order=3, priority=70,
      get=function(p) return p.zoomBtn end,
      visible=function(c) local p=c.pane; return p.zoomable and (p._split or p.floating or p._zoomed) and true or false end,
      menuText=function(c) return c.pane._zoomed and "⧉  Unzoom" or "□  Zoom" end,
      menuGroup="window", menuOrder=30, run=function(c) c.pane:zoom() end },
    -- right · tiling cluster
    { id="swap",   side="right", group="tiling", order=1, priority=50,
      get=function(p) return p.swapBtn end,
      visible=function(c) local p=c.pane; return p.swappable and not p.floating and p._split and true or false end,
      menuText="⇔  Swap with sibling", menuGroup="tiling", menuOrder=50,
      run=function(c) if c.pane._split then c.pane._split:swapSlots() end end },
    { id="anchor", side="right", group="tiling", order=1, priority=50,
      get=function(p) return p.anchorBtn end,
      visible=function(c) local p=c.pane; return p.floating and p.anchorable and (p.showAnchorElement ~= false) and not p._zoomed and true or false end,
      menuText="⚓  Anchor", menuGroup="tiling", menuOrder=40,
      submenu=function(c) if c.pane.anchor then return {
          { text="Return to anchor", fn=function() c.pane:returnToAnchor() end },
          { text="Remove anchor",    fn=function() c.pane:removeAnchor() end, danger=true },
      } end end,
      run=function(c) if not c.pane.anchor then c.pane:armAnchorMode(true) end end },
    { id="splitH", side="right", group="tiling", order=2, priority=40,
      get=function(p) return p.splitHBtn end,
      visible=function(c) local p=c.pane; return p.splittable and not p.floating and true or false end,
      menuText="═  Split Horizontally", menuGroup="tiling", menuOrder=70,
      run=function(c) c.pane:split("v") end },
    { id="splitV", side="right", group="tiling", order=3, priority=40,
      get=function(p) return p.splitVBtn end,
      visible=function(c) local p=c.pane; return p.splittable and not p.floating and true or false end,
      menuText="║  Split Vertically", menuGroup="tiling", menuOrder=60,
      run=function(c) c.pane:split("h") end },
    -- left · info cluster
    { id="properties", side="left", group="info", order=2, priority=110,
      get=function(p) return p.infoBtn end,
      visible=function(c) local p=c.pane; return p.contextMenu and p.infoBtn and (p.showSettingsInMenu or p.propertiesButton) and true or false end,
      menuText=function(c) return c.pane.showSettingsInMenu and "⚙  Settings" or "≡  Properties" end,
      menuGroup="info", menuOrder=80,
      run=function(c) if c.pane.showSettingsInMenu then Mux.settings.toggle() else Mux.showPaneProperties(c.pane) end end },
    { id="content",    side="left", group="info", order=3, priority=80,
      get=function(p) return p.contentBtn end,
      visible=function(c) return c.pane:_contentEnabled() end,
      menuText="▥  Content Library…", menuGroup="info", menuOrder=90,
      run=function(c) Mux._showContentLibrary(c.pane) end },
}
local BUILTIN_TB_IDS = {}
for _, s in ipairs(BUILTIN_TB) do BUILTIN_TB_IDS[s.id] = true end

-- The state snapshot passed to every visible()/onClick(). Reads, never mutates.
function MuxPane:_elementCtx()
    -- The pane titlebar and the pane's right-click menu reflect the pane's OWN
    -- content only. Content hosted in a tab publishes solely to that tab's
    -- right-click menu (see tabs.lua _showTabContextMenu): a tab has no titlebar, so
    -- its content must never add icons or menu rows to the host pane.
    local contentId = self._activeContent
    return {
        pane        = self,
        tab         = nil,
        isTab       = false,
        isFloating  = self.floating and true or false,
        isEmbedded  = (self._split ~= nil and not self.floating) and true or false,
        content     = contentId and Mux._content and Mux._content[contentId] or nil,
    }
end

-- Build a content-contributed titlebar Label (mirrors the builtin maker, minus
-- the constructor-local closures). Returns { label, echo, spec }.
function MuxPane:_makeTbButton(spec)
    local theme = Mux.activeTheme()
    local btnY  = theme.btnTopMargin or 2
    local btn = Geyser.Label:new({
        name = self._gid .. "_ctb_" .. spec.id, x = 2, y = tostring(btnY),
        width = tostring(theme.btnSize), height = tostring((theme.btnSize or 22)), fillBg = 1,
    }, self.header)
    btn:setStyleSheet(theme.btnCss or "")
    local hoverKey = spec.hoverCss or "minHoverCss"
    local function echo(hovered)
        local tc   = hovered and "white" or (Mux.activeTheme().btnTextColor or "#aaaabb")
        local icon = (type(spec.icon) == "function") and spec.icon(self:_elementCtx()) or spec.icon
        btn:echo(string.format("<center><font color='%s'>%s</font></center>", tc, icon or "?"))
    end
    echo(false)
    if spec.tooltip then btn:setToolTip(spec.tooltip) end
    btn:setOnEnter(function() btn:setStyleSheet(Mux.activeTheme()[hoverKey] or Mux.activeTheme().btnCss); echo(true) end)
    btn:setOnLeave(function() btn:setStyleSheet(Mux.activeTheme().btnCss or ""); echo(false) end)
    if spec.onClick then
        btn:setClickCallback(function(event) spec.onClick(self:_elementCtx(), event) end)
    end
    return { label = btn, echo = echo, spec = spec }
end

-- Content elements come from the active content def's `titlebarElements`. Rebuild
-- the content Labels only when the active content changes (not per frame). Content
-- ids that collide with a builtin are ignored — content cannot override builtins.
function MuxPane:_syncContentTbButtons()
    local ctx    = self:_elementCtx()
    local def    = ctx.content
    local sig    = self._activeContent or "none"
    if self._contentTbSig == sig then return end
    self._contentTbSig = sig
    self._contentTbBtns = self._contentTbBtns or {}

    local specs = (def and def.titlebarElements) or {}
    local want  = {}
    for _, s in ipairs(specs) do
        if s.id and s.iconable ~= false and not BUILTIN_TB_IDS[s.id] then want[s.id] = s end
    end
    -- Drop buttons whose content went away or changed.
    for id, b in pairs(self._contentTbBtns) do
        if not want[id] then
            pcall(function() b.label:hide() end)
            pcall(function() if b.label.delete then b.label:delete() end end)
            self._contentTbBtns[id] = nil
        end
    end
    -- Create newcomers.
    for id, s in pairs(want) do
        if not self._contentTbBtns[id] then
            self._contentTbBtns[id] = self:_makeTbButton(s)
        end
    end
end

-- Collect the visible elements for each side, ordered for packing. Builtins map
-- to their existing Labels; content maps to its created Labels. Returns
-- left/right arrays of { spec, label } plus a flat ascending-priority list for
-- overflow folding.
function MuxPane:_collectTbElements(ctx)
    local left, right, all = {}, {}, {}
    local function consider(spec, label)
        if not label then return end
        if self.hiddenTbElements and self.hiddenTbElements[spec.id] then return end
        local vis = true
        if type(spec.visible) == "function" then
            local ok, v = pcall(spec.visible, ctx)
            vis = ok and v
        end
        if not vis then return end
        local entry = { spec = spec, label = label }
        all[#all + 1] = entry
        if spec.side == "left" then left[#left + 1] = entry else right[#right + 1] = entry end
    end
    for _, spec in ipairs(BUILTIN_TB) do consider(spec, spec.get(self)) end
    if self._contentTbBtns then
        for _, b in pairs(self._contentTbBtns) do consider(b.spec, b.label) end
    end
    local function sortSide(arr)
        table.sort(arr, function(x, y)
            local gx = TB_GROUP_RANK[x.spec.group] or 9
            local gy = TB_GROUP_RANK[y.spec.group] or 9
            if gx ~= gy then return gx < gy end
            if (x.spec.order or 0) ~= (y.spec.order or 0) then return (x.spec.order or 0) < (y.spec.order or 0) end
            return (x.spec.id or "") < (y.spec.id or "")
        end)
    end
    sortSide(left); sortSide(right)
    table.sort(all, function(x, y) return (x.spec.priority or 50) < (y.spec.priority or 50) end)
    return left, right, all
end

-- Back-compat entry: the layout is now computed inside _syncButtons (visibility
-- and packing are interdependent), so this just forces a full sync.
function MuxPane:_layoutTitlebarButtons()
    if not self.titlebar then return end
    self:_syncButtons(true)
end

-- Sets the name alignment and refreshes the titlebar layout.
function MuxPane:setNameAlign(align)
    self.nameAlign = align
    if not self.titlebar then return end
    self:_layoutTitlebarButtons()
    self:_refreshTitlebarName()
    self:_syncButtons()
end

-- ── Anchoring ────────────────────────────────────────────────────────────────
-- Set/replace this pane's anchor and snap to it. spec is an anchor table (see
-- anchor.lua). No-op unless the pane is anchorable.
function MuxPane:setAnchor(spec)
    if not self.anchorable then return false end
    self.anchor = spec
    local ok = Mux._applyAnchor(self)
    if self._refreshAnchorBtn then self._refreshAnchorBtn() end
    return ok
end

-- Remove the anchor; the pane becomes a plain floating pane that stays exactly
-- where it is. Its current position persists; no more snap-back.
function MuxPane:removeAnchor()
    self.anchor    = nil
    self._atAnchor = false
    if self._refreshAnchorBtn then self._refreshAnchorBtn() end
    Mux._scheduleAutoSave()
end

-- Re-derive from the anchor and snap back, resuming live tracking. The canonical
-- "return to anchor" used by re-show, double-click, and the context menu.
function MuxPane:returnToAnchor()
    if not self.anchor then return false end
    local ok = Mux._applyAnchor(self)
    if ok then Mux._scheduleAutoSave() end
    if self._refreshAnchorBtn then self._refreshAnchorBtn() end
    return ok
end

function MuxPane:isAnchored() return self.anchor ~= nil end

-- Arm anchor mode for the next titlebar drag: it will anchor (stay floating)
-- instead of insert. Cleared automatically on drag release.
function MuxPane:armAnchorMode(on)
    self._anchorArming = ((on ~= false) and self.anchorable) or false
    if self._refreshAnchorBtn then self._refreshAnchorBtn() end
    if self.titlebar then self.titlebar:setCursor(self:_titlebarCursor()) end
end

-- Single authority for all titlebar button visibility. Called after any state
-- change that could affect what buttons should show. With force=true it always
-- re-applies; without force it skips re-apply when the overflow state is unchanged
-- (safe for per-frame onReposition calls during live handle drags).
function MuxPane:_syncButtons(force)
    if not self.titlebarVisible then return end
    -- During a live handle drag this is called on every reposition frame.
    if Mux._resizing and not force then return end
    local headerW = self.header:get_width()
    -- Skip only unforced (per-frame) calls before the pane is measured. A forced
    -- relayout (setting change, content apply/remove) must proceed even if the header
    -- momentarily reports a tiny width, so compact folding still applies.
    if headerW < 10 and not force then return end

    -- Content-button (re)creation must never abort the titlebar layout below: it runs
    -- content-provided icon/visible functions and creates Geyser widgets, any of which
    -- could error. If it did, the builtins would be left un-folded — e.g. toggling
    -- compact_titlebar while content is applied would leave that pane showing icons
    -- while every other pane switched to the menu. Isolate it so layout always runs.
    pcall(function() self:_syncContentTbButtons() end)

    local theme   = Mux.activeTheme() or {}
    local btnSize = theme.btnSize or 22
    local intraGap, groupGap, edgePad = 4, 8, 2
    local namePad, clusterGap = 6, 6
    local align   = self.nameAlign or "left"
    local nameW   = self:_titlebarNameWidth()
    local btnY    = theme.btnTopMargin or 2
    -- Dialogs (_dialog) always show their controls regardless of compact mode.
    local compact = (not self._dialog) and Mux.settings.get and Mux.settings.get("mux", "compact_titlebar")

    local ctx          = self:_elementCtx()
    local left, right, all = self:_collectTbElements(ctx)   -- visible iconable; no Geyser calls

    -- Any content element with a menu row forces the ⋯ menu to exist and be
    -- reachable by right-click — even when its icon is visible in the bar — so
    -- content settings are always available from the right-click menu.
    local hasMenuExtra = false
    if ctx.content and ctx.content.titlebarElements then
        for _, s in ipairs(ctx.content.titlebarElements) do
            if s.menuText and not BUILTIN_TB_IDS[s.id] and not s.menuFallbackOnly then
                local ok, vis = pcall(s.visible or function() return true end, ctx)
                if ok and vis then hasMenuExtra = true; break end
            end
        end
    end

    -- Overflow: fold the lowest-priority elements into the right-click menu until
    -- the bar fits. close is highest priority among the window/tiling controls so
    -- it folds late; compact folds everything. The menu is reached by right-click.
    local folded = {}
    local function sideW(arr)
        local w, pg = 0, nil
        for _, e in ipairs(arr) do
            if not folded[e.spec.id] then
                if pg then w = w + ((pg ~= e.spec.group) and groupGap or intraGap) end
                w = w + btnSize
                pg = e.spec.group
            end
        end
        return w
    end
    local function fits()
        local lw, rw = sideW(left), sideW(right)
        local need
        if align == "right" then
            need = 6 + lw + clusterGap + nameW + namePad + rw + edgePad + 6
        elseif align == "center" then
            need = 6 + lw + nameW + rw + edgePad + 10
        else
            need = 16 + nameW + 4 + lw + rw + edgePad + 6
        end
        return headerW >= need
    end

    if compact then
        for _, e in ipairs(all) do folded[e.spec.id] = true end
    else
        local i = 1
        while not fits() and i <= #all do
            folded[all[i].spec.id] = true
            i = i + 1
        end
    end
    -- A menu exists when something folded, a menu-only element is present, or compact.
    self._overflowMode = compact or (next(folded) ~= nil) or hasMenuExtra or false

    -- Result signature — nothing visual changes unless the visible/placed set does.
    -- Positions are edge/name anchored (header-width independent), so a drag that
    -- doesn't flip overflow produces the same signature and skips all Geyser work.
    local parts = { align, nameW, btnY }
    local function tag(label, arr)
        parts[#parts + 1] = label
        for _, e in ipairs(arr) do if not folded[e.spec.id] then parts[#parts + 1] = e.spec.id end end
    end
    tag("L", left); tag("R", right)
    local sig = table.concat(parts, ":")
    if not force and sig == self._tbSig then return end
    self._tbSig = sig

    -- Record the folded elements in the menu in the same sequence the icons read
    -- left-to-right across the titlebar: the left cluster in pack order, then the
    -- right cluster reversed (it packs inward from the right edge). One source of
    -- truth for both the icon row and the menu order.
    local foldedSpecs = {}
    for _, e in ipairs(left) do
        if folded[e.spec.id] then foldedSpecs[#foldedSpecs + 1] = e.spec end
    end
    for i = #right, 1, -1 do
        if folded[right[i].spec.id] then foldedSpecs[#foldedSpecs + 1] = right[i].spec end
    end
    self._foldedElements = foldedSpecs

    -- Hide all, then show + place the visible, non-folded set.
    for _, s in ipairs(BUILTIN_TB) do local b = s.get(self); if b then b:hide() end end
    if self._contentTbBtns then for _, b in pairs(self._contentTbBtns) do b.label:hide() end end

    local yPx      = Mux._toPx(btnY)
    local nameSlot = (align == "right") and (namePad + nameW + clusterGap) or 0

    -- Right side: non-folded elements pack leftward from the edge, group gaps
    -- between clusters.
    local acc, pg = edgePad, nil
    for _, e in ipairs(right) do
        if not folded[e.spec.id] then
            if pg and pg ~= e.spec.group then acc = acc + groupGap end
            e.label:move(Mux._fromEdgePx(nameSlot + acc + btnSize), yPx)
            e.label:show()
            if e.spec.id == "anchor" and self._refreshAnchorBtn then self._refreshAnchorBtn() end
            -- Repaint the zoom glyph here too: it only otherwise redraws on hover,
            -- so toggling zoom programmatically left the stale icon showing.
            if e.spec.id == "zoom" and self._zoomBtnEcho then self._zoomBtnEcho(false) end
            acc = acc + btnSize + intraGap
            pg = e.spec.group
        end
    end

    -- Left side: pack rightward, starting just past the name (left-align) or far
    -- left otherwise. group gaps separate clusters (e.g. a content gear from info).
    local x0 = (align == "left") and self:_infoBtnX() or 2
    local lx, lpg = 0, nil
    for _, e in ipairs(left) do
        if not folded[e.spec.id] then
            if lpg and lpg ~= e.spec.group then lx = lx + groupGap end
            e.label:move(x0 + lx, yPx)
            e.label:show()
            lx = lx + btnSize + intraGap
            lpg = e.spec.group
        end
    end
end

function MuxPane:_applyTitlebarVisibility()
    local theme = Mux.activeTheme()
    local bi    = self.bordered and borderInset or 0
    if self.titlebarVisible then
        local h = theme.titlebarHeight
        self.header:resize(nil, Mux._toPx(h))
        self.content:move(nil, Mux._toPx(bi + h))
        self.content:resize(nil, Mux._fromEdgePx(bi))
        self.header:reposition()
        self.content:reposition()
        if self._syncConnScreenGeometry then self:_syncConnScreenGeometry() end
        self.titlebar:show()
        self:_syncButtons(true)
    else
        self.header:resize(nil, "0px")
        self.content:move(nil, Mux._toPx(bi))
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
        if self._contentTbBtns then for _, b in pairs(self._contentTbBtns) do b.label:hide() end end
        if self.anchorBtn  then self.anchorBtn:hide()  end
        if self.addPaneBtn then self.addPaneBtn:hide() end
    end
    -- The content container was just resized to span the reclaimed titlebar space;
    -- force the inner content widget to re-fit (clearing the size cache so the
    -- relayout actually runs), otherwise it keeps its old height and leaves a gap.
    self._lastContentW, self._lastContentH = nil, nil
    if Mux._relayoutContent then
        -- consoleBorders panes drive the native console via setBorderSizes, which can
        -- itself raise sysWindowResizeEvent. Without this guard that handler's
        -- Mux._notifyAllReposition() re-fires every pane's onReposition — including
        -- this one's chained updateConsoleBorders — so a single toggle calls
        -- setBorderSizes (and the console scrollback rewrap it triggers) twice.
        local wasInResize = Mux._inResize
        Mux._inResize = true
        Mux._relayoutContent(self)
        Mux._inResize = wasInResize
        -- The deferred second pass exists for content whose internal geometry needs
        -- a tick to settle after the container resize. The native console has no
        -- such lag — updateConsoleBorders reads self.outer's geometry directly,
        -- already final above — so re-running it here would only add a third
        -- redundant (and expensive) scrollback rewrap.
        if not self.consoleBorders then
            tempTimer(0, function()
                if self and self.content then
                    self._lastContentW, self._lastContentH = nil, nil
                    Mux._relayoutContent(self)
                end
            end)
        end
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
        if self.floating or self.overlay then
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
        if self.floating or self.overlay then
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
    self:_syncButtons()
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
    -- Reset the stylesheet: content authors may have set it transparent, and
    -- since the slot container is now deleted, contentBg is visible again.
    local theme = Mux.activeTheme and Mux.activeTheme() or {}
    self.contentBg:setStyleSheet(theme.contentCss or "")
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
    -- Void guard: floating the only embedded pane would empty the panespace. Overlays
    -- (dialogs) are exempt — they are created to float and never hold the layout.
    if not self.overlay and Mux._isLastEmbeddedPane(self) then
        Mux._log("MuxPane: refusing to float last embedded pane %s", self.id)
        return
    end
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
    -- A pane that spans (nearly) the full panespace in a dimension has almost no
    -- room to travel on that axis once floating — awkward, especially with edge
    -- borders. Shrink any maxed dimension to 70% of its size and re-centre it in
    -- the old span so the resulting float has room to move on that axis.
    do
        local psOuter = self._paneSpace and self._paneSpace.outer
        if psOuter and psOuter.get_width then
            local pw, ph = psOuter:get_width(), psOuter:get_height()
            if pw and pw > 0 and self.floatW >= pw * 0.95 then
                local newW = math.floor(self.floatW * 0.7)
                self.floatX = self.floatX + math.floor((self.floatW - newW) / 2)
                self.floatW = newW
            end
            if ph and ph > 0 and self.floatH >= ph * 0.95 then
                local newH = math.floor(self.floatH * 0.7)
                self.floatY = self.floatY + math.floor((self.floatH - newH) / 2)
                self.floatH = newH
            end
        end
    end
    self.outer:changeContainer(Geyser)
    self.outer:move(self.floatX, self.floatY)
    self.outer:resize(self.floatW, self.floatH)
    self.outer:reposition()
    -- Deep-reflow so Label-nested widgets pick up the new floating size.
    Mux._reflowContent(self)
    self:_applyTitlebarVisibility()   -- floating state now set; _syncButtons(true) inside handles all buttons
    self:raise()
    self.frame:setStyleSheet(self:_baseFrameCss())
    if self.resizable then self:_showCornerHandles() else self:_hideCornerHandles() end
    -- Always leave a ghost slot in the vacated split slot. Ghosts persist until
    -- explicitly dismissed (×) or the pane is closed; they never auto-vanish.
    if self._split then
        -- Clear our child reference in the parent split so collapseSlot sees nil
        -- (ghost-only) rather than a stale floating-pane pointer if the sibling
        -- is later closed before this pane re-embeds.
        if self._slotSide == "a" then self._split.childA = nil
        else                          self._split.childB = nil
        end
        -- Record the home as the ghost's stable key (not the owner-back-reference
        -- model). Survives promotion, so return resolves the live home tile.
        self._homeGhostKey = Mux._createGhostSlot(self._slot, self._split, self._slotSide, self._paneSpace)
        -- Raise ALL floating panes so none are obscured by the new ghost.
        Mux.raiseFloatingPanes()
    end
    if self.onFloat then self.onFloat(self) end
    if not self.overlay then Mux._scheduleAutoSave() end
    if Mux._recomputeAllLocks then Mux._recomputeAllLocks() end
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
    self._homeGhostKey = nil   -- embedded now; no home ghost outstanding
    -- Restore the split box so VBox/HBox layout and resize handle are visible again.
    if not slot and self._split then
        self._split.box:show()
    end
    self.floating = false
    -- Anchoring is a floating-only concept: dropping back into a split clears it
    -- and removes the (floating-only) anchor button.
    self._anchorArming = false
    if self.anchor then self:removeAnchor() end
    if self.anchorBtn then self.anchorBtn:hide() end
    if self.titlebar then self.titlebar:setCursor(self:_titlebarCursor()) end
    self.outer:changeContainer(target)
    self.outer:move("0%", "0%")
    self.outer:resize("100%", "100%")
    self.outer:reposition()
    -- Deep-reflow the content subtree so widgets nested inside Labels pick up the
    -- new embedded size (stock reposition above does not recurse through Labels).
    Mux._reflowContent(self)
    self.frame:setStyleSheet(self:_baseFrameCss())
    self:_hideCornerHandles()
    -- _split may not be wired until split.place() runs after embed(); defer so
    -- _syncButtons sees the final split state when computing min/swap/zoom eligibility.
    tempTimer(0, function()
        if self.titlebar then self:_syncButtons(true) end
        -- Re-reflow once the final embedded geometry has settled (split.place may
        -- run after embed() returns), so the size is the slot's real size.
        Mux._reflowContent(self)
    end)
    if self.onEmbed then self.onEmbed(self) end
    if self._split then self._split:_updateHandleResizability() end
    Mux._scheduleAutoSave()
    if Mux._recomputeAllLocks then Mux._recomputeAllLocks() end
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
    -- Held across the whole operation: this pane briefly becomes p.floating with
    -- stale floatX/floatY (its old pre-zoom position, or none at all). updateConsoleBorders
    -- below calls setBorderSizes, which raises sysWindowResizeEvent; unguarded, that
    -- handler's Mux._notifyAllReposition() would see p.floating and yank the pane from
    -- (0,0) back to those stale floatX/floatY coordinates while it's still sized to fill
    -- the screen — the zoomed pane then drifts off past the screen edge.
    local wasInResize = Mux._inResize
    Mux._inResize = true
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
        tempTimer(0, function() if self.titlebar then self:_syncButtons(true) end end)
    end
    self.outer:move(0, 0)
    self.outer:resize("100%", "100%")
    self.outer:reposition()
    if self.onReposition then self.onReposition(self) end
    Mux._reflowContent(self)
    Mux._inResize = wasInResize
    self._zoomed = true
    -- Raise above everything, then let free floaters come back on top so that
    -- popup dialogs (free floating panes) are never obscured by the zoom.
    self:raise()
    Mux._raiseFreeFloatingPanes()
    Mux._log("MuxPane zoomed: %s", self.id)
end

function MuxPane:_unzoom()
    if not self._zoomed then return end
    local state    = self._preZoomState
    self._zoomed   = false
    self._preZoomState = nil
    -- See the matching guard in zoom(): updateConsoleBorders below calls setBorderSizes,
    -- which raises sysWindowResizeEvent; held so that doesn't cascade into an extra
    -- full-workspace reposition mid-transition.
    local wasInResize = Mux._inResize
    Mux._inResize = true
    if state.wasFloating then
        -- Restore to previous floating position and re-show resize/minimize UI.
        self.outer:move(state.floatX, state.floatY)
        self.outer:resize(state.floatW, state.floatH)
        self.outer:reposition()
        if self.resizable then self:_showCornerHandles() else self:_hideCornerHandles() end
        tempTimer(0, function() if self.titlebar then self:_syncButtons(true) end end)
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
        if self.consoleBorders and self._paneSpace then
            self._paneSpace.outer:show()
        end
        tempTimer(0, function() if self.titlebar then self:_syncButtons(true) end end)
    end
    if self.onReposition then self.onReposition(self) end
    Mux._reflowContent(self)
    Mux._inResize = wasInResize
    Mux.raiseFloatingPanes()
    Mux._log("MuxPane unzoomed: %s", self.id)
end


function MuxPane:raise()
    -- raiseAll on a Container iterates windowList and raises each native child.
    if self.outer and self.outer.raiseAll then self.outer:raiseAll() end
end

function MuxPane:lower()
    if self.outer and self.outer.lowerAll then self.outer:lowerAll() end
end

-- Turn this pane into the console host: transparent click-through frame so the
-- native console shows through the content area, contentBg hidden, and reposition
-- wired to track the borders. Idempotent. Called by the mux_console content's apply
-- (or directly when a pane is constructed with consoleBorders=true).
function MuxPane:_enableConsoleBorders()
    self.consoleBorders = true
    if self.frame then
        self.frame:setStyleSheet([[
            background-color: transparent;
            border: 2px solid rgba(255, 255, 255, 0.38);
            border-radius: 3px;
        ]])
        if enableClickthrough then enableClickthrough(self.frame.name) end
    end
    if self.contentBg then self.contentBg:hide() end
    -- Chain updateConsoleBorders into the reposition chain (every pane already has
    -- an onReposition by construction — line ~253 — so a bare "if not onReposition"
    -- would never wire this, which is why swaps/moves stopped retracking the console
    -- once it became content-driven). The _consoleReposChained guard keeps repeated
    -- applies from stacking the call; updateConsoleBorders self-guards on
    -- self.consoleBorders, so it's inert after the console is released.
    if not self._consoleReposChained then
        self._consoleReposChained = true
        local prev = self.onReposition
        self.onReposition = function(p)
            if prev then prev(p) end
            p:updateConsoleBorders()
        end
    end
end

-- Release the console host: restore the normal frame and contentBg, and hand the
-- native console back to full-window (borders 0). Called by mux_console's remove.
function MuxPane:_disableConsoleBorders()
    self.consoleBorders = false
    if self.frame and self._baseFrameCss then
        self.frame:setStyleSheet(self:_baseFrameCss())
    end
    if disableClickthrough and self.frame then pcall(disableClickthrough, self.frame.name) end
    if self.contentBg then pcall(function() self.contentBg:show() end) end
    if setBorderSizes then setBorderSizes(0, 0, 0, 0) end
end

-- Recalculates setBorderSizes so the Mudlet native console tracks the content area.
-- Called automatically via onReposition for consoleBorders panes.
function MuxPane:updateConsoleBorders()
    if not self.consoleBorders then return end
    local theme = Mux.activeTheme()
    local bi = 2
    local tb = self.titlebarVisible and theme.titlebarHeight or 0
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

-- The capabilities the last remaining embedded pane must surrender so the workspace
-- can never be emptied. Order matches the Permissions tab reading order.
-- When a pane is the only embedded one, several capabilities can't apply. The
-- reasons differ per property — only closeable is really about an empty workspace;
-- the rest are about there being nothing else to act against.
local LAST_PANE_LOCKED = {
    closeable    = "This is the only pane — a workspace can't be empty.",
    convertible  = "Can't float the only pane — the tiled area would be left empty.",
    minimizable  = "Can't minimize the only pane — it would leave empty space with nothing else to show.",
    resizable    = "Nothing to resize against — this is the only pane.",
    movable      = "Nowhere to move it — this is the only pane.",
    swappable    = "Nothing to swap with — this is the only pane.",
}

-- Number of embedded (non-floating) panes currently alive. A floating pane doesn't
-- fill the panespace, so emptiness is measured by embedded count.
function Mux._countEmbeddedPanes()
    local n = 0
    for _, p in pairs(Mux._panes) do
        if not p.floating then n = n + 1 end
    end
    return n
end

-- True when closing/floating `pane` would leave the panespace with no embedded pane.
function Mux._isLastEmbeddedPane(pane)
    return pane and not pane.floating and Mux._countEmbeddedPanes() <= 1
end

-- Rebuild this pane's read-only locks from its two sources: the active content's
-- declared paramLocks, and the last-embedded-pane rule. Content reasons win when a
-- property is locked by both. Drives the Properties read-only display; the actual
-- void-prevention is enforced by hard guards in close()/_detachToFloat().
function MuxPane:_recomputeLocks()
    local locks = {}
    local def = self._activeContent and Mux._content and Mux._content[self._activeContent]
    if def and def.paramLocks then
        for prop, spec in pairs(def.paramLocks) do
            locks[prop] = (type(spec) == "table" and spec.why) or "Set by the active content."
        end
    end
    if Mux._isLastEmbeddedPane(self) then
        for prop, reason in pairs(LAST_PANE_LOCKED) do
            if not locks[prop] then locks[prop] = reason end
        end
    end
    -- State-based locks: some capabilities only apply in one embedding mode. These
    -- DON'T change the stored value — they just show it read-only when inapplicable,
    -- so the setting is visible but can't be toggled where it has no effect.
    if self.floating then
        if not locks.splittable then locks.splittable = "Only applies to embedded panes." end
        if not locks.swappable  then locks.swappable  = "Only applies to embedded panes." end
    else
        if not locks.anchorable then locks.anchorable = "Only applies to floating panes." end
    end
    self._paramLocks = locks
end

-- Reason string if `prop` is read-only for this pane, else nil.
function MuxPane:paramReadonly(prop)
    return self._paramLocks and self._paramLocks[prop] or nil
end

-- Recompute locks for every pane. Called after any change to embedded-pane count
-- (create/close/float/embed) since the last-pane status of the survivor can flip.
function Mux._recomputeAllLocks()
    for _, p in pairs(Mux._panes) do
        if p._recomputeLocks then p:_recomputeLocks() end
    end
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
    if self._zoomed then return false end   -- a zoomed pane can't also be minimized
    if self.floating or self.overlay then return true end
    return self._split ~= nil and self._split.direction == "v"
end

function MuxPane:_titlebarCursor()
    if self._anchorArming then return "Cross" end   -- anchor mode: crosshair to indicate "drop to anchor"
    if self.floating then
        return (self.movable ~= false) and "OpenHand" or "Arrow"
    else
        return (self.convertible ~= false and self.movable ~= false) and "OpenHand" or "Arrow"
    end
end

function MuxPane:_confirmClose()
    if not self.closeable then return end
    if Mux._isLastEmbeddedPane(self) then return end  -- never close the only pane
    if self.overlay then self:close(); return end  -- dialogs: no confirm needed
    if not self.confirmClose then self:close(); return end
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
    -- Void guard, under all circumstances: refuse to close the only embedded pane.
    -- (Teardown/uninstall doesn't route through close(), so this only blocks the user.)
    if Mux._isLastEmbeddedPane(self) then
        Mux._log("MuxPane: refusing to close last embedded pane %s", self.id)
        return
    end
    if self._propertiesDialogs then
        for _, dlg in pairs(self._propertiesDialogs) do
            pcall(function() dlg:close() end)
        end
        self._propertiesDialogs = nil
    end
    Mux._closeContextMenu()
    if Mux.ui and Mux.ui.closeDropdown then Mux.ui.closeDropdown() end
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
        -- Closing a floating pane leaves its home tile as an ownerless empty ghost
        -- that persists until dismissed via its ✕. There is no home-ghost link that
        -- would pull the space back automatically.
        self.outer:hide()
    else
        if self._slot then self._slot:remove(self.outer) end
        self.outer:hide()
        if self._split then self._split:collapseSlot(self._slotSide) end
    end

    if Mux._dropAnchorsReferencing then Mux._dropAnchorsReferencing(self.id) end
    if Mux._deregisterRuleSubject then Mux._deregisterRuleSubject(self) end
    Mux._panes[self.id] = nil
    if self._gid then Mux._tabHosts[self._gid] = nil end
    if self._singletonKey and Mux._singletonDialogs then
        Mux._singletonDialogs[self._singletonKey] = nil
    end
    Mux._freeId(self.id)
    Mux._scheduleAutoSave()
    if Mux._recomputeAllLocks then Mux._recomputeAllLocks() end
    Mux._log("MuxPane closed: %s", self.id)
    if _t0 then
        Mux._echo(string.format("\n<grey>[mux perf] pane destroy %s = %.1fms<reset>\n",
            self.id, (os.clock() - _t0) * 1000))
    end
end

function MuxPane:applyTheme()
    local btnCss = Mux.css("btn", self)
    if self.frame then self.frame:setStyleSheet(self:_baseFrameCss()) end
    if self.contentBg  then self.contentBg:setStyleSheet(Mux.css("content", self))       end
    if self.titlebar   then
        self.titlebar:setStyleSheet(Mux.css("titlebar", self))
        -- Same renderer _refreshTitlebarName uses elsewhere, so a theme switch
        -- doesn't clobber a pane's nameAlign (this used to hard-code a left-aligned
        -- echo here, snapping center/right-aligned names back to left on every
        -- theme change) and picks up the per-pane titlebar.text.color token.
        self:_refreshTitlebarName()
        self:_updateInfoBtnPos()
    end
    -- Restyle + re-echo every titlebar button uniformly by iterating _btnEchos, so
    -- no button (e.g. add-pane) is skipped.
    for _, e in ipairs(self._btnEchos or {}) do
        if e.btn then
            e.btn:setStyleSheet(btnCss)
            if e.echo then e.echo(false) end
        end
    end
    if self.zoomBtn then self.zoomBtn:setStyleSheet(btnCss) end
    -- Anchor button layers active/align rules on top of btnCss.
    if self._refreshAnchorBtn then self._refreshAnchorBtn() end
    if self._cornerHandles then
        local css = Mux.css("cornerHandle", self)
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
            -- Same negative-coordinate guard as the titlebar drag: if a left/top
            -- resize pushes the edge past the screen origin, pin that edge to 0 and
            -- absorb the overshoot into the size so the opposite edge stays put,
            -- rather than letting Geyser read the negative as a from-far-edge jump.
            if pane.floatX < 0 then pane.floatW = pane.floatW + pane.floatX; pane.floatX = 0 end
            if pane.floatY < 0 then pane.floatH = pane.floatH + pane.floatY; pane.floatY = 0 end
            pane.outer:move(pane.floatX, pane.floatY)
            pane.outer:resize(pane.floatW, pane.floatH)
            pane.outer:reposition()
            pane:_syncButtons()
            if pane._tabBarBox then pane:_relayoutTabLabels() end
            if Mux._relayoutContent then Mux._relayoutContent(pane) end
        end)

        lbl:setReleaseCallback(function(event)
            if event.button ~= "LeftButton" then return end
            drag.active = false
            lbl:setStyleSheet(css)
            if pane._atAnchor and Mux._recaptureAlong then Mux._recaptureAlong(pane) end
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
function MuxPane:setBordered(on)
    self.bordered = (on ~= false)
    if self.frame then self.frame:setStyleSheet(self:_baseFrameCss()) end
    -- Update the left/right inset (the visible-state layout only adjusts y/height),
    -- then re-run it for y/height and refit the content.
    local inset = self.bordered and borderInset or 0
    if self.header then
        self.header:move(Mux._toPx(inset), nil)
        self.header:resize(Mux._fromEdgePx(inset), nil)
    end
    if self.content then
        self.content:move(Mux._toPx(inset), nil)
        self.content:resize(Mux._fromEdgePx(inset), nil)
    end
    self:_applyTitlebarVisibility()
    if self.outer then self.outer:reposition() end
    Mux._scheduleAutoSave()
end

function MuxPane:setBorderColor(hex)
    local v = (hex and hex ~= "") and hex or nil
    self.borderColor = v   -- legacy mirror
    Mux.setLocalToken(self, "pane.border.color", v)   -- re-renders the frame
    if self.frame then self.frame:setStyleSheet(self:_baseFrameCss()) end
    Mux._scheduleAutoSave()
end

function MuxPane:_baseFrameCss()
    if not self.bordered then
        return "background-color: transparent; border: none;"
    end
    if self.transparentFrame or self.consoleBorders then
        return string.format("background-color: transparent; border: %spx solid %s; border-radius: %spx;",
            Mux.tok("pane.border.width", self), Mux.tok("pane.border.color", self), Mux.tok("pane.border.radius", self))
    end
    local base = Mux.css("paneOuter", self)
    if self.overlay then base = base .. "\n" .. Mux.css("floatingExtra", self) end
    return base
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

-- The Mudlet main console as registered content. Applied to the (pre-configured,
-- locked) console host pane: apply drives the native console borders and supplies
-- the ⚙ Settings gear as a titlebar element; remove releases the console. Singleton
-- (only one console host). Appears in the Content Library.
Mux.registerContent("mux_console", {
    name        = "Main Console",
    description = "Hosts the Mudlet main console. Embedded only — one per layout.",
    group       = "Muxlet",
    singleton   = true,
    -- The native main console is cropped to this pane via setBorderSizes; it isn't a
    -- Geyser widget that can live inside a tab viewport, so it would paint through any
    -- tab background. Tabs are therefore disallowed on the console's pane.
    noTabs      = true,
    -- The console can't be closed, floated, or moved: it's the native main console
    -- pinned to this pane via setBorderSizes. These set the values AND mark them
    -- read-only in Properties (with the reason on hover); reverted when removed.
    paramLocks = {
        closeable   = { value = false, why = "The Mudlet console can't be closed — remove the console content first." },
        convertible = { value = false, why = "The Mudlet console can't be floated; it must stay embedded." },
        movable     = { value = false, why = "The Mudlet console is embedded and can't be moved." },
    },
    -- Can't be applied to a floating pane (the native console can't float), nor to
    -- a tab (a tab is a sub-surface with a .pane back-reference; the console is
    -- cropped to a pane's content region via border sizes and can't live in a tab
    -- viewport — see noTabs).
    canApply = function(target)
        if target.pane then
            return false, "The console must be embedded directly in a pane, not a tab."
        end
        if target.floating then
            return false, "The console must be embedded — it can't go in a floating pane."
        end
        return true
    end,
    titlebarElements = {
        {
            id="console.settings", side="left", group="console", order=0, priority=110,
            icon="⚙", tooltip="Settings",
            visible=function(_)
                return not (Mux.settings and Mux.settings.get("mux", "showConsoleGear") == false)
            end,
            onClick=function(_, event)
                if not event or event.button == "LeftButton" then Mux.settings.toggle() end
            end,
            menuText="⚙  Settings", menuGroup="info", menuOrder=95,
            run=function(_) Mux.settings.toggle() end,
        },
    },
    apply = function(target)
        -- The content slot covers the content area; keep it transparent and
        -- click-through so the native console shows through and receives input.
        if target._contentSlot then
            pcall(function() target._contentSlot:setStyleSheet("background: transparent; border: none;") end)
            if enableClickthrough then pcall(enableClickthrough, target._contentSlot.name) end
        end
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        if target._enableConsoleBorders then target:_enableConsoleBorders() end
        if target.updateConsoleBorders then target:updateConsoleBorders() end
    end,
    remove = function(target)
        if target._disableConsoleBorders then target:_disableConsoleBorders() end
    end,
    resize = function(target)
        if target.updateConsoleBorders then target:updateConsoleBorders() end
    end,
})

Mux._log("mux_pane loaded")