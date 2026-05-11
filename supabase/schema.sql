-- ════════════════════════════════════════════════════════════════════════
-- ei-tools schema v1
-- ────────────────────────────────────────────────────────────────────────
-- Mirrors the 9 Google Sheet tabs that previously held this data.
-- Run once in the Supabase SQL editor (Database → SQL Editor → + New query).
-- Idempotent (uses CREATE TABLE IF NOT EXISTS) so it's safe to re-run.
--
-- ID strategy: keep the existing text IDs (adv_xxx, pkg_xxx, etc.) rather
-- than rewriting to UUIDs. Lower migration risk, preserves existing URLs
-- (e.g. accounts.html?id=adv_mov8s2dt29n), and the team can read them.
--
-- RLS: enabled on every table at creation. No policies yet — that means
-- default-deny for anyone using the publishable key. We'll add policies
-- after deciding the auth model. The service_role key bypasses RLS, so
-- the data migration will still work.
-- ════════════════════════════════════════════════════════════════════════

-- ── 1. ADVERTISERS ─────────────────────────────────────────────────────
create table if not exists public.advertisers (
  id                            text        primary key,
  name                          text        not null,
  status                        text        not null default 'Active',
  par_live                      text        not null default 'No',
  start_date                    date,
  renewal_date                  date,
  term_type                     text        not null default 'Monthly Rolling',
  fixed_months                  int,
  fixed_then_rolling            text,           -- 'TRUE' / 'FALSE' / null  (kept as text for compat)
  primary_contact_first_name    text,
  primary_contact_last_name     text,
  primary_contact_email         text,
  created_at                    timestamptz not null default now(),
  updated_at                    timestamptz not null default now()
);

create index if not exists idx_advertisers_status        on public.advertisers (status);
create index if not exists idx_advertisers_renewal_date  on public.advertisers (renewal_date) where renewal_date is not null;
create index if not exists idx_advertisers_term_type     on public.advertisers (term_type);

alter table public.advertisers enable row level security;

-- ── 2. CONTACTS ────────────────────────────────────────────────────────
create table if not exists public.contacts (
  id              text  primary key,
  advertiser_id   text  not null references public.advertisers(id) on delete cascade,
  first_name      text,
  last_name       text,
  email           text
);

create index if not exists idx_contacts_advertiser_id on public.contacts (advertiser_id);

alter table public.contacts enable row level security;

-- ── 3. PACKAGES ────────────────────────────────────────────────────────
create table if not exists public.packages (
  id              text        primary key,
  advertiser_id   text        not null references public.advertisers(id) on delete cascade,
  name            text,
  monthly_price   numeric(12, 2),
  status          text        not null default 'Active',
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists idx_packages_advertiser_id on public.packages (advertiser_id);
create index if not exists idx_packages_status        on public.packages (status);

alter table public.packages enable row level security;

-- ── 4. ARTICLES ────────────────────────────────────────────────────────
create table if not exists public.articles (
  id              text        primary key,
  advertiser_id   text        not null references public.advertisers(id) on delete cascade,
  package_id      text                 references public.packages(id)    on delete set null,
  url             text,
  position        int,
  monthly_price   numeric(12, 2),
  active          boolean     not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists idx_articles_advertiser_id on public.articles (advertiser_id);
create index if not exists idx_articles_package_id    on public.articles (package_id) where package_id is not null;
create index if not exists idx_articles_position      on public.articles (position);

alter table public.articles enable row level security;

-- ── 5. SERVICES ────────────────────────────────────────────────────────
create table if not exists public.services (
  id              text  primary key,
  advertiser_id   text  not null references public.advertisers(id) on delete cascade,
  name            text,
  details         text
);

create index if not exists idx_services_advertiser_id on public.services (advertiser_id);

alter table public.services enable row level security;

-- ── 6. NOTES ───────────────────────────────────────────────────────────
create table if not exists public.notes (
  id              text         primary key,
  advertiser_id   text         not null references public.advertisers(id) on delete cascade,
  body            text         not null,
  author          text,
  timestamp       timestamptz  not null default now()
);

create index if not exists idx_notes_advertiser_id on public.notes (advertiser_id);
create index if not exists idx_notes_timestamp     on public.notes (timestamp desc);

alter table public.notes enable row level security;

-- ── 7. PROPOSALS ───────────────────────────────────────────────────────
create table if not exists public.proposals (
  id                text         primary key,                -- format: PROP-YYYYMMDD-HHmmss
  vendor            text,
  date_created      timestamptz  not null default now(),
  account_manager   text,
  contact_email     text,
  contract_term     text,
  articles_json     jsonb,                                   -- was text in Sheets; jsonb for queryability
  monthly_total     numeric(12, 2),
  discount_pct      numeric(5, 2),
  status            text         not null default 'Draft',   -- Draft / Sent / Accepted / Rejected
  notes             text,
  start_date        date,
  customer_name     text,
  advertiser_id     text                  references public.advertisers(id) on delete set null,
  stage             text         not null default 'Discovery', -- Discovery / Proposal / Negotiation / Closed Won / Closed Lost
  updated_at        timestamptz  not null default now()
);

create index if not exists idx_proposals_status         on public.proposals (status);
create index if not exists idx_proposals_stage          on public.proposals (stage);
create index if not exists idx_proposals_advertiser_id  on public.proposals (advertiser_id) where advertiser_id is not null;
create index if not exists idx_proposals_date_created   on public.proposals (date_created desc);

alter table public.proposals enable row level security;

-- ── 8. ACTIVITY ─────────────────────────────────────────────────────────
-- Replaces the Activity tab on the Auth Handle sheet. Page-view + login log.
create table if not exists public.activity (
  id          bigserial   primary key,
  username    text,
  page        text,
  type        text        not null default 'pageview',
  timestamp   timestamptz not null default now()
);

create index if not exists idx_activity_timestamp on public.activity (timestamp desc);
create index if not exists idx_activity_username  on public.activity (username);

alter table public.activity enable row level security;

-- ── 9. ANNOUNCEMENTS ────────────────────────────────────────────────────
create table if not exists public.announcements (
  id            text         primary key,
  active        boolean      not null default true,
  version       text,
  type          text         not null default 'update',     -- update / heads-up / outage
  title         text         not null,
  message       text,
  date          date,
  created_at    timestamptz  not null default now(),
  updated_at    timestamptz  not null default now()
);

create index if not exists idx_announcements_active on public.announcements (active, date desc);

alter table public.announcements enable row level security;

-- ── Auto-update updated_at trigger ──────────────────────────────────────
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
declare t text;
begin
  for t in
    select unnest(array['advertisers','packages','articles','proposals','announcements'])
  loop
    execute format(
      'drop trigger if exists trg_%I_updated_at on public.%I',
      t, t
    );
    execute format(
      'create trigger trg_%I_updated_at before update on public.%I for each row execute function public.set_updated_at()',
      t, t
    );
  end loop;
end$$;

-- ════════════════════════════════════════════════════════════════════════
-- DONE. Tables exist, RLS enabled, no policies yet.
-- Next steps:
--   1. Decide auth model (Google OAuth / magic link / email+password)
--   2. Add RLS policies based on that choice
--   3. Migrate data from Sheets
--   4. Refactor front-end to use supabase-js
-- ════════════════════════════════════════════════════════════════════════
