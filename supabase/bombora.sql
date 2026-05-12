-- ════════════════════════════════════════════════════════════════════════
-- ei-tools — Bombora visitor intent pipeline
-- ────────────────────────────────────────────────────────────────────────
-- Replaces the existing SFTP → Zapier → Google Drive → Bombora Raw Data
-- sheet → Apps Script summariser pipeline with:
--   1. SFTP → Python ingester (GitHub Actions cron) → bombora_raw  (this file)
--   2. Postgres function get_intent_summary() that aggregates on demand
--   3. reports.html Audience tab calls the function
--
-- During the migration the existing Sheets pipeline keeps running as a
-- backup. Once the new path has reconciled cleanly we switch off Zapier
-- and the Apps Scripts.
-- ════════════════════════════════════════════════════════════════════════

-- ── 1. bombora_raw ────────────────────────────────────────────────────
-- One row per Bombora visitor record. Mirrors the daily CSV's 51 columns
-- plus a few ingestion bookkeeping fields.
create table if not exists public.bombora_raw (
  id                 bigserial   primary key,
  ingested_at        timestamptz not null default now(),
  source_file        text,                         -- CSV filename for traceability

  -- Identifiers
  bombora_id         text,
  firstparty_id      text,
  custom_id          text,
  entity_id          text,

  -- Request
  url                text,
  device_type        text,
  user_agent         text,
  interaction_type   text,

  -- Topics (×10) + scores
  topic_1            text,  topic_1_score  numeric,
  topic_2            text,  topic_2_score  numeric,
  topic_3            text,  topic_3_score  numeric,
  topic_4            text,  topic_4_score  numeric,
  topic_5            text,  topic_5_score  numeric,
  topic_6            text,  topic_6_score  numeric,
  topic_7            text,  topic_7_score  numeric,
  topic_8            text,  topic_8_score  numeric,
  topic_9            text,  topic_9_score  numeric,
  topic_10           text,  topic_10_score numeric,

  -- Geography
  country            text,
  state              text,
  zip                text,

  -- Event timing
  universal_datetime timestamptz,
  localized_datetime timestamptz,

  -- Visitor's company (may be null for unresolved visitors)
  domain             text,
  industry           text,
  company_size       text,
  company_revenue    text,

  -- Visitor profile
  professional_group text,
  functional_area    text,
  seniority          text,

  -- Intent topics (×10) — separate concept from Topic 1–10 above
  intent_topic_1     text,
  intent_topic_2     text,
  intent_topic_3     text,
  intent_topic_4     text,
  intent_topic_5     text,
  intent_topic_6     text,
  intent_topic_7     text,
  intent_topic_8     text,
  intent_topic_9     text,
  intent_topic_10    text,

  predictive_signal  text
);

-- Indexes tuned for the summary query (domain + url group-by, date filter)
create index if not exists idx_bombora_raw_ingested_at on public.bombora_raw (ingested_at);
create index if not exists idx_bombora_raw_domain      on public.bombora_raw (domain) where domain is not null and domain <> '';
create index if not exists idx_bombora_raw_domain_url  on public.bombora_raw (domain, lower(url)) where domain is not null and url is not null;
create index if not exists idx_bombora_raw_source_file on public.bombora_raw (source_file);

alter table public.bombora_raw enable row level security;

-- Authenticated users can read; only service_role can write (the ingester uses it)
drop policy if exists authenticated_read on public.bombora_raw;
create policy authenticated_read on public.bombora_raw
  for select to authenticated using (true);

grant select on public.bombora_raw to authenticated;
grant select, insert, update, delete on public.bombora_raw to service_role;
grant usage, select on sequence public.bombora_raw_id_seq to service_role;


-- ── 2. bombora_ingest_log ─────────────────────────────────────────────
-- The ingester checks this before downloading a file. One row per processed file.
create table if not exists public.bombora_ingest_log (
  id              bigserial   primary key,
  filename        text        not null unique,
  bytes           bigint,
  rows_inserted   int,
  duration_ms     int,
  ingested_at     timestamptz not null default now(),
  notes           text
);

create index if not exists idx_bombora_ingest_log_ingested_at on public.bombora_ingest_log (ingested_at desc);

alter table public.bombora_ingest_log enable row level security;

drop policy if exists authenticated_read on public.bombora_ingest_log;
create policy authenticated_read on public.bombora_ingest_log
  for select to authenticated using (true);

