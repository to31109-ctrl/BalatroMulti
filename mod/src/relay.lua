-- BalatroCoop relay transport: host and clients all connect OUT to the Cloudflare relay
-- (relay/worker.js), so no router configuration is needed on any side.
-- Exposes objects with the same interface core.lua uses for direct TCP (net.host/net.connect).
local relay = {}
COOP.relay = relay
local json = COOP.json

relay.url = nil -- e.g. ws://balatro-coop.<account>.workers.dev/ws

function relay.load_url()
    local f = io.open(COOP.BASE .. '/relay.txt', 'r')
    if not f then return nil end
    local u = f:read('*l')
    f:close()
    u = u and u:gsub('%s+', '') or ''
    if u == '' or u:sub(1, 1) == '#' then return nil end
    if not u:match('^wss?://') then u = 'ws://' .. u end
    if not u:match('/ws$') then u = u:gsub('/+$', '') .. '/ws' end
    relay.url = u
    return u
end

function relay.available()
    return relay.url ~= nil
end

-- Virtual connection for one client, as seen by the host --------------------
local VConn = {}
VConn.__index = VConn

function VConn.new(host, cid)
    return setmetatable({ host = host, id = cid, alive = true, err = nil, bytes_in = 0, bytes_out = 0, outbuf = '', queue = {} }, VConn)
end

function VConn:send_raw(str)
    if not self.alive then return end
    self.bytes_out = self.bytes_out + #str
    self.host.ws:send_text(tostring(self.id) .. '|' .. str)
end

function VConn:send(tbl)
    local ok, s = pcall(json.encode, tbl)
    if ok then self:send_raw(s) else COOP.log('relay: encode failed: ' .. tostring(s)) end
end

function VConn:flush() end

function VConn:receive(handler)
    local q = self.queue
    self.queue = {}
    for _, line in ipairs(q) do
        self.bytes_in = self.bytes_in + #line
        handler(line)
    end
end

function VConn:close()
    self.alive = false
end

-- Host over relay -------------------------------------------------------------
local Host = {}
Host.__index = Host

function relay.host(url)
    local sock, err = COOP.ws.connect(url .. '?role=host', 6)
    if not sock then return nil, err end
    local h = setmetatable({ ws = sock, conns = {}, code = nil, port = 0 }, Host)
    -- wait briefly for the room code
    local deadline = love.timer.getTime() + 5
    while not h.code and love.timer.getTime() < deadline do
        sock:update()
        for _, m in ipairs(sock:take_messages()) do
            local code = m:match('^sys|code|(%w+)$')
            if code then h.code = code end
        end
        if not sock.alive then return nil, 'relay closed: ' .. tostring(sock.err) end
        if not h.code then socket_sleep(0.05) end
    end
    if not h.code then sock:close(); return nil, 'relay did not answer with a room code' end
    return h
end

function socket_sleep(s)
    local sk = COOP.net.socket
    if sk and sk.sleep then sk.sleep(s) end
end

function Host:update(on_message, on_disconnect)
    local sock = self.ws
    sock:update()
    for _, m in ipairs(sock:take_messages()) do
        local sys = m:match('^sys|(.*)$')
        if sys then
            local kind, arg = sys:match('^(%w+)|?(.*)$')
            if kind == 'join' then
                local cid = tonumber(arg)
                if cid then
                    local conn = VConn.new(self, cid)
                    self.conns[#self.conns + 1] = conn
                    COOP.log('relay: client #' .. cid .. ' connected')
                end
            elseif kind == 'leave' then
                local cid = tonumber(arg)
                for i = #self.conns, 1, -1 do
                    if self.conns[i].id == cid then self.conns[i].alive = false; self.conns[i].err = 'left' end
                end
            end
        else
            local cid, payload = m:match('^(%d+)|(.*)$')
            if cid then
                cid = tonumber(cid)
                for _, conn in ipairs(self.conns) do
                    if conn.id == cid and conn.alive then conn.queue[#conn.queue + 1] = payload end
                end
            end
        end
    end
    for i = #self.conns, 1, -1 do
        local conn = self.conns[i]
        conn:receive(function(line)
            local ok, msg = pcall(json.decode, line)
            if ok and type(msg) == 'table' then on_message(conn, msg) else COOP.log('relay: bad message from #' .. tostring(conn.id)) end
        end)
        if not conn.alive then
            table.remove(self.conns, i)
            on_disconnect(conn, conn.err)
        end
    end
    if not sock.alive then
        -- relay link died: everyone is gone
        for i = #self.conns, 1, -1 do
            local conn = self.conns[i]
            conn.alive = false
            table.remove(self.conns, i)
            on_disconnect(conn, 'relay connection lost: ' .. tostring(sock.err))
        end
        if not self.lost_logged then
            self.lost_logged = true
            COOP.log('relay: host link lost: ' .. tostring(sock.err))
            COOP.toast('Relay connection lost', G.C.RED, 4)
        end
    end
end

function Host:broadcast(tbl, except)
    local ok, s = pcall(json.encode, tbl)
    if not ok then return end
    for _, conn in ipairs(self.conns) do
        if conn ~= except and conn.alive then conn:send_raw(s) end
    end
end

function Host:close()
    for _, c in ipairs(self.conns) do c.alive = false end
    self.conns = {}
    pcall(self.ws.close, self.ws)
end

-- Client over relay -------------------------------------------------------------
local Client = {}
Client.__index = Client

function relay.connect(url, code)
    local sock, err = COOP.ws.connect(url .. '?role=join&code=' .. code, 6)
    if not sock then return nil, err end
    -- The connection object mimics net.Conn enough for core.lua (alive/err/bytes/outbuf/flush)
    local conn = { sock = sock, alive = true, err = nil, bytes_in = 0, bytes_out = 0, outbuf = '', inbuf = '' }
    function conn:send(tbl)
        local ok, s = pcall(json.encode, tbl)
        if ok then self.bytes_out = self.bytes_out + #s; sock:send_text(s) end
    end
    function conn:send_raw(s) self.bytes_out = self.bytes_out + #s; sock:send_text(s) end
    function conn:flush() sock:flush() end
    function conn:close() sock:close() end
    local c = setmetatable({ conn = conn, my_cid = nil }, Client)
    return c
end

function Client:update(on_message, on_disconnect)
    local conn, sock = self.conn, self.conn.sock
    sock:update()
    for _, m in ipairs(sock:take_messages()) do
        local sys = m:match('^sys|(.*)$')
        if sys then
            local cid = sys:match('^welcome|(%d+)$')
            if cid then self.my_cid = tonumber(cid) end
        else
            conn.bytes_in = conn.bytes_in + #m
            local ok, msg = pcall(json.decode, m)
            if ok and type(msg) == 'table' then on_message(conn, msg) else COOP.log('relay: bad message from host') end
        end
    end
    conn.outbuf = sock.outbuf
    if not sock.alive then
        conn.alive = false
        conn.err = sock.err
        on_disconnect(conn, sock.err)
    end
end

function Client:send(tbl)
    self.conn:send(tbl)
end

function Client:close()
    self.conn:close()
end

relay.load_url()
return relay
