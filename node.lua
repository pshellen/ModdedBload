-- Copyright (C) 2016-2019 Florian Wesch <fw@dividuum.de>
-- All Rights Reserved.
--
-- Unauthorized copying of this file, via any medium is
-- strictly prohibited. Proprietary and confidential.

gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

util.no_globals()

local json = require "json"
local bload = require "bload"
local glob = require "globtopattern".globtopattern
local matrix = require "matrix2d"

local font = resource.load_font "font.ttf"
local box = resource.load_image "box.png"
local white = resource.create_colored_texture(1,1,1,1)

local screen
local movies = {}
local shows = {}

local st, vid_scaler
local portrait, rotation, main_logo_name, corner_logo
local debug = true
local outdated = false

local my_serial = sys.get_env "SERIAL"
local scale = 1

local schedule = bload.Bload()

local function load_bload(raw)
    schedule.set_bload(raw)
    local screens = schedule.get_screens()
    shows = screens[screen] or {}
    print("found " .. #shows .. " shows for screen " .. tostring(screen))
end

util.file_watch("config.json", function(raw)
    local config = json.decode(raw)
    pp(config)

    debug = false

    screen = nil
    rotation = 0
    main_logo_name = config.main_logo.asset_name
    corner_logo = resource.load_image(config.corner_logo.asset_name)

    for idx = 1, #config.signs do
        local sign = config.signs[idx]
        if sign.serial == my_serial then
            screen = sign.screen
            rotation = sign.rotation
            debug = sign.debug
            scale = sign.scale
        end
    end
    print("my screen name is " .. tostring(screen))

    movies = config.movies
    for idx = 1, #movies do
        local movie = movies[idx]
        movie.match_pattern = glob(movie.pattern:lower())
    end

    gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)
    st = util.screen_transform(rotation)
    print("screen size is " .. WIDTH .. "x" .. HEIGHT)

    vid_scaler = matrix.trans(NATIVE_WIDTH/2, NATIVE_HEIGHT/2) *
                 matrix.scale(scale, scale) *
                 matrix.trans(-NATIVE_WIDTH/2, -NATIVE_HEIGHT/2)

    portrait = rotation == 90 or rotation == 270

    local ok, raw = pcall(resource.load_file, "BLOAD.txt")
    if ok then
        load_bload(raw)
    end
end)

util.file_watch("BLOAD.txt", load_bload)

local base_time = 0
local function current_offset()
    local time = base_time + sys.now()
    local offset = (time % 86400) / 60
    return offset
end

local function get_current_show()
    local offset = current_offset()

    if outdated then
        return
    end

    for idx = 1, #shows do
        local show = shows[idx]
        local next_show = shows[idx+1]
        local starts, ends

        -- Message-Id: <1465504497.2051037.633156353.268DA54A@webmail.messagingengine.com>
        -- Message-Id: <CAHCqjYM87qcOTtXTJO-ZcV835q6P2SPa7=mW2ZkSbWmD_h7MOA@mail.gmail.com>
        local BEFORE_FIRST_SHOW = 60 
        local BEFORE_OTHER_SHOWS = 30

        if idx == 1 then
            starts = show.showtime.offset - BEFORE_FIRST_SHOW
        else
            starts = show.showtime.offset - BEFORE_OTHER_SHOWS
        end

        if next_show then
            ends = next_show.showtime.offset - BEFORE_OTHER_SHOWS
        else
            ends = show.showtime.offset + show.runtime
        end

        -- print(("%d:%02d - %d:%02d %d:%02d %s"):format(
        --     starts / 60, starts % 60,
        --     ends / 60, ends % 60, 
        --     show.showtime.offset / 60, show.showtime.offset % 60,
        --     show.name
        -- ))

        if starts <= offset and offset < ends then
            return show
        end
    end
end

util.data_mapper{
    ["age/set"] = function(age)
        outdated = tonumber(age) > 3600 * 6 -- older than 6 hours?
        print("bload outdated: ", age, outdated)
    end;
    ["clock/set"] = function(time)
        print("time set to", time)
        base_time = tonumber(time) - sys.now()
        local offset = current_offset()
        local show = get_current_show()
        print(("CURRENT OFFSET is now %d (%d:%02d) -> %s"):format(
            offset, offset/60, offset%60, show and show.name or "<none>"
        ))
    end;
    ["date/set"] = function(date)
        print("date set to", date)
        schedule.set_date(date)
    end;
}

