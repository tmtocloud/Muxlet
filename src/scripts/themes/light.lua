-- Muxlet — Light theme
-- Soft grey-white palette for bright environments.
--
-- A theme is a SPARSE token-override table: it overrides only the tokens that
-- differ from the dark fallback (mostly colours; structural sizes/radii fall
-- through). Anything omitted inherits the fallback.
--
-- Note: the dark theme's close/min button HOVER states brighten the border
-- colour; the original light theme left the base border to persist on hover.
-- Under the shared element template light sets *.hover.border.color equal to its
-- base border colour, so the rendered result is identical — just made explicit.

Mux.registerTheme("light", {
    -- Pane frame
    ["pane.bg"]                   = "rgba(238,238,245,248)",
    ["pane.border.color"]         = "rgba(0,0,0,0.28)",
    ["content.bg"]                = "rgba(248,248,252,255)",

    -- Titlebar
    ["titlebar.bg"]               = "rgba(210,212,226,240)",
    ["titlebar.borderBottom.color"] = "rgba(0,0,0,0.20)",
    ["titlebar.text.color"]       = "rgba(18,18,32,0.95)",

    -- Titlebar buttons
    ["btn.text.glyphColor"]       = "#2c2c3c",
    ["btn.bg"]                    = "rgba(192,192,208,200)",
    ["btn.border.color"]          = "rgba(0,0,0,0.16)",
    ["btn.text.color"]            = "rgba(45,45,60,225)",
    ["btn.hover.bg"]              = "rgba(165,165,185,220)",
    ["btn.hover.border.color"]    = "rgba(0,0,0,0.30)",
    ["btn.hover.text.color"]      = "black",
    ["close.bg"]                  = "rgba(210,45,45,225)",
    ["close.border.color"]        = "rgba(180,30,30,0.65)",
    ["close.text.color"]          = "white",
    ["close.hover.bg"]            = "rgba(230,55,55,245)",
    ["close.hover.border.color"]  = "rgba(180,30,30,0.65)",  -- matches base
    ["close.hover.text.color"]    = "white",
    ["min.bg"]                    = "rgba(200,160,30,225)",
    ["min.border.color"]          = "rgba(180,140,20,0.65)",
    ["min.text.color"]            = "white",
    ["min.hover.bg"]              = "rgba(215,175,40,245)",
    ["min.hover.border.color"]    = "rgba(180,140,20,0.65)",  -- = base
    ["min.hover.text.color"]      = "white",

    -- Handles
    ["handle.bg"]                 = "rgba(0,0,0,0.28)",
    ["handle.hover.bg"]           = "rgba(50,100,220,0.55)",
    ["dragGuide.bg"]              = "rgba(50,100,220,0.70)",
    ["cornerHandle.bg"]           = "rgba(0,0,0,0.0)",
    ["cornerHandle.hover.bg"]     = "rgba(50,100,220,0.35)",

    -- Context menu
    ["contextMenu.bg"]            = "rgba(248,249,253,0.985)",
    ["contextMenu.border.color"]  = "rgba(40,70,140,0.14)",
    ["contextMenu.text.color"]    = "rgba(15,15,30,0.95)",
    ["contextMenu.echoText.color"] = "rgba(15,15,30,0.92)",
    ["contextMenuItem.hover.bg"]  = "rgba(50,110,230,0.14)",
    ["contextMenuDanger.text.color"] = "rgba(160,30,30,0.95)",
    ["contextMenuDanger.hover.bg"] = "rgba(210,70,70,0.18)",
    ["contextMenuSep.color"]      = "rgba(0,0,0,0.10)",

    -- Ghost / insertion
    ["ghostSlot.bg"]              = "rgba(220,222,235,180)",
    ["ghostSlot.border.color"]    = "rgba(100,110,160,0.45)",
    ["ghostSlot.hover.bg"]        = "rgba(210,215,235,200)",
    ["ghostSlot.hover.border.color"] = "rgba(80,100,200,0.65)",
    ["ghostSlot.drop.bg"]         = "rgba(190,210,245,220)",
    ["ghostSlot.drop.border.color"] = "rgba(60,110,220,0.85)",
    ["insertionGhost.bg"]         = "rgba(60,110,220,0.20)",
    ["insertionGhost.border.color"] = "rgba(60,120,230,0.75)",

    -- Floating accent
    ["floating.border.color"]     = "rgba(180,138,20,0.70)",

    -- Connection screen
    ["connScreen.bg"]                       = "rgba(242,242,248,250)",
    ["connScreen.disconnected.icon.color"]  = "rgba(155,35,35,210)",
    ["connScreen.disconnected.title.color"] = "rgba(175,50,50,225)",
    ["connScreen.connecting.icon.color"]    = "rgba(30,90,130,210)",
    ["connScreen.connecting.title.color"]   = "rgba(40,115,155,225)",

    -- Tabs
    ["tabBar.bg"]                 = "rgba(200,202,218,235)",
    ["tabBar.borderBottom.color"] = "rgba(0,0,0,0.14)",
    ["tabDropTarget.bg"]          = "rgba(185,200,230,230)",
    ["tabDropTarget.borderBottom.color"] = "rgba(50,100,220,0.55)",
    ["tab.active.bg"]             = "rgba(255,255,255,246)",
    ["tab.active.border.color"]   = "rgba(0,0,0,0.20)",
    ["tab.active.text.color"]     = "rgba(14,14,28,0.95)",
    ["tab.inactive.bg"]           = "rgba(192,195,215,200)",
    ["tab.inactive.border.color"] = "rgba(0,0,0,0.18)",
    ["tab.inactive.text.color"]   = "rgba(55,62,95,0.88)",
    ["tab.hover.highlight"]       = "rgba(55,110,230,0.65)",
    ["tab.hover.text.color"]      = "rgba(18,22,50,0.98)",
    ["tab.moving.bg"]             = "rgba(200,70,70,220)",
    ["tab.moving.borderRight.color"] = "rgba(160,30,30,0.35)",
    ["tab.moving.text.color"]     = "rgba(255,240,240,1.0)",
    ["tab.moving.borderBottom.color"] = "rgba(180,40,40,0.85)",
    ["tabAddBtn.bg"]              = "rgba(200,202,218,200)",
    ["tabAddBtn.borderLeft.color"] = "rgba(0,0,0,0.12)",
    ["tabAddBtn.text.color"]      = "rgba(80,88,118,0.80)",
    ["tabAddBtn.fontSize"]        = 14,
    ["tabAddBtn.hover.bg"]        = "rgba(182,185,205,225)",
    ["tabAddBtn.hover.text.color"] = "rgba(25,30,60,0.95)",
    ["tabInsertGhost.bg"]         = "rgba(55,110,230,0.14)",
    ["tabInsertGhost.border.color"] = "rgba(55,110,230,0.50)",
    ["tabInsertGhost.text.color"] = "rgba(30,70,190,0.78)",

    -- Scrollbar
    ["scrollbar.track.bg"]        = "rgb(210,212,220)",
    ["scrollbar.handle.bg"]       = "rgba(135,138,155,0.60)",
    ["scrollbar.handle.hover.bg"] = "rgba(90,93,115,0.82)",

    -- Widget palette
    ["ui.textColor"]       = "rgba(18,18,32,0.95)",
    ["ui.bg"]              = "rgb(238,238,245)",
    ["ui.rowOdd"]          = "rgb(232,234,244)",
    ["ui.rowEven"]         = "rgb(218,220,232)",
    ["ui.tabActiveBg"]     = "rgb(210,212,226)",
    ["ui.tabInactiveBg"]   = "rgb(238,238,245)",
    ["ui.tabHoverBg"]      = "rgb(218,220,235)",
    ["ui.tabActiveLine"]   = "rgba(50,100,220,0.8)",
    ["ui.tabActiveText"]   = "rgba(14,14,28,0.95)",
    ["ui.tabInactiveText"] = "rgba(60,65,90,0.72)",
    ["ui.tabHoverText"]    = "rgba(14,14,28,0.95)",
    ["ui.descTextColor"]   = "rgba(65,75,115,0.80)",
    ["ui.rowDivider"]      = "rgba(0,0,0,0.13)",
    ["ui.widgetBg"]        = "rgb(200,202,218)",
    ["ui.widgetFg"]        = "rgba(18,18,40,0.90)",
    ["ui.widgetBorder"]    = "rgba(0,0,0,0.22)",
    ["ui.widgetHoverBg"]   = "rgb(178,182,205)",
    ["ui.inputBg"]         = "rgb(248,248,252)",
    ["ui.inputFg"]         = "#1a1a2e",
    ["ui.inputBorder"]     = "rgba(0,0,0,0.30)",
    ["ui.helpIconFg"]      = "rgba(40,80,200,0.85)",
    ["ui.helpIconBg"]      = "rgba(60,100,210,0.14)",
    ["ui.helpIconBorder"]  = "rgba(50,90,200,0.35)",
    ["ui.helpIconHoverBg"] = "rgba(60,100,210,0.35)",
    ["ui.style.on.bg"]     = "rgb(160,220,160)",
    ["ui.style.on.fg"]     = "#1a5a1a",
    ["ui.style.on.border"] = "rgba(60,160,60,0.6)",
    ["ui.style.on.hover"]  = "rgb(140,200,140)",
    ["ui.style.off.bg"]     = "rgb(240,200,200)",
    ["ui.style.off.fg"]     = "#8b1010",
    ["ui.style.off.border"] = "rgba(180,60,60,0.5)",
    ["ui.style.off.hover"]  = "rgb(220,175,175)",
    ["ui.style.warn.bg"]     = "rgb(255,245,195)",
    ["ui.style.warn.fg"]     = "rgb(100,70,0)",
    ["ui.style.warn.border"] = "rgba(180,140,0,0.5)",
    ["ui.style.warn.hover"]  = "rgb(240,225,160)",
})