local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local gallery = require 'lib/gallery'

local opts = {
    root_dir = "music",
    thumbs_dir = "thumbs",
    waveforms_dir = "waveform",
    albums_file = "albums", -- for optimization purposes
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
local focus = nil -- 0,1,2,3 is respectively none, gallery_main, gallery_queue, seekbar

local seekbar_geometry = {
    position = {0,0},
    size = {0,0},
    waveform_position = {0,0},
    waveform_size = {0,0},
    cover_position = {0,0},
    cover_size = {0,0},
    text_position = {0,0},
}

local playing_index = nil
local length = nil
local chapters = nil
local paused = false

local albums = {}
local queue = {}

local ass = {
    queue = "",
    main = "",
    seekbar = {
        background = "",
        chapters = "",
        elapsed = "",
        cursor_bar = "",
        times = "",
    },
    changed = false,
}

local gallery_main = gallery_new()
local gallery_queue = gallery_new()

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

local seekbar_overlay_index = 0

gallery_main.items = albums
gallery_main.config.always_show_placeholders = false
gallery_main.config.align_text = true
gallery_main.config.max_thumbnails = 48
gallery_main.config.overlay_range = 1
gallery_main.config.background_opacity = background_opacity
gallery_main.geometry.min_spacing = {15,30}
gallery_main.geometry.thumbnail_size = {150,150}

gallery_queue.items = queue
gallery_queue.config.always_show_placeholders = false
gallery_queue.config.align_text = false
gallery_queue.config.max_thumbnails = 16
gallery_queue.config.overlay_range = 49
gallery_queue.config.background_opacity = background_opacity
gallery_queue.geometry.min_spacing = {0,10}
gallery_queue.geometry.thumbnail_size = {150,150}

gallery_main.item_to_overlay_path = function(index, item)
    return string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
        item.artist, item.album,
        gallery_main.geometry.thumbnail_size[1],
        gallery_main.geometry.thumbnail_size[2]
    )
end
gallery_queue.item_to_overlay_path = function(index, item)
    local album = albums[item]
    return string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
        album.artist, album.album,
        gallery_queue.geometry.thumbnail_size[1],
        gallery_queue.geometry.thumbnail_size[2]
    )
end

gallery_main.item_to_border = function(index, item)
    if focus == 1 and index == gallery_main.selection then
        return 4, "AAAAAA"
    else
        return 0.5, "BBBBBB"
    end
end

gallery_queue.item_to_border = function(index, item)
    if index == gallery_queue.selection then
        return 3, "AAAAAA"
    else
        return 1, "BBBBBB"
    end
end

gallery_main.item_to_text = function(index, item)
    if focus == 1 and index == gallery_main.selection then
        return string.format("%s - %s [%d]", item.artist, item.album, item.year)
    end
    return ""
end

gallery_queue.item_to_text = function(index, item)
    return ""
end

gallery_main.set_geometry_props = function(ww, wh)
    gallery_main.geometry.gallery_position = {global_offset, global_offset}
    gallery_main.geometry.gallery_size = {ww - 180 - global_offset * 3, wh - 170 - global_offset * 3}
end
gallery_queue.set_geometry_props = function(ww, wh)
    gallery_queue.geometry.gallery_position = {ww - 180 - global_offset, global_offset}
    gallery_queue.geometry.gallery_size = {180, wh - 170 - global_offset * 3}
end
function update_seekbar_geom(ww, wh)
    local g = seekbar_geometry
    g.position = { global_offset,  wh - 170 - global_offset }
    local dist_w = 10
    local dist_h = 10
    g.size = { ww - 2 * global_offset, 150 + dist_w * 2 }

    g.cover_size = { 150, 150 }
    g.cover_position = { g.position[1] + dist_h, g.position[2] + (g.size[2] - g.cover_size[2]) / 2 }

    local waveform_margin_y = 10
    g.text_position = { g.position[1] + g.cover_size[1] + 2 * dist_h, g.position[2] + waveform_margin_y}

    g.waveform_position = { g.text_position[1], g.text_position[2] + artist_album_text_size + title_text_size }
    g.waveform_size = { g.size[1] - g.cover_size[1] - 3 * dist_h, g.size[2] - 2 * waveform_margin_y - (artist_album_text_size + title_text_size + time_text_size) }
end

gallery_main.ass_show = function(gallery_ass)
    ass.main = gallery_ass
    ass.changed = true
