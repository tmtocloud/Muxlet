-- Muxlet - Built-in step op: Un-zoom this pane (Settings → Muxlet → Actions)
-- See stepShowPane.lua for the "this pane" note. Panes only.
Mux.registerActionOp("unzoomPane", { label = "Un-zoom this pane", group = "Pane", icon = "🔭",
    desc = "Restore the pane this action's rule lives on from zoomed. Panes only.",
    run = function(_, ctx) local p = ctx and ctx.pane; if p and p._unzoom then p:_unzoom() end end })
