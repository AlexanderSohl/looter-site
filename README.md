# Top Down Looter: website + backend

Static website (`public/`) plus a Supabase backend (`supabase/schema.sql`). There is no server
to run. Players need **no account**: the game registers an anonymous player on first use and
shows a secret **recovery code** that restores their identity on another device.

```
public/index.html   landing page: game iframe, recovery code panel, leaderboard table
public/config.js    Supabase URL + PUBLIC key (safe to publish; never the service_role key)
public/play/        Unity WebGL build (Unity menu: Looter -> Build WebGL Test)
supabase/schema.sql tables, locked down, plus the RPC functions the game calls
```

## One-time setup

1. **Supabase project:** supabase.com -> New project (free). Region near your players.
2. **Database:** SQL Editor -> paste all of `supabase/schema.sql` -> Run. (Safe to re-run later.)
3. **Keys:** Project Settings -> API. Copy the **Project URL** and the **anon / publishable** key.
   Never use the `service_role` / secret key in the game or this repo.
4. **Game:** put both values in `Assets/Game/Leaderboard/Resources/leaderboard_settings.json`
   (`supabaseUrl`, `supabaseKey`).
5. **Site:** put the same two values in `public/config.js`.
6. **Smoke test** (replace `URL` and `KEY`):
   ```
   curl -s URL/rest/v1/rpc/register_player -H "apikey: KEY" -H "Content-Type: application/json" -d '{"p_display_name":"Tester"}'
   curl -s URL/rest/v1/rpc/get_leaderboard -H "apikey: KEY" -H "Content-Type: application/json" -d '{"p_category":"deepestFloor"}'
   ```
   The first returns a `playerKey`; the second returns `{"entries":[]}`. If the key starts with
   `eyJ` (legacy), also add `-H "Authorization: Bearer KEY"`.
7. In the Unity editor, press Play with the settings filled in: opening the leaderboard registers a
   player and finishing a run submits it, so you can test before any web build.

## Publish (Cloudflare Pages, free)

1. Push this repo to GitHub.
2. Cloudflare dashboard -> Workers & Pages -> Create -> Pages -> connect the repo.
   Build command: none. **Build output directory: `public`.**
3. Each push redeploys. Keep the final URL fixed: the browser keeps saves per site address, so
   changing the address orphans players' local saves (their recovery code still works for runs).

Cloudflare Pages allows 25 MiB per file; the gzip'd `.wasm` is about 12 MiB. Check new builds stay under it.

## Update the game

Unity: **Looter -> Build WebGL Test** (writes `public/play/`), then commit and push.

## Moderation

Delete a bad score or name in Supabase -> Table Editor (`runs`, `players`). The browser cannot read
or write those tables directly; only the functions in `schema.sql` are callable.

## Two modes

`runs.mode` already supports `normal` and `roguelike`; the leaderboard function takes a mode, and the
site has a mode selector. The game still sends `normal` until the roguelike mode exists
(see `WebLeaderboardService.NormalModeName`).
