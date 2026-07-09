-- Muxlet — Styling token engine
--
-- The single source of truth for every visual value. Replaces hand-written CSS
-- blobs in themes with ATOMIC tokens (one colour / size / radius per key) plus
-- declarative element templates that assemble the CSS on demand.
--
-- Four cascade layers, lowest precedence first:
--   1. fallback  — complete default set (this file). Last resort; every token
--                  has a value here, so Mux.tok() can never return nil.
--   2. theme     — the active registered theme's sparse token table. Anything it
--                  omits falls through to fallback. Packages ship these.
--   3. global    — the user's global overrides, set in Settings, persisted.
--   4. local     — per-pane / per-tab overrides, set in Properties, persisted in
--                  the workspace on the object (scope._tokens).
--
-- Resolution:  Mux.tok(key, scope) = local(scope) ?? global ?? theme ?? fallback
--
-- Consumers NEVER read raw token names off a theme table. They call:
--   Mux.tok(key, scope)        — a single resolved value
--   Mux.css(element, scope)    — an assembled stylesheet string for an element
-- Because nothing hard-codes token names, renaming a token is a localised change
-- (this file + the legacy bridge map in theme.lua), never a codebase-wide churn.

Mux.tokens = Mux.tokens or {}

-- ── Layer stores ──────────────────────────────────────────────────────────────
-- fallback is filled below. global is loaded from settings at init. theme comes
-- from Mux.activeThemeTokens(). local lives on each scope as scope._tokens.
Mux.tokens.global = Mux.tokens.global or {}

