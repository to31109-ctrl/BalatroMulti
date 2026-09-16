-- BalatroCoop save/load. Every player keeps a vanilla-style save of their own part of
-- the run (deck, jokers, hand levels, vouchers...) under coop_saves/<session>/<name>.jkr,
-- plus a shared meta.json describing the session (players, seed, deck, stake, progress).
-- Loading matches players to their saved build by NAME, so names must stay the same.
local json = COOP.json
local saves = {}
COOP.saves = saves

local DIR = 'coop_saves'
saves.last_save_state = nil
saves.list_cache = nil

local function safe_name(name)
    return (tostring(name):gsub('[^%w_%-]', '_'))
end

function saves.session_dir(sid)
    return DIR .. '/' .. sid
end

function saves.player_file(sid, name)
    return saves.session_dir(sid) .. '/' .. safe_name(name) .. '.jkr'
end

-- Build the same table the base game writes to save.jkr
local function build_save_table()
    -- while spectating, the HUD shows the other player's hands/discards: save our own
    local spec = COOP.spectate
    local shown_hands, shown_discards
    if spec and spec.saved and G.GAME.current_round then
        shown_hands, shown_discards = G.GAME.current_round.hands_left, G.GAME.current_round.discards_left
        G.GAME.current_round.hands_left, G.GAME.current_round.discards_left = spec.saved.hands, spec.saved.discards
    end
    local cardAreas = {}
    for k, v in pairs(G) do
        if type(v) == 'table' and v.is and v:is(CardArea) and not v.coop_spectate then
            local ser = v:save()
            if ser then cardAreas[k] = ser end
        end
    end
    local tags = {}
    for k, v in ipairs(G.GAME.tags) do
        if type(v) == 'table' and v.is and v:is(Tag) then
            local ser = v:save()
            if ser then tags[k] = ser end
        end
    end
    local t = recursive_table_cull({
        cardAreas = cardAreas,
        tags = tags,
        GAME = G.GAME,
        STATE = G.STATE,
        BLIND = G.GAME.blind:save(),
        BACK = G.GAME.selected_back:save(),
        VERSION = G.VERSION,
    })
    if shown_hands ~= nil then
        G.GAME.current_round.hands_left, G.GAME.current_round.discards_left = shown_hands, shown_discards
    end
    return t
end

