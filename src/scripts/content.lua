-- Muxlet — Content registry
--
-- Any Lua file — in this package or an external one — can register a named
-- content type that users can apply to any pane or tab from the context menu:
--
--   Mux.registerContent("my_widget", {
--       name        = "My Widget",
--       description = "Fills the pane with something cool",
--       group       = "My Package",   -- optional; see "Content Library grouping" below
--       singleton   = false,   -- set true to allow only one active instance
--       apply  = function(target) ... end,   -- REQUIRED
--       remove = function(target) ... end,   -- optional; called before a new apply
--                                            -- Widget cleanup is automatic — remove()
--                                            -- is only needed for non-widget teardown
--                                            -- (event handlers, timers, state resets).
--   })
--
-- Content Library grouping:
--   `group` is an optional string. The Content Library dialog (Mux._showContentLibrary)
--   buckets content by this field and renders each group under a collapsible divider,
--   collapsed by default. Content registered without a group renders as a flat row
--   above the groups — no divider, always visible, nothing to collapse. Muxlet's own
--   built-in content (console, button grid, capture, gmcp inspector) uses
--   group = "Muxlet"; a downstream package is free to pick its own group name, or
--   leave content ungrouped if it only registers one or two items.
--
-- `target` has the same interface whether it is a pane or a tab:
--   target.id        — unique string id
--   target.name      — display name
--   target.content   — Geyser.Container; parent for your widgets
--   target.contentBg — Geyser.Label; clear this after attaching real content:
--                        target.contentBg:echo("")
--                        target.contentBg:hide()
--
-- Singleton content:
--   When singleton = true only one pane or tab may have the content active at
--   a time.  Attempting to open it in a second target shows a small dialog
--   naming where it is currently open; the apply is aborted.
--   Works for both panes and tabs because the tracking uses a direct object
--   reference (def._activeTargetRef) rather than a pane ID lookup.
--
-- The context menu reads Mux._content at open-time so entries registered
-- after startup appear automatically without restarting Mudlet.
--
-- Persistence:
--   Each registration is saved to Muxlet_persistent/content.json as a catalog
--   of {name, description, singleton, group} pairs.  The apply/remove Lua functions
--   are not serialisable; they are always re-registered at load time.

Mux._content     = Mux._content     or {}
Mux._contentFile = Mux._persistentDir .. "/content.json"

-- Destroy a target's active content slot — the disposable Geyser.Container
-- that the framework creates around each apply() call.
-- Geyser.Container:delete() is recursive: it deletes all descendants (including
-- ScrollBox children), calls type_delete() (deleteLabel / deleteScrollBox), and
-- unregisters from Geyser.windowList / Geyser.parentWindows.
-- This is the single teardown path for all content, regardless of widget depth.
local function destroyContentSlot(target)
    if target._contentSlot then
        pcall(target._contentSlot.delete, target._contentSlot)
        target._contentSlot = nil
    end
end

-- Exposed so _clearWorkspace (manager.lua) can tear down every pane's active
-- content before wiping the pane registry.
Mux._destroyContentWidgets = destroyContentSlot

local function saveContentCatalog()
    local catalog = {}
    for id, def in pairs(Mux._content) do
        if not def.internal then
            catalog[id] = {
                name        = def.name        or id,
                description = def.description or "",
                singleton   = def.singleton   or false,
                group       = def.group       or "",
            }
        end
    end
    local ok, err = pcall(function()
        local f = io.open(Mux._contentFile, "w")
        f:write(yajl.to_string(catalog))
        f:close()
    end)
    if not ok then Mux._err("content catalog save failed: %s", tostring(err)) end
    Mux._log("content catalog saved to %s", Mux._contentFile)
end

-- Debounced: coalesce rapid registrations at startup into one write.
local _saveTimer = nil
local function scheduleSave()
    if _saveTimer then killTimer(_saveTimer) end
    _saveTimer = tempTimer(1, function()
        _saveTimer = nil
        saveContentCatalog()
    end)
end

local function showSingletonBlocked(contentName, def, existing)
    local targetName = (existing and existing.name) or "another pane"
    if not (Mux.createDialog and Mux.dialogCss) then
        Mux._warn("'%s' is a singleton already active in '%s'", contentName, targetName)
        return
    end
    Mux._pendingSingleton = { contentName = def.name or contentName, targetName = targetName }
    local d = Mux.createDialog({
        title = "Already Open", width = 360, minimizable = false, contextMenu = false,
    })
    Mux._applyContent(d, "mux_singleton_blocked")
    d:show()
    d:raise()