-- ════════════════════════════════════════════════════════════════════════════
-- FALLBACK — atomic defaults (values mirror the original dark theme exactly)
-- ════════════════════════════════════════════════════════════════════════════
Mux.tokens.fallback = {
    -- Dimensions
    ["titlebar.height"]          = 22,
    ["titlebar.fontSize"]        = 11,
    ["titlebar.charWidth"]       = 7,
    ["handle.size"]              = 3,
    ["btn.size"]                 = 18,
    ["btn.topMargin"]            = 2,
    ["cornerHandle.size"]        = 10,
    ["tabBar.height"]            = 30,
    ["tabAddBtn.width"]          = 24,
    ["tab.fontSize"]             = 12,
    ["contextMenu.itemHeight"]   = 30,
    ["contextMenu.sepHeight"]    = 11,
    ["contextMenu.width"]        = 224,
    ["contextMenu.padX"]         = 7,
    ["contextMenu.padY"]         = 7,

    -- Cursors
    ["handle.cursor.v"]          = "ResizeVertical",
    ["handle.cursor.h"]          = "ResizeHorizontal",

    -- Pane frame
    ["pane.bg"]                  = "rgba(10,10,16,248)",
    ["pane.border.width"]        = 2,
    ["pane.border.color"]        = "rgba(255,255,255,0.38)",
    ["pane.border.radius"]       = 3,
    ["content.bg"]               = "rgba(8,8,13,255)",

    -- Titlebar
    ["titlebar.bg"]              = "rgba(25,25,38,235)",
    ["titlebar.borderBottom.color"] = "rgba(255,255,255,0.18)",
    ["titlebar.text.color"]      = "rgba(215,215,230,0.92)",

    -- Titlebar buttons (shared geometry, per-button colours)
    ["titlebarBtn.border.radius"] = 3,
    ["titlebarBtn.fontSize"]      = 9,
    ["btn.text.glyphColor"]       = "#aaaabb",   -- echo()-HTML glyph colour
    ["btn.bg"]                    = "rgba(38,38,52,200)",
    ["btn.border.color"]          = "rgba(255,255,255,0.16)",
    ["btn.text.color"]            = "rgba(175,175,190,225)",
    ["btn.hover.bg"]              = "rgba(65,65,85,220)",
    ["btn.hover.border.color"]    = "rgba(255,255,255,0.38)",
    ["btn.hover.text.color"]      = "white",
    ["close.bg"]                  = "rgba(170,38,38,225)",
    ["close.border.color"]        = "rgba(220,60,60,0.65)",
    ["close.text.color"]          = "white",
    ["close.hover.bg"]            = "rgba(210,50,50,245)",
    ["close.hover.border.color"]  = "rgba(255,80,80,0.85)",
    ["close.hover.text.color"]    = "white",
    ["min.bg"]                    = "rgba(170,140,30,225)",
    ["min.border.color"]          = "rgba(220,185,40,0.65)",
    ["min.text.color"]            = "white",
    ["min.hover.bg"]              = "rgba(205,168,42,245)",
    ["min.hover.border.color"]    = "rgba(240,210,60,0.85)",
    ["min.hover.text.color"]      = "white",

    -- Resize handles
    ["handle.bg"]                 = "rgba(255,255,255,0.38)",
    ["handle.hover.bg"]           = "rgba(100,160,255,0.65)",
    ["dragGuide.bg"]              = "rgba(100,160,255,0.75)",
    ["dragGuide.radius"]          = 2,
    ["cornerHandle.bg"]           = "rgba(255,255,255,0.0)",
    ["cornerHandle.hover.bg"]     = "rgba(100,160,255,0.45)",
    ["cornerHandle.hover.radius"] = 2,

    -- Context menu
    ["contextMenu.bg"]            = "rgba(20,22,32,0.985)",
    ["contextMenu.border.color"]  = "rgba(140,160,210,0.16)",
    ["contextMenu.radius"]        = 11,
    ["contextMenu.fontSize"]      = 12,
    ["contextMenu.text.color"]    = "rgba(220,222,235,0.96)",  -- blob color (HTML echo uses its own token)
    ["contextMenu.echoText.color"] = "rgba(220,222,235,0.95)",  -- HTML-echo text colour (legacy contextMenuTextColor)
    ["contextMenuItem.bg"]        = "rgba(0,0,0,0)",
    ["contextMenuItem.radius"]    = 7,
    ["contextMenuItem.fontSize"]  = 12,
    ["contextMenuItem.padLeft"]   = 14,
    ["contextMenuItem.padRight"]  = 12,
    ["contextMenuItem.hover.bg"]  = "rgba(120,160,255,0.18)",
    ["contextMenuDanger.bg"]      = "rgba(0,0,0,0)",
    ["contextMenuDanger.text.color"] = "rgba(232,120,120,0.95)",
    ["contextMenuDanger.hover.bg"] = "rgba(216,72,72,0.26)",
    ["contextMenuSep.color"]      = "rgba(255,255,255,0.07)",

    -- Ghost slot / insertion preview
    ["ghostSlot.bg"]              = "rgba(20,24,40,180)",
    ["ghostSlot.border.width"]    = 2,
    ["ghostSlot.border.color"]    = "rgba(100,120,200,0.45)",
    ["ghostSlot.radius"]          = 3,
    ["ghostSlot.hover.bg"]        = "rgba(25,30,55,200)",
    ["ghostSlot.hover.border.color"] = "rgba(120,150,255,0.65)",
    ["ghostSlot.drop.bg"]         = "rgba(30,40,80,220)",
    ["ghostSlot.drop.border.color"] = "rgba(100,160,255,0.85)",
    ["insertionGhost.bg"]         = "rgba(80,130,255,0.22)",
    ["insertionGhost.border.color"] = "rgba(100,160,255,0.75)",
    ["insertionGhost.radius"]     = 2,

    -- Floating accent
    ["floating.border.width"]     = 2,
    ["floating.border.color"]     = "rgba(205,162,40,0.72)",
    ["floating.border.radius"]    = 3,

    -- Tabs
    ["tabBar.bg"]                 = "rgba(0,0,0,255)",
    ["tabBar.borderBottom.color"] = "rgba(255,255,255,0.10)",
    ["tabDropTarget.bg"]          = "rgba(25,40,65,230)",
    ["tabDropTarget.borderBottom.color"] = "rgba(100,180,255,0.55)",
    ["tab.padX"]                  = 4,
    -- Tab appearance (one system, same cascade as panes). Shape is the radius token.
    ["tab.border.radius"]         = 6,
    ["tab.vGap"]                  = 1,
    ["tab.hGap"]                  = 0,
    ["tab.border.width"]          = 1,
    ["tab.active.border.width"]   = 1,
    ["tab.inactive.bg"]           = "rgba(28,28,28,255)",
    ["tab.inactive.border.color"] = "rgba(72,72,72,255)",
    ["tab.inactive.text.color"]   = "rgba(255,255,255,255)",
    ["tab.active.bg"]             = "rgba(55,55,55,255)",
    ["tab.active.border.color"]   = "rgba(155,155,155,255)",
    ["tab.active.text.color"]     = "rgba(255,255,255,255)",
    ["tab.hover.highlight"]       = "rgba(255,255,255,255)",
    ["tab.hover.text.color"]      = "rgba(255,255,255,255)",
    ["tab.moving.bg"]             = "rgba(80,15,15,235)",
    ["tab.moving.borderRight.color"] = "rgba(180,45,45,0.35)",
    ["tab.moving.text.color"]     = "rgba(255,170,170,1.0)",
    ["tab.moving.borderBottom.color"] = "rgba(195,50,50,0.85)",
    ["tab.moving.padX"]           = 2,
    ["tabAddBtn.bg"]              = "rgba(14,14,22,200)",
    ["tabAddBtn.borderLeft.color"] = "rgba(255,255,255,0.10)",
    ["tabAddBtn.text.color"]      = "rgba(185,192,220,0.90)",
    ["tabAddBtn.fontSize"]        = 15,
    ["tabAddBtn.hover.bg"]        = "rgba(35,35,55,225)",
    ["tabAddBtn.hover.text.color"] = "rgba(225,228,248,1.0)",
    ["tabInsertGhost.bg"]         = "rgba(80,140,255,0.18)",
    ["tabInsertGhost.border.color"] = "rgba(110,170,255,0.55)",
    ["tabInsertGhost.radius"]     = 2,
    ["tabInsertGhost.text.color"] = "rgba(140,200,255,0.80)",

    -- Connection-awareness screen
    ["connScreen.bg"]                       = "rgba(8,8,14,250)",
    ["connScreen.disconnected.icon.color"]  = "rgba(150,50,50,210)",
    ["connScreen.disconnected.title.color"] = "rgba(185,70,70,225)",
    ["connScreen.connecting.icon.color"]    = "rgba(40,110,140,210)",
    ["connScreen.connecting.title.color"]   = "rgba(55,140,165,225)",

    -- Profile scrollbar skin
    ["scrollbar.track.bg"]        = "rgb(14,14,22)",
    ["scrollbar.width"]           = 6,
    ["scrollbar.handle.bg"]       = "rgba(75,78,95,0.65)",
    ["scrollbar.handle.radius"]   = 3,
    ["scrollbar.handle.minHeight"] = 20,
    ["scrollbar.handle.hover.bg"] = "rgba(120,124,148,0.85)",

    -- Widget palette (settings / properties / buildForm)
    ["ui.textColor"]       = "rgba(215,215,230,0.92)",
    ["ui.bg"]              = "rgb(18,18,26)",
    ["ui.rowOdd"]          = "rgb(16,16,24)",
    ["ui.rowEven"]         = "rgb(34,34,50)",
    ["ui.tabActiveBg"]     = "rgb(40,40,62)",
    ["ui.tabInactiveBg"]   = "rgb(18,18,26)",
    ["ui.tabHoverBg"]      = "rgb(35,35,55)",
    ["ui.tabActiveLine"]   = "rgba(100,180,255,0.8)",
    ["ui.tabActiveText"]   = "rgba(215,215,230,0.95)",
    ["ui.tabInactiveText"] = "rgba(160,165,185,0.75)",
    ["ui.tabHoverText"]    = "rgba(215,218,232,0.95)",
    ["ui.descTextColor"]   = "rgba(120,130,170,0.85)",
    ["ui.rowDivider"]      = "rgba(255,255,255,0.12)",
    ["ui.widgetBg"]        = "rgb(38,38,58)",
    ["ui.widgetFg"]        = "#d8d8f0",
    ["ui.widgetBorder"]    = "rgba(255,255,255,0.22)",
    ["ui.widgetHoverBg"]   = "rgb(55,55,80)",
    ["ui.inputBg"]         = "rgb(12,12,18)",
    ["ui.inputFg"]         = "#c8c8d0",
    ["ui.inputBorder"]     = "rgba(255,255,255,0.46)",
    ["ui.helpIconFg"]      = "rgba(100,160,255,0.85)",
    ["ui.helpIconBg"]      = "rgba(60,80,120,0.25)",
    ["ui.helpIconBorder"]  = "rgba(100,140,200,0.35)",
    ["ui.helpIconHoverBg"] = "rgba(80,110,185,0.85)",
    ["ui.style.on.bg"]     = "rgb(30,70,40)",
    ["ui.style.on.fg"]     = "#88ee88",
    ["ui.style.on.border"] = "rgba(80,180,80,0.5)",
    ["ui.style.on.hover"]  = "rgb(40,90,50)",
    ["ui.style.off.bg"]     = "rgb(65,30,30)",
    ["ui.style.off.fg"]     = "rgba(220,120,120,0.9)",
    ["ui.style.off.border"] = "rgba(180,80,80,0.4)",
    ["ui.style.off.hover"]  = "rgb(85,40,40)",
    ["ui.style.warn.bg"]     = "rgb(58,50,18)",
    ["ui.style.warn.fg"]     = "rgba(220,190,80,0.9)",
    ["ui.style.warn.border"] = "rgba(200,170,60,0.5)",
    ["ui.style.warn.hover"]  = "rgb(78,68,24)",
}

