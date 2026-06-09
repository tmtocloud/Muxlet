for _, ps in pairs(Mux._paneSets) do
    if ps.zone == "top" then ps:toggle(); return end
end
