# Muxlet

A game-agnostic tiling window manager for [Mudlet](https://mudlet.org). Split the Mudlet window into panes, stack views in tabs, save named workspaces, and attach custom content widgets to any pane or tab.

---

## For Users

### Requirements

- [Mudlet](https://mudlet.org) 4.x or later

### Installation

Open Mudlet's **Package Manager** (Toolbox → Package Manager), search for **Muxlet**, and click Install.

Or download `Muxlet.mpackage` from the [Releases](https://github.com/tmtocloud/Muxlet/releases) page and install via **Install from file**.

### Getting Started

On first install a welcome dialog walks you through choosing a startup mode. If you skip it, type:

```
mux
```

This starts Muxlet and restores your last session. On the very first run it applies the default workspace — a single pane hosting the main game console.

Type `mux help` at any time for a command summary.

---

### Commands

The `mux` alias covers sessions, workspaces, themes, settings, diagnostics, and recovery. There are no `mux pane …`, `mux tab …`, or `mux focus …` subcommands — panes and tabs are manipulated directly through their titlebar buttons, context menus, and drag gestures, or programmatically through methods on the pane/tab object (see *Accessing the Live Pane Graph*). Muxlet does not track a "focused" pane.

#### Session

| Command | Description |
|---------|-------------|
| `mux` / `mux start` | Start Muxlet (restores last session, or the `default` workspace on first run) |
| `mux stop` | Stop Muxlet, restore the normal Mudlet console |
| `mux reset` | Re-apply the reset workspace (configurable via the `mux.reset_workspace` setting; defaults to `default`) |
| `mux status` | Show status overview (version, workspace, pane count) |

#### Panes (interactive + programmatic)

Use the pane's **titlebar buttons** (shown according to its capability flags): split vertical, split horizontal, swap with sibling, zoom, Content Library, minimize (floating panes), Properties (≡), and close. **Right-click** a titlebar for the full context menu. **Drag** a titlebar to move a floating pane, drop a pane on another pane's edge to insert a split, and drag a corner handle to resize.

Programmatic equivalents on any pane `p`:

```lua
p:split("v", 0.6)     -- "v" = left/right divider, "h" = top/bottom; ratio 0.0-1.0
p:zoom()              -- fill the screen; call again to restore
p:float() / p:embed()
p:close()
p:setName("Map")
p:lock() / p:unlock()
p:setTitlebarVisible(false)
p._split:swapSlots()  -- swap a pane with its split sibling
```

Locked panes ignore drag, close, split, and rename until `p:unlock()` (or context-menu Unlock).

#### Tabs (interactive + programmatic)

Add tabs from a pane's context menu (**Add Tab**); manage them via the tab labels:

- **Drag** a tab label to reorder it within a bar, or drop it onto a different pane's tab bar to move it.
- **Middle-click** a tab label to close it (with confirmation).
- **Double-click** a tab label to enter move mode — the tab turns red and drop targets appear on every bar so you can click to place it anywhere.
- **Right-click** a tab for rename / lock / close / Properties.

Tabs share the `MuxSurface` API with panes, so these methods exist on both:

```lua
p:enableTabs()           -- turn a pane into a tab host
p:addTab("Status")       -- returns the new MuxTab
p:activateTab(tabId)
p:renameTab(tabId, "Chat")
p:removeTab(tabId)
```

#### Workspace

Save and restore complete window arrangements. Muxlet auto-saves the live session as `"current"` one second after any structural change, so your layout survives Mudlet restarts automatically.

| Command | Description |
|---------|-------------|
| `mux workspace save <name>` | Snapshot and name the current layout |
| `mux workspace load <name>` | Restore a saved workspace |
| `mux workspace list` | List all saved workspaces |
| `mux workspace delete <name>` | Remove a named workspace |
| `mux workspaces` | Alias for `mux workspace list` |

#### Theme

| Command | Description |
|---------|-------------|
| `mux theme [name]` | Show the active theme, or switch to a named theme |
| `mux themes` | List all registered themes |

Built-in themes: **dark** (default), **light**.

#### Settings

| Command | Description |
|---------|-------------|
| `mux settings` | Open the floating settings window |
| `mux settings list [ns]` | List all settings for a namespace |
| `mux settings get ns.key` | Read a setting value |
| `mux settings set ns.key value` | Change a setting |
| `mux settings clear ns.key` | Revert a setting to its default |

Common settings:

```
mux settings set mux.auto_start true    — start automatically on every profile load
mux settings set mux.theme light        — switch to light theme persistently
```

#### Recovery

If a pane's titlebar or Properties access has been hidden, these commands bring them back.

| Command | Description |
|---------|-------------|
| `mux panes` | List every pane and tab with its id and hidden state |
| `mux reveal <id>` | Restore the titlebar and Properties access on one pane or tab |
| `mux reveal all` | Restore them across the entire workspace |

#### Debug

| Command | Description |
|---------|-------------|
| `mux debug [on\|off]` | Toggle (or set) debug output in the console |
| `mux version` | Show installed version and check for updates |
| `mux reload` | Reinstall Muxlet from the local build, preserving settings (development helper) |
| `mux reload fresh` | Reinstall and reset the update-skip counter, simulating a fresh install |

---

### Attaching Content to Panes

Right-click any pane titlebar and choose **Content Library** to see all available content types. Selecting one fills the pane with that view. Any content types registered by installed packages appear there automatically — no restart required.

#### Built-in: GMCP Inspector

The **GMCP Inspector** is always available in the Content Library menu. It shows a live, type-grouped view of any GMCP path:

- Click the **PATH** label at the top to open a path browser and select a different GMCP path.
- Click **−** / **+** to zoom the row height in or out.
- Click **Live** to pause auto-refresh (it becomes **Paused**; click again to resume).

You can pre-point an inspector at a specific path from script:

```lua
-- Point all active inspectors at a new path
Mux.gmcpInspect("char.vitals")

-- Point only the inspector in a specific pane
Mux.gmcpInspect("room.info", "sidebar")
```

---

## For Developers

This section covers how external packages integrate with Muxlet: registering workspaces, themes, content types, and settings; using the dialog API; and accessing the live pane graph.

### The `muxletReady` Event

Wait for this event before calling any `Mux.*` API. It fires once after all Muxlet scripts have loaded and persisted settings have been applied — always after the synchronous script-loading stack unwinds, so a handler registered at load time never misses it regardless of package load order.

```lua
registerAnonymousEventHandler("muxletReady", function()
    -- Safe to call any Mux.* API here.
    Mux.registerWorkspace("my-workspace", { ... })
end)
```

A separate `muxletStarted` event fires at the end of `fullStart()` each time Muxlet is started or restarted at runtime. Use it if you need to re-apply layout changes after a `mux stop` / `mux start` cycle.

---

### Controlling the Startup Sequence

Most packages can ignore this section entirely — register your content and workspaces in `muxletReady` and let the user's Muxlet settings drive the rest. But if your package provides its own onboarding or startup logic, you may want finer control over how and when Muxlet initializes.

**Suppressing the welcome dialog**

Muxlet shows a first-run dialog the first time it loads. If your package provides its own onboarding, you can suppress it by setting `welcome_shown` before the 0.3-second check fires:

```lua
registerAnonymousEventHandler("muxletReady", function()
    Mux.settings.set("mux", "welcome_shown", true)
    -- Your own onboarding goes here.
end)
```

**Calling `fullStart()` yourself**

By default, Muxlet auto-starts 1.5 seconds after `muxletReady` if the user has `auto_start` enabled. If your package wants to register content and workspaces before anything renders — or drive a different startup flow — you can call `Mux.fullStart()` directly at the end of your `muxletReady` handler. The built-in timer checks `Mux._running` before it acts, so there is no double-start.

```lua
registerAnonymousEventHandler("muxletReady", function()
    Mux.settings.set("mux", "welcome_shown", true)
    Mux.registerContent("my-content", { ... })
    Mux.registerWorkspace("my-workspace", { ... })
    -- Everything is registered; start Muxlet on our terms.
    Mux.fullStart()
end)
```

If you want Muxlet available but not started — for example, to let the user trigger it manually or after your own async setup — just omit the `fullStart()` call and ensure `mux.auto_start` is not set to `true` in the user's saved settings.

**Disabling the update checker**

If your package manages which version of Muxlet is installed (for example, by pinning a specific release), you may want to disable Muxlet's built-in update check so it doesn't prompt the user to upgrade to an incompatible version:

```lua
registerAnonymousEventHandler("muxletReady", function()
    Mux.settings.set("mux", "update_check_enabled", false)
end)
```

The user can still run `mux version` to check manually, and can re-enable automatic checks with `mux settings set mux.update_check_enabled true`.

---

### Workspaces

A workspace is a complete snapshot of the pane/split tree, theme, and content assignments. Register from any package; registered workspaces appear in `mux workspace list` and survive package reloads.

```lua
Mux.registerWorkspace("my-game-layout", {
    name  = "My Game Layout",
    theme = "dark",          -- optional; uses the active theme if omitted
    paneSpace = {
        id   = "screen",
        zone = "screen",
        root = {
            type = "split", direction = "v", ratio = 0.70,
            a = {
                type            = "pane",
                id              = "output",
                name            = "Main",
                mainConsoleHost = true,
            },
            b = {
                type = "split", direction = "h", ratio = 0.50,
                a = { type = "pane", id = "chat",   name = "Chat" },
                b = { type = "pane", id = "status", name = "Status",
                      activeContent = "gmcp:char.vitals" },
            },
        },
    },
})

-- Apply immediately (also auto-saves as "current" after 1 second)
Mux.applyWorkspace("my-game-layout")
```

#### Zone types

The `zone` field on a paneSpace controls how it interacts with the main console borders:

| Zone | Behaviour |
|------|-----------|
| `"screen"` | Covers the full window. Use `mainConsoleHost = true` on one pane to show game output. |
| `"left"` | Left border panel. Pushes the console right by the paneSpace width. |
| `"right"` | Right border panel. Pushes the console left. |
| `"top"` | Top border panel. Pushes the console down. |
| `"bottom"` | Bottom border panel. Pushes the console up. |
| `"float"` | Free-floating overlay. No border management; supply explicit geometry. |

Only **one paneSpace per workspace** is supported. Use splits within it to arrange multiple panels.

#### Pane node fields

All behavioral flags default to `true` (the permissive state). Set a flag to `false` only when you want to restrict that capability. These same field names are used in workspace registration, the workspace JSON file, and on live `MuxPane` objects.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | string | — | `"pane"` |
| `id` | string | — | Unique identifier. Becomes the `panes["id"]` key. |
| `name` | string | — | Display name shown in the titlebar. |
| `mainConsoleHost` | bool | `false` | Routes the main game console into this pane. Only one pane should set this. Automatically sets `closeable = false`, `convertible = false`, and `contentable = false`. |
| `showTitlebar` | bool | `false` | Override the default titlebar visibility for this pane. |
| `locked` | bool | `false` | Pane starts locked (drag, split, close, minimize disabled). |
| `activeContent` | string | — | Content type id to apply automatically on load. |
| `contentable` | bool | `true` | Show the Content Library (▥) button and context menu item. |
| `tabsLocked` | bool | `false` | Prevent new tabs from being added to an existing tab bar (NoAdd state). Pair with a `tabs` array to define a read-only set of tabs that users cannot extend. |
| `resizable` | bool | `true` | Show corner resize handles when floating. |
| `titlebarHideable` | bool | `true` | Allow the titlebar to be hidden via toggle. Set to `false` to keep it permanently visible. |
| `renamable` | bool | `true` | Allow renaming via UI or command. |
| `connectionAware` | bool | `false` | Show a ⊘ / ⟳ overlay while the client is disconnected or connecting. Covers the full content area including any tab bar. See **Connection Awareness** below. |
| `zoomable` | bool | `true` | Show a zoom button in the titlebar. |
| `splittable` | bool | `true` | Show split buttons in the titlebar. |
| `swappable` | bool | `true` | Show the swap button when the pane is part of a split. |
| `closeable` | bool | `true` | Show the close button and allow `close()`. Set to `false` to make the pane permanently uncloseable (e.g. `mainConsoleHost`). `lock()` sets this to `false`; `unlock()` restores it. |
| `minimizable` | bool | `true` | Show the minimize (–) button on floating panes. `lock()` sets this to `false`; `unlock()` restores it. |
| `convertible` | bool | `true` | Allow switching between embedded and floating states. Set to `false` to lock the pane in its initial position permanently. |
| `movable` | bool | `true` | Allow repositioning by dragging the titlebar. |
| `contextMenu` | bool | `true` | Show the right-click context menu on the titlebar. |
| `propertiesButton` | bool | `true` | Show the Properties (≡) button in the titlebar and context menu. |
| `insertable` | bool | `true` | Include this pane as a drop target when another pane is dragged over it for edge-insertion. |
| `overlay` | bool | `false` | Pane is always floating and excluded from workspace save/restore and ghost slots. Used for system dialogs and persistent HUDs that should not participate in the split tree. |
| `transparentFrame` | bool | `false` | Makes the frame transparent and click-through. Use for HUD overlays that sit above the Qt surface without blocking interaction. |
| `floatX` | number | `100` | Initial left edge (px) when the pane is floating. |
| `floatY` | number | `100` | Initial top edge (px) when the pane is floating. |
| `floatW` | number | `400` | Initial width (px) when the pane is floating. |
| `floatH` | number | `300` | Initial height (px) when the pane is floating. |

#### Tab node fields

Pre-create tabs on a pane by including a `tabs` array in the pane node. Each entry defines one tab in order; `activeTabName` controls which tab is active after restore. The same format is used for sub-tabs inside a tab (tabs-in-tabs).

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | — | Display name shown on the tab label. |
| `renamable` | bool | `true` | Allow renaming via the Properties dialog. |
| `closeable` | bool | `true` | Allow this tab to be closed. |
| `movable` | bool | `true` | Allow this tab to be dragged to reorder or moved to another pane. |
| `contentable` | bool | `true` | Allow Content Library assignments on this tab. |
| `propertiesButton` | bool | `true` | Show the Properties item in the tab's right-click context menu. |
| `connectionAware` | bool | `false` | Show a ⊘ / ⟳ overlay when the client is not connected. Suppressed when the parent pane has `connectionAware` enabled. |
| `tabsLocked` | bool | `false` | Host sub-tabs in this tab but prevent new ones from being added (NoAdd state). |
| `tabs` | array | — | Sub-tab definitions. Same format as this table — enables tabs-in-tabs. |
| `activeTabName` | string | — | Name of the sub-tab to activate after restore. |
| `activeContent` | string | — | Content type id to apply automatically on restore. |

```lua
{
    type = "pane",
    id   = "sidebar",
    name = "Sidebar",
    tabs = {
        { name = "Chat",   activeContent = "my_chat_view" },
        { name = "Map",    closeable = false, renamable = false },
        { name = "Status", connectionAware = true },
    },
    activeTabName = "Chat",
}
```

#### Tabs in tabs

Any tab can host its own nested tab bar. Enable this from the Properties dialog on an active tab by setting **Tabs** to **Enabled** or **NoAdd**, or include a `tabs` array in the tab's workspace entry.

Sub-tabs follow the same rules as top-level tabs: they hold content, support connection awareness, and can be dragged and reordered within their bar. Cross-pane tab moves are only supported at the top level — sub-tabs cannot be relocated to a different pane's bar.

```lua
-- A tab that hosts two sub-tabs
{
    name  = "Analysis",
    tabsLocked = true,   -- bar shown but no new sub-tabs can be added
    tabs  = {
        { name = "Chart",  activeContent = "my_chart" },
        { name = "Table",  activeContent = "my_table" },
    },
    activeTabName = "Chart",
}
```

#### Lifecycle callbacks

Supply these as fields on the pane node. Each is an optional function that Muxlet calls when the corresponding event occurs.

| Field | Signature | When called |
|-------|-----------|-------------|
| `onClose` | `function(pane)` | After the pane is closed and removed from the graph. |
| `onFloat` | `function(pane)` | After the pane transitions to floating. |
| `onEmbed` | `function(pane)` | After the pane is embedded back into a split slot. |
| `onMinimize` | `function(pane, isMinimized)` | After minimize or restore. `isMinimized` is `true` when collapsing, `false` when restoring. |
| `onReposition` | `function(pane)` | After the pane's geometry changes due to a split rebalance, window resize, workspace restore, or zoom. |

```lua
{
    type = "pane",
    id   = "sidebar",
    name = "Sidebar",

    onFloat = function(p)
        echo("sidebar is now floating at " .. p.floatX .. "," .. p.floatY .. "\n")
    end,

    onEmbed = function(p)
        echo("sidebar embedded\n")
    end,

    onMinimize = function(p, minimized)
        if minimized then
            echo("sidebar minimized\n")
        else
            echo("sidebar restored\n")
        end
    end,

    onReposition = function(p)
        -- fires on every resize; keep external widgets in sync here
    end,
}
```

Callbacks can also be assigned after a workspace is applied:

```lua
panes["sidebar"].onClose = function(p)
    echo("sidebar was closed\n")
end
```

#### Split node fields

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `"split"` |
| `direction` | string | `"v"` — left / right slots. `"h"` — top / bottom slots. |
| `ratio` | number | Fraction of space given to slot `a` (0.0–1.0). Default `0.5`. |
| `a` | node | First child (left for `"v"`, top for `"h"`). |
| `b` | node | Second child (right for `"v"`, bottom for `"h"`). |

#### Floating panes in workspaces

```lua
Mux.registerWorkspace("with-float", {
    paneSpace = { ... },
    floatingPanes = {
        {
            type   = "pane",
            id     = "notes",
            name   = "Notes",
            floatX = 200, floatY = 150,
            floatW = 380, floatH = 260,
        },
    },
})
```

#### Runtime workspace API

```lua
Mux.applyWorkspace("my-game-layout")   -- restore a workspace
Mux.saveWorkspace("afternoon-session") -- snapshot the live layout
Mux.listWorkspaces()                   -- list all registered workspaces
Mux.deleteWorkspace("old-layout")      -- remove a saved workspace
```

---

### Content Types

Content types are named widget factories. Once registered they appear in the right-click **Content Library** menu on every pane and tab — immediately, with no restart. The catalog is persisted to `Muxlet_persistent/content.json` so names survive reloads.

```lua
Mux.registerContent("my_hud", {
    name        = "My HUD",
    description = "Shows something useful in a pane",
    singleton   = false,   -- true = only one active instance at a time

    -- Called when the user selects this content type, or a workspace loads it.
    -- `target` is a pane or a tab — both expose the same interface.
    apply = function(target)
        -- target.id        — unique string id
        -- target.name      — display name
        -- target.content   — Geyser.Container; parent all widgets here
        -- target.contentBg — Geyser.Label placeholder; hide once real content is attached
        local lbl = Geyser.Label:new({
            name = target.id .. "_hud_lbl",
            x = "0%", y = "0%", width = "100%", height = "100%",
        }, target.content)
        lbl:rawEcho("Hello from My HUD")
        target.contentBg:hide()
    end,

    -- Optional. Called before a different content type replaces this one.
    remove = function(target)
        hideWindow(target.id .. "_hud_lbl")
    end,
})
```

> **Text colour in content widgets:** Use `rawEcho` instead of `echo` when the label's text colour is controlled by `setStyleSheet`. Geyser's `echo` wraps content in a `<div style="color: #ffffff;">` that overrides the stylesheet colour. `rawEcho` bypasses that wrapper and lets the Qt stylesheet take effect.

Set `singleton = true` to allow only one active instance at a time. If the user tries to open it in a second pane, a dialog tells them where it is currently open and the apply is aborted.

#### Applying content programmatically

```lua
Mux._applyContent(panes["sidebar"], "my_hud")

-- Apply to a specific tab
local tab = panes["chat"]:_findTab(panes["chat"]._activeTabId)
Mux._applyContent(tab, "my_hud")
```

#### Built-in: GMCP Inspector

`gmcp_inspector` is pre-registered and always available in the Content Library menu. It provides an interactive, type-grouped live view of any GMCP path with click-to-browse, expand/collapse, and zoom controls.

Use it in a workspace definition like any other content type:

```lua
{ type = "pane", id = "gmcp", name = "GMCP", activeContent = "gmcp_inspector" }
```

#### Built-in: Fixed-path GMCP viewer

`Mux.registerGmcpViewer(path)` creates a simple HTML content type that pretty-prints a single GMCP path and auto-refreshes on the corresponding event. Use this when you want a dedicated pane that always shows one specific path:

```lua
Mux.registerGmcpViewer("char.vitals")   -- → content id "gmcp:char.vitals"
Mux.registerGmcpViewer("room.info")     -- → content id "gmcp:room.info"
```

Use the resulting id in a workspace definition:

```lua
{ type = "pane", id = "vitals", name = "Vitals", activeContent = "gmcp:char.vitals" }
```

---

### Themes

A theme is a Lua table of CSS strings, pixel dimensions, and color values. Register from any package; registered themes appear in `mux themes` and the settings dropdown.

The recommended pattern is to extend an existing built-in rather than specifying every field from scratch:

```lua
registerAnonymousEventHandler("muxletReady", function()
    local base = Mux._themes["dark"]

    Mux.registerTheme("my-theme", Mux._merge(base, {
        titlebarHeight  = 28,
        titlebarCss     = "background-color: #1e1e2e; border: none;",
        paneOuterCss    = "background-color: #181825; border: 2px solid #313244; border-radius: 4px;",
        handleCss       = "background-color: #313244;",
        handleHoverCss  = "background-color: #45475a;",
    }))

    Mux.applyTheme("my-theme")
end)
```

`Mux._merge(base, overrides)` returns a shallow-merged table — every field in `overrides` replaces the corresponding field in `base`, and unspecified fields inherit from `base`. This means your theme stays visually coherent even as new fields are added in future Muxlet versions.

Runtime theme API:

```lua
Mux.applyTheme("my-theme")   -- applies immediately to all live panes and splits
Mux.currentTheme()           -- returns the active theme name
Mux.activeTheme()            -- returns the active theme table
```

See `src/scripts/themes/dark.lua` in the source for the full field reference.

---

### Settings

Muxlet has a two-level namespace settings system (`ns.key`). Packages register their own namespaces, which appear as tabs in the floating settings window.

#### Registering settings

```lua
registerAnonymousEventHandler("muxletReady", function()

    -- Boolean toggle
    Mux.settings.register("my-package", "show_timestamps", {
        tab         = "My Package",
        description = "Show timestamps on chat messages",
        default     = true,
    })

    -- Dropdown from a fixed list
    Mux.settings.register("my-package", "color_scheme", {
        description = "Color scheme for chat messages",
        default     = "blue",
        choices     = { "blue", "green", "amber", "white" },
    })

    -- Integer stepper (when max - min ≤ 100)
    Mux.settings.register("my-package", "font_size", {
        description = "Font size for MiniConsoles",
        default     = 12,
        min         = 8,
        max         = 24,
    })

    -- Free-text entry (any other type)
    Mux.settings.register("my-package", "server_host", {
        description = "MUD server hostname",
        default     = "example.com",
    })

end)
```

The widget type is inferred automatically:
- `choices` table → dropdown
- `boolean` default → toggle
- `number` default with `min`/`max` where `max − min ≤ 100` → stepper
- Everything else → text entry with an Apply button

#### Tab hierarchy

The `tab` field on the first registered key for a namespace sets the tab label. A slash creates a sub-tab:

```lua
Mux.settings.register("my-package", "first_key", {
    tab = "My Package",
    ...
})

Mux.settings.register("my-package/map", "zoom", {
    tab = "My Package/Map",
    ...
})
```

#### Reading, writing, and reacting to settings

```lua
-- Read (returns persisted value, or default if never set)
local showTs = Mux.settings.get("my-package", "show_timestamps")

-- Write (validates, persists, fires onChange)
local ok, err = Mux.settings.set("my-package", "font_size", 14)

-- Revert to default
Mux.settings.clear("my-package", "font_size")

-- React to changes (fires on both UI and script changes)
Mux.settings.onChange("my-package", "font_size", function(value)
    applyFontSize(value)
end)
```

Settings are persisted to `Muxlet_persistent/settings.json`.

---

### Dialog API

Use `Mux.createDialog()` for all floating popup windows. Dialogs created through this API:

- Get automatic frame, border, and titlebar styling from the active theme.
- Update instantly when the user switches themes.
- Stay above workspace panes automatically.
- Have a working × close button built in.
- Expose a `pane.content` Geyser.Container for widget placement.

#### Creating a dialog

```lua
local d = Mux.createDialog({
    title  = "Apply Workspace?",
    width  = 480,
    height = 220,
    -- x, y: pixel coordinates (defaults to centered in main window)
    -- resizable = true  (default false)
})

local body = Geyser.Label:new({
    name = "my_dlg_body", x = "4%", y = 14, width = "92%", height = 50,
}, d.content)
body:setStyleSheet(Mux.dialogCss.body)
body:rawEcho("Apply the recommended workspace?")

local btnYes = Geyser.Label:new({
    name = "my_dlg_yes", x = "10%", y = 140, width = "35%", height = 34,
}, d.content)
btnYes:setStyleSheet(Mux.dialogCss.buttonPrimary)
btnYes:rawEcho("<center>Yes, Apply</center>")
btnYes:setClickCallback(function()
    Mux.applyWorkspace("my-workspace")
    d:close()
end)

local btnNo = Geyser.Label:new({
    name = "my_dlg_no", x = "55%", y = 140, width = "35%", height = 34,
}, d.content)
btnNo:setStyleSheet(Mux.dialogCss.button)
btnNo:rawEcho("<center>Skip</center>")
btnNo:setClickCallback(function() d:close() end)

d.onClose = function()
    -- cleanup when dismissed
end
```

#### `createDialog` options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `title` | string | `"Dialog"` | Titlebar label |
| `width` | number | `440` | Width in pixels |
| `height` | number | `280` | Height in pixels |
| `x` | number | centered | Left edge in pixels |
| `y` | number | centered | Top edge in pixels |
| `resizable` | bool | `false` | Enable corner resize handles |
| `id` | string | auto | Custom pane id |

#### Pre-built CSS palette

Use these on labels inside your dialog:

| Key | Use for |
|-----|---------|
| `Mux.dialogCss.body` | Primary body text |
| `Mux.dialogCss.subtext` | Secondary / caption text |
| `Mux.dialogCss.divider` | 1 px horizontal rule (set on a height=1 label) |
| `Mux.dialogCss.button` | Neutral action button |
| `Mux.dialogCss.buttonPrimary` | Affirmative button (green) |
| `Mux.dialogCss.buttonDanger` | Destructive action button (red) |

---

### Connection Awareness

Panes and tabs can display a status overlay when the game client is disconnected or mid-handshake. The overlay shows **⊘ DISCONNECTED** or **⟳ CONNECTING…** and disappears automatically once the connection is ready.

#### Enabling via Properties

Open the Properties dialog for any pane or tab and toggle **Connection Awareness** to **On**. The overlay appears immediately if the client is currently in a non-connected state.

Enabling connection awareness on a **pane** covers the entire content area, including the tab bar. Per-tab overlays are suppressed for all tabs in that pane while pane-level awareness is active. Disabling pane-level awareness restores any enrolled tab overlays automatically.

#### API

```lua
-- Pane-level: covers the full content area including the tab bar.
pane:setConnectionAware(true)
pane:setConnectionAware(false)

-- Tab-level: covers one tab's content area only.
-- Has no effect when the parent pane already has connectionAware = true.
pane:setTabConnectionAware(tabId, true)
pane:setTabConnectionAware(tabId, false)

-- Drive state from game-specific logic.
-- States: "connected" | "connecting" | "disconnected"
Mux.setConnectionState("connected")
```

#### State machine

Muxlet listens for Mudlet system events and advances state automatically:

| Mudlet event | Argument | State transition |
|--------------|----------|-----------------|
| `sysConnectionEvent` | — | → `"connecting"` (⟳) |
| `sysProtocolEnabled` | `"GMCP"` | → `"connected"` (overlay hidden) |
| `sysDisconnectionEvent` | — | → `"disconnected"` (⊘) |

`sysProtocolEnabled` fires within milliseconds of a TCP connect on any GMCP-capable MUD, so the connecting screen is effectively invisible on those games. For games that do not use GMCP, a fallback timer advances the state to `"connected"` after a configurable delay.

```lua
-- Default fallback delay is 30 seconds. Change it in a muxletReady handler.
Mux._connReadyDelay = 10

-- Set to 0 to disable the fallback entirely.
-- You are then responsible for calling Mux.setConnectionState("connected")
-- from your own game-ready event handler (e.g. a game-specific GMCP event).
Mux._connReadyDelay = 0
```

#### Workspace persistence

`connectionAware` is saved and restored automatically. Set it in a workspace definition:

```lua
-- Pane-level connection awareness
{ type = "pane", id = "chat", name = "Chat", connectionAware = true }

-- Tab-level (inside the pane's tabs array)
{ name = "Chat", connectionAware = true }
```

---

### Accessing the Live Pane Graph

```lua
-- Lookup by id (panes proxy is always current after workspace changes)
local p = panes["sidebar"]        -- equivalent to Mux._panes["sidebar"]
local s = Mux.getSplit("split_0001")
local ps = Mux.getPaneSpace("screen")

-- Structural operations are methods on the pane object (there is no focus concept)
panes["sidebar"]:split("v", 0.6)   -- "v" = left/right, "h" = top/bottom; ratio 0.0-1.0
panes["sidebar"]:float()
panes["sidebar"]:embed()
panes["sidebar"]:zoom()
panes["sidebar"]:close()
s:swapSlots()                      -- swap the two children of a split node

-- Raise all floating panes above embedded ones
-- Call this after adding widgets to any floating or dialog pane.
Mux.raiseFloatingPanes()
```

The `panes` global is a metatable proxy over `Mux._panes`. Always use `panes["id"]` rather than storing a direct reference — the proxy remains valid after `_clearWorkspace()` rebuilds the internal table.

---

### Developer Notes

- All Mux Lua identifiers use **camelCase** — `titlebarHeight`, `setName`, `applyTheme`. Match this in any code that touches Mux internals.
- All behavioral pane flags use a **positive convention** — `closeable`, `minimizable`, `resizable`, `renamable`, `contentable`, `convertible`, `contextMenu`, `propertiesButton`, `insertable`, `titlebarHideable`. A flag set to `false` restricts that capability; omitting it (or setting `true`) leaves it enabled. `lock()` sets all mutable flags to `false`; `unlock()` restores them.
- `MuxPane`, `MuxSplit`, and `MuxPaneSpace` are the three concrete classes. Instances are registered in `Mux._panes`, `Mux._splits`, and `Mux._paneSpaces` automatically on creation.
- IDs (e.g. `pane_0003`) are user-facing and recycle freed numbers. Internal Geyser widget names (e.g. `mux_w_0042`) never recycle — Qt holds named widgets in memory and recycled names would alias destroyed widgets.
- `Mux._scheduleAutoSave()` is called internally after every structural change. You do not need to call it unless you make external modifications to the pane graph.
- `Mux._applyBorders()` recomputes all border sizes atomically from `Mux._borders`. Never call `setBorderSizes` directly — route through this function so all PaneSpace contributions are combined correctly.

---

## License

MIT