# Muxlet — Package Developer Guide

This document covers Muxlet's public API for package authors: bootstrapping against
a host profile, registering content/actions/conditions/themes/workspaces, and the
source layout. For installing and using Muxlet as an end user, see the main
[README](../README.md).

---

Muxlet exposes a single global table, `Mux`. Everything below is a method or table on
it. Public API is unprefixed (`Mux.registerContent`); names beginning with an
underscore (`Mux._applyContent`) are internal but stable enough to call when noted.

A Muxlet add-on is just a Mudlet package whose scripts run after Muxlet's. Register
your content/actions/conditions/themes/workspaces at load time; they slot into the
same UI users already have.

## Bootstrapping from your own package

Paste this at the very top of your package's init script, filling in the version
you've built/tested against and the matching GitHub Releases download URL (see
Muxlet's own Releases page — `.../releases/download/v<version>/Muxlet.mpackage`
for a tagged release, or the bare version tag for a pre-release). Nothing else in
your package should assume `Mux` exists until your callback runs.

```lua
local MUXLET_VERSION = "2.1.0"
local MUXLET_URL = "https://github.com/<owner>/Muxlet/releases/download/v2.1.0/Muxlet.mpackage"

local function onMuxletReady()
    Mux.ensureVersion(MUXLET_VERSION, MUXLET_URL, function()
        -- Runs once a Muxlet satisfying MUXLET_VERSION is loaded and ready.
        -- Every field below is optional — omit any you don't have an opinion
        -- on yet (see Mux.configureHost for the full list and defaults).
        Mux.configureHost({
            suppressWelcome    = true,   -- you're showing your own onboarding, not Muxlet's
            autoStart          = false,  -- your onboarding decides when Mux.fullStart() runs
            quietStart         = true,   -- you're printing your own "started" message
            checkForUpdates    = false,  -- you pin a Muxlet version; don't offer drift from it
            includePrereleases = false,  -- only relevant if checkForUpdates is left true
            defaultWorkspace   = "myPackageWorkspace",  -- must already be registered
        })

        -- The rest of your package's real startup goes here: register
        -- content/workspaces, decide (from your own settings) whether to
        -- call Mux.fullStart() now or wait for the user.
    end)
end

registerAnonymousEventHandler("muxletReady", onMuxletReady)

if Mux and Mux._ready then
    onMuxletReady()                                  -- Muxlet already ready this session
elseif not table.contains(getPackages(), "Muxlet") then
    if not MUXLET_URL then
        cecho("\n<red>[your-package]<reset> Cannot install Muxlet: build is missing MUXLET_URL injection.\n")
    else
        installPackage(MUXLET_URL)                    -- not installed at all yet
    end
end
-- Otherwise Muxlet is installed but hasn't finished loading yet this
-- session — the handler above will fire naturally once it does.
```

Why `Mux and Mux._ready` rather than just `Mux`: the `Mux` table is created at
the very start of Muxlet's own load sequence, before the rest of its scripts
have necessarily run — checking only `Mux` risks calling into an API that
doesn't exist yet if your package's Lua happens to execute mid-way through
Muxlet's. `Mux._ready` only becomes true once Muxlet's `muxletReady` event has
actually fired. Likewise, the `elseif` uses
`table.contains(getPackages(), "Muxlet")` rather than reinstalling
unconditionally, since that reads the profile's package manifest — safe
regardless of Lua load order — rather than assuming Muxlet is missing just
because `Mux` isn't ready yet.

The `MUXLET_URL` nil-check guards against a bad build (your package's build
step failed to inject the URL) — without it, `installPackage(nil)` fails with
a confusing native error instead of a clear one. `Mux.ensureVersion` has the
same guard built in for the upgrade path, so it's only needed here for the
"never installed" path, which runs before `Mux` exists.

`Mux.ensureVersion` handles keeping the *version* correct (installing or
upgrading in place) every time `onMuxletReady` fires — including the retry
after it triggers an upgrade, since the freshly installed Muxlet raises its
own `muxletReady`, which your handler receives again. `Mux.configureHost`
(called from inside the callback, once the version is confirmed) bundles the
startup choices that go along with owning your own onboarding — see its
doc comment in `update.lua` for the full field list and what each defaults to
if you omit it.

