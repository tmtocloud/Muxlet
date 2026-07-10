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
--     alongV = <px>,  -- Y pixel offset down from the target's top edge when ONLY v is set
--     alongH = <px>,  -- X pixel offset across from the target's left edge when ONLY h is set
--   }
--
-- An edge anchor sets one axis (and stores the free axis as an absolute pixel
-- offset from the target's edge start, so resizing the anchored pane never shifts
-- it along that side); a corner anchor sets both v and h (each may reference a
-- different pane, which is how the navigator pins its right edge to one pane and
-- its top edge to another).

-- Screen-space edges of a pane by id, or of a ghost tile by its key (ghost keys
-- share the internal-id namespace), or nil if neither is currently present.
function Mux._paneEdges(id)
    local p = id and Mux.getPane and Mux.getPane(id) or nil
    if p and p.outer and p.outer.get_x then
        local x, y = p.outer:get_x(), p.outer:get_y()
        local w, h = p.outer:get_width(), p.outer:get_height()
        return { left = x, top = y, right = x + w, bottom = y + h }
    end
    local g = id and Mux._ghostSlots and Mux._ghostSlots[id]
    if g and g.slot and g.slot.get_x then
        local x, y = g.slot:get_x(), g.slot:get_y()
        local w, h = g.slot:get_width(), g.slot:get_height()
        return { left = x, top = y, right = x + w, bottom = y + h }
    end
    return nil
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
            -- alongV is an absolute pixel offset down from the target's top edge,
            -- so resizing the anchored pane never shifts it along the side.
            Y = e.top + (A.alongV or 0)
        end
    end
    if A.h then
        local e = Mux._paneEdges(A.h.ref); if not e then return nil end
        local line = (A.h.targetEdge == "top") and e.top or e.bottom
        Y = (A.h.myEdge == "top") and line or (line - H)
        if not A.v then
            X = e.left + (A.alongH or 0)   -- absolute pixel offset from target's left edge
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
    -- Anchoring moves a floating pane (possibly into the panespace region) without
    -- going through the normal float path; explicitly raise so it stays above
    -- embedded panes. _reanchorAll is called per-frame during drags and must stay
    -- cheap, so the raise belongs here in _applyAnchor only.
    if pane.raise then pane:raise() end
    return true
end

-- Small gap kept between siblings stacked on the same anchor line, so they
-- don't sit flush edge-to-edge.
local ANCHOR_STACK_GAP = 6

-- Key identifying the shared line an edge-anchored pane sits on, plus which
-- axis it's free to slide along that line (its "along" offset). Corner
-- anchors (both v and h set) pin both axes to a fixed point already and have
-- no free axis to stack along, so they're excluded (returns nil).
local function _anchorStackKey(A)
    if A.v and not A.h then return "v|" .. tostring(A.v.ref) .. "|" .. A.v.targetEdge .. "|" .. A.v.myEdge end
    if A.h and not A.v then return "h|" .. tostring(A.h.ref) .. "|" .. A.h.targetEdge .. "|" .. A.h.myEdge end
    return nil
end

