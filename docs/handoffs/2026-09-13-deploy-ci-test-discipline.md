# Handoff — deployment/CI/test discipline RFC, live incident response, new deploy pipeline

**Date:** 2026-09-13
**Scope:** all three taban sites (`dr-yousefi-site`, `clinic-next`, `implant-rescue-institute`),
the shared services (`umami`, `supabase`, lab Directus/Postgres), and the shared origin box
(`94.101.177.69`). Driven by [taban-infrastructure#14](https://github.com/taban-clinic/taban-infrastructure/issues/14)
(still open — see "Open follow-ups" below).

**Multi-session context, worth knowing before continuing this work:** this session ran
concurrently with two other Claude Code sessions coordinating on the same infrastructure —
`taban-hub` (relaying decisions to/from the user) and a session running directly on the
production box (`claude-on-dr-yousefi-server` — note: it was originally named plain `main`,
which is a **reserved keyword** in the cross-session messaging tool that silently self-routes
instead of reaching the actual session; renaming it fixed direct messaging). If this pattern
recurs, don't name a session `main`.

## What's live now

### 1. RFC + Discussion resolved
[#14](https://github.com/taban-clinic/taban-infrastructure/issues/14) /
[Discussion #15](https://github.com/taban-clinic/taban-infrastructure/discussions/15) — full
discovery, research (verified against `man rsync`, GitHub API for tool activity, this
machine's installed `sops`/`age`), and synthesis resolving 5 open questions: live-inventory
as a habit (superseded by `drift-check`, see below), memory limits, CI-gated tests,
`rsync --max-delete` as the real fix (not another exclude list), and `sops`+`age` over Ansible
Vault for secrets (not yet implemented — see follow-ups).

### 2. `services/` brought into git — `taban-infrastructure`
`umami`, `supabase` (override only), and `lab-directus` Docker Compose configs — previously
live-only, hand-edited files on the server with **no git home anywhere**. Now at
`services/{umami,supabase,lab-directus}/`. `services/umami/docker-compose.yml` was
parameterized before committing (the live file had a plaintext DB password + `APP_SECRET`;
this repo is public).

### 3. Security incident found and fixed — public DB + admin exposure
The lab Postgres (`clinic_prod` — includes `patients` and `otp_codes`) and Directus admin
login were reachable from the **public internet**, not just localhost as assumed. Root cause:
the compose file published ports on all interfaces, and Docker's iptables rules bypass UFW
entirely (`DOCKER-USER` chain was empty) — UFW's default-deny does **not** cover
Docker-published ports. Fixed live (ports rebound to `127.0.0.1`) and verified externally
closed; repo caught up in
[taban-infrastructure#17](https://github.com/taban-clinic/taban-infrastructure/pull/17) and
[clinic-next#44](https://github.com/taban-clinic/clinic-next/pull/44). **If any future service
publishes a Docker port, bind it to `127.0.0.1` explicitly — never assume UFW protects it.**

### 4. Live outage found and fixed — memory exhaustion
Separately, the box crashed twice tonight (~21:00 and ~22:10 UTC) from memory exhaustion with
no swap. Fixed live: a 3 GB swapfile, `earlyoom` (protects `postgres`/`caddy`/`dockerd`/
`tailscaled` from being killed), `mem_limit` on `umami`/`umami-db`/Supabase's `db`/`auth`/
`rest`, and relaxed healthcheck intervals (5s→30s, fixing a zombie-process leak from
`studio`/`meta` spawning a fresh Node process every 5s). **The box's per-service memory
limits now total ~3.9G against 2.8G RAM + 3G swap — this is a soft-overcommit guard, not a
capacity plan.** See `deploy/README.md`'s "Memory limits are guards, not a budget" section
before adding another service to this box.

### 5. New deploy pipeline — `deploy/` in `taban-infrastructure`
[#18](https://github.com/taban-clinic/taban-infrastructure/pull/18) (merged): release-based
deploys replacing the old rsync-into-live-directory pattern. `deploy-release`
(deploy/rollback/status/health with automatic rollback on failed health check),
`deploy-gate` (SSH forced command restricting the CI deploy key to upload+deploy+rollback+
status only), `migrate-app` (one-time cutover, old dir/unit never touched, auto-restores on
failure). `dr-yousefi-site` has already been migrated
(`migrate-app dr-yousefi-site --seed-from-live`) and is running on the new layout
(`~/apps/dr-yousefi-site/{releases,current,shared}`), ready for its first CI-built deploy.
43 tests passing, `shellcheck` clean.

### 6. Pinned-checkout drift detection — `services/bin/apply-service` + `drift-check`
[#19](https://github.com/taban-clinic/taban-infrastructure/pull/19) (merged): a read-only
pinned git checkout on the server (`~/taban-infrastructure`) plus `apply-service <name>` to
push a `services/*` change live (pins `-p`/`--project-directory` explicitly, so it's
independent of the `name:` field in the compose files) and `drift-check` (compares Compose
config-hashes against running containers, nightly via `taban-drift-check.timer` at 04:15 UTC).
Verified against the live server before merge: all 10 running containers already matched
`services/` on `dev` exactly.

### 7. `rsync --max-delete` safety net + CI — all 3 site repos
[dr-yousefi-site#17](https://github.com/taban-clinic/dr-yousefi-site/pull/17),
[clinic-next#45](https://github.com/taban-clinic/clinic-next/pull/45),
[implant-rescue-institute#37](https://github.com/taban-clinic/implant-rescue-institute/pull/37)
(all merged). `--max-delete=50` added to every `DEPLOY.md` redeploy rsync — a circuit breaker
independent of the exclude list (verified against `man rsync`: aborts remaining deletions,
exit code 25, if the count is exceeded), closing the actual failure mode behind two prior
outages (an exclude list that didn't cover the real env filename). Plus `.github/workflows/
ci.yml` (lint + unit tests + build) on all three — **no CI existed anywhere in the estate
before tonight.**

Fixed two pre-existing test-categorization bugs surfaced by adding this CI (not introduced by
it): `clinic-next`'s `lab/db-constraints.test.ts` needed a live Directus and was missing from
the `test:unit`/`test:integration` split; `implant-rescue-institute` had no split at all
(`lab/permissions.test.ts` and `lab/schema.test.ts` need one too — added the split).

### 8. Release-build workflow — `dr-yousefi-site` only so far
[dr-yousefi-site#18](https://github.com/taban-clinic/dr-yousefi-site/pull/18) (open, CI green,
not yet merged): the build side of decision D8 — triggers on a `v*` tag, builds standalone
output on `ubuntu-latest` with **Node 22.14.0 pinned** to match the server exactly
(`better-sqlite3` needs the matching ABI), assembles the artifact per `deploy/README.md`'s
contract exactly, hard-fails the build if any `.env*` ends up at the root, and publishes as a
GitHub Release asset. `clinic-next`/`implant-rescue-institute` don't have this yet — see
follow-ups.

## Open follow-ups (in rough priority order)

1. **Merge dr-yousefi-site#18** (release-build workflow) once reviewed.
2. **`clinic-next`/`implant-rescue-institute` need the `output: "standalone"` switch** before
   they can get their own release-build workflow — check whether this is already done or
   still pending (decision D4, described as "approved" by `taban-hub` but not confirmed done
   as of this handoff).
3. **m4 self-hosted runner + deploy key setup** — `taban-hub` said it was "handling that
   separately"; confirm status. This is the piece that actually pulls a built artifact and
   calls `deploy-gate` — without it, the release-build workflow produces artifacts nobody
   ships yet.
4. **`sops`+`age` secrets pilot** — the one item from the original RFC phasing not started.
   Plan (from Discussion #15's synthesis): generate one `age` keypair, add `.sops.yaml`,
   migrate one `~/secrets/*.env` file as a pilot, verify round-trip. A scope question (which
   file, local-only vs. touching the server) was sent to `taban-hub` and not yet answered —
   re-ask before starting.
5. **Alert channel for `drift-check`'s `ALERT_CMD`** — open question for the user, noted in
   PR #19's description, not yet decided.
6. **Migrate `clinic-next`/`implant-rescue-institute` to the new release layout** — blocked on
   their first standalone artifact existing (items 2–3 above).
7. Pre-existing, unrelated to tonight: [taban-infrastructure#9](https://github.com/taban-clinic/taban-infrastructure/pull/9)
   (Dockerized clinic-next stack spec) and issues
   [#1](https://github.com/taban-clinic/taban-infrastructure/issues/1)/[#5](https://github.com/taban-clinic/taban-infrastructure/issues/5)/[#6](https://github.com/taban-clinic/taban-infrastructure/issues/6)/[#10](https://github.com/taban-clinic/taban-infrastructure/issues/10)/[#11](https://github.com/taban-clinic/taban-infrastructure/issues/11)
   are still open, deliberately not re-litigated by this session's work (see Discussion #15
   §4).
8. **[taban-infrastructure#14](https://github.com/taban-clinic/taban-infrastructure/issues/14)
   itself is still open** — its acceptance criteria (P2/P3 CI, sops+age pilot) aren't all
   done yet. Don't close it until items 2–4 above land.

## Also fixed during this session's wrap-up (unrelated to the RFC, found doing housekeeping)

[taban-infrastructure#13](https://github.com/taban-clinic/taban-infrastructure/pull/13) — the
**previous** session's handoff doc (2026-09-02, Umami/Directus) had been sitting as an open,
unmerged PR this entire time, silently drifting behind `dev`. Merged it (clean merge, no
conflicts — it only touched a new doc file). **Worth checking for this pattern at the start of
future sessions**: an open docs/handoff PR that never got merged means the handoff itself was
never actually landed on `dev`.

## PRs merged this session

- `taban-infrastructure`: #13 (previous session's handoff, caught during wrap-up), #16
  (`services/` in git), #17 (lab-directus port exposure fix), #18 (deploy/ release system),
  #19 (apply-service + drift-check)
- `dr-yousefi-site`: #17 (rsync `--max-delete` + CI)
- `clinic-next`: #44 (lab exposure fix companion), #45 (rsync `--max-delete` + CI)
- `implant-rescue-institute`: #37 (rsync `--max-delete` + CI)

Open, not yet merged: `dr-yousefi-site`#18 (release-build workflow, CI green).

## Related memory / prior context

- `taban-infrastructure/docs/handoffs/2026-09-02-umami-analytics-directus-staff-cms.md` —
  the prior session's handoff (now actually on `dev`, see above).
- Discussion [#15](https://github.com/taban-clinic/taban-infrastructure/discussions/15) has
  the full RFC trail (verified facts, research, synthesis) if any decision here needs
  re-justifying.
