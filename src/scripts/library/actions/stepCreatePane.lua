-- Muxlet - Built-in step op: Create pane with content (Settings → Muxlet → Actions)
-- See stepShowPane.lua for the "this pane" note.
Mux.registerActionOp("createPane", { label = "Create pane with content", group = "Content", icon = "➕",
    desc = "Split this pane and put the chosen content in the new one.",
    fields = {
        { key = "content",   label = "Content",   kind = "content" },
        { key = "direction", label = "Direction", kind = "choice",
          options = { { value = "v", label = "Right" }, { value = "h", label = "Below" } } },
    },
    run = function(s, ctx)
        local p = ctx and ctx.pane; if not (p and p.split) then return end
        local ns = p:split(s.direction or "v")
        if ns and ns.childB and s.content then
            tempTimer(0, function() pcall(Mux._applyContent, ns.childB, s.content) end)
        end
    end })
