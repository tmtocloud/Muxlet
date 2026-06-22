-- Muxlet — Dialog API
--
-- Mux.createDialog(opts) is the recommended way to build floating popup windows
-- in Muxlet.  A dialog is an overlay MuxPane: it hovers above all embedded
-- workspace panes, cannot be dragged into a split, and carries the theme's system-
-- accent border so users immediately recognise it as a transient overlay.
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

    -- Hover-state CSS for setOnEnter/setOnLeave (QLabel::hover doesn't fire in Mudlet).
    buttonHover = [[
        background-color: rgba(52,60,95,245);
        color: white;
        border: 1px solid rgba(105,158,255,210);
        border-radius: 5px;
        font-size: 12px; font-weight: bold;
        qproperty-alignment: AlignCenter;
    ]],
    buttonDangerHover = [[
        background-color: rgba(82,22,22,245);
        color: rgba(255,160,155,255);
        border: 1px solid rgba(200,70,68,220);
        border-radius: 5px;
        font-size: 12px; font-weight: bold;
        qproperty-alignment: AlignCenter;
    ]],
    buttonPrimaryHover = [[
        background-color: rgba(26,82,46,255);
        color: rgba(178,255,200,255);
        border: 1px solid rgba(65,210,108,235);
        border-radius: 5px;
        font-size: 12px; font-weight: bold;
        qproperty-alignment: AlignCenter;
    ]],
}

-- ── Mux.wireDialogButton ─────────────────────────────────────────────────────

--- Wires hover-highlight on a dialog button via setOnEnter/setOnLeave.
-- Only the stylesheet changes on hover — button content is never altered.
-- @param btn        Geyser.Label  the button widget
-- @param normalCss  string        CSS for idle state (e.g. Mux.dialogCss.button)
-- @param hoverCss   string        CSS for hovered state (e.g. Mux.dialogCss.buttonHover)
function Mux.wireDialogButton(btn, normalCss, hoverCss)
    btn:setOnEnter(function() btn:setStyleSheet(hoverCss) end)
    btn:setOnLeave(function() btn:setStyleSheet(normalCss) end)
end

-- ── MuxDialog ────────────────────────────────────────────────────────────────
--
-- A dialog is a specialized MuxPane: a closeable overlay that floats above the
-- workspace, never participates in splits or PaneSpaces, and isn't serialized.
-- MuxDialog rhymes with the other primitives (MuxPane / MuxSplit / MuxPaneSpace):
-- it inherits everything from MuxPane and only layers on dialog defaults,
-- cascade positioning, and the initial raise. Because an instance *is* a
-- MuxPane, every pane method (content, close, setName, …) works unchanged, and
-- Mux.createDialog(opts) is kept as the ergonomic verb that builds one.

MuxDialog = Mux._class(MuxPane)

-- Registry of singleton dialogs, keyed by the caller's `singleton` string. A
-- dialog created with a singleton key that's already live is never duplicated —
-- the existing one is raised instead. Entries are cleared in MuxPane:close.
Mux._singletonDialogs = Mux._singletonDialogs or {}

-- Returns the live dialog registered under `key`, or nil. Guards against stale
-- entries whose pane has already been closed.
function Mux.getDialog(key)
    local d = key and Mux._singletonDialogs[key]
    if d and Mux._panes[d.id] then return d end
    Mux._singletonDialogs[key or ""] = nil
    return nil
end

-- Picks a top-left corner for a new dialog. When the caller doesn't specify a
-- position, dialogs would otherwise all open dead-center and stack on top of
-- each other. Instead, cascade diagonally by SLOT INDEX: each open dialog claims
-- the slot index equal to its own offset-from-centre in `step` units, and the
-- new dialog takes the first free index. Indexing by offset-from-own-centre
-- (rather than absolute position) makes the cascade size-independent, so a tab
-- Properties dialog tiles off an open pane Properties dialog even though they're
-- different heights. Off-diagonal (explicitly-positioned) dialogs are ignored,
-- and closing a dialog frees its slot for reuse.
local function _dialogCascadePos(w, h, sw, sh)
    local baseX = math.floor((sw - w) / 2)
    local baseY = math.floor((sh - h) / 2)
    local step, maxSteps = 30, 12

    local taken = {}
    for _, p in pairs(Mux._panes) do
        if p._dialog and p.outer then
            local pw, ph = p.outer:get_width(), p.outer:get_height()
            local pcx    = math.floor((sw - pw) / 2)
            local pcy    = math.floor((sh - ph) / 2)
            local idxX   = math.floor((p.outer:get_x() - pcx) / step + 0.5)
            local idxY   = math.floor((p.outer:get_y() - pcy) / step + 0.5)
            if idxX == idxY and idxX >= 0 then taken[idxX] = true end  -- on the cascade diagonal
        end
    end

    local k = 0
    while taken[k] and k < maxSteps do k = k + 1 end

    local x = Mux._clamp(baseX + k * step, 0, math.max(0, sw - w))
    local y = Mux._clamp(baseY + k * step, 0, math.max(0, sh - h))
    return x, y
