-- ============================================================
-- ONE-TIME MIGRATION: switch from recovery codes to name + password accounts.
--
-- !!! THIS DELETES EVERYTHING: every player, every leaderboard run, every cloud save. !!!
-- It is meant to be run exactly once, before schema.sql, to reset the boards for the new difficulty.
-- It is NOT part of schema.sql on purpose, so re-running schema.sql can never wipe production.
--
-- Order:
--   1. (optional) Supabase -> Table Editor: export runs/players if you want a backup.
--   2. Run THIS file in SQL Editor.
--   3. Run schema.sql in SQL Editor.
--   4. Run:  notify pgrst, 'reload schema';
-- ============================================================

-- Old recovery-code functions (replaced by register_account / login / get_account / logout / change_password).
drop function if exists public.register_player(text);
drop function if exists public.recover_player(text);
drop function if exists public.set_display_name(text, text);

-- Old data. "cascade" also removes anything that pointed at these tables.
drop table if exists public.runs cascade;
drop table if exists public.saves cascade;
drop table if exists public.players cascade;
drop table if exists private.registration_log cascade;
drop table if exists private.sessions cascade;
drop table if exists private.auth_log cascade;
