-- BalatroCoop UI: main-menu button, lobby screens, in-run HUD panel, toasts.
local ui = {}
COOP.ui = ui

ui.screen = nil
ui.vars = { status = '', deck = '', stake = '', order = '', title = '', slots = { { t = '' }, { t = '' }, { t = '' }, { t = '' } } }
ui.hud = nil
ui.hud_vars = { info = { t = '' } }
for i = 1, COOP.MAX_PLAYERS do
    ui.hud_vars[i] = { name = '', status = '', colour = { 1, 1, 1, 1 } }
end
ui.toasts = {}

local function deck_names()
    local names = {}
    for _, v in ipairs(G.P_CENTER_POOLS.Back) do names[#names + 1] = v.name end
    return names
end

local function stake_names()
    local names = {}
    for _, v in ipairs(G.P_CENTER_POOLS.Stake) do
        local ok, loc = pcall(localize, { type = 'name_text', set = 'Stake', key = v.key })
        names[#names + 1] = (ok and type(loc) == 'string' and loc ~= 'ERROR') and loc or (v.name or ('Stake ' .. #names + 1))
    end
    if #names == 0 then for i = 1, 8 do names[i] = 'Stake ' .. i end end
    return names
end

local ORDER_OPTIONS = { 'Rotate first player', 'Fixed order' }

local function text(t, scale, colour, ref, key)
    if ref then
        return { n = G.UIT.T, config = { ref_table = ref, ref_value = key, scale = scale or 0.4, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true } }
    end
    return { n = G.UIT.T, config = { text = t, scale = scale or 0.4, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true } }
end

local function row(nodes, cfg)
    cfg = cfg or {}
    cfg.align = cfg.align or 'cm'
    cfg.padding = cfg.padding or 0.05
    return { n = G.UIT.R, config = cfg, nodes = nodes }
end

local function player_rows()
    local rows = {}
    for i = 1, COOP.MAX_PLAYERS do
        rows[#rows + 1] = row({ text(nil, 0.4, G.C.WHITE, ui.vars.slots[i], 't') }, { align = 'cl', minw = 5 })
    end
    return rows
end

local function overlay(contents, back_func)
    G.FUNCS.overlay_menu({
        definition = create_UIBox_generic_options({ back_func = back_func or 'exit_overlay_menu', contents = contents }),
    })
end

-- Screens --------------------------------------------------------------------
function ui.open_main()
    ui.screen = 'main'
    COOP.status = COOP.status ~= '' and COOP.status or ('Version ' .. COOP.VERSION)
    ui.name_input = { }
    overlay({
        row({ text('BALATRO CO-OP', 0.7, G.C.GOLD) }),
        row({ text('Play one run together: shared money, shared shop, turn-based blinds.', 0.3, G.C.UI.TEXT_LIGHT) }),
        row({
            text('Your name: ', 0.4, G.C.WHITE),
            create_text_input({ w = 4, max_length = 16, prompt_text = 'Name', ref_table = COOP.cfg, ref_value = 'name', extended_corpus = true, coop_zero = true }),
        }),
        row({ UIBox_button({ button = 'coop_host_click', label = { 'HOST GAME' }, colour = G.C.BLUE, minw = 5, minh = 1 }) }),
        row({ UIBox_button({ button = 'coop_join_click', label = { 'JOIN GAME' }, colour = G.C.GREEN, minw = 5, minh = 1 }) }),
        row({ text(nil, 0.3, G.C.UI.TEXT_LIGHT, ui.vars, 'status') }),
    }, 'coop_close')
end

function ui.open_host_lobby()
    ui.screen = 'host'
    local decks = deck_names()
    local deck_idx = 1
    for i, n in ipairs(decks) do if n == COOP.lobby.deck then deck_idx = i end end
    local stakes = stake_names()
    local order_idx = COOP.lobby.turn_order == 'fixed' and 2 or 1
    overlay({
        row({ text('HOSTING A CO-OP RUN', 0.6, G.C.GOLD) }),
        row({ text(nil, 0.32, G.C.UI.TEXT_LIGHT, ui.vars, 'status') }),
        row({ text('Friends join with your IP (LAN, Hamachi/Radmin/Tailscale, or a forwarded port).', 0.27, G.C.UI.TEXT_LIGHT) }),
        row({
            { n = G.UIT.C, config = { align = 'cm', minw = 2 }, nodes = { text('Deck', 0.4, G.C.WHITE) } },
            create_option_cycle({ options = decks, current_option = deck_idx, opt_callback = 'coop_change_deck', w = 4.5, colour = G.C.RED }),
        }),
        row({
            { n = G.UIT.C, config = { align = 'cm', minw = 2 }, nodes = { text('Stake', 0.4, G.C.WHITE) } },
            create_option_cycle({ options = stakes, current_option = COOP.lobby.stake or 1, opt_callback = 'coop_change_stake', w = 4.5, colour = G.C.RED }),
        }),
        row({
            { n = G.UIT.C, config = { align = 'cm', minw = 2 }, nodes = { text('Turns', 0.4, G.C.WHITE) } },
            create_option_cycle({ options = ORDER_OPTIONS, current_option = order_idx, opt_callback = 'coop_change_order', w = 4.5, colour = G.C.RED }),
        }),
        row({ text('Players', 0.45, G.C.GOLD) }),
        row(player_rows(), { align = 'cm', colour = G.C.L_BLACK, r = 0.1, padding = 0.1 }),
        row({ UIBox_button({ button = 'coop_start_click', label = { 'START RUN' }, colour = G.C.GREEN, minw = 5, minh = 1 }) }),
    }, 'coop_leave_click')
end

function ui.open_join()
    ui.screen = 'join'
    overlay({
        row({ text('JOIN A CO-OP RUN', 0.6, G.C.GOLD) }),
        row({ text('Ask the host for their IP address. Type O for zero if needed, it is converted.', 0.27, G.C.UI.TEXT_LIGHT) }),
        row({
            { n = G.UIT.C, config = { align = 'cm', minw = 2 }, nodes = { text('Host IP', 0.4, G.C.WHITE) } },
            create_text_input({ w = 4.5, max_length = 24, prompt_text = 'IP address', ref_table = COOP.cfg, ref_value = 'ip', extended_corpus = true, coop_zero = true }),
        }),
        row({
            { n = G.UIT.C, config = { align = 'cm', minw = 2 }, nodes = { text('Port', 0.4, G.C.WHITE) } },
            create_text_input({ w = 2.5, max_length = 5, prompt_text = 'Port', ref_table = COOP.cfg, ref_value = 'port', extended_corpus = true, coop_zero = true }),
        }),
        row({ UIBox_button({ button = 'coop_connect_click', label = { 'CONNECT' }, colour = G.C.GREEN, minw = 5, minh = 1 }) }),
        row({ text(nil, 0.3, G.C.UI.TEXT_LIGHT, ui.vars, 'status') }),
    }, 'coop_back_to_main')
end

function ui.open_client_lobby()
    ui.screen = 'client'
    overlay({
        row({ text('CO-OP LOBBY', 0.6, G.C.GOLD) }),
        row({ text(nil, 0.32, G.C.UI.TEXT_LIGHT, ui.vars, 'status') }),
        row({ text(nil, 0.35, G.C.WHITE, ui.vars, 'deck') }),
        row({ text(nil, 0.35, G.C.WHITE, ui.vars, 'stake') }),
        row({ text(nil, 0.35, G.C.WHITE, ui.vars, 'order') }),
        row({ text('Players', 0.45, G.C.GOLD) }),
        row(player_rows(), { align = 'cm', colour = G.C.L_BLACK, r = 0.1, padding = 0.1 }),
        row({ text('Waiting for the host to start the run...', 0.32, G.C.UI.TEXT_LIGHT) }),
    }, 'coop_leave_click')
end

function ui.on_disconnected()
    if ui.screen == 'client' and G.STAGE == G.STAGES.MAIN_MENU then
        ui.open_main()
    end
end

-- Button callbacks -----------------------------------------------------------
G.FUNCS.coop_menu = function(e)
    G.SETTINGS.paused = true
    ui.open_main()
end

G.FUNCS.coop_close = function(e)
    COOP.save_config()
    if COOP.connected() and not COOP.active then COOP.leave() end
    ui.screen = nil
    G.FUNCS.exit_overlay_menu()
end

G.FUNCS.coop_back_to_main = function(e)
    COOP.save_config()
    ui.open_main()
end

G.FUNCS.coop_host_click = function(e)
    COOP.save_config()
    local ok = COOP.start_host(COOP.cfg.port)
    if ok then
        ui.open_host_lobby()
    end
end

G.FUNCS.coop_join_click = function(e)
    COOP.save_config()
    ui.open_join()
end

G.FUNCS.coop_connect_click = function(e)
    COOP.save_config()
    local ok = COOP.join(COOP.cfg.ip, COOP.cfg.port)
    if ok then ui.open_client_lobby() end
end

G.FUNCS.coop_leave_click = function(e)
    COOP.leave()
    ui.open_main()
end

G.FUNCS.coop_start_click = function(e)
    if COOP.mode ~= 'host' then return end
    COOP.host_start_game()
end

G.FUNCS.coop_change_deck = function(args)
    COOP.lobby.deck = args.to_val
    COOP.broadcast_lobby()
end

G.FUNCS.coop_change_stake = function(args)
    COOP.lobby.stake = args.to_key
    COOP.broadcast_lobby()
end

G.FUNCS.coop_change_order = function(args)
    COOP.lobby.turn_order = (args.to_key == 2) and 'fixed' or 'rotate'
    COOP.broadcast_lobby()
end

-- In-run HUD panel ------------------------------------------------------------
function ui.ensure_hud()
    if ui.hud or not G.HUD or G.STAGE ~= G.STAGES.RUN then return end
    local rows = {}
    rows[#rows + 1] = row({ text('CO-OP', 0.35, G.C.GOLD) })
    for i = 1, COOP.MAX_PLAYERS do
        rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cl', padding = 0.01 }, nodes = {
            { n = G.UIT.T, config = { ref_table = ui.hud_vars[i], ref_value = 'name', scale = 0.3, colour = ui.hud_vars[i].colour, shadow = true } },
        } }
        rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cl', padding = 0.01 }, nodes = {
            { n = G.UIT.T, config = { ref_table = ui.hud_vars[i], ref_value = 'status', scale = 0.24, colour = G.C.UI.TEXT_LIGHT } },
        } }
    end
    rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
        { n = G.UIT.T, config = { ref_table = ui.hud_vars.info, ref_value = 't', scale = 0.24, colour = G.C.GOLD } },
    } }
    ui.hud = UIBox({
        definition = { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.08, r = 0.1, colour = G.C.UI.TRANSPARENT_DARK, minw = 2.7, maxw = 2.7 }, nodes = rows },
        config = { align = 'cri', offset = { x = -0.1, y = -0.8 }, major = G.ROOM_ATTACH, bond = 'Weak' },
    })
