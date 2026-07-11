-- Muxlet - Built-in action: Hide
-- See showSelf.lua for the Mux._ruleSubject dispatch note.
Mux.registerAction("mux.hideSelf", {
    name = "Hide", group = "muxlet", icon = "🚫", readOnly = true,
    desc = "Hide the pane or tab. The default action when a condition becomes false.",
    run  = function(ctx) local s = Mux._ruleSubject(ctx); if s and s._conditionHide then s:_conditionHide() end end,
})
