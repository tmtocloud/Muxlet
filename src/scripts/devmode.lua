-- Muxlet — Dev Mode: local build auto-reload
--
-- `muddlet --profile <name>` deploys the freshly built package into the profile
-- directory and writes a SINGLE stamp file:
--     Muxlet-rebuild.stamp   contents: "<unix-ts>"   or   "<unix-ts> wipe"
-- A recursive 30-second timer watches the stamp. When it changes, Muxlet
-- reinstalls itself from the deployed package via Mux._reinstallPackage
-- (update.lua) — the same reinstall the real update system uses when a user
-- accepts an update — so a local rebuild takes effect without restarting
-- Mudlet. A trailing "wipe" marker (written by `muddlet --wipe`) additionally
-- deletes all persisted Muxlet state first, so the reload comes up exactly
-- like a brand-new profile.
--
-- The new code is active immediately after the reinstall; Mux._promptRestartRequired
-- (triggered via promptRestart below) offers a profile close/reopen for a fully
-- clean UI, but doesn't force one.
--
-- Mux._reinstallPackage defers the uninstall+install out of the current call
-- stack. That is what stops the reload from crashing Mudlet: uninstalling the
-- package while the timer callback that triggered it is still on the Lua
-- stack frees the running script mid-execution.

local STAMP_FILE = "/Muxlet-rebuild.stamp"

-- Stamp value seen at last check. nil = not yet observed this session.
Mux._devLastStamp = Mux._devLastStamp or nil

-- Read the stamp file → (token, wipeFlag). The first whitespace-delimited token
-- is the change-detection value; a trailing "wipe" marker requests a full wipe.
local function readStamp()
    local f = io.open(getMudletHomeDir() .. STAMP_FILE, "r")
    if not f then return nil, false end
    local raw = f:read("*a") or ""
    f:close()
    local token = raw:match("^%s*(%S+)")
    local wipe  = raw:lower():find("wipe") ~= nil
    return token, wipe
end

local function doReload(wipe)
    local pkgPath = getMudletHomeDir() .. "/Muxlet.mpackage"
    if Mux._reinstallPackage then
        -- promptRestart matches the real update flow (Mux.checkForUpdates) exactly,
        -- so a local rebuild reloads the same way an accepted update does.
        Mux._reinstallPackage(pkgPath, { wipe = wipe, promptRestart = true })
    else
        -- Fallback if update.lua's primitive is somehow unavailable: still defer
        -- out of the current stack so we don't crash on self-uninstall.
        tempTimer(0, function()
            if table.contains(getPackages(), "Muxlet") then pcall(uninstallPackage, "Muxlet") end
            installPackage(pkgPath)
        end)
    end
end

-- Recursive 30-second watcher. No-op when the stamp file is absent (production
-- installs never have it). Stops when Mux._devStopped is set (uninstall teardown).
local function muxDevmodeCheck()
    if Mux._devStopped then return end

    local stamp, wipe = readStamp()

    if not stamp or stamp == Mux._devLastStamp then
        Mux._devTimer = tempTimer(30, muxDevmodeCheck)
        return
    end

    if Mux._devLastStamp == nil then
        -- First observation: record but don't reload (prevents a spurious reload
        -- on every restart when the stamp file already exists).
        Mux._devLastStamp = stamp
        Mux._log("[mux] Dev mode active (stamp %s) — monitoring for new local builds", stamp)
        Mux._devTimer = tempTimer(30, muxDevmodeCheck)
        return
    end

    -- Stamp changed: a new build was deployed. Record before reloading so the
    -- freshly loaded package's first check sees the same stamp and doesn't
    -- immediately reload again.
    Mux._devLastStamp = stamp
    Mux._echo(string.format(
        "\n<yellow>[Muxlet]<reset> New local build detected (stamp %s%s) — reloading...\n",
        stamp, wipe and ", wipe" or ""))
    doReload(wipe)
    -- No reschedule: the freshly installed package starts its own timer on load.
end

-- Stop the watcher. Called from the uninstall teardown so the old timer can't keep
-- firing against the reinstalled package.
function Mux._stopDevmode()
    Mux._devStopped = true
    if Mux._devTimer then pcall(killTimer, Mux._devTimer); Mux._devTimer = nil end
end

-- Anything past a bare "major.minor.patch" (e.g. the "-a3f91cd" muddlet appends
-- for untagged local builds) marks this as a pre-release/dev build.
local function isPreRelease()
    return tostring(Mux._version or ""):match("^%d[%d%.]*$") == nil
end

-- Only start polling if a stamp file already exists in the profile directory.
-- Production installs never have this file, so the timer never runs for end-users.
local function muxDevmodeStart()
    Mux._devStopped = false   -- clear any stop flag left by a prior teardown
    local stamp = readStamp()
    if not stamp then return end

    if isPreRelease() then
        Mux._echo(string.format("\n<yellow>[Muxlet]<reset> Dev mode active (v%s, stamp %s)\n", Mux._version, stamp))
    end

    Mux._devTimer = tempTimer(30, muxDevmodeCheck)
end

muxDevmodeStart()

Mux._log("mux_devmode loaded")