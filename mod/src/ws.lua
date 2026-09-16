-- Minimal WebSocket client (RFC 6455, text frames) over luasocket for BalatroCoop's relay mode.
-- Blocking handshake with a timeout, then fully non-blocking; pump with :update().
local socket = COOP.net.socket
local ws = {}
COOP.ws = ws

local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift

local function random_bytes(n)
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

local function b64(s)
    return love.data.encode('string', 'base64', s)
end

-- url: ws://host[:port]/path?query
local function parse_ws_url(url)
    local host, port, path = url:match('^ws://([^/:]+):?(%d*)(/?.*)$')
    if not host then return nil end
    if path == '' then path = '/' end
    return host, tonumber(port) or 80, path
end

local Sock = {}
Sock.__index = Sock

function ws.connect(url, timeout)
    if not socket then return nil, 'luasocket missing' end
    if url:match('^wss://') then return nil, 'wss:// (TLS) is not supported; use ws://' end
    local host, port, path = parse_ws_url(url)
    if not host then return nil, 'bad url' end
    local t = socket.tcp()
    t:settimeout(timeout or 6)
    local ok, err = t:connect(host, port)
    if not ok then t:close(); return nil, 'connect: ' .. tostring(err) end
    pcall(t.setoption, t, 'tcp-nodelay', true)
    pcall(t.setoption, t, 'keepalive', true)
    local key = b64(random_bytes(16))
    local req = 'GET ' .. path .. ' HTTP/1.1\r\n'
        .. 'Host: ' .. host .. ((port ~= 80) and (':' .. port) or '') .. '\r\n'
        .. 'Upgrade: websocket\r\nConnection: Upgrade\r\n'
        .. 'Sec-WebSocket-Key: ' .. key .. '\r\nSec-WebSocket-Version: 13\r\n'
        .. 'User-Agent: BalatroCoop\r\n\r\n'
    ok, err = t:send(req)
    if not ok then t:close(); return nil, 'send: ' .. tostring(err) end
    -- read the HTTP response headers
    local status = t:receive('*l')
    if not status then t:close(); return nil, 'no handshake response' end
    if not status:match('^HTTP/1%.1 101') then
        t:close()
        return nil, 'relay refused: ' .. status
    end
    while true do
        local line, lerr = t:receive('*l')
        if not line then t:close(); return nil, 'handshake: ' .. tostring(lerr) end
        if line == '' then break end
    end
    t:settimeout(0)
    local self = setmetatable({ sock = t, inbuf = '', outbuf = '', alive = true, messages = {}, err = nil, bytes_in = 0, bytes_out = 0 }, Sock)
    return self
end

local function frame(opcode, payload)
    local len = #payload
    local head = string.char(bor(0x80, opcode))
    local lenbytes
    if len < 126 then
        lenbytes = string.char(bor(0x80, len))
    elseif len < 65536 then
        lenbytes = string.char(bor(0x80, 126), rshift(len, 8), band(len, 0xFF))
    else
        lenbytes = string.char(bor(0x80, 127), 0, 0, 0, 0,
            band(rshift(len, 24), 0xFF), band(rshift(len, 16), 0xFF), band(rshift(len, 8), 0xFF), band(len, 0xFF))
    end
    local mask = random_bytes(4)
    local m = { mask:byte(1, 4) }
    local out = {}
    for i = 1, len do
        out[i] = string.char(bxor(payload:byte(i), m[((i - 1) % 4) + 1]))
    end
    return head .. lenbytes .. mask .. table.concat(out)
end

function Sock:send_text(s)
    if not self.alive then return end
    self.outbuf = self.outbuf .. frame(0x1, s)
end

function Sock:send_pong(s)
    if not self.alive then return end
    self.outbuf = self.outbuf .. frame(0xA, s or '')
end

function Sock:close(code)
    if self.alive then
        pcall(function()
            self.sock:settimeout(0.2)
            self.sock:send(frame(0x8, string.char(0x03, 0xE8)))
        end)
    end
    self.alive = false
    pcall(self.sock.close, self.sock)
end

function Sock:flush()
    if not self.alive then return end
    local guard = 0
    while #self.outbuf > 0 and guard < 64 do
        guard = guard + 1
        local n, err, last = self.sock:send(self.outbuf)
        if n then
            self.bytes_out = self.bytes_out + n
            self.outbuf = self.outbuf:sub(n + 1)
        elseif err == 'timeout' then
            local sent = last or 0
            self.bytes_out = self.bytes_out + sent
            self.outbuf = self.outbuf:sub(sent + 1)
            break
        else
            self.alive = false
            self.err = err
            break
        end
    end
end

-- parse complete frames from inbuf; returns list of text messages
function Sock:parse()
    local buf = self.inbuf
    local pos = 1
    local out = self.messages
    while true do
        if #buf - pos + 1 < 2 then break end
        local b1, b2 = buf:byte(pos, pos + 1)
        local fin = band(b1, 0x80) ~= 0
        local opcode = band(b1, 0x0F)
        local masked = band(b2, 0x80) ~= 0
        local len = band(b2, 0x7F)
        local p = pos + 2
        if len == 126 then
            if #buf - p + 1 < 2 then break end
            local a, b = buf:byte(p, p + 1)
            len = a * 256 + b
            p = p + 2
        elseif len == 127 then
            if #buf - p + 1 < 8 then break end
            local b5, b6, b7, b8 = buf:byte(p + 4, p + 7)
            len = ((b5 * 256 + b6) * 256 + b7) * 256 + b8
            p = p + 8
        end
        local mask
        if masked then
            if #buf - p + 1 < 4 then break end
            mask = { buf:byte(p, p + 3) }
            p = p + 4
        end
        if #buf - p + 1 < len then break end
        local payload = buf:sub(p, p + len - 1)
        if mask then
            local t = {}
            for i = 1, len do t[i] = string.char(bxor(payload:byte(i), mask[((i - 1) % 4) + 1])) end
            payload = table.concat(t)
        end
        pos = p + len
        if opcode == 0x1 or opcode == 0x0 then
            if fin then
                out[#out + 1] = (self.partial or '') .. payload
                self.partial = nil
            else
                self.partial = (self.partial or '') .. payload
            end
        elseif opcode == 0x8 then
            self.alive = false
            self.err = 'closed by relay' .. ((#payload >= 2) and (' (' .. (payload:byte(1) * 256 + payload:byte(2)) .. ')') or '')
            break
        elseif opcode == 0x9 then
            self:send_pong(payload)
        end
    end
    self.inbuf = buf:sub(pos)
end

function Sock:update()
    if not self.alive then return end
    for _ = 1, 64 do
        local data, err, partial = self.sock:receive(65536)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            self.inbuf = self.inbuf .. chunk
            self.bytes_in = self.bytes_in + #chunk
        end
        if err == 'timeout' then break end
        if err and err ~= 'timeout' then
            self.alive = false
            self.err = err
            break
        end
        if not data then break end
    end
    if #self.inbuf > 0 then self:parse() end
    self:flush()
end

-- pop received text messages
function Sock:take_messages()
    local m = self.messages
    self.messages = {}
    return m
end

return ws
