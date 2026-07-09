# Muxlet — Claude Working Notes

Muxlet is a game-agnostic tiling window manager for Mudlet, written in Lua.  It is modelled on tmux: panes, splits, tab bars, themes, workspaces, and a content registry that any downstream package can populate.

---

## Core philosophy: Muxlet is built from its own primitives

Every piece of Muxlet's own UI — settings window, properties dialog, popups, notifications — is a **MuxPane**.  Nothing uses native Mudlet dialogs or bare Geyser widgets as top-level windows.  This keeps the theme system universal: if the active theme changes, every surface refreshes automatically because `applyTheme()` walks `Mux._panes`.

Consequences:
- "Popup windows" → `Mux.createDialog(opts)` which returns an `overlay` MuxPane.  Put widgets in `pane.content`.
- "Settings window" → a dialog-mode MuxPane that is `locked`, `resizable = false`, `contextMenu = false`, with tabs enabled internally.
- "Properties panel" → same dialog pattern, content applied via `Mux.registerContent`/`Mux._applyContent` so the placeholder is suppressed and the content lifecycle (singleton tracking, remove callbacks) is respected.
- Any new system UI follows the same pattern.  Never create a raw `Geyser.Label` or `Geyser.Container` as a floating window; always go through `Mux.createDialog`.

---

## Startup: "start without starting"

`Mux._running` tracks whether a workspace is live.  **Muxlet does not auto-apply a default workspace on load.**  Startup runs `fullStart()` which does:

1. Load persistent data (settings, workspaces, content catalog).
2. If the saved `"current"` workspace exists → restore it exactly.
3. If no `"current"` exists and a `"default"` workspace is registered → apply that.
4. Only if nothing is registered does Muxlet fall back to a bare single-pane layout.

The implication: Muxlet should never discard the user's live arrangement on reload.  The `"current"` workspace is always the source of truth for the next session.

---

## Workspace model

| Term | Meaning |
|------|---------|
| `"current"` | Auto-saved on every structural change (1 s debounce). Restored automatically next session. The live state. |
| Named workspaces | Explicit snapshots the user saves with `mux workspace save <name>`. Restored on demand with `mux workspace load <name>`. Think of them as bookmarks, not the live state. |
| `Mux.registerWorkspace` | Registers a *static* workspace definition (usually from a package). Applied once; overwritten when the user modifies the layout. |

