local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local gallery = require 'lib/gallery'

local opts = {
    root_dir = "music",
    thumbs_dir = "thumbs",
    waveforms_dir = "waveform",
    albums_file = "", -- for optimization purposes
}

-- CONFIG
local global_offset = 25
local background_focus="DDDDDD"
local background_idle="999999"
local chapters_marker_width=3
local chapters_marker_color="888888"
local cursor_bar_width=3
local cursor_bar_color="BBBBBB"
local background_opacity= "BB"
local waveform_padding_proportion=2/3
local title_text_size=32
local artist_album_text_size=24
local time_text_size=24
local darker_text_color="888888"

-- VARS
local focus = nil -- 0,1,2,3 is respectively none, gallery_main/lyrics, gallery_queue, seekbar
local ass_changed = false

local seekbar_overlay_index = 0

local playing_index = nil

local albums = {}
local queue = {}

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
    this.active = function() return gallery.active end
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

    this.pending_selection = nil

    this.keys = {
        LEFT = function()
            this.pending_selection = this.pending_selection and this.pending_selection - 1 or this.gallery.selection - 1
        end,
        RIGHT = function()
            this.pending_selection = this.pending_selection and this.pending_selection + 1 or this.gallery.selection + 1
        end,
        UP = function() end,
        DOWN = function() end,
        ENTER = function()
            if #queue > 0 then
                play(table.remove(queue, this.gallery.selection))
                if this.gallery.selection > #queue then
                    this.gallery:set_selection(this.gallery.selection - 1)
                end
                this.gallery:items_changed()
            end
        end,
    }
    this.mouse_move = function(mx, my) end

    this.idle = function()
        if this.pending_selection then
            this.gallery:set_selection(this.pending_selection)
            this.pending_selection = nil
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
    this.active = function() return gallery.active end
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

    this.pending_selection = nil

    this.keys = {
        LEFT = function()
            this.pending_selection = this.pending_selection and this.pending_selection - 1 or this.gallery.selection - 1
        end,
        RIGHT = function()
            this.pending_selection = this.pending_selection and this.pending_selection + 1 or this.gallery.selection + 1
        end,
        UP = function() end,
        DOWN = function() end,
        -- TODO it's not so nice that this component knows about the queue
        ENTER = function()
            if playing_index == nil then
                play(this.gallery.selection)
            else
                queue[#queue + 1] = this.gallery.selection
                queue_component.gallery:items_changed()
                if #queue == 1 then
                    queue_component.gallery:set_selection(1)
                end
            end
        end,
    }
    this.mouse_move = function(mx, my) end

    this.idle = function()
        if this.pending_selection then
            this.gallery:set_selection(this.pending_selection)
            this.pending_selection = nil
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
    this.duration = nil
    this.chapters = nil

    local function redraw_chapters()
        if not this.chapters then
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
        for _, chap in ipairs(this.chapters) do
            local x = g.waveform_position[1] + g.waveform_size[1] * (chap.time / this.duration)
            a:rect_cw(x - w, y1, x + w, y2)
        end
        local x = g.waveform_position[1] + g.waveform_size[1]
        a:rect_cw(x - w, y1, x + w, y2)
        a:new_event()
        a:pos(g.text_position[1], g.text_position[2] + (title_text_size + artist_album_text_size) / 2 - 5)
        a:append('{\\bord0\\an4}')
        local chapnum = mp.get_property_number("chapter", 0) + 1
        if chapnum <= 0 then chapnum = 1 end
        local chap = this.chapters[chapnum]
        local title = string.match(chap.title, ".*/%d+ (.*)%..-")
        local duration = chapnum == #this.chapters and this.duration - chap.time or this.chapters[chapnum + 1].time - chap.time
        local text = string.format("{\\fs%d}%s {\\1c&%s&}[%d/%d] [%s]", title_text_size, title, darker_text_color, chapnum, #this.chapters, mp.format_time(duration, "%m:%S"))
        local album = albums[playing_index]
        text = text .. "\\N" .. string.format("{\\fs%d}{\\1c&FFFFFF&}%s - %s {\\1c&%s&}[%s]", artist_album_text_size, album.artist, album.album, darker_text_color, album.year)
        a:append(text)
        this.ass_text.chapters = a.text
        ass_changed = true
    end

    local function redraw_times()
        if not playing_index or not this.duration then
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
        local snap_within = 20

        local g = this.geometry
        local a = assdraw.ass_new()
        local show_time_at = function(x)
            if not x then return end
            local time = (x - g.waveform_position[1]) / g.waveform_size[1] * this.duration
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
                for _, chap in ipairs(this.chapters) do
                    local chap_x = g.waveform_position[1] + chap.time / this.duration * g.waveform_size[1]
                    if math.abs(chap_x - cursor_x) < snap_within then
                        cursor_x = chap_x
                    end
                end
            end
        end
        local pos = mp.get_property_number("time-pos")
        if pos and this.duration then
            current_x = g.waveform_position[1] + g.waveform_size[1] * (pos / this.duration)
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
        local pos = mp.get_property_number("time-pos")
        if not this.duration or not pos then
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
        local x2 = x1 + this.geometry.waveform_size[1] * (pos / this.duration)
        a:rect_cw(x1, y1, x2, y2)
        this.ass_text.elapsed = a.text
        ass_changed = true
    end

    local function refresh_background(color)
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

    local timer = mp.add_periodic_timer(0.5, function()
        redraw_elapsed()
        redraw_times()
    end)
    timer:kill()

    this.set_active = function(active)
        this.active = active
        if active then
            mp.register_event("start-file", function()
                local album = albums[playing_index]
                mp.set_property("external-files", string.format("%s/%d - %s.png", opts.waveforms_dir, album.year, string.gsub(album.album, ':', '\\:')))
                mp.set_property("vid", "1")
                mp.commandv("overlay-add",
                    seekbar_overlay_index,
                    tostring(math.floor(this.geometry.cover_position[1] + 0.5)),
                    tostring(math.floor(this.geometry.cover_position[2] + 0.5)),
                    string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
                        album.artist, album.album,
                        this.geometry.cover_size[1],
                        this.geometry.cover_size[2]),
                    "0",
                    "bgra",
                    tostring(this.geometry.cover_size[1]),
                    tostring(this.geometry.cover_size[2]),
                    tostring(4*this.geometry.cover_size[1]))

            end)
            mp.observe_property("chapter", nil, function()
                redraw_chapters()
            end)
            mp.register_event("seek", function()
                redraw_times()
                redraw_elapsed()
            end)
            mp.register_event("file-loaded", function()
                this.duration = mp.get_property_number("duration")
                this.chapters = mp.get_property_native("chapter-list")
                redraw_chapters()
            end)
            mp.register_event("idle", function()
                mp.commandv("overlay-remove", seekbar_overlay_index)
                mp.set_property("external-files", "")
                this.duration = nil
                this.chapters = nil
                redraw_elapsed()
                redraw_times()
                redraw_chapters()
            end)
            timer:resume()
            refresh_background(background_idle)
        else
            timer:kill()
        end
    end
    this.active = function() return this.active end
    this.set_focus = function(focus)
        refresh_background(focus and background_focus or background_idle)
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
    end

    this.position = function()
        return this.geometry.position[1], this.geometry.position[2]
    end
    this.size = function()
        return this.geometry.size[1], this.geometry.size[2]
    end
    this.ass = function()
        return table.concat({
            this.ass_text.background,
            this.ass_text.elapsed,
            this.ass_text.times,
            this.ass_text.chapters,
            this.ass_text.text,
        }, "\n")
    end

    this.keys = {
        -- TODO
        -- seeking and stuff
        LEFT = function() end,
        RIGHT = function() end,
        PGUP = function() mp.command("no-osd add chapter 1") end,
        PGDWN = function() mp.command("no-osd add chapter -1") end,
        MBTN_RIGHT = function()
            local x, y = normalized_coordinates({mp.get_mouse_pos()}, this.geometry.cover_position, this.geometry.cover_size)
            if x < 0 or y < 0 or x > 1 or y > 1 then return end
            mp.commandv("playlist-remove", 0)
        end,
        MBTN_LEFT = function()
            if not this.duration then return end
            local x, y = normalized_coordinates({mp.get_mouse_pos()}, this.geometry.waveform_position, this.geometry.waveform_size)
            if x < 0 or y < 0 or x > 1 or y > 1 then return end
            mp.set_property_number("time-pos", x * this.duration)
        end,
    }
    this.mouse_move = function(mx, my)
        if not playing_index then return end
        local x, y = normalized_coordinates({mp.get_mouse_pos()}, this.geometry.waveform_position, this.geometry.waveform_size)
        if x < 0 or y < 0 or x > 1 or y > 1 then return end
        redraw_times()
        -- FIXME maybe? the times are not erased when the cursor leaves the
    end

    this.idle = function() end
end

local lyrics_component = {}
do
    local this = lyrics_component

    this.set_active = function(active)
    end
    this.active = function()
        return false
    end
    this.set_focus = function(focus)
    end
    this.set_geometry = function(x, y, w, h)
    end
    this.position = function()
        return 0, 0
    end
    this.size = function()
        return 0, 0
    end
    this.ass = function()
        return ""
    end
    this.keys = {
        UP = function() end,
        DOWN = function() end,
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

    mp.set_property_number("video-aspect", ratio)
    mp.set_property_number("video-zoom", zoom)
    mp.set_property_number("video-pan-y", pan_y)
    mp.set_property_number("video-pan-x", pan_x)
    -- doesn't work much better
    --if playing_index then
    --    local vf = string.format("scale=w=%s:h=%s,pad=w=%s:h=%s:x=%s:y=%s", w, h, ww, wh, x, y)
    --    local pos = mp.get_property_number("time-pos")
    --    mp.set_property("vf", vf)
    --    mp.set_property("time-pos", "0")
    --    mp.set_property("time-pos", pos)
    --end
end

local components = {
    albums_component,
    queue_component,
    now_playing_component,
    lyrics_component,
}
local active_components = {
    albums_component,
    queue_component,
    now_playing_component,
}
local focused_component = nil

function play(album_index)
    local album = albums[album_index]
    local files = utils.readdir(album.dir)
    if not files then return end
    table.sort(files)
    for i, file in ipairs(files) do
        file = album.dir .. "/" .. file
        files[i] = string.format("%%%i%%%s", string.len(file), file)
    end
    playing_index = album_index
    mp.set_property_bool("pause", false)
    mp.commandv("loadfile", "edl://" .. table.concat(files, ';'))
end

local all_keys = {}
for _, comp in ipairs(components) do
    for key, _ in pairs(comp.keys) do
        all_keys[key] = true
    end
end
for key, _ in pairs(all_keys) do
    mp.add_forced_key_binding(key, function()
        if focused_component then
            local func = focused_component.keys[key]
            if func then func() end
        end
    end)
end

function focus_next_component(backwards)
    if not focused_component and #active_components > 0 then
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
    for _, comp in ipairs(active_components) do
        local nx, ny = normalized_coordinates({x, y}, {comp.position()}, {comp.size()})
        if nx >= 0 and ny >= 0 and nx <= 1 and ny <= 1 then
            return comp
        end
    end
    return nil
end

local started = false
mp.register_idle(function()
    for _, comp in ipairs(active_components) do
        comp.idle()
    end
    if size_changed then
        size_changed = false
        local ww, wh = mp.get_osd_size()
        if ww and wh and ww * wh > 0 then
            local x = global_offset
            local y = global_offset
            local w = ww - 2 * global_offset
            local h = wh - 2 * global_offset
            now_playing_component.set_geometry(x, y + h - 180, w, 180)
            h = h - 180 - global_offset

            queue_component.set_geometry(x + w - 200, y, 200, h)
            w = w - 200 - global_offset

            albums_component.set_geometry(x, y, w, h)

            if not started then
                started = true
                for _, comp in ipairs(active_components) do
                    comp.set_active(true)
                end
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
