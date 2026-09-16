-- BalatroCoop hooks into the base game. Every hook falls back to the original
-- behaviour when no co-op run is active.
local shop = COOP.shop
local spec = COOP.spectate

local function wrap(tbl, name, fn)
    local orig = tbl[name]
    if type(orig) ~= 'function' then
        COOP.log('hook target missing: ' .. tostring(name))
        return
    end
    tbl[name] = function(...)
        return fn(orig, ...)
    end
end

-- Frame pump -----------------------------------------------------------------
wrap(Game, 'update', function(orig, self, dt)
    orig(self, dt)
    local ok, err = pcall(COOP.update, dt)
    if not ok then
        if COOP.last_update_err ~= tostring(err) then
            COOP.last_update_err = tostring(err)
            COOP.log('COOP.update error: ' .. tostring(err))
        end
    end
end)

-- Main menu button -----------------------------------------------------------
wrap(_G, 'create_UIBox_main_menu_buttons', function(orig)
    local t = orig()
    pcall(function()
        local col = t.nodes[1].nodes[1].nodes
        table.insert(col, 2, UIBox_button({
            id = 'coop_button', button = 'coop_menu', colour = G.C.GREEN,
            minw = 3.65, minh = 1.0, label = { 'CO-OP' }, scale = 0.45 * 1.5, col = true,
        }))
    end)
    return t
end)

-- Escape/options menu: host gets a "Save co-op run" button ------------------------
wrap(_G, 'create_UIBox_options', function(orig)
    local t = orig()
    if COOP.active and G.STAGE == G.STAGES.RUN then
        pcall(function()
            local contents = t.nodes[1].nodes[1].nodes[1].nodes
            local label = COOP.is_host() and 'SAVE CO-OP RUN' or 'CO-OP RUN (host saves)'
            table.insert(contents, 1, UIBox_button({ id = 'coop_save_button', button = 'coop_save_click', label = { label }, colour = COOP.is_host() and G.C.GREEN or G.C.UI.BACKGROUND_INACTIVE, minw = 5 }))
        end)
    end
    return t
end)

-- Text input: allow typing a real "0" in co-op fields (base game maps 0 -> o) ---
wrap(G.FUNCS, 'text_input_key', function(orig, args)
    local hook = G.CONTROLLER and G.CONTROLLER.text_input_hook
    local fix = args and args.key == '0' and hook and hook.config and hook.config.ref_table and hook.config.ref_table.coop_zero
    local r = orig(args)
    if fix then
        pcall(function()
            local t = hook.config.ref_table.text
            local pos = t.current_position
            if t.letters[pos] == 'o' or t.letters[pos] == 'O' then
                t.letters[pos] = '0'
                local s = ''
                for i = 1, #t.letters do s = s .. (t.letters[i] or '') end
                t.ref_table[t.ref_value] = s
            end
        end)
    end
    return r
end)

-- Run lifecycle --------------------------------------------------------------
wrap(Game, 'start_run', function(orig, self, args)
    orig(self, args)
    if COOP.active and COOP.run then
        local ok, err = pcall(COOP.apply_run_mods, args and args.savetext ~= nil)
        if not ok then COOP.log('apply_run_mods failed: ' .. tostring(err)) end
    end
end)

wrap(G.FUNCS, 'start_run', function(orig, e, args)
    if COOP.active and not COOP.starting then
        -- player started a normal run (e.g. from the game over screen): leave the co-op session
        COOP.leave()
    end
    return orig(e, args)
end)

wrap(Game, 'main_menu', function(orig, self, change_context)
    if COOP.connected() then COOP.leave() end
    return orig(self, change_context)
end)

-- Turn handling: decide what happens after a hand was played ------------------
wrap(Game, 'update_hand_played', function(orig, self, dt)
    if not COOP.active or not COOP.run then return orig(self, dt) end
    if self.buttons then self.buttons:remove(); self.buttons = nil end
    if self.shop then self.shop:remove(); self.shop = nil end
    if not G.STATE_COMPLETE then
        G.STATE_COMPLETE = true
        G.E_MANAGER:add_event(Event({
            trigger = 'immediate',
            func = function()
                if G.GAME.chips - G.GAME.blind.chips >= 0 then
                    G.STATE = G.STATES.NEW_ROUND
                elseif G.GAME.current_round.hands_left < 1 then
                    -- out of hands: refill and hand the turn to the next player
                    G.STATE = G.STATES.DRAW_TO_HAND
                    if COOP.is_my_turn() then COOP.turn_over() end
                else
                    G.STATE = G.STATES.DRAW_TO_HAND
                end
                G.STATE_COMPLETE = false
                return true
            end
        }))
    end
end)

