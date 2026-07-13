-- Muxlet — Update checker and notification dialog
--
-- Checks GitHub Releases for a newer build and offers to self-upgrade in place
-- from the release asset. Nothing here touches the Mudlet Package Repository
-- (MPR/mpkg) — GitHub Releases are the single source of truth for both the
-- version check and the download.
--
-- Standalone (default): checks tmtocloud/Muxlet, for Muxlet itself.
--
-- Hosted: a consumer package can call Mux.configureHost({ updateRepo = "...",
-- ... }) to have this SAME machinery check ITS OWN repo instead, with Muxlet's
-- own self-polling stepping aside. See Mux.configureHost's doc comment near
-- the bottom of this file for the full field list — updateRepo is the only
-- one that's actually required. If the host also declares a
-- requiredMuxletVersion/requiredMuxletUrl, "Update Now" transparently bumps
-- Muxlet first (via the same Mux.ensureVersion used for the one-time boot
-- gate) before installing the host's own update, and the dialog gains a
-- second "Muxlet" tab showing what that bump actually changes. At most one
-- host can be registered; it always takes priority over Muxlet's own cadence.
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
-- Test the dialog with fake data (pass automatic=true to see the "Remind Me
-- Later"/"Never Check Automatically" buttons a real startup check would show;
-- pass muxletCand/muxletChangelog too to preview the two-tab hosted layout):
--   Mux.showUpdateDialog(
--     { kind="prerelease", version="2.1.0", tag="2.1.0", sha="deadbeef", assets={} },
--     { { version="2.1.0", kind="prerelease", body="- New feature\n- A fix", sha="deadbeef" } },
--     { automatic = true })

-- ── Settings (Update tab) ─────────────────────────────────────────────────────
--
-- Muxlet's own two user-facing toggles (update_check_enabled, update_include_prereleases)
-- are registered in settings.lua alongside the other tab-anchoring settings
-- (e.g. muxtheme for Design), under the "muxupdate" namespace / "Muxlet/Update"
-- tab. This file owns only the update *logic* and reads them at runtime via
-- Mux.settings.get("muxupdate", ...). settings.lua loads before this file, so the
-- keys are always registered by the time anything here runs.
--
-- A registered host's equivalent toggles are registered here instead (see
-- registerHostSettingsRows below), under whichever namespace it supplies,
-- because Muxlet has no way to know that namespace ahead of time.

-- ── Repo / endpoint ───────────────────────────────────────────────────────────

local MUXLET_REPO = "tmtocloud/Muxlet"

local function releasesUrl(repo)  return "https://api.github.com/repos/" .. repo .. "/releases?per_page=30" end
local function releasesPage(repo) return "https://github.com/" .. repo .. "/releases" end

