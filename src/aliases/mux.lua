-- Muxlet — "mux" alias
-- @regex: ^mux(?:\s+(.+))?$

local args = matches[2]

if not args or args == "" then
    Mux.fullStart()
    return
end

local words = {}
for w in args:gmatch("%S+") do words[#words+1] = w end
local sub = words[1] and words[1]:lower() or ""

-- ── mux help ─────────────────────────────────────────────────────────────────
if sub == "help" then
    Mux._echo([[

<cyan>[Muxlet]<reset> Commands:
  mux                          — start mux (same as mux start)
  mux help                     — this message

  <white>Session<reset>
  mux start                    — enable mux (uses startup_workspace setting, or 'default')
  mux stop                     — disable mux, restore normal Mudlet console
  mux reset                    — re-apply startup_workspace (discard manual changes)
  mux status                   — show status overview

  <white>Pane Actions<reset>
  mux split v [ratio]          — split left / right  (vertical divider)
  mux split h [ratio]          — split top / bottom  (horizontal divider)
  mux zoom                     — zoom / unzoom focused pane
  mux swap                     — swap focused pane with its sibling in the split
  mux close                    — close focused pane
  mux float                    — float focused pane
  mux embed                    — embed / re-attach last floating pane
  mux titlebar                 — toggle titlebar on focused pane
  mux rename <name>            — rename focused pane
  mux lock                     — lock focused pane
  mux unlock                   — unlock focused pane
  mux new [name]               — create a new floating pane

  <white>Tab Actions (active tab in focused pane)<reset>
  mux tab add [name]           — add a new tab
  mux tab close                — close the active tab
  mux tab rename [name]        — rename active tab (dialog if no name given)
  mux tab lock                 — lock the active tab
  mux tab unlock               — unlock the active tab
  mux tab next                 — activate the next tab
  mux tab prev                 — activate the previous tab

  <white>Focus<reset>
  mux focus                    — show focused pane name
  mux focus next               — move focus to next pane
  mux focus prev               — move focus to previous pane

  <white>Workspaces<reset>
  mux workspace save <name>    — save full UI state as a named workspace
  mux workspace load <name>    — restore a saved workspace
  mux workspace list           — list all registered workspaces
  mux workspace delete <name>  — remove a saved workspace
  mux workspaces               — alias for: mux workspace list

  <white>Themes<reset>
  mux theme [name]             — show or switch active theme
  mux themes                   — list all registered themes

  <white>Keybinds<reset>
  mux keys                     — list all keybindings
  mux hint                     — show keybind hint overlay  (Alt+B)

  <white>Settings<reset>
  mux settings                 — toggle settings window
  mux settings list [ns]       — list settings for a namespace
  mux settings get ns.key      — show one setting
  mux settings set ns.key val  — change a setting

  <white>Debug<reset>
  mux debug [on|off]           — toggle debug output
  mux version                  — show version and check for updates

  <white>Dev<reset>
  mux reload                   — reinstall from local build (preserves settings)
  mux reload fresh             — reinstall and reset skip counter

]])

-- ── mux theme ────────────────────────────────────────────────────────────────
elseif sub == "theme" then
    if not words[2] then
        Mux._echo(string.format("\n<cyan>[Muxlet]<reset> Current theme: %s\n",
            Mux.currentTheme()))
    else
        local ok, err = Mux.settings.set("mux", "theme", words[2])
        if not ok then
            Mux._echo(string.format("\n<red>[Muxlet]<reset> %s\n", err or "unknown theme"))
        end
    end

elseif sub == "themes" then
    Mux._echo("\n<cyan>[Muxlet]<reset> Registered themes:\n")
    local names = {}
    for n in pairs(Mux._themes) do names[#names+1] = n end
    table.sort(names)
    for _, n in ipairs(names) do
        local tag = (n == Mux._activeThemeName) and " <green>(active)<reset>" or ""
        Mux._echo(string.format("  %s%s\n", n, tag))
    end

-- ── mux workspace ────────────────────────────────────────────────────────────
elseif sub == "workspace" then
    local action = words[2] and words[2]:lower() or ""
    if action == "save" then
        Mux.saveWorkspace(words[3])
    elseif action == "load" then
        if not words[3] then
            Mux._echo("\n<red>[Muxlet]<reset> Usage: mux workspace load <name>\n")
        else
            Mux.applyWorkspace(words[3])
        end
    elseif action == "list" or action == "" then
        Mux.listWorkspaces()
    elseif action == "delete" or action == "rm" then
        Mux.deleteWorkspace(words[3])
    else
        Mux._echo("\n<red>[Muxlet]<reset> Usage: mux workspace save|load|list|delete <name>\n")
    end

elseif sub == "workspaces" then
    Mux.listWorkspaces()

-- ── mux split ────────────────────────────────────────────────────────────────
elseif sub == "split" then
    local dir   = words[2] and words[2]:lower() or "v"
    local ratio = tonumber(words[3]) or 0.5
    if dir ~= "v" and dir ~= "h" then
        Mux._echo("\n<red>[Muxlet]<reset> Usage: mux split v [ratio] — split left/right (vertical divider)\n"
               .. "                       mux split h [ratio] — split top/bottom (horizontal divider)\n")
    else
        local internalDir = (dir == "v") and "h" or "v"
        Mux.splitFocused(internalDir, ratio)
    end

-- ── mux zoom ─────────────────────────────────────────────────────────────────
elseif sub == "zoom" then
    Mux.zoomFocused()

-- ── mux swap ─────────────────────────────────────────────────────────────────
elseif sub == "swap" then
    Mux.swapFocused()

-- ── mux close ────────────────────────────────────────────────────────────────
elseif sub == "close" then
    Mux.closeFocused()

-- ── mux float ────────────────────────────────────────────────────────────────
elseif sub == "float" then
    Mux.floatFocused()

-- ── mux embed ────────────────────────────────────────────────────────────────
elseif sub == "embed" then
    Mux.embedFocused()

-- ── mux titlebar ─────────────────────────────────────────────────────────────
elseif sub == "titlebar" then
    Mux.toggleTitlebarFocused()

-- ── mux rename ───────────────────────────────────────────────────────────────
elseif sub == "rename" then
    local newName = table.concat(words, " ", 2)
    Mux.renameFocused(newName)

-- ── mux lock / unlock ─────────────────────────────────────────────────────────
elseif sub == "lock" then
    Mux.lockFocused()

elseif sub == "unlock" then
    Mux.unlockFocused()

-- ── mux tab ───────────────────────────────────────────────────────────────────
elseif sub == "tab" then
    local action = words[2] and words[2]:lower() or ""
    if action == "add" then
        local name = words[3] and table.concat(words, " ", 3) or nil
        Mux.tabAdd(name)
    elseif action == "close" then
        Mux.tabClose()
    elseif action == "rename" then
        local name = words[3] and table.concat(words, " ", 3) or nil
        Mux.tabRename(name)
    elseif action == "lock" then
        Mux.tabLock()
    elseif action == "unlock" then
        Mux.tabUnlock()
    elseif action == "next" then
        Mux.tabNext()
    elseif action == "prev" or action == "previous" then
        Mux.tabPrev()
    else
        Mux._echo("\n<cyan>[Muxlet]<reset> Tab commands: add [name] | close | rename [name] | lock | unlock | next | prev\n")
    end

-- ── mux new ──────────────────────────────────────────────────────────────────
elseif sub == "new" then
    local name = words[2] and table.concat(words, " ", 2) or "Pane"
    Mux.newFloatingPane({ name = name })

-- ── mux focus ────────────────────────────────────────────────────────────────
elseif sub == "focus" then
    local action = words[2] and words[2]:lower()
    if action == "next" then
        Mux.focusNext()
    elseif action == "prev" or action == "previous" then
        Mux.focusPrev()
    else
        local fp = Mux._focusedPane
        if fp then
            Mux._echo(string.format("\n<cyan>[Muxlet]<reset> Focused: %s (%s)\n",
                fp.name, fp.id))
        else
            Mux._echo("\n<cyan>[Muxlet]<reset> No focused pane.\n")
        end
    end

-- ── mux settings ─────────────────────────────────────────────────────────────
elseif sub == "settings" then
    local rest = words[2] and table.concat(words, " ", 2) or ""
    if rest == "" then
        Mux.settings.toggle()
    else
        local sub2 = words[2] and words[2]:lower() or ""
        if sub2 == "list" then
            local ns = words[3] or "mux"
            Mux.settings.showList(ns)
        elseif sub2 == "get" and words[3] then
            local ns, key = words[3]:match("^([^%.]+)%.(.+)$")
            if ns and key then
                Mux.settings.showSetting(ns, key)
            else
                Mux._echo("\n<red>[Muxlet]<reset> Usage: mux settings get <ns>.<key>\n")
            end
        elseif sub2 == "set" and words[3] and words[4] then
            local ns, key = words[3]:match("^([^%.]+)%.(.+)$")
            if ns and key then
                local value = table.concat(words, " ", 4)
                Mux.settings.handleCommand(ns, "set " .. key .. " " .. value)
            else
                Mux._echo("\n<red>[Muxlet]<reset> Usage: mux settings set <ns>.<key> <value>\n")
            end
        elseif sub2 == "clear" and words[3] then
            local ns, key = words[3]:match("^([^%.]+)%.(.+)$")
            if ns and key then
                Mux.settings.handleCommand(ns, "clear " .. key)
            else
                Mux._echo("\n<red>[Muxlet]<reset> Usage: mux settings clear <ns>.<key>\n")
            end
        else
            Mux._echo("\n<red>[Muxlet]<reset> Usage: mux settings [list [ns] | get ns.key | set ns.key val | clear ns.key]\n")
        end
    end

-- ── mux keys ─────────────────────────────────────────────────────────────────
elseif sub == "keys" then
    Mux.listBindings()

elseif sub == "hint" then
    Mux._showHintOverlay()

-- ── mux version ──────────────────────────────────────────────────────────────
elseif sub == "version" then
    Mux._echo(string.format("\n<cyan>[Muxlet]<reset> Version: <white>%s<reset>\n", Mux._version))
    Mux.checkForUpdates(false)

-- ── mux reload ───────────────────────────────────────────────────────────────
elseif sub == "reload" then
    local fresh = words[2] and words[2]:lower() == "fresh"
    Mux.devmodeReload(fresh)

-- ── mux debug ────────────────────────────────────────────────────────────────
elseif sub == "debug" then
    local val = words[2] and words[2]:lower()
    if val == "on"  or val == "true"  then Mux.setDebug(true)
    elseif val == "off" or val == "false" then Mux.setDebug(false)
    else Mux.setDebug(not Mux.debug)
    end

-- ── mux status ───────────────────────────────────────────────────────────────
elseif sub == "status" then
    Mux.status()

-- ── mux start ────────────────────────────────────────────────────────────────
elseif sub == "start" then
    Mux.fullStart()

-- ── mux stop ─────────────────────────────────────────────────────────────────
elseif sub == "stop" then
    Mux.fullStop()

-- ── mux reset ────────────────────────────────────────────────────────────────
elseif sub == "reset" then
    local wsName = Mux.settings.get("mux", "startup_workspace")
    if not wsName or wsName == "" then
        wsName = Mux.settings.get("mux", "startup_layout")
    end
    if not wsName or wsName == "" then wsName = "default" end
    if not Mux._workspaces[wsName] then
        Mux._echo(string.format(
            "\n<red>[Muxlet]<reset> Unknown workspace '%s'. Use: mux workspaces\n", wsName))
    else
        Mux.applyWorkspace(wsName)
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Reset to workspace '<cyan>%s<reset>'.\n", wsName))
    end

-- ── unknown ──────────────────────────────────────────────────────────────────
else
    Mux._echo(string.format(
        "\n<red>[Muxlet]<reset> Unknown command '%s'. "
        .. "Type <cyan>mux help<reset> for usage.\n", sub))
end
