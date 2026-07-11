-- Muxlet - Built-in action: Hide "Connecting" overlay
-- See overlayDisconnectedShow.lua for context.
Mux.registerAction("mux.overlay.connecting.hide", {
    name = "Hide “Connecting” overlay", group = "Connection", icon = "⟳", readOnly = true,
    desc = "Remove the connecting overlay.",
    run = function(ctx) Mux._runOverlay(ctx, "connecting", "connecting", false) end,
})
