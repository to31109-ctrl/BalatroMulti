-- BalatroCoop: automatic router port opening (UPnP IGD) and join codes.
-- Lets a host accept connections from the internet without manual port forwarding
-- on routers that have UPnP enabled (the default on most home routers).
local upnp = {}
COOP.upnp = upnp

local socket = COOP.net.socket

upnp.state = { mapped = false, external_ip = nil, control_url = nil, service_type = nil, port = nil, error = nil }

local SSDP_ADDR, SSDP_PORT = '239.255.255.250', 1900
local SERVICE_TYPES = {
    'urn:schemas-upnp-org:service:WANIPConnection:2',
    'urn:schemas-upnp-org:service:WANIPConnection:1',
    'urn:schemas-upnp-org:service:WANPPPConnection:1',
}

-- Minimal HTTP/1.1 client over raw TCP (the bundled socket.http fails against some routers)
local function parse_url(url)
    local host, port, path = url:match('^http://([^/:]+):?(%d*)(/.*)$')
    if not host then
        host, port = url:match('^http://([^/:]+):?(%d*)$')
        path = '/'
    end
    if not host then return nil end
    return host, tonumber(port) or 80, path
end

local function http_raw(method, url, headers, body, timeout)
    if not socket then return nil, 'no socket' end
    local host, port, path = parse_url(url)
    if not host then return nil, 'bad url' end
    local t = socket.tcp()
    t:settimeout(timeout or 3)
    local ok, err = t:connect(host, port)
    if not ok then t:close(); return nil, 'connect: ' .. tostring(err) end
    local req = { method .. ' ' .. path .. ' HTTP/1.1', 'Host: ' .. host .. ':' .. port, 'Connection: close', 'User-Agent: BalatroCoop' }
    for k, v in pairs(headers or {}) do req[#req + 1] = k .. ': ' .. v end
    if body then req[#req + 1] = 'Content-Length: ' .. #body end
    local raw = table.concat(req, '\r\n') .. '\r\n\r\n' .. (body or '')
    ok, err = t:send(raw)
    if not ok then t:close(); return nil, 'send: ' .. tostring(err) end
    local parts = {}
    while true do
        local d, e, partial = t:receive(8192)
        if d then parts[#parts + 1] = d elseif partial and #partial > 0 then parts[#parts + 1] = partial end
        if e then break end
    end
    t:close()
    local resp = table.concat(parts)
    local code = tonumber(resp:match('^HTTP/%d%.%d (%d+)'))
    local hdr_end = resp:find('\r\n\r\n', 1, true)
    local rbody = hdr_end and resp:sub(hdr_end + 4) or ''
    if not code then return nil, 'bad response' end
    return rbody, code
end

local function http_get(url, timeout)
    local body, code = http_raw('GET', url, nil, nil, timeout)
    if not body then return nil, code end
    if code ~= 200 then return nil, 'HTTP ' .. tostring(code) end
    return body, code
end

local function soap(control_url, service_type, action, args_xml, timeout)
    local body = '<?xml version="1.0"?>'
        .. '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        .. '<s:Body><u:' .. action .. ' xmlns:u="' .. service_type .. '">' .. (args_xml or '') .. '</u:' .. action .. '></s:Body></s:Envelope>'
    local text, code = http_raw('POST', control_url, {
        ['Content-Type'] = 'text/xml; charset="utf-8"',
        ['SOAPAction'] = '"' .. service_type .. '#' .. action .. '"',
    }, body, timeout or 4)
    if not text then return nil, tostring(code) end
    if code ~= 200 then
        local err = text:match('<errorDescription>([^<]*)</errorDescription>') or text:match('<errorCode>([^<]*)</errorCode>')
        return nil, 'HTTP ' .. tostring(code) .. (err and (' ' .. err) or '')
    end
    return text
end

-- SSDP discovery: returns a list of description URLs
local function discover(timeout, local_ip)
    if not socket then return {} end
    local udp = socket.udp()
    if not udp then return {} end
    udp:settimeout(0.3)
    -- bind to the LAN adapter so the multicast leaves on the right interface
    local bound = local_ip and local_ip ~= '?' and pcall(udp.setsockname, udp, local_ip, 0)
    if not bound then pcall(udp.setsockname, udp, '*', 0) end
    local msg = 'M-SEARCH * HTTP/1.1\r\nHOST: ' .. SSDP_ADDR .. ':' .. SSDP_PORT .. '\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: %s\r\n\r\n'
    for _, st in ipairs({ 'urn:schemas-upnp-org:device:InternetGatewayDevice:1', 'urn:schemas-upnp-org:device:InternetGatewayDevice:2', 'urn:schemas-upnp-org:service:WANIPConnection:1', 'ssdp:all' }) do
        pcall(udp.sendto, udp, string.format(msg, st), SSDP_ADDR, SSDP_PORT)
    end
    local urls, seen = {}, {}
    local deadline = socket.gettime() + (timeout or 2)
    while socket.gettime() < deadline do
        local data = udp:receivefrom()
        if data and (data:find('InternetGatewayDevice') or data:find('WANIPConnection') or data:find('WANPPPConnection')) then
            local loc = data:match('[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:%s*([^\r\n]+)')
            if loc and not seen[loc] then
                seen[loc] = true
                urls[#urls + 1] = loc
            end
        end
    end
    udp:close()
    return urls
end

local function find_service(desc_url)
    local xml = http_get(desc_url, 3)
    if not xml then return nil end
    local base = xml:match('<URLBase>%s*([^<%s]+)%s*</URLBase>') or desc_url:match('^(https?://[^/]+)')
    for _, st in ipairs(SERVICE_TYPES) do
        -- find the <service> block with this serviceType and pull its controlURL
        for block in xml:gmatch('<service>(.-)</service>') do
            if block:find(st, 1, true) then
                local ctrl = block:match('<controlURL>%s*([^<%s]+)%s*</controlURL>')
                if ctrl then
                    if not ctrl:match('^https?://') then
                        if ctrl:sub(1, 1) ~= '/' then ctrl = '/' .. ctrl end
                        ctrl = base:gsub('/+$', '') .. ctrl
                    end
                    return ctrl, st
                end
            end
        end
    end
    return nil
end

function upnp.public_ip_from_web()
    for _, url in ipairs({ 'http://api.ipify.org', 'http://checkip.amazonaws.com', 'http://ipv4.icanhazip.com' }) do
        local body = http_get(url, 3)
        if body then
            local ip = body:match('(%d+%.%d+%.%d+%.%d+)')
            if ip then return ip end
        end
    end
    return nil
end

-- Try to open `port` (TCP) on the router. Returns ok, external_ip, error
function upnp.open_port(port, local_ip)
    local st = upnp.state
    st.error = nil
    st.port = port
    if not st.control_url then
        local urls = discover(3, local_ip)
        COOP.log('upnp: ' .. #urls .. ' device(s) answered discovery')
        for _, u in ipairs(urls) do
            local ctrl, stype = find_service(u)
            if ctrl then
                st.control_url, st.service_type = ctrl, stype
                COOP.log('upnp: gateway service ' .. stype .. ' at ' .. ctrl)
                break
            end
        end
    end
    if not st.control_url then
        st.error = 'No UPnP router found'
        return false, nil, st.error
    end
    local args = '<NewRemoteHost></NewRemoteHost>'
        .. '<NewExternalPort>' .. port .. '</NewExternalPort>'
        .. '<NewProtocol>TCP</NewProtocol>'
        .. '<NewInternalPort>' .. port .. '</NewInternalPort>'
        .. '<NewInternalClient>' .. local_ip .. '</NewInternalClient>'
        .. '<NewEnabled>1</NewEnabled>'
        .. '<NewPortMappingDescription>Balatro Co-op</NewPortMappingDescription>'
        .. '<NewLeaseDuration>0</NewLeaseDuration>'
    local resp, err = soap(st.control_url, st.service_type, 'AddPortMapping', args)
    if not resp then
        -- some routers reject lease 0; retry with a 12h lease
        args = args:gsub('<NewLeaseDuration>0</NewLeaseDuration>', '<NewLeaseDuration>43200</NewLeaseDuration>')
        resp, err = soap(st.control_url, st.service_type, 'AddPortMapping', args)
    end
    if not resp then
        st.error = 'Router refused port mapping: ' .. tostring(err)
        COOP.log('upnp: ' .. st.error)
        return false, nil, st.error
    end
    st.mapped = true
    local ipresp = soap(st.control_url, st.service_type, 'GetExternalIPAddress', '')
    local ext = ipresp and ipresp:match('<NewExternalIPAddress>%s*([%d%.]+)%s*</NewExternalIPAddress>')
    if not ext or ext == '0.0.0.0' then ext = upnp.public_ip_from_web() end
    st.external_ip = ext
    COOP.log('upnp: mapped TCP ' .. port .. ' -> ' .. local_ip .. ', external ip ' .. tostring(ext))
    return true, ext, nil
end

function upnp.close_port()
    local st = upnp.state
    if not st.mapped or not st.control_url then return end
    local args = '<NewRemoteHost></NewRemoteHost><NewExternalPort>' .. st.port .. '</NewExternalPort><NewProtocol>TCP</NewProtocol>'
    pcall(soap, st.control_url, st.service_type, 'DeletePortMapping', args, 2)
    st.mapped = false
    COOP.log('upnp: mapping removed')
end

-- Join codes: 32-bit IPv4 + 16-bit port -> 10 symbols from an alphabet without 0/O/1/I.
local ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'
local CODE_LEN = 10

local function ip_to_num(ip)
    local a, b, c, d = ip:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

function upnp.encode_code(ip, port)
    local n = ip_to_num(ip)
    if not n then return nil end
    -- 48-bit value split into 10 base-32 digits (50 bits); handle as two parts to stay exact in doubles
    local value = n * 65536 + port
    local digits = {}
    for i = CODE_LEN, 1, -1 do
        local d = value % 32
        digits[i] = ALPHABET:sub(d + 1, d + 1)
        value = math.floor(value / 32)
    end
    local s = table.concat(digits)
    return s:sub(1, 5) .. '-' .. s:sub(6, 10)
end

function upnp.decode_code(code)
    if not code then return nil end
    code = tostring(code):upper():gsub('[^%w]', '')
    -- forgive the characters we deliberately left out of the alphabet
    code = code:gsub('O', '0'):gsub('I', '1'):gsub('L', '1')
    if #code ~= CODE_LEN then return nil end
    local value = 0
    for i = 1, CODE_LEN do
        local ch = code:sub(i, i)
        local idx = ALPHABET:find(ch, 1, true)
        if not idx then
            if ch == '0' then idx = nil end
            return nil
        end
        value = value * 32 + (idx - 1)
    end
    local port = value % 65536
    local n = math.floor(value / 65536)
    local d = n % 256; n = math.floor(n / 256)
    local c = n % 256; n = math.floor(n / 256)
    local b = n % 256; n = math.floor(n / 256)
    local a = n % 256
    if port == 0 then return nil end
    return string.format('%d.%d.%d.%d', a, b, c, d), port
end

function upnp.looks_like_code(s)
    s = tostring(s or ''):upper():gsub('[^%w]', '')
    return #s == CODE_LEN and not s:find('%.')
end

return upnp
