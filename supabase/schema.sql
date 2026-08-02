-- Household budget app: Supabase schema (Phase 1 — persistence + auth)
--
-- Run this once in the Supabase SQL Editor (Dashboard > SQL Editor > New query)
-- against a fresh project. Safe to re-run (uses IF NOT EXISTS / OR REPLACE
-- throughout) but not idempotent for data — this only creates structure.
--
-- Every table is scoped to auth.uid() via RLS. There is no service-role
-- bypass built into the app itself — the browser client only ever uses the
-- public anon key, so RLS is the only thing standing between users' rows.

-- ===================== helper: auto-bump updated_at =====================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ===================== singleton-per-user tables =====================
-- (one row per user_id — mirrors settings/ballet/etc being a single JS object today)

create table if not exists public.user_settings (
  user_id        uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  current_month  text,
  theme          text not null default 'light',
  last_goal      numeric not null default 0,
  balance_mode   text not null default 'live',
  manual_balance numeric not null default 0,
  period_mode    text not null default 'calendar',  -- 'calendar' or 'paycycle' — see index.html's recomputeEffectivePeriod()
  up_token       text,  -- Phase 1 only: client still calls Up Bank directly. Moves to an Edge Function secret in a later phase.
  last_up_balance numeric,  -- most recent successfully-fetched Up Bank balance, remembered across sessions/devices for when a live fetch isn't available
  is_admin       boolean not null default false,  -- app-level admin (Users tab, feature grants) — see admin_* functions below
  display_name   text,  -- optional, shown alongside email in the admin Users tab
  feature_tech         boolean not null default true,  -- Tech Replacement calculator — optional per user, default on
  feature_grocery       boolean not null default true,  -- Groceries calculator — optional per user, default on
  feature_monthlycosts boolean not null default true,  -- Monthly Costs calculator — optional per user, default on
  feature_ballet        boolean not null default false, -- non-admin users only see this if an admin grants it (relabelled "Flexible Tracker") — see index.html's balletFeatureAvailable()
  updated_at     timestamptz not null default now()
);

create table if not exists public.month_template (
  user_id     uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  income      jsonb not null default '[]'::jsonb,
  categories  jsonb not null default '[]'::jsonb,
  goal        numeric not null default 0,
  updated_at  timestamptz not null default now()
);

create table if not exists public.ballet (
  user_id      uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  cost         numeric not null default 0,
  date_charged date,
  balance      numeric not null default 0,
  updated_at   timestamptz not null default now()
);

create table if not exists public.up_income_source (
  user_id     uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  key         text,
  label       text,
  updated_at  timestamptz not null default now()
);

create table if not exists public.grocery_settings (
  user_id  uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  days     int not null default 30,
  eat_out  numeric not null default 0
);

-- ===================== months: one row per user per YYYY-MM =====================
-- income/categories kept as JSONB — they're always loaded/saved as one cohesive
-- form for a single month, never queried piecemeal.

create table if not exists public.months (
  user_id     uuid references auth.users(id) on delete cascade default auth.uid(),
  month_key   text not null,
  income      jsonb not null default '[]'::jsonb,
  categories  jsonb not null default '[]'::jsonb,
  notes       text not null default '',
  goal        numeric not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (user_id, month_key)
);

-- ===================== keyed-note map (currently unused by the app, kept per request) =====================

create table if not exists public.price_change_notes (
  user_id     uuid references auth.users(id) on delete cascade default auth.uid(),
  key         text not null,
  note        text not null default '',
  updated_at  timestamptz not null default now(),
  primary key (user_id, key)
);

-- ===================== independent row lists =====================
-- Each of these is add/remove-one-row-at-a-time in the UI, with manual
-- drag-to-reorder, so each carries an explicit sort_order (Postgres does not
-- preserve insert order). ids are plain text and client-generated (the app's
-- existing uid() helper), not uuid defaults — the client never has to read a
-- generated id back after insert.

create table if not exists public.tech_items (
  id          text primary key,
  user_id     uuid references auth.users(id) on delete cascade default auth.uid(),
  name        text not null default '',
  cost        numeric not null default 0,
  lifespan    numeric,
  sort_order  int not null default 0
);

create table if not exists public.grocery_items (
  id          text primary key,
  user_id     uuid references auth.users(id) on delete cascade default auth.uid(),
  name        text not null default '',
  cost        numeric not null default 0,
  sort_order  int not null default 0
);

create table if not exists public.grocery_item_breakdown (
  id               text primary key,
  grocery_item_id  text not null references public.grocery_items(id) on delete cascade,
  user_id          uuid references auth.users(id) on delete cascade default auth.uid(),
  name             text not null default '',
  cost             numeric not null default 0,
  sort_order       int not null default 0
);
create index if not exists grocery_item_breakdown_parent_idx on public.grocery_item_breakdown(grocery_item_id);

create table if not exists public.mtg_rows (
  id                text primary key,
  user_id           uuid references auth.users(id) on delete cascade default auth.uid(),
  item              text not null default '',
  date_bought       text,  -- free text, not a real date — source data is notes like "April 3-11*, some bought on 3rd..."
  cost              numeric not null default 0,
  expected_revenue  numeric not null default 0,
  sort_order        int not null default 0
);

create table if not exists public.monthly_costs (
  id          text primary key,
  user_id     uuid references auth.users(id) on delete cascade default auth.uid(),
  name        text not null default '',
  cost        numeric not null default 0,
  round_to    numeric not null default 0,  -- 0 = no rounding; otherwise round the monthly cost to the nearest multiple of this
  sort_order  int not null default 0
);

