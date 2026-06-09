-- Muxlet — Theme registry
--
-- A theme is a plain Lua table of CSS strings, pixel dimensions, and color
-- values.  Themes are registered by name.  Switching themes calls applyTheme()
-- on every live pane and split so changes are instant without a reload.
--
-- Built-in themes live in mux_theme_<name>.lua files (dark, light).
-- They load after this file alphabetically and call Mux.registerTheme().
-- External packages can also register themes at any time:
--
--   local my = Mux._merge(Mux._themes["dark"], { titlebarHeight = 28 })
--   Mux.registerTheme("my_theme", my)
--   Mux.applyTheme("my_theme")

Mux._themes           = Mux._themes           or {}
Mux._activeThemeName  = Mux._activeThemeName  or "dark"

--- Return the active theme table.
function Mux.activeTheme()
    return Mux._themes[Mux._activeThemeName] or Mux._themes["dark"] or {}
end

--- Register a named theme.
function Mux.registerTheme(name, def)
    assert(type(name) == "string", "theme name must be a string")
    assert(type(def)  == "table",  "theme definition must be a table")
    Mux._themes[name] = def
    Mux._log("Registered theme: %s", name)
end

--- Switch to a named theme and refresh every live widget immediately.
function Mux.applyTheme(name)
    if not Mux._themes[name] then
        Mux._err("applyTheme: unknown theme '%s'", name)
        return
    end
    Mux._activeThemeName = name
    local theme = Mux._themes[name]
    -- Push scrollbar skin to the Qt profile stylesheet so it cascades to all
    -- QScrollArea widgets (Geyser.ScrollBox has no per-instance setStyleSheet).
    if theme.scrollbarCss and setProfileStyleSheet then
        setProfileStyleSheet(theme.scrollbarCss)
    end
    for _, p in pairs(Mux._panes)  do if p.applyTheme then p:applyTheme() end end
    for _, s in pairs(Mux._splits) do if s.applyTheme then s:applyTheme() end end
    Mux._echo(string.format("\n<green>[Muxlet]<reset> Theme: %s\n", name))
end

Mux._log("mux_theme loaded")
