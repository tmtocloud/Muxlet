-- Muxlet — Connection state overlays
--
-- Connection awareness is built from ordinary rules, not a special toggle. The
-- built-in "Connecting" / "Disconnected" conditions pair with the overlay actions
-- registered here (mux.overlay.{connecting,disconnected}.{show,hide}) so a user can
-- wire, per pane or tab:
--   When Disconnected → Do: Show "Disconnected" overlay, Else: Hide "Disconnected"
--   When Connecting   → Do: Show "Connecting" overlay,   Else: Hide "Connecting"
--
-- API:
--   Mux.setConnectionState("connected"|"disconnected"|"connecting")
--   pane:_showStateOverlay(key,state) / _hideStateOverlay(key)
--   surface:_showTabStateOverlay(tab,key,state) / _hideTabStateOverlay(tab,key)
--
-- The overlay is a Geyser.Label sibling of the content container; showing it hides
-- content and shows the label, and it's keyed so each rule's Else only clears its
-- own state's overlay. No z-order tricks are involved.

-- ── Global state ──────────────────────────────────────────────────────────────
-- Connection awareness keeps no registry of its own: connection-aware panes/tabs
-- carry a rule (connection_state → connection screen) and are tracked by the
-- generic rule engine like any other reactive subject.

-- Determine initial state synchronously from Mudlet's connection status.
-- Default to "connected" when isConnected() is unavailable so that profiles
-- which load while already connected do not flash the disconnected screen.
if isConnected ~= nil then
    Mux._connState = isConnected() and "connected" or "disconnected"
else
    Mux._connState = "connected"
end

-- ── HTML builder ──────────────────────────────────────────────────────────────

function Mux._connScreenHtml(state)
    local theme = Mux.activeTheme()
    local icon, iconColor, title, titleColor
    if state == "connecting" then
        icon       = "⟳"
        iconColor  = theme.connScreenConnectingIconColor  or "rgba(40,110,140,210)"
        title      = "CONNECTING…"
        titleColor = theme.connScreenConnectingTitleColor or "rgba(55,140,165,225)"
    else
        icon       = "⊘"
        iconColor  = theme.connScreenDisconnectedIconColor  or "rgba(150,50,50,210)"
        title      = "DISCONNECTED"
        titleColor = theme.connScreenDisconnectedTitleColor or "rgba(185,70,70,225)"
    end
    return string.format(
        "<div style='text-align:center;padding-top:22%%;'>"
        .. "<span style='font-size:22pt;font-family:Consolas,Monaco,monospace;color:%s;'>%s</span>"
        .. "<br/><br/>"
        .. "<span style='font-size:11pt;font-family:Consolas,Monaco,monospace;color:%s;'>%s</span>"
        .. "</div>",
        iconColor, icon, titleColor, title)
end

-- ── Pane-level connection screen ──────────────────────────────────────────────
-- _connScreen lives in pane.outer as a sibling of pane.content.
-- It matches content's geometry exactly and is toggled exclusively with it.
--
-- borderInset must match the module-level constant in pane.lua (currently 2).
local _paneInset = 2

function MuxPane:_buildConnScreen()
    if self._connScreen then return end
    local theme    = Mux.activeTheme()
    local bi       = _paneInset
    local hdrH     = self.titlebarVisible and theme.titlebarHeight or 0
    local contentY = bi + hdrH
    self._connScreen = Geyser.Label:new({
        name   = self._gid .. "_conn",
        x      = Mux._toPx(bi),
        y      = Mux._toPx(contentY),
        width  = Mux._fromEdgePx(bi),
        height = Mux._fromEdgePx(bi),
        fillBg = 1,
    }, self.outer)
    self._connScreen:setStyleSheet(
        theme.connScreenBg or "background-color:rgba(8,8,14,250);border:none;")
    self._connScreen:hide()
end

-- Sync _connScreen position/size after titlebar show/hide (called from pane.lua).
function MuxPane:_syncConnScreenGeometry()
    if not self._connScreen then return end
    local theme    = Mux.activeTheme()
    local bi       = _paneInset
    local hdrH     = self.titlebarVisible and theme.titlebarHeight or 0
    local contentY = bi + hdrH
    self._connScreen:move(Mux._toPx(bi), Mux._toPx(contentY))
    self._connScreen:resize(Mux._fromEdgePx(bi), Mux._fromEdgePx(bi))
    self._connScreen:reposition()
end

function MuxPane:_showConnScreen(state)
    if not self._connScreen then self:_buildConnScreen() end
    local theme = Mux.activeTheme()
    self._connScreen:setStyleSheet(
        theme.connScreenBg or "background-color:rgba(8,8,14,250);border:none;")
    self._connScreen:echo(Mux._connScreenHtml(state))
    self.content:hide()
    self._connScreen:show()
    Mux.raiseFloatingPanes()
end

