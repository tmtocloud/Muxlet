-- Muxlet — MDK Integration
--
-- The Mudlet Developer Kit (MDK) by demonnic provides polished UI components
-- that fit naturally into MuxPane content areas.  This module:
--
--   1. Detects which MDK components are available as globals after package load.
--   2. Provides factory functions that create a MuxPane pre-wired with the
--      appropriate MDK widget filling pane.content.
--   3. Falls back gracefully when MDK is not installed.
--
-- MDK components used and why:
--
--   EMCO (Enhanced Multi-Console Object)
--     The gold standard for tabbed consoles in Mudlet.  It extends
--     Geyser.Container so EMCO:new(opts, pane.content) works directly.
--     Use for: chat tabs, game output, any tabbed multi-channel view.
--
--   LoggingConsole
--     Extends Geyser.MiniConsole with transparent disk logging (HTML/text/ANSI).
--     Identical API to MiniConsole; swap in for any console pane where you want
--     session logs.  Falls back to plain MiniConsole if MDK unavailable.
--
--   SortBox
--     Extends Geyser.Container.  Auto-organises its children using pluggable
--     sort functions (by gauge value, timer, name, message text).
--     Use for: player lists, timer panels, ranked leaderboards.
--
--   Chyron
--     Extends Geyser.Label.  Scrolling marquee text at configurable speed.
--     Use for: status tickers, notification strips, info banners.
--
--   TimerGauge
--     Extends Geyser.Gauge.  Animated countdown with auto-hide and finish hook.
--     Use for: cooldown displays, countdown timers, activity gauges.
--
--   TextGauge
--     Plain Lua table (no Geyser parent); returns a formatted string.
--     Caller echoes the result to a Label or MiniConsole.
--     Use for: compact health/status bars inside a Label pane.
--
--   Checkbox / Spinbox
--     Both extend Geyser.Container.  Good for settings panels inside a pane.
--
-- Detection is deferred to first use (tempTimer 0) so MDK packages have time
-- to load before we inspect globals.

Mux.mdk = Mux.mdk or {}

-- ── Detection (deferred) ──────────────────────────────────────────────────────

local function detect()
    Mux.mdk.hasEmco       = (type(EMCO)           == "table")
    Mux.mdk.hasLoggingCon = (type(LoggingConsole) == "table")
    Mux.mdk.hasSortbox    = (type(SortBox)        == "table")
    Mux.mdk.hasChyron     = (type(Chyron)         == "table")
    Mux.mdk.hasTimergauge = (type(TimerGauge)     == "table")
    Mux.mdk.hasTextgauge  = (type(TextGauge)      == "table")
    Mux.mdk.hasCheckbox   = (type(checkbox)       == "table")
    Mux.mdk.hasSpinbox    = (type(spinbox)        == "table")
    Mux.mdk._detected = true
    Mux._log("MDK detection complete")
end
-- Run after all packages finish loading.
tempTimer(0, detect)

-- ── Factory helpers ───────────────────────────────────────────────────────────

-- Ensure detection has run before creating MDK widgets.
local function ensureDetected()
    if not Mux.mdk._detected then detect() end
end

-- ── Console pane ──────────────────────────────────────────────────────────────
-- Creates a MuxPane whose content area contains a LoggingConsole (or plain
-- MiniConsole when LoggingConsole is unavailable).
--
-- Returned pane has:   pane.console  — the console widget
--
-- opts (pane opts + extras):
--   fontSize   (number)   — font size, default 12
--   scrollBar  (boolean)  — show scrollbar, default true
--   autoWrap   (boolean)  — word-wrap, default true
--   log        (boolean)  — enable disk logging (LoggingConsole only), default true
--   logFormat  (string)   — "h" HTML / "t" plaintext / "l" ANSI, default "h"
--   logPath    (string)   — path template, default MDK default
--   logFile    (string)   — filename template, default MDK default

