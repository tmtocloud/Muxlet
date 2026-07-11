-- Muxlet - Built-in action: Hide pane/tab...
-- See showTarget.lua for the needsTarget dispatch note.
Mux.registerAction("mux.hideTarget", {
    name = "Hide pane/tab…", group = "muxlet", icon = "🚫", readOnly = true, needsTarget = true,
    desc = "Hide a specific pane or tab, chosen when you bind this action (e.g. to a button).",
    run  = function(ctx) local s = Mux._ruleSubject(ctx); if s and s._conditionHide then s:_conditionHide() end end,
})
