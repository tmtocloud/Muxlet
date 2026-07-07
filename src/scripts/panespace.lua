-- Muxlet — MuxPaneSpace
--
-- A PaneSpace is a top-level workspace zone that occupies a region relative to
-- Mudlet's main game console. It is the bridge between the tiling tree and
-- Mudlet's border management system.
--
-- Zone types:
--   "left"   — left border; pushes the console right
--   "right"  — right border; pushes the console left
--   "top"    — top border; pushes the console down
--   "bottom" — bottom border; pushes the console up
--   "float"  — free-floating overlay (no border management; explicit geometry)
--
-- Border management uses Mudlet's setBorderSizes(top, right, bottom, left).
-- Mux._borders tracks the current contribution of every PaneSpace.
-- Mux._applyBorders() recomputes and applies the combined value.
--
-- The root of the tiling tree is either:
--   • a single MuxPane  (no splits yet)
--   • a MuxSplit        (at least one split has been made)

MuxPaneSpace = Mux._class()
Mux.PaneSpace = MuxPaneSpace

local minBorderPx = 40   -- prevents the border from collapsing to zero

function MuxPaneSpace:init(opts)
    opts = opts or {}

    if opts.id then Mux._reserveId(opts.id) end
    self.id      = opts.id   or Mux._newId("ps")
    self.zone    = opts.zone or "float"
    self.size    = opts.size or "20%"
    self.visible = false
    self.root    = nil

    local geo = self:_zoneGeometry()
    self.outer = Geyser.Container:new({
        name   = self.id .. "_outer",
        x      = geo.x,
        y      = geo.y,
        width  = geo.width,
        height = geo.height,
    }, Geyser)

    Mux._paneSpaces[self.id] = self
    self:_registerBorder()

    Mux._log("MuxPaneSpace created: %s zone=%s size=%s", self.id, self.zone, self.size)
end

function MuxPaneSpace:_zoneGeometry()
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
        return { x = "0%", y = "0%", width = "100%", height = "100%" }
    else
        return { x = "25%", y = "25%", width = "50%", height = "50%" }
    end
end

function MuxPaneSpace:_registerBorder()
    if self.zone == "float" then return end
    self:_updateBorderContribution()
end

-- "screen" zone: renders over the main console without collapsing it to 0px.
-- Collapsing the console breaks selectCurrentLine()+appendBuffer, which breaks
-- output capture. Instead, the PaneSpace sits in front via Geyser z-order.
function MuxPaneSpace:_updateBorderContribution()
    if self.zone == "float" then return end

    if self.zone == "screen" then
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

function MuxPaneSpace:_onWindowResize()
    self:_updateBorderContribution()
end

-- Place a MuxSplit or MuxPane as the root of this PaneSpace's layout tree.
-- The root's widget is reparented into outer and made to fill it completely.
function MuxPaneSpace:setRoot(child)
    self.root = child
    local widget = child.box or child.outer
    if not widget then
        Mux._err("setRoot: child has no box or outer widget")
        return
    end
    widget:changeContainer(self.outer)
    moveWindow(widget.name, 0, 0)
    resizeWindow(widget.name, self.outer:get_width(), self.outer:get_height())
    Mux._log("MuxPaneSpace.setRoot: %s in %s", child.id, self.id)
end

function MuxPaneSpace:show()
    if self.visible then return end
    self.visible = true
    self.outer:show()
    self:_updateBorderContribution()
    Mux._log("MuxPaneSpace shown: %s", self.id)
end

function MuxPaneSpace:hide()
    if not self.visible then return end
    self.visible = false
    self.outer:hide()
    self:_updateBorderContribution()
    Mux._log("MuxPaneSpace hidden: %s", self.id)
end

function MuxPaneSpace:toggle()
    if self.visible then self:hide() else self:show() end
end

-- newSize: a Geyser constraint string, e.g. "25%" or "300px".
function MuxPaneSpace:resize(newSize)
    self.size = newSize
    local geo = self:_zoneGeometry()
    moveWindow(self.outer.name, 0, 0)
    if self.zone == "left" or self.zone == "right" then
        resizeWindow(self.outer.name, self.outer:get_width(), self.outer:get_height())
    end
    self.outer:move(geo.x, geo.y)
    self.outer:resize(geo.width, geo.height)
    self:_updateBorderContribution()
end

function MuxPaneSpace:destroy()
    self:hide()
    Mux._borders[self.zone] = 0
    Mux._applyBorders()
    self.outer:hide()
    Mux._paneSpaces[self.id] = nil
    Mux._log("MuxPaneSpace destroyed: %s", self.id)
end

Mux._log("panespace loaded")