function Mux.newConsolePane(opts)
    ensureDetected()
    opts = opts or {}
    local p = Mux.newPane(opts)

    local conOpts = {
        name      = p.id .. "_console",
        x         = "0%", y = "0%", width = "100%", height = "100%",
        fontSize  = opts.fontSize or 12,
        scrollBar = opts.scrollBar ~= false,
        autoWrap  = opts.autoWrap  ~= false,
        color     = "black",
    }

    if Mux.mdk.hasLoggingCon then
        if opts.log          ~= nil  then conOpts.log       = opts.log        end
        if opts.logFormat             then conOpts.logFormat = opts.logFormat  end
        if opts.logPath               then conOpts.path      = opts.logPath    end
        if opts.logFile               then conOpts.fileName  = opts.logFile    end
        p.console = LoggingConsole:new(conOpts, p.content)
    else
        Mux._log("newConsolePane: LoggingConsole not found — using MiniConsole")
        p.console = Geyser.MiniConsole:new(conOpts, p.content)
    end
    return p
end

-- ── EMCO (tabbed console) pane ────────────────────────────────────────────────
-- Creates a MuxPane whose content area contains an EMCO tabbed console.
--
-- Returned pane has:   pane.emco  — the EMCO instance
--
-- opts (pane opts + extras):
--   consoles    (table)    — tab names, e.g. {"Chat","System"}, default {"Main"}
--   fontSize    (number)   — console font size, default 12
--   tabHeight   (number)   — tab bar height, default 20
--   gap         (number)   — gap between tabs and console, default 2
--   timestamp   (boolean)  — show timestamps, default false
--   allTab      (boolean)  — add an "All" aggregator tab, default false
--   blink       (boolean)  — blink inactive tabs on new content, default true
--   mapTab      (boolean)  — one tab is a Mapper, default false
--   mapTabName  (string)   — name of the mapper tab, default "Map"
--   emco_opts   (table)    — merged verbatim into the EMCO constructor

function Mux.newEmcoPane(opts)
    ensureDetected()
    opts = opts or {}
    local p = Mux.newPane(opts)

    if not Mux.mdk.hasEmco then
        Mux._warn("newEmcoPane: EMCO not available — using plain MiniConsole")
        p.console = Geyser.MiniConsole:new({
            name="p"..p.id.."_con", x="0%",y="0%",width="100%",height="100%",
            fontSize=12, autoWrap=true, scrollBar=true, color="black",
        }, p.content)
        return p
    end

    local emcoOpts = Mux._merge({
        name       = p.id .. "_emco",
        x          = "0%", y = "0%", width = "100%", height = "100%",
        consoles   = opts.consoles   or {"Main"},
        fontSize   = opts.fontSize   or 12,
        tabHeight  = opts.tabHeight  or 20,
        gap        = opts.gap        or 2,
        timestamp  = opts.timestamp  or false,
        allTab     = opts.allTab     or false,
        blink      = (opts.blink ~= false),
        mapTab     = opts.mapTab     or false,
        mapTabName = opts.mapTabName or "Map",
    }, opts.emco_opts or {})

    p.emco = EMCO:new(emcoOpts, p.content)
    return p
end

-- ── SortBox pane ──────────────────────────────────────────────────────────────
-- Creates a MuxPane whose content area is a SortBox container.
-- Ideal for player lists, ranked gauges, or any dynamically-ordered content.
--
-- Returned pane has:   pane.sortbox  — the SortBox instance
--
-- opts (pane opts + extras):
--   boxType      (string)  — "v" vertical / "h" horizontal, default "v"
--   sortFunction (string)  — sort function name, default "name"
--   autoSort     (boolean) — continuously sort, default true
--   sortInterval (number)  — ms between sorts, default 500
--   elastic      (boolean) — expand/shrink to fit children, default false
--   sortbox_opts (table)   — merged verbatim into the SortBox constructor