-- ===================== transaction assignment / rule tables =====================

create table if not exists public.tx_assignments (
  tx_id       text not null,
  user_id     uuid references auth.users(id) on delete cascade default auth.uid(),
  cat_id      text,
  item_id     text,
  month_key   text,
  description text,
  item_name   text,
  tx_date     timestamptz,
  tx_amount   numeric,
  excluded    boolean not null default false,
  primary key (user_id, tx_id)
);

create table if not exists public.tx_rules (
  merchant_key         text not null,
  user_id              uuid references auth.users(id) on delete cascade default auth.uid(),
  category_name        text,
  item_name            text,
  threshold            numeric,
  above_category_name  text,
  above_item_name      text,
  primary key (user_id, merchant_key)
);

-- ===================== updated_at triggers =====================

drop trigger if exists set_updated_at on public.user_settings;
create trigger set_updated_at before update on public.user_settings
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.month_template;
create trigger set_updated_at before update on public.month_template
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.ballet;
create trigger set_updated_at before update on public.ballet
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.up_income_source;
create trigger set_updated_at before update on public.up_income_source
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.months;
create trigger set_updated_at before update on public.months
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.price_change_notes;
create trigger set_updated_at before update on public.price_change_notes
  for each row execute function public.set_updated_at();

-- ===================== row level security =====================
-- One "owner" policy per table: a row is only visible/writable by the user
-- it belongs to. auth.uid() = user_id covers select/insert/update/delete.

do $$
declare
  t text;
begin
  foreach t in array array[
    'user_settings','month_template','ballet','up_income_source','grocery_settings',
    'months','price_change_notes','tech_items','grocery_items','grocery_item_breakdown',
    'mtg_rows','monthly_costs','tx_assignments','tx_rules'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I_owner on public.%I', t, t);
    execute format(
      'create policy %I_owner on public.%I for all using (auth.uid() = user_id) with check (auth.uid() = user_id)',
      t, t
    );
  end loop;
end $$;

-- ===================== admin support functions =====================
-- The blanket owner-only RLS above deliberately has no admin exception — user_settings
-- also holds up_token (a plaintext Up Bank API token), so a blanket "admins can read
-- every row" policy would let an admin read other users' bank tokens. Instead, these
-- security definer functions bypass RLS internally but (a) re-check the caller is an
-- admin before doing anything, (b) only ever return/write a hardcoded column allowlist
-- that never includes up_token, and (c) for writes, match the target column against a
-- hardcoded list rather than interpolating client input into SQL.

create or replace function public.admin_list_users()
returns table(
  user_id uuid, email text, display_name text, is_admin boolean,
  feature_tech boolean, feature_grocery boolean, feature_monthlycosts boolean, feature_ballet boolean
)
language plpgsql security definer set search_path = public as $$
begin
  -- Table aliased and columns qualified below because RETURNS TABLE(user_id, ..., is_admin, ...)
  -- above implicitly declares PL/pgSQL variables of those same names, which would otherwise be
  -- ambiguous against user_settings' own user_id/is_admin columns in this unqualified check.
  if not exists (select 1 from public.user_settings us where us.user_id = auth.uid() and us.is_admin) then
    raise exception 'not authorized';
  end if;
  return query
    -- auth.users.email is varchar(255), not text - cast explicitly or Postgres rejects
    -- this with "structure of query does not match function result type".
    select u.id, u.email::text, s.display_name, coalesce(s.is_admin,false), coalesce(s.feature_tech,true),
           coalesce(s.feature_grocery,true), coalesce(s.feature_monthlycosts,true), coalesce(s.feature_ballet,false)
    from auth.users u left join public.user_settings s on s.user_id = u.id
    order by u.created_at asc;
end; $$;

create or replace function public.admin_set_feature(target_user_id uuid, feature_name text, enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.user_settings where user_id = auth.uid() and is_admin) then
    raise exception 'not authorized';
  end if;
  if feature_name not in ('feature_tech','feature_grocery','feature_monthlycosts','feature_ballet') then
    raise exception 'unknown feature';
  end if;
  insert into public.user_settings(user_id) values (target_user_id) on conflict (user_id) do nothing;
  if feature_name = 'feature_tech' then update public.user_settings set feature_tech = enabled where user_id = target_user_id;
  elsif feature_name = 'feature_grocery' then update public.user_settings set feature_grocery = enabled where user_id = target_user_id;
  elsif feature_name = 'feature_monthlycosts' then update public.user_settings set feature_monthlycosts = enabled where user_id = target_user_id;
  elsif feature_name = 'feature_ballet' then update public.user_settings set feature_ballet = enabled where user_id = target_user_id;
  end if;
end; $$;

create or replace function public.admin_set_is_admin(target_user_id uuid, enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.user_settings where user_id = auth.uid() and is_admin) then
    raise exception 'not authorized';
  end if;
  if target_user_id = auth.uid() and not enabled then
    raise exception 'cannot demote your own account';
  end if;
  insert into public.user_settings(user_id) values (target_user_id) on conflict (user_id) do nothing;
  update public.user_settings set is_admin = enabled where user_id = target_user_id;
end; $$;

revoke all on function public.admin_list_users() from public;
revoke all on function public.admin_set_feature(uuid, text, boolean) from public;
revoke all on function public.admin_set_is_admin(uuid, boolean) from public;
grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_set_feature(uuid, text, boolean) to authenticated;
grant execute on function public.admin_set_is_admin(uuid, boolean) to authenticated;
