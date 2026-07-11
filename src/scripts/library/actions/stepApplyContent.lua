-- Muxlet - Built-in step op: Set content of this pane (Settings → Muxlet → Actions)
-- See stepShowPane.lua for the "this pane/tab" note.
Mux.registerActionOp("applyContent", { label = "Set content of this pane", group = "Content", icon = "▦",
    desc = "Replace the content of the pane or tab this action's rule lives on.",
    fields = { { key = "content", label = "Content", kind = "content" } },
    run = function(s, ctx) local subj = Mux._ruleSubject(ctx)
        if subj and s.content and Mux._applyContent then Mux._applyContent(subj, s.content) end end })
