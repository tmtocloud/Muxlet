-- Muxlet — Theme registry
--
-- A theme is a plain Lua table of CSS strings, pixel dimensions, and color
-- values. Themes are registered by name. Switching themes calls applyTheme()
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
-- Package CSS that must survive theme changes. Packages append here via
-- Mux.addProfileCss(); applyTheme() concatenates all entries with the theme's
-- own scrollbarCss each time it fires.
Mux._profileCssAddons = Mux._profileCssAddons or {}

function Mux.activeTheme()
    return Mux._themes[Mux._activeThemeName] or Mux._themes["dark"] or {}
end

function Mux.registerTheme(name, def)
    assert(type(name) == "string", "theme name must be a string")
    assert(type(def)  == "table",  "theme definition must be a table")
    Mux._themes[name] = def
    Mux._log("Registered theme: %s", name)
end

function Mux.applyTheme(name)
    if not Mux._themes[name] then
        Mux._err("applyTheme: unknown theme '%s'", name)
        return
    end
    Mux._activeThemeName = name
    local theme = Mux._themes[name]
    -- Push scrollbar skin + package addon CSS to the Qt profile stylesheet so
    -- it cascades to all QScrollArea widgets.  Addons survive theme changes
    -- because they are re-appended every time applyTheme() runs.
    if setProfileStyleSheet then
        local parts = { theme.scrollbarCss or "" }
        for _, css in ipairs(Mux._profileCssAddons) do
            parts[#parts + 1] = css
        end
        setProfileStyleSheet(table.concat(parts, "\n"))
    end
    for _, p in pairs(Mux._panes)  do if p.applyTheme then p:applyTheme() end end
    for _, s in pairs(Mux._splits) do if s.applyTheme then s:applyTheme() end end
end

--- Register CSS that must persist across theme changes.
-- Called by packages that need profile-wide Qt rules (e.g. to hide a native
-- widget panel).  The CSS is appended to the theme's scrollbarCss on every
-- applyTheme() call and applied immediately.
function Mux.addProfileCss(css)
    assert(type(css) == "string", "addProfileCss: css must be a string")
    table.insert(Mux._profileCssAddons, css)
    -- Apply immediately so callers don't need to wait for the next theme switch.
    if setProfileStyleSheet then
        local theme = Mux.activeTheme()
        local parts = { theme.scrollbarCss or "" }
        for _, c in ipairs(Mux._profileCssAddons) do
            parts[#parts + 1] = c
        end
        setProfileStyleSheet(table.concat(parts, "\n"))
    end
end

Mux._log("mux_theme loaded")