function MuxPane:_hideConnScreen()
    if not self._connScreen then return end
    self._connScreen:hide()
    -- Only restore content when the pane is not minimized (minimize also hides content).
    if not self.minimized then
        self.content:show()
    end
end

-- Called from applyTheme in pane.lua to keep colours in sync.
function MuxPane:_refreshConnScreen()
    if not self._connScreen then return end
    local theme = Mux.activeTheme()
    self._connScreen:setStyleSheet(
        theme.connScreenBg or "background-color:rgba(8,8,14,250);border:none;")
    if Mux._connState ~= "connected" then
        self._connScreen:echo(Mux._connScreenHtml(Mux._connState))
    end
end

-- Called from toggleMinimize in pane.lua after content:show() on restore.
-- Re-hides content and re-shows the conn screen if we are still disconnected.
function MuxPane:_onRestoreContent()
    if self._connectionAware and Mux._connState ~= "connected" then
        self.content:hide()
        if self._connScreen then self._connScreen:show() end
    end
end

-- ── Tab-level connection screen ───────────────────────────────────────────────
-- Each tab gets its own _connScreen inside _tabViewport, sibling of tab.content.
-- Only the active tab's conn screen is ever visible at one time.

function MuxSurface:_buildTabConnScreen(tab)
    if tab._connScreen then return end
    if not self._tabViewport then return end
    local theme = Mux.activeTheme()
    tab._connScreen = Geyser.Label:new({
        name   = self._gid .. "_tconn_" .. tab.id,
        x      = "0%", y = "0%", width = "100%", height = "100%",
        fillBg = 1,
    }, self._tabViewport)
    tab._connScreen:setStyleSheet(
        theme.connScreenBg or "background-color:rgba(8,8,14,250);border:none;")
    tab._connScreen:hide()
end

-- Show conn screen for a tab (only when that tab is currently active).
function MuxSurface:_showTabConnScreen(tab, state)
    if not self._tabViewport then return end
    if not tab._connScreen then self:_buildTabConnScreen(tab) end
    if not tab._connScreen then return end
    local theme = Mux.activeTheme()
    tab._connScreen:setStyleSheet(
        theme.connScreenBg or "background-color:rgba(8,8,14,250);border:none;")
    tab._connScreen:echo(Mux._connScreenHtml(state))
    if self._activeTabId == tab.id then
        tab.content:hide()
        tab._connScreen:show()
        Mux.raiseFloatingPanes()
    end
end

-- Hide a tab's conn screen and restore its content if the tab is active.
function MuxSurface:_hideTabConnScreen(tab)
    if not tab._connScreen then return end
    tab._connScreen:hide()
    if self._activeTabId == tab.id then
        tab.content:show()
    end
end

-- Called from _applyTabTheme in tabs.lua to keep colours in sync.
function MuxSurface:_refreshTabConnScreen(tab)
    if not tab._connScreen then return end
    local theme = Mux.activeTheme()
    tab._connScreen:setStyleSheet(
        theme.connScreenBg or "background-color:rgba(8,8,14,250);border:none;")
    if tab._connectionAware and Mux._connState ~= "connected" and self._activeTabId == tab.id then
        tab._connScreen:echo(Mux._connScreenHtml(Mux._connState))
    end
end

-- ── Overlay actions (Connection group) ────────────────────────────────────────
-- Plain actions that show/hide a keyed state overlay on the pane/tab, paired with
-- the built-in "Connecting"/"Disconnected" conditions. Build awareness with rules:
--   When Disconnected → Do: Show "Disconnected" overlay, Else: Hide "Disconnected"
--   When Connecting   → Do: Show "Connecting" overlay,   Else: Hide "Connecting"
-- The overlay is keyed so each rule's Else only hides ITS overlay (the states are
-- mutually exclusive, so exactly one shows at a time; connected hides both).

function MuxPane:_showStateOverlay(key, state)
    self._overlayKey = key
    self:_showConnScreen(state)
end
function MuxPane:_hideStateOverlay(key)
    if self._overlayKey and self._overlayKey ~= key then return end   -- another state owns it
    self._overlayKey = nil
    self:_hideConnScreen()
end
function MuxSurface:_showTabStateOverlay(tab, key, state)
    tab._overlayKey = key
    self:_showTabConnScreen(tab, state)
end
function MuxSurface:_hideTabStateOverlay(tab, key)
    if tab._overlayKey and tab._overlayKey ~= key then return end
    tab._overlayKey = nil
    self:_hideTabConnScreen(tab)
end

