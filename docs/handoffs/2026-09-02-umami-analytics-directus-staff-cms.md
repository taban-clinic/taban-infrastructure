# Handoff — Umami analytics + Directus staff CMS access

**Date:** 2026-09-02
**Scope:** all three taban sites (`dr-yousefi.ir`, `iran-implant-rescue-institute.ir` /
`clinic-next`, `implantrescue.ir` / `implant-rescue-institute`) plus the shared origin box
(`94.101.177.69`).

## What's live now

### 1. Umami web analytics — all three sites tracked
- Dashboard: **https://analytics.dr-yousefi.ir** — Umami's own login only (no Basic Auth
  in front; see "Incidents" below for why that was tried and removed).
- Verified end-to-end with real browser traffic, not just curl (curl can't execute the
  tracking JS, so an earlier "it looks deployed" check was misleading — the actual
  pageview beacon only fires from a real page load).
- Website IDs: `dr-yousefi-site` `ccc2b195-52cb-4963-a4b5-41b371c3f3df`,
  `implant-rescue-institute` `74bc730a-6d84-42c6-b9b5-933d97333623`, `clinic-next`
  `ff89ab9a-faa6-4ec5-b65e-8d983644656b`.
- **Why the tracking script is served from `analytics.dr-yousefi.ir` and not
  `analytics.implantrescue.ir`**: the only Arvan API key on file
  (`taban-infrastructure/.envrc`'s `ARVAN_API_KEY`) is access-policy-scoped to the
  `dr-yousefi.ir` zone only (confirmed live — the domains-list API returns exactly one
  domain for this key). Rather than widen the key's scope or mint a new one,
  `analytics.dr-yousefi.ir` was used instead. The Caddy block lists both hostnames, so if
  `implantrescue.ir`'s zone ever gets its own scoped key, the second hostname activates
  with zero further work.
- Credentials: `~/secrets/taban-umami-infra.env` (on the operator's machine, m4).

### 2. Directus staff CMS access — new, didn't exist before this session
- URL: **https://cms.dr-yousefi.ir**. Before this session, Directus had **no public
  route at all** — only reachable via SSH tunnel to `localhost:61984` on the origin,
  which meant nobody except someone with SSH access could see a booking or a lead. That
  was an unfinished part of the original "lab" setup, not a deliberate security choice.
- The owner's own staff account (`zixlancer@gmail.com`, credentials in
  `~/secrets/taban-directus-staff-account.env`) has a scoped **"Staff"** role → **"Staff
  — Bookings & Leads"** policy: full CRUD on `appointments` and `institute_leads` only.
  Verified live: `doctors`/`services`/`availability`/other users are all `403 Forbidden`
  under this account.
- To add another staff member later: create a `directus_users` row with `role` set to
  the "Staff" role's UUID (`aba231fb-44b3-4de7-a7ea-26a8e7c24ff5` as of creation — verify
  it still exists first) and a fresh password. No new permissions work needed.
