-- BalatroCoop spectate: the active player streams their table (hand, played cards,
-- jokers, consumables, HUD numbers, cursor) and everyone else renders a live mirror.
local json = COOP.json
local spec = {}
COOP.spectate = spec

spec.target = nil      -- player id currently being watched
spec.areas = nil       -- mirror card areas {hand, play, jokers, cons}
spec.hidden = nil      -- own areas hidden while spectating
spec.saved = nil       -- saved HUD values (hands/discards)
spec.last_sent = {}    -- part -> encoded string (sender side)
spec.pending = {}      -- part -> latest data received
spec.cursor = { x = 10, y = 6, tx = 10, ty = 6, visible = false, t = 0 }
spec.cursor_sprite = nil
spec.send_timer = 0
spec.cursor_timer = 0
spec.last_cursor = { x = nil, y = nil }

-- Playing cards: tiny description (key, enhancement, edition, seal, debuff, face-down).
-- Jokers/consumables: full save (their descriptions depend on ability values).
local function ser_playing(area)
    local list = {}
    if not area or not area.cards then return list end
    for i, c in ipairs(area.cards) do
        local ed = c.edition and c.edition.type or nil
        list[i] = {
            uid = c.sort_id, hl = c.highlighted and true or false,
            k = c.config.card_key, c = c.config.center_key,
            e = ed, sl = c.seal, d = c.debuff and true or nil, f = (c.facing == 'back') and true or nil,
        }
    end
    return list
end

local function ser_cards(area)
    local list = {}
    if not area or not area.cards then return list end
    for i, c in ipairs(area.cards) do
        list[i] = { uid = c.sort_id, hl = c.highlighted and true or false, s = c:save() }
    end
    return list
end

local function hud_data()
    local cr = G.GAME.current_round
    local ch = cr.current_hand or {}
    return {
        hands = cr.hands_left, discards = cr.discards_left, chips = G.GAME.chips,
        handname = ch.handname or '', hchips = ch.chips or 0, hmult = ch.mult or 0,
        hand_level = ch.hand_level or '', chip_total = ch.chip_total or 0,
    }
end

-- Sender ---------------------------------------------------------------------
function spec.send_updates(dt)
    spec.send_timer = spec.send_timer + dt
    spec.cursor_timer = spec.cursor_timer + dt
    if spec.cursor_timer >= 0.12 and G.CURSOR then
        spec.cursor_timer = 0
        local x, y = G.CURSOR.T.x, G.CURSOR.T.y
        if spec.last_cursor.x == nil or math.abs(x - spec.last_cursor.x) > 0.02 or math.abs(y - spec.last_cursor.y) > 0.02 then
            spec.last_cursor.x, spec.last_cursor.y = x, y
            COOP.send_to_host({ t = 'cur', x = math.floor(x * 100) / 100, y = math.floor(y * 100) / 100 })
        end
    end
    if spec.send_timer < 0.15 then return end
    spec.send_timer = 0
    local parts = {
        hand = ser_playing(G.hand), play = ser_playing(G.play),
        jokers = ser_cards(G.jokers), cons = ser_cards(G.consumeables),
        hud = hud_data(),
    }
    for name, data in pairs(parts) do
        local ok, s = pcall(json.encode, data)
        if ok and s ~= spec.last_sent[name] then
            spec.last_sent[name] = s
            COOP.send_to_host({ t = 'snap', part = name, data = data })
        end
    end
end

function spec.reset_sender()
    spec.last_sent = {}
    spec.last_cursor = { x = nil, y = nil }
end

-- Receiver -------------------------------------------------------------------
function spec.on_turn_changed()
    local run = COOP.run
    local active = run and run.turn.active
    if active and active ~= COOP.me.id then
        spec.start(active)
    else
        spec.stop()
        spec.reset_sender()
    end
end

