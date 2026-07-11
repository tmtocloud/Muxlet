-- Muxlet — Update checker and notification dialog
--
-- Checks this repo's GitHub Releases for a newer build of Muxlet and offers to
-- self-upgrade in place from the release asset. Nothing here touches the Mudlet
-- Package Repository (MPR/mpkg) — the releases in tmtocloud/Muxlet are the single
-- source of truth for both the version check and the download.
--
-- Two release channels, distinguished by tag shape (see ./muddlet):
--   Production release   tag "v2.1.0"   — final; keyed off the version number.
--   Pre-release          tag "2.1.0"    — rolling build off main; the version
--                                         number can sit still (still "2.1.0")
--                                         while the underlying commit advances, so
--                                         it is keyed off the commit sha instead.
--
-- A CI pre-release build stamps its own package version as "2.1.0-<shortsha>"
-- (muddler appends the short sha when HEAD is not exactly tagged v<version>), so
-- the sha of what is *installed* is read straight out of Mux._version, and the
-- sha of what is *available* comes from the release's target_commitish. The last
-- installed identity is also persisted (update_state.json) as a fallback so
-- "has this pre-release changed since I installed it?" survives even if a build
-- ever ships without the sha suffix.
--
-- Manual check:    mux version
-- Enable startup checks:      mux settings set muxupdate.update_check_enabled true
-- Opt in to pre-releases:     mux settings set muxupdate.update_include_prereleases true
-- Test the dialog with fake data:
--   Mux.showUpdateDialog(
--     { kind="prerelease", version="2.1.0", tag="2.1.0", sha="deadbeef", assets={} },
--     { { version="2.1.0", kind="prerelease", body="- New feature\n- A fix", sha="deadbeef" } })

-- ── Settings (Update tab) ─────────────────────────────────────────────────────
--
-- The two user-facing toggles (update_check_enabled, update_include_prereleases)
-- are registered in settings.lua alongside the other tab-anchoring settings
-- (e.g. muxtheme for Design), under the "muxupdate" namespace / "Muxlet/Update"
-- tab. This file owns only the update *logic* and reads them at runtime via
-- Mux.settings.get("muxupdate", ...). settings.lua loads before this file, so the
-- keys are always registered by the time anything here runs.

-- ── Repo / endpoint ───────────────────────────────────────────────────────────

local REPO          = "tmtocloud/Muxlet"
local RELEASES_URL  = "https://api.github.com/repos/" .. REPO .. "/releases?per_page=30"
local RELEASES_PAGE = "https://github.com/" .. REPO .. "/releases"

-- ── Internal persisted state ──────────────────────────────────────────────────
--
-- Kept in its own tiny file rather than the settings registry: none of it is a
-- user-facing preference, it is bookkeeping the updater owns.
--   remindSkip    number  sessions left to skip startup nagging ("Remind Later")
--   installedRef  string  identity of the pre-release we last installed (sha, or
--                         "t:<published_at>" when no sha was resolvable)
--   installedTag  string  the tag we last installed (diagnostic only)

Mux._updateStateFile = getMudletHomeDir() .. "/Muxlet_persistent/update_state.json"
Mux._updateState     = Mux._updateState or { remindSkip = 0, installedRef = nil, installedTag = nil }

local function loadUpdateState()
    if not io.exists(Mux._updateStateFile) then return end
    local ok = pcall(function()
        local f = io.open(Mux._updateStateFile, "r")
        if not f then return end
        local raw = f:read("*a"); f:close()
        local t = yajl.to_value(raw)
        if type(t) == "table" then
            Mux._updateState.remindSkip   = tonumber(t.remindSkip) or 0
            Mux._updateState.installedRef = t.installedRef
            Mux._updateState.installedTag = t.installedTag
        end
    end)
    if not ok then Mux._err("update: failed to read update_state.json") end
end