end

--- Constructs the dialog. Called by MuxDialog:new(opts) via Mux._class.
--
-- @param  opts.title     string   titlebar label (default: "Dialog")
-- @param  opts.width     number   pixel width    (default: 440)
-- @param  opts.height    number   pixel height   (default: 280)
-- @param  opts.x         number   left edge px   (default: centered, cascaded)
-- @param  opts.y         number   top  edge px   (default: centered, cascaded)
-- @param  opts.resizable boolean  resize handles (default: false)
-- @param  opts.id        string   custom pane id (default: auto "dialog_N")
function MuxDialog:init(opts)
    opts = opts or {}
    local w = opts.width  or 440
    local h = opts.height or 280
    local sw, sh = getMainWindowSize()

    -- Explicit x or y is honoured verbatim (callers restoring a remembered
    -- position). With neither given, cascade off any dialogs already open.
    local x, y
    if opts.x or opts.y then
        x = opts.x or math.floor((sw - w) / 2)
        y = opts.y or math.floor((sh - h) / 2)
    else
        x, y = _dialogCascadePos(w, h, sw, sh)
    end

    -- Build the underlying pane with dialog defaults.
    MuxPane.init(self, {
        id               = opts.id or Mux._newId("dialog"),
        name             = opts.title or "Dialog",
        x = x, y = y, width = w, height = h,
        parent           = Geyser,
        overlay          = true,
        zoomable         = false,
        splittable       = false,
        swappable        = false,
        resizable        = opts.resizable or false,
        titlebarHideable = opts.titlebarHideable or false,
        renamable        = opts.renamable or false,
        contentable      = opts.contentable or false,
        tabsLocked       = opts.tabsLocked or false,
        contextMenu      = opts.contextMenu or false,
        closeable        = opts.closeable ~= false,
        convertible      = opts.convertible or false,
        minimizable      = opts.minimizable or false,
    })

    self._dialog = true   -- marks this pane for dialog cascade bookkeeping
    if opts.singleton then
        self._singletonKey = opts.singleton
        Mux._singletonDialogs[opts.singleton] = self
    end
    self.floatX, self.floatY = x, y
    self.floatW, self.floatH = w, h
    self:_detachToFloat()
    -- Give the new dialog the top z-sequence so raiseFloatingPanes puts it above
    -- any already-open dialog (rather than below, per pairs() ordering).
    Mux._raiseSeq = (Mux._raiseSeq or 0) + 1
    self._raiseSeq = Mux._raiseSeq
    Mux.raiseFloatingPanes()
    -- Deferred second raise forces Qt to repaint border labels that may have
    -- been occluded by a pre-existing pane during the initial layout pass.
    tempTimer(0, function()
        if self and self.outer then
            self.outer:reposition()
            Mux.raiseFloatingPanes()
        end
    end)
    Mux._log("MuxDialog: '%s' (%dx%d at %d,%d)", self.name, w, h, x, y)
end

--- Creates and returns a dialog overlay. The ergonomic verb wrapping
--- MuxDialog:new — preferred in calling code, and what existing callers use.
-- @return MuxDialog  add widgets to dialog.content; dismiss with dialog:close()
function Mux.createDialog(opts)
    opts = opts or {}
    if opts.singleton then
        local existing = Mux.getDialog(opts.singleton)
        if existing then
            existing:show()
            existing:raise()
            return existing
        end
    end
    return MuxDialog:new(opts)
end

Mux._log("mux_dialog loaded")