-- Muxlet - Built-in step op: Zoom this pane (Settings → Muxlet → Actions)
-- See stepShowPane.lua for the "this pane" note. Panes only (tabs have no zoom).
Mux.registerActionOp("zoomPane", { label = "Zoom this pane", group = "Pane", icon = "🔍",
    desc = "Zoom the pane this action's rule lives on. Panes only (tabs have no zoom).",
    run = function(_, ctx) local p = ctx and ctx.pane; if p and p.zoom then p:zoom() end end })
