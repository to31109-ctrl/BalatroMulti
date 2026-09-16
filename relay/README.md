# Balatro Co-op relay (Cloudflare Worker)

Lets everyone host without touching a router: the host's game and the friends' games all
connect *out* to this Worker, which forwards the messages. Runs on Cloudflare's free plan
(no card needed).

## Deploy once (owner)

1. Create a free account at https://dash.cloudflare.com/sign-up
2. In this folder:
   ```
   npm install
   npx wrangler login        # opens the browser, click Allow
   npx wrangler deploy
   ```
   The last command prints a URL like `https://balatro-coop-relay.<you>.workers.dev`.
3. Put the relay address into `mod/relay.txt` (one line):
   ```
   ws://balatro-coop-relay.<you>.workers.dev/ws
   ```
   commit, bump `version.txt` + `mod/version.txt`, push. Every player picks it up on next launch.

## Local test

`npm run dev` starts it on `ws://127.0.0.1:8787/ws` (no account needed).

## Protocol

- Host: `GET /ws?role=host` -> receives `sys|code|XXXXX`; then `sys|join|<cid>` / `sys|leave|<cid>`
  and `<cid>|<payload>` for client messages. Host sends `<cid>|<payload>` or `*|<payload>`.
- Client: `GET /ws?role=join&code=XXXXX` -> `sys|welcome|<cid>`, then raw payloads from the host.
