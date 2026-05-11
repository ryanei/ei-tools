#!/usr/bin/env python3
"""
One-shot migration: Google Sheets → Supabase Postgres.
Idempotent for most tables (uses UPSERT on id). Safe to re-run.

Usage:
    SUPABASE_SECRET_KEY=sb_secret_xxxxx python3 supabase/migrate.py

How to get the secret key:
    Supabase dashboard → Settings → API Keys → Secret keys → "default" → reveal/copy.
    Set it as an env var so it never lands on disk or in git.

Notes:
  - Reads via gviz JSONP (no auth needed — Sheets are public, which is why we're here)
  - Writes via PostgREST with the service-role key (bypasses RLS)
  - 'activity' is plain INSERT (no natural unique key), so re-running will duplicate rows
    in that table. Run it once at final cutover. Other tables UPSERT cleanly.
"""

import os
import sys
import json
import re
import urllib.request
import urllib.parse
import urllib.error

PROJECT_URL = "https://aicrefpmzqkmoksdpqcj.supabase.co"
SECRET_KEY = os.environ.get("SUPABASE_SECRET_KEY")
if not SECRET_KEY:
    print("ERROR: Set SUPABASE_SECRET_KEY env var to your sb_secret_xxx key.", file=sys.stderr)
    print("       In Supabase: Settings → API Keys → Secret keys → default → reveal/copy.", file=sys.stderr)
    print("       Then run: SUPABASE_SECRET_KEY=sb_secret_xxxxx python3 supabase/migrate.py", file=sys.stderr)
    sys.exit(1)

# Sheet IDs (lifted from reference_apps_scripts.md)
SHEET_ACCOUNTS  = "1eKicwsnuaPBK6_cNf8oMScJqGVH4ioQQjkCKNO9-xG4"
SHEET_PROPOSALS = "12JC_3Y52i1qrMcKtXk7dYvzhqyU6RijB6ybq0wNP18M"
SHEET_AUTH      = "1iijkoWwwMUIySNG4yOmc6aVq5jeuvlp_G6-JR0jVRz0"


# ────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────

def parse_gviz_date(v):
    """Convert gviz 'Date(yyyy,mm,dd[,h,m,s])' → ISO string. Returns None for null/empty."""
    if v is None or v == "":
        return None
    if isinstance(v, str) and v.startswith("Date("):
        m = re.match(r'Date\((\d+),(\d+),(\d+)(?:,(\d+),(\d+),(\d+))?', v)
        if m:
            y  = int(m.group(1))
            mo = int(m.group(2)) + 1   # ← gviz months are 0-indexed
            d  = int(m.group(3))
            if m.group(4) is not None:
                h, mi, s = int(m.group(4)), int(m.group(5)), int(m.group(6))
                return f"{y:04d}-{mo:02d}-{d:02d}T{h:02d}:{mi:02d}:{s:02d}Z"
            return f"{y:04d}-{mo:02d}-{d:02d}"
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


def to_text_bool(v):
    """Convert gviz boolean (True/False) → 'TRUE'/'FALSE' string for text-typed columns."""
    if v is True:  return "TRUE"
    if v is False: return "FALSE"
    return None


def fetch_sheet(sheet_id, tab):
    """Fetch a sheet tab via gviz JSONP. Returns (cols, rows) where rows are dicts keyed by column."""
    url = f"https://docs.google.com/spreadsheets/d/{sheet_id}/gviz/tq?tqx=out:json&sheet={urllib.parse.quote(tab)}"
    raw = urllib.request.urlopen(url).read().decode()
    m = re.search(r'setResponse\((.*)\);?\s*$', raw, re.DOTALL)
    data = json.loads(m.group(1))
    if data.get('status') == 'error':
        raise RuntimeError(f"gviz error on {tab}: {data.get('errors')}")
    cols = [c.get('label') or c.get('id') for c in data['table']['cols']]
    out_rows = []
    for r in data['table']['rows']:
        row = {}
        for i, cell in enumerate(r['c']):
            row[cols[i]] = None if cell is None else cell.get('v')
        out_rows.append(row)
    return cols, out_rows


def sheet_has_no_gviz_headers(cols):
    """gviz returns A/B/C/D as column names when the sheet has no header row marker."""
    return cols and all(c in ('A','B','C','D','E','F','G','H','I','J','K','L','M','N','O') for c in cols)


def supabase_request(method, path, body=None, headers_extra=None):
    """Send a request to the Supabase REST API using the service-role key."""
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
    """Drop None values from each row so Postgres column defaults take effect.
    Avoids explicit nulls overriding `not null default now()` columns like created_at."""
    return [{k: v for k, v in r.items() if v is not None} for r in rows]


