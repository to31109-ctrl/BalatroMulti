-- BalatroCoop shared shop. The host owns the shop contents; clients mirror it.
-- Purchases are requested from the host, which validates money/availability.
local shop = {}
COOP.shop = shop

local AREA_NAMES = { 'shop_jokers', 'shop_vouchers', 'shop_booster' }
shop.last_sig = nil
shop.dirty_at = nil
shop.pending = nil

local function now()
    return love.timer.getTime()
end

function shop.area_name_of(area)
    for _, n in ipairs(AREA_NAMES) do
        if G[n] == area then return n end
    end
end

function shop.is_shop_area(area)
    return area ~= nil and shop.area_name_of(area) ~= nil
end

local function areas_ready()
    for _, n in ipairs(AREA_NAMES) do
        local a = G[n]
        if not a or not a.cards then return false end
    end
    return G.shop ~= nil
end

function shop.find_card(uid)
    for _, n in ipairs(AREA_NAMES) do
        local a = G[n]
        if a and a.cards then
            for _, c in ipairs(a.cards) do
                if c.coop_uid == uid then return c, a end
            end
        end
    end
end

local function serialize_area(area)
    local list = {}
    if not area or not area.cards then return list end
    for _, c in ipairs(area.cards) do
        if not c.coop_uid then c.coop_uid = c.sort_id end
        list[#list + 1] = { uid = c.coop_uid, s = c:save() }
    end
    return list
end

local function signature()
    local parts = {}
    for _, n in ipairs(AREA_NAMES) do
        local a = G[n]
        if a and a.cards then
            for _, c in ipairs(a.cards) do
                if not c.coop_uid then c.coop_uid = c.sort_id end
                parts[#parts + 1] = tostring(c.coop_uid)
            end
        end
        parts[#parts + 1] = '|'
    end
    parts[#parts + 1] = tostring(G.GAME.current_round.reroll_cost)
    parts[#parts + 1] = tostring(G.GAME.discount_percent) .. '/' .. tostring(G.GAME.current_round.free_rerolls)
    return table.concat(parts, ',')
end

-- Host -----------------------------------------------------------------------
function shop.host_ensure_extra_boosters()
    local n = COOP.run and COOP.run.n or 1
    if n <= 1 then return end
    local total = 2 * n
    local used = G.GAME.current_round.used_packs
    if not used or not used[2] then return end
    local area = G.shop_booster
    if not area or not area.cards then return end
    if area.config.card_limit < total then area.config.card_limit = total end
    for i = 3, total do
        if not used[i] then used[i] = get_pack('shop_pack').key end
        if used[i] ~= 'USED' and G.P_CENTERS[used[i]] then
            local exists = false
            for _, c in ipairs(area.cards) do
                if c.ability and c.ability.booster_pos == i then exists = true end
            end
            if not exists then
                local card = Card(area.T.x + area.T.w / 2, area.T.y, G.CARD_W * 1.27, G.CARD_H * 1.27,
                    G.P_CARDS.empty, G.P_CENTERS[used[i]], { bypass_discovery_center = true, bypass_discovery_ui = true })
                create_shop_card_ui(card, 'Booster', area)
                card.ability.booster_pos = i
                card:start_materialize()
                area:emplace(card)
            end
        end
    end
end

function shop.broadcast()
    if COOP.mode ~= 'host' or not COOP.active then return end
    COOP.broadcast({
        t = 'shop',
        jokers = serialize_area(G.shop_jokers),
        vouchers = serialize_area(G.shop_vouchers),
        boosters = serialize_area(G.shop_booster),
        reroll_cost = G.GAME.current_round.reroll_cost,
        round = G.GAME.round,
    }, COOP.me.id)
end

function shop.host_update(dt)
    if not areas_ready() then
        shop.last_sig = nil
        return
    end
    pcall(shop.host_ensure_extra_boosters)
    local sig = signature()
    if sig ~= shop.last_sig then
        shop.last_sig = sig
        shop.dirty_at = now()
    end
    if shop.dirty_at and now() - shop.dirty_at > 0.3 then
        shop.dirty_at = nil
        shop.broadcast()
    end
end

function shop.host_on_buy(player, msg)
    if player.id == COOP.me.id then return end
    local card, area = shop.find_card(msg.uid)
    if not card then
        COOP.send_to(player, { t = 'buy_fail', uid = msg.uid, reason = 'Already sold' })
        return
    end
    local cost = card.cost or 0
    if cost > 0 and cost > G.GAME.dollars - (G.GAME.bankrupt_at or 0) then
        COOP.send_to(player, { t = 'buy_fail', uid = msg.uid, reason = 'Not enough money' })
        return
    end
    if cost > 0 then
        COOP.suppress_dollar_sync = true
        pcall(ease_dollars, -cost, true)
        COOP.suppress_dollar_sync = false
    end
    COOP.broadcast_wallet()
    if card.ability and card.ability.set == 'Booster' and card.ability.booster_pos then
        G.GAME.current_round.used_packs[card.ability.booster_pos] = 'USED'
    end
    local name = (card.ability and card.ability.name) or 'a card'
    COOP.send_to(player, { t = 'buy_ok', uid = msg.uid, use = msg.use, buy_and_use = msg.buy_and_use })
    pcall(function()
        area:remove_card(card)
        card:remove()
    end)
    shop.last_sig = nil
    COOP.broadcast({ t = 'toast', text = player.name .. ' bought ' .. name .. (cost > 0 and (' ($' .. cost .. ')') or '') })
end

function shop.host_on_reroll(player, msg)
    if player.id == COOP.me.id then return end
    if not G.shop or G.STATE ~= G.STATES.SHOP then
        COOP.send_to(player, { t = 'toast', text = 'Host is busy, try again' })
        return
    end
    if G.CONTROLLER.locks.shop_reroll then return end
    local cost = G.GAME.current_round.reroll_cost or 0
    if cost > 0 and cost > G.GAME.dollars - (G.GAME.bankrupt_at or 0) then
        COOP.send_to(player, { t = 'toast', text = 'Not enough money to reroll' })
        return
    end
    COOP.executing = true
    local ok, err = pcall(G.FUNCS.reroll_shop, nil)
    COOP.executing = false
    if not ok then COOP.log('host reroll failed: ' .. tostring(err)) end
    COOP.broadcast({ t = 'toast', text = player.name .. ' rerolled the shop' }, player.id)
end

-- Client ---------------------------------------------------------------------
function shop.on_shop(msg)
    shop.pending = msg
    shop.try_apply()
end

local function make_card(area, item, kind)
    local card = Card(area.T.x + area.T.w / 2, area.T.y, G.CARD_W, G.CARD_H, G.P_CARDS.empty, G.P_CENTERS.c_base,
        { bypass_discovery_center = true, bypass_discovery_ui = true })
    card:load(item.s)
    card:hard_set_T()
    card.coop_uid = item.uid
    card.added_to_deck = false
    if kind == 'Voucher' then card.shop_voucher = true end
    create_shop_card_ui(card, kind, area)
    card:start_materialize()
    area:emplace(card)
    return card
end

function shop.reconcile(area, list, kind)
    list = list or {}
    local existing = {}
    for _, c in ipairs(area.cards) do
        if c.coop_uid then existing[c.coop_uid] = c end
    end
    local keep = {}
    for _, item in ipairs(list) do
        local c = existing[item.uid]
        if not c then
            local ok, err = pcall(make_card, area, item, kind)
            if not ok then COOP.log('shop make_card failed: ' .. tostring(err)) end
        elseif item.s then
            -- prices can change while the card sits in the shop (discount vouchers, inflation)
            if item.s.cost ~= nil then c.cost = item.s.cost end
            if item.s.sell_cost ~= nil then c.sell_cost = item.s.sell_cost end
        end
        keep[item.uid] = true
    end
    for i = #area.cards, 1, -1 do
        local c = area.cards[i]
        if not c.coop_uid or not keep[c.coop_uid] then
            pcall(function()
                area:remove_card(c)
                c:remove()
            end)
        end
    end
    area:align_cards()
end

function shop.try_apply()
    local msg = shop.pending
    if not msg then return end
    if G.STATE ~= G.STATES.SHOP or not areas_ready() then return end
    -- wait until the base game finished its (empty) shop load, otherwise it would wipe our cards
    if G.load_shop_jokers or G.load_shop_vouchers or G.load_shop_booster then return end
    shop.pending = nil
    if msg.reroll_cost then G.GAME.current_round.reroll_cost = msg.reroll_cost end
    shop.reconcile(G.shop_jokers, msg.jokers, nil)
    shop.reconcile(G.shop_vouchers, msg.vouchers, 'Voucher')
    shop.reconcile(G.shop_booster, msg.boosters, 'Booster')
end

function shop.client_request_buy(card, use, buy_and_use)
    if card.coop_pending_buy then return end
    if not card.coop_uid then return end
    card.coop_pending_buy = true
    COOP.send_to_host({ t = 'buy', uid = card.coop_uid, use = use and true or false, buy_and_use = buy_and_use and true or false })
end

function shop.on_buy_ok(msg)
    local card = shop.find_card(msg.uid)
    if not card then
        COOP.log('buy_ok for unknown card ' .. tostring(msg.uid))
        return
    end
    card.coop_pending_buy = nil
    local orig_cost = card.cost
    card.cost = 0 -- already paid from the shared wallet by the host
    COOP.executing = true
    local ok, err = pcall(function()
        if msg.use then
            G.FUNCS.use_card({ config = { ref_table = card } })
        else
            G.FUNCS.buy_from_shop({ config = { ref_table = card, id = msg.buy_and_use and 'buy_and_use' or nil } })
        end
    end)
    COOP.executing = false
    if not ok then COOP.log('local buy failed: ' .. tostring(err)) end
    G.E_MANAGER:add_event(Event({
        trigger = 'after', delay = 0.6, blocking = false, blockable = false,
        func = function()
            if card.cost == 0 and orig_cost and orig_cost > 0 then card.cost = orig_cost end
            return true
        end
    }))
end

function shop.on_buy_fail(msg)
    local card = shop.find_card(msg.uid)
    if card then card.coop_pending_buy = nil end
    COOP.toast(tostring(msg.reason or 'Purchase failed'), G.C.RED, 2)
end

function shop.client_update(dt)
    shop.try_apply()
end

function shop.update(dt)
    if not COOP.active then return end
    if COOP.is_host() then shop.host_update(dt) else shop.client_update(dt) end
end

-- Applied by the G.UIDEF.shop hook right after the base game creates the shop areas.
function shop.on_shop_created()
    if not COOP.active or not COOP.run then return end
    local n = math.max(1, COOP.run.n)
    if G.shop_jokers then
        G.shop_jokers.T.w = math.min(G.shop_jokers.T.w, 9.4)
        G.shop_jokers.config.card_limit = G.GAME.shop.joker_max
    end
    if G.shop_booster then
        G.shop_booster.config.card_limit = 2 * n
        G.shop_booster.T.w = math.min(1.25 * G.CARD_W * 2 * n, 7.4)
    end
    if not COOP.is_host() then
        -- clients never generate their own shop; the host's contents arrive over the network
        G.load_shop_jokers = { cards = {}, config = G.shop_jokers.config }
        G.load_shop_vouchers = { cards = {}, config = G.shop_vouchers.config }
        G.load_shop_booster = { cards = {}, config = G.shop_booster.config }
    end
    shop.last_sig = nil
end
