# Game website + leaderboard server

Small Node 20 + Express + SQLite server. From the **same origin** it serves:

- the website (`public/index.html`): sign in with Google or an email/password account, then play,
- the Unity WebGL build (`public/play/`), embedded by the website,
- the account and leaderboard API.

Leaderboard runs belong to the signed-in **website account**. The session is an HttpOnly
cookie, so the game's same-origin requests carry it automatically; the game never sees a
password or token. Without a session, `POST /api/runs` answers `401` and the game keeps
the run locally.

## Run

```
cd Server/leaderboard
npm install
npm start            # http://localhost:8080  (PORT env var changes it)
```

`leaderboard.sqlite` is created next to `server.js` (`DATABASE_FILE` env var overrides).

## Google sign-in (optional)

1. Google Cloud Console → APIs & Services → Credentials → Create OAuth client ID → **Web application**.
2. Add your site under **Authorized JavaScript origins** (e.g. `http://localhost:8080` and `https://yourgame.com`).
3. Start the server with `GOOGLE_CLIENT_ID=<the client id>`.

Without `GOOGLE_CLIENT_ID` the Google button is hidden and only email accounts work.
A Google sign-in never merges into an existing password account with the same email
(that email was never verified); the player is asked to use their password instead.

## Quick local test

1. In Unity: **Looter → Build WebGL Test** (or the Development variant for logs/profiler).
   It builds straight into `public/play/` with Gzip, turns on save syncing
   (`autoSyncPersistentDataPath`) and makes the game fill the site's frame.
2. Double-click `start-test-site.cmd` (installs packages on first run, starts the server, opens the browser).

## Host the game (manual build)

1. In Unity: Build Profiles, WebGL, build to any folder. Brotli/Gzip compression both work (Brotli needs HTTPS).
   Enable `config.autoSyncPersistentDataPath = true` in the built `index.html`, or saves are lost on reload.
2. Copy the whole build output (`index.html`, `Build/`, `TemplateData/`) into `Server/leaderboard/public/play/`.
   Do not copy it into `public/` itself: that would overwrite the website's `index.html`.
3. Open `http://localhost:8080`, create an account, and the game loads below the account bar.

`.br` / `.gz` files are served with the right `Content-Encoding` and `Content-Type`.

## Deploy

Any VPS or Node host: copy this folder, `npm ci --omit=dev`, run `node server.js`
under pm2/systemd, and put Caddy/nginx in front for HTTPS.
- Serve over HTTPS: session cookies get the `Secure` flag there, and browsers ignore Brotli (`.br`) builds on plain HTTP.
- Set `TRUST_PROXY=1` when the server runs behind one proxy (nginx/Caddy/Cloudflare), so the rate limit sees the real client IP and HTTPS is detected for the cookie. Leave it unset when Node is exposed directly.
- Set `COOKIE_SECURE=1` in production so the session cookie is always `Secure`, even if proxy headers are misconfigured.
- Sign-in is limited per IP (30 requests/min) and per email (10 failed attempts per 15 min).
- Back up `leaderboard.sqlite` (it now holds accounts and password hashes too).

The game and the API must share one origin (session cookies are `SameSite=Lax` and
write endpoints have no CORS). Keep `apiBaseUrl` in
`Assets/Game/Leaderboard/Resources/leaderboard_settings.json` empty.

## API

Accounts (JSON bodies, `Content-Type: application/json` required on every POST):
- `GET /api/config` → `{ googleClientId }` (null when Google sign-in is off).
- `GET /api/auth/me` → `{ accountId, displayName, email }`, or `401` when signed out.
- `POST /api/auth/register` `{ email, password, displayName }` → account + session cookie. Password 8-128 characters. `409` if the email is taken.
- `POST /api/auth/login` `{ email, password }` → account + session cookie, `401` on a wrong email or password.
- `POST /api/auth/google` `{ credential }` (the Google Identity Services ID token) → account + session cookie.
- `POST /api/auth/logout` → clears the session.
- `POST /api/account/name` `{ displayName }` → renames the account (the leaderboard name). Signed in only.

Leaderboard:
- `POST /api/runs` body `{ statistics: {...RunStatistics} }`, signed in only. The player id and name come
  from the account, never from the body. Numbers are clamped. `201 {ok:true}`, `400` on bad input,
  `401` when signed out, `429` when rate limited.
- `GET /api/leaderboard?category=<key>&limit=<1-100>` returns `{ entries: [{ rank, playerId, displayName, value, difficultyTier, submittedAtUtc }] }`.
  Each player appears once with their best value. Keys: `deepestFloor`, `mostKills`, `mostElitesKilled`, `mostGoldExtracted`, `highestDifficulty`.
  Public and CORS-open, so other pages can show the boards.

Scores are tier-weighted and runs far below the player's highest unlocked tier are unranked
(see `TIER_SCORE_WEIGHTS` in `server.js`; keep it in sync with `dungeon_rules.json`).

## Limits

Accounts stop players from posting under someone else's name, but the run numbers are still
reported by the client; clamping only stops absurd values. Real protection
(server-authoritative runs) belongs to the later Nakama step.
The rate limit is in memory and resets on restart. Runs submitted before accounts existed
keep their old random player ids.

## Deploy with Docker

The folder has a `Dockerfile` (database on the `/data` volume) and a `docker-compose.yml`
that adds Caddy for automatic HTTPS.

- **Any VM (e.g. Oracle Cloud Always Free, a cheap VPS):** install Docker, point a DNS record at the
  VM, copy `.env.example` to `.env` (set `DOMAIN`), then `docker compose up -d --build`.
- **Container hosts (Render, Fly.io, Railway):** deploy the `Dockerfile`, mount a persistent disk
  at `/data`, and set `TRUST_PROXY=1` and `COOKIE_SECURE=1`. Without a persistent disk the
  accounts and leaderboard reset on every redeploy.
- Update the game: build in Unity (**Looter -> Build WebGL Test**), commit `public/play`, redeploy.
