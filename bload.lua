local M = {}

function M.Bload()
    local function strip(s)
        return s:match "^%s*(.-)%s*$"
    end

    -- Sometimes the name has another numerical suffix. Throw that away.
    local function strip_name(s)
        return strip(s:sub(1, 29))
    end

    local function hhmm(s)
        local hour, minute = s:match("(..)(..)")
        local hour, minute = tonumber(hour), tonumber(minute)
        local function mil2ampm(hour, minute)
            local suffix = hour < 12 and "am" or ""
            return ("%d:%02d%s"):format((hour-1) % 12 +1, minute, suffix)
        end
        return {
            hour = hour,
            minute = minute,
            offset = hour * 60 + minute,
            string = mil2ampm(hour, minute),
        }
    end
    local function tobool(str)
        return tonumber(str) == 1
    end

    local function convert(names, fixups, ...)
        local cols = {...}
        local out = {}
        for i = 1, #fixups do
            out[names[i]] = fixups[i](cols[i])
        end
        return out
    end

    local screens = {}
    local bload, date

    local function parse_bload()
        if not bload then
            print("BLOAD: cannot parse yet. no bload")
            return
        end

        local movies = {}
        for line in bload:gmatch("[^\r\n]+") do
            -- "123456789012345678901234567890123456789012345678901234567890123456789012345"
            -- "1111111122 33 4444 555  6666 7777 8 9999AAAAAAAAAAAAAAAAAAAAAAAAAAAAA     B"
            -- "06/25/151  1  1320 94   10   231  0     Inside Out                        0"

            local single_day = true
            local row

            if single_day then 
                row = convert(
                    {"screen", "show",   "showtime", "runtime", "sold",   "seats",  "threed", "mpaa", "name"},
                    {strip,    tonumber, hhmm,       tonumber,  tonumber, tonumber, tobool,   strip,  strip},
                    line:match("(..) (..) (....) (...)  (....) (....) (.) (....)(.*)")
                )
            else
                if not date then
                    print("BLOAD: cannot parse yet. no bload")
                    return
                end
                row = convert(
                    {"date","screen", "show",   "showtime", "runtime", "sold",   "seats",  "threed", "mpaa", "name"},
                    {strip, strip,    tonumber, hhmm,       tonumber,  tonumber, tonumber, tobool,   strip,  strip_name},
                    line:match("(........)(..) (..) (....) (...)  (....) (....) (.) (....)(.............................)")
                )
            end

            if single_day or row.date == date then
                movies[#movies+1] = {
                    name = row.name,
                    match_name = row.name:lower(),
                    mpaa = row.mpaa,
                    threed = row.threed,
                    showtime = row.showtime,
                    runtime = row.runtime,
                    screen = row.screen,
                }
            end
        end

        screens = {}
        for idx = 1, #movies do
            local movie = movies[idx]
            if not screens[movie.screen] then
                screens[movie.screen] = {}
            end
            local screen = screens[movie.screen]
            screen[#screen+1] = movie
        end

        for screen, movies in pairs(screens) do
            table.sort(movies, function(a, b)
                return a.showtime.offset < b.showtime.offset
            end)
        end
        -- pp(screens)
    end

    local function set_bload(new_bload)
        if new_bload == bload then return end
        bload = new_bload
        return parse_bload()
    end

    local function set_date(new_date)
        if new_date == date then return end
        date = new_date
        return parse_bload()
    end

    local function get_screens()
        return screens
    end

    return {
        set_bload = set_bload;
        set_date = set_date;

        get_screens = get_screens;
    }
end

return M


