local socket = require 'socket.unix'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'

local lib = mp.find_config_file('scripts/lib.disable')
if not lib then
    return
end
-- lib can be nil if the folder does not exist or we're in --no-config mode
package.path = package.path .. ';' .. lib .. '/?.lua;'
require 'gallery'

local opts = {
    root_dir = "music",
    thumbs_dir = "thumbs",
    waveforms_dir = "waveform",
    lyrics_dir = "lyrics",
    albums_file = '', -- for optimization purposes
    socket = "bob",
    default_layout = "BROWSE",
}
(require 'mp.options').read_options(opts)

local client = nil
while true do
    client = socket()
    local res, err = client:connect(opts.socket)
    if res == 1 then break end
    msg.warn("Could not connect to server, waiting...")
    mp.command_native({ name = "subprocess", playback_only = false, args = {"sleep", "1"}})
end

local function send_to_server(array)
    client:send(string.format("%s\n", utils.format_json({ command = array })))
    local rep, err = client:receive()
    if err then
        print(err)
        return
    end
end
send_to_server({"disable_event", "all"})

local red = '5E66F9'
local blue = 'CB9F79'
local yellow = '7DBEEF'
local white = '999999'
local gray = '555555'

-- CONFIG
local global_offset = 10

local background_opacity = 'BB'
local background_color_focus = 'AAAAAA'
local background_color_idle = '666666'
local background_border_size = '3'
local background_border_color = '000000'
local background_roundness = 2

local chapters_marker_width = 3
local chapters_marker_color = "888888"
local cursor_bar_width = 3
local seekbar_snap_distance = 15
local cursor_bar_color = "BBBBBB"
local waveform_padding_proportion = 2/3
local title_text_size = 32
local artist_album_text_size = 24
local time_text_size = 24
local darker_text_color = "888888"

-- VARS
local ass_changed = false

local seekbar_overlay_index = 0

local albums = {}
local queue = {}

properties = {
    ["path"] = '',
    ["playlist"] = {},
    ["pause"] = false,
    ["time-pos"] = -1,
    ["chapter"] = -1,
    ["chapter-list"] = {},
    ["duration"] = -1,
    ["mute"] = false,
    ["volume"] = -1,
    ["audio-client-name"] = '',
}

local edl_album_cache = {}
local function album_from_path(path)
    if not path then return nil end
    local cached = edl_album_cache[path]
    if cached then
        return cached, albums[cached]
    end
    if string.find(path, "^edl://") then
        local s, e = string.find(path, "%%%d+%%")
        local len = tonumber(string.sub(path, s + 1, e - 1))
        local track_path = string.sub(path, e + 1, e + len)
        local artist, year, album = string.match(track_path, ".*/(.-)/(%d%d%d%d) %- (.-)/.-")
        for index, item in ipairs(albums) do
            if item.album == album and item.artist == artist then
                edl_album_cache[path] = index
                return index, item
            end
        end
    end
    return nil
end

local function get_background(position, size, focused)
    local a = assdraw.ass_new()
    a:new_event()
    a:append(string.format('{\\bord%s\\shad0\\1a&%s&\\1c&%s&\\3c&%s&}',
        background_border_size,
        background_opacity,
        focused and background_color_focus or background_color_idle,
        background_border_color
    ))
    a:pos(0, 0)
    a:draw_start()
    a:round_rect_cw(position[1], position[2], position[1] + size[1], position[2] + size[2], background_roundness)
    return a.text
end

