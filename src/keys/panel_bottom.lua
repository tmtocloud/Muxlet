for _, ps in pairs(Mux._paneSets) do
    if ps.zone == "bottom" then ps:toggle(); return end
end
