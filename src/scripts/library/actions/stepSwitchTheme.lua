-- Muxlet - Built-in step op: Switch theme (Settings → Muxlet → Actions)
-- Global - doesn't depend on "this pane" (see stepShowPane.lua), so this one
-- works fine from a button too.
Mux.registerActionOp("switchTheme", { label = "Switch theme", group = "Appearance", icon = "🎨",
    desc = "Switch Muxlet's whole UI theme. Global — doesn't depend on 'this pane', so this "
        .. "one works fine from a button too.",
    fields = { { key = "theme", label = "Theme", kind = "theme" } },
    run = function(s)
        if s.theme and Mux.settings and Mux.settings.set then Mux.settings.set("mux", "theme", s.theme) end
    end })