What `saveWorkspace` / `_doAutoSave` capture per pane:
- `id`, `name`, `showTitlebar`, `mainConsoleHost`, `nameAlign`
- All non-default behavioral flags. These use the **positive convention** (a flag is `true`/absent when the capability is enabled, `false` only to restrict it): `contentable`, `resizable`, `titlebarHideable`, `renamable`, `tabsLocked`, `locked`, `connectionAware` (and the rest of the flag set documented in the README's "Pane node fields" table).
- `activeContent` — the content type currently applied; re-applied on load
- Float position (`floatX/Y/W/H`) for floating panes
- Full tab tree (via `_serializeTabs`): tab names, locked state, active tab, nested sub-tab structure, each tab's `activeContent`

`overlay` panes (dialogs) are **excluded** from serialization — they are transient system UI.

---

## The content system

`Mux.registerContent(id, def)` + `Mux._applyContent(target, id)` is the canonical way to put UI into a pane or tab.  **This applies to Muxlet's own system UI as much as to user or downstream-package content.**  Every surface that fills a pane or tab — settings panel, properties editor, GMCP viewer, custom widgets — should be registered content.  This ensures the placeholder (`contentBg`) is properly suppressed, the content lifecycle (remove callbacks, singleton tracking) is respected, and workspace auto-save captures `activeContent` correctly.

`target` is the same interface whether it is a pane or a tab:
```
target.id          — unique string ID
target.name        — display name
target.content     — Geyser.Container  → parent all your widgets here
target.contentBg   — Geyser.Label      → hide this after attaching real content:
                       target.contentBg:echo("")
                       target.contentBg:hide()
target._activeContent  — set to your content id by _applyContent; suppresses placeholder
```

`def` fields:
```
name        string   display name (shown in context menu)
description string   optional tooltip
group       string   optional; buckets this item under a collapsible divider of the same
                     name in the Content Library dialog (collapsed by default). Omit to
                     render as a flat, always-visible row above the groups instead.
singleton   bool     only one active instance at a time; extra opens are blocked with a dialog
internal    bool     Muxlet system-only content; hidden from the "Add Content" menu and
                     excluded from the content catalog persistence.  Use for all internal
                     Muxlet UI (properties, settings pane, connection screen, etc.)
apply(target)        REQUIRED — build widgets in target.content; hide target.contentBg
remove(target)       optional — called before a different content is applied (tear down timers, etc.)
```

Key behaviour:
- Calling `_applyContent(target, id)` when `target._activeContent ~= id` first calls `old.remove(target)`.
- Setting `target._activeContent` before calling `apply` is handled by `_applyContent`; do not set it manually.
- The content registry is read at context-menu open time, so registrations made after startup appear without a reload.
- `Mux._listContent()` returns only non-internal entries — the "Add Content" menu never shows system content.
- Internal content is also excluded from the catalog persistence file (`content.json`).
- `Mux._showContentLibrary(pane)` (globals.lua) renders the grouped dialog itself, built on `Mux.ui.buildForm`'s divider/collapsible-section mechanism (see below). Muxlet's own visible built-in content (console, button grid, capture, GMCP inspector) is registered with `group = "Muxlet"`.

---

## Class model

Runtime objects are built with a tiny factory, `Mux._class(parent)` (globals.lua). It returns a class table whose `__index` is itself; if a `parent` is given, the class's metatable falls through to the parent, so both instance lookups and static `Class.field` access inherit. Each class defines an `:init(opts)` hook; `Class:new(opts)` allocates the instance and calls `:init`.

```
MuxSurface = Mux._class()            -- shared base: content + name + lifecycle + tab-hosting
MuxPane    = Mux._class(MuxSurface)  -- a chrome-wrapped surface (titlebar, borders, splits)
MuxTab     = Mux._class(MuxSurface)  -- a content surface that lives in a tab bar
MuxDialog  = Mux._class(MuxPane)     -- an overlay pane used for all system dialogs
MuxSplit   = Mux._class()            -- a binary split node (not a surface)
MuxPaneSpace = Mux._class()            -- the root container / border-zone manager
```

**Why MuxSurface exists.** A tab is not a specialised pane — it never runs `MuxPane:init`, and has no titlebar, borders, or split machinery. But panes and tabs share two things: they both hold content (the `content`/`contentBg`/`_activeContent` trio and the `_applyContent` lifecycle), and they can both *host* a tab bar (a pane has tabs; a tab can have nested sub-tabs). Those shared concerns live on `MuxSurface`, so `MuxPane` and `MuxTab` are siblings that inherit them rather than one pretending to be the other. The content system treats any `target` (pane or tab) identically because both satisfy the `MuxSurface` interface. This is a clarity win, not a speed one — it costs one extra metatable hop.

**MuxTab.** `addTab` builds a real `MuxTab:new({host = surface, id, name})` (tabs.lua). The tab owns its `content` container, `contentBg` placeholder, label, and the positive-convention flags (`renamable`, `closeable`, `movable`, `contentable`, `contextMenu`). `tab.pane` is the back-reference to its host surface.

**MuxDialog.** `Mux.createDialog(opts)` is a thin wrapper that returns `MuxDialog:new(opts)`; existing call sites keep working unchanged. `MuxDialog:init` runs the pane chrome, forces `overlay`, applies the dialog palette, and claims the top of the raise order so a new dialog never lands underneath an older one (z-order is by an ascending `Mux._raiseSeq` counter; see manager.lua).

**Tear-off seam (future).** `MuxSurface:_captureState()` snapshots a surface's name/content/flags/tabs. It is unused today; it exists so a tab can later be *promoted* into a standalone pane (drag-tab-to-pane) without a special-case path. Serialization stays inline for now.

---

## MuxPane — constructor options and runtime fields

`MuxPane:new(opts)` — most fields survive workspace serialization.

Behavioral flags follow the **positive convention**: each flag enables a capability, defaults to `true` (the permissive state) when omitted, and is set to `false` only to restrict that capability. `lock()` sets the mutable flags to `false`; `unlock()` restores them. The full flag set is documented in the README's "Pane node fields" table; the most load-bearing ones for system UI are below.

| Option | Effect |
|--------|--------|
| `id` | Stable user-facing ID (reused after close via free pool) |
| `name` | Titlebar display text; changed with `pane:setName(text)` |
| `nameAlign` | Titlebar name alignment: `"left"` (default), `"center"`, or `"right"`. Governs both where the name renders and how the titlebar buttons arrange around it. |
| `overlay` | Always floating; excluded from workspace serialization; cannot be embedded |
| `resizable` | `false` hides corner drag handles when floating |
| `titlebarHideable` | `false` keeps the titlebar permanently visible; `setTitlebarVisible(false)` becomes a no-op |
| `renamable` | `false` blocks rename from UI and API |
| `contentable` | `false` hides the Content Library button/menu item (does not block `_applyContent`) |
| `noTabs` | Tab bar cannot be enabled (constructor-only convenience flag; not a persisted behavioral flag) |
| `contextMenu` | `false` suppresses the right-click menu entirely |
| `locked` | Prevents drag, split, resize; hides close button unless `closeable = true` |
| `closeable` | Show close button even when `locked = true` |
| `titlebarVisible` | Persisted; toggled via `pane:setTitlebarVisible(bool)` |
| `mainConsoleHost` | Pane hosts the Mudlet main console via border sizing; special casing throughout |

Runtime methods used frequently:
```lua
pane:setName(text)
pane:lock() / pane:unlock()
pane:setTitlebarVisible(bool)
pane:_applyTitlebarVisibility()   -- refresh after changing .closeable
pane:enableTabs([opts])           -- opts.noDefaultTab = true to skip creating first tab
pane:disableTabs()
pane:addTab(name, pos)
pane:renameTab(tabId, newName)
pane:removeTab(tabId)
pane:close()
pane:float() / pane:embed()
pane:_detachToFloat()             -- used internally after createDialog
```

Geyser widget name uniqueness: pane IDs are user-facing and recycled; internal Geyser widget names use `Mux._newInternalId()` (ever-increasing `mux_w_NNNN`) to prevent Qt name conflicts with hidden old widgets.

---

## Tab objects — property parity with panes

A tab is a `MuxTab` — a `MuxSurface` sibling of `MuxPane` (see Class model) — built by `addTab` as `MuxTab:new({host, id, name})`. Wherever a pane has a property or behaviour, consider whether a tab should too.  Current tab fields:

| Field | Notes |
|-------|-------|
| `tab.id` | Unique, generated by `Mux._newId("tab")` |
| `tab.name` | Display text on the tab label |
| `tab.nameAlign` | Label text alignment: `"left"`, `"center"` (default for tabs), or `"right"`. Tab labels are button-free, so alignment is pure CSS — unlike pane titlebars, there is no button cluster to rearrange. |
| `tab.locked` | Prevents rename and close |
| `tab.contextMenu` | `false` suppresses the tab's right-click menu (also gated by the host pane's `contextMenu`) |
| `tab.pane` | Back-reference to the containing MuxPane (the "host") |
| `tab.content` | `Geyser.Container` — parent for tab content widgets; same interface as `pane.content` |
| `tab.contentBg` | `Geyser.Label` — placeholder; hide after attaching content |
| `tab._activeContent` | Set by `_applyContent`; suppresses placeholder |
| `tab._tabsEnabled` | True if this tab itself hosts a nested sub-tab bar |

