-- Muxlet — Dev Mode: local build auto-reload and manual reload helpers
--
-- Auto-reload: build.ps1 -Profile <name> writes a stamp file to the profile
-- directory after running muddler. A recursive 30-second timer watches for
-- stamp changes and performs uninstallPackage + installPackage for a clean reload.
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
        Mux._log("[mux] Dev mode active — monitoring for new local builds")
        tempTimer(30, muxDevmodeCheck)
        return
    end

    -- Stamp changed: a new build was deployed; reload.
    -- Update stamp before reload so the newly loaded package sees the same stamp
    -- on its first check and skips its own spurious-reload guard correctly.
    Mux._devLastStamp = stamp
    Mux._echo("\n<yellow>[Muxlet]<reset> New local build detected — reloading...\n")
    local pkgPath = getMudletHomeDir() .. "/Muxlet.mpackage"
    muxDevmodeDoReload(pkgPath)
    -- No reschedule: the freshly installed package starts its own timer on load.
end

-- Called by "mux reload [fresh]".
function Mux.devmodeReload(fresh)
    local pkgPath = getMudletHomeDir() .. "/Muxlet.mpackage"
    local f = io.open(pkgPath, "r")
    if not f then
        Mux._echo("\n<red>[Muxlet]<reset> No deployed build found in profile directory.\n")
        Mux._echo("\n<yellow>[Muxlet]<reset> Run: ./build.ps1 -Profile <your-profile-name>\n")
        return
    end
    f:close()

    if fresh then
        -- Reset the remind-skip counter so the update dialog fires on next load.
        Mux.settings.set("mux", "update_check_remind_skip", 0)
        Mux._echo("\n<yellow>[Muxlet]<reset> Settings reset — fresh-install path on next load.\n")
    end

    Mux._echo("\n<yellow>[Muxlet]<reset> Reloading Muxlet...\n")
    muxDevmodeDoReload(pkgPath)
end

-- Only start the polling timer if a stamp file already exists in the profile
-- directory.  Production installs never have this file, so the timer never
-- runs for end-users.  Developers who have run build.ps1 at least once will
-- have the file and get the auto-reload behaviour as normal.
local function muxDevmodeStart()
    local stampPath = getMudletHomeDir() .. "/Muxlet-rebuild.stamp"
    local probe = io.open(stampPath, "r")
    if not probe then return end
    probe:close()
    tempTimer(30, muxDevmodeCheck)
end

muxDevmodeStart()

Mux._log("mux_devmode loaded")
