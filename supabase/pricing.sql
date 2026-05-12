-- ════════════════════════════════════════════════════════════════════════
-- ei-tools — Plan G: Master Pricing migration (Phase 1 schema)
-- ────────────────────────────────────────────────────────────────────────
-- Three new tables that replace the Master Pricing Google Sheet tab:
--   1. pricing_tiers     — 10-row config (user/impression bands → base prices)
--   2. pricing_articles  — one row per article, with 7 vendor slots (O–U)
--                          each slot stores typed name + optional FK to
--                          advertisers (smart link) + a "proposed" flag.
--   3. pricing_changes   — audit log, populated by trigger on UPDATE.
--
-- Run once in the Supabase SQL editor. Idempotent.
-- ════════════════════════════════════════════════════════════════════════

-- ── 1. PRICING TIERS ───────────────────────────────────────────────────
-- Config table: the 6-row reference (Starter → Enterprise) that maps user
-- AND impression bands to a base price for each position.
--
-- Pricing model (Dual-Axis "Model C"): an article is priced at the HIGHER
-- of its user tier or impression tier. Position prices are multiples of
-- the inclusion price: Pos #1 = 1.75x, Pos #2 = 1.5x, Pos #3 = 1.25x.
-- The Enterprise tier is Price-on-Application (poa = true).
create table if not exists public.pricing_tiers (
  tier              int          primary key check (tier between 1 and 20),
  tier_name         text         not null,
  users_min         int,
  users_max         int,
  impressions_min   int,
  impressions_max   int,
  price_inclusion   numeric(12, 2),
  price_pos3        numeric(12, 2),       -- 1.25x inclusion
  price_pos2        numeric(12, 2),       -- 1.5x  inclusion
  price_pos1        numeric(12, 2),       -- 1.75x inclusion
  poa               boolean      not null default false,
  notes             text,
  updated_at        timestamptz  not null default now()
);

alter table public.pricing_tiers enable row level security;

-- Seed the 6 tiers from the Tier Reference sheet (Dual-Axis Pricing Tiers, Model C).
insert into public.pricing_tiers
  (tier, tier_name,    users_min, users_max, impressions_min, impressions_max,
   price_inclusion, price_pos3, price_pos2, price_pos1, poa)
values
  (1, 'Starter',      0,     25,     0,          2000,        120,  150,  180,  210, false),
  (2, 'Standard',    26,     50,     2001,       5000,        160,  200,  240,  280, false),
  (3, 'Mid',         51,    100,     5001,      10000,        280,  350,  420,  490, false),
  (4, 'High',       101,    200,    10001,      20000,        400,  500,  600,  700, false),
  (5, 'Premium',    201,    400,    20001,      40000,        560,  700,  840,  980, false),
  (6, 'Enterprise', 401, 999999,    40001,  999999999,        null, null, null, null, true)
on conflict (tier) do update set
  tier_name       = excluded.tier_name,
  users_min       = excluded.users_min,
  users_max       = excluded.users_max,
  impressions_min = excluded.impressions_min,
  impressions_max = excluded.impressions_max,
  price_inclusion = excluded.price_inclusion,
  price_pos3      = excluded.price_pos3,
  price_pos2      = excluded.price_pos2,
  price_pos1      = excluded.price_pos1,
  poa             = excluded.poa;

