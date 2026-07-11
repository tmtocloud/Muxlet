-- Muxlet - Built-in action: Show "Connecting" overlay
-- See overlayDisconnectedShow.lua for context.
Mux.registerAction("mux.overlay.connecting.show", {
    name = "Show “Connecting” overlay", group = "Connection", icon = "⟳", readOnly = true,
    desc = "Cover this pane/tab with the connecting screen.",
    run = function(ctx) Mux._runOverlay(ctx, "connecting", "connecting", true) end,
})
