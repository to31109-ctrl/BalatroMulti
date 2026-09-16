-- BalatroCoop UI: main-menu button, lobby screens, in-run HUD panel, toasts.
local ui = {}
COOP.ui = ui

ui.screen = nil
ui.vars = { status = '', deck = '', stake = '', order = '', title = '', code = '', code_hint = '', slots = { { t = '' }, { t = '' }, { t = '' }, { t = '' } } }
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
    -- plain text rows created this way end up misplaced until the box is laid out a second time
    if G.OVERLAY_MENU then G.OVERLAY_MENU:recalculate() end
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
        row({ text('Keep the same name: saved co-op runs are matched to players by name.', 0.25, G.C.ORANGE) }),
        row({ UIBox_button({ button = 'coop_host_click', label = { 'HOST NEW RUN' }, colour = G.C.BLUE, minw = 5, minh = 0.9 }) }),
        row({ UIBox_button({ button = 'coop_load_click', label = { 'LOAD SAVED RUN' }, colour = G.C.ORANGE, minw = 5, minh = 0.9 }) }),
        row({ UIBox_button({ button = 'coop_join_click', label = { 'JOIN GAME' }, colour = G.C.GREEN, minw = 5, minh = 0.9 }) }),
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
    local meta = COOP.load_meta
    local settings
    if meta then
        settings = {
            row({ text('LOADING SAVED RUN', 0.4, G.C.ORANGE) }),
            row({ text('Ante ' .. tostring(meta.ante) .. ', round ' .. tostring(meta.round) .. ', ' .. tostring(meta.deck) .. ', saved ' .. tostring(meta.saved_at), 0.3, G.C.WHITE) }),
            row({ text('Required players (same names!): ' .. table.concat(meta.players or {}, ', '), 0.3, G.C.GOLD) }),
        }
    else
        settings = {
            row({
                { n = G.UIT.C, config = { align = 'cm', minw = 1.6 }, nodes = { text('Deck', 0.35, G.C.WHITE) } },
                create_option_cycle({ options = decks, current_option = deck_idx, opt_callback = 'coop_change_deck', w = 4.5, colour = G.C.RED, scale = 0.8 }),
            }, { padding = 0.02 }),
            row({
                { n = G.UIT.C, config = { align = 'cm', minw = 1.6 }, nodes = { text('Stake', 0.35, G.C.WHITE) } },
                create_option_cycle({ options = stakes, current_option = COOP.lobby.stake or 1, opt_callback = 'coop_change_stake', w = 4.5, colour = G.C.RED, scale = 0.8 }),
            }, { padding = 0.02 }),
            row({
                { n = G.UIT.C, config = { align = 'cm', minw = 1.6 }, nodes = { text('Turns', 0.35, G.C.WHITE) } },
                create_option_cycle({ options = ORDER_OPTIONS, current_option = order_idx, opt_callback = 'coop_change_order', w = 4.5, colour = G.C.RED, scale = 0.8 }),
            }, { padding = 0.02 }),
        }
    end
    local contents = {
        row({ text(meta and 'HOSTING A SAVED CO-OP RUN' or 'HOSTING A CO-OP RUN', 0.5, G.C.GOLD) }, { padding = 0.02 }),
        row({
            text('JOIN CODE: ', 0.45, G.C.WHITE), text(nil, 0.6, G.C.GOLD, ui.vars, 'code'),
            { n = G.UIT.C, config = { align = 'cm', minw = 0.3 }, nodes = {} },
            UIBox_button({ button = 'coop_copy_code', label = { 'COPY' }, colour = G.C.BLUE, minw = 1.3, minh = 0.6, scale = 0.35, col = true }),
        }, { padding = 0.02 }),
        row({ text(nil, 0.25, G.C.UI.TEXT_LIGHT, ui.vars, 'code_hint') }, { padding = 0.02 }),
        row({ text(nil, 0.25, G.C.UI.TEXT_LIGHT, ui.vars, 'status') }, { padding = 0.02 }),
    }
    for _, r in ipairs(settings) do contents[#contents + 1] = r end
    contents[#contents + 1] = row({ text('Players', 0.4, G.C.GOLD) }, { padding = 0.02 })
    contents[#contents + 1] = row(player_rows(), { align = 'cm', colour = G.C.L_BLACK, r = 0.1, padding = 0.05 })
    contents[#contents + 1] = row({ UIBox_button({ button = 'coop_start_click', label = { meta and 'CONTINUE RUN' or 'START RUN' }, colour = G.C.GREEN, minw = 5, minh = 0.9 }) }, { padding = 0.02 })
    overlay(contents, 'coop_leave_click')
end

function ui.open_load_list()
    ui.screen = 'load'
    local list = COOP.saves.list()
    local rows = {}
    rows[#rows + 1] = row({ text('LOAD A SAVED CO-OP RUN', 0.55, G.C.GOLD) })
    rows[#rows + 1] = row({ text('Only the host loads a run. Everyone else joins with the code, using the same name as before.', 0.27, G.C.UI.TEXT_LIGHT) })
    if #list == 0 then
        rows[#rows + 1] = row({ text('No saved co-op runs yet. Runs save automatically at every shop and blind select.', 0.32, G.C.WHITE) })
    end
    for i, meta in ipairs(list) do
        if i > 8 then break end
        local label1 = tostring(meta.saved_at) .. '   Ante ' .. tostring(meta.ante) .. '  Round ' .. tostring(meta.round) .. '   ' .. tostring(meta.deck) .. (meta.mid_blind and '   (mid-blind)' or '')
        local label2 = 'Players: ' .. table.concat(meta.players or {}, ', ')
        rows[#rows + 1] = row({
            UIBox_button({ button = 'coop_pick_save', label = { label1, label2 }, colour = COOP.saves.has_player_file(meta.sid, COOP.cfg.name) and G.C.BLUE or G.C.UI.BACKGROUND_INACTIVE, minw = 8, minh = 0.9, scale = 0.32, ref_table = meta }),
            UIBox_button({ button = 'coop_delete_save', label = { 'X' }, colour = G.C.RED, minw = 0.6, minh = 0.9, scale = 0.4, ref_table = meta, col = true }),
        }, { padding = 0.03 })
    end
    overlay(rows, 'coop_back_to_main')
end

function ui.open_join()
    ui.screen = 'join'
    overlay({
        row({ text('JOIN A CO-OP RUN', 0.6, G.C.GOLD) }),
        row({ text('Type the JOIN CODE the host sees in their lobby (or an IP address).', 0.27, G.C.UI.TEXT_LIGHT) }),
        row({
            { n = G.UIT.C, config = { align = 'cm', minw = 2 }, nodes = { text('Code / IP', 0.4, G.C.WHITE) } },
            create_text_input({ w = 4.5, max_length = 24, prompt_text = 'Join code', ref_table = COOP.cfg, ref_value = 'ip', extended_corpus = true, coop_zero = true }),
            { n = G.UIT.C, config = { align = 'cm', minw = 0.2 }, nodes = {} },
            UIBox_button({ button = 'coop_paste_code', label = { 'PASTE' }, colour = G.C.BLUE, minw = 1.4, minh = 0.6, scale = 0.35, col = true }),
        }),
        row({
            { n = G.UIT.C, config = { align = 'cm', minw = 2 }, nodes = { text('Port', 0.4, G.C.WHITE) } },
            create_text_input({ w = 2.5, max_length = 5, prompt_text = 'Port', ref_table = COOP.cfg, ref_value = 'port', extended_corpus = true, coop_zero = true }),
            text('  (only used with an IP address)', 0.25, G.C.UI.TEXT_LIGHT),
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
    COOP.load_meta = nil
    local ok = COOP.start_host(COOP.cfg.port)
    if ok then
        ui.open_host_lobby()
    end
end

G.FUNCS.coop_load_click = function(e)
    COOP.save_config()
    ui.open_load_list()
end

G.FUNCS.coop_pick_save = function(e)
    local meta = e.config.ref_table
    if not meta then return end
    if not COOP.saves.has_player_file(meta.sid, COOP.cfg.name) then
        COOP.toast('Your name "' .. COOP.cfg.name .. '" is not part of this save (players: ' .. table.concat(meta.players or {}, ', ') .. ')', G.C.RED, 5)
        return
    end
    COOP.save_config()
    local ok = COOP.start_host(COOP.cfg.port)
    if ok then
        COOP.load_meta = meta
        COOP.lobby.deck = meta.deck or COOP.lobby.deck
        COOP.lobby.stake = meta.stake or COOP.lobby.stake
        COOP.lobby.turn_order = meta.turn_order or COOP.lobby.turn_order
        COOP.broadcast_lobby()
        ui.open_host_lobby()
    end
end

G.FUNCS.coop_delete_save = function(e)
    local meta = e.config.ref_table
    if meta then COOP.saves.delete(meta.sid) end
    ui.open_load_list()
end

G.FUNCS.coop_copy_code = function(e)
    local hi = COOP.host_info
    local code = hi and (hi.code or hi.lan_code)
    if not code then return end
    local ok = pcall(love.system.setClipboardText, code)
    COOP.toast(ok and ('Copied ' .. code .. ' to clipboard') or 'Could not access the clipboard', G.C.GREEN, 2)
    pcall(play_sound, 'button')
end

G.FUNCS.coop_paste_code = function(e)
    local ok, clip = pcall(love.system.getClipboardText)
    clip = ok and tostring(clip or '') or ''
    clip = clip:gsub('^%s+', ''):gsub('%s+$', '')
    if clip == '' then
        COOP.toast('Clipboard is empty', G.C.RED, 2)
        return
    end
    -- keep only the first token (a code or an IP[:port])
    clip = clip:match('^(%S+)') or clip
    local host, port = clip:match('^([%d%.]+):(%d+)$')
    if host and port then
        COOP.cfg.ip, COOP.cfg.port = host, port
    else
        COOP.cfg.ip = clip:sub(1, 24)
    end
    COOP.save_config()
    ui.open_join() -- rebuild so the text box shows the pasted value
    COOP.toast('Pasted ' .. COOP.cfg.ip, G.C.GREEN, 2)
end

G.FUNCS.coop_save_click = function(e)
    if not COOP.active then return end
    if not COOP.is_host() then
        COOP.toast('Only the host can save the run', G.C.RED, 2)
        return
    end
    COOP.send_to_host({ t = 'save_req' })
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
        definition = { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.06, r = 0.1, colour = G.C.UI.TRANSPARENT_DARK, minw = 2.5, maxw = 2.5 }, nodes = rows },
        config = { align = 'cri', offset = { x = 1.15, y = -1.0 }, major = G.ROOM_ATTACH, bond = 'Weak' },
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
            local rtt = COOP.rtt_of and COOP.rtt_of(p.id)
            if rtt and p.id ~= 1 then tag = tag .. ' ' .. tostring(rtt) .. 'ms' end
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
    local hi = COOP.host_info
    if hi then
        ui.vars.code = hi.code or hi.lan_code or '?'
        if hi.code and not hi.upnp_error then
            ui.vars.code_hint = 'Works over the internet. Same-network friends can also use LAN code ' .. tostring(hi.lan_code) .. ' (IP ' .. tostring(hi.lan_ip) .. ':' .. tostring(hi.port) .. ')'
        else
            ui.vars.code_hint = 'LAN code: ' .. tostring(hi.lan_code) .. ' (IP ' .. tostring(hi.lan_ip) .. ':' .. tostring(hi.port) .. ')'
        end
    end
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
