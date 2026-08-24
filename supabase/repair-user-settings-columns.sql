-- Run this in the Supabase SQL Editor.
--
-- Reported as "toggling pay cycle does nothing that sticks". The real cause was that
-- user_settings had no period_mode column, and because every setting is written as one row,
-- that single missing column made the ENTIRE settings save fail with PGRST204 - so
-- current_month, theme, last_goal and balance_mode silently stopped persisting too.
--
-- Every column below is what supabase/schema.sql already declares. IF NOT EXISTS means this is
-- safe to run whether or not a given column is already there, and safe to run twice.

alter table public.user_settings add column if not exists current_month        text;
alter table public.user_settings add column if not exists theme                text not null default 'light';
alter table public.user_settings add column if not exists last_goal            numeric not null default 0;
alter table public.user_settings add column if not exists balance_mode         text not null default 'live';
alter table public.user_settings add column if not exists manual_balance       numeric not null default 0;
alter table public.user_settings add column if not exists period_mode          text not null default 'calendar';
alter table public.user_settings add column if not exists up_token             text;
alter table public.user_settings add column if not exists last_up_balance      numeric;
alter table public.user_settings add column if not exists is_admin             boolean not null default false;
alter table public.user_settings add column if not exists display_name         text;
alter table public.user_settings add column if not exists feature_tech         boolean not null default true;
alter table public.user_settings add column if not exists feature_grocery      boolean not null default true;
alter table public.user_settings add column if not exists feature_monthlycosts boolean not null default true;
alter table public.user_settings add column if not exists feature_ballet       boolean not null default false;
alter table public.user_settings add column if not exists feature_recurring    boolean not null default true;
alter table public.user_settings add column if not exists feature_up           boolean not null default true;
alter table public.user_settings add column if not exists feature_dashboard    boolean not null default true;
alter table public.user_settings add column if not exists feature_records      boolean not null default true;
alter table public.user_settings add column if not exists feature_template     boolean not null default true;
alter table public.user_settings add column if not exists platform_hidden      jsonb not null default '{}'::jsonb;
alter table public.user_settings add column if not exists saver_order          jsonb not null default '[]'::jsonb;
alter table public.user_settings add column if not exists updated_at           timestamptz not null default now();

-- PostgREST caches the schema; without this the API can keep reporting a column as missing for
-- a minute or so after it exists.
notify pgrst, 'reload schema';

-- Confirm: this should list every column above.
select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'user_settings'
order by column_name;
