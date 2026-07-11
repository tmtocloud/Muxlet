-- Muxlet - Built-in action: Clear Console
Mux.registerAction("mux.clearConsole", {
    name = "Clear Console", group = "Muxlet", icon = "🧹", readOnly = true,
    desc = "Clear the main console window.",
    run = function() clearWindow() end,
})