end

function ui.remove_hud()
    if ui.hud then
        pcall(ui.hud.remove, ui.hud)
        ui.hud = nil
    end
end

local function set_colour(c, r, g, b)
    c[1], c[2], c[3], c[4] = r, g, b, 1
end

function ui.refresh_hud()
    local run = COOP.run
    local st = G.STATE
    local in_blind_select = st == G.STATES.BLIND_SELECT
    local in_shop = st == G.STATES.SHOP or st == G.STATES.TAROT_PACK or st == G.STATES.PLANET_PACK
        or st == G.STATES.SPECTRAL_PACK or st == G.STATES.STANDARD_PACK or st == G.STATES.BUFFOON_PACK
    local info = ''
    for i = 1, COOP.MAX_PLAYERS do
        local p = COOP.players[i]
        local v = ui.hud_vars[i]
        if not p or not run then
            v.name, v.status = '', ''
        else
            local tag = (p.id == COOP.me.id) and ' (you)' or ''
            if p.id == 1 then tag = tag .. ' [host]' end
            v.name = p.name .. tag
            set_colour(v.colour, 1, 1, 1)
            if run.round_active then
                if run.turn.active == p.id then
                    v.status = '>> PLAYING'
                    set_colour(v.colour, 0.3, 1, 0.4)
                else
                    local pos = nil
                    for k, id in ipairs(run.turn.order) do if id == p.id then pos = k end end
                    if pos and pos < (run.turn.idx or 1) then v.status = 'done'
                    elseif pos then v.status = 'up next #' .. (pos - (run.turn.idx or 1))
                    else v.status = 'waiting' end
                end
            elseif in_blind_select then
                local vt = run.votes[p.id]
                v.status = vt == 'select' and 'voted PLAY' or vt == 'skip' and 'voted SKIP' or 'voting...'
            elseif in_shop then
                v.status = run.ready[p.id] and 'READY' or 'shopping'
            else
                v.status = ''
            end
        end
    end
    if run then
        if run.round_active then
            if COOP.is_my_turn() then info = 'Your turn: play your hands!'
            elseif run.turn.active then info = 'Watching ' .. COOP.player_name(run.turn.active)
            else info = 'Waiting...' end
        elseif in_blind_select then
            info = 'Everyone votes: play or skip'
        elseif in_shop then
            info = 'Press Next Round when ready'
        elseif st == G.STATES.SELECTING_HAND then
            info = 'Waiting for all players...'
        end
    end
    ui.hud_vars.info.t = info