local function saveUpdateState()
    pcall(function()
        lfs.mkdir(getMudletHomeDir() .. "/Muxlet_persistent")
        local f = io.open(Mux._updateStateFile, "w")
        if not f then return end
        f:write(yajl.to_string(Mux._updateState)); f:close()
    end)
end

loadUpdateState()

-- Reset the startup-reminder skip counter (used by the wipe reload path).
function Mux.clearUpdateSnooze()
    Mux._updateState.remindSkip = 0
    saveUpdateState()
end

-- ── Reinstall primitive (shared by the updater and devmode) ───────────────────
--
-- Delete every file Muxlet persists (the whole Muxlet_persistent directory) so the
-- next load behaves like a brand-new profile: default settings, no saved
-- workspaces/themes/rules, welcome dialog shown again. Best-effort; missing dir is
-- fine. Kept flat (no recursion) because Muxlet only writes files there.
function Mux._wipePersistentDir()
    local dir = Mux._persistentDir
    if not dir then return end
    pcall(function()
        if not lfs or not lfs.dir then return end
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                os.remove(dir .. "/" .. entry)
            end
        end
        if lfs.rmdir then lfs.rmdir(dir) end
    end)
end

-- Reinstall Muxlet from a local .mpackage. CRITICAL: this is deferred to a
-- runtime tempTimer(0) so the uninstall does NOT run while a package-owned
-- alias/script (e.g. the "mux" alias that called us) is still on the Lua stack.
-- Uninstalling the very script that is executing frees it mid-run and crashes
-- Mudlet — that is the long-standing "mux reload crashes" bug. From a runtime
-- timer the triggering alias has already returned, so the teardown is safe.
--   opts.wipe  delete persisted state between uninstall and install (fresh profile)
function Mux._reinstallPackage(path, opts)
    opts = opts or {}
    local doWipe = opts.wipe and true or false
    local wipeFn = Mux._wipePersistentDir   -- capture before teardown
    tempTimer(0, function()
        if table.contains(getPackages(), "Muxlet") then
            pcall(uninstallPackage, "Muxlet")   -- fires the sysUninstallPackage teardown
        end
        if doWipe and wipeFn then pcall(wipeFn) end
        installPackage(path)
    end)
end

-- ── Version / ref helpers ─────────────────────────────────────────────────────

-- Semver comparison: true if v1 is strictly newer than v2. Pre-release suffixes
-- ("2.1.0-a3f91cd") are stripped before comparing — the sha, not the number,
-- distinguishes same-version pre-releases (handled separately below).
function Mux._versionIsNewer(v1, v2)
    if not v1 or not v2 then return false end
    local function parse(v)
        local base = tostring(v):match("^(%d[%d%.]*)") or "0"
        local major, minor, patch = base:match("^(%d+)%.?(%d*)%.?(%d*)")
        return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
    end
    local maj1, min1, pat1 = parse(v1)
    local maj2, min2, pat2 = parse(v2)
    if maj1 ~= maj2 then return maj1 > maj2 end
    if min1 ~= min2 then return min1 > min2 end
    return pat1 > pat2
end

-- Bare "major.minor.patch" of whatever is installed (drops any "-sha" suffix).
local function installedBaseVersion()
    return (tostring(Mux._version or "0")):match("^(%d[%d%.]*)") or "0"
end

-- Short commit sha the installed build was cut from ("2.1.0-a3f91cd" → "a3f91cd"),
-- or nil for a bare production version.
local function installedSha()
    return (tostring(Mux._version or "")):match("^%d[%d%.]*%-(%w+)$")
end

-- True if the installed build is a pre-release/dev build (anything past a bare
-- semver — same test devmode uses).
local function installedIsPre()
    local v = tostring(Mux._version or "")
    if v == "" or v == "unknown" then return false end
    return installedBaseVersion() ~= v
end

