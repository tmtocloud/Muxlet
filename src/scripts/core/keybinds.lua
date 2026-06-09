-- Muxlet — Keybind registry and hint overlay
--
-- Actual key interception is handled by native Mudlet keybindings in src/keys/.
-- Native keybindings are intercepted before the command line, so printable Alt+key
-- combinations work correctly.
--
-- This module provides:
--   Mux._bindings    — registry of key descriptions shown in the hint overlay
--   Mux.bind()       — register a description entry (no event handler needed)
--   Mux._showHintOverlay()  — Alt+B overlay listing all bindings
--   Mux.listBindings()      — console listing of all bindings

Mux._bindings = Mux._bindings or {}

local function buildKey(mod, key)
    return string.format("%d_%s", mod or 0, key)
end

-- Register a keybind description for the hint overlay.
-- mod/key are kept for display only; no event handler is created here.
function Mux.bind(mod, key, action, description)
    Mux._bindings[buildKey(mod, key)] = { desc = description or "" }
end

function Mux.unbind(mod, key)
    Mux._bindings[buildKey(mod, key)] = nil
end

-- ── Modifier constants (display only) ────────────────────────────────────────
local ALT      = 4
local CTRL     = 2
local SHIFT    = 1
local altShift = ALT + SHIFT

-- ── Binding descriptions — kept in sync with src/keys/Muxlet/ ─────────────

-- Split
Mux.bind(ALT, "Key_Backslash", nil, "split vertically (left|right)  (tmux: prefix+%)")
Mux.bind(ALT, "Key_Minus",     nil, "split horizontally (top|bottom) (tmux: prefix+\")")

-- Navigate
Mux.bind(ALT, "Key_Left",  nil, "focus pane left         (tmux: prefix+←)")
Mux.bind(ALT, "Key_Right", nil, "focus pane right        (tmux: prefix+→)")
Mux.bind(ALT, "Key_Up",    nil, "focus pane up           (tmux: prefix+↑)")
Mux.bind(ALT, "Key_Down",  nil, "focus pane down         (tmux: prefix+↓)")
Mux.bind(ALT, "Key_N",     nil, "next pane               (tmux: prefix+n)")
Mux.bind(ALT, "Key_P",     nil, "previous pane           (tmux: prefix+p)")

-- Pane actions
Mux.bind(ALT, "Key_Z",            nil, "zoom/unzoom pane        (tmux: prefix+z)")
Mux.bind(ALT, "Key_X",            nil, "close pane              (tmux: prefix+x)")
Mux.bind(ALT, "Key_D",            nil, "float / detach pane     (tmux: prefix+d)")
Mux.bind(ALT, "Key_A",            nil, "embed / attach pane")
Mux.bind(ALT, "Key_BracketLeft",  nil, "toggle titlebar          (tmux: prefix+[)")
Mux.bind(ALT, "Key_Comma",        nil, "rename pane prompt       (tmux: prefix+,)")
Mux.bind(ALT, "Key_C",            nil, "new floating pane       (tmux: prefix+c)")

-- PaneSet toggles
Mux.bind(ALT, "Key_L", nil, "toggle left panel")
Mux.bind(ALT, "Key_R", nil, "toggle right panel")
Mux.bind(ALT, "Key_U", nil, "toggle top panel")
Mux.bind(ALT, "Key_J", nil, "toggle bottom panel")

-- Appearance / utility
Mux.bind(ALT, "Key_T",     nil, "cycle theme              (Alt+T)")
Mux.bind(ALT, "Key_S",     nil, "show status")
Mux.bind(ALT, "Key_Slash", nil, "toggle debug output")
Mux.bind(ALT, "Key_B",     nil, "show keybind help        (tmux: prefix+?)")

-- ── Hint overlay (Alt+B) ─────────────────────────────────────────────────────

Mux._hintLabel   = nil
Mux._hintTimerId = nil