-- Re-derive every pane currently sitting at its anchor. Cheap for the common
-- (unanchored) case; called from the reposition cascade so anchored panes track
-- split drags, resizes, and window changes.
--
-- Panes that share an anchor line (same ref/edge/myEdge) are otherwise free to
-- overlap along it, so before moving them each stacking group is swept in
-- preferred-position order: a pane keeps its own saved alongV/alongH unless
-- the sibling ahead of it in that order would overlap it, in which case it's
-- nudged just far enough to clear — respecting the user's placement except
-- where a currently-visible sibling forces a change. Condition-hidden panes
-- are skipped entirely (they occupy no space); becoming visible re-enters this
-- sweep via _reflowConditionLayout.
--
-- A light move() only (no reposition) to stay fast; no recursion since move()
-- doesn't re-enter the cascade.
function Mux._reanchorAll()
    if not Mux._panes then return end
    local sw, sh = getMainWindowSize()
    local groups = {}   -- stackKey → { axis=.., {pane=,x=,y=,w=,h=,pref=}, ... }

    local function applyIfMoved(p, X, Y)
        if X ~= p.floatX or Y ~= p.floatY then
            p.floatX, p.floatY = X, Y
            if p.outer then p.outer:move(X, Y) end
        end
    end

    for _, p in pairs(Mux._panes) do
        if p.anchor and p._atAnchor and p.floating and not p._conditionHidden then
            local X, Y, W, H = Mux._anchorGeom(p)
            if X then
                local key = _anchorStackKey(p.anchor)
                if key then
                    local axis = key:sub(1, 1)
                    local g = groups[key]
                    if not g then g = { axis = axis }; groups[key] = g end
                    g[#g + 1] = { pane = p, x = X, y = Y, w = W, h = H, pref = (axis == "v" and Y or X) }
                else
                    applyIfMoved(p, X, Y)
                end
            end
        end
    end

    for _, g in pairs(groups) do
        table.sort(g, function(a, b) return a.pref < b.pref end)
        local cursor = nil
        for _, e in ipairs(g) do
            local X, Y = e.x, e.y
            if g.axis == "v" then
                Y = cursor and math.max(Y, cursor) or Y
                Y = math.min(Y, math.max(0, sh - e.h))
                cursor = Y + e.h + ANCHOR_STACK_GAP
            else
                X = cursor and math.max(X, cursor) or X
                X = math.min(X, math.max(0, sw - e.w))
                cursor = X + e.w + ANCHOR_STACK_GAP
            end
            applyIfMoved(e.pane, X, Y)
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
            -- ref may be a pane id or a ghost key; _paneEdges resolves either. Ghost
            -- keys regenerate on reload, so a saved ghost anchor simply drops if that
            -- ghost is gone, leaving a plain floating pane.
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

function Mux._showAnchorIndicator(x, y, w, h, corner)
    if not Mux._anchorInd then
        Mux._anchorInd = Geyser.Label:new(
            { name = "mux_anchor_ind", x = 0, y = 0, width = 10, height = 10 }, Geyser)
    end
    Mux._anchorInd:move(math.floor(x), math.floor(y))
    Mux._anchorInd:resize(math.floor(w), math.floor(h))
    if corner then
        -- Corner anchor: same blue dashed rectangle as an edge preview, but the
        -- two edges meeting at the anchoring corner are drawn as bold solid blue
        -- to call out exactly which 90° corner it's pinning to.
        local strong = "3px solid rgba(90,200,255,0.98)"
        local faint  = "2px dashed rgba(90,200,255,0.55)"
        Mux._anchorInd:setStyleSheet(
            "background: rgba(90,200,255,0.12); border-radius: 3px;"
            .. "border-left: "   .. (corner.vx == "left"   and strong or faint) .. ";"
            .. "border-right: "  .. (corner.vx == "right"  and strong or faint) .. ";"
            .. "border-top: "    .. (corner.hy == "top"    and strong or faint) .. ";"
            .. "border-bottom: " .. (corner.hy == "bottom" and strong or faint) .. ";")
    else
        Mux._anchorInd:setStyleSheet(
            "background: rgba(90,200,255,0.12); border: 2px dashed rgba(90,200,255,0.95); border-radius: 3px;")
    end
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
function Mux._anchorHitTest(targets, ghostTargets, gx, gy, W, H)
    -- Shared edge/corner logic for a target rect. `ref` is a pane id or a ghost
    -- key — both resolve through _paneEdges, and the float keeps its own W/H (this
    -- is positional edge anchoring, not a resize-to-fill).
    local function hit(t, ref)
        if not (gx >= t.x and gx <= t.x + t.w and gy >= t.y and gy <= t.y + t.h) then return nil end
        local edgeW = Mux._clamp(t.w * 0.20, 30, 80)
        local edgeH = Mux._clamp(t.h * 0.20, 30, 80)
        local nearL = gx <= t.x + edgeW
        local nearR = gx >= t.x + t.w - edgeW
        local nearT = gy <= t.y + edgeH
        local nearB = gy >= t.y + t.h - edgeH
        local A
        if (nearL or nearR) and (nearT or nearB) then
            A = {
                v = { ref = ref, targetEdge = nearL and "left" or "right", myEdge = nearL and "left" or "right" },
                h = { ref = ref, targetEdge = nearT and "top"  or "bottom", myEdge = nearT and "top"  or "bottom" },
            }
        elseif nearL or nearR then
            local along = Mux._clamp(gy - t.y - H / 2, 0, math.max(0, t.h - H))
            A = { v = { ref = ref, targetEdge = nearL and "left" or "right", myEdge = nearL and "left" or "right" }, alongV = along }
        elseif nearT or nearB then
            local along = Mux._clamp(gx - t.x - W / 2, 0, math.max(0, t.w - W))
            A = { h = { ref = ref, targetEdge = nearT and "top" or "bottom", myEdge = nearT and "top" or "bottom" }, alongH = along }
        end
        if A then
            local X, Y, w2, h2 = Mux._anchorGeom({ anchor = A, floatW = W, floatH = H, floating = true })
            if X then return A, X, Y, w2, h2 end
        end
        return nil
    end

    -- Ghosts take precedence: dropping near a ghost tile's border anchors the float
    -- to that border (the float keeps its size and sits inside the ghost region).
    for _, g in ipairs(ghostTargets or {}) do
        local A, X, Y, w2, h2 = hit(g, g.key)
        if A then return A, X, Y, w2, h2 end
        if gx >= g.x and gx <= g.x + g.w and gy >= g.y and gy <= g.y + g.h then return nil end
    end
    for _, t in ipairs(targets) do
        local A, X, Y, w2, h2 = hit(t, t.pane.id)
        if A then return A, X, Y, w2, h2 end
        if gx >= t.x and gx <= t.x + t.w and gy >= t.y and gy <= t.y + t.h then return nil end
    end
    return nil
end

-- Re-capture an edge anchor's free-axis position from the pane's current screen
-- position. Called after a resize-while-anchored so the remembered position along
-- the side is updated and a later return doesn't jump the pane. Corner anchors
-- (both v and h) pin both axes and need no recapture.
function Mux._recaptureAlong(pane)
    local A = pane and pane.anchor
    if not A then return end
    local x = (pane.outer and pane.outer.get_x and pane.outer:get_x()) or pane.floatX
    local y = (pane.outer and pane.outer.get_y and pane.outer:get_y()) or pane.floatY
    if A.v and not A.h then
        local e = Mux._paneEdges(A.v.ref); if e and y then A.alongV = math.max(0, y - e.top) end
    elseif A.h and not A.v then
        local e = Mux._paneEdges(A.h.ref); if e and x then A.alongH = math.max(0, x - e.left) end
    end
end

-- Drop the anchor on any pane that references `id` (e.g. its anchor target was
-- just closed). The pane keeps its current position but is no longer anchored,
-- so it won't think it's tracking a pane that no longer exists.
function Mux._dropAnchorsReferencing(id)
    if not id or not Mux._panes then return end
    for _, p in pairs(Mux._panes) do
        local A = p.anchor
        if A and ((A.v and A.v.ref == id) or (A.h and A.h.ref == id)) then
            if p.removeAnchor then p:removeAnchor() else p.anchor = nil; p._atAnchor = false end
        end
    end
end