end

-- Toasts ---------------------------------------------------------------------
function ui.toast(msg, colour, hold)
    if not G.ROOM_ATTACH or not attention_text then return end
    attention_text({
        text = tostring(msg), scale = 0.55, hold = hold or 2, colour = colour or G.C.WHITE,
        backdrop_colour = G.C.BLACK, align = 'tm', offset = { x = 0, y = 1.6 }, major = G.ROOM_ATTACH,
    })
end

-- Per frame ------------------------------------------------------------------
local function lobby_vars()
    ui.vars.status = COOP.status or ''
    ui.vars.deck = 'Deck: ' .. tostring(COOP.lobby.deck)
    local stakes = stake_names()
    ui.vars.stake = 'Stake: ' .. tostring(stakes[COOP.lobby.stake or 1] or COOP.lobby.stake)
    ui.vars.order = 'Turn order: ' .. ((COOP.lobby.turn_order == 'fixed') and 'fixed' or 'rotating')
    for i = 1, COOP.MAX_PLAYERS do
        local p = COOP.players[i]
        if p then
            local tag = ''
            if p.id == 1 then tag = tag .. ' [host]' end
            if p.id == COOP.me.id then tag = tag .. ' (you)' end
            ui.vars.slots[i].t = i .. '. ' .. p.name .. tag
        else
            ui.vars.slots[i].t = i .. '. (empty)'
        end
    end
end

function ui.update(dt)
    if G.STAGE == G.STAGES.MAIN_MENU then
        lobby_vars()
        if ui.hud then ui.remove_hud() end
    elseif COOP.active and G.STAGE == G.STAGES.RUN then
        ui.ensure_hud()
        ui.refresh_hud()
    elseif ui.hud then
        ui.remove_hud()
    end
    -- remote cursor hook, installed once G.CURSOR exists
    if G.CURSOR and not G.CURSOR.coop_hooked then
        G.CURSOR.coop_hooked = true
        local orig_draw = G.CURSOR.draw
        G.CURSOR.draw = function(self, ...)
            orig_draw(self, ...)
            if COOP.spectate and COOP.spectate.target then
                local ok, err = pcall(COOP.spectate.draw_remote_cursor)
                if not ok and not ui.cursor_err_logged then
                    ui.cursor_err_logged = true
                    COOP.log('remote cursor draw failed: ' .. tostring(err))
                end
            end
        end
    end
end
