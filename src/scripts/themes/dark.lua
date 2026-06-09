-- Muxlet — Dark theme
-- Deep blue-black palette with high-contrast accents.
-- This is the default theme; selected automatically on first load.

Mux.registerTheme("dark", {

    -- ── Dimensions ────────────────────────────────────────────────────────────
    titlebarHeight     = 22,
    revealStripHeight  = 4,
    handleSize         = 3,
    btnSize            = 18,
    btnTopMargin       = 2,
    cornerHandleSize   = 10,

    -- ── Pane outer container ──────────────────────────────────────────────────
    paneOuterCss = [[
        background-color: rgba(10, 10, 16, 248);
        border: 2px solid rgba(255, 255, 255, 0.38);
        border-radius: 3px;
    ]],

    -- ── Content area ──────────────────────────────────────────────────────────
    contentCss = [[
        background-color: rgba(8, 8, 13, 255);
        border: none;
    ]],

    -- ── Titlebar ──────────────────────────────────────────────────────────────
    titlebarCss = [[
        background-color: rgba(25, 25, 38, 235);
        border-bottom: 1px solid rgba(255, 255, 255, 0.18);
        color: rgba(215, 215, 230, 0.92);
        font-size: 11px;
        font-weight: bold;
    ]],

    -- ── Reveal strip (shown when titlebar is hidden) ───────────────────────────
    revealStripCss = [[
        background-color: rgba(255, 255, 255, 0.04);
        border: none;
        border-bottom: 1px solid rgba(255, 255, 255, 0.12);
    ]],
    revealStripHoverCss = [[
        background-color: rgba(100, 160, 255, 0.20);
        border: none;
        border-bottom: 1px solid rgba(120, 180, 255, 0.45);
    ]],

    -- ── Titlebar buttons ──────────────────────────────────────────────────────
    -- btnTextColor is used to explicitly colour button glyphs in echo() HTML because
    -- Qt ignores a QLabel stylesheet's color: property when the content is rich text.
    btnTextColor = "#aaaabb",
    btnCss = [[
        QLabel {
            background-color: rgba(38, 38, 52, 200);
            border: 1px solid rgba(255, 255, 255, 0.16);
            border-radius: 3px;
            color: rgba(175, 175, 190, 225);
            font-size: 9px;
            font-weight: bold;
        }
        QLabel::hover {
            background-color: rgba(65, 65, 85, 220);
            border-color: rgba(255, 255, 255, 0.38);
            color: white;
        }
    ]],
    closeHoverCss = [[
        QLabel {
            background-color: rgba(170, 38, 38, 225);
            border: 1px solid rgba(220, 60, 60, 0.65);
            border-radius: 3px;
            color: white;
            font-size: 9px;
            font-weight: bold;
        }
        QLabel::hover {
            background-color: rgba(210, 50, 50, 245);
            border-color: rgba(255, 80, 80, 0.85);
            color: white;
        }
    ]],
    minHoverCss = [[
        QLabel {
            background-color: rgba(170, 140, 30, 225);
            border: 1px solid rgba(220, 185, 40, 0.65);
            border-radius: 3px;
            color: white;
            font-size: 9px;
            font-weight: bold;
        }
        QLabel::hover {
            background-color: rgba(205, 168, 42, 245);
            border-color: rgba(240, 210, 60, 0.85);
            color: white;
        }
    ]],

    -- ── Resize handle ─────────────────────────────────────────────────────────
    handleCss = [[
        background-color: rgba(255, 255, 255, 0.38);
        border: none;
    ]],
    handleHoverCss = [[
        background-color: rgba(100, 160, 255, 0.65);
        border: none;
    ]],
    handleCursorV = "ResizeVertical",
    handleCursorH = "ResizeHorizontal",

    -- ── Corner resize handles (floating panes) ────────────────────────────────
    cornerHandleCss = [[
        background-color: rgba(255, 255, 255, 0.0);
        border: none;
    ]],
    cornerHandleHoverCss = [[
        background-color: rgba(100, 160, 255, 0.45);
        border: none;
        border-radius: 2px;
    ]],

    -- ── Context menu ──────────────────────────────────────────────────────────
    contextMenuCss = [[
        background-color: rgba(18, 18, 28, 252);
        border: 1px solid rgba(100, 160, 255, 0.50);
        border-radius: 4px;
        color: rgba(215, 215, 230, 0.95);
        font-size: 11px;
    ]],
    contextMenuItemHeight     = 30,
    contextMenuSepHeight      = 9,
    contextMenuWidth          = 220,
    contextMenuItemCss        = "color:rgba(215,215,230,0.95);background-color:rgba(0,0,0,0);border:none;font-size:11px;",
    contextMenuItemHoverCss   = "color:rgba(255,255,255,1.0);background-color:rgba(100,160,255,0.22);border:none;font-size:11px;",
    contextMenuDangerCss      = "color:rgba(230,100,100,0.95);background-color:rgba(0,0,0,0);border:none;font-size:11px;",
    contextMenuDangerHoverCss = "color:rgba(255,150,150,1.0);background-color:rgba(180,40,40,0.35);border:none;font-size:11px;",
    contextMenuSepCss         = "background-color:rgba(255,255,255,0.04);border:none;border-top:1px solid rgba(255,255,255,0.14);",

    -- ── Ghost slot (empty slot left by a floating pane) ───────────────────────
    ghostSlotCss = [[
        background-color: rgba(20, 24, 40, 180);
        border: 2px dashed rgba(100, 120, 200, 0.45);
        border-radius: 3px;
    ]],
    ghostSlotHoverCss = [[
        background-color: rgba(25, 30, 55, 200);
        border: 2px dashed rgba(120, 150, 255, 0.65);
        border-radius: 3px;
    ]],
    ghostSlotDropHighlightCss = [[
        background-color: rgba(30, 40, 80, 220);
        border: 2px solid rgba(100, 160, 255, 0.85);
        border-radius: 3px;
    ]],

    -- ── Insertion ghost (edge-drop preview strip) ─────────────────────────────
    insertionGhostCss = [[
        background-color: rgba(80, 130, 255, 0.22);
        border: 2px solid rgba(100, 160, 255, 0.75);
        border-radius: 2px;
    ]],

    -- ── Floating pane extra border (permanent floats — gold, distinct from focus blue) ──
    floatingExtraCss = [[
        border: 2px solid rgba(205, 162, 40, 0.72);
        border-radius: 3px;
    ]],

    -- ── Focused pane border ────────────────────────────────────────────────────
    focusedFrameCss = [[
        background-color: rgba(10, 10, 16, 248);
        border: 2px solid rgba(100, 180, 255, 0.85);
        border-radius: 3px;
    ]],

    -- ── Keybind hint overlay ──────────────────────────────────────────────────
    hintOverlayCss = [[
        background-color: rgba(15, 15, 24, 235);
        border: 1px solid rgba(100, 180, 255, 0.55);
        border-radius: 5px;
        color: rgba(210, 220, 235, 0.95);
        font-size: 11px;
        font-family: "Consolas", "Monaco", monospace;
        padding: 8px;
    ]],
    hintKeyColor    = "rgba(100, 200, 255, 1.0)",
    hintActionColor = "rgba(200, 210, 220, 0.85)",
    hintFooterColor = "rgba(140, 155, 175, 0.50)",

    -- ── Tab system ────────────────────────────────────────────────────────────
    tabBarHeight    = 22,
    tabAddBtnWidth  = 24,

    tabBarCss = [[
        background-color: rgba(14, 14, 22, 240);
        border-bottom: 1px solid rgba(255, 255, 255, 0.10);
    ]],
    tabDropTargetBarCss = [[
        background-color: rgba(25, 40, 65, 230);
        border-bottom: 2px solid rgba(100, 180, 255, 0.55);
    ]],
    tabActiveCss = [[
        QLabel {
            background-color: rgba(46, 48, 70, 255);
            border: 1px solid rgba(255, 255, 255, 0.22);
            border-top: 2px solid rgba(110, 170, 255, 0.65);
            border-bottom: none;
            color: rgba(228, 228, 248, 1.0);
            font-size: 11px;
            font-weight: bold;
            padding: 0 4px;
        }
    ]],
    tabInactiveCss = [[
        QLabel {
            background-color: rgba(16, 16, 24, 200);
            border: none;
            border-right: 1px solid rgba(255, 255, 255, 0.08);
            color: rgba(155, 162, 198, 0.88);
            font-size: 11px;
            font-weight: bold;
            padding: 0 4px;
        }
        QLabel::hover {
            background-color: rgba(30, 32, 48, 220);
            color: rgba(210, 215, 238, 1.0);
            border-top: 1px solid rgba(255, 255, 255, 0.14);
        }
    ]],
    tabMovingCss = [[
        QLabel {
            background-color: rgba(80, 15, 15, 235);
            border-right: 1px solid rgba(180, 45, 45, 0.35);
            color: rgba(255, 170, 170, 1.0);
            font-size: 11px;
            font-weight: bold;
            border-bottom: 2px solid rgba(195, 50, 50, 0.85);
            padding: 0 2px;
        }
    ]],
    tabAddBtnCss = [[
        QLabel {
            background-color: rgba(14, 14, 22, 200);
            border-left: 1px solid rgba(255, 255, 255, 0.10);
            color: rgba(185, 192, 220, 0.90);
            font-size: 15px;
            font-weight: bold;
        }
        QLabel::hover {
            background-color: rgba(35, 35, 55, 225);
            color: rgba(225, 228, 248, 1.0);
        }
    ]],
    tabActiveTextColor      = "rgba(228, 228, 248, 1.0)",
    tabInactiveTextColor    = "rgba(155, 162, 198, 0.88)",
    tabMovingTextColor      = "rgba(255, 170, 170, 1.0)",
    tabAddBtnTextColor      = "rgba(185, 192, 220, 0.90)",
    -- Ghost preview shown at insertion point during tab drag / double-click move.
    tabInsertGhostCss = [[
        QLabel {
            background-color: rgba(80, 140, 255, 0.18);
            border: 2px dashed rgba(110, 170, 255, 0.55);
            border-radius: 2px;
        }
    ]],
    tabInsertGhostTextColor = "rgba(140, 200, 255, 0.80)",

    -- ── Titlebar text color (explicit; CSS color ignored for HTML-mode echo) ─────
    titlebarTextColor = "rgba(215, 215, 230, 0.92)",

    -- ── Connection awareness screen ────────────────────────────────────────────
    connScreenBg                     = "background-color:rgba(8,8,14,250);border:none;",
    connScreenDisconnectedIconColor  = "rgba(150,50,50,210)",
    connScreenDisconnectedTitleColor = "rgba(185,70,70,225)",
    connScreenConnectingIconColor    = "rgba(40,110,140,210)",
    connScreenConnectingTitleColor   = "rgba(55,140,165,225)",

    -- ── Context menu text colors (CSS color ignored for HTML echo content) ─────
    contextMenuTextColor       = "rgba(215, 215, 230, 0.95)",
    contextMenuDangerTextColor = "rgba(230, 100, 100, 0.95)",

    -- ── Profile-level scrollbar skin (applied via setProfileStyleSheet) ───────
    -- Cascades to all QScrollArea/QScrollBar widgets in the profile.
    -- QScrollArea > QWidget makes the viewport transparent to kill the gap sliver.
    scrollbarCss = [[
        QScrollArea { border: none; background: transparent; }
        QScrollArea > QWidget { background: transparent; }
        QScrollBar:vertical {
            background: rgb(14, 14, 22);
            width: 6px;
            border: none;
            margin: 0;
        }
        QScrollBar::handle:vertical {
            background: rgba(75, 78, 95, 0.65);
            border-radius: 3px;
            min-height: 20px;
        }
        QScrollBar::handle:vertical:hover {
            background: rgba(120, 124, 148, 0.85);
        }
        QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
            height: 0; background: none;
        }
        QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {
            background: transparent;
        }
        QScrollBar:horizontal { height: 0px; border: none; background: transparent; }
    ]],

    -- ── Settings window palette ────────────────────────────────────────────────
    settingsUi = {
        textColor        = "rgba(215, 215, 230, 0.92)",
        bg               = "rgb(18, 18, 26)",
        rowOdd           = "rgb(16, 16, 24)",
        rowEven          = "rgb(34, 34, 50)",
        tabActiveBg      = "rgb(40, 40, 62)",
        tabInactiveBg    = "rgb(18, 18, 26)",
        tabHoverBg       = "rgb(35, 35, 55)",
        tabActiveLine    = "rgba(100, 180, 255, 0.8)",
        tabActiveText    = "rgba(215, 215, 230, 0.95)",
        tabInactiveText  = "rgba(160, 165, 185, 0.75)",
        tabHoverText     = "rgba(215, 218, 232, 0.95)",
        rowDivider       = "rgba(255, 255, 255, 0.12)",
        -- Widget colors (dropdowns, steppers, text inputs, apply button)
        widgetBg         = "rgb(38, 38, 58)",
        widgetFg         = "#d8d8f0",
        widgetBorder     = "rgba(255, 255, 255, 0.22)",
        widgetHoverBg    = "rgb(55, 55, 80)",
        inputBg          = "rgb(12, 12, 18)",
        inputFg          = "#c8c8d0",
        inputBorder      = "rgba(255, 255, 255, 0.46)",
        -- Toggle widget
        toggleOnBg       = "rgb(30, 70, 40)",
        toggleOnFg       = "#88ee88",
        toggleOnBorder   = "rgba(80, 180, 80, 0.5)",
        toggleOnHoverBg  = "rgb(40, 90, 50)",
        toggleOffBg      = "rgb(65, 30, 30)",
        toggleOffFg      = "rgba(220, 120, 120, 0.9)",
        toggleOffBorder  = "rgba(180, 80, 80, 0.4)",
        toggleOffHoverBg = "rgb(85, 40, 40)",
        -- Help icon (the "i" badge on each setting row)
        helpIconFg     = "rgba(100, 160, 255, 0.85)",
        helpIconBg     = "rgba(60, 80, 120, 0.25)",
        helpIconBorder = "rgba(100, 140, 200, 0.35)",
    },
})
