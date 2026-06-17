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
  mux start                    — enable mux (restores last session, or 'default')
  mux stop                     — disable mux, restore normal Mudlet console
  mux reset                    — re-apply the reset workspace (see mux.reset_workspace setting)
  mux status                   — show status overview

  <white>Pane Actions (focused pane)<reset>
  mux pane split v [ratio]     — split left / right  (vertical divider)
  mux pane split h [ratio]     — split top / bottom  (horizontal divider)
  mux pane zoom                — zoom / unzoom focused pane
  mux pane swap                — swap focused pane with its sibling in the split
  mux pane close               — close focused pane
  mux pane float               — float focused pane
  mux pane embed               — embed / re-attach last floating pane
  mux pane titlebar            — toggle titlebar on focused pane
  mux pane rename <name>       — rename focused pane
  mux pane lock                — lock focused pane
  mux pane unlock              — unlock focused pane
  mux pane new [name]          — create a new floating pane
  mux pane width <1-99>        — set width to % of screen width
  mux pane height <1-99>       — set height to % of screen height
  mux pane properties          — open Properties dialog for focused pane

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

-- ── mux pane ─────────────────────────────────────────────────────────────────
elseif sub == "pane" then
    local paneAction = words[2] and words[2]:lower() or ""
    if paneAction == "split" then
        local dir   = words[3] and words[3]:lower() or "v"
        local ratio = tonumber(words[4]) or 0.5
        if dir ~= "v" and dir ~= "h" then
            Mux._echo("\n<red>[Muxlet]<reset> Usage: mux pane split v [ratio] — left/right\n"
                   .. "                            mux pane split h [ratio] — top/bottom\n")
        else
            local internalDir = (dir == "v") and "h" or "v"
            Mux.splitFocused(internalDir, ratio)
        end
    elseif paneAction == "zoom" then
        Mux.zoomFocused()
    elseif paneAction == "swap" then
        Mux.swapFocused()
    elseif paneAction == "close" then
        Mux.closeFocused()
    elseif paneAction == "float" then
        Mux.floatFocused()
    elseif paneAction == "embed" then
        Mux.embedFocused()
    elseif paneAction == "titlebar" then
        Mux.toggleTitlebarFocused()
    elseif paneAction == "rename" then
        local newName = table.concat(words, " ", 3)
        Mux.renameFocused(newName)
    elseif paneAction == "lock" then
        Mux.lockFocused()
    elseif paneAction == "unlock" then
        Mux.unlockFocused()
    elseif paneAction == "new" then
        local name = words[3] and table.concat(words, " ", 3) or "Pane"
        Mux.newFloatingPane({ name = name })
    elseif paneAction == "width" then
        local pct = tonumber(words[3])
        if not pct then
            Mux._echo("\n<red>[Muxlet]<reset> Usage: mux pane width <1-99>\n")
        else
            Mux.resizePaneToWidth(Mux._focusedPane, pct)
        end
    elseif paneAction == "height" then
        local pct = tonumber(words[3])
        if not pct then
            Mux._echo("\n<red>[Muxlet]<reset> Usage: mux pane height <1-99>\n")
        else
            Mux.resizePaneToHeight(Mux._focusedPane, pct)
        end
    elseif paneAction == "properties" or paneAction == "props" then
        local fp = Mux._focusedPane
        if fp then
            Mux.showPaneProperties(fp)
        else
            Mux._echo("\n<red>[Muxlet]<reset> No focused pane.\n")
        end
    else
        Mux._echo("\n<cyan>[Muxlet]<reset> Pane commands: split | zoom | swap | close | float | embed | titlebar | rename | lock | unlock | new | width | height | properties\n")
    end

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
    local target = Mux.settings.get("mux", "reset_workspace") or "default"
    if not Mux._workspaces[target] then
        Mux._echo(string.format(
            "\n<red>[Muxlet]<reset> Reset workspace '<cyan>%s<reset>' is not registered.\n"
            .. "  Use <cyan>mux workspace list<reset> to see available workspaces,\n"
            .. "  then <cyan>mux settings set mux.reset_workspace <name><reset> to update.\n",
            target))
    else
        Mux.applyWorkspace(target)
        Mux._echo(string.format(
            "\n<yellow>[Muxlet]<reset> Reset to workspace '<cyan>%s<reset>'.\n", target))
    end

-- ── unknown ──────────────────────────────────────────────────────────────────
else
    Mux._echo(string.format(
        "\n<red>[Muxlet]<reset> Unknown command '%s'. "
        .. "Type <cyan>mux help<reset> for usage.\n", sub))
end