When adding new properties or behaviours to panes, evaluate them for tabs.  The `_applyContent` system already treats panes and tabs identically.  Properties dialog (`Mux.showTabProperties`) should mirror pane properties to the degree that they make sense for a tab.

---

## Dialog pattern

```lua
local d = Mux.createDialog({
    title         = "My Dialog",
    width         = 440,
    height        = 280,
    -- x, y         default: centered in main window
    resizable     = false,   -- default; set true only when content can reflow
    contextMenu   = false,   -- default for createDialog; system dialogs keep it off
    closeable     = true,    -- default; gives a close button
})
-- d is an overlay MuxPane; put widgets in d.content
-- Dismiss: d:close()
```

`Mux.createDialog` is a thin wrapper over `MuxDialog:new` (a `MuxPane` subclass — see Class model); dialogs claim the top of the z-order on creation, so a newer dialog never opens beneath an older one.

`createDialog` accepts the same positive-convention option names used everywhere else (`resizable`, `contextMenu`, `titlebarHideable`, `renamable`, `contentable`, `tabsLocked`, `convertible`, `minimizable`, `closeable`) and defaults each to the restrictive state appropriate for a system dialog. Passing legacy `no*` names has no effect — they are not read.

`Mux.createDialog` calls `_detachToFloat()` immediately, so `d.content:get_width()` is correct synchronously after the call — no timer needed to query geometry.