-- ── 2. PRICING ARTICLES ────────────────────────────────────────────────
-- One row per article in the Master Pricing catalogue.
-- Vendor slots O–U live on the same row (matches sheet layout, makes the
-- spreadsheet-style UI a 1:1 render). Each slot has:
--   - vendor_X            : typed display name (free text)
--   - vendor_X_advertiser_id : optional FK to advertisers (smart link)
--   - vendor_X_proposed   : boolean (replaces the " - Proposed" suffix
--                            convention used in the Sheet today)
create table if not exists public.pricing_articles (
  id                  text         primary key,                  -- pa_<short_hash>
  slug                text         not null unique,               -- stable editorial id, derived from URL/title
  category            text,
  title               text         not null,
  pull_url            text,
  date_published      date,

  -- Analytics (denormalised from Users / Impressions sheets)
  users_90d           int,
  impressions_30d     int,

  -- Tier computation (derived but stored for query performance)
  user_tier           int          check (user_tier between 1 and 10),
  imp_tier            int          check (imp_tier between 1 and 10),
  final_tier          int          check (final_tier between 1 and 10),
  upgraded_by_imps    boolean      not null default false,

  -- Prices per position
  price_pos1          numeric(12, 2),
  price_pos2          numeric(12, 2),
  price_pos3          numeric(12, 2),
  price_inclusion     numeric(12, 2),

  -- Pricing flags
  poa                 boolean      not null default false,        -- Price on Application
  custom_pricing      boolean      not null default false,        -- overrides tier-derived price
  archived            boolean      not null default false,

  -- Vendor slot O
  vendor_o                  text,
  vendor_o_advertiser_id    text references public.advertisers(id) on delete set null,
  vendor_o_proposed         boolean not null default false,

  -- Vendor slot P
  vendor_p                  text,
  vendor_p_advertiser_id    text references public.advertisers(id) on delete set null,
  vendor_p_proposed         boolean not null default false,

  -- Vendor slot Q
  vendor_q                  text,
  vendor_q_advertiser_id    text references public.advertisers(id) on delete set null,
  vendor_q_proposed         boolean not null default false,

  -- Vendor slot R
  vendor_r                  text,
  vendor_r_advertiser_id    text references public.advertisers(id) on delete set null,
  vendor_r_proposed         boolean not null default false,

  -- Vendor slot S
  vendor_s                  text,
  vendor_s_advertiser_id    text references public.advertisers(id) on delete set null,
  vendor_s_proposed         boolean not null default false,

  -- Vendor slot T
  vendor_t                  text,
  vendor_t_advertiser_id    text references public.advertisers(id) on delete set null,
  vendor_t_proposed         boolean not null default false,

  -- Vendor slot U
  vendor_u                  text,
  vendor_u_advertiser_id    text references public.advertisers(id) on delete set null,
  vendor_u_proposed         boolean not null default false,

  created_at          timestamptz  not null default now(),
  updated_at          timestamptz  not null default now()
);

create index if not exists idx_pricing_articles_slug         on public.pricing_articles (slug);
create index if not exists idx_pricing_articles_category     on public.pricing_articles (category);
create index if not exists idx_pricing_articles_archived     on public.pricing_articles (archived);
create index if not exists idx_pricing_articles_final_tier   on public.pricing_articles (final_tier);
create index if not exists idx_pricing_articles_vendor_o_fk  on public.pricing_articles (vendor_o_advertiser_id) where vendor_o_advertiser_id is not null;
create index if not exists idx_pricing_articles_vendor_p_fk  on public.pricing_articles (vendor_p_advertiser_id) where vendor_p_advertiser_id is not null;
create index if not exists idx_pricing_articles_vendor_q_fk  on public.pricing_articles (vendor_q_advertiser_id) where vendor_q_advertiser_id is not null;
create index if not exists idx_pricing_articles_vendor_r_fk  on public.pricing_articles (vendor_r_advertiser_id) where vendor_r_advertiser_id is not null;
create index if not exists idx_pricing_articles_vendor_s_fk  on public.pricing_articles (vendor_s_advertiser_id) where vendor_s_advertiser_id is not null;
create index if not exists idx_pricing_articles_vendor_t_fk  on public.pricing_articles (vendor_t_advertiser_id) where vendor_t_advertiser_id is not null;
create index if not exists idx_pricing_articles_vendor_u_fk  on public.pricing_articles (vendor_u_advertiser_id) where vendor_u_advertiser_id is not null;

alter table public.pricing_articles enable row level security;

-- ── 3. PRICING CHANGES (AUDIT LOG) ─────────────────────────────────────
-- One row per column-level change. Populated by a Postgres trigger so
-- nothing can update pricing data without leaving a trail.
create table if not exists public.pricing_changes (
  id            bigserial    primary key,
  table_name    text         not null,       -- 'pricing_articles' | 'pricing_tiers'
  row_id        text         not null,       -- article id (text) or tier number cast to text
  column_name   text         not null,
  old_value     text,
  new_value     text,
  changed_by    text,                        -- email pulled from JWT
  changed_at    timestamptz  not null default now()
);

create index if not exists idx_pricing_changes_row   on public.pricing_changes (table_name, row_id, changed_at desc);
create index if not exists idx_pricing_changes_user  on public.pricing_changes (changed_by, changed_at desc);
create index if not exists idx_pricing_changes_when  on public.pricing_changes (changed_at desc);

alter table public.pricing_changes enable row level security;