local function make_mirror(src, type_)
    local limit = src.config.card_limit or 8
    local a = CardArea(src.T.x, src.T.y, src.T.w, src.T.h,
        { card_limit = limit, type = type_, highlight_limit = 0, card_w = src.card_w })
    a.config.temp_limit = src.config.temp_limit or limit
    a.coop_spectate = true
    -- the mirror draws its own box and "x/y" counter (the real, hidden areas draw nothing)
    a:hard_set_T(src.T.x, src.T.y, src.T.w, src.T.h)
    return a
end

function spec.start(id)
    if spec.target == id and spec.areas then return end
    if spec.target then spec.stop() end
    if not G.hand or not G.jokers or not G.play or not G.consumeables then return end
    spec.target = id
    spec.hidden = { G.hand, G.play, G.jokers, G.consumeables }
    for _, a in ipairs(spec.hidden) do a.states.visible = false end
    local cr = G.GAME.current_round
    spec.saved = { hands = cr.hands_left, discards = cr.discards_left }
    spec.shown = { hands = nil, discards = nil }
    spec.areas = {
        hand = make_mirror(G.hand, 'hand'),
        play = make_mirror(G.play, 'play'),
        jokers = make_mirror(G.jokers, 'joker'),
        cons = make_mirror(G.consumeables, 'joker'),
    }
    spec.cursor.visible = true
    for part, data in pairs(spec.pending) do
        pcall(spec.apply_part, part, data)
    end
    COOP.log('spectating player ' .. tostring(id))
end

function spec.stop()
    if not spec.target and not spec.areas then return end
    spec.target = nil
    spec.pending = {}
    if spec.areas then
        for _, a in pairs(spec.areas) do pcall(a.remove, a) end
        spec.areas = nil
    end
    if spec.hidden then
        for _, a in ipairs(spec.hidden) do a.states.visible = true end
        spec.hidden = nil
    end
    if spec.saved and G.GAME and G.GAME.current_round then
        G.GAME.current_round.hands_left = spec.saved.hands
        G.GAME.current_round.discards_left = spec.saved.discards
        spec.saved = nil
    end
    spec.shown = nil
    spec.cursor.visible = false
    pcall(update_hand_text, { immediate = true, nopulse = true, delay = 0 }, { mult = 0, chips = 0, level = '', handname = '' })
    if G.hand and G.hand.cards then pcall(G.hand.align_cards, G.hand) end
end

function spec.on_snapshot(msg)
    if not COOP.run or not msg.part then return end
    spec.pending[msg.part] = msg.data
    if spec.target and spec.target == msg.from and spec.areas then
        local ok, err = pcall(spec.apply_part, msg.part, msg.data)
        if not ok then COOP.log('spectate apply failed: ' .. tostring(err)) end
    end
end

function spec.on_cursor(msg)
    if not spec.target or msg.from ~= spec.target then return end
    spec.cursor.tx = tonumber(msg.x) or spec.cursor.tx
    spec.cursor.ty = tonumber(msg.y) or spec.cursor.ty
    spec.cursor.visible = true
end

function spec.apply_part(part, data)
    if not data then return end
    if part == 'hud' then
        local cr = G.GAME.current_round
        spec.shown = spec.shown or {}
        if data.hands ~= nil then cr.hands_left = data.hands; spec.shown.hands = data.hands end
        if data.discards ~= nil then cr.discards_left = data.discards; spec.shown.discards = data.discards end
        if data.chips ~= nil then
            G.GAME.chips = data.chips
            if COOP.run then COOP.run.chips = data.chips end
        end
        local ch = cr.current_hand
        if ch then
            ch.handname = data.handname or ''
            ch.chips = data.hchips or 0
            ch.mult = data.hmult or 0
            ch.hand_level = data.hand_level or ''
            ch.chip_total = data.chip_total or 0
        end
        return
    end
    local area = spec.areas and spec.areas[part]
    if area then spec.reconcile(area, data) end
end

