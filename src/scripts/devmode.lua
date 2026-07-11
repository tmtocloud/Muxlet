-- Muxlet — Dev Mode: local build auto-reload and manual reload helpers
--
-- Auto-reload: muddlet --profile <name> writes a stamp file to the profile
-- directory after running muddler. A recursive 30-second timer watches for
-- stamp changes and performs uninstallPackage + installPackage for a clean reload.
-- When --fresh is passed to muddlet it also writes a fresh flag file; the
-- watcher detects it and reloads with fresh=true instead of false.
--
-- Manual reload:
--   mux reload        — upgrade path (preserves settings)
--   mux reload fresh  — resets update-skip counter, simulating a fresh install

-- Stamp value seen at last check. nil = not yet observed this session.
Mux._devLastStamp = Mux._devLastStamp or nil

local function muxDevmodeDoReload(pkgPath)
    if table.contains(getPackages(), "Muxlet") then
        uninstallPackage("Muxlet")
    end
    installPackage(pkgPath)
end

-- Recursive 30-second timer. Does nothing when the stamp file is absent
-- (standard production installs have no stamp file).
local function muxDevmodeCheck()
    local stampPath = getMudletHomeDir() .. "/Muxlet-rebuild.stamp"
    local file = io.open(stampPath, "r")

    if not file then
        tempTimer(30, muxDevmodeCheck)
        return
    end

    local stamp = file:read("*a"):match("^%s*(.-)%s*$")
    file:close()

    if stamp == Mux._devLastStamp then
        tempTimer(30, muxDevmodeCheck)
        return
    end

    if Mux._devLastStamp == nil then
        -- First observation: record stamp but don't reload. Prevents a spurious
        -- reload on every package restart when the stamp file already exists.
        Mux._devLastStamp = stamp
        Mux._log("[mux] Dev mode active (stamp %s) — monitoring for new local builds", stamp)
        tempTimer(30, muxDevmodeCheck)
        return
    end

    -- Stamp changed: a new build was deployed; check for the fresh flag.
    -- Update stamp before reload so the newly loaded package sees the same stamp
    -- on its first check and skips its own spurious-reload guard correctly.
    Mux._devLastStamp = stamp
    local freshPath = getMudletHomeDir() .. "/Muxlet-fresh.stamp"
    local freshFile = io.open(freshPath, "r")

    if freshFile then
        freshFile:close()
        os.remove(freshPath)
        Mux._echo(string.format("\n<yellow>[Muxlet]<reset> New local build detected (fresh, stamp %s) — reloading...\n", stamp))
        Mux.devmodeReload(true)
    else
        Mux._echo(string.format("\n<yellow>[Muxlet]<reset> New local build detected (stamp %s) — reloading...\n", stamp))
        local pkgPath = getMudletHomeDir() .. "/Muxlet.mpackage"
        muxDevmodeDoReload(pkgPath)
    end
    -- No reschedule: the freshly installed package starts its own timer on load.
end

-- Called by "mux reload [fresh]".
function Mux.devmodeReload(fresh)
    local pkgPath = getMudletHomeDir() .. "/Muxlet.mpackage"
    local f = io.open(pkgPath, "r")
    if not f then
        Mux._echo("\n<red>[Muxlet]<reset> No deployed build found in profile directory.\n")
        Mux._echo("\n<yellow>[Muxlet]<reset> Run: ./muddlet --profile <name>\n")
        return
    end
    f:close()

    if fresh then
        -- Reset the update-reminder skip so the update dialog fires on next load.
        if Mux.clearUpdateSnooze then Mux.clearUpdateSnooze() end
        Mux._echo("\n<yellow>[Muxlet]<reset> Settings reset — fresh-install path on next load.\n")
    end

    Mux._echo("\n<yellow>[Muxlet]<reset> Reloading Muxlet...\n")
    muxDevmodeDoReload(pkgPath)
end

-- Anything past a bare "major.minor.patch" (e.g. the "-a3f91cd" muddlet
-- appends for untagged local builds) marks this as a pre-release build.
local function isPreRelease()
    return Mux._version:match("^%d[%d%.]*$") == nil
end

-- Only start the polling timer if a stamp file already exists in the profile
-- directory.  Production installs never have this file, so the timer never
-- runs for end-users.  Developers who have run build.ps1 at least once will
-- have the file and get the auto-reload behaviour as normal.
local function muxDevmodeStart()
    local stampPath = getMudletHomeDir() .. "/Muxlet-rebuild.stamp"
    local probe = io.open(stampPath, "r")
    if not probe then return end
    local stamp = probe:read("*a"):match("^%s*(.-)%s*$")
    probe:close()

    if isPreRelease() then
        Mux._echo(string.format("\n<yellow>[Muxlet]<reset> Dev mode active (v%s, stamp %s)\n", Mux._version, stamp))
    end

    tempTimer(30, muxDevmodeCheck)
end

muxDevmodeStart()

Mux._log("mux_devmode loaded")