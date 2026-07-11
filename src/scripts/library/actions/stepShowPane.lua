-- Muxlet - Built-in step op: Show this pane (Settings → Muxlet → Actions)
--
-- "This pane/tab" always means the pane or tab that OWNS the rule this action
-- is wired to as Do/Else (see conditional.lua:ctxFor) - never a pane/tab you
-- pick per step. A step that needs an explicit, picked target should use a
-- needsTarget action instead (e.g. mux.toggleTarget), not a step.
Mux.registerActionOp("showPane", { label = "Show this pane", group = "Pane", icon = "👁",
    desc = "Show the pane or tab this action's rule lives on.",
    run = function(_, ctx) local s = Mux._ruleSubject(ctx); if s and s._conditionShow then s:_conditionShow() end end })
