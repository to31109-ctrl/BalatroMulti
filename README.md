# Balatro Co-op

A co-operative multiplayer mod for Balatro. One shared run for 2 to 4 friends:

- **Turn-based blinds.** Every blind's chip target is multiplied by the number of players. Players take turns: the active player plays until they run out of hands, then the next player takes over. Everyone's chips add up to one team score.
- **Spectating.** While someone else plays you see their hand, selected cards, played cards, jokers, consumables, remaining hands/discards, the current hand score and even their cursor, live.
- **Shared wallet.** Money is pooled: starting money is `players x normal`, every blind reward is paid once per player, interest is paid once.
- **Shared shop.** The shop has `players x` the normal number of cards and booster packs. Anyone can buy or reroll; the item goes to the buyer and the money leaves the shared wallet. Everyone sees purchases in real time.
- **Voting.** Playing or skipping a blind is a majority vote. A tie is decided by a coin flip. Leaving the shop requires everyone to press *Next Round*.
- **Host picks the deck and stake**, and whether the first player rotates each blind or stays fixed.
- **Shared economy:** shop/economy vouchers and jokers owned by anyone (Overstock, Clearance Sale, Reroll Surplus, Chaos the Clown, Seed Money, Credit Card, Hone/Glow Up, Merchant vouchers) apply to the shared shop and wallet for the whole team.
- **Personal stuff stays personal:** everyone has their own deck, hand, discards, jokers, consumables and vouchers.
- **Relay mode.** A tiny Cloudflare Worker in `relay/` (deployed, address in `mod/relay.txt`) lets anyone host with no router involvement at all. *Hosting via* in the CO-OP menu: **Auto** (default: direct connection through UPnP, relay only if the router refuses), **Relay** (5-letter room code, works anywhere, adds roughly 0.3 s of delay because Cloudflare's rooms are not hosted in Africa), or **Direct** (lowest ping, needs UPnP).
- **Join codes, no port forwarding.** The host's game opens the port on the router automatically (UPnP) and shows a short code like `7B26J-FWNUT`; friends type the code. No Steam networking.
- **Save & load.** Runs save automatically at every shop and blind select, and the host can save at any moment (even mid-boss) from the Escape menu with *Save co-op run*. The host picks *Load saved run*, friends join with the code using the same name as before, and everyone resumes exactly where they were: same seat, remaining hands, team score, deck, jokers, hand levels and vouchers.
- **Copy / paste codes.** A COPY button next to the join code and a PASTE button on the join screen.
- **Auto-updating launcher.** Friends install once; the desktop shortcut checks GitHub for a new version before every launch.

## Install (for players)

1. Download [`launcher/Install-BalatroCoop.bat`](launcher/Install-BalatroCoop.bat) (right click, *Save link as*) and run it.
   It downloads the launcher, installs the [Lovely injector](https://github.com/ethangreen-dev/lovely-injector) next to `Balatro.exe` if missing, installs the mod into `%APPDATA%\Balatro\Mods\BalatroCoop`, and puts a **Balatro Co-op** shortcut on your desktop.
2. Always start the game through that shortcut. It updates the mod and then launches Balatro.
3. In the main menu press **CO-OP**.

The mod does not need Steamodded. If Windows SmartScreen complains about the `.bat`, choose *More info -> Run anyway*.

## Playing

- **Host:** CO-OP -> HOST NEW RUN. Pick deck, stake and turn order. Send your friends the JOIN CODE shown at the top. Press START RUN when everyone is in.
- **Join:** CO-OP -> JOIN GAME, type the code, CONNECT. (An IP address plus port also works, e.g. on a LAN.)
- **Continue a saved run:** the host picks CO-OP -> LOAD SAVED RUN and chooses the run; the same players join with the same names; the host presses CONTINUE RUN.
- **Names matter:** saved runs are matched to players by name, so keep your name the same.
- If the router has UPnP disabled or the ISP uses a shared address (CGNAT), the internet code cannot work; use the LAN code on the same network or a VPN tool such as Hamachi/Radmin/Tailscale/ZeroTier and join by IP.
- Blind select: everybody presses *Select* or *Skip*; majority wins, ties are coin flips.
- During a blind only the active player can play/discard. Others watch.
- Shop: buy freely from the shared wallet; press *Next Round* when done. The round starts when everyone is ready.

All players must run the same mod version; the launcher takes care of that.

## Publishing an update (for the mod owner)

1. Edit files under `mod/`.
2. Bump the version in **both** `version.txt` and `mod/version.txt` (same value, e.g. `1.0.1`).
3. Commit and push to `main`. Friends get the update the next time they launch through the shortcut.

## Development setup

Link the mod folder into the Mods directory instead of copying, so edits are live:

```bat
mklink /J "%APPDATA%\Balatro\Mods\BalatroCoop" "D:\path\to\BalatroMulti\mod"
```

Logs: `%APPDATA%\Balatro\coop.log` (mod, own game), `%APPDATA%\Balatro\coop_players.log` (host only: every connected player's log lines, stats every 10 s, stalls) and `%APPDATA%\Balatro\Mods\lovely\log` (injector). Co-op saves live in `%APPDATA%\Balatro\coop_saves`.

Set the environment variable `BALATRO_COOP_DEBUG=1` to enable the developer command channel (see `mod/src/debug.lua`); `BALATRO_COOP_AUTO=host|join` auto-opens a lobby, which makes it easy to test with two game instances on one PC.

## Layout

```
mod/            the mod itself (installed to %APPDATA%\Balatro\Mods\BalatroCoop)
  lovely.toml   Lovely patch: appends bootstrap.lua to main.lua
  bootstrap.lua loads mod/src/init.lua from disk
  src/          net.lua (TCP), upnp.lua (router port + join codes), core.lua (lobby, turns,
                votes, wallet), shop.lua, spectate.lua, saves.lua, ui.lua, hooks.lua, json.lua,
                log.lua, debug.lua
launcher/       BalatroCoop.ps1 (install + update + launch), Install-BalatroCoop.bat
version.txt     current version (checked by the launcher)
```
