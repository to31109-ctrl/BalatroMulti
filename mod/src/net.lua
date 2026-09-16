-- TCP networking for BalatroCoop using the luasocket bundled with LÖVE.
-- Newline-delimited JSON messages. Non-blocking; pumped every frame.
local ok_socket, socket = pcall(require, 'socket')
if not ok_socket then
    COOP.log('luasocket unavailable: ' .. tostring(socket))
    socket = nil
end

local net = { socket = socket }
local json = COOP.json

local MAX_LINE = 4 * 1024 * 1024

-- Conn -----------------------------------------------------------------------
local Conn = {}
Conn.__index = Conn

function Conn.new(sock, label)
    sock:settimeout(0)
    pcall(sock.setoption, sock, 'tcp-nodelay', true)
    pcall(sock.setoption, sock, 'keepalive', true)
    return setmetatable({
        sock = sock, inbuf = '', outbuf = '', alive = true, label = label or '?',
        bytes_in = 0, bytes_out = 0, id = nil,
    }, Conn)
end

function Conn:send_raw(str)
    if not self.alive then return end
    self.outbuf = self.outbuf .. str .. '\n'
end

function Conn:send(tbl)
    local ok, s = pcall(json.encode, tbl)
    if not ok then
        COOP.log('net: encode failed: ' .. tostring(s))
        return
    end
    self:send_raw(s)
end

function Conn:flush()
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

function Conn:receive(handler)
    if not self.alive then return end
    for _ = 1, 500 do
        local line, err, partial = self.sock:receive('*l')
        if line then
            local msg = self.inbuf .. line
            self.inbuf = ''
            self.bytes_in = self.bytes_in + #msg + 1
            if #msg > 0 then handler(msg) end
        elseif err == 'timeout' then
            if partial and #partial > 0 then
                self.inbuf = self.inbuf .. partial
                if #self.inbuf > MAX_LINE then
                    self.alive = false
                    self.err = 'message too large'
                end
            end
            break
        else
            self.alive = false
            self.err = err
            break
        end
    end
end

function Conn:close()
    self.alive = false
    pcall(self.sock.close, self.sock)
end

net.Conn = Conn

-- Host -----------------------------------------------------------------------
local Host = {}
Host.__index = Host

function net.host(port)
    if not socket then return nil, 'luasocket missing' end
    local server, err = socket.bind('*', port)
    if not server then return nil, err end
    server:settimeout(0)
    local h = setmetatable({ server = server, port = port, conns = {}, next_id = 2 }, Host)
    return h
end

function Host:update(on_message, on_disconnect)
    -- accept
    for _ = 1, 8 do
        local sock = self.server:accept()
        if not sock then break end
        local conn = Conn.new(sock, 'client')
        conn.id = self.next_id
        self.next_id = self.next_id + 1
        self.conns[#self.conns + 1] = conn
        COOP.log('net: accepted connection #' .. conn.id)
    end
    -- pump
    for i = #self.conns, 1, -1 do
        local conn = self.conns[i]
        conn:receive(function(line)
            local ok, msg = pcall(json.decode, line)
            if ok and type(msg) == 'table' then
                on_message(conn, msg)
            else
                COOP.log('net: bad message from #' .. tostring(conn.id) .. ': ' .. tostring(msg))
            end
        end)
        conn:flush()
        if not conn.alive then
            table.remove(self.conns, i)
            conn:close()
            on_disconnect(conn, conn.err)
        end
    end
end

function Host:broadcast(tbl, except)
    local ok, s = pcall(json.encode, tbl)
    if not ok then COOP.log('net: encode failed: ' .. tostring(s)); return end
    for _, conn in ipairs(self.conns) do
        if conn ~= except and conn.id then conn:send_raw(s) end
    end
end

function Host:close()
    for _, conn in ipairs(self.conns) do conn:close() end
    self.conns = {}
    pcall(self.server.close, self.server)
end

-- Client ---------------------------------------------------------------------
local Client = {}
Client.__index = Client

function net.connect(ip, port, timeout)
    if not socket then return nil, 'luasocket missing' end
    local sock = socket.tcp()
    sock:settimeout(timeout or 4)
    local ok, err = sock:connect(ip, port)
    if not ok then
        pcall(sock.close, sock)
        return nil, err
    end
    local c = setmetatable({ conn = Conn.new(sock, 'server') }, Client)
    return c
end

function Client:update(on_message, on_disconnect)
    local conn = self.conn
    conn:receive(function(line)
        local ok, msg = pcall(json.decode, line)
        if ok and type(msg) == 'table' then
            on_message(conn, msg)
        else
            COOP.log('net: bad message from host: ' .. tostring(msg))
        end
    end)
    conn:flush()
    if not conn.alive then
        conn:close()
        on_disconnect(conn, conn.err)
    end
end

function Client:send(tbl)
    self.conn:send(tbl)
end

function Client:close()
    self.conn:close()
end

function net.local_ip()
    if not socket then return '?' end
    local ok, ip = pcall(function()
        -- Trick: a UDP socket "connected" to a public address reveals the local outbound IP without sending anything
        local udp = socket.udp()
        udp:setpeername('8.8.8.8', 80)
        local addr = udp:getsockname()
        udp:close()
        return addr
    end)
    if ok and ip and ip ~= '0.0.0.0' then return ip end
    local ok2, host = pcall(socket.dns.gethostname)
    if ok2 and host then
        local ok3, addr = pcall(socket.dns.toip, host)
        if ok3 and addr then return addr end
    end
    return '?'
end

return net