end
gallery_main.ass_hide = function()
    ass.main = ""
    ass.changed = true
end
gallery_queue.ass_show = function(gallery_ass)
    ass.queue = gallery_ass
    ass.changed = true
end
gallery_queue.ass_hide = function()
    ass.queue = ""
    ass.changed = true
end

function set_video_position(ww, wh, x, y, w, h)
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

function redraw_seekbar_background()
    local a = assdraw.ass_new()
    a:new_event()
    a:append('{\\bord0}')
    a:append('{\\shad0}')
    a:append('{\\1c&' .. (focus == 3 and background_focus or background_idle) .. '}')
    a:append('{\\1a&' .. "BB" .. '}')
    a:pos(0, 0)
    --a:append('{\\iclip(4,')
    --local ww, wh = mp.get_osd_size()
    --a:rect_cw(seekbar_position[1] + 30, seekbar_position[2] + 30, seekbar_position[1] + seekbar_size[1] - 30, seekbar_position[2] + seekbar_size[2] - 30)
    --a:append(')}')
    a:draw_start()
    a:move_to(0,0)
    local g = seekbar_geometry
    a:round_rect_cw(g.position[1], g.position[2], g.position[1] + g.size[1], g.position[2] + g.size[2], 5)
    ass.seekbar.background = a.text
    ass.changed = true
end

function redraw_seekbar_times()
    if not playing_index or not length then
        if ass.seekbar.times ~= "" then
            ass.seekbar.times = ""
            ass.changed = true
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

    local pos = mp.get_property_number("time-pos")
    local a = assdraw.ass_new()
    a:new_event()
    local g = seekbar_geometry
    local y = g.waveform_position[2] + g.waveform_size[2]
    if pos then
        local x = g.waveform_position[1] + g.waveform_size[1] * (pos / length)
        a:pos(x, y)
        a:append("{\\an8\\fs " .. time_text_size .. "\\bord0}")
        a:append(format_time(pos))
    end
    a:new_event()
    a:append("{\\an9\\fs " .. time_text_size .. "\\bord0}")
    a:pos(g.waveform_position[1] + g.waveform_size[1], y)
    a:append(format_time(length))

    local mx, my = mp.get_mouse_pos()
    local tx = mx - g.waveform_position[1]
    local ty = my - g.waveform_position[2]
    if tx >= 0 and tx <= g.waveform_size[1] and ty >= 0 and ty <= g.waveform_size[2] then
        a:new_event()
        a:append("{\\an8\\fs " .. time_text_size .. "\\bord0}")
        a:pos(mx, y)
        a:append(format_time(tx / g.waveform_size[1] * length))
    end

    ass.seekbar.times = a.text
    ass.changed = true
end

function redraw_cursor_bar()
    local x, y = mp.get_mouse_pos()
    local g = seekbar_geometry
    local tx = x - g.waveform_position[1]
    local ty = y - g.waveform_position[2]
    if not playing_index or tx < 0 or tx > g.waveform_size[1] or ty < 0 or ty > g.waveform_size[2] then
        if ass.seekbar.cursor_bar ~= "" then
            ass.seekbar.cursor_bar = ""
            ass.changed = true
        end
        return
    end
    local a = assdraw.ass_new()
    a:new_event()
    a:pos(0, 0)
    a:append('{\\bord0\\shad0\\1c&' .. cursor_bar_color .. '}')
    a:draw_start()
    local w = cursor_bar_width/2
    local g = seekbar_geometry
    local y1 = g.waveform_position[2]
    local y2 = y1 + g.waveform_size[2]
    a:rect_cw(x - w, y1, x + w, y2)
    ass.seekbar.cursor_bar = a.text
    ass.changed = true
end