-- Only the active player may play/discard ------------------------------------
wrap(G.FUNCS, 'can_play', function(orig, e)
    orig(e)
    if COOP.active and not COOP.is_my_turn() then
        e.config.colour = G.C.UI.BACKGROUND_INACTIVE
        e.config.button = nil
    end
end)

wrap(G.FUNCS, 'can_discard', function(orig, e)
    orig(e)
    if COOP.active and not COOP.is_my_turn() then
        e.config.colour = G.C.UI.BACKGROUND_INACTIVE
        e.config.button = nil
    end
end)

wrap(G.FUNCS, 'play_cards_from_highlighted', function(orig, e)
    if COOP.active and not COOP.is_my_turn() then return end
    return orig(e)
end)

wrap(G.FUNCS, 'discard_cards_from_highlighted', function(orig, e, hook)
    if COOP.active and not COOP.is_my_turn() then return end
    return orig(e, hook)
end)

wrap(CardArea, 'can_highlight', function(orig, self, card)
    if self.coop_spectate then return false end
    return orig(self, card)
end)

-- Blind selection is a vote ---------------------------------------------------
wrap(G.FUNCS, 'select_blind', function(orig, e)
    if COOP.active and not COOP.executing then
        COOP.vote('select')
        return
    end
    return orig(e)
end)

wrap(G.FUNCS, 'skip_blind', function(orig, e)
    if COOP.active and not COOP.executing then
        COOP.vote('skip')
        return
    end
    return orig(e)
end)

-- Leaving the shop requires everyone to be ready --------------------------------
wrap(G.FUNCS, 'toggle_shop', function(orig, e)
    if COOP.active and not COOP.executing then
        COOP.ready_for_next_round()
        return
    end
    return orig(e)
end)

-- Shared shop ------------------------------------------------------------------
wrap(G.UIDEF, 'shop', function(orig)
    local t = orig()
    if COOP.active then pcall(shop.on_shop_created) end
    return t
end)

wrap(G.FUNCS, 'reroll_shop', function(orig, e)
    if COOP.active and not COOP.is_host() and not COOP.executing then
        COOP.send_to_host({ t = 'reroll' })
        return
    end
    return orig(e)
end)

wrap(G.FUNCS, 'buy_from_shop', function(orig, e)
    if COOP.active and not COOP.is_host() and not COOP.executing then
        local card = e and e.config and e.config.ref_table
        if card and shop.is_shop_area(card.area) then
            shop.client_request_buy(card, false, e.config.id == 'buy_and_use')
            return
        end
    end
    return orig(e)
end)

wrap(G.FUNCS, 'use_card', function(orig, e, mute, nosave)
    if COOP.active and not COOP.is_host() and not COOP.executing then
        local card = e and e.config and e.config.ref_table
        if card and card.area and shop.is_shop_area(card.area) then
            shop.client_request_buy(card, true, false)
            return
        end
    end
    return orig(e, mute, nosave)
end)

local function gate_pending(orig, e)
    orig(e)
    local card = e and e.config and e.config.ref_table
    if COOP.active and card and shop.is_shop_area(card.area) then
        if card.coop_pending_buy or (not COOP.is_host() and not card.coop_uid) then
            e.config.colour = G.C.UI.BACKGROUND_INACTIVE
            e.config.button = nil
        end
    end
end
wrap(G.FUNCS, 'can_buy', gate_pending)
wrap(G.FUNCS, 'can_buy_and_use', gate_pending)
wrap(G.FUNCS, 'can_open', gate_pending)
wrap(G.FUNCS, 'can_redeem', gate_pending)

-- Shared wallet ----------------------------------------------------------------
wrap(_G, 'ease_dollars', function(orig, mod, instant)
    orig(mod, instant)
    if COOP.active then
        local ok, err = pcall(COOP.on_local_dollars, mod)
        if not ok then COOP.log('dollar sync failed: ' .. tostring(err)) end
    end
end)

-- Boss / tag sync after cash out ------------------------------------------------
wrap(G.FUNCS, 'cash_out', function(orig, e)
    orig(e)
    if COOP.active then
        if COOP.is_host() then
            COOP.broadcast_blinds()
        else
            pcall(COOP.apply_remote_blinds)
        end
    end
end)

COOP.log('hooks installed')
