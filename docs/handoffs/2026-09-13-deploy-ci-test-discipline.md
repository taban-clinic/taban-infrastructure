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

A related, more general hazard: multiple sessions can share the same repo's **main checkout**
(not a worktree) if they don't each use `scripts/new-issue`. Twice tonight, another session's
`git checkout <its-feature-branch>` in a shared main checkout left `implant-rescue-institute`
on someone else's branch mid-session, from this session's point of view. No work was lost
(the tree was clean both times), but it's worth checking `git status --short --branch` before
trusting a main checkout's branch, rather than assuming it's still on `dev`.

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

### 8. Release-build + ship-automation workflows — all 3 apps, fully live
The build side of D8 (`.github/workflows/release.yml` per repo: `v*` tag → standalone build
on `ubuntu-24.04` with **Node 22.14.0 pinned** → artifact assembled per `deploy/README.md`'s
contract → hard `.env*` gate → GitHub Release) shipped for `dr-yousefi-site` first
([#18](https://github.com/taban-clinic/dr-yousefi-site/pull/18)), then `clinic-next`
([#46](https://github.com/taban-clinic/clinic-next/pull/46)) and
`implant-rescue-institute` ([#40](https://github.com/taban-clinic/implant-rescue-institute/pull/40))
once each got its `output: "standalone"` switch (D4).

The **ship side** (D8's other half — artifact → server) is now fully automated too, not just
built: a `ship` job on the m4 self-hosted runner (`m4-deploy-runner`, labels `m4`/`deploy`/
`macos-arm64`) downloads the Release asset, re-verifies its checksum, rsyncs it over the
tailnet with a **pinned SSH host key** (not trust-on-first-use — that needs an interactive
yes/no a CI runner can't give), then runs `deploy <app> <artifact>` through `deploy-gate`,
translating exit codes 0/1/2/3 into clear job failures. Landed for `dr-yousefi-site` first
([dr-yousefi-site#20](https://github.com/taban-clinic/dr-yousefi-site/pull/20), reviewed and
fixed — host-key pinning, tag filter restricted to exact `vX.Y.Z` since `v*` would auto-deploy
a pre-release tag to production, 15-minute timeout), then copied to
[clinic-next#47](https://github.com/taban-clinic/clinic-next/pull/47) and
[implant-rescue-institute#43](https://github.com/taban-clinic/implant-rescue-institute/pull/43).

**A `v*` tag push now goes all the way to production, hands-off, with automatic rollback on a
failed health check.** Proven working, not just designed: first real deploy through the whole
pipeline (`dr-yousefi-site v1.0.0`, ship run manually before the automation existed) worked on
the first try; subsequent tags (`dr-yousefi-site v1.0.1`, `clinic-next v1.0.0`,
`implant-rescue-institute v1.0.0`/`v1.0.1`) exist as real GitHub Releases.

### 9. All three apps migrated to the release layout
`dr-yousefi-site` (`--seed-from-live`, since it was already standalone), then `clinic-next`
and `implant-rescue-institute` (`--from-tarball`, once their first CI artifact existed) — all
via `migrate-app`, run server-side. Old directories (`~/dr-yousefi-site`, `~/clinic-next`,
`~/implant-rescue-institute`) were **never modified**, only read from; each app now runs from
`~/apps/<app>/current` per `deploy/README.md`'s layout.

### 10. Three more `deploy`/`services` fixes landed after the initial pipeline PRs
- [#21](https://github.com/taban-clinic/taban-infrastructure/pull/21) — `migrate-app`'s advice
  to delete the old app dir after a week was wrong for `clinic-next`/`implant-rescue-institute`:
  their old dirs also host the `lab` Docker Compose project (Postgres/Directus), so deleting
  them would have taken down shared infra, not just cleaned up a stale directory.
- [#22](https://github.com/taban-clinic/taban-infrastructure/pull/22) — `deploy-release` now
  removes the uploaded artifact from `~/apps/incoming/` after a successful deploy, instead of
  letting them accumulate.
- [#23](https://github.com/taban-clinic/taban-infrastructure/pull/23) — relocated the
  `lab-directus` Compose project out of the app directories entirely (into its own home under
  `services/`), added a **named volume for Directus's uploaded files** (they previously lived
  inside the container — meaning a container recreate would have silently lost every uploaded
  file), and added `apply-service --recreate`.

## Open follow-ups (in rough priority order)

1. **`sops`+`age` secrets pilot** — the one item from the original RFC phasing never started
   tonight. Plan (from Discussion #15's synthesis): generate one `age` keypair, add
   `.sops.yaml`, migrate one `~/secrets/*.env` file as a pilot, verify round-trip.
   Deliberately deferred to next session per the user's explicit call.
2. **Alert channel for `drift-check`'s `ALERT_CMD`** — open question for the user, noted in
   PR #19's description, not yet decided.
3. **Old app directories** (`~/dr-yousefi-site`, `~/clinic-next`, `~/implant-rescue-institute`)
   are still on the server, untouched, as the migration runbook intends — safe to remove only
   after real confidence in the new pipeline (a week+ of normal deploys was the original
   guidance) and, per #21 above, only the parts that aren't also hosting the `lab` Compose
   project.
4. Pre-existing, unrelated to tonight: [taban-infrastructure#9](https://github.com/taban-clinic/taban-infrastructure/pull/9)
   (Dockerized clinic-next stack spec) and issues
   [#1](https://github.com/taban-clinic/taban-infrastructure/issues/1)/[#5](https://github.com/taban-clinic/taban-infrastructure/issues/5)/[#6](https://github.com/taban-clinic/taban-infrastructure/issues/6)/[#10](https://github.com/taban-clinic/taban-infrastructure/issues/10)/[#11](https://github.com/taban-clinic/taban-infrastructure/issues/11)
   are still open, deliberately not re-litigated by this session's work (see Discussion #15
   §4).
5. **[taban-infrastructure#14](https://github.com/taban-clinic/taban-infrastructure/issues/14)
   is still open** — deliberately: item 1 above (sops+age) is its one unfinished acceptance
   criterion. Close it once that lands, not before.

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
  #19 (apply-service + drift-check), #20 (this doc's first version), #21 (migrate-app old-dir
  advice fix), #22 (artifact cleanup after deploy), #23 (lab-directus relocation + persistent
  Directus uploads volume)
- `dr-yousefi-site`: #17 (rsync `--max-delete` + CI), #18 (release-build workflow), #20
  (ship automation, reviewed/fixed)
- `clinic-next`: #44 (lab exposure fix companion), #45 (rsync `--max-delete` + CI), #46
  (standalone + release-build workflow), #47 (ship automation)
- `implant-rescue-institute`: #37 (rsync `--max-delete` + CI), #40 (standalone +
  release-build workflow), #41 (sitemap.ts SEO fix — was prerendering once at build time
  against a placeholder Directus URL, shipping an empty sitemap), #43 (ship automation)

Everything above is merged — nothing left open from tonight's PRs.

## Related memory / prior context

- `taban-infrastructure/docs/handoffs/2026-09-02-umami-analytics-directus-staff-cms.md` —
  the prior session's handoff (now actually on `dev`, see above).
- Discussion [#15](https://github.com/taban-clinic/taban-infrastructure/discussions/15) has
  the full RFC trail (verified facts, research, synthesis) if any decision here needs
  re-justifying.
