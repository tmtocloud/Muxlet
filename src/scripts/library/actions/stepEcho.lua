-- Muxlet - Built-in step op: Echo to console (Settings → Muxlet → Actions)
Mux.registerActionOp("echo", { label = "Echo to console", group = "Game", icon = "💬",
    desc = "Print a line of text to the main console.",
    fields = { { key = "text", label = "Text", kind = "text" } },
    run = function(s) if cecho then cecho("\n" .. (s.text or "") .. "\n") end end })
