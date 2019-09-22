local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local gallery = require 'lib/gallery'

local opts = {
    root_dir = "music",
    thumbs_dir = "thumbs",
    waveforms_dir = "waveform",
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
local waveform_padding_proportion=0

-- VARS
local focus = 1 -- 0,1,2,3 is respectively none, gallery_main, gallery_queue, seekbar

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

local queue_ass = ""
local main_ass = ""
local seekbar_ass = {
    chapters = "",
    elapsed = "",
    background = "",
    cursor_bar = "",
}

local gallery_main = gallery_new()
local gallery_queue = gallery_new()

do
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
                    dir= string.format("%s/%s/%s", opts.root_dir, artist, yearalbum)
                }
            end
        end
    end
    if #albums == 0 then
        msg.warn("No albums, exiting")
        return
    end
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
    if index == gallery_main.selection then
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
    if index == gallery_main.selection then return string.format("%s - %s [%d]", item.artist, item.album, item.year) end
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
    g.size = { ww - 2 * global_offset, 170 }
    local dist_h = 15

    g.cover_size = { 150, 150 }
    g.cover_position = { g.position[1] + dist_h, g.position[2] + (g.size[2] - g.cover_size[2]) / 2 }

    local waveform_margin_y = 10
    g.text_position = { g.position[1] + g.cover_size[1] + 2 * dist_h, g.position[2] + waveform_margin_y}

    g.waveform_position = { g.text_position[1], g.text_position[2] + 26 + 32 }
    g.waveform_size = { g.size[1] - g.cover_size[1] - 3 * dist_h, g.size[2] - 2 * waveform_margin_y - 26 - 32 }
end

function refresh_ass(ass)
    local ww, wh = mp.get_osd_size()
    mp.set_osd_ass(ww, wh, string.format("%s\n%s\n%s\n%s\n%s\n%s",
        main_ass,
        queue_ass,
        seekbar_ass.background,
        seekbar_ass.elapsed,
        seekbar_ass.chapters,
        seekbar_ass.cursor_bar
    ))
end
gallery_queue.ass_show = function(ass)
    queue_ass = ass
    refresh_ass()
end
gallery_main.ass_show = function(ass)
    main_ass = ass
    refresh_ass()
end

gallery_queue.ass_hide = function() end
gallery_main.ass_hide = function() end

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
    seekbar_ass.background = a.text
    refresh_ass()
end

function redraw_cursor_bar()
    local x, y = mp.get_mouse_pos()
    local g = seekbar_geometry
    local tx = x - g.waveform_position[1]
    local ty = y - g.waveform_position[2]
    if not playing_index or tx < 0 or tx > g.waveform_size[1] or ty < 0 or ty > g.waveform_size[2] then
        if seekbar_ass.cursor_bar ~= "" then
            seekbar_ass.cursor_bar = ""
            refresh_ass()
        end
        return
    end
    local a = assdraw.ass_new()
    a:new_event()
    a:pos(0, 0)
    a:append('{\\bord0}')
    a:append('{\\shad0}')
    a:append('{\\1c&' .. cursor_bar_color .. '}')
    a:draw_start()
    local w = cursor_bar_width/2
    local g = seekbar_geometry
    local y1 = g.waveform_position[2]
    local y2 = y1 + g.waveform_size[2]
    a:rect_cw(x - w, y1, x + w, y2)
    a:draw_stop()
    seekbar_ass.cursor_bar = a.text
    refresh_ass()
end

function redraw_chapters()
    if not chapters then
        seekbar_ass.chapters = ""
        refresh_ass()
        return
    end
    local a = assdraw.ass_new()
    a:new_event()
    a:pos(0, 0)
    a:append('{\\bord0}')
    a:append('{\\shad0}')
    a:append('{\\1c&' .. chapters_marker_color .. '}')
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
    a:pos(g.text_position[1], g.text_position[2] + (26 + 32) / 2 - 6)
    a:append('{\\bord0}{\\an4}')
    local album = albums[playing_index]
    --a:append(string.format("{\\fs32}%s", album.album))
    a:append(string.format("{\\fs32}%s (%d)\\N{\\fs26}%s", album.album, album.year, album.artist))
    seekbar_ass.chapters = a.text
    refresh_ass()
