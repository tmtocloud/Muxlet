-- Muxlet - Built-in action: Reconnect
Mux.registerAction("mux.reconnect", {
    name = "Reconnect", group = "Muxlet", icon = "🔌", readOnly = true,
    desc = "Reconnect to the current game server.",
    run = function() reconnect() end,
})