grant select on public.bombora_ingest_log to authenticated;
grant select, insert, update, delete on public.bombora_ingest_log to service_role;
grant usage, select on sequence public.bombora_ingest_log_id_seq to service_role;


-- ── 3. get_intent_summary() ───────────────────────────────────────────
-- Replaces the 10am Apps Script summariser. Same semantics:
--   * Filter: rows ingested in the last N days (default 30)
--   * Filter: domain and url non-empty
--   * Filter: domain != 'gammagroup.co' (hardcoded exclusion, kept for parity)
--   * Group by: domain + lower(url)
--   * For each group:
--       - page_views    = count(*)
--       - unique_visitors = count(distinct bombora_id)   ← FIXED: was buggy in Apps Script
--                            (the old logic deduped within each run then summed across
--                            runs, double-counting visitors who returned on different days)
--       - first_seen, last_seen = min/max(ingested_at::date)
--       - industry / company_size / revenue / country / seniority
--           = the value from the row with the latest ingested_at (most recent metadata)
--           - industry has the top-level slice extracted: split by '|' first, then '>'
--       - professional_group = comma-separated list of distinct values across the group
--           (each row's value is itself comma-split before deduping)
create or replace function public.get_intent_summary(
  lookback_days int default 30
)
returns table (
  domain             text,
  url                text,
  industry           text,
  company_size       text,
  revenue            text,
  country            text,
  seniority          text,
  professional_group text,
  unique_visitors    bigint,
  page_views         bigint,
  first_seen         date,
  last_seen          date
)
language sql
stable
security definer
as $$
  with f as (
    select
      btrim(b.domain)        as g_domain,
      btrim(b.url)           as g_url,
      lower(btrim(b.url))    as g_url_key,
      b.bombora_id,
      b.industry,
      b.company_size,
      b.company_revenue,
      b.country,
      b.seniority,
      b.professional_group,
      (b.ingested_at)::date  as event_date
    from public.bombora_raw b
    where b.ingested_at::date >= (current_date - (lookback_days || ' days')::interval)
      and btrim(coalesce(b.domain, '')) <> ''
      and btrim(coalesce(b.url, '')) <> ''
      and lower(btrim(coalesce(b.domain, ''))) <> 'gammagroup.co'
  ),
  latest_meta as (
    select distinct on (g_domain, g_url_key)
      g_domain,
      g_url_key,
      split_part(split_part(industry, '|', 1), '>', 1) as industry,
      company_size,
      company_revenue,
      country,
      seniority
    from f
    order by g_domain, g_url_key, event_date desc
  ),
  pg_distinct as (
    select
      f.g_domain,
      f.g_url_key,
      string_agg(distinct btrim(pg_val), ', ' order by btrim(pg_val)) as professional_group
    from f
    cross join unnest(string_to_array(coalesce(f.professional_group, ''), ',')) as pg_val
    where btrim(coalesce(pg_val, '')) <> ''
    group by f.g_domain, f.g_url_key
  ),
  aggs as (
    select
      g_domain,
      g_url_key,
      (array_agg(g_url order by event_date desc))[1] as g_url_best,
      count(*)                                              as page_views,
      count(distinct nullif(btrim(bombora_id), ''))         as unique_visitors,
      min(event_date)                                       as first_seen,
      max(event_date)                                       as last_seen
    from f
    group by g_domain, g_url_key
  )
  select
    a.g_domain                                        as domain,
    a.g_url_best                                      as url,
    lm.industry                                       as industry,
    lm.company_size                                   as company_size,
    lm.company_revenue                                as revenue,
    lm.country                                        as country,
    lm.seniority                                      as seniority,
    coalesce(pd.professional_group, '')               as professional_group,
    a.unique_visitors                                 as unique_visitors,
    a.page_views                                      as page_views,
    a.first_seen                                      as first_seen,
    a.last_seen                                       as last_seen
  from aggs a
  left join latest_meta lm  on lm.g_domain = a.g_domain and lm.g_url_key = a.g_url_key
  left join pg_distinct pd  on pd.g_domain = a.g_domain and pd.g_url_key = a.g_url_key
  order by a.last_seen desc, a.page_views desc;
$$;

grant execute on function public.get_intent_summary(int) to authenticated, service_role;

-- ════════════════════════════════════════════════════════════════════════
-- DONE.
-- ════════════════════════════════════════════════════════════════════════