-- ════════════════════════════════════════════════════════════════════════════
-- ELEMENTS — declarative CSS templates. Property order matches the original
-- theme blobs so assembled output is byte-identical after whitespace
-- normalisation (verified by the parity harness). args are resolved in order.
-- ════════════════════════════════════════════════════════════════════════════
Mux.tokens.elements = {
    paneOuter = { tpl = "background-color: %s; border: %spx solid %s; border-radius: %spx;",
        args = { "pane.bg", "pane.border.width", "pane.border.color", "pane.border.radius" } },
    content = { tpl = "background-color: %s; border: none;",
        args = { "content.bg" } },
    titlebar = { tpl = "background-color: %s; border-bottom: 1px solid %s; color: %s; font-size: %spx; font-weight: bold;",
        args = { "titlebar.bg", "titlebar.borderBottom.color", "titlebar.text.color", "titlebar.fontSize" } },

    btn = { tpl = "QLabel { background-color: %s; border: 1px solid %s; border-radius: %spx; color: %s; font-size: %spx; font-weight: bold; qproperty-alignment: 'AlignCenter'; } QLabel::hover { background-color: %s; border-color: %s; color: %s; }",
        args = { "btn.bg", "btn.border.color", "titlebarBtn.border.radius", "btn.text.color", "titlebarBtn.fontSize", "btn.hover.bg", "btn.hover.border.color", "btn.hover.text.color" } },
    closeHover = { tpl = "QLabel { background-color: %s; border: 1px solid %s; border-radius: %spx; color: %s; font-size: %spx; font-weight: bold; } QLabel::hover { background-color: %s; border-color: %s; color: %s; }",
        args = { "close.bg", "close.border.color", "titlebarBtn.border.radius", "close.text.color", "titlebarBtn.fontSize", "close.hover.bg", "close.hover.border.color", "close.hover.text.color" } },
    minHover = { tpl = "QLabel { background-color: %s; border: 1px solid %s; border-radius: %spx; color: %s; font-size: %spx; font-weight: bold; } QLabel::hover { background-color: %s; border-color: %s; color: %s; }",
        args = { "min.bg", "min.border.color", "titlebarBtn.border.radius", "min.text.color", "titlebarBtn.fontSize", "min.hover.bg", "min.hover.border.color", "min.hover.text.color" } },

    handle = { tpl = "background-color: %s; border: none;", args = { "handle.bg" } },
    handleHover = { tpl = "background-color: %s; border: none;", args = { "handle.hover.bg" } },
    dragGuide = { tpl = "background-color: %s; border-radius: %spx;", args = { "dragGuide.bg", "dragGuide.radius" } },
    cornerHandle = { tpl = "background-color: %s; border: none;", args = { "cornerHandle.bg" } },
    cornerHandleHover = { tpl = "background-color: %s; border: none; border-radius: %spx;",
        args = { "cornerHandle.hover.bg", "cornerHandle.hover.radius" } },

    contextMenu = { tpl = "background-color: %s; border: 1px solid %s; border-radius: %spx; color: %s; font-size: %spx;",
        args = { "contextMenu.bg", "contextMenu.border.color", "contextMenu.radius", "contextMenu.text.color", "contextMenu.fontSize" } },
    contextMenuItem = { tpl = "background-color:%s;border:none;border-radius:%spx;font-size:%spx;padding-left:%spx;padding-right:%spx;qproperty-alignment:'AlignVCenter|AlignLeft';",
        args = { "contextMenuItem.bg", "contextMenuItem.radius", "contextMenuItem.fontSize", "contextMenuItem.padLeft", "contextMenuItem.padRight" } },
    contextMenuItemHover = { tpl = "background-color:%s;border:none;border-radius:%spx;font-size:%spx;padding-left:%spx;padding-right:%spx;qproperty-alignment:'AlignVCenter|AlignLeft';",
        args = { "contextMenuItem.hover.bg", "contextMenuItem.radius", "contextMenuItem.fontSize", "contextMenuItem.padLeft", "contextMenuItem.padRight" } },
    contextMenuDanger = { tpl = "background-color:%s;border:none;border-radius:%spx;font-size:%spx;padding-left:%spx;padding-right:%spx;qproperty-alignment:'AlignVCenter|AlignLeft';",
        args = { "contextMenuDanger.bg", "contextMenuItem.radius", "contextMenuItem.fontSize", "contextMenuItem.padLeft", "contextMenuItem.padRight" } },
    contextMenuDangerHover = { tpl = "background-color:%s;border:none;border-radius:%spx;font-size:%spx;padding-left:%spx;padding-right:%spx;qproperty-alignment:'AlignVCenter|AlignLeft';",
        args = { "contextMenuDanger.hover.bg", "contextMenuItem.radius", "contextMenuItem.fontSize", "contextMenuItem.padLeft", "contextMenuItem.padRight" } },
    contextMenuSep = { tpl = "background-color:transparent;border:none;border-top:1px solid %s;",
        args = { "contextMenuSep.color" } },

    ghostSlot = { tpl = "background-color: %s; border: %spx dashed %s; border-radius: %spx;",
        args = { "ghostSlot.bg", "ghostSlot.border.width", "ghostSlot.border.color", "ghostSlot.radius" } },
    ghostSlotHover = { tpl = "background-color: %s; border: %spx dashed %s; border-radius: %spx;",
        args = { "ghostSlot.hover.bg", "ghostSlot.border.width", "ghostSlot.hover.border.color", "ghostSlot.radius" } },
    ghostSlotDropHighlight = { tpl = "background-color: %s; border: %spx solid %s; border-radius: %spx;",
        args = { "ghostSlot.drop.bg", "ghostSlot.border.width", "ghostSlot.drop.border.color", "ghostSlot.radius" } },
    insertionGhost = { tpl = "background-color: %s; border: %spx solid %s; border-radius: %spx;",
        args = { "insertionGhost.bg", "ghostSlot.border.width", "insertionGhost.border.color", "insertionGhost.radius" } },
    floatingExtra = { tpl = "border: %spx solid %s; border-radius: %spx;",
        args = { "floating.border.width", "floating.border.color", "floating.border.radius" } },

    tabBar = { tpl = "background-color: %s; border-bottom: 1px solid %s;",
        args = { "tabBar.bg", "tabBar.borderBottom.color" } },
    tabDropTargetBar = { tpl = "background-color: %s; border-bottom: %spx solid %s;",
        args = { "tabDropTarget.bg", "tabDropTarget.borderBottom.width", "tabDropTarget.borderBottom.color" } },
    tabActive = { tpl = "QLabel { background-color: %s; border: %spx solid %s; border-radius: %spx; margin: %spx %spx; padding: 0 %spx; } QLabel::hover { border: %spx solid %s; }",
        args = { "tab.active.bg", "tab.active.border.width", "tab.active.border.color", "tab.border.radius", "tab.vGap", "tab.hGap", "tab.padX", "tab.active.border.width", "tab.hover.highlight" } },
    tabInactive = { tpl = "QLabel { background-color: %s; border: %spx solid %s; border-radius: %spx; margin: %spx %spx; padding: 0 %spx; } QLabel::hover { border: %spx solid %s; }",
        args = { "tab.inactive.bg", "tab.border.width", "tab.inactive.border.color", "tab.border.radius", "tab.vGap", "tab.hGap", "tab.padX", "tab.border.width", "tab.hover.highlight" } },
    tabMoving = { tpl = "QLabel { background-color: %s; border-right: 1px solid %s; color: %s; font-size: %spx; font-weight: bold; border-bottom: 2px solid %s; padding: 0 %spx; }",
        args = { "tab.moving.bg", "tab.moving.borderRight.color", "tab.moving.text.color", "tab.fontSize", "tab.moving.borderBottom.color", "tab.moving.padX" } },
    tabAddBtn = { tpl = "QLabel { background-color: %s; border-left: 1px solid %s; color: %s; font-size: %spx; font-weight: bold; } QLabel::hover { background-color: %s; color: %s; }",
        args = { "tabAddBtn.bg", "tabAddBtn.borderLeft.color", "tabAddBtn.text.color", "tabAddBtn.fontSize", "tabAddBtn.hover.bg", "tabAddBtn.hover.text.color" } },
    tabActiveParent = { tpl = "QLabel { background-color: %s; border: %spx solid %s; border-radius: %spx; margin: %spx %spx; padding: 0 %spx; } QLabel::hover { border: %spx solid %s; }",
        args = { "tab.active.bg", "tab.active.border.width", "tab.active.border.color", "tab.border.radius", "tab.vGap", "tab.hGap", "tab.padX", "tab.active.border.width", "tab.hover.highlight" } },
    subTabBar = { tpl = "background-color: %s; border-bottom: 1px solid %s;",
        args = { "tabBar.bg", "tabBar.borderBottom.color" } },
    tabInsertGhost = { tpl = "QLabel { background-color: %s; border: 2px dashed %s; border-radius: %spx; }",
        args = { "tabInsertGhost.bg", "tabInsertGhost.border.color", "tabInsertGhost.radius" } },

    connScreenBg = { tpl = "background-color:%s;border:none;", args = { "connScreen.bg" } },

    scrollbar = { tpl = "QScrollArea { border: none; background: transparent; } QScrollArea > QWidget { background: transparent; } QScrollBar:vertical { background: %s; width: %spx; border: none; margin: 0; } QScrollBar::handle:vertical { background: %s; border-radius: %spx; min-height: %spx; } QScrollBar::handle:vertical:hover { background: %s; } QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; background: none; } QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical { background: transparent; } QScrollBar:horizontal { height: 0px; border: none; background: transparent; }",
        args = { "scrollbar.track.bg", "scrollbar.width", "scrollbar.handle.bg", "scrollbar.handle.radius", "scrollbar.handle.minHeight", "scrollbar.handle.hover.bg" } },
}
-- subTabBar / tabDropTarget need a width token absent from the originals' decomposition:
Mux.tokens.fallback["tabDropTarget.borderBottom.width"] = 2

-- ════════════════════════════════════════════════════════════════════════════
-- SPEC — UI metadata for the user-facing tokens. Drives the Settings theme editor
-- (all of them, grouped) and the per-scope Properties style sections (entries
-- whose `scope` is "pane" or "tab"). Tokens not listed here aren't user-editable
-- in the UI but still resolve through the cascade. Tabs use the same token system
-- as panes (Theme > Tabs editor for the global layer; per-tab Properties for local).
-- scope = the smallest scope that can override it: "pane" tokens also accept
-- global; "global" tokens are global-only.
Mux.tokens.spec = {
    { group = "Pane",     scope = "pane",   key = "pane.border.color",        type = "color", label = "Border" },
    { group = "Pane",     scope = "pane",   key = "pane.border.width",        type = "size",  label = "Border Width", min = 0, max = 6 },
    { group = "Pane",     scope = "pane",   key = "pane.border.radius",       type = "size",  label = "Corner Radius", min = 0, max = 16 },
    { group = "Pane",     scope = "pane",   key = "floating.border.color",    type = "color", label = "Border - Dialog" },

    { group = "Titlebar", scope = "pane",   key = "titlebar.bg",              type = "color", label = "Background" },
    { group = "Titlebar", scope = "pane",   key = "titlebar.text.color",      type = "color", label = "Text" },
    { group = "Titlebar", scope = "pane",   key = "titlebar.borderBottom.color", type = "color", label = "Bottom Border" },

    { group = "Buttons",  scope = "pane",   key = "btn.bg",                   type = "color", label = "Button" },
    { group = "Buttons",  scope = "pane",   key = "btn.text.glyphColor",      type = "color", label = "Button Icon" },
    { group = "Buttons",  scope = "pane",   key = "btn.hover.bg",             type = "color", label = "Button Hover" },

    -- Context menu (right-click menu). Item text echoes with echoText.color, so
    -- that — not contextMenu.text.color — is the colour you actually see.
    { group = "Menu",   scope = "global", key = "contextMenu.bg",             type = "color", label = "Background" },
    { group = "Menu",   scope = "global", key = "contextMenu.echoText.color", type = "color", label = "Text" },
    { group = "Menu",   scope = "global", key = "contextMenu.border.color",   type = "color", label = "Border" },
    { group = "Menu",   scope = "global", key = "contextMenuItem.hover.bg",   type = "color", label = "Highlight" },

    -- Empty pane placeholder ("ghost slot"): background, resting, hovered, drop-target.
    { group = "Slot",   scope = "global", key = "ghostSlot.bg",               type = "color", label = "Background" },
    { group = "Slot",   scope = "global", key = "ghostSlot.border.color",       type = "color", label = "Border" },
    { group = "Slot",   scope = "global", key = "ghostSlot.hover.border.color", type = "color", label = "Border (hover)" },
    { group = "Slot",   scope = "global", key = "ghostSlot.drop.border.color",  type = "color", label = "Border (drop target)" },

    -- Drag-to-split insertion preview (shown while dragging a pane between others).
    { group = "Drag",   scope = "global", key = "insertionGhost.border.color",  type = "color", label = "Insertion line" },

    -- Split resize handles (the draggable bars between panes).
    { group = "Handle", scope = "global", key = "handle.bg",              type = "color", label = "Bar" },
    { group = "Handle", scope = "global", key = "handle.hover.bg",        type = "color", label = "Bar (hover)" },
    { group = "Handle", scope = "global", key = "cornerHandle.hover.bg",  type = "color", label = "Corner (hover)" },

    { group = "Scrollbar", scope = "global", key = "scrollbar.handle.bg",       type = "color", label = "Handle" },
    { group = "Scrollbar", scope = "global", key = "scrollbar.handle.hover.bg", type = "color", label = "Handle (hover)" },
    { group = "Scrollbar", scope = "global", key = "scrollbar.track.bg",        type = "color", label = "Track" },

    -- Tabs — same token construct as panes. scope "tab" so a single tab can override
    -- in its Properties; the Theme > Tabs editor writes the global layer for all.
    { group = "Tab", scope = "global", key = "tabBar.height",            type = "size",  label = "Bar Height",  min = 16, max = 60 },
    { group = "Tab", scope = "global", key = "tabBar.bg",                type = "color", label = "Bar Background" },
    { group = "Tab", scope = "tab",    key = "tab.fontSize",             type = "size",  label = "Font Size",    min = 6,  max = 28 },
    { group = "Tab", scope = "tab",    key = "tab.border.radius",        type = "size",  label = "Shape (radius)", min = 0, max = 14 },
    { group = "Tab", scope = "tab",    key = "tab.border.width",         type = "size",  label = "Border Width", min = 0, max = 6 },
    { group = "Tab", scope = "tab",    key = "tab.active.border.width",  type = "size",  label = "Active Border Width", min = 0, max = 6 },
    { group = "Tab", scope = "global", key = "tab.hGap",                 type = "size",  label = "Horizontal Gap", min = 0, max = 40 },
    { group = "Tab", scope = "global", key = "tab.vGap",                 type = "size",  label = "Vertical Gap",   min = 0, max = 16 },
    { group = "Tab", scope = "tab",    key = "tab.inactive.bg",          type = "color", label = "Background" },
    { group = "Tab", scope = "tab",    key = "tab.active.bg",            type = "color", label = "Active Background" },
    { group = "Tab", scope = "tab",    key = "tab.inactive.text.color",  type = "color", label = "Text" },
    { group = "Tab", scope = "tab",    key = "tab.active.text.color",    type = "color", label = "Active Text" },
    { group = "Tab", scope = "tab",    key = "tab.inactive.border.color", type = "color", label = "Border" },
    { group = "Tab", scope = "tab",    key = "tab.active.border.color",  type = "color", label = "Active Border" },
    { group = "Tab", scope = "tab",    key = "tab.hover.highlight",      type = "color", label = "Hover Highlight" },
    { group = "Tab", scope = "tab",    key = "tab.hover.text.color",     type = "color", label = "Hover Text" },
}
-- Group order for the editor.
Mux.tokens.specGroups = { "Pane", "Titlebar", "Buttons", "Menu", "Slot", "Drag", "Handle", "Scrollbar", "Tab" }

