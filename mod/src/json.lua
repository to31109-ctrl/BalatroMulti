-- Minimal JSON encoder/decoder for BalatroCoop network messages.
-- Lua tables with consecutive integer keys 1..n become arrays; everything else
-- becomes an object. Numeric object keys are encoded as strings and restored to
-- numbers on decode (Balatro card save tables never use numeric-looking string keys).
local json = {}

local BS = string.char(92) -- backslash

local escape_map = {
    ['"'] = BS .. '"', [BS] = BS .. BS, ['\b'] = BS .. 'b', ['\f'] = BS .. 'f',
    ['\n'] = BS .. 'n', ['\r'] = BS .. 'r', ['\t'] = BS .. 't',
}

local function escape_char(c)
    return escape_map[c] or string.format(BS .. 'u%04x', c:byte())
end

local function encode_string(s)
    return '"' .. s:gsub('[%c"' .. BS .. ']', escape_char) .. '"'
end

local function is_array(t)
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= 'number' or k <= 0 or math.floor(k) ~= k then return false end
        n = n + 1
    end
    if n == 0 then return false end
    return n == #t
end

local encode_value

local function encode_table(t, out, depth)
    if depth > 40 then error('json: nesting too deep') end
    if t.is and type(t.is) == 'function' then
        -- Balatro Object instance: never serialize
        out[#out + 1] = 'null'
        return
    end
    if is_array(t) then
        out[#out + 1] = '['
        for i = 1, #t do
            if i > 1 then out[#out + 1] = ',' end
            encode_value(t[i], out, depth + 1)
        end
        out[#out + 1] = ']'
    else
        out[#out + 1] = '{'
        local first = true
        for k, v in pairs(t) do
            local tk = type(k)
            if (tk == 'string' or tk == 'number') and type(v) ~= 'function' and type(v) ~= 'userdata' then
                if not first then out[#out + 1] = ',' end
                first = false
                out[#out + 1] = encode_string(tostring(k))
                out[#out + 1] = ':'
                encode_value(v, out, depth + 1)
            end
        end
        out[#out + 1] = '}'
    end
end

encode_value = function(v, out, depth)
    local tv = type(v)
    if tv == 'nil' then
        out[#out + 1] = 'null'
    elseif tv == 'boolean' then
        out[#out + 1] = v and 'true' or 'false'
    elseif tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = 'null'
        elseif math.floor(v) == v and math.abs(v) < 1e15 then
            out[#out + 1] = string.format('%d', v)
        else
            out[#out + 1] = string.format('%.14g', v)
        end
    elseif tv == 'string' then
        out[#out + 1] = encode_string(v)
    elseif tv == 'table' then
        encode_table(v, out, depth)
    else
        out[#out + 1] = 'null'
    end
end

function json.encode(v)
    local out = {}
    encode_value(v, out, 0)
    return table.concat(out)
end

-- Decoder -------------------------------------------------------------------
local decode_value

local function skip_ws(s, i)
    local _, e = s:find('^[ \t\r\n]*', i)
    return e + 1
end

local unescape_map = {
    ['"'] = '"', [BS] = BS, ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function utf8_char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local STR_STOP = '["' .. BS .. ']'

local function decode_string(s, i)
    -- s:sub(i,i) == '"'
    local out = {}
    local j = i + 1
    while true do
        local c = s:sub(j, j)
        if c == '' then error('json: unterminated string') end
        if c == '"' then
            return table.concat(out), j + 1
        elseif c == BS then
            local n = s:sub(j + 1, j + 1)
            if n == 'u' then
                local hex = s:sub(j + 2, j + 5)
                local code = tonumber(hex, 16)
                if not code then error('json: bad unicode escape') end
                out[#out + 1] = utf8_char(code)
                j = j + 6
            else
                local r = unescape_map[n]
                if not r then error('json: bad escape ' .. tostring(n)) end
                out[#out + 1] = r
                j = j + 2
            end
        else
            local nxt = s:find(STR_STOP, j)
            if not nxt then error('json: unterminated string') end
            out[#out + 1] = s:sub(j, nxt - 1)
            j = nxt
        end
    end
end

local function decode_number(s, i)
    local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
    if not num or num == '' then error('json: bad number at ' .. i) end
    local v = tonumber(num)
    if not v then error('json: bad number ' .. num) end
    return v, i + #num
end

local function decode_array(s, i)
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    local n = 0
    while true do
        local v
        v, i = decode_value(s, i)
        n = n + 1
        arr[n] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == ']' then return arr, i + 1 end
        if c ~= ',' then error('json: expected , or ] at ' .. i) end
        i = skip_ws(s, i + 1)
    end
end

local function decode_object(s, i)
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
        if s:sub(i, i) ~= '"' then error('json: expected key at ' .. i) end
        local k
        k, i = decode_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ':' then error('json: expected : at ' .. i) end
        i = skip_ws(s, i + 1)
        local v
        v, i = decode_value(s, i)
        local nk = tonumber(k)
        if nk and k:match('^%-?%d+$') then k = nk end
        obj[k] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == '}' then return obj, i + 1 end
        if c ~= ',' then error('json: expected , or } at ' .. i) end
        i = skip_ws(s, i + 1)
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '{' then return decode_object(s, i) end
    if c == '[' then return decode_array(s, i) end
    if c == '"' then return decode_string(s, i) end
    if c == 't' and s:sub(i, i + 3) == 'true' then return true, i + 4 end
    if c == 'f' and s:sub(i, i + 4) == 'false' then return false, i + 5 end
    if c == 'n' and s:sub(i, i + 3) == 'null' then return nil, i + 4 end
    if c == '-' or c:match('%d') then return decode_number(s, i) end
    error('json: unexpected character "' .. c .. '" at ' .. i)
end

function json.decode(s)
    if type(s) ~= 'string' then error('json: expected string') end
    local v, i = decode_value(s, 1)
    i = skip_ws(s, i)
    if i <= #s then error('json: trailing garbage at ' .. i) end
    return v
end

return json
