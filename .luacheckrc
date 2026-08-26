std = "lua51"

-- Qt stylesheet template strings (theme.lua, widgets.lua, etc.) are
-- legitimately long single-purpose literals; wrapping them via string
-- concatenation would hurt readability more than it helps.
max_line_length = false

-- Mudlet/Geyser/Muxlet framework code shares globals across files by design
-- (no module system) -- enumerating every project global would be a
-- constantly-stale maintenance burden. Suppress global-related warnings but
-- keep everything else (unused vars, shadowing, line length, etc.) active.
ignore = {
    "111", -- setting non-standard global variable
    "112", -- mutating non-standard global variable
    "113", -- accessing undefined variable
    "143", -- accessing undefined field of a global variable (e.g. table.contains, io.exists)
}
