# Muxlet

A game-agnostic tiling window manager for [Mudlet](https://mudlet.org). Split the
Mudlet window into resizable panes, stack views in tabs, float and anchor panes,
attach custom content to any pane or tab, react to game state with per-pane rules,
theme everything through a token system, and save named workspaces.

---

## Concepts

A quick vocabulary — the rest of this document uses these terms precisely.

- **Pane** — the basic tiling container. Has a titlebar, a content area, and a set
  of capability flags (closeable, movable, zoomable, …). A pane is either *embedded*
  in the tiling tree or *floating* freely.
- **Split** — an internal node that divides a region into two children (left/right
  or top/bottom) at a ratio. You never create splits directly; they appear when you
  split a pane.
- **Pane space** — the root region a split tree lives in (normally the whole screen).
- **Tab** — a sub-surface hosted inside a pane. Panes and tabs share one class,
  `MuxSurface`, so most operations work on either.
- **Content** — a swappable module attached to a pane or tab (the main console, a
  button grid, a capture window, …). Content is registered once and can be applied
  to any surface.
- **Rule** — a `condition → action` binding on a pane or tab. When the condition
  becomes true the action runs; an optional *else* action runs when it becomes false.
- **Theme** — a set of style *tokens*. Tokens resolve through a cascade so you can
  override styling globally, per theme, or for one surface.
- **Workspace** — a complete, named snapshot of the layout (the split tree, floating
  panes, content, tabs, theme).

There is no "focused pane" concept. Panes are styled by their resting frame and
acted on directly through their titlebar, context menu, or API.

Building a package on top of Muxlet (registering content, actions, conditions,
themes, or workspaces)? See the [Package Developer Guide](docs/PACKAGE_DEVELOPERS.md).

---

# For Users

## Requirements

- [Mudlet](https://mudlet.org) 4.x or later.

## Installation

Open Mudlet's **Package Manager** (Toolbox → Package Manager), search for
**Muxlet**, and install. Or download `Muxlet.mpackage` from the Releases page and
use **Install from file**.

## Getting started

On first install a welcome dialog helps you pick a startup mode. Otherwise, type:

```
mux
```

This starts Muxlet and restores your last session. On the very first run it applies
the built-in `default` workspace — a single pane hosting the main game console.

Type `mux help` at any time for a command summary.

## Commands

The `mux` alias covers sessions, workspaces, themes, settings, diagnostics, and
recovery. Panes and tabs themselves are manipulated directly (titlebar buttons,
context menus, drag gestures) rather than through subcommands.

### Session

| Command | Description |
|---------|-------------|
| `mux` / `mux start` | Start Muxlet (restores last session, or `default` on first run) |
| `mux stop` | Stop Muxlet, restore the normal Mudlet console |
| `mux reset` | Re-apply the reset workspace (setting `mux.reset_workspace`, default `default`) |
| `mux status` | Version, active workspace, pane count |
| `mux panes` | List every pane/tab with its id and hidden state |
| `mux reveal <id>` | Undo a "lock/hide editor" on content (e.g. a button grid), restore a hidden titlebar/Properties button, raise a floating pane to the front, and force a rule-hidden pane/tab back on screen (deactivating its rules so it stays put for maintenance) |
| `mux reveal all` | Same, across every pane/tab in the workspace — an escape hatch for a UI you've hidden or buried |
| `mux version` | Show the installed version and check for updates |
| `mux debug [on\|off]` | Toggle diagnostic logging |

### Workspaces

Muxlet auto-saves the live session as `current` a second after any structural
change, so your layout survives Mudlet restarts.

| Command | Description |
|---------|-------------|
| `mux workspace save <name>` | Snapshot and name the current layout |
| `mux workspace load <name>` | Restore a saved workspace |
| `mux workspace list` / `mux workspaces` | List saved workspaces |
| `mux workspace delete <name>` | Remove a saved workspace |
| `mux workspace export <name>` | Write the workspace as ready-to-paste Lua, bundling any named conditions/actions its rules depend on — see the [Package Developer Guide](docs/PACKAGE_DEVELOPERS.md#exporting-your-work-for-a-package) |

### Conditions & Actions

Named conditions and actions created from Settings → Conditions/Actions are
profile-local data (`rules.json`) until exported — see the
[Package Developer Guide](docs/PACKAGE_DEVELOPERS.md#exporting-your-work-for-a-package).

| Command | Description |
|---------|-------------|
| `mux conditions list` | List named (non-built-in) conditions |
| `mux conditions export <id>` | Write one condition as ready-to-paste Lua |
| `mux conditions export all` | Write every named condition to one file |
| `mux actions list` | List named (non-built-in) actions |
| `mux actions export <id>` | Write one action as ready-to-paste Lua |
| `mux actions export all` | Write every named action to one file |
| `mux export` | Write every named theme, condition, action, and workspace to one file — for a package offering a full menu of possibilities |

### Themes

| Command | Description |
|---------|-------------|
| `mux theme [name]` | Show the active theme, or switch to a named one |
| `mux theme save <name>` | Save the current look (theme + your global tweaks) as a new named theme — also writes a ready-to-paste Lua export |
| `mux theme export <name>` | Re-export an already-saved theme on demand |
| `mux theme export all` | Write every named theme to one file |
| `mux themes` | List all registered themes |

Built-in themes: **dark** (default) and **light**.

### Settings

| Command | Description |
|---------|-------------|
| `mux settings` | Toggle the floating settings window |
| `mux settings list [ns]` | List settings for a namespace |
| `mux settings get ns.key` | Read a setting |
| `mux settings set ns.key value` | Change a setting |
| `mux settings clear ns.key` | Revert a setting to its default |

Common ones:

```
mux settings set mux.auto_start true    -- start automatically on profile load
mux settings set muxtheme.active light  -- persist the light theme
```

## Working with panes

Each pane's titlebar shows only the buttons its capabilities allow: split vertical,
split horizontal, swap with sibling, anchor (floating panes only), zoom, Content
Library, minimize (floating panes, and embedded panes in a top/bottom split),
Properties (≡), and close. The pane hosting the main console also shows a **+**
button to spawn a new floating pane. There's no separate overflow button — if the
titlebar is too narrow to show every button, or the `compact_titlebar` setting is
on, the folded buttons simply become reachable from the right-click menu instead.

- **Right-click** a titlebar for the context menu. It's only active when something
  is folded (narrow titlebar or `compact_titlebar`), or when the current content
  publishes menu settings, and lists whatever's folded plus those settings.
- **Drag** a titlebar to move a floating pane.
- **Drop** a pane on another pane's edge (the 20% margins) to insert a split there.
- **Drag** a corner handle to resize.
- **Double-click empty titlebar space** or use the menu to float/embed.

**Anchoring:** click a floating pane's anchor button (or its context-menu "Anchor"
row) to arm anchor mode, then drag the pane near an embedded pane's edge or corner
and drop to pin it there. An anchored pane tracks that pane's position and stays out
of the way of other anchored panes sharing the same edge (ordered by an anchor
priority, highest first). Anchor state and its priority persist across sessions
(they're saved and restored with the workspace).

**Void prevention:** Muxlet refuses actions that would leave the tiling area empty.
You can't close or float the only embedded pane, and splits never strand an empty
region. When a pane is the last one, the relevant controls are disabled and shown
read-only in Properties with the reason on hover.

## Tabs

Add tabs from a pane's context menu (**Add Tab**), then manage them on the tab bar:

- **Drag** a tab to reorder it, or drop it on another pane's tab bar to move it.
- **Middle-click** a tab to close it (with confirmation).
- **Double-click** a tab to enter move mode — drop targets appear on every bar.
- **Right-click** a tab for rename / lock / close / Properties.

Tabs nest: a tab's own content can itself be a tabbed surface. Hidden tabs remember
their ordering and reappear in the same place when a rule shows them again.

## Content

Every pane and tab has a **Content Library** button (and menu item). It lists the
registered content you can drop onto that surface — the main console, a button grid,
a capture window, a GMCP inspector, and anything packages add. Items that can't apply
to the current surface are greyed with the reason on hover (e.g. the console can't go
in a tab), and singleton content shows as "Active" where it already lives.

Content can publish its own settings into the host titlebar and right-click menu —
for example the button grid's wrench (edit mode) or the capture window's settings
gear. Those controls follow the content, whether it lives on a pane or on a tab.

## Rules (reactive panes and tabs)

Open a pane or tab's **Properties** to give it rules. A rule is *When \<condition\>,
Do \<action\>* with an optional *Else \<action\>*. Conditions include connection
state, GMCP values, a recently-fired event, or a line matching the game output;
actions include showing/hiding/zooming the pane, sending a command, switching
content, switching theme, or running Lua. Editing a rule's condition or active state
takes effect immediately, without needing a reload. You can also define **named
conditions** and **named actions** once and reuse them across surfaces.
