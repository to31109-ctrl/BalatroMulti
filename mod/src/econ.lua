-- BalatroCoop shared economy. The shop and the interest live on the host's game, so
-- shop/economy modifiers owned by OTHER players (Overstock, Clearance Sale, Reroll Surplus,
-- Chaos the Clown, Seed Money, Credit Card, Hone/Glow Up, Merchant vouchers, ...) would do
-- nothing. Every player reports its modifiers; the host applies the combined effect to the
-- shared shop/wallet. Per-player things (hands, discards, hand size, jokers) stay per player.
local econ = {}
COOP.econ = econ

local RATES = { 'joker_rate', 'tarot_rate', 'planet_rate', 'playing_card_rate', 'spectral_rate', 'edition_rate' }

econ.reports = {}        -- host: player id -> report
econ.last_sent = nil     -- client: last report json
econ.timer = 0
econ.applied = nil       -- host: what we last applied (to tell our own changes from ours)

local function count_joker(name)
    local ok, list = pcall(find_joker, name)
    return (ok and type(list) == 'table') and #list or 0
end

-- What this player contributes (host builds its own the same way)
function econ.my_report()
    if not G.GAME or not G.GAME.shop then return nil end
    local base_slots = G.GAME.coop_base_joker_max or G.GAME.shop.joker_max
    local credit = 0
    local ok, cards = pcall(find_joker, 'Credit Card')
    if ok and type(cards) == 'table' then
        for _, c in ipairs(cards) do credit = credit + ((c.ability and c.ability.extra) or 20) end
    end
    local r = {
        extra_slots = math.max(0, (G.GAME.shop.joker_max or base_slots) - base_slots),
        discount = G.GAME.discount_percent or 0,
        reroll_red = math.max(0, (G.GAME.base_reroll_cost or 5) - (G.GAME.round_resets.reroll_cost or 5)),
        chaos = count_joker('Chaos the Clown'),
        interest_cap = G.GAME.interest_cap or 25,
        credit = credit,
    }
    for _, k in ipairs(RATES) do r[k] = G.GAME[k] or 0 end
    return r
end

-- Client: send the report whenever it changes ---------------------------------
function econ.client_update(dt)
    econ.timer = econ.timer + dt
    if econ.timer < 1 then return end
    econ.timer = 0
    local r = econ.my_report()
    if not r then return end
    local ok, s = pcall(COOP.json.encode, r)
    if ok and s ~= econ.last_sent then
        econ.last_sent = s
        COOP.send_to_host({ t = 'econ', r = r })
    end
end

-- Host: aggregate ------------------------------------------------------------------
local function combined(field, how)
    local v = nil
    for _, rep in pairs(econ.reports) do
        local x = rep[field]
        if type(x) == 'number' then
            if v == nil then v = x
            elseif how == 'max' then v = math.max(v, x)
            elseif how == 'min' then v = math.min(v, x)
            else v = v + x end
        end
    end
    return v
end