-- Echoed right before resetProfile() runs after a successful install (see
-- Mux._reinstallPackage's doc comment for why a reset is needed at all).
-- resetProfile()'s own widget-teardown safety net is a fairly recent Mudlet
-- fix — an informational nudge rather than a confirmation popup, since the
-- alternative (leaving stale Lua state behind) is worse on any Mudlet version.
local RESET_NOTICE = "<yellow>[Muxlet]<reset> Resetting Lua state to finish applying the update. "
    .. "If anything looks off afterward, make sure Mudlet itself is up to date.\n"

-- ── Host registration (optional) ──────────────────────────────────────────────
--
-- Set by Mux.configureHost when a hosting package opts in via opts.updateRepo.
-- nil (the default) means standalone: Muxlet checks its own repo, for itself.
-- See Mux.configureHost's doc comment for the full field list.
Mux._hostUpdate = Mux._hostUpdate or nil

-- ── Internal persisted state ──────────────────────────────────────────────────
--
-- Kept in its own tiny file rather than the settings registry: none of it is a
-- user-facing preference, it is bookkeeping the updater owns. Keyed by target
-- ("muxlet" or "host") so a registered host's remind-later state never
-- collides with Muxlet's own.
--   remindSkip    number  sessions left to skip startup nagging ("Remind Later")
--   installedRef  string  identity of the pre-release we last installed (sha, or
--                         "t:<published_at>" when no sha was resolvable)
--   installedTag  string  the tag we last installed (diagnostic only)

Mux._updateStateFile = getMudletHomeDir() .. "/Muxlet_persistent/update_state.json"
Mux._updateState     = Mux._updateState or {}

local function stateFor(key)
    Mux._updateState[key] = Mux._updateState[key] or { remindSkip = 0, installedRef = nil, installedTag = nil }
    return Mux._updateState[key]
end

local function loadUpdateState()
    if not io.exists(Mux._updateStateFile) then return end
    local ok = pcall(function()
        local f = io.open(Mux._updateStateFile, "r")
        if not f then return end
        local raw = f:read("*a"); f:close()
        local t = yajl.to_value(raw)
        if type(t) ~= "table" then return end
        if t.remindSkip ~= nil or t.installedRef ~= nil or t.installedTag ~= nil then
            -- Pre-existing flat shape (from before per-target keying) → migrate
            -- into the "muxlet" slot so upgrading doesn't lose the countdown.
            Mux._updateState.muxlet = {
                remindSkip   = tonumber(t.remindSkip) or 0,
                installedRef = t.installedRef,
                installedTag = t.installedTag,
            }
        else
            for k, v in pairs(t) do
                if type(v) == "table" then Mux._updateState[k] = v end
            end
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

-- Reset the startup-reminder skip counter for every known target (used by the
-- wipe reload path).
function Mux.clearUpdateSnooze()
    for _, st in pairs(Mux._updateState) do
        if type(st) == "table" then st.remindSkip = 0 end
    end
    saveUpdateState()
end

-- ── Reinstall primitive (shared by the updater and devmode) ───────────────────
--
-- Delete every file Muxlet persists (everything inside Muxlet_persistent) so the
-- next load behaves like a brand-new profile: default settings, no saved
-- workspaces/themes/rules, welcome dialog shown again. Best-effort; missing dir is
-- fine. Kept flat (no recursion) because Muxlet only writes files there. The
-- directory itself is left in place (settings.lua recreates it on load anyway) —
-- only its contents need to go.
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
    end)
end

-- Reinstall Muxlet from a local .mpackage. CRITICAL: this is deferred to a
-- runtime tempTimer(0) so the uninstall does NOT run while a package-owned
-- alias/script (e.g. the "mux" alias that called us) is still on the Lua stack.
-- Uninstalling the very script that is executing frees it mid-run and crashes
-- Mudlet — that is the long-standing "mux reload crashes" bug. From a runtime
-- timer the triggering alias has already returned, so the teardown is safe.
--   opts.wipe       delete persisted state between uninstall and install (fresh profile)
--   opts.resetAfter call resetProfile() after a successful reinstall (the update flow
--                   wants this; devmode's "mux reload" doesn't — a dev mid-session
--                   probably has other state they don't want silently reset).
--
-- Why resetAfter is needed at all: installPackage/uninstallPackage only add/remove
-- that package's own Trigger/Timer/Alias/Script/Key XML subtree (verified against
-- Mudlet's own source) — they never clear registerAnonymousEventHandler's handler
-- map, never touch plain Lua global tables, and never reset the Lua VM. Stale
-- handlers/globals from the old code can legitimately survive a reinstall, which
-- is exactly the "needs a full profile close/reopen to behave correctly" problem —
-- resetProfile() is the one thing in Mudlet that actually clears all of that.
function Mux._reinstallPackage(path, opts)
    opts = opts or {}
    local doWipe = opts.wipe and true or false
    local resetAfter = opts.resetAfter and true or false
    local wipeFn = Mux._wipePersistentDir   -- capture before teardown
    tempTimer(0, function()
        if table.contains(getPackages(), "Muxlet") then
            pcall(uninstallPackage, "Muxlet")   -- fires the sysUninstallPackage teardown
        end
        if doWipe and wipeFn then pcall(wipeFn) end
        -- installPackage is synchronous (loads and runs the new package's scripts
        -- before returning), so its result here is authoritative. Report it with raw
        -- cecho rather than Mux._echo — the table that function belonged to was just
        -- torn down and rebuilt, and we want this message to survive either way.
        local ok, err = installPackage(path)
        if ok then
            cecho("\n<green>[Muxlet]<reset> Update installed. Run <cyan>mux version<reset> to confirm the new build.\n")
            if resetAfter then
                cecho(RESET_NOTICE)
                pcall(resetProfile)
            end
        else
            cecho(string.format(
                "\n<red>[Muxlet]<reset> Reinstall failed (%s). Install manually from <cyan>%s<reset>\n",
                tostring(err or "unknown error"), path))
        end
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

-- Bare "major.minor.patch" of a version string (drops any "-sha" suffix).
local function baseVersionOf(v)
    return (tostring(v or "0")):match("^(%d[%d%.]*)") or "0"
end

-- Short commit sha a version string was cut from ("2.1.0-a3f91cd" → "a3f91cd"),
-- or nil for a bare production version.
local function shaOf(v)
    return (tostring(v or "")):match("^%d[%d%.]*%-(%w+)$")
end

-- True if a version string is a pre-release/dev build (anything past a bare
-- semver — same test devmode uses).
local function isPreOf(v)
    v = tostring(v or "")
    if v == "" or v == "unknown" then return false end
    return baseVersionOf(v) ~= v
end

local function installedBaseVersion() return baseVersionOf(Mux._version) end

-- The host's own installed version string, from its own reader if given, else
-- getPackageInfo(updatePackageName). "0" (never an update) if nothing is
-- registered or resolvable, so callers never need a separate nil-guard.
local function hostInstalledVersion()
    local host = Mux._hostUpdate
    if not host then return "0" end
    if host.installedVersion then
        local ok, v = pcall(host.installedVersion)
        if ok and v and tostring(v) ~= "" then return tostring(v) end
    end
    local info = host.packageName and getPackageInfo(host.packageName)
    return (info and info.version) or "0"
end

-- ── Display labels ────────────────────────────────────────────────────────────
--
-- "version" is reserved for a finished production release (always "vX.Y.Z").
-- "build" means one specific commit of a pre-release ("X.Y.Z-sha") — a
-- pre-release NEVER gets a "v" prefix, sha or not, so the two channels never
-- read as interchangeable in the dialog.

-- Label for a release/prerelease candidate or changelog entry.
local function releaseLabel(version, kind, sha)
    version = version or "?"
    if kind == "prerelease" then
        if sha and sha ~= "" then return version .. "-" .. sha:sub(1, 7) end
        return version
    end
    return "v" .. version
end

-- Label for an arbitrary installed-version string, using the same rule.
local function installedLabelOf(v)
    if isPreOf(v) then
        local sha = shaOf(v)
        return sha and (baseVersionOf(v) .. "-" .. sha) or baseVersionOf(v)
    end
    return "v" .. baseVersionOf(v)
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

-- `target` tags which repo/product this candidate belongs to ("muxlet" or
-- "host"), so downstream code (install, labels, state) knows what it's for
-- without needing a second parameter threaded everywhere.
local function parseRelease(r, target)
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
        target      = target,
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
-- `installedVer` is the version string to compare against (Mux._version, or a
-- host's own installed version); `state` is that target's persisted state
-- table (stateFor("muxlet") or stateFor("host")). Returns the chosen candidate
-- or nil.
local function chooseUpdate(cands, includePre, installedVer, state)
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

    local iVer = baseVersionOf(installedVer)
    local iPre = isPreOf(installedVer)
    local iRef = shaOf(installedVer) or (state and state.installedRef)

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
    -- Trim a leading/trailing run of blank lines (e.g. a trailing blank before
    -- build.yml's injected "**Commit:**" line) so it doesn't render as dead space
    -- at the end of the section. Interior blank lines (paragraph breaks) are left
    -- alone.
    body = body:match("^%s*(.-)%s*$") or ""
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
    -- 5.4 px/char (was 6.4): real proportional-font wrapping packs noticeably
    -- more characters per line than a flat average-width guess, and this repo's
    -- commit-message-derived bullets run long (100-250+ chars is common) — at
    -- the old ratio, the per-line wrap-count overestimate compounded across a
    -- dense changelog body into a large, very visible blank gap before the
    -- footer (nothing to do with the earlier trailing-blank-line fix below).
    local charsPerLine = math.max(24, math.floor(width / 5.4))
    local lines = 0
    for seg in (html .. "<br>"):gmatch("(.-)<br>") do
        local plain = seg:gsub("<[^>]->", "")
        plain = plain:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        if plain:match("^%s*$") then
            -- Blank-line separators render at mdToHtml's dedicated 6px font-size,
            -- not a full text line — counting them as a full line here is exactly
            -- the same class of overestimate as the wrap-count one above.
            lines = lines + 0.4
        else
            lines = lines + math.max(1, math.ceil(#plain / charsPerLine))
        end
    end
    -- +17 (one line) of trailing breathing room below the last line of text,
    -- not the 5+ lines that came from un-trimmed trailing blank lines in the
    -- source body, and not zero either.
    return math.max(22, math.ceil(lines * 17) + 17)
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
Mux._updateAutomatic = Mux._updateAutomatic or false

local function closeUpdateDialog()
    if Mux._updateDialog then
        local d = Mux._updateDialog
        pcall(function() d:close() end)
        Mux._updateDialog = nil
        if Mux._fitDialog == d then Mux._fitDialog = nil end
    end
end

-- Download the chosen release's package asset and install it in place.
-- cand.target ("muxlet" or "host") decides the install identity: Muxlet's own
-- reinstall keeps its persistent-dir-wipe-capable dance; a host either uses its
-- own updateInstall override or a plain install/uninstall on updatePackageName.
local function installFromRelease(cand)
    if not cand then return end
    local isHost = cand.target == "host"
    local host   = isHost and Mux._hostUpdate or nil
    local repo   = isHost and host and host.repo or MUXLET_REPO

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
            .. "  Download it manually from <cyan>%s<reset>\n", cand.tag or "?", releasesPage(repo)))
        return
    end

    Mux._echo(string.format(
        "\n<yellow>[Muxlet]<reset> Downloading %s <cyan>%s<reset>...\n",
        cand.kind == "prerelease" and "pre-release" or "release", cand.tag or "?"))

    local pkg = getMudletHomeDir() .. "/" .. (isHost and "Mux_host_update.mpackage" or "Muxlet_update.mpackage")

    if Mux._updateInstallDone then killAnonymousEventHandler(Mux._updateInstallDone) end
    if Mux._updateInstallErr  then killAnonymousEventHandler(Mux._updateInstallErr)  end

    Mux._updateInstallDone = registerAnonymousEventHandler("sysDownloadDone", function(_, filename)
        if filename ~= pkg then return end
        killAnonymousEventHandler(Mux._updateInstallDone); Mux._updateInstallDone = nil
        if Mux._updateInstallErr then killAnonymousEventHandler(Mux._updateInstallErr); Mux._updateInstallErr = nil end

        -- Record what we are about to install BEFORE tearing the package down, so
        -- the freshly loaded build knows which pre-release commit it now is even if
        -- the version string ever lacks the sha suffix.
        local st = stateFor(isHost and "host" or "muxlet")
        st.installedRef = preRef(cand) or st.installedRef
        st.installedTag = cand.tag
        st.remindSkip   = 0
        saveUpdateState()

        Mux._echo("\n<yellow>[Muxlet]<reset> Installing update...\n")
        if isHost then
            if host.install then
                pcall(host.install, pkg)
                Mux._echo(RESET_NOTICE)
                pcall(resetProfile)
            else
                local pkgName = host.packageName
                if pkgName and table.contains(getPackages(), pkgName) then pcall(uninstallPackage, pkgName) end
                local ok, err = installPackage(pkg)
                if ok then
                    Mux._echo(RESET_NOTICE)
                    pcall(resetProfile)
                else
                    Mux._echo(string.format(
                        "\n<red>[Muxlet]<reset> Install failed (%s). Install manually from <cyan>%s<reset>\n",
                        tostring(err or "unknown error"), pkg))
                end
            end
        else
            Mux._reinstallPackage(pkg, { resetAfter = true })
        end
    end)

    Mux._updateInstallErr = registerAnonymousEventHandler("sysDownloadError", function(_, filename)
        if filename ~= pkg then return end
        killAnonymousEventHandler(Mux._updateInstallErr); Mux._updateInstallErr = nil
        if Mux._updateInstallDone then
            killAnonymousEventHandler(Mux._updateInstallDone); Mux._updateInstallDone = nil
        end
        Mux._echo(string.format(
            "\n<red>[Muxlet]<reset> Download failed. Install manually from <cyan>%s<reset>\n", releasesPage(repo)))
    end)

    downloadFile(pkg, url)
end

-- Build the "intro + Changes + per-version changelog" body spec list for one
-- update target. `displayName` is the product name for the intro sentence
-- ("Muxlet", or a host's own label); `installedVer` is the version string to
-- compare against (Mux._version, or a host's own installed version).
local function buildTargetBodySpecs(displayName, cand, changelog, installedVer)
    local iVer      = baseVersionOf(installedVer)
    local isPre     = cand.kind == "prerelease"
    local haveLabel = installedLabelOf(installedVer)

    local verText
    if isPre and cand.version == iVer then
        verText = string.format(
            "A new build of the <b>%s</b> pre-release is available.<br>"
            .. "<span style='color:rgba(120,140,190,255);'>You have build <b>%s</b>. "
            .. "The latest build is <b>%s</b>.</span>",
            escapeHtml(cand.version or "?"),
            escapeHtml(haveLabel),
            escapeHtml(releaseLabel(cand.version, cand.kind, cand.sha)))
    elseif isPre then
        verText = string.format(
            "A newer <b>pre-release</b> of %s is available.<br>"
            .. "<span style='color:rgba(120,140,190,255);'>You have <b>%s</b>. "
            .. "Latest pre-release is <b>%s</b>.</span>",
            escapeHtml(displayName), escapeHtml(haveLabel),
            escapeHtml(releaseLabel(cand.version, cand.kind, cand.sha)))
    else
        verText = string.format(
            "A new version of <b>%s</b> is available.<br>"
            .. "<span style='color:rgba(120,140,190,255);'>You have <b>%s</b>. "
            .. "Latest is <b>v%s</b>.</span>",
            escapeHtml(displayName), escapeHtml(haveLabel), escapeHtml(cand.version or "?"))
    end

    local specs = {}
    specs[#specs + 1] = { type = "richText", html = verText, rowHeight = estimateRichHeight(verText) + 4 }
    specs[#specs + 1] = { type = "divider", label = "Changes", static = true }

    if changelog and #changelog > 0 then
        for idx, entry in ipairs(changelog) do
            local label = releaseLabel(entry.version, entry.kind, entry.sha)
            local header
            if entry.kind == "prerelease" and entry == cand and entry.version == iVer then
                header = label .. "  (updated pre-release build)"
            elseif entry.kind == "prerelease" then
                header = label .. "  (pre-release)"
            else
                header = label
            end
            -- Only the newest entry starts expanded; older ones are collapsed by
            -- default so a long changelog doesn't spam the dialog.
            specs[#specs + 1] = { type = "divider", label = header, _collapsed = idx > 1 }
            local html = mdToHtml(entry.body)
            if html == "" then html = "<span style='color:rgba(105,125,180,255);'>No notes for this release.</span>" end
            specs[#specs + 1] = { type = "richText", html = html, rowHeight = estimateRichHeight(html) }
        end
    else
        specs[#specs + 1] = { type = "richText",
            html = "<span style='color:rgba(105,125,180,255);'>No release notes found.</span>",
            rowHeight = 28 }
    end
    return specs
end

-- Build a ScrollBox + Geyser.Label + Mux.ui.buildForm directly into a tab's own
-- .content — the same pattern properties.lua's grouped-tabs branch already
-- uses — and wire onLayoutChange to the same auto-fit machinery Settings and
-- Properties already rely on (Mux._scheduleFit/Mux._ownerDialog walk up to
-- whichever ancestor is flagged _isDialogRoot).
local function mountTabForm(tab, specs, prefix)
    if tab.contentBg then tab.contentBg:echo(""); tab.contentBg:hide() end
    tab.content:show()
    local tcw = tab.content:get_width(); if tcw < 50 then tcw = 460 end
    local theme = Mux.activeTheme() or {}
    local bg    = (theme.ui and theme.ui.bg) or "rgb(18,18,26)"
    local sb = Geyser.ScrollBox:new(
        { name = prefix .. "_sb", x = 0, y = 0, width = "100%", height = "100%" }, tab.content)
    local lbl = Geyser.Label:new(
        { name = prefix .. "_body", x = 0, y = 0, width = tcw - 8, height = 10 }, sb)
    lbl:setStyleSheet(string.format("background:%s; border:none;", bg))
    Mux.ui.buildForm(lbl, specs, {
        width = tcw - 8,
        prefix = prefix,
        onLayoutChange = function(h)
            tab._muxContentH = h
            Mux._scheduleFit(Mux._ownerDialog(tab))
        end,
    })
end

-- Build (or rebuild) the update dialog for a chosen candidate + changelog entries.
-- opts.automatic: true when this dialog was raised by the silent startup check;
-- false for a user-initiated check ("mux version" / the settings "Check now"
-- button). Only the automatic case offers "Remind Me Later"/"Never Check
-- Automatically" — a manual check already told the user exactly what they asked
-- for, so those two don't make sense there.
-- opts.muxletCand/opts.muxletChangelog: only set when hosted AND a required
-- Muxlet bump is pending — adds a second "Muxlet" tab showing what that bump
-- changes. Omitted (the common case): single content, no tab bar at all.
function Mux.showUpdateDialog(cand, changelog, opts)
    ensureRichWidget()
    closeUpdateDialog()

    cand      = cand or Mux._updateCandidate or {}
    changelog = changelog or Mux._changelog or {}
    opts      = opts or {}
    local automatic = opts.automatic
    if automatic == nil then automatic = Mux._updateAutomatic end
    Mux._updateCandidate = cand
    Mux._changelog       = changelog
    Mux._updateAutomatic = automatic and true or false

    local host       = Mux._hostUpdate
    local isHostCand = host ~= nil and cand.target == "host"
    local muxletCand      = opts.muxletCand
    local muxletChangelog = opts.muxletChangelog or {}
    local showTabs        = isHostCand and muxletCand ~= nil

    local displayName  = isHostCand and host.label or "Muxlet"
    local installedVer = isHostCand and hostInstalledVersion() or Mux._version
    local bodySpecs    = buildTargetBodySpecs(displayName, cand, changelog, installedVer)

    local footerSpecs = {
        { type = "button", label = "Update Now", style = "primary", _noReset = true,
            onClick = function()
                closeUpdateDialog()
                -- Transparent Muxlet bump: if the host declares a required Muxlet
                -- version the current install doesn't meet, upgrade Muxlet first
                -- (reusing the same primitive that powers the one-time boot gate)
                -- and only then install the host's own update. One click either way.
                if isHostCand and host.requiredMuxletVersion
                   and Mux._versionIsNewer(host.requiredMuxletVersion, Mux._version) then
                    Mux.ensureVersion(host.requiredMuxletVersion, host.requiredMuxletUrl, function()
                        installFromRelease(cand)
                    end)
                else
                    installFromRelease(cand)
                end
            end },
    }
    -- "Remind Me Later"/"Never Check Automatically" only make sense when Muxlet
    -- raised this dialog on its own; a user who typed "mux version" or clicked
    -- "Check for updates now" already got the answer they asked for, and the X
    -- closes the dialog without changing any of that state either way.
    if automatic then
        local ns  = isHostCand and host.settingsNamespace or "muxupdate"
        local key = isHostCand and "host" or "muxlet"
        footerSpecs[#footerSpecs + 1] = { type = "button", label = "Remind Me Later", _noReset = true,
            onClick = function()
                closeUpdateDialog()
                stateFor(key).remindSkip = 5
                saveUpdateState()
            end }
        footerSpecs[#footerSpecs + 1] = { type = "button", label = "Never Check Automatically",
            style = "danger", _noReset = true,
            onClick = function()
                closeUpdateDialog()
                Mux.settings.set(ns, "update_check_enabled", false)
                stateFor(key).remindSkip = 0
                saveUpdateState()
            end }
    end

    local bodyH   = Mux.ui.formHeight(bodySpecs, {})
    local footerH = Mux.ui.formHeight(footerSpecs, {})

    local d = Mux.createDialog({
        title     = isHostCand and (host.label .. " Update") or "Muxlet Update",
        width     = 480,
        height    = bodyH + footerH + 40,   -- +chrome estimate; the actual fit/pin below correct this exactly
        singleton = "mux_update",
        maxHeightPct = 0.8,
    })
    if not d then return end
    if d.contentBg then d.contentBg:echo(""); d.contentBg:hide() end
    Mux._updateDialog = d

    if showTabs then
        -- Two real tabs, the same machinery Settings/Properties already use
        -- (MuxSurface:enableTabs/:addTab, Mux._fitDialogToActiveTab auto-fit) —
        -- not a bespoke widget. dialog.lua's :pinFooter already knows how to
        -- shrink the tab viewport instead of a mountForm scrollbox.
        d._isDialogRoot = true
        Mux._fitDialog  = d
        local prevOnClose = d.onClose
        d.onClose = function()
            if Mux._fitDialog == d then Mux._fitDialog = nil end
            if prevOnClose then prevOnClose() end
        end
        d:enableTabs({ noDefaultTab = true })

        local hostTab = d:addTab(host.label)
        hostTab.renamable = false; hostTab.closeable = false; hostTab.movable = false
        hostTab.contentable = false; hostTab.contextMenu = false
        mountTabForm(hostTab, bodySpecs, "mux_update_host")

        local muxletSpecs = buildTargetBodySpecs("Muxlet", muxletCand, muxletChangelog, Mux._version)
        local muxletTab = d:addTab("Muxlet")
        muxletTab.renamable = false; muxletTab.closeable = false; muxletTab.movable = false
        muxletTab.contentable = false; muxletTab.contextMenu = false
        mountTabForm(muxletTab, muxletSpecs, "mux_update_muxlet")

        d:activateTab(hostTab.id)
    else
        d:mountForm(bodySpecs, { prefix = "mux_update_f" })
    end

    d:pinFooter(footerSpecs, { prefix = "mux_update_ft" })
end

-- ── Version check ─────────────────────────────────────────────────────────────

-- Which target this whole check/dialog cycle is primarily about: the
-- registered host if one exists (it always goes first), else Muxlet itself.
local function primaryTargetKey()  return Mux._hostUpdate and "host" or "muxlet" end
local function primaryNamespace()  return (Mux._hostUpdate and Mux._hostUpdate.settingsNamespace) or "muxupdate" end

-- Fetch Muxlet's own releases (independent of any host registration) and
-- build the candidate + changelog range for a required-Muxlet-version bump,
-- so the dialog's second tab can show what that bump actually changes.
-- cb(cand, changelog) runs with (nil, nil) if the exact required version
-- can't be found in the releases list (network error, unlisted tag, etc.) —
-- callers treat that as "skip the tab," not a hard failure.
local function fetchMuxletBumpChangelog(requiredVersion, cb)
    local tmp = getMudletHomeDir() .. "/mux_releases_bump.json"

    local function cleanup()
        if Mux._bumpDlHandler then killAnonymousEventHandler(Mux._bumpDlHandler); Mux._bumpDlHandler = nil end
        if Mux._bumpDlErrHandler then killAnonymousEventHandler(Mux._bumpDlErrHandler); Mux._bumpDlErrHandler = nil end
    end
    cleanup()

    Mux._bumpDlHandler = registerAnonymousEventHandler("sysDownloadDone", function(_, filename)
        if filename ~= tmp then return end
        cleanup()
        local file = io.open(tmp, "r")
        if not file then cb(nil, nil); return end
        local content = file:read("*a"); file:close()
        local releases = yajl.to_value(content)
        if type(releases) ~= "table" then cb(nil, nil); return end

        local cands = {}
        for _, r in ipairs(releases) do
            if r.tag_name and not r.draft then cands[#cands + 1] = parseRelease(r, "muxlet") end
        end
        local target
        for _, c in ipairs(cands) do
            if c.version == requiredVersion then target = c; break end
        end
        if not target then cb(nil, nil); return end
        cb(target, buildChangelog(cands, target, installedBaseVersion()))
    end)

    Mux._bumpDlErrHandler = registerAnonymousEventHandler("sysDownloadError", function(_, filename)
        if filename ~= tmp then return end
        cleanup()
        cb(nil, nil)
    end)

    downloadFile(tmp, releasesUrl(MUXLET_REPO))
end

-- Fetch the releases JSON, decide on an update, and either open the dialog or
-- report status. silent=true suppresses the "checking"/"up to date" chatter.
-- When a host is registered, its repo is checked instead of Muxlet's own — see
-- Mux.configureHost's doc comment.
function Mux.checkForUpdates(silent)
    if tostring(Mux._version or "") == "unknown" then
        if not silent then
            Mux._echo("\n<yellow>[Muxlet]<reset> Can't read the installed version — skipping update check.\n")
        end
        return
    end

    local host   = Mux._hostUpdate
    local target = primaryTargetKey()
    local ns     = primaryNamespace()
    local repo   = host and host.repo or MUXLET_REPO

    local includePre = Mux.settings.get(ns, "update_include_prereleases") and true or false
    local modeText    = includePre and "stable + pre-releases" or "stable releases only"

    if not silent then
        Mux._echo(string.format(
            "\n<cyan>[Muxlet]<reset> Checking releases for updates <dim_grey>(%s)<reset>...\n",
            modeText))
    end

    local tmp = getMudletHomeDir() .. "/mux_releases.json"

    local function cleanup()
        if Mux._updateDlHandler then
            killAnonymousEventHandler(Mux._updateDlHandler); Mux._updateDlHandler = nil
        end
        if Mux._updateDlErrHandler then
            killAnonymousEventHandler(Mux._updateDlErrHandler); Mux._updateDlErrHandler = nil
        end
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
            if r.tag_name and not r.draft then cands[#cands + 1] = parseRelease(r, target) end
        end

        local installedVer = host and hostInstalledVersion() or Mux._version
        local chosen = chooseUpdate(cands, includePre, installedVer, stateFor(target))
        if not chosen then
            if not silent then
                Mux._echo(string.format(
                    "<cyan> You are up to date <white>(%s)<cyan> <dim_grey>(%s)<reset>.\n",
                    installedLabelOf(installedVer), modeText))
            end
            return
        end

        local changelog = buildChangelog(cands, chosen, baseVersionOf(installedVer))

        if host and host.requiredMuxletVersion and Mux._versionIsNewer(host.requiredMuxletVersion, Mux._version) then
            fetchMuxletBumpChangelog(host.requiredMuxletVersion, function(muxletCand, muxletChangelog)
                Mux.showUpdateDialog(chosen, changelog, {
                    automatic = silent, muxletCand = muxletCand, muxletChangelog = muxletChangelog,
                })
            end)
        else
            Mux.showUpdateDialog(chosen, changelog, { automatic = silent })
        end
    end)

    Mux._updateDlErrHandler = registerAnonymousEventHandler("sysDownloadError", function(_, filename)
        if filename ~= tmp then return end
        cleanup()
        if not silent then
            Mux._echo(string.format(
                "\n<red>[Muxlet]<reset> Couldn't reach GitHub. Check releases at <cyan>%s<reset>\n",
                releasesPage(repo)))
        end
    end)

    downloadFile(tmp, releasesUrl(repo))
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
-- This is also what powers the transparent Muxlet bump in the hosted update
-- dialog's "Update Now" (see Mux.showUpdateDialog) — the one-time boot gate and
-- the live "you also need a newer Muxlet" case are the same operation.
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
            "Mux.ensureVersion: installed Muxlet %s does not satisfy required %s, and no url was given to upgrade.",
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

-- Register the two toggles + "Check for updates now" button under a given
-- settings namespace — the same trio Muxlet's own "muxupdate" namespace has
-- (those live in settings.lua/below; this is only for a registered host's own
-- namespace, which Muxlet has no way to know ahead of time). `tab`, if given,
-- anchors the namespace to an existing settings tab (first-registered-key-wins,
-- same rule Mux.settings.register always uses) — pass it when the host already
-- has its own settings living somewhere and wants this row to land there too,
-- instead of spawning a new tab named after the namespace.
local function registerHostSettingsRows(ns, tab)
    Mux.settings.register(ns, "update_check_enabled", {
        tab         = tab,
        label       = "Check for updates on startup",
        description = "When Mudlet opens, quietly check this repo's releases and offer any newer build.",
        default     = false,
    })
    Mux.settings.register(ns, "update_include_prereleases", {
        label       = "Include pre-releases",
        description = "Also offer rolling pre-release builds (tagged without a leading 'v'). "
                   .. "Pre-releases can update in place even when the version number is unchanged.",
        default     = false,
    })
    Mux.settings.registerRow(ns, {
        type    = "button",
        label   = "Check for updates now",
        style   = "primary",
        desc    = "Check this repo's releases immediately, honouring the pre-release setting above.",
        onClick = function()
            if Mux.checkForUpdates then Mux.checkForUpdates(false) end
        end,
    })
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
--                                  to self-upgrade. Usually left alone (false) when
--                                  updateRepo below is set, since that already
--                                  takes over the live-check cycle.
--   opts.includePrereleases (bool) true = also offer pre-release builds.
--   opts.defaultWorkspace (string) Workspace name applied by `mux reset` / first
--                                  Mux.fullStart(). Must already be registered.
--
--   -- Reuse Muxlet's update system for your own package too (all optional
--   -- except updateRepo; at most one host may be registered):
--   opts.updateRepo              (string)   "owner/repo" to poll via GitHub
--                                  Releases INSTEAD of Muxlet's own — opts in.
--                                  Muxlet's own self-polling stops; this repo
--                                  goes first and is the only thing checked.
--   opts.requiredMuxletVersion   (string)   Muxlet version this build needs —
--                                  typically the same constant already computed
--                                  for a Mux.ensureVersion boot gate. Optional:
--                                  omit to never show a Muxlet tab/bump.
--   opts.requiredMuxletUrl       (string)   Download URL for that version —
--                                  ditto, typically the same constant already
--                                  computed for the boot gate.
--   opts.updateLabel             (string)   Display name in the dialog/settings
--                                  tab. Default: the last path segment of
--                                  updateRepo.
--   opts.updatePackageName       (string)   getPackages()/installPackage
--                                  identity. Default: same as updateLabel.
--   opts.updateInstall           (function(assetPath)) Override instead of a
--                                  plain install/uninstall on updatePackageName —
--                                  only needed for anything unusual (Muxlet's
--                                  own reinstall needs its persistent-dir wipe
--                                  dance, for example).
--   opts.updateInstalledVersion  (function() -> string) Override instead of
--                                  getPackageInfo(updatePackageName).version.
--   opts.updateSettingsNamespace (string)   Namespace for the check-enabled/
--                                  prereleases/check-now rows. Default: same
--                                  as updateLabel. Pass an existing namespace
--                                  (e.g. "f2t") so they render alongside that
--                                  namespace's other settings.
--   opts.updateSettingsTab       (string)   Anchors updateSettingsNamespace to
--                                  a tab (only matters/takes effect if that
--                                  namespace has no other registered settings
--                                  already anchoring one — e.g. pass an
--                                  existing top-level tab like "Fed2-Tools" to
--                                  land Update as a sub-tab there). Default:
--                                  "<updateLabel>/Update", mirroring Muxlet's
--                                  own "Muxlet/Update" shape — a package with
--                                  no other settings still gets a properly
--                                  nested tab instead of a flat one. Muxlet's
--                                  own "Muxlet/Update" tab steps aside once a
--                                  host is registered (see tabHierarchy() in
--                                  settings.lua) — this moves it, doesn't
--                                  duplicate it.
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

    if opts.updateRepo then
        local label = opts.updateLabel or opts.updateRepo:match("/(.+)$") or opts.updateRepo
        local ns    = opts.updateSettingsNamespace or label
        -- Mirrors Muxlet's own "Muxlet/Update" shape by default: a dedicated
        -- "Update" sub-tab nested under the host's own parent tab, even if the
        -- host has no other settings registered anywhere yet. Muxlet's own
        -- Update tab steps aside (see tabHierarchy() in settings.lua) once
        -- Mux._hostUpdate is set below, so this is a move, not a duplicate.
        local tab = opts.updateSettingsTab or (label .. "/Update")
        Mux._hostUpdate = {
            repo                  = opts.updateRepo,
            label                 = label,
            packageName           = opts.updatePackageName or label,
            install               = opts.updateInstall,
            installedVersion      = opts.updateInstalledVersion,
            settingsNamespace     = ns,
            requiredMuxletVersion = opts.requiredMuxletVersion,
            requiredMuxletUrl     = opts.requiredMuxletUrl,
        }
        registerHostSettingsRows(ns, tab)
    end
end

-- ── Startup check ─────────────────────────────────────────────────────────────

-- Deferred 15s so a hosting package's own muxletReady handler (which typically
-- fires within that window) has time to call Mux.configureHost({updateRepo=...})
-- first — the enable/remind-skip check below re-reads Mux._hostUpdate at fire
-- time, not at schedule time, so a host registered after this function runs but
-- before the timer fires is still picked up correctly.
local function muxStartupUpdateCheck()
    tempTimer(15, function()
        local ns = primaryNamespace()
        if not Mux.settings.get(ns, "update_check_enabled") then return end

        local st   = stateFor(primaryTargetKey())
        local skip = tonumber(st.remindSkip) or 0
        if skip > 0 then
            st.remindSkip = skip - 1
            saveUpdateState()
            return
        end

        Mux.checkForUpdates(true)
    end)
end

muxStartupUpdateCheck()

-- ── Graphical "Check now" button on Muxlet's own Update settings tab ──────────
-- Appended after the two toggles via settings.registerRow (settings.lua loads
-- first, so the hook exists). Runs a visible (non-silent) check so the user gets
-- "up to date" feedback in the console and the update dialog if one is found.
-- (A registered host's equivalent row is added by registerHostSettingsRows,
-- under its own namespace, when Mux.configureHost({updateRepo=...}) runs.)
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
