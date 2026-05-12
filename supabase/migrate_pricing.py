#!/usr/bin/env python3
"""
Plan G — Master Pricing migration: Google Sheets → Supabase Postgres.

Reads the Master and Archived Articles tabs on the Proposal Backend sheet
(12JC_3Y52i1qrMcKtXk7dYvzhqyU6RijB6ybq0wNP18M) and upserts into
public.pricing_articles. Idempotent (UPSERT on id).

Usage:
    SUPABASE_SECRET_KEY=sb_secret_xxxxx python3 supabase/migrate_pricing.py

Notes:
  - Run AFTER pricing.sql has been applied (tables must exist).
  - The 6 pricing_tiers rows are seeded by pricing.sql itself — this script
    does not touch them.
  - ID strategy: id = "pa_" + slug. Stable + readable + sortable.
  - Slug is derived from the Pull-URL's last path segment.
  - POA cells in price columns set poa=true and leave prices null.
  - Vendor cells ending in " - Proposed" set vendor_X_proposed=true and
    strip the suffix from the stored name.
  - Vendor advertiser_id linking is left null — the new pricing tool will
    offer "link to advertiser?" inline, and we may also run a one-off
    name-match pass after import.
"""

import os
import sys
import json
import re
import urllib.request
import urllib.parse
import urllib.error
from collections import defaultdict

PROJECT_URL = "https://aicrefpmzqkmoksdpqcj.supabase.co"
SECRET_KEY = os.environ.get("SUPABASE_SECRET_KEY")
if not SECRET_KEY:
    print("ERROR: Set SUPABASE_SECRET_KEY env var to your sb_secret_xxx key.", file=sys.stderr)
    print("       In Supabase: Settings → API Keys → Secret keys → default → reveal/copy.", file=sys.stderr)
    print("       Then run: SUPABASE_SECRET_KEY=sb_secret_xxx python3 supabase/migrate_pricing.py", file=sys.stderr)
    sys.exit(1)

SHEET_PROPOSALS = "12JC_3Y52i1qrMcKtXk7dYvzhqyU6RijB6ybq0wNP18M"

# Column layout (positional, 0-indexed). The Master tab in the source sheet
# has the header in row 1, data from row 2. gviz returns the headers as
# column 'label' when they're plain text; we use positional A/B/C/... as a
# robust fallback since the sheet's header cells include parens, slashes,
# question marks, and other characters that gviz sometimes mangles.
COL_CATEGORY      = 0   # A
COL_TITLE         = 1   # B
COL_PULL_URL      = 2   # C
COL_DATE_PUB      = 3   # D
COL_USERS_90D     = 4   # E
COL_IMPS_30D      = 5   # F
COL_USER_TIER     = 6   # G
COL_IMP_TIER      = 7   # H
COL_FINAL_TIER    = 8   # I
COL_POS1          = 9   # J
COL_POS2          = 10  # K
COL_POS3          = 11  # L
COL_INCLUSION     = 12  # M
COL_UPGRADED      = 13  # N
COL_VENDOR_O      = 14  # O
COL_VENDOR_P      = 15  # P
COL_VENDOR_Q      = 16  # Q
COL_VENDOR_R      = 17  # R
COL_VENDOR_S      = 18  # S
COL_VENDOR_T      = 19  # T
COL_VENDOR_U      = 20  # U


# ────────────────────────────────────────────────────────────────────────
# Helpers (mostly lifted from migrate.py — copying instead of importing to
# keep this script independently runnable)
# ────────────────────────────────────────────────────────────────────────

def parse_gviz_date(v):
    if v is None or v == "":
        return None
    if isinstance(v, str):
        if v.startswith("Date("):
            m = re.match(r'Date\((\d+),(\d+),(\d+)(?:,(\d+),(\d+),(\d+))?', v)
            if m:
                y  = int(m.group(1))
                mo = int(m.group(2)) + 1   # ← gviz months are 0-indexed
                d  = int(m.group(3))
                if m.group(4) is not None:
                    h, mi, s = int(m.group(4)), int(m.group(5)), int(m.group(6))
                    return f"{y:04d}-{mo:02d}-{d:02d}T{h:02d}:{mi:02d}:{s:02d}Z"
                return f"{y:04d}-{mo:02d}-{d:02d}"
            return None
        # Pass through ISO-shaped dates (e.g. '2025-04-30'), drop anything else
        # so we don't shove header strings like 'Date Removed' into date columns.
        if re.match(r'^\d{4}-\d{2}-\d{2}', v):
            return v
        return None
    return v


