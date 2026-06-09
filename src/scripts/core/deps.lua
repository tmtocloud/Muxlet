-- Muxlet — Dependency bootstrap
--
-- Checks whether MDK (Mudlet Developer Kit) is installed one second after
-- package load (giving all packages time to initialise).  If not found,
-- downloads and installs MDK from the official GitHub release.
--
-- MDK provides: EMCO, LoggingConsole, SortBox, Chyron, TimerGauge,
--               TextGauge, Checkbox, Spinbox.
--
-- Detection: EMCO is MDK's flagship component; its presence means MDK loaded.

local mdkPackage = "MDK"
local mdkUrl     = "https://github.com/demonnic/MDK/releases/latest/download/MDK.mpackage"

-- Check the installed-package registry — accurate regardless of load order.
-- EMCO (a global MDK sets) is NOT reliable here because package scripts may
-- not have finished executing when this timer fires.
local function muxMdkPresent()
    return table.contains(getPackages(), mdkPackage)
end

local function muxInstallMdk()
    if not Mux.settings.get("mux", "auto_install_mdk") then
        Mux._log("MDK auto-install disabled by settings")
        return
    end

    if muxMdkPresent() then return end

    Mux._log("MDK not found — downloading from GitHub...")

    -- One-shot handler: fires when MDK finishes installing this session.
    registerAnonymousEventHandler("sysInstallPackage", function(_, name)
        if name ~= mdkPackage then return end
        Mux._log("MDK installed successfully; MDK features are now active.")
        -- Re-trigger MDK detection so factory functions work immediately.
        if Mux.mdk then
            Mux.mdk._detected = false
        end
    end, true)   -- true = one-shot; auto-deregisters after first matching fire

    installPackage(mdkUrl)
end

-- Defer one second so all other packages finish loading first.
tempTimer(1, muxInstallMdk)

Mux._log("mux_deps loaded — MDK check deferred 1s")
