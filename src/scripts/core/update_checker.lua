-- Muxlet — Update Checker
--
-- Checks the Mudlet Package Repository (MPR) for a newer version of Muxlet.
-- Fires once per Mudlet session on package load (15-second deferred start).
--
-- Manual check:    mux version
-- Disable:         mux settings set mux.update_check_enabled false
-- Remind later:    use the dialog button (skips 5 sessions)

Mux.settings.register("mux", "update_check_enabled", {
    description = "Check for Muxlet updates automatically when Mudlet opens",
    default     = true,
})

Mux.settings.register("mux", "update_check_remind_skip", {
    description = "Sessions remaining before update reminder re-appears (set by 'Remind Later')",
    default     = 0,
    min         = 0,
    max         = 99,
})

-- Global changelog data populated by _triggerUpdateDialog before dialog opens.
Mux._changelog      = Mux._changelog      or {}
Mux._updateDlHandler = Mux._updateDlHandler or nil

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

    -- Silently refresh the package list then wait 5s for it to take effect.
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

    if Mux._updateDlHandler then
        killAnonymousEventHandler(Mux._updateDlHandler)
    end

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

        -- Newest version first so the dialog leads with the latest entry.
        table.sort(Mux._changelog, function(a, b)
            return Mux._versionIsNewer(a.version, b.version)
        end)

        if Mux.showUpdateDialog then
            Mux.showUpdateDialog(currentVersion, latestVersion)
        end

        killAnonymousEventHandler(Mux._updateDlHandler)
        Mux._updateDlHandler = nil
    end)

    downloadFile(tmp, "https://api.github.com/repos/tmtocloud/Muxlet/releases")
end

-- Runs once per Mudlet session at package load.
local function muxStartupUpdateCheck()
    local enabled = Mux.settings.get("mux", "update_check_enabled")
    if enabled == false then return end

    local skip = tonumber(Mux.settings.get("mux", "update_check_remind_skip")) or 0
    if skip > 0 then
        Mux.settings.set("mux", "update_check_remind_skip", skip - 1)
        return
    end

    -- Defer 15 s so all packages and MDK fully initialise before querying mpkg.
    tempTimer(15, function()
        Mux.checkForUpdates(true)
    end)
end

muxStartupUpdateCheck()

Mux._log("mux_update_checker loaded")
