# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ei-tools` is an internal sales/campaign tools site for **Expert Insights**, hosted as static HTML on **GitHub Pages** at https://ryanei.github.io/ei-tools/. There is no build step, no bundler, no package.json — every page is a single self-contained HTML file with inline `<style>` and `<script>` blocks.

The site has five tool pages plus a login screen:

| Page | Purpose |
|---|---|
| `login.html` | Magic-link sign-in (Supabase Auth) |
| `index.html` | Hub — announcements, snapshot widgets, tool launcher |
| `accounts.html` | Advertiser/campaign database — biggest page, full CRUD |
| `proposals.html` | Proposal builder + dashboard + PDF/IO generation |
| `reports.html` | Audience analytics (Bombora) + Revenue dashboard |
| `pipeline.html` | **Parked, not in use.** Do not delete — see "Workflow rules" |

`dashboard.html` is a meta-refresh redirect to `reports.html` (legacy URL preservation).

## Deploy workflow

**Push directly to `origin/main`.** No PRs, no feature branches. GitHub Pages auto-deploys from `main`, takes ~30s.

```bash
git add <files>
git commit -m "..."
git push origin HEAD:main
```

The user works in a git worktree at `.claude/worktrees/stoic-murdock-151142/`. Commits pushed from the worktree go to `origin/main`. The user's own local clone at `/Users/ryan/Desktop/ei-tools/` is frequently behind — they run `git pull` when they need fresh files locally.

There are no tests, no linters, no typecheck. Verification is done by previewing with `python3 -m http.server` (via Claude Preview MCP — see `.claude/launch.json`) and clicking through, then pushing.

## Architecture — the big picture

The site is mid-migration from **Google Sheets + Apps Script Web Apps** to **Supabase** (Postgres + Auth). Both backends are live simultaneously in a deliberate hybrid; see "Migration state" below.

### Front-end pattern

Every page is a single HTML file containing:
- `<head>` with Google Fonts (Inter Tight, Fraunces, JetBrains Mono), inline CSS using EI Blue tokens, and deferred `<script>` tags for `supabase-js` (CDN) + `supabase-client.js` (local).
- An auth gate IIFE at the top of `<body>` that calls `await window.eitools.requireAuth()` and redirects to `login.html` if there's no Supabase session.
- The page UI markup.
- Inline `<script>` blocks at the bottom for page logic.
- Trailing shared snippets pasted before `</body>`: the **Cmd+K command palette** and the **toast/confirm dialog** system, each scoped under their own CSS classes and self-initialising IIFEs. These two snippets appear on all five pages and must stay in sync if you change them.

`supabase-client.js` exposes `window.eitools` with:
- `sb` — the Supabase JS client instance
- `requireAuth()` — the auth gate (redirects to `login.html` on miss)
- `getUser()` — current user or null
- `logActivity(page, type)` — best-effort `activity` row insert
- `signOut()` — sign out and bounce to login

Per-page data helpers (e.g. `sbLoadAccounts`, `sbSaveAdvertiserBundle`, `sbListProposals`) are defined inline at the top of each page's script block. They are not shared across pages.

### Backend

**Supabase project:** `https://aicrefpmzqkmoksdpqcj.supabase.co`. Postgres schema in `supabase/schema.sql`:

- 9 tables: `advertisers`, `contacts`, `packages`, `articles`, `services`, `notes`, `proposals`, `activity`, `announcements`.
- IDs are **text** in the existing format (`adv_xxx`, `pkg_xxx`, `PROP-YYYYMMDD-HHmmss`) — not UUIDs — to preserve deep links and avoid an ID rewrite during migration.
- All tables have RLS enabled with a single permissive policy `authenticated_all`. Anonymous users hit 401 on everything.
- The Supabase project was created with "Automatically expose new tables" **off**, so new tables require explicit `GRANT SELECT, INSERT, UPDATE, DELETE` to `authenticated` and `service_role` (already done for the current 9).
- `articles_json` on `proposals` is `jsonb` (not text) — `_propFromSupabase` in `proposals.html` stringifies it on read for compatibility with `parseProposalData`.
- Date and timestamp columns are real `date` / `timestamptz`. Supabase returns ISO strings; `fmtDate()` helpers handle both ISO and the legacy `Date(yyyy,mm,dd,…)` gviz format.

**Auth:** Supabase Auth with email magic link, **implicit flow** (`flowType: 'implicit'` in `supabase-client.js`). PKCE was tried first but broke when users clicked the email link from Outlook — the OS opens the link in the default browser, which doesn't have the PKCE `code_verifier` from the original incognito session. Implicit flow puts the access token in the URL hash so any browser can complete sign-in.

### Migration state (mid-Phase 3)

Critical customer data (advertisers, proposals, articles, packages) is fully on Supabase. The following Apps Scripts are **deliberately kept alive** for specific side effects:

| Apps Script | Sheet | Why still alive |
|---|---|---|
| Auth Handle | `1iijkoWwwMUIySNG4yOmc6aVq5jeuvlp_G6-JR0jVRz0` | `saveAnnouncement` triggers a Slack webhook (URL only in the script, not in the repo). Activity logging is also still wired through here from `index.html`'s legacy paths. |
| Proposal Backend | `12JC_3Y52i1qrMcKtXk7dYvzhqyU6RijB6ybq0wNP18M` | `updateStatus` and `delete` write articles into the **Master Pricing** tab on the same sheet — the editorial source of truth that the rest of `expertinsights.com` reads. proposals.html does **both** a Supabase mutation (primary) and an Apps Script POST (best-effort side effect). |
| EI Accounts API | `1eKicwsnuaPBK6_cNf8oMScJqGVH4ioQQjkCKNO9-xG4` | Unused after Phase 3b. Will be archived at cutover. |

The Bombora visitor-analytics sheet (`12QD-qlPFpsUcpH_etqOolBGGURzYqoofXHPsWAwWFNw`) is read via gviz JSONP on `reports.html` (Audience tab). Not migrated — separate dataset, separate problem, lower-stakes.

`index.html` contains a **transitional bridge** that converts a Supabase session into the legacy `localStorage.eitools_session` shape, so hub internal logic (announcements load/save, the visible old login form's `doLogout`) keeps working. The bridge will be removed in Phase 4 when announcements and activity move off Apps Script.

### Migration tooling

```bash
# One-shot data sync, Sheets → Supabase. Idempotent (UPSERT on id).
# The secret key never lands in git — passed via env.
SUPABASE_SECRET_KEY=sb_secret_xxxxx python3 supabase/migrate.py

# Re-run with --include-activity at final cutover to bring across log history
# (activity is plain INSERT, not UPSERT, so don't pass this flag on repeat runs)
SUPABASE_SECRET_KEY=sb_secret_xxxxx python3 supabase/migrate.py --include-activity
```

`migrate.py` uses urllib (stdlib only — no pip install) and handles gviz date parsing, boolean coercion, PostgREST row-batching by key shape, and `Prefer: missing=default` for column defaults.

## Design system

Restrained **EI Blue (`#012747`)** on warm paper (`#faf9f6`), with a navy topbar. Full token list in the `:root` block of every HTML file (or the `reference_design_system.md` memory file).

Three fonts, all from Google Fonts (same link on every page):
- **Inter Tight** — body, headings, tabular numbers
- **Fraunces** italic 400 — accent only (hero greeting, login screen closing word). Don't sprinkle elsewhere
- **JetBrains Mono** — mono uppercase eyebrows, KPI labels, mono badges

There's a **canonical unified topbar** CSS block at the END of the `<style>` of every page, prefixed `/* ── Canonical unified topbar (overrides any earlier per-page rules) ── */` and using `!important` everywhere to win against page-specific older styles. **If you change the topbar visually, you must edit this block in all five HTML files identically.** Don't add a new override block — overwrite the canonical one.

Common components (`.btn`, `.card`, `.badge`, `.kpi-card`, `.section-label`, `.screen-eyebrow`, `.screen-title`, `.detail-grid`) follow the same pattern across pages. The shared **Cmd+K palette** (`.cmdk-*`) and **toast/confirm system** (`.ei-toast-*`, `.ei-confirm-*`) live below the main `</script>` on every page and are pasted verbatim.

## Workflow rules (memory-backed)

These are user-confirmed instructions from previous sessions. Honor them.

1. **Push directly to `origin/main`.** No PRs, no feature branches.
2. **Announce user-facing pushes.** After shipping a user-visible change, POST to the Auth Handle script's `saveAnnouncement` endpoint so a card appears on the hub. **The Slack webhook fires on insert**, so:
   - Generate the announcement `id` as a separate step first and `echo` it to verify it looks like `ann_<short_hash>` and not `ann_` (use `python3 -c 'import time; print(format(int(time.time()*1000),"x"))'` for the suffix).
   - Treat the post as non-reversible. If the title/message is wrong after posting, ask the user — re-posting fires Slack again.
   - Skip the announcement on pure refactors, comment-only changes, internal config tweaks.
3. **Never propose deletion of `pipeline.html`** (or its hub card, topbar link, or `RESTRICTED_TOOLS` entry) unless the user explicitly says "remove pipeline" / "delete the pipeline tool." It's parked but they want optionality.
4. **Hub `RESTRICTED_TOOLS`** = `["pipeline.html", "accounts.html"]`. Non-admin users see these as "Coming Soon" on the hub. The admin allowlist is `ADMIN_USERS = ["relliott"]` in `index.html`. This is a UI gate only — auth happens at the Supabase layer.

## Useful in-repo references

- `supabase/schema.sql` — the source of truth for the Postgres schema. Includes RLS policy and grant setup.
- `supabase/migrate.py` — Sheets→Supabase migrator. Read this if you need to understand how legacy data shapes map to the new schema.
- `~/.claude/projects/-Users-ryan-Desktop-ei-tools/memory/` — longer-form project memory: `project_overview.md`, `reference_design_system.md`, `reference_apps_scripts.md`, and feedback notes. Read these for the "why" behind specific decisions.
