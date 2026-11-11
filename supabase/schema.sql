-- ============================================================
-- Top Down Looter: Supabase backend (name + password accounts).
--
-- Paste this whole file into Supabase -> SQL Editor -> Run. Safe to re-run (it never deletes data).
-- The ONE-TIME wipe lives in migration_accounts.sql, which must be run BEFORE this file the first time.
--
-- How identity works:
--   * A player creates an account on the website with a name and a password. The password is stored only
--     as a bcrypt hash; the name is the login and is unique ignoring case.
--   * Logging in returns a random SESSION TOKEN. Only its SHA-256 hash is stored (private.sessions); the
--     browser keeps the token in localStorage and the game sends it with every call. One account can be
--     logged in on several devices at once.
--   * Boards show a separate public player_id (uuid), never the token or the password.
--   * The game and site talk only to the RPC functions below, using the public anon key.
--     The tables are locked: no direct reads or writes from the browser.
-- ============================================================

create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

-- ---------- Tables ----------

create table if not exists public.players (
  player_id     uuid primary key default gen_random_uuid(),
  password_hash text not null,
  display_name  text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
-- Names are unique ignoring case, so nobody can pose as another player (and login is by name).
create unique index if not exists players_display_name_lower_index on public.players (lower(display_name));

create table if not exists public.runs (
  id               bigint generated always as identity primary key,
  player_id        uuid not null references public.players (player_id) on delete cascade,
  mode             text not null default 'normal' check (mode in ('normal', 'roguelike')),
  difficulty_tier  integer not null,
  deepest_floor    integer not null,
  kills            integer not null,
  elites           integer not null,
  bosses           integer not null,
  gold             integer not null,
  duration_seconds double precision not null,
  extracted        boolean not null,
  ranked           boolean not null default true,
  score_weight     double precision not null default 1,
  created_at       timestamptz not null default now()
);
create index if not exists runs_player_index on public.runs (player_id, created_at desc);
create index if not exists runs_mode_index on public.runs (mode, ranked);

create table if not exists public.saves (
  player_id     uuid primary key references public.players (player_id) on delete cascade,
  profile       text not null default '',
  save          text not null default '',
  personal_best text not null default '',
  updated_at    timestamptz not null default now()
);

-- Logged-in devices. The token itself is never stored, only its hash.
create table if not exists private.sessions (
  token_hash bytea primary key,
  player_id  uuid not null references public.players (player_id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '180 days'
);
create index if not exists sessions_player_index on private.sessions (player_id, created_at);

-- Registrations and failed logins, for rate limiting. name_key is the lower-cased name that was tried.
create table if not exists private.auth_log (
  kind       text not null,
  ip_hash    bytea,
  name_key   text,
  created_at timestamptz not null default now()
);
create index if not exists auth_log_ip_index on private.auth_log (kind, ip_hash, created_at);
create index if not exists auth_log_name_index on private.auth_log (kind, name_key, created_at);

-- Lock every table: RLS on with no policies = nothing readable through the API.
alter table public.players enable row level security;
alter table public.runs enable row level security;
alter table public.saves enable row level security;
alter table private.sessions enable row level security;
alter table private.auth_log enable row level security;
revoke all on public.players, public.runs, public.saves from anon, authenticated;
revoke all on private.sessions, private.auth_log from anon, authenticated;
revoke all on schema private from anon, authenticated, public;

-- ---------- Helpers (not callable from the API) ----------

-- TUNING: limits. Keep the score weights in sync with Assets/Game/Config/Definitions/dungeon_rules.json
-- (difficultyTiers[].leaderboardScoreWeight and endlessTierScaling.leaderboardScoreWeightGrowthPerTier).
create or replace function private.tier_score_weight(p_tier integer)
returns double precision
language plpgsql immutable set search_path = ''
as $$
declare
  v_weights double precision[] := array[1.0, 1.5, 2.2, 3.2, 4.6, 6.5];
  v_growth_per_tier constant double precision := 1.4;
begin
  if p_tier <= array_length(v_weights, 1) then
    return v_weights[p_tier];
  end if;
  return v_weights[array_length(v_weights, 1)] * power(v_growth_per_tier, p_tier - array_length(v_weights, 1));
end;
$$;

-- Recovery codes are hex; dashes, spaces and case are ignored when typed in.
create or replace function private.hash_key(p_key text)
returns bytea
language sql immutable set search_path = ''
as $$
  select extensions.digest(upper(regexp_replace(coalesce(p_key, ''), '[^0-9A-Fa-f]', '', 'g')), 'sha256');
$$;

create or replace function private.require_player(p_key text)
returns uuid
language plpgsql stable set search_path = ''
as $$
declare
  v_player_id uuid;
begin
  select player_id into v_player_id from private.sessions
   where token_hash = private.hash_key(p_key) and expires_at > now();
  if v_player_id is null then
    raise exception 'invalid_key';
  end if;
  return v_player_id;
end;
$$;

-- TODO: add a profanity filter here if names need moderating.
create or replace function private.clean_name(p_name text)
returns text
language sql immutable set search_path = ''
as $$
  select btrim(left(btrim(regexp_replace(coalesce(p_name, ''), '[^[:alnum:] _-]', '', 'g')), 16));
$$;

-- The caller's IP (hashed), or null when the request carries none.
create or replace function private.caller_ip_hash()
returns bytea
language plpgsql stable set search_path = ''
as $$
declare
  v_headers json := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json;
  v_ip text := btrim(split_part(coalesce(v_headers ->> 'cf-connecting-ip', v_headers ->> 'x-forwarded-for', ''), ',', 1));
begin
  if v_ip = '' then
    return null;
  end if;
  return extensions.digest(v_ip, 'sha256');
end;
$$;

-- Starts a login session for a player and returns the new token (shown to the browser exactly once).
create or replace function private.start_session(p_player_id uuid)
returns text
language plpgsql volatile set search_path = ''
as $$
declare
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  insert into private.sessions (token_hash, player_id) values (private.hash_key(v_token), p_player_id);
  -- Keep only the 10 newest devices per account.
  delete from private.sessions
   where player_id = p_player_id
     and token_hash not in (select token_hash from private.sessions where player_id = p_player_id order by created_at desc limit 10);
  return v_token;
end;
$$;

-- ---------- Public API (RPC) ----------

-- Creates an account and logs it in. Errors: invalid_name, invalid_password, name_taken, rate_limited.
create or replace function public.register_account(p_display_name text, p_password text)
returns json
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_ip_hash bytea := private.caller_ip_hash();
  v_max_per_ip_per_hour constant integer := 10;
  v_name text := private.clean_name(p_display_name);
  v_player_id uuid;
begin
  if char_length(v_name) < 3 then
    raise exception 'invalid_name';
  end if;
  -- bcrypt only looks at the first 72 bytes, so longer passwords are refused instead of silently cut.
  if p_password is null or char_length(p_password) < 8 or octet_length(p_password) > 72 then
    raise exception 'invalid_password';
  end if;

  if v_ip_hash is not null then
    delete from private.auth_log where created_at < now() - interval '1 day';
    if (select count(*) from private.auth_log where kind = 'register' and ip_hash = v_ip_hash and created_at > now() - interval '1 hour') >= v_max_per_ip_per_hour then
      raise exception 'rate_limited';
    end if;
    insert into private.auth_log (kind, ip_hash) values ('register', v_ip_hash);
  end if;

  begin
    insert into public.players (password_hash, display_name)
    values (extensions.crypt(p_password, extensions.gen_salt('bf', 10)), v_name)
    returning player_id into v_player_id;
  exception when unique_violation then
    raise exception 'name_taken';
  end;

  return json_build_object('token', private.start_session(v_player_id), 'playerId', v_player_id, 'displayName', v_name);
end;
$$;

-- Logs in with name + password. A wrong name or password RETURNS {"error":"invalid_login"} instead of raising, because a
-- raised error would roll back the failed-attempt record that the rate limit needs. Raises too_many_attempts at the limits.
create or replace function public.login(p_display_name text, p_password text)
returns json
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_ip_hash bytea := private.caller_ip_hash();
  v_name_key text := lower(private.clean_name(p_display_name));
  v_max_failures_per_name constant integer := 10;
  v_max_failures_per_ip constant integer := 30;
  v_player public.players;
  v_is_valid boolean;
begin
  delete from private.auth_log where created_at < now() - interval '1 day';
  if (select count(*) from private.auth_log where kind = 'login_failed' and name_key = v_name_key and created_at > now() - interval '15 minutes') >= v_max_failures_per_name
     or (v_ip_hash is not null and (select count(*) from private.auth_log where kind = 'login_failed' and ip_hash = v_ip_hash and created_at > now() - interval '15 minutes') >= v_max_failures_per_ip) then
    raise exception 'too_many_attempts';
  end if;

  select * into v_player from public.players where lower(display_name) = v_name_key;
  if v_player.player_id is null then
    -- Spend the same time as a real check so response time does not reveal which names exist.
    perform extensions.crypt(coalesce(p_password, ''), extensions.gen_salt('bf', 10));
    v_is_valid := false;
  else
    v_is_valid := v_player.password_hash = extensions.crypt(coalesce(p_password, ''), v_player.password_hash);
  end if;

  if not v_is_valid then
    insert into private.auth_log (kind, ip_hash, name_key) values ('login_failed', v_ip_hash, v_name_key);
    return json_build_object('error', 'invalid_login');
  end if;

  delete from private.auth_log where kind = 'login_failed' and name_key = v_name_key;
  return json_build_object('token', private.start_session(v_player.player_id), 'playerId', v_player.player_id, 'displayName', v_player.display_name);
end;
$$;

-- Who is this token? (Used by the game and the site at startup.) Raises invalid_key when it expired or was logged out.
create or replace function public.get_account(p_player_key text)
returns json
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_player public.players;
begin
  select p.* into v_player
    from private.sessions s join public.players p on p.player_id = s.player_id
   where s.token_hash = private.hash_key(p_player_key) and s.expires_at > now();
  if v_player.player_id is null then
    raise exception 'invalid_key';
  end if;
  return json_build_object('playerId', v_player.player_id, 'displayName', v_player.display_name);
end;
$$;

-- Ends this device's session.
create or replace function public.logout(p_player_key text)
returns json
language plpgsql volatile security definer set search_path = ''
as $$
begin
  delete from private.sessions where token_hash = private.hash_key(p_player_key);
  return json_build_object('ok', true);
end;
$$;

-- Changes the password and logs every OTHER device out. A wrong old password RETURNS {"error":"invalid_login"}.
create or replace function public.change_password(p_player_key text, p_old_password text, p_new_password text)
returns json
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_player_id uuid := private.require_player(p_player_key);
  v_current_hash text;
begin
  if p_new_password is null or char_length(p_new_password) < 8 or octet_length(p_new_password) > 72 then
    raise exception 'invalid_password';
  end if;
  select password_hash into v_current_hash from public.players where player_id = v_player_id;
  if v_current_hash <> extensions.crypt(coalesce(p_old_password, ''), v_current_hash) then
    return json_build_object('error', 'invalid_login');
  end if;
  update public.players
     set password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf', 10)), updated_at = now()
   where player_id = v_player_id;
  delete from private.sessions where player_id = v_player_id and token_hash <> private.hash_key(p_player_key);
  return json_build_object('ok', true);
end;
$$;

-- Same clamps the old Node server used. The score weight is computed here, never trusted from the client.
create or replace function public.submit_run(
  p_player_key text,
  p_mode text default 'normal',
  p_difficulty_tier integer default 1,
  p_deepest_floor integer default 0,
  p_enemies_killed integer default 0,
  p_elites_killed integer default 0,
  p_bosses_killed integer default 0,
  p_gold_extracted integer default 0,
  p_duration_seconds double precision default 0,
  p_extracted boolean default false,
  p_is_ranked boolean default true
)
returns json
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_player_id uuid := private.require_player(p_player_key);
  v_max_runs_per_minute constant integer := 6;
  v_tier integer := least(20, greatest(1, coalesce(p_difficulty_tier, 1)));
begin
  if coalesce(p_mode, '') not in ('normal', 'roguelike') then
    raise exception 'invalid_mode';
  end if;
  if (select count(*) from public.runs where player_id = v_player_id and created_at > now() - interval '1 minute') >= v_max_runs_per_minute then
    raise exception 'rate_limited';
  end if;

  insert into public.runs (player_id, mode, difficulty_tier, deepest_floor, kills, elites, bosses, gold,
                           duration_seconds, extracted, ranked, score_weight)
  values (
    v_player_id, p_mode, v_tier,
    least(1000, greatest(0, coalesce(p_deepest_floor, 0))),
    least(100000, greatest(0, coalesce(p_enemies_killed, 0))),
    least(100000, greatest(0, coalesce(p_elites_killed, 0))),
    least(100000, greatest(0, coalesce(p_bosses_killed, 0))),
    least(100000000, greatest(0, coalesce(p_gold_extracted, 0))),
    least(86400, greatest(0, coalesce(p_duration_seconds, 0))),
    coalesce(p_extracted, false),
    coalesce(p_is_ranked, true),
    private.tier_score_weight(v_tier)
  );
  return json_build_object('ok', true);
end;
$$;

-- Returns {"entries":[...]} (an object, because Unity's JsonUtility cannot read a top-level array).
-- One row per player: their best run for the category.
create or replace function public.get_leaderboard(p_category text, p_limit integer default 50, p_mode text default 'normal')
returns json
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_limit integer := least(100, greatest(1, coalesce(p_limit, 50)));
begin
  if p_category is null or p_category not in ('deepestFloor', 'mostKills', 'mostElitesKilled', 'mostGoldExtracted', 'highestDifficulty') then
    raise exception 'Unknown category';
  end if;

  return json_build_object('entries', coalesce((
    select json_agg(json_build_object(
      'rank', ranked.rank,
      'playerId', ranked.player_id,
      'displayName', ranked.display_name,
      'value', ranked.value,
      'difficultyTier', ranked.difficulty_tier,
      'submittedAtUtc', to_char(ranked.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ) order by ranked.rank)
    from (
      select row_number() over (order by best.value desc, best.created_at asc) as rank,
             best.player_id, best.display_name, best.value, best.difficulty_tier, best.created_at
      from (
        select distinct on (scored.player_id) scored.player_id, players.display_name, scored.value,
               scored.difficulty_tier, scored.created_at
        from (
          select runs.player_id, runs.difficulty_tier, runs.created_at,
                 (case p_category
                    when 'deepestFloor' then round(runs.deepest_floor * runs.score_weight)
                    when 'mostKills' then round(runs.kills * runs.score_weight)
                    when 'mostElitesKilled' then round(runs.elites * runs.score_weight)
                    when 'mostGoldExtracted' then round(runs.gold * runs.score_weight)
                    else runs.difficulty_tier
                  end)::bigint as value
          from public.runs
          where runs.ranked
            and runs.mode = p_mode
            and (p_category <> 'mostGoldExtracted' or runs.extracted)
        ) scored
        join public.players on players.player_id = scored.player_id
        order by scored.player_id, scored.value desc, scored.created_at asc
      ) best
      order by best.value desc, best.created_at asc
      limit v_limit
    ) ranked
  ), '[]'::json));
end;
$$;

-- Cloud save: three text blobs (the game's own JSON files), size-capped.
create or replace function public.save_cloud(p_player_key text, p_profile text, p_save text, p_personal_best text)
returns json
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_player_id uuid := private.require_player(p_player_key);
  v_max_characters constant integer := 262144;
begin
  if length(coalesce(p_profile, '')) > v_max_characters
     or length(coalesce(p_save, '')) > v_max_characters
     or length(coalesce(p_personal_best, '')) > v_max_characters then
    raise exception 'save_too_large';
  end if;
  insert into public.saves (player_id, profile, save, personal_best, updated_at)
  values (v_player_id, coalesce(p_profile, ''), coalesce(p_save, ''), coalesce(p_personal_best, ''), now())
  on conflict (player_id) do update
    set profile = excluded.profile, save = excluded.save,
        personal_best = excluded.personal_best, updated_at = excluded.updated_at;
  return json_build_object('ok', true);
end;
$$;

create or replace function public.load_cloud(p_player_key text)
returns json
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_player_id uuid := private.require_player(p_player_key);
  v_row public.saves;
begin
  select * into v_row from public.saves where player_id = v_player_id;
  if v_row.player_id is null then
    return json_build_object('found', false, 'profile', '', 'save', '', 'personalBest', '', 'updatedAtUtc', '');
  end if;
  return json_build_object(
    'found', true,
    'profile', v_row.profile,
    'save', v_row.save,
    'personalBest', v_row.personal_best,
    'updatedAtUtc', to_char(v_row.updated_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
end;
$$;

-- ---------- Permissions: only these functions are callable from the browser ----------

revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;

grant execute on function public.register_account(text, text) to anon, authenticated;
grant execute on function public.login(text, text) to anon, authenticated;
grant execute on function public.get_account(text) to anon, authenticated;
grant execute on function public.logout(text) to anon, authenticated;
grant execute on function public.change_password(text, text, text) to anon, authenticated;
grant execute on function public.submit_run(text, text, integer, integer, integer, integer, integer, integer, double precision, boolean, boolean) to anon, authenticated;
grant execute on function public.get_leaderboard(text, integer, text) to anon, authenticated;
grant execute on function public.save_cloud(text, text, text, text) to anon, authenticated;
grant execute on function public.load_cloud(text) to anon, authenticated;