## Accessing the live graph

```lua
Mux._panes                     -- table: pane id -> MuxPane (the live registry)
panes[id]                      -- convenience global proxy for Mux._panes[id]
local p = Mux.newPane(opts)    -- create a pane (see MuxPane options)
```

Useful `MuxPane` methods (panes and tabs share `MuxSurface`, noted):

```lua
p:split("v", 0.6)      -- "v" = left/right, "h" = top/bottom; ratio 0..1; returns the split
p:zoom()               -- fill the screen; call again to restore
p:float() ; p:embed()
p:close()
p:setName("Map")
p:setTitlebarVisible(false)
p:setBordered(false) ; p:setBorderColor("#88aaff")
p:setCondition(spec)   -- inline reactive condition (see Rules)
p:raise() ; p:lower()  -- z-order for floating panes/dialogs
p:setNameAlign("center")            -- "left" (default) | "center" | "right"
p:setAnchor(spec) ; p:removeAnchor() ; p:returnToAnchor() ; p:isAnchored()
p:absX() ; p:absY() ; p:width() ; p:height()   -- absolute screen geometry

-- MuxSurface (pane OR tab):
p:enableTabs() ; p:disableTabs()
local t = p:addTab("Status")   -- returns the new MuxTab
p:activateTab(tabId) ; p:getTab(tabId)
p:renameTab(tabId, "Chat") ; p:removeTab(tabId)
```

## Registering content

`Mux.registerContent(name, def)` adds a content type. Only `apply` is required.
Content is attached to a surface with `Mux._applyContent(target, name)` (the Content
Library and the `applyContent` action op call this for you). `target` is a pane or a
tab.

```lua
Mux.registerContent("myclock", {
  name        = "Clock",                       -- Content Library label
  description = "A ticking clock.",            -- Content Library subtitle
  group       = "My Package",                   -- optional; Content Library section (see below)
  singleton   = false,                          -- true = only one instance across all surfaces
  internal    = false,                          -- true = hide from the Content Library
  noTabs      = false,                          -- true = disallow tabs on the hosting pane

  -- Optionally forbid applying in some contexts. Return false + reason to block;
  -- the library greys the item and shows the reason on hover.
  canApply = function(target)
    if target.floating then return false, "Clock must be embedded." end
    return true
  end,

  -- Lock host pane properties while this content is active. Sets the value AND marks
  -- it read-only in Properties (reason on hover). Reverted automatically on remove.
  paramLocks = {
    movable = { value = false, why = "The clock pins its pane in place." },
  },

  apply = function(target)
    -- Build your widget(s) into the surface. target.content is the Geyser container;
    -- target.contentBg is the background label. target.id is the surface id.
    target._clock = Geyser.Label:new({ name = target._gid .. "_clock",
      x = 0, y = 0, width = "100%", height = "100%" }, target.content)
    target._clockTimer = tempTimer(1, function()
      if target._clock then target._clock:echo(os.date("%H:%M:%S")) end
    end, true)
  end,

  remove = function(target)                    -- tear down what apply built
    if target._clockTimer then killTimer(target._clockTimer) end
    target._clock, target._clockTimer = nil, nil
  end,

  resize   = function(target) end,             -- called when the surface changes size
  serialize = function(target)                 -- return a plain table saved with the workspace
    return { format = "24h" }
  end,
  restore  = function(target, data) end,       -- receive that table on workspace restore

  -- See "Publishing to the titlebar and menu" below.
  titlebarElements = { … },
  onReveal = function(target) end,             -- called by `mux reveal <id>`
})
```

`group` controls how the item is presented in the Content Library dialog: items
sharing a group are bucketed under a collapsible divider labelled with that group
name, collapsed by default. Omit `group` and the item renders as a flat row above
the groups instead — no divider, always visible. Muxlet's own built-in content
(console, button grid, capture, GMCP inspector) is grouped under `"Muxlet"`; pick
any group name for your own package, or leave content ungrouped if you only
register a handful of items.

## Publishing to the titlebar and menu

A content def's `titlebarElements` list adds icons to the host titlebar and/or rows
to its right-click menu. These follow the content whether it lives on a pane or a
tab. Every callback receives a **context** table:

