-- anchor.lua — native floating-pane anchoring.
--
-- A floating pane may carry an `anchor` spec describing how to derive its
-- position from one or two other panes' edges. While the pane is "at anchor"
-- (pane._atAnchor) it re-derives on every layout change — the reposition cascade
-- calls Mux._reanchorAll(). A plain drag sets _atAnchor=false (a temporary
-- detour) but keeps the spec; pane:returnToAnchor() re-applies and resumes
-- tracking. Anchoring is gated by pane.anchorable and is fully independent of
-- convertible / insertable — nothing ever auto-anchors.
--
--   anchor = {
--     v = { ref=<paneId>, targetEdge="left"|"right", myEdge="left"|"right" }, -- pins X (optional)
--     h = { ref=<paneId>, targetEdge="top"|"bottom",  myEdge="top"|"bottom"  }, -- pins Y (optional)
--     alongV = <0..1>,  -- Y fraction down the target's height when ONLY v is set
--     alongH = <0..1>,  -- X fraction across the target's width when ONLY h is set
--   }
--
-- An edge anchor sets one axis (and stores the free axis as a fraction so it
-- tracks resizes); a corner anchor sets both v and h (each may reference a
-- different pane, which is how the navigator pins its right edge to one pane and
-- its top edge to another).

-- Screen-space edges of a pane by id, or nil if it isn't currently present.
function Mux._paneEdges(id)
    local p = id and Mux.getPane and Mux.getPane(id) or nil
    if not (p and p.outer and p.outer.get_x) then return nil end
    local x, y = p.outer:get_x(), p.outer:get_y()
    local w, h = p.outer:get_width(), p.outer:get_height()
    return { left = x, top = y, right = x + w, bottom = y + h }
end

-- Derive X,Y,W,H from a pane's anchor, or nil if any constrained target is gone.
function Mux._anchorGeom(pane)
    local A = pane and pane.anchor
    if not A then return nil end
    local W = pane.floatW or (pane.outer and pane.outer.get_width and pane.outer:get_width())  or 400
    local H = pane.floatH or (pane.outer and pane.outer.get_height and pane.outer:get_height()) or 300
    local X, Y

    if A.v then
        local e = Mux._paneEdges(A.v.ref); if not e then return nil end
        local line = (A.v.targetEdge == "left") and e.left or e.right
        X = (A.v.myEdge == "left") and line or (line - W)
        if not A.h then
            Y = e.top + (A.alongV or 0) * math.max(0, (e.bottom - e.top) - H)
        end
    end
    if A.h then
        local e = Mux._paneEdges(A.h.ref); if not e then return nil end
        local line = (A.h.targetEdge == "top") and e.top or e.bottom
        Y = (A.h.myEdge == "top") and line or (line - H)
        if not A.v then
            X = e.left + (A.alongH or 0) * math.max(0, (e.right - e.left) - W)
        end
    end

    if not (X and Y) then return nil end
    local sw, sh = getMainWindowSize()
    X = math.max(0, math.min(X, math.max(0, sw - W)))
    Y = math.max(0, math.min(Y, math.max(0, sh - H)))
    return math.floor(X), math.floor(Y), W, H
end