def to_int(v):
    if v is None or v == "":
        return None
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def to_float(v):
    if v is None or v == "":
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def to_bool(v):
    if v is True:  return True
    if v is False: return False
    if v is None or v == "": return None
    if isinstance(v, str):
        s = v.strip().lower()
        if s in ("true","yes","y","1"):  return True
        if s in ("false","no","n","0"): return False
    return None


def fetch_sheet_positional(sheet_id, tab):
    """Fetch a sheet tab via gviz JSONP and return rows as LISTS (positional),
    not dicts — because the Master tab headers are inconsistent across
    columns and positional indexing is more reliable here."""
    url = f"https://docs.google.com/spreadsheets/d/{sheet_id}/gviz/tq?tqx=out:json&sheet={urllib.parse.quote(tab)}"
    raw = urllib.request.urlopen(url).read().decode()
    m = re.search(r'setResponse\((.*)\);?\s*$', raw, re.DOTALL)
    data = json.loads(m.group(1))
    if data.get('status') == 'error':
        raise RuntimeError(f"gviz error on {tab}: {data.get('errors')}")
    out_rows = []
    for r in data['table']['rows']:
        row = []
        for cell in r['c']:
            row.append(None if cell is None else cell.get('v'))
        out_rows.append(row)
    # gviz already strips the header row when there's one, but it sometimes
    # leaves it as the first data row when headers are weird. We'll detect
    # and strip a likely header row at the parse stage.
    return out_rows


def cell(row, idx):
    """Safe positional access — returns None if the row is shorter than idx."""
    return row[idx] if idx < len(row) else None


def slug_from_url(url):
    """https://expertinsights.com/articles/best-zero-trust-network-access-software/
       → best-zero-trust-network-access-software"""
    if not url:
        return None
    u = str(url).split('?')[0].split('#')[0].rstrip('/')
    parts = [p for p in u.split('/') if p]
    if not parts:
        return None
    last = parts[-1]
    # Already URL-slug shaped in 99% of cases; normalise just to be safe.
    last = re.sub(r'[^A-Za-z0-9\-_]+', '-', last).strip('-')
    return last.lower() or None


def parse_price_or_poa(v):
    """Return (price_or_None, is_poa_bool)."""
    if v is None or v == "":
        return (None, False)
    if isinstance(v, str) and v.strip().upper() == 'POA':
        return (None, True)
    p = to_float(v)
    return (p, False)


def parse_vendor(v):
    """Return (vendor_name_or_None, is_proposed_bool).
       'Acme - Proposed' → ('Acme', True). 'Acme' → ('Acme', False)."""
    if v is None or v == "":
        return (None, False)
    s = str(v).strip()
    if not s:
        return (None, False)
    # The Apps Script writes the suffix exactly as ' - Proposed' (space-dash-space)
    if s.lower().endswith(' - proposed'):
        return (s[:-len(' - proposed')].strip() or None, True)
    return (s, False)


# ────────────────────────────────────────────────────────────────────────
# Supabase write helpers (lifted from migrate.py)
# ────────────────────────────────────────────────────────────────────────

def supabase_request(method, path, body=None, headers_extra=None):
    url = f"{PROJECT_URL}/rest/v1/{path}"
    data = None
    headers = {
        "apikey": SECRET_KEY,
        "Authorization": f"Bearer {SECRET_KEY}",
        "Content-Type": "application/json",
    }
    if headers_extra:
        headers.update(headers_extra)
    if body is not None:
        data = json.dumps(body, default=str).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(req)
        return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def _strip_nulls(rows):
    return [{k: v for k, v in r.items() if v is not None} for r in rows]


def _group_by_keys(rows):
    groups = defaultdict(list)
    for r in rows:
        groups[tuple(sorted(r.keys()))].append(r)
    return list(groups.values())


def upsert(table, rows, on_conflict="id", batch=200):
    if not rows:
        print(f"  · {table}: nothing to insert")
        return
    rows = _strip_nulls(rows)
    total = 0
    for group in _group_by_keys(rows):
        for i in range(0, len(group), batch):
            chunk = group[i:i+batch]
            status, body = supabase_request(
                "POST",
                f"{table}?on_conflict={on_conflict}",
                body=chunk,
                headers_extra={"Prefer": "resolution=merge-duplicates,return=minimal,missing=default"},
            )
            if status >= 400:
                print(f"  ✗ {table}: HTTP {status}: {body[:800]}")
                sys.exit(1)
            total += len(chunk)
    print(f"  ✓ {table}: upserted {total} rows")


# ────────────────────────────────────────────────────────────────────────
# Row parsing
# ────────────────────────────────────────────────────────────────────────

