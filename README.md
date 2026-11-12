# Top Down Looter: website + backend

Static website (`public/`) plus a Supabase backend (`supabase/`). There is no server to run.
Players can play with **no account**. To save progress online and post scores they make a **name + password
account on the website**; the page stores a login token that the game reads. There are no recovery codes.

```
public/index.html           main page: game cards (Looter + Fish Online), shared account panel, mini leaderboards
public/looter.html          Top Down Looter page: game iframe, account panel, leaderboard table
public/config.js            Supabase URL + PUBLIC key (safe to publish; never the service_role key)
public/play/                Looter Unity WebGL build (Unity menu: Looter -> Build WebGL Test)
public/fish/index.html      Fish Online page: game iframe + fish leaderboards (log in on the main page)
public/fish/play/           Fish Online Unity WebGL build (Fish Online project: Fish Online -> Build WebGL Test)
supabase/schema.sql         tables, locked down, plus the RPC functions the game and site call (safe to re-run)
supabase/fish_schema.sql    Fish Online tables + RPCs (submit_fish_stats, get_fish_leaderboard); run after schema.sql
supabase/migration_accounts.sql  ONE-TIME wipe + switch from recovery codes to accounts (deletes all data)
```

## How accounts work

- `register_account(name, password)` / `login(name, password)` return a random session token. Passwords are stored
  only as bcrypt hashes; tokens only as SHA-256 hashes (`private.sessions`). Several devices can be logged in at once.
- The site keeps the token in `localStorage` under `looter_session`. The Unity game reads the same key
  (`PlayerKeyStore`), asks `get_account` who it is, and sends the token with `submit_run`, `save_cloud`, `load_cloud`.
- Logged out (no token, or an expired one) the game plays locally and sends nothing online. It never creates accounts.
- Wrong logins are rate limited (10 failures / 15 min per name, 30 per IP). Account creation: 10 per IP per hour.
- No password recovery yet. To reset a forgotten password, delete that row's sessions and set a new `password_hash`
  by hand in the Supabase SQL editor (`update public.players set password_hash = extensions.crypt('new', extensions.gen_salt('bf', 10)) where lower(display_name) = 'name';`).

## One-time setup (new project)

1. **Supabase project:** supabase.com -> New project (free). Region near your players.
2. **Database:** SQL Editor -> paste all of `supabase/schema.sql` -> Run. (Safe to re-run later.)
3. **Keys:** Project Settings -> API. Copy the **Project URL** and the **anon / publishable** key.
   Never use the `service_role` / secret key in the game or this repo.
4. **Game:** put both values in `Assets/Game/Leaderboard/Resources/leaderboard_settings.json`
   (`supabaseUrl`, `supabaseKey`).
5. **Site:** put the same two values in `public/config.js`.
6. **Smoke test** (Git Bash; replace `URL` and `KEY`). If a call says "Could not find the function", run
   `notify pgrst, 'reload schema';` in the SQL editor and retry:
   ```
   curl -s URL/rest/v1/rpc/get_leaderboard -H "apikey: KEY" -H "Content-Type: application/json" -d '{"p_category":"deepestFloor"}'
   curl -s URL/rest/v1/rpc/login -H "apikey: KEY" -H "Content-Type: application/json" -d '{"p_display_name":"nobody","p_password":"wrong-password"}'
   ```
   The first returns `{"entries":[]}`; the second returns `{"error":"invalid_login"}`. If the key starts with
   `eyJ` (legacy), also add `-H "Authorization: Bearer KEY"`. Avoid creating test accounts on the live project.

## Switching an existing project from recovery codes to accounts (wipes all data)

Run in the Supabase SQL editor, in this order:
1. `supabase/migration_accounts.sql`  (DELETES every player, run and cloud save)
2. `supabase/schema.sql`
3. `notify pgrst, 'reload schema';`

Then deploy the new WebGL build and `public/` **together in one commit** (the old build calls functions that no
longer exist). Local saves are reset by the game itself: `SaveSeason.CurrentSeason` in `Assets/Game/Leaderboard`
discards older local saves once per browser. Raise that number whenever you want another global reset.

## Publish (Cloudflare Pages, free)

**Order matters.** `leaderboard_settings.json` is baked into the Unity build, so fill in the Supabase
URL and key first, then run **Looter -> Build WebGL Test**, and only then commit.

1. Push this repo to GitHub.
2. Cloudflare dashboard -> Workers & Pages -> Create -> Pages -> connect the repo.
   Build command: none. **Build output directory: `public`.**
3. Each push redeploys. Keep the final URL fixed: the browser keeps saves and logins per site address, so
   changing the address orphans players' local saves and logins.

Cloudflare Pages allows 25 MiB per file; the gzip'd `.wasm` is about 12 MiB. Check new builds stay under it.

## Update the game

Unity: **Looter -> Build WebGL Test** (writes `public/play/`), then commit and push.

## Moderation

Delete a bad score or name in Supabase -> Table Editor (`runs`, `players`). The browser cannot read
or write those tables directly; only the functions in `schema.sql` are callable.

## Two modes

`runs.mode` supports `normal` and `roguelike`; the leaderboard function takes a mode, and the site has a mode
selector. The game sends the mode of each run (`GameModeNames`).

## Fish Online

Second game on the same site and Supabase project, sharing the same accounts (`looter_session` token).

1. Supabase -> SQL Editor: run `supabase/fish_schema.sql` (safe to re-run; only adds fish tables/functions),
   then `notify pgrst, 'reload schema';`.
2. In `public/index.html` set `FISH_RELEASED = true` so the main page links to `/fish/` instead of "Coming soon".
3. To update the game: in the Fish Online Unity project run **Fish Online -> Build WebGL Test**, copy its
   `Site/fish/play/` over `public/fish/play/`, commit and push. Keep the gzipped `.wasm` under 25 MiB.
