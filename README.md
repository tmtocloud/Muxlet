# Muxlet

A game-agnostic tiling window manager for [Mudlet](https://mudlet.org), inspired by tmux. Split the Mudlet window into panes, arrange them with keyboard shortcuts, switch themes, and save named workspaces.

## Requirements

- [Mudlet](https://mudlet.org) 4.x or later
- [MDK](https://github.com/demonnic/MDK) (available in the Mudlet Package Manager)

## Installation

Open Mudlet's **Package Manager** (Toolbox → Package Manager), search for **Muxlet**, and click Install.

Or download `Muxlet.mpackage` from the [Releases](https://github.com/tmtocloud/Muxlet/releases) page and install via **Install from file**.

## Quick Start

```
mux            — start Muxlet (or type: mux start)
mux help       — show all commands
mux hint       — show keybind overlay (also: Alt+B)
```

## Commands

### Session

| Command | Description |
|---------|-------------|
| `mux` / `mux start` | Enable Muxlet |
| `mux stop` | Disable Muxlet, restore normal console |
| `mux reset` | Re-apply the startup workspace |
| `mux status` | Show session overview |

### Panes

| Command | Description |
|---------|-------------|
| `mux split v [ratio]` | Split left/right (vertical divider) |
| `mux split h [ratio]` | Split top/bottom (horizontal divider) |
| `mux zoom` | Zoom / unzoom focused pane |
| `mux swap` | Swap focused pane with its sibling |
| `mux close` | Close focused pane |
| `mux float` | Float the focused pane |
| `mux embed` | Re-attach the last floating pane |
| `mux titlebar` | Toggle titlebar on focused pane |
| `mux rename <name>` | Rename focused pane |
| `mux lock` / `mux unlock` | Lock / unlock focused pane |
| `mux new [name]` | Create a new floating pane |

### Tabs

| Command | Description |
|---------|-------------|
| `mux tab add [name]` | Add a tab to the focused pane |
| `mux tab close` | Close the active tab |
| `mux tab rename [name]` | Rename the active tab |
| `mux tab lock` / `mux tab unlock` | Lock / unlock active tab |
| `mux tab next` / `mux tab prev` | Switch tabs |

### Workspaces

Save and restore complete UI state across sessions.

| Command | Description |
|---------|-------------|
| `mux workspace save <name>` | Save the current layout |
| `mux workspace load <name>` | Restore a saved layout |
| `mux workspace list` | List all saved workspaces |
| `mux workspace delete <name>` | Remove a workspace |

### Themes

| Command | Description |
|---------|-------------|
| `mux theme [name]` | Show active theme or switch to a named one |
| `mux themes` | List available themes |

Built-in themes: **dark** (default), **light**.

### Settings

| Command | Description |
|---------|-------------|
| `mux settings` | Open the floating settings window |
| `mux settings list` | List all settings |
| `mux settings get mux.theme` | Read a setting |
| `mux settings set mux.theme dark` | Change a setting |

### Focus

| Command | Description |
|---------|-------------|
| `mux focus` | Show which pane has focus |
| `mux focus next` / `mux focus prev` | Move focus |

## Keyboard Shortcuts

Press **Alt+B** (or type `mux hint`) to show a keybind overlay at any time.
Type `mux keys` to list them in the console.

| Key | Action |
|-----|--------|
| `Alt+\` | Split left/right |
| `Alt+-` | Split top/bottom |
| `Alt+←/→/↑/↓` | Focus adjacent pane |
| `Alt+N` / `Alt+P` | Next / previous pane |
| `Alt+Z` | Zoom / unzoom pane |
| `Alt+X` | Close pane |
| `Alt+D` | Float pane |
| `Alt+A` | Embed / re-attach pane |
| `Alt+[` | Toggle titlebar |
| `Alt+,` | Rename pane prompt |
| `Alt+C` | New floating pane |
| `Alt+L/R/U/J` | Toggle left/right/top/bottom panel |
| `Alt+T` | Cycle theme |
| `Alt+S` | Show status |
| `Alt+B` | Keybind hint overlay |
| `Alt+/` | Toggle debug output |

## Extending Muxlet

Muxlet exposes a Lua API for registering custom themes and workspaces from other packages.

```lua
-- Register a custom workspace
Mux.registerWorkspace("my-workspace", {
    name  = "My Workspace",
    theme = "dark",
    paneSets = {
        {
            id   = "screen",
            zone = "screen",
            root = { type = "pane", id = "output", name = "Main", mainConsoleHost = true },
        },
    },
})

-- Register a custom theme
Mux.registerTheme("my-theme", {
    titlebarHeight = 22,
    paneOuterCss   = "background-color: #1a1a2e; border: 2px solid #444;",
    -- ... (see dark.lua / light.lua for full spec)
})

-- Apply a workspace on startup
Mux.settings.set("mux", "startup_workspace", "my-workspace")
```

## Developer Guide

See [DEVELOPER.md](DEVELOPER.md) for the local dev workflow, build setup, and release process.

## License

MIT