local function get_assets()
    local show = get_current_show()
    for idx = 1, #movies do
        local movie = movies[idx]
        -- print(show.match_name, movie.pattern)
        if show and show.match_name:match(movie.match_pattern) then
            print "found my movie"
            return movie.assets
        end
    end

    print "returning default asset"
    return {{
        media = {
            asset_name = main_logo_name,
            type = "image",
        },
        duration = 5
    }}
end

local function Image(asset_name, duration)
    print("started new image " .. asset_name)
    local obj = resource.load_image(asset_name)
    local started

    local function start()
        started = sys.now()
    end
    local function draw()
        util.draw_correct(obj, 0, 0, WIDTH, HEIGHT)
        return sys.now() - started > duration
    end
    local function unload()
        obj:dispose()
    end
    return {
        start = start;
        draw = draw;
        unload = unload;
    }
end

local function Video(asset_name)
    print("started new video " .. asset_name)
    local file = resource.open_file(asset_name)
    local obj

    local function start()
    end
    local function draw()
        if not obj then
            obj = resource.load_video{
                file = file;
                raw = true;
            }
        else
            local state, w, h = obj:state()
            if state == "loaded" then
                if portrait then
                    w, h = h, w
                end
                local x1, y1, x2, y2 = util.scale_into(NATIVE_WIDTH, NATIVE_HEIGHT, w, h)
                x1, y1 = vid_scaler(x1, y1)
                x2, y2 = vid_scaler(x2, y2)
                obj:place(x1, y1, x2, y2, rotation)
            end
        end
        return obj:state() == "finished"
    end

    local function unload()
        obj:dispose()
    end
    return {
        start = start;
        draw = draw;
        unload = unload;
    }
end

local function Player()
    local offset = 0
    local current = Image(main_logo_name, 5)
    local next

    current.start()

    local function draw()
        if not next then
            print "adding next asset"
            local assets = get_assets()
            offset = offset + 1
            if offset > #assets then
                offset = 1
            end

            local asset = assets[offset]
            next = ({
                image = Image;
                video = Video;
            })[asset.media.type](asset.media.asset_name, asset.duration)
        end

        local ended = current.draw()

        if ended then
            current.unload()
            current = next
            next = nil
            current.start()
        end
    end

    return {
        draw = draw;
    }
end

local player = Player()

function node.render()
    gl.clear(1,1,1,0)
    st()

    gl.translate(WIDTH/2, HEIGHT/2)
    gl.scale(scale, scale)
    gl.translate(-WIDTH/2, -HEIGHT/2)

    player.draw()

    if not screen then
        font:write(WIDTH/2-120, HEIGHT/2+140, "NO SCREEN CONFIGURED", 24, 1,1,1,.1)
        font:write(WIDTH/2-60, HEIGHT/2+165, my_serial, 20, 1,1,1,.1)
        return
    elseif outdated then
        font:write(WIDTH/2-110, HEIGHT/2+140, "NO RECENT SCHEDULE", 24, 1,1,1,.1)
        font:write(WIDTH/2-60, HEIGHT/2+165, my_serial, 20, 1,1,1,.1)
        return
    end

    local show = get_current_show()

    if debug then
        local x, y = WIDTH-250, 10
        font:write(x, y, "Serial: " .. my_serial, 12, 1,1,1,1); y=y+12
        local offset = current_offset()
        font:write(x, y, ("Time: %d (%d:%02d)"):format(
            offset, offset/60, offset%60
        ), 12, 1,1,1,1); y=y+12
        if show then
            font:write(x, y, "Next show: "..show.name, 12, 1,1,1,1); y=y+12
            font:write(x, y, ("Show time: %s (%d %d:%02d)"):format(
                show.showtime.string,
                show.showtime.offset,
                show.showtime.hour,
                show.showtime.minute
            ), 12, 1,1,1,1); y=y+12
            font:write(x, y, "Runtime: "..show.runtime, 12, 1,1,1,1); y=y+12
        end
    end

    -- Font size
    local default_size = 80
    if portrait then
        default_size = 60
    end

    if show then
        local text = show.showtime.string .. " " .. show.name

        local size = default_size
        local w

        while true do
            w = font:width(text, size)
            if w > WIDTH - 80 then
                size = size - 2
            else
                break
            end
        end

        local x, y = WIDTH-w-20, HEIGHT-size-10
        box:draw(x, y, x+1800, y+100)
        font:write(WIDTH-w-8, HEIGHT-size+2, text, size, 1,1,1,1)
    end

local size = default_size
local text = "Auditorium " .. screen
local w = font:width(text, size)
local x, y = w+20, size+10
box:draw(x, y, x-1800, y-100)
font:write(5, 8, text, size, 1,1,1,1)




    corner_logo:draw(5, HEIGHT-default_size-5, default_size+5, HEIGHT-5)
end
