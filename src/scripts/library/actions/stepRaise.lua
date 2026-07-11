-- Muxlet - Built-in step op: Raise event (Settings → Muxlet → Actions)
Mux.registerActionOp("raise", { label = "Raise event", group = "Game", icon = "📣",
    desc = "Raise a Mudlet event other scripts (or an 'Event fired' condition) can react to.",
    fields = { { key = "event", label = "Event name", kind = "text" } },
    run = function(s) if raiseEvent and s.event and s.event ~= "" then raiseEvent(s.event) end end })
