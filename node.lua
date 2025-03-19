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

local current_poster_height = HEIGHT * 0.6 -- default fallback

local schedule = bload.Bload()

-- (unchanged setup code here)

local function Image(asset_name, duration)
    print("started new image " .. asset_name)
    local obj = resource.load_image(asset_name)
    local started

    local function start()
        started = sys.now()
    end
    local function draw()
        local w, h = obj:size()
        local x1, y1, x2, y2 = util.scale_into(WIDTH, HEIGHT, w, h)
        local scale_factor = WIDTH / (x2 - x1)
        current_poster_height = (y2 - y1) * scale_factor
        obj:draw(0, 0, WIDTH, current_poster_height)
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
                local x1, y1, x2, y2 = util.scale_into(WIDTH, HEIGHT, w, h)
                local scale_factor = WIDTH / (x2 - x1)
                current_poster_height = (y2 - y1) * scale_factor
                obj:place(0, 0, WIDTH, current_poster_height, rotation)
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

-- (player logic unchanged)

function node.render()
    gl.clear(1,1,1,0)
    st()

    gl.translate(WIDTH/2, HEIGHT/2)
    gl.scale(scale, scale)
    gl.translate(-WIDTH/2, -HEIGHT/2)

    player.draw()

    local default_size = 80
    if portrait then
        default_size = 60
    end

    local show = get_current_show()

    if show then
        local full_text = "Auditorium " .. screen .. " : " .. show.showtime.string .. " " .. show.name
        local text_size = default_size - 10

        while font:width(full_text, text_size) > WIDTH - 40 do
            text_size = text_size - 2
            if text_size < 20 then break end
        end

        local full_w = font:width(full_text, text_size)
        local full_x = (WIDTH / 2) - (full_w / 2)
        local full_y = current_poster_height + ((HEIGHT - current_poster_height) / 2) - (text_size / 2)

        box:draw(full_x - 10, full_y - 10, full_x + full_w + 10, full_y + text_size + 10)
        font:write(full_x, full_y, full_text, text_size, 1,1,1,1)
    end

    corner_logo:draw(5, HEIGHT - default_size - 5, default_size + 5, HEIGHT - 5)
end
