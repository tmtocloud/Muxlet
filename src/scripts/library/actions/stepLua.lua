-- Muxlet - Built-in step op: Run Lua (Settings → Muxlet → Actions)
-- Advanced escape hatch: write arbitrary Lua, run with the action's ctx
-- (pane/tab/value) available as the vararg.
Mux.registerActionOp("lua", { label = "Run Lua", group = "Advanced", icon = "⚙",
    desc = "Run custom Lua. The action context is the vararg — write: local ctx = ...  "
        .. "then use ctx.pane / ctx.tab / ctx.value.",
    fields = { { key = "code", label = "Lua code", kind = "lua" } },
    run = function(s, ctx)
        local fn, err = loadstring(s.code or "")
        if not fn then if Mux._warn then Mux._warn("action lua compile: %s", tostring(err)) end return end
        local ok, e2 = pcall(fn, ctx)
        if not ok and Mux._warn then Mux._warn("action lua run: %s", tostring(e2)) end
    end })
