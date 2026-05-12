#!/usr/bin/env python3
"""
Bombora SFTP → Supabase ingester.

Replaces the existing Zapier zap (SFTP → Drive → Sheets) + Apps Script CSV importer
combo. Runs daily as a GitHub Actions cron.

What it does each run:
  1. Connect to Bombora's SFTP with credentials from env vars
  2. List the files in SFTP_DIR
  3. For each file not already in bombora_ingest_log:
       - Download, parse the CSV (the format Bombora sends — 51 columns)
       - Bulk-insert rows into bombora_raw (in batches via PostgREST)
       - Record the file in bombora_ingest_log
  4. Exit. Errors raise non-zero so GitHub Actions surfaces them.

Env vars (set as GitHub Actions secrets):
  BOMBORA_SFTP_HOST      e.g. sftp.bombora.com
  BOMBORA_SFTP_PORT      defaults to 22
  BOMBORA_SFTP_USER
  BOMBORA_SFTP_PASS      (or BOMBORA_SFTP_KEY for SSH key auth — see below)
  BOMBORA_SFTP_DIR       defaults to '.'
  SUPABASE_SECRET_KEY    sb_secret_xxxxx (service-role key)

Local dry-run:
  BOMBORA_SFTP_HOST=… BOMBORA_SFTP_USER=… BOMBORA_SFTP_PASS=… \\
  SUPABASE_SECRET_KEY=sb_secret_xxxxx \\
  python3 supabase/bombora_ingest.py --dry-run

Local single-file run (skip SFTP, ingest a local CSV):
  SUPABASE_SECRET_KEY=sb_secret_xxxxx \\
  python3 supabase/bombora_ingest.py --local-file path/to/file.csv
"""

import os
import sys
import csv
import gzip
import io
import time
import json
import argparse
import urllib.request
import urllib.error

PROJECT_URL = "https://aicrefpmzqkmoksdpqcj.supabase.co"

# CSV column → bombora_raw column mapping. Order matches the daily Bombora feed.
COLUMN_MAP = [
    ("Bombora ID",            "bombora_id",         "text"),
    ("FirstParty ID",         "firstparty_id",      "text"),
    ("Custom ID",             "custom_id",          "text"),
    ("Entity ID",             "entity_id",          "text"),
    ("URL",                   "url",                "text"),
    ("Device_Type",           "device_type",        "text"),
    ("User_Agent",            "user_agent",         "text"),
    ("Interaction Type",      "interaction_type",   "text"),
    ("Topic 1",               "topic_1",            "text"),
    ("Topic 1 Score",         "topic_1_score",      "numeric"),
    ("Topic 2",               "topic_2",            "text"),
    ("Topic 2 Score",         "topic_2_score",      "numeric"),
    ("Topic 3",               "topic_3",            "text"),
    ("Topic 3 Score",         "topic_3_score",      "numeric"),
    ("Topic 4",               "topic_4",            "text"),
    ("Topic 4 Score",         "topic_4_score",      "numeric"),
    ("Topic 5",               "topic_5",            "text"),
    ("Topic 5 Score",         "topic_5_score",      "numeric"),
    ("Topic 6",               "topic_6",            "text"),
    ("Topic 6 Score",         "topic_6_score",      "numeric"),
    ("Topic 7",               "topic_7",            "text"),
    ("Topic 7 Score",         "topic_7_score",      "numeric"),
    ("Topic 8",               "topic_8",            "text"),
    ("Topic 8 Score",         "topic_8_score",      "numeric"),
    ("Topic 9",               "topic_9",            "text"),
    ("Topic 9 Score",         "topic_9_score",      "numeric"),
    ("Topic 10",              "topic_10",           "text"),
    ("Topic 10 Score",        "topic_10_score",     "numeric"),
    ("Country",               "country",            "text"),
    ("State",                 "state",              "text"),
    ("Zip",                   "zip",                "text"),
    ("Universal Date/Time",   "universal_datetime", "bombora_dt"),
    ("Localized Date/Time",   "localized_datetime", "bombora_dt"),
    ("Domain",                "domain",             "text"),
    ("Intent Topic 1",        "intent_topic_1",     "text"),
    ("Intent Topic 2",        "intent_topic_2",     "text"),
    ("Intent Topic 3",        "intent_topic_3",     "text"),
    ("Intent Topic 4",        "intent_topic_4",     "text"),
    ("Intent Topic 5",        "intent_topic_5",     "text"),
    ("Intent Topic 6",        "intent_topic_6",     "text"),
    ("Intent Topic 7",        "intent_topic_7",     "text"),
    ("Intent Topic 8",        "intent_topic_8",     "text"),
    ("Intent Topic 9",        "intent_topic_9",     "text"),
    ("Intent Topic 10",       "intent_topic_10",    "text"),
    ("Industry",              "industry",           "text"),
    ("Company_Size",          "company_size",       "text"),
    ("Company_Revenue",       "company_revenue",    "text"),
    ("Professional_Group",    "professional_group", "text"),
    ("Functional_Area",       "functional_area",    "text"),
    ("Seniority",             "seniority",          "text"),
    ("Predictive_Signal",     "predictive_signal",  "text"),
]