function spec.reconcile(area, list)
    if not area.cards then return end
    list = list or {}
    local existing = {}
    for _, c in ipairs(area.cards) do
        if c.coop_uid then existing[c.coop_uid] = c end
    end
    local new_cards = {}
    for i, item in ipairs(list) do
        local c = existing[item.uid]
        if c then
            existing[item.uid] = nil
        elseif item.s then
            c = Card(area.T.x + area.T.w / 2, area.T.y, G.CARD_W, G.CARD_H, G.P_CARDS.empty, G.P_CENTERS.c_base,
                { bypass_discovery_center = true, bypass_discovery_ui = true })
            c:load(item.s)
            c:hard_set_T()
            c.coop_uid = item.uid
            c.added_to_deck = false
            c.states.drag.can = false
            c.states.click.can = false
        else
            local front = G.P_CARDS[item.k] or G.P_CARDS.empty
            local center = G.P_CENTERS[item.c] or G.P_CENTERS.c_base
            c = Card(area.T.x + area.T.w / 2, area.T.y, G.CARD_W, G.CARD_H, front, center,
                { bypass_discovery_center = true, bypass_discovery_ui = true })
            if item.e then pcall(c.set_edition, c, { [item.e] = true }, true, true) end
            if item.sl then pcall(c.set_seal, c, item.sl, true, true) end
            if item.f then pcall(c.flip, c) end
            c:hard_set_T()
            c.coop_uid = item.uid
            c.added_to_deck = false
            c.states.drag.can = false
            c.states.click.can = false
        end
        c.highlighted = item.hl and true or false
        if item.s and type(item.s) == 'table' then c.debuff = item.s.debuff else c.debuff = item.d and true or false end
        new_cards[#new_cards + 1] = c
    end
    for _, c in pairs(existing) do
        pcall(function()
            area:remove_card(c)
            c:remove()
        end)
    end
    area.cards = new_cards
    area.highlighted = {}
    for _, c in ipairs(new_cards) do
        c:set_card_area(area)
        if c.highlighted then area.highlighted[#area.highlighted + 1] = c end
    end
    area:set_ranks()
    area:align_cards()
end

-- Per-frame ------------------------------------------------------------------
function spec.update(dt)
    if COOP.is_my_turn() then
        spec.send_updates(dt)
    end
    if spec.target and spec.saved and spec.shown and G.GAME and G.GAME.current_round then
        local cr = G.GAME.current_round
        if spec.shown.hands ~= nil and cr.hands_left ~= spec.shown.hands then
            spec.saved.hands = cr.hands_left
            cr.hands_left = spec.shown.hands
        end
        if spec.shown.discards ~= nil and cr.discards_left ~= spec.shown.discards then
            spec.saved.discards = cr.discards_left
            cr.discards_left = spec.shown.discards
        end
    end
    if spec.target then
        local c = spec.cursor
        local k = math.min(1, dt * 14)
        c.x = c.x + (c.tx - c.x) * k
        c.y = c.y + (c.ty - c.y) * k
        -- keep mirrors glued to the real areas in case the layout moved
        if spec.areas and G.hand then
            for name, src in pairs({ hand = G.hand, play = G.play, jokers = G.jokers, cons = G.consumeables }) do
                local a = spec.areas[name]
                if a and src and (a.T.x ~= src.T.x or a.T.y ~= src.T.y) then
                    a:hard_set_T(src.T.x, src.T.y, src.T.w, src.T.h)
                end
            end
        end
    end
end

-- Remote cursor drawing: called from the G.CURSOR draw hook (inside the room transform)
function spec.draw_remote_cursor()
    if not spec.target or not spec.cursor.visible then return end
    if not spec.cursor_sprite then
        local ok, spr = pcall(function()
            local s = Sprite(0, 0, 0.4, 0.4, G.ASSET_ATLAS['gamepad_ui'], { x = 18, y = 0 })
            s.states.collide.can = false
            s.states.hover.can = false
            s.states.drag.can = false
            return s
        end)
        if not ok then
            COOP.log('cursor sprite failed: ' .. tostring(spr))
            spec.cursor.visible = false
            return
        end
        spec.cursor_sprite = spr
    end
    local s = spec.cursor_sprite
    s.T.x, s.T.y = spec.cursor.x, spec.cursor.y
    s.VT.x, s.VT.y = spec.cursor.x, spec.cursor.y
    s.states.visible = true
    s:draw(G.C.RED)
end
