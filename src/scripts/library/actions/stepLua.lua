-- Muxlet - Built-in step op: Run Lua (Settings → Muxlet → Actions)
-- Advanced escape hatch: write arbitrary Lua, run with the action's ctx
-- (pane/tab/value) available as the vararg. Whatever the code returns becomes
-- this step's output: it's stored in ctx.value for any step after it, and if
-- this is the last (or only) step, it's the whole action's result — see
-- Mux.runAction / buildActionRun.
Mux.registerActionOp("lua", { label = "Run Lua", group = "Advanced", icon = "⚙",
    desc = "Run custom Lua. The action context is the vararg — write: local ctx = ...  "
        .. "then use ctx.pane / ctx.tab / ctx.value. Whatever you `return` becomes this "
        .. "step's output (feeds ctx.value for later steps, and the action's overall result).",
    fields = { { key = "code", label = "Lua code", kind = "lua" } },
    run = function(s, ctx)
        local fn, err = loadstring(s.code or "")
        if not fn then if Mux._warn then Mux._warn("action lua compile: %s", tostring(err)) end return end
        local ok, result = pcall(fn, ctx)
        if not ok then if Mux._warn then Mux._warn("action lua run: %s", tostring(result)) end return end
        return result
    end })
