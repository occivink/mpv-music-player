local utils = require 'mp.utils'
local options = require 'mp.options'

-- options are shared between client and server, so that the socket is only defined in one place
local opts = {
    socket = "/tmp/mmp_socket",
}
options.read_options(opts, "music-player")

mp.set_property("input-ipc-server", opts.socket)

mp.observe_property("playlist-pos", "number", function(_, val)
    if val and val > 0 then
        mp.commandv("playlist-remove", 0)
    end
end)
mp.register_script_message("start_playing", function(index_0)
    -- we use loadlist memory:// so that the playlist change is atomic
    local index_1 = index_0 + 1
    local pl = {}
    -- skip current, and put the the one that was passed in the front
    for i, entry in ipairs(mp.get_property_native("playlist")) do
        if i > 1 then
            local line = entry.filename
            if entry.title then
                line = "#EXTINF:0," .. entry.title .. "\n" .. line
            end
            if i == index_1 then
                table.insert(pl, 1, line)
            else
                pl[#pl + 1] = line
            end
        end
    end
    table.insert(pl, 1, "#EXTM3U")
    mp.commandv("loadlist", "memory://" .. table.concat(pl, "\n"), "replace")
end)
