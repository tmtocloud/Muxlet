std = "lua51"

-- Mudlet/Geyser/Muxlet framework code shares globals across files by design
-- (no module system) -- enumerating every project global would be a
-- constantly-stale maintenance burden. Suppress global-related warnings but
-- keep everything else (unused vars, shadowing, line length, etc.) active.
ignore = {
    "111", -- setting non-standard global variable
    "112", -- mutating non-standard global variable
    "113", -- accessing undefined variable
}
