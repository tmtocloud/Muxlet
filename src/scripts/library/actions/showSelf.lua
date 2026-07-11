-- Muxlet - Built-in action: Show
--
-- Dispatches to whichever subject a RULE actually lives on: a tab (ctx.tab) if
-- the rule was added to a tab, else its host pane (ctx.pane) - see
-- Mux._ruleSubject (conditional.lua) and ctxFor, which always sets ctx.pane =
-- the tab's host, so ctx.tab must be checked first.
Mux.registerAction("mux.showSelf", {
    name = "Show", group = "muxlet", icon = "👁", readOnly = true,
    desc = "Show the pane or tab. The default action when a condition becomes true.",
    run  = function(ctx) local s = Mux._ruleSubject(ctx); if s and s._conditionShow then s:_conditionShow() end end,
})