For dialogs that show dynamic content (settings, properties) use `Mux._applyContent(d, "my_content_id")` so `contentBg` is hidden and the content lifecycle is tracked — EXCEPT dialogs built with `MuxDialog:mountForm` (a scrolling/auto-fit form), which must build directly on `d.content` instead; see the `mountForm` exception in What NOT to do.

---

## Theme system

`Mux.applyTheme(name)` walks every live `Mux._panes` entry and every `Mux._splits` entry and calls `applyTheme()` on each.  Theme changes are therefore instant.

**All new UI must read colours from the active theme**, never hard-code values.  Pattern:
```lua
local theme = Mux.activeTheme()
local sui   = theme.settingsUi or {}   -- for settings/properties-style UI
local bg    = sui.bg or "rgb(18,18,26)"
local text  = sui.textColor or "rgba(215,215,230,0.92)"
-- ...derive CSS strings here, then apply to widgets
```

Theme fields used by settings / properties UI (all accessed via `theme.settingsUi`):
`bg`, `rowOdd`, `rowEven`, `rowDivider`, `textColor`,
`widgetBg`, `widgetFg`, `widgetBorder`, `widgetHoverBg`,
`inputBg`, `inputFg`, `inputBorder`,
`toggleOnBg/Fg/Border/HoverBg`, `toggleOffBg/Fg/Border/HoverBg`,
`helpIconFg/Bg/Border`

Direct theme fields (not under `settingsUi`):
`titlebarHeight`, `revealStripHeight`, `tabBarHeight`,
`contextMenuItemHeight`, `contextMenuWidth`,
`titlebarTextColor`, `btnTextColor`,
`scrollbarCss` (pushed to `setProfileStyleSheet` for Qt scrollbar styling)

Registering a theme:
```lua
local base = Mux._merge(Mux._themes["dark"], { titlebarHeight = 28 })
Mux.registerTheme("my_theme", base)
```

---

## Settings window

`Mux.settings.toggle()` opens/closes the settings dialog.  Internally it is a `Mux.createDialog` pane with `noTabs = false` (tabs enabled for category navigation).  Its widget content is built via `buildSettingsContent` which creates a `Geyser.ScrollBox` inside the tab's `content` container, then rows of toggle / dropdown / stepper / text-entry widgets.

Settings keys are registered with `Mux.settings.register(ns, key, cfg)`:
```lua
Mux.settings.register("mux", "debugMode", {
    tab         = "Muxlet",          -- top-level tab label in settings UI
    description = "Enable debug logging",
    default     = false,
})
```
`tab = "Parent/Child"` nests under a sub-tab.  Reading: `Mux.settings.get(ns, key)`.  Writing: `Mux.settings.set(ns, key, value)`.  Both trigger `onChange` callbacks and auto-save.

Widget type is inferred from `cfg.default`:
- `boolean` → toggle
- `number` with `min`/`max` where range ≤ 100 → stepper
- `choices` table → dropdown
- anything else → text entry

---

## Properties dialog

`Mux.showPaneProperties(pane)` / `Mux.showTabProperties(host, tab)` — open a small locked `createDialog` pane and apply `"mux_properties"` content to it.

The content type is registered at properties.lua load time (`Mux.registerContent("mux_properties", ...)`).  The apply function reads `pendingRows` (a module-level variable set synchronously before calling `_applyContent`) to build the row widgets.

Adding new properties: extend `paneRows()` / `tabRows()` in `src/scripts/properties.lua`.  Row schema:
```lua
{
    label   = "Display Name",
    desc    = "One-line description shown below the label",
    type    = "toggle",   -- or "text"
    readFn  = function() return target.someField end,
    writeFn = function(v) ... end,
}
```

The properties dialog and the settings window both build their rows through the shared form builder described next, rather than hand-placing widgets.

---

## Form builder (`Mux.ui`, widgets.lua)

`widgets.lua` provides the declarative, theme-aware form toolkit used by the properties dialog, the settings panel, and any downstream package that wants matching widgets. Prefer it over hand-placing `Geyser.Label` toggles.