-- A GitHub release object → a normalized candidate table.
-- Pull the built commit sha out of a pre-release body. build.yml writes a line
-- like "**Commit:** <github.sha>" into the notes, and that sha is exactly the
-- commit muddler stamped into the package version ("2.1.0-<shortsha>"). This is
-- the authoritative build identity — more reliable than target_commitish, which
-- for a branch-built pre-release is usually the branch name ("main"), not a sha.
local function extractCommitSha(body)
    if type(body) ~= "string" then return nil end
    return body:match("[Cc]ommit%**:%**%s*(%x%x%x%x%x%x%x+)")
        or body:match("[Cc]ommit[^%x]-(%x%x%x%x%x%x%x+)")
end

local function parseRelease(r)
    local tag   = r.tag_name or ""
    -- Pre-release convention here is a bare tag (no leading "v"); honour the API's
    -- own prerelease flag too, in case a release is flagged but oddly tagged.
    local isPre = (r.prerelease == true) or (tag:match("^v") == nil)
    -- Commit identity: prefer the sha recorded in the body; fall back to
    -- target_commitish only when it is a real sha (ignore "main" and other
    -- branch names, which don't identify the built commit).
    local sha = extractCommitSha(r.body)
    if not sha then
        local tc = r.target_commitish
        if type(tc) == "string" and tc:match("^%x%x%x%x%x%x%x+$") then sha = tc end
    end
    return {
        kind        = isPre and "prerelease" or "release",
        tag         = tag,
        version     = tag:gsub("^v", ""),
        sha         = sha,
        publishedAt = r.published_at or r.created_at,
        body        = r.body or "",
        name        = r.name,
        assets      = r.assets or {},
    }
end

-- Identity used to tell one build of the same pre-release version from another:
-- the commit sha if we have it, otherwise a timestamp tag so at least published
-- rebuilds are distinguishable.
local function preRef(cand)
    if cand.sha then return cand.sha end
    if cand.publishedAt then return "t:" .. cand.publishedAt end
    return nil
end

-- Two refs describe the same build. Shas compare by prefix (short vs full);
-- timestamp refs compare exactly.
local function refsMatch(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local la, lb = #a, #b
    if la < lb then return b:sub(1, la) == a else return a:sub(1, lb) == b end
end

-- Both refs are the same *kind* (both shas, or both timestamps) and therefore
-- meaningfully comparable — guards against a false "changed" when we can only
-- read a sha on one side and a timestamp on the other.
local function refsComparable(a, b)
    if not a or not b then return false end
    local at, bt = a:match("^t:"), b:match("^t:")
    return (at and bt) or (not at and not bt)
end

-- ── Update decision ───────────────────────────────────────────────────────────
--
-- From the parsed candidate list, pick the single build (if any) to offer.
-- Returns the chosen candidate or nil.
local function chooseUpdate(cands, includePre)
    local prod, pre
    for _, c in ipairs(cands) do
        if c.kind == "release" then
            if not prod or Mux._versionIsNewer(c.version, prod.version) then prod = c end
        else
            if not pre
               or Mux._versionIsNewer(c.version, pre.version)
               or (c.version == pre.version and (c.publishedAt or "") > (pre.publishedAt or "")) then
                pre = c
            end
        end
    end

    local iVer = installedBaseVersion()
    local iPre = installedIsPre()
    local iRef = installedSha() or Mux._updateState.installedRef

    -- Prefer the pre-release channel only when it is strictly ahead of the newest
    -- production release; at an equal version the finished production build wins.
    local primary
    if includePre and pre and (not prod or Mux._versionIsNewer(pre.version, prod.version)) then
        primary = pre
    else
        primary = prod
    end
    if not primary then return nil end

    if primary.kind == "release" then
        if Mux._versionIsNewer(primary.version, iVer) then return primary end
        -- Sitting on a pre-release of this version and now a stable release of the
        -- same number exists → offer the transition to stable.
        if iPre and primary.version == iVer then return primary end
        return nil
    else
        if Mux._versionIsNewer(primary.version, iVer) then return primary end
        -- Same version number, pre-release channel: it is an update only if we are
        -- already on a pre-release and the commit actually moved.
        if primary.version == iVer and iPre then
            local pRef = preRef(primary)
            if refsComparable(pRef, iRef) and not refsMatch(pRef, iRef) then
                return primary
            end
        end
        return nil
    end
end

-- Release-note entries to show, newest first: everything on the target's channel
-- in the range (installed, target], plus the target itself.
local function buildChangelog(cands, primary, iVer)
    local out, seen = {}, {}
    for _, c in ipairs(cands) do
        local inRange = Mux._versionIsNewer(c.version, iVer)
                        and not Mux._versionIsNewer(c.version, primary.version)
                        and c.kind == primary.kind
        if (inRange or c == primary) and not seen[c] then
            seen[c] = true
            out[#out + 1] = c
        end
    end
    table.sort(out, function(a, b)
        if a.version ~= b.version then return Mux._versionIsNewer(a.version, b.version) end
        return (a.publishedAt or "") > (b.publishedAt or "")
    end)
    return out
end

-- ── Markdown → label HTML (light) ─────────────────────────────────────────────

local function escapeHtml(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Enough of GitHub's release-note markdown to read well in a QLabel: headings go
-- bold, list markers become bullets, blank lines become spacing. Everything is
-- escaped first so stray angle brackets don't corrupt the label.
-- Inline markdown applied to already-escaped text: **bold** and `code`.
local function inlineMd(s)
    s = s:gsub("%*%*(.-)%*%*", "<b>%1</b>")   -- **bold** → <b>
    s = s:gsub("`([^`]-)`", "%1")             -- `code` → render the text plainly
    return s
end

local function mdToHtml(body)
    body = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if body:match("^%s*$") then return "" end
    local lines = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        local raw = line:gsub("%s+$", "")
        if raw == "" then
            lines[#lines + 1] = "<span style='font-size:6px;'>&nbsp;</span>"
        else
            local heading = raw:match("^#+%s+(.*)$")
            local bullet  = raw:match("^%s*[%-%*]%s+(.*)$")
            if heading then
                lines[#lines + 1] = "<b>" .. inlineMd(escapeHtml(heading)) .. "</b>"
            elseif bullet then
                lines[#lines + 1] = "&nbsp;&nbsp;• " .. inlineMd(escapeHtml(bullet))
            else
                lines[#lines + 1] = inlineMd(escapeHtml(raw))
            end
        end
    end
    return table.concat(lines, "<br>")
end

-- ── Custom form widget: rich-text block ───────────────────────────────────────
--
-- A read-only wrapped-text block, laid out by buildForm like any other row. Used
-- for the intro line, the "What's New" bodies, and the post-update note, so the
-- whole dialog is a single mountForm (scroll + grow-to-fit for free) rather than a
-- bespoke MiniConsole. Registered lazily because widgets.lua loads after this file.
local _APPROX_TEXT_W = 470   -- ≈ dialog content width minus row padding

local function estimateRichHeight(html, width)
    width = width or _APPROX_TEXT_W
    local charsPerLine = math.max(24, math.floor(width / 6.4))
    local lines = 0
    for seg in (html .. "<br>"):gmatch("(.-)<br>") do
        local plain = seg:gsub("<[^>]->", "")
        plain = plain:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        lines = lines + math.max(1, math.ceil(math.max(1, #plain) / charsPerLine))
    end
    return math.max(22, lines * 17 + 10)
end

local function ensureRichWidget()
    if not (Mux.ui and Mux.ui.registerWidget) then return end
    if Mux.ui._widgets and Mux.ui._widgets["richText"] then return end
    Mux.ui.registerWidget("richText", function(row, c)
        local spec, uid = c.spec, c.uid
        local theme = Mux.activeTheme() or {}
        local sui   = theme.settingsUi or theme.ui or {}
        local fg    = spec.color or sui.textColor or "rgba(198,210,238,255)"
        local w     = c.formW - c.padL - c.padR
        local lbl   = Geyser.Label:new({
            name = uid .. "_rt", x = c.padL, y = 5, width = w, height = math.max(14, (c.thisH or 30) - 10),
        }, row)
        lbl:setStyleSheet(string.format(
            "background:transparent; border:none; color:%s; font-size:%dpx; "
            .. "qproperty-alignment:'AlignLeft|AlignTop'; qproperty-wordWrap:true;",
            fg, spec.fontSize or 12))
        lbl:echo(spec.html or "")
        return {}
    end, { layout = "block", rowHeight = 30 })
end

-- ── Dialog ────────────────────────────────────────────────────────────────────

Mux._changelog       = Mux._changelog       or {}   -- retained for manual testing
Mux._updateCandidate = Mux._updateCandidate or nil

local function closeUpdateDialog()
    if Mux._updateDialog then
        pcall(function() Mux._updateDialog:close() end)
        Mux._updateDialog = nil
    end
end

-- Download the chosen release's package asset and reinstall Muxlet in place.
local function installFromRelease(cand)
    if not cand then return end

    local url
    for _, a in ipairs(cand.assets or {}) do
        if (a.name or ""):lower():match("%.mpackage$") then url = a.browser_download_url; break end
    end
    if not url then
        for _, a in ipairs(cand.assets or {}) do
            if (a.name or ""):lower():match("%.zip$") then url = a.browser_download_url; break end
        end
    end
    if not url then
        Mux._echo(string.format(
            "\n<red>[Muxlet]<reset> Release <cyan>%s<reset> has no installable package asset.\n"
            .. "  Download it manually from <cyan>%s<reset>\n", cand.tag or "?", RELEASES_PAGE))
        return
    end

    Mux._echo(string.format(
        "\n<yellow>[Muxlet]<reset> Downloading %s <cyan>%s<reset>...\n",
        cand.kind == "prerelease" and "pre-release" or "release", cand.tag or "?"))

    local pkg = getMudletHomeDir() .. "/Muxlet_update.mpackage"

    if Mux._updateInstallDone then killAnonymousEventHandler(Mux._updateInstallDone) end
    if Mux._updateInstallErr  then killAnonymousEventHandler(Mux._updateInstallErr)  end

    Mux._updateInstallDone = registerAnonymousEventHandler("sysDownloadDone", function(_, filename)
        if filename ~= pkg then return end
        killAnonymousEventHandler(Mux._updateInstallDone); Mux._updateInstallDone = nil
        if Mux._updateInstallErr then killAnonymousEventHandler(Mux._updateInstallErr); Mux._updateInstallErr = nil end

        -- Record what we are about to install BEFORE tearing the package down, so
        -- the freshly loaded build knows which pre-release commit it now is even if
        -- the version string ever lacks the sha suffix.
        Mux._updateState.installedRef = preRef(cand) or Mux._updateState.installedRef
        Mux._updateState.installedTag = cand.tag
        Mux._updateState.remindSkip   = 0
        saveUpdateState()

        Mux._echo("\n<yellow>[Muxlet]<reset> Installing update...\n")
        Mux._reinstallPackage(pkg)
    end)

    Mux._updateInstallErr = registerAnonymousEventHandler("sysDownloadError", function(_, filename)
        if filename ~= pkg then return end
        killAnonymousEventHandler(Mux._updateInstallErr); Mux._updateInstallErr = nil
        if Mux._updateInstallDone then killAnonymousEventHandler(Mux._updateInstallDone); Mux._updateInstallDone = nil end
        Mux._echo(string.format(
            "\n<red>[Muxlet]<reset> Download failed. Install manually from <cyan>%s<reset>\n", RELEASES_PAGE))
    end)

    downloadFile(pkg, url)
end

-- Build (or rebuild) the update dialog for a chosen candidate + changelog entries.
function Mux.showUpdateDialog(cand, changelog)
    ensureRichWidget()
    closeUpdateDialog()

    cand      = cand or Mux._updateCandidate or {}
    changelog = changelog or Mux._changelog or {}
    Mux._updateCandidate = cand
    Mux._changelog       = changelog

    local iVer  = installedBaseVersion()
    local isPre = cand.kind == "prerelease"

    local d = Mux.createDialog({
        title     = "Muxlet Update",
        width     = 520,
        height    = 300,
        singleton = "mux_update",
        maxHeightPct = 0.82,
    })
    if not d then return end
    if d.contentBg then d.contentBg:echo(""); d.contentBg:hide() end
    Mux._updateDialog = d

    -- Intro + version line as one rich block.
    local verText
    if isPre and cand.version == iVer then
        verText = string.format(
            "A new build of the <b>%s</b> pre-release is available.<br>"
            .. "<span style='color:rgba(120,140,190,255);'>You have build <b>%s</b>. "
            .. "The latest build is <b>%s</b>.</span>",
            escapeHtml(cand.version or "?"),
            escapeHtml(tostring(Mux._version or "?")),
            escapeHtml((cand.sha and (cand.version .. "-" .. cand.sha:sub(1, 7))) or cand.tag or "?"))
    elseif isPre then
        verText = string.format(
            "A newer <b>pre-release</b> of Muxlet is available.<br>"
            .. "<span style='color:rgba(120,140,190,255);'>You have <b>v%s</b>. "
            .. "Latest pre-release is <b>%s</b>.</span>",
            escapeHtml(iVer), escapeHtml(cand.tag or cand.version or "?"))
    else
        verText = string.format(
            "A new version of <b>Muxlet</b> is available.<br>"
            .. "<span style='color:rgba(120,140,190,255);'>You have <b>v%s</b>. "
            .. "Latest is <b>v%s</b>.</span>",
            escapeHtml(tostring(Mux._version or "?")), escapeHtml(cand.version or "?"))
    end

    local specs = {}

    specs[#specs + 1] = { type = "richText", html = verText,
        rowHeight = estimateRichHeight(verText) + 6 }

    specs[#specs + 1] = { type = "divider", label = "What's New" }

    if changelog and #changelog > 0 then
        for _, entry in ipairs(changelog) do
            local header
            if entry.kind == "prerelease" and entry == cand and entry.version == iVer then
                header = "v" .. entry.version .. "  (updated pre-release build)"
            elseif entry.kind == "prerelease" then
                header = entry.version .. "  (pre-release)"
            else
                header = "v" .. entry.version
            end
            specs[#specs + 1] = { type = "divider", label = header }
            local html = mdToHtml(entry.body)
            if html == "" then html = "<span style='color:rgba(105,125,180,255);'>No notes for this release.</span>" end
            specs[#specs + 1] = { type = "richText", html = html, rowHeight = estimateRichHeight(html) }
        end
    else
        specs[#specs + 1] = { type = "richText",
            html = "<span style='color:rgba(105,125,180,255);'>No release notes found.</span>",
            rowHeight = 28 }
    end

    specs[#specs + 1] = { type = "divider", label = "" }

    local note = "<span style='color:rgba(105,125,180,255);'>After updating, close and reopen your "
              .. "Mudlet profile so every UI element redraws cleanly.</span>"
    specs[#specs + 1] = { type = "richText", html = note, rowHeight = estimateRichHeight(note) + 4 }

    specs[#specs + 1] = { type = "button", label = "Update Now", style = "primary", _noReset = true,
        onClick = function()
            closeUpdateDialog()
            installFromRelease(cand)
        end }
    specs[#specs + 1] = { type = "button", label = "Remind Me Later", _noReset = true,
        onClick = function()
            closeUpdateDialog()
            Mux._updateState.remindSkip = 5
            saveUpdateState()
        end }
    specs[#specs + 1] = { type = "button", label = "Never Check Automatically", style = "danger", _noReset = true,
        onClick = function()
            closeUpdateDialog()
            Mux.settings.set("muxupdate", "update_check_enabled", false)
            Mux._updateState.remindSkip = 0
            saveUpdateState()
        end }

    d:mountForm(specs, { prefix = "mux_update_f" })
    -- Geyser only finalises this dialog's geometry after the current stack
    -- unwinds; the mount-time fit therefore runs against provisional sizes and
    -- can misplace/overshoot rows until something forces a relayout. Re-run the
    -- layout on the next tick so the first render matches the settled state
    -- (previously this only corrected itself when the user clicked the dialog).
    tempTimer(0, function()
        if Mux._updateDialog == d and d._muxRelayout then pcall(d._muxRelayout) end
    end)
end

-- ── Version check ─────────────────────────────────────────────────────────────

-- Fetch the releases JSON, decide on an update, and either open the dialog or
-- report status. silent=true suppresses the "checking"/"up to date" chatter.
function Mux.checkForUpdates(silent)
    if tostring(Mux._version or "") == "unknown" then
        if not silent then
            Mux._echo("\n<yellow>[Muxlet]<reset> Can't read the installed version — skipping update check.\n")
        end
        return
    end

    local includePre = Mux.settings.get("muxupdate", "update_include_prereleases") and true or false
    local modeText   = includePre and "stable + pre-releases" or "stable releases only"

    if not silent then
        Mux._echo(string.format(
            "\n<cyan>[Muxlet]<reset> Checking releases for updates <dim_grey>(%s)<reset>...\n",
            modeText))
    end

    local tmp = getMudletHomeDir() .. "/mux_releases.json"

    local function cleanup()
        if Mux._updateDlHandler then killAnonymousEventHandler(Mux._updateDlHandler); Mux._updateDlHandler = nil end
        if Mux._updateDlErrHandler then killAnonymousEventHandler(Mux._updateDlErrHandler); Mux._updateDlErrHandler = nil end
    end
    cleanup()

    Mux._updateDlHandler = registerAnonymousEventHandler("sysDownloadDone", function(_, filename)
        if filename ~= tmp then return end
        cleanup()

        local file = io.open(tmp, "r")
        if not file then return end
        local content = file:read("*a"); file:close()

        local releases = yajl.to_value(content)
        if type(releases) ~= "table" or not releases[1] then
            if not silent then Mux._echo("<red> Could not read the releases list.\n") end
            return
        end

        local cands = {}
        for _, r in ipairs(releases) do
            if r.tag_name and not r.draft then cands[#cands + 1] = parseRelease(r) end
        end

        local chosen = chooseUpdate(cands, includePre)
        if not chosen then
            if not silent then
                Mux._echo(string.format(
                    "<cyan> You are up to date <dim_grey>(%s)<reset>.\n", modeText))
            end
            return
        end

        local changelog = buildChangelog(cands, chosen, installedBaseVersion())
        Mux.showUpdateDialog(chosen, changelog)
    end)

    Mux._updateDlErrHandler = registerAnonymousEventHandler("sysDownloadError", function(_, filename)
        if filename ~= tmp then return end
        cleanup()
        if not silent then
            Mux._echo(string.format(
                "\n<red>[Muxlet]<reset> Couldn't reach GitHub. Check releases at <cyan>%s<reset>\n", RELEASES_PAGE))
        end
    end)

    downloadFile(tmp, RELEASES_URL)
end

-- ── Downstream version pinning (unchanged public API) ─────────────────────────
--
-- Mux.ensureVersion(requiredVersion, url, callback)
--
-- For packages built against a specific Muxlet version. Call it from your own
-- package's `muxletReady` handler (see README "Bootstrapping from your own
-- package"). If the loaded Muxlet already satisfies requiredVersion, callback runs
-- immediately. Otherwise Muxlet reinstalls itself in place from `url` (a GitHub
-- release download URL) and does NOT call callback — the freshly installed Muxlet
-- raises its own muxletReady, which re-invokes your handler, which calls
-- Mux.ensureVersion again; this time the version check passes and callback runs.
--
-- Mux._version of "unknown" is treated as satisfied rather than risking a
-- reinstall loop.
function Mux.ensureVersion(requiredVersion, url, callback)
    local installed = Mux._version
    if installed == "unknown" or not Mux._versionIsNewer(requiredVersion, installed) then
        local ok, err = pcall(callback)
        if not ok then Mux._err("Mux.ensureVersion callback error: %s", tostring(err)) end
        return
    end

    if not url then
        Mux._err(
            "Mux.ensureVersion: installed Muxlet %s does not satisfy required %s, and no url was given to upgrade from.",
            tostring(installed), requiredVersion)
        return
    end

    Mux._echo(string.format(
        "\n<yellow>[Muxlet]<reset> Upgrading Muxlet %s -> %s...\n", tostring(installed), requiredVersion))

    if table.contains(getPackages(), "Muxlet") then
        uninstallPackage("Muxlet")
    end
    installPackage(url)
end

-- Mux.configureHost(opts)
--
-- The startup choices a hosting package (one with its own onboarding, using
-- Mux.ensureVersion) almost always needs to make, in one call. Every field is
-- optional — omit one to leave that setting untouched.
--
--   opts.suppressWelcome  (bool)   true = don't show Muxlet's first-run welcome.
--   opts.autoStart        (bool)   true = Mux.fullStart() runs on profile load.
--   opts.quietStart       (bool)   true = suppress Muxlet's "Started" message.
--   opts.checkForUpdates  (bool)   true = let Muxlet check its releases and offer
--                                  to self-upgrade. Usually false for a package
--                                  pinning a version via Mux.ensureVersion.
--   opts.includePrereleases (bool) true = also offer pre-release builds.
--   opts.defaultWorkspace (string) Workspace name applied by `mux reset` / first
--                                  Mux.fullStart(). Must already be registered.
function Mux.configureHost(opts)
    opts = opts or {}
    if opts.suppressWelcome ~= nil then
        Mux.settings.set("mux", "welcome_shown", opts.suppressWelcome)
    end
    if opts.autoStart ~= nil then
        Mux.settings.set("mux", "auto_start", opts.autoStart)
    end
    if opts.quietStart ~= nil then
        Mux.settings.set("mux", "quietStart", opts.quietStart)
    end
    if opts.checkForUpdates ~= nil then
        Mux.settings.set("muxupdate", "update_check_enabled", opts.checkForUpdates)
    end
    if opts.includePrereleases ~= nil then
        Mux.settings.set("muxupdate", "update_include_prereleases", opts.includePrereleases)
    end
    if opts.defaultWorkspace ~= nil then
        Mux.settings.set("mux", "reset_workspace", opts.defaultWorkspace)
    end
end

-- ── Startup check ─────────────────────────────────────────────────────────────

local function muxStartupUpdateCheck()
    if not Mux.settings.get("muxupdate", "update_check_enabled") then return end

    local skip = tonumber(Mux._updateState.remindSkip) or 0
    if skip > 0 then
        Mux._updateState.remindSkip = skip - 1
        saveUpdateState()
        return
    end

    tempTimer(15, function()
        Mux.checkForUpdates(true)
    end)
end

muxStartupUpdateCheck()

-- ── Graphical "Check now" button on the Update settings tab ───────────────────
-- Appended after the two toggles via settings.registerRow (settings.lua loads
-- first, so the hook exists). Runs a visible (non-silent) check so the user gets
-- "up to date" feedback in the console and the update dialog if one is found.
if Mux.settings and Mux.settings.registerRow then
    Mux.settings.registerRow("muxupdate", {
        type    = "button",
        label   = "Check for updates now",
        style   = "primary",
        desc    = "Check this repo's releases immediately, honouring the pre-release setting above.",
        onClick = function()
            if Mux.checkForUpdates then Mux.checkForUpdates(false) end
        end,
    })
end

Mux._log("update loaded")