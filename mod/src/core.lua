-- BalatroCoop core: lobby, players, run flow (turns, votes, money), message routing.
local json = COOP.json
local net = COOP.net

COOP.MAX_PLAYERS = 4
COOP.DEFAULT_PORT = 21337

COOP.mode = nil          -- 'host' | 'client' | nil
COOP.active = false      -- a co-op run is in progress
COOP.host_obj = nil      -- net host
COOP.client_obj = nil    -- net client
COOP.me = { id = nil, name = 'Player' }
COOP.players = {}        -- ordered: {id, name, conn(host only)}
COOP.lobby = { deck = 'Red Deck', stake = 1, turn_order = 'rotate', started = false }
COOP.run = nil
COOP.cfg = { name = '', ip = '127.0.0.1', port = tostring(COOP.DEFAULT_PORT) }
COOP.executing = false   -- true while replaying a host decision locally
COOP.status = ''
COOP.starting = false

-- Config persistence ----------------------------------------------------------
function COOP.load_config()

do
    local orig_handler = love.errorhandler or love.errhand
    local function coop_errorhandler(msg)
        pcall(function()
            local text = 'CRASH: ' .. tostring(msg)
            COOP.log(text)
            COOP.log('CRASH traceback: ' .. tostring(debug.traceback()):sub(1, 1500):gsub('\n', ' | '))
            -- push the last lines to the host right now, before the game dies
            if COOP.mode == 'client' and COOP.client_obj then
                COOP.client_obj:send({ t = 'rlog', line = text })
                if COOP.client_obj.conn and COOP.client_obj.conn.flush then COOP.client_obj.conn:flush() end
                if COOP.client_obj.conn and COOP.client_obj.conn.sock and COOP.client_obj.conn.sock.flush then COOP.client_obj.conn.sock:flush() end
            end
        end)
        if orig_handler then return orig_handler(msg) end
    end
    love.errorhandler = coop_errorhandler
    love.errhand = coop_errorhandler
end
    local ok, data = pcall(love.filesystem.read, 'coop_config.json')
    if ok and data and data ~= '' then
        local ok2, cfg = pcall(json.decode, data)
        if ok2 and type(cfg) == 'table' then
            for k, v in pairs(cfg) do COOP.cfg[k] = v end
        end
    end
    if not COOP.cfg.name or COOP.cfg.name == '' then
        COOP.cfg.name = 'Player' .. tostring(math.random(10, 99))
    end
    COOP.cfg.port = tostring(COOP.cfg.port or COOP.DEFAULT_PORT)
end

function COOP.save_config()
    pcall(love.filesystem.write, 'coop_config.json', json.encode(COOP.cfg))
end

-- Helpers --------------------------------------------------------------------
function COOP.is_host() return COOP.mode == 'host' end
function COOP.connected() return COOP.mode ~= nil end

function COOP.get_player(id)
    for _, p in ipairs(COOP.players) do
        if p.id == id then return p end
    end
end

function COOP.player_name(id)
    local p = COOP.get_player(id)
    return p and p.name or ('P' .. tostring(id))
end

function COOP.player_count()
    return #COOP.players
end

function COOP.is_my_turn()
    return COOP.active and COOP.run ~= nil and COOP.run.turn.active == COOP.me.id
end

function COOP.can_act()
    if not COOP.active then return true end
    return COOP.is_my_turn()
end

