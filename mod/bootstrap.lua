-- Balatro Co-op bootstrap. Appended to main.lua by Lovely.
-- Locates the mod folder and loads src/init.lua from disk so the rest of the
-- mod can be edited/updated without touching the patch manifest.
do
    local function coop_boot()
        local mods_dir = (lovely and lovely.mod_dir) or ((os.getenv('APPDATA') or '') .. '/Balatro/Mods')
        mods_dir = tostring(mods_dir):gsub(string.char(92), '/'):gsub('/+$', '')
        local candidates = { 'BalatroCoop', 'BalatroMulti', 'BalatroMulti-main/mod', 'Coop' }
        local errors = {}
        for _, name in ipairs(candidates) do
            local base = mods_dir .. '/' .. name
            local chunk, err = loadfile(base .. '/src/init.lua')
            if chunk then
                local ok, run_err = pcall(chunk, base)
                if ok then return true end
                return false, 'error while running ' .. base .. '/src/init.lua: ' .. tostring(run_err)
            else
                errors[#errors + 1] = tostring(err)
            end
        end
        return false, table.concat(errors, ' | ')
    end
    local ok, err = coop_boot()
    if not ok then
        print('[BalatroCoop] failed to load: ' .. tostring(err))
        BALATRO_COOP_LOAD_ERROR = tostring(err)
    end
end
