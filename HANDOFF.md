# Balatro Co-op — HANDOFF

Read this first in any new session. Keep it current: add PLANNED / BUILT / RELEASED entries as work happens.

## Standing orders from the owner (to31109-ctrl)
1. **Publish means: bump `version.txt` AND `mod/version.txt` (same number), commit, push to `main`.** Friends' launchers update from raw GitHub `version.txt`; without a bump nobody gets anything.
2. **No port forwarding, no money, nothing running on the owner's PC besides the game.** Hosting must work through join codes.
3. **Names are identities.** Saves are matched by player name; never change how names are stored without a migration.
4. **Diagnose from logs, not theory.** `%APPDATA%\Balatro\coop_players.log` on the host has every player's log lines, stats, stalls and crashes. Ask for it before guessing.
5. **Never test on the owner's live session** (killing instances kills their run). Test with the debug harness described below.
6. **NEVER delete or rewrite `%APPDATA%\Balatro\coop_saves` on the owner's PC.** It holds the owner's real runs with their friend (players Whoppa + Nigber). Test with the names TestHost/TestBuddy and remove only the session folders those tests created (compare the folder list before/after). Never change the save format without a loader for the old one.
7. The game copy here is a non-Steam build. `steam_api64.dll` was once removed by antivirus; the owner restores it themselves. Do not touch DRM files.

## What this is
A Balatro mod (Lua, loaded by the Lovely injector, no Steamodded) for 2–4 friends playing ONE shared run:
turn-based blinds, shared wallet and shop, spectating, votes, join codes, save/load, auto-updating launcher, optional Cloudflare relay.

Repo: https://github.com/to31109-ctrl/BalatroMulti  (this folder, `D:\Balatro\Balatro\BalatroMulti`)
Game: `D:\Balatro\Balatro\Balatro.exe` (1.0.1o). Extracted game source for reference lives in the session scratchpad only; re-extract with `unzip Balatro.exe` if needed.
Dev link: `%APPDATA%\Balatro\Mods\BalatroCoop` is a junction to `mod/` (edits are live on next game start; the launcher never overwrites a junction).
Owner's shortcut: `D:\Balatro\Balatro\Balatro Co-op.lnk` (runs `%LOCALAPPDATA%\BalatroCoop\BalatroCoop.ps1`).
Friends: send `launcher/Install-BalatroCoop.bat` (run once; it creates a desktop shortcut that updates + launches).

## Layout
```
mod/                     the mod (installed to %APPDATA%\Balatro\Mods\BalatroCoop)
  lovely.toml            appends bootstrap.lua to main.lua
  bootstrap.lua          loads mod/src/init.lua from disk (no backslashes in this file: Lovely mangles them)
  relay.txt              relay address (ws://balatro-coop-relay.balatro-coop-relay.workers.dev/ws)
  version.txt            must equal ../version.txt
  src/init.lua           module load order
  src/net.lua            luasocket TCP host/client, newline-delimited JSON, non-blocking
  src/ws.lua             WebSocket client over luasocket (ws:// only, no TLS)
  src/relay.lua          relay transport with the same interface as net.lua (virtual conns per client)
  src/upnp.lua           SSDP + SOAP AddPortMapping (raw HTTP; socket.http fails on some routers), join codes
  src/core.lua           lobby, players, messages, run start, turns, votes, wallet, ping/stats/log forwarding, crash capture
  src/shop.lua           shared shop (host authoritative, clients mirror by uid)
  src/spectate.lua       active player streams hand/play/jokers/consumables/HUD/cursor; spectators mirror
  src/saves.lua          per-player vanilla-style saves + meta.json; mid-blind turn restore
  src/ui.lua             CO-OP menu, lobbies, load list, HUD panel, toasts, copy/paste
  src/hooks.lua          all wraps of base-game functions
  src/debug.lua          test harness (only with BALATRO_COOP_DEBUG env)
  src/json.lua, log.lua
launcher/BalatroCoop.ps1        install/update/launch (finds game via picker, installs Lovely, firewall rule)
launcher/Install-BalatroCoop.bat one-file installer for friends
relay/worker.js + wrangler.toml  Cloudflare Worker + Durable Object relay (deployed on the owner's free account)
```

## How it works (short)
- Every player runs their own full Balatro run (own deck/hand/jokers). The host is authoritative for: shop contents, wallet, blind votes, turn order, boss/tag choice, ready-to-leave-shop.
- Blind chips ×players (`starting_params.ante_scaling`), wallet ×players at start, shop slots and packs ×players.
- Turns: everyone reports `phase blind_ready` after drawing; host sends `turn`; active player plays until hands run out (`Game:update_hand_played` override → `turn_done`) or wins (`round_won`); host sends `round_result`; everyone goes NEW_ROUND → end_round (shared team chips decide win/lose).
- Wallet: clients send `dollars {delta}`, host applies, broadcasts `wallet`; client defers the host value until its own +$ animation ran (event ordering bug fixed 1.2.x).
- Shop: host broadcasts full shop when its signature changes (debounced); clients reconcile cards by uid; purchases are `buy` requests validated by host (`buy_ok` sets card.cost=0 locally so no double charge).
- Spectate: parts hand/play/jokers/cons/hud sent when their JSON changes (≤ ~7 KB per hand); mirror CardAreas with `coop_spectate` flag; cursor at ~8/s.
- Saves: auto at shop (once populated) and blind select, re-saved on changes; manual from Escape menu (`save_req` → `do_save` with turn meta). Load: host picks run, players join with same names, host `start {load=true}`; mid-blind saves restore active seat/order/chips (`restore_turn`).
- Transports: `auto` (direct via UPnP, relay if the router refuses), `relay`, `direct`. Direct codes are 10 chars (IP+port encoded), relay codes 5 chars.
- Diagnostics: clients forward every log line to host (`rlog`, throttled) → `coop_players.log`; stats every 10 s; ping every 3 s shown in HUD; stalls >100 ms logged with breakdown; window focus changes logged; crashes logged + pushed before the crash screen.

