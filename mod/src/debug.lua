-- BalatroCoop developer tooling. Only active when the environment variable
-- BALATRO_COOP_DEBUG is set, so it never runs for normal players.
--   BALATRO_COOP_INST=<tag>     instance tag (default "a")
--   BALATRO_COOP_AUTO=host|join automatically host / join on the main menu
--   BALATRO_COOP_NAME=<name>    player name for the automatic lobby
-- Commands: write Lua to %APPDATA%/Balatro/coop_cmd_<tag>.lua; the result is
-- written to coop_out_<tag>.txt and the command file is deleted.
local dbg = {}
COOP.debug = dbg

dbg.enabled = os.getenv('BALATRO_COOP_DEBUG') ~= nil
if not dbg.enabled then return dbg end

dbg.inst = os.getenv('BALATRO_COOP_INST') or 'a'
dbg.auto = os.getenv('BALATRO_COOP_AUTO')
dbg.auto_name = os.getenv('BALATRO_COOP_NAME')
dbg.auto_done = false
dbg.timer = 0
dbg.cmd_file = 'coop_cmd_' .. dbg.inst .. '.lua'
dbg.out_file = 'coop_out_' .. dbg.inst .. '.txt'
COOP.log('debug mode on, instance ' .. dbg.inst .. ' auto=' .. tostring(dbg.auto))
pcall(love.filesystem.remove, dbg.cmd_file)
pcall(love.filesystem.write, dbg.out_file, 'READY')

local function dump(v, depth)
    depth = depth or 0
    if type(v) == 'table' then
        if depth > 2 then return '{...}' end
        local parts = {}
        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 40 then parts[#parts + 1] = '...'; break end
            parts[#parts + 1] = tostring(k) .. '=' .. dump(val, depth + 1)
        end
        return '{' .. table.concat(parts, ', ') .. '}'
    end
    return tostring(v)
end
dbg.dump = dump

function dbg.run_command(src)
    local chunk, err = loadstring(src, 'coop_cmd')
    if not chunk then return 'COMPILE ERROR: ' .. tostring(err) end
    local ok, res = pcall(chunk)
    if not ok then return 'RUNTIME ERROR: ' .. tostring(res) end
    if type(res) == 'table' then
        local ok2, s = pcall(COOP.json.encode, res)
        return ok2 and s or dump(res)
    end
    return tostring(res)
end

function dbg.update(dt)
    dbg.timer = dbg.timer + dt
    if dbg.timer < 0.2 then return end
    dbg.timer = 0
    -- automatic lobby actions once the main menu is up
    if dbg.auto and not dbg.auto_done and G.STAGE == G.STAGES.MAIN_MENU and G.STATE == G.STATES.MENU and G.MAIN_MENU_UI then
        dbg.auto_done = true
        if dbg.auto_name then COOP.cfg.name = dbg.auto_name end
        if dbg.auto == 'host' then
            G.FUNCS.coop_menu()
            G.FUNCS.coop_host_click()
        elseif dbg.auto == 'join' then
            G.FUNCS.coop_menu()
            G.FUNCS.coop_join_click()
            G.FUNCS.coop_connect_click()
        end
    end
    local info = love.filesystem.getInfo(dbg.cmd_file)
    if info then
        local src = love.filesystem.read(dbg.cmd_file)
        love.filesystem.remove(dbg.cmd_file)
        if src and src ~= '' then
            local out = dbg.run_command(src)
            love.filesystem.write(dbg.out_file, out)
            COOP.log('debug cmd -> ' .. tostring(out):sub(1, 200))
        end
    end
end

local orig_update = COOP.update
COOP.update = function(dt)
    orig_update(dt)
    local ok, err = pcall(dbg.update, dt)
    if not ok then COOP.log('debug update error: ' .. tostring(err)) end
end

return dbg