function Mux.newSortboxPane(opts)
    ensureDetected()
    opts = opts or {}
    local p = Mux.newPane(opts)

    if not Mux.mdk.hasSortbox then
        Mux._err("newSortboxPane: SortBox not available")
        return p
    end

    local sbOpts = Mux._merge({
        name         = p.id .. "_sortbox",
        x            = "0%", y = "0%", width = "100%", height = "100%",
        boxType      = opts.boxType      or "v",
        sortFunction = opts.sortFunction or "name",
        autoSort     = (opts.autoSort ~= false),
        sortInterval = opts.sortInterval or 500,
        elastic      = opts.elastic      or false,
    }, opts.sortbox_opts or {})

    p.sortbox = SortBox:new(sbOpts, p.content)
    return p
end

-- ── Chyron (ticker) pane ──────────────────────────────────────────────────────
-- Creates a MuxPane whose content area is a scrolling Chyron ticker.
-- Best used in a narrow horizontal strip (e.g., a thin top/bottom panel).
--
-- Returned pane has:   pane.chyron  — the Chyron instance
--
-- opts (pane opts + extras):
--   text         (string)  — initial ticker text
--   displayWidth (number)  — visible character width, default 40
--   updateTime   (ms)      — scroll speed, default 200
--   delimiter    (string)  — boundary marker, default "|"
--   chyron_opts  (table)   — merged verbatim into Chyron constructor

function Mux.newChyronPane(opts)
    ensureDetected()
    opts = opts or {}
    local p = Mux.newPane(opts)

    if not Mux.mdk.hasChyron then
        Mux._err("newChyronPane: Chyron not available")
        return p
    end

    local cyOpts = Mux._merge({
        name         = p.id .. "_chyron",
        x            = "0%", y = "0%", width = "100%", height = "100%",
        text         = opts.text         or "",
        displayWidth = opts.displayWidth or 40,
        updateTime   = opts.updateTime   or 200,
        delimiter    = opts.delimiter    or "|",
    }, opts.chyron_opts or {})

    p.chyron = Chyron:new(cyOpts, p.content)
    return p
end

-- ── TimerGauge helper ─────────────────────────────────────────────────────────
-- Not a pane type (TimerGauge extends Geyser.Gauge which extends Window).
-- Creates a TimerGauge directly inside a given parent container.
-- Returns the TimerGauge object.
--
-- parent  : a Geyser container (e.g., any pane.content or sub-Container)
-- opts:
--   name     (string)   — widget name
--   time     (number)   — countdown duration in seconds (required)
--   x,y,width,height    — position within parent
--   showTime (boolean)  — show remaining time text, default true
--   autoHide (boolean)  — hide when elapsed, default true
--   hook     (function) — called when timer reaches 0

function Mux.newTimergauge(parent, opts)
    ensureDetected()
    opts = opts or {}
    if not Mux.mdk.hasTimergauge then
        Mux._err("newTimergauge: TimerGauge not available")
        return nil
    end
    assert(opts.time, "newTimergauge: opts.time (seconds) is required")
    local tgOpts = Mux._merge({
        name     = opts.name or Mux._newId("tg"),
        x        = opts.x      or "0%",
        y        = opts.y      or "0%",
        width    = opts.width  or "100%",
        height   = opts.height or "20px",
        time     = opts.time,
        showTime = (opts.showTime ~= false),
        autoHide = (opts.autoHide ~= false),
        active   = opts.active ~= false,
    }, opts.tg_opts or {})
    if opts.hook then tgOpts.hook = opts.hook end
    return TimerGauge:new(tgOpts, parent)
end

-- ── TextGauge helper ──────────────────────────────────────────────────────────
-- Returns a TextGauge object.  Because TextGauge is not a Geyser widget,
-- the caller must echo its output to a Label or console.
--
-- Example:
--   local tg = Mux.newTextgauge({ width=20, fillColor="<green>" })
--   local barStr = tg:setValue(currentHp, maxHp)
--   myLabel:echo(barStr)

function Mux.newTextgauge(opts)
    ensureDetected()
    if not Mux.mdk.hasTextgauge then
        Mux._err("newTextgauge: TextGauge not available")
        return nil
    end
    return TextGauge:new(opts)
