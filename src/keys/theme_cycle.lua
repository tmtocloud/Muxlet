local names = {}
for n in pairs(Mux._themes) do names[#names+1] = n end
table.sort(names)
local cur = Mux._activeThemeName
local idx = 1
for i, n in ipairs(names) do if n == cur then idx = i; break end end
-- Route through settings so the chosen theme persists across sessions.
Mux.settings.set("mux", "theme", names[(idx % #names) + 1])
