-- Muxlet - Built-in step op: Remove this pane (Settings → Muxlet → Actions)
-- See stepShowPane.lua for the "this pane" note. Panes only, and not reversible.
Mux.registerActionOp("removePane", { label = "Remove this pane", group = "Pane", icon = "✖",
    desc = "Close the pane this action's rule lives on. Panes only, and not reversible.",
    run = function(_, ctx) local p = ctx and ctx.pane; if p and p.close then p:close() end end })