```lua
ctx = {
  pane        = <MuxPane>,        -- the host pane (always present)
  tab         = <MuxTab|nil>,     -- the active tab, if the content lives in one
  isTab       = <bool>,           -- true when the content is on a tab
  isFloating  = <bool>,
  isEmbedded  = <bool>,
  content     = <content def>,    -- this content's registered definition
}
```

Element spec (all fields optional except `id`):

```lua
titlebarElements = {
  {
    id       = "myclock.settings",  -- unique id (avoid built-in ids)
    side     = "left",              -- "left" | "right" cluster
    group    = "info",              -- packing/menu group for ordering
    order    = 0,                   -- order within the group
    priority = 100,                 -- higher folds into the right-click menu last
    icon     = "⚙",                 -- glyph, or a function(ctx) -> glyph
    tooltip  = "Clock settings",
    iconable = true,                -- false = never a titlebar icon, menu-only
    visible  = function(ctx) return true end,   -- optional; default visible
    onClick  = function(ctx, event) openClockSettings(ctx.tab or ctx.pane) end,

    -- Menu counterpart (shown in the right-click menu / when folded):
    menuText  = "⚙  Clock settings…",  -- string or function(ctx) -> string
    menuGroup = "info",
    menuOrder = 95,
    run       = function(ctx) openClockSettings(ctx.tab or ctx.pane) end,
  },
}
```

Resolve the surface that actually owns the content with `ctx.tab or ctx.pane` — that
is the value to pass to your own settings dialog and to `serialize`/`restore`.

Advanced, menu-only fields (see `library/content/buttons.lua` for a real example):
`menuFallbackOnly` (this element's `menuText` doesn't by itself force the right-click
menu open — only reachable once the menu is showing for another reason),
`menuKeepOpen` (bool, or `function(ctx) -> bool`; keep the menu open after this row
runs, e.g. so a submenu stays reachable), and `menuSubmenu(ctx) -> items|nil` (a
dynamic list of `{ text, fn, keepOpen? }` rows nested under this one).

## Settings dialogs and forms

`Mux.createDialog(opts)` returns a floating `MuxDialog` (itself a pane). Give it a
form with `d:mountForm(specs, formOpts)`, which builds a scrolling form that grows to
fit its content up to a share of the screen, snaps back when it shrinks, stays
on-screen, and positions dropdown/colour popups correctly — no per-dialog code.

```lua
local d = Mux.createDialog({
  title = "Clock — " .. Mux._targetPath(target),
  width = 380, height = 300,
  singleton = "myclock_" .. target.id,   -- reuse the same dialog if already open
  contextMenu = false,
  maxHeightPct = 0.82, minHeight = 140,  -- autofit bounds
})

d:mountForm({
  { type = "divider", label = "Clock" },
  { label = "Format", type = "array", display = "dropdown",
    options = { { value = "24h", label = "24-hour" }, { value = "12h", label = "12-hour" } },
    readFn  = function() return cfg.format end,
    writeFn = function(v) cfg.format = v end },
  { label = "Show seconds", type = "toggle",
    readFn  = function() return cfg.seconds end,
    writeFn = function(v) cfg.seconds = v end },
  { label = "Label", type = "text", allowEmpty = true,
    readFn  = function() return cfg.label or "" end,
    writeFn = function(v) cfg.label = v end },
}, { prefix = d._gid .. "_clockform" })
```

Form row `type` values (canonical: `string`, `number`, `bool`, `array`; the rest are
aliases): `text` (→ `string`; full-width block with a label above and an **Apply**
button — there is no separate single-line variant), `readOnly` (→ `string` +
read-only, value shown but not editable), `number` (display defaults to `stepper`;
`min`, `max`, `step`), `toggle` (→ `bool`, checkbox), `array` (choose one; `display =
"dropdown" | "cycler" | "segmented"`), `choiceCycler` (→ `array` + cycler),
`segmentedControl` (→ `array` + segmented), `color`, `button` (`onClick`), `code`
(Lua editor, registered via `Mux.ui.registerWidget`), `listRow` (a clickable "pick one
of these named things" row — `title`, `subtitle`, `accent`, `dim`, `onClick`,
`onDelete`; used by the built-in Conditions/Actions dialogs), and `divider` (section
header; following rows collapse under it). Common per-row fields: `label`, `desc`,
`readFn`, `writeFn`, `options`, `allowEmpty`, `trueLabel`/`falseLabel`, `locked`,
`lockedReason`, `readOnly`.

