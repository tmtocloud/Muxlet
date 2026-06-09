-- Muxlet — Default workspace
-- Single pane covering the entire window.  The native Mudlet game console is
-- displayed inside this pane via setBorderSizes.  Split or float from here.

Mux.registerWorkspace("default", {
    name  = "Default",
    theme = "dark",
    paneSets = {
        {
            id   = "screen",
            zone = "screen",
            root = {
                type            = "pane",
                id              = "output",
                name            = "Main",
                mainConsoleHost = true,
            },
        },
    },
})
