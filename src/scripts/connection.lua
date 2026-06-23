-- Muxlet — Connection Awareness
--
-- Panes and tabs can opt in to displaying a "disconnected" or "connecting"
-- screen when the Mudlet client is in those states.  Default behavior is
-- unchanged for all panes and tabs.
--
-- API:
--   pane:setConnectionAware(true|false)           -- whole pane content area
--   pane:setTabConnectionAware(tabId, true|false) -- one specific tab
--   Mux.setConnectionState("connected"|"disconnected"|"connecting")
--
-- The screen is implemented as a Geyser.Label sibling of the content
-- container, never overlaid on top of it.  Activating the screen hides
-- content entirely and shows the label; deactivating reverses the swap.
-- No z-order tricks are involved.

-- ── Global state ──────────────────────────────────────────────────────────────

-- Registry of connection-aware objects.
-- key → { kind = "pane"|"tab", obj, pane (tab only) }
Mux._connAware = Mux._connAware or {}

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
    local hdrH     = self.titlebarVisible
        and theme.titlebarHeight
        or  theme.revealStripHeight
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
    local hdrH     = self.titlebarVisible
        and theme.titlebarHeight
        or  theme.revealStripHeight
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

-- ── Public opt-in API ─────────────────────────────────────────────────────────

-- Connection awareness reframed as a condition/action pair (see conditional.lua):
-- a connection-aware pane carries condition = "disconnected" with these two
-- actions, so the engine shows the screen while not connected and hides it once
-- connected. They're registered into the normal action registry so they're also
-- selectable/overridable from the pane's Rules properties.
if Mux.registerAction then
    Mux.registerAction("mux.connScreen.show", {
        name = "Show connection screen", group = "muxlet", icon = "⊘",
        desc = "Cover the pane with the disconnected/connecting screen.",
        run  = function(ctx)
            if ctx and ctx.pane and ctx.pane._showConnScreen then
                ctx.pane:_showConnScreen(Mux._connState)
            end
        end,
    })
    Mux.registerAction("mux.connScreen.hide", {
        name = "Hide connection screen", group = "muxlet", icon = "✓",
        desc = "Remove the connection screen and reveal the pane content.",
        run  = function(ctx)
            if ctx and ctx.pane and ctx.pane._hideConnScreen then ctx.pane:_hideConnScreen() end
        end,
    })
end

function MuxPane:setConnectionAware(enabled)
    enabled = (enabled ~= false)
    self._connectionAware = enabled
    if enabled then
        -- Suppress any tab-level screens — the pane screen covers everything.
        for _, tab in ipairs(self._tabs or {}) do
            if tab._connScreen then tab._connScreen:hide() end
        end
        -- Drive the screen through the condition engine: visible while disconnected.
        self.actionTrue    = "mux.connScreen.show"
        self.actionFalse   = "mux.connScreen.hide"
        self._conditionMet = nil
        self:setCondition({ type = "disconnected" })
    else
        self:setCondition(nil)
        self.actionTrue  = "mux.showSelf"
        self.actionFalse = "mux.hideSelf"
        self:_hideConnScreen()
        -- Restore tab-level screens for enrolled tabs if still disconnected.
        if Mux._connState ~= "connected" then
            for _, entry in pairs(Mux._connAware) do
                if entry.kind == "tab" and entry.pane == self then
                    self:_showTabConnScreen(entry.obj, Mux._connState)
                end
            end
        end
    end
end

function MuxSurface:setTabConnectionAware(tabId, enabled)
    if not self._tabsEnabled then return end
    local tab = self:_findTab(tabId)
    if not tab then return end
    enabled = (enabled ~= false)
    tab._connectionAware = enabled
    local key = "tab_" .. self.id .. "_" .. tab.id
    if enabled then
        Mux._connAware[key] = { kind = "tab", obj = tab, pane = self }
        if Mux._connState ~= "connected" and not self._connectionAware then
            self:_showTabConnScreen(tab, Mux._connState)
        end
    else
        Mux._connAware[key] = nil
        self:_hideTabConnScreen(tab)
    end
end

-- ── State propagation ─────────────────────────────────────────────────────────

function Mux.setConnectionState(state)
    if Mux._connState == state then return end
    if state == "connected" and Mux._connReadyTimer then
        killTimer(Mux._connReadyTimer)
        Mux._connReadyTimer = nil
    end
    Mux._connState = state
    for _, entry in pairs(Mux._connAware) do
        if entry.kind == "pane" then
            if state == "connected" then
                entry.obj:_hideConnScreen()
            else
                entry.obj:_showConnScreen(state)
            end
        elseif entry.kind == "tab" then
            -- Pane-level awareness takes precedence; tab screens stay hidden.
            if not entry.pane._connectionAware then
                if state == "connected" then
                    entry.pane:_hideTabConnScreen(entry.obj)
                else
                    entry.pane:_showTabConnScreen(entry.obj, state)
                end
            end
        end
    end
    -- Connection-aware panes are now driven by the condition engine (an inline
    -- "disconnected" spec). Re-evaluate on every state change so transitions that
    -- arrive without a Mudlet event (e.g. the connect-ready delay timer) still
    -- toggle their screens.
    if Mux.evaluateAllPaneConditions then Mux.evaluateAllPaneConditions() end
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

    -- After switch: show tab screen only when tab is enrolled and pane-level is not active.
    if tab._connectionAware and not self._connectionAware and Mux._connState ~= "connected" then
        tab.content:hide()
        self:_showTabConnScreen(tab, Mux._connState)
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