```lua
Mux.ui.buildForm(parent, specs, opts)  -- → formHandle
Mux.ui.specHeight(spec)                -- → pixel height of one row
Mux.ui.formHeight(specs)               -- → total pixel height of all rows
```

A spec describes one row; the widget is inferred from `type` (or forced with `display`):

```lua
{
    label    = "Show timestamps",
    desc     = "Tooltip / help-icon text",
    type     = "bool",          -- "bool" | "string" | "number" | "array"
                                -- aliases: "toggle"→bool, "text"→string,
                                --          "choiceCycler"→array, "readOnly"→string+readOnly
    display  = "checkbox",      -- "checkbox"|"cycler"|"dropdown"|"text"|"stepper"; inferred when omitted
    options  = { { value = true, label = "ON" }, { value = false, label = "OFF" } },
    step = 1, min = 0, max = 100,   -- number+stepper
    readOnly = false,
    readFn   = function() return target.someField end,
    writeFn  = function(v) ... end,
}
```

Key `opts` fields: `prefix` (unique widget-name prefix — **required** when two forms share a parent), `width`, `rowHeight` (default 42), `textRowHeight` (default 64), `showReset` + `onReset(i, spec)`, and `getContentScreenPos()` (returns the content area's absolute top-left; **required** for dropdown rows so the overlay positions correctly).

The returned `formHandle` exposes `.totalHeight`, `.closeDropdown()`, `.refresh(i)`, and `.refreshAll()`. Widget styling is read from `theme.ui.styles` with built-in fallbacks, so forms re-theme automatically like every other surface.

---

## Key files

```
src/scripts/globals.lua            — Mux table, ID generators, class factory, context menu renderer, Mux._serializeLua (shared table→Lua-source serializer for all export commands)
src/scripts/settings.lua           — settings registry, settings dialog, row builders
src/scripts/content.lua            — registerContent, _applyContent, singleton tracking
src/scripts/update.lua             — version check and auto-update logic
src/scripts/style.lua               — token engine (Mux.tok, setGlobalToken/setLocalToken) + theme registry (registerTheme, applyTheme, activeTheme(), merged from the former theme.lua), saveThemeFromGlobals/exportTheme/exportAllThemes
src/scripts/pane.lua               — MuxPane class: construction, titlebar, lock/unlock, close, resize
src/scripts/tabs.lua               — Tab infrastructure: buildTabInfrastructure, addTab, activateTabObj
src/scripts/connection.lua         — connectionAware pane/tab integration
src/scripts/split.lua              — MuxSplit: binary split with drag-resize handle
src/scripts/panespace.lua           — MuxPaneSpace: border-zone management, root node management
src/scripts/manager.lua            — pane lookup (getPane), z-order (raisePane / raiseFloatingPanes via Mux._raiseSeq), recovery (mux panes / mux reveal). No focus tracking — panes are styled by their resting frame, not a focus border.
src/scripts/dialog.lua             — Mux.createDialog(opts), Mux.dialogCss palette
src/scripts/widgets.lua            — Mux.ui declarative, theme-aware form builder (buildForm/specHeight/formHeight)
src/scripts/welcome.lua            — first-run welcome dialog (registered internal content)
src/scripts/workspace.lua          — registerWorkspace, applyWorkspace, saveWorkspace, auto-save, exportWorkspace (dependency-aware — bundles referenced conditions/actions), exportAll
src/scripts/conditional.lua        — condition engine (Mux._conditionValue, rule evaluation), declarative condition/action store (createDeclarativeCondition/Action, rules.json), exportCondition/exportAction (+ "all" variants)
src/scripts/content_builtins.lua   — registerGmcpViewer + gmcp_inspector content
src/scripts/properties.lua         — Mux.showPaneProperties, Mux.showTabProperties, mux_properties content
src/scripts/devmode.lua            — local-build auto-reload and `mux reload` helpers
src/scripts/themes/                — dark.lua, light.lua (theme definitions)
src/aliases/mux.lua                — the `mux` command alias (parses all subcommands)
```

Load order (`src/scripts/scripts.json`): globals → settings → content → update → theme → pane → tabs → connection → split → panespace → manager → dialog → widgets → welcome → workspace → content_builtins → properties → devmode → themes

There is no keybinds module. Muxlet ships no Alt+key bindings; every action is reachable through the `mux` command alias, the titlebar buttons, and the context menus. (The reveal-strip tooltip in `pane.lua` mentions "Press Alt+[ to restore titlebar," but no such binding is registered — the tooltip text is stale and the titlebar is restored by clicking the reveal strip, through the Properties dialog, with `pane:setTitlebarVisible(true)`, or with `mux reveal <id>`. Treat that tooltip as a known bug, not a documented feature.)

---

## Performance model

Layout used to be O(branches^depth). Geyser's `set_constraints` runs `calc_constraints` **and** `reposition`; `Container:move`/`:resize` each call it; `HBox`/`VBox:organize` calls both move and resize per child; and `Container:set_constraints` recurses every child. Because a MuxSplit box always contains a Fixed-policy handle, any `reposition` re-runs `organize`. One `box:reposition()` therefore fans out across the whole subtree, and a nested resize measured 3600–5500 ms.

The fix rests on one fact: Geyser's `get_x/get_y/get_width/get_height` are derived from the constraint **chain** (parent getter × scale + offset), not from native window state. So constraints can be recomputed with repositioning suppressed, then native geometry applied in a single pass.

Two shared helpers in globals.lua:
- `Mux._suppressReposition(fn)` — temporarily replaces `Geyser.set_constraints` with a calc-only version, runs `fn` (e.g. `organize`), and restores it under `pcall`. Constraints update; nothing repositions.
- `Mux._applyGeometry(win)` — one depth-first pass of `moveWindow`/`resizeWindow` per window, then `redraw`. This is the single geometry-apply used by resize, split-create, and workspace load.

The resize/create/load paths all follow the same shape: **suppress → `organize` → `Mux._applyGeometry` → notify.** Resize dropped from ~3600 ms to 1–2 ms. The whole block runs inside a `Mux._inResize` guard so the `sysWindowResizeEvent` echo that `setBorderSizes` raises is ignored (the event handler's own guard only blocks re-entry once already running).

**Preview vs live drag.** Dragging a handle live re-runs the layout every frame — smooth for pane-only subtrees, but unusable when the main console is involved because resizing it reflows the entire scrollback each frame. So a handle uses the lightweight preview line (deferring the real resize to mouse-release) when `_leafCount() > mux.live_resize_max_panes` **or** `MuxSplit:_subtreeHasMainConsole()` is true; otherwise it stays live. `live_resize_max_panes` is a registered setting (default 2).

**What the release cost actually is (measured).** The one-time `notify` on release scales with the **live** layout — roughly per visible pane, plus more per live tab — topping out around ~125 ms for a heavy multi-pane/many-tab arrangement. It is **not** proportional to the scrollback buffer, and it is **not** caused by hidden/closed widgets: closing a tab only hides it, yet the cost drops, so dead widgets don't count toward it. Earlier ~900 ms readings came from an earlier code state before the preview + `_inResize` guard landed (a double-fire of the main-console reflow), not from the steady state.

**Still using stock layout.** Structural operations off the hot path — `place`, `collapseSlot`, `zoom` — still use stock `organize()` + `reposition()`. They could adopt the suppress technique later if they ever surface in profiling.

**Debug timing.** With `mux debug on`, `_setRatio` prints `[mux perf] <split> leaves=N applyGeometry=Xms notify=Yms`, and pane create/close print their own timings. These lines are gated behind `Mux.debug` and can be stripped for a clean build.

**Teardown note.** Pane/tab/panespace teardown currently *hides* widgets rather than deleting them, so hidden Geyser windows accumulate over a long session — a memory matter, not a resize-speed one (see above). Geyser exposes a recursive `Container:delete()` (deletes children first, clears its registries, calls `deleteLabel`/`deleteMiniConsole`) that can be wired into `close`/`removeTab`/`destroy` if long-session memory ever becomes a concern.

---

## Geyser notes

- **Widget names must be globally unique** across the entire Mudlet session.  Use `Mux._newInternalId()` for widget names, or prefix with a pane/dialog ID: `"mux_prop_" .. pane.id .. "_widget"`.
- **`Geyser.ScrollBox`** overrides `get_x()` / `get_y()` to return 0 after construction.  Child widgets inside a ScrollBox should use absolute pixel offsets relative to the scroll origin (0,0), not relative to the screen.
- **`Geyser.Container:show(auto)`** — `auto=true` clears `auto_hidden` but not `hidden`.  Widgets explicitly hidden with `:hide()` stay hidden when a parent is shown with `show(true)`.
- **`base_add`** calls `reposition()` after adding a child, so widget sizes are immediately correct after `Geyser.Label:new(...)` — no timer required.
- **Synchronous geometry**: after `Mux.createDialog` returns, all geometry is computed.  Build widgets immediately; never use `tempTimer(0, ...)` just to defer widget construction.
- **`fillBg=1`** on a Label makes it render a solid CSS background.  The `contentBg` placeholder label in every pane uses this; it covers the entire content area until `contentBg:hide()` is called by the content system.

---

## Naming conventions

All Lua identifiers: **camelCase**, descriptive, no abbreviations.

```lua
-- correct
local itemHeight = 24
local function buildTitlebar(theme) end
self.titlebarVisible = true

-- wrong
local IH = 24
local function build_titlebar(theme) end
self.titlebar_visible = true
```

Leading underscore (`_applyBorders`, `_focusedPane`) signals internal/private by convention — Lua gives it no enforcement.

External API names (Geyser, Mudlet built-ins) are not ours to rename.

---

## What NOT to do

- Do not build UI directly into `pane.content` without going through `Mux._applyContent` — doing so leaves `contentBg` visible (placeholder on top), bypasses the content lifecycle, and causes `activeContent` to not be saved in workspaces. **Exception:** dialogs built with `MuxDialog:mountForm` (dialog.lua) must go the OTHER way — build directly on `dlg.content` (hide `dlg.contentBg` manually, then call `dlg:mountForm(...)`), matching `contentLibrary/buttons.lua`'s `openGridSettings` / `contentLibrary/capture.lua`'s `openCaptureSettings`. Routing a `mountForm` dialog through `_applyContent` swaps `target.content` for a temporary slot sized to the dialog's PRE-`fitContent` geometry; the ScrollBox `mountForm` builds never catches up when `fitContent` grows the frame afterward, leaving most of the dialog showing Qt's bare white background.
- Do not append hand-rendered widgets to a `buildForm` panel/dialog OUTSIDE the `specs` array it was built from. `buildForm`'s own `relayout()` (collapse/expand, and any external caller of `formHandle.relayout`/`target._muxRelayout`) only resizes the content label to fit the specs IT knows about — extra content appended afterward gets silently clobbered on the next relayout. If a panel needs a custom look a plain field spec can't produce (e.g. a clickable list row with a delete icon), add a new block-layout entry to `Mux.ui._builtins` (see `listRow` in widgets.lua) and put it in the specs array like any other row, rather than hand-building it alongside the form.
- Any code that resizes a pane/dialog's `.outer` directly (`d.outer:resize(...)`) must follow with `Mux._reflowContent(d)` (or call a helper that already does), or nested `.content` several levels deep (tab → sub-tab → ScrollBox) keeps reporting its PRE-resize size even though the visible frame changed. `MuxPane:_detachToFloat` already does this; `MuxDialog:fitContent` and `Mux._fitDialogToActiveTab` needed it added.
- Do not register Muxlet system UI content without `internal = true` — it will appear in the user-facing "Add Content" menu and be written to the content catalog file.
- Do not use `tempTimer(0, fn)` to defer widget construction — geometry is synchronous after `createDialog` / `_detachToFloat`.
- Do not set `pane._activeContent` manually — use `Mux._applyContent` which handles cleanup of previous content.
- Do not create floating system UI as raw Geyser windows — always use `Mux.createDialog`.
- Do not hardcode CSS colours — derive them from `Mux.activeTheme()` so the theme system can refresh them.
- Do not skip `contentBg:hide()` when applying content — the placeholder label covers the entire content area with `fillBg=1`.
- Do not serialise `overlay` panes into workspaces — they are transient system UI and are excluded by `serializeNode`.
- Do not use `\xNN` or `\uXXXX` Lua escape sequences for Unicode characters — embed them as literal UTF-8 in source files.
- Do not create `Geyser.ScrollBox` children using percentage constraints — ScrollBox's `get_x/get_y` returns 0 after construction; use absolute pixel values.
- Do not call stock `organize()`/`reposition()` on the resize/create/load hot path — wrap layout in `Mux._suppressReposition` and apply native geometry once with `Mux._applyGeometry`, or you reintroduce the O(branches^depth) cascade (see Performance model).