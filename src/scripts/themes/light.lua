-- Muxlet — Light theme
-- Soft grey-white palette for bright environments.

Mux.registerTheme("light", {

    -- ── Dimensions ────────────────────────────────────────────────────────────
    titlebarHeight     = 22,
    revealStripHeight  = 4,
    handleSize         = 3,
    btnSize            = 18,
    btnTopMargin       = 2,
    cornerHandleSize   = 10,

    -- ── Pane outer container ──────────────────────────────────────────────────
    paneOuterCss = [[
        background-color: rgba(238, 238, 245, 248);
        border: 2px solid rgba(0, 0, 0, 0.28);
        border-radius: 3px;
    ]],

    -- ── Content area ──────────────────────────────────────────────────────────
    contentCss = [[
        background-color: rgba(248, 248, 252, 255);
        border: none;
    ]],

    -- ── Titlebar ──────────────────────────────────────────────────────────────
    titlebarCss = [[
        background-color: rgba(210, 212, 226, 240);
        border-bottom: 1px solid rgba(0, 0, 0, 0.20);
        color: rgba(18, 18, 32, 0.95);
        font-size: 11px;
        font-weight: bold;
    ]],

    -- ── Reveal strip ──────────────────────────────────────────────────────────
    revealStripCss = [[
        background-color: rgba(0, 0, 0, 0.04);
        border: none;
        border-bottom: 1px solid rgba(0, 0, 0, 0.12);
    ]],
    revealStripHoverCss = [[
        background-color: rgba(50, 100, 220, 0.18);
        border: none;
        border-bottom: 1px solid rgba(60, 120, 240, 0.42);
    ]],

    -- ── Titlebar buttons ──────────────────────────────────────────────────────
    btnTextColor = "#2c2c3c",
    btnCss = [[
        QLabel {
            background-color: rgba(192, 192, 208, 200);
            border: 1px solid rgba(0, 0, 0, 0.16);
            border-radius: 3px;
            color: rgba(45, 45, 60, 225);
            font-size: 9px;
            font-weight: bold;
        }
        QLabel::hover {
            background-color: rgba(165, 165, 185, 220);
            border-color: rgba(0, 0, 0, 0.30);
            color: black;
        }
    ]],
    closeHoverCss = [[
        QLabel {
            background-color: rgba(210, 45, 45, 225);
            border: 1px solid rgba(180, 30, 30, 0.65);
            border-radius: 3px;
            color: white;
            font-size: 9px;
            font-weight: bold;
        }
        QLabel::hover {
            background-color: rgba(230, 55, 55, 245);
            color: white;
        }
    ]],
    minHoverCss = [[
        QLabel {
            background-color: rgba(200, 160, 30, 225);
            border: 1px solid rgba(180, 140, 20, 0.65);
            border-radius: 3px;
            color: white;
            font-size: 9px;
            font-weight: bold;
        }
        QLabel::hover {
            background-color: rgba(215, 175, 40, 245);
            color: white;
        }
    ]],

    -- ── Resize handle ─────────────────────────────────────────────────────────
    handleCss = [[
        background-color: rgba(0, 0, 0, 0.28);
        border: none;
    ]],
    handleHoverCss = [[
        background-color: rgba(50, 100, 220, 0.55);
        border: none;
    ]],
    handleCursorV = "ResizeVertical",
    handleCursorH = "ResizeHorizontal",

    -- ── Corner resize handles ─────────────────────────────────────────────────
    cornerHandleCss = [[
        background-color: rgba(0, 0, 0, 0.0);
        border: none;
    ]],
    cornerHandleHoverCss = [[
        background-color: rgba(50, 100, 220, 0.35);
        border: none;
        border-radius: 2px;
    ]],

    -- ── Context menu ──────────────────────────────────────────────────────────
    contextMenuCss = [[
        background-color: rgba(232, 234, 244, 252);
        border: 1px solid rgba(50, 100, 220, 0.45);
        border-radius: 4px;
        color: rgba(15, 15, 30, 0.95);
        font-size: 11px;
    ]],
    contextMenuItemHeight     = 30,
    contextMenuSepHeight      = 9,
    contextMenuWidth          = 220,
    contextMenuItemCss        = "color:rgba(15,15,30,0.92);background-color:rgba(0,0,0,0);border:none;font-size:11px;",
    contextMenuItemHoverCss   = "color:rgba(5,5,20,1.0);background-color:rgba(50,100,220,0.14);border:none;font-size:11px;",
    contextMenuDangerCss      = "color:rgba(160,30,30,0.95);background-color:rgba(0,0,0,0);border:none;font-size:11px;",
    contextMenuDangerHoverCss = "color:rgba(180,20,20,1.0);background-color:rgba(200,60,60,0.18);border:none;font-size:11px;",
    contextMenuSepCss         = "background-color:rgba(0,0,0,0.03);border:none;border-top:1px solid rgba(0,0,0,0.20);",

    -- ── Ghost slot (empty slot left by a floating pane) ───────────────────────
    ghostSlotCss = [[
        background-color: rgba(220, 222, 235, 180);
        border: 2px dashed rgba(100, 110, 160, 0.45);
        border-radius: 3px;
    ]],
    ghostSlotHoverCss = [[
        background-color: rgba(210, 215, 235, 200);
        border: 2px dashed rgba(80, 100, 200, 0.65);
        border-radius: 3px;
    ]],
    ghostSlotDropHighlightCss = [[
        background-color: rgba(190, 210, 245, 220);
        border: 2px solid rgba(60, 110, 220, 0.85);
        border-radius: 3px;
    ]],

    -- ── Insertion ghost (edge-drop preview strip) ─────────────────────────────
    insertionGhostCss = [[
        background-color: rgba(60, 110, 220, 0.20);
        border: 2px solid rgba(60, 120, 230, 0.75);
        border-radius: 2px;
    ]],

    -- ── Floating pane extra border (permanent floats — gold, distinct from focus blue) ──
    floatingExtraCss = [[
        border: 2px solid rgba(180, 138, 20, 0.70);
        border-radius: 3px;
    ]],

    -- ── Focused pane border ────────────────────────────────────────────────────
    focusedFrameCss = [[
        background-color: rgba(238, 238, 245, 248);
        border: 2px solid rgba(50, 100, 220, 0.85);
        border-radius: 3px;
    ]],

    -- ── Titlebar text color ───────────────────────────────────────────────────
    titlebarTextColor = "rgba(18, 18, 32, 0.95)",
    titlebarCharWidth = 7,

    -- ── Connection awareness screen ────────────────────────────────────────────
    connScreenBg                     = "background-color:rgba(242,242,248,250);border:none;",
    connScreenDisconnectedIconColor  = "rgba(155,35,35,210)",
    connScreenDisconnectedTitleColor = "rgba(175,50,50,225)",
    connScreenConnectingIconColor    = "rgba(30,90,130,210)",
    connScreenConnectingTitleColor   = "rgba(40,115,155,225)",

    -- ── Context menu text colors ──────────────────────────────────────────────
    contextMenuTextColor       = "rgba(15, 15, 30, 0.92)",
    contextMenuDangerTextColor = "rgba(160, 30, 30, 0.95)",

    -- ── Tab system ────────────────────────────────────────────────────────────
    tabBarHeight    = 22,
    tabAddBtnWidth  = 24,

    tabBarCss = [[
        background-color: rgba(200, 202, 218, 235);
        border-bottom: 1px solid rgba(0, 0, 0, 0.14);
    ]],
    tabDropTargetBarCss = [[
        background-color: rgba(185, 200, 230, 230);
        border-bottom: 2px solid rgba(50, 100, 220, 0.55);
    ]],
    tabActiveCss = [[
        QLabel {
            background-color: rgba(255, 255, 255, 246);
            border: 1px solid rgba(0, 0, 0, 0.20);
            border-top: 2px solid rgba(55, 110, 230, 0.65);
            border-bottom: none;
            color: rgba(14, 14, 28, 0.95);
            font-size: 11px;
            font-weight: bold;
            padding: 0 4px;
        }
    ]],
    tabInactiveCss = [[
        QLabel {
            background-color: rgba(192, 195, 215, 200);
            border: none;
            border-right: 1px solid rgba(0, 0, 0, 0.10);
            color: rgba(55, 62, 95, 0.88);
            font-size: 11px;
            font-weight: bold;
            padding: 0 4px;
        }
        QLabel::hover {
            background-color: rgba(210, 213, 232, 220);
            color: rgba(18, 22, 50, 0.98);
            border-top: 1px solid rgba(0, 0, 0, 0.15);
        }
    ]],
    tabMovingCss = [[
        QLabel {
            background-color: rgba(200, 70, 70, 220);
            border-right: 1px solid rgba(160, 30, 30, 0.35);
            color: rgba(255, 240, 240, 1.0);
            font-size: 11px;
            font-weight: bold;
            border-bottom: 2px solid rgba(180, 40, 40, 0.85);
            padding: 0 2px;
        }
    ]],
    tabAddBtnCss = [[
        QLabel {
            background-color: rgba(200, 202, 218, 200);
            border-left: 1px solid rgba(0, 0, 0, 0.12);
            color: rgba(80, 88, 118, 0.80);
            font-size: 14px;
            font-weight: bold;
        }
        QLabel::hover {
            background-color: rgba(182, 185, 205, 225);
            color: rgba(25, 30, 60, 0.95);
        }
    ]],
    tabActiveParentCss = [[
        QLabel {
            background-color: rgba(255, 255, 255, 246);
            border: 1px solid rgba(0, 0, 0, 0.20);
            border-top: 2px solid rgba(55, 110, 230, 0.65);
            border-bottom: none;
            color: rgba(14, 14, 28, 0.95);
            font-size: 11px;
            font-weight: bold;
            padding: 0 4px;
        }
    ]],
    subTabBarCss = [[
        background-color: rgba(255, 255, 255, 246);
        border-bottom: 1px solid rgba(0, 0, 0, 0.14);
    ]],

    tabActiveTextColor      = "rgba(14, 14, 28, 0.95)",
    tabInactiveTextColor    = "rgba(55, 62, 95, 0.88)",
    tabMovingTextColor      = "rgba(255, 240, 240, 1.0)",
    tabAddBtnTextColor      = "rgba(80, 88, 118, 0.80)",
    -- Ghost preview shown at insertion point during tab drag / double-click move.
    tabInsertGhostCss = [[
        QLabel {
            background-color: rgba(55, 110, 230, 0.14);
            border: 2px dashed rgba(55, 110, 230, 0.50);
            border-radius: 2px;
        }
    ]],
    tabInsertGhostTextColor = "rgba(30, 70, 190, 0.78)",

    -- ── Profile-level scrollbar skin (applied via setProfileStyleSheet) ───────
    scrollbarCss = [[
        QScrollArea { border: none; background: transparent; }
        QScrollArea > QWidget { background: transparent; }
        QScrollBar:vertical {
            background: rgb(210, 212, 220);
            width: 6px;
            border: none;
            margin: 0;
        }
        QScrollBar::handle:vertical {
            background: rgba(135, 138, 155, 0.60);
            border-radius: 3px;
            min-height: 20px;
        }
        QScrollBar::handle:vertical:hover {
            background: rgba(90, 93, 115, 0.82);
        }
        QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
            height: 0; background: none;
        }
        QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {
            background: transparent;
        }
        QScrollBar:horizontal { height: 0px; border: none; background: transparent; }
    ]],

    -- ── Widget palette (shared by settings, properties, and Mux.ui.buildForm) ──
    ui = {
        textColor        = "rgba(18, 18, 32, 0.95)",
        bg               = "rgb(238, 238, 245)",
        rowOdd           = "rgb(232, 234, 244)",
        rowEven          = "rgb(218, 220, 232)",
        tabActiveBg      = "rgb(210, 212, 226)",
        tabInactiveBg    = "rgb(238, 238, 245)",
        tabHoverBg       = "rgb(218, 220, 235)",
        tabActiveLine    = "rgba(50, 100, 220, 0.8)",
        tabActiveText    = "rgba(14, 14, 28, 0.95)",
        tabInactiveText  = "rgba(60, 65, 90, 0.72)",
        tabHoverText     = "rgba(14, 14, 28, 0.95)",
        descTextColor    = "rgba(65, 75, 115, 0.80)",
        rowDivider       = "rgba(0, 0, 0, 0.13)",
        widgetBg         = "rgb(200, 202, 218)",
        widgetFg         = "rgba(18, 18, 40, 0.90)",
        widgetBorder     = "rgba(0, 0, 0, 0.22)",
        widgetHoverBg    = "rgb(178, 182, 205)",
        inputBg          = "rgb(248, 248, 252)",
        inputFg          = "#1a1a2e",
        inputBorder      = "rgba(0, 0, 0, 0.30)",
        helpIconFg       = "rgba(40, 80, 200, 0.85)",
        helpIconBg       = "rgba(60, 100, 210, 0.14)",
        helpIconBorder   = "rgba(50, 90, 200, 0.35)",
        helpIconHoverBg  = "rgba(60, 100, 210, 0.35)",
        -- Named style slots used by Mux.ui widgets (checkbox, cycler, etc.)
        styles = {
            on   = { bg = "rgb(160, 220, 160)", fg = "#1a5a1a",  border = "rgba(60, 160, 60, 0.6)",   hover = "rgb(140, 200, 140)" },
            off  = { bg = "rgb(240, 200, 200)", fg = "#8b1010",  border = "rgba(180, 60, 60, 0.5)",   hover = "rgb(220, 175, 175)" },
            warn = { bg = "rgb(255, 245, 195)", fg = "rgb(100, 70, 0)", border = "rgba(180, 140, 0, 0.5)", hover = "rgb(240, 225, 160)" },
        },
    },
})
