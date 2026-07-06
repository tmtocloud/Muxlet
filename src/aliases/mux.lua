-- Muxlet — "mux" alias
-- @regex: ^mux(?:\s+(.+))?$
--
-- Command surface is intentionally small. Interactive pane/tab editing is done
-- from the UI (titlebar buttons, right-click menus, the Properties dialog), and
-- repeatable/scripted setup is done programmatically via the Mux.* API and
-- workspace definitions. The CLI keeps session control, global settings/themes,
-- workspace management, diagnostics, and one recovery command (`mux reveal`).

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

  <white>Workspaces<reset>
  mux workspace save <name>    — save full UI state as a named workspace
  mux workspace load <name>    — restore a saved workspace
  mux workspace list           — list all registered workspaces
  mux workspace delete <name>  — remove a saved workspace
  mux workspace export <name>  — write a workspace as ready-to-paste Lua source
                                 (for baking a saved layout into a package)
  mux workspaces               — alias for: mux workspace list

  <white>Themes<reset>
  mux theme [name]             — show or switch active theme
  mux theme save <name>        — save the current look (theme + global tweaks)
                                 as a named theme you can switch to or package
  mux themes                   — list all registered themes

  <white>Settings<reset>
  mux settings                 — toggle settings window
  mux settings list [ns]       — list settings for a namespace
  mux settings get ns.key      — show one setting
  mux settings set ns.key val  — change a setting

  <white>Recovery<reset>
  mux panes                    — list every pane/tab with its id and hidden state
  mux reveal <id>              — restore hidden titlebar/Properties on one pane/tab;
                                 also raises floating panes to the front
  mux reveal all               — restore them across the whole workspace and raise
                                 all floating panes (escape hatch for a UI you've
                                 hidden or buried)

  <white>Diagnostics<reset>
  mux debug [on|off]           — toggle debug output
  mux version                  — show version and check for updates
  mux reload [fresh]           — reinstall from local build (dev)

  <grey>Panes and tabs are edited from the UI (titlebar buttons, right-click
  menus, the Properties dialog). For scripted setup, use the Mux.* API and
  workspace definitions.<reset>

]])

-- ── mux theme ────────────────────────────────────────────────────────────────
elseif sub == "theme" then
    local action = words[2] and words[2]:lower() or nil
    if action == "save" then
        -- mux theme save <name> — bottle the current look as a named theme.
        local name = words[3]
        local ok, msg = Mux.saveThemeFromGlobals(name)
        Mux._echo(string.format("\n%s[Muxlet]<reset> %s\n",
            ok and "<cyan>" or "<red>", msg or ""))
    elseif not words[2] then
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
    elseif action == "export" then
        Mux.exportWorkspace(words[3])
    else
        Mux._echo("\n<red>[Muxlet]<reset> Usage: mux workspace save|load|list|delete|export <name>\n")
    end

elseif sub == "workspaces" then
    Mux.listWorkspaces()

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

-- ── mux panes / mux reveal ───────────────────────────────────────────────────
-- Inspection + recovery escape hatch. `mux panes` enumerates the panespace with
-- ids and hidden state; `mux reveal <id|all>` restores titlebars and Properties
-- controls that were hidden from the UI, so a workspace can always be made
-- editable again without dropping to Lua or resetting.
elseif sub == "panes" then
    Mux.listPanespace()

elseif sub == "reveal" then
    Mux.revealUI(words[2])

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