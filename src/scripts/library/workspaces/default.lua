-- Muxlet - Built-in workspace: Default
-- The clean Muxlet baseline: a single pane hosting the main console.
Mux.registerWorkspace("default", {
    name     = "Default",
    theme    = "dark",
    paneSpace = {
        id   = "screen",
        zone = "screen",
        root = {
            type            = "pane",
            id              = "output",
            name            = "Mudlet",
            mainConsoleHost = true,
            activeContent   = "mux_console",
        },
    },
})
