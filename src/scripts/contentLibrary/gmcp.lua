-- Muxlet — built-in GMCP content
--
-- Mux.registerGmcpViewer(path)
--   Fixed-path live GMCP viewer registered as a content type.
--
-- "gmcp_inspector" content  /  Mux.gmcpInspect(path [, paneId])
--   Interactive GMCP data visualiser. Data is grouped by type at each
--   hierarchy level. Click ▶/▼ in the body to expand/collapse objects.
--   Click PATH to open the tree browser and select a new watched path.

-- ── Shared colour palette ─────────────────────────────────────────────────────

local HC = {
    key      = "#7ab4ff",
    str      = "#73de94",
    num      = "#f0c060",
    bool_t   = "#73de94",
    bool_f   = "#e06060",
    null     = "rgba(150,160,190,0.65)",
    body_bg  = "rgba(10,14,20,0.96)",
    hdr_bg   = "#101622",
    sep      = "rgba(40,60,85,0.55)",
    chip_obj = "#3d6080",
    chip_arr = "#4a7040",
    chip_bg  = "rgba(25,40,60,0.75)",
}

-- ── Shared helpers ────────────────────────────────────────────────────────────

local function escHtml(s)
    return tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local function isArrayLike(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return false end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end

local function gmcpGet(path)
    local val = gmcp
    for seg in path:gmatch("[^.]+") do
        if type(val) ~= "table" then return nil end
        val = val[seg]
    end
    return val
end

local function tableCount(t)
    if type(t) ~= "table" then return 0 end
    local n = 0; for _ in pairs(t) do n = n + 1 end
    return n
end

-- ════════════════════════════════════════════════════════════════════════════
-- Mux.registerGmcpViewer — fixed-path live GMCP viewer (HTML label)
-- ════════════════════════════════════════════════════════════════════════════

local DEPTH_LIMIT = 6
local ENTRY_LIMIT = 40

local FONT = "'Segoe UI','Helvetica Neue',Arial,sans-serif"

-- A small type badge ("object · 3", "array · 5").
local function kindBadge(kind, n)
    local bg = (kind == "array") and "rgba(74,112,64,0.55)" or "rgba(61,96,128,0.55)"
    return string.format(
        "<span style='background:%s;color:rgba(225,233,247,0.88);font-size:9px;padding:1px 6px;'>%s&#160;&#183;&#160;%d</span>",
        bg, kind, n)
end

-- A single scalar value, colour-coded by type. Booleans get a soft badge.
local function valuePill(val)
    local t = type(val)
    if val == nil then
        return string.format("<span style='color:%s;font-style:italic;'>&#8212;</span>", HC.null)
    elseif t == "boolean" then
        local bg = val and "rgba(60,140,80,0.28)" or "rgba(170,70,70,0.28)"
        return string.format(
            "<span style='background:%s;color:%s;padding:1px 7px;font-weight:600;'>%s</span>",
            bg, val and HC.bool_t or HC.bool_f, tostring(val))
    elseif t == "number" then
        return string.format("<span style='color:%s;font-weight:600;'>%s</span>", HC.num, tostring(val))
    elseif t == "string" then
        local s = escHtml(val)
        if #s > 90 then s = s:sub(1, 87) .. "&#8230;" end
        return string.format("<span style='color:%s;'>%s</span>", HC.str, s)
    end
    return string.format("<span style='color:%s;font-style:italic;'>&lt;%s&gt;</span>", HC.null, t)
end

local renderValue   -- forward declaration (mutual recursion)

-- An array of scalars renders inline as soft comma-separated chips.
local function renderScalarArray(arr)
    local parts = {}
    local total = #arr
    for i = 1, math.min(total, ENTRY_LIMIT) do
        parts[#parts+1] = string.format(
            "<span style='background:rgba(255,255,255,0.05);padding:1px 7px;'>%s</span>", valuePill(arr[i]))
    end
    local sep  = "<span style='color:rgba(120,140,180,0.0);'>&#160;</span>"
    local html = table.concat(parts, sep)
    if total > ENTRY_LIMIT then
        html = html .. string.format(
            "<span style='color:%s;font-style:italic;font-size:10px;'>&#160;&#160;+%d more</span>",
            HC.null, total - ENTRY_LIMIT)
    end
    return "<div style='line-height:20px;'>" .. html .. "</div>"
end

-- An array of objects renders as a stack of indexed cards.
local function renderObjectArray(arr, depth)
    local cards = {}
    local total = #arr
    for i = 1, math.min(total, ENTRY_LIMIT) do
        cards[#cards+1] = string.format(
            "<div style='background:rgba(255,255,255,0.028);border-left:2px solid %s;"
            .. "padding:5px 9px;margin:0 0 4px 0;'>"
            .. "<div style='color:rgba(125,155,195,0.85);font-size:9px;'>#%d</div>%s</div>",
            HC.chip_obj, i, renderValue(arr[i], depth + 1))
    end
    if total > ENTRY_LIMIT then
        cards[#cards+1] = string.format(
            "<div style='color:%s;font-style:italic;font-size:10px;padding:2px 0;'>+%d more</div>",
            HC.null, total - ENTRY_LIMIT)
    end
    return table.concat(cards)
end

-- An object renders as key / value rows; nested objects/arrays indent under their
-- key with a coloured accent bar instead of console tree characters.
local function renderObject(tbl, depth)
    local keys = {}
    for k in pairs(tbl) do keys[#keys+1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local rows  = {}
    local total = #keys
    for i = 1, total do
        if i > ENTRY_LIMIT then
            rows[#rows+1] = string.format(
                "<tr><td colspan='2' style='color:%s;font-style:italic;font-size:10px;padding:3px 0;'>+%d more</td></tr>",
                HC.null, total - ENTRY_LIMIT)
            break
        end
        local k   = keys[i]
        local v   = tbl[k]
        local key = string.format(
            "<span style='color:%s;font-weight:600;'>%s</span>", HC.key, escHtml(tostring(k)))
        if type(v) == "table" then
            local n    = tableCount(v)
            local kind = isArrayLike(v) and "array" or "object"
            local body = ""
            if n > 0 and depth < DEPTH_LIMIT then
                body = string.format(
                    "<div style='margin-top:3px;border-left:2px solid %s;padding-left:11px;'>%s</div>",
                    HC.sep, renderValue(v, depth + 1))
            elseif n > 0 then
                body = string.format("<div style='color:%s;font-style:italic;'>&#8230;</div>", HC.null)
            end
            rows[#rows+1] = string.format(
                "<tr><td valign='top' style='padding:5px 12px 5px 0;white-space:nowrap;'>%s</td>"
                .. "<td valign='top' style='padding:5px 0;'>%s%s</td></tr>",
                key, kindBadge(kind, n), body)
        else
            rows[#rows+1] = string.format(
                "<tr><td valign='top' style='padding:5px 12px 5px 0;white-space:nowrap;'>%s</td>"
                .. "<td valign='top' style='padding:5px 0;'>%s</td></tr>",
                key, valuePill(v))
        end
    end
    return "<table style='width:100%;border-collapse:collapse;'>" .. table.concat(rows) .. "</table>"
end

renderValue = function(val, depth)
    if type(val) ~= "table" then return valuePill(val) end
    if isArrayLike(val) then
        local allScalar = true
        for _, v in ipairs(val) do if type(v) == "table" then allScalar = false; break end end
        return allScalar and renderScalarArray(val) or renderObjectArray(val, depth)
    end
    return renderObject(val, depth)
end

local function buildViewerHtml(path, val)
    local count = type(val) == "table" and tableCount(val) or nil
    local header = string.format(
        "<div style='background:%s;padding:5px 11px;margin-bottom:9px;"
        .. "border-left:3px solid %s;'>"
        .. "<span style='color:rgba(150,170,205,0.65);font-size:10px;'>gmcp.</span>"
        .. "<span style='color:%s;font-size:12px;font-weight:600;'>%s</span>%s</div>",
        HC.chip_bg, HC.key, "#dbe4ff", escHtml(path),
        count and ("&#160;&#160;" .. kindBadge(isArrayLike(val) and "array" or "object", count)) or "")

    local body
    if val == nil then
        body = string.format(
            "<div style='color:%s;font-style:italic;padding:6px 2px;'>Waiting for data at gmcp.%s&#8230;</div>",
            HC.null, escHtml(path))
    elseif type(val) ~= "table" then
        body = "<div style='padding:4px 2px;'>" .. valuePill(val) .. "</div>"
    elseif count == 0 then
        body = string.format("<div style='color:%s;padding:6px 2px;'>(empty)</div>", HC.null)
    else
        body = renderValue(val, 0)
    end

    return string.format(
        "<div style='font-family:%s;font-size:11px;color:#cdd6ee;"
        .. "background:%s;padding:11px 13px;'>%s%s</div>",
        FONT, HC.body_bg, header, body)
end

function Mux.registerGmcpViewer(path)
    assert(type(path) == "string" and path ~= "",
        "registerGmcpViewer: path must be a non-empty string")
    local contentId = "gmcp:" .. path
    local eventName = "gmcp." .. path
    local safePath  = path:gsub("[^%w]", "_")
    Mux.registerContent(contentId, {
        name        = "GMCP: " .. path,
        description = "Live view of gmcp." .. path,
        apply = function(target)
            local lblName    = target.id .. "_gmcpv_" .. safePath
            local lblKey     = "_gmcpvLbl_"     .. safePath
            local handlerKey = "_gmcpvHandler_" .. safePath
            local lbl
            if Geyser.windowList[lblName] then
                lbl = Geyser.windowList[lblName]
                showWindow(lblName)
            else
                lbl = Geyser.Label:new({
                    name = lblName, x = "0%", y = "0%",
                    width = "100%", height = "100%", fillBg = 1,
                }, target.content)
                lbl:setStyleSheet(string.format(
                    "background-color:%s; border:none;", HC.body_bg))
            end
            target[lblKey] = lbl
            local darkCss = string.format("background-color:%s; border:none;", HC.body_bg)
            local function refresh()
                lbl:setStyleSheet(darkCss)            -- re-assert so it can never be left white
                lbl:echo(buildViewerHtml(path, gmcpGet(path)))
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
            if target[lblKey] then hideWindow(target[lblKey].name); target[lblKey] = nil end
        end,
        resize = function(target)
            local lbl = target["_gmcpvLbl_" .. safePath]
            if lbl then
                lbl:setStyleSheet(string.format("background-color:%s; border:none;", HC.body_bg))
                lbl:echo(buildViewerHtml(path, gmcpGet(path)))
            end
        end,
    })
end

-- ════════════════════════════════════════════════════════════════════════════
-- GMCP Inspector — type-grouped interactive widget-tree visualiser
-- ════════════════════════════════════════════════════════════════════════════

local _inspectors   = {}
local INS_DEFAULT   = "char.vitals"
local INS_HDR_H     = 30
local POLL_INTERVAL = 1
local BODY_LIMIT    = 40    -- max items per type group per level
local BROWSER_THRESH_ARR = 10   -- arrays with > this many items hidden in browser
local BROWSER_THRESH_OBJ = 20   -- objects with > this many keys hidden in browser

-- Zoom table: {rowHeight, fontSize} indexed by st.zoomIdx (default = 3)
local ZOOM = {
    {22, 8}, {26, 9}, {30, 10}, {34, 11}, {38, 12}, {42, 13}, {48, 14},
}
local ZOOM_DEFAULT = 3

-- Type group constants — controls sort order and section header display
local TG_OBJECT  = 1
local TG_ARRAY   = 2
local TG_STRING  = 3
local TG_NUMBER  = 4
local TG_BOOLEAN = 5
local TG_OTHER   = 6

local TG_LABEL  = { "OBJECTS", "ARRAYS", "STRINGS", "NUMBERS", "BOOLEANS", "OTHER" }
local TG_ACCENT = {
    "rgba(65,115,215,0.80)",   -- objects
    "rgba(38,155,98,0.75)",    -- arrays
    "rgba(48,155,80,0.65)",    -- strings
    "rgba(195,140,24,0.70)",   -- numbers
    "rgba(48,148,68,0.72)",    -- booleans (true default; overridden per-row for false)
    "rgba(85,92,125,0.50)",    -- other
}
local TG_ICON   = { "{}", "[]", '""', "42", "◉", "?" }

local function typeGroup(v)
    local t = type(v)
    if t == "table" then
        if isArrayLike(v) then return TG_ARRAY else return TG_OBJECT end
    elseif t == "string"  then return TG_STRING
    elseif t == "number"  then return TG_NUMBER
    elseif t == "boolean" then return TG_BOOLEAN
    else                       return TG_OTHER
    end
end

-- Module-level widget counters — reset each insDrawBody call (Lua single-threaded, safe)
local _insEpoch    = 0
local _insSeq      = 0
local _insTargetId = ""

local function nextRowId()
    _insSeq = _insSeq + 1
    return string.format("muxgi_%s_%d_%d_", _insTargetId, _insEpoch, _insSeq)
end

-- ── Section divider ───────────────────────────────────────────────────────────

local DIV_H = 16  -- fixed height; not zoom-scaled

local function addDivider(parent, yOff, group, count, st)
    local id     = nextRowId()
    local accent = TG_ACCENT[group]

    local divBg = Geyser.Label:new({
        name=id.."dvb", x=0, y=yOff, width="100%", height=DIV_H, fillBg=1,
    }, parent)
    divBg:setStyleSheet(
        "background:rgba(7,9,16,0.98);border:none;"
        .. "border-bottom:1px solid rgba(255,255,255,0.05);")
    table.insert(st.rows, divBg)

    local dot = Geyser.Label:new({
        name=id.."dvd", x=8, y=yOff+5, width=6, height=6, fillBg=1,
    }, parent)
    dot:setStyleSheet(string.format(
        "background:%s;border-radius:2px;border:none;", accent))
    table.insert(st.rows, dot)

    local icon = Geyser.Label:new({
        name=id.."dvi", x=20, y=yOff+1, width=20, height=DIV_H-2,
    }, parent)
    icon:setStyleSheet(string.format(
        "background:transparent;color:%s;font-size:8px;font-weight:bold;", accent))
    icon:echo(TG_ICON[group])
    table.insert(st.rows, icon)

    local lbl = Geyser.Label:new({
        name=id.."dvl", x=44, y=yOff+1, width=180, height=DIV_H-2,
    }, parent)
    lbl:setStyleSheet(string.format(
        "background:transparent;color:%s;font-size:8px;font-weight:bold;", accent))
    lbl:echo(string.format('%s  <font color="rgba(80,95,130,0.70)">(%d)</font>',
        TG_LABEL[group], count))
    table.insert(st.rows, lbl)

    return yOff + DIV_H
end

-- ── Body row builder ──────────────────────────────────────────────────────────
-- Children are siblings inside `parent` (bodyContent Label).
-- Returns new yOff after all rows.

local function buildBodyRows(parent, data, path, depth, st, rowH, fontSize, yOff)
    local isArr = isArrayLike(data)
    local iX    = depth * 12  -- indent px per depth level
    local LB    = 3           -- left accent bar width

    -- Collect keys and sort by (type group, alpha)
    local keys = {}
    if isArr then
        for i = 1, #data do keys[i] = i end
    else
        for k in pairs(data) do keys[#keys+1] = k end
        table.sort(keys, function(a, b)
            local ga = typeGroup(data[a])
            local gb = typeGroup(data[b])
            if ga ~= gb then return ga < gb end
            return tostring(a) < tostring(b)
        end)
    end

    -- Count items per type group for section headers
    local groupCount = {}
    for _, k in ipairs(keys) do
        local g = typeGroup(data[k])
        groupCount[g] = (groupCount[g] or 0) + 1
    end
    local hasMultipleGroups = 0
    for _ in pairs(groupCount) do hasMultipleGroups = hasMultipleGroups + 1 end
    hasMultipleGroups = (hasMultipleGroups > 1)

    local lastGroup    = nil
    local groupShown   = {}  -- per-group items shown so far

    for _, k in ipairs(keys) do
        local v         = data[k]
        local childPath = path .. "." .. tostring(k)
        local g         = typeGroup(v)

        -- Insert section divider when type group changes (only if multiple groups)
        if hasMultipleGroups and g ~= lastGroup then
            if groupCount[g] and groupCount[g] > 0 then
                yOff = addDivider(parent, yOff, g, groupCount[g], st)
            end
            lastGroup = g
        end

        groupShown[g] = (groupShown[g] or 0) + 1
        if groupShown[g] > BODY_LIMIT then
            -- "more" notice shown once at group end
            if groupShown[g] == BODY_LIMIT + 1 then
                local mId  = nextRowId() .. "mr"
                local mLbl = Geyser.Label:new({
                    name=mId, x=LB+iX+36, y=yOff+3, width=200, height=rowH-6,
                }, parent)
                mLbl:setStyleSheet(string.format(
                    "background:transparent;color:rgba(130,140,180,0.65);"
                    .. "font-size:%dpx;font-style:italic;", fontSize))
                mLbl:echo(string.format("… +%d more %s",
                    groupCount[g] - BODY_LIMIT, TG_LABEL[g]:lower()))
                table.insert(st.rows, mLbl)
                yOff = yOff + rowH
            end
            -- Skip remaining overflow items
        elseif g == TG_OBJECT or g == TG_ARRAY then
            -- ── Table / object / array row ─────────────────────────────────
            local count      = tableCount(v)
            local isChildArr = (g == TG_ARRAY)
            local isExp      = st.expanded[childPath] or false
            local accentClr  = TG_ACCENT[g]

            local id    = nextRowId()
            local rowBg = Geyser.Label:new({
                name=id.."bg", x=0, y=yOff, width="100%", height=rowH, fillBg=1,
            }, parent)
            rowBg:setStyleSheet(isChildArr
                and "background:rgba(10,28,22,0.95);border:none;"
                    .. "border-bottom:1px solid rgba(255,255,255,0.04);"
                or  "background:rgba(12,18,42,0.95);border:none;"
                    .. "border-bottom:1px solid rgba(255,255,255,0.04);")
            table.insert(st.rows, rowBg)

            -- Accent bar on top of background (created after → higher z)
            local ab = Geyser.Label:new({
                name=id.."ab", x=0, y=yOff, width=LB, height=rowH, fillBg=1,
            }, parent)
            ab:setStyleSheet(string.format("background:%s;border:none;", accentClr))
            table.insert(st.rows, ab)

            -- Expand/collapse toggle
            local toggleCY = yOff + math.floor((rowH - 16) / 2)
            local tog = Geyser.Label:new({
                name=id.."tg", x=LB+iX+2, y=toggleCY, width=18, height=16, fillBg=1,
            }, parent)
            local togBaseCss = string.format(
                "background:transparent;color:rgba(100,150,220,0.85);font-size:%dpx;", fontSize)
            local togHovCss  = string.format(
                "background:rgba(40,72,140,0.35);color:rgba(160,200,255,0.95);"
                .. "font-size:%dpx;border-radius:3px;", fontSize)
            tog:setStyleSheet(togBaseCss)
            tog:echo(isExp and "▼" or "▶")
            table.insert(st.rows, tog)

            local capPath = childPath
            local capSt   = st
            local capTog  = tog
            local capBase = togBaseCss
            local capHov  = togHovCss
            tog:setOnEnter(function() capTog:setStyleSheet(capHov) end)
            tog:setOnLeave(function() capTog:setStyleSheet(capBase) end)
            tog:setClickCallback(function()
                capSt.expanded[capPath] = not capSt.expanded[capPath]
                tempTimer(0, function() insDrawBody(capSt) end)
            end)

            -- Key label
            local keyLbl = Geyser.Label:new({
                name=id.."kl", x=LB+iX+22, y=yOff+3, width=115, height=rowH-6, fillBg=1,
            }, parent)
            keyLbl:setStyleSheet(string.format(
                "background:transparent;color:%s;font-size:%dpx;font-weight:bold;",
                isChildArr and "#73d8a8" or "#8ab4ff", fontSize))
            keyLbl:echo(isArr and string.format("[%d]", k) or escHtml(tostring(k)))
            table.insert(st.rows, keyLbl)

            -- Type badge
            local bdY = yOff + math.floor((rowH - 16) / 2)
            local bd  = Geyser.Label:new({
                name=id.."bd", x=LB+iX+140, y=bdY, width=72, height=16, fillBg=1,
            }, parent)
            bd:setStyleSheet(string.format(
                "background:%s;color:%s;font-size:8px;border-radius:3px;"
                .. "border:1px solid %s;",
                isChildArr and "rgba(20,62,42,0.88)" or "rgba(22,45,85,0.88)",
                isChildArr and "#58a878"              or "#5888c8",
                isChildArr and "rgba(38,122,62,0.45)" or "rgba(42,82,148,0.45)"))
            bd:echo(string.format("<center>%s:%d</center>",
                isChildArr and "[arr" or "{obj", count))
            table.insert(st.rows, bd)

            yOff = yOff + rowH

            if isExp and count > 0 and depth < 8 then
                yOff = buildBodyRows(parent, v, childPath, depth+1, st, rowH, fontSize, yOff)
            end

        elseif g == TG_BOOLEAN then
            -- ── Boolean row ────────────────────────────────────────────────
            local id        = nextRowId()
            local boolTrue  = (v == true)
            local boolAcc   = boolTrue
                and "rgba(45,145,68,0.72)"
                or  "rgba(150,42,42,0.72)"
            local boolBg    = boolTrue
                and "background:rgba(10,28,16,0.95);"
                or  "background:rgba(28,10,10,0.95);"

            local rowBg = Geyser.Label:new({
                name=id.."bg", x=0, y=yOff, width="100%", height=rowH, fillBg=1,
            }, parent)
            rowBg:setStyleSheet(boolBg
                .. "border:none;border-bottom:1px solid rgba(255,255,255,0.04);")
            table.insert(st.rows, rowBg)

            local ab = Geyser.Label:new({
                name=id.."ab", x=0, y=yOff, width=LB, height=rowH, fillBg=1,
            }, parent)
            ab:setStyleSheet(string.format("background:%s;border:none;", boolAcc))
            table.insert(st.rows, ab)

            -- Key
            local keyLbl = Geyser.Label:new({
                name=id.."kl", x=LB+iX+4, y=yOff+3, width=120, height=rowH-6, fillBg=1,
            }, parent)
            keyLbl:setStyleSheet(string.format(
                "background:transparent;color:%s;font-size:%dpx;",
                boolTrue and "rgba(140,195,150,0.85)" or "rgba(190,140,140,0.85)",
                fontSize))
            keyLbl:echo(isArr and string.format("[%d]", k) or escHtml(tostring(k)))
            table.insert(st.rows, keyLbl)

            -- Boolean pill badge
            local pillH = math.min(rowH - 8, 22)
            local pillY = yOff + math.floor((rowH - pillH) / 2)
            local pill  = Geyser.Label:new({
                name=id.."vl", x=LB+iX+128, y=pillY, width=90, height=pillH, fillBg=1,
            }, parent)
            pill:setStyleSheet(string.format(
                "background:%s;color:%s;font-size:10px;font-weight:bold;"
                .. "border-radius:%dpx;border:1px solid %s;",
                boolTrue and "rgba(22,68,36,0.92)" or "rgba(68,18,18,0.92)",
                boolTrue and "#73de94"              or "#e06060",
                math.floor(pillH / 2),
                boolTrue and "rgba(42,125,60,0.55)" or "rgba(138,38,38,0.55)"))
            pill:echo(string.format("<center>%s</center>",
                boolTrue and "✓  TRUE" or "✗  FALSE"))
            table.insert(st.rows, pill)

            yOff = yOff + rowH

        elseif g == TG_NUMBER then
            -- ── Number row ─────────────────────────────────────────────────
            local id    = nextRowId()
            local rowBg = Geyser.Label:new({
                name=id.."bg", x=0, y=yOff, width="100%", height=rowH, fillBg=1,
            }, parent)
            rowBg:setStyleSheet(
                "background:rgba(26,20,8,0.95);border:none;"
                .. "border-bottom:1px solid rgba(255,255,255,0.04);")
            table.insert(st.rows, rowBg)

            local ab = Geyser.Label:new({
                name=id.."ab", x=0, y=yOff, width=LB, height=rowH, fillBg=1,
            }, parent)
            ab:setStyleSheet("background:rgba(195,140,24,0.70);border:none;")
            table.insert(st.rows, ab)

            local keyLbl = Geyser.Label:new({
                name=id.."kl", x=LB+iX+4, y=yOff+3, width=120, height=rowH-6, fillBg=1,
            }, parent)
            keyLbl:setStyleSheet(string.format(
                "background:transparent;color:rgba(195,168,112,0.88);font-size:%dpx;",
                fontSize))
            keyLbl:echo(isArr and string.format("[%d]", k) or escHtml(tostring(k)))
            table.insert(st.rows, keyLbl)

            local numLbl = Geyser.Label:new({
                name=id.."vl", x=LB+iX+128, y=yOff+2, width=140, height=rowH-4, fillBg=1,
            }, parent)
            numLbl:setStyleSheet(string.format(
                "background:transparent;color:#f0c060;font-size:%dpx;font-weight:bold;",
                fontSize + 1))
            numLbl:echo(tostring(v))
            table.insert(st.rows, numLbl)

            yOff = yOff + rowH

        elseif g == TG_STRING then
            -- ── String row ─────────────────────────────────────────────────
            local id    = nextRowId()
            local rowBg = Geyser.Label:new({
                name=id.."bg", x=0, y=yOff, width="100%", height=rowH, fillBg=1,
            }, parent)
            rowBg:setStyleSheet(
                "background:rgba(12,24,16,0.95);border:none;"
                .. "border-bottom:1px solid rgba(255,255,255,0.04);")
            table.insert(st.rows, rowBg)

            local ab = Geyser.Label:new({
                name=id.."ab", x=0, y=yOff, width=LB, height=rowH, fillBg=1,
            }, parent)
            ab:setStyleSheet("background:rgba(48,155,80,0.65);border:none;")
            table.insert(st.rows, ab)

            local keyLbl = Geyser.Label:new({
                name=id.."kl", x=LB+iX+4, y=yOff+3, width=118, height=rowH-6, fillBg=1,
            }, parent)
            keyLbl:setStyleSheet(string.format(
                "background:transparent;color:rgba(148,192,158,0.88);font-size:%dpx;",
                fontSize))
            keyLbl:echo(isArr and string.format("[%d]", k) or escHtml(tostring(k)))
            table.insert(st.rows, keyLbl)

            local s   = v:sub(1, 48)
            if #v > 48 then s = s .. "…" end
            local strH = rowH - 8
            local strY = yOff + 4
            local strLbl = Geyser.Label:new({
                name=id.."vl", x=LB+iX+126, y=strY, width=160, height=strH, fillBg=1,
            }, parent)
            strLbl:setStyleSheet(string.format(
                "background:rgba(22,52,32,0.85);color:#73de94;font-size:%dpx;"
                .. "border-radius:3px;border:1px solid rgba(42,108,60,0.38);padding:0 4px;",
                fontSize))
            strLbl:echo(string.format('"%s"', escHtml(s)))
            table.insert(st.rows, strLbl)

            yOff = yOff + rowH

        else
            -- ── Other / nil row ────────────────────────────────────────────
            local id    = nextRowId()
            local rowBg = Geyser.Label:new({
                name=id.."bg", x=0, y=yOff, width="100%", height=rowH, fillBg=1,
            }, parent)
            rowBg:setStyleSheet(
                "background:rgba(14,14,22,0.95);border:none;"
                .. "border-bottom:1px solid rgba(255,255,255,0.04);")
            table.insert(st.rows, rowBg)

            local ab = Geyser.Label:new({
                name=id.."ab", x=0, y=yOff, width=LB, height=rowH, fillBg=1,
            }, parent)
            ab:setStyleSheet("background:rgba(85,92,125,0.50);border:none;")
            table.insert(st.rows, ab)

            local keyLbl = Geyser.Label:new({
                name=id.."kl", x=LB+iX+4, y=yOff+3, width=120, height=rowH-6, fillBg=1,
            }, parent)
            keyLbl:setStyleSheet(string.format(
                "background:transparent;color:rgba(130,140,175,0.75);font-size:%dpx;",
                fontSize))
            keyLbl:echo(isArr and string.format("[%d]", k) or escHtml(tostring(k)))
            table.insert(st.rows, keyLbl)

            local othLbl = Geyser.Label:new({
                name=id.."vl", x=LB+iX+128, y=yOff+3, width=120, height=rowH-6, fillBg=1,
            }, parent)
            othLbl:setStyleSheet(string.format(
                "background:transparent;color:rgba(130,140,180,0.60);"
                .. "font-size:%dpx;font-style:italic;", fontSize))
            othLbl:echo(v == nil and "null" or ("(" .. type(v) .. ")"))
            table.insert(st.rows, othLbl)

            yOff = yOff + rowH
        end
    end

    return yOff
end

-- ── Body draw ─────────────────────────────────────────────────────────────────

-- Non-local so toggle callbacks in buildBodyRows can reference it by global lookup
insDrawBody = function(st)
    if not st.bodyContent then return end

    -- Recompute content width from the live scrollbox size on every draw so the
    -- body always tracks pane resizes without needing an explicit resize hook call.
    if st.bodyScroll then
        st.contentWidth = math.max(50, st.bodyScroll:get_width())
    end

    for _, r in ipairs(st.rows or {}) do
        if r and r.delete then r:delete() end
    end
    st.rows = {}

    _insEpoch    = _insEpoch + 1
    _insSeq      = 0
    _insTargetId = st.targetId

    local rowH     = ZOOM[st.zoomIdx][1]
    local fontSize = ZOOM[st.zoomIdx][2]
    local content  = st.bodyContent
    local totalH   = 0

    local val = gmcp and gmcpGet(st.path)

    if not gmcp then
        local id  = nextRowId() .. "nd"
        local lbl = Geyser.Label:new({
            name=id, x=12, y=16, width="90%", height=42, fillBg=1,
        }, content)
        lbl:setStyleSheet(
            "background:rgba(18,22,38,0.90);border:1px solid rgba(255,255,255,0.08);"
            .. "border-radius:4px;color:rgba(140,150,190,0.70);font-size:10px;")
        lbl:echo("<center>Not connected — no GMCP data available.</center>")
        table.insert(st.rows, lbl)
        totalH = 80

    elseif val == nil then
        local id  = nextRowId() .. "nv"
        local lbl = Geyser.Label:new({
            name=id, x=12, y=16, width="90%", height=42, fillBg=1,
        }, content)
        lbl:setStyleSheet(
            "background:rgba(18,22,38,0.90);border:1px solid rgba(255,255,255,0.08);"
            .. "border-radius:4px;color:rgba(140,150,190,0.70);font-size:10px;")
        lbl:echo(string.format(
            "<center>No data at gmcp.<b>%s</b></center>", escHtml(st.path)))
        table.insert(st.rows, lbl)
        totalH = 80

    elseif type(val) ~= "table" then
        local t   = type(val)
        local id  = nextRowId() .. "lv"

        if t == "boolean" then
            local bv  = val
            local lbl = Geyser.Label:new({
                name=id, x=16, y=12, width=120, height=28, fillBg=1,
            }, content)
            lbl:setStyleSheet(string.format(
                "background:%s;color:%s;font-size:12px;font-weight:bold;"
                .. "border-radius:14px;border:1px solid %s;",
                bv and "rgba(22,68,36,0.92)" or "rgba(68,18,18,0.92)",
                bv and "#73de94"             or "#e06060",
                bv and "rgba(42,125,60,0.55)" or "rgba(138,38,38,0.55)"))
            lbl:echo(string.format("<center>%s</center>",
                bv and "✓  TRUE" or "✗  FALSE"))
            table.insert(st.rows, lbl)
            totalH = 52

        elseif t == "number" then
            local lbl = Geyser.Label:new({
                name=id, x=16, y=12, width=200, height=28, fillBg=1,
            }, content)
            lbl:setStyleSheet(
                "background:rgba(26,20,8,0.90);color:#f0c060;font-size:14px;"
                .. "font-weight:bold;border-radius:4px;"
                .. "border:1px solid rgba(190,135,22,0.30);padding:0 8px;")
            lbl:echo(tostring(val))
            table.insert(st.rows, lbl)
            totalH = 52

        elseif t == "string" then
            local s   = val:sub(1, 120)
            local lbl = Geyser.Label:new({
                name=id, x=16, y=12, width="90%", height=28, fillBg=1,
            }, content)
            lbl:setStyleSheet(
                "background:rgba(22,52,32,0.88);color:#73de94;font-size:11px;"
                .. "border-radius:4px;border:1px solid rgba(42,108,60,0.42);padding:0 8px;")
            lbl:echo(string.format('"%s"', escHtml(s)))
            table.insert(st.rows, lbl)
            totalH = 52

        else
            local lbl = Geyser.Label:new({
                name=id, x=16, y=12, width=200, height=28,
            }, content)
            lbl:setStyleSheet(
                "background:transparent;color:rgba(140,150,185,0.65);"
                .. "font-size:10px;font-style:italic;")
            lbl:echo(tostring(val))
            table.insert(st.rows, lbl)
            totalH = 52
        end

    else
        totalH = buildBodyRows(content, val, st.path, 0, st, rowH, fontSize, 4)
        totalH = totalH + 10
    end

    -- Keep bodyContent tall enough to fill the ScrollBox viewport so the ScrollBox's
    -- own background never shows through. Use the actual live viewport height instead
    -- of a magic number so the fill tracks the pane size correctly at any dimension.
    local viewportH = (st.bodyScroll and st.bodyScroll:get_height()) or 0
    totalH = math.max(totalH, viewportH > 0 and viewportH or 200)
    content:resize(st.contentWidth, totalH)
end

-- ── Header rendering ──────────────────────────────────────────────────────────

local function insDrawHeader(st)
    if not st.pathLabel then return end

    local theme  = Mux.activeTheme and Mux.activeTheme() or {}
    local btnCss = theme.btnCss or [[
        QLabel {
            background-color: rgba(38,38,52,200);
            border: 1px solid rgba(255,255,255,0.16);
            border-radius: 3px;
            color: rgba(175,175,190,225);
            font-size: 9px;
            font-weight: bold;
        }
        QLabel::hover {
            background-color: rgba(65,65,85,220);
            border-color: rgba(255,255,255,0.38);
            color: white;
        }
    ]]

    -- Path label — styled as interactive (underline-like border on hover handled via CSS hover)
    st.pathLabel:setStyleSheet([[
        QLabel {
            background: rgba(20,28,42,0.85);
            border: 1px solid rgba(100,140,210,0.22);
            border-radius: 3px;
            font-family: monospace;
            font-size: 9px;
            padding: 0 5px;
        }
        QLabel::hover {
            background: rgba(28,42,68,0.92);
            border-color: rgba(120,165,255,0.45);
        }
    ]])
    st.pathLabel:echo(string.format(
        '<font color="#a8c8ff">gmcp.<b>%s</b></font>', escHtml(st.path)))

    if st.paused then
        st.pauseBtn:setStyleSheet([[
            QLabel {
                background-color: rgba(100,70,20,210);
                border: 1px solid rgba(170,120,30,0.55);
                border-radius: 3px;
                color: #f0c060;
                font-size: 9px;
                font-weight: bold;
            }
            QLabel::hover { background-color: rgba(130,90,25,225); }
        ]])
        st.pauseBtn:echo("<center>PAUSED</center>")
    else
        st.pauseBtn:setStyleSheet([[
            QLabel {
                background-color: rgba(20,75,30,210);
                border: 1px solid rgba(40,130,55,0.55);
                border-radius: 3px;
                color: #60c870;
                font-size: 9px;
                font-weight: bold;
            }
            QLabel::hover { background-color: rgba(28,95,38,220); }
        ]])
        st.pauseBtn:echo("<center>LIVE</center>")
    end

    local dimBtn = [[
        QLabel {
            background-color: rgba(28,28,38,140);
            border: 1px solid rgba(255,255,255,0.07);
            border-radius: 3px;
            color: rgba(120,130,160,0.5);
            font-size: 9px;
            font-weight: bold;
        }
    ]]
    st.minusBtn:setStyleSheet(st.zoomIdx <= 1   and dimBtn or btnCss)
    st.minusBtn:echo("<center>−</center>")
    st.plusBtn:setStyleSheet(st.zoomIdx >= #ZOOM and dimBtn or btnCss)
    st.plusBtn:echo("<center>+</center>")
end

local function insRefresh(st)
    insDrawHeader(st)
    insDrawBody(st)
end

-- ── Event / poll binding ──────────────────────────────────────────────────────

local function insBindEvent(st)
    if st.handlerId then killAnonymousEventHandler(st.handlerId); st.handlerId = nil end
    if st.pollTimer  then killTimer(st.pollTimer);                st.pollTimer  = nil end
    if not st.path or st.path == "" or st.paused then return end

    local captured    = st
    local pendingDraw = false

    -- Coalesce back-to-back triggers (event + poll firing together) into one redraw.
    local function scheduleDraw()
        if pendingDraw then return end
        pendingDraw = true
        tempTimer(0.05, function()
            pendingDraw = false
            if captured and not captured.paused then insDrawBody(captured) end
        end)
    end

    -- Exact-path event: fires immediately when the server sends this specific module.
    st.handlerId = registerAnonymousEventHandler("gmcp." .. st.path, function()
        if not captured.paused then scheduleDraw() end
    end)

    -- Poll fallback: catches updates to child paths (watching "Char" when the server
    -- sends "Char.Vitals", "Char.Status" etc.) and any case mismatch between the
    -- registered path name and the server's module name.
    local function poll()
        if not captured.pollTimer then return end  -- stopped by insRemove / insBindEvent
        if not captured.paused then scheduleDraw() end
        captured.pollTimer = tempTimer(POLL_INTERVAL, poll)
    end
    st.pollTimer = tempTimer(POLL_INTERVAL, poll)
end

-- ── Path change ───────────────────────────────────────────────────────────────

local function insSetPath(st, path)
    path = (path or ""):match("^%s*(.-)%s*$"):gsub("^gmcp%.", "")
    if path == "" then return end
    st.path     = path
    st.expanded = {}
    insBindEvent(st)
    insRefresh(st)
end

-- ── GMCP path browser — filtered tree UI ─────────────────────────────────────
--
-- Nodes are hidden when their child count exceeds the type-specific threshold.
-- Arrays:  > BROWSER_THRESH_ARR children → hidden
-- Objects: > BROWSER_THRESH_OBJ children → hidden
-- Leaf values are never shown (browser selects table paths only).
-- First level is auto-expanded on open, as are ancestors of the current path.

local _brEpoch = 0
local _brSeq   = 0
local _brPfx   = ""

local function nextBrId()
    _brSeq = _brSeq + 1
    return string.format("%sbr%d_%d_", _brPfx, _brEpoch, _brSeq)
end

local function insShowPathBrowser(st)
    if st.locked then return end

    local BR_ROW_H = 28
    local HDR_H    = 42
    local SEP_H    = 1
    local dlgW     = 460
    local dlgH     = 440

    local dlg = Mux.createDialog({
        title="GMCP Path Browser", width=dlgW, height=dlgH,
        contextMenu=false,
    })
    if dlg.contentBg then dlg.contentBg:echo(""); dlg.contentBg:hide() end

    local c   = dlg.content
    local pfx = dlg.id .. "_brw_"
    _brPfx    = pfx

    -- Header
    local hdrBg = Geyser.Label:new({
        name=pfx.."hbg", x=0, y=0, width="100%", height=HDR_H,
    }, c)
    hdrBg:setStyleSheet("background:#0e1220;border-bottom:1px solid rgba(255,255,255,0.10);")

    -- Currently-selected path label
    local selLbl = Geyser.Label:new({
        name=pfx.."sl", x=8, y=6, width="56%", height=HDR_H-12,
    }, c)
    selLbl:setStyleSheet(
        "background:rgba(12,20,40,0.92);border:1px solid rgba(70,110,180,0.30);"
        .. "border-radius:3px;font-family:monospace;font-size:9px;"
        .. "color:#a8c8ff;padding:0 5px;")

    local selectBtn = Geyser.Label:new({
        name=pfx.."sb", x="60%", y=6, width="17%", height=HDR_H-12,
    }, c)
    selectBtn:setStyleSheet([[
        QLabel{background:rgba(25,70,42,0.92);color:#73de94;font-size:9px;font-weight:bold;
               border:1px solid rgba(40,115,62,0.55);border-radius:3px;}
        QLabel::hover{background:rgba(35,90,55,0.97);}
    ]])
    selectBtn:echo("<center>✓ SELECT</center>")

    local closeBtn = Geyser.Label:new({
        name=pfx.."cb", x="79%", y=6, width="17%", height=HDR_H-12,
    }, c)
    closeBtn:setStyleSheet([[
        QLabel{background:rgba(72,18,18,0.85);color:#e06060;font-size:9px;font-weight:bold;
               border:1px solid rgba(135,40,40,0.45);border-radius:3px;}
        QLabel::hover{background:rgba(90,25,25,0.95);}
    ]])
    closeBtn:echo("<center>✕ CLOSE</center>")

    -- Hint label
    local hint = Geyser.Label:new({
        name=pfx.."hn", x=8, y=HDR_H-14, width="56%", height=13,
    }, c)
    hint:setStyleSheet(
        "background:transparent;color:rgba(100,115,158,0.75);font-size:8px;")
    hint:echo("Click a row to select · ▶ to expand")

    -- Separator
    local sep = Geyser.Label:new({
        name=pfx.."sp", x=0, y=HDR_H, width="100%", height=SEP_H,
    }, c)
    sep:setStyleSheet("background:rgba(255,255,255,0.10);")

    -- Tree scroll area
    local treeY  = HDR_H + SEP_H
    local treeH  = dlgH - treeY - 26
    local treeSc = Geyser.ScrollBox:new({
        name=pfx.."sc", x=0, y=treeY, width="100%", height=treeH,
    }, c)
    local treeW   = math.max(50, treeSc:get_width() - 17)
    local treeCnt = Geyser.Label:new({
        name=pfx.."tc", x=0, y=0, width=treeW, height=200,
    }, treeSc)
    treeCnt:setStyleSheet("background:rgba(10,12,22,0.97);border:none;")

    -- Browser state
    local brRows     = {}
    local brExpanded = {}
    local currentSel = st.path

    -- Show any table node in the browser — size-based hiding is for the body view only
    local function isBrVisible(val) return type(val) == "table" end

    -- Auto-expand first level and ancestors of current selection
    if type(gmcp) == "table" then
        for k, v in pairs(gmcp) do
            if isBrVisible(v) then brExpanded[tostring(k)] = true end
        end
    end

    -- Expand each prefix segment of currentSel
    local selSegs = {}
    for seg in currentSel:gmatch("[^.]+") do selSegs[#selSegs+1] = seg end
    for i = 1, #selSegs - 1 do
        brExpanded[table.concat(selSegs, ".", 1, i)] = true
    end

    local function updateSelLbl()
        selLbl:echo(string.format(
            '<font color="#a8c8ff">gmcp.<b>%s</b></font>', escHtml(currentSel)))
    end

    -- Build flat row list recursively
    local function buildBrTree(data, segs, depth, rows)
        if type(data) ~= "table" then return end
        local keys = {}
        if isArrayLike(data) then
            for i = 1, #data do keys[i] = i end
        else
            for k in pairs(data) do keys[#keys+1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        end
        for _, k in ipairs(keys) do
            local v = data[k]
            if isBrVisible(v) then
                local childSegs = {}
                for _, s in ipairs(segs) do childSegs[#childSegs+1] = s end
                childSegs[#childSegs+1] = tostring(k)
                local childPath = table.concat(childSegs, ".")
                local count     = tableCount(v)
                local hasKids   = false
                for _, cv in pairs(v) do
                    if isBrVisible(cv) then hasKids = true; break end
                end
                rows[#rows+1] = {
                    key   = tostring(k), path = childPath, segs = childSegs,
                    depth = depth, count = count, data = v,
                    isArr = isArrayLike(v), hasKids = hasKids,
                }
                if brExpanded[childPath] and hasKids then
                    buildBrTree(v, childSegs, depth+1, rows)
                end
            end
        end
    end

    local function redrawBrTree()
        for _, r in ipairs(brRows) do
            if r and r.delete then r:delete() end
        end
        brRows = {}
        _brEpoch = _brEpoch + 1
        _brSeq   = 0

        local rows = {}
        if type(gmcp) == "table" then buildBrTree(gmcp, {}, 0, rows) end

        local yOff = 2

        if #rows == 0 then
            local id  = nextBrId() .. "em"
            local lbl = Geyser.Label:new({
                name=id, x=10, y=12, width=treeW-20, height=56,
            }, treeCnt)
            lbl:setStyleSheet(
                "background:rgba(18,22,38,0.90);border:1px solid rgba(255,255,255,0.08);"
                .. "border-radius:4px;color:rgba(140,150,190,0.70);font-size:10px;")
            lbl:rawEcho("<center>No browsable GMCP paths found.<br/>"
                .. "<font color='rgba(100,115,155,0.75)'>"
                .. "Connect to a server to populate GMCP data.</font></center>")
            table.insert(brRows, lbl)
            treeCnt:resize(treeW, 80)
            return
        end

        for i, row in ipairs(rows) do
            local isEven   = (i % 2 == 0)
            local isSel    = (row.path == currentSel)
            local id       = nextBrId()
            local iX       = row.depth * 14

            local rowBg = Geyser.Label:new({
                name=id.."bg", x=0, y=yOff, width=treeW, height=BR_ROW_H,
            }, treeCnt)
            rowBg:setStyleSheet(isSel
                and "background:rgba(28,52,90,0.95);border:none;"
                    .. "border-bottom:1px solid rgba(70,120,215,0.20);"
                    .. "border-left:3px solid rgba(95,155,255,0.55);"
                or (isEven
                    and "background:rgba(20,23,38,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.04);"
                    or  "background:rgba(15,17,28,0.95);border:none;border-bottom:1px solid rgba(255,255,255,0.04);"))
            table.insert(brRows, rowBg)

            if row.hasKids then
                local isExp = brExpanded[row.path] or false
                local tog   = Geyser.Label:new({
                    name=id.."tg", x=iX+4,
                    y=yOff+math.floor((BR_ROW_H-14)/2), width=14, height=14,
                }, treeCnt)
                tog:setStyleSheet(
                    "background:transparent;color:rgba(100,150,220,0.85);font-size:10px;")
                tog:rawEcho(isExp and "▼" or "▶")
                table.insert(brRows, tog)

                local capPath = row.path
                tog:setClickCallback(function()
                    brExpanded[capPath] = not brExpanded[capPath]
                    tempTimer(0, redrawBrTree)
                end)
            end

            local keyLbl = Geyser.Label:new({
                name=id.."kl", x=iX+20, y=yOff+4, width=170, height=BR_ROW_H-8,
            }, treeCnt)
            keyLbl:setStyleSheet(string.format(
                "background:transparent;color:%s;font-size:10px;%s",
                isSel and "#c4d8ff" or "#a8c4ee",
                isSel and "font-weight:bold;" or ""))
            keyLbl:rawEcho(escHtml(row.key))
            table.insert(brRows, keyLbl)

            -- Type / count badge
            local bdX = iX + 194
            local bd  = Geyser.Label:new({
                name=id.."bd", x=bdX,
                y=yOff+math.floor((BR_ROW_H-16)/2), width=72, height=16,
            }, treeCnt)
            bd:setStyleSheet(string.format(
                "background:%s;color:%s;font-size:8px;border-radius:3px;border:1px solid %s;",
                row.isArr and "rgba(20,62,42,0.85)" or "rgba(22,45,85,0.85)",
                row.isArr and "#58a878"              or "#5888c8",
                row.isArr and "rgba(38,122,62,0.45)" or "rgba(42,82,148,0.45)"))
            bd:rawEcho(string.format("<center>%s:%d</center>",
                row.isArr and "[arr" or "{obj", row.count))
            table.insert(brRows, bd)

            -- Click callbacks — select this path
            local capRowPath = row.path
            local function selectRow()
                currentSel = capRowPath
                updateSelLbl()
                tempTimer(0, redrawBrTree)
            end
            keyLbl:setClickCallback(selectRow)
            bd:setClickCallback(selectRow)
            rowBg:setClickCallback(selectRow)

            yOff = yOff + BR_ROW_H
        end

        treeCnt:resize(treeW, math.max(yOff + 4, treeH))
    end

    selectBtn:setClickCallback(function()
        if currentSel and currentSel ~= "" then insSetPath(st, currentSel) end
        dlg:close()
    end)
    closeBtn:setClickCallback(function() dlg:close() end)

    updateSelLbl()
    dlg:show()
    dlg:raise()
    -- Defer tree draw: treeSc:get_width() returns 0 until Geyser finishes layout
    tempTimer(0.15, function()
        treeW = math.max(200, treeSc:get_width() - 17)
        treeCnt:resize(treeW, 200)
        redrawBrTree()
    end)
end

-- ── Content lifecycle ─────────────────────────────────────────────────────────

local function insApply(target)
    local pfx = "muxgi_" .. target.id .. "_"
    local st  = _inspectors[target.id]

    if target.contentBg then target.contentBg:hide() end

    if st and st.bodyContent then
        for _, w in ipairs(st.widgets) do if w then w:show() end end
        insBindEvent(st)
        tempTimer(0.1, function() insRefresh(st) end)
        return
    end

    local hdrBg = Geyser.Label:new({
        name=pfx.."hbg", x=0, y=0, width="100%", height=INS_HDR_H,
    }, target.content)
    hdrBg:setStyleSheet(string.format(
        "background:%s;border-bottom:1px solid rgba(255,255,255,0.08);", HC.hdr_bg))

    -- Path label is the primary interactive element — click opens the path browser
    local pathLabel = Geyser.Label:new({
        name=pfx.."hpath", x=4, y=4, width="70%", height=INS_HDR_H-8,
    }, target.content)

    -- Pause/Live and zoom buttons — right-justified small controls
    local pauseBtn = Geyser.Label:new({
        name=pfx.."pause", x="-94", y=5, width=54, height=INS_HDR_H-10,
    }, target.content)
    local minusBtn = Geyser.Label:new({
        name=pfx.."minus", x="-36", y=5, width=14, height=INS_HDR_H-10,
    }, target.content)
    local plusBtn = Geyser.Label:new({
        name=pfx.."plus", x="-19", y=5, width=14, height=INS_HDR_H-10,
    }, target.content)

    local bodyScroll = Geyser.ScrollBox:new({
        name=pfx.."bsc", x=0, y=INS_HDR_H, width="100%", height=Mux._fromEdgePx(0),
    }, target.content)
    -- Style the scroll area: suppress horizontal scrollbar so bodyContent can fill
    -- the full width without triggering horizontal scroll when the vertical bar appears.
    -- Vertical bar is styled to a fixed 8px so we know the overlap amount.
    pcall(function()
        bodyScroll:setStyleSheet([[
            background: rgba(10,12,22,0.97); border: none;
            QScrollBar:horizontal { height: 0px; max-height: 0px; }
            QScrollBar:vertical {
                background: rgba(14,18,30,0.95); width: 8px; border: none;
            }
            QScrollBar::handle:vertical {
                background: rgba(70,90,135,0.80); border-radius: 4px; min-height: 16px;
            }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
                height: 0px; border: none;
            }
            QAbstractScrollArea::corner { background: rgba(10,12,22,0.97); }
        ]])
    end)

    -- bodyContent fills the full ScrollBox width; the 8px vertical scrollbar overlaps
    -- only the rightmost 8px of the content (which is fine since rows are left-anchored).
    -- Width is recomputed on every draw so it tracks pane size changes correctly.
    local contentW = math.max(50, bodyScroll:get_width())
    local bodyContent = Geyser.Label:new({
        name=pfx.."bc", x=0, y=0, width=contentW, height=60,
    }, bodyScroll)
    bodyContent:setStyleSheet("background:rgba(10,12,22,0.97);border:none;")

    st = {
        targetId     = target.id,
        path         = INS_DEFAULT,
        paused       = false,
        zoomIdx      = ZOOM_DEFAULT,
        expanded     = {},
        rows         = {},
        handlerId    = nil,
        pollTimer    = nil,
        contentWidth = contentW,
        pathLabel    = pathLabel,
        pauseBtn     = pauseBtn,
        minusBtn     = minusBtn,
        plusBtn      = plusBtn,
        bodyContent  = bodyContent,
        bodyScroll   = bodyScroll,
        widgets      = { hdrBg, pathLabel, pauseBtn, minusBtn, plusBtn, bodyScroll },
    }
    _inspectors[target.id] = st

    pathLabel:setClickCallback(function()
        insShowPathBrowser(st)
    end)

    pauseBtn:setClickCallback(function()
        st.paused = not st.paused
        insBindEvent(st)
        if not st.paused then insDrawBody(st) end
        insDrawHeader(st)
    end)

    minusBtn:setClickCallback(function()
        if st.zoomIdx > 1 then
            st.zoomIdx = st.zoomIdx - 1
            insDrawHeader(st)
            insDrawBody(st)
        end
    end)

    plusBtn:setClickCallback(function()
        if st.zoomIdx < #ZOOM then
            st.zoomIdx = st.zoomIdx + 1
            insDrawHeader(st)
            insDrawBody(st)
        end
    end)

    insBindEvent(st)
    tempTimer(0.1, function() insRefresh(st) end)
end

local function insRemove(target)
    local st = _inspectors[target.id]
    if not st then return end
    if st.handlerId then killAnonymousEventHandler(st.handlerId); st.handlerId = nil end
    if st.pollTimer  then killTimer(st.pollTimer);                st.pollTimer  = nil end
    for _, w in ipairs(st.widgets) do if w then w:hide() end end
    for _, r in ipairs(st.rows or {}) do
        if r and r.delete then r:delete() end
    end
    st.rows = {}
end

Mux.registerContent("gmcp_inspector", {
    name        = "GMCP Inspector",
    description = "Type-grouped interactive visualiser for any GMCP path. "
               .. "Click PATH to browse; − / + to zoom.",
    group       = "Muxlet",
    singleton   = false,
    apply       = insApply,
    remove      = insRemove,
    resize = function(target)
        local st = _inspectors[target.id]
        if not (st and st.bodyScroll) then return end
        insDrawBody(st)
    end,
    serialize = function(target)
        local st = _inspectors[target.id]
        if not st then return nil end
        return { path = st.path, zoomIdx = st.zoomIdx }
    end,
    restore = function(target, data)
        local st = _inspectors[target.id]
        if not (st and data) then return end
        if data.zoomIdx then
            st.zoomIdx = math.max(1, math.min(#ZOOM, data.zoomIdx))
        end
        if data.path and data.path ~= "" then
            insSetPath(st, data.path)
        end
    end,
})

-- ── Public API ────────────────────────────────────────────────────────────────

function Mux.gmcpInspect(path, paneId)
    if not path then
        Mux._log('gmcpInspect: Mux.gmcpInspect("path") — path required')
        return
    end
    if paneId then
        local st = _inspectors[paneId]
        if st then insSetPath(st, path) end
    else
        for _, st in pairs(_inspectors) do
            insSetPath(st, path)
        end
    end
end

Mux._log("content_builtins loaded")