end

-- ── Availability report ───────────────────────────────────────────────────────

function Mux.mdk.status()
    ensureDetected()
    cecho("\n<cyan>[Muxlet]<reset> MDK component availability:\n")
    local components = {
        { "EMCO",           Mux.mdk.hasEmco,       "Mux.newEmcoPane()    — tabbed multi-console"   },
        { "LoggingConsole", Mux.mdk.hasLoggingCon, "Mux.newConsolePane() — console with disk log"  },
        { "SortBox",        Mux.mdk.hasSortbox,    "Mux.newSortboxPane() — auto-sorted container"  },
        { "Chyron",         Mux.mdk.hasChyron,     "Mux.newChyronPane()  — scrolling ticker"       },
        { "TimerGauge",     Mux.mdk.hasTimergauge, "Mux.newTimergauge()  — countdown gauge widget" },
        { "TextGauge",      Mux.mdk.hasTextgauge,  "Mux.newTextgauge()   — text progress bar util" },
        { "Checkbox",       Mux.mdk.hasCheckbox,   "checkbox:new()       — toggle checkbox widget" },
        { "Spinbox",        Mux.mdk.hasSpinbox,    "spinbox:new()        — numeric input widget"   },
    }
    for _, c in ipairs(components) do
        local ok = c[2] and "<green>✓<reset>" or "<red>✗<reset>"
        cecho(string.format("  %s %-18s %s\n", ok, c[1], c[3]))
    end
end

-- ── Built-in content registrations ───────────────────────────────────────────
-- These ship with Muxlet so the "Add Content" menu has useful defaults.
-- External packages (e.g. fed2-tools) add their own entries the same way by
-- calling Mux.registerContent() from anywhere after Muxlet loads.
--
-- All built-in content reads from standard GMCP paths so it works on any
-- GMCP-enabled MUD without configuration.

local function clearPlaceholder(target)
    if target.contentBg then
        target.contentBg:hide()
    end
end