function redraw_chapters()
    if not chapters then
        ass.seekbar.chapters = ""
        ass.changed = true
        return
    end
    local a = assdraw.ass_new()
    a:new_event()
    a:pos(0, 0)
    a:append('{\\bord0\\shad0\\1c&' .. chapters_marker_color .. '}')
    a:draw_start()
    local w = chapters_marker_width/2
    local g = seekbar_geometry
    local y1 = g.waveform_position[2]
    local y2 = y1 + g.waveform_size[2]
    for _, chap in ipairs(chapters) do
        local x = g.waveform_position[1] + g.waveform_size[1] * (chap.time / length)
        a:rect_cw(x - w, y1, x + w, y2)
    end
    local x = g.waveform_position[1] + g.waveform_size[1]
    a:rect_cw(x - w, y1, x + w, y2)
    a:new_event()
    a:pos(g.text_position[1], g.text_position[2] + (title_text_size + artist_album_text_size) / 2 - 5)
    a:append('{\\bord0\\an4}')
    local album = albums[playing_index]
    local chapnum = mp.get_property_number("chapter", 0) + 1
    local chap = chapters[chapnum]
    local title = string.match(chap.title, ".*/%d+ (.*)%..-")
    local duration = chapnum == #chapters and length - chap.time or chapters[chapnum + 1].time - chap.time
    local text = string.format("{\\fs%d}%s {\\1c&%s&}[%d/%d] [%s]", title_text_size, title, darker_text_color, chapnum, #chapters, mp.format_time(duration, "%m:%S"))
    text = text .. "\\N" .. string.format("{\\fs%d}{\\1c&FFFFFF&}%s - %s {\\1c&%s&}[%s]", artist_album_text_size, album.artist, album.album, darker_text_color, album.year)
    a:append(text)
    ass.seekbar.chapters = a.text
    ass.changed = true
end

function redraw_elapsed()
    local pos = mp.get_property_number("time-pos")
    if not length or not pos then
        if ass.seekbar.elapsed ~= "" then
            ass.seekbar.elapsed = ""
            ass.changed = true
        end
        return
    end
    local a = assdraw.ass_new()
    a:new_event()
    a:append('{\\bord0}')
    a:append('{\\shad0}')
    a:append('{\\1c&' .. "222222" .. '}')
    a:append('{\\1a&' .. "AA" .. '}')
    a:pos(0,0)
    a:draw_start()
    local g = seekbar_geometry
    local y1 = g.waveform_position[2]
    local y2 = y1 + g.waveform_size[2]
    local x1 = g.waveform_position[1]
    local x2 = x1 + g.waveform_size[1] * (pos / length)
    a:rect_cw(x1, y1, x2, y2)
    ass.seekbar.elapsed = a.text
    ass.changed = true
end

function gallery_main_activate()
    if playing_index == nil then
        play(gallery_main.selection)
    else
        queue[#queue + 1] = gallery_main.selection
        if #queue == 1 then
            gallery_queue.pending.selection = 1
        end
        gallery_queue:items_changed()
    end
end

function gallery_queue_activate()
    local sel = gallery_queue.selection
    play(table.remove(queue, sel))
    if sel > #queue then
        gallery_queue.selection = #queue
    end
    gallery_queue:items_changed()
end

function add_to_queue(index)
end

function play(index)
    local item = albums[index]
    local files = utils.readdir(item.dir)
    if not files then return end
    table.sort(files)
    for i, file in ipairs(files) do
        file = item.dir .. "/" .. file
        files[i] = string.format("%%%i%%%s", string.len(file), file)
    end
    playing_index = index
    mp.commandv("loadfile", "edl://" .. table.concat(files, ';'))
    mp.set_property_bool("pause", false)
    mp.set_property("external-files", string.format("%s/%d - %s.png", opts.waveforms_dir, item.year, string.gsub(item.album, ':', '\\:')))
    mp.set_property("vid", "1")
    mp.commandv("overlay-add",
        seekbar_overlay_index,
        tostring(math.floor(seekbar_geometry.cover_position[1] + 0.5)),
        tostring(math.floor(seekbar_geometry.cover_position[2] + 0.5)),
        string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
            item.artist, item.album,
            seekbar_geometry.cover_size[1],
            seekbar_geometry.cover_size[2]),
        "0",
        "bgra",
        tostring(seekbar_geometry.cover_size[1]),
        tostring(seekbar_geometry.cover_size[2]),
        tostring(4*seekbar_geometry.cover_size[1]))
end

mp.add_forced_key_binding("ENTER", "enter", function()
    if focus == 1 then
        gallery_main_activate()
    elseif focus == 2 then
        gallery_queue_activate()
    end
end)

function change_focus(new)
    local old_focus = focus
    focus = (new - 1 + 3) % 3 + 1
    if focus == old_focus then return end
    gallery_main.config.background_color = background_idle
    gallery_queue.config.background_color = background_idle
    if focus == 1 then
        gallery_main.config.background_color = background_focus
    elseif focus == 2 then
        gallery_queue.config.background_color = background_focus
    end
    if old_focus == 2 and #queue > 0 then
        gallery_queue.pending.selection = 1
    end
    redraw_seekbar_background()
    gallery_main:ass_refresh(true, false, false, true)
    gallery_queue:ass_refresh(false, false, false, true)
end

function element_from_pos(x, y)
    local tx, ty, g
    g = gallery_main.geometry
    tx = x - g.gallery_position[1]
    ty = y - g.gallery_position[2]
    if tx > 0 and tx < g.gallery_size[1] and ty > 0 and ty < g.gallery_size[2] then
        return 1
    end
    g = gallery_queue.geometry
    tx = x - g.gallery_position[1]
    ty = y - g.gallery_position[2]
    if tx > 0 and tx < g.gallery_size[1] and ty > 0 and ty < g.gallery_size[2] then
        return 2
    end
    g = seekbar_geometry
    tx = x - g.position[1]
    ty = y - g.position[2]
    if tx > 0 and tx < g.size[1] and ty > 0 and ty < g.size[2] then
        return 3
    end
    return nil
end

mp.add_forced_key_binding("DEL", "del", function()
    if focus == 2 then
        local index = gallery_queue.selection
        table.remove(queue, index)
        if index > #queue then
            gallery_queue.selection = #queue
        end
        gallery_queue:items_changed()
    elseif focus == 3 then
        if playing_index ~= nil then
            mp.commandv("playlist-remove", "0")
        end
    end
end)

mp.add_forced_key_binding("MBTN_RIGHT", "rightclick", function()
    local x, y = mp.get_mouse_pos()
    local f = element_from_pos(x, y)
    if f == 2 then
        local index = gallery_queue:index_at(x, y)
        if index then
            if gallery_queue.selection == index then
                table.remove(queue, index)
                if index > #queue then
                    gallery_queue.selection = #queue
                end
                gallery_queue:items_changed()
            else
                gallery_queue.pending.selection = index
            end
        end
    elseif f == 3 then
        if playing_index ~= nil then
            local g = seekbar_geometry
            x = x - g.cover_position[1]
            y = y - g.cover_position[2]
            if x >= 0 and x <= g.cover_size[1] and y >= 0 and y <= g.cover_size[2] then
                mp.commandv("playlist-remove", "0")
            end
        end
    end
end)

mp.add_forced_key_binding("MBTN_LEFT", "leftclick", function()
    local x, y = mp.get_mouse_pos()
    local f = element_from_pos(x, y)
    if f == 1 then
        local index = gallery_main:index_at(x, y)
        if index then
            if gallery_main.selection == index then
                gallery_main_activate(index)
            else
                gallery_main.pending.selection = index
            end
        end
    elseif f == 2 then
        local index = gallery_queue:index_at(x, y)
        if index then
            if gallery_queue.selection == index then
                gallery_queue_activate(index)
            else
                gallery_queue.pending.selection = index
            end
        end
    elseif f == 3 then
        if playing_index and length then
            local g = seekbar_geometry
            x = x - g.waveform_position[1]
            y = y - g.waveform_position[2]
            if x >= 0 and x <= g.waveform_size[1] and y >= 0 and y <= g.waveform_size[2] then
                mp.set_property_number("time-pos", x / g.waveform_size[1] * length)
            end
        end
    end
end)

local move_current_gallery = function(leftright, updown, clamp)
    if focus ~= 1 and focus ~= 2 then return false end
    local gallery = (focus == 1 and gallery_main or gallery_queue)
    local inc = leftright + updown * gallery.geometry.columns
    local new = (gallery.pending.selection or gallery.selection) + inc
    if new <= 0 or new > #gallery.items then
        if clamp then
            gallery.pending.selection = math.max(1, math.min(new, #gallery.items))
        end
    else
        gallery.pending.selection = new
    end
    return true
end

function scroll(up)
    if focus == 1 or focus == 2 then
        move_current_gallery(0, up and -1 or 1, false)
    elseif f == 3 then
        mp.commandv("no-osd", "seek", up and "5" or "-5", "exact")
    end
end

mp.add_forced_key_binding("WHEEL_UP", "wheel_up", function() scroll(true) end)
mp.add_forced_key_binding("WHEEL_DOWN", "wheel_down", function() scroll(false) end)

mp.add_forced_key_binding("LEFT", "left",  function() move_current_gallery(-1, 0, false) end, {repeatable=true})
mp.add_forced_key_binding("RIGHT", "right",  function() move_current_gallery(1, 0, false) end, {repeatable=true})
mp.add_forced_key_binding("UP", "up",  function() move_current_gallery(0, -1, false) end, {repeatable=true})
mp.add_forced_key_binding("DOWN", "down",  function() move_current_gallery(0, 1, false) end, {repeatable=true})

mp.add_forced_key_binding("r", "rand",  function()
    if not focus == 1 then return end
    gallery_main.pending.selection = math.random(1, #albums)
end, {repeatable=true})

mp.add_forced_key_binding("TAB", "tab", function() change_focus(focus + 1) end)
mp.add_forced_key_binding("SHIFT+TAB", "backtab", function() change_focus(focus - 1) end)

mp.register_event("idle", function()
    playing_index = nil
    length = nil
    chapters = nil
    if #queue == 0 then
        mp.commandv("overlay-remove", seekbar_overlay_index)
        redraw_chapters()
        redraw_elapsed()
        redraw_seekbar_times()
    else
        play(table.remove(queue, 1))
        gallery_queue:items_changed()
    end
end)

mp.register_event("file-loaded", function()
    chapters = mp.get_property_native("chapter-list")
    length = mp.get_property_number("duration")
    redraw_chapters()
    redraw_seekbar_times()
end)

mp.add_periodic_timer(0.5, function()
    if playing_index ~= nil and not paused then
        redraw_elapsed()
        redraw_seekbar_times()
    end
end)

mp.observe_property("pause", "bool", function(_, val)
    paused = val
end)

mp.observe_property("chapter", "number", function()
    redraw_chapters()
end)

mp.observe_property("seeking", "bool", function(_, val)
    if playing_index ~= nil and not val then
        redraw_elapsed()
        redraw_seekbar_times()
    end
end)

function start_or_resize()
    local ww, wh = mp.get_osd_size()
    if not ww or not wh or ww * wh <= 0 then return end
    update_seekbar_geom(ww, wh)
    if not gallery_main.active then
        change_focus(1)
        gallery_main:activate(1)
        gallery_queue:activate(0)
    end
    redraw_seekbar_background()
    if playing_index ~= nil then
        redraw_chapters()
        redraw_elapsed()
        redraw_cursor_bar()
        redraw_seekbar_times()
        local item = albums[playing_index]
        mp.commandv("overlay-add",
            seekbar_overlay_index,
            tostring(math.floor(seekbar_geometry.cover_position[1] + 0.5)),
            tostring(math.floor(seekbar_geometry.cover_position[2] + 0.5)),
            string.format("%s/%s - %s_%s_%s", opts.thumbs_dir,
                item.artist, item.album,
                seekbar_geometry.cover_size[1],
                seekbar_geometry.cover_size[2]),
            "0",
            "bgra",
            tostring(seekbar_geometry.cover_size[1]),
            tostring(seekbar_geometry.cover_size[2]),
            tostring(4*seekbar_geometry.cover_size[1]))
    end
    local g = seekbar_geometry
    set_video_position(ww, wh, g.waveform_position[1], g.waveform_position[2] - 0.5 * waveform_padding_proportion * g.waveform_size[2] / (1 - waveform_padding_proportion), g.waveform_size[1], g.waveform_size[2] / (1 - waveform_padding_proportion))
end

local size_changed = false
for _, prop in ipairs({"osd-width", "osd-height"}) do
    mp.observe_property(prop, "native", function() size_changed = true end)
end

local mouse_moved = false
mp.add_forced_key_binding("mouse_move", "mouse_move", function() mouse_moved = true end)

mp.register_idle(function()
    gallery_main:invoke_idle()
    gallery_queue:invoke_idle()
    if size_changed then
        start_or_resize()
        size_changed = false
    end
    if mouse_moved then
        local x, y = mp.get_mouse_pos()
        local f = element_from_pos(x, y)
        if f then
            change_focus(f)
        end
        redraw_cursor_bar()
        redraw_seekbar_times()
        mouse_moved = false
    end
    if ass.changed then
        local ww, wh = mp.get_osd_size()
        mp.set_osd_ass(ww, wh, table.concat({
            ass.main,
            ass.queue,
            ass.seekbar.background,
            ass.seekbar.elapsed,
            ass.seekbar.chapters,
            ass.seekbar.cursor_bar,
            ass.seekbar.times
        }, "\n"))
        ass.changed = false
    end
end)
