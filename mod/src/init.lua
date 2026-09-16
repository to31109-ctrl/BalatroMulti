-- Balatro Co-op: module loader. Called with the mod's base folder path.
local base = ...
base = tostring(base):gsub(string.char(92), '/')

COOP = COOP or {}
COOP.BASE = base
COOP.VERSION = '0.0.0'
COOP.PROTOCOL = 1

do
    local f = io.open(base .. '/version.txt', 'r')
    if f then
        local v = f:read('*l')
        f:close()
        if v and v ~= '' then COOP.VERSION = (v:gsub('%s+', '')) end
    end
end

local function load_module(name)
    local path = base .. '/src/' .. name .. '.lua'
    local chunk, err = loadfile(path)
    if not chunk then error('BalatroCoop: cannot load ' .. path .. ': ' .. tostring(err)) end
    return chunk(base)
end
COOP.load_module = load_module

load_module('log')
COOP.log('BalatroCoop v' .. COOP.VERSION .. ' loading from ' .. base)
COOP.json = load_module('json')
COOP.net = load_module('net')
load_module('upnp')
load_module('core')
load_module('shop')
load_module('saves')
load_module('spectate')
load_module('ui')
load_module('hooks')
load_module('debug')
COOP.log('BalatroCoop loaded OK')