end

--- Register a named content type.
-- @param name  string identifier (used in API calls and menus)
-- @param def   table with at minimum an `apply(target)` function
function Mux.registerContent(name, def)
    assert(type(name)      == "string",   "content name must be a string")
    assert(type(def)       == "table",    "content definition must be a table")
    assert(type(def.apply) == "function", "content.apply must be a function")
    Mux._content[name] = def
    Mux._log("Registered content: %s", name)
    scheduleSave()
end

--- Apply the named content to a pane or tab target.
-- If the target already has different content applied, calls that content's
-- remove() first (for non-widget teardown: event handlers, timers, state), then
-- destroys the previous content slot container (removing all descendant widgets).
-- A fresh slot container is created and target.content is temporarily remapped
-- to it during the apply call so all new widgets land inside the slot.
-- Singleton content is blocked if already active on another pane or tab;
-- a dialog tells the user where it is currently open.
-- Tracking uses a direct object reference (def._activeTargetRef) so it works
-- correctly for both panes and tabs without a registry lookup.
-- Content-declared parameter locks. A content def may carry:
--   paramLocks = { closeable = { value=false, why="…" }, … }
-- On apply we snapshot the target's current value for each locked prop and set the
-- declared value; on removal we restore the snapshot. The read-only/why metadata is
-- read live by MuxPane:_recomputeLocks(); here we only manage the values + snapshot.
local function _applyParamLocks(target, def)
    if not (def and def.paramLocks) then return end
    target._lockSnapshot = target._lockSnapshot or {}
    for prop, spec in pairs(def.paramLocks) do
        if target._lockSnapshot[prop] == nil then target._lockSnapshot[prop] = target[prop] end
        if type(spec) == "table" and spec.value ~= nil then target[prop] = spec.value end
    end
end

local function _restoreParamLocks(target, def)
    if not (def and def.paramLocks and target._lockSnapshot) then return end
    for prop in pairs(def.paramLocks) do
        if target._lockSnapshot[prop] ~= nil then
            target[prop] = target._lockSnapshot[prop]
            target._lockSnapshot[prop] = nil
        end
    end
end

