-- Muxlet — Dialog API
--
-- Mux.createDialog(opts) is the recommended way to build floating popup windows
-- in Muxlet.  A dialog is a permanentFloat MuxPane: it hovers above all embedded
-- workspace panes, cannot be dragged into a split, and carries the theme's system-
-- accent border so users immediately recognise it as a transient system overlay.
--
-- ── Why use this instead of Adjustable.Container or raw Geyser widgets? ────────
--
--   • Zero CSS for the chrome.  Frame, background, border, and titlebar styling
--     all come from the active Mux theme and update automatically when the user
--     switches themes.
--   • Consistent drag behaviour.  Users move the dialog by dragging its titlebar,
--     exactly like any other Mux pane — same cursor feedback, same feel.
--   • Z-order is automatic.  Mux.raiseFloatingPanes() keeps every dialog on top
--     of workspace panes; no manual raise() calls needed after widget updates.
--   • A working × close button is built in.  Wire cleanup logic via pane.onClose.
--   • Widgets live in pane.content — the same Geyser.Container used everywhere
--     else in Muxlet.  No special API to learn; the docs you already know apply.
--
-- ── Quick start ──────────────────────────────────────────────────────────────────
--
--   local d = Mux.createDialog({
--       title  = "Apply Workspace?",
--       width  = 480,
--       height = 220,
--   })
--
--   local body = Geyser.Label:new({
--       name = "my_dialog_body", x = "4%", y = 14, width = "92%", height = 50,
--   }, d.content)
--   body:setStyleSheet(Mux.dialogCss.body)
--   body:echo("Apply the recommended fed2-tools workspace?")
--
--   local btnYes = Geyser.Label:new({
--       name = "my_dialog_yes", x = "10%", y = 150, width = "35%", height = 34,
--   }, d.content)
--   btnYes:setStyleSheet(Mux.dialogCss.buttonPrimary)
--   btnYes:echo("<center>Yes, Apply</center>")
--   btnYes:setClickCallback(function()
--       do_the_thing()
--       d:close()
--   end)
--
--   local btnNo = Geyser.Label:new({
--       name = "my_dialog_no", x = "55%", y = 150, width = "35%", height = 34,
--   }, d.content)
--   btnNo:setStyleSheet(Mux.dialogCss.button)
--   btnNo:echo("<center>Skip</center>")
--   btnNo:setClickCallback(function() d:close() end)
--
-- ── CSS helpers ──────────────────────────────────────────────────────────────────
--
--   Mux.dialogCss.body           body-text label (light blue-white)
--   Mux.dialogCss.subtext        secondary / caption label (muted blue)
--   Mux.dialogCss.divider        1px horizontal rule — use on a height=1 Label
--   Mux.dialogCss.button         neutral action button
--   Mux.dialogCss.buttonPrimary  affirmative / "yes" button (green tint)
--   Mux.dialogCss.buttonDanger   destructive action button (red tint)
--
-- Pass any entry directly to label:setStyleSheet(css).  The colours match
-- Muxlet's built-in dialogs so custom popups look at home alongside them.
-- All entries are fixed dark-palette values that read well in both themes.
--
-- ── Interaction model ────────────────────────────────────────────────────────────
--
-- Three meaningful states control how much the user can manipulate a dialog:
--
--   Default (no extra opts)   — moveable, fixed size.  The user drags the titlebar
--                               to reposition but cannot resize.  Right for most popups.
--
--   opts.locked = true        — fully locked.  Neither movement nor resizing is
--                               possible.  The × close button still works if
--                               opts.closeable is not false.  Right for modal-style
--                               confirmations where accidental repositioning would
--                               confuse the user.
--
--   opts.resizable = true     — moveable and resizable.  Right for content that
--                               can reflow (e.g. a scrollable log viewer).
--
-- ── Advanced positioning ─────────────────────────────────────────────────────────
--
-- Omit opts.x / opts.y to center the dialog in the main window (default).
-- Supply them in pixels to anchor the dialog relative to a button or pane:
--
--   local bx = somePane.floatX + somePane.floatW + 8
--   local by = somePane.floatY
--   local d  = Mux.createDialog({ title="…", width=300, height=200, x=bx, y=by })

