-- ============================================================
-- Top Down Looter: Supabase backend (no accounts).
--
-- Paste this whole file into Supabase -> SQL Editor -> Run. Safe to re-run.
--
-- How identity works:
--   * A player registers once and gets a secret RECOVERY CODE (20 hex chars).
--     Only its SHA-256 hash is stored. The code is the only thing that proves
--     "this is me", on this device or any other.
--   * Boards show a separate public player_id (uuid), never the secret code.
--   * The game talks only to the RPC functions below, using the public anon key.
--     The tables are locked: no direct reads or writes from the browser.
-- ============================================================

create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

-- ---------- Tables ----------

create table if not exists public.players (
  player_id    uuid primary key default gen_random_uuid(),
  key_hash     bytea not null unique,
  display_name text  not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
-- Names are unique ignoring case, so nobody can pose as another player.
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

create table if not exists private.registration_log (
  ip_hash    bytea not null,
  created_at timestamptz not null default now()
);
create index if not exists registration_log_index on private.registration_log (ip_hash, created_at);

-- Lock every table: RLS on with no policies = nothing readable through the API.
alter table public.players enable row level security;
alter table public.runs enable row level security;
alter table public.saves enable row level security;
alter table private.registration_log enable row level security;
revoke all on public.players, public.runs, public.saves from anon, authenticated;
revoke all on private.registration_log from anon, authenticated;
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
  select player_id into v_player_id from public.players where key_hash = private.hash_key(p_key);
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

-- ---------- Public API (RPC) ----------

-- Creates a player and returns the one-time recovery code. TODO(UI): the game/site must show it.
create or replace function public.register_player(p_display_name text default '')
returns json
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_headers json := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json;
  v_ip text := btrim(split_part(coalesce(v_headers ->> 'cf-connecting-ip', v_headers ->> 'x-forwarded-for', ''), ',', 1));
  v_ip_hash bytea;
  v_max_per_ip_per_hour constant integer := 10;
  v_key text := upper(encode(extensions.gen_random_bytes(10), 'hex'));
  v_name text := private.clean_name(p_display_name);
  v_player_id uuid;
  v_attempt integer := 0;
begin
  if v_ip <> '' then
    v_ip_hash := extensions.digest(v_ip, 'sha256');
    delete from private.registration_log where created_at < now() - interval '1 day';
    if (select count(*) from private.registration_log where ip_hash = v_ip_hash and created_at > now() - interval '1 hour') >= v_max_per_ip_per_hour then
      raise exception 'rate_limited';
    end if;
    insert into private.registration_log (ip_hash) values (v_ip_hash);
  end if;

  loop
    v_attempt := v_attempt + 1;
    if v_name = '' then
      v_name := 'Player' || lpad(floor(random() * 10000)::integer::text, 4, '0');
    end if;
    begin
      insert into public.players (key_hash, display_name)
      values (private.hash_key(v_key), v_name)
      returning player_id into v_player_id;
      exit;
    exception when unique_violation then
      -- A chosen name that is taken is an error; a generated one just retries.
      if btrim(coalesce(p_display_name, '')) <> '' or v_attempt >= 5 then
        raise exception 'name_taken';
      end if;
      v_name := '';
    end;
  end loop;

  return json_build_object('playerKey', v_key, 'playerId', v_player_id, 'displayName', v_name);
end;
$$;

-- Restores a player on a new device from the recovery code.
create or replace function public.recover_player(p_player_key text)
returns json
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_player public.players;
begin
  select * into v_player from public.players where key_hash = private.hash_key(p_player_key);
  if v_player.player_id is null then
    raise exception 'invalid_key';
  end if;
  return json_build_object('playerId', v_player.player_id, 'displayName', v_player.display_name);
end;
$$;

create or replace function public.set_display_name(p_player_key text, p_display_name text)
returns json
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_player_id uuid := private.require_player(p_player_key);
  v_name text := private.clean_name(p_display_name);
begin
  if v_name = '' then
    raise exception 'invalid_name';
  end if;
  begin
    update public.players set display_name = v_name, updated_at = now() where player_id = v_player_id;
  exception when unique_violation then
    raise exception 'name_taken';
  end;
  return json_build_object('playerId', v_player_id, 'displayName', v_name);
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

grant execute on function public.register_player(text) to anon, authenticated;
grant execute on function public.recover_player(text) to anon, authenticated;
grant execute on function public.set_display_name(text, text) to anon, authenticated;
grant execute on function public.submit_run(text, text, integer, integer, integer, integer, integer, integer, double precision, boolean, boolean) to anon, authenticated;
grant execute on function public.get_leaderboard(text, integer, text) to anon, authenticated;
grant execute on function public.save_cloud(text, text, text, text) to anon, authenticated;
grant execute on function public.load_cloud(text) to anon, authenticated;
