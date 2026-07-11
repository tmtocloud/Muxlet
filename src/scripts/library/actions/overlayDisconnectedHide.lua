-- Muxlet - Built-in action: Hide "Disconnected" overlay
-- See overlayDisconnectedShow.lua for context.
Mux.registerAction("mux.overlay.disconnected.hide", {
    name = "Hide “Disconnected” overlay", group = "Connection", icon = "⊘", readOnly = true,
    desc = "Remove the disconnected overlay.",
    run = function(ctx) Mux._runOverlay(ctx, "disconnected", "disconnected", false) end,
})
