for _, ps in pairs(Mux._paneSets) do
    if ps.zone == "left" then ps:toggle(); return end
end