def parse_master_row(row, archived=False):
    """Parse a single Master / Archived row into a pricing_articles dict.
       Returns None if the row is empty or unusable."""
    category = cell(row, COL_CATEGORY)
    title    = cell(row, COL_TITLE)
    pull_url = cell(row, COL_PULL_URL)

    # Skip header rows that gviz didn't strip (varies per tab depending on
    # whether the source sheet has the row styled as a frozen header).
    if isinstance(category, str) and category.strip().lower() == 'category':
        return None
    if isinstance(title, str) and title.strip().lower() in ('title', 'article title'):
        return None
    if isinstance(pull_url, str) and pull_url.strip().lower() in ('pull-url', 'url', 'pull url'):
        return None

    if not title and not pull_url:
        return None  # empty row

    slug = slug_from_url(pull_url) or slug_from_url(title)  # title fallback for slug-less rows
    if not slug:
        return None  # can't identify

    price_pos1, poa1 = parse_price_or_poa(cell(row, COL_POS1))
    price_pos2, poa2 = parse_price_or_poa(cell(row, COL_POS2))
    price_pos3, poa3 = parse_price_or_poa(cell(row, COL_POS3))
    price_inc,  poaI = parse_price_or_poa(cell(row, COL_INCLUSION))
    poa = poa1 or poa2 or poa3 or poaI

    out = {
        "id":                 f"pa_{slug}",
        "slug":               slug,
        "category":           cell(row, COL_CATEGORY),
        "title":              title,
        "pull_url":           pull_url,
        "date_published":     parse_gviz_date(cell(row, COL_DATE_PUB)),
        "users_90d":          to_int(cell(row, COL_USERS_90D)),
        "impressions_30d":    to_int(cell(row, COL_IMPS_30D)),
        "user_tier":          to_int(cell(row, COL_USER_TIER)),
        "imp_tier":           to_int(cell(row, COL_IMP_TIER)),
        "final_tier":         to_int(cell(row, COL_FINAL_TIER)),
        "upgraded_by_imps":   bool(to_bool(cell(row, COL_UPGRADED))) or False,
        "price_pos1":         price_pos1,
        "price_pos2":         price_pos2,
        "price_pos3":         price_pos3,
        "price_inclusion":    price_inc,
        "poa":                poa,
        "custom_pricing":     False,
        "archived":           archived,
    }

    # Vendor slots O–U
    for letter, col_idx in (
        ('o', COL_VENDOR_O),
        ('p', COL_VENDOR_P),
        ('q', COL_VENDOR_Q),
        ('r', COL_VENDOR_R),
        ('s', COL_VENDOR_S),
        ('t', COL_VENDOR_T),
        ('u', COL_VENDOR_U),
    ):
        name, proposed = parse_vendor(cell(row, col_idx))
        out[f"vendor_{letter}"]          = name
        out[f"vendor_{letter}_proposed"] = proposed
        # vendor_X_advertiser_id stays null; we'll backfill via a name-match
        # pass in the tool itself.

    return out


# ────────────────────────────────────────────────────────────────────────
# Per-tab migrators
# ────────────────────────────────────────────────────────────────────────

def migrate_master_tab(tab_name, archived=False, label=None):
    label = label or tab_name
    print(f"{label} …")
    raw_rows = fetch_sheet_positional(SHEET_PROPOSALS, tab_name)
    parsed = []
    skipped_empty = 0
    seen_slugs = {}
    duplicate_slugs = []
    for row in raw_rows:
        out = parse_master_row(row, archived=archived)
        if out is None:
            skipped_empty += 1
            continue
        slug = out["slug"]
        if slug in seen_slugs:
            duplicate_slugs.append((slug, seen_slugs[slug], out["title"]))
            continue
        seen_slugs[slug] = out["title"]
        parsed.append(out)
    if skipped_empty:
        print(f"    (skipped {skipped_empty} empty/headerless rows)")
    if duplicate_slugs:
        print(f"    ⚠  {len(duplicate_slugs)} duplicate slug(s) — kept the first, dropped:")
        for slug, first_title, dup_title in duplicate_slugs[:10]:
            print(f"        {slug}: kept '{first_title}', dropped '{dup_title}'")
        if len(duplicate_slugs) > 10:
            print(f"        … and {len(duplicate_slugs) - 10} more")
    upsert("pricing_articles", parsed)


# ────────────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print(f"Migrating Master Pricing → {PROJECT_URL}")
    print("=" * 64)
    migrate_master_tab("Master",            archived=False, label="Master (active)")
    try:
        migrate_master_tab("Archived Articles", archived=True,  label="Archived Articles")
    except Exception as e:
        print(f"  · Archived Articles: skipped ({e})")
    print("=" * 64)
    print("✓ Pricing migration complete")
