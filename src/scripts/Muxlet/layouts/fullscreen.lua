-- Muxlet — Full-screen workspace
--
-- Covers the entire window with three panes.  Classic MUD workspace:
--
--   ┌──────────────────────┬──────────┐
--   │    Game Output  65%  │          │
--   │                      │ Sidebar  │
--   │         70%          │   30%    │
--   ├──────────────────────┤          │
--   │    Chat / Log  35%   │          │
--   └──────────────────────┴──────────┘
--
-- Pane IDs for attaching content:
--   "output"  — game output (MiniConsole / EMCO)
--   "chat"    — chat / log (MiniConsole / EMCO)
--   "sidebar" — map, gauges, player lists, etc.

Mux.registerWorkspace("fullscreen", {
    name  = "Full Screen",
    theme = "dark",
    paneSets = {
        {
            id   = "screen",
            zone = "screen",
            root = {
                type      = "split",
                direction = "h",
                ratio     = 0.70,
                a = {
                    type      = "split",
                    direction = "v",
                    ratio     = 0.65,
                    a = { type = "pane", id = "output",  name = "Game Output" },
                    b = { type = "pane", id = "chat",    name = "Chat"        },
                },
                b = { type = "pane", id = "sidebar", name = "Sidebar" },
            },
        },
    },
})
