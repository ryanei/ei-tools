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


-- ── 4. Supporting index for the date predicate ────────────────────────
-- (Removed: Postgres won't index `coalesce(timestamptz, timestamptz)::date`
--  because the cast is timezone-dependent (STABLE, not IMMUTABLE). The
--  existing idx_bombora_raw_ingested_at index gets used for ingested_at-only
--  predicates; for the date-bounded filter in get_audience_summary the
--  planner falls back to a seq scan. On 38k rows that's still <100ms.
--  When the table grows past a million rows we'd want to revisit — likely
--  by adding a generated `event_date date` column that we index normally.)


-- ── 5. get_audience_summary() ─────────────────────────────────────────
-- One call returns the entire Audience tab dashboard for a date range:
-- KPIs + weekly chart + top pages + top business domains + every
-- demographic table. Replaces the client-side processData() in
-- reports.html which paginated thousands of raw rows and crunched
-- everything in JS.
--
--   from_date / to_date : inclusive, applied against
--                         coalesce(universal_datetime, ingested_at)::date
--   advertiser_urls     : NULL or empty = no allowlist (All view).
--                         Otherwise each row's normalised path must
--                         match one of these prefixes (exact OR startsWith).
--                         Paths are pre-normalised by the client.
--   limit_domains       : when true (and no advertiser filter), top
--                         business domains is capped at 3 server-side.
--
-- gammagroup.co is hard-excluded for parity with get_intent_summary().
-- ADVERTISER_DOMAINS (vendor exclusion list) stays client-side: edited
-- by humans, changes often, wasteful to ship over the wire.
create or replace function public.get_audience_summary(
  from_date       date,
  to_date         date,
  advertiser_urls text[]  default null,
  limit_domains   boolean default false
)
returns jsonb
language sql
stable
security definer
as $$
with
base as (
  select
    b.bombora_id,
    b.domain,
    coalesce(b.universal_datetime, b.ingested_at)::date as event_date,
    -- URL normalisation: mirrors normalizePath() in reports.html (~line 991)
    (
      with u0 as (select coalesce(b.url, '') as u),
           u1 as (select regexp_replace(u, '^https?://expertinsights\.com', '') as u from u0),
           u2 as (select split_part(split_part(u, '#', 1), '?', 1) as u from u1),
           u3 as (select case when u = '' or u like '/%' then u else '/' || u end as u from u2),
           u4 as (select case when length(u) > 1 and right(u, 1) = '/' then left(u, length(u)-1) else u end as u from u3)
      select lower(u) from u4
    ) as path,
    b.country,
    nullif(btrim(split_part(split_part(coalesce(b.industry, ''), '|', 1), '>', 1)), '') as industry_top,
    nullif(btrim(coalesce(b.company_size, '')),    '') as company_size,
    nullif(btrim(coalesce(b.company_revenue, '')), '') as revenue,
    nullif(btrim(coalesce(b.professional_group, '')), '') as professional_group_raw,
    nullif(btrim(coalesce(b.functional_area, '')), '') as functional_area,
    case
      when lower(coalesce(b.seniority, '')) like '%csuite%'    then 'C-Suite'
      when lower(coalesce(b.seniority, '')) like '%c-suite%'   then 'C-Suite'
      when lower(coalesce(b.seniority, '')) like '%board%'     then 'Management'
      when lower(coalesce(b.seniority, '')) like '%ownership%' then 'Management'
      else nullif(btrim(coalesce(b.seniority, '')), '')
    end as seniority
  from public.bombora_raw b
  where coalesce(b.universal_datetime, b.ingested_at)::date between from_date and to_date
    and lower(btrim(coalesce(b.domain, ''))) <> 'gammagroup.co'
),
f as (
  select b.*
  from base b
  where advertiser_urls is null
     or array_length(advertiser_urls, 1) is null
     or exists (
       select 1 from unnest(advertiser_urls) as a(allowed)
       where b.path = a.allowed
          or b.path like a.allowed || '/%'
     )
),
kpis as (
  select
    count(*)                                          as page_views,
    count(distinct nullif(btrim(bombora_id), ''))     as unique_visitors,
    count(distinct nullif(btrim(domain), ''))         as business_domains
  from f
),
weekly as (
  select
    date_trunc('week', event_date)::date              as week_start,
    count(*)                                          as page_views,
    count(distinct nullif(btrim(bombora_id), ''))     as visitors,
    count(distinct nullif(btrim(domain),     ''))     as domains
  from f
  group by 1 order by 1
),
pages_agg as (
  select
    path,
    count(*)                                          as pv,
    count(distinct nullif(btrim(bombora_id), ''))     as visitors,
    count(distinct nullif(btrim(domain),     ''))     as domains
  from f
  where path is not null and path <> ''
  group by path
),
domain_agg as (
  select
    domain,
    count(*)                                          as pv,
    count(distinct nullif(btrim(bombora_id), ''))     as visitors
  from f
  where coalesce(btrim(domain), '') <> ''
  group by domain
),
domain_cats as (
  -- First path segment per (domain, path), Title Cased.
  select
    domain,
    string_agg(distinct cat_title, ', ' order by cat_title) as categories
  from (
    select
      f.domain,
      initcap(replace(split_part(trim(both '/' from f.path), '/', 1), '-', ' ')) as cat_title
    from f
    where coalesce(btrim(f.domain), '') <> ''
      and f.path is not null and f.path <> ''
      and split_part(trim(both '/' from f.path), '/', 1) <> ''
  ) s
  group by domain
),
domain_table as (
  select d.domain, d.pv, d.visitors, coalesce(c.categories, '') as pages
  from domain_agg d
  left join domain_cats c using (domain)
  order by d.visitors desc, d.pv desc
),
industry_agg as (
  select industry_top as label, count(*) as n
  from f where industry_top is not null
  group by industry_top
  order by n desc
  limit 8
),
size_agg as (
  select company_size as label, count(*) as n
  from f where company_size is not null
  group by company_size
),
size_ordered as (
  -- SIZE_ORDER mirrored from reports.html.
  select o.ord, coalesce(s.label, o.prefix) as label, coalesce(s.n, 0) as n
  from (values (1,'Micro'),(2,'Small'),(3,'Medium-Small'),(4,'Medium'),
               (5,'Medium-Large'),(6,'Large'),(7,'XLarge'),(8,'XXLarge')
       ) o(ord, prefix)
  left join lateral (
    select label, sum(n) as n
    from size_agg
    where label ilike o.prefix || '%'
    group by label
    order by n desc
    limit 1
  ) s on true
  order by o.ord
),
rev_agg as (
  select revenue as label, count(*) as n
  from f where revenue is not null
  group by revenue
),
rev_ordered as (
  -- REV_ORDER mirrored from reports.html (no "Medium" bucket here).
  select o.ord, coalesce(s.label, o.prefix) as label, coalesce(s.n, 0) as n
  from (values (1,'Micro'),(2,'Small'),(3,'Medium-Small'),
               (4,'Medium-Large'),(5,'Large'),(6,'XLarge'),(7,'XXLarge')
       ) o(ord, prefix)
  left join lateral (
    select label, sum(n) as n
    from rev_agg
    where label ilike o.prefix || '%'
    group by label
    order by n desc
    limit 1
  ) s on true
  order by o.ord
),
prof_agg as (
  -- Each row's professional_group is itself '|'-delimited; split first.
  select pg as label, count(*) as n
  from f, lateral unnest(string_to_array(professional_group_raw, '|')) as pg
  where btrim(coalesce(pg, '')) <> ''
  group by pg
  order by n desc
  limit 3
),
func_agg as (
  select functional_area as label, count(*) as n
  from f where functional_area is not null
  group by functional_area
  order by n desc
  limit 3
),
sen_agg as (
  select seniority as label, count(*) as n
  from f where seniority is not null
  group by seniority
  order by n desc
  limit 5
),
region_agg as (
  -- REGION_MAP inline. Unmapped countries go to 'Other' (filtered out below).
  select
    case country
      when 'United States' then 'North America' when 'Canada' then 'North America'
      when 'Mexico' then 'LATAM' when 'Brazil' then 'LATAM' when 'Argentina' then 'LATAM'
      when 'Colombia' then 'LATAM' when 'Chile' then 'LATAM' when 'Peru' then 'LATAM'
      when 'Panama' then 'LATAM' when 'Costa Rica' then 'LATAM' when 'Dominican Republic' then 'LATAM'
      when 'Ecuador' then 'LATAM' when 'Trinidad and Tobago' then 'LATAM' when 'Belize' then 'LATAM'
      when 'Jamaica' then 'LATAM'
      when 'United Kingdom' then 'EMEA' when 'United Kingdom (Great Britain)' then 'EMEA'
      when 'Germany' then 'EMEA' when 'France' then 'EMEA' when 'Spain' then 'EMEA'
      when 'Italy' then 'EMEA' when 'Netherlands' then 'EMEA' when 'Finland' then 'EMEA'
      when 'South Africa' then 'EMEA' when 'Israel' then 'EMEA' when 'Sweden' then 'EMEA'
      when 'Norway' then 'EMEA' when 'Denmark' then 'EMEA' when 'Switzerland' then 'EMEA'
      when 'Poland' then 'EMEA' when 'Belgium' then 'EMEA' when 'Austria' then 'EMEA'
      when 'Ireland' then 'EMEA' when 'Portugal' then 'EMEA' when 'Czech Republic' then 'EMEA'
      when 'Romania' then 'EMEA' when 'Turkey' then 'EMEA' when 'Saudi Arabia' then 'EMEA'
      when 'UAE' then 'EMEA' when 'United Arab Emirates' then 'EMEA' when 'Egypt' then 'EMEA'
      when 'Nigeria' then 'EMEA' when 'Kenya' then 'EMEA' when 'Croatia' then 'EMEA'
      when 'Slovakia' then 'EMEA' when 'Armenia' then 'EMEA' when 'Ghana' then 'EMEA'
      when 'Latvia' then 'EMEA' when 'Bulgaria' then 'EMEA' when 'Lithuania' then 'EMEA'
      when 'Hungary' then 'EMEA' when 'Algeria' then 'EMEA'
      when 'Tanzania, United Republic of' then 'EMEA' when 'Qatar' then 'EMEA'
      when 'Kuwait' then 'EMEA' when 'Ukraine' then 'EMEA' when 'Zambia' then 'EMEA'
      when 'Slovenia' then 'EMEA' when 'Iraq' then 'EMEA' when 'Oman' then 'EMEA'
      when 'Albania' then 'EMEA' when 'Serbia' then 'EMEA' when 'Russian Federation' then 'EMEA'
      when 'Macedonia' then 'EMEA' when 'Greece' then 'EMEA' when 'Malta' then 'EMEA'
      when 'Jordan' then 'EMEA' when 'Morocco' then 'EMEA' when 'Bahrain' then 'EMEA'
      when 'Estonia' then 'EMEA' when 'Cyprus' then 'EMEA' when 'Lesotho' then 'EMEA'
      when 'Kazakhstan' then 'EMEA' when 'Palestinian Territory' then 'EMEA'
      when 'Ethiopia' then 'EMEA' when 'Rwanda' then 'EMEA' when 'Niger' then 'EMEA'
      when 'Lebanon' then 'EMEA' when 'Namibia' then 'EMEA' when 'Mauritius' then 'EMEA'
      when 'Tunisia' then 'EMEA' when 'Luxembourg' then 'EMEA' when 'Angola' then 'EMEA'
      when 'Belarus' then 'EMEA' when 'Madagascar' then 'EMEA'
      when 'Moldova, Republic of' then 'EMEA' when 'Kyrgyzstan' then 'EMEA'
      when 'Uzbekistan' then 'EMEA'
      when 'India' then 'APAC' when 'China' then 'APAC' when 'Japan' then 'APAC'
      when 'Singapore' then 'APAC' when 'Australia' then 'APAC' when 'South Korea' then 'APAC'
      when 'Korea (South)' then 'APAC' when 'Hong Kong' then 'APAC' when 'Taiwan' then 'APAC'
      when 'New Zealand' then 'APAC' when 'Thailand' then 'APAC' when 'Malaysia' then 'APAC'
      when 'Philippines' then 'APAC' when 'Indonesia' then 'APAC' when 'Vietnam' then 'APAC'
      when 'Pakistan' then 'APAC' when 'Bangladesh' then 'APAC' when 'Sri Lanka' then 'APAC'
      when 'Mongolia' then 'APAC' when 'Timor-Leste' then 'APAC' when 'Myanmar' then 'APAC'
      when 'Cambodia' then 'APAC' when 'Papua New Guinea' then 'APAC'
      else 'Other'
    end as region,
    count(*) as n
  from f
  where coalesce(btrim(country), '') <> ''
  group by 1
  order by n desc
  limit 5
)
select jsonb_build_object(
  'pageViews',       (select page_views      from kpis),
  'uniqueVisitors',  (select unique_visitors from kpis),
  'businessDomains', (select business_domains from kpis),
  'weeks', coalesce((
    select jsonb_agg(jsonb_build_object(
      'week',      to_char(week_start, 'YYYY-MM-DD'),
      'label',     to_char(week_start, 'FMMon FMDD'),
      'pageViews', page_views,
      'visitors',  visitors,
      'domains',   domains
    ) order by week_start)
    from weekly
  ), '[]'::jsonb),
  'urlTable', coalesce((
    select jsonb_agg(jsonb_build_object(
      'path', path, 'pv', pv, 'visitors', visitors, 'domains', domains
    ) order by visitors desc, pv desc)
    from (
      select * from pages_agg
      order by visitors desc, pv desc
      limit case
        when advertiser_urls is null or array_length(advertiser_urls, 1) is null
        then 15 else 10000 end
    ) p
  ), '[]'::jsonb),
  'domainTable', coalesce((
    select jsonb_agg(jsonb_build_object(
      'domain', domain, 'pv', pv, 'visitors', visitors, 'pages', pages
    ) order by visitors desc, pv desc)
    from (
      select * from domain_table
      order by visitors desc, pv desc
      limit case
        when advertiser_urls is not null and array_length(advertiser_urls, 1) is not null
        then 10000
        when limit_domains then 3
        else 15
      end
    ) d
  ), '[]'::jsonb),
  'industry',    coalesce((select jsonb_agg(jsonb_build_array(label, n) order by n desc) from industry_agg), '[]'::jsonb),
  'companySize', coalesce((select jsonb_agg(jsonb_build_array(label, n) order by ord)    from size_ordered), '[]'::jsonb),
  'revenue',     coalesce((select jsonb_agg(jsonb_build_array(label, n) order by ord)    from rev_ordered),  '[]'::jsonb),
  'profGroup',   coalesce((select jsonb_agg(jsonb_build_array(label, n) order by n desc) from prof_agg),     '[]'::jsonb),
  'funcArea',    coalesce((select jsonb_agg(jsonb_build_array(label, n) order by n desc) from func_agg),     '[]'::jsonb),
  'seniority',   coalesce((select jsonb_agg(jsonb_build_array(label, n) order by n desc) from sen_agg),      '[]'::jsonb),
  'regions',     coalesce((select jsonb_agg(jsonb_build_array(region, n) order by n desc) from region_agg),  '[]'::jsonb),
  'meta', jsonb_build_object(
    'rowCount',         (select page_views from kpis),
    'fromDate',         to_char(from_date, 'YYYY-MM-DD'),
    'toDate',           to_char(to_date,   'YYYY-MM-DD'),
    'advertiserFilter', advertiser_urls is not null and array_length(advertiser_urls, 1) is not null,
    'limitDomains',     limit_domains
  )
);
$$;

grant execute on function public.get_audience_summary(date, date, text[], boolean)
  to authenticated, service_role;


-- ════════════════════════════════════════════════════════════════════════
-- DONE.
-- ════════════════════════════════════════════════════════════════════════
