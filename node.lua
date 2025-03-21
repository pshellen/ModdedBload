gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)
util.no_globals()

local json = require "json"
local bload = require "bload"
local glob = require "globtopattern".globtopattern
local matrix = require "matrix2d"

local font = resource.load_font "font.ttf"
local box = resource.load_image "box.png"

local screen
local movies = {}
local shows = {}

local st, vid_scaler
local portrait, rotation, main_logo_name, corner_logo
local debug = true
local outdated = false

local my_serial = sys.get_env "SERIAL"
local scale = 1

local fade_alpha = 1
local fading = false
local fade_timer = 0
local fade_duration = 1.0

local schedule = bload.Bload()

local function load_bload(raw)
    schedule.set_bload(raw)
    local screens = schedule.get_screens()
    shows = screens[screen] or {}
end

util.file_watch("config.json", function(raw)
    local config = json.decode(raw)
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
    movies = config.movies
    for idx = 1, #movies do
        local movie = movies[idx]
        movie.match_pattern = glob(movie.pattern:lower())
    end
    gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)
    st = util.screen_transform(rotation)
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
    if outdated then return end
    for idx = 1, #shows do
        local show = shows[idx]
        local next_show = shows[idx+1]
        local starts, ends
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
        if starts <= offset and offset < ends then
            return show
        end
    end
end

util.data_mapper{
    ["age/set"] = function(age)
        outdated = tonumber(age) > 3600 * 6
    end;
    ["clock/set"] = function(time)
        base_time = tonumber(time) - sys.now()
    end;
    ["date/set"] = function(date)
        schedule.set_date(date)
    end;
}

local function get_assets()
    local show = get_current_show()
    for idx = 1, #movies do
        local movie = movies[idx]
        if show and show.match_name:match(movie.match_pattern) then
            return movie.assets
        end
    end
    return { {
        media = {
            asset_name = main_logo_name,
            type = "image",
        },
        duration = 5
    } }
end

local function Image(asset_name, duration)
    local obj = resource.load_image(asset_name)
    local started

    local function start()
        started = sys.now()
    end

    local function draw()
        gl.pushMatrix()
        gl.translate(WIDTH/2, HEIGHT/2)
        gl.scale(scale, scale)
        gl.translate(-WIDTH/2, -HEIGHT/2)

        local w_img, h_img = obj:size()
        if asset_name == main_logo_name then
            local scale_factor = math.min(WIDTH / w_img, HEIGHT / h_img) * 0.8
            local draw_w = w_img * scale_factor
            local draw_h = h_img * scale_factor
            local cx = (WIDTH - draw_w) / 2
            local cy = (HEIGHT - draw_h) / 2
            obj:draw(cx, cy, cx + draw_w, cy + draw_h)
        else
            local offset_top = 15
            local x1, y1, x2, y2 = util.scale_into(WIDTH, HEIGHT, w_img, h_img)
            obj:draw(0, offset_top, WIDTH, y2 - y1)
        end

        gl.popMatrix()
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
            local assets = get_assets()
            offset = offset + 1
            if offset > #assets then offset = 1 end
            local asset = assets[offset]
            next = ({
                image = Image;
                video = Video;
            })[asset.media.type](asset.media.asset_name, asset.duration)
            fading = true
            fade_timer = sys.now()
        end
        local ended = current.draw()
        if ended then
            current.unload()
            current = next
            next = nil
            current.start()
        end
    end
    return { draw = draw }
end

local player = Player()

function node.render()
    gl.clear(1,1,1,0)
    st()

    gl.pushMatrix()
    player.draw()
    gl.popMatrix()

    if fading then
        local t = sys.now() - fade_timer
        fade_alpha = 1 - math.min(1, t / fade_duration)
        if fade_alpha <= 0 then
            fade_alpha = 0
            fading = false
        end

        gl.color(0, 0, 0, fade_alpha)
        gl.rect(0, 0, WIDTH, HEIGHT)
        gl.color(1,1,1,1)
    end

    gl.translate(WIDTH/2, HEIGHT/2)
    gl.scale(scale, scale)
    gl.translate(-WIDTH/2, -HEIGHT/2)

    local default_size = 80
    if portrait then
        default_size = 60
    end

    local show = get_current_show()

    if show then
        local full_text = "Auditorium " .. screen .. " : " .. show.showtime.string .. " " .. show.name
        local text_size = default_size + 10

        while font:width(full_text, text_size) > WIDTH - 40 do
            text_size = text_size - 2
            if text_size < 20 then break end
        end

        local full_w = font:width(full_text, text_size)
        local full_x = (WIDTH / 2) - (full_w / 2)

        local full_y = HEIGHT - text_size - 150

        box:draw(full_x - 10, full_y - 10, full_x + full_w + 10, full_y + text_size + 10)
        font:write(full_x, full_y, full_text, text_size, 1,1,1,1)
    end

    corner_logo:draw(10, HEIGHT - default_size - 10, default_size + 10, HEIGHT - 10)
end