-- ════════════════════════════════════════════════════════════════════════════
-- RESOLVER + ASSEMBLER
-- ════════════════════════════════════════════════════════════════════════════

-- Returns the active theme's sparse token table (filled in by theme.lua once a
-- theme is registered; empty before then so fallback applies).
function Mux.activeThemeTokens()
    return (Mux._activeThemeTokens) or {}
end

-- Resolve one token through the cascade. scope is nil (global), or a pane/tab
-- carrying a sparse _tokens override table.
function Mux.tok(key, scope)
    if scope and scope._tokens then
        local v = scope._tokens[key]; if v ~= nil then return v end
    end
    local g = Mux.tokens.global[key];      if g ~= nil then return g end
    local t = Mux.activeThemeTokens()[key]; if t ~= nil then return t end
    return Mux.tokens.fallback[key]
end

-- Assemble an element's stylesheet from its template + resolved token args. As an
-- ultimate escape hatch, an element can be given a wholesale raw-CSS override via
-- the "<element>.cssOverride" token: set it globally, per-theme, or per-scope
-- (setLocalToken) and it is returned verbatim, bypassing the template + args. This
-- lets a theme or a single pane/tab supply its own CSS without touching the token
-- vocabulary.
local _unpack = table.unpack or unpack
function Mux.css(element, scope)
    local override = Mux.tok(element .. ".cssOverride", scope)
    if type(override) == "string" and override ~= "" then return override end
    local spec = Mux.tokens.elements[element]
    if not spec then return "" end
    local vals = {}
    for i, key in ipairs(spec.args) do vals[i] = Mux.tok(key, scope) end
    return string.format(spec.tpl, _unpack(vals))
end

-- ── Global overrides ────────────────────────────────────────────────────────
-- Persisted as JSON in the Muxlet persistent dir, loaded once at startup.
local function _overridesFile()
    if not getMudletHomeDir then return nil end
    return getMudletHomeDir() .. "/Muxlet_persistent/theme_overrides.json"
end
function Mux._persistGlobalTokens()
    local path = _overridesFile()
    if not (path and yajl and io) then return end
    pcall(function() if lfs then lfs.mkdir(getMudletHomeDir() .. "/Muxlet_persistent") end end)
    pcall(function()
        local f = io.open(path, "w")
        if f then f:write(yajl.to_string(Mux.tokens.global)); f:close() end
    end)
end
function Mux._loadGlobalTokens()
    local path = _overridesFile()
    if not (path and yajl and io and io.open) then return end
    pcall(function()
        local f = io.open(path, "r")
        if not f then return end
        local raw = f:read("*all"); f:close()
        local t = yajl.to_value(raw)
        if type(t) == "table" then Mux.tokens.global = t end
    end)
end

-- Coalesce rapid edits (colour-wheel clicks, slider drags) into one re-style and
-- one file write instead of a full all-panes restyle + JSON write per keystroke.
function Mux._scheduleGlobalRefresh()
    if not tempTimer then if Mux.refreshStyling then Mux.refreshStyling() end; return end
    if Mux._refreshPending then return end
    Mux._refreshPending = true
    tempTimer(0, function()
        Mux._refreshPending = false
        if Mux.refreshStyling then Mux.refreshStyling() end
    end)
