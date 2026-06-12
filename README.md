# Muxlet

A game-agnostic tiling window manager for [Mudlet](https://mudlet.org), inspired by tmux. Split the Mudlet window into panes, arrange them with keyboard shortcuts, switch themes, save named workspaces, and attach custom content widgets to any pane.

## Requirements

- [Mudlet](https://mudlet.org) 4.x or later

## Installation

Open Mudlet's **Package Manager** (Toolbox → Package Manager), search for **Muxlet**, and click Install.

Or download `Muxlet.mpackage` from the [Releases](https://github.com/tmtocloud/Muxlet/releases) page and install via **Install from file**.

## Quick Start

```
mux start      — enable Muxlet (auto_start is off by default)
mux help       — show all commands
mux hint       — show keybind overlay (also: Alt+B)
```

> **Note:** `auto_start` is disabled by default so Muxlet does not interfere with downstream packages. Enable it permanently with `mux settings set mux.auto_start true`.

## Commands

### Session

| Command | Description |
|---------|-------------|
| `mux` / `mux start` | Enable Muxlet (restores last session) |
| `mux stop` | Disable Muxlet, restore normal console |
| `mux reset` | Re-apply the default workspace |
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

Save and restore complete workspace arrangements across sessions. Workspaces are persisted automatically to `Muxlet_persistent/workspaces.json` in your Mudlet profile directory.

| Command | Description |
|---------|-------------|
| `mux workspace save <name>` | Save the current workspace |
| `mux workspace load <name>` | Restore a saved workspace |
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

Muxlet exposes a Lua API for registering custom themes, workspaces, and content types from other packages.

### Lifecycle events

#### `muxletReady`

Raised once after all Muxlet scripts have loaded and persisted settings (theme, debug flag) have been applied. This is the correct hook point for any package that depends on Muxlet — use it instead of guessing at timer delays.

```lua
registerAnonymousEventHandler("muxletReady", function()
    -- Safe to call any Mux.* API here.
    Mux.fullStart()
    Mux.applyWorkspace("my-workspace")
end)
```

The handler is registered synchronously at package load time. Because `muxletReady` is fired from a `tempTimer(0)` callback inside Muxlet's own init, it always fires after the synchronous script-loading stack unwinds — so a handler registered at load time will never miss the event, regardless of which package Mudlet loads first.

If your package also needs to handle a `mux stop` / `mux start` cycle at runtime, check `Mux._running` at the top of your handler; `muxletReady` only fires at session start (or after a fresh Muxlet install), not on every `fullStart()`.

### Workspaces

Workspaces define a complete pane, split, and theme arrangement. Register them from any package and they appear in `mux workspace list`.

```lua
Mux.registerWorkspace("my-workspace", {
    name  = "My Workspace",
    theme = "dark",
    paneSets = {
        {
            id   = "screen",
            zone = "screen",
            root = {
                type = "split", direction = "v", ratio = 0.65,
                a = { type = "pane", id = "output", name = "Main", mainConsoleHost = true },
                b = { type = "pane", id = "sidebar", name = "Info" },
            },
        },
    },
})

-- Apply immediately (it auto-saves and will be restored next session)
Mux.applyWorkspace("my-workspace")
```

**Workspace node fields:**

| Field | Description |
|-------|-------------|
| `type` | `"pane"` or `"split"` |
| `id` | Unique string identifier for the pane |
| `name` | Display name shown in the titlebar |
| `mainConsoleHost` | `true` to host the main MUD output console |
| `showTitlebar` | Show/hide the pane titlebar (default: from settings) |
| `noContent` | Suppress the "Add Content" context menu item |
| `activeContent` | Content type to apply automatically on load |
| `direction` | `"v"` (left/right) or `"h"` (top/bottom) for splits |
| `ratio` | Split point as a fraction 0.0–1.0 |

Workspaces are auto-saved to `Muxlet_persistent/workspaces.json` after every structural change. The `"current"` workspace key always holds the live session state so your arrangement survives Mudlet restarts even without an explicit save.

### Content system

Content types are named widget factories that users can attach to any pane or tab from the right-click context menu. They're registered at runtime and catalogued in `Muxlet_persistent/content.json`.

```lua
Mux.registerContent("my_widget", {
    name        = "My Widget",
    description = "Shows something useful in a pane",

    -- Called when the user selects this content type.
    -- `target` is either a pane or a tab; both expose the same interface.
    apply = function(target)
        -- target.id        — unique string id
        -- target.name      — display name
        -- target.content   — Geyser.Container: parent for your widgets
        -- target.contentBg — Geyser.Label: hide this once you attach real content
        local lbl = Geyser.Label:new({
            name = target.id .. "_my_lbl",
            x = "0%", y = "0%", width = "100%", height = "100%",
        }, target.content)
        lbl:echo("Hello from My Widget")
        target.contentBg:hide()
    end,

    -- Optional: called before a different content type is applied to this target.
    remove = function(target)
        hideWindow(target.id .. "_my_lbl")
    end,
})
```

### GMCP viewer

`Mux.registerGmcpViewer(path)` creates a content type for any dot-path under `gmcp`. It pretty-prints whatever value is there — tables, arrays, strings, numbers, booleans — and refreshes automatically whenever the corresponding GMCP event fires.

```lua
-- Register viewers for any GMCP paths your game exposes
Mux.registerGmcpViewer("char.vitals")   -- → content id "gmcp:char.vitals"
Mux.registerGmcpViewer("char.status")   -- → content id "gmcp:char.status"
Mux.registerGmcpViewer("room.info")     -- → content id "gmcp:room.info"
```

The following are pre-registered and available out of the box:

| Content ID | Watches |
|------------|---------|
| `gmcp:char.vitals` | `gmcp.char.vitals` |
| `gmcp:room.info` | `gmcp.room.info` |

Use in a workspace pane definition:
```lua
{ type = "pane", id = "vitals", name = "Vitals", activeContent = "gmcp:char.vitals" }
```

Or apply at runtime:
```lua
Mux._applyContent(panes.vitals, "gmcp:char.vitals")
```

### Themes

```lua
Mux.registerTheme("my-theme", {
    titlebarHeight = 22,
    paneOuterCss   = "background-color: #1a1a2e; border: 2px solid #444;",
    -- see dark.lua / light.lua in the Muxlet source for the full spec
})
```

### Dialog API

Create floating popup windows that integrate with the Muxlet theme system.

```lua
local d = Mux.createDialog({
    title     = "Confirm",
    width     = 420,
    height    = 180,
    resizable = false,
})

-- d.content is a Geyser.Container — add your widgets here
local msg = Geyser.Label:new({
    name = "my_dialog_msg", x = "4%", y = 14, width = "92%", height = 40,
}, d.content)
msg:setStyleSheet(Mux.dialogCss.body)
msg:echo("Apply the recommended workspace?")

local btnOk = Geyser.Label:new({
    name = "my_dialog_ok", x = "30%", y = 120, width = "40%", height = 30,
}, d.content)
btnOk:setStyleSheet(Mux.dialogCss.buttonPrimary)
btnOk:echo("<center>OK</center>")
btnOk:setClickCallback(function()
    d:close()
    Mux.applyWorkspace("my-workspace")
end)

-- Optional cleanup hook
d.onClose = function() end
```

**Predefined CSS classes:**

| Key | Style |
|-----|-------|
| `Mux.dialogCss.body` | Body text (light blue) |
| `Mux.dialogCss.subtext` | Muted caption text |
| `Mux.dialogCss.divider` | 1 px horizontal rule |
| `Mux.dialogCss.button` | Neutral action button |
| `Mux.dialogCss.buttonPrimary` | Affirmative / green button |
| `Mux.dialogCss.buttonDanger` | Destructive / red button |

## Developer Guide

See [DEVELOPER.md](DEVELOPER.md) for the local dev workflow, build setup, and release process.

## License

MIT