def _group_by_keys(rows):
    """Group rows that share the same key set. PostgREST batch insert requires
    every row in a batch to have the same shape."""
    from collections import defaultdict
    groups = defaultdict(list)
    for r in rows:
        groups[tuple(sorted(r.keys()))].append(r)
    return list(groups.values())


def upsert(table, rows, on_conflict="id", batch=200):
    """UPSERT rows into a Supabase table via PostgREST. Batches for safety."""
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
                print(f"  ✗ {table}: HTTP {status}: {body[:500]}")
                sys.exit(1)
            total += len(chunk)
    print(f"  ✓ {table}: upserted {total} rows")


def insert(table, rows, batch=200):
    """Plain INSERT (no conflict resolution). Used for activity (no natural unique key)."""
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
                table,
                body=chunk,
                headers_extra={"Prefer": "return=minimal,missing=default"},
            )
            if status >= 400:
                print(f"  ✗ {table}: HTTP {status}: {body[:500]}")
                sys.exit(1)
            total += len(chunk)
    print(f"  ✓ {table}: inserted {total} rows")


# ────────────────────────────────────────────────────────────────────────
# Per-table migrators
# ────────────────────────────────────────────────────────────────────────

def migrate_advertisers():
    print("Advertisers …")
    _, rows = fetch_sheet(SHEET_ACCOUNTS, "Advertisers")
    out = []
    for r in rows:
        if not r.get("id"):
            continue
        out.append({
            "id":                          r["id"],
            "name":                        r.get("name") or "(unnamed)",
            "status":                      r.get("status") or "Active",
            "par_live":                    r.get("par_live") or "No",
            "start_date":                  parse_gviz_date(r.get("start_date")),
            "renewal_date":                parse_gviz_date(r.get("renewal_date")),
            "term_type":                   r.get("term_type") or "Monthly Rolling",
            "fixed_months":                to_int(r.get("fixed_months")),
            "fixed_then_rolling":          to_text_bool(r.get("fixed_then_rolling")),
            "primary_contact_first_name":  r.get("primary_contact_first_name"),
            "primary_contact_last_name":   r.get("primary_contact_last_name"),
            "primary_contact_email":       r.get("primary_contact_email"),
            "created_at":                  parse_gviz_date(r.get("created_at")),
            "updated_at":                  parse_gviz_date(r.get("updated_at")),
        })
    upsert("advertisers", out)


def migrate_contacts():
    print("Contacts …")
    cols, rows = fetch_sheet(SHEET_ACCOUNTS, "Contacts")
    if sheet_has_no_gviz_headers(cols) and rows:
        rows = rows[1:]  # drop the header-as-data row
        col_map = ('A','B','C','D','E','F','G')
    else:
        col_map = None
    out = []
    for r in rows:
        if col_map:
            id_, adv_id, first, last, email = (r.get(c) for c in col_map[:5])
        else:
            id_, adv_id, first, last, email = (
                r.get('id'), r.get('advertiser_id'), r.get('first_name'), r.get('last_name'), r.get('email')
            )
        if not id_:
            continue
        out.append({"id": id_, "advertiser_id": adv_id, "first_name": first, "last_name": last, "email": email})
    upsert("contacts", out)


def migrate_packages():
    print("Packages …")
    _, rows = fetch_sheet(SHEET_ACCOUNTS, "Packages")
    out = []
    for r in rows:
        if not r.get("id"):
            continue
        out.append({
            "id":             r["id"],
            "advertiser_id":  r.get("advertiser_id"),
            "name":           r.get("name"),
            "monthly_price":  to_float(r.get("monthly_price")),
            "status":         r.get("status") or "Active",
            "notes":          r.get("notes"),
            "created_at":     parse_gviz_date(r.get("created_at")),
            "updated_at":     parse_gviz_date(r.get("updated_at")),
        })
    upsert("packages", out)


def migrate_articles():
    print("Articles …")
    _, rows = fetch_sheet(SHEET_ACCOUNTS, "Articles")
    out = []
    for r in rows:
        if not r.get("id"):
            continue
        out.append({
            "id":             r["id"],
            "advertiser_id":  r.get("advertiser_id"),
            "package_id":     r.get("package_id") or None,
            "url":            r.get("url"),
            "position":       to_int(r.get("position")),
            "monthly_price":  to_float(r.get("monthly_price")),
            "active":         bool(r.get("active")) if r.get("active") is not None else True,
            "created_at":     parse_gviz_date(r.get("created_at")),
            "updated_at":     parse_gviz_date(r.get("updated_at")),
        })
    upsert("articles", out)


