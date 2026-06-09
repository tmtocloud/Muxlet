for _, ps in pairs(Mux._paneSets) do
    if ps.zone == "right" then ps:toggle(); return end
end