- Real production Directus admin superuser (`admin@iran-implant-rescue-institute.ir`,
  **not** the local dev lab's `admin@clinic-lab.dev`): credentials in
  `~/secrets/taban-directus-shared-infra.env`. Real collections in this shared instance:
  `appointments`, `availability`, `doctors`, `institute_articles`, `institute_leads`,
  `institute_pages`, `services`.

## Incidents this session (both caught and fixed same-session)

### A. clinic-next booking page went down during redeploy
A routine `rsync --delete` redeploy (to push the new analytics domain into the tracking
snippet) excluded `.env`, `.env.local`, and `.env.production.local` — an exclude list
copied from the other two sites' `DEPLOY.md` runbooks. The actual production file on
`clinic-next` was named plain **`.env.production`** (no `.local`), which wasn't on that
list and doesn't exist in the local repo, so `rsync --delete` silently removed it. This
wiped `DIRECTUS_URL`/`DIRECTUS_PATIENT_BOOKING_TOKEN` and took `/booking` down
(`Error: Missing required env var: DIRECTUS_URL`) until it was caught via the user's own
screenshot of the broken page.

**Recovery:** re-ran `lab/permissions.ts` on the origin to reissue a fresh
`DIRECTUS_PATIENT_BOOKING_TOKEN` (the admin credentials in `lab/.env` had survived — a
different exclude pattern protected it), wrote a new `.env.production.local` by hand,
restarted the service. Verified `200` on `/booking` both locally on the origin and
publicly.

**Structural fix:** `clinic-next/DEPLOY.md` now exists (it didn't before — the other two
sites had one, this one didn't) and documents the real file name plus a "Known gap"
section telling the next redeploy to `ls -la ~/clinic-next/.env*` on the server before
trusting any exclude list. The recovered file is also backed up locally at
`~/secrets/taban-clinic-next-infra.env`.

### B. Basic Auth on the analytics dashboard broke Umami's own login
Caddy's `basicauth` directive was applied with no path scoping, so it gated *every*
request on `analytics.dr-yousefi.ir` — including `/script.js` (breaking real visitor
tracking, since a `<script>` tag never sends Basic Auth credentials) and, after a first
attempt to narrow the scope, still gated `/api/auth/login` (breaking Umami's own login —
a `fetch()` to a Basic-Auth-gated endpoint that didn't carry cached credentials got an
empty `401` body, which Umami's JS then crashed trying to `.json()` parse).

**Fix:** removed Basic Auth from the analytics vhost entirely. Umami already has its own
password-protected login; a second HTTP-Basic-Auth layer in front of it was redundant
friction, not real added security, and HTTP Basic Auth's credential-attachment on
`fetch()`/XHR calls is fragile in exactly the way that caused this. **If a second layer
is ever wanted again, use session-cookie-based edge auth, not HTTP Basic Auth.**

## Not done / open follow-ups

- Only one staff account exists (the owner's own). Adding real clinic staff needs their
  names/emails — the process above is ready, just needs the actual people.
- `implantrescue.ir`'s own DNS zone still has no scoped Arvan API key on file, so its
  Caddy `analytics.implantrescue.ir` hostname (already configured) stays dormant until
  one is provisioned.
- The Umami/Directus `analytics`/`cms` subdomains both live under the `dr-yousefi.ir`
  zone as a practical workaround for the API-key-scoping issue above, not because that's
  the "correct" long-term home for shared taban-wide services. Worth revisiting if a
  proper shared-infra subdomain strategy is ever designed (e.g. a dedicated zone key, or
  moving these under a zone meant for cross-brand tooling).
- `dr-yousefi-site`'s own `/admin` login password was intentionally **not** fetched this
  session (the sandbox's safety classifier blocks reading a live production secrets file
  over SSH) — retrieve it yourself if needed:
  `ssh -o ProxyCommand="nc -X 5 -x 127.0.0.1:1080 94.101.177.69 22" -i ~/.ssh/id_ed25519_taban ubuntu@94.101.177.69 "cat ~/dr-yousefi-site/.env"`

## PRs merged this session

- `clinic-next` #39 (analytics domain swap), #40 (DEPLOY.md)
- `implant-rescue-institute` #16 (analytics domain swap)
- `dr-yousefi-site` #13 (analytics domain swap)

## Secrets backed up (all at `~/secrets/` on the operator's machine, mode 600)

| File | Contents |
|---|---|
| `taban-umami-infra.env` | Umami app secret, DB password, dashboard creds (Basic Auth creds now unused) |
| `taban-clinic-next-infra.env` | clinic-next's recovered production env (Directus URL + booking token) |
| `taban-directus-shared-infra.env` | Real production Directus admin superuser |
| `taban-directus-staff-account.env` | Owner's own staff-scoped Directus login |

## Related memory (agent-facing, not for humans)

See `taban` project memory: `project-taban-shared-infra-analytics-and-staff-cms.md` and
`feedback-rsync-delete-verify-server-env-files-first.md` — same content as this handoff,
kept in sync for a future agent session to read without re-discovering via SSH.