-- Deferred so MDK detection has completed before we check availability.
tempTimer(0.05, function()

    -- ── Vitals panel ──────────────────────────────────────────────────────────
    -- Reads gmcp.char.vitals and displays stat values in a refreshing label.
    -- Detects common paired fields (hp/maxhp, mp/maxmp, sp/maxsp, etc.) and
    -- renders them as "HP: 150 / 200".  Remaining scalar fields are listed below.
    Mux.registerContent("mux_vitals", {
        name        = "Vitals",
        description = "Character vitals from gmcp.char.vitals",

        apply = function(target)
            local labelName = target.id .. "_vitals_lbl"
            local lbl
            if Geyser.windowList[labelName] then
                lbl = Geyser.windowList[labelName]
                showWindow(labelName)
            else
                lbl = Geyser.Label:new({
                    name = labelName,
                    x = "0%", y = "0%", width = "100%", height = "100%",
                    fillBg = 1,
                }, target.content)
                lbl:setStyleSheet("background-color: rgba(18,18,30,0.92); border: none;")
            end
            target._vitalsLabel = lbl

            local function refresh()
                local v = gmcp and gmcp.char and gmcp.char.vitals
                if not v then
                    lbl:echo("<div style='padding:10px;color:rgba(130,135,175,0.8);"
                        .. "font-family:Consolas,Monaco,monospace;font-size:10px;'>"
                        .. "Waiting for gmcp.char.vitals...</div>")
                    return
                end

                -- Detect paired stat fields: hp+maxhp, mp+maxmp, sp+maxsp, etc.
                local paired = {}
                local pairedKeys = {}
                local knownMaxPrefixes = {"max", "Max", "MAX"}
                for k, val in pairs(v) do
                    if type(val) == "number" then
                        for _, prefix in ipairs(knownMaxPrefixes) do
                            local baseName = k:match("^" .. prefix .. "(.+)$")
                            if baseName then
                                local lowerBase = baseName:lower()
                                -- find the base key (case-insensitive match)
                                for bk, bv in pairs(v) do
                                    if bk:lower() == lowerBase and bk ~= k then
                                        local pairKey = bk:lower()
                                        if not paired[pairKey] then
                                            paired[pairKey]    = { cur = bv, max = val, label = bk:upper() }
                                            pairedKeys[#pairedKeys+1] = pairKey
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                -- Collect unpaired scalar fields.
                local usedKeys = {}
                for _, pk in ipairs(pairedKeys) do
                    usedKeys[pk] = true
                    for _, prefix in ipairs(knownMaxPrefixes) do
                        usedKeys[(prefix .. pk)] = true
                    end
                end
                local singles = {}
                for k, val in pairs(v) do
                    if not usedKeys[k:lower()] and (type(val) == "number" or type(val) == "string") then
                        singles[#singles+1] = { key = k, val = tostring(val) }
                    end
                end
                table.sort(pairedKeys)
                table.sort(singles, function(a, b) return a.key < b.key end)

                -- Build HTML.
                local lines = {}
                local statColor  = "color:rgba(180,185,220,0.9)"
                local pairColor  = "color:rgba(110,155,215,0.9)"
                local numColor   = "color:rgba(220,220,255,1.0)"
                for _, pk in ipairs(pairedKeys) do
                    local p = paired[pk]
                    local pct = (p.max > 0) and math.floor(p.cur / p.max * 100) or 0
                    local barColor = pct > 60 and "rgba(80,180,100,0.7)"
                              or pct > 30 and "rgba(200,160,50,0.7)"
                              or "rgba(200,70,70,0.7)"
                    local barW = math.max(2, math.floor(pct * 0.6))
                    lines[#lines+1] = string.format(
                        "<div style='margin:2px 8px;'>"
                        .. "<span style='%s;font-weight:bold;'>%s</span>"
                        .. "<span style='%s;'> %d / %d</span>"
                        .. "<div style='height:3px;margin-top:2px;"
                        .. "background:rgba(40,40,60,0.8);border-radius:2px;'>"
                        .. "<div style='width:%d%%;height:3px;"
                        .. "background:%s;border-radius:2px;'></div></div>"
                        .. "</div>",
                        pairColor, p.label, numColor, p.cur, p.max, barW, barColor)
                end
                for _, s in ipairs(singles) do
                    lines[#lines+1] = string.format(
                        "<div style='margin:2px 8px;%s;'>"
                        .. "<span style='font-weight:bold;'>%s:</span> %s</div>",
                        statColor, s.key, s.val)
                end

                local body = #lines > 0
                    and table.concat(lines)
                    or  "<div style='padding:10px;color:rgba(130,135,175,0.8);'>No vitals data.</div>"
                lbl:echo(string.format(
                    "<div style='padding-top:6px;font-family:Consolas,Monaco,monospace;"
                    .. "font-size:10px;'>%s</div>", body))
            end

            refresh()
            target._vitalsHandler = registerAnonymousEventHandler("gmcp.char.vitals", refresh)
            clearPlaceholder(target)
        end,

        remove = function(target)
            if target._vitalsHandler then
                killAnonymousEventHandler(target._vitalsHandler)
                target._vitalsHandler = nil
            end
            if target._vitalsLabel then
                hideWindow(target._vitalsLabel.name)
                target._vitalsLabel = nil
            end
        end,
    })

    -- ── Room info panel ───────────────────────────────────────────────────────
    -- Reads gmcp.room.info and displays room name, area, and exits.
    -- Updates automatically as you move between rooms.
    Mux.registerContent("mux_room_info", {
        name        = "Room Info",
        description = "Current room details from gmcp.room.info",

        apply = function(target)
            local labelName = target.id .. "_room_lbl"
            local lbl
            if Geyser.windowList[labelName] then
                lbl = Geyser.windowList[labelName]
                showWindow(labelName)
            else
                lbl = Geyser.Label:new({
                    name = labelName,
                    x = "0%", y = "0%", width = "100%", height = "100%",
                    fillBg = 1,
                }, target.content)
                lbl:setStyleSheet("background-color: rgba(18,18,30,0.92); border: none;")
            end
            target._roomLabel = lbl

            local function refresh()
                local r = gmcp and gmcp.room and gmcp.room.info
                if not r then
                    lbl:echo("<div style='padding:10px;color:rgba(130,135,175,0.8);"
                        .. "font-family:Consolas,Monaco,monospace;font-size:10px;'>"
                        .. "Waiting for gmcp.room.info...</div>")
                    return
                end

                local roomName = tostring(r.name or r.room or "Unknown Room")
                local areaName = tostring(r.area or r.zone or r.region or "")
                local sysName  = tostring(r.system or r.sector or "")

                -- Build exits string from whatever key holds them.
                local exits = r.exits or r.exit or {}
                local exitList = {}
                if type(exits) == "table" then
                    for dir, _ in pairs(exits) do
                        exitList[#exitList+1] = tostring(dir)
                    end
                    table.sort(exitList)
                end
                local exitsStr = #exitList > 0
                    and table.concat(exitList, ", ")
                    or  "none"

                -- Build any extra scalar fields for interest.
                local extras = {}
                local skipKeys = { name=true, room=true, area=true, zone=true,
                    region=true, system=true, sector=true, exits=true, exit=true }
                for k, val in pairs(r) do
                    if not skipKeys[k] and (type(val) == "string" or type(val) == "number") then
                        extras[#extras+1] = string.format(
                            "<div style='margin:1px 8px;color:rgba(150,155,190,0.8);font-size:9px;'>"
                            .. "<b>%s:</b> %s</div>", k, tostring(val))
                    end
                end
                table.sort(extras)

                local locationLine = areaName ~= "" and areaName or ""
                if sysName ~= "" and sysName ~= areaName then
                    locationLine = sysName ~= "" and (sysName .. (areaName ~= "" and " / " .. areaName or "")) or locationLine
                end

                lbl:echo(string.format(
                    "<div style='padding:8px;font-family:Consolas,Monaco,monospace;'>"
                    .. "<div style='color:rgba(220,210,160,1.0);font-size:12px;font-weight:bold;"
                    .. "margin-bottom:2px;'>%s</div>"
                    .. "<div style='color:rgba(150,155,190,0.85);font-size:10px;margin-bottom:6px;'>%s</div>"
                    .. "<div style='color:rgba(130,175,130,0.9);font-size:10px;'>"
                    .. "<b>Exits:</b> %s</div>"
                    .. "%s"
                    .. "</div>",
                    roomName, locationLine, exitsStr, table.concat(extras)))
            end

            refresh()
            target._roomHandler = registerAnonymousEventHandler("gmcp.room.info", refresh)
            clearPlaceholder(target)
        end,

        remove = function(target)
            if target._roomHandler then
                killAnonymousEventHandler(target._roomHandler)
                target._roomHandler = nil
            end
            if target._roomLabel then
                hideWindow(target._roomLabel.name)
                target._roomLabel = nil
            end
        end,
    })

    -- ── EMCO tabbed console ───────────────────────────────────────────────────
    if Mux.mdk.hasEmco then
        Mux.registerContent("mux_emco", {
            name        = "Tabbed Console (EMCO)",
            description = "MDK EMCO tabbed multi-console",
            apply = function(target)
                local name = target.id .. "_emco"
                if not Geyser.windowList[name] then
                    EMCO:new({
                        name      = name,
                        x = "0%", y = "0%", width = "100%", height = "100%",
                        consoles  = {"Main"},
                        fontSize  = 12, tabHeight = 20, gap = 2,
                        blink     = true,
                    }, target.content)
                else
                    showWindow(name)
                end
                clearPlaceholder(target)
            end,
            remove = function(target)
                local name = target.id .. "_emco"
                if Geyser.windowList[name] then hideWindow(name) end
            end,
        })
    end

end)

Mux._log("mux_mdk loaded")
