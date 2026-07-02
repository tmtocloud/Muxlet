-- Muxlet — Dark theme (default)
--
-- The dark palette is the fallback layer in style.lua, so the dark theme is the
-- identity: an empty token table. Everything resolves straight to the fallback.
-- This avoids duplicating ~150 values that would otherwise have to be kept in
-- sync with the fallback by hand. A package that wants a dark-derived theme can
-- still merge onto this and override only what it needs.

Mux.registerTheme("dark", {})