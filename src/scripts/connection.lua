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

function MuxPane:_buildTabConnScreen(tab)
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
function MuxPane:_showTabConnScreen(tab, state)
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
    end
end

-- Hide a tab's conn screen and restore its content if the tab is active.
function MuxPane:_hideTabConnScreen(tab)
    if not tab._connScreen then return end
    tab._connScreen:hide()
    if self._activeTabId == tab.id then
        tab.content:show()
    end
end

-- Called from _applyTabTheme in tabs.lua to keep colours in sync.
function MuxPane:_refreshTabConnScreen(tab)
    if not tab._connScreen then return end
    local theme = Mux.activeTheme()
    tab._connScreen:setStyleSheet(
        theme.connScreenBg or "background-color:rgba(8,8,14,250);border:none;")
    if tab._connectionAware and Mux._connState ~= "connected" and self._activeTabId == tab.id then
        tab._connScreen:echo(Mux._connScreenHtml(Mux._connState))
    end
end

-- ── Public opt-in API ─────────────────────────────────────────────────────────

function MuxPane:setConnectionAware(enabled)
    enabled = (enabled ~= false)
    self._connectionAware = enabled
    local key = "pane_" .. self.id
    if enabled then
        Mux._connAware[key] = { kind = "pane", obj = self }
        if Mux._connState ~= "connected" then
            self:_showConnScreen(Mux._connState)
        end
    else
        Mux._connAware[key] = nil
        self:_hideConnScreen()
    end
end

function MuxPane:setTabConnectionAware(tabId, enabled)
    if not self._tabsEnabled then return end
    local tab = self:_findTab(tabId)
    if not tab then return end
    enabled = (enabled ~= false)
    tab._connectionAware = enabled
    local key = "tab_" .. self.id .. "_" .. tab.id
    if enabled then
        Mux._connAware[key] = { kind = "tab", obj = tab, pane = self }
        if Mux._connState ~= "connected" then
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
    Mux._connState = state
    for _, entry in pairs(Mux._connAware) do
        if entry.kind == "pane" then
            if state == "connected" then
                entry.obj:_hideConnScreen()
            else
                entry.obj:_showConnScreen(state)
            end
        elseif entry.kind == "tab" then
            if state == "connected" then
                entry.pane:_hideTabConnScreen(entry.obj)
            else
                entry.pane:_showTabConnScreen(entry.obj, state)
            end
        end
    end
end

-- ── Extend _activateTabObj for connection-aware tabs ─────────────────────────
-- Wrap the original function (defined in tabs.lua) so tab switches respect the
-- current connection state without modifying tabs.lua.

local _origActivateTabObj = MuxPane._activateTabObj

function MuxPane:_activateTabObj(tab)
    -- Before switching: hide the previous tab's conn screen if it was showing.
    if self._activeTabId and self._activeTabId ~= tab.id then
        local cur = self:_findTab(self._activeTabId)
        if cur and cur._connScreen then
            cur._connScreen:hide()
        end
    end

    -- Run the original activation (updates label styles, hides old content, sets _activeTabId).
    _origActivateTabObj(self, tab)

    -- After switch: if this tab is connection-aware and disconnected, override content visibility.
    if tab._connectionAware and Mux._connState ~= "connected" then
        tab.content:hide()
        self:_showTabConnScreen(tab, Mux._connState)
    end
end

-- ── Mudlet event handlers ─────────────────────────────────────────────────────

if not Mux._connHandlerConn then
    Mux._connHandlerConn = registerAnonymousEventHandler(
        "sysConnectionEvent",
        function() Mux.setConnectionState("connected") end
    )
end

if not Mux._connHandlerDisc then
    Mux._connHandlerDisc = registerAnonymousEventHandler(
        "sysDisconnectionEvent",
        function() Mux.setConnectionState("disconnected") end
    )
end

Mux._log("mux_connection loaded")