if Mux.registerAction then
    local function runOverlay(ctx, key, state, show)
        if not ctx then return end
        if ctx.tab and ctx.pane then
            if show then ctx.pane:_showTabStateOverlay(ctx.tab, key, state)
            else ctx.pane:_hideTabStateOverlay(ctx.tab, key) end
        elseif ctx.pane then
            if show then ctx.pane:_showStateOverlay(key, state)
            else ctx.pane:_hideStateOverlay(key) end
        end
    end
    Mux.registerAction("mux.overlay.disconnected.show", { name = "Show “Disconnected” overlay", group = "Connection", icon = "⊘",
        desc = "Cover this pane/tab with the disconnected screen.",
        run = function(ctx) runOverlay(ctx, "disconnected", "disconnected", true) end })
    Mux.registerAction("mux.overlay.disconnected.hide", { name = "Hide “Disconnected” overlay", group = "Connection", icon = "⊘",
        desc = "Remove the disconnected overlay.",
        run = function(ctx) runOverlay(ctx, "disconnected", "disconnected", false) end })
    Mux.registerAction("mux.overlay.connecting.show", { name = "Show “Connecting” overlay", group = "Connection", icon = "⟳",
        desc = "Cover this pane/tab with the connecting screen.",
        run = function(ctx) runOverlay(ctx, "connecting", "connecting", true) end })
    Mux.registerAction("mux.overlay.connecting.hide", { name = "Hide “Connecting” overlay", group = "Connection", icon = "⟳",
        desc = "Remove the connecting overlay.",
        run = function(ctx) runOverlay(ctx, "connecting", "connecting", false) end })
end

-- ── State propagation ─────────────────────────────────────────────────────────
-- A state change is just a signal: bump the engine and let every rule whose
-- condition watches connection state re-fire. Because the engine re-fires on value
-- change (not only boolean edges), disconnected→connecting→connected each repaint.

function Mux.setConnectionState(state)
    if Mux._connState == state then return end
    if state == "connected" and Mux._connReadyTimer then
        killTimer(Mux._connReadyTimer)
        Mux._connReadyTimer = nil
    end
    Mux._connState = state
    if Mux.evaluateAllRules then Mux.evaluateAllRules(false) end
end

-- ── Extend _activateTabObj for connection-aware tabs ─────────────────────────
-- Wrap the original function (defined in tabs.lua) so tab switches respect the
-- current connection state without modifying tabs.lua.

local _origActivateTabObj = MuxSurface._activateTabObj

function MuxSurface:_activateTabObj(tab)
    -- Before switching: hide the previous tab's conn screen if it was showing.
    if self._activeTabId and self._activeTabId ~= tab.id then
        local cur = self:_findTab(self._activeTabId)
        if cur and cur._connScreen then
            cur._connScreen:hide()
        end
    end

    -- Run the original activation (updates label styles, hides old content, sets _activeTabId).
    _origActivateTabObj(self, tab)

    -- Rules only re-fire on signal changes, not tab switches; re-evaluate the newly
    -- active tab's rules so any state-overlay (e.g. a Disconnected/Connecting overlay
    -- rule) repaints for the tab now on screen.
    if Mux._evaluateRules and tab.rules and #tab.rules > 0 then
        Mux._evaluateRules(tab, true)
    end
end

-- ── Mudlet event handlers ─────────────────────────────────────────────────────
--
-- sysConnectionEvent (TCP socket open) → "connecting"  shows ⟳
-- sysProtocolEnabled with "GMCP"       → "connected"   hides overlay
--   GMCP negotiation completes within milliseconds of TCP connect on any
--   GMCP-capable game, so this is effectively instant for modern MUDs.
-- sysDisconnectionEvent                → "disconnected" shows ⊘
--
-- For non-GMCP games, application code should call
-- Mux.setConnectionState("connected") when the game is ready.
-- _connReadyDelay (default 30s) is a last-resort fallback for those cases.

Mux._connReadyDelay = Mux._connReadyDelay or 30

local function _cancelConnReady()
    if Mux._connReadyTimer then
        killTimer(Mux._connReadyTimer)
        Mux._connReadyTimer = nil
    end
end

if not Mux._connHandlerConn then
    Mux._connHandlerConn = registerAnonymousEventHandler(
        "sysConnectionEvent",
        function()
            _cancelConnReady()
            Mux.setConnectionState("connecting")
            if Mux._connReadyDelay and Mux._connReadyDelay > 0 then
                Mux._connReadyTimer = tempTimer(Mux._connReadyDelay, function()
                    Mux._connReadyTimer = nil
                    if Mux._connState == "connecting" then
                        Mux.setConnectionState("connected")
                    end
                end)
            end
        end
    )
end

if not Mux._connHandlerGmcp then
    Mux._connHandlerGmcp = registerAnonymousEventHandler(
        "sysProtocolEnabled",
        function(_, protocol)
            if protocol == "GMCP" and Mux._connState == "connecting" then
                Mux.setConnectionState("connected")
            end
        end
    )
end

if not Mux._connHandlerDisc then
    Mux._connHandlerDisc = registerAnonymousEventHandler(
        "sysDisconnectionEvent",
        function()
            _cancelConnReady()
            Mux.setConnectionState("disconnected")
        end
    )
end

Mux._log("mux_connection loaded")