end
function Mux._schedulePersist()
    if not tempTimer then Mux._persistGlobalTokens(); return end
    Mux._persistDue = true
    if Mux._persistTimer then return end
    Mux._persistTimer = tempTimer(0.6, function()
        Mux._persistTimer = nil
        if Mux._persistDue then Mux._persistDue = false; Mux._persistGlobalTokens() end
    end)
end

function Mux.setGlobalToken(key, val)
    if val == nil then Mux.tokens.global[key] = nil else Mux.tokens.global[key] = val end
    Mux._schedulePersist()
    Mux._scheduleGlobalRefresh()
end
function Mux.clearGlobalToken(key) Mux.setGlobalToken(key, nil) end

-- Drop ALL global overrides so the active theme (and fallback) shows through.
function Mux.resetGlobalTokens()
    Mux.tokens.global = {}
    Mux._schedulePersist()
    Mux._scheduleGlobalRefresh()
end

-- ── Local (per-scope) overrides ──────────────────────────────────────────────
-- A local edit only re-styles the one owning pane, so it stays immediate.
function Mux.setLocalToken(scope, key, val)
    if not scope then return end
    scope._tokens = scope._tokens or {}
    if val == nil then scope._tokens[key] = nil else scope._tokens[key] = val end
    if Mux.refreshStyling then Mux.refreshStyling(scope) end
end
function Mux.clearLocalToken(scope, key) Mux.setLocalToken(scope, key, nil) end

-- Drop ALL of a scope's local overrides so it falls back to global/theme.
function Mux.resetLocalTokens(scope)
    if not scope then return end
    scope._tokens = {}
    if Mux.refreshStyling then Mux.refreshStyling(scope) end
end

-- ── Tabbed-dialog auto-fit ───────────────────────────────────────────────────
-- Resize a tabbed dialog (Settings, pane Properties) to its currently-active
-- leaf tab so short tabs aren't padded out to the tallest tab's height. Leaf
-- content builders store their needed height on tab._muxContentH; we walk the
-- active path to find the visible leaf and its tab-bar depth. Guarded + a no-op
-- when nothing changed, so it's cheap to call on every tab activation.
function Mux._fitDialogToActiveTab(d)
    if not (d and d.outer and d._findTab) then return end
    local function leaf(surface, bars)
        local tab = surface._activeTabId and surface:_findTab(surface._activeTabId)
        if not tab then return nil, bars end
        if tab._tabs and #tab._tabs > 0 then return leaf(tab, bars + 1) end
        return tab, bars + 1
    end
    local tab, bars = leaf(d, 0)
    if not (tab and tab._muxContentH) then return end
    local theme  = Mux.activeTheme() or {}
    local titleH = theme.titlebarHeight or 22
    local tabH   = theme.tabBarHeight   or 22
    local need   = titleH + 2*2 + bars*tabH + tab._muxContentH + 16
    local _, sh  = getMainWindowSize()
    local capH   = math.floor((sh or 1000) * 0.70)
    local h      = math.max(160, math.min(capH, need))
    if math.abs((d.floatH or 0) - h) < 2 then return end
    d.floatH = h
    d.outer:resize(d.floatW or d.outer:get_width(), h)
    if d.outer.reposition then d.outer:reposition() end
    -- Resizing d.outer alone doesn't push the new pixel size down through the
    -- frame → tab bars → nested tab content chain (same gap as MuxDialog:fitContent
    -- — see its comment). Without this, target.content several tab-levels deep
    -- keeps reporting its PRE-resize size even though the visible window changed,
    -- so a ScrollBox sized "100%" of it is built against stale geometry.
    if Mux._reflowContent then pcall(Mux._reflowContent, d) end
    -- The form's content label was sized to max(content, OLD viewport); now that the
    -- dialog (and thus the viewport) has shrunk, re-run the form's relayout so the
    -- label re-clamps to the NEW viewport — otherwise the ScrollBox keeps scrolling
    -- into the empty gap below the content. Deferred so the resize has flushed; the
    -- relayout re-fires the fit, which no-ops here (height unchanged), so it ends.
    if tab._muxRelayout and tempTimer then
        tempTimer(0, function() pcall(tab._muxRelayout) end)
    end
end

-- Schedule a fit on the next tick. Geometry changes made synchronously inside a
-- Geyser click callback (e.g. expanding a collapsible separator) often don't
-- flush; deferring one tick — the same path the initial open uses — makes the
-- dialog actually grow/shrink to the new content height.
function Mux._scheduleFit(d)
    if not (d and Mux._fitDialogToActiveTab) then return end
    if tempTimer then tempTimer(0, function() pcall(Mux._fitDialogToActiveTab, d) end)
    else pcall(Mux._fitDialogToActiveTab, d) end
end

-- Resolve the dialog a form belongs to by walking up its host chain to the surface
-- flagged _isDialogRoot. With several dialogs open at once, each form must auto-fit
-- ITS OWN dialog, not a single shared global (which the last-opened dialog would win).
function Mux._ownerDialog(scope)
    local s = scope
    while s do
        if s._isDialogRoot then return s end
        s = s.pane
    end
    return Mux._fitDialog
end

-- For the Settings / Properties UIs: the fully-resolved value of every token at
-- a given scope, so the form can display what's inherited from fallback+theme
-- +global before the user overrides it.
function Mux.resolvedTokens(scope)
    local out = {}
    for key in pairs(Mux.tokens.fallback) do out[key] = Mux.tok(key, scope) end
    return out
end

-- Which layer currently supplies a token's value, for "inherited / overridden"
-- affordances in the UI. Returns "local" | "global" | "theme" | "fallback".
function Mux.tokenSource(key, scope)
    if scope and scope._tokens and scope._tokens[key] ~= nil then return "local" end
    if Mux.tokens.global[key] ~= nil then return "global" end
    if Mux.activeThemeTokens()[key] ~= nil then return "theme" end
    return "fallback"
end

Mux._log("Token engine loaded (%d fallback tokens, %d elements).",
    (function() local n=0 for _ in pairs(Mux.tokens.fallback) do n=n+1 end return n end)(),
    (function() local n=0 for _ in pairs(Mux.tokens.elements) do n=n+1 end return n end)())

Mux._loadGlobalTokens()

-- ════════════════════════════════════════════════════════════════════════════
-- THEME REGISTRY + LEGACY BRIDGE  (merged from the former theme.lua)
-- ════════════════════════════════════════════════════════════════════════════
Mux._themes           = Mux._themes           or {}
Mux._activeThemeName  = Mux._activeThemeName  or "dark"
Mux._activeThemeTokens = Mux._activeThemeTokens or {}
Mux._profileCssAddons = Mux._profileCssAddons or {}

