-- ============================================================
-- fish_schema.sql  -  Fish Online leaderboard (adds to the Top Down Looter Supabase project).
-- Run in Supabase -> SQL Editor AFTER the Looter schema.sql. Safe to re-run. Touches nothing of Looter's.
-- Uses Looter's public.get_account(p_player_key) to turn the website login token into a player,
-- so both games share the same accounts.
--
-- Callable from the browser (anon key):
--   submit_fish_stats(p_player_key, p_biggest_kg, p_biggest_name, p_total_kg, p_catch_count, p_species_mask, p_xp, p_level)
--   get_fish_leaderboard(p_category 'biggest' | 'total' | 'species' | 'level', p_limit)
-- Not cheat-proof (the client reports its own numbers); values only ever go up and are clamped.
-- ============================================================

create table if not exists public.fish_stats (
    player_id      text primary key,
    display_name   text        not null default '',
    biggest_kg     numeric(10, 3) not null default 0,
    biggest_name   text        not null default '',
    total_kg       numeric(14, 3) not null default 0,
    catch_count    integer     not null default 0,
    species_mask   bigint      not null default 0,
    species_count  integer     not null default 0,
    xp             bigint      not null default 0,
    fisher_level   integer     not null default 1,
    updated_at     timestamptz not null default now()
);

alter table public.fish_stats enable row level security;
revoke all on public.fish_stats from anon, authenticated;

create index if not exists fish_stats_biggest_idx on public.fish_stats (biggest_kg desc);
create index if not exists fish_stats_total_idx   on public.fish_stats (total_kg desc);
create index if not exists fish_stats_species_idx on public.fish_stats (species_count desc);

alter table public.fish_stats add column if not exists xp bigint not null default 0;
alter table public.fish_stats add column if not exists fisher_level integer not null default 1;
create index if not exists fish_stats_xp_idx on public.fish_stats (xp desc);

-- Older 6-argument version (before fisherman levels).
drop function if exists public.submit_fish_stats(text, numeric, text, numeric, integer, bigint);

-- ------------------------------------------------------------
-- submit_fish_stats: upsert the logged-in player's lifetime snapshot (monotonic, clamped).
-- Errors (as PostgREST "message"): invalid_key, too_fast.
-- ------------------------------------------------------------
create or replace function public.submit_fish_stats(
    p_player_key   text,
    p_biggest_kg   numeric,
    p_biggest_name text,
    p_total_kg     numeric,
    p_catch_count  integer,
    p_species_mask bigint,
    p_xp           bigint  default 0,
    p_level        integer default 1
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_account  jsonb;
    v_player   text;
    v_name     text;
    v_biggest  numeric := least(greatest(coalesce(p_biggest_kg, 0), 0), 1000);
    v_total    numeric := least(greatest(coalesce(p_total_kg, 0), 0), 10000000);
    v_count    integer := least(greatest(coalesce(p_catch_count, 0), 0), 1000000);
    v_mask     bigint  := coalesce(p_species_mask, 0) & 9223372036854775807;
    v_xp       bigint  := least(greatest(coalesce(p_xp, 0), 0), 100000000);
    v_level    integer := least(greatest(coalesce(p_level, 1), 1), 99);
    v_row      public.fish_stats%rowtype;
    v_new_mask bigint;
begin
    v_account := to_jsonb(public.get_account(p_player_key));
    v_player := v_account ->> 'playerId';
    v_name := coalesce(v_account ->> 'displayName', '');
    if v_player is null or v_player = '' then
        raise exception 'invalid_key';
    end if;

    insert into public.fish_stats (player_id, display_name, updated_at)
    values (v_player, v_name, now() - interval '1 minute')
    on conflict (player_id) do nothing;

    select * into v_row from public.fish_stats where player_id = v_player for update;
    if now() - v_row.updated_at < interval '1 second' then
        raise exception 'too_fast';
    end if;

    v_new_mask := v_row.species_mask | v_mask;
    update public.fish_stats set
        display_name  = v_name,
        biggest_name  = case when v_biggest > biggest_kg then left(coalesce(p_biggest_name, ''), 40) else biggest_name end,
        biggest_kg    = greatest(biggest_kg, v_biggest),
        total_kg      = greatest(total_kg, v_total),
        catch_count   = greatest(catch_count, v_count),
        species_mask  = v_new_mask,
        xp            = greatest(xp, v_xp),
        fisher_level  = greatest(fisher_level, v_level),
        species_count = (select count(*) from generate_series(0, 62) as bit_index where (v_new_mask >> bit_index) & 1 = 1),
        updated_at    = now()
    where player_id = v_player;

    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- get_fish_leaderboard: top players for one board.
-- Returns { "entries": [ { rank, playerId, displayName, value, detail } ] }.
-- ------------------------------------------------------------
create or replace function public.get_fish_leaderboard(
    p_category text,
    p_limit    integer default 25
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_limit   integer := least(greatest(coalesce(p_limit, 25), 1), 100);
    v_entries jsonb;
begin
    if p_category not in ('biggest', 'total', 'species', 'level') then
        raise exception 'bad_category';
    end if;

    select coalesce(jsonb_agg(row_data order by (row_data ->> 'rank')::int), '[]'::jsonb)
    into v_entries
    from (
        select jsonb_build_object(
            'rank', row_number() over (order by score desc, updated_at asc),
            'playerId', player_id,
            'displayName', display_name,
            'value', shown,
            'detail', detail
        ) as row_data
        from (
            select player_id, display_name, updated_at,
                   case p_category
                       when 'biggest' then biggest_kg
                       when 'total'   then total_kg
                       when 'level'   then xp::numeric
                       else species_count::numeric
                   end as score,
                   case p_category
                       when 'biggest' then biggest_kg
                       when 'total'   then total_kg
                       when 'level'   then fisher_level::numeric
                       else species_count::numeric
                   end as shown,
                   case p_category when 'biggest' then biggest_name when 'level' then xp::text || ' XP' else '' end as detail
            from public.fish_stats
        ) scored
        where score > 0
        order by score desc, updated_at asc
        limit v_limit
    ) ranked;

    return jsonb_build_object('entries', v_entries);
end;
$$;

revoke all on function public.submit_fish_stats(text, numeric, text, numeric, integer, bigint, bigint, integer) from public;
revoke all on function public.get_fish_leaderboard(text, integer) from public;
grant execute on function public.submit_fish_stats(text, numeric, text, numeric, integer, bigint, bigint, integer) to anon, authenticated;
grant execute on function public.get_fish_leaderboard(text, integer) to anon, authenticated;

notify pgrst, 'reload schema';