function econ.host_apply()
    if not COOP.is_host() or not G.GAME or not G.GAME.shop then return end
    econ.applied = econ.applied or { extra = 0, chaos = 0, bankrupt = G.GAME.bankrupt_at or 0 }
    local A = econ.applied
    -- our own report is always current
    local mine = econ.my_report()
    if mine then
        -- our own contribution must not include what we applied on behalf of others
        mine.extra_slots = math.max(0, mine.extra_slots - A.extra)
        econ.reports[COOP.me.id] = mine
    end

    -- shop slots: base + everyone's extra slots
    local extra_clients = 0
    for id, rep in pairs(econ.reports) do
        if id ~= COOP.me.id then extra_clients = extra_clients + (rep.extra_slots or 0) end
    end
    if extra_clients ~= A.extra then
        local delta = extra_clients - A.extra
        A.extra = extra_clients
        pcall(change_shop_size, delta)
        COOP.log('econ: shop slots ' .. (delta > 0 and '+' or '') .. delta .. ' from other players')
    end

    -- max-style modifiers: discount, interest cap, shop rates
    local function apply_max(field, game_key, after)
        local mine_v = econ.reports[COOP.me.id] and econ.reports[COOP.me.id][field]
        -- if the game value changed underneath us, that was the host's own change
        if A[game_key] ~= nil and G.GAME[game_key] ~= A[game_key] then mine_v = G.GAME[game_key] end
        if mine_v ~= nil and econ.reports[COOP.me.id] then econ.reports[COOP.me.id][field] = mine_v end
        local eff = combined(field, 'max')
        if eff ~= nil and G.GAME[game_key] ~= eff then
            G.GAME[game_key] = eff
            COOP.log('econ: ' .. game_key .. ' = ' .. tostring(eff))
            if after then pcall(after) end
        end
        A[game_key] = G.GAME[game_key]
    end
    apply_max('discount', 'discount_percent', function()
        for _, v in pairs(G.I.CARD) do if v.set_cost then v:set_cost() end end
        if COOP.shop then COOP.shop.last_sig = nil end
    end)
    apply_max('interest_cap', 'interest_cap')
    for _, k in ipairs(RATES) do apply_max(k, k) end

    -- reroll cost: base minus the best reduction anyone has
    do
        local red = combined('reroll_red', 'max') or 0
        local target = math.max(0, (G.GAME.base_reroll_cost or 5) - red)
        if G.GAME.round_resets.reroll_cost ~= target then
            G.GAME.round_resets.reroll_cost = target
            pcall(calculate_reroll_cost, true)
            if COOP.shop then COOP.shop.last_sig = nil end
            COOP.log('econ: reroll cost = ' .. target)
        end
    end

    -- free rerolls from everyone's Chaos the Clown (host's own are counted by the base game)
    do
        local chaos_clients = 0
        for id, rep in pairs(econ.reports) do
            if id ~= COOP.me.id then chaos_clients = chaos_clients + (rep.chaos or 0) end
        end
        if chaos_clients ~= A.chaos then
            local delta = chaos_clients - A.chaos
            A.chaos = chaos_clients
            G.GAME.current_round.free_rerolls = math.max(0, (G.GAME.current_round.free_rerolls or 0) + delta)
            pcall(calculate_reroll_cost, true)
            if COOP.shop then COOP.shop.last_sig = nil end
        end
    end

    -- debt allowance: the lowest bankrupt_at anyone's Credit Card gives
    do
        local credit = combined('credit', 'max') or 0
        local eff = -credit
        if (G.GAME.bankrupt_at or 0) ~= eff then
            G.GAME.bankrupt_at = eff
            COOP.log('econ: bankrupt_at = ' .. eff)
        end
        if A.bankrupt ~= eff then
            A.bankrupt = eff
            COOP.broadcast({ t = 'econ_fx', bankrupt_at = eff }, COOP.me.id)
        end
    end
end

function econ.host_on_report(player, msg)
    if type(msg.r) ~= 'table' then return end
    econ.reports[player.id] = msg.r
    econ.dirty = true
end

function econ.host_update(dt)
    econ.timer = econ.timer + dt
    if econ.timer < 1 and not econ.dirty then return end
    econ.timer = 0
    econ.dirty = false
    local ok, err = pcall(econ.host_apply)
    if not ok then COOP.log('econ apply failed: ' .. tostring(err)) end
end

function econ.on_player_left(id)
    econ.reports[id] = nil
    econ.dirty = true
end

function econ.update(dt)
    if not COOP.active or not G.GAME or G.STAGE ~= G.STAGES.RUN then return end
    if COOP.is_host() then econ.host_update(dt) else econ.client_update(dt) end
end

function econ.reset()
    econ.reports = {}
    econ.last_sent = nil
    econ.applied = nil
    econ.timer = 0
end

return econ