-- legacy CSS-blob key -> element name
local CSS_MAP = {
    paneOuterCss="paneOuter", contentCss="content", titlebarCss="titlebar",
    btnCss="btn", closeHoverCss="closeHover", minHoverCss="minHover",
    handleCss="handle", handleHoverCss="handleHover", dragGuideCss="dragGuide",
    cornerHandleCss="cornerHandle", cornerHandleHoverCss="cornerHandleHover",
    contextMenuCss="contextMenu", contextMenuItemCss="contextMenuItem",
    contextMenuItemHoverCss="contextMenuItemHover", contextMenuDangerCss="contextMenuDanger",
    contextMenuDangerHoverCss="contextMenuDangerHover", contextMenuSepCss="contextMenuSep",
    ghostSlotCss="ghostSlot", ghostSlotHoverCss="ghostSlotHover",
    ghostSlotDropHighlightCss="ghostSlotDropHighlight", insertionGhostCss="insertionGhost",
    floatingExtraCss="floatingExtra", tabBarCss="tabBar", tabDropTargetBarCss="tabDropTargetBar",
    tabActiveCss="tabActive", tabInactiveCss="tabInactive", tabMovingCss="tabMoving",
    tabAddBtnCss="tabAddBtn", tabActiveParentCss="tabActiveParent", subTabBarCss="subTabBar",
    tabInsertGhostCss="tabInsertGhost", connScreenBg="connScreenBg", scrollbarCss="scrollbar",
}
-- legacy scalar key -> token key
local TOK_MAP = {
    titlebarHeight="titlebar.height", handleSize="handle.size", btnSize="btn.size",
    btnTopMargin="btn.topMargin", cornerHandleSize="cornerHandle.size",
    btnTextColor="btn.text.glyphColor", handleCursorV="handle.cursor.v", handleCursorH="handle.cursor.h",
    contextMenuItemHeight="contextMenu.itemHeight", contextMenuSepHeight="contextMenu.sepHeight",
    contextMenuWidth="contextMenu.width", contextMenuPadX="contextMenu.padX", contextMenuPadY="contextMenu.padY",
    tabBarHeight="tabBar.height", tabAddBtnWidth="tabAddBtn.width", tabFontSize="tab.fontSize",
    tabActiveTextColor="tab.active.text.color", tabInactiveTextColor="tab.inactive.text.color",
    tabMovingTextColor="tab.moving.text.color", tabAddBtnTextColor="tabAddBtn.text.color",
    tabHoverTextColor="tab.hover.text.color",
    tabInsertGhostTextColor="tabInsertGhost.text.color", titlebarTextColor="titlebar.text.color",
    titlebarCharWidth="titlebar.charWidth",
    connScreenDisconnectedIconColor="connScreen.disconnected.icon.color",
    connScreenDisconnectedTitleColor="connScreen.disconnected.title.color",
    connScreenConnectingIconColor="connScreen.connecting.icon.color",
    connScreenConnectingTitleColor="connScreen.connecting.title.color",
    contextMenuTextColor="contextMenu.echoText.color",
    contextMenuDangerTextColor="contextMenuDanger.text.color",
}
-- legacy ui.* key -> token key
local UI_MAP = {
    textColor="ui.textColor", bg="ui.bg", rowOdd="ui.rowOdd", rowEven="ui.rowEven",
    tabActiveBg="ui.tabActiveBg", tabInactiveBg="ui.tabInactiveBg", tabHoverBg="ui.tabHoverBg",
    tabActiveLine="ui.tabActiveLine", tabActiveText="ui.tabActiveText",
    tabInactiveText="ui.tabInactiveText", tabHoverText="ui.tabHoverText",
    descTextColor="ui.descTextColor", rowDivider="ui.rowDivider", widgetBg="ui.widgetBg",
    widgetFg="ui.widgetFg", widgetBorder="ui.widgetBorder", widgetHoverBg="ui.widgetHoverBg",
    inputBg="ui.inputBg", inputFg="ui.inputFg", inputBorder="ui.inputBorder",
    helpIconFg="ui.helpIconFg", helpIconBg="ui.helpIconBg", helpIconBorder="ui.helpIconBorder",
    helpIconHoverBg="ui.helpIconHoverBg",
}
local STYLE_SLOTS  = { "on", "off", "warn" }
local STYLE_FIELDS = { "bg", "fg", "border", "hover" }

-- Build the legacy-shaped theme table from tokens at the given scope (nil=global).
function Mux._buildEffectiveTheme(scope)
    local T = {}
    for legacy, el  in pairs(CSS_MAP) do T[legacy] = Mux.css(el, scope) end
    for legacy, tk  in pairs(TOK_MAP) do T[legacy] = Mux.tok(tk, scope) end
    local ui = {}
    for legacy, tk  in pairs(UI_MAP)  do ui[legacy] = Mux.tok(tk, scope) end
    ui.styles = {}
    for _, slot in ipairs(STYLE_SLOTS) do
        local s = {}
        for _, f in ipairs(STYLE_FIELDS) do s[f] = Mux.tok("ui.style." .. slot .. "." .. f, scope) end
        ui.styles[slot] = s
    end
    T.ui = ui
    return T
end

function Mux.activeTheme()
    if not Mux._effectiveTheme then Mux._effectiveTheme = Mux._buildEffectiveTheme(nil) end
    return Mux._effectiveTheme
end

function Mux.registerTheme(name, def)
    assert(type(name) == "string", "theme name must be a string")
    assert(type(def)  == "table",  "theme definition must be a table")
    Mux._themes[name] = def
    Mux._log("Registered theme: %s", name)
end