do
    if opts.albums_file == '' then
        local artists = utils.readdir(opts.root_dir)
        if not artists then return end
        table.sort(artists)
        for _, artist in ipairs(artists) do
            local yearalbums = utils.readdir(opts.root_dir .. "/" .. artist)
            table.sort(yearalbums)
            for _, yearalbum in ipairs(yearalbums) do
                local year, album = string.match(yearalbum, "^(%d+) %- (.*)$")
                if year ~= nil and album ~= nil then
                    albums[#albums + 1] = {
                        artist = string.gsub(artist, '\\', '/'),
                        album = string.gsub(album, '\\', '/'),
                        year = year,
                        dir = string.format("%s/%s/%s", opts.root_dir, artist, yearalbum)
                    }
                end
            end
        end
    else
        local f = io.open(opts.albums_file, "r")
        while true do
            local line = f:read()
            if not line then break end
            local artist, album, year = string.match(line, "^(.-) %- (.-) %[(%d+)]$")
            if artist and album and year then
                albums[#albums + 1] = {
                    artist = artist,
                    album = album,
                    year = year,
                    dir = string.format("%s/%s/%s - %s", opts.root_dir,
                        string.gsub(artist, '/', '\\'),
                        year,
                        string.gsub(album, '/', '\\'))
                }
            else
                msg.error("Invalid line in albums file: " .. line)
            end
        end
    end
    if #albums == 0 then
        msg.warn("No albums, exiting")
        return
    end
    local r = {
        ['á']='a',  ['à']='a',  ['â']='a',  ['ä']='a',  ['ă']='a',  ['å']='a',  ['æ']='a',
        ['é']='e',  ['è']='e',  ['ë']='e',  ['ê']='e',
        ['ï']='i',  ['î']='i',  ['í']='i',  ['ì']='i',
        ['ó']='o',  ['ò']='o',  ['ô']='o',  ['ö']='o',  ['ø']='o',
        ['ü']='u',  ['û']='u',  ['ú']='u',  ['ù']='u',
        ['ð']='d',
        ['ç']='c',
        ['þ']='t',  ['ț']='t',
        ['ș']='s',
        ['ñ']='n',
        ['ý']='y',
    }

    local function normalize_name(name)
        local norm = {}
        for code in string.gmatch(string.lower(name), '[%z\1-\127\194-\244][\128-\191]*') do
            norm[#norm + 1] = r[code] or code
        end
        return table.concat(norm, '')
    end
    for _, album in ipairs(albums) do
        album.artist_normalized = normalize_name(album.artist)
        album.album_normalized = normalize_name(album.album)
    end
end


function normalized_coordinates(coord, position, size)
    return (coord[1] - position[1]) / size[1], (coord[2] - position[2]) / size[2]
end

function setup_bindings(list, component_name, activate)
    for _, binding in ipairs(list) do
        local name = component_name .. "_" .. binding[1]
        if activate then
            mp.add_forced_key_binding(binding[1], name, binding[2], binding[3])
        else
            mp.remove_key_binding(name)
        end
    end
end

local queue_component = {}
do
    local this = queue_component
    local gallery = gallery_new()
    local pending_selection = nil
    local active = false

    gallery.items = queue
    gallery.config.always_show_placeholders = false
    gallery.config.align_text = false
    gallery.config.max_thumbnails = 16
    gallery.config.overlay_range = 49
    gallery.config.background_opacity = 'ff'

    local ass_text = {
        background = '',
        gallery = '',
    }

    gallery.item_to_overlay_path = function(index, item)
        local album = albums[item]
        return string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
            album.artist, album.album,
            gallery.geometry.thumbnail_size[1],
            gallery.geometry.thumbnail_size[2]
        )
    end
    gallery.item_to_border = function(index, item)
        if index == gallery.selection then
            return 3, "AAAAAA"
        end
        return 1, "BBBBBB"
    end
    gallery.item_to_text = function(index, item)
        return ''
    end
    gallery.ass_show = function(ass)
        ass_text.gallery = ass
        ass_changed = true
    end


    local function increase_pending(inc)
        pending_selection = (pending_selection or gallery.selection) + inc
    end
    local function remove_from_queue()
        if #queue == 0 then return end
        -- playlist-remove is 0-indexed, but queue doesn't contain the current one anyway
        local play_index = gallery.selection
        send_to_server({"playlist-remove", tostring(play_index)})
        gallery:set_selection(play_index + (play_index == #queue and -1 or 1))
    end
    local function play_from_queue()
        if #queue == 0 then return end
        local play_index = gallery.selection
        --send_to_server({"playlist-move", tostring(play_index), "1"})
        --send_to_server({"set_property", "playlist-pos", "1"})
        send_to_server({"script_message", "start_playing", tostring(play_index)})
        gallery:set_selection(play_index + (play_index == #queue and -1 or 1))
    end

    local function select_or_play()
        local mx, my = mp.get_mouse_pos()
        local index = gallery:index_at(mx, my)
        if not index then return end
        if index == gallery.selection then
            play_from_queue()
        else
            pending_selection = index
        end
    end

    local function select_or_remove()
        local mx, my = mp.get_mouse_pos()
        local index = gallery:index_at(mx, my)
        if not index then return end
        if index == gallery.selection then
            remove_from_queue()
        else
            pending_selection = index
        end
    end

    local bindings = {
        {"LEFT", function() increase_pending(-1) end, {repeatable=true}},
        {"RIGHT", function() increase_pending(1) end, {repeatable=true}},
        {"UP", function() increase_pending(-gallery.geometry.columns) end, {repeatable=true}},
        {"DOWN", function() increase_pending(gallery.geometry.columns) end, {repeatable=true}},
        {"WHEEL_UP", function() increase_pending(-gallery.geometry.columns) end, {}},
        {"WHEEL_DOWN", function() increase_pending(gallery.geometry.columns) end, {}},
        {"ENTER", function() play_from_queue() end, {}},
        {"DEL", function() if #queue > 0 then remove_from_queue() end end, {}},
        {"MBTN_LEFT", function() select_or_play() end, {}},
        {"MBTN_RIGHT", function() select_or_remove() end, {}},
    }

    this.set_active = function(active_now)
        active = active_now
        if active then
            gallery:activate();
            ass_text.background = get_background(gallery.geometry.position, gallery.geometry.size, focus)
            ass_changed = true
        else
            gallery:deactivate();
        end
    end
    this.set_focus = function(focus_now)
        focus = focus_now
        setup_bindings(bindings, "queue", focus)
        ass_text.background = get_background(gallery.geometry.position, gallery.geometry.size, focus)
        ass_changed = true
    end
    this.set_geometry = function(x, y, w, h)
        gallery:set_geometry(x, y, w, h, 15, 15, 150, 150)
        ass_text.background = get_background(gallery.geometry.position, gallery.geometry.size, focus)
        ass_changed = true
    end
    this.get_active = function()
        return active
    end
    this.get_position = function()
        return gallery.geometry.position[1], gallery.geometry.position[2]
    end
    this.get_size = function()
        return gallery.geometry.size[1], gallery.geometry.size[2]
    end
    this.get_ass = function()
        return active and table.concat({ass_text.background, ass_text.gallery}, '\n') or ''
    end

    this.prop_changed = {
        ["playlist"] = function(val)
            -- queue = {} is no good because it creates a new object or something
            local prev_index = queue[gallery.selection]
            local new_sel = nil
            for i in pairs(queue) do queue[i] = nil end
            for i = 2, #val do
                local item = val[i].filename
                local index = album_from_path(item)
                queue[#queue + 1] = index
                if index == prev_index then
                    new_sel = #queue
                end
            end
            gallery:items_changed(new_sel or 1)
        end
    }

    this.mouse_move = function(mx, my) end

    this.idle = function()
        if pending_selection then
            gallery:set_selection(pending_selection)
            pending_selection = nil
        end
    end
end

local albums_component = {}
do
    local this = albums_component -- mfw oop

    local active = false
    local focus = false

    local position = {0,0}
    local size = {0,0}

    local gallery = gallery_new()
    local albums_filtered = {}

    local filter_position = {0,0}
    local filter_size = {0,0}

    gallery.items = albums_filtered
    gallery.config.always_show_placeholders = false
    gallery.config.align_text = true
    gallery.config.max_thumbnails = 48
    gallery.config.overlay_range = 1
    gallery.config.background_opacity = 'ff'

    local ass_text = {
        background = '',
        gallery = '',
        filter = '',
    }
    local pending_selection = nil

    local focus_filter = false
    local filter = ''
    local cursor = 1

    local function add_to_queue(index)
        local album = albums_filtered[index]
        local files = utils.readdir(album.dir)
        if not files then return end
        table.sort(files)
        for i, file in ipairs(files) do
            file = album.dir .. "/" .. file
            files[i] = string.format("%%%i%%%s", string.len(file), file)
        end
        send_to_server({"loadfile", "edl://" .. table.concat(files, ';'), "append-play"})
    end


    gallery.item_to_overlay_path = function(index, item)
        return string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
            item.artist, item.album,
            gallery.geometry.thumbnail_size[1],
            gallery.geometry.thumbnail_size[2]
        )
    end
    gallery.item_to_border = function(index, item)
        if index == gallery.selection then
            return 4, "AAAAAA"
        end
        return 0.8, "BBBBBB"
    end
    gallery.item_to_text = function(index, item)
        if index == gallery.selection then
            return string.format("%s - %s [%d]", item.artist, item.album, item.year)
        end
        return ''
    end

    gallery.ass_show = function(ass)
        ass_text.gallery = ass
        ass_changed = true
    end

    local function increase_pending(inc)
        pending_selection = (pending_selection or gallery.selection) + inc
    end

    local function select_or_queue()
        local mx, my = mp.get_mouse_pos()
        local index = gallery:index_at(mx, my)
        if not index then return end
        if index == gallery.selection then
            add_to_queue(index)
        else
            gallery:set_selection(index)
        end
    end

    local function redraw_filter()
        local ass_escape = function(ass)
            ass = ass:gsub('\\', '\\\239\187\191')
            ass = ass:gsub('{', '\\{')
            ass = ass:gsub('}', '\\}')
            ass = ass:gsub('^ ', '\\h')
            return ass
        end

        local coffset = 8
        local cheight = 28 * 8
        local cglyph = '{\\r' ..
           '\\1a&H44&\\3a&H44&\\4a&H99&' ..
           '\\1c&Heeeeee&\\3c&Heeeeee&\\4c&H000000&' ..
           '\\xbord1\\ybord0\\xshad0\\yshad1\\p4\\pbo24}' ..
           'm 0 ' .. coffset.. ' l 1 ' .. coffset .. ' l 1 ' .. cheight .. ' l 0 ' .. cheight ..
           '{\\p0}'

        local a = assdraw.ass_new()
        a:new_event()
        a:append(string.format('{\\bord4\\shad0\\1a&%s&\\3c&%s&}', 'ff', focus_filter and blue or '222222'))
        a:pos(0, 0)
        a:draw_start()
        a:rect_cw(filter_position[1], filter_position[2], filter_position[1] + filter_size[1], filter_position[2] + filter_size[2])
        if filter ~= '' then
            a:new_event()
            a:pos(filter_position[1] + 5, filter_position[2] + filter_size[2] / 2)
            a:an(4)
            local style = string.format("{\\r\\bord0\\fs%d}", 28)
            a:append(style .. ass_escape(string.sub(filter, 1, cursor - 1)))
            a:append(cglyph)
            a:append(style .. ass_escape(string.sub(filter, cursor)))
        end
        ass_text.filter = a.text
        ass_changed = true
    end

    local function apply_filter()
        local filter_processed = string.lower(filter)
        local prev_focus = albums_filtered[gallery.selection]
        for i = #albums_filtered, 1, -1 do
            albums_filtered[i] = nil
        end
        local new_sel = nil
        for _, album in ipairs(albums) do
            if filter_processed == ''
                or string.find(album.artist_normalized, filter_processed, 1, true)
                or string.find(album.album_normalized, filter_processed, 1, true)
                or string.find(album.year, filter_processed, 1, true)
            then
                albums_filtered[#albums_filtered + 1] = album
                if album == prev_focus then new_sel = #albums_filtered end
            end
        end
        gallery:items_changed(new_sel or 1)
    end

    apply_filter()

    local function filter_changed()
        apply_filter()
        redraw_filter()
    end

    -- some of this stuff is taken from Rossy's repl.lua
    local function next_utf8(str, pos)
        if pos > str:len() then return pos end
        repeat
            pos = pos + 1
        until pos > str:len() or str:byte(pos) < 0x80 or str:byte(pos) > 0xbf
        return pos
    end
    local function prev_utf8(str, pos)
        if pos <= 1 then return pos end
        repeat
            pos = pos - 1
        until pos <= 1 or str:byte(pos) < 0x80 or str:byte(pos) > 0xbf
        return pos
    end
    local function append_char(c)
        filter = filter:sub(1, cursor - 1) .. c .. filter:sub(cursor)
        cursor = cursor + #c
        filter_changed()
    end
    local function del_char_left()
        if cursor <= 1 then return end
        local prev = prev_utf8(filter, cursor)
        filter = filter:sub(1, prev - 1) .. filter:sub(cursor)
        cursor = prev
        filter_changed()
    end
    local function del_char_right()
        if cursor > filter:len() then return end
        filter = filter:sub(1, cursor - 1) .. filter:sub(next_utf8(filter, cursor))
        filter_changed()
    end
    local function handle_left()
        if focus_filter then
            if cursor > 1 then
                cursor = prev_utf8(filter, cursor)
                redraw_filter()
            end
        else
            increase_pending(-1)
        end
    end
    local function handle_right()
        if focus_filter then
            if cursor < filter:len() then
                cursor = next_utf8(filter, cursor)
                redraw_filter()
            end
        else
            increase_pending(1)
        end
    end
    local function handle_home()
        if focus_filter then
            cursor = 1
            redraw_filter()
        else
            pending_selection = 1
        end
    end
    local function handle_end()
        if focus_filter then
            cursor = filter:len() + 1
            redraw_filter()
        else
            pending_selection = #albums_filtered
        end
    end
    local function handle_enter()
        if focus_filter then
            focus_filter = false
            redraw_filter()
        else
            add_to_queue(gallery.selection)
        end
    end
    local function handle_esc()
        filter = ''
        cursor = 1
        focus_filter = false
        filter_changed()
    end
    local function handle_unicode(table)
        -- special handling for space: if filter is focused: insert space, otherwise toggle pause
        if not focus_filter and table.key_name == "SPACE" then
            if table["event"] == "down" then
                send_to_server({"cycle", "pause"})
            end
        elseif table["event"] == "down" or table["event"] == "repeat" then
            focus_filter = true
            append_char(table.key_text)
        end
    end

    local function toggle_focus_filter()
        focus_filter = not focus_filter
        redraw_filter()
    end

    local bindings = {
        {"ANY_UNICODE", handle_unicode, {complex=true, repeatable=true}},
        {"BS", del_char_left, {repeatable=true}},
        {"DEL", del_char_right, {repeatable=true}},
        {"LEFT", handle_left, {repeatable=true}},
        {"RIGHT", handle_right, {repeatable=true}},
        {"CTRL+LEFT", function() end, {repeatable=true}}, -- TODO
        {"CTRL+RIGHT", function() end, {repeatable=true}}, -- TODO
        {"ENTER", handle_enter, {}},
        {"ESC", handle_esc, {}},
        {"ALT+f", toggle_focus_filter, {}},
        {"ALT+r", function() pending_selection = math.random(1, #albums_filtered) end, {repeatable=true}},
        {"UP", function() increase_pending(-gallery.geometry.columns) end, {repeatable=true}},
        {"DOWN", function() increase_pending(gallery.geometry.columns) end, {repeatable=true}},
        {"WHEEL_UP", function() increase_pending(-gallery.geometry.columns) end, {}},
        {"WHEEL_DOWN", function() increase_pending(gallery.geometry.columns) end, {}},
        {"HOME", handle_home, {}},
        {"END", handle_end, {}},
        {"MBTN_LEFT", select_or_queue, {}},
    }

    this.set_active = function(active_now)
        active = active_now
        if active then
            gallery:activate();
        else
            gallery:deactivate();
        end
        ass_text.background = get_background(position, size, focus)
        redraw_filter()
        ass_changed = true
    end
    this.set_focus = function(focus_now)
        focus = focus_now
        setup_bindings(bindings, "albums", focus)
        gallery:ass_refresh(false, false, false, true)
        focus_filter = false
        ass_text.background = get_background(position, size, focus)
        redraw_filter()
        ass_changed = true
    end
    this.set_geometry = function(x, y, w, h)
        position = {x,y}
        size = {w,h}
        local gallery_vertical_spacing = 30
        local filter_height = 30
        local offset = filter_height - gallery_vertical_spacing + 2 * 10
        gallery:set_geometry(
            x, y + offset,
            w, h - offset,
            15, gallery_vertical_spacing, 150, 150)
        filter_position = {x + gallery.geometry.effective_spacing[1], y + gallery.geometry.effective_spacing[2] / 2 - 10}
        filter_size = {math.min(300, w - 2 * 10), filter_height}
        ass_text.background = get_background(position, size, focus)
        redraw_filter()
        ass_changed = true
    end
    this.get_position = function()
        return position[1], position[2]
    end
    this.get_size = function()
        return size[1], size[2]
    end
    this.get_ass = function()
        return active and table.concat({ass_text.background, ass_text.gallery, ass_text.filter}, '\n') or ''
    end

    this.prop_changed = {}
    this.mouse_move = function(mx, my) end

    this.idle = function()
        if pending_selection then
            gallery:set_selection(pending_selection)
            pending_selection = nil
        end
    end
end

local now_playing_component = {}
do
    local this = now_playing_component

    local position = {0,0}
    local size = {0,0}
    local waveform_position = {0,0}
    local waveform_size = {0,0}
    local cover_position = {0,0}
    local cover_size = {0,0}
    local text_position = {0,0}
    local times_position = {0, 0}

    local time_pos_coarse = -1

    local ass_text = {
        background = '',
        elapsed = '',
        times = '',
        chapters = '',
        text = '',
    }
    local active = false
    local focus = false

    local function redraw_chapters()
        local duration = properties["duration"]
        local chapters = properties["chapter-list"]
        if not duration or #chapters == 0 then
            ass_text.chapters = ''
            ass_changed = true
            return
        end
        local a = assdraw.ass_new()
        a:new_event()
        a:pos(0, 0)
        a:append('{\\bord0\\shad0\\1c&' .. chapters_marker_color .. '}')
        a:draw_start()
        local w = chapters_marker_width/2
        local y1 = waveform_position[2]
        local y2 = y1 + waveform_size[2]
        for _, chap in ipairs(chapters) do
            local x = waveform_position[1] + waveform_size[1] * (chap.time / duration)
            a:rect_cw(x - w, y1, x + w, y2)
        end
        local x = waveform_position[1] + waveform_size[1]
        a:rect_cw(x - w, y1, x + w, y2)
        a:new_event()
        a:pos(text_position[1], text_position[2] + (title_text_size + artist_album_text_size) / 2 - 5)
        a:append('{\\bord0\\an4}')

        local chap = math.max(0, properties["chapter"] or 0) + 1
        local chapter = chapters[chap]
        local title = string.match(chapter.title, ".*/%d+ (.*)%..-")
        local track_duration = chap == #chapters and duration - chapter.time or chapters[chap + 1].time - chapter.time
        local text = string.format("{\\fs%d}%s {\\1c&%s&}[%d/%d] [%s]", title_text_size, title, darker_text_color, chap, #chapters, mp.format_time(track_duration, "%m:%S"))
        local _, album = album_from_path(properties["path"])
        if album then
            text = text .. "\\N" .. string.format("{\\fs%d}{\\1c&FFFFFF&}%s - %s {\\1c&%s&}[%s]", artist_album_text_size, album.artist, album.album, darker_text_color, album.year)
            a:append(text)
        end
        ass_text.chapters = a.text
        ass_changed = true
    end

    local left_mouse_button_held = false
    local scrubbing = false

    local function redraw_times()
        local duration = properties["duration"]
        if duration == -1 then
            if ass_text.times ~= '' then
                ass_text.times = ''
                ass_changed = true
            end
            return
        end

        local format_time = function(time)
            if time > 60 * 60 then
                return mp.format_time(time, "%h:%M:%S")
            else
                return mp.format_time(time, "%M:%S")
            end
        end
        local time_width = 65

        local a = assdraw.ass_new()
        local show_time_at = function(x)
            if not x then return end
            local time = (x - waveform_position[1]) / waveform_size[1] * duration
            local align = "8"
            if math.abs(x - waveform_position[1]) < (time_width / 2) then
                align = "7"
                x = waveform_position[1]
            elseif math.abs(x - (waveform_position[1] + waveform_size[1])) < (time_width / 2) then
                align = "9"
                x = waveform_position[1] + waveform_size[1]
            end
            a:new_event()
            a:pos(x, times_position[2])
            a:append(string.format("{\\an%s\\fs%s\\bord0}", align, time_text_size))
            a:append(format_time(time))
        end

        local cursor_x = nil
        local end_x = waveform_position[1] + waveform_size[1]
        local current_x = nil

        do
            local mx, my = mp.get_mouse_pos()
            local tx = mx - waveform_position[1]
            local ty = my - waveform_position[2]
            if tx >= 0 and tx <= waveform_size[1] and ty >= 0 and ty <= waveform_size[2] then
                cursor_x = mx
                if not scrubbing then
                    for _, chap in ipairs(properties["chapter-list"]) do
                        local chap_x = waveform_position[1] + chap.time / duration * waveform_size[1]
                        if math.abs(chap_x - cursor_x) < seekbar_snap_distance then
                            cursor_x = chap_x
                        end
                    end
                end
            end
        end
        if time_pos_coarse and duration then
            current_x = waveform_position[1] + waveform_size[1] * (time_pos_coarse / duration)
        end

        -- cursor > current > end
        if cursor_x and current_x and math.abs(cursor_x - current_x) < time_width then
            current_x = nil
        end
        if cursor_x and end_x and math.abs(cursor_x - end_x) < time_width then
            end_x = nil
        end
        if current_x and end_x and math.abs(current_x - end_x) < time_width then
            end_x = nil
        end

        show_time_at(current_x)
        show_time_at(end_x)
        show_time_at(cursor_x)

        ass_text.times = a.text
        ass_changed = true
    end

    local function redraw_elapsed()
        local duration = properties["duration"]
        if duration == -1 or time_pos_coarse == -1 then
            if ass_text.elapsed ~= '' then
                ass_text.elapsed = ''
                ass_changed = true
            end
            return
        end
        local a = assdraw.ass_new()
        a:new_event()
        a:append(string.format('{\\bord0\\shad0\\1c&%s\\1a&%s}', "222222", "AA"))
        a:pos(0,0)
        a:draw_start()
        local y1 = waveform_position[2]
        local y2 = y1 + waveform_size[2]
        local x1 = waveform_position[1]
        local x2 = x1 + waveform_size[1] * (time_pos_coarse / duration)
        a:rect_cw(x1, y1, x2, y2)
        ass_text.elapsed = a.text
        ass_changed = true
    end

    local function set_waveform()
        local _, album = album_from_path(properties["path"])
        if not active or not album then
            mp.commandv("playlist-remove", "current")
            return
        end
        local wavefile = string.format("%s/%d - %s.png", opts.waveforms_dir, album.year, string.gsub(album.album, ':', '\\:'))
        mp.commandv("loadfile", wavefile, "replace")
    end

    local function set_overlay()
        local _, album = album_from_path(properties["path"])
        if not active or not album then
            mp.commandv("overlay-remove", seekbar_overlay_index)
            return
        end
        mp.commandv("overlay-add",
            seekbar_overlay_index,
            tostring(math.floor(cover_position[1] + 0.5)),
            tostring(math.floor(cover_position[2] + 0.5)),
            string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
                album.artist, album.album,
                cover_size[1],
                cover_size[2]),
            "0",
            "bgra",
            tostring(cover_size[1]),
            tostring(cover_size[2]),
            tostring(4*cover_size[1]))
    end

    local function skip_current_maybe()
        local x, y = normalized_coordinates({mp.get_mouse_pos()}, cover_position, cover_size)
        if x < 0 or y < 0 or x > 1 or y > 1 then return end
        send_to_server({"playlist-remove", "0"})
    end

    local function seek_or_pause()
        local duration = properties["duration"]
        local chapters = properties["chapter-list"]
        if not duration or not chapters then return end
        local mouse_pos = {mp.get_mouse_pos()}
        local x, y = normalized_coordinates(mouse_pos, waveform_position, waveform_size)
        if x >= 0 and y >= 0 and x <= 1 and y <= 1 then
            local snap_chap = nil
            local min_dist = nil
            for _, chap in ipairs(chapters) do
                local dist = math.abs(x - chap.time / duration)
                if dist * waveform_size[1] < seekbar_snap_distance then
                    if not snap_chap or dist < min_dist then
                        snap_chap = chap.time
                        min_dist = dist
                    end
                end
            end
            send_to_server({"set_property", "time-pos", tostring(snap_chap or x * duration)})
            return
        end
        local x, y = normalized_coordinates(mouse_pos, cover_position, cover_size)
        if x >= 0 and y >= 0 and x <= 1 and y <= 1 then
            send_to_server({"set_property", "pause", properties["pause"] and "no" or "yes"})
            return
        end
    end

    local bindings = {
        {"UP", function() send_to_server({"seek", "30", "exact"}) end, {repeatable=true}},
        {"DOWN", function() send_to_server({"seek", "-30", "exact"}) end, {repeatable=true}},
        {"LEFT", function() send_to_server({"seek", "-5", "exact"}) end, {repeatable=true}},
        {"RIGHT", function() send_to_server({"seek", "5", "exact"}) end, {repeatable=true}},
        {"PGUP", function() send_to_server({"add", "chapter", "1"}) end, {}},
        {"PGDWN", function() send_to_server({"add", "chapter", "-1"}) end, {}},
        {"SPACE", function() send_to_server({"set_property", "pause", properties["pause"] and "no" or "yes"}) end, {}},
        {"m", function() send_to_server({"set_property", "mute", properties["mute"] and "no" or "yes"}) end, {}},
        {"DEL", function() send_to_server({"playlist-remove", "0"}) end, {}},
        {"MBTN_RIGHT", function() skip_current_maybe() end, {}},
        {"MBTN_LEFT", function(table)
                          left_mouse_button_held = (table["event"] == "down")
                          scrubbing = false
                          if left_mouse_button_held then seek_or_pause() end
                      end, {complex=true,repeatable=false}},
    }

    this.set_active = function(newactive)
        active = newactive
        set_overlay()
        set_waveform()
        redraw_elapsed()
        redraw_times()
        redraw_chapters()
        ass_text.background = get_background(position, size, focus)
        ass_changed = true
    end
    this.set_focus = function(newfocus)
        focus = newfocus
        setup_bindings(bindings, "seekbar", focus)
        ass_text.background = get_background(position, size, focus)
        ass_changed = true
    end
    this.set_geometry = function(x, y, w, h)
        position = { x, y }
        size = { w, h }
        cover_size = { 150, 150 }

        local dist_w = 10
        cover_position = { x + dist_w, y + (h - cover_size[2]) / 2 }

        local dist_h = 10
        text_position = { x + cover_size[1] + 2 * dist_w, y + dist_h}

        waveform_position = { text_position[1], text_position[2] + artist_album_text_size + title_text_size }
        waveform_size = { w - cover_size[1] - 3 * dist_w, h - 2 * dist_h - (artist_album_text_size + title_text_size + time_text_size) }
        times_position = { text_position[1], waveform_position[2] + waveform_size[2] }

        set_video_position(waveform_position[1], waveform_position[2] - 0.5 * waveform_padding_proportion * waveform_size[2] / (1 - waveform_padding_proportion), waveform_size[1], waveform_size[2] / (1 - waveform_padding_proportion))
        if active then
            set_overlay()
            redraw_elapsed()
            redraw_times()
            redraw_chapters()
            ass_text.background = get_background(position, size, focus)
            ass_changed = true
        end
    end

    this.get_position = function()
        return position[1], position[2]
    end
    this.get_size = function()
        return size[1], size[2]
    end
    this.get_ass = function()
        return active and table.concat({
            ass_text.background,
            ass_text.elapsed,
            ass_text.times,
            ass_text.chapters,
            ass_text.text,
        }, "\n") or ''
    end

    this.prop_changed = {
        ["path"] = function()
            set_waveform()
            set_overlay()
            redraw_chapters()
            redraw_elapsed()
            redraw_times()
        end,
        ["chapter-list"] = function() redraw_chapters() end,
        ["chapter"] = function() redraw_chapters() end,
        ["time-pos"] = function(value)
            -- since time-pos is changed ~15/second during normal playback, we throttle redraws to 1/s
            value = math.floor(value)
            if value == time_pos_coarse then return end
            time_pos_coarse = value
            redraw_elapsed()
            redraw_times()
        end,
        ["duration"] = function() redraw_chapters() redraw_elapsed() end,
    }

    local cursor_visible = false
    this.mouse_move = function(mx, my)
        scrubbing = left_mouse_button_held
        if not properties["path"] then return end
        local x, y = normalized_coordinates({mx, my}, waveform_position, waveform_size)
        if x >= 0 and y >= 0 and x <= 1 and y <= 1 then
            if scrubbing then
                local duration = properties["duration"]
                -- no snapping in this case
                if duration then
                    send_to_server({"set_property", "time-pos", tostring(x * duration)})
                end
            end
            redraw_times()
            cursor_visible = true
        elseif cursor_visible then
            redraw_times()
            cursor_visible = false
        end
    end

    this.idle = function() end
end

local controls_component = {}
do
    local this = controls_component

    local position = {0, 0}
    local size = {0, 0}
    local active = false
    local focus = false

    local play = {}
    local pause = {}
    local backwards = {}
    local forwards = {}
    local speakers = {}
    local headphones = {}
    local mute = {}
    local volume = {}

    local ass_text = {
        background = "",
        buttons = "",
    }

    local hovered_button = nil
    local holding_volume = false

    local function is_on_button(button, x, y)
        return x >= button[1] and y >= button[2] and x <= button[1] + button[3] and y <= button[2] + button[4]
    end

    local function get_button_at(x, y)
        for _, button in ipairs({play,pause,backwards,forwards,speakers,headphones,mute,volume}) do
            if is_on_button(button, x, y) then
                return button
            end
        end
        return nil
    end

    local function redraw_buttons(focus)
        local a = assdraw.ass_new()
        local last_color = nil
        local draw_button = function(b, border, color, tint_factor)
            if tint_factor and tint_factor ~= 0 then
                local b = tonumber(string.sub(color, 1, 2), 16)
                local g = tonumber(string.sub(color, 3, 4), 16)
                local r = tonumber(string.sub(color, 5, 6), 16)
                color = string.format("%02x%02x%02x",
                    b + (255 - b) * tint_factor,
                    g + (255 - g) * tint_factor,
                    r + (255 - r) * tint_factor)
            end

            if color ~= last_color then
                last_color = color
                a:new_event()
                a:append(string.format('{\\bord0\\shad0\\1a&00&\\1c&%s&}', color))
                a:pos(0, 0)
                a:draw_start()
            end
            if b[3] + border < 0 or b[4] + border < 0 then return end
            a:rect_cw(b[1] - border, b[2] - border, b[1] + b[3] + border, b[2] + b[4] + border)
        end

        -- each button has a little frame of 1px
        local border = 1
        for _, b in ipairs({play, pause, backwards, forwards, speakers, headphones, mute, volume}) do
            draw_button(b, border, '000000')
        end
        local is_pause = properties["pause"]
        local is_play = not is_pause
        local is_mute = properties["mute"]
        local is_speakers = properties["audio-client-name"] == 'mmp-speakers'
        local is_headphones = properties["audio-client-name"] == 'mmp-headphones'
        local current_volume = properties["volume"] / 100

        draw_button(backwards, -border, white, hovered_button == backwards and 0.15)
        draw_button(forwards, -border, white, hovered_button == forwards and 0.15)
        draw_button(play, -border, is_play and blue or white, hovered_button == play and 0.15)
        draw_button(pause, -border, is_pause and yellow or white, hovered_button == pause and 0.15)

        draw_button(speakers, -border, is_speakers and white or gray, hovered_button == speakers and 0.15)
        draw_button(headphones, -border, is_headphones and white or gray, hovered_button == headphones and 0.15)

        draw_button(mute, -border, is_mute and red or white, hovered_button == mute and 0.15)

        local v = volume
        draw_button({v[1], v[2], current_volume * v[3], v[4]}, -border, white, hovered_button == volume and 0.15)
        draw_button({v[1] + current_volume * v[3], v[2], (1 - current_volume) * v[3], v[4]}, -border, gray, hovered_button == volume and 0.15)

        local draw_icon = function(b, percent_margin, icon)
            a:new_event()
            local frac = percent_margin / 100
            a:append(string.format("{\\bord%i\\pos(%d,%d)\\fscx%i\\fscy%i}{\\an7\\p1}%s",
                border * 2,
                b[1] + b[3] * frac,
                b[2] + b[4] * frac,
                (1 - 2 * frac) * b[3],
                (1 - 2 * frac) * b[4],
                icon))
        end
        draw_icon(play, 30, "m 5 -5 l 5 105 l 105 50") -- slight forward advance (x += 5) to look more centered
        draw_icon(pause, 30, "m 0 0 l 0 100 l 35 100 l 35 0 m 65 0 l 65 100 l 100 100 l 100 0")
        draw_icon(forwards, 30, "m 0 0 l 0 100 l 45 70 l 45 100 l 100 50 l 45 0 l 45 30")
        draw_icon(backwards, 30, "m 100 0 l 100 100 l 55 70 l 55 100 l 0 50 l 55 0 l 55 30")

        draw_icon(speakers, 22, "m -5 5 l -5 105 l 30 105 l 30 5 m 70 5 l 70 105 l 105 105 l 105 5")
        local function circle(center, radius)
            return table.concat({
                'm', center[1], center[2] - radius,
                'b',  center[1] + radius, center[2] - radius,
                center[1] + radius, center[2] + radius,
                center[1], center[2] + radius,
                'b', center[1]  - radius, center[2] + radius,
                center[1] - radius, center[2] - radius,
                center[1], center[2] - radius
            }, ' ')
        end
        draw_icon(speakers, 22, '{\\1c&333333&}' ..
            circle({-5 + 35/2, 80}, 12) ..
            circle({-5 + 35/2, 30}, 7) ..
            circle({70 + 35/2, 80}, 12) ..
            circle({70 + 35/2, 30}, 7))
        draw_icon(headphones, 22, table.concat({ -- really could use some automatic symmetry... oh well
            'm', 50, 0,-- top of arch's highest point
            'b', 15, 0,
            15, 50,
            15, 60,     -- left can, arch connection
            'l', 5, 60, --left can, top left
            'b', 0, 60,
            0, 100,
            5, 100, -- left can, bottom left
            'l', 25, 100, -- left can, bottom right
            'l', 25, 60, -- left can, top right
            'l', 20, 60,
            'b', 20, 50,
            20, 10,
            50, 8, -- bottom of arch's highest point, symmetry point
            'b', 80, 10,
            80, 50,
            80, 60,
            'l', 75, 60,
            'l', 75, 100,
            'l', 95, 100,
            'b', 100, 100,
            100, 60,
            95, 60,
            'l', 85, 60,
            'b', 85, 50,
            85, 0,
            50, 0,
        }, ' '))

        draw_icon(mute, 30, "m 0 30 l 0 70 l 50 70 l 100 100 l 100 0 l 50 30")

        ass_text.buttons = a.text
        ass_changed = true
    end

    this.set_active = function(active_now)
        active = active_now
        if active then
            ass_text.background = get_background(position, size, focus)
            redraw_buttons()
            ass_changed = true
        end
    end

    local function press_button(table)
        if table["event"] == "up" then
            holding_volume = false
            return
        end

        local mx, my = mp.get_mouse_pos()
        local button = get_button_at(mx, my)
        if not button then return end

        if button == volume then
            holding_volume = true
            if holding_volume then
                vol = ((mx - volume[1]) / volume[3]) * 100
                send_to_server({"set", "volume", tostring(vol)})
            end
            return
        end

        if button == play then
            send_to_server({"set", "pause", "no"})
        elseif button == pause then
            send_to_server({"set", "pause", "yes"})
        elseif button == backwards then
            send_to_server({"add", "chapter", -1})
        elseif button == forwards then
            send_to_server({"add", "chapter", 1})
        elseif button == speakers then
            send_to_server({"set", "audio-client-name", "mmp-speakers"})
        elseif button == headphones then
            send_to_server({"set", "audio-client-name", "mmp-headphones"})
        elseif button == mute then
            send_to_server({"cycle", "mute"})
        end
    end

    local bindings = {
        {"MBTN_LEFT", press_button, {complex=true, repeatable=false}},
        {"m", function() send_to_server({"cycle", "mute"}) end, {}},
        {"s", function() send_to_server({"set", "audio-client-name", "mmp-speakers"}) end, {}},
        {"h", function() send_to_server({"set", "audio-client-name", "mmp-headphones"}) end, {}},
        {"RIGHT", function() send_to_server({"add", "chapter", 1}) end, {}},
        {"LEFT", function() send_to_server({"add", "chapter", -1}) end, {}},
        {"UP", function() send_to_server({"add", "volume", 5}) end, {repeatable=true}},
        {"DOWN", function() send_to_server({"add", "volume", -5}) end, {repeatable=true}},
    }

    this.set_focus = function(focus_now)
        focus = focus_now
        setup_bindings(bindings, "controls", focus)
        if not focus then holding_volume = false end
        ass_text.background = get_background(position, size, focus)
        ass_changed = true
    end

    this.set_geometry = function(x, y, w, h)
        position = { x, y }
        size = { w, h }
        local set_pos = function(comp, cx, cy, cw, ch)
            comp[1] = x + cx * w
            comp[2] = y + cy * h
            comp[3] = cw * w
            comp[4] = ch * h
        end
        set_pos(pause,      0.22, 0.1,   0.28, 0.28)
        set_pos(play,       0.5,  0.1,   0.28, 0.28)
        set_pos(backwards,  0.06, 0.16,  0.16, 0.16)
        set_pos(forwards,   0.78, 0.16,  0.16, 0.16)

        set_pos(speakers,   0.16, 0.46,  0.34, 0.24)
        set_pos(headphones, 0.5,  0.46,  0.34, 0.24)

        set_pos(mute,       0.05, 0.80,  0.15, 0.15)
        set_pos(volume,     0.23, 0.825, 0.72, 0.10)
        if active then
            ass_text.background = get_background(position, size, focus)
            redraw_buttons()
            ass_changed = true
        end
    end
    this.get_position = function()
        return position[1], position[2]
    end
    this.get_size = function()
        return size[1], size[2]
    end
    this.get_ass = function()
        return active and table.concat({ ass_text.background, ass_text.buttons }, '\n') or ''
    end

    this.prop_changed = {
        ["pause"] = redraw_buttons,
        ["mute"] = redraw_buttons,
        ["volume"] = redraw_buttons,
        ["audio-client-name"] = redraw_buttons,
    }

    this.mouse_move = function(mx, my)
        local new_button = get_button_at(mx, my)
        if holding_volume then
            vol = math.max(0, math.min((mx - volume[1]) / volume[3] * 100, 100))
            send_to_server({"set", "volume", tostring(vol)})
        elseif new_button ~= hovered_button then
            hovered_button = new_button
            redraw_buttons()
        end
    end

    this.idle = function() end
end

local lyrics_component = {}
do
    local this = lyrics_component

    local positon = { 0, 0 }
    local size = { 0, 0 }

    local active = false
    local focus = false

    local lyrics = {}
    local offset = 0
    local max_offset = 0
    local autoscrolling = true
    local track_start = 0
    local track_length = 0
    local text_size = 24
    local ass_text = {
        background = '',
        text = '',
    }

    local time_pos_coarse = -1

    local function redraw_lyrics()
        if #lyrics == 0 then
            if ass_text.text ~= '' then
                ass_text.text = ''
                ass_changed = true
            end
            return
        end
        local a = assdraw.ass_new()
        a:new_event()
        local fmt = string.format('{\\fs%i\\an8\\bord0\\shad0\\clip(%d,%d,%d,%d)}',
            text_size, position[1], position[2], position[1] + size[1], position[2] + size[2]
        )
        -- TODO don't draw unnecessary things
        for i, l in ipairs(lyrics) do
            a:new_event()
            a:pos(position[1] + size[1] / 2, position[2] - offset + (i - 1) * text_size)
            a:append(fmt .. l)
        end
        ass_text.text = a.text
        ass_changed = true
    end

    local function autoscroll()
        if not time_pos_coarse or time_pos_coarse == -1 then return end
        -- don't autoscroll during [0, grace_period] and [end - grace_period, end]
        local grace_period = math.max(track_length / 15, 20)
        local pos = time_pos_coarse - track_start
        if pos < grace_period then
            normalized = 0
        elseif pos > (track_length - grace_period) then
            normalized = 1
        else
            normalized = (pos - grace_period) / (track_length - 2 * grace_period)
        end
        offset = normalized * max_offset
        redraw_lyrics()
    end

    local function fetch_lyrics()
        offset = 0
        lyrics = {}
        local chapters = properties["chapter-list"]
        local chap = properties["chapter"]
        local duration = properties["duration"]
        local _, album = album_from_path(properties["path"])
        if #chapters == 0 or not chap or not duration or not album then
            redraw_lyrics()
            return
        end
        chap = math.max(chap + 1, 1)
        track_start = chapters[chap].time
        if chap == #chapters then
            track_length = duration - chapters[chap].time
        else
            track_length = chapters[chap + 1].time - chapters[chap].time
        end
        local title = string.match(chapters[chap].title, ".*/(%d+ .*)%..-")
        local path = string.format("%s/%s - %s/%s.lyr",
            opts.lyrics_dir,
            album.artist,
            album.album,
            title)
        local f = io.open(path, "r")
        if not f then
            msg.warn("Cannot open lyrics file " .. path)
            return
        end
        lyrics[1] = ''
        for line in string.gmatch(f:read("*all"), "([^\n]*)\n") do
            lyrics[#lyrics + 1] = line
        end
        f:close()
        lyrics[#lyrics + 1] = ''
        autoscrolling = true
        max_offset = math.max(0, #lyrics * text_size - size[2])
        autoscroll()
    end

    local function clear_lyrics()
        lyrics = {}
        redraw_lyrics()
    end

    local scroll = function(howmuch)
        offset = math.max(0, math.min(offset + howmuch, max_offset))
        autoscrolling = false
        redraw_lyrics()
    end

    local bindings = {
        {"a", function() autoscrolling = true autoscroll() end, {}},
        {"UP", function() scroll(-25) end, {repeatable=true}},
        {"DOWN", function() scroll(25) end, {repeatable=true}},
        {"WHEEL_UP", function() scroll(-15) end, {repeatable=true}},
        {"WHEEL_DOWN", function() scroll(15) end, {repeatable=true}},
    }

    this.set_active = function(active_now)
        active = active_now
        ass_text.background = get_background(position, size, focus)
        if active then
            fetch_lyrics()
            autoscrolling = true
        else
            clear_lyrics()
        end
        ass_changed = true
    end
    this.set_focus = function(focus_now)
        focus = focus_now
        setup_bindings(bindings, "lyrics", focus)
        ass_text.background = get_background(position, size, focus)
        ass_changed = true
    end

    this.set_geometry = function(x, y, w, h)
        position = { x, y }
        size = { w, h }
        if active then
            max_offset = math.max(0, #lyrics * text_size - size[2])
            offset = math.max(0, math.min(offset, max_offset))
            ass_text.background = get_background(position, size, focus)
            redraw_lyrics()
            ass_changed = true
        end
    end
    this.get_active = function()
        return active
    end
    this.get_position = function()
        return position[1], position[2]
    end
    this.get_size = function()
        return size[1], size[2]
    end
    this.get_ass = function()
        return active and ass_text.background .. "\n" .. ass_text.text or ''
    end

    this.prop_changed = {
        ["path"] = function(path) if path == '' then clear_lyrics() end end,
        ["chapter"] = function() fetch_lyrics() end,
        ["time-pos"] = function(value)
                           value = value - (value % 0.2)
                           if value == time_pos_coarse then return end
                           time_pos_coarse = value
                           if autoscrolling then
                               autoscroll()
                           end
                       end,
    }
    this.mouse_move = function(mx, my) end

    this.idle = function() end
end

function set_video_position(x, y, w, h)
    local ww, wh = mp.get_osd_size()
    local ratio = w / h
    local zoom_x = math.log(w / ww) / math.log(2)
    local zoom_y = math.log(h / wh) / math.log(2)
    local dist_y = y - (wh - h) / 2
    local pan_y = dist_y / h

    local dist_x = x - (ww - w) / 2
    local pan_x = dist_x / w

    mp.set_property_number("video-aspect-override", ratio)
    mp.set_property_number("video-zoom", math.max(zoom_x, zoom_y))
    mp.set_property_number("video-pan-y", pan_y)
    mp.set_property_number("video-pan-x", pan_x)

    -- doesn't work much better
    --local vf = string.format("scale=w=%s:h=%s,pad=w=%s:h=%s:x=%s:y=%s", w, h, ww, wh, x, y)
    --mp.set_property("vf", vf)
end

local components = {
    albums_component,
    queue_component,
    now_playing_component,
    lyrics_component,
    controls_component,
}
local layouts = {
    EMPTY = {},
    BROWSE = {
        albums_component,
        queue_component,
        now_playing_component,
        controls_component,
    },
    PLAYING = {
        now_playing_component,
        lyrics_component,
        controls_component,
    },
    PLAYING_SMALL = {
        now_playing_component,
    },
}
local active_layout = "EMPTY"
local focused_component = nil

function layout_geometry(ww, wh)
    local ww, wh = mp.get_osd_size()
    local x = global_offset
    local y = global_offset
    local w = ww - 2 * global_offset
    local h = wh - 2 * global_offset

    if active_layout == "BROWSE" then
        controls_component.set_geometry(x, y + h - 180, 180, 180)
        local tw = w - 180 - global_offset
        local tx = x + 180 + global_offset
        now_playing_component.set_geometry(tx, y + h - 180, tw, 180)
        h = h - 180 - global_offset

        queue_component.set_geometry(x + w - 200, y, 200, h)
        w = w - 200 - global_offset
        albums_component.set_geometry(x, y, w, h)
    elseif active_layout == "PLAYING" then
        now_playing_component.set_geometry(x, y, w, 180)
        y = y + 180 + global_offset
        h = h - (180 + global_offset)
        controls_component.set_geometry(x, y, 180, 180)
        x = x + 180 + global_offset
        w = w - 180 - global_offset
        local lyrics_w = math.min(w, 600)
        lyrics_component.set_geometry(x + (w - lyrics_w) / 2, y, lyrics_w, h)
    elseif active_layout == "PLAYING_SMALL" then
        now_playing_component.set_geometry(x, y, w, h)
    elseif active_layout == "EMPTY" then
    else
        assert(false)
    end
end

function set_active_layout(layout)
    if active_layout == layout then return end
    local deactivate = {}
    local prev_components = layouts[active_layout]
    for _, comp in ipairs(prev_components) do
        deactivate[comp] = true
    end
    active_layout = layout
    layout_geometry()
    local components = layouts[active_layout]
    for _, comp in ipairs(components) do
        if deactivate[comp] then
            deactivate[comp] = nil
        else
            comp.set_active(true)
        end
    end
    for comp, _ in pairs(deactivate) do
        if focused_component == comp then
            focused_component.set_focus(false)
            focused_component = nil
        end
        comp.set_active(false)
    end
    if not focused_component and #components > 0 then
        components[1].set_focus(true)
        focused_component = components[1]
    end
end

function focus_next_component(backwards)
    local active_components = layouts[active_layout]
    if not focused_component then
        focused_component = active_components[1]
        focused_component.set_focus(true)
    else
        local index_0
        for i, comp in ipairs(active_components) do
            if comp == focused_component then
                index_0 = i - 1
                break
            end
        end
        local next = ((index_0 + (backwards and -1 or 1)) % #active_components) + 1
        focused_component.set_focus(false)
        focused_component = active_components[next]
        focused_component.set_focus(true)
    end
end

local size_changed = false
for _, prop in ipairs({"osd-width", "osd-height"}) do
    mp.observe_property(prop, "native", function() size_changed = true end)
end
local prev_focused_component = nil
mp.observe_property("focused", "native", function(_, val)
    if val and not focused_component and prev_focused_component then
        focused_component = prev_focused_component
        focused_component.set_focus(true)
        prev_focused_component = nil
    elseif not val and focused_component then
        focused_component.set_focus(false)
        prev_focused_component = focused_component
        focused_component = nil
    end
end)

function component_from_pos(x, y)
    for _, comp in ipairs(layouts[active_layout]) do
        local nx, ny = normalized_coordinates({x, y}, {comp.get_position()}, {comp.get_size()})
        if nx >= 0 and ny >= 0 and nx <= 1 and ny <= 1 then
            return comp
        end
    end
    return nil
end

local mouse_moved = false

setup_bindings({
    {"SPACE", function() send_to_server({"cycle", "pause"}) end, {}},
    {"TAB", function() focus_next_component(false) end, { repeatable=true }},
    {"SHIFT+TAB", function() focus_next_component(true) end, { repeatable=true }},
    {"mouse_move", function() mouse_moved = true end, {}},
}, "global", true)

mp.add_key_binding(nil, "music-player-set-layout", set_active_layout)

local started = false

-- coalesce stuff together
local props_changed = {}
mp.register_script_message("prop-changed", function(name, value)
    if name == "chapter-list" or name == "playlist" then
        value = value and utils.parse_json(value) or {}
    elseif name == "mute" or name == "pause" then
        value = (value == "yes")
    elseif name == "time-pos" or name == "duration" or name == "chapter" or name == "volume" then
        value = tonumber(value) or -1
    else
        value = value or ''
    end
    props_changed[name] = value
end)

mp.register_idle(function()
    for k, v in pairs(props_changed) do
        properties[k] = v
    end
    for k, v in pairs(props_changed) do
        for _, comp in ipairs(layouts[active_layout]) do
            local func = comp.prop_changed[k]
            if func then func(v) end
        end
    end
    props_changed = {}

    for _, comp in ipairs(layouts[active_layout]) do
        comp.idle()
    end
    if size_changed then
        size_changed = false
        local ww, wh = mp.get_osd_size()
        if ww and wh and ww * wh >= 1 then
            if started then
                layout_geometry()
            else
                started = true
                set_active_layout(opts.default_layout)
            end
        end
    end
    if mouse_moved then
        mouse_moved = false
        local x, y = mp.get_mouse_pos()
        local comp = component_from_pos(x, y)
        if comp then
            if comp ~= focused_component then
                if focused_component then
                    focused_component.set_focus(false)
                end
                focused_component = comp
                focused_component.set_focus(true)
            end
            comp.mouse_move(x, y)
        end
    end
    if ass_changed then
        ass_changed = false
        local ww, wh = mp.get_osd_size()
        mp.set_osd_ass(ww, wh, table.concat({
            albums_component.get_ass(),
            queue_component.get_ass(),
            now_playing_component.get_ass(),
            lyrics_component.get_ass(),
            controls_component.get_ass(),
        }, "\n"))
    end
end)

local start_time = mp.get_time()
local start_listener
start_listener = mp.add_periodic_timer(0.05, function()
    local time = mp.get_time()
    if time - start_time > 3 then
        start_listener:kill()
        return
    end
    mp.commandv("script_message-to", "listener", "listener-start", opts.socket, mp.get_script_name())
end)

collectgarbage()
