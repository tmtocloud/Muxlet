-- Muxlet — Demo workspace
-- Two-panel demo showing border zones alongside the main console.
-- Apply with: mux workspace load mux_demo

Mux.registerWorkspace("mux_demo", {
    name  = "Demo",
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
        {
            id   = "left_panel",
            zone = "left",
            size = "22%",
            root = {
                type      = "split",
                direction = "v",
                ratio     = 0.6,
                a = { type = "pane", id = "demo_top",    name = "Top Left"    },
                b = { type = "pane", id = "demo_bottom", name = "Bottom Left" },
            },
        },
        {
            id   = "right_panel",
            zone = "right",
            size = "20%",
            root = { type = "pane", id = "demo_right", name = "Right" },
        },
    },
})