-- Move a pane to its anchored geometry and mark it at-anchor. Returns true if
-- applied (false when there's no anchor or a target is missing).
function Mux._applyAnchor(pane)
    if not (pane and pane.anchor and pane.floating) then return false end
    local X, Y = Mux._anchorGeom(pane)
    if not X then return false end
    pane.floatX, pane.floatY = X, Y
    if pane.outer then pane.outer:move(X, Y); pane.outer:reposition() end
    pane._atAnchor = true
    return true
end

-- Re-derive every pane currently sitting at its anchor. Cheap for the common
-- (unanchored) case; called from the reposition cascade so anchored panes track
-- split drags, resizes, and window changes. A light move() only (no reposition)
-- to stay fast; no recursion since move() doesn't re-enter the cascade.
function Mux._reanchorAll()
    if not Mux._panes then return end
    for _, p in pairs(Mux._panes) do
        if p.anchor and p._atAnchor and p.floating then
            local X, Y = Mux._anchorGeom(p)
            if X and (X ~= p.floatX or Y ~= p.floatY) then
                p.floatX, p.floatY = X, Y
                if p.outer then p.outer:move(X, Y) end
            end
        end
    end
end

-- After a workspace loads, wire saved anchors. Targets are resolved by id from
-- the now-fully-built pane set (ids are preserved across save/load and the
-- embedded tree is restored before floating panes). A missing target drops the
-- anchor, leaving a plain floating pane at its restored position.
function Mux._resolveSavedAnchors()
    if not Mux._panes then return end
    for _, p in pairs(Mux._panes) do
        local A = p._pendingAnchor
        if A then
            p._pendingAnchor = nil
            local ok = (not A.v or Mux._paneEdges(A.v.ref)) and (not A.h or Mux._paneEdges(A.h.ref))
            if ok then
                p.anchor = A
                if p._pendingAtAnchor ~= false then Mux._applyAnchor(p) end
            end
        end
        p._pendingAtAnchor = nil
    end
end

-- ── Graphical anchoring (drag-to-edge/corner) ────────────────────────────────
-- A single overlay rectangle previews where an armed anchor drag would land.
-- Visually distinct (blue dashed) from the insertion ghost.

function Mux._showAnchorIndicator(x, y, w, h)
    if not Mux._anchorInd then
        Mux._anchorInd = Geyser.Label:new(
            { name = "mux_anchor_ind", x = 0, y = 0, width = 10, height = 10 }, Geyser)
    end
    Mux._anchorInd:move(math.floor(x), math.floor(y))
    Mux._anchorInd:resize(math.floor(w), math.floor(h))
    Mux._anchorInd:setStyleSheet(
        "background: rgba(90,200,255,0.12); border: 2px dashed rgba(90,200,255,0.95); border-radius: 3px;")
    Mux._anchorInd:show(); Mux._anchorInd:raise()
end

function Mux._hideAnchorIndicator()
    if Mux._anchorInd then Mux._anchorInd:hide() end
end

-- Given drop-target rects (non-floating panes), the cursor, and the dragged
-- pane's size, return an anchor spec + the preview rect it would occupy, or nil.
-- Docking is flush-OUTSIDE: dragging toward a pane's edge docks the dragged
-- pane just beyond it (its opposite edge flush against that edge). A cursor in
-- a corner region pins both axes to that pane.
function Mux._anchorHitTest(targets, gx, gy, W, H)
    for _, t in ipairs(targets) do
        if gx >= t.x and gx <= t.x + t.w and gy >= t.y and gy <= t.y + t.h then
            local edgeW = Mux._clamp(t.w * 0.20, 30, 80)
            local edgeH = Mux._clamp(t.h * 0.20, 30, 80)
            local nearL = gx <= t.x + edgeW
            local nearR = gx >= t.x + t.w - edgeW
            local nearT = gy <= t.y + edgeH
            local nearB = gy >= t.y + t.h - edgeH
            local id = t.pane.id
            local A
            if (nearL or nearR) and (nearT or nearB) then
                A = {
                    v = { ref = id, targetEdge = nearL and "left" or "right", myEdge = nearL and "right" or "left" },
                    h = { ref = id, targetEdge = nearT and "top"  or "bottom", myEdge = nearT and "bottom" or "top" },
                }
            elseif nearL or nearR then
                local frac = Mux._clamp((gy - t.y - H / 2) / math.max(1, t.h - H), 0, 1)
                A = { v = { ref = id, targetEdge = nearL and "left" or "right", myEdge = nearL and "right" or "left" }, alongV = frac }
            elseif nearT or nearB then
                local frac = Mux._clamp((gx - t.x - W / 2) / math.max(1, t.w - W), 0, 1)
                A = { h = { ref = id, targetEdge = nearT and "top" or "bottom", myEdge = nearT and "bottom" or "top" }, alongH = frac }
            end
            if A then
                local X, Y, w2, h2 = Mux._anchorGeom({ anchor = A, floatW = W, floatH = H, floating = true })
                if X then return A, X, Y, w2, h2 end
            end
            return nil
        end
    end
    return nil
end