local client = require 'socket.unix'()
local utils = require 'mp.utils'
local msg = require 'mp.msg'

if not client:connect("bob") then
    msg.error("Cannot connect")
    return
end

local i = 1
function listen_to(prop)
    client:send(string.format("{ \"command\": [\"observe_property_string\", %d, \"%s\"] }\n", i, prop))
    i = i + 1
    local rep = client:receive()
end

listen_to("path")
listen_to("time-pos")
listen_to("chapter")
listen_to("chapter-list")
listen_to("duration")
listen_to("pause")
listen_to("playlist")
listen_to("mute")

client:settimeout(0.05)

local timer
timer = mp.add_periodic_timer(0.10, function()
    while true do
        local rep, err = client:receive()
        if err == "timeout" then
            return
        elseif err then
            print(err)
            timer:kill()
            return
        end
        local json = utils.parse_json(rep)
        if json["event"] == "property-change" then
            if json["data"] then
                mp.commandv("script-message-to", "music_player", "prop-changed", json["name"], json["data"])
            else
                mp.commandv("script-message-to", "music_player", "prop-changed", json["name"])
            end
        end
    end
end)