function COOP.player_summaries()
    local list = {}
    for _, p in ipairs(COOP.players) do
        list[#list + 1] = { id = p.id, name = p.name }
    end
    return list
end

function COOP.toast(text, colour, hold)
    if COOP.ui and COOP.ui.toast then
        pcall(COOP.ui.toast, text, colour, hold)
    end
    COOP.log('toast: ' .. tostring(text))
end

-- Messaging ------------------------------------------------------------------
-- Every message is a table with field t = type.
COOP.host_handlers = {}    -- messages arriving at the host (from clients or host itself)
COOP.client_handlers = {}  -- messages arriving at a client (from host, or host to itself)

function COOP.send_to_host(msg)
    if COOP.mode == 'host' then
        local me = COOP.get_player(COOP.me.id)
        COOP.dispatch_host(me, msg)
    elseif COOP.mode == 'client' and COOP.client_obj then
        COOP.client_obj:send(msg)
    end
end

function COOP.send_to(player, msg)
    if not player then return end
    if player.id == COOP.me.id then
        COOP.dispatch_client(msg)
    elseif player.conn then
        player.conn:send(msg)
    end
end

function COOP.broadcast(msg, except_id)
    if COOP.mode ~= 'host' then return end
    for _, p in ipairs(COOP.players) do
        if p.id ~= except_id then COOP.send_to(p, msg) end
    end
end

function COOP.dispatch_host(player, msg)
    local h = COOP.host_handlers[msg.t]
    if not h then
        COOP.log('host: unknown message ' .. tostring(msg.t))
        return
    end
    local ok, err = pcall(h, player, msg)
    if not ok then COOP.log('host handler ' .. tostring(msg.t) .. ' failed: ' .. tostring(err)) end
end

function COOP.dispatch_client(msg)
    local h = COOP.client_handlers[msg.t]
    if not h then
        COOP.log('client: unknown message ' .. tostring(msg.t))
        return
    end
    local ok, err = pcall(h, msg)
    if not ok then COOP.log('client handler ' .. tostring(msg.t) .. ' failed: ' .. tostring(err)) end
end

-- Hosting / joining ----------------------------------------------------------
function COOP.reset_state()
    COOP.mode = nil
    COOP.host_obj = nil
    COOP.client_obj = nil
    COOP.players = {}
    COOP.me.id = nil
    COOP.lobby.started = false
    COOP.run = nil
    COOP.active = false
    COOP.executing = false
    COOP.status = ''
    if COOP.spectate then pcall(COOP.spectate.stop) end
    if COOP.ui and COOP.ui.remove_hud then pcall(COOP.ui.remove_hud) end
end

function COOP.start_host_relay()
    COOP.leave(true)
    COOP.transport = 'relay'
    local h, err = COOP.relay.host(COOP.relay.url)
    if not h then
        COOP.status = 'Relay unavailable (' .. tostring(err) .. '). Try Direct hosting.'
        COOP.log(COOP.status)
        return false, err
    end
    COOP.mode = 'host'
    COOP.host_obj = h
    COOP.me.id = 1
    COOP.me.name = COOP.cfg.name
    COOP.players = { { id = 1, name = COOP.cfg.name, conn = nil } }
    COOP.lobby.started = false
    COOP.host_info = { port = 0, lan_ip = net.local_ip(), code = h.code, relay = true }
    COOP.status = 'Relay room open. Share the JOIN CODE with your friends (works anywhere, no router setup).'
    COOP.log('hosting via relay, room ' .. tostring(h.code))
    return true
end

function COOP.start_host(port, transport)
    COOP.leave(true)
    transport = transport or COOP.cfg.transport or 'auto'
    if (transport == 'relay' or transport == 'auto') and not COOP.relay.available() then transport = 'direct' end
    COOP.transport = transport
    if transport == 'relay' then
        COOP.status = 'Connecting to the relay...'
        local h, err = COOP.relay.host(COOP.relay.url)
        if not h then
            COOP.status = 'Relay unavailable (' .. tostring(err) .. '). Try Direct hosting.'
            COOP.log(COOP.status)
            return false, err
        end
        COOP.mode = 'host'
        COOP.host_obj = h
        COOP.me.id = 1
        COOP.me.name = COOP.cfg.name
        COOP.players = { { id = 1, name = COOP.cfg.name, conn = nil } }
        COOP.lobby.started = false
        COOP.host_info = { port = 0, lan_ip = net.local_ip(), code = h.code, relay = true }
        COOP.status = 'Relay room open. Share the JOIN CODE with your friends (works anywhere, no router setup).'
        COOP.log('hosting via relay, room ' .. tostring(h.code))
        return true
    end
    port = tonumber(port) or COOP.DEFAULT_PORT
    local h, err = net.host(port)
    if not h then
        COOP.status = 'Could not open port ' .. tostring(port) .. ': ' .. tostring(err)
        COOP.log(COOP.status)
        return false, err
    end
    COOP.mode = 'host'
    COOP.host_obj = h
    COOP.me.id = 1
    COOP.me.name = COOP.cfg.name
    COOP.players = { { id = 1, name = COOP.cfg.name, conn = nil } }
    COOP.lobby.started = false
    local lan_ip = net.local_ip()
    COOP.host_info = { port = port, lan_ip = lan_ip, lan_code = COOP.upnp.encode_code(lan_ip, port), code = nil, upnp_error = nil }
    COOP.status = 'Opening the router port automatically (UPnP)...'
    COOP.log('hosting on port ' .. port)
    local ok, ext, err = COOP.upnp.open_port(port, lan_ip)
    if ok and ext then
        COOP.host_info.code = COOP.upnp.encode_code(ext, port)
        COOP.host_info.external_ip = ext
        COOP.status = 'Port opened on your router. Share the JOIN CODE with your friends.'
    else
        if transport == 'auto' then
            -- router refused: fall back to the relay so hosting still works
            COOP.log('auto transport: UPnP failed (' .. tostring(err) .. '), switching to relay')
            return COOP.start_host_relay()
        end
        COOP.host_info.upnp_error = err
        local ext2 = COOP.upnp.public_ip_from_web()
        if ext2 then
            COOP.host_info.code = COOP.upnp.encode_code(ext2, port)
            COOP.host_info.external_ip = ext2
        end
        COOP.status = 'Router did not open the port automatically (' .. tostring(err) .. '). Internet code may not work; LAN code works on the same network.'
    end
    if transport == 'auto' then COOP.transport = 'direct' end
    return true
end

function COOP.join(ip, port)
    COOP.leave(true)
    ip = tostring(ip or ''):gsub('%s+', '')
    local relay_code = ip:upper():gsub('[^%w]', '')
    if #relay_code == 5 and not ip:find('%.') then
        if not COOP.relay.available() then
            COOP.status = 'That looks like a relay code, but this build has no relay address configured'
            return false, 'no relay'
        end
        COOP.status = 'Connecting to relay room ' .. relay_code .. ' ...'
        local c, err = COOP.relay.connect(COOP.relay.url, relay_code)
        if not c then
            COOP.status = 'Relay join failed: ' .. tostring(err)
            COOP.log(COOP.status)
            return false, err
        end
        COOP.mode = 'client'
        COOP.transport = 'relay'
        COOP.client_obj = c
        COOP.me.name = COOP.cfg.name
        COOP.players = {}
        c:send({ t = 'hello', name = COOP.cfg.name, ver = COOP.VERSION, proto = COOP.PROTOCOL })
        COOP.status = 'Connected to relay, waiting for host...'
        COOP.log('joined relay room ' .. relay_code)
        return true
    end
    if COOP.upnp.looks_like_code(ip) then
        local cip, cport = COOP.upnp.decode_code(ip)
        if not cip then
            COOP.status = 'That join code is not valid'
            return false, 'bad code'
        end
        ip, port = cip, cport
    else
        -- The Balatro text input turns "0" into "o"; undo that for addresses.
        ip = ip:gsub('[oO]', '0')
        port = tonumber((tostring(port or ''):gsub('[oO]', '0'))) or COOP.DEFAULT_PORT
    end
    COOP.status = 'Connecting to ' .. ip .. ':' .. port .. ' ...'
    local c, err = net.connect(ip, port, 4)
    if not c then
        COOP.status = 'Connection failed: ' .. tostring(err)
        COOP.log(COOP.status)
        return false, err
    end
    COOP.mode = 'client'
    COOP.transport = 'direct'
    COOP.client_obj = c
    COOP.me.name = COOP.cfg.name
    COOP.players = {}
    c:send({ t = 'hello', name = COOP.cfg.name, ver = COOP.VERSION, proto = COOP.PROTOCOL })
    COOP.status = 'Connected, waiting for host...'
    COOP.log('joined ' .. ip .. ':' .. port)
    return true
end

function COOP.leave(silent)
    if COOP.host_obj then
        if COOP.transport ~= 'relay' then pcall(COOP.upnp.close_port) end
        COOP.broadcast({ t = 'kick', reason = 'Host closed the lobby' })
        for _, p in ipairs(COOP.players) do
            if p.conn then p.conn:flush() end
        end
        pcall(COOP.host_obj.close, COOP.host_obj)
    end
    if COOP.client_obj then
        pcall(function() COOP.client_obj:send({ t = 'leave' }); COOP.client_obj.conn:flush() end)
        pcall(COOP.client_obj.close, COOP.client_obj)
    end
    local was_active = COOP.active
    if was_active then COOP.end_local_run_mods() end
    COOP.load_meta = nil
    COOP.pending_local_dollars = 0
    COOP.wallet_target = nil
    COOP.reset_state()
    if not silent then COOP.log('left co-op session') end
end

-- Per-frame pump -------------------------------------------------------------
local function host_on_message(conn, msg)
    local player = nil
    for _, p in ipairs(COOP.players) do
        if p.conn == conn then player = p end
    end
    if not player then
        if msg.t == 'hello' then
            COOP.host_handlers.hello(conn, msg)
        end
        return
    end
    COOP.dispatch_host(player, msg)
end

local function host_on_disconnect(conn, err)
    for i, p in ipairs(COOP.players) do
        if p.conn == conn then
            COOP.log('player ' .. p.name .. ' disconnected (' .. tostring(err) .. ')')
            table.remove(COOP.players, i)
            COOP.on_player_left(p)
            return
        end
    end
end

local function client_on_message(conn, msg)
    COOP.dispatch_client(msg)
end

local function client_on_disconnect(conn, err)
    COOP.log('disconnected from host: ' .. tostring(err))
    COOP.toast('Disconnected from host', G.C.RED, 3)
    if COOP.active then COOP.end_local_run_mods() end
    COOP.reset_state()
    COOP.status = 'Disconnected from host (' .. tostring(err) .. ')'
    if COOP.ui and COOP.ui.on_disconnected then pcall(COOP.ui.on_disconnected) end
end

COOP.timers = { snapshot = 0, cursor = 0, shop = 0, hud = 0 }

COOP.perf = { slow_logged_at = 0, worst = 0 }
COOP.diag = { rlog_budget = 20, rlog_last_refill = 0, stats_at = 0, ping_at = 0, rtt = {}, stall_logged_at = 0 }

-- Every log line written by a client is also sent to the host (throttled), so the host has
-- all players' logs in %APPDATA%/Balatro/coop_players.log without anyone sending files.
do
    local base_log = COOP.log
    COOP.log = function(msg, ...)
        base_log(msg, ...)
        if COOP.mode == 'client' and COOP.client_obj then
            local d = COOP.diag
            local now = love.timer and love.timer.getTime() or 0
            if now - d.rlog_last_refill >= 1 then d.rlog_budget, d.rlog_last_refill = 20, now end
            if d.rlog_budget > 0 then
                d.rlog_budget = d.rlog_budget - 1
                local line = tostring(msg)
                if select('#', ...) > 0 then
                    local ok, s = pcall(string.format, line, ...)
                    if ok then line = s end
                end
                pcall(function() COOP.client_obj:send({ t = 'rlog', line = line:sub(1, 400) }) end)
            end
        end
    end
end

local function players_log(name, line)
    pcall(love.filesystem.append, 'coop_players.log', '[' .. os.date('%H:%M:%S') .. '] [' .. tostring(name) .. '] ' .. tostring(line) .. '\n')
end

function COOP.diag_update(dt)
    local d = COOP.diag
    local now = love.timer.getTime()
    -- window focus changes (a game in the background gets throttled by Windows)
    local focused = love.window and love.window.hasFocus and love.window.hasFocus()
    if focused ~= d.focused then
        d.focused = focused
        if d.focus_known then COOP.log('window ' .. (focused and 'focused' or 'LOST FOCUS (game may be throttled)')) end
        d.focus_known = true
    end
    -- frame spikes (any peer): report where the time went
    if dt > 0.1 and now - d.stall_logged_at > 3 then
        d.stall_logged_at = now
        local q = G.E_MANAGER and G.E_MANAGER.queues and G.E_MANAGER.queues.base
        COOP.log(string.format('stall: frame %.0f ms, co-op part %.1f ms, events queued %d, state %s, focus %s, spectating %s, my turn %s',
            dt * 1000, COOP.perf.last or 0, q and #q or -1, tostring(G.STATE), tostring(focused),
            tostring(COOP.spectate and COOP.spectate.target), tostring(COOP.is_my_turn())))
    end
    -- periodic stats
    if now - d.stats_at > 10 then
        d.stats_at = now
        local conn = COOP.client_obj and COOP.client_obj.conn
        local line = string.format('stats: fps=%d avg_frame=%.1fms worst_coop=%.1fms state=%s', love.timer.getFPS(), love.timer.getAverageDelta() * 1000, COOP.perf.worst, tostring(G.STATE))
        if conn then line = line .. string.format(' net_in=%dB net_out=%dB unsent=%dB', conn.bytes_in, conn.bytes_out, #conn.outbuf) end
        if COOP.mode == 'host' and COOP.host_obj then
            local tot_out, unsent = 0, 0
            for _, c in ipairs(COOP.host_obj.conns) do tot_out = tot_out + c.bytes_out; unsent = unsent + #c.outbuf end
            line = line .. string.format(' host_out=%dB unsent=%dB', tot_out, unsent)
        end
        COOP.perf.worst = 0
        if COOP.active or COOP.mode then COOP.log(line) end
        if COOP.mode == 'host' then players_log(COOP.me.name .. ' (host)', line) end
    end
    -- host pings everyone every 3 s and shares the round-trip times
    if COOP.mode == 'host' and now - d.ping_at > 3 then
        d.ping_at = now
        for _, p in ipairs(COOP.players) do
            if p.conn then p.conn:send({ t = 'ping', ts = now }) end
        end
        COOP.broadcast({ t = 'rtts', rtt = d.rtt })
    end
end

COOP.host_handlers.rlog = function(player, msg)
    players_log(player.name, msg.line)
end

COOP.host_handlers.pong = function(player, msg)
    local rtt = math.floor(((love.timer.getTime() - (tonumber(msg.ts) or 0)) * 1000) + 0.5)
    COOP.diag.rtt[tostring(player.id)] = rtt
    player.rtt = rtt
end

COOP.client_handlers.ping = function(msg)
    COOP.send_to_host({ t = 'pong', ts = msg.ts })
end

COOP.client_handlers.rtts = function(msg)
    COOP.diag.rtt = msg.rtt or {}
end

function COOP.rtt_of(id)
    local v = COOP.diag.rtt[tostring(id)] or COOP.diag.rtt[id]
    return v
end

function COOP.update(dt)
    local t0 = love.timer.getTime()
    if COOP.mode == 'host' and COOP.host_obj then
        COOP.host_obj:update(host_on_message, host_on_disconnect)
    elseif COOP.mode == 'client' and COOP.client_obj then
        COOP.client_obj:update(client_on_message, client_on_disconnect)
    end
    COOP.update_inner(dt)
    pcall(COOP.diag_update, dt)
    -- performance watchdog: log when the mod itself eats a frame (at most every 5 s)
    local spent = (love.timer.getTime() - t0) * 1000
    COOP.perf.last = spent
    if spent > COOP.perf.worst then COOP.perf.worst = spent end
    if spent > 25 and t0 - COOP.perf.slow_logged_at > 5 then
        COOP.perf.slow_logged_at = t0
        COOP.log(string.format('perf: co-op update took %.0f ms this frame (game fps %d, state %s)', spent, love.timer.getFPS(), tostring(G.STATE)))
    end
end

function COOP.update_inner(dt)
    if COOP.active then
        local ok, err = pcall(COOP.update_run, dt)
        if not ok then
            COOP.log('update_run error: ' .. tostring(err))
            COOP.last_error = tostring(err)
        end
    end
    if COOP.ui and COOP.ui.update then
        local ok, err = pcall(COOP.ui.update, dt)
        if not ok then COOP.log('ui.update error: ' .. tostring(err)) end
    end
end

-- Host handlers --------------------------------------------------------------
COOP.host_handlers.hello = function(conn, msg)
    -- conn here is a raw connection without a player yet
    if COOP.lobby.started then
        conn:send({ t = 'reject', reason = 'Game already in progress' })
        conn:flush()
        conn.alive = false
        return
    end
    if #COOP.players >= COOP.MAX_PLAYERS then
        conn:send({ t = 'reject', reason = 'Lobby is full' })
        conn:flush()
        conn.alive = false
        return
    end
    if msg.proto ~= COOP.PROTOCOL or msg.ver ~= COOP.VERSION then
        conn:send({ t = 'reject', reason = 'Version mismatch: host has v' .. COOP.VERSION .. ', you have v' .. tostring(msg.ver) .. '. Relaunch to update.' })
        conn:flush()
        conn.alive = false
        return
    end
    local name = tostring(msg.name or 'Player'):sub(1, 16)
    if name == '' then name = 'Player' end
    local base_name, n = name, 2
    while COOP.get_player_by_name(name) do
        name = base_name .. n
        n = n + 1
    end
    local player = { id = conn.id, name = name, conn = conn }
    COOP.players[#COOP.players + 1] = player
    COOP.log('player joined: ' .. name .. ' (#' .. conn.id .. ')')
    players_log(name, '--- joined the lobby (v' .. tostring(msg.ver) .. ') ---')
    conn:send({ t = 'welcome', id = conn.id, name = name })
    COOP.broadcast_lobby()
    COOP.toast(name .. ' joined', G.C.GREEN)
end

function COOP.get_player_by_name(name)
    for _, p in ipairs(COOP.players) do
        if p.name == name then return p end
    end
end

function COOP.broadcast_lobby()
    COOP.broadcast({
        t = 'lobby',
        players = COOP.player_summaries(),
        deck = COOP.lobby.deck,
        stake = COOP.lobby.stake,
        turn_order = COOP.lobby.turn_order,
    })
end

COOP.host_handlers.leave = function(player, msg)
    if player.conn then player.conn.alive = false end
end

COOP.host_handlers.vote = function(player, msg)
    if not COOP.run then return end
    local choice = msg.choice == 'skip' and 'skip' or 'select'
    COOP.run.votes[player.id] = choice
    COOP.log('vote from ' .. player.name .. ': ' .. choice)
    COOP.broadcast({ t = 'vote_state', votes = COOP.run.votes })
    COOP.host_check_votes()
end

function COOP.host_check_votes()
    local run = COOP.run
    if not run then return end
    local select_n, skip_n, total = 0, 0, 0
    for _, p in ipairs(COOP.players) do
        total = total + 1
        local v = run.votes[p.id]
        if v == 'select' then select_n = select_n + 1 elseif v == 'skip' then skip_n = skip_n + 1 end
    end
    if total == 0 or select_n + skip_n < total then return end
    local choice, coin = nil, false
    if skip_n > select_n then choice = 'skip'
    elseif select_n > skip_n then choice = 'select'
    else
        coin = true
        choice = (math.random() < 0.5) and 'select' or 'skip'
    end
    run.votes = {}
    COOP.log('vote result: ' .. choice .. (coin and ' (coin flip)' or ''))
    COOP.broadcast({ t = 'blind_decision', choice = choice, coin = coin, select_n = select_n, skip_n = skip_n })
end

COOP.host_handlers.ready = function(player, msg)
    if not COOP.run then return end
    COOP.run.ready[player.id] = true
    COOP.broadcast({ t = 'ready_state', ready = COOP.run.ready })
    COOP.host_check_ready()
end

function COOP.host_check_ready()
    local run = COOP.run
    if not run then return end
    if #COOP.players == 0 then return end
    for _, p in ipairs(COOP.players) do
        if not run.ready[p.id] then return end
    end
    run.ready = {}
    COOP.broadcast({ t = 'next_round' })
end

COOP.host_handlers.phase = function(player, msg)
    if not COOP.run then return end
    if msg.p == 'blind_ready' then
        COOP.run.phase[player.id] = 'blind_ready'
        COOP.host_check_blind_ready()
    end
end

function COOP.host_check_blind_ready()
    local run = COOP.run
    if not run or run.round_active then return end
    if #COOP.players == 0 then return end
    for _, p in ipairs(COOP.players) do
        if run.phase[p.id] ~= 'blind_ready' then return end
    end
    -- everyone drew their hand for the new blind: start turns
    run.phase = {}
    run.round_active = true
    local rt = run.restore_turn
    run.restore_turn = nil
    if rt and rt.order and rt.active then
        -- continuing a blind that was saved mid-way: same order, same seat, same team score
        local order, complete = {}, true
        for _, name in ipairs(rt.order) do
            local p = COOP.get_player_by_name(name)
            if p then order[#order + 1] = p.id else complete = false end
        end
        local active = COOP.get_player_by_name(rt.active)
        if complete and active then
            run.round_no = rt.round_no or run.round_no
            run.turn.order = order
            run.turn.idx = rt.idx or 1
            run.chips = tonumber(rt.chips) or 0
            COOP.log('restored turn: active=' .. rt.active .. ' idx=' .. tostring(run.turn.idx) .. ' chips=' .. tostring(run.chips))
            COOP.broadcast({ t = 'turn', active = active.id, order = order, idx = run.turn.idx, chips = run.chips })
            return
        end
    end
    run.round_no = run.round_no + 1
    local ids = {}
    for _, p in ipairs(COOP.players) do ids[#ids + 1] = p.id end
    local order = {}
    local n = #ids
    local start = 1
    if COOP.lobby.turn_order == 'rotate' then start = ((run.round_no - 1) % n) + 1 end
    for i = 0, n - 1 do
        order[#order + 1] = ids[((start - 1 + i) % n) + 1]
    end
    run.turn.order = order
    run.turn.idx = 1
    run.chips = 0
    COOP.log('turn order: ' .. table.concat(order, ','))
    COOP.broadcast({ t = 'turn', active = order[1], order = order, idx = 1, chips = 0 })
end

COOP.host_handlers.turn_done = function(player, msg)
    local run = COOP.run
    if not run or not run.round_active then return end
    if run.turn.active ~= player.id then return end
    run.chips = tonumber(msg.chips) or run.chips
    local order = run.turn.order
    local next_idx = run.turn.idx + 1
    while next_idx <= #order and not COOP.get_player(order[next_idx]) do
        next_idx = next_idx + 1
    end
    if next_idx <= #order then
        run.turn.idx = next_idx
        run.turn.active = order[next_idx]
        COOP.broadcast({ t = 'turn', active = order[next_idx], order = order, idx = next_idx, chips = run.chips })
    else
        COOP.host_end_round(false)
    end
end

COOP.host_handlers.round_won = function(player, msg)
    local run = COOP.run
    if not run or not run.round_active then return end
    run.chips = tonumber(msg.chips) or run.chips
    COOP.host_end_round(true)
end

function COOP.host_end_round(won)
    local run = COOP.run
    run.round_active = false
    run.turn.active = nil
    run.turn.order = {}
    run.turn.idx = 0
    run.phase = {}
    COOP.broadcast({ t = 'round_result', won = won, chips = run.chips })
end

COOP.host_handlers.dollars = function(player, msg)
    if not COOP.active then return end
    local delta = tonumber(msg.delta) or 0
    if delta == 0 then return end
    COOP.suppress_dollar_sync = true
    local ok, err = pcall(ease_dollars, delta, true)
    COOP.suppress_dollar_sync = false
    if not ok then COOP.log('host ease_dollars failed: ' .. tostring(err)) end
    COOP.broadcast_wallet()
end

function COOP.broadcast_wallet()
    if COOP.mode ~= 'host' or not COOP.active then return end
    COOP.broadcast({ t = 'wallet', v = G.GAME.dollars }, COOP.me.id)
end

COOP.host_handlers.snap = function(player, msg)
    if not COOP.run or COOP.run.turn.active ~= player.id then return end
    msg.from = player.id
    COOP.broadcast(msg, player.id)
end

COOP.host_handlers.snd = function(player, msg)
    if not COOP.run or COOP.run.turn.active ~= player.id then return end
    msg.from = player.id
    COOP.broadcast(msg, player.id)
end

COOP.host_handlers.cur = function(player, msg)
    if not COOP.run or COOP.run.turn.active ~= player.id then return end
    msg.from = player.id
    COOP.broadcast(msg, player.id)
end

COOP.host_handlers.buy = function(player, msg)
    if COOP.shop and COOP.shop.host_on_buy then COOP.shop.host_on_buy(player, msg) end
end

COOP.host_handlers.reroll = function(player, msg)
    if COOP.shop and COOP.shop.host_on_reroll then COOP.shop.host_on_reroll(player, msg) end
end

COOP.host_handlers.save_req = function(player, msg)
    if player.id ~= COOP.me.id or not COOP.active then return end
    COOP.broadcast({ t = 'do_save', turn = COOP.saves.turn_meta() })
end

COOP.host_handlers.chat = function(player, msg)
    COOP.broadcast({ t = 'toast', text = player.name .. ': ' .. tostring(msg.text):sub(1, 60) })
end

function COOP.on_player_left(p)
    COOP.toast(p.name .. ' left', G.C.RED, 3)
    COOP.broadcast({ t = 'player_left', id = p.id, name = p.name, players = COOP.player_summaries() })
    if not COOP.active then
        COOP.broadcast_lobby()
        return
    end
    local run = COOP.run
    if not run then return end
    run.votes[p.id] = nil
    run.ready[p.id] = nil
    run.phase[p.id] = nil
    if run.round_active and run.turn.active == p.id then
        COOP.host_handlers.turn_done(p, { chips = run.chips })
    end
    COOP.host_check_votes()
    COOP.host_check_ready()
    COOP.host_check_blind_ready()
end

-- Host: start the run --------------------------------------------------------
function COOP.host_start_game()
    if COOP.mode ~= 'host' then return end
    if COOP.lobby.started then return end
    local meta = COOP.load_meta
    if meta then
        local ok, missing, extra = COOP.saves.lobby_matches(meta)
        if not ok then
            local parts = {}
            if #missing > 0 then parts[#parts + 1] = 'missing: ' .. table.concat(missing, ', ') end
            if #extra > 0 then parts[#parts + 1] = 'not in this save: ' .. table.concat(extra, ', ') end
            COOP.status = 'Cannot load: ' .. table.concat(parts, ' | ')
            COOP.toast(COOP.status, G.C.RED, 4)
            return
        end
        COOP.lobby.started = true
        local msg = {
            t = 'start', load = true, sid = meta.sid,
            seed = meta.seed, deck = meta.deck, stake = meta.stake, turn_order = meta.turn_order or COOP.lobby.turn_order,
            players = COOP.player_summaries(),
        }
        COOP.log('loading co-op run ' .. tostring(meta.sid) .. ' players=' .. #msg.players)
        COOP.broadcast(msg)
        return
    end
    COOP.lobby.started = true
    local seed = random_string(8, math.random() * 1000 + (love.timer and love.timer.getTime() or 0))
    -- every player gets their own seed so decks shuffle differently (bosses, tags and the shop
    -- are still shared because the host sends those)
    local seeds = {}
    for i, p in ipairs(COOP.players) do
        seeds[tostring(p.id)] = (i == 1) and seed or random_string(8, math.random() * 1000 + i * 17.31 + (love.timer and love.timer.getTime() or 0))
    end
    local msg = {
        t = 'start',
        seed = seed,
        seeds = seeds,
        sid = seed .. '-' .. os.date('%Y%m%d-%H%M%S'),
        deck = COOP.lobby.deck,
        stake = COOP.lobby.stake,
        turn_order = COOP.lobby.turn_order,
        players = COOP.player_summaries(),
    }
    COOP.log('starting co-op run seed=' .. seed .. ' deck=' .. msg.deck .. ' players=' .. #msg.players)
    COOP.broadcast(msg)
end

-- Client handlers ------------------------------------------------------------
COOP.client_handlers.welcome = function(msg)
    COOP.me.id = msg.id
    COOP.me.name = msg.name or COOP.me.name
    COOP.status = 'Joined lobby as ' .. COOP.me.name
end

COOP.client_handlers.reject = function(msg)
    COOP.status = 'Rejected: ' .. tostring(msg.reason)
    COOP.log(COOP.status)
    COOP.toast(COOP.status, G.C.RED, 4)
end

COOP.client_handlers.kick = function(msg)
    COOP.status = tostring(msg.reason or 'Removed from lobby')
    COOP.toast(COOP.status, G.C.RED, 4)
end

local function set_players_from(list)
    COOP.players = {}
    for _, p in ipairs(list or {}) do
        COOP.players[#COOP.players + 1] = { id = p.id, name = p.name }
    end
end

COOP.client_handlers.lobby = function(msg)
    if COOP.mode == 'client' then
        set_players_from(msg.players)
        COOP.lobby.deck = msg.deck or COOP.lobby.deck
        COOP.lobby.stake = msg.stake or COOP.lobby.stake
        COOP.lobby.turn_order = msg.turn_order or COOP.lobby.turn_order
    end
end

COOP.client_handlers.player_left = function(msg)
    if COOP.mode == 'client' then
        set_players_from(msg.players)
        COOP.toast(tostring(msg.name) .. ' left', G.C.RED, 3)
    end
end

COOP.client_handlers.do_save = function(msg)
    if not COOP.active or not COOP.saves then return end
    COOP.saves.save_now('manual', msg.turn)
    COOP.toast('Co-op run saved' .. (msg.turn and ' (mid-blind)' or ''), G.C.GREEN, 2.5)
    pcall(play_sound, 'coin1')
end

COOP.client_handlers.toast = function(msg)
    COOP.toast(tostring(msg.text), G.C.WHITE, 3)
end

COOP.client_handlers.start = function(msg)
    COOP.lobby.started = true
    if COOP.mode == 'client' then set_players_from(msg.players) end
    COOP.run = {
        seed = msg.seed, deck = msg.deck, stake = msg.stake, turn_order = msg.turn_order,
        n = #COOP.players,
        round_no = 0, round_active = false,
        turn = { active = nil, order = {}, idx = 0 },
        chips = 0, votes = {}, ready = {}, phase = {},
        blind_ready_sent = false, won_sent = false, my_vote = nil, my_ready = false,
        remote_blinds = nil, pending_next_round = false, pending_decision = nil,
        sid = msg.sid, loaded = msg.load and true or false,
    }
    COOP.lobby.turn_order = msg.turn_order or COOP.lobby.turn_order
    COOP.active = true
    if COOP.saves then COOP.saves.last_save_state = nil end
    if msg.load and COOP.is_host() and COOP.load_meta and COOP.load_meta.turn then
        COOP.run.restore_turn = COOP.load_meta.turn
    end
    if msg.load then
        COOP.start_local_run_loaded(msg)
    else
        COOP.start_local_run(msg)
    end
end

function COOP.start_local_run_loaded(msg)
    local t, err = COOP.saves.load_table(msg.sid, COOP.me.name)
    if not t then
        COOP.log('load failed: ' .. tostring(err))
        COOP.toast('Could not load your save: ' .. tostring(err), G.C.RED, 5)
        COOP.leave()
        return
    end
    COOP.starting = true
    local ok, e = pcall(function()
        if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu() end
        G.FUNCS.start_run(nil, { savetext = t })
    end)
    COOP.starting = false
    if not ok then
        COOP.log('start_local_run_loaded failed: ' .. tostring(e))
        COOP.toast('Failed to load run: ' .. tostring(e), G.C.RED, 5)
    end
end

function COOP.start_local_run(msg)
    COOP.starting = true
    local ok, err = pcall(function()
        if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu() end
        local back = get_deck_from_name(msg.deck) or G.P_CENTERS.b_red
        G.GAME.viewed_back = Back(back)
        local my_seed = (msg.seeds and (msg.seeds[COOP.me.id] or msg.seeds[tostring(COOP.me.id)])) or msg.seed
        G.FUNCS.start_run(nil, { stake = msg.stake or 1, seed = my_seed })
    end)
    COOP.starting = false
    if not ok then
        COOP.log('start_local_run failed: ' .. tostring(err))
        COOP.toast('Failed to start run: ' .. tostring(err), G.C.RED, 5)
    end
end

-- Called from the Game:start_run hook after the base game initialised the run.
function COOP.apply_run_mods(loaded)
    if not COOP.active or not COOP.run then return end
    local n = math.max(1, COOP.run.n)
    COOP.saved_no_saving = G.F_NO_SAVING
    G.F_NO_SAVING = true
    G.SETTINGS.tutorial_complete = true
    if not loaded then
        G.GAME.starting_params.ante_scaling = (G.GAME.starting_params.ante_scaling or 1) * n
        G.GAME.dollars = (G.GAME.dollars or 0) * n
        G.GAME.shop = G.GAME.shop or { joker_max = 2 }
        G.GAME.shop.joker_max = (G.GAME.shop.joker_max or 2) * n
    end
    G.GAME.coop_players = n
    if not COOP.is_host() then
        G.GAME.modifiers.no_interest = true
    end
    COOP.run.blind_ready_sent = false
    COOP.run.won_sent = false
    COOP.log('applied run mods: n=' .. n .. ' dollars=' .. G.GAME.dollars .. ' ante_scaling=' .. G.GAME.starting_params.ante_scaling)
    if COOP.is_host() then
        COOP.broadcast_blinds()
    elseif COOP.run.remote_blinds then
        COOP.apply_remote_blinds()
    end
end

function COOP.end_local_run_mods()
    if COOP.saved_no_saving ~= nil then
        G.F_NO_SAVING = COOP.saved_no_saving
        COOP.saved_no_saving = nil
    end
end

function COOP.broadcast_blinds()
    if COOP.mode ~= 'host' or not G.GAME or not G.GAME.round_resets then return end
    local rr = G.GAME.round_resets
    COOP.broadcast({
        t = 'blinds',
        boss = rr.blind_choices and rr.blind_choices.Boss,
        small = rr.blind_tags and rr.blind_tags.Small,
        big = rr.blind_tags and rr.blind_tags.Big,
        ante = rr.ante,
    }, COOP.me.id)
end

COOP.client_handlers.blinds = function(msg)
    if not COOP.run then return end
    COOP.run.remote_blinds = msg
    if G.GAME and G.GAME.round_resets then COOP.apply_remote_blinds() end
end

function COOP.apply_remote_blinds()
    local rb = COOP.run and COOP.run.remote_blinds
    if not rb or not G.GAME or not G.GAME.round_resets then return end
    local rr = G.GAME.round_resets
    local changed = false
    if rb.boss and G.P_BLINDS[rb.boss] and rr.blind_choices.Boss ~= rb.boss then
        rr.blind_choices.Boss = rb.boss
        changed = true
    end
    rr.blind_tags = rr.blind_tags or {}
    if rb.small and G.P_TAGS[rb.small] and rr.blind_tags.Small ~= rb.small then
        rr.blind_tags.Small = rb.small
        changed = true
    end
    if rb.big and G.P_TAGS[rb.big] and rr.blind_tags.Big ~= rb.big then
        rr.blind_tags.Big = rb.big
        changed = true
    end
    if changed and G.STATE == G.STATES.BLIND_SELECT and G.blind_select then
        -- rebuild the blind selection UI so it shows the host's boss/tags
        pcall(function()
            G.blind_select:remove()
            G.blind_select = nil
            if G.blind_prompt_box then G.blind_prompt_box:remove(); G.blind_prompt_box = nil end
            G.STATE_COMPLETE = false
        end)
    end
    if changed then COOP.log('applied host blinds: boss=' .. tostring(rb.boss)) end
end

COOP.client_handlers.vote_state = function(msg)
    if COOP.run then COOP.run.votes = msg.votes or {} end
end

COOP.client_handlers.blind_decision = function(msg)
    local run = COOP.run
    if not run then return end
    run.votes = {}
    run.my_vote = nil
    local label = (msg.choice == 'skip') and 'SKIP BLIND' or 'PLAY BLIND'
    if msg.coin then
        COOP.toast('Tie! Coin flip: ' .. label, G.C.GOLD, 3)
        pcall(play_sound, 'coin1')
    else
        COOP.toast('Vote: ' .. label .. ' (' .. tostring(msg.select_n) .. ' play / ' .. tostring(msg.skip_n) .. ' skip)', G.C.BLUE, 2.5)
    end
    run.pending_decision = msg.choice
    COOP.try_execute_decision()
end

function COOP.try_execute_decision()
    local run = COOP.run
    if not run or not run.pending_decision then return end
    if G.STATE ~= G.STATES.BLIND_SELECT or not G.blind_select then return end
    if G.CONTROLLER and G.CONTROLLER.locks and G.CONTROLLER.locks.skip_blind then return end
    local choice = run.pending_decision
    run.pending_decision = nil
    COOP.executing = true
    local ok, err = pcall(function()
        local on_deck = G.GAME.blind_on_deck or 'Small'
        if choice == 'skip' and on_deck ~= 'Boss' then
            local box = G.blind_select_opts and G.blind_select_opts[string.lower(on_deck)]
            if box then G.FUNCS.skip_blind({ UIBox = box }) end
        else
            local key = G.GAME.round_resets.blind_choices[on_deck]
            G.FUNCS.select_blind({ config = { ref_table = G.P_BLINDS[key] } })
        end
    end)
    COOP.executing = false
    if not ok then COOP.log('execute decision failed: ' .. tostring(err)) end
end

COOP.client_handlers.ready_state = function(msg)
    if COOP.run then COOP.run.ready = msg.ready or {} end
end

COOP.client_handlers.next_round = function(msg)
    local run = COOP.run
    if not run then return end
    run.ready = {}
    run.my_ready = false
    run.pending_next_round = true
    COOP.try_next_round()
end

function COOP.try_next_round()
    local run = COOP.run
    if not run or not run.pending_next_round then return end
    if G.STATE ~= G.STATES.SHOP or not G.shop then return end
    if G.CONTROLLER and G.CONTROLLER.locks and G.CONTROLLER.locks.toggle_shop then return end
    run.pending_next_round = false
    COOP.executing = true
    local ok, err = pcall(G.FUNCS.toggle_shop, nil)
    COOP.executing = false
    if not ok then COOP.log('next_round failed: ' .. tostring(err)) end
end

COOP.pending_local_dollars = 0   -- deltas whose local animation has not run yet (client)
COOP.wallet_target = nil

local function apply_wallet(v)
    G.GAME.dollars = v
    pcall(function()
        local dollar_UI = G.HUD and G.HUD:get_UIE_by_ID('dollar_text_UI')
        if dollar_UI and dollar_UI.config.object then
            dollar_UI.config.object:update()
            G.HUD:recalculate()
        end
    end)
end

COOP.client_handlers.wallet = function(msg)
    if not COOP.active or COOP.mode == 'host' then return end
    local v = tonumber(msg.v)
    if not v then return end
    if COOP.pending_local_dollars ~= 0 then
        -- our own +$ animation is still queued; apply the host value once it has run
        COOP.wallet_target = v
        return
    end
    apply_wallet(v)
end

COOP.client_handlers.turn = function(msg)
    local run = COOP.run
    if not run then return end
    run.turn.active = msg.active
    run.turn.order = msg.order or {}
    run.turn.idx = msg.idx or 1
    run.round_active = true
    run.chips = tonumber(msg.chips) or 0
    G.GAME.chips = run.chips
    if COOP.spectate then COOP.spectate.on_turn_changed() end
    if msg.active == COOP.me.id then
        COOP.toast('YOUR TURN!', G.C.GREEN, 2)
        pcall(play_sound, 'multhit1')
    else
        COOP.toast(COOP.player_name(msg.active) .. "'s turn", G.C.BLUE, 2)
    end
end

COOP.client_handlers.snap = function(msg)
    if COOP.spectate then COOP.spectate.on_snapshot(msg) end
end

COOP.client_handlers.snd = function(msg)
    if COOP.spectate and COOP.spectate.target and msg.from == COOP.spectate.target and type(msg.c) == 'string' then
        pcall(play_sound, msg.c, msg.p, msg.v)
    end
end

COOP.client_handlers.cur = function(msg)
    if COOP.spectate then COOP.spectate.on_cursor(msg) end
end

COOP.client_handlers.round_result = function(msg)
    local run = COOP.run
    if not run then return end
    run.round_active = false
    run.turn.active = nil
    run.turn.order = {}
    run.chips = tonumber(msg.chips) or run.chips
    if COOP.spectate then COOP.spectate.stop() end
    G.GAME.chips = run.chips
    run.blind_ready_sent = false
    if msg.won then
        COOP.toast('Blind defeated! Team score: ' .. number_format(run.chips), G.C.GREEN, 3)
    else
        COOP.toast('The team ran out of hands...', G.C.RED, 3)
    end
    local st = G.STATE
    if st ~= G.STATES.NEW_ROUND and st ~= G.STATES.ROUND_EVAL and st ~= G.STATES.GAME_OVER and st ~= G.STATES.SHOP then
        G.STATE = G.STATES.NEW_ROUND
        G.STATE_COMPLETE = false
    end
end

COOP.client_handlers.shop = function(msg)
    if COOP.shop and COOP.shop.on_shop then COOP.shop.on_shop(msg) end
end
COOP.client_handlers.buy_ok = function(msg)
    if COOP.shop and COOP.shop.on_buy_ok then COOP.shop.on_buy_ok(msg) end
end
COOP.client_handlers.buy_fail = function(msg)
    if COOP.shop and COOP.shop.on_buy_fail then COOP.shop.on_buy_fail(msg) end
end

-- Local run monitoring (all peers) -------------------------------------------
function COOP.update_run(dt)
    local run = COOP.run
    if not run or G.STAGE ~= G.STAGES.RUN or not G.GAME then return end
    local st = G.STATE

    -- after a load the host's wallet is the truth: push it once
    if COOP.is_host() and not run.wallet_synced and G.HUD then
        run.wallet_synced = true
        COOP.broadcast_wallet()
        COOP.broadcast_blinds()
    end

    -- reset per-blind flags whenever we are outside of a blind
    if st == G.STATES.ROUND_EVAL or st == G.STATES.SHOP or st == G.STATES.BLIND_SELECT or st == G.STATES.GAME_OVER then
        if run.blind_ready_sent then
            run.blind_ready_sent = false
            run.won_sent = false
        end
        if run.turn.active then
            run.turn.active = nil
            if COOP.spectate then COOP.spectate.stop() end
        end
    end

    -- new blind: hand drawn, tell the host we are ready for turns
    if st == G.STATES.SELECTING_HAND and not run.blind_ready_sent and G.GAME.blind and G.GAME.blind.chips and G.GAME.blind.chips > 0
        and G.hand and #G.hand.cards > 0 and not run.round_active then
        run.blind_ready_sent = true
        run.won_sent = false
        COOP.send_to_host({ t = 'phase', p = 'blind_ready', round = G.GAME.round })
    end

    -- active player won the blind (any path that moves us to NEW_ROUND/ROUND_EVAL with enough chips)
    if COOP.is_my_turn() and not run.won_sent and (st == G.STATES.NEW_ROUND or st == G.STATES.ROUND_EVAL)
        and G.GAME.blind and G.GAME.chips - G.GAME.blind.chips >= 0 then
        run.won_sent = true
        COOP.send_to_host({ t = 'round_won', chips = G.GAME.chips })
    end

    COOP.try_execute_decision()
    COOP.try_next_round()

    if COOP.spectate then COOP.spectate.update(dt) end
    if COOP.shop then COOP.shop.update(dt) end
    if COOP.saves then COOP.saves.update(dt) end
end

-- Player actions -------------------------------------------------------------
function COOP.vote(choice)
    if not COOP.run then return end
    if G.STATE ~= G.STATES.BLIND_SELECT then return end
    COOP.run.my_vote = choice
    COOP.send_to_host({ t = 'vote', choice = choice })
end

function COOP.ready_for_next_round()
    if not COOP.run then return end
    if not G.shop then return end
    COOP.run.my_ready = true
    COOP.send_to_host({ t = 'ready' })
end

function COOP.turn_over()
    if not COOP.run then return end
    COOP.log('my turn is over, chips=' .. tostring(G.GAME.chips))
    -- the host's reply (next 'turn' or 'round_result') moves us out of the active seat
    COOP.send_to_host({ t = 'turn_done', chips = G.GAME.chips })
end

function COOP.on_local_dollars(mod)
    -- called from the ease_dollars hook on every peer
    if not COOP.active or COOP.suppress_dollar_sync then return end
    if COOP.mode == 'host' then
        -- broadcast after the base game's own event applied the change
        G.E_MANAGER:add_event(Event({
            trigger = 'immediate', blocking = false, blockable = true,
            func = function() COOP.broadcast_wallet(); return true end
        }))
    elseif COOP.mode == 'client' then
        if mod and mod ~= 0 then
            COOP.pending_local_dollars = COOP.pending_local_dollars + mod
            COOP.send_to_host({ t = 'dollars', delta = mod })
            -- runs right after the base game's own event applied the local change
            G.E_MANAGER:add_event(Event({
                trigger = 'immediate', blocking = false, blockable = true,
                func = function()
                    COOP.pending_local_dollars = COOP.pending_local_dollars - mod
                    if COOP.pending_local_dollars == 0 and COOP.wallet_target then
                        apply_wallet(COOP.wallet_target)
                        COOP.wallet_target = nil
                    end
                    return true
                end
            }))
        end
    end
end

COOP.load_config()

do
    local orig_handler = love.errorhandler or love.errhand
    local function coop_errorhandler(msg)
        pcall(function()
            local text = 'CRASH: ' .. tostring(msg)
            COOP.log(text)
            COOP.log('CRASH traceback: ' .. tostring(debug.traceback()):sub(1, 1500):gsub('\n', ' | '))
            -- push the last lines to the host right now, before the game dies
            if COOP.mode == 'client' and COOP.client_obj then
                COOP.client_obj:send({ t = 'rlog', line = text })
                if COOP.client_obj.conn and COOP.client_obj.conn.flush then COOP.client_obj.conn:flush() end
                if COOP.client_obj.conn and COOP.client_obj.conn.sock and COOP.client_obj.conn.sock.flush then COOP.client_obj.conn.sock:flush() end
            end
        end)
        if orig_handler then return orig_handler(msg) end
    end
    love.errorhandler = coop_errorhandler
    love.errhand = coop_errorhandler
end
