-- Muxlet - Built-in action: Show pane/tab...
--
-- Explicitly-targeted counterpart to showSelf: needsTarget=true so any picker
-- that supports it (currently the Button Grid's action editor, see
-- library/content/buttons.lua) shows a "Target Pane/Tab" dropdown and resolves
-- it to ctx.pane/tab before run() fires. Unlike showSelf (which acts on
-- whatever pane/tab the rule it's attached to lives on), this acts on a
-- pane/tab picked up front - the only way today to point a button at a
-- specific pane/tab.
Mux.registerAction("mux.showTarget", {
    name = "Show pane/tab…", group = "muxlet", icon = "👁", readOnly = true, needsTarget = true,
    desc = "Show a specific pane or tab, chosen when you bind this action (e.g. to a button).",
    run  = function(ctx) local s = Mux._ruleSubject(ctx); if s and s._conditionShow then s:_conditionShow() end end,
})
