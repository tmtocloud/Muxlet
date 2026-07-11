-- Muxlet - Built-in action: Toggle pane/tab...
--
-- See showTarget.lua for the needsTarget dispatch note. This is the one to use
-- for a button that toggles a pane/tab's visibility.
Mux.registerAction("mux.toggleTarget", {
    name = "Toggle pane/tab…", group = "muxlet", icon = "🔁", readOnly = true, needsTarget = true,
    desc = "Show a specific pane or tab if it's hidden, hide it if it's shown. Pick the "
        .. "target when you bind this action (e.g. to a button) — this is the one to use "
        .. "for a button that toggles a pane/tab.",
    run  = function(ctx)
        local s = Mux._ruleSubject(ctx)
        if not s then return end
        if s._conditionHidden then
            if s._conditionShow then s:_conditionShow() end
        elseif s._conditionHide then
            s:_conditionHide()
        end
    end,
})