def migrate_services():
    print("Services …")
    cols, rows = fetch_sheet(SHEET_ACCOUNTS, "Services")
    if sheet_has_no_gviz_headers(cols) and rows:
        rows = rows[1:]
        col_map = ('A','B','C','D','E','F')
    else:
        col_map = None
    out = []
    for r in rows:
        if col_map:
            id_, adv_id, name, details = (r.get(c) for c in col_map[:4])
        else:
            id_, adv_id, name, details = r.get('id'), r.get('advertiser_id'), r.get('name'), r.get('details')
        if not id_:
            continue
        out.append({"id": id_, "advertiser_id": adv_id, "name": name, "details": details})
    upsert("services", out)


def migrate_notes():
    print("Notes …")
    cols, rows = fetch_sheet(SHEET_ACCOUNTS, "Notes")
    if sheet_has_no_gviz_headers(cols) and rows:
        rows = rows[1:]
        col_map = ('A','B','C','D','E','F')  # id, advertiser_id, timestamp, body, author, created_at
    else:
        col_map = None
    out = []
    for r in rows:
        if col_map:
            id_, adv_id, ts, body, author = (r.get(c) for c in col_map[:5])
        else:
            id_, adv_id, ts, body, author = (
                r.get('id'), r.get('advertiser_id'), r.get('timestamp'), r.get('body'), r.get('author')
            )
        if not id_:
            continue
        out.append({
            "id": id_, "advertiser_id": adv_id,
            "timestamp": parse_gviz_date(ts),
            "body": body or "",
            "author": author,
        })
    upsert("notes", out)


def migrate_proposals():
    print("Proposals …")
    _, rows = fetch_sheet(SHEET_PROPOSALS, "Proposals")
    out = []
    for r in rows:
        pid = r.get("Proposal ID")
        if not pid:
            continue
        # Parse the Articles JSON string into a dict so it lands as proper jsonb
        articles_raw = r.get("Articles JSON")
        articles_obj = None
        if articles_raw:
            try:
                articles_obj = json.loads(articles_raw)
            except (json.JSONDecodeError, TypeError):
                articles_obj = {"raw": str(articles_raw)}
        out.append({
            "id":              pid,
            "vendor":          r.get("Vendor"),
            "date_created":    parse_gviz_date(r.get("Date Created")),
            "account_manager": r.get("Account Manager"),
            "contact_email":   r.get("Contact Email"),
            "contract_term":   r.get("Contract Term"),
            "articles_json":   articles_obj,
            "monthly_total":   to_float(r.get("Monthly Total")),
            "discount_pct":    to_float(r.get("Discount %")),
            "status":          r.get("Status") or "Draft",
            "notes":           r.get("Notes"),
            "start_date":      parse_gviz_date(r.get("Start Date")),
            "customer_name":   r.get("Customer Name"),
            "advertiser_id":   r.get("Advertiser ID") or None,
            "stage":           r.get("Stage") or "Discovery",
        })
    upsert("proposals", out)


def migrate_announcements():
    print("Announcements …")
    _, rows = fetch_sheet(SHEET_AUTH, "Announcements")
    out = []
    for r in rows:
        if not r.get("id"):
            continue
        out.append({
            "id":          r["id"],
            "active":      bool(r.get("active")) if r.get("active") is not None else True,
            "version":     r.get("version"),
            "type":        r.get("type") or "update",
            "title":       r.get("title") or "(no title)",
            "message":     r.get("message"),
            "date":        parse_gviz_date(r.get("date")),
            "created_at":  parse_gviz_date(r.get("created_at")),
            "updated_at":  parse_gviz_date(r.get("updated_at")),
        })
    upsert("announcements", out)


def migrate_activity():
    print("Activity …")
    cols, rows = fetch_sheet(SHEET_AUTH, "Activity")
    if sheet_has_no_gviz_headers(cols) and rows:
        rows = rows[1:]  # drop header-as-data
    out = []
    for r in rows:
        # Sheet columns: A=timestamp, B=username, C=page, D=action → mapped to type
        ts = r.get('A')
        username = r.get('B')
        page = r.get('C')
        action = r.get('D')
        if not (ts or username or page or action):
            continue
        out.append({
            "timestamp": parse_gviz_date(ts) or None,
            "username":  username,
            "page":      page,
            "type":      action or "pageview",
        })
    insert("activity", out)


# ────────────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    include_activity = "--include-activity" in sys.argv
    print(f"Migrating Sheets → {PROJECT_URL}")
    print("=" * 64)
    migrate_advertisers()
    migrate_contacts()
    migrate_packages()
    migrate_articles()
    migrate_services()
    migrate_notes()
    migrate_proposals()
    migrate_announcements()
    if include_activity:
        migrate_activity()
    else:
        print("Activity … skipped (pass --include-activity to bring across 701 historical log rows;")
        print("                    safe to do once on final cutover, since INSERT would duplicate on re-run)")
    print("=" * 64)
    print("✓ Migration complete")