Text rows show an **Apply** button that greys out when the field matches what's
applied and brightens when edited. Set `allowEmpty = true` to let a field be cleared
by blanking it and pressing Enter.

Two more building blocks:

```lua
Mux.ui.registerWidget(type, builder, opts)   -- add a custom form row type
Mux.ui.iconCascade(parent, opts)             -- a fan-out strip/popup of icon buttons
```

## Conditions and actions (the rule engine)

A **rule** on a subject (pane or tab) is `{ id, cond, act, actElse, enabled }`:

```lua
Mux._addRule(pane, {
  id      = "hide-when-offline",
  cond    = { type = "disconnected" },   -- inline spec, or { ref = "<named condition id>" }
  act     = "mux.hideSelf",              -- action id to run when the condition is met
  actElse = "mux.showSelf",              -- optional: run when it becomes not-met
  enabled = true,
})
Mux._removeRule(pane, "hide-when-offline")
Mux._reapplyRule(pane, rule)             -- re-arm after editing cond/enabled in place
```

Rules are independent, so a subject can react to several signals at once. Rule
evaluation follows a value change; trigger-backed conditions (below) fire on each
match instead.

### Condition types

```lua
{ type = "always" }
{ type = "connected" }                                   -- live socket status
{ type = "connecting" }
{ type = "disconnected" }
{ type = "gmcp_exists",  path  = "char.vitals" }
{ type = "gmcp_equals",  path  = "char.vitals.hp", value = "100" }
{ type = "gmcp_contains", path = "room.info.players", values = "Bob,Alice" }  -- comma list or array; case-insensitive
{ type = "event_fired",  event = "myEvent", seconds = 5 } -- true if fired in the last N seconds
{ type = "line_match",   pattern = "You are hungry", mode = "substring" }  -- mode: substring|exact|regex
```

`line_match` is a *pulse* condition: Muxlet manages a Mudlet trigger for it and fires
the rule's action once per match, with the matched text/captures in the action
context.

### Actions and action ops

An action is registered under an id and run with a context. Beyond the reactive pair
`mux.showSelf`/`mux.hideSelf`, Muxlet ships several other built-ins in
`library/actions/`: `mux.reconnect`, `mux.clearConsole`, and the "explicitly-targeted"
family `mux.showTarget`/`mux.hideTarget`/`mux.toggleTarget` (plus the connection-aware
overlay show/hide pairs). You can register your own the same way:

```lua
Mux.registerAction("myclock.reset", {
  name = "Reset clock", group = "user", icon = "⏱",
  run  = function(ctx) --[[ ctx = { pane, tab, value, met } ]] end,
})
Mux.runAction("myclock.reset", { pane = somePane })
```

Set `needsTarget = true` on a def when the action acts on an explicit *other*
pane/tab rather than "self" — the built-in `showTarget`/`hideTarget`/`toggleTarget`
actions do this, and the Button Grid's editor shows a "Target Pane/Tab" picker
(`Mux.listTargets()`/`Mux.findTarget(id)`, from `manager.lua`) whenever the chosen
action declares it.

User-defined actions in the UI are built from **ops** (steps). Register new palette
ops so users can compose them:

```lua
-- def.fields[].kind tells the editor which control to show:
--   text | lua | content | theme | choice
Mux.registerActionOp("notify", {
  label = "Desktop notify", group = "Game", icon = "🔔",
  desc  = "Show a notification.",
  fields = { { key = "text", label = "Message", kind = "text" } },
  run   = function(step, ctx) --[[ step.text, ctx.pane/tab/value ]] end,
})
```

Built-in ops: `send`, `echo`, `raise`, `showPane`, `hidePane`, `zoomPane`,
`unzoomPane`, `removePane`, `applyContent`, `createPane`, `switchTheme`, `lua`.

### Named conditions and actions (persisted)

These round-trip to `rules.json` and populate the editor's dropdowns:

