-- Muxlet — MuxPaneSet
--
-- A PaneSet is a top-level workspace that occupies a named zone relative to
-- Mudlet's main game console.  It is the bridge between the tiling tree and
-- Mudlet's border management system.
--
-- Zone types:
--   "left"   — left border; pushes the console right  (setBorderSizes left)
--   "right"  — right border; pushes the console left
--   "top"    — top border; pushes the console down
--   "bottom" — bottom border; pushes the console up
--   "float"  — free-floating overlay (no border management; explicit geometry)
--
-- Border management uses Mudlet's setBorderSizes(top, right, bottom, left).
-- Mux._borders tracks the current contribution of every PaneSet.
-- Mux._applyBorders() recomputes and applies the combined value.
--
-- The root of the tiling tree is either:
--   • a single MuxPane  (no splits yet)
--   • a MuxSplit        (at least one split has been made)
--
-- Example usage:
--   local ps = MuxPaneSet:new({ zone = "left", size = "20%" })
--   ps:setRoot(MuxSplit:new({ direction = "v", ratio = 0.6, parent = ps.outer }))
--   ps:show()

MuxPaneSet = Mux._class()
Mux.PaneSet = MuxPaneSet

-- Minimum size in pixels.  Prevents the border from collapsing to zero.
local minBorderPx = 40

function MuxPaneSet:init(opts)
    opts = opts or {}

    self.id      = opts.id   or Mux._newId("ps")
    self.zone    = opts.zone or "float"   -- "left"|"right"|"top"|"bottom"|"float"
    self.size    = opts.size or "20%"     -- width (left/right) or height (top/bottom)
    self.visible = false   -- starts hidden; call show() or applyLayout() to reveal
    self.root    = nil   -- MuxSplit or MuxPane placed here by the consumer

    -- ── Build outer container ─────────────────────────────────────────────────
    -- Geometry is derived from zone + size.  The outer Container is what gets
    -- shown/hidden when the PaneSet is toggled.
    local geo = self:_zoneGeometry()
    self.outer = Geyser.Container:new({
        name   = self.id .. "_outer",
        x      = geo.x,
        y      = geo.y,
        width  = geo.width,
        height = geo.height,
    }, Geyser)   -- always a child of Geyser root

    -- Register borders
    Mux._paneSets[self.id] = self
    self:_registerBorder()

    Mux._log("MuxPaneSet created: %s zone=%s size=%s", self.id, self.zone, self.size)
end

-- ── Zone geometry ─────────────────────────────────────────────────────────────

function MuxPaneSet:_zoneGeometry()
    local z = self.zone
    local s = self.size
    if z == "left" then
        return { x = "0%", y = "0%", width = s, height = "100%" }
    elseif z == "right" then
        local pct = tonumber(s:match("(%d+)%%")) or 20
        return { x = (100 - pct) .. "%", y = "0%", width = s, height = "100%" }
    elseif z == "top" then
        return { x = "0%", y = "0%", width = "100%", height = s }
    elseif z == "bottom" then
        local pct = tonumber(s:match("(%d+)%%")) or 10
        return { x = "0%", y = (100 - pct) .. "%", width = "100%", height = s }
    elseif z == "screen" then
        -- Covers the entire window; main console is hidden by border management.
        return { x = "0%", y = "0%", width = "100%", height = "100%" }
    else   -- "float" or unknown
        return { x = "25%", y = "25%", width = "50%", height = "50%" }
    end
end

-- ── Border registration ───────────────────────────────────────────────────────

function MuxPaneSet:_registerBorder()
    if self.zone == "float" then return end
    self:_updateBorderContribution()
end

-- Compute this PaneSet's pixel contribution to its border side and update
-- Mux._borders, then call Mux._applyBorders().
--
-- "screen" zone: sets left border = full window width so the main console
-- collapses to 0px wide.  Geyser Labels always render over the main console,
-- so the pane content visually fills the entire window.
-- Intended for full-screen layouts — do not combine with other border zones.
function MuxPaneSet:_updateBorderContribution()
    if self.zone == "float" then return end

    if self.zone == "screen" then
        -- Screen zone visually covers the main console by rendering on top
        -- (PaneSet Geyser objects are created later → higher Qt z-order).
        -- We intentionally do NOT set a left border here: collapsing the main
        -- console to 0px breaks selectCurrentLine()+appendBuffer, preventing
        -- output capture from working.
        Mux._applyBorders()
        return
    end

    local px = 0
    if self.visible then
        if self.zone == "left" or self.zone == "right" then
            px = self.outer:get_width()
        elseif self.zone == "top" or self.zone == "bottom" then
            px = self.outer:get_height()
        end
        px = math.max(px, 0)
    end
    Mux._borders[self.zone] = px
    Mux._applyBorders()
end

-- Called by the global window-resize handler in mux_globals.lua.
function MuxPaneSet:_onWindowResize()
    self:_updateBorderContribution()
end

-- ── Set root ──────────────────────────────────────────────────────────────────
-- Place a MuxSplit or MuxPane as the root of this PaneSet's layout tree.
-- The root's widget is reparented into outer and made to fill it completely.

function MuxPaneSet:setRoot(child)
    self.root = child
    local widget = child.box or child.outer
    if not widget then
        Mux._err("setRoot: child has no box or outer widget")
        return
    end
    widget:changeContainer(self.outer)
    moveWindow(widget.name, 0, 0)
    resizeWindow(widget.name, self.outer:get_width(), self.outer:get_height())
    Mux._log("MuxPaneSet.setRoot: %s in %s", child.id, self.id)
end

-- Convenience: create a single empty pane and set it as root.
-- Returns the MuxPane.
function MuxPaneSet:newRootPane(paneOpts)
    local p = MuxPane:new(Mux._merge(paneOpts or {}, { parent = self.outer }))
    self.root = p
    p._paneSet = self
    return p
end

-- ── Show / hide ───────────────────────────────────────────────────────────────

function MuxPaneSet:show()
    if self.visible then return end
    self.visible = true
    self.outer:show()
    self:_updateBorderContribution()
    Mux._log("MuxPaneSet shown: %s", self.id)
end

function MuxPaneSet:hide()
    if not self.visible then return end
    self.visible = false
    self.outer:hide()
    self:_updateBorderContribution()
    Mux._log("MuxPaneSet hidden: %s", self.id)
end

function MuxPaneSet:toggle()
    if self.visible then self:hide() else self:show() end
end

-- ── Resize ────────────────────────────────────────────────────────────────────
-- Change the size of the PaneSet (its width for left/right, height for top/bottom).
-- newSize: a Geyser constraint string, e.g. "25%" or "300px".

function MuxPaneSet:resize(newSize)
    self.size = newSize
    local geo = self:_zoneGeometry()
    moveWindow(self.outer.name, 0, 0)   -- position stays at zone origin
    if self.zone == "left" or self.zone == "right" then
        resizeWindow(self.outer.name, self.outer:get_width(), self.outer:get_height())
    end
    -- Re-apply geometry via constraint update
    self.outer:move(geo.x, geo.y)
    self.outer:resize(geo.width, geo.height)
    self:_updateBorderContribution()
end

-- ── Destroy ───────────────────────────────────────────────────────────────────

function MuxPaneSet:destroy()
    self:hide()
    Mux._borders[self.zone] = 0
    Mux._applyBorders()
    self.outer:hide()
    Mux._paneSets[self.id] = nil
    Mux._log("MuxPaneSet destroyed: %s", self.id)
end

Mux._log("mux_pane_set loaded")