## Verified (all live, two or three game instances on one PC, plus the real Cloudflare relay)
Lobby/join by code (direct + relay), external reachability of the UPnP port from 3 countries, votes + coin flip, turn hand-off (2 and 3 players, rotation), spectating incl. consumables and cursor, shared game-over, win screen + Endless continuing to ante 9, cash-out wallet equality, shop sync/buy/reroll/pack with 2 and 3 players, save/load from shop, blind select and mid-blind (seat, hands, chips restored), per-player seeds with shared boss/tags, copy/paste codes, crash capture, launcher fresh-install and update paths, UPnP retry after stale mapping.

## Known issues / open investigation
- **Friend (Leon-Louid) "super laggy" then game closed (session 2026-09-16 13:47–13:51, over the relay).** Collected logs: his mod overhead ≤ 2 ms/frame, unsent bytes 0, yet his game ran at 2 FPS for ~10 s on his own turn and 12 FPS during scoring, then the socket closed. The host ran 165 FPS. Conclusion so far: stall inside his game/PC (window focus loss / Discord streaming / local), not the mod or the pipe. 1.3.2 added focus-change, frame-spike and crash logging; **next step is one more session on Auto (lobby must say DIRECT) and reading `coop_players.log`.**
- Relay ping from South Africa is ~350–400 ms because Cloudflare Durable Objects are not hosted in Africa (location hint `afr` is ignored). Direct is ~20 ms. Auto prefers direct.
- Mr. Bones / similar "saved" jokers only save the player that owns them → other players would game-over (desync). Not handled.
- Boss reroll vouchers (Director's Cut/Retcon) are not synced.
- Vanilla `Card:save` typo (`highligted`) means highlight must be sent separately (done).
- Cloudflare Workers free plan: 100k requests/day (WebSocket messages are not requests) — fine for a few friends.

## Planned / options discussed
- PLANNED (if logs implicate the main thread): move all socket I/O to a `love.thread` like BalatroMP (`networking/socket.lua` in their repo: channels `uiToNetwork` / `networkToUi`, keepalive + reconnect). Would also give reconnect-on-drop.
- OPTION: relay on a free Johannesburg VM (Oracle Cloud Always Free needs a card for verification; owner declined). Would bring relay ping to ~20 ms. Same protocol as `relay/worker.js`, port to Node/Python.
- OPTION: TURN-style relay via Cloudflare Calls (edge in JNB) — unexplored.
- Nice-to-haves: spectator sees deck count; hide "0/2" counters on hidden own areas; end-turn button; chat.

## Test harness
Launch instances with env vars (Git Bash):
```
BALATRO_COOP_DEBUG=1 BALATRO_COOP_INST=a BALATRO_COOP_AUTO=host BALATRO_COOP_NAME=Whoppa ./Balatro.exe &
BALATRO_COOP_DEBUG=1 BALATRO_COOP_INST=b BALATRO_COOP_AUTO=join BALATRO_COOP_NAME=Buddy ./Balatro.exe &
```
Send Lua to an instance by writing `%APPDATA%\Balatro\coop_cmd_<inst>.lua`; result appears in `coop_out_<inst>.txt` (`/tmp/coopcmd.sh <inst> '<lua>'` helper existed in the original session). Useful calls: `COOP.host_start_game()`, `COOP.vote("select")`, `G.FUNCS.toggle_shop(nil)`, `COOP.shop.client_request_buy(card,false,false)`, `G.GAME.chips = 590` then play 5 cards to force a win, `COOP.saves.list()`.
Screenshots of a specific window: PrintWindow by PID (PowerShell) works without focusing the window.
Syntax check without the game: load `lua51.dll` via Python ctypes and `luaL_loadfile` each file.
Local relay: `cd relay && npm run dev` (ws://127.0.0.1:8787/ws), set `mod/relay.txt` accordingly for tests, restore before publishing.
Gotcha: Bash heredocs in this environment collapse `\\` to `\`; write files with the Write tool or Python.

## Release log
- 1.0.0 core mod + launcher · 1.1.0 UPnP join codes, save/load, firewall rule · 1.1.1 exe picker · 1.1.2 vote/ready guards
- 1.2.0 copy/paste codes, Escape-menu save with mid-blind resume, spectator boxes · 1.2.1 per-player seeds, 12× smaller stream, perf watchdog · 1.2.2 host collects all players' logs, ping, stall detection
- 1.3.4 spectators hear the active player's sound effects (play_sound forwarded, ≤40/s)
- 1.3.0 relay mode (dormant) · 1.3.1 relay deployed, Auto transport · 1.3.2 crash/focus/spike diagnostics · 1.3.3 UPnP retry, connection type shown, lower cursor rate