end

function redraw_elapsed()
    if not length then
        seekbar_ass.elapsed = ""
        refresh_ass()
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
    local x2 = x1 + g.waveform_size[1] * (mp.get_property_number("time-pos", 0) / length)
    a:rect_cw(x1, y1, x2, y2)
    a:draw_stop()
    seekbar_ass.elapsed = a.text
    refresh_ass()
end

function gallery_main_activate(index)
    if playing_index == nil then
        play(index)
    else
        add_to_queue(index)
    end
end

function gallery_queue_activate(index)
    play(queue[index])
    table.remove(queue, index)
    gallery_queue:items_changed()
end

function add_to_queue(index)
    queue[#queue + 1] = index
    if #queue == 1 then
        gallery_queue.pending.selection = 1
    end
    gallery_queue:items_changed()
end

function play(index)
    playing_index = index
    local item = albums[index]
    local files = utils.readdir(item.dir)
    table.sort(files)
    for i, file in ipairs(files) do
        file = item.dir .. "/" .. file
        files[i] = string.format("%%%i%%%s", string.len(file), file)
    end
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
        local sel = gallery_main.selection
        if sel == 0 then return end
        gallery_main_activate(sel)
    elseif focus == 2 then
        local sel = gallery_queue.selection
        if sel == 0 then return end
        play(sel)
    end
end)

local change_focus = function(new)
    focus = (new - 1 + 3) % 3 + 1
    gallery_main.config.background_color = background_idle
    gallery_queue.config.background_color = background_idle
    if focus == 1 then
        gallery_main.config.background_color = background_focus
    elseif focus == 2 then
        gallery_queue.config.background_color = background_focus
    end
    redraw_seekbar_background()
    gallery_main:ass_refresh(false, false, false, true)
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

local mouse_moved = false
mp.register_idle(function()
    if not mouse_moved then return end
    redraw_cursor_bar()
    mouse_moved = false
end)

mp.add_forced_key_binding("mouse_move", "mouse_move", function() mouse_moved=true end)

mp.add_forced_key_binding("MBTN_RIGHT", "rightclick", function()
    -- TODO
end)

mp.add_forced_key_binding("MBTN_LEFT", "leftclick", function()
    local x, y = mp.get_mouse_pos()
    local f = element_from_pos(x, y)
    if not f then return end
    if focus == f then
        if focus == 1 then
            local index = gallery_main:index_at(x, y)
            if index then
                if gallery_main.selection == index then
                    gallery_main_activate(index)
                else
                    gallery_main.pending.selection = index
                end
            end
        elseif focus == 2 then
            local index = gallery_queue:index_at(x, y)
            if index then
                if gallery_queue.selection == index then
                    gallery_queue_activate(index)
                else
                    gallery_queue.pending.selection = index
                end
            end
        elseif focus == 3 then
            if playing_index ~= nil then
                local g = seekbar_geometry
                mp.set_property_number("time-pos", (x - g.waveform_position[1]) / g.waveform_size[1] * length)
            end
        end
    else
        change_focus(f)
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
    local x, y = mp.get_mouse_pos()
    local f = element_from_pos(x, y)
    change_focus(f)
    if f == 1 or f == 2 then
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
    else
        play(table.remove(queue, 1))
        gallery_queue:items_changed()
    end
end)

mp.register_event("file-loaded", function()
    chapters = mp.get_property_native("chapter-list")
    length = mp.get_property_number("duration")
    redraw_chapters()
end)

local timer = mp.add_periodic_timer(0.5, function()
    if playing_index ~= nil and not paused then
        redraw_elapsed()
    end
end)

mp.observe_property("pause", "bool", function(_, val)
    paused = val
end)

mp.observe_property("seeking", "bool", function(_, val)
    if playing_index ~= nil and not val then
        redraw_elapsed()
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

mp.register_idle(function()
    if size_changed then
        start_or_resize()
        size_changed = false
    end
end)
