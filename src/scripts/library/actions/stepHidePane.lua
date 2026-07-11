-- Muxlet - Built-in step op: Hide this pane (Settings → Muxlet → Actions)
-- See stepShowPane.lua for the "this pane/tab" note.
Mux.registerActionOp("hidePane", { label = "Hide this pane", group = "Pane", icon = "🚫",
    desc = "Hide the pane or tab this action's rule lives on.",
    run = function(_, ctx) local s = Mux._ruleSubject(ctx); if s and s._conditionHide then s:_conditionHide() end end })