-- ── Shared CSS palette ────────────────────────────────────────────────────────

Mux.dialogCss = {
    body = [[
        background: transparent;
        color: rgba(198,210,238,255);
        font-size: 13px;
        padding: 0 14px;
    ]],

    subtext = [[
        background: transparent;
        color: rgba(105,125,180,255);
        font-size: 11px;
        padding: 0 14px;
    ]],

    -- Apply to a Label with height=1 to draw a horizontal rule.
    divider = "background-color: rgba(255,255,255,0.10); border: none;",

    button = [[
        QLabel {
            background-color: rgba(36,40,62,230);
            color: rgba(178,190,225,255);
            border: 1px solid rgba(85,98,140,210);
            border-radius: 5px;
            font-size: 12px; font-weight: bold;
            qproperty-alignment: AlignCenter;
        }
        QLabel::hover {
            background-color: rgba(52,60,95,245);
            border-color: rgba(105,158,255,210);
            color: white;
        }
    ]],

    buttonPrimary = [[
        QLabel {
            background-color: rgba(18,58,34,240);
            color: rgba(115,222,148,255);
            border: 1px solid rgba(48,152,78,215);
            border-radius: 5px;
            font-size: 12px; font-weight: bold;
            qproperty-alignment: AlignCenter;
        }
        QLabel::hover {
            background-color: rgba(26,82,46,255);
            border-color: rgba(65,210,108,235);
            color: rgba(178,255,200,255);
        }
    ]],

    buttonDanger = [[
        QLabel {
            background-color: rgba(52,18,18,230);
            color: rgba(210,120,115,255);
            border: 1px solid rgba(140,48,48,200);
            border-radius: 5px;
            font-size: 12px; font-weight: bold;
            qproperty-alignment: AlignCenter;
        }
        QLabel::hover {
            background-color: rgba(82,22,22,245);
            border-color: rgba(200,70,68,220);
            color: rgba(255,160,155,255);
        }
    ]],
}

-- ── Mux.createDialog ─────────────────────────────────────────────────────────

--- Creates and returns a permanentFloat MuxPane for use as a dialog popup.
--
-- @param  opts.title     string   titlebar label (default: "Dialog")
-- @param  opts.width     number   pixel width    (default: 440)
-- @param  opts.height    number   pixel height   (default: 280)
-- @param  opts.x         number   left edge px   (default: centered)
-- @param  opts.y         number   top  edge px   (default: centered)
-- @param  opts.resizable boolean  resize handles (default: false)
-- @param  opts.locked    boolean  block drag movement (default: false)
-- @param  opts.id        string   custom pane id (default: auto "dialog_N")
-- @return MuxPane  add widgets to pane.content; dismiss with pane:close()
function Mux.createDialog(opts)
    opts = opts or {}
    local w  = opts.width  or 440
    local h  = opts.height or 280
    local sw, sh = getMainWindowSize()
    local x  = opts.x or math.floor((sw - w) / 2)
    local y  = opts.y or math.floor((sh - h) / 2)

    local pane = MuxPane:new({
        id               = opts.id or Mux._newId("dialog"),
        name             = opts.title or "Dialog",
        x = x, y = y, width = w, height = h,
        parent           = Geyser,
        permanentFloat   = true,
        zoomable         = false,
        splittable       = false,
        swappable        = false,
        noResize         = opts.resizable and false or true,
        noTitlebarToggle = opts.noTitlebarToggle ~= false,
        noRename         = opts.noRename ~= false,
        noContent        = opts.noContent ~= false,
        noTabs           = opts.noTabs ~= false,
        noContextMenu    = opts.noContextMenu ~= false,
        closeable        = opts.closeable ~= false,
    })
    if opts.locked then pane.locked = true end
    pane.floatX = x
    pane.floatY = y
    pane.floatW = w
    pane.floatH = h
    pane:_detachToFloat()
    Mux.raiseFloatingPanes()
    Mux._log("Mux.createDialog: '%s' (%dx%d at %d,%d)", pane.name, w, h, x, y)
    return pane
end

Mux._log("mux_dialog loaded")