-- Shared geometry math for both the one-shot post-apply fit and any later live
-- re-fit request (Mux.requestAutoFit). initial=true recenters on screen (the
-- existing "just opened" behavior); initial=false preserves the pane's
-- current top-left corner and only grows/shrinks from there, clamped to stay
-- fully on-screen, so a pane the user has already positioned doesn't jump
-- when its content's live size changes. Also floors width/height at the same
-- minimum corner-resize uses (pane.lua's drag-resize minW/minH = 120, 60) so
-- a content module can't shrink the pane below the usable minimum.
local MIN_AUTOFIT_W, MIN_AUTOFIT_H = 120, 60
local function computeAutoFit(target, initial)
    local theme  = Mux.activeTheme and Mux.activeTheme() or {}
    local chrome = (theme.titlebarHeight or 22) + 4
    local sw, sh = getMainWindowSize()
    local newH = math.max(MIN_AUTOFIT_H + chrome,
                    math.min(target._autoFitHeight + chrome, math.floor(sh * 0.85)))
    local newW = math.max(MIN_AUTOFIT_W,
                    math.min(target._autoFitWidth or target.floatW or 380, math.floor(sw * 0.85)))
    local newX, newY
    if initial then
        newX = math.floor((sw - newW) / 2)
        newY = math.floor((sh - newH) / 2)
    else
        newX = math.max(0, math.min(target.floatX or 0, sw - newW))
        newY = math.max(0, math.min(target.floatY or 0, sh - newH))
    end
    return newX, newY, newW, newH
end

-- Apply computed geometry to the live widget and keep floatX/Y/W/H
-- authoritative -- the same fields workspace.lua serializes/restores and that
-- drag/corner-resize treat as the source of truth for the next gesture.
local function applyAutoFit(target, newX, newY, newW, newH)
    target.floatX, target.floatY = newX, newY
    target.floatW, target.floatH = newW, newH
    target._autoFitHeight = nil
    target._autoFitWidth  = nil
    target.outer:move(newX, newY)
    target.outer:resize(newW, newH)
    tempTimer(0, function()
        if target.outer then target.outer:reposition() end
    end)
end

function Mux._applyContent(target, contentName, force)
    local def = Mux._content[contentName]
    if not def then
        Mux._warn("_applyContent: unknown content '%s'", contentName)
        return
    end

    -- Block USER-initiated content on targets where contentable is false.  The
    -- workspace restore passes force=true to reinstate a pane's OWN saved content:
    -- locking a pane's content must not cause that content to be dropped on reload.
    if target.contentable == false and not def.internal and not force then
        return
    end

    -- Singleton check: block if another target still actively holds this content.
    if def.singleton and def._activeTargetRef and def._activeTargetRef ~= target then
        local existing = def._activeTargetRef
        if existing._activeContent == contentName then
            showSingletonBlocked(contentName, def, existing)
            return
        end
        -- Target no longer holds this content (destroyed or replaced); clear stale ref.
        def._activeTargetRef = nil
    end

    -- Remove whatever content is currently on this target before applying the new one.
    if target._activeContent then
        local old = Mux._content[target._activeContent]
        if old then
            if old.singleton and old._activeTargetRef == target then
                old._activeTargetRef = nil
            end
            _restoreParamLocks(target, old)   -- give back the outgoing content's locked values
            if type(old.remove) == "function" then
                pcall(old.remove, target)
            end
        end
        -- Destroy the previous content slot.  Geyser.Container:delete() is
        -- recursive, so this removes all descendant widgets (including nested
        -- ScrollBox children) without any per-content cleanup contract.
        destroyContentSlot(target)
    end

    -- Create a fresh slot container that covers the full content area.
    -- target.content is temporarily remapped to the slot so all widgets the
    -- apply function creates land inside it.  The slot is what gets deleted
    -- on the next content change or explicit removal.
    --
    -- _activeContent is set AFTER apply returns, not before.  Setting it before
    -- the call causes apply functions that call enableTabs() to see the new
    -- content name as "prior content" and recursively call _removeContent,
    -- which destroys the slot while apply is still using it.
    local realContent = target.content
    local slot = Geyser.Container:new({
        name   = target._gid .. "_cslot",
        x = "0%", y = "0%", width = "100%", height = "100%",
    }, realContent)
    target._contentSlot = slot
    target.content      = slot

    local ok, err = pcall(def.apply, target)
    target.content = realContent   -- always restore, even on apply error

    target._activeContent = contentName
    if def.singleton then def._activeTargetRef = target end
    -- Apply this content's parameter locks (sets values + snapshots prior ones), then
    -- recompute the read-only set so Properties reflects them immediately.
    _applyParamLocks(target, def)
    if type(target._recomputeLocks) == "function" then target:_recomputeLocks() end
    -- Content may contribute titlebar elements; refresh the placement engine so
    -- they appear (and fold into the menu) immediately.
    if type(target._syncButtons) == "function" then
        target._contentTbSig = nil
        target:_syncButtons(true)
    end
    -- When content landed on a tab, its titlebar elements belong to the OWNING
    -- pane's titlebar, so refresh that too.
    local ownerPane = target
    while ownerPane and ownerPane.pane do ownerPane = ownerPane.pane end
    if ownerPane and ownerPane ~= target and ownerPane._layoutTitlebarButtons then
        ownerPane._contentTbSig = nil
        pcall(function() ownerPane:_layoutTitlebarButtons() end)
    end

    if not ok then
        Mux._err("content '%s' apply error: %s", contentName, tostring(err))
    end

    -- If the pane was hidden before the apply (e.g. minimized), re-hide the outer
    -- so the newly-created slot and all its widgets collapse with the pane.
    if target._conditionHidden and target.outer then
        target.outer:hide()
    end

    -- A slot rebuilt while its target is hidden (an inactive settings/
    -- properties tab -- see MuxSurface:_activateTabObj -- or any other pane/
    -- tab not currently shown) would otherwise leak visible; realContent
    -- carries the target's real hidden/auto_hidden state (toggled explicitly
    -- by the tab/pane show-hide code, never by this function), so re-hide the
    -- slot to match. See Mux.reassertHidden for why this is needed.
    Mux.reassertHidden(slot, realContent)

    -- Auto-fit: if apply set _autoFitHeight and the pane is floating (and the
    -- pane's Auto-Fit to Content permission is on), resize to fit content.
    -- initial=true recenters (dialogs keep exact existing behavior).
    if ok and target.floating and target.autoFit ~= false and target._autoFitHeight and target.outer then
        local newX, newY, newW, newH = computeAutoFit(target, true)
        applyAutoFit(target, newX, newY, newW, newH)
    end

    Mux._scheduleAutoSave()
end

--- Request a live re-fit of a floating pane's size to its content, without
--- recentering. Content modules call this any time after their data changes
--- size (independent of apply()) to ask the hosting pane to grow/shrink from
--- its CURRENT top-left corner, clamped to stay on-screen. No-op for
--- docked/tabbed (non-floating) panes, or when the pane's Auto-Fit to Content
--- permission (Properties > Permissions, pane.autoFit) is off -- the user can
--- disable this per-pane the same way they can disable Movable/Resizable/etc.
--- This is the continuous counterpart to the one-shot fit _applyContent runs
--- immediately after apply() (which still recenters -- for the initial-open
--- case only, and is gated by the same flag).
-- @param target  a pane or tab with .floating, .outer, .floatX/Y/W/H
-- @param height  optional; if given, sets target._autoFitHeight before fitting
-- @param width   optional; if given, sets target._autoFitWidth before fitting
function Mux.requestAutoFit(target, height, width)
    if not target then return end
    if height then target._autoFitHeight = height end
    if width  then target._autoFitWidth  = width  end
    if target.autoFit == false then return end
    if not (target.floating and target._autoFitHeight and target.outer) then return end
    local newX, newY, newW, newH = computeAutoFit(target, false)
    applyAutoFit(target, newX, newY, newW, newH)
    -- A live content resize (e.g. Local Players growing/shrinking with the room's
    -- player count) changes floatH/floatW out from under any anchor -- including
    -- the stacking sweep that keeps it from overlapping siblings on the same
    -- anchor line. Re-run it so those siblings re-accommodate the new size.
    if target.anchor and Mux._reanchorAll then Mux._reanchorAll() end
end

--- Re-applies a hidden/auto_hidden container's Qt-level hide to `container`,
--- covering any widgets just added to it. Geyser's plain :add always shows a
--- freshly created widget regardless of its parent's hidden state (see
--- GeyserGeyser.lua's Geyser:add) -- new widgets just leak visible instead of
--- inheriting the ancestor's hidden state. Content that rebuilds its own
--- widgets live -- independent of Mux._applyContent's own apply-time rebuild,
--- e.g. reacting to a GMCP event or a game-line trigger -- must call this
--- right after, or a condition-hidden (or inactive-tab-hidden) pane/tab can
--- leak newly built content visible until its next full hide/show cycle.
---
--- (NOT a candidate for Geyser's useAdd2: that rewrites .add on every
--- descendant widget type, including ScrollBox, which collides with
--- ScrollBox's own internal add2 handling and broke dialogs everywhere --
--- see Muxlet commit 8cd78ed. This re-hides after the fact instead of
--- changing how widgets get added, so it can't have that blast radius.)
-- @param container   the container that just received new children
-- @param reference   optional; carries the real hidden/auto_hidden state to
--                     check, if different from container (e.g. a freshly
--                     created slot has its own hidden/auto_hidden reset to
--                     false, so its long-lived parent must be checked
--                     instead). Defaults to container.
function Mux.reassertHidden(container, reference)
    reference = reference or container
    if container and reference and (reference.hidden or reference.auto_hidden) then
        container:hide(true)
    end
end

-- Remove whatever content is active on a target, returning it to its empty
-- placeholder state.  Mirrors the teardown _applyContent does before replacing,
-- but leaves the slot empty rather than applying something new.
function Mux._removeContent(target)
    if not target or not target._activeContent then return end
    local name = target._activeContent
    local def  = Mux._content[name]
    if def then
        if def.singleton and def._activeTargetRef == target then def._activeTargetRef = nil end
        _restoreParamLocks(target, def)   -- give back pre-content values (closeable, etc.)
        if type(def.remove) == "function" then pcall(def.remove, target) end
    end
    destroyContentSlot(target)
    target._activeContent = nil
    -- Recompute read-only locks now the content (and its paramLocks) is gone.
    if type(target._recomputeLocks) == "function" then target:_recomputeLocks() end
    -- Drop any content-contributed titlebar elements and re-layout.
    if type(target._syncButtons) == "function" then target:_syncButtons(true) end
    if type(target._updatePlaceholder) == "function" then
        target:_updatePlaceholder()
    elseif target.contentBg and type(target.contentBg.show) == "function" then
        pcall(target.contentBg.show, target.contentBg)
    end
    Mux._scheduleAutoSave()
end

-- Notify a target's active content that its container geometry changed, so
-- pixel-laid-out content can re-flow to fit.  This is the single contract behind
-- "content scales with its pane/tab": the framework calls it on every geometry
-- change (window resize, split drag, embed/float, float-resize) and content types
-- opt in by declaring an optional `resize(target)` callback in registerContent.
-- Size-gated so it is cheap to call from hot reposition paths — the content's
-- resize runs only when the content area's pixel size actually changed.
-- Ask a target's active content to reveal any chrome it has deliberately hidden
-- (e.g. an edit affordance / lock). Optional per-content `onReveal(target)` hook;
-- cascades into the active tab. Wired into `mux reveal` so there's a uniform,
-- discoverable way back from a content that has hidden its own controls.
function Mux._revealContent(target)
    if not target then return end
    if target._tabsEnabled and target._activeTabId and target._findTab then
        local activeTab = target:_findTab(target._activeTabId)
        if activeTab then Mux._revealContent(activeTab) end
    end
    if not target._activeContent then return end
    local def = Mux._content[target._activeContent]
    if def and type(def.onReveal) == "function" then pcall(def.onReveal, target) end
end

-- Run a content's resize() hook and record how long it took. The measured cost
-- drives the adaptive debounce below: cheap content keeps resizing live during
-- drags, expensive content (full re-renders, widget rebuilds) is coalesced.
local function runResizeHook(target, def)
    local t0 = os.clock()
    pcall(def.resize, target)
    target._resizeCostMs = (os.clock() - t0) * 1000
end

function Mux._relayoutContent(target)
    if not target then return end

    -- Tabbed hosts (a pane or a tab hosting sub-tabs) keep their visible content
    -- on the active tab, which isn't in Mux._panes and so is never reached by the
    -- reposition loop directly. Cascade into it; recursion covers nested sub-tabs.
    if target._tabsEnabled and target._activeTabId and target._findTab then
        local activeTab = target:_findTab(target._activeTabId)
        if activeTab then Mux._relayoutContent(activeTab) end
    end

    if not target._activeContent or not target.content then return end
    local def = Mux._content[target._activeContent]
    if not (def and type(def.resize) == "function") then return end
    local C = target.content
    if not C.get_width then return end
    local w, h = C:get_width(), C:get_height()
    if target._lastContentW == w and target._lastContentH == h then return end
    target._lastContentW, target._lastContentH = w, h

    -- Adaptive per-frame debounce: during an active drag (Mux._resizing), a
    -- resize hook whose last run exceeded the live budget is deferred to a
    -- trailing timer instead of running every frame. The timer re-arms on each
    -- frame, so it fires once, ~0.15s after the last size change — i.e. with
    -- the final geometry. Content under the budget keeps resizing live.
    if Mux._resizing then
        local budget = (Mux.settings and Mux.settings.get
            and Mux.settings.get("mux", "resize_live_budget_ms")) or 8
        if (target._resizeCostMs or 0) > budget then
            if target._resizeDebounce then killTimer(target._resizeDebounce) end
            target._resizeDebounce = tempTimer(0.15, function()
                target._resizeDebounce = nil
                local d = target._activeContent and Mux._content[target._activeContent]
                if not (d and type(d.resize) == "function" and target.content) then return end
                if target.content.get_width then
                    target._lastContentW = target.content:get_width()
                    target._lastContentH = target.content:get_height()
                end
                runResizeHook(target, d)
            end)
            return
        end
    end

    runResizeHook(target, def)
end

-- Systemic conversion reflow.  Called whenever a pane/tab changes its embedding
-- (float→embed, embed→float, return-to-ghost, zoom/unzoom).  The stock Geyser
-- reposition cascade run by those paths updates Container children but does NOT
-- recurse through Geyser.Label parents, so any widget nested inside a Label
-- (e.g. a button embedded in a labelled cell) keeps stale geometry after the
-- conversion even though the pane itself resized.  Mux._applyGeometry walks the
-- full windowList tree — Labels included — and pushes each widget's
-- constraint-derived geometry natively, the same deep pass the split-drag resize
-- path already uses.  This is what makes "everything inside a pane resizes to
-- match the embed it converts to" work for ALL content with no per-content code.
-- _relayoutContent then fires the optional resize() hook for content that lays
-- itself out in pixels rather than constraints.
function Mux._reflowContent(target)
    if not target or not target.content then return end

    -- Deep geometry pass first so the content area and the tab bar carry their
    -- new pixel size before anything measures against it.
    if Mux._applyGeometry then
        pcall(Mux._applyGeometry, target.content)
    end

    -- Tabbed host: relayout the tab bar (tab label widths track the content
    -- width).  onReposition normally does this, but the conversion paths do not
    -- fire onReposition, so it must be done explicitly here or the tab strip
    -- keeps its pre-conversion width.
    if target._tabBarBox and type(target._relayoutTabLabels) == "function" then
        pcall(function() target:_relayoutTabLabels() end)
    end

    -- Cascade into the active tab; the visible content (and its own widgets,
    -- possibly nested in Labels) lives there, not directly under target.content.
    if target._tabsEnabled and target._activeTabId and target._findTab then
        local t = target:_findTab(target._activeTabId)
        if t then Mux._reflowContent(t) end
    end

    -- Force the resize() hook to run (the normal call is gated on a pixel-size
    -- change vs the last reflow; a conversion may land on the same size yet still
    -- need a re-layout, so clear the gate first).
    target._lastContentW, target._lastContentH = nil, nil
    Mux._relayoutContent(target)
end

-- Optional per-instance content persistence.  A content type may implement
--   serialize(target) -> table        capture this instance's config/state
--   restore(target, data)             reapply it (called after apply on load)
-- When serialize is present, Muxlet stores the returned table inside the
-- workspace beside the pane's activeContent, so the content's state travels with
-- the workspace (export/import, multiple workspaces, session restore) for free.
-- Content that prefers its own storage simply omits these.  Returns nil when the
-- content has no serialize hook, so callers can skip writing an empty key.
function Mux._serializeContent(target)
    if not target or not target._activeContent then return nil end
    local def = Mux._content[target._activeContent]
    if not (def and type(def.serialize) == "function") then return nil end
    local ok, data = pcall(def.serialize, target)
    if ok and type(data) == "table" then return data end
    return nil
end

-- Reapply previously-serialized state to a target whose content has just been
-- (re)applied.  No-op unless the active content implements restore().
function Mux._restoreContent(target, data)
    if not target or type(data) ~= "table" or not target._activeContent then return end
    local def = Mux._content[target._activeContent]
    if def and type(def.restore) == "function" then
        pcall(def.restore, target, data)
    end
end

--- Return an alphabetically sorted list of user-visible registered content names.
-- Content registered with internal=true is excluded; it is used by Muxlet
-- system UI and should not appear in the Content Library context menu.
function Mux._listContent()
    local names = {}
    for name, def in pairs(Mux._content) do
        if not def.internal then names[#names+1] = name end
    end
    table.sort(names)
    return names
end

Mux.registerContent("mux_singleton_blocked", {
    internal = true,
    apply = function(target)
        if target.contentBg then target.contentBg:echo(""); target.contentBg:hide() end
        local p = Mux._pendingSingleton
        Mux._pendingSingleton = nil
        if not p then return end
        local cw = target.content:get_width()
        if cw < 50 then cw = (target.floatW or 360) - 4 end
        local msg = Geyser.Label:new({
            name=target._gid.."_msg", x=10, y=10, width=cw-20, height=50,
        }, target.content)
        msg:setStyleSheet(Mux.dialogCss.subtext)
        msg:echo(string.format(
            "<b>%s</b> is already open in <b>%s</b>.<br>Only one instance can be active at a time.",
            p.contentName, p.targetName))
        local btnW = 120
        local btn = Geyser.Label:new({
            name=target._gid.."_ok", x=math.floor((cw - btnW) / 2), y=68, width=btnW, height=32,
        }, target.content)
        btn:setStyleSheet(Mux.dialogCss.button)
        btn:echo("<center>OK</center>")
        Mux.wireDialogButton(btn, Mux.dialogCss.button, Mux.dialogCss.buttonHover)
        btn:setClickCallback(function() target:close() end)
        target._autoFitHeight = 110
    end,
    remove = function(_) end,
})

Mux._log("content loaded")