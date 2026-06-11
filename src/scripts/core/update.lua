-- Muxlet — Update checker and notification dialog
--
-- Checks the Mudlet Package Repository (MPR) for a newer version of Muxlet.
-- Fires once per Mudlet session on package load (15-second deferred start).
-- Both update_check_enabled and auto_start default to false so Muxlet
-- is as compatible as possible with downstream packages.
--
-- Manual check:    mux version
-- Enable:          mux settings set mux.update_check_enabled true
-- Disable:         mux settings set mux.update_check_enabled false
-- Test dialog:     Mux._changelog = {{version="9.9.9", body="- New feature"}}
--                  Mux.showUpdateDialog("0.0.0", "9.9.9")

-- ── Settings ──────────────────────────────────────────────────────────────────

Mux.settings.register("mux", "update_check_enabled", {
    description = "Check for Muxlet updates automatically when Mudlet opens",
    default     = false,
})

Mux.settings.register("mux", "update_check_remind_skip", {
    description = "Sessions remaining before update reminder re-appears (set by 'Remind Later')",
    default     = 0,
    min         = 0,
    max         = 99,
})

-- ── Dialog CSS ────────────────────────────────────────────────────────────────

local _FRAME_CSS = [[
    background-color: rgba(10, 12, 22, 254);
    border: 2px solid rgba(255, 255, 255, 0.42);
    border-radius: 6px;
]]
local _CSS_HDR = [[
    background: qlineargradient(x1:0,y1:0,x2:0,y2:1,
        stop:0 rgba(44,50,78,255), stop:1 rgba(22,26,44,255));
    color: rgba(220,230,255,255);
    font-size: 15px; font-weight: bold;
    border-radius: 4px 4px 0 0;
    border-bottom: 1px solid rgba(255,255,255,0.16);
    padding: 0 12px;
]]
local _CSS_BODY = [[
    background: transparent;
    color: rgba(198,210,238,255);
    font-size: 13px;
    padding: 0 14px;
]]
local _CSS_SUB = [[
    background: transparent;
    color: rgba(105,125,180,255);
    font-size: 11px;
    padding: 0 14px;
]]
local _CSS_BTN = [[
    QLabel {
        background-color: rgba(36,40,62,230);
        color: rgba(178,190,225,255);
        border: 1px solid rgba(85,98,140,210);
        border-radius: 5px;
        font-size: 12px; font-weight: bold;
        qproperty-alignment: AlignCenter;
    }
    QLabel::hover {
        background-color: rgba(52,60,95,245);
        border-color: rgba(105,158,255,210);
        color: white;
    }
]]
local _CSS_OK = [[
    QLabel {
        background-color: rgba(18,58,34,240);
        color: rgba(115,222,148,255);
        border: 1px solid rgba(48,152,78,215);
        border-radius: 5px;
        font-size: 12px; font-weight: bold;
        qproperty-alignment: AlignCenter;
    }
    QLabel::hover {
        background-color: rgba(26,82,46,255);
        border-color: rgba(65,210,108,235);
        color: rgba(178,255,200,255);
    }
]]
local _CSS_DANGER = [[
    QLabel {
        background-color: rgba(52,18,18,230);
        color: rgba(210,120,115,255);
        border: 1px solid rgba(140,48,48,200);
        border-radius: 5px;
        font-size: 12px; font-weight: bold;
        qproperty-alignment: AlignCenter;
    }
    QLabel::hover {
        background-color: rgba(82,22,22,245);
        border-color: rgba(200,70,68,220);
        color: rgba(255,160,155,255);
    }
]]
local _CSS_XBTN = [[
    QLabel {
        background-color: transparent;
        color: rgba(200,210,240,160);
        font-size: 17px; font-weight: bold;
        border-radius: 3px;
    }
    QLabel::hover {
        background-color: rgba(200,50,50,200);
        color: white;
    }
]]

-- ── Dialog ────────────────────────────────────────────────────────────────────

Mux._changelog          = Mux._changelog          or {}
Mux._updateDlHandler    = Mux._updateDlHandler    or nil
Mux._updateDlErrHandler = Mux._updateDlErrHandler or nil

-- Counter so each show() call uses fresh widget names.
local _n = 0

local function closeUpdateDialog()
    if Mux._updateDialog then
        Mux._updateDialog:hide()
        Mux._updateDialog = nil
    end
end

-- Estimate console height needed to show the full changelog without scrolling.
local _LINE_H     = 14
local _CHARS_LINE = 65

local function estimateConsoleH()
    local lines = 0
    if Mux._changelog and #Mux._changelog > 0 then
        for _, entry in ipairs(Mux._changelog) do
            lines = lines + 1
            local body = ((entry.body or ""):gsub("\r", ""))
            for seg in (body .. "\n"):gmatch("([^\n]*)\n") do
                lines = lines + math.max(1, math.ceil(math.max(1, #seg) / _CHARS_LINE))
            end
            lines = lines + 1
        end
    else
        lines = 2
    end
    return math.max(60, lines * _LINE_H + 8)
end

function Mux.showUpdateDialog(currentVersion, latestVersion)
    closeUpdateDialog()
    _n = _n + 1
    local n = _n

    local sw, sh = getMainWindowSize()
    local dw = 500

    local consoleH = math.min(
        estimateConsoleH(),
        math.max(60, math.floor(sh * 0.8) - 251)
    )
    local dh    = 251 + consoleH
    local divY  = 136 + consoleH + 10
    local noteY = divY  + 14
    local btnY  = noteY + 42

    local cx = math.floor((sw - dw) / 2)
    local cy = math.floor((sh - dh) / 2)

    Mux._updateDialog = Adjustable.Container:new({
        name          = "mux_upd_ac_" .. n,
        x             = cx, y = cy,
        width         = dw, height = dh,
        adjLabelstyle = _FRAME_CSS,
        autoSave      = false,
        autoLoad      = false,
    })
    Mux._updateDialog:lockContainer("border")
    Mux._updateDialog.locked = false   -- keep draggable

    local _in = Mux._updateDialog.Inside

    local hdr = Geyser.Label:new({
        name = "mux_upd_hdr_" .. n,
        x = 0, y = 0, width = "100%", height = 44,
    }, _in)
    hdr:setStyleSheet(_CSS_HDR)
    hdr:echo("  Update Available")

    local xbtn = Geyser.Label:new({
        name = "mux_upd_xbtn_" .. n,
        x = "92%", y = 8, width = 30, height = 28,
    }, _in)
    xbtn:setStyleSheet(_CSS_XBTN)
    xbtn:echo("<center>×</center>")
    xbtn:setClickCallback(closeUpdateDialog)

    local div1 = Geyser.Label:new({
        name = "mux_upd_div1_" .. n,
        x = 0, y = 44, width = "100%", height = 1,
    }, _in)
    div1:setStyleSheet("background-color: rgba(255,255,255,0.1); border:none;")

    local body = Geyser.Label:new({
        name = "mux_upd_body_" .. n,
        x = 0, y = 54, width = "100%", height = 26,
    }, _in)
    body:setStyleSheet(_CSS_BODY)
    body:echo("A new version of <b>Muxlet</b> is available.")

    local verLbl = Geyser.Label:new({
        name = "mux_upd_ver_" .. n,
        x = 0, y = 80, width = "100%", height = 22,
    }, _in)
    verLbl:setStyleSheet(_CSS_SUB)
    verLbl:echo(string.format(
        "You have <b>v%s</b>.  Latest is <b>v%s</b>.",
        currentVersion or "???", latestVersion))

    local wnLbl = Geyser.Label:new({
        name = "mux_upd_wnlbl_" .. n,
        x = "3%", y = 112, width = "94%", height = 20,
    }, _in)
    wnLbl:setStyleSheet(_CSS_SUB)
    wnLbl:echo("<b>What's New:</b>")

    local con = Geyser.MiniConsole:new({
        name      = "mux_upd_con_" .. n,
        x         = "3%", y = 136,
        width     = "94%", height = consoleH,
        autoWrap  = true,
        fontSize  = 10,
        scrollBar = true,
        color     = "black",
    }, _in)
    clearWindow(con.name)

    if Mux._changelog and #Mux._changelog > 0 then
        for _, entry in ipairs(Mux._changelog) do
            con:hecho("#73de94[ v" .. entry.version .. " ]\n")
            con:hecho("#c6d2ee" .. (entry.body or "") .. "\n\n")
        end
    else
        con:hecho("#697db4No specific release notes found.\n")
    end
    scrollTo(con.name, 1)

    local div2 = Geyser.Label:new({
        name = "mux_upd_div2_" .. n,
        x = 0, y = divY, width = "100%", height = 1,
    }, _in)
    div2:setStyleSheet("background-color: rgba(255,255,255,0.1); border:none;")

    local noteLbl = Geyser.Label:new({
        name = "mux_upd_note_" .. n,
        x = "3%", y = noteY, width = "94%", height = 34,
    }, _in)
    noteLbl:setStyleSheet(_CSS_SUB)
    noteLbl:echo("<b>Note:</b> After updating, close and reopen your Mudlet profile to ensure<br>all UI elements redraw correctly.")

    local btnNever = Geyser.Label:new({
        name = "mux_upd_never_" .. n,
        x = "2%", y = btnY, width = "28%", height = 32,
    }, _in)
    btnNever:setStyleSheet(_CSS_DANGER)
    btnNever:echo("<center>Never</center>")
    btnNever:setClickCallback(function()
        closeUpdateDialog()
        Mux.settings.set("mux", "update_check_enabled", false)
        Mux.settings.set("mux", "update_check_remind_skip", 0)
    end)

    local btnLater = Geyser.Label:new({
        name = "mux_upd_later_" .. n,
        x = "36%", y = btnY, width = "28%", height = 32,
    }, _in)
    btnLater:setStyleSheet(_CSS_BTN)
    btnLater:echo("<center>Remind Later</center>")
    btnLater:setClickCallback(function()
        closeUpdateDialog()
        Mux.settings.set("mux", "update_check_enabled", true)
        Mux.settings.set("mux", "update_check_remind_skip", 5)
    end)

    local btnUpdate = Geyser.Label:new({
        name = "mux_upd_now_" .. n,
        x = "70%", y = btnY, width = "28%", height = 32,
    }, _in)
    btnUpdate:setStyleSheet(_CSS_OK)
    btnUpdate:echo("<center>Update Now</center>")
    btnUpdate:setClickCallback(function()
        closeUpdateDialog()
        mpkg.upgrade("Muxlet")
    end)

    Mux._updateDialog:hide()
    Mux._updateDialog:show()
    Mux._updateDialog:raiseAll()
end

-- ── Version check logic ───────────────────────────────────────────────────────

-- Semver comparison: returns true if v1 is strictly newer than v2.
-- Strips pre-release suffixes (e.g. "0.2.0-dev" → "0.2.0") before comparing.
function Mux._versionIsNewer(v1, v2)
    if not v1 or not v2 then return false end
    local function parse(v)
        local base = v:match("^(%d[%d%.]*)") or "0"
        local major, minor, patch = base:match("^(%d+)%.?(%d*)%.?(%d*)")
        return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
    end
    local maj1, min1, pat1 = parse(v1)
    local maj2, min2, pat2 = parse(v2)
    if maj1 ~= maj2 then return maj1 > maj2 end
    if min1 ~= min2 then return min1 > min2 end
    return pat1 > pat2
end

-- Check MPR for a newer version.
-- silent=true suppresses "Checking..." and "Up to date" messages.
function Mux.checkForUpdates(silent)
    if not silent then
        Mux._echo("\n<cyan>[Muxlet]<reset> Checking for updates...\n")
    end

    if not mpkg or not mpkg.ready(true) then
        if not silent then
            Mux._echo("<red> Error: mpkg repository data not loaded.\n")
        end
        return
    end

    mpkg.updatePackageList(true)

    tempTimer(5, function()
        local current = mpkg.getInstalledVersion("Muxlet") or "0.0.0"

        if not getPackageInfo("Muxlet") then
            if not silent then
                Mux._echo("<red> Error: Muxlet not found in mpkg repository.\n")
            end
            return
        end

        local latest = mpkg.getRepositoryVersion("Muxlet")
        if Mux._versionIsNewer(latest, current) then
            Mux._triggerUpdateDialog(current, latest)
        elseif not silent then
            Mux._echo("<cyan> You are up to date.\n")
        end
    end)
end

-- Download the GitHub releases JSON, extract changelog entries between
-- currentVersion and latestVersion, then open the update dialog.
function Mux._triggerUpdateDialog(currentVersion, latestVersion)
    local tmp = getMudletHomeDir() .. "/mux_releases.json"

    Mux._changelog = {}

    local function cleanupDlHandlers()
        if Mux._updateDlHandler then
            killAnonymousEventHandler(Mux._updateDlHandler)
            Mux._updateDlHandler = nil
        end
        if Mux._updateDlErrHandler then
            killAnonymousEventHandler(Mux._updateDlErrHandler)
            Mux._updateDlErrHandler = nil
        end
    end
    cleanupDlHandlers()

    Mux._updateDlHandler = registerAnonymousEventHandler("sysDownloadDone", function(_, filename)
        if filename ~= tmp then return end

        local file = io.open(tmp, "r")
        if not file then return end
        local content = file:read("*a")
        file:close()

        local releases = yajl.to_value(content)
        if not releases then return end

        for _, release in ipairs(releases) do
            local tag = release.tag_name:gsub("^v", "")
            if Mux._versionIsNewer(tag, currentVersion)
            and not Mux._versionIsNewer(tag, latestVersion) then
                table.insert(Mux._changelog, {
                    version = tag,
                    body    = release.body,
                })
            end
        end

        table.sort(Mux._changelog, function(a, b)
            return Mux._versionIsNewer(a.version, b.version)
        end)

        if Mux.showUpdateDialog then
            Mux.showUpdateDialog(currentVersion, latestVersion)
        end

        cleanupDlHandlers()
    end)

    Mux._updateDlErrHandler = registerAnonymousEventHandler("sysDownloadError", function(_, filename)
        if filename ~= tmp then return end
        cleanupDlHandlers()
    end)

    downloadFile(tmp, "https://api.github.com/repos/tmtocloud/Muxlet/releases")
end

-- Runs once per Mudlet session at package load.
local function muxStartupUpdateCheck()
    local enabled = Mux.settings.get("mux", "update_check_enabled")
    if not enabled then return end

    local skip = tonumber(Mux.settings.get("mux", "update_check_remind_skip")) or 0
    if skip > 0 then
        Mux.settings.set("mux", "update_check_remind_skip", skip - 1)
        return
    end

    tempTimer(15, function()
        Mux.checkForUpdates(true)
    end)
end

muxStartupUpdateCheck()

Mux._log("update loaded")