BATCH_SIZE = 500   # rows per PostgREST request — Supabase happily handles much more
                   # but 500 keeps each request well under timeout and memory limits


# ────────────────────────────────────────────────────────────────────────
# Parsers
# ────────────────────────────────────────────────────────────────────────

def parse_bombora_dt(s):
    """20260511T03:41:33.183 → 2026-05-11T03:41:33.183Z (ISO 8601 string).
       Returns None for empty / unparseable values."""
    if not s:
        return None
    s = s.strip()
    if not s:
        return None
    # Expected form: YYYYMMDDTHH:MM:SS[.fff]
    if len(s) >= 9 and s[8] == 'T':
        date_part = s[:8]
        time_part = s[9:]
        try:
            int(date_part)
            return f"{date_part[:4]}-{date_part[4:6]}-{date_part[6:8]}T{time_part}Z"
        except ValueError:
            pass
    return None  # don't shove garbage into a timestamp column


def parse_numeric(s):
    if s is None or s == "":
        return None
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def parse_text(s):
    if s is None:
        return None
    s = s.strip()
    return s if s else None


def parse_row(row_dict):
    """Convert one CSV row (dict keyed by source-column name) into a bombora_raw row
       (dict keyed by DB column name)."""
    out = {}
    for src, dst, ctype in COLUMN_MAP:
        v = row_dict.get(src)
        if ctype == "numeric":
            out[dst] = parse_numeric(v)
        elif ctype == "bombora_dt":
            out[dst] = parse_bombora_dt(v)
        else:
            out[dst] = parse_text(v)
    return out


# ────────────────────────────────────────────────────────────────────────
# Supabase REST
# ────────────────────────────────────────────────────────────────────────