```lua
Mux.createDeclarativeCondition({ id = "lowhp", label = "Low HP",
  cond = { type = "gmcp_equals", path = "char.vitals.hp", value = "0" } })

Mux.createDeclarativeAction({ id = "flee", label = "Flee",
  steps = { { op = "send", command = "flee" }, { op = "echo", text = "Running!" } } })

Mux.listConditions() ; Mux.listActions()      -- for building your own UI
```

`Mux.createDeclarativeCondition`/`Mux.createDeclarativeAction` calls like these are
exactly what `mux conditions export`/`mux actions export` generate from ones you
built interactively — see [Exporting your work](#exporting-your-work-for-a-package).

## Theming

Styling resolves through a four-level **token** cascade. For any token key, the value
is the first of: **local** (set on one surface) → **global** (set everywhere) →
**active theme** → **fallback** (the shipped defaults). Elements read their CSS
through this cascade, so an override at any level flows through automatically.

```lua
Mux.tok(key, scope)               -- resolve a token value (scope = a pane/tab, optional)
Mux.css(element, scope)           -- assembled stylesheet string for an element
Mux.tokenSource(key, scope)       -- "local" | "global" | "theme" | "fallback"

Mux.setGlobalToken(key, val)      -- override everywhere
Mux.clearGlobalToken(key)
Mux.setLocalToken(scope, key, v)  -- override on one pane/tab only
```

A theme is a sparse table of token overrides. Register one, then switch to it:

```lua
Mux.registerTheme("ocean", {
  ["pane.bg"]              = "rgba(18,30,46,248)",
  ["pane.border.color"]   = "rgba(120,180,255,0.35)",
  ["titlebar.bg"]         = "rgba(24,42,64,240)",
  ["titlebar.text.color"] = "rgba(220,235,255,0.95)",
  ["btn.bg"]              = "rgba(40,70,104,200)",
})
Mux.applyTheme("ocean")
```

Anything a theme omits inherits the fallback, so the dark theme is literally an empty
table (`Mux.registerTheme("dark", {})`) — it *is* the fallback. Look at
`library/themes/light.lua` for the full set of keys you can override.

Two escape hatches:

```lua
-- Save the current look (active theme overlaid with the user's global tweaks) as a
-- new named, persistent theme — the same thing `mux theme save <name>` does:
Mux.saveThemeFromGlobals("mylook")

-- Persistent profile-wide Qt CSS that survives theme switches:
Mux.addProfileCss("QToolTip { color: #eee; }")
```

For total control over one element, set its `cssOverride` token to a raw stylesheet
string (at any cascade level); `Mux.css` returns it verbatim, bypassing the template:

```lua
Mux.setLocalToken(pane, "titlebar.cssOverride",
  "background: qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #203, stop:1 #406);")
```

## Workspaces

A workspace is a declarative snapshot. Register one and it becomes loadable by name;
users can also save/restore their own at runtime.

```lua
Mux.registerWorkspace("combat", {
  name  = "Combat",
  theme = "dark",
  paneSpace = {
    id = "screen", zone = "screen",
    root = {                                   -- a split node or a pane node
      type = "split", direction = "v", ratio = 0.7,
      a = { type = "pane", id = "main", name = "Mudlet",
            mainConsoleHost = true, activeContent = "mux_console" },
      b = { type = "pane", id = "side", name = "Status",
            activeContent = "myclock" },
    },
  },
  floatingPanes = {                            -- optional; restored after the tree
    { type = "pane", id = "notes", name = "Notes",
      floating = true, floatX = 80, floatY = 80, floatW = 320, floatH = 200 },
  },
})

Mux.applyWorkspace("combat")
```

Node shapes:

- **Split:** `{ type = "split", direction = "v"|"h", ratio = 0..1, a = <node>, b = <node> }`
- **Pane:** `{ type = "pane", id, name, activeContent, contentState, tabs, condition,
  actionTrue, actionFalse, … capability flags (mainConsoleHost, closeable, movable,
  bordered, addable, …) }`. `addable` only needs setting explicitly when it diverges
  from its per-role default (true for the main console host, false otherwise).

Runtime workspace API:

```lua
Mux.saveWorkspace(name)      -- snapshot the live layout under a name
Mux.listWorkspaces()
Mux.deleteWorkspace(name)
```

Muxlet auto-saves the live layout to `current` shortly after any structural change,
including each pane/tab's content (via your `serialize`/`restore`).

## Exporting your work for a package

Design live — build a workspace, create named conditions/actions from Settings →
Conditions/Actions, save a look with `mux theme save`, wire up rules referencing them
— then export what you built as ready-to-paste Lua and drop it into your package's own
source (after your `onMuxletReady` bootstrap block,
[above](#bootstrapping-from-your-own-package), so `Mux` already exists). Everything
below writes to Muxlet's persistent directory and echoes the path; nothing installs
itself into your package automatically — that step stays manual, since it depends on
your own package's build layout.

Named conditions/actions/themes only round-trip through profile-local storage
(`rules.json`, `user_themes.json`) until exported — a workspace referencing one (a rule's
`{ ref = "id" }`/action id, or `def.theme`) that was never exported ships broken: the
reference silently resolves to an "always" condition (or a theme-switch error) on a
profile that never created that id, with no error surfaced to the person who shipped it.

```
mux workspace export <name>   -- the workspace, PLUS its theme (if user-created) and
                               -- the Mux.createDeclarativeCondition/createDeclarativeAction
                               -- calls its rules actually reference — self-contained

mux conditions export <id>    -- one named condition, standalone
mux conditions export all     -- every named condition in this profile
mux actions export <id>       -- one named action, standalone
mux actions export all        -- every named action in this profile
mux theme export <name>       -- one named theme, standalone (mux theme save already
                               -- does this automatically too)
mux theme export all          -- every named theme in this profile

mux export                    -- EVERYTHING non-built-in at once (all named themes +
                               -- conditions + actions + workspaces), no dependency
                               -- filtering — for a package that ships a whole
                               -- library and lets the end user pick, the way
                               -- fed2-tools' Build Your Own Workspace mode does
```

`mux workspace export` is the common case: one self-contained file for one workspace.
`mux export` is for the opposite case — you don't want a minimal bundle, you want to
hand users the whole menu.

## Persistence

- **Rules, named conditions, named actions** → `rules.json`.
- **Named themes** (`mux theme save`) → `user_themes.json`.
- **Workspaces** → the workspaces file (auto-saved `current` plus any you name).
- **Settings** → Mudlet's per-profile setting store, under namespaces (`mux.*` for
  core behavior, `muxtheme.*` for the active theme, `muxupdate.*` for update checks).

Content persists via its own `serialize`/`restore`, embedded in the workspace snapshot.

All of the above is profile-local — it doesn't ship with a package on its own. See
[Exporting your work](#exporting-your-work-for-a-package) for turning it into static
Lua a package can carry.

---

# Package layout

Muxlet is a Mudlet package. Source lives under `src/`:

```
src/
  aliases/            the `mux` command
  scripts/
    scripts.json      load order (engine + UI, in dependency order)
    globals.lua theme.lua settings.lua content.lua action.lua conditional.lua …
    library/          everything registered through the engines above, one file
                       per item — loads last, since registration only ever
                       depends on its own engine, never on other registered items
      content/        built-in content items (scripts.json: gmcp, buttons, capture)
      themes/         built-in themes (scripts.json: dark, light)
      actions/        built-in actions + step ops (one file each)
      conditions/     built-in named conditions (always, connected, connecting, disconnected)
      workspaces/     built-in workspaces (default)
```

Scripts load in the order listed in `scripts.json`; the engine (globals, theme,
content, action, conditional, …) loads before the UI, and `library/` — every
built-in content type, theme, action, condition, and workspace — loads last.
Your own package's scripts run after Muxlet's, so the whole `Mux` API is
available at your load time.

Built-in content items live in `library/content/` — a good reference for
`registerContent`, `titlebarElements`, and content settings dialogs (`gmcp.lua`,
`buttons.lua`, `capture.lua`). The same one-file-per-item pattern is used for
`library/actions/`, `library/conditions/`, `library/themes/`, and
`library/workspaces/` — each registers through the corresponding engine's
`Mux.registerX` function, no different from how your own package would.
