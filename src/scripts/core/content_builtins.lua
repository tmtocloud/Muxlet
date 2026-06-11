-- Muxlet — GMCP viewer content factory
--
-- Mux.registerGmcpViewer(path)
--   Registers a content type with id "gmcp:<path>" that displays a live,
--   pretty-printed view of whatever value lives at gmcp.<path>.
--   Works with any value type: table, array, string, number, boolean.
--   Refreshes automatically whenever Mudlet fires the "gmcp.<path>" event.
--
-- Example — register a viewer for any GMCP path:
--   Mux.registerGmcpViewer("char.vitals")   → content id "gmcp:char.vitals"
--   Mux.registerGmcpViewer("char.status")   → content id "gmcp:char.status"
--   Mux.registerGmcpViewer("room.info")     → content id "gmcp:room.info"
--
-- Use in a workspace pane definition:
--   { type="pane", id="vitals", name="Vitals", activeContent="gmcp:char.vitals" }

-- ── HTML pretty-printer ───────────────────────────────────────────────────────

local DEPTH_LIMIT = 6

local function escapeHtml(s)
    return tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local function isArrayLike(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local colors = {
    key     = "rgba(200,180,120,0.95)",
    str     = "rgba(140,210,140,0.92)",
    num     = "rgba(150,200,255,0.95)",
    bool_t  = "rgba(100,210,110,0.92)",
    bool_f  = "rgba(210,110,100,0.92)",
    null    = "rgba(130,135,175,0.65)",
    bracket = "rgba(180,185,200,0.70)",
    index   = "rgba(130,150,180,0.70)",
}

local function prettyHtml(val, depth)
    depth = depth or 0
    local t = type(val)
    local indent     = string.rep("&nbsp;&nbsp;&nbsp;&nbsp;", depth)
    local indentInner = string.rep("&nbsp;&nbsp;&nbsp;&nbsp;", depth + 1)

    if val == nil then
        return string.format("<span style='color:%s;font-style:italic;'>nil</span>", colors.null)
    elseif t == "boolean" then
        local c = val and colors.bool_t or colors.bool_f
        return string.format("<span style='color:%s;'>%s</span>", c, tostring(val))
    elseif t == "number" then
        return string.format("<span style='color:%s;'>%s</span>", colors.num, tostring(val))
    elseif t == "string" then
        return string.format("<span style='color:%s;'>&quot;%s&quot;</span>", colors.str, escapeHtml(val))
    elseif t == "table" then
        if depth >= DEPTH_LIMIT then
            return string.format("<span style='color:%s;font-style:italic;'>{…}</span>", colors.bracket)
        end

        if isArrayLike(val) then
            if #val == 0 then
                return string.format("<span style='color:%s;'>[]</span>", colors.bracket)
            end
            local items = {}
            for i, v in ipairs(val) do
                local indexLabel = string.format(
                    "<span style='color:%s;font-size:9px;'>[%d]</span> ", colors.index, i)
                items[#items+1] = indentInner .. indexLabel .. prettyHtml(v, depth + 1)
            end
            return string.format("<span style='color:%s;'>[</span><br>", colors.bracket)
                .. table.concat(items, "<br>")
                .. string.format("<br>%s<span style='color:%s;'>]</span>", indent, colors.bracket)
        else
            local keys = {}
            for k in pairs(val) do keys[#keys+1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            if #keys == 0 then
                return string.format("<span style='color:%s;'>{}</span>", colors.bracket)
            end
            local items = {}
            for _, k in ipairs(keys) do
                local keyHtml = string.format(
                    "<span style='color:%s;font-weight:bold;'>%s</span>: ",
                    colors.key, escapeHtml(tostring(k)))
                items[#items+1] = indentInner .. keyHtml .. prettyHtml(val[k], depth + 1)
            end
            return string.format("<span style='color:%s;'>{</span><br>", colors.bracket)
                .. table.concat(items, "<br>")
                .. string.format("<br>%s<span style='color:%s;'>}</span>", indent, colors.bracket)
        end
    else
        -- userdata, function, thread, etc. — show type only
        return string.format("<span style='color:%s;font-style:italic;'>&lt;%s&gt;</span>",
            colors.null, t)
    end
end

-- ── Path resolver ─────────────────────────────────────────────────────────────

local function gmcpGet(path)
    local val = gmcp
    for seg in path:gmatch("[^.]+") do
        if type(val) ~= "table" then return nil end
        val = val[seg]
    end
    return val
end

-- ── Factory ───────────────────────────────────────────────────────────────────

function Mux.registerGmcpViewer(path)
    assert(type(path) == "string" and path ~= "",
        "registerGmcpViewer: path must be a non-empty string")

    local contentId  = "gmcp:" .. path
    local eventName  = "gmcp." .. path
    -- Safe string to use as part of a widget name (replace non-alphanumeric with _)
    local safePath   = path:gsub("[^%w]", "_")

    Mux.registerContent(contentId, {
        name        = "GMCP: " .. path,
        description = "Live view of gmcp." .. path,

        apply = function(target)
            local lblName     = target.id .. "_gmcpv_" .. safePath
            local lblKey      = "_gmcpvLbl_"     .. safePath
            local handlerKey  = "_gmcpvHandler_" .. safePath

            local lbl
            if Geyser.windowList[lblName] then
                lbl = Geyser.windowList[lblName]
                showWindow(lblName)
            else
                lbl = Geyser.Label:new({
                    name = lblName,
                    x = "0%", y = "0%", width = "100%", height = "100%",
                    fillBg = 1,
                }, target.content)
                lbl:setStyleSheet(
                    "background-color: rgba(14,14,22,0.94); border: none;")
            end
            target[lblKey] = lbl

            local function refresh()
                local val = gmcpGet(path)
                local html
                if val == nil then
                    html = string.format(
                        "<div style='padding:10px;color:rgba(130,135,175,0.7);"
                        .. "font-family:Consolas,Monaco,monospace;font-size:10px;'>"
                        .. "Waiting for gmcp.%s&hellip;</div>", path)
                else
                    html = string.format(
                        "<div style='padding:8px 10px;"
                        .. "font-family:Consolas,Monaco,monospace;font-size:10px;'>"
                        .. "%s</div>",
                        prettyHtml(val))
                end
                lbl:echo(html)
            end

            refresh()
            target[handlerKey] = registerAnonymousEventHandler(eventName, refresh)
            if target.contentBg then target.contentBg:hide() end
        end,

        remove = function(target)
            local lblKey     = "_gmcpvLbl_"     .. safePath
            local handlerKey = "_gmcpvHandler_" .. safePath
            if target[handlerKey] then
                killAnonymousEventHandler(target[handlerKey])
                target[handlerKey] = nil
            end
            if target[lblKey] then
                hideWindow(target[lblKey].name)
                target[lblKey] = nil
            end
        end,
    })
end

-- ── Built-in registrations ────────────────────────────────────────────────────
-- Deferred so all packages have loaded before registering.
tempTimer(0.05, function()
    Mux.registerGmcpViewer("char.vitals")
    Mux.registerGmcpViewer("room.info")
end)

Mux._log("content_builtins loaded")