-- ── 4. AUDIT TRIGGER FUNCTION ──────────────────────────────────────────
-- Diffs OLD vs NEW column-by-column and writes one pricing_changes row
-- per changed column. Skips housekeeping columns (created_at, updated_at).
create or replace function public.log_pricing_change()
returns trigger
language plpgsql
security definer
as $$
declare
  user_email   text;
  col_name     text;
  old_val      text;
  new_val      text;
  row_id_val   text;
begin
  -- User email from the JWT claims (logged-in user). Falls back to 'system'
  -- if running outside an authenticated request (e.g. migration scripts).
  user_email := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::json->>'email',
    'system'
  );

  -- Different PK columns per table: articles use id (text), tiers use tier (int).
  row_id_val := coalesce(
    (to_jsonb(NEW) ->> 'id'),
    (to_jsonb(NEW) ->> 'tier')
  );

  for col_name in
    select column_name
    from information_schema.columns
    where table_schema = 'public'
      and table_name   = TG_TABLE_NAME
      and column_name not in ('created_at', 'updated_at')
  loop
    old_val := (to_jsonb(OLD) ->> col_name);
    new_val := (to_jsonb(NEW) ->> col_name);
    if old_val is distinct from new_val then
      insert into public.pricing_changes
        (table_name, row_id, column_name, old_value, new_value, changed_by)
      values
        (TG_TABLE_NAME, row_id_val, col_name, old_val, new_val, user_email);
    end if;
  end loop;

  return NEW;
end;
$$;

drop trigger if exists trg_pricing_articles_audit on public.pricing_articles;
create trigger trg_pricing_articles_audit
  after update on public.pricing_articles
  for each row execute function public.log_pricing_change();

drop trigger if exists trg_pricing_tiers_audit on public.pricing_tiers;
create trigger trg_pricing_tiers_audit
  after update on public.pricing_tiers
  for each row execute function public.log_pricing_change();

-- Also log INSERTs (so creating a new article shows up in the history)
create or replace function public.log_pricing_insert()
returns trigger
language plpgsql
security definer
as $$
declare
  user_email   text;
  row_id_val   text;
begin
  user_email := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::json->>'email',
    'system'
  );
  row_id_val := coalesce(
    (to_jsonb(NEW) ->> 'id'),
    (to_jsonb(NEW) ->> 'tier')
  );
  insert into public.pricing_changes
    (table_name, row_id, column_name, old_value, new_value, changed_by)
  values
    (TG_TABLE_NAME, row_id_val, '__created__', null, 'row inserted', user_email);
  return NEW;
end;
$$;

drop trigger if exists trg_pricing_articles_audit_ins on public.pricing_articles;
create trigger trg_pricing_articles_audit_ins
  after insert on public.pricing_articles
  for each row execute function public.log_pricing_insert();

drop trigger if exists trg_pricing_tiers_audit_ins on public.pricing_tiers;
create trigger trg_pricing_tiers_audit_ins
  after insert on public.pricing_tiers
  for each row execute function public.log_pricing_insert();

-- And DELETEs
create or replace function public.log_pricing_delete()
returns trigger
language plpgsql
security definer
as $$
declare
  user_email   text;
  row_id_val   text;
begin
  user_email := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::json->>'email',
    'system'
  );
  row_id_val := coalesce(
    (to_jsonb(OLD) ->> 'id'),
    (to_jsonb(OLD) ->> 'tier')
  );
  insert into public.pricing_changes
    (table_name, row_id, column_name, old_value, new_value, changed_by)
  values
    (TG_TABLE_NAME, row_id_val, '__deleted__',
     coalesce((to_jsonb(OLD) ->> 'title'), (to_jsonb(OLD) ->> 'tier')),
     null, user_email);
  return OLD;
end;
$$;

drop trigger if exists trg_pricing_articles_audit_del on public.pricing_articles;
create trigger trg_pricing_articles_audit_del
  after delete on public.pricing_articles
  for each row execute function public.log_pricing_delete();

drop trigger if exists trg_pricing_tiers_audit_del on public.pricing_tiers;
create trigger trg_pricing_tiers_audit_del
  after delete on public.pricing_tiers
  for each row execute function public.log_pricing_delete();

-- ── 5. AUTO-UPDATE updated_at ──────────────────────────────────────────
-- Reuses the existing public.set_updated_at() function from schema.sql.
drop trigger if exists trg_pricing_articles_updated_at on public.pricing_articles;
create trigger trg_pricing_articles_updated_at
  before update on public.pricing_articles
  for each row execute function public.set_updated_at();

