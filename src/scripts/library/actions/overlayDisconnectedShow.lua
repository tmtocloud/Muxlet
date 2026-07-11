-- Muxlet - Built-in action: Show "Disconnected" overlay
-- Used by the Connection Awareness rule preset (conditional.lua's
-- _migrateLegacyRules); also available to bind manually. Dispatch logic is
-- Mux._runOverlay (connection.lua), shared across all four overlay actions.
Mux.registerAction("mux.overlay.disconnected.show", {
    name = "Show “Disconnected” overlay", group = "Connection", icon = "⊘", readOnly = true,
    desc = "Cover this pane/tab with the disconnected screen.",
    run = function(ctx) Mux._runOverlay(ctx, "disconnected", "disconnected", true) end,
})