def sb_request(method, path, body=None, headers_extra=None, secret_key=None):
    url = f"{PROJECT_URL}/rest/v1/{path}"
    data = None
    headers = {
        "apikey": secret_key,
        "Authorization": f"Bearer {secret_key}",
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


def processed_filenames(secret_key):
    """Return the set of filenames already in bombora_ingest_log."""
    status, body = sb_request(
        "GET",
        "bombora_ingest_log?select=filename",
        secret_key=secret_key,
    )
    if status >= 400:
        print(f"  ✗ Failed to read ingest log: HTTP {status}: {body[:300]}", file=sys.stderr)
        sys.exit(1)
    rows = json.loads(body)
    return {r["filename"] for r in rows}


def insert_rows(rows, source_file, secret_key):
    """Bulk-insert into bombora_raw in chunks of BATCH_SIZE.
       parse_row() produces uniform shape (all 51 keys, with None for empty
       fields), so we don't strip nulls — that would create variable-shape
       batches and PostgREST rejects those with PGRST102 "All object keys
       must match". Nullable columns happily accept JSON null."""
    if not rows:
        return 0
    payload = [{**r, "source_file": source_file} for r in rows]
    inserted = 0
    for i in range(0, len(payload), BATCH_SIZE):
        chunk = payload[i:i + BATCH_SIZE]
        status, body = sb_request(
            "POST",
            "bombora_raw",
            body=chunk,
            headers_extra={"Prefer": "return=minimal"},
            secret_key=secret_key,
        )
        if status >= 400:
            print(f"  ✗ Insert failed at offset {i}: HTTP {status}: {body[:500]}", file=sys.stderr)
            sys.exit(1)
        inserted += len(chunk)
    return inserted


def log_ingest(filename, bytes_len, rows_inserted, duration_ms, notes, secret_key):
    status, body = sb_request(
        "POST",
        "bombora_ingest_log",
        body=[{
            "filename": filename,
            "bytes": bytes_len,
            "rows_inserted": rows_inserted,
            "duration_ms": duration_ms,
            "notes": notes or None,
        }],
        headers_extra={"Prefer": "return=minimal"},
        secret_key=secret_key,
    )
    if status >= 400:
        print(f"  ✗ Failed to write ingest log: HTTP {status}: {body[:300]}", file=sys.stderr)
        sys.exit(1)


# ────────────────────────────────────────────────────────────────────────
# CSV → rows
# ────────────────────────────────────────────────────────────────────────

def parse_csv_text(text):
    """Parse the CSV text into a list of bombora_raw row dicts.
       Uses csv.DictReader so quoted fields with commas are handled correctly."""
    reader = csv.DictReader(io.StringIO(text))
    rows = []
    for raw in reader:
        rows.append(parse_row(raw))
    return rows


# ────────────────────────────────────────────────────────────────────────
# SFTP
# ────────────────────────────────────────────────────────────────────────

def _is_dir(entry):
    """Whether an SFTPAttributes entry is a directory."""
    return entry.st_mode is not None and (entry.st_mode & 0o170000) == 0o040000


def list_and_fetch_sftp(host, port, user, password, key_text, remote_dir, verbose=False, fetch=True):
    """Connect, navigate to remote_dir, list .csv files. If fetch=True, also
       download them. If verbose=True, print the full directory listing
       (files + dirs) and peek into any subdirectories one level deep.

       Returns (filename, bytes_content) tuples; bytes_content is None if
       fetch=False."""
    try:
        import paramiko
    except ImportError:
        print("ERROR: paramiko is not installed. Run: pip install paramiko", file=sys.stderr)
        sys.exit(1)

    transport = paramiko.Transport((host, port))
    try:
        if key_text:
            import io as _io
            pkey = paramiko.RSAKey.from_private_key(_io.StringIO(key_text))
            transport.connect(username=user, pkey=pkey)
        else:
            transport.connect(username=user, password=password)
        sftp = paramiko.SFTPClient.from_transport(transport)
        try:
            sftp.chdir(remote_dir)
            cwd = sftp.getcwd()
            entries = sftp.listdir_attr()

            if verbose:
                print(f"  · cwd after chdir({remote_dir!r}): {cwd}")
                print(f"  · {len(entries)} entries in {cwd}:")
                for e in sorted(entries, key=lambda x: (not _is_dir(x), x.filename)):
                    kind = "DIR " if _is_dir(e) else "file"
                    size = "" if _is_dir(e) else f"  {e.st_size:>14,} bytes"
                    print(f"      {kind}  {e.filename}{size}")
                # Peek into any subdirectories one level deep, so we can see if
                # Bombora drops files in /outbox/ or /visitor_insight/ etc.
                for e in entries:
                    if not _is_dir(e):
                        continue
                    try:
                        sub = sftp.listdir_attr(e.filename)
                    except IOError as ex:
                        print(f"      (couldn't list {e.filename}: {ex})")
                        continue
                    print(f"  · {len(sub)} entries inside {e.filename}/:")
                    for s in sorted(sub, key=lambda x: (not _is_dir(x), x.filename))[:30]:
                        kind = "DIR " if _is_dir(s) else "file"
                        size = "" if _is_dir(s) else f"  {s.st_size:>14,} bytes"
                        print(f"      {kind}  {e.filename}/{s.filename}{size}")
                    if len(sub) > 30:
                        print(f"      … and {len(sub) - 30} more")

            files = []
            for e in entries:
                if _is_dir(e):
                    continue
                fn = e.filename.lower()
                # Bombora ships .csv.gz; accept plain .csv too just in case
                if not (fn.endswith(".csv") or fn.endswith(".csv.gz")):
                    continue
                files.append(e.filename)
            files.sort()

            if not fetch:
                return [(f, None) for f in files]

            out = []
            for f in files:
                buf = io.BytesIO()
                sftp.getfo(f, buf)
                out.append((f, buf.getvalue()))
            return out
        finally:
            sftp.close()
    finally:
        transport.close()


# ────────────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────────────

def run_local_file(path, secret_key):
    """Ingest a single CSV from disk. Convenience for backfill / debugging."""
    filename = os.path.basename(path)
    print(f"Local file mode: {filename}")
    already = processed_filenames(secret_key)
    if filename in already:
        print(f"  · {filename}: already in ingest log; skipping")
        return
    with open(path, "rb") as fh:
        content = fh.read()
    process_file(filename, content, secret_key)


def process_file(filename, content, secret_key):
    t0 = time.time()
    bytes_len = len(content)
    # Bombora ships .csv.gz — decompress transparently
    if filename.lower().endswith(".gz"):
        try:
            content = gzip.decompress(content)
        except OSError as e:
            print(f"  ✗ {filename}: gzip decompression failed: {e}", file=sys.stderr)
            log_ingest(filename, bytes_len, 0, int((time.time() - t0) * 1000),
                       f"gzip decompression failed: {e}", secret_key)
            return
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        text = content.decode("utf-8", errors="replace")
    rows = parse_csv_text(text)
    if not rows:
        print(f"  · {filename}: empty CSV, skipping")
        log_ingest(filename, bytes_len, 0, int((time.time() - t0) * 1000), "empty CSV", secret_key)
        return
    inserted = insert_rows(rows, filename, secret_key)
    duration_ms = int((time.time() - t0) * 1000)
    log_ingest(filename, bytes_len, inserted, duration_ms, None, secret_key)
    print(f"  ✓ {filename}: {inserted} rows, {bytes_len:,} bytes, {duration_ms} ms")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="Connect + list files but don't insert / log")
    parser.add_argument("--local-file", help="Ingest a local CSV file (skips SFTP)")
    args = parser.parse_args()

    secret_key = os.environ.get("SUPABASE_SECRET_KEY")
    if not secret_key:
        print("ERROR: SUPABASE_SECRET_KEY env var is required.", file=sys.stderr)
        sys.exit(1)

    if args.local_file:
        run_local_file(args.local_file, secret_key)
        return

    # GitHub Actions sets unset secrets to '' (not unset/None), so use `or DEFAULT`
    # rather than the dict default to fall back when the secret is empty.
    host = (os.environ.get("BOMBORA_SFTP_HOST") or "").strip()
    user = (os.environ.get("BOMBORA_SFTP_USER") or "").strip()
    password = os.environ.get("BOMBORA_SFTP_PASS") or None
    key_text = os.environ.get("BOMBORA_SFTP_KEY") or None
    port = int((os.environ.get("BOMBORA_SFTP_PORT") or "22").strip())
    remote_dir = (os.environ.get("BOMBORA_SFTP_DIR") or ".").strip()

    missing = [k for k, v in [
        ("BOMBORA_SFTP_HOST", host),
        ("BOMBORA_SFTP_USER", user),
    ] if not v]
    if not password and not key_text:
        missing.append("BOMBORA_SFTP_PASS or BOMBORA_SFTP_KEY")
    if missing:
        print(f"ERROR: missing env vars: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    print(f"Connecting to {user}@{host}:{port} (dir: {remote_dir})")
    files = list_and_fetch_sftp(
        host, port, user, password, key_text, remote_dir,
        verbose=args.dry_run,           # full directory listing only in dry-run
        fetch=not args.dry_run,         # don't download in dry-run
    )
    print(f"  · {len(files)} CSV file(s) directly in {remote_dir!r}")

    if args.dry_run:
        for f, _ in files:
            print(f"    [dry-run] {f}")
        return

    already = processed_filenames(secret_key)
    new = [(f, c) for f, c in files if f not in already]
    if not new:
        print("  · No new files to ingest")
        return
    print(f"  · {len(new)} new file(s) to ingest")
    for filename, content in new:
        process_file(filename, content, secret_key)
    print("✓ Bombora ingest complete")


if __name__ == "__main__":
    main()