-- Push the profile-level scrollbar skin + any package addons to Qt.
local function _pushProfileCss()
    if not setProfileStyleSheet then return end
    local parts = { Mux.css("scrollbar") }
    for _, css in ipairs(Mux._profileCssAddons) do parts[#parts + 1] = css end
    setProfileStyleSheet(table.concat(parts, "\n"))
end

-- Rebuild styling. With no scope: rebuild the global effective theme and re-apply
-- to everything (theme switch / global token change). With a scope: re-apply just
-- that pane/tab (local token change).
function Mux.refreshStyling(scope)
    if scope then
        if scope.applyTheme then scope:applyTheme() end
        return
    end
    Mux._effectiveTheme = Mux._buildEffectiveTheme(nil)
    _pushProfileCss()
    -- Tabs are styled by the same token element templates as everything else
    -- (theme.tab*Css = Mux.css("tab*")); restyle every live tab host so theme
    -- switches and global-token edits flow through, just like panes/splits.
    if Mux._restyleAllTabs then pcall(Mux._restyleAllTabs) end
    for _, p in pairs(Mux._panes)  do if p.applyTheme then p:applyTheme() end end
    for _, s in pairs(Mux._splits) do if s.applyTheme then s:applyTheme() end end
end

function Mux.applyTheme(name)
    if not Mux._themes[name] then
        Mux._err("applyTheme: unknown theme '%s'", name)
        return
    end
    Mux._activeThemeName   = name
    Mux._activeThemeTokens = Mux._themes[name] or {}
    Mux.refreshStyling()
end

--- Register CSS that must persist across theme changes (profile-wide Qt rules).
function Mux.addProfileCss(css)
    assert(type(css) == "string", "addProfileCss: css must be a string")
    table.insert(Mux._profileCssAddons, css)
    _pushProfileCss()
end

-- ── User-saved themes ────────────────────────────────────────────────────────
-- `mux theme save <name>` bottles the current look (active-theme tokens overlaid
-- with the global overrides) into a named theme: registered immediately (so it's
-- switchable and shows in the picker), persisted as JSON so it survives a restart,
-- and exported as a standalone registerTheme() script the user can drop into a
-- package to share.
Mux._userThemes = Mux._userThemes or {}
local _BUILTIN_THEMES = { dark = true, light = true }

local function _userThemesFile()
    if not getMudletHomeDir then return nil end
    return getMudletHomeDir() .. "/Muxlet_persistent/user_themes.json"
end

-- Snapshot the effective theme-layer token set: active theme tokens, then the
-- global overrides on top (globals win), so the result reproduces the current
-- look standalone — even on another profile with no globals set.
local function _snapshotThemeTokens()
    local snap = {}
    for k, v in pairs(Mux.activeThemeTokens()) do snap[k] = v end
    for k, v in pairs(Mux.tokens.global)      do snap[k] = v end
    return snap
end

function Mux._persistUserThemes()
    local path = _userThemesFile()
    if not (path and yajl and io) then return end
    pcall(function() if lfs then lfs.mkdir(getMudletHomeDir() .. "/Muxlet_persistent") end end)
    pcall(function()
        local f = io.open(path, "w")
        if f then f:write(yajl.to_string(Mux._userThemes)); f:close() end
    end)
end

function Mux._loadUserThemes()
    local path = _userThemesFile()
    if not (path and yajl and io and io.open) then return end
    pcall(function()
        local f = io.open(path, "r"); if not f then return end
        local raw = f:read("*all"); f:close()
        local t = yajl.to_value(raw)
        if type(t) == "table" then
            Mux._userThemes = t
            for name, tok in pairs(t) do
                if type(tok) == "table" and not _BUILTIN_THEMES[name] then
                    Mux.registerTheme(name, tok)
                end
            end
        end
    end)
end

-- One Mux.registerTheme(...) line — the shared building block for single-theme
-- export, "export all", and Mux.exportWorkspace's dependency bundling
-- (workspace.lua), exactly mirroring Mux._conditionRegisterLua/_actionRegisterLua
-- (conditional.lua). Uses the shared Mux._serializeLua rather than the old
-- bespoke flat-scalar-only serializer, so it round-trips any token value type.
function Mux._themeRegisterLua(name, tok)
    return "Mux.registerTheme(" .. Mux._serializeLua(name, 0) .. ", " .. Mux._serializeLua(tok, 0) .. ")"
end

-- On-demand export of one user theme (not just at save time) — writes
-- <safe-name>-theme-export.lua to Mux._persistentDir, same flat layout and
-- naming convention as Mux.exportCondition/exportAction/exportWorkspace.
-- quiet=true skips the success echo (used by saveThemeFromGlobals, which
-- reports its own consolidated save+export message instead).
function Mux.exportTheme(name, quiet)
    if not name or name == "" then
        Mux._echo("\n<red>[mux]<reset> Usage: mux theme export <name>|all\n")
        return
    end
    local tok = Mux._userThemes[name]
    if not tok then
        Mux._echo(string.format(
            "\n<red>[mux]<reset> No user theme named '%s'.\n"
            .. "  (Built-ins can't be exported — they're already code. Use `mux themes`.)\n",
            name))
        return
    end
    local safe = name:gsub("[^%w_%-]", "_")
    local lua = "-- Generated by `mux theme export " .. name .. "`.\n\n" .. Mux._themeRegisterLua(name, tok) .. "\n"
    local outPath = Mux._writeExportFile(safe .. "-theme-export.lua", lua)
    if outPath and not quiet then
        Mux._echo(string.format("\n<green>[mux]<reset> Exported theme '<cyan>%s<reset>' to:\n  <white>%s<reset>\n", name, outPath))
    end
    return outPath
end

function Mux.exportAllThemes()
    local names = {}
    for name in pairs(Mux._userThemes) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        Mux._echo("\n<yellow>[mux]<reset> No user themes to export.\n")
        return
    end
    local lines = { "-- Generated by `mux theme export all`.", "" }
    for _, name in ipairs(names) do lines[#lines + 1] = Mux._themeRegisterLua(name, Mux._userThemes[name]) end
    lines[#lines + 1] = ""
    local outPath = Mux._writeExportFile("themes-export.lua", table.concat(lines, "\n"))
    if outPath then
        Mux._echo(string.format("\n<green>[mux]<reset> Exported %d theme(s) to:\n  <white>%s<reset>\n", #names, outPath))
    end
end

-- Save the current look as theme `name`. Returns ok, message.
function Mux.saveThemeFromGlobals(name)
    if not name or name == "" then
        return false, "Usage: mux theme save <name>"
    end
    if _BUILTIN_THEMES[name:lower()] then
        return false, string.format("'%s' is a built-in theme name — choose another.", name)
    end
    local snap = _snapshotThemeTokens()
    local count = 0; for _ in pairs(snap) do count = count + 1 end

    local existed = Mux._themes[name] ~= nil
    Mux.registerTheme(name, snap)          -- live: switchable + appears in the picker
    Mux._userThemes[name] = snap
    Mux._persistUserThemes()               -- survives restart
    local exportPath = Mux.exportTheme(name, true)   -- also drop a package-ready script (quiet: message below covers it)

    -- Refresh any open theme picker so the new entry shows immediately.
    if Mux._settings_ui and Mux._settings_ui._refreshAllForms then
        pcall(Mux._settings_ui._refreshAllForms)
    end

    return true, string.format(
        "%s theme '%s' (%d tokens). Switch with: mux theme %s%s",
        existed and "Updated" or "Saved", name, count, name,
        exportPath and ("\n  Package script: " .. exportPath) or "")
end

Mux._log("mux_theme loaded (token-backed)")

Mux._loadUserThemes()