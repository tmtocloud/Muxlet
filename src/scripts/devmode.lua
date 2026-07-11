-- Muxlet — Dev Mode: local build auto-reload and manual reload helpers
--
-- Auto-reload: `muddlet --profile <name>` deploys the freshly built package into
-- the profile directory and writes a SINGLE stamp file:
--     Muxlet-rebuild.stamp   contents: "<unix-ts>"   or   "<unix-ts> wipe"
-- A recursive 30-second timer watches the stamp. When it changes, Muxlet
-- reinstalls itself from the deployed package. A trailing "wipe" marker (written
-- by `muddlet --wipe`) additionally deletes all persisted Muxlet state first, so
-- the reload comes up exactly like a brand-new profile.
--
-- Manual reload:
--   mux reload         — reinstall from the deployed local build (keeps state)
--   mux reload wipe    — reinstall AND wipe all persisted state (fresh profile)
--
-- The actual reinstall runs through Mux._reinstallPackage (update.lua), which
-- defers the uninstall+install out of the current call stack. That is what stops
-- "mux reload" from crashing Mudlet: uninstalling the package while the "mux"
-- alias that triggered it is still on the Lua stack frees the running script
-- mid-execution.

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
        Mux._reinstallPackage(pkgPath, { wipe = wipe })
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

-- Called by "mux reload [wipe]".
function Mux.devmodeReload(wipe)
    local pkgPath = getMudletHomeDir() .. "/Muxlet.mpackage"
    local f = io.open(pkgPath, "r")
    if not f then
        Mux._echo("\n<red>[Muxlet]<reset> No deployed build found in profile directory.\n")
        Mux._echo("\n<yellow>[Muxlet]<reset> Run: ./muddlet --profile <name>\n")
        return
    end
    f:close()

    if wipe then
        Mux._echo("\n<yellow>[Muxlet]<reset> Wiping all Muxlet state — reloading as a fresh profile...\n")
    else
        Mux._echo("\n<yellow>[Muxlet]<reset> Reloading Muxlet...\n")
    end
    doReload(wipe)
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