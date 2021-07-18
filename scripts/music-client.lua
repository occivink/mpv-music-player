local client = require 'socket.unix'()
local utils = require 'mp.utils'
local msg = require 'mp.msg'

mp.register_script_message("music-client-start", function(server_address, client_script)
    mp.unregister_script_message("music-client-start")
    if not client:connect(server_address) then
        msg.error("Cannot connect, aborting")
        return
    end

    local send_data = function(name, value)
        if value then
            mp.commandv("script-message-to", client_script, "prop-changed", name, value)
        else
            mp.commandv("script-message-to", client_script, "prop-changed", name)
        end
    end

    for i, prop in ipairs({
            "path",
            "time-pos",
            "chapter",
            "chapter-list",
            "duration",
            "pause",
            "playlist",
            "mute",
            "volume",
            "audio-client-name",
        })
    do
        client:send(string.format('{ "command": ["observe_property_string", %d, "%s"] }\n', i, prop))
    end

    client:settimeout(0.05)

    local timer
    -- force the idle to run, but not if shutdown is sent
    timer = mp.add_periodic_timer(0.05, function() end)
    mp.register_idle(function()
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
                send_data(json["name"], json["data"])
            end
        end
    end)
end)
