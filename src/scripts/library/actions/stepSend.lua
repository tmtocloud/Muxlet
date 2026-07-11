-- Muxlet - Built-in step op: Send command (Settings → Muxlet → Actions)
Mux.registerActionOp("send", { label = "Send command", group = "Game", icon = "⌨",
    desc = "Send a command to the game, as if you typed it.",
    fields = { { key = "command", label = "Command", kind = "text" } },
    run = function(s) if send then send(s.command or "") end end })
