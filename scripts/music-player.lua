local client = require 'socket.unix'()
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local gallery = require 'lib/gallery'

local opts = {
    root_dir = "/home/omtose/media/music/audio",
    thumbs_dir = "/home/omtose/media/music/thumbs",
    waveforms_dir = "/home/omtose/media/music/waveform",
    lyrics_dir = "/home/omtose/media/music/lyrics",
    albums_file = "", -- for optimization purposes
    socket = "bob",
    default_layout = "BROWSE",
}
(require 'mp.options').read_options(opts)

if not client:connect(opts.socket) then
    msg.error("Cannot connect, aborting")
    return
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

-- CONFIG
local global_offset = 25
local background_focus="DDDDDD"
local background_idle="999999"
local chapters_marker_width=3
local chapters_marker_color="888888"
local cursor_bar_width=3
local seekbar_snap_distance=15
local cursor_bar_color="BBBBBB"
local background_opacity= "BB"
local waveform_padding_proportion=2/3
local title_text_size=32
local artist_album_text_size=24
local time_text_size=24
local darker_text_color="888888"

-- VARS
local ass_changed = false

local seekbar_overlay_index = 0

local albums = {}
local queue = {}

properties = {
    ["path"] = "",
    ["playlist"] = {},
    ["pause"] = false,
    ["time-pos"] = -1,
    ["chapter"] = -1,
    ["chapter-list"] = {},
    ["duration"] = -1,
    ["mute"] = false,
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

if opts.albums_file == "" then
    local artists = utils.readdir(opts.root_dir)
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

function normalized_coordinates(coord, position, size)
    return (coord[1] - position[1]) / size[1], (coord[2] - position[2]) / size[2]
end

local queue_component = {}
do
    local this = queue_component
    this.gallery = gallery_new()

    this.gallery.items = queue
    this.gallery.config.always_show_placeholders = false
    this.gallery.config.align_text = false
    this.gallery.config.max_thumbnails = 16
    this.gallery.config.overlay_range = 49
    this.gallery.config.background_color = background_idle
    this.gallery.config.background_opacity = background_opacity
    this.gallery.geometry.min_spacing = {15,30}
    this.gallery.geometry.thumbnail_size = {150,150}

    this.gallery.item_to_overlay_path = function(index, item)
        local album = albums[item]
        return string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
            album.artist, album.album,
            this.gallery.geometry.thumbnail_size[1],
            this.gallery.geometry.thumbnail_size[2]
        )
    end
    this.gallery.item_to_border = function(index, item)
        if index == this.gallery.selection then
            return 3, "AAAAAA"
        end
        return 1, "BBBBBB"
    end
    this.gallery.item_to_text = function(index, item)
        return ""
    end
    this.ass_text = ""
    this.gallery.ass_show = function(ass)
        this.ass_text = ass
        ass_changed = true
    end

    this.set_active = function(active)
        if active then
            this.gallery:activate();
        else
            this.gallery:deactivate();
        end
    end
    this.set_focus = function(focus)
        this.gallery.config.background_color = focus and background_focus or background_idle
        this.gallery:ass_refresh(false, false, false, true)
    end
    this.set_geometry = function(x, y, w, h)
        this.gallery:set_geometry(x, y, w, h)
    end
    this.position = function()
        return this.gallery.geometry.position[1], this.gallery.geometry.position[2]
    end
    this.size = function()
        return this.gallery.geometry.size[1], this.gallery.geometry.size[2]
    end
    this.ass = function()
        return this.ass_text
    end

    local pending_selection = nil

    -- not part of the interface

    local function increase_pending(inc)
        pending_selection = (pending_selection or this.gallery.selection) + inc
    end
    local function remove_from_queue()
        if #queue == 0 then return end
        -- playlist-remove is 0-indexed, but queue doesn't contain the current one anyway
        local play_index = this.gallery.selection
        send_to_server({"playlist-remove", tostring(play_index)})
        this.gallery:set_selection(play_index + (play_index == #queue and -1 or 1))
    end
    local function play_from_queue()
        if #queue == 0 then return end
        local play_index = this.gallery.selection
        --send_to_server({"playlist-move", tostring(play_index), "1"})
        --send_to_server({"set_property", "playlist-pos", "1"})
        send_to_server({"script_message", "start_playing", tostring(play_index)})
        this.gallery:set_selection(play_index + (play_index == #queue and -1 or 1))
    end

    this.prop_changed = {
        ["playlist"] = function(val)
            -- queue = {} is no good because it creates a new object or something
            local prev_index = queue[this.gallery.selection]
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
            this.gallery:items_changed()
            if new_sel then
                this.gallery:set_selection(new_sel)
            elseif #queue > 0 then
                this.gallery:set_selection(1)
            end
        end
    }
    this.keys_repeat = {
        LEFT = function() increase_pending(-1) end,
        RIGHT = function() increase_pending(1) end,
        UP = function() increase_pending(-this.gallery.geometry.columns) end,
        DOWN = function() increase_pending(this.gallery.geometry.columns) end,
    }
    this.keys = {
        WHEEL_UP = function() increase_pending(-this.gallery.geometry.columns) end,
        WHEEL_DOWN = function() increase_pending(this.gallery.geometry.columns) end,
        ENTER = function() play_from_queue() end,
        DEL = function() if #queue > 0 then remove_from_queue() end end,
        MBTN_LEFT = function()
            local mx, my = mp.get_mouse_pos()
            local index = this.gallery:index_at(mx, my)
            if not index then return end
            if index == this.gallery.selection then
                play_from_queue()
            else
                pending_selection = index
            end
        end,
        MBTN_RIGHT = function()
            local mx, my = mp.get_mouse_pos()
            local index = this.gallery:index_at(mx, my)
            if not index then return end
            if index == this.gallery.selection then
                remove_from_queue()
            else
                pending_selection = index
            end
        end,
    }
    this.mouse_move = function(mx, my) end

    this.idle = function()
        if pending_selection then
            this.gallery:set_selection(pending_selection)
            pending_selection = nil
        end
    end
end

local albums_component = {}
do
    local this = albums_component -- mfw oop

    this.gallery = gallery_new()

    this.gallery.items = albums
    this.gallery.config.always_show_placeholders = false
    this.gallery.config.align_text = true
    this.gallery.config.max_thumbnails = 48
    this.gallery.config.overlay_range = 1
    this.gallery.config.background_color = background_idle
    this.gallery.config.background_opacity = background_opacity
    this.gallery.geometry.min_spacing = {15,30}
    this.gallery.geometry.thumbnail_size = {150,150}

    this.gallery.item_to_overlay_path = function(index, item)
        return string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
            item.artist, item.album,
            this.gallery.geometry.thumbnail_size[1],
            this.gallery.geometry.thumbnail_size[2]
        )
    end
    this.gallery.item_to_border = function(index, item)
        if index == this.gallery.selection then
            return 4, "AAAAAA"
        end
        return 0.8, "BBBBBB"
    end
    this.gallery.item_to_text = function(index, item)
        if index == this.gallery.selection then
            return string.format("%s - %s [%d]", item.artist, item.album, item.year)
        end
        return ""
    end
    this.ass_text = ""
    this.gallery.ass_show = function(ass)
        this.ass_text = ass
        ass_changed = true
    end

    this.set_active = function(active)
        if active then
            this.gallery:activate();
        else
            this.gallery:deactivate();
        end
    end
    this.set_focus = function(focus)
        this.gallery.config.background_color = focus and background_focus or background_idle
        this.gallery:ass_refresh(false, false, false, true)
    end
    this.set_geometry = function(x, y, w, h)
        this.gallery:set_geometry(x, y, w, h)
    end
    this.position = function()
        return this.gallery.geometry.position[1], this.gallery.geometry.position[2]
    end
    this.size = function()
        return this.gallery.geometry.size[1], this.gallery.geometry.size[2]
    end
    this.ass = function()
        return this.ass_text
    end

    local pending_selection = nil

    local function increase_pending(inc)
        pending_selection = (pending_selection or this.gallery.selection) + inc
    end

    this.prop_changed = {}
    this.keys_repeat = {
        r = function() pending_selection = math.random(1, #albums) end,
        LEFT = function() increase_pending(-1) end,
        RIGHT = function() increase_pending(1) end,
        UP = function() increase_pending(-this.gallery.geometry.columns) end,
        DOWN = function() increase_pending(this.gallery.geometry.columns) end,
    }
    this.keys = {
        WHEEL_UP = function() increase_pending(-this.gallery.geometry.columns) end,
        WHEEL_DOWN = function() increase_pending(this.gallery.geometry.columns) end,
        HOME = function() pending_selection = 1 end,
        END = function() pending_selection = #albums end,
        ENTER = function() play(this.gallery.selection) end,
        MBTN_LEFT = function()
            local mx, my = mp.get_mouse_pos()
            local index = this.gallery:index_at(mx, my)
            if not index then return end
            if index == this.gallery.selection then
                play(index)
            else
                this.gallery:set_selection(index)
            end
        end,
    }
    this.mouse_move = function(mx, my) end

    this.idle = function()
        if pending_selection then
            this.gallery:set_selection(pending_selection)
            pending_selection = nil
        end
    end
end

local now_playing_component = {}
do
    local this = now_playing_component
    this.geometry = {
        position = {0,0},
        size = {0,0},
        waveform_position = {0,0},
        waveform_size = {0,0},
        cover_position = {0,0},
        cover_size = {0,0},
        text_position = {0,0},
        times_position = {0, 0},
    }
    this.ass_text = {
        background = "",
        elapsed = "",
        times = "",
        chapters = "",
        text = "",
    }
    this.active = false

    local function redraw_chapters()
        local duration = properties["duration"]
        local chapters = properties["chapter-list"]
        if not duration or #chapters == 0 then
            this.ass_text.chapters = ""
            ass_changed = true
            return
        end
        local a = assdraw.ass_new()
        a:new_event()
        a:pos(0, 0)
        a:append('{\\bord0\\shad0\\1c&' .. chapters_marker_color .. '}')
        a:draw_start()
        local w = chapters_marker_width/2
        local g = this.geometry
        local y1 = g.waveform_position[2]
        local y2 = y1 + g.waveform_size[2]
        for _, chap in ipairs(chapters) do
            local x = g.waveform_position[1] + g.waveform_size[1] * (chap.time / duration)
            a:rect_cw(x - w, y1, x + w, y2)
        end
        local x = g.waveform_position[1] + g.waveform_size[1]
        a:rect_cw(x - w, y1, x + w, y2)
        a:new_event()
        a:pos(g.text_position[1], g.text_position[2] + (title_text_size + artist_album_text_size) / 2 - 5)
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
        this.ass_text.chapters = a.text
        ass_changed = true
    end

    local function redraw_times()
        local duration = properties["duration"]
        if duration == -1 then
            if this.ass_text.times ~= "" then
                this.ass_text.times = ""
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

        local g = this.geometry
        local a = assdraw.ass_new()
        local show_time_at = function(x)
            if not x then return end
            local time = (x - g.waveform_position[1]) / g.waveform_size[1] * duration
            local align = "8"
            if math.abs(x - g.waveform_position[1]) < (time_width / 2) then
                align = "7"
                x = g.waveform_position[1]
            elseif math.abs(x - (g.waveform_position[1] + g.waveform_size[1])) < (time_width / 2) then
                align = "9"
                x = g.waveform_position[1] + g.waveform_size[1]
            end
            a:new_event()
            a:pos(x, g.times_position[2])
            a:append(string.format("{\\an%s\\fs%s\\bord0}", align, time_text_size))
            a:append(format_time(time))
        end

        local cursor_x = nil
        local end_x = g.waveform_position[1] + g.waveform_size[1]
        local current_x = nil

        do
            local mx, my = mp.get_mouse_pos()
            local tx = mx - g.waveform_position[1]
            local ty = my - g.waveform_position[2]
            if tx >= 0 and tx <= g.waveform_size[1] and ty >= 0 and ty <= g.waveform_size[2] then
                cursor_x = mx
                for _, chap in ipairs(properties["chapter-list"]) do
                    local chap_x = g.waveform_position[1] + chap.time / duration * g.waveform_size[1]
                    if math.abs(chap_x - cursor_x) < seekbar_snap_distance then
                        cursor_x = chap_x
                    end
                end
            end
        end
        local pos = properties["time-pos"]
        if pos and duration then
            current_x = g.waveform_position[1] + g.waveform_size[1] * (pos / duration)
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

        this.ass_text.times = a.text
        ass_changed = true
    end

    local function redraw_elapsed()
        local pos = properties["time-pos"]
        local duration = properties["duration"]
        if duration == -1 or pos == -1 then
            if this.ass_text.elapsed ~= "" then
                this.ass_text.elapsed = ""
                ass_changed = true
            end
            return
        end
        local a = assdraw.ass_new()
        a:new_event()
        a:append(string.format('{\\bord0\\shad0\\1c&%s\\1a&%s}', "222222", "AA"))
        a:pos(0,0)
        a:draw_start()
        local y1 = this.geometry.waveform_position[2]
        local y2 = y1 + this.geometry.waveform_size[2]
        local x1 = this.geometry.waveform_position[1]
        local x2 = x1 + this.geometry.waveform_size[1] * (pos / duration)
        a:rect_cw(x1, y1, x2, y2)
        this.ass_text.elapsed = a.text
        ass_changed = true
    end

    local function redraw_background(color)
        if not this.active then
            this.ass_text.background = ""
            ass_changed = true
            return
        end
        local a = assdraw.ass_new()
        a:new_event()
        a:append(string.format('{\\bord0\\shad0\\1a&%s&\\1c&%s&}', background_opacity, color))
        a:pos(0, 0)
        --a:append('{\\iclip(4,')
        --local ww, wh = mp.get_osd_size()
        --a:rect_cw(seekbar_position[1] + 30, seekbar_position[2] + 30, seekbar_position[1] + seekbar_size[1] - 30, seekbar_position[2] + seekbar_size[2] - 30)
        --a:append(')}')
        a:draw_start()
        local g = this.geometry
        a:round_rect_cw(g.position[1], g.position[2], g.position[1] + g.size[1], g.position[2] + g.size[2], 5)
        this.ass_text.background = a.text
        ass_changed = true
    end

    local function set_waveform()
        local _, album = album_from_path(properties["path"])
        if not this.active or not album then
            mp.commandv("playlist-remove", "current")
            return
        end
        local wavefile = string.format("%s/%d - %s.png", opts.waveforms_dir, album.year, string.gsub(album.album, ':', '\\:'))
        mp.commandv("loadfile", wavefile, "replace")
    end

    local function set_overlay()
        local _, album = album_from_path(properties["path"])
        if not this.active or not album then
            mp.commandv("overlay-remove", seekbar_overlay_index)
            return
        end
        local g = this.geometry
        mp.commandv("overlay-add",
            seekbar_overlay_index,
            tostring(math.floor(g.cover_position[1] + 0.5)),
            tostring(math.floor(g.cover_position[2] + 0.5)),
            string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
                album.artist, album.album,
                g.cover_size[1],
                g.cover_size[2]),
            "0",
            "bgra",
            tostring(g.cover_size[1]),
            tostring(g.cover_size[2]),
            tostring(4*g.cover_size[1]))
    end

    this.set_active = function(active)
        this.active = active
        set_overlay()
        set_waveform()
        redraw_elapsed()
        redraw_times()
        redraw_chapters()
        redraw_background(background_idle)
    end
    this.set_focus = function(focus)
        redraw_background(focus and background_focus or background_idle)
    end
    this.set_geometry = function(x, y, w, h)
        local g = this.geometry
        g.position = { x, y }
        g.size = { w, h }
        g.cover_size = { 150, 150 }

        local dist_w = 10
        g.cover_position = { x + dist_w, y + (h - g.cover_size[2]) / 2 }

        local dist_h = 10
        g.text_position = { x + g.cover_size[1] + 2 * dist_w, y + dist_h}

        g.waveform_position = { g.text_position[1], g.text_position[2] + artist_album_text_size + title_text_size }
        g.waveform_size = { w - g.cover_size[1] - 3 * dist_w, h - 2 * dist_h - (artist_album_text_size + title_text_size + time_text_size) }
        g.times_position = { g.text_position[1], g.waveform_position[2] + g.waveform_size[2] }

        set_video_position(g.waveform_position[1], g.waveform_position[2] - 0.5 * waveform_padding_proportion * g.waveform_size[2] / (1 - waveform_padding_proportion), g.waveform_size[1], g.waveform_size[2] / (1 - waveform_padding_proportion))
        if this.active then
            set_overlay()
            redraw_background(focus and background_focus or background_idle)
            redraw_elapsed()
            redraw_times()
            redraw_chapters()
        end
    end

    this.position = function()
        return this.geometry.position[1], this.geometry.position[2]
    end
    this.size = function()
        return this.geometry.size[1], this.geometry.size[2]
    end
    this.ass = function()
        return this.active and table.concat({
            this.ass_text.background,
            this.ass_text.elapsed,
            this.ass_text.times,
            this.ass_text.chapters,
            this.ass_text.text,
        }, "\n") or ""
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
        ["time-pos"] = function() redraw_elapsed() redraw_times() end,
        ["duration"] = function() redraw_chapters() redraw_elapsed() end,
    }
    this.keys_repeat = {
        UP = function() send_to_server({"seek", "30", "exact"}) end,
        DOWN = function() send_to_server({"seek", "-30", "exact"}) end,
        LEFT = function() send_to_server({"seek", "-5", "exact"}) end,
        RIGHT = function() send_to_server({"seek", "5", "exact"}) end,
    }
    this.keys = {
        SPACE = function() send_to_server({"set_property", "pause", properties["pause"] and "no" or "yes"}) end,
        PGUP = function() send_to_server({"add", "chapter", "1"}) end,
        PGDWN = function() send_to_server({"add", "chapter", "-1"}) end,
        DEL = function() send_to_server({"playlist-remove", "0"}) end,
        MBTN_RIGHT = function()
            local x, y = normalized_coordinates({mp.get_mouse_pos()}, this.geometry.cover_position, this.geometry.cover_size)
            if x < 0 or y < 0 or x > 1 or y > 1 then return end
            send_to_server({"playlist-remove", "0"})
        end,
        MBTN_LEFT = function()
            local duration = properties["duration"]
            local chapters = properties["chapter-list"]
            if not duration or not chapters then return end
            local mouse_pos = {mp.get_mouse_pos()}
            local x, y = normalized_coordinates(mouse_pos, this.geometry.waveform_position, this.geometry.waveform_size)
            if x >= 0 and y >= 0 and x <= 1 and y <= 1 then
                local snap_chap = nil
                local min_dist = nil
                for _, chap in ipairs(chapters) do
                    local dist = math.abs(x - chap.time / duration)
                    if dist * this.geometry.waveform_size[1] < seekbar_snap_distance then
                        if not snap_chap or dist < min_dist then
                            snap_chap = chap.time
                            min_dist = dist
                        end
                    end
                end
                send_to_server({"set_property", "time-pos", tostring(snap_chap or x * duration)})
                return
            end
            local x, y = normalized_coordinates(mouse_pos, this.geometry.cover_position, this.geometry.cover_size)
            if x >= 0 and y >= 0 and x <= 1 and y <= 1 then
                send_to_server({"set_property", "pause", properties["pause"] and "no" or "yes"})
                return
            end
        end,
    }
    local cursor_visible = false
    this.mouse_move = function(mx, my)
        if not properties["path"] then return end
        local x, y = normalized_coordinates({mx, my}, this.geometry.waveform_position, this.geometry.waveform_size)
        if x >= 0 and y >= 0 and x <= 1 and y <= 1 then
            redraw_times()
            cursor_visible = true
        elseif cursor_visible then
            redraw_times()
            cursor_visible = false
        end
    end

    this.idle = function() end
end

local lyrics_component = {}
do
    local this = lyrics_component

    this.geometry = {
        positon = { 0, 0 },
        size = { 0, 0 },
    }
    this.lyrics = {}
    this.offset = 0
    this.max_offset = 0
    this.active = false
    this.has_focus = false
    this.autoscrolling = true
    this.track_start = 0
    this.track_length = 0
    this.ass_text = {
        background = "",
        text = "",
    }

    local function redraw_background(color)
        local a = assdraw.ass_new()
        a:new_event()
        a:append(string.format('{\\bord0\\shad0\\1a&%s&\\1c&%s&}', background_opacity, color))
        a:pos(0, 0)
        a:draw_start()
        local g = this.geometry
        a:round_rect_cw(g.position[1], g.position[2], g.position[1] + g.size[1], g.position[2] + g.size[2], 5)
        this.ass_text.background = a.text
        ass_changed = true
    end

    local function redraw_lyrics()
        if #this.lyrics == 0 then
            if this.ass_text.text ~= "" then
                this.ass_text.text = ""
                ass_changed = true
            end
            return
        end
        local g = this.geometry
        local a = assdraw.ass_new()
        a:new_event()
        local fmt = string.format('{\\fs24\\an8\\bord0\\shad0\\clip(%d,%d,%d,%d)}',
            g.position[1], g.position[2], g.position[1] + g.size[1], g.position[2] + g.size[2]
        )
        -- TODO don't draw unnecessary things
        for i, l in ipairs(this.lyrics) do
            a:new_event()
            a:pos(g.position[1] + g.size[1] / 2, g.position[2] - this.offset + (i - 1) * 24)
            a:append(fmt .. l)
        end
        this.ass_text.text = a.text
        ass_changed = true
    end

    local function autoscroll()
        local time_pos = properties["time-pos"]
        if not time_pos then return end
        -- don't autoscroll during [0, grace_period] and [end - grace_period, end]
        local grace_period = math.max(this.track_length / 15, 20)
        local pos = time_pos - this.track_start
        if pos < grace_period then
            normalized = 0
        elseif pos > (this.track_length - grace_period) then
            normalized = 1
        else
            normalized = (pos - grace_period) / (this.track_length - 2 * grace_period)
        end
        this.offset = normalized * this.max_offset
        redraw_lyrics()
    end

    local function fetch_lyrics()
        this.offset = 0
        this.lyrics = {}
        local chapters = properties["chapter-list"]
        local chap = properties["chapter"]
        local duration = properties["duration"]
        local _, album = album_from_path(properties["path"])
        if #chapters == 0 or not chap or not duration or not album then
            redraw_lyrics()
            return
        end
        chap = math.max(chap + 1, 1)
        this.track_start = chapters[chap].time
        if chap == #chapters then
            this.track_length = duration - chapters[chap].time
        else
            this.track_length = chapters[chap + 1].time - chapters[chap].time
        end
        local title = string.match(chapters[chap].title, ".*/(%d+ .*)%..-")
        local f = io.open(string.format("%s/%s - %s/%s.lyr",
            opts.lyrics_dir,
            album.artist,
            album.album,
            title), "r")
        if not f then
            msg.warn("Cannot open lyrics file")
            return
        end
        this.lyrics[1] = ""
        for line in string.gmatch(f:read("*all"), "([^\n]*)\n") do
            this.lyrics[#this.lyrics + 1] = line
        end
        f:close()
        this.lyrics[#this.lyrics + 1] = ""
        this.autoscrolling = true
        this.max_offset = math.max(0, #this.lyrics * 24 - this.geometry.size[2])
        autoscroll()
    end

    local function clear_lyrics()
        this.lyrics = {}
        redraw_lyrics()
    end

    this.set_active = function(active)
        this.active = active
        redraw_background(background_idle)
        if active then
            fetch_lyrics()
            this.autoscrolling = true
        else
            clear_lyrics()
        end
    end
    this.set_focus = function(focus)
        this.has_focus = focus
        redraw_background(this.has_focus and background_focus or background_idle)
    end
    this.set_geometry = function(x, y, w, h)
        this.geometry.position = { x, y }
        this.geometry.size = { w, h }
        if this.active then
            this.max_offset = math.max(0, #this.lyrics * 24 - this.geometry.size[2])
            this.offset = math.max(0, math.min(this.offset, this.max_offset))
            redraw_background(this.has_focus and background_focus or background_idle)
            redraw_lyrics()
        end
    end
    this.position = function()
        return this.geometry.position[1], this.geometry.position[2]
    end
    this.size = function()
        return this.geometry.size[1], this.geometry.size[2]
    end
    this.ass = function()
        return this.active and this.ass_text.background .. "\n" .. this.ass_text.text or ""
    end

    local scroll = function(howmuch)
        this.offset = math.max(0, math.min(this.offset + howmuch, this.max_offset))
        this.autoscrolling = false
        redraw_lyrics()
    end
    this.prop_changed = {
        ["path"] = function(path) if path == "" then clear_lyrics() end end,
        ["chapter"] = function() fetch_lyrics() end,
        ["time-pos"] = function() if this.autoscrolling then autoscroll() end end,
    }
    this.keys_repeat = {
        a = function() this.autoscrolling = true autoscroll() end,
        UP = function() scroll(-25) end,
        DOWN = function() scroll(25) end,
    }
    this.keys = {
        WHEEL_UP = function() scroll(-15) end,
        WHEEL_DOWN = function() scroll(15) end,
    }
    this.mouse_move = function(mx, my) end

    this.idle = function() end
end

function set_video_position(x, y, w, h)
    local ww, wh = mp.get_osd_size()
    local ratio = w / h
    local zoom = math.log(w / ww) / math.log(2)
    local dist_y = y - (wh - h) / 2
    local pan_y = dist_y / h

    local dist_x = x - (ww - w) / 2
    local pan_x = dist_x / w

    mp.set_property_number("video-aspect-override", ratio)
    mp.set_property_number("video-zoom", zoom)
    mp.set_property_number("video-pan-y", pan_y)
    mp.set_property_number("video-pan-x", pan_x)

    -- doesn't work much better
    --local vf = string.format("scale=w=%s:h=%s,pad=w=%s:h=%s:x=%s:y=%s", w, h, ww, wh, x, y)
    --mp.set_property("vf", vf)
end

function play(album_index)
    local album = albums[album_index]
    local files = utils.readdir(album.dir)
    if not files then return end
    table.sort(files)
    for i, file in ipairs(files) do
        file = album.dir .. "/" .. file
        files[i] = string.format("%%%i%%%s", string.len(file), file)
    end
    send_to_server({"loadfile", "edl://" .. table.concat(files, ';'), "append-play"})
end

local components = {
    albums_component,
    queue_component,
    now_playing_component,
    lyrics_component,
}
local layouts = {
    EMPTY = {},
    BROWSE = {
        albums_component,
        queue_component,
    },
    PLAYING = {
        now_playing_component,
        lyrics_component,
    },
    PLAYING_SMALL = {
        now_playing_component,
    },
}
local active_layout = "EMPTY"

function layout_geometry(ww, wh)
    local ww, wh = mp.get_osd_size()
    local x = global_offset
    local y = global_offset
    local w = ww - 2 * global_offset
    local h = wh - 2 * global_offset

    if active_layout == "BROWSE" then
        queue_component.set_geometry(x + w - 200, y, 200, h)
        w = w - 200 - global_offset

        albums_component.set_geometry(x, y, w, h)
    elseif active_layout == "PLAYING" then
        now_playing_component.set_geometry(x, y, w, 180)
        y = y + 180 + global_offset
        h = h - (180 + global_offset)

        local lyrics_w = math.min(w, math.max(600, w / 3))
        lyrics_component.set_geometry(x + (w - lyrics_w) / 2, y, lyrics_w, h)
    elseif active_layout == "PLAYING_SMALL" then
        now_playing_component.set_geometry(x, y, w, 180)
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

do
    local all_keys = {}
    for _, comp in ipairs(components) do
        for key, _ in pairs(comp.keys) do
            all_keys[key] = true
        end
        for key, _ in pairs(comp.keys_repeat) do
            all_keys[key] = true
        end
    end
    for key, _ in pairs(all_keys) do
        mp.add_forced_key_binding(key, "bind-" .. key, function(table)
            if not focused_component then return end
            if table["event"] == "down" then
                local func = focused_component.keys_repeat[key] or focused_component.keys[key]
                if func then func() end
            elseif table["event"] == "repeat" then
                func = focused_component.keys_repeat[key]
                if func then func() end
            end
        end, { repeatable=true, complex=true })
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

mp.add_forced_key_binding("TAB", "tab", function() focus_next_component(false) end, { repeatable=true })
mp.add_forced_key_binding("SHIFT+TAB", "backtab", function() focus_next_component(true) end, { repeatable=true })

local size_changed = false
for _, prop in ipairs({"osd-width", "osd-height"}) do
    mp.observe_property(prop, "native", function() size_changed = true end)
end

local mouse_moved = false
mp.add_forced_key_binding("mouse_move", function() mouse_moved = true end)

function component_from_pos(x, y)
    for _, comp in ipairs(layouts[active_layout]) do
        local nx, ny = normalized_coordinates({x, y}, {comp.position()}, {comp.size()})
        if nx >= 0 and ny >= 0 and nx <= 1 and ny <= 1 then
            return comp
        end
    end
    return nil
end

local started = false
mp.add_forced_key_binding(nil, "music-player-set-layout", set_active_layout)

-- coalesce stuff together
local props_changed = {}
mp.register_script_message("prop-changed", function(name, value)
    if name == "chapter-list" or name == "playlist" then
        value = utils.parse_json(value) or {}
    elseif name == "mute" or name == "pause" then
        value = (value == "yes")
    elseif name == "time-pos" or name == "duration" or name == "chapter" then
        value = tonumber(value) or -1
    else
        value = value or ""
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
            albums_component.ass(),
            queue_component.ass(),
            now_playing_component.ass(),
            lyrics_component.ass(),
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
