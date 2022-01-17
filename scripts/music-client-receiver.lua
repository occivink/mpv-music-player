local options = require 'mp.options'

-- options are shared between client and server, so that the socket is only defined in one place
local opts = {
    mode = '',
    socket = "mmp_socket",
}
options.read_options(opts, "music-player")

if opts.mode ~= "client" then return end

local socket = require 'socket.unix'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local client = socket()
if not client:connect(opts.socket) then
    msg.error("Cannot connect, aborting")
    return
end


local pid = tostring(utils.getpid())

local interesting_properties = {
    "path",
    "time-pos",
    "chapter",
    "chapter-list",
    "duration",
    "pause",
    "playlist",
    "mute",
    "volume",
    "audio-device",
}

function send_data(who, what, value)
    if value then
        mp.commandv("script-message-to", who, "prop-changed", what, value)
    else
        mp.commandv("script-message-to", who, "prop-changed", what)
    end
end

for i, prop in ipairs(interesting_properties) do
    client:send(string.format('{ "command": ["observe_property_string", %d, "%s"] }\n', i, prop))
end

function mp_event_loop()
    local recipient
    local cache = {} -- used to cache properties until the recipient is known
    while true do
        local rep, err = client:receive()
        if not err then
            local json = utils.parse_json(rep)
            local event = json["event"]
            if event == "property-change" then
                local name = json["name"]
                local value = json["data"]
                if recipient then
                    send_data(recipient, name, value)
                elseif value then
                    cache[name] = value
                end
            elseif event == "client-message" then
                local args = json["args"]
                if args and #args >= 2 and args[2] == pid then
                    if args[1] == "start" then
                        if #args == 3 then
                            recipient = args[3]
                            for k, v in pairs(cache) do
                                send_data(recipient, k, v)
                            end
                            cache = {}
                        end
                    elseif args[1] == "stop" then
                        client:close()
                        return
                    end
                end
            end
        elseif err == "timeout" then
            --
        else
            print(err)
            return
        end
        while true do
            local e = mp.wait_event(0)
            if not e or e.event == "none" then
                break
            elseif e.event == "shutdown" then
                client:close()
                return
            end
        end
    end
end