-- Turn state to store with a mid-blind save (host builds it, everyone stores it)
function saves.turn_meta()
    local run = COOP.run
    if not run or not run.round_active or not run.turn.active then return nil end
    local order = {}
    for _, id in ipairs(run.turn.order) do order[#order + 1] = COOP.player_name(id) end
    local chips = COOP.is_my_turn() and G.GAME.chips or run.chips
    return { active = COOP.player_name(run.turn.active), order = order, idx = run.turn.idx, chips = chips, round_no = run.round_no }
end

function saves.write_meta(sid, extra)
    local names = {}
    for _, p in ipairs(COOP.players) do names[#names + 1] = p.name end
    local meta = {
        sid = sid,
        players = names,
        turn = extra and extra.turn or nil,
        mid_blind = (extra and extra.turn) ~= nil,
        host = COOP.player_name(1),
        deck = COOP.run.deck, stake = COOP.run.stake, turn_order = COOP.run.turn_order, seed = COOP.run.seed,
        ante = G.GAME.round_resets.ante, round = G.GAME.round, dollars = G.GAME.dollars,
        saved_at = os.date('%Y-%m-%d %H:%M'), saved_at_num = os.time(),
        version = COOP.VERSION,
        finished = extra and extra.finished or false,
        won = G.GAME.won or false,
    }
    love.filesystem.write(saves.session_dir(sid) .. '/meta.json', json.encode(meta))
    saves.list_cache = nil
end

-- Save this player's part of the run (called at safe points: shop start, blind select)
function saves.save_now(reason, turn)
    local run = COOP.run
    if not COOP.active or not run or not run.sid or not G.GAME or G.STAGE ~= G.STAGES.RUN then return end
    local ok, err = pcall(function()
        love.filesystem.createDirectory(saves.session_dir(run.sid))
        local t = build_save_table()
        compress_and_save(saves.player_file(run.sid, COOP.me.name), t)
        saves.write_meta(run.sid, { turn = turn })
    end)
    if ok then
        COOP.log('co-op save written (' .. tostring(reason) .. ') for ' .. COOP.me.name)
    else
        COOP.log('co-op save failed: ' .. tostring(err))
    end
end

function saves.mark_finished()
    local run = COOP.run
    if not run or not run.sid then return end
    pcall(function()
        if love.filesystem.getInfo(saves.session_dir(run.sid) .. '/meta.json') then
            saves.write_meta(run.sid, { finished = true })
        end
    end)
end

-- Called every frame from update_run: save at safe points (shop, blind select) and
-- again whenever something relevant changed there (money, shop contents, jokers).
saves.pending_since = nil
saves.pending_reason = nil

saves.shop_ready = false -- becomes true once the shop of this visit is fully generated

local function shop_populated()
    if not G.shop or not G.shop_jokers or not G.shop_jokers.cards then return false end
    if G.load_shop_jokers or G.load_shop_vouchers or G.load_shop_booster then return false end
    if saves.shop_ready then return true end
    local used = G.GAME.current_round.used_packs
    if COOP.is_host() then
        if #G.shop_jokers.cards < (G.GAME.shop.joker_max or 2) then return false end
        if not used or not used[2] then return false end
    else
        -- clients: wait until the host's contents arrived
        if #G.shop_jokers.cards == 0 and (not used or not used[2]) then return false end
    end
    saves.shop_ready = true
    return true
end

local function state_key(st)
    local parts = { tostring(st), tostring(G.GAME.round), tostring(G.GAME.round_resets.ante), tostring(G.GAME.dollars), tostring(#G.jokers.cards), tostring(#G.consumeables.cards) }
    for _, n in ipairs({ 'shop_jokers', 'shop_vouchers', 'shop_booster' }) do
        local a = G[n]
        if a and a.cards then
            for _, c in ipairs(a.cards) do parts[#parts + 1] = tostring(c.sort_id) end
        end
    end
    return table.concat(parts, '|')
end

function saves.update(dt)
    local run = COOP.run
    if not run or not run.sid then return end
    local st = G.STATE
    local safe = (st == G.STATES.SHOP and shop_populated()) or (st == G.STATES.BLIND_SELECT and G.blind_select ~= nil)
    if safe then
        local key = state_key(st)
        if saves.last_save_state ~= key then
            saves.last_save_state = key
            saves.pending_since = love.timer.getTime()
            saves.pending_reason = st == G.STATES.SHOP and 'shop' or 'blind select'
        end
        if saves.pending_since and love.timer.getTime() - saves.pending_since > 1.0 then
            saves.pending_since = nil
            saves.save_now(saves.pending_reason)
        end
    elseif st == G.STATES.GAME_OVER then
        saves.pending_since = nil
        if saves.last_save_state ~= 'over' then
            saves.last_save_state = 'over'
            saves.mark_finished()
        end
    else
        saves.pending_since = nil
    end
    if st == G.STATES.BLIND_SELECT or st == G.STATES.SELECTING_HAND or st == G.STATES.ROUND_EVAL then
        saves.shop_ready = false
    end
end

-- Listing (host side) -----------------------------------------------------------
function saves.list()
    if saves.list_cache then return saves.list_cache end
    local out = {}
    local ok, dirs = pcall(love.filesystem.getDirectoryItems, DIR)
    if ok and dirs then
        for _, d in ipairs(dirs) do
            local mpath = DIR .. '/' .. d .. '/meta.json'
            if love.filesystem.getInfo(mpath) then
                local ok2, meta = pcall(function() return json.decode(love.filesystem.read(mpath)) end)
                if ok2 and type(meta) == 'table' and not meta.finished then
                    meta.sid = meta.sid or d
                    out[#out + 1] = meta
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.saved_at_num or 0) > (b.saved_at_num or 0) end)
    saves.list_cache = out
    return out
end

function saves.has_player_file(sid, name)
    return love.filesystem.getInfo(saves.player_file(sid, name)) ~= nil
end

function saves.delete(sid)
    pcall(function()
        local dir = saves.session_dir(sid)
        for _, f in ipairs(love.filesystem.getDirectoryItems(dir)) do
            love.filesystem.remove(dir .. '/' .. f)
        end
        love.filesystem.remove(dir)
    end)
    saves.list_cache = nil
end

-- Loading ------------------------------------------------------------------------
function saves.load_table(sid, name)
    local path = saves.player_file(sid, name)
    local str = get_compressed(path)
    if not str then return nil, 'no save file for ' .. tostring(name) end
    local ok, t = pcall(STR_UNPACK, str)
    if not ok or type(t) ~= 'table' then return nil, 'save file is corrupt' end
    return t
end

-- Names required by a saved session that are not in the lobby (and vice versa)
function saves.lobby_matches(meta)
    local missing, extra = {}, {}
    local have = {}
    for _, p in ipairs(COOP.players) do have[p.name] = true end
    local need = {}
    for _, n in ipairs(meta.players or {}) do
        need[n] = true
        if not have[n] then missing[#missing + 1] = n end
    end
    for _, p in ipairs(COOP.players) do
        if not need[p.name] then extra[#extra + 1] = p.name end
    end
    return #missing == 0 and #extra == 0, missing, extra
end

return saves
