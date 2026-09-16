-- Simple file logger. Writes to the LÖVE save directory (%APPDATA%/Balatro/coop.log)
-- and mirrors to stdout.
local MAX_BYTES = 2 * 1024 * 1024

local function stamp()
    return os.date('%H:%M:%S')
end

local buffer = {}
local opened = false

local function ensure_open()
    if opened then return end
    opened = true
    local ok, info = pcall(love.filesystem.getInfo, 'coop.log')
    if ok and info and info.size and info.size > MAX_BYTES then
        pcall(love.filesystem.write, 'coop.log', '')
    end
    pcall(love.filesystem.append, 'coop.log', '\n==== BalatroCoop session ' .. os.date('%Y-%m-%d %H:%M:%S') .. ' ====\n')
end

function COOP.log(msg, ...)
    if select('#', ...) > 0 then
        local ok, s = pcall(string.format, tostring(msg), ...)
        msg = ok and s or (tostring(msg) .. ' ' .. table.concat({ ... }, ' '))
    end
    local line = '[' .. stamp() .. '] ' .. tostring(msg)
    print('[COOP] ' .. tostring(msg))
    if love and love.filesystem then
        ensure_open()
        pcall(love.filesystem.append, 'coop.log', line .. '\n')
    else
        buffer[#buffer + 1] = line
    end
end

function COOP.logf(fmt, ...)
    COOP.log(fmt, ...)
end

function COOP.safe(fn, label)
    return function(...)
        local res = { pcall(fn, ...) }
        if not res[1] then
            COOP.log('ERROR in ' .. tostring(label or 'callback') .. ': ' .. tostring(res[2]))
            COOP.last_error = tostring(res[2])
            return nil
        end
        return unpack(res, 2)
    end
end