function Mux._showHintOverlay()
    local theme  = Mux.activeTheme()
    local sw, sh = getMainWindowSize()

    local kc = theme.hintKeyColor    or "rgba(100,200,255,1.0)"
    local ac = theme.hintActionColor or "rgba(200,210,220,0.85)"
    local fc = theme.hintFooterColor or "rgba(130,145,165,0.50)"

    -- Collect and sort visible entries first so we can size the overlay to fit.
    local entries = {}
    for k, v in pairs(Mux._bindings) do
        if v.desc ~= "" then
            entries[#entries+1] = { key = k, desc = v.desc }
        end
    end
    table.sort(entries, function(a, b) return a.key < b.key end)

    local function fmtKey(k)
        local modS, keyS = k:match("^(%d+)_(.+)$")
        local mod = tonumber(modS) or 0
        local mods = {
            [0]="", [1]="Shift+", [2]="Ctrl+", [4]="Alt+",
            [3]="Ctrl+Shift+", [5]="Alt+Shift+", [6]="Ctrl+Alt+",
        }
        local display = keyS:gsub("^Key_", "")
        return (mods[mod] or tostring(mod) .. "+") .. display
    end

    -- Size the overlay dynamically: each entry row is ~19px; add header + footer room.
    local lineH   = 19
    local ow      = math.min(530, math.floor(sw * 0.88))
    local oh      = math.max(200, math.min(
        math.floor(sh * 0.85),
        50 + #entries * lineH + 30))
    local ox = math.floor((sw - ow) / 2)
    local oy = math.floor((sh - oh) / 2)

    local lines = {
        string.format(
            "<div style='text-align:center;margin-bottom:8px;"
            .. "font-size:13px;color:%s;font-weight:bold;letter-spacing:1px;'>"
            .. "Muxlet Keybinds</div>", kc),
    }
    for _, e in ipairs(entries) do
        lines[#lines+1] = string.format(
            "<div style='margin:1px 0;'>"
            .. "<span style='color:%s;font-weight:bold;min-width:140px;"
            .. "display:inline-block;'>%s</span>"
            .. "&nbsp;&nbsp;<span style='color:%s;'>%s</span></div>",
            kc, fmtKey(e.key), ac, e.desc)
    end
    lines[#lines+1] = string.format(
        "<div style='text-align:center;margin-top:8px;"
        .. "font-size:9px;color:%s;'>click to close</div>", fc)

    local html = table.concat(lines, "\n")

    if Mux._hintLabel then
        Mux._hintLabel:setStyleSheet(theme.hintOverlayCss or "")
        Mux._hintLabel:echo(html)
        moveWindow(Mux._hintLabel.name, ox, oy)
        resizeWindow(Mux._hintLabel.name, ow, oh)
        Mux._hintLabel:show()
        Mux._hintLabel:raiseAll()
    else
        Mux._hintLabel = Geyser.Label:new({
            name="mux_hint_overlay", x=ox, y=oy, width=ow, height=oh, fillBg=1,
        }, Geyser)
        Mux._hintLabel:setStyleSheet(theme.hintOverlayCss or "")
        Mux._hintLabel:echo(html)
        Mux._hintLabel:setClickCallback(function() Mux._hideHintOverlay() end)
    end

    if Mux._hintTimerId then killTimer(Mux._hintTimerId) end
    local timeout = (Mux.settings and Mux.settings.get("mux", "hint_timeout")) or 8
    Mux._hintTimerId = tempTimer(timeout, function() Mux._hideHintOverlay() end)
end

function Mux._hideHintOverlay()
    if Mux._hintLabel then Mux._hintLabel:hide() end
    if Mux._hintTimerId then
        killTimer(Mux._hintTimerId)
        Mux._hintTimerId = nil
    end
end

-- ── Console listing ───────────────────────────────────────────────────────────

function Mux.listBindings()
    local mods = {
        [0]="", [1]="Shift+", [2]="Ctrl+", [4]="Alt+",
        [3]="Ctrl+Shift+", [5]="Alt+Shift+", [6]="Ctrl+Alt+",
    }
    local entries = {}
    for k, v in pairs(Mux._bindings) do
        local modS, keyS = k:match("^(%d+)_(.+)$")
        local mod  = tonumber(modS) or 0
        local disp = (mods[mod] or modS .. "+") .. keyS:gsub("^Key_", "")
        entries[#entries+1] = { disp = disp, desc = v.desc }
    end
    table.sort(entries, function(a, b) return a.disp < b.disp end)

    Mux._echo("\n<cyan>[Muxlet]<reset> Keybindings (press Alt+B for overlay):\n")
    for _, e in ipairs(entries) do
        Mux._echo(string.format("  <white>%-18s<reset> %s\n", e.disp, e.desc))
    end
end

Mux._log("mux_keybinds loaded — %d descriptions", (function()
    local n = 0; for _ in pairs(Mux._bindings) do n = n + 1 end; return n
end)())
