local p = Mux._focusedPane
if p then
    cecho(string.format(
        "\n<cyan>[Muxlet]<reset> Rename '%s': type <white>mux rename <name><reset>\n",
        p.name))
end