drop trigger if exists trg_pricing_tiers_updated_at on public.pricing_tiers;
create trigger trg_pricing_tiers_updated_at
  before update on public.pricing_tiers
  for each row execute function public.set_updated_at();

-- ── 6. RLS POLICIES ────────────────────────────────────────────────────
-- Matches the existing pattern: permissive 'authenticated_all' policy.
-- Admin-only access is enforced at the UI layer via RESTRICTED_TOOLS in
-- index.html (same as accounts.html and pipeline.html).
drop policy if exists authenticated_all on public.pricing_tiers;
create policy authenticated_all on public.pricing_tiers
  for all to authenticated using (true) with check (true);

drop policy if exists authenticated_all on public.pricing_articles;
create policy authenticated_all on public.pricing_articles
  for all to authenticated using (true) with check (true);

-- pricing_changes: read-only for authenticated users (no manual writes;
-- only the trigger inserts). service_role still has full access via grants.
drop policy if exists authenticated_read on public.pricing_changes;
create policy authenticated_read on public.pricing_changes
  for select to authenticated using (true);

-- ── 7. GRANTS ──────────────────────────────────────────────────────────
-- Required because this project has "Automatically expose new tables" OFF.
grant select, insert, update, delete on public.pricing_tiers    to authenticated, service_role;
grant select, insert, update, delete on public.pricing_articles to authenticated, service_role;
grant select                         on public.pricing_changes  to authenticated;
grant select, insert, update, delete on public.pricing_changes  to service_role;
grant usage, select on sequence public.pricing_changes_id_seq   to authenticated, service_role;

-- ── 8. RECOMPUTE FUNCTION ──────────────────────────────────────────────
-- Recomputes user_tier / imp_tier / final_tier / upgraded_by_imps and the
-- 4 prices for one article (when p_article_id is given) or every non-archived
-- article (when null). Skips price overrides on rows where custom_pricing=true.
-- Returns the number of rows updated.
--
-- Called after CSV upload of the Users (90d) or Impressions (30d) data, and
-- on demand from the front-end when an article's analytics change.
create or replace function public.recompute_pricing(p_article_id text default null)
returns int
language plpgsql
security definer
as $$
declare
  rows_updated int := 0;
begin
  with scope as (
    select id, users_90d, impressions_30d, custom_pricing
    from public.pricing_articles
    where (p_article_id is null or id = p_article_id)
      and archived = false
  ),
  with_tiers as (
    select
      s.id,
      s.custom_pricing,
      (select t.tier
         from public.pricing_tiers t
        where coalesce(s.users_90d, 0)
              between coalesce(t.users_min, 0)
                  and coalesce(t.users_max, 2147483647)
        order by t.tier asc
        limit 1
      ) as user_tier,
      (select t.tier
         from public.pricing_tiers t
        where coalesce(s.impressions_30d, 0)
              between coalesce(t.impressions_min, 0)
                  and coalesce(t.impressions_max, 2147483647)
        order by t.tier asc
        limit 1
      ) as imp_tier
    from scope s
  ),
  computed as (
    select
      id,
      custom_pricing,
      user_tier,
      imp_tier,
      greatest(coalesce(user_tier, 1), coalesce(imp_tier, 1)) as final_tier,
      (coalesce(imp_tier, 0) > coalesce(user_tier, 0)) as upgraded_by_imps
    from with_tiers
  )
  update public.pricing_articles a
     set user_tier        = c.user_tier,
         imp_tier         = c.imp_tier,
         final_tier       = c.final_tier,
         upgraded_by_imps = c.upgraded_by_imps,
         price_inclusion  = case when c.custom_pricing then a.price_inclusion else t.price_inclusion end,
         price_pos3       = case when c.custom_pricing then a.price_pos3      else t.price_pos3      end,
         price_pos2       = case when c.custom_pricing then a.price_pos2      else t.price_pos2      end,
         price_pos1       = case when c.custom_pricing then a.price_pos1      else t.price_pos1      end,
         poa              = case when c.custom_pricing then a.poa             else t.poa             end
    from computed c
    join public.pricing_tiers t on t.tier = c.final_tier
   where a.id = c.id;

  get diagnostics rows_updated = row_count;
  return rows_updated;
end;
$$;

grant execute on function public.recompute_pricing(text) to authenticated, service_role;

-- ════════════════════════════════════════════════════════════════════════
-- DONE. Tables exist, RLS enabled, triggers wired, grants applied,
-- recompute function ready.
-- ════════════════════════════════════════════════════════